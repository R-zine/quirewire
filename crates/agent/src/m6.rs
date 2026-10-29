use std::collections::{BTreeMap, VecDeque};
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::net::{Ipv4Addr, SocketAddrV4, TcpListener};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use printbridge_domain::{
    BridgeError, ComponentState, ComponentStatus, GuestPrinting, Hypervisor, JobState, OwnedVm,
    OwnershipMarker, PrinterEndpoint, Startup, UsbAccess, UsbDevice, UsbIdentity, VmId,
    WindowsPrinting,
};
use printbridge_ipc::{
    AgentComponents, AgentEvent, AgentStatus, Command, DeviceSummary, Diagnostics, ErrorPayload,
    OperationResult, PROTOCOL_VERSION, Payload, RequestEnvelope, ResponseEnvelope, StartupStatus,
    TestPrintResult, WireComponent, WireComponentState, WireError, read_request, write_response,
};
use printbridge_provider_cups::CupsIppProvider;
use printbridge_provider_virtualbox::VirtualBoxProvider;
use printbridge_provider_windows::{WindowsPrintProvider, WindowsStartupProvider};
use serde::{Deserialize, Serialize};
use tokio::io::BufReader;

pub const M6_CONFIG_SCHEMA: &str = "printbridge.m6.config.v1";
const STATE_SCHEMA: &str = "printbridge.m6.state.v1";
const VM_SCHEMA: &str = "printbridge.m4.acceptance-vm.v1";
const TASK_NAME: &str = r"\PrintBridge\Agent";
const TICK_INTERVAL: Duration = Duration::from_secs(1);
const HEALTHY_INTERVAL: Duration = Duration::from_secs(10);
const MAX_BACKOFF: Duration = Duration::from_secs(30);
const STARTUP_CHECK_INTERVAL: Duration = Duration::from_secs(60);
const MAX_EVENTS: usize = 128;
const MAX_REQUEST_CACHE: usize = 128;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct M6Config {
    pub owner_sid: String,
    pub vm: OwnedVm,
    pub vm_schema: String,
    pub usb: UsbIdentity,
    pub printer_name: String,
    pub endpoint: PrinterEndpoint,
}

impl M6Config {
    pub fn load(path: &Path) -> Result<Self, BridgeError> {
        let contents =
            fs::read_to_string(path).map_err(|error| BridgeError::MissingDependency {
                dependency: format!("M6 configuration at {}", path.display()),
                action: format!("Create a readable owner-protected configuration ({error})."),
            })?;
        Self::parse(&contents)
    }

    pub fn parse(contents: &str) -> Result<Self, BridgeError> {
        let mut values = BTreeMap::new();
        for (index, raw) in contents.lines().enumerate() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let (key, value) = line
                .split_once('=')
                .ok_or_else(|| config_error(format!("line {} must be key=value", index + 1)))?;
            if !matches!(
                key,
                "schema"
                    | "owner_sid"
                    | "vm_uuid"
                    | "vm_marker"
                    | "vm_schema"
                    | "usb_vendor_id"
                    | "usb_product_id"
                    | "usb_serial"
                    | "printer_name"
                    | "endpoint_port"
                    | "guest_queue"
            ) {
                return Err(config_error(format!("unknown key '{key}'")));
            }
            if values.insert(key.to_string(), value.to_string()).is_some() {
                return Err(config_error(format!("duplicate key '{key}'")));
            }
        }
        if required(&values, "schema")? != M6_CONFIG_SCHEMA {
            return Err(config_error("unsupported schema"));
        }
        let owner_sid = required(&values, "owner_sid")?;
        validate_sid(owner_sid)?;
        let vm_uuid = required(&values, "vm_uuid")?;
        if !canonical_uuid(vm_uuid) {
            return Err(config_error("vm_uuid must be a canonical UUID"));
        }
        let vm_marker = required(&values, "vm_marker")?;
        if vm_marker.is_empty() || vm_marker.len() > 200 {
            return Err(config_error("vm_marker must contain 1-200 characters"));
        }
        let vm_schema = required(&values, "vm_schema")?;
        if vm_schema != VM_SCHEMA {
            return Err(config_error(format!(
                "vm_schema must be the accepted M4 schema '{VM_SCHEMA}'"
            )));
        }
        let vendor_id = hex_id(required(&values, "usb_vendor_id")?, "usb_vendor_id")?;
        let product_id = hex_id(required(&values, "usb_product_id")?, "usb_product_id")?;
        let serial = values
            .get("usb_serial")
            .filter(|value| !value.is_empty())
            .cloned();
        let printer_name = required(&values, "printer_name")?;
        if printer_name != "Brother via PrintBridge" {
            return Err(config_error(
                "M6 manages only the accepted queue name 'Brother via PrintBridge'",
            ));
        }
        let port = required(&values, "endpoint_port")?
            .parse::<u16>()
            .map_err(|_| config_error("endpoint_port must be 1-65535"))?;
        if port == 0 {
            return Err(config_error("endpoint_port must be non-zero"));
        }
        let queue = required(&values, "guest_queue")?;
        if queue.is_empty()
            || queue.len() > 127
            || !queue
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        {
            return Err(config_error("guest_queue contains unsafe characters"));
        }
        Ok(Self {
            owner_sid: owner_sid.into(),
            vm: OwnedVm {
                id: VmId::new(vm_uuid),
                marker: OwnershipMarker::new(vm_marker),
            },
            vm_schema: vm_schema.into(),
            usb: UsbIdentity {
                vendor_id,
                product_id,
                serial,
            },
            printer_name: printer_name.into(),
            endpoint: PrinterEndpoint::Loopback {
                port,
                queue: queue.into(),
            },
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum DesiredState {
    Running,
    Stopped,
}

impl DesiredState {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Stopped => "stopped",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PersistedState {
    schema: String,
    revision: u64,
    desired: DesiredState,
    vm_uuid: String,
    vm_marker: String,
    vm_schema: String,
    usb_vendor_id: u16,
    usb_product_id: u16,
    usb_serial: Option<String>,
    endpoint_port: u16,
    guest_queue: String,
    printer_name: String,
}

impl PersistedState {
    fn from_config(config: &M6Config) -> Self {
        Self {
            schema: STATE_SCHEMA.into(),
            revision: 0,
            desired: DesiredState::Running,
            vm_uuid: config.vm.id.as_str().into(),
            vm_marker: config.vm.marker.as_str().into(),
            vm_schema: config.vm_schema.clone(),
            usb_vendor_id: config.usb.vendor_id,
            usb_product_id: config.usb.product_id,
            usb_serial: config.usb.serial.clone(),
            endpoint_port: config.endpoint.port(),
            guest_queue: config.endpoint.queue().into(),
            printer_name: config.printer_name.clone(),
        }
    }

    fn matches(&self, config: &M6Config) -> bool {
        self.schema == STATE_SCHEMA
            && self.vm_uuid.eq_ignore_ascii_case(config.vm.id.as_str())
            && self.vm_marker == config.vm.marker.as_str()
            && self.vm_schema == config.vm_schema
            && self.usb_vendor_id == config.usb.vendor_id
            && self.usb_product_id == config.usb.product_id
            && self.usb_serial == config.usb.serial
            && self.endpoint_port == config.endpoint.port()
            && self.guest_queue == config.endpoint.queue()
            && self.printer_name == config.printer_name
    }
}

struct StateStore {
    directory: PathBuf,
}

impl StateStore {
    fn new(directory: PathBuf) -> Result<Self, BridgeError> {
        fs::create_dir_all(&directory).map_err(state_io_error)?;
        Ok(Self { directory })
    }

    fn load(&self, config: &M6Config) -> Result<PersistedState, BridgeError> {
        let mut candidates = Vec::new();
        for entry in fs::read_dir(&self.directory).map_err(state_io_error)? {
            let entry = entry.map_err(state_io_error)?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if let Some(revision) = name
                .strip_prefix("state-")
                .and_then(|name| name.strip_suffix(".json"))
                .and_then(|digits| digits.parse::<u64>().ok())
            {
                candidates.push((revision, entry.path()));
            }
        }
        candidates.sort_by_key(|(revision, _)| std::cmp::Reverse(*revision));
        for (revision, path) in candidates {
            let Ok(contents) = fs::read(&path) else {
                continue;
            };
            let Ok(state) = serde_json::from_slice::<PersistedState>(&contents) else {
                continue;
            };
            if state.revision == revision && state.matches(config) {
                return Ok(state);
            }
        }
        let state = PersistedState::from_config(config);
        self.persist(&state)?;
        Ok(state)
    }

    fn persist(&self, state: &PersistedState) -> Result<(), BridgeError> {
        let final_path = self
            .directory
            .join(format!("state-{:020}.json", state.revision));
        if final_path.exists() {
            return Err(BridgeError::PermissionDenied {
                operation: "persisting desired state".into(),
                action: "Refusing to overwrite an immutable state generation.".into(),
            });
        }
        let temporary = self.directory.join(format!(
            ".state-{:020}-{}.tmp",
            state.revision,
            std::process::id()
        ));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(state_io_error)?;
        let bytes = serde_json::to_vec(state).map_err(|error| BridgeError::Internal {
            detail: format!("state serialization failed: {error}"),
        })?;
        file.write_all(&bytes).map_err(state_io_error)?;
        file.sync_all().map_err(state_io_error)?;
        drop(file);
        fs::rename(&temporary, &final_path).map_err(state_io_error)
    }
}

#[derive(Debug, Clone)]
struct Observation {
    components: AgentComponents,
    startup: StartupStatus,
}

trait ReconcileBackend: Send {
    fn observe(&mut self, config: &M6Config, desired: DesiredState, repair: bool) -> Observation;
    fn discover_devices(&self, config: &M6Config) -> Result<Vec<DeviceSummary>, BridgeError>;
    fn begin_setup(&mut self, config: &M6Config, device_index: usize) -> Result<(), BridgeError>;
    fn test_print(&mut self, config: &M6Config) -> Result<TestPrintResult, BridgeError>;
}

struct RealBackend {
    virtualbox: VirtualBoxProvider,
    cups: CupsIppProvider,
    windows: WindowsPrintProvider,
    startup: WindowsStartupProvider,
    startup_registered: Option<bool>,
    startup_checked: Option<Instant>,
}

impl RealBackend {
    fn discover(config: &M6Config, config_path: &Path) -> Result<Self, BridgeError> {
        let executable = std::env::current_exe().map_err(|error| BridgeError::Internal {
            detail: format!("cannot resolve agent executable: {error}"),
        })?;
        Ok(Self {
            virtualbox: VirtualBoxProvider::discover_with_ownership_schema(&config.vm_schema)?,
            cups: CupsIppProvider::new(config.endpoint.clone(), Duration::from_secs(5)),
            windows: WindowsPrintProvider::discover(
                config.printer_name.clone(),
                config.endpoint.clone(),
            )?,
            startup: WindowsStartupProvider::discover(
                executable,
                config_path,
                config.owner_sid.clone(),
            )?,
            startup_registered: None,
            startup_checked: None,
        })
    }

    fn startup_status(&mut self) -> StartupStatus {
        let check_due = self.startup_checked.is_none_or(|checked| {
            Instant::now().saturating_duration_since(checked) >= STARTUP_CHECK_INTERVAL
        });
        if check_due {
            self.startup_registered = self
                .startup
                .verify_registration()
                .ok()
                .map(|registration| registration.enabled);
            self.startup_checked = Some(Instant::now());
        }
        StartupStatus {
            registered: self.startup_registered.unwrap_or(false),
            task_name: TASK_NAME.into(),
            logoff_behavior:
                "interactive per-user agent terminates at logoff; printing resumes after next logon"
                    .into(),
        }
    }

    fn running_components(&mut self, config: &M6Config, repair: bool) -> AgentComponents {
        let hypervisor = match self.virtualbox.detect() {
            Ok(info) => ready(format!("{} {} available", info.name, info.version)),
            Err(error) => component_error(&error),
        };
        if hypervisor.state == WireComponentState::Error {
            return AgentComponents {
                hypervisor,
                guest: blocked("VirtualBox is unavailable"),
                usb: blocked("Guest is unavailable"),
                cups: blocked("Guest is unavailable"),
                windows_queue: self.windows_component(config),
            };
        }
        let guest_status = match self.virtualbox.guest_state(&config.vm) {
            Ok(status) => status,
            Err(error) => {
                return AgentComponents {
                    hypervisor,
                    guest: component_error(&error),
                    usb: blocked("Guest ownership could not be verified"),
                    cups: blocked("Guest is unavailable"),
                    windows_queue: self.windows_component(config),
                };
            }
        };
        if guest_status.state == ComponentState::Stopped {
            if let Err(error) = port_available(config.endpoint.port()) {
                return AgentComponents {
                    hypervisor,
                    guest: component_error(&error),
                    usb: blocked("Guest could not start"),
                    cups: blocked("Guest could not start"),
                    windows_queue: self.windows_component(config),
                };
            }
            let guest = match self.virtualbox.start_headless(&config.vm) {
                Ok(()) => connecting("Owned VM start accepted"),
                Err(error) => component_error(&error),
            };
            return AgentComponents {
                hypervisor,
                guest,
                usb: blocked("Waiting for guest startup"),
                cups: blocked("Waiting for guest startup"),
                windows_queue: self.windows_component(config),
            };
        }
        let guest = from_domain(guest_status);
        let mut usb = match self.virtualbox.attachment_status(&config.vm, &config.usb) {
            Ok(status) => from_domain(status),
            Err(error) => component_error(&error),
        };
        if usb.state == WireComponentState::Waiting {
            match self.virtualbox.capture_selected(&config.vm, &config.usb) {
                Ok(()) => usb = connecting("Selected USB capture accepted"),
                Err(BridgeError::PrinterMissing { .. }) => {
                    usb = waiting("Selected USB device is unplugged")
                }
                Err(error) => usb = component_error(&error),
            }
        }
        let mut cups = match self.cups.queue_status(config.endpoint.queue()) {
            Ok(status) => from_domain(status),
            Err(error) => component_error(&error),
        };
        if repair && cups.state == WireComponentState::Error {
            cups = match self.virtualbox.stop_gracefully(&config.vm) {
                Ok(()) => match self.virtualbox.start_headless(&config.vm) {
                    Ok(()) => connecting("Owned guest restarted to recover CUPS"),
                    Err(error) => component_error(&error),
                },
                Err(error) => component_error(&error),
            };
        }
        let windows_queue = self.windows_component(config);
        AgentComponents {
            hypervisor,
            guest,
            usb,
            cups,
            windows_queue,
        }
    }

    fn windows_component(&mut self, config: &M6Config) -> WireComponent {
        match self.windows.inspect_owned_queue(&config.printer_name) {
            Ok(status) if !status.spooler_running => {
                error("Windows Print Spooler is stopped; start the Spooler service")
            }
            Ok(status) if status.queue.is_none() => match self
                .windows
                .register_owned_queue(&config.printer_name, &config.endpoint)
            {
                Ok(_) => ready("Owned Microsoft IPP queue restored"),
                Err(error) => component_error(&error),
            },
            Ok(status) if !status.ownership_verified => {
                error("Windows queue exists but ownership could not be verified")
            }
            Ok(status) if status.is_default => {
                degraded("Owned queue is unexpectedly the default; PrintBridge will not change it")
            }
            Ok(_) => match self.windows.verify_driver(&config.printer_name) {
                Ok(()) => ready("Owned queue uses Microsoft IPP Class Driver"),
                Err(error) => component_error(&error),
            },
            Err(error) => component_error(&error),
        }
    }
}

impl ReconcileBackend for RealBackend {
    fn observe(&mut self, config: &M6Config, desired: DesiredState, repair: bool) -> Observation {
        let startup = self.startup_status();
        let components = if desired == DesiredState::Stopped {
            let guest = match self.virtualbox.stop_gracefully(&config.vm) {
                Ok(()) => stopped("Owned VM is stopped by desired state"),
                Err(error) => component_error(&error),
            };
            AgentComponents {
                hypervisor: ready("VirtualBox provider available"),
                guest,
                usb: stopped("USB capture inactive while bridge is stopped"),
                cups: stopped("CUPS endpoint inactive while bridge is stopped"),
                windows_queue: self.windows_component(config),
            }
        } else {
            self.running_components(config, repair)
        };
        Observation {
            components,
            startup,
        }
    }

    fn discover_devices(&self, config: &M6Config) -> Result<Vec<DeviceSummary>, BridgeError> {
        let devices = self.virtualbox.list_devices()?;
        Ok(summarize_devices(&devices, &config.usb))
    }

    fn begin_setup(&mut self, config: &M6Config, device_index: usize) -> Result<(), BridgeError> {
        let devices = self.virtualbox.list_devices()?;
        let selected = devices.get(device_index.saturating_sub(1)).ok_or_else(|| {
            BridgeError::PrinterMissing {
                printer: format!("USB list index {device_index}"),
                action: "Discover devices again and choose a current one-based index.".into(),
            }
        })?;
        if selected.identity != config.usb {
            return Err(BridgeError::PermissionDenied {
                operation: "selecting a USB device".into(),
                action: "M6 can only select the exact device recorded by accepted M4 evidence."
                    .into(),
            });
        }
        self.startup.enable_login_start()?;
        self.startup_registered = Some(true);
        self.startup_checked = Some(Instant::now());
        Ok(())
    }

    fn test_print(&mut self, config: &M6Config) -> Result<TestPrintResult, BridgeError> {
        let submission = self
            .windows
            .submit_windows_test_page(&config.printer_name)?;
        Ok(TestPrintResult {
            correlation_id: submission.correlation_id,
            spooler_job_id: submission.spooler_job_id,
            windows_spooler: match submission.state {
                JobState::Accepted => "accepted".into(),
                _ => "unexpected".into(),
            },
            cups_processing: "not_inferred".into(),
            physical_output: "requires_owner_confirmation".into(),
        })
    }
}

struct Supervisor<B> {
    config: M6Config,
    store: StateStore,
    state: PersistedState,
    backend: B,
    status: AgentStatus,
    events: VecDeque<AgentEvent>,
    completed: BTreeMap<String, ResponseEnvelope>,
    completed_order: VecDeque<String>,
    event_sequence: u64,
    failure_count: u32,
    next_reconcile: Instant,
    state_path: PathBuf,
    log_path: PathBuf,
    pipe_name: String,
}

impl<B: ReconcileBackend> Supervisor<B> {
    fn new(
        config: M6Config,
        state_directory: PathBuf,
        log_path: PathBuf,
        pipe_name: String,
        backend: B,
    ) -> Result<Self, BridgeError> {
        let store = StateStore::new(state_directory.clone())?;
        let state = store.load(&config)?;
        let status = initial_status(&state);
        let mut supervisor = Self {
            config,
            store,
            state,
            backend,
            status,
            events: VecDeque::new(),
            completed: BTreeMap::new(),
            completed_order: VecDeque::new(),
            event_sequence: 0,
            failure_count: 0,
            next_reconcile: Instant::now(),
            state_path: state_directory,
            log_path,
            pipe_name,
        };
        supervisor.event(
            "info",
            "agent_started",
            "Standalone headless agent initialized",
        );
        supervisor.reconcile(false);
        Ok(supervisor)
    }

    fn handle(&mut self, request: RequestEnvelope) -> ResponseEnvelope {
        if let Some(response) = self.completed.get(&request.request_id) {
            return response.clone();
        }
        let request_id = request.request_id.clone();
        let result = self.execute(request.command);
        let response = match result {
            Ok(payload) => ResponseEnvelope::ok(&request_id, payload),
            Err(error) => {
                self.event("error", "command_failed", error.safe_summary());
                ResponseEnvelope::error(
                    &request_id,
                    ErrorPayload {
                        code: error.kind().as_str().into(),
                        message: error.to_string(),
                        action: None,
                        retryable: error.retryable(),
                    },
                )
            }
        };
        self.cache(request_id, response.clone());
        response
    }

    fn execute(&mut self, command: Command) -> Result<Payload, BridgeError> {
        match command {
            Command::GetStatus => Ok(Payload::Status(self.status.clone())),
            Command::DiscoverDevices => Ok(Payload::Devices(
                self.backend.discover_devices(&self.config)?,
            )),
            Command::BeginSetup { device_index } => {
                if device_index == 0 {
                    return Err(config_error("device_index is one-based"));
                }
                self.backend.begin_setup(&self.config, device_index)?;
                self.set_desired(DesiredState::Running)?;
                self.reconcile(false);
                Ok(Payload::Operation(operation("begin_setup")))
            }
            Command::Start => {
                self.set_desired(DesiredState::Running)?;
                self.reconcile(false);
                Ok(Payload::Operation(operation("start")))
            }
            Command::Stop => {
                self.set_desired(DesiredState::Stopped)?;
                self.reconcile(false);
                Ok(Payload::Operation(operation("stop")))
            }
            Command::Restart => {
                self.set_desired(DesiredState::Stopped)?;
                self.reconcile(false);
                self.set_desired(DesiredState::Running)?;
                self.reconcile(false);
                Ok(Payload::Operation(operation("restart")))
            }
            Command::TestPrint => Ok(Payload::TestPrint(self.backend.test_print(&self.config)?)),
            Command::GetDiagnostics => Ok(Payload::Diagnostics(self.diagnostics())),
            Command::Repair => {
                self.set_desired(DesiredState::Running)?;
                self.reconcile(true);
                Ok(Payload::Operation(operation("repair")))
            }
        }
    }

    fn set_desired(&mut self, desired: DesiredState) -> Result<(), BridgeError> {
        if self.state.desired == desired {
            return Ok(());
        }
        let mut next = self.state.clone();
        next.revision = next
            .revision
            .checked_add(1)
            .ok_or_else(|| BridgeError::Internal {
                detail: "state revision overflow".into(),
            })?;
        next.desired = desired;
        self.store.persist(&next)?;
        self.state = next;
        self.event("info", "desired_state_changed", desired.as_str());
        Ok(())
    }

    fn tick(&mut self) {
        if Instant::now() >= self.next_reconcile {
            self.reconcile(false);
        }
    }

    fn reconcile(&mut self, repair: bool) {
        let prior = self.status.clone();
        let observation = self
            .backend
            .observe(&self.config, self.state.desired, repair);
        let unhealthy = components_unhealthy(&observation.components);
        self.failure_count = if unhealthy {
            self.failure_count.saturating_add(1)
        } else {
            0
        };
        let delay = if self.failure_count == 0 {
            HEALTHY_INTERVAL
        } else {
            Duration::from_secs((1_u64 << self.failure_count.min(5)).min(MAX_BACKOFF.as_secs()))
        };
        self.next_reconcile = Instant::now() + delay;
        self.status = AgentStatus {
            desired: self.state.desired.as_str().into(),
            overall: overall(self.state.desired, &observation.components).into(),
            revision: self.state.revision,
            retry_after_ms: unhealthy.then_some(delay.as_millis() as u64),
            components: observation.components,
            startup: observation.startup,
        };
        if self.status != prior {
            let detail = self.status.overall.clone();
            self.event("info", "status_changed", &detail);
        }
    }

    fn diagnostics(&self) -> Diagnostics {
        Diagnostics {
            generated_at_unix_ms: unix_ms(),
            protocol_version: PROTOCOL_VERSION,
            owner_sid: self.config.owner_sid.clone(),
            pipe_name: self.pipe_name.clone(),
            process_id: std::process::id(),
            state_path: self.state_path.display().to_string(),
            log_path: self.log_path.display().to_string(),
            status: self.status.clone(),
            recent_events: self.events.iter().cloned().collect(),
            notes: vec![
                "USB serial values are intentionally redacted from IPC, logs, and diagnostics."
                    .into(),
                "Spooler acceptance and CUPS completion do not prove physical paper output.".into(),
                "The per-user interactive agent is unavailable after logoff until the next logon."
                    .into(),
            ],
        }
    }

    fn event(&mut self, level: &str, event: &str, detail: &str) {
        self.event_sequence = self.event_sequence.saturating_add(1);
        let record = AgentEvent {
            sequence: self.event_sequence,
            unix_ms: unix_ms(),
            level: level.into(),
            event: event.into(),
            detail: detail.into(),
        };
        if self.events.len() == MAX_EVENTS {
            self.events.pop_front();
        }
        self.events.push_back(record.clone());
        if let Some(parent) = self.log_path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        if let Ok(mut file) = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.log_path)
            && serde_json::to_writer(&mut file, &record).is_ok()
        {
            let _ = file.write_all(b"\n");
        }
    }

    fn cache(&mut self, id: String, response: ResponseEnvelope) {
        if self.completed.len() == MAX_REQUEST_CACHE
            && let Some(oldest) = self.completed_order.pop_front()
        {
            self.completed.remove(&oldest);
        }
        self.completed_order.push_back(id.clone());
        self.completed.insert(id, response);
    }
}

pub async fn run_agent(config_path: PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let config = M6Config::load(&config_path)?;
    let current_sid = printbridge_ipc::windows_pipe::current_user_sid()?;
    if current_sid != config.owner_sid {
        return Err(format!(
            "configured owner SID does not match the current interactive user ({current_sid})"
        )
        .into());
    }
    let factory = printbridge_ipc::windows_pipe::SecurePipeFactory::new(&config.owner_sid)?;
    let mut server = factory.create_first().map_err(|error| {
        if error.raw_os_error() == Some(5) || error.raw_os_error() == Some(231) {
            io::Error::new(
                io::ErrorKind::AlreadyExists,
                "another PrintBridge agent already owns the per-user pipe",
            )
        } else {
            error
        }
    })?;
    let root = config_path
        .parent()
        .ok_or("M6 config must have a parent directory")?;
    let backend = RealBackend::discover(&config, &config_path)?;
    let supervisor = Arc::new(Mutex::new(Supervisor::new(
        config,
        root.join("state"),
        root.join("logs/agent.jsonl"),
        factory.pipe_name().into(),
        backend,
    )?));
    let reconcile_supervisor = Arc::clone(&supervisor);
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(TICK_INTERVAL).await;
            let supervisor = Arc::clone(&reconcile_supervisor);
            let _ = tokio::task::spawn_blocking(move || {
                if let Ok(mut guard) = supervisor.lock() {
                    guard.tick();
                }
            })
            .await;
        }
    });
    loop {
        server.connect().await?;
        let connected = server;
        server = factory.create_next()?;
        let supervisor = Arc::clone(&supervisor);
        tokio::spawn(async move {
            if let Err(error) = serve_connection(connected, supervisor).await {
                eprintln!("printbridge-agent IPC: {error}");
            }
        });
    }
}

async fn serve_connection<B: ReconcileBackend + 'static>(
    stream: tokio::net::windows::named_pipe::NamedPipeServer,
    supervisor: Arc<Mutex<Supervisor<B>>>,
) -> Result<(), WireError> {
    let (reader, mut writer) = tokio::io::split(stream);
    let request = tokio::time::timeout(
        Duration::from_secs(10),
        read_request(&mut BufReader::new(reader)),
    )
    .await
    .map_err(|_| {
        WireError::Io(io::Error::new(
            io::ErrorKind::TimedOut,
            "IPC read timed out",
        ))
    })??;
    let response = tokio::task::spawn_blocking(move || {
        supervisor
            .lock()
            .map_err(|_| WireError::Io(io::Error::other("supervisor lock poisoned")))
            .map(|mut guard| guard.handle(request))
    })
    .await
    .map_err(|error| WireError::Io(io::Error::other(error.to_string())))??;
    write_response(&mut writer, &response).await
}

fn summarize_devices(devices: &[UsbDevice], selected: &UsbIdentity) -> Vec<DeviceSummary> {
    devices
        .iter()
        .enumerate()
        .map(|(index, device)| DeviceSummary {
            index: index + 1,
            vendor_id: format!("{:04x}", device.identity.vendor_id),
            product_id: format!("{:04x}", device.identity.product_id),
            display_name: device.display_name.clone(),
            serial_present: device.identity.serial.is_some(),
            selected: device.identity == *selected,
        })
        .collect()
}

fn initial_status(state: &PersistedState) -> AgentStatus {
    AgentStatus {
        desired: state.desired.as_str().into(),
        overall: "starting".into(),
        revision: state.revision,
        retry_after_ms: None,
        components: AgentComponents {
            hypervisor: connecting("Initial observation pending"),
            guest: connecting("Initial observation pending"),
            usb: connecting("Initial observation pending"),
            cups: connecting("Initial observation pending"),
            windows_queue: connecting("Initial observation pending"),
        },
        startup: StartupStatus {
            registered: false,
            task_name: TASK_NAME.into(),
            logoff_behavior:
                "interactive per-user agent terminates at logoff; printing resumes after next logon"
                    .into(),
        },
    }
}

fn from_domain(status: ComponentStatus) -> WireComponent {
    let state = match status.state {
        ComponentState::NotConfigured | ComponentState::Provisioning => {
            WireComponentState::NotConfigured
        }
        ComponentState::Stopped => WireComponentState::Stopped,
        ComponentState::Starting => WireComponentState::Starting,
        ComponentState::Waiting => WireComponentState::Waiting,
        ComponentState::Connecting => WireComponentState::Connecting,
        ComponentState::Ready => WireComponentState::Ready,
        ComponentState::Degraded => WireComponentState::Degraded,
        ComponentState::Error => WireComponentState::Error,
        ComponentState::Stopping => WireComponentState::Stopping,
    };
    WireComponent {
        state,
        detail: status.detail.unwrap_or_else(|| status.state.to_string()),
    }
}

fn component_error(error_value: &BridgeError) -> WireComponent {
    error(error_value.safe_summary())
}

fn ready(detail: impl Into<String>) -> WireComponent {
    component(WireComponentState::Ready, detail)
}

fn stopped(detail: impl Into<String>) -> WireComponent {
    component(WireComponentState::Stopped, detail)
}

fn waiting(detail: impl Into<String>) -> WireComponent {
    component(WireComponentState::Waiting, detail)
}

fn connecting(detail: impl Into<String>) -> WireComponent {
    component(WireComponentState::Connecting, detail)
}

fn degraded(detail: impl Into<String>) -> WireComponent {
    component(WireComponentState::Degraded, detail)
}

fn blocked(detail: impl Into<String>) -> WireComponent {
    component(WireComponentState::Stopped, detail)
}

fn error(detail: impl Into<String>) -> WireComponent {
    component(WireComponentState::Error, detail)
}

fn component(state: WireComponentState, detail: impl Into<String>) -> WireComponent {
    WireComponent {
        state,
        detail: detail.into(),
    }
}

fn components_unhealthy(components: &AgentComponents) -> bool {
    [
        components.hypervisor.state,
        components.guest.state,
        components.usb.state,
        components.cups.state,
        components.windows_queue.state,
    ]
    .iter()
    .any(|state| {
        matches!(
            state,
            WireComponentState::Error
                | WireComponentState::Waiting
                | WireComponentState::Connecting
                | WireComponentState::Degraded
        )
    })
}

fn overall(desired: DesiredState, components: &AgentComponents) -> &'static str {
    if desired == DesiredState::Stopped {
        return "stopped";
    }
    let states = [
        components.hypervisor.state,
        components.guest.state,
        components.usb.state,
        components.cups.state,
        components.windows_queue.state,
    ];
    if states
        .iter()
        .all(|state| *state == WireComponentState::Ready)
    {
        "ready"
    } else if states.contains(&WireComponentState::Error) {
        "error"
    } else if components.usb.state == WireComponentState::Waiting {
        "waiting_for_usb"
    } else if states.contains(&WireComponentState::Starting)
        || states.contains(&WireComponentState::Connecting)
    {
        "connecting"
    } else {
        "degraded"
    }
}

fn port_available(port: u16) -> Result<(), BridgeError> {
    TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port))
        .map(drop)
        .map_err(|_| BridgeError::PortConflict {
            port,
            action: "Stop the conflicting loopback listener or repair PrintBridge with a newly validated stable port."
                .into(),
        })
}

fn operation(name: &str) -> OperationResult {
    OperationResult {
        operation: name.into(),
        accepted: true,
        detail:
            "Desired state persisted; reconciliation completed or will retry with bounded backoff."
                .into(),
    }
}

fn unix_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

fn required<'a>(values: &'a BTreeMap<String, String>, key: &str) -> Result<&'a str, BridgeError> {
    values
        .get(key)
        .map(String::as_str)
        .ok_or_else(|| config_error(format!("missing key '{key}'")))
}

fn validate_sid(value: &str) -> Result<(), BridgeError> {
    if value.starts_with("S-1-")
        && value.len() <= 184
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'S' | b'-'))
    {
        Ok(())
    } else {
        Err(config_error("owner_sid must be a canonical SID string"))
    }
}

fn canonical_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
}

fn hex_id(value: &str, key: &str) -> Result<u16, BridgeError> {
    let digits = value.strip_prefix("0x").unwrap_or(value);
    if digits.len() != 4 {
        return Err(config_error(format!(
            "{key} must be four hexadecimal digits"
        )));
    }
    u16::from_str_radix(digits, 16).map_err(|_| config_error(format!("{key} is invalid")))
}

fn config_error(detail: impl Into<String>) -> BridgeError {
    BridgeError::PermissionDenied {
        operation: format!("reading M6 configuration: {}", detail.into()),
        action: "Use the documented owner-protected M6 schema and exact accepted identities."
            .into(),
    }
}

fn state_io_error(error: io::Error) -> BridgeError {
    BridgeError::PermissionDenied {
        operation: "persisting owner-protected M6 state".into(),
        action: format!("Verify the PrintBridge data directory ACL and free space ({error})."),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Arc, Mutex};

    use super::*;
    use printbridge_ipc::CommandResult;

    static TEST_COUNTER: AtomicU64 = AtomicU64::new(1);

    const CONFIG: &str = "schema=printbridge.m6.config.v1\n\
owner_sid=S-1-5-21-111-222-333-1001\n\
vm_uuid=00000000-0000-0000-0000-000000000004\n\
vm_marker=accepted-m4-owner\n\
vm_schema=printbridge.m4.acceptance-vm.v1\n\
usb_vendor_id=04f9\n\
usb_product_id=0567\n\
usb_serial=secret-never-render\n\
printer_name=Brother via PrintBridge\n\
endpoint_port=8644\n\
guest_queue=PrintBridge_DCP_L2600D\n";

    #[derive(Clone)]
    struct FakeBackend {
        calls: Arc<Mutex<Vec<String>>>,
        components: AgentComponents,
    }

    impl ReconcileBackend for FakeBackend {
        fn observe(
            &mut self,
            _config: &M6Config,
            desired: DesiredState,
            repair: bool,
        ) -> Observation {
            self.calls
                .lock()
                .expect("calls")
                .push(format!("observe:{}:{repair}", desired.as_str()));
            Observation {
                components: if desired == DesiredState::Stopped {
                    AgentComponents {
                        hypervisor: ready("ok"),
                        guest: stopped("stopped"),
                        usb: stopped("stopped"),
                        cups: stopped("stopped"),
                        windows_queue: ready("ok"),
                    }
                } else {
                    self.components.clone()
                },
                startup: StartupStatus {
                    registered: true,
                    task_name: TASK_NAME.into(),
                    logoff_behavior: "test".into(),
                },
            }
        }

        fn discover_devices(&self, config: &M6Config) -> Result<Vec<DeviceSummary>, BridgeError> {
            Ok(vec![DeviceSummary {
                index: 1,
                vendor_id: format!("{:04x}", config.usb.vendor_id),
                product_id: format!("{:04x}", config.usb.product_id),
                display_name: "Brother".into(),
                serial_present: true,
                selected: true,
            }])
        }

        fn begin_setup(
            &mut self,
            _config: &M6Config,
            device_index: usize,
        ) -> Result<(), BridgeError> {
            self.calls
                .lock()
                .expect("calls")
                .push(format!("setup:{device_index}"));
            Ok(())
        }

        fn test_print(&mut self, _config: &M6Config) -> Result<TestPrintResult, BridgeError> {
            self.calls.lock().expect("calls").push("print".into());
            Ok(TestPrintResult {
                correlation_id: "test".into(),
                spooler_job_id: Some(1),
                windows_spooler: "accepted".into(),
                cups_processing: "not_inferred".into(),
                physical_output: "requires_owner_confirmation".into(),
            })
        }
    }

    fn temporary_directory() -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "printbridge-m6-test-{}-{}",
            std::process::id(),
            TEST_COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).expect("temp");
        path
    }

    fn supervisor() -> (Supervisor<FakeBackend>, Arc<Mutex<Vec<String>>>, PathBuf) {
        let config = M6Config::parse(CONFIG).expect("config");
        let calls = Arc::new(Mutex::new(Vec::new()));
        let root = temporary_directory();
        let backend = FakeBackend {
            calls: Arc::clone(&calls),
            components: AgentComponents {
                hypervisor: ready("ok"),
                guest: ready("ok"),
                usb: ready("ok"),
                cups: ready("ok"),
                windows_queue: ready("ok"),
            },
        };
        let supervisor = Supervisor::new(
            config,
            root.join("state"),
            root.join("agent.jsonl"),
            "test-pipe".into(),
            backend,
        )
        .expect("supervisor");
        (supervisor, calls, root)
    }

    #[test]
    fn parses_exact_config_and_debug_redacts_usb_serial() {
        let config = M6Config::parse(CONFIG).expect("config");
        assert_eq!(config.endpoint.port(), 8644);
        assert!(!format!("{:?}", config.usb).contains("secret-never-render"));
        assert!(M6Config::parse(&format!("{CONFIG}unknown=value\n")).is_err());
    }

    #[test]
    fn desired_state_is_persisted_as_immutable_generations() {
        let (mut supervisor, _, root) = supervisor();
        let response = supervisor.handle(RequestEnvelope::new("stop-1", Command::Stop));
        assert!(matches!(response.result, CommandResult::Ok { .. }));
        assert!(root.join("state/state-00000000000000000000.json").is_file());
        assert!(root.join("state/state-00000000000000000001.json").is_file());
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn repeated_request_id_does_not_duplicate_test_print() {
        let (mut supervisor, calls, root) = supervisor();
        let request = RequestEnvelope::new("same-request", Command::TestPrint);
        let first = supervisor.handle(request.clone());
        let second = supervisor.handle(request);
        assert_eq!(first, second);
        assert_eq!(
            calls
                .lock()
                .expect("calls")
                .iter()
                .filter(|call| *call == "print")
                .count(),
            1
        );
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn backoff_is_bounded_and_status_is_truthful() {
        let (mut supervisor, _, root) = supervisor();
        supervisor.backend.components.usb = waiting("unplugged");
        for _ in 0..20 {
            supervisor.reconcile(false);
        }
        assert_eq!(supervisor.status.overall, "waiting_for_usb");
        assert!(supervisor.status.retry_after_ms <= Some(MAX_BACKOFF.as_millis() as u64));
        fs::remove_dir_all(root).expect("cleanup");
    }
}
