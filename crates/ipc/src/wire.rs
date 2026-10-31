use std::io;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::PROTOCOL_VERSION;

pub const MAX_FRAME_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RequestEnvelope {
    pub version: u16,
    pub request_id: String,
    pub command: Command,
}

impl RequestEnvelope {
    #[must_use]
    pub fn new(request_id: impl Into<String>, command: Command) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            request_id: request_id.into(),
            command,
        }
    }

    pub fn validate(&self) -> Result<(), WireError> {
        if self.version != PROTOCOL_VERSION {
            return Err(WireError::UnsupportedVersion(self.version));
        }
        if self.request_id.is_empty()
            || self.request_id.len() > 128
            || !self
                .request_id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
        {
            return Err(WireError::InvalidRequest(
                "request_id must be 1-128 ASCII letters, digits, '-' or '_'".into(),
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "name", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    GetStatus,
    DiscoverDevices,
    BeginSetup { device_index: usize },
    Start,
    Stop,
    Restart,
    TestPrint,
    GetDiagnostics,
    Repair,
    Heartbeat,
    Shutdown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResponseEnvelope {
    pub version: u16,
    pub request_id: String,
    #[serde(flatten)]
    pub result: CommandResult,
}

impl ResponseEnvelope {
    #[must_use]
    pub fn ok(request_id: impl Into<String>, payload: Payload) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            request_id: request_id.into(),
            result: CommandResult::Ok {
                payload: Box::new(payload),
            },
        }
    }

    #[must_use]
    pub fn error(request_id: impl Into<String>, error: ErrorPayload) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            request_id: request_id.into(),
            result: CommandResult::Error { error },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "outcome", rename_all = "snake_case", deny_unknown_fields)]
pub enum CommandResult {
    Ok { payload: Box<Payload> },
    Error { error: ErrorPayload },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", content = "value", rename_all = "snake_case")]
pub enum Payload {
    Status(AgentStatus),
    Devices(Vec<DeviceSummary>),
    Operation(OperationResult),
    TestPrint(TestPrintResult),
    Diagnostics(Diagnostics),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ErrorPayload {
    pub code: String,
    pub message: String,
    pub action: Option<String>,
    pub retryable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentStatus {
    pub desired: String,
    pub overall: String,
    pub revision: u64,
    pub retry_after_ms: Option<u64>,
    pub components: AgentComponents,
    pub startup: StartupStatus,
    pub lan: LanStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentComponents {
    pub hypervisor: WireComponent,
    pub guest: WireComponent,
    pub usb: WireComponent,
    pub cups: WireComponent,
    pub windows_queue: WireComponent,
    pub lan: WireComponent,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WireComponent {
    pub state: WireComponentState,
    pub detail: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WireComponentState {
    NotConfigured,
    Stopped,
    Starting,
    Waiting,
    Connecting,
    Ready,
    Degraded,
    Error,
    Stopping,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StartupStatus {
    pub registered: bool,
    pub task_name: String,
    pub logoff_behavior: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LanStatus {
    pub enabled: bool,
    pub interface_alias: Option<String>,
    pub network_category: Option<String>,
    pub address: Option<String>,
    pub endpoint: Option<String>,
    pub service_instance: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceSummary {
    pub index: usize,
    pub vendor_id: String,
    pub product_id: String,
    pub display_name: String,
    pub serial_present: bool,
    pub selected: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OperationResult {
    pub operation: String,
    pub accepted: bool,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TestPrintResult {
    pub correlation_id: String,
    pub spooler_job_id: Option<u32>,
    pub windows_spooler: String,
    pub cups_processing: String,
    pub physical_output: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Diagnostics {
    pub generated_at_unix_ms: u64,
    pub protocol_version: u16,
    pub owner_sid: String,
    pub pipe_name: String,
    pub process_id: u32,
    pub state_path: String,
    pub log_path: String,
    pub status: AgentStatus,
    pub recent_events: Vec<AgentEvent>,
    pub notes: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentEvent {
    pub sequence: u64,
    pub unix_ms: u64,
    pub level: String,
    pub event: String,
    pub detail: String,
}

#[derive(Debug)]
pub enum WireError {
    Io(io::Error),
    Json(serde_json::Error),
    FrameTooLarge,
    TruncatedFrame,
    UnsupportedVersion(u16),
    InvalidRequest(String),
}

impl std::fmt::Display for WireError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "IPC I/O failed: {error}"),
            Self::Json(error) => write!(formatter, "IPC JSON was invalid: {error}"),
            Self::FrameTooLarge => write!(formatter, "IPC frame exceeded {MAX_FRAME_BYTES} bytes"),
            Self::TruncatedFrame => formatter.write_str("IPC frame ended before newline"),
            Self::UnsupportedVersion(version) => write!(
                formatter,
                "IPC protocol {version} is unsupported; expected {PROTOCOL_VERSION}"
            ),
            Self::InvalidRequest(detail) => write!(formatter, "IPC request was invalid: {detail}"),
        }
    }
}

impl std::error::Error for WireError {}

impl From<io::Error> for WireError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

impl From<serde_json::Error> for WireError {
    fn from(value: serde_json::Error) -> Self {
        Self::Json(value)
    }
}

pub async fn read_request<R: AsyncBufRead + Unpin>(
    reader: &mut R,
) -> Result<RequestEnvelope, WireError> {
    let request: RequestEnvelope = read_json_frame(reader).await?;
    request.validate()?;
    Ok(request)
}

pub async fn write_request<W: AsyncWrite + Unpin>(
    writer: &mut W,
    request: &RequestEnvelope,
) -> Result<(), WireError> {
    request.validate()?;
    write_json_frame(writer, request).await
}

pub async fn read_response<R: AsyncBufRead + Unpin>(
    reader: &mut R,
) -> Result<ResponseEnvelope, WireError> {
    let response: ResponseEnvelope = read_json_frame(reader).await?;
    if response.version != PROTOCOL_VERSION {
        return Err(WireError::UnsupportedVersion(response.version));
    }
    Ok(response)
}

pub async fn write_response<W: AsyncWrite + Unpin>(
    writer: &mut W,
    response: &ResponseEnvelope,
) -> Result<(), WireError> {
    write_json_frame(writer, response).await
}

async fn read_json_frame<T: for<'de> Deserialize<'de>, R: AsyncBufRead + Unpin>(
    reader: &mut R,
) -> Result<T, WireError> {
    let mut bytes = Vec::new();
    let read = reader
        .take((MAX_FRAME_BYTES + 1) as u64)
        .read_until(b'\n', &mut bytes)
        .await?;
    if bytes.len() > MAX_FRAME_BYTES {
        return Err(WireError::FrameTooLarge);
    }
    if read == 0 || bytes.last() != Some(&b'\n') {
        return Err(WireError::TruncatedFrame);
    }
    bytes.pop();
    Ok(serde_json::from_slice(&bytes)?)
}

async fn write_json_frame<T: Serialize, W: AsyncWrite + Unpin>(
    writer: &mut W,
    value: &T,
) -> Result<(), WireError> {
    let bytes = serde_json::to_vec(value)?;
    if bytes.len() + 1 > MAX_FRAME_BYTES {
        return Err(WireError::FrameTooLarge);
    }
    writer.write_all(&bytes).await?;
    writer.write_all(b"\n").await?;
    writer.flush().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use tokio::io::{AsyncWriteExt, BufReader, duplex};

    use super::{
        Command, MAX_FRAME_BYTES, RequestEnvelope, WireError, read_request, write_request,
    };

    #[tokio::test]
    async fn request_round_trip_is_versioned_and_typed() {
        let (mut writer, reader) = duplex(1024);
        let request = RequestEnvelope::new("request-1", Command::BeginSetup { device_index: 2 });
        let task = tokio::spawn(async move { write_request(&mut writer, &request).await });
        let decoded = read_request(&mut BufReader::new(reader))
            .await
            .expect("request");
        task.await.expect("task").expect("write");
        assert_eq!(decoded.command, Command::BeginSetup { device_index: 2 });
    }

    #[tokio::test]
    async fn arbitrary_commands_and_unknown_fields_are_rejected() {
        for json in [
            "{\"version\":6,\"request_id\":\"r1\",\"command\":{\"name\":\"exec\",\"command\":\"whoami\"}}\n",
            "{\"version\":6,\"request_id\":\"r1\",\"extra\":true,\"command\":{\"name\":\"start\"}}\n",
        ] {
            let (mut writer, reader) = duplex(1024);
            writer.write_all(json.as_bytes()).await.expect("write");
            drop(writer);
            assert!(matches!(
                read_request(&mut BufReader::new(reader)).await,
                Err(WireError::Json(_))
            ));
        }
    }

    #[tokio::test]
    async fn oversized_frame_is_bounded() {
        let (mut writer, reader) = duplex(MAX_FRAME_BYTES * 2);
        writer
            .write_all(&vec![b'x'; MAX_FRAME_BYTES + 1])
            .await
            .expect("write");
        writer.write_all(b"\n").await.expect("newline");
        drop(writer);
        assert!(matches!(
            read_request(&mut BufReader::new(reader)).await,
            Err(WireError::FrameTooLarge)
        ));
    }
}
