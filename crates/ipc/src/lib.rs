//! Versioned agent protocol shared by every non-UI client.

use printbridge_domain::{
    BridgeStatus, ComponentStatus, DoctorReport, UsbDevice, WindowsPrintSubmission,
    WindowsQueueStatus,
};

mod wire;

#[cfg(windows)]
pub mod windows_pipe;

pub use wire::{
    AgentComponents, AgentEvent, AgentStatus, Command, CommandResult, DeviceSummary, Diagnostics,
    ErrorPayload, LanStatus, MAX_FRAME_BYTES, OperationResult, Payload, RequestEnvelope,
    ResponseEnvelope, ScannerStatus, StartupStatus, TestPrintResult, WireComponent,
    WireComponentState, WireError, read_request, read_response, write_request, write_response,
};

pub const PROTOCOL_VERSION: u16 = 7;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    GetStatus,
    Doctor,
    VmStatus,
    VmStart,
    VmStop,
    UsbList,
    UsbAttach,
    UsbAttachAt(usize),
    UsbRelease,
    UsbReleaseAt(usize),
    PrinterInstall,
    PrinterStatus,
    PrinterTestPage,
    PrinterRemove,
    Help,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Response {
    Status(BridgeStatus),
    Doctor(DoctorReport),
    VmStatus(ComponentStatus),
    UsbDevices(Vec<UsbDevice>),
    PrinterStatus(WindowsQueueStatus),
    PrinterTestPage(WindowsPrintSubmission),
    OperationComplete { operation: &'static str },
    Help(String),
    Error { code: String, message: String },
}

pub trait RequestHandler {
    fn handle(&mut self, version: u16, request: Request) -> Response;
}

pub trait Client {
    fn send(&mut self, request: Request) -> Response;
}

pub struct InProcessClient<H> {
    handler: H,
    version: u16,
}

impl<H> InProcessClient<H> {
    #[must_use]
    pub const fn new(handler: H) -> Self {
        Self {
            handler,
            version: PROTOCOL_VERSION,
        }
    }

    #[must_use]
    pub const fn with_version(handler: H, version: u16) -> Self {
        Self { handler, version }
    }

    pub fn into_handler(self) -> H {
        self.handler
    }
}

impl<H: RequestHandler> Client for InProcessClient<H> {
    fn send(&mut self, request: Request) -> Response {
        self.handler.handle(self.version, request)
    }
}

#[cfg(test)]
mod tests {
    use super::{Client, InProcessClient, PROTOCOL_VERSION, Request, RequestHandler, Response};

    struct EchoVersion;

    impl RequestHandler for EchoVersion {
        fn handle(&mut self, version: u16, _request: Request) -> Response {
            Response::Help(version.to_string())
        }
    }

    #[test]
    fn in_process_client_uses_current_version() {
        let mut client = InProcessClient::new(EchoVersion);
        assert_eq!(
            client.send(Request::Help),
            Response::Help(PROTOCOL_VERSION.to_string())
        );
    }
}
