//! Windows PrintManagement/IPP provider for M5.
//!
//! All PowerShell calls use an argument vector, a tracked helper script and a
//! bounded timeout. Queue mutation is guarded by a per-user ownership marker;
//! ports, drivers, default-printer state and unrelated queues are never removed.

mod protocol;
mod runner;

use std::env;
use std::ffi::OsString;
use std::net::Ipv4Addr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use printbridge_domain::{
    BridgeError, ComponentState, ComponentStatus, DependencyInfo, JobState, PrintQueue,
    PrinterEndpoint, WindowsPrintSubmission, WindowsPrinting, WindowsQueueStatus,
};

use protocol::ProviderRecord;
pub use runner::{CommandOutput, CommandRunner, ProcessRunner};

pub const EXPECTED_DRIVER: &str = "Microsoft IPP Class Driver";
pub const OWNERSHIP_SCHEMA: &str = "printbridge.m5.owned-printer.v1";
pub const PRINTING_IMPLEMENTATION_MILESTONE: &str = "M5";
pub const STARTUP_IMPLEMENTATION_MILESTONE: &str = "M6";
pub const STARTUP_TASK_PATH: &str = r"\PrintBridge\";
pub const STARTUP_TASK_NAME: &str = "Agent";
pub const LAN_IMPLEMENTATION_MILESTONE: &str = "M10";
const LAN_PROTOCOL: &str = "PRINTBRIDGE_LAN_V2";

static CORRELATION_COUNTER: AtomicU64 = AtomicU64::new(1);

fn discover_resource(relative: &[&str]) -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(root) = env::var_os("PRINTBRIDGE_RESOURCE_ROOT") {
        candidates.push(PathBuf::from(root));
    }
    if let Ok(executable) = env::current_exe()
        && let Some(parent) = executable.parent()
    {
        candidates.extend(parent.ancestors().take(4).map(PathBuf::from));
    }
    candidates.push(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../.."));

    candidates.into_iter().find_map(|root| {
        let candidate = relative
            .iter()
            .fold(root, |path, segment| path.join(segment));
        candidate.is_file().then_some(candidate)
    })
}

#[derive(Debug, Clone)]
pub struct WindowsProviderConfig {
    pub powershell: PathBuf,
    pub script: PathBuf,
    pub state_path: PathBuf,
    pub printer_name: String,
    pub endpoint: PrinterEndpoint,
    pub command_timeout: Duration,
}

#[derive(Debug, Clone)]
pub struct WindowsStartupConfig {
    pub powershell: PathBuf,
    pub script: PathBuf,
    pub agent_executable: PathBuf,
    pub agent_config: PathBuf,
    pub owner_sid: String,
    pub command_timeout: Duration,
}

#[derive(Debug, Clone)]
pub struct WindowsLanConfig {
    pub powershell: PathBuf,
    pub script: PathBuf,
    pub owner_token: String,
    pub ipp_port: u16,
    pub agent_executable: PathBuf,
    pub vbox_headless_executable: PathBuf,
    pub approved_interface_alias: Option<String>,
    pub approved_subnet: Option<String>,
    pub command_timeout: Duration,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LanStatus {
    pub network_allowed: bool,
    pub interface_alias: Option<String>,
    pub network_category: Option<String>,
    pub address: Option<Ipv4Addr>,
    pub firewall_ready: bool,
    pub reason: String,
}

pub struct WindowsLanProvider<R = ProcessRunner> {
    runner: R,
    config: WindowsLanConfig,
}

impl WindowsLanProvider<ProcessRunner> {
    pub fn discover(
        owner_token: impl Into<String>,
        ipp_port: u16,
        agent_executable: impl Into<PathBuf>,
        approved_interface_alias: Option<String>,
        approved_subnet: Option<String>,
    ) -> Result<Self, BridgeError> {
        let script = discover_resource(&["scripts", "m10", "windows", "Invoke-M10LanSharing.ps1"])
            .ok_or_else(|| BridgeError::MissingDependency {
                dependency: "PrintBridge M10 LAN provider resource".into(),
                action: "Repair the PrintBridge installation or restore Invoke-M10LanSharing.ps1."
                    .into(),
            })?;
        let program_files =
            env::var_os("ProgramFiles").ok_or_else(|| BridgeError::MissingDependency {
                dependency: "ProgramFiles".into(),
                action: "Run PrintBridge under the owning interactive Windows user.".into(),
            })?;
        Ok(Self::new(WindowsLanConfig {
            powershell: PathBuf::from("powershell.exe"),
            script,
            owner_token: owner_token.into(),
            ipp_port,
            agent_executable: agent_executable.into(),
            vbox_headless_executable: PathBuf::from(program_files)
                .join("Oracle/VirtualBox/VBoxHeadless.exe"),
            approved_interface_alias,
            approved_subnet,
            command_timeout: Duration::from_secs(30),
        }))
    }

    #[must_use]
    pub fn new(config: WindowsLanConfig) -> Self {
        Self {
            runner: ProcessRunner,
            config,
        }
    }
}

impl<R: CommandRunner> WindowsLanProvider<R> {
    #[must_use]
    pub const fn with_runner(config: WindowsLanConfig, runner: R) -> Self {
        Self { runner, config }
    }

    pub fn status(&self) -> Result<LanStatus, BridgeError> {
        let mut arguments = vec![
            OsString::from("-NoLogo"),
            OsString::from("-NoProfile"),
            OsString::from("-NonInteractive"),
            OsString::from("-ExecutionPolicy"),
            OsString::from("Bypass"),
            OsString::from("-File"),
            self.config.script.as_os_str().to_os_string(),
            OsString::from("-Action"),
            OsString::from("Status"),
            OsString::from("-OwnerToken"),
            OsString::from(&self.config.owner_token),
            OsString::from("-IppPort"),
            OsString::from(self.config.ipp_port.to_string()),
            OsString::from("-AgentExecutable"),
            self.config.agent_executable.as_os_str().to_os_string(),
            OsString::from("-VBoxHeadlessExecutable"),
            self.config
                .vbox_headless_executable
                .as_os_str()
                .to_os_string(),
        ];
        if let (Some(interface_alias), Some(subnet)) = (
            &self.config.approved_interface_alias,
            &self.config.approved_subnet,
        ) {
            arguments.push(OsString::from("-ApprovedInterfaceAlias"));
            arguments.push(OsString::from(interface_alias));
            arguments.push(OsString::from("-ApprovedSubnet"));
            arguments.push(OsString::from(subnet));
        }
        let output = self.runner.run(
            &self.config.powershell,
            &arguments,
            self.config.command_timeout,
        )?;
        let record = ProviderRecord::parse_with_header(&output.stdout, LAN_PROTOCOL)?;
        if output.exit_code != Some(0) || !record.boolean("ok")? {
            return Err(BridgeError::PermissionDenied {
                operation: "checking approved-LAN sharing policy".into(),
                action: record.optional_text("error_message")?.unwrap_or_else(|| {
                    "Run PrintBridge Repair and inspect Windows Firewall.".into()
                }),
            });
        }
        let address = record
            .optional_text("address")?
            .map(|value| {
                value
                    .parse::<Ipv4Addr>()
                    .map_err(|_| BridgeError::Internal {
                        detail: "LAN provider returned an invalid IPv4 address".into(),
                    })
            })
            .transpose()?;
        Ok(LanStatus {
            network_allowed: record.boolean("network_allowed")?,
            interface_alias: record.optional_text("interface_alias")?,
            network_category: record.optional_text("network_category")?,
            address,
            firewall_ready: record.boolean("firewall_ready")?,
            reason: record.text("reason")?,
        })
    }
}

pub struct WindowsStartupProvider<R = ProcessRunner> {
    runner: R,
    config: WindowsStartupConfig,
}

impl WindowsStartupProvider<ProcessRunner> {
    pub fn discover(
        agent_executable: impl Into<PathBuf>,
        agent_config: impl Into<PathBuf>,
        owner_sid: impl Into<String>,
    ) -> Result<Self, BridgeError> {
        let script = discover_resource(&[
            "scripts",
            "m6",
            "windows",
            "Invoke-M6Startup.ps1",
        ])
        .ok_or_else(|| BridgeError::MissingDependency {
            dependency: "PrintBridge startup provider resource".into(),
            action: "Repair the PrintBridge installation or restore the tracked M6 startup provider script."
                .into(),
        })?;
        Ok(Self::new(WindowsStartupConfig {
            powershell: PathBuf::from("powershell.exe"),
            script,
            agent_executable: agent_executable.into(),
            agent_config: agent_config.into(),
            owner_sid: owner_sid.into(),
            command_timeout: Duration::from_secs(60),
        }))
    }

    #[must_use]
    pub fn new(config: WindowsStartupConfig) -> Self {
        Self {
            runner: ProcessRunner,
            config,
        }
    }
}

impl<R: CommandRunner> WindowsStartupProvider<R> {
    #[must_use]
    pub const fn with_runner(config: WindowsStartupConfig, runner: R) -> Self {
        Self { runner, config }
    }

    fn invoke_startup(
        &self,
        action: &str,
    ) -> Result<printbridge_domain::StartupRegistration, BridgeError> {
        let arguments = [
            OsString::from("-NoLogo"),
            OsString::from("-NoProfile"),
            OsString::from("-NonInteractive"),
            OsString::from("-ExecutionPolicy"),
            OsString::from("Bypass"),
            OsString::from("-File"),
            self.config.script.as_os_str().to_os_string(),
            OsString::from("-Action"),
            OsString::from(action),
            OsString::from("-AgentExecutable"),
            self.config.agent_executable.as_os_str().to_os_string(),
            OsString::from("-AgentConfig"),
            self.config.agent_config.as_os_str().to_os_string(),
            OsString::from("-OwnerSid"),
            OsString::from(&self.config.owner_sid),
        ];
        let output = self.runner.run(
            &self.config.powershell,
            &arguments,
            self.config.command_timeout,
        )?;
        let record = ProviderRecord::parse(&output.stdout)?;
        if output.exit_code != Some(0) || !record.boolean("ok")? {
            return Err(BridgeError::PermissionDenied {
                operation: "managing the PrintBridge login task".into(),
                action: record.optional_text("error_message")?.unwrap_or_else(|| {
                    "Review Task Scheduler permissions and exact task ownership.".into()
                }),
            });
        }
        Ok(printbridge_domain::StartupRegistration {
            enabled: record.boolean("enabled")?,
            owner: record.text("owner_sid")?,
        })
    }
}

impl<R: CommandRunner> printbridge_domain::Startup for WindowsStartupProvider<R> {
    fn enable_login_start(&mut self) -> Result<(), BridgeError> {
        let registration = self.invoke_startup("Enable")?;
        if registration.enabled {
            Ok(())
        } else {
            Err(BridgeError::Internal {
                detail: "startup provider did not enable the owned task".into(),
            })
        }
    }

    fn disable_login_start(&mut self) -> Result<(), BridgeError> {
        let registration = self.invoke_startup("Disable")?;
        if registration.enabled {
            Err(BridgeError::Internal {
                detail: "startup provider left the owned task enabled".into(),
            })
        } else {
            Ok(())
        }
    }

    fn verify_registration(&self) -> Result<printbridge_domain::StartupRegistration, BridgeError> {
        self.invoke_startup("Status")
    }
}

impl WindowsProviderConfig {
    #[must_use]
    pub fn new(
        powershell: impl Into<PathBuf>,
        script: impl Into<PathBuf>,
        state_path: impl Into<PathBuf>,
        printer_name: impl Into<String>,
        endpoint: PrinterEndpoint,
    ) -> Self {
        Self {
            powershell: powershell.into(),
            script: script.into(),
            state_path: state_path.into(),
            printer_name: printer_name.into(),
            endpoint,
            command_timeout: Duration::from_secs(60),
        }
    }
}

pub struct WindowsPrintProvider<R = ProcessRunner> {
    runner: R,
    config: WindowsProviderConfig,
}

impl WindowsPrintProvider<ProcessRunner> {
    pub fn discover(
        printer_name: impl Into<String>,
        endpoint: PrinterEndpoint,
    ) -> Result<Self, BridgeError> {
        let local_app_data =
            env::var_os("LOCALAPPDATA").ok_or_else(|| BridgeError::MissingDependency {
                dependency: "LOCALAPPDATA".into(),
                action: "Run PrintBridge under the owning interactive Windows user.".into(),
            })?;
        let powershell = env::var_os("PRINTBRIDGE_POWERSHELL")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("powershell.exe"));
        let script = env::var_os("PRINTBRIDGE_WINDOWS_PROVIDER_SCRIPT")
            .map(PathBuf::from)
            .or_else(|| {
                discover_resource(&[
                    "scripts",
                    "m5",
                    "windows",
                    "Invoke-M5WindowsPrinting.ps1",
                ])
            })
            .ok_or_else(|| BridgeError::MissingDependency {
                dependency: "PrintBridge Windows printing provider resource".into(),
                action: "Repair the PrintBridge installation or set PRINTBRIDGE_WINDOWS_PROVIDER_SCRIPT."
                    .into(),
            })?;
        let state_path = PathBuf::from(local_app_data)
            .join("PrintBridge")
            .join("m5-windows-printer.json");
        Ok(Self::new(WindowsProviderConfig::new(
            powershell,
            script,
            state_path,
            printer_name,
            endpoint,
        )))
    }

    #[must_use]
    pub fn new(config: WindowsProviderConfig) -> Self {
        Self {
            runner: ProcessRunner,
            config,
        }
    }
}

impl<R: CommandRunner> WindowsPrintProvider<R> {
    #[must_use]
    pub const fn with_runner(config: WindowsProviderConfig, runner: R) -> Self {
        Self { runner, config }
    }

    fn validate_target(
        &self,
        name: &str,
        endpoint: Option<&PrinterEndpoint>,
    ) -> Result<(), BridgeError> {
        if name != self.config.printer_name {
            return Err(ownership_error(
                "requested queue name differs from the configured owned queue",
            ));
        }
        if endpoint.is_some_and(|value| value != &self.config.endpoint) {
            return Err(ownership_error(
                "requested endpoint differs from the configured owned endpoint",
            ));
        }
        Ok(())
    }

    fn invoke(
        &self,
        action: &str,
        correlation_id: Option<&str>,
    ) -> Result<ProviderRecord, BridgeError> {
        let mut arguments = vec![
            OsString::from("-NoLogo"),
            OsString::from("-NoProfile"),
            OsString::from("-NonInteractive"),
            OsString::from("-ExecutionPolicy"),
            OsString::from("Bypass"),
            OsString::from("-File"),
            self.config.script.as_os_str().to_os_string(),
            OsString::from("-Action"),
            OsString::from(action),
            OsString::from("-PrinterName"),
            OsString::from(&self.config.printer_name),
            OsString::from("-IppUrl"),
            OsString::from(self.config.endpoint.windows_ipp_url()),
            OsString::from("-StatePath"),
            self.config.state_path.as_os_str().to_os_string(),
        ];
        if let Some(value) = correlation_id {
            arguments.push(OsString::from("-CorrelationId"));
            arguments.push(OsString::from(value));
        }
        let output = self.runner.run(
            &self.config.powershell,
            &arguments,
            self.config.command_timeout,
        )?;
        let record = ProviderRecord::parse(&output.stdout)?;
        if output.exit_code == Some(0) && record.boolean("ok")? {
            Ok(record)
        } else {
            Err(map_script_error(&record, &output))
        }
    }

    fn status(&self) -> Result<WindowsQueueStatus, BridgeError> {
        record_to_status(&self.invoke("Status", None)?)
    }
}

impl<R: CommandRunner> WindowsPrinting for WindowsPrintProvider<R> {
    fn detect_ipp_support(&self) -> Result<DependencyInfo, BridgeError> {
        let record = self.invoke("Detect", None)?;
        if !record.boolean("ipp_url_supported")? {
            return Err(unsupported_ipp_error());
        }
        Ok(DependencyInfo {
            name: "Windows PrintManagement with Add-Printer -IppURL".into(),
            version: record.text("print_management_version")?,
        })
    }

    fn register_owned_queue(
        &mut self,
        name: &str,
        endpoint: &PrinterEndpoint,
    ) -> Result<PrintQueue, BridgeError> {
        self.validate_target(name, Some(endpoint))?;
        let status = record_to_status(&self.invoke("Install", None)?)?;
        status.queue.ok_or_else(|| BridgeError::Internal {
            detail: "Windows reported a successful install without a queue".into(),
        })
    }

    fn list_owned_queues(&self) -> Result<Vec<PrintQueue>, BridgeError> {
        let status = self.status()?;
        Ok(if status.ownership_verified {
            status.queue.into_iter().collect()
        } else {
            Vec::new()
        })
    }

    fn remove_owned_queue(&mut self, name: &str) -> Result<(), BridgeError> {
        self.validate_target(name, None)?;
        self.invoke("Remove", None)?;
        Ok(())
    }

    fn verify_driver(&self, name: &str) -> Result<(), BridgeError> {
        self.validate_target(name, None)?;
        let status = self.status()?;
        let queue = status.queue.ok_or_else(|| BridgeError::PrinterMissing {
            printer: name.into(),
            action: "Run 'printbridgectl printer install' first.".into(),
        })?;
        if queue.driver != EXPECTED_DRIVER {
            return Err(BridgeError::UnsupportedDriver {
                observed: queue.driver,
                expected: EXPECTED_DRIVER.into(),
            });
        }
        if !status.ownership_verified {
            return Err(ownership_error(
                "live queue does not match the persisted ownership record",
            ));
        }
        Ok(())
    }

    fn windows_queue_status(&self) -> Result<ComponentStatus, BridgeError> {
        let status = self.status()?;
        let Some(queue) = status.queue else {
            return Ok(ComponentStatus::with_detail(
                ComponentState::NotConfigured,
                "owned Windows IPP queue is absent",
            ));
        };
        if !status.spooler_running {
            return Ok(ComponentStatus::with_detail(
                ComponentState::Error,
                "Windows Print Spooler is not running",
            ));
        }
        if !status.ownership_verified {
            return Ok(ComponentStatus::with_detail(
                ComponentState::Degraded,
                "queue exists but ownership metadata does not match",
            ));
        }
        if queue.driver != EXPECTED_DRIVER {
            return Ok(ComponentStatus::with_detail(
                ComponentState::Error,
                format!("unexpected driver: {}", queue.driver),
            ));
        }
        Ok(ComponentStatus::with_detail(
            ComponentState::Ready,
            "owned queue uses Microsoft IPP Class Driver",
        ))
    }

    fn inspect_owned_queue(&self, name: &str) -> Result<WindowsQueueStatus, BridgeError> {
        self.validate_target(name, None)?;
        self.status()
    }

    fn submit_windows_test_page(
        &mut self,
        name: &str,
    ) -> Result<WindowsPrintSubmission, BridgeError> {
        self.validate_target(name, None)?;
        self.verify_driver(name)?;
        let correlation_id = new_correlation_id();
        let record = self.invoke("TestPage", Some(&correlation_id))?;
        Ok(WindowsPrintSubmission {
            correlation_id: record.text("correlation_id")?,
            spooler_job_id: record.optional_u32("spooler_job_id")?,
            state: JobState::Accepted,
        })
    }
}

fn record_to_status(record: &ProviderRecord) -> Result<WindowsQueueStatus, BridgeError> {
    let queue_found = record.boolean("queue_found")?;
    let queue = if queue_found {
        Some(PrintQueue {
            name: record.text("queue_name")?,
            driver: record.text("driver_name")?,
        })
    } else {
        None
    };
    Ok(WindowsQueueStatus {
        queue,
        endpoint: record.text("ipp_url")?,
        port_name: record.optional_text("port_name")?,
        printer_status: record.optional_text("printer_status")?,
        spooler_running: record.boolean("spooler_running")?,
        ipp_url_supported: record.boolean("ipp_url_supported")?,
        ownership_verified: record.boolean("ownership_verified")?,
        is_default: record.boolean("is_default")?,
    })
}

fn map_script_error(record: &ProviderRecord, output: &CommandOutput) -> BridgeError {
    let code = record.raw("error_code").unwrap_or("provider_failure");
    let message = record
        .optional_text("error_message")
        .ok()
        .flatten()
        .unwrap_or_else(|| "Windows printing provider failed".into());
    match code {
        "missing_printmanagement" => BridgeError::MissingDependency {
            dependency: "Windows PrintManagement".into(),
            action: message,
        },
        "ipp_url_unsupported" => unsupported_ipp_error(),
        "queue_not_found" => BridgeError::PrinterMissing {
            printer: "configured Windows queue".into(),
            action: message,
        },
        "ownership_mismatch" | "default_printer" | "invalid_argument" | "permission_denied" => {
            BridgeError::PermissionDenied {
                operation: "managing the Windows print queue".into(),
                action: message,
            }
        }
        "unsupported_driver" => BridgeError::UnsupportedDriver {
            observed: record
                .optional_text("observed_driver")
                .ok()
                .flatten()
                .unwrap_or_else(|| "unknown".into()),
            expected: EXPECTED_DRIVER.into(),
        },
        "endpoint_unreachable" => BridgeError::IppNegotiationFailed {
            endpoint: "configured loopback IPP endpoint".into(),
            action: message,
        },
        "spooler_not_running" => BridgeError::GuestUnhealthy {
            detail: "Windows Print Spooler is stopped".into(),
            action: message,
        },
        _ => BridgeError::Internal {
            detail: format!(
                "Windows provider failed (exit {:?}): {}",
                output.exit_code,
                message.chars().take(300).collect::<String>()
            ),
        },
    }
}

fn unsupported_ipp_error() -> BridgeError {
    BridgeError::MissingDependency {
        dependency: "Add-Printer -IppURL".into(),
        action: "Use Settings > Bluetooth & devices > Printers & scanners > Add device > Add manually > Add a printer using an IP address or hostname, choose IPP Device, enter the configured URL, and verify the driver is Microsoft IPP Class Driver. Do not select a Brother driver."
            .into(),
    }
}

fn ownership_error(detail: &str) -> BridgeError {
    BridgeError::PermissionDenied {
        operation: detail.into(),
        action:
            "Refusing to change a queue not proven to be the configured PrintBridge-owned queue."
                .into(),
    }
}

fn new_correlation_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let counter = CORRELATION_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("m5-{nanos:032x}-{:08x}-{counter:016x}", std::process::id())
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;
    use std::path::Path;
    use std::sync::Mutex;
    use std::time::Duration;

    use printbridge_domain::{JobState, PrinterEndpoint, WindowsPrinting};

    use super::{
        CommandOutput, CommandRunner, WindowsLanConfig, WindowsLanProvider, WindowsPrintProvider,
        WindowsProviderConfig,
    };

    struct ScriptedRunner {
        outputs: Mutex<Vec<CommandOutput>>,
        calls: Mutex<Vec<Vec<OsString>>>,
    }

    impl ScriptedRunner {
        fn new(outputs: Vec<CommandOutput>) -> Self {
            Self {
                outputs: Mutex::new(outputs.into_iter().rev().collect()),
                calls: Mutex::new(Vec::new()),
            }
        }

        fn calls(&self) -> Vec<Vec<OsString>> {
            self.calls.lock().expect("calls").clone()
        }
    }

    impl CommandRunner for ScriptedRunner {
        fn run(
            &self,
            _executable: &Path,
            arguments: &[OsString],
            _timeout: Duration,
        ) -> Result<CommandOutput, printbridge_domain::BridgeError> {
            self.calls.lock().expect("calls").push(arguments.to_vec());
            Ok(self.outputs.lock().expect("outputs").pop().expect("output"))
        }
    }

    fn endpoint() -> PrinterEndpoint {
        PrinterEndpoint::Loopback {
            port: 8644,
            queue: "PrintBridge_DCP_L2600D".into(),
        }
    }

    fn config() -> WindowsProviderConfig {
        WindowsProviderConfig::new(
            "powershell.exe",
            "provider.ps1",
            "C:/state/owner.json",
            "Brother via PrintBridge",
            endpoint(),
        )
    }

    fn record(queue_found: bool, owned: bool) -> String {
        format!(
            "PRINTBRIDGE_WINDOWS_V1\nok=true\nipp_url_supported=true\nprint_management_version=MS4x\nqueue_found={queue_found}\nownership_verified={owned}\nspooler_running=true\nis_default=false\nipp_url=aHR0cDovLzEyNy4wLjAuMTo4NjQ0L3ByaW50ZXJzL1ByaW50QnJpZGdlX0RDUEwyNjAwRA==\nqueue_name=QnJvdGhlciB2aWEgUHJpbnRCcmlkZ2U=\ndriver_name=TWljcm9zb2Z0IElQUCBDbGFzcyBEcml2ZXI=\nport_name=V1NELXRlc3Q=\nprinter_status=Tm9ybWFs\n"
        )
    }

    #[test]
    fn detects_installed_ipp_url_support() {
        let runner = ScriptedRunner::new(vec![CommandOutput {
            exit_code: Some(0),
            stdout: record(false, false),
            stderr: String::new(),
        }]);
        let provider = WindowsPrintProvider::with_runner(config(), runner);
        let info = provider.detect_ipp_support().expect("supported");
        assert!(info.name.contains("IppURL"));
        let calls = provider.runner.calls();
        assert!(calls[0].iter().any(|value| value == "Detect"));
    }

    #[test]
    fn install_uses_argument_vector_and_exact_configured_target() {
        let runner = ScriptedRunner::new(vec![CommandOutput {
            exit_code: Some(0),
            stdout: record(true, true),
            stderr: String::new(),
        }]);
        let mut provider = WindowsPrintProvider::with_runner(config(), runner);
        let queue = provider
            .register_owned_queue("Brother via PrintBridge", &endpoint())
            .expect("install");
        assert_eq!(queue.driver, "Microsoft IPP Class Driver");
        let call: Vec<String> = provider.runner.calls()[0]
            .iter()
            .map(|value| value.to_string_lossy().into_owned())
            .collect();
        assert!(call.windows(2).any(|pair| pair == ["-Action", "Install"]));
        assert!(
            call.windows(2)
                .any(|pair| pair == ["-PrinterName", "Brother via PrintBridge"])
        );
        assert!(call.iter().all(|part| !part.contains("Add-Printer")));
    }

    #[test]
    fn refuses_a_different_name_before_running_powershell() {
        let runner = ScriptedRunner::new(Vec::new());
        let mut provider = WindowsPrintProvider::with_runner(config(), runner);
        let error = provider
            .remove_owned_queue("Unrelated printer")
            .expect_err("ownership guard");
        assert_eq!(error.kind().as_str(), "permission_denied");
        assert!(provider.runner.calls().is_empty());
    }

    #[test]
    fn test_page_is_only_spooler_accepted_and_has_correlation() {
        let status = record(true, true);
        let submission =
            format!("{status}correlation_id=bTUtY29ycmVsYXRpb24=\nspooler_job_id=17\n");
        let runner = ScriptedRunner::new(vec![
            CommandOutput {
                exit_code: Some(0),
                stdout: status,
                stderr: String::new(),
            },
            CommandOutput {
                exit_code: Some(0),
                stdout: submission,
                stderr: String::new(),
            },
        ]);
        let mut provider = WindowsPrintProvider::with_runner(config(), runner);
        let result = provider
            .submit_windows_test_page("Brother via PrintBridge")
            .expect("submission");
        assert_eq!(result.state, JobState::Accepted);
        assert_eq!(result.spooler_job_id, Some(17));
        assert_eq!(result.correlation_id, "m5-correlation");
    }

    #[test]
    fn lan_status_parses_the_explicit_scope_protocol() {
        let runner = ScriptedRunner::new(vec![CommandOutput {
            exit_code: Some(0),
            stdout: "PRINTBRIDGE_LAN_V2\nok=true\nnetwork_allowed=true\ninterface_alias=RXRoZXJuZXQ=\nnetwork_category=UHVibGlj\naddress=MTkyLjE2OC4xLjIw\nfirewall_ready=true\nreason=cmVhZHk=\nerror_code=\nerror_message=\n".into(),
            stderr: String::new(),
        }]);
        let provider = WindowsLanProvider::with_runner(
            WindowsLanConfig {
                powershell: "powershell.exe".into(),
                script: "lan.ps1".into(),
                owner_token: "00000000-0000-0000-0000-000000000004".into(),
                ipp_port: 8644,
                agent_executable: "agent.exe".into(),
                vbox_headless_executable: "VBoxHeadless.exe".into(),
                approved_interface_alias: Some("Ethernet".into()),
                approved_subnet: Some("192.168.1.0/24".into()),
                command_timeout: Duration::from_secs(5),
            },
            runner,
        );
        let status = provider.status().expect("LAN status");
        assert!(status.network_allowed);
        assert!(status.firewall_ready);
        assert_eq!(status.interface_alias.as_deref(), Some("Ethernet"));
        assert_eq!(status.network_category.as_deref(), Some("Public"));
        assert_eq!(status.address.unwrap().to_string(), "192.168.1.20");
        let calls = provider.runner.calls();
        assert!(
            calls[0]
                .windows(2)
                .any(|parts| parts == ["-Action", "Status"])
        );
    }
}
