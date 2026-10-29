//! Windows PrintManagement/IPP provider for M5.
//!
//! All PowerShell calls use an argument vector, a tracked helper script and a
//! bounded timeout. Queue mutation is guarded by a per-user ownership marker;
//! ports, drivers, default-printer state and unrelated queues are never removed.

mod protocol;
mod runner;

use std::env;
use std::ffi::OsString;
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

static CORRELATION_COUNTER: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone)]
pub struct WindowsProviderConfig {
    pub powershell: PathBuf,
    pub script: PathBuf,
    pub state_path: PathBuf,
    pub printer_name: String,
    pub endpoint: PrinterEndpoint,
    pub command_timeout: Duration,
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
            .unwrap_or_else(|| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("../../scripts/m5/windows/Invoke-M5WindowsPrinting.ps1")
            });
        if !script.is_file() {
            return Err(BridgeError::MissingDependency {
                dependency: script.display().to_string(),
                action: "Restore the tracked M5 Windows provider script or set PRINTBRIDGE_WINDOWS_PROVIDER_SCRIPT."
                    .into(),
            });
        }
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

    use super::{CommandOutput, CommandRunner, WindowsPrintProvider, WindowsProviderConfig};

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
}
