use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use printbridge_domain::{
    BridgeError, CheckState, ComponentState, DoctorCheck, DoctorReport, Hypervisor, OwnedVm,
    OwnershipMarker, UsbAccess, UsbIdentity, VmId,
};
use printbridge_ipc::{PROTOCOL_VERSION, Request, RequestHandler, Response};
use printbridge_provider_virtualbox::VirtualBoxProvider;

pub const M3_CONFIG_SCHEMA: &str = "printbridge.m3.config.v1";

#[derive(Clone, PartialEq, Eq)]
pub struct M3Config {
    pub vm: OwnedVm,
    pub usb: UsbIdentity,
}

impl M3Config {
    pub fn load(path: &Path) -> Result<Self, BridgeError> {
        let contents =
            fs::read_to_string(path).map_err(|error| BridgeError::MissingDependency {
                dependency: format!("M3 configuration at {}", path.display()),
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
            if values.insert(key.to_string(), value.to_string()).is_some() {
                return Err(config_error(format!("duplicate key '{key}'")));
            }
        }
        let schema = required(&values, "schema")?;
        if schema != M3_CONFIG_SCHEMA {
            return Err(config_error(format!(
                "unsupported schema '{schema}'; expected '{M3_CONFIG_SCHEMA}'"
            )));
        }
        let vm_uuid = required(&values, "vm_uuid")?;
        if !is_canonical_uuid(vm_uuid) {
            return Err(config_error("vm_uuid must be a canonical UUID"));
        }
        let vm_marker = required(&values, "vm_marker")?;
        if vm_marker.is_empty() || vm_marker.len() > 200 {
            return Err(config_error("vm_marker must contain 1 to 200 characters"));
        }
        let vendor_id = parse_hex_id(required(&values, "usb_vendor_id")?, "usb_vendor_id")?;
        let product_id = parse_hex_id(required(&values, "usb_product_id")?, "usb_product_id")?;
        let serial = values
            .get("usb_serial")
            .filter(|value| !value.is_empty())
            .cloned();
        Ok(Self {
            vm: OwnedVm {
                id: VmId::new(vm_uuid),
                marker: OwnershipMarker::new(vm_marker),
            },
            usb: UsbIdentity {
                vendor_id,
                product_id,
                serial,
            },
        })
    }
}

pub struct M3AgentService<P> {
    provider: P,
    config: Option<M3Config>,
}

impl M3AgentService<VirtualBoxProvider> {
    pub fn discover(config: Option<M3Config>) -> Result<Self, BridgeError> {
        Ok(Self::new(VirtualBoxProvider::discover()?, config))
    }
}

impl<P: Hypervisor + UsbAccess> M3AgentService<P> {
    #[must_use]
    pub const fn new(provider: P, config: Option<M3Config>) -> Self {
        Self { provider, config }
    }

    fn configured(&self) -> Result<&M3Config, BridgeError> {
        self.config
            .as_ref()
            .ok_or_else(|| BridgeError::MissingDependency {
                dependency: "M3 VM/USB configuration".into(),
                action: "Pass --config <path> containing the exact owned VM UUID, marker, and USB identity."
                    .into(),
            })
    }

    fn doctor(&self) -> DoctorReport {
        let mut checks = Vec::with_capacity(5);
        checks.push(match self.provider.detect() {
            Ok(info) => DoctorCheck::pass(
                "virtualbox",
                format!("{} {} is supported", info.name, info.version),
            ),
            Err(error) => failed_check("virtualbox", &error),
        });
        checks.push(match self.provider.validate_host_prerequisites() {
            Ok(()) => DoctorCheck::pass(
                "host_virtualization",
                "hardware virtualization is available to VirtualBox",
            ),
            Err(error) => failed_check("host_virtualization", &error),
        });
        checks.push(match &self.config {
            Some(config) => match self.provider.guest_state(&config.vm) {
                Ok(status) => {
                    DoctorCheck::pass("owned_vm", format!("exact owned VM is {}", status.state))
                }
                Err(error) => failed_check("owned_vm", &error),
            },
            None => warning_check(
                "owned_vm",
                "no M3 configuration was supplied",
                "Pass --config <path> to validate an exact owned VM.",
            ),
        });
        let devices = self.provider.list_devices();
        checks.push(match &devices {
            Ok(devices) if devices.is_empty() => warning_check(
                "usb_discovery",
                "VirtualBox reported no host USB devices",
                "Connect the printer, then run printbridgectl usb list.",
            ),
            Ok(devices) => DoctorCheck::pass(
                "usb_discovery",
                format!("VirtualBox reported {} host USB device(s)", devices.len()),
            ),
            Err(error) => failed_check("usb_discovery", error),
        });
        checks.push(match &self.config {
            Some(config) => match self.provider.attachment_status(&config.vm, &config.usb) {
                Ok(status) if status.state == ComponentState::Ready => {
                    DoctorCheck::pass("usb_selection", "selected USB is attached to the owned VM")
                }
                Ok(status) => warning_check(
                    "usb_selection",
                    format!("selected USB state is {}", status.state),
                    "Start the owned VM and run printbridgectl usb attach.",
                ),
                Err(error) => failed_check("usb_selection", &error),
            },
            None => warning_check(
                "usb_selection",
                "no exact USB identity was supplied",
                "Create an M3 configuration after reviewing usb list.",
            ),
        });
        DoctorReport {
            provider: "virtualbox-real",
            checks,
        }
    }

    fn handle_current(&mut self, request: Request) -> Result<Response, BridgeError> {
        match request {
            Request::Doctor => Ok(Response::Doctor(self.doctor())),
            Request::VmStatus => {
                let config = self.configured()?;
                Ok(Response::VmStatus(self.provider.guest_state(&config.vm)?))
            }
            Request::VmStart => {
                let vm = self.configured()?.vm.clone();
                self.provider.start_headless(&vm)?;
                Ok(Response::OperationComplete {
                    operation: "vm_start",
                })
            }
            Request::VmStop => {
                let vm = self.configured()?.vm.clone();
                self.provider.stop_gracefully(&vm)?;
                Ok(Response::OperationComplete {
                    operation: "vm_stop",
                })
            }
            Request::UsbList => Ok(Response::UsbDevices(self.provider.list_devices()?)),
            Request::UsbAttach => {
                let config = self.configured()?.clone();
                self.provider.capture_selected(&config.vm, &config.usb)?;
                Ok(Response::OperationComplete {
                    operation: "usb_attach",
                })
            }
            Request::UsbAttachAt(index) => {
                let vm = self.configured()?.vm.clone();
                let device = device_at(self.provider.list_devices()?, index)?;
                let host_id = device
                    .host_id
                    .as_deref()
                    .ok_or_else(|| BridgeError::Internal {
                        detail: "USB provider omitted the interactive host handle".into(),
                    })?;
                self.provider
                    .capture_selected_host(&vm, &device.identity, host_id)?;
                Ok(Response::OperationComplete {
                    operation: "usb_attach",
                })
            }
            Request::UsbRelease => {
                let config = self.configured()?.clone();
                self.provider.release_selected(&config.vm, &config.usb)?;
                Ok(Response::OperationComplete {
                    operation: "usb_release",
                })
            }
            Request::UsbReleaseAt(index) => {
                let vm = self.configured()?.vm.clone();
                let device = device_at(self.provider.list_devices()?, index)?;
                let host_id = device
                    .host_id
                    .as_deref()
                    .ok_or_else(|| BridgeError::Internal {
                        detail: "USB provider omitted the interactive host handle".into(),
                    })?;
                self.provider
                    .release_selected_host(&vm, &device.identity, host_id)?;
                Ok(Response::OperationComplete {
                    operation: "usb_release",
                })
            }
            Request::Help => Ok(Response::Help(m3_help_text().into())),
            Request::GetStatus => Err(BridgeError::MissingDependency {
                dependency: "full bridge status".into(),
                action: "M3 exposes vm status; full multi-provider status returns in M6.".into(),
            }),
            Request::PrinterInstall
            | Request::PrinterStatus
            | Request::PrinterTestPage
            | Request::PrinterRemove => Err(BridgeError::MissingDependency {
                dependency: "Windows printing provider".into(),
                action: "Use the M5 printer command handler.".into(),
            }),
        }
    }
}

impl<P: Hypervisor + UsbAccess> RequestHandler for M3AgentService<P> {
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
pub const fn m3_help_text() -> &'static str {
    "PrintBridge M3 CLI (real VirtualBox provider)\n\
Usage: printbridgectl [--trace] [--config <path>] <command>\n\n\
Commands:\n\
  doctor       Validate VirtualBox, host virtualization, VM ownership, and USB\n\
  vm status    Show exact owned VM state\n\
  vm start     Idempotently start exact owned VM headlessly\n\
  vm stop      Idempotently request graceful shutdown of exact owned VM\n\
  usb list     List host USB identities without revealing serial values\n\
  usb attach [--index N]   Attach configured identity or an explicit listed device\n\
  usb release [--index N]  Release configured identity or an explicit listed device\n\
  help         Show this help\n\n\
Configuration schema: printbridge.m3.config.v1"
}

fn required<'a>(values: &'a BTreeMap<String, String>, key: &str) -> Result<&'a str, BridgeError> {
    values
        .get(key)
        .map(String::as_str)
        .ok_or_else(|| config_error(format!("missing key '{key}'")))
}

fn device_at(
    devices: Vec<printbridge_domain::UsbDevice>,
    index: usize,
) -> Result<printbridge_domain::UsbDevice, BridgeError> {
    if index == 0 {
        return Err(config_error(
            "USB index is one-based and must be at least 1",
        ));
    }
    devices
        .into_iter()
        .nth(index - 1)
        .ok_or_else(|| BridgeError::PrinterMissing {
            printer: format!("USB list index {index}"),
            action: "Run usb list again and choose a current one-based index.".into(),
        })
}

fn parse_hex_id(value: &str, key: &str) -> Result<u16, BridgeError> {
    let digits = value.strip_prefix("0x").unwrap_or(value);
    if digits.len() != 4 {
        return Err(config_error(format!(
            "{key} must contain four hexadecimal digits"
        )));
    }
    u16::from_str_radix(digits, 16).map_err(|_| config_error(format!("{key} is not hexadecimal")))
}

fn is_canonical_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
}

fn config_error(detail: impl Into<String>) -> BridgeError {
    BridgeError::PermissionDenied {
        operation: format!("reading M3 configuration: {}", detail.into()),
        action: "Use the documented schema and exact owned resource identities.".into(),
    }
}

fn failed_check(name: &'static str, error: &BridgeError) -> DoctorCheck {
    DoctorCheck::fail(name, error.safe_summary(), error.to_string())
}

fn warning_check(
    name: &'static str,
    detail: impl Into<String>,
    action: impl Into<String>,
) -> DoctorCheck {
    DoctorCheck {
        name,
        state: CheckState::Warn,
        detail: detail.into(),
        action: Some(action.into()),
    }
}

#[cfg(test)]
mod tests {
    use printbridge_core::fake::{FakeAction, FakePlatform};
    use printbridge_ipc::{PROTOCOL_VERSION, Request, RequestHandler, Response};

    use super::{M3AgentService, M3Config};

    const CONFIG: &str = "schema=printbridge.m3.config.v1\n\
vm_uuid=00000000-0000-0000-0000-000000000002\n\
vm_marker=printbridge.m2.fake-owned-vm.v1\n\
usb_vendor_id=04f9\n\
usb_product_id=0567\n\
usb_serial=fake-sensitive-serial\n";

    #[test]
    fn parses_exact_configuration_without_debugging_serial() {
        let config = M3Config::parse(CONFIG).expect("valid config");
        assert_eq!(
            config.vm.id.as_str(),
            "00000000-0000-0000-0000-000000000002"
        );
        assert_eq!(config.usb.vendor_id, 0x04f9);
        assert_eq!(config.usb.serial.as_deref(), Some("fake-sensitive-serial"));
    }

    #[test]
    fn rejects_duplicate_or_noncanonical_configuration() {
        let duplicate = format!("{CONFIG}usb_vendor_id=1234\n");
        assert!(M3Config::parse(&duplicate).is_err());
        assert!(
            M3Config::parse(&CONFIG.replace("00000000-0000-0000-0000-000000000002", "not-a-uuid"))
                .is_err()
        );
    }

    #[test]
    fn real_command_handler_uses_provider_traits() {
        let provider = FakePlatform::ready();
        let config = M3Config::parse(CONFIG).expect("config");
        let mut agent = M3AgentService::new(provider, Some(config));
        assert!(matches!(
            agent.handle(PROTOCOL_VERSION, Request::VmStatus),
            Response::VmStatus(_)
        ));
        assert!(matches!(
            agent.handle(PROTOCOL_VERSION, Request::VmStart),
            Response::OperationComplete {
                operation: "vm_start"
            }
        ));
        assert!(
            agent
                .provider
                .actions()
                .contains(&FakeAction::StartedHeadless)
        );
    }

    #[test]
    fn mutation_without_configuration_is_refused() {
        let mut agent = M3AgentService::new(FakePlatform::ready(), None);
        assert!(matches!(
            agent.handle(PROTOCOL_VERSION, Request::VmStart),
            Response::Error { ref code, .. } if code == "missing_dependency"
        ));
    }
}
