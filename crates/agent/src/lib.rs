//! Framework-free agent request handler.
//!
//! M2 hosts this handler in process for deterministic CLI tests. The standalone
//! background executable and named-pipe transport are intentionally deferred to
//! M6.

mod m3;
mod m5;
pub mod m6;

pub use m3::{M3_CONFIG_SCHEMA, M3AgentService, M3Config, m3_help_text};
pub use m5::{M5_CONFIG_SCHEMA, M5AgentService, M5Config, m5_help_text};

use quirewire_core::{Controller, fake::FakePlatform};
use quirewire_domain::Platform;
use quirewire_ipc::{PROTOCOL_VERSION, Request, RequestHandler, Response};

pub struct AgentService<P> {
    controller: Controller<P>,
}

impl<P: Platform> AgentService<P> {
    #[must_use]
    pub const fn new(controller: Controller<P>) -> Self {
        Self { controller }
    }

    pub fn controller(&self) -> &Controller<P> {
        &self.controller
    }
}

impl AgentService<FakePlatform> {
    #[must_use]
    pub fn fake_ready() -> Self {
        let provider = FakePlatform::ready();
        let (vm, usb, endpoint) = provider.selection();
        Self::new(Controller::new(provider, vm, usb, endpoint))
    }
}

impl<P: Platform> RequestHandler for AgentService<P> {
    fn handle(&mut self, version: u16, request: Request) -> Response {
        if version != PROTOCOL_VERSION {
            return Response::Error {
                code: "unsupported_protocol".into(),
                message: format!("Protocol {version} is unsupported; expected {PROTOCOL_VERSION}."),
            };
        }
        match request {
            Request::GetStatus => Response::Status(self.controller.status()),
            Request::Doctor => Response::Doctor(self.controller.doctor()),
            Request::Help => Response::Help(help_text().into()),
            Request::VmStatus
            | Request::VmStart
            | Request::VmStop
            | Request::UsbList
            | Request::UsbAttach
            | Request::UsbAttachAt(_)
            | Request::UsbRelease
            | Request::UsbReleaseAt(_)
            | Request::PrinterInstall
            | Request::PrinterStatus
            | Request::PrinterTestPage
            | Request::PrinterRemove => Response::Error {
                code: "unsupported_command".into(),
                message: "The M2 fake handler does not implement M3 hardware commands.".into(),
            },
        }
    }
}

#[must_use]
pub const fn help_text() -> &'static str {
    "QuireWire M2 CLI (fake in-memory provider)\n\
Usage: quirewirectl [--trace] <command>\n\n\
Commands:\n\
  status    Show typed component and overall state\n\
  doctor    Run hardware-free provider contract checks\n\
  help      Show this help\n\n\
M2 never invokes VirtualBox, CUPS, Windows printing APIs, or physical hardware."
}

#[cfg(test)]
mod tests {
    use quirewire_ipc::{PROTOCOL_VERSION, Request, RequestHandler, Response};

    use super::AgentService;

    #[test]
    fn rejects_unknown_protocol_version() {
        let mut agent = AgentService::fake_ready();
        let response = agent.handle(PROTOCOL_VERSION + 1, Request::GetStatus);
        assert!(
            matches!(response, Response::Error { ref code, .. } if code == "unsupported_protocol")
        );
    }

    #[test]
    fn fake_agent_serves_status_doctor_and_help() {
        let mut agent = AgentService::fake_ready();
        assert!(matches!(
            agent.handle(PROTOCOL_VERSION, Request::GetStatus),
            Response::Status(_)
        ));
        assert!(matches!(
            agent.handle(PROTOCOL_VERSION, Request::Doctor),
            Response::Doctor(_)
        ));
        assert!(matches!(
            agent.handle(PROTOCOL_VERSION, Request::Help),
            Response::Help(_)
        ));
    }
}
