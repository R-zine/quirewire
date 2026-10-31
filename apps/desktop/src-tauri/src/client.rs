use std::sync::Arc;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use printbridge_ipc::{
    AgentStatus, Command, CommandResult, DeviceSummary, Diagnostics, ErrorPayload, OperationResult,
    Payload, RequestEnvelope, TestPrintResult, WireError,
};
use serde::Serialize;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(75);

#[derive(Debug, Clone, Serialize)]
pub struct DesktopError {
    pub code: String,
    pub message: String,
    pub action: Option<String>,
    pub retryable: bool,
}

impl DesktopError {
    fn protocol(message: impl Into<String>) -> Self {
        Self {
            code: "desktop_protocol_error".into(),
            message: message.into(),
            action: Some(
                "Update PrintBridge so the desktop and agent use the same protocol.".into(),
            ),
            retryable: false,
        }
    }

    fn unavailable(message: impl Into<String>) -> Self {
        Self {
            code: "agent_unavailable".into(),
            message: message.into(),
            action: Some(
                "Keep PrintBridge open while its on-demand engine starts, then try again.".into(),
            ),
            retryable: true,
        }
    }

    pub(crate) fn runtime(message: impl Into<String>) -> Self {
        Self {
            code: "desktop_runtime_error".into(),
            message: message.into(),
            action: Some(
                "Repair PrintBridge and verify the installed agent and configuration.".into(),
            ),
            retryable: true,
        }
    }
}

impl From<ErrorPayload> for DesktopError {
    fn from(value: ErrorPayload) -> Self {
        Self {
            code: value.code,
            message: value.message,
            action: value.action,
            retryable: value.retryable,
        }
    }
}

impl From<WireError> for DesktopError {
    fn from(value: WireError) -> Self {
        match value {
            WireError::Io(error) => {
                Self::unavailable(format!("Cannot reach the PrintBridge agent: {error}"))
            }
            other => Self::protocol(other.to_string()),
        }
    }
}

#[derive(Clone, Default)]
pub struct AgentClient {
    sequence: Arc<AtomicU64>,
    #[cfg(windows)]
    owner_sid: Arc<OnceLock<String>>,
}

impl AgentClient {
    pub async fn status(&self) -> Result<AgentStatus, DesktopError> {
        match self.request(Command::GetStatus).await? {
            Payload::Status(value) => Ok(value),
            payload => Err(unexpected_payload("status", &payload)),
        }
    }

    pub async fn devices(&self) -> Result<Vec<DeviceSummary>, DesktopError> {
        match self.request(Command::DiscoverDevices).await? {
            Payload::Devices(value) => Ok(value),
            payload => Err(unexpected_payload("devices", &payload)),
        }
    }

    pub async fn operation(&self, command: Command) -> Result<OperationResult, DesktopError> {
        match self.request(command).await? {
            Payload::Operation(value) => Ok(value),
            payload => Err(unexpected_payload("operation", &payload)),
        }
    }

    pub async fn test_print(&self) -> Result<TestPrintResult, DesktopError> {
        match self.request(Command::TestPrint).await? {
            Payload::TestPrint(value) => Ok(value),
            payload => Err(unexpected_payload("test_print", &payload)),
        }
    }

    pub async fn diagnostics(&self) -> Result<Diagnostics, DesktopError> {
        match self.request(Command::GetDiagnostics).await? {
            Payload::Diagnostics(value) => Ok(value),
            payload => Err(unexpected_payload("diagnostics", &payload)),
        }
    }

    pub async fn request(&self, command: Command) -> Result<Payload, DesktopError> {
        let request_id = self.next_request_id();
        let request = RequestEnvelope::new(&request_id, command);

        #[cfg(windows)]
        let response = {
            let sid = if let Some(value) = self.owner_sid.get() {
                value
            } else {
                let value = printbridge_ipc::windows_pipe::current_user_sid().map_err(|error| {
                    DesktopError::unavailable(format!(
                        "Cannot identify the current Windows user: {error}"
                    ))
                })?;
                let _ = self.owner_sid.set(value);
                self.owner_sid.get().ok_or_else(|| {
                    DesktopError::unavailable("Cannot cache the Windows owner SID.")
                })?
            };
            let pipe_name = printbridge_ipc::windows_pipe::pipe_name_for_sid(sid);
            printbridge_ipc::windows_pipe::send(&pipe_name, &request, REQUEST_TIMEOUT).await?
        };

        #[cfg(not(windows))]
        return Err(DesktopError::unavailable(
            "The PrintBridge desktop is supported only on Windows.",
        ));

        #[cfg(windows)]
        {
            if response.request_id != request_id {
                return Err(DesktopError::protocol(
                    "The agent response did not match the desktop request.",
                ));
            }
            match response.result {
                CommandResult::Ok { payload } => Ok(*payload),
                CommandResult::Error { error } => Err(error.into()),
            }
        }
    }

    fn next_request_id(&self) -> String {
        let milliseconds = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        let sequence = self.sequence.fetch_add(1, Ordering::Relaxed);
        format!("desktop-{}-{milliseconds}-{sequence}", std::process::id())
    }
}

fn unexpected_payload(expected: &str, payload: &Payload) -> DesktopError {
    DesktopError::protocol(format!(
        "Agent returned {} when the desktop expected {expected}.",
        payload_name(payload)
    ))
}

fn payload_name(payload: &Payload) -> &'static str {
    match payload {
        Payload::Status(_) => "status",
        Payload::Devices(_) => "devices",
        Payload::Operation(_) => "operation",
        Payload::TestPrint(_) => "test_print",
        Payload::Diagnostics(_) => "diagnostics",
    }
}

#[cfg(test)]
mod tests {
    use printbridge_ipc::ErrorPayload;

    use super::{AgentClient, DesktopError};

    #[test]
    fn request_ids_are_unique_and_wire_safe() {
        let client = AgentClient::default();
        let first = client.next_request_id();
        let second = client.next_request_id();
        assert_ne!(first, second);
        assert!(
            first
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        );
        assert!(first.len() <= 128);
    }

    #[test]
    fn agent_errors_keep_actionability() {
        let error = DesktopError::from(ErrorPayload {
            code: "usb_busy".into(),
            message: "USB device is busy".into(),
            action: Some("Close the application using the printer.".into()),
            retryable: true,
        });
        assert_eq!(error.code, "usb_busy");
        assert_eq!(
            error.action.as_deref(),
            Some("Close the application using the printer.")
        );
        assert!(error.retryable);
    }
}
