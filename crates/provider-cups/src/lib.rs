//! Bounded, dependency-free IPP client for the protected CUPS endpoint.
//!
//! Guest provisioning stays in `guest/`; this adapter speaks IPP directly and
//! never shells out to SSH, CUPS tools, or a command interpreter.

use std::io::{ErrorKind, Read, Write};
use std::net::{IpAddr, SocketAddr, TcpStream};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;

use printbridge_domain::{
    BridgeError, ComponentState, ComponentStatus, DiagnosticEntry, GuestPrinting, JobId, JobState,
    PrintJob, PrintQueue, PrinterEndpoint,
};

const IPP_GET_JOBS: u16 = 0x000a;
const IPP_GET_PRINTER_ATTRIBUTES: u16 = 0x000b;
const IPP_PRINT_JOB: u16 = 0x0002;
const MAX_RESPONSE_BYTES: usize = 1024 * 1024;

#[derive(Debug)]
pub struct CupsIppProvider {
    endpoint: PrinterEndpoint,
    timeout: Duration,
    next_request_id: AtomicU32,
}

impl CupsIppProvider {
    #[must_use]
    pub fn new(endpoint: PrinterEndpoint, timeout: Duration) -> Self {
        Self {
            endpoint,
            timeout,
            next_request_id: AtomicU32::new(1),
        }
    }

    fn request_id(&self) -> u32 {
        self.next_request_id.fetch_add(1, Ordering::Relaxed)
    }

    fn get_printer_attributes(
        &self,
        endpoint: &PrinterEndpoint,
    ) -> Result<IppResponse, BridgeError> {
        let uri = endpoint_uri(endpoint);
        let mut request = IppRequest::new(IPP_GET_PRINTER_ATTRIBUTES, self.request_id());
        request.operation_defaults(&uri);
        let requested = [
            "printer-name",
            "printer-state",
            "printer-state-reasons",
            "printer-is-accepting-jobs",
            "printer-make-and-model",
            "queued-job-count",
        ];
        request.attribute(0x44, "requested-attributes", requested[0].as_bytes());
        for attribute in &requested[1..] {
            request.additional_value(0x44, attribute.as_bytes());
        }
        self.send(endpoint, request.finish(&[]))
    }

    fn ensure_queue(&self, queue: &str) -> Result<(), BridgeError> {
        if queue == self.endpoint.queue() {
            Ok(())
        } else {
            Err(BridgeError::PrinterMissing {
                printer: queue.into(),
                action: "Use the configured PrintBridge CUPS queue.".into(),
            })
        }
    }

    fn send(&self, endpoint: &PrinterEndpoint, body: Vec<u8>) -> Result<IppResponse, BridgeError> {
        let address = SocketAddr::new(endpoint.host(), endpoint.port());
        let mut stream = TcpStream::connect_timeout(&address, self.timeout)
            .map_err(|error| ipp_error(endpoint, &format!("connect failed: {error}")))?;
        stream
            .set_read_timeout(Some(self.timeout))
            .map_err(|error| ipp_error(endpoint, &format!("read timeout setup failed: {error}")))?;
        stream
            .set_write_timeout(Some(self.timeout))
            .map_err(|error| {
                ipp_error(endpoint, &format!("write timeout setup failed: {error}"))
            })?;
        let host = match endpoint.host() {
            IpAddr::V4(address) => address.to_string(),
            IpAddr::V6(address) => format!("[{address}]"),
        };
        let header = format!(
            "POST /printers/{} HTTP/1.1\r\nHost: {host}:{}\r\nContent-Type: application/ipp\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            encode_path_segment(endpoint.queue()),
            endpoint.port(),
            body.len()
        );
        stream
            .write_all(header.as_bytes())
            .and_then(|()| stream.write_all(&body))
            .and_then(|()| stream.flush())
            .map_err(|error| ipp_error(endpoint, &format!("request write failed: {error}")))?;

        let mut response = Vec::new();
        let mut chunk = [0_u8; 8192];
        loop {
            match stream.read(&mut chunk) {
                Ok(0) => break,
                Ok(count) => {
                    response.extend_from_slice(&chunk[..count]);
                    if response.len() > MAX_RESPONSE_BYTES {
                        return Err(ipp_error(
                            endpoint,
                            "response exceeded the 1 MiB safety limit",
                        ));
                    }
                    if let Some(expected) = http_response_length(endpoint, &response)? {
                        if response.len() >= expected {
                            response.truncate(expected);
                            break;
                        }
                    }
                    if let Some(expected) = chunked_response_length(endpoint, &response)? {
                        response.truncate(expected);
                        break;
                    }
                }
                Err(error)
                    if matches!(error.kind(), ErrorKind::TimedOut | ErrorKind::WouldBlock) =>
                {
                    return Err(ipp_error(
                        endpoint,
                        "timed out before the declared HTTP body arrived",
                    ));
                }
                Err(error) => {
                    return Err(ipp_error(
                        endpoint,
                        &format!("response read failed: {error}"),
                    ));
                }
            }
        }
        parse_http_ipp(endpoint, &response)
    }
}

impl GuestPrinting for CupsIppProvider {
    fn probe_ipp(&self, endpoint: &PrinterEndpoint) -> Result<(), BridgeError> {
        self.get_printer_attributes(endpoint).map(|_| ())
    }

    fn list_queues(&self) -> Result<Vec<PrintQueue>, BridgeError> {
        let response = self.get_printer_attributes(&self.endpoint)?;
        let name = response
            .first_text("printer-name")
            .unwrap_or_else(|| self.endpoint.queue().to_string());
        let driver = response
            .first_text("printer-make-and-model")
            .unwrap_or_else(|| "CUPS IPP queue".into());
        Ok(vec![PrintQueue { name, driver }])
    }

    fn queue_status(&self, queue: &str) -> Result<ComponentStatus, BridgeError> {
        self.ensure_queue(queue)?;
        let response = self.get_printer_attributes(&self.endpoint)?;
        let printer_state = response.first_integer("printer-state").unwrap_or(5);
        let accepting = response.first_boolean("printer-is-accepting-jobs");
        let reasons = response.texts("printer-state-reasons").join(",");
        let state = match (printer_state, accepting) {
            (3 | 4, Some(true)) => ComponentState::Ready,
            (3 | 4, _) => ComponentState::Degraded,
            _ => ComponentState::Error,
        };
        let detail = if reasons.is_empty() {
            format!("IPP printer-state={printer_state}; accepting={accepting:?}")
        } else {
            format!("IPP printer-state={printer_state}; accepting={accepting:?}; reasons={reasons}")
        };
        Ok(ComponentStatus::with_detail(state, detail))
    }

    fn submit_test_page(&mut self, queue: &str) -> Result<PrintJob, BridgeError> {
        self.ensure_queue(queue)?;
        let uri = endpoint_uri(&self.endpoint);
        let mut request = IppRequest::new(IPP_PRINT_JOB, self.request_id());
        request.operation_defaults(&uri);
        request.attribute(0x42, "requesting-user-name", b"printbridge");
        request.attribute(0x42, "job-name", b"PrintBridge IPP test page");
        request.attribute(0x49, "document-format", b"text/plain");
        let document =
            b"PrintBridge IPP software test page\nPhysical output requires owner confirmation.\n";
        let response = self.send(&self.endpoint, request.finish(document))?;
        let id = response
            .first_integer("job-id")
            .and_then(|value| u64::try_from(value).ok())
            .ok_or_else(|| ipp_error(&self.endpoint, "Print-Job response omitted job-id"))?;
        Ok(PrintJob {
            id: JobId(id),
            state: JobState::Accepted,
            physical_confirmation_source: None,
        })
    }

    fn jobs(&self, queue: &str) -> Result<Vec<PrintJob>, BridgeError> {
        self.ensure_queue(queue)?;
        let uri = endpoint_uri(&self.endpoint);
        let mut request = IppRequest::new(IPP_GET_JOBS, self.request_id());
        request.operation_defaults(&uri);
        request.attribute(0x44, "which-jobs", b"all");
        request.attribute(0x44, "requested-attributes", b"job-id");
        request.additional_value(0x44, b"job-state");
        let response = self.send(&self.endpoint, request.finish(&[]))?;
        let mut jobs = Vec::new();
        for group in response.groups.iter().filter(|group| group.tag == 0x02) {
            let Some(id) = group.first_integer("job-id") else {
                continue;
            };
            let Some(id) = u64::try_from(id).ok() else {
                continue;
            };
            let state = match group.first_integer("job-state") {
                Some(9) => JobState::CompletedByCups,
                Some(7 | 8) => JobState::Failed,
                _ => JobState::Accepted,
            };
            jobs.push(PrintJob {
                id: JobId(id),
                state,
                physical_confirmation_source: None,
            });
        }
        Ok(jobs)
    }

    fn diagnostics(&self) -> Result<Vec<DiagnosticEntry>, BridgeError> {
        let response = self.get_printer_attributes(&self.endpoint)?;
        Ok(vec![
            DiagnosticEntry {
                name: "provider".into(),
                value: "cups-ipp".into(),
                sensitive: false,
            },
            DiagnosticEntry {
                name: "endpoint".into(),
                value: format!("{}:{}", self.endpoint.host(), self.endpoint.port()),
                sensitive: false,
            },
            DiagnosticEntry {
                name: "queue".into(),
                value: self.endpoint.queue().into(),
                sensitive: false,
            },
            DiagnosticEntry {
                name: "printer_state".into(),
                value: response
                    .first_integer("printer-state")
                    .map_or_else(|| "unknown".into(), |value| value.to_string()),
                sensitive: false,
            },
            DiagnosticEntry {
                name: "accepting_jobs".into(),
                value: response
                    .first_boolean("printer-is-accepting-jobs")
                    .map_or_else(|| "unknown".into(), |value| value.to_string()),
                sensitive: false,
            },
            DiagnosticEntry {
                name: "printer_state_reasons".into(),
                value: response.texts("printer-state-reasons").join(","),
                sensitive: false,
            },
            DiagnosticEntry {
                name: "physical_output".into(),
                value: "not_inferred".into(),
                sensitive: false,
            },
        ])
    }
}

#[derive(Debug)]
struct IppRequest {
    bytes: Vec<u8>,
}

impl IppRequest {
    fn new(operation: u16, request_id: u32) -> Self {
        let mut bytes = Vec::with_capacity(256);
        bytes.extend_from_slice(&[0x02, 0x00]);
        bytes.extend_from_slice(&operation.to_be_bytes());
        bytes.extend_from_slice(&request_id.to_be_bytes());
        bytes.push(0x01);
        Self { bytes }
    }

    fn operation_defaults(&mut self, printer_uri: &str) {
        self.attribute(0x47, "attributes-charset", b"utf-8");
        self.attribute(0x48, "attributes-natural-language", b"en");
        self.attribute(0x45, "printer-uri", printer_uri.as_bytes());
    }

    fn attribute(&mut self, value_tag: u8, name: &str, value: &[u8]) {
        let name_len = u16::try_from(name.len()).expect("fixed IPP attribute name is short");
        let value_len = u16::try_from(value.len()).expect("bounded IPP attribute value is short");
        self.bytes.push(value_tag);
        self.bytes.extend_from_slice(&name_len.to_be_bytes());
        self.bytes.extend_from_slice(name.as_bytes());
        self.bytes.extend_from_slice(&value_len.to_be_bytes());
        self.bytes.extend_from_slice(value);
    }

    fn additional_value(&mut self, value_tag: u8, value: &[u8]) {
        let value_len = u16::try_from(value.len()).expect("bounded IPP attribute value is short");
        self.bytes.push(value_tag);
        self.bytes.extend_from_slice(&0_u16.to_be_bytes());
        self.bytes.extend_from_slice(&value_len.to_be_bytes());
        self.bytes.extend_from_slice(value);
    }

    fn finish(mut self, document: &[u8]) -> Vec<u8> {
        self.bytes.push(0x03);
        self.bytes.extend_from_slice(document);
        self.bytes
    }
}

#[derive(Debug)]
struct IppResponse {
    groups: Vec<IppGroup>,
}

impl IppResponse {
    fn first_value(&self, name: &str) -> Option<&IppValue> {
        self.groups.iter().find_map(|group| group.first_value(name))
    }

    fn first_text(&self, name: &str) -> Option<String> {
        match self.first_value(name) {
            Some(IppValue::Text(value)) => Some(value.clone()),
            _ => None,
        }
    }

    fn texts(&self, name: &str) -> Vec<String> {
        self.groups
            .iter()
            .flat_map(|group| group.attributes.iter())
            .filter_map(|attribute| match (&*attribute.name, &attribute.value) {
                (observed, IppValue::Text(value)) if observed == name => Some(value.clone()),
                _ => None,
            })
            .collect()
    }

    fn first_integer(&self, name: &str) -> Option<i32> {
        match self.first_value(name) {
            Some(IppValue::Integer(value)) => Some(*value),
            _ => None,
        }
    }

    fn first_boolean(&self, name: &str) -> Option<bool> {
        match self.first_value(name) {
            Some(IppValue::Boolean(value)) => Some(*value),
            _ => None,
        }
    }
}

#[derive(Debug)]
struct IppGroup {
    tag: u8,
    attributes: Vec<IppAttribute>,
}

impl IppGroup {
    fn first_value(&self, name: &str) -> Option<&IppValue> {
        self.attributes
            .iter()
            .find(|attribute| attribute.name == name)
            .map(|attribute| &attribute.value)
    }

    fn first_integer(&self, name: &str) -> Option<i32> {
        match self.first_value(name) {
            Some(IppValue::Integer(value)) => Some(*value),
            _ => None,
        }
    }
}

#[derive(Debug)]
struct IppAttribute {
    name: String,
    value: IppValue,
}

#[derive(Debug)]
enum IppValue {
    Integer(i32),
    Boolean(bool),
    Text(String),
    Opaque,
}

fn parse_http_ipp(endpoint: &PrinterEndpoint, response: &[u8]) -> Result<IppResponse, BridgeError> {
    let separator = response
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .ok_or_else(|| ipp_error(endpoint, "HTTP response omitted the header terminator"))?;
    let headers = std::str::from_utf8(&response[..separator])
        .map_err(|_| ipp_error(endpoint, "HTTP response headers were not UTF-8"))?;
    let status = headers.lines().next().unwrap_or_default();
    if !status.starts_with("HTTP/1.1 200 ") && !status.starts_with("HTTP/1.0 200 ") {
        return Err(ipp_error(endpoint, "CUPS returned a non-200 HTTP status"));
    }
    let encoded_body = &response[separator + 4..];
    let body = if header_has_token(headers, "transfer-encoding", "chunked") {
        decode_chunked_body(endpoint, encoded_body)?
    } else {
        encoded_body.to_vec()
    };
    parse_ipp(endpoint, &body)
}

fn http_response_length(
    endpoint: &PrinterEndpoint,
    response: &[u8],
) -> Result<Option<usize>, BridgeError> {
    let Some(separator) = response.windows(4).position(|window| window == b"\r\n\r\n") else {
        return Ok(None);
    };
    let headers = std::str::from_utf8(&response[..separator])
        .map_err(|_| ipp_error(endpoint, "HTTP response headers were not UTF-8"))?;
    let content_length = headers.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.eq_ignore_ascii_case("content-length")
            .then(|| value.trim().parse::<usize>())
    });
    let Some(content_length) = content_length else {
        return Ok(None);
    };
    let content_length =
        content_length.map_err(|_| ipp_error(endpoint, "HTTP Content-Length was invalid"))?;
    let total = separator
        .checked_add(4)
        .and_then(|value| value.checked_add(content_length))
        .ok_or_else(|| ipp_error(endpoint, "HTTP response length overflowed"))?;
    if total > MAX_RESPONSE_BYTES {
        return Err(ipp_error(
            endpoint,
            "declared HTTP response exceeded the 1 MiB safety limit",
        ));
    }
    Ok(Some(total))
}

fn chunked_response_length(
    endpoint: &PrinterEndpoint,
    response: &[u8],
) -> Result<Option<usize>, BridgeError> {
    let Some(separator) = response.windows(4).position(|window| window == b"\r\n\r\n") else {
        return Ok(None);
    };
    let headers = std::str::from_utf8(&response[..separator])
        .map_err(|_| ipp_error(endpoint, "HTTP response headers were not UTF-8"))?;
    if !header_has_token(headers, "transfer-encoding", "chunked") {
        return Ok(None);
    }
    let body = &response[separator + 4..];
    let Some(encoded_length) = complete_chunked_length(endpoint, body)? else {
        return Ok(None);
    };
    separator
        .checked_add(4)
        .and_then(|value| value.checked_add(encoded_length))
        .map(Some)
        .ok_or_else(|| ipp_error(endpoint, "chunked HTTP response length overflowed"))
}

fn complete_chunked_length(
    endpoint: &PrinterEndpoint,
    body: &[u8],
) -> Result<Option<usize>, BridgeError> {
    let mut offset = 0;
    loop {
        let Some(line_end) = body[offset..].windows(2).position(|part| part == b"\r\n") else {
            return Ok(None);
        };
        let size_line = std::str::from_utf8(&body[offset..offset + line_end])
            .map_err(|_| ipp_error(endpoint, "chunk size was not ASCII"))?;
        let size_text = size_line.split(';').next().unwrap_or_default().trim();
        let size = usize::from_str_radix(size_text, 16)
            .map_err(|_| ipp_error(endpoint, "chunk size was invalid"))?;
        offset = offset
            .checked_add(line_end + 2)
            .ok_or_else(|| ipp_error(endpoint, "chunk offset overflowed"))?;
        if size == 0 {
            if body.get(offset..offset + 2) == Some(b"\r\n") {
                return Ok(Some(offset + 2));
            }
            let Some(trailer_end) = body[offset..]
                .windows(4)
                .position(|part| part == b"\r\n\r\n")
            else {
                return Ok(None);
            };
            return Ok(Some(offset + trailer_end + 4));
        }
        let Some(chunk_end) = offset.checked_add(size) else {
            return Err(ipp_error(endpoint, "chunk length overflowed"));
        };
        if body.len() < chunk_end + 2 {
            return Ok(None);
        }
        if body.get(chunk_end..chunk_end + 2) != Some(b"\r\n") {
            return Err(ipp_error(endpoint, "chunk data omitted its terminator"));
        }
        offset = chunk_end + 2;
    }
}

fn decode_chunked_body(endpoint: &PrinterEndpoint, body: &[u8]) -> Result<Vec<u8>, BridgeError> {
    let mut decoded = Vec::new();
    let mut offset = 0;
    loop {
        let line_end = body[offset..]
            .windows(2)
            .position(|part| part == b"\r\n")
            .ok_or_else(|| ipp_error(endpoint, "chunked body was incomplete"))?;
        let size_line = std::str::from_utf8(&body[offset..offset + line_end])
            .map_err(|_| ipp_error(endpoint, "chunk size was not ASCII"))?;
        let size =
            usize::from_str_radix(size_line.split(';').next().unwrap_or_default().trim(), 16)
                .map_err(|_| ipp_error(endpoint, "chunk size was invalid"))?;
        offset += line_end + 2;
        if size == 0 {
            return Ok(decoded);
        }
        let end = offset
            .checked_add(size)
            .ok_or_else(|| ipp_error(endpoint, "chunk length overflowed"))?;
        let chunk = body
            .get(offset..end)
            .ok_or_else(|| ipp_error(endpoint, "chunked body was truncated"))?;
        decoded.extend_from_slice(chunk);
        if decoded.len() > MAX_RESPONSE_BYTES {
            return Err(ipp_error(
                endpoint,
                "decoded response exceeded the 1 MiB safety limit",
            ));
        }
        if body.get(end..end + 2) != Some(b"\r\n") {
            return Err(ipp_error(endpoint, "chunk data omitted its terminator"));
        }
        offset = end + 2;
    }
}

fn header_has_token(headers: &str, expected_name: &str, expected_token: &str) -> bool {
    headers.lines().any(|line| {
        let Some((name, value)) = line.split_once(':') else {
            return false;
        };
        name.eq_ignore_ascii_case(expected_name)
            && value
                .split(',')
                .any(|token| token.trim().eq_ignore_ascii_case(expected_token))
    })
}

fn parse_ipp(endpoint: &PrinterEndpoint, bytes: &[u8]) -> Result<IppResponse, BridgeError> {
    if bytes.len() < 9 || bytes[0] != 0x02 {
        return Err(ipp_error(
            endpoint,
            "response did not contain an IPP 2.x header",
        ));
    }
    let status = u16::from_be_bytes([bytes[2], bytes[3]]);
    if status >= 0x0100 {
        return Err(ipp_error(
            endpoint,
            &format!("CUPS returned IPP status 0x{status:04x}"),
        ));
    }
    let mut offset = 8;
    let mut groups = Vec::<IppGroup>::new();
    let mut current_name = String::new();
    while offset < bytes.len() {
        let tag = bytes[offset];
        offset += 1;
        if tag == 0x03 {
            return Ok(IppResponse { groups });
        }
        if (0x01..=0x0f).contains(&tag) {
            groups.push(IppGroup {
                tag,
                attributes: Vec::new(),
            });
            current_name.clear();
            continue;
        }
        let name_len = read_u16(endpoint, bytes, &mut offset)? as usize;
        if offset + name_len > bytes.len() {
            return Err(ipp_error(endpoint, "truncated IPP attribute name"));
        }
        if name_len > 0 {
            current_name = String::from_utf8_lossy(&bytes[offset..offset + name_len]).into_owned();
        }
        offset += name_len;
        if current_name.is_empty() {
            return Err(ipp_error(
                endpoint,
                "IPP attribute omitted its initial name",
            ));
        }
        let value_len = read_u16(endpoint, bytes, &mut offset)? as usize;
        if offset + value_len > bytes.len() {
            return Err(ipp_error(endpoint, "truncated IPP attribute value"));
        }
        let raw = &bytes[offset..offset + value_len];
        offset += value_len;
        let value = match tag {
            0x21 | 0x23 if raw.len() == 4 => {
                IppValue::Integer(i32::from_be_bytes([raw[0], raw[1], raw[2], raw[3]]))
            }
            0x22 if raw.len() == 1 => IppValue::Boolean(raw[0] != 0),
            0x41..=0x49 | 0x5a => IppValue::Text(String::from_utf8_lossy(raw).into_owned()),
            _ => IppValue::Opaque,
        };
        let Some(group) = groups.last_mut() else {
            return Err(ipp_error(endpoint, "IPP value appeared before a group tag"));
        };
        group.attributes.push(IppAttribute {
            name: current_name.clone(),
            value,
        });
    }
    Err(ipp_error(endpoint, "IPP response omitted the end tag"))
}

fn read_u16(
    endpoint: &PrinterEndpoint,
    bytes: &[u8],
    offset: &mut usize,
) -> Result<u16, BridgeError> {
    if *offset + 2 > bytes.len() {
        return Err(ipp_error(endpoint, "truncated IPP length"));
    }
    let value = u16::from_be_bytes([bytes[*offset], bytes[*offset + 1]]);
    *offset += 2;
    Ok(value)
}

fn endpoint_uri(endpoint: &PrinterEndpoint) -> String {
    let host = match endpoint.host() {
        IpAddr::V4(address) => address.to_string(),
        IpAddr::V6(address) => format!("[{address}]"),
    };
    format!(
        "ipp://{host}:{}/printers/{}",
        endpoint.port(),
        encode_path_segment(endpoint.queue())
    )
}

fn encode_path_segment(value: &str) -> String {
    let mut encoded = String::new();
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
            encoded.push(char::from(byte));
        } else {
            use std::fmt::Write as _;
            let _ = write!(encoded, "%{byte:02X}");
        }
    }
    encoded
}

fn ipp_error(endpoint: &PrinterEndpoint, detail: &str) -> BridgeError {
    BridgeError::IppNegotiationFailed {
        endpoint: format!("{}:{}", endpoint.host(), endpoint.port()),
        action: format!("Verify the loopback NAT forward and CUPS queue: {detail}."),
    }
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;
    use std::time::Duration;

    use printbridge_domain::{ComponentState, GuestPrinting, JobState, PrinterEndpoint};

    use super::{CupsIppProvider, IppRequest};

    fn endpoint(port: u16) -> PrinterEndpoint {
        PrinterEndpoint::Loopback {
            port,
            queue: "PrintBridge_DCP_L2600D".into(),
        }
    }

    fn ipp_response(attributes: &[(u8, &str, Vec<u8>)]) -> Vec<u8> {
        let mut body = vec![0x02, 0x00, 0x00, 0x00, 0, 0, 0, 1, 0x04];
        for (tag, name, value) in attributes {
            body.push(*tag);
            body.extend_from_slice(&(name.len() as u16).to_be_bytes());
            body.extend_from_slice(name.as_bytes());
            body.extend_from_slice(&(value.len() as u16).to_be_bytes());
            body.extend_from_slice(value);
        }
        body.push(0x03);
        body
    }

    fn serve_once(body: Vec<u8>) -> (u16, thread::JoinHandle<Vec<u8>>) {
        serve_once_with_delay(body, Duration::ZERO)
    }

    fn serve_once_with_delay(
        body: Vec<u8>,
        close_delay: Duration,
    ) -> (u16, thread::JoinHandle<Vec<u8>>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind fixture");
        let port = listener.local_addr().expect("fixture address").port();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept fixture");
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .expect("fixture read timeout");
            let mut request = Vec::new();
            let mut buffer = [0_u8; 4096];
            loop {
                let count = stream.read(&mut buffer).expect("read fixture request");
                if count == 0 {
                    break;
                }
                request.extend_from_slice(&buffer[..count]);
                if let Some(separator) = request.windows(4).position(|part| part == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&request[..separator]);
                    let length = headers
                        .lines()
                        .find_map(|line| {
                            line.strip_prefix("Content-Length: ")
                                .and_then(|value| value.parse::<usize>().ok())
                        })
                        .expect("content length");
                    if request.len() >= separator + 4 + length {
                        break;
                    }
                }
            }
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/ipp\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            stream
                .write_all(response.as_bytes())
                .expect("fixture header");
            stream.write_all(&body).expect("fixture body");
            thread::sleep(close_delay);
            request
        });
        (port, handle)
    }

    fn serve_chunked_once(body: Vec<u8>) -> (u16, thread::JoinHandle<Vec<u8>>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind fixture");
        let port = listener.local_addr().expect("fixture address").port();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept fixture");
            let mut request = vec![0_u8; 4096];
            let count = stream.read(&mut request).expect("read fixture request");
            request.truncate(count);
            let split = body.len() / 2;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/ipp\r\nTransfer-Encoding: chunked\r\nConnection: Keep-Alive\r\n\r\n{:X}\r\n",
                split
            );
            stream
                .write_all(response.as_bytes())
                .expect("fixture header");
            stream.write_all(&body[..split]).expect("first chunk");
            let second = format!("\r\n{:X}\r\n", body.len() - split);
            stream.write_all(second.as_bytes()).expect("second size");
            stream.write_all(&body[split..]).expect("second chunk");
            stream.write_all(b"\r\n0\r\n\r\n").expect("final chunk");
            thread::sleep(Duration::from_millis(500));
            request
        });
        (port, handle)
    }

    fn printer_attributes() -> Vec<u8> {
        ipp_response(&[
            (0x42, "printer-name", b"PrintBridge_DCP_L2600D".to_vec()),
            (
                0x41,
                "printer-make-and-model",
                b"Brother DCP-L2600D".to_vec(),
            ),
            (0x23, "printer-state", 3_i32.to_be_bytes().to_vec()),
            (0x22, "printer-is-accepting-jobs", vec![1]),
            (0x44, "printer-state-reasons", b"none".to_vec()),
        ])
    }

    #[test]
    fn probe_and_queue_status_use_real_ipp_requests() {
        let (port, handle) = serve_once(printer_attributes());
        let endpoint = endpoint(port);
        let provider = CupsIppProvider::new(endpoint.clone(), Duration::from_secs(2));
        let status = provider
            .queue_status("PrintBridge_DCP_L2600D")
            .expect("healthy fixture");
        assert_eq!(status.state, ComponentState::Ready);
        let request = handle.join().expect("fixture thread");
        let separator = request
            .windows(4)
            .position(|part| part == b"\r\n\r\n")
            .expect("HTTP request separator");
        assert_eq!(
            &request[separator + 6..separator + 8],
            &0x000b_u16.to_be_bytes()
        );
        let request_text = String::from_utf8_lossy(&request);
        assert!(request_text.contains("/printers/PrintBridge_DCP_L2600D"));
        assert_eq!(request_text.matches("requested-attributes").count(), 1);
    }

    #[test]
    fn listing_reports_advertised_name_and_driver() {
        let (port, handle) = serve_once(printer_attributes());
        let provider = CupsIppProvider::new(endpoint(port), Duration::from_secs(2));
        let queues = provider.list_queues().expect("queue listing");
        assert_eq!(queues[0].name, "PrintBridge_DCP_L2600D");
        assert_eq!(queues[0].driver, "Brother DCP-L2600D");
        handle.join().expect("fixture thread");
    }

    #[test]
    fn submitted_job_is_never_reported_as_physical_output() {
        let body = ipp_response(&[(0x21, "job-id", 42_i32.to_be_bytes().to_vec())]);
        let (port, handle) = serve_once(body);
        let mut provider = CupsIppProvider::new(endpoint(port), Duration::from_secs(2));
        let job = provider
            .submit_test_page("PrintBridge_DCP_L2600D")
            .expect("submit fixture");
        assert_eq!(job.id.0, 42);
        assert_eq!(job.state, JobState::Accepted);
        assert!(job.physical_confirmation_source.is_none());
        let request = handle.join().expect("fixture thread");
        let separator = request
            .windows(4)
            .position(|part| part == b"\r\n\r\n")
            .expect("HTTP request separator");
        assert_eq!(
            &request[separator + 6..separator + 8],
            &0x0002_u16.to_be_bytes()
        );
        assert!(
            String::from_utf8_lossy(&request)
                .contains("Physical output requires owner confirmation")
        );
    }

    #[test]
    fn unsafe_queue_characters_are_percent_encoded() {
        let mut request = IppRequest::new(0x000b, 1);
        request.operation_defaults("ipp://127.0.0.1/printers/safe");
        assert!(!request.finish(&[]).is_empty());
        assert_eq!(super::encode_path_segment("queue/name"), "queue%2Fname");
    }

    #[test]
    fn unreachable_endpoint_is_actionable_ipp_error() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("reserve port");
        let port = listener.local_addr().expect("reserved address").port();
        drop(listener);
        let provider = CupsIppProvider::new(endpoint(port), Duration::from_millis(100));
        let error = provider
            .probe_ipp(&endpoint(port))
            .expect_err("closed port must fail");
        assert_eq!(error.kind().as_str(), "ipp_negotiation_failed");
        assert!(error.to_string().contains("loopback NAT forward"));
    }

    #[test]
    fn content_length_completes_without_waiting_for_server_close() {
        let (port, handle) =
            serve_once_with_delay(printer_attributes(), Duration::from_millis(500));
        let endpoint = endpoint(port);
        let provider = CupsIppProvider::new(endpoint.clone(), Duration::from_millis(100));
        provider
            .probe_ipp(&endpoint)
            .expect("declared response body is complete");
        handle.join().expect("fixture thread");
    }

    #[test]
    fn chunked_body_completes_without_waiting_for_server_close() {
        let (port, handle) = serve_chunked_once(printer_attributes());
        let endpoint = endpoint(port);
        let provider = CupsIppProvider::new(endpoint.clone(), Duration::from_millis(100));
        provider
            .probe_ipp(&endpoint)
            .expect("complete chunked response is decoded");
        handle.join().expect("fixture thread");
    }
}
