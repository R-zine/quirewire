//! Bounded eSCL/AirScan capability probe for the guest scanner service.

use std::collections::BTreeSet;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

use quick_xml::Reader;
use quick_xml::events::Event;
use quirewire_domain::{BridgeError, GuestScanning, ScannerCapabilities, ScannerEndpoint};

const CAPABILITIES_PATH: &str = "/eSCL/ScannerCapabilities";
const MAX_RESPONSE_BYTES: usize = 512 * 1024;
const TIMEOUT: Duration = Duration::from_secs(5);

pub struct EsclProvider;

impl EsclProvider {
    #[must_use]
    pub const fn new() -> Self {
        Self
    }
}

impl Default for EsclProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl GuestScanning for EsclProvider {
    fn probe_escl(&self, endpoint: &ScannerEndpoint) -> Result<ScannerCapabilities, BridgeError> {
        if endpoint.port == 0 || !endpoint.address.is_loopback() {
            return Err(scan_error(
                endpoint,
                "the agent probe is restricted to the owned loopback eSCL forward",
            ));
        }
        let socket = SocketAddr::new(endpoint.address, endpoint.port);
        let mut stream = TcpStream::connect_timeout(&socket, TIMEOUT)
            .map_err(|error| scan_error(endpoint, &format!("cannot connect: {error}")))?;
        stream
            .set_read_timeout(Some(TIMEOUT))
            .map_err(|error| scan_error(endpoint, &format!("cannot set read timeout: {error}")))?;
        stream
            .set_write_timeout(Some(TIMEOUT))
            .map_err(|error| scan_error(endpoint, &format!("cannot set write timeout: {error}")))?;

        let host = endpoint.address.to_string();
        let request = format!(
            "GET {CAPABILITIES_PATH} HTTP/1.1\r\nHost: {host}:{}\r\nAccept: text/xml, application/xml\r\nConnection: close\r\n\r\n",
            endpoint.port
        );
        stream
            .write_all(request.as_bytes())
            .map_err(|error| scan_error(endpoint, &format!("request failed: {error}")))?;

        let mut response = Vec::new();
        let mut chunk = [0_u8; 8192];
        loop {
            let read = stream
                .read(&mut chunk)
                .map_err(|error| scan_error(endpoint, &format!("response failed: {error}")))?;
            if read == 0 {
                break;
            }
            if response.len() + read > MAX_RESPONSE_BYTES {
                return Err(scan_error(
                    endpoint,
                    "response exceeded the 512 KiB capability limit",
                ));
            }
            response.extend_from_slice(&chunk[..read]);
        }
        let body = parse_http(endpoint, &response)?;
        parse_capabilities(endpoint, &body)
    }
}

fn parse_http(endpoint: &ScannerEndpoint, response: &[u8]) -> Result<Vec<u8>, BridgeError> {
    let separator = response
        .windows(4)
        .position(|part| part == b"\r\n\r\n")
        .ok_or_else(|| scan_error(endpoint, "HTTP response omitted its header terminator"))?;
    let headers = std::str::from_utf8(&response[..separator])
        .map_err(|_| scan_error(endpoint, "HTTP response headers were not UTF-8"))?;
    let status = headers.lines().next().unwrap_or_default();
    if !status.starts_with("HTTP/1.1 200 ") && !status.starts_with("HTTP/1.0 200 ") {
        return Err(scan_error(endpoint, "eSCL returned a non-200 HTTP status"));
    }
    if !headers.lines().any(|line| {
        line.split_once(':').is_some_and(|(name, value)| {
            name.eq_ignore_ascii_case("content-type") && value.to_ascii_lowercase().contains("xml")
        })
    }) {
        return Err(scan_error(endpoint, "eSCL response was not XML"));
    }
    let encoded = &response[separator + 4..];
    if header_has_token(headers, "transfer-encoding", "chunked") {
        decode_chunked(endpoint, encoded)
    } else {
        if let Some(length) = content_length(endpoint, headers)? {
            if length != encoded.len() {
                return Err(scan_error(endpoint, "HTTP response body was truncated"));
            }
        }
        Ok(encoded.to_vec())
    }
}

fn content_length(endpoint: &ScannerEndpoint, headers: &str) -> Result<Option<usize>, BridgeError> {
    headers
        .lines()
        .find_map(|line| {
            let (name, value) = line.split_once(':')?;
            name.eq_ignore_ascii_case("content-length")
                .then_some(value.trim())
        })
        .map(|value| {
            value
                .parse::<usize>()
                .map_err(|_| scan_error(endpoint, "HTTP Content-Length was invalid"))
                .and_then(|length| {
                    (length <= MAX_RESPONSE_BYTES)
                        .then_some(length)
                        .ok_or_else(|| scan_error(endpoint, "declared response was too large"))
                })
        })
        .transpose()
}

fn header_has_token(headers: &str, expected_name: &str, expected_token: &str) -> bool {
    headers.lines().any(|line| {
        line.split_once(':').is_some_and(|(name, value)| {
            name.eq_ignore_ascii_case(expected_name)
                && value
                    .split(',')
                    .any(|token| token.trim().eq_ignore_ascii_case(expected_token))
        })
    })
}

fn decode_chunked(endpoint: &ScannerEndpoint, body: &[u8]) -> Result<Vec<u8>, BridgeError> {
    let mut decoded = Vec::new();
    let mut offset = 0;
    loop {
        let line_end = body
            .get(offset..)
            .and_then(|tail| tail.windows(2).position(|part| part == b"\r\n"))
            .ok_or_else(|| scan_error(endpoint, "chunked response was incomplete"))?;
        let size_line = std::str::from_utf8(&body[offset..offset + line_end])
            .map_err(|_| scan_error(endpoint, "chunk size was not ASCII"))?;
        let size =
            usize::from_str_radix(size_line.split(';').next().unwrap_or_default().trim(), 16)
                .map_err(|_| scan_error(endpoint, "chunk size was invalid"))?;
        offset += line_end + 2;
        if size == 0 {
            return Ok(decoded);
        }
        let end = offset
            .checked_add(size)
            .ok_or_else(|| scan_error(endpoint, "chunk length overflowed"))?;
        let chunk = body
            .get(offset..end)
            .ok_or_else(|| scan_error(endpoint, "chunked response was truncated"))?;
        decoded.extend_from_slice(chunk);
        if decoded.len() > MAX_RESPONSE_BYTES {
            return Err(scan_error(endpoint, "decoded response was too large"));
        }
        if body.get(end..end + 2) != Some(b"\r\n") {
            return Err(scan_error(endpoint, "chunk omitted its terminator"));
        }
        offset = end + 2;
    }
}

fn parse_capabilities(
    endpoint: &ScannerEndpoint,
    body: &[u8],
) -> Result<ScannerCapabilities, BridgeError> {
    let mut reader = Reader::from_reader(body);
    reader.config_mut().trim_text(true);
    let mut current = String::new();
    let mut make_model = String::new();
    let mut uuid = None;
    let mut sources = BTreeSet::new();
    let mut duplex = false;
    let mut color_modes = BTreeSet::new();
    let mut formats = BTreeSet::new();
    let mut resolutions = BTreeSet::new();

    loop {
        match reader.read_event() {
            Ok(Event::Start(element)) => {
                current = String::from_utf8_lossy(element.local_name().as_ref()).into_owned();
                match current.as_str() {
                    "Platen" | "PlatenInputCaps" => {
                        sources.insert("platen".to_string());
                    }
                    "Adf" | "AdfSimplexInputCaps" | "AdfDuplexInputCaps" => {
                        sources.insert("adf".to_string());
                        duplex |= current == "AdfDuplexInputCaps";
                    }
                    _ => {}
                }
            }
            Ok(Event::Text(text)) => {
                let value = text
                    .decode()
                    .map_err(|_| scan_error(endpoint, "capability XML text was invalid"))?
                    .trim()
                    .to_string();
                if value.is_empty() {
                    continue;
                }
                match current.as_str() {
                    "MakeAndModel" => make_model = value,
                    "UUID" => uuid = Some(value),
                    "ColorMode" => {
                        color_modes.insert(value);
                    }
                    "DocumentFormat" | "DocumentFormatExt" => {
                        formats.insert(value);
                    }
                    "XResolution" => {
                        if let Ok(value) = value.parse::<u32>() {
                            if (50..=2400).contains(&value) {
                                resolutions.insert(value);
                            }
                        }
                    }
                    _ => {}
                }
            }
            Ok(Event::DocType(_) | Event::GeneralRef(_)) => {
                return Err(scan_error(
                    endpoint,
                    "capability XML contained a forbidden declaration or entity",
                ));
            }
            Ok(Event::Eof) => break,
            Ok(_) => {}
            Err(error) => {
                return Err(scan_error(
                    endpoint,
                    &format!("capability XML was invalid: {error}"),
                ));
            }
        }
    }
    if make_model.is_empty() || sources.is_empty() || formats.is_empty() {
        return Err(scan_error(
            endpoint,
            "capabilities omitted the scanner model, source, or document formats",
        ));
    }
    Ok(ScannerCapabilities {
        make_model,
        uuid,
        sources: sources.into_iter().collect(),
        duplex,
        color_modes: color_modes.into_iter().collect(),
        document_formats: formats.into_iter().collect(),
        resolutions_dpi: resolutions.into_iter().collect(),
    })
}

fn scan_error(endpoint: &ScannerEndpoint, detail: &str) -> BridgeError {
    BridgeError::GuestUnhealthy {
        detail: format!("eSCL {}:{}: {detail}", endpoint.address, endpoint.port),
        action: "Connect and power on the selected scanner, then run Repair.".into(),
    }
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;

    use quirewire_domain::{GuestScanning, ScannerEndpoint};

    use super::EsclProvider;

    const XML: &str = r#"<?xml version="1.0"?>
<scan:ScannerCapabilities xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
  <pwg:MakeAndModel>Brother DCP-L2600D</pwg:MakeAndModel>
  <pwg:UUID>urn:uuid:test-scanner</pwg:UUID>
  <scan:Platen><scan:PlatenInputCaps>
    <scan:ColorModes><scan:ColorMode>RGB24</scan:ColorMode><scan:ColorMode>Grayscale8</scan:ColorMode></scan:ColorModes>
    <scan:DocumentFormats><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat><scan:DocumentFormatExt>application/pdf</scan:DocumentFormatExt></scan:DocumentFormats>
    <scan:SettingProfiles><scan:SettingProfile><scan:SupportedResolutions><scan:DiscreteResolutions><scan:DiscreteResolution><scan:XResolution>300</scan:XResolution><scan:YResolution>300</scan:YResolution></scan:DiscreteResolution></scan:DiscreteResolutions></scan:SupportedResolutions></scan:SettingProfile></scan:SettingProfiles>
  </scan:PlatenInputCaps></scan:Platen>
</scan:ScannerCapabilities>"#;

    fn serve(body: &'static str, content_type: &'static str) -> (u16, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().expect("address").port();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut request = [0_u8; 1024];
            let read = stream.read(&mut request).expect("read");
            assert!(
                String::from_utf8_lossy(&request[..read])
                    .starts_with("GET /eSCL/ScannerCapabilities HTTP/1.1")
            );
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .expect("write");
        });
        (port, handle)
    }

    #[test]
    fn probe_reports_only_live_escl_capabilities() {
        let (port, handle) = serve(XML, "text/xml; charset=utf-8");
        let capabilities = EsclProvider::new()
            .probe_escl(&ScannerEndpoint::loopback(port))
            .expect("capabilities");
        handle.join().expect("server");
        assert_eq!(capabilities.make_model, "Brother DCP-L2600D");
        assert_eq!(capabilities.sources, ["platen"]);
        assert!(!capabilities.duplex);
        assert_eq!(capabilities.color_modes, ["Grayscale8", "RGB24"]);
        assert_eq!(
            capabilities.document_formats,
            ["application/pdf", "image/jpeg"]
        );
        assert_eq!(capabilities.resolutions_dpi, [300]);
    }

    #[test]
    fn unsafe_or_incomplete_responses_fail_closed() {
        let malicious = "<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///secret'>]><ScannerCapabilities><MakeAndModel>&e;</MakeAndModel></ScannerCapabilities>";
        for body in [
            malicious,
            "<ScannerCapabilities><MakeAndModel>Brother</MakeAndModel></ScannerCapabilities>",
        ] {
            let (port, handle) = serve(body, "application/xml");
            assert!(
                EsclProvider::new()
                    .probe_escl(&ScannerEndpoint::loopback(port))
                    .is_err()
            );
            handle.join().expect("server");
        }
    }

    #[test]
    fn non_loopback_probe_is_refused() {
        let endpoint = ScannerEndpoint {
            address: "192.168.1.10".parse().expect("address"),
            port: 8645,
        };
        assert!(EsclProvider::new().probe_escl(&endpoint).is_err());
    }
}
