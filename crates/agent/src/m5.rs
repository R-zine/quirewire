use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use quirewire_domain::{BridgeError, PrinterEndpoint, WindowsPrinting};
use quirewire_ipc::{PROTOCOL_VERSION, Request, RequestHandler, Response};
use quirewire_provider_windows::WindowsPrintProvider;

pub const M5_CONFIG_SCHEMA: &str = "quirewire.m5.config.v1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct M5Config {
    pub printer_name: String,
    pub endpoint: PrinterEndpoint,
}

impl M5Config {
    pub fn load(path: &Path) -> Result<Self, BridgeError> {
        let contents =
            fs::read_to_string(path).map_err(|error| BridgeError::MissingDependency {
                dependency: format!("M5 configuration at {}", path.display()),
                action: format!("Create a readable configuration file ({error})."),
            })?;
        Self::parse(&contents)
    }

    pub fn parse(contents: &str) -> Result<Self, BridgeError> {
        let mut values = BTreeMap::new();
        for (line_number, raw) in contents.lines().enumerate() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let (key, value) = line.split_once('=').ok_or_else(|| {
                config_error(format!("line {} must be key=value", line_number + 1))
            })?;
            let key = key.trim();
            let value = value.trim();
            if !matches!(
                key,
                "schema" | "printer_name" | "endpoint_port" | "guest_queue"
            ) {
                return Err(config_error(format!("unknown key '{key}'")));
            }
            if values.insert(key.to_string(), value.to_string()).is_some() {
                return Err(config_error(format!("duplicate key '{key}'")));
            }
        }
        let schema = required(&values, "schema")?;
        if schema != M5_CONFIG_SCHEMA {
            return Err(config_error(format!(
                "unsupported schema '{schema}'; expected '{M5_CONFIG_SCHEMA}'"
            )));
        }
        let printer_name = required(&values, "printer_name")?;
        if !valid_printer_name(printer_name) {
            return Err(config_error(
                "printer_name must be 'Brother via QuireWire' with at most one safe suffix",
            ));
        }
        let endpoint_port = required(&values, "endpoint_port")?
            .parse::<u16>()
            .map_err(|_| config_error("endpoint_port must be an integer from 1 to 65535"))?;
        if endpoint_port == 0 {
            return Err(config_error("endpoint_port must be non-zero"));
        }
        let guest_queue = required(&values, "guest_queue")?;
        if guest_queue.is_empty()
            || guest_queue.len() > 127
            || !guest_queue
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        {
            return Err(config_error(
                "guest_queue must contain only ASCII letters, digits, dot, underscore, or hyphen",
            ));
        }
        Ok(Self {
            printer_name: printer_name.into(),
            endpoint: PrinterEndpoint::Loopback {
                port: endpoint_port,
                queue: guest_queue.into(),
            },
        })
    }
}

pub struct M5AgentService<P> {
    provider: P,
    config: M5Config,
}

impl M5AgentService<WindowsPrintProvider> {
    pub fn discover(config: M5Config) -> Result<Self, BridgeError> {
        let provider =
            WindowsPrintProvider::discover(config.printer_name.clone(), config.endpoint.clone())?;
        Ok(Self::new(provider, config))
    }
}

impl<P: WindowsPrinting> M5AgentService<P> {
    #[must_use]
    pub const fn new(provider: P, config: M5Config) -> Self {
        Self { provider, config }
    }

    fn handle_current(&mut self, request: Request) -> Result<Response, BridgeError> {
        match request {
            Request::PrinterInstall => {
                self.provider.detect_ipp_support()?;
                self.provider
                    .register_owned_queue(&self.config.printer_name, &self.config.endpoint)?;
                self.provider.verify_driver(&self.config.printer_name)?;
                Ok(Response::PrinterStatus(
                    self.provider
                        .inspect_owned_queue(&self.config.printer_name)?,
                ))
            }
            Request::PrinterStatus => Ok(Response::PrinterStatus(
                self.provider
                    .inspect_owned_queue(&self.config.printer_name)?,
            )),
            Request::PrinterTestPage => {
                let submission = self
                    .provider
                    .submit_windows_test_page(&self.config.printer_name)?;
                Ok(Response::PrinterTestPage(submission))
            }
            Request::PrinterRemove => {
                self.provider
                    .remove_owned_queue(&self.config.printer_name)?;
                let status = self
                    .provider
                    .inspect_owned_queue(&self.config.printer_name)?;
                if status.queue.is_some() {
                    return Err(BridgeError::Internal {
                        detail: "owned Windows queue remained after removal".into(),
                    });
                }
                Ok(Response::OperationComplete {
                    operation: "printer_remove",
                })
            }
            Request::Help => Ok(Response::Help(m5_help_text().into())),
            _ => Err(BridgeError::MissingDependency {
                dependency: "requested provider in the M5 handler".into(),
                action: "Use a printer install, status, test-page, or remove command.".into(),
            }),
        }
    }
}

impl<P: WindowsPrinting> RequestHandler for M5AgentService<P> {
    fn handle(&mut self, version: u16, request: Request) -> Response {
        if version != PROTOCOL_VERSION {
            return Response::Error {
                code: "unsupported_protocol".into(),
                message: format!("Protocol {version} is unsupported; expected {PROTOCOL_VERSION}."),
            };
        }
        self.handle_current(request)
            .unwrap_or_else(|error| Response::Error {
                code: error.kind().as_str().into(),
                message: error.to_string(),
            })
    }
}

#[must_use]
pub const fn m5_help_text() -> &'static str {
    "QuireWire M5 CLI (real Windows IPP provider)\n\
Usage: quirewirectl [--trace] --config <path> <command>\n\n\
Commands:\n\
  printer install      Idempotently create the marker-owned Windows IPP queue\n\
  printer status       Show spooler, endpoint, ownership, driver, port, and queue state\n\
  printer test-page    Submit one Windows test page; this proves spooler acceptance only\n\
  printer remove       Remove only the exact marker-owned queue; retain driver and port\n\
  help                 Show this help\n\n\
Configuration schema: quirewire.m5.config.v1\n\
The expected driver is Microsoft IPP Class Driver. Physical output always requires owner confirmation."
}

fn required<'a>(values: &'a BTreeMap<String, String>, key: &str) -> Result<&'a str, BridgeError> {
    values
        .get(key)
        .map(String::as_str)
        .ok_or_else(|| config_error(format!("missing key '{key}'")))
}

fn valid_printer_name(value: &str) -> bool {
    let prefix = "Brother via QuireWire";
    if value == prefix {
        return true;
    }
    value
        .strip_prefix(&format!("{prefix} "))
        .is_some_and(|suffix| {
            !suffix.is_empty()
                && suffix.len() <= 40
                && suffix
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        })
}

fn config_error(detail: impl Into<String>) -> BridgeError {
    BridgeError::PermissionDenied {
        operation: format!("reading M5 configuration: {}", detail.into()),
        action: "Use the documented schema and loopback endpoint values.".into(),
    }
}

#[cfg(test)]
mod tests {
    use quirewire_core::fake::FakePlatform;
    use quirewire_ipc::{PROTOCOL_VERSION, Request, RequestHandler, Response};

    use super::{M5AgentService, M5Config};

    const CONFIG: &str = "schema=quirewire.m5.config.v1\n\
printer_name=Brother via QuireWire M5Test\n\
endpoint_port=8632\n\
guest_queue=DCPL2600D\n";

    #[test]
    fn parses_bounded_loopback_configuration() {
        let config = M5Config::parse(CONFIG).expect("config");
        assert_eq!(config.printer_name, "Brother via QuireWire M5Test");
        assert_eq!(config.endpoint.port(), 8632);
        assert_eq!(config.endpoint.queue(), "DCPL2600D");
    }

    #[test]
    fn rejects_unknown_keys_unsafe_names_and_queue_paths() {
        assert!(M5Config::parse(&format!("{CONFIG}other=value\n")).is_err());
        assert!(M5Config::parse(&CONFIG.replace("M5Test", "bad suffix")).is_err());
        assert!(M5Config::parse(&CONFIG.replace("DCPL2600D", "../../queue")).is_err());
    }

    #[test]
    fn printer_commands_use_the_windows_provider_trait() {
        let config = M5Config::parse(CONFIG).expect("config");
        let mut service = M5AgentService::new(FakePlatform::ready(), config);
        assert!(matches!(
            service.handle(PROTOCOL_VERSION, Request::PrinterInstall),
            Response::PrinterStatus(_)
        ));
        assert!(matches!(
            service.handle(PROTOCOL_VERSION, Request::PrinterTestPage),
            Response::PrinterTestPage(_)
        ));
        assert!(matches!(
            service.handle(PROTOCOL_VERSION, Request::PrinterRemove),
            Response::OperationComplete {
                operation: "printer_remove"
            }
        ));
    }
}
