//! Real VirtualBox CLI provider for M3.
//!
//! Every command is executed directly with an argument vector and a bounded
//! timeout. VM mutation requires an exact UUID plus matching live ownership
//! metadata. No display-name enumeration is used for lifecycle operations.

mod parser;
mod runner;

use std::env;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use printbridge_domain::{
    BridgeError, ComponentState, ComponentStatus, DependencyInfo, Hypervisor, OwnedVm,
    OwnershipMarker, UsbAccess, UsbDevice, UsbIdentity, VmId,
};

pub use parser::{HostUsbDevice, HostUsbState, VBoxVersion, VmPowerState};
pub use runner::{CommandOutput, CommandRunner, ProcessRunner};

use crate::parser::{
    VmUsbFilter, parse_attached_usb_uuids, parse_machine_readable, parse_usb_host,
    parse_vm_usb_filters,
};

pub const OWNERSHIP_SCHEMA_KEY: &str = "PrintBridge/Schema";
pub const OWNERSHIP_SCHEMA_VALUE: &str = "printbridge.m3.owned-vm.v1";
pub const OWNERSHIP_MARKER_KEY: &str = "PrintBridge/Owner";

#[derive(Debug, Clone)]
pub struct VirtualBoxConfig {
    pub executable: PathBuf,
    pub command_timeout: Duration,
    pub import_timeout: Duration,
    pub shutdown_timeout: Duration,
}

impl VirtualBoxConfig {
    #[must_use]
    pub fn new(executable: impl Into<PathBuf>) -> Self {
        Self {
            executable: executable.into(),
            command_timeout: Duration::from_secs(15),
            import_timeout: Duration::from_secs(15 * 60),
            shutdown_timeout: Duration::from_secs(60),
        }
    }
}

pub struct VirtualBoxProvider<R = ProcessRunner> {
    runner: R,
    config: VirtualBoxConfig,
}

impl VirtualBoxProvider<ProcessRunner> {
    pub fn discover() -> Result<Self, BridgeError> {
        let mut candidates = Vec::new();
        if let Some(configured) = env::var_os("PRINTBRIDGE_VBOXMANAGE") {
            candidates.push(PathBuf::from(configured));
        }
        if let Some(program_files) = env::var_os("ProgramFiles") {
            candidates.push(PathBuf::from(program_files).join("Oracle/VirtualBox/VBoxManage.exe"));
        }
        candidates.push(PathBuf::from("VBoxManage.exe"));

        let mut last_error = None;
        for executable in candidates {
            let provider = Self::new(VirtualBoxConfig::new(executable));
            match provider.version() {
                Ok(version) if version.supported() => return Ok(provider),
                Ok(version) => {
                    return Err(BridgeError::MissingDependency {
                        dependency: "supported VirtualBox 7.1 or 7.2".into(),
                        action: format!(
                            "Detected {}.{}.{}; install a supported release.",
                            version.major, version.minor, version.patch
                        ),
                    });
                }
                Err(error) => last_error = Some(error),
            }
        }
        Err(
            last_error.unwrap_or_else(|| BridgeError::MissingDependency {
                dependency: "VBoxManage".into(),
                action: "Install supported VirtualBox 7.1 or 7.2.".into(),
            }),
        )
    }

    #[must_use]
    pub fn new(config: VirtualBoxConfig) -> Self {
        Self {
            runner: ProcessRunner,
            config,
        }
    }
}

impl<R: CommandRunner> VirtualBoxProvider<R> {
    #[must_use]
    pub const fn with_runner(config: VirtualBoxConfig, runner: R) -> Self {
        Self { runner, config }
    }

    pub fn version(&self) -> Result<VBoxVersion, BridgeError> {
        let output = self.execute(
            ["--version"],
            self.config.command_timeout,
            "detecting VirtualBox",
        )?;
        VBoxVersion::parse(&output.stdout)
    }

    pub fn list_host_usb(&self) -> Result<Vec<HostUsbDevice>, BridgeError> {
        let output = self.execute(
            ["list", "usbhost"],
            self.config.command_timeout,
            "listing host USB devices",
        )?;
        parse_usb_host(&normalize_newlines(&output.stdout))
    }

    fn host_info(&self) -> Result<std::collections::BTreeMap<String, String>, BridgeError> {
        let output = self.execute(
            ["list", "hostinfo"],
            self.config.command_timeout,
            "validating virtualization prerequisites",
        )?;
        Ok(parse_host_info(&normalize_newlines(&output.stdout)))
    }

    pub fn vm_power_state(&self, vm: &OwnedVm) -> Result<VmPowerState, BridgeError> {
        let machine = self.ensure_owned(vm)?;
        Ok(machine
            .get("VMState")
            .map_or(VmPowerState::Unknown, |value| VmPowerState::parse(value)))
    }

    pub fn ensure_owned(
        &self,
        vm: &OwnedVm,
    ) -> Result<std::collections::BTreeMap<String, String>, BridgeError> {
        validate_uuid(vm.id.as_str())?;
        let machine = self.machine_info(vm.id.as_str())?;
        if machine
            .get("UUID")
            .is_none_or(|uuid| !uuid.eq_ignore_ascii_case(vm.id.as_str()))
        {
            return Err(ownership_error(
                "live VM UUID does not match the requested UUID",
            ));
        }
        let schema = self.extra_data(vm.id.as_str(), OWNERSHIP_SCHEMA_KEY)?;
        let marker = self.extra_data(vm.id.as_str(), OWNERSHIP_MARKER_KEY)?;
        if schema.as_deref() != Some(OWNERSHIP_SCHEMA_VALUE)
            || marker.as_deref() != Some(vm.marker.as_str())
        {
            return Err(ownership_error("live VM ownership metadata does not match"));
        }
        Ok(machine)
    }

    fn machine_info(
        &self,
        id_or_name: &str,
    ) -> Result<std::collections::BTreeMap<String, String>, BridgeError> {
        let output = self.execute(
            [
                OsStr::new("showvminfo"),
                OsStr::new(id_or_name),
                OsStr::new("--machinereadable"),
            ],
            self.config.command_timeout,
            "reading VM state",
        )?;
        Ok(parse_machine_readable(&normalize_newlines(&output.stdout)))
    }

    fn machine_info_optional(
        &self,
        id_or_name: &str,
    ) -> Result<Option<std::collections::BTreeMap<String, String>>, BridgeError> {
        let output = self.run_raw(
            [
                OsStr::new("showvminfo"),
                OsStr::new(id_or_name),
                OsStr::new("--machinereadable"),
            ],
            self.config.command_timeout,
        )?;
        if output.exit_code == Some(0) {
            return Ok(Some(parse_machine_readable(&normalize_newlines(
                &output.stdout,
            ))));
        }
        let combined = format!("{} {}", output.stdout, output.stderr).to_ascii_lowercase();
        if combined.contains("could not find") || combined.contains("not find a registered machine")
        {
            Ok(None)
        } else {
            Err(map_command_failure("reading VM state", &output))
        }
    }

    fn machine_text(&self, vm: &OwnedVm) -> Result<String, BridgeError> {
        self.ensure_owned(vm)?;
        let output = self.execute(
            [OsStr::new("showvminfo"), OsStr::new(vm.id.as_str())],
            self.config.command_timeout,
            "reading attached USB devices",
        )?;
        Ok(normalize_newlines(&output.stdout))
    }

    fn attached_usb_uuids(&self, vm: &OwnedVm) -> Result<Vec<String>, BridgeError> {
        Ok(parse_attached_usb_uuids(&self.machine_text(vm)?))
    }

    fn extra_data(&self, vm_uuid: &str, key: &str) -> Result<Option<String>, BridgeError> {
        let output = self.execute(
            [
                OsStr::new("getextradata"),
                OsStr::new(vm_uuid),
                OsStr::new(key),
            ],
            self.config.command_timeout,
            "reading VM ownership metadata",
        )?;
        let value = output.stdout.trim();
        if value.eq_ignore_ascii_case("No value set!") {
            return Ok(None);
        }
        Ok(value
            .strip_prefix("Value:")
            .map(str::trim)
            .map(str::to_string))
    }

    fn set_extra_data(&self, vm_uuid: &str, key: &str, value: &str) -> Result<(), BridgeError> {
        self.execute(
            [
                OsStr::new("setextradata"),
                OsStr::new(vm_uuid),
                OsStr::new(key),
                OsStr::new(value),
            ],
            self.config.command_timeout,
            "writing VM ownership metadata",
        )?;
        Ok(())
    }

    fn vm_filters(&self, vm: &OwnedVm) -> Result<Vec<VmUsbFilter>, BridgeError> {
        Ok(parse_vm_usb_filters(&self.ensure_owned(vm)?))
    }

    fn ensure_filter(&self, vm: &OwnedVm, selected: &UsbIdentity) -> Result<(), BridgeError> {
        let name = filter_name(vm.marker.as_str());
        let filters = self.vm_filters(vm)?;
        if let Some(existing) = filters.iter().find(|filter| filter.name == name) {
            if filter_matches(existing, selected) {
                return Ok(());
            }
            return Err(ownership_error(
                "an owned filter name exists with different USB identity",
            ));
        }
        let mut arguments = vec![
            OsString::from("usbfilter"),
            OsString::from("add"),
            OsString::from(filters.len().to_string()),
            OsString::from(format!("--target={}", vm.id.as_str())),
            OsString::from(format!("--name={name}")),
            OsString::from("--active=yes"),
            OsString::from(format!("--vendorid={:04x}", selected.vendor_id)),
            OsString::from(format!("--productid={:04x}", selected.product_id)),
            OsString::from("--remote=no"),
        ];
        if let Some(serial) = &selected.serial {
            arguments.push(OsString::from(format!("--serialnumber={serial}")));
        }
        self.execute(
            arguments,
            self.config.command_timeout,
            "adding owned USB filter",
        )?;
        let verified = self
            .vm_filters(vm)?
            .into_iter()
            .any(|filter| filter.name == name && filter_matches(&filter, selected));
        if !verified {
            return Err(BridgeError::Internal {
                detail: "VirtualBox did not retain the exact owned USB filter".into(),
            });
        }
        Ok(())
    }

    fn remove_filter(&self, vm: &OwnedVm, selected: &UsbIdentity) -> Result<(), BridgeError> {
        let name = filter_name(vm.marker.as_str());
        let filters = self.vm_filters(vm)?;
        let Some(filter) = filters.iter().find(|filter| filter.name == name) else {
            return Ok(());
        };
        if !filter_matches(filter, selected) {
            return Err(ownership_error(
                "owned filter identity changed; refusing removal",
            ));
        }
        self.execute(
            [
                OsString::from("usbfilter"),
                OsString::from("remove"),
                OsString::from(filter.position.to_string()),
                OsString::from(format!("--target={}", vm.id.as_str())),
            ],
            self.config.command_timeout,
            "removing owned USB filter",
        )?;
        Ok(())
    }

    fn execute<I, S>(
        &self,
        arguments: I,
        timeout: Duration,
        operation: &str,
    ) -> Result<CommandOutput, BridgeError>
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        let output = self.run_raw(arguments, timeout)?;
        if output.exit_code == Some(0) {
            Ok(output)
        } else {
            Err(map_command_failure(operation, &output))
        }
    }

    fn run_raw<I, S>(&self, arguments: I, timeout: Duration) -> Result<CommandOutput, BridgeError>
    where
        I: IntoIterator<Item = S>,
        S: Into<OsString>,
    {
        let arguments: Vec<OsString> = arguments.into_iter().map(Into::into).collect();
        self.runner
            .run(&self.config.executable, &arguments, timeout)
    }
}

impl<R: CommandRunner> Hypervisor for VirtualBoxProvider<R> {
    fn detect(&self) -> Result<DependencyInfo, BridgeError> {
        let version = self.version()?;
        if !version.supported() {
            return Err(BridgeError::MissingDependency {
                dependency: "supported VirtualBox 7.1 or 7.2".into(),
                action: format!(
                    "Detected {}.{}.{}; install a supported release.",
                    version.major, version.minor, version.patch
                ),
            });
        }
        Ok(DependencyInfo {
            name: "Oracle VirtualBox".into(),
            version: format!("{}.{}.{}", version.major, version.minor, version.patch),
        })
    }

    fn validate_host_prerequisites(&self) -> Result<(), BridgeError> {
        let info = self.host_info()?;
        let virtualization = info
            .get("Processor supports HW virtualization")
            .map(|value| value.eq_ignore_ascii_case("yes"));
        if virtualization != Some(true) {
            return Err(BridgeError::MissingDependency {
                dependency: "hardware virtualization support".into(),
                action: "Enable Intel VT-x/AMD-V in firmware and verify that VirtualBox can create a VM."
                    .into(),
            });
        }
        let online = info
            .get("Processor online count")
            .and_then(|value| value.parse::<usize>().ok())
            .unwrap_or_default();
        if online == 0 {
            return Err(BridgeError::GuestUnhealthy {
                detail: "VirtualBox reported no online host processors".into(),
                action: "Repair the VirtualBox host installation and retry doctor.".into(),
            });
        }
        Ok(())
    }

    fn import(
        &mut self,
        appliance: &Path,
        marker: OwnershipMarker,
    ) -> Result<OwnedVm, BridgeError> {
        if !appliance.is_file() {
            return Err(BridgeError::MissingDependency {
                dependency: appliance.display().to_string(),
                action: "Provide a readable OVF/OVA appliance path.".into(),
            });
        }
        self.detect()?;
        let name = owned_vm_name(marker.as_str());
        if let Some(existing) = self.machine_info_optional(&name)? {
            let uuid = existing.get("UUID").ok_or_else(|| BridgeError::Internal {
                detail: "existing named VM omitted UUID".into(),
            })?;
            let vm = OwnedVm {
                id: VmId::new(uuid),
                marker,
            };
            self.ensure_owned(&vm)?;
            return Ok(vm);
        }
        self.execute(
            [
                OsString::from("import"),
                appliance.as_os_str().to_os_string(),
                OsString::from("--options=importtovdi"),
                OsString::from("--vsys=0"),
                OsString::from(format!("--vmname={name}")),
            ],
            self.config.import_timeout,
            "importing the owned appliance",
        )?;
        let machine = self.machine_info(&name)?;
        let uuid = machine
            .get("UUID")
            .cloned()
            .ok_or_else(|| BridgeError::Internal {
                detail: "imported VM omitted UUID".into(),
            })?;
        let result = self
            .set_extra_data(&uuid, OWNERSHIP_SCHEMA_KEY, OWNERSHIP_SCHEMA_VALUE)
            .and_then(|()| self.set_extra_data(&uuid, OWNERSHIP_MARKER_KEY, marker.as_str()));
        if let Err(error) = result {
            let _ = self.run_raw(
                [
                    OsStr::new("unregistervm"),
                    OsStr::new(&uuid),
                    OsStr::new("--delete"),
                ],
                self.config.command_timeout,
            );
            return Err(error);
        }
        let vm = OwnedVm {
            id: VmId::new(uuid),
            marker,
        };
        self.ensure_owned(&vm)?;
        Ok(vm)
    }

    fn start_headless(&mut self, vm: &OwnedVm) -> Result<(), BridgeError> {
        match self.vm_power_state(vm)? {
            VmPowerState::Running => return Ok(()),
            VmPowerState::PoweredOff | VmPowerState::Saved | VmPowerState::Aborted => {}
            state => {
                return Err(BridgeError::GuestUnhealthy {
                    detail: format!("VM cannot start from state {state:?}"),
                    action: "Wait for the current transition or repair the owned VM.".into(),
                });
            }
        }
        self.execute(
            [
                OsStr::new("startvm"),
                OsStr::new(vm.id.as_str()),
                OsStr::new("--type"),
                OsStr::new("headless"),
            ],
            self.config.command_timeout,
            "starting the owned VM headlessly",
        )?;
        if self.vm_power_state(vm)? != VmPowerState::Running {
            return Err(BridgeError::GuestUnhealthy {
                detail: "VirtualBox returned success but VM is not running".into(),
                action: "Inspect the owned VM log.".into(),
            });
        }
        Ok(())
    }

    fn stop_gracefully(&mut self, vm: &OwnedVm) -> Result<(), BridgeError> {
        match self.vm_power_state(vm)? {
            VmPowerState::PoweredOff => return Ok(()),
            VmPowerState::Running => {}
            state => {
                return Err(BridgeError::GuestUnhealthy {
                    detail: format!("VM cannot receive ACPI shutdown from state {state:?}"),
                    action: "Resume or repair the owned VM before stopping it.".into(),
                });
            }
        }
        self.execute(
            [
                OsStr::new("controlvm"),
                OsStr::new(vm.id.as_str()),
                OsStr::new("acpipowerbutton"),
            ],
            self.config.command_timeout,
            "requesting graceful VM shutdown",
        )?;
        let started = Instant::now();
        while started.elapsed() < self.config.shutdown_timeout {
            if self.vm_power_state(vm)? == VmPowerState::PoweredOff {
                return Ok(());
            }
            thread::sleep(Duration::from_millis(250));
        }
        Err(BridgeError::Timeout {
            operation: "waiting for graceful VM shutdown".into(),
            seconds: self.config.shutdown_timeout.as_secs(),
        })
    }

    fn hypervisor_state(&self) -> Result<ComponentStatus, BridgeError> {
        self.detect()?;
        Ok(ComponentStatus::new(ComponentState::Ready))
    }

    fn guest_state(&self, vm: &OwnedVm) -> Result<ComponentStatus, BridgeError> {
        Ok(match self.vm_power_state(vm)? {
            VmPowerState::PoweredOff | VmPowerState::Saved => {
                ComponentStatus::new(ComponentState::Stopped)
            }
            VmPowerState::Running => ComponentStatus::new(ComponentState::Ready),
            VmPowerState::Starting => ComponentStatus::new(ComponentState::Starting),
            VmPowerState::Stopping => ComponentStatus::new(ComponentState::Stopping),
            VmPowerState::Paused => {
                ComponentStatus::with_detail(ComponentState::Degraded, "owned VM is paused")
            }
            VmPowerState::Aborted | VmPowerState::Unknown => {
                ComponentStatus::with_detail(ComponentState::Error, "owned VM state is unhealthy")
            }
        })
    }

    fn delete_owned_vm(&mut self, vm: OwnedVm) -> Result<(), BridgeError> {
        match self.vm_power_state(&vm)? {
            VmPowerState::PoweredOff | VmPowerState::Saved => {}
            state => {
                return Err(BridgeError::PermissionDenied {
                    operation: format!("deleting owned VM while state is {state:?}"),
                    action: "Stop the exact owned VM gracefully first.".into(),
                });
            }
        }
        self.execute(
            [
                OsStr::new("unregistervm"),
                OsStr::new(vm.id.as_str()),
                OsStr::new("--delete"),
            ],
            self.config.import_timeout,
            "deleting the exact owned VM",
        )?;
        Ok(())
    }
}

impl<R: CommandRunner> UsbAccess for VirtualBoxProvider<R> {
    fn list_devices(&self) -> Result<Vec<UsbDevice>, BridgeError> {
        Ok(self
            .list_host_usb()?
            .into_iter()
            .map(|device| UsbDevice {
                identity: device.identity,
                display_name: device.display_name,
                host_id: Some(device.host_uuid),
            })
            .collect())
    }

    fn capture_selected(
        &mut self,
        vm: &OwnedVm,
        selected: &UsbIdentity,
    ) -> Result<(), BridgeError> {
        let device = resolve_usb_device(&self.list_host_usb()?, selected)?.clone();
        self.attach_host_device(vm, &device, true)
    }

    fn capture_selected_host(
        &mut self,
        vm: &OwnedVm,
        selected: &UsbIdentity,
        host_id: &str,
    ) -> Result<(), BridgeError> {
        let devices = self.list_host_usb()?;
        let device = resolve_usb_host_device(&devices, selected, host_id)?.clone();
        let identical_count = devices
            .iter()
            .filter(|candidate| candidate.identity == device.identity)
            .count();
        // A VID:PID-only filter would capture an arbitrary member of a set of
        // identical serial-less devices. The explicit host choice is safe for
        // this session, so attach that host UUID directly without a broad filter.
        let safe_filter = device.identity.serial.is_some() || identical_count == 1;
        self.attach_host_device(vm, &device, safe_filter)
    }

    fn release_selected(
        &mut self,
        vm: &OwnedVm,
        selected: &UsbIdentity,
    ) -> Result<(), BridgeError> {
        self.ensure_owned(vm)?;
        let devices = self.list_host_usb()?;
        let device = match resolve_usb_device(&devices, selected) {
            Ok(device) => Some(device.clone()),
            Err(BridgeError::PrinterMissing { .. }) => None,
            Err(error) => return Err(error),
        };
        if let Some(device) = device {
            if self
                .attached_usb_uuids(vm)?
                .iter()
                .any(|uuid| uuid.eq_ignore_ascii_case(&device.host_uuid))
            {
                self.execute(
                    [
                        OsStr::new("controlvm"),
                        OsStr::new(vm.id.as_str()),
                        OsStr::new("usbdetach"),
                        OsStr::new(&device.host_uuid),
                    ],
                    self.config.command_timeout,
                    "detaching selected USB device",
                )?;
            }
        }
        self.remove_filter(vm, selected)
    }

    fn release_selected_host(
        &mut self,
        vm: &OwnedVm,
        selected: &UsbIdentity,
        host_id: &str,
    ) -> Result<(), BridgeError> {
        self.ensure_owned(vm)?;
        let devices = self.list_host_usb()?;
        let device = resolve_usb_host_device(&devices, selected, host_id)?;
        if self
            .attached_usb_uuids(vm)?
            .iter()
            .any(|uuid| uuid.eq_ignore_ascii_case(&device.host_uuid))
        {
            self.execute(
                [
                    OsStr::new("controlvm"),
                    OsStr::new(vm.id.as_str()),
                    OsStr::new("usbdetach"),
                    OsStr::new(&device.host_uuid),
                ],
                self.config.command_timeout,
                "detaching interactively selected USB device",
            )?;
        }
        self.remove_filter(vm, &device.identity)
    }

    fn attachment_status(
        &self,
        vm: &OwnedVm,
        selected: &UsbIdentity,
    ) -> Result<ComponentStatus, BridgeError> {
        self.ensure_owned(vm)?;
        let devices = self.list_host_usb()?;
        let device = match resolve_usb_device(&devices, selected) {
            Ok(device) => device,
            Err(BridgeError::PrinterMissing { .. }) => {
                return Ok(ComponentStatus::with_detail(
                    ComponentState::Waiting,
                    "selected USB device is absent",
                ));
            }
            Err(error) => return Err(error),
        };
        if self
            .attached_usb_uuids(vm)?
            .iter()
            .any(|uuid| uuid.eq_ignore_ascii_case(&device.host_uuid))
        {
            Ok(ComponentStatus::new(ComponentState::Ready))
        } else if matches!(
            device.state,
            HostUsbState::Captured | HostUsbState::Busy | HostUsbState::Unavailable
        ) {
            Ok(ComponentStatus::with_detail(
                ComponentState::Degraded,
                "selected USB is unavailable or captured by another owner",
            ))
        } else if device.state == HostUsbState::Unknown {
            Ok(ComponentStatus::with_detail(
                ComponentState::Error,
                "VirtualBox reported an unknown selected USB state",
            ))
        } else {
            Ok(ComponentStatus::with_detail(
                ComponentState::Waiting,
                "selected USB is available but not attached",
            ))
        }
    }
}

impl<R: CommandRunner> VirtualBoxProvider<R> {
    fn attach_host_device(
        &self,
        vm: &OwnedVm,
        device: &HostUsbDevice,
        create_filter: bool,
    ) -> Result<(), BridgeError> {
        if self.vm_power_state(vm)? != VmPowerState::Running {
            return Err(BridgeError::GuestUnhealthy {
                detail: "owned VM is not running".into(),
                action: "Start the owned VM headlessly before USB capture.".into(),
            });
        }
        if self
            .attached_usb_uuids(vm)?
            .iter()
            .any(|uuid| uuid.eq_ignore_ascii_case(&device.host_uuid))
        {
            return Ok(());
        }
        if device.state != HostUsbState::Available {
            let exact_filter_installed = create_filter && device.identity.serial.is_some();
            if exact_filter_installed {
                self.ensure_filter(vm, &device.identity)?;
            }
            return Err(BridgeError::UsbBusy {
                device: device.identity.to_string(),
                action: if exact_filter_installed {
                    format!(
                        "VirtualBox reports host state {:?}. An exact serial-matched owned filter is ready; disconnect and reconnect this device, then retry.",
                        device.state
                    )
                } else {
                    format!(
                        "VirtualBox reports host state {:?}; release or reconnect it before retrying.",
                        device.state
                    )
                },
            });
        }
        if create_filter {
            self.ensure_filter(vm, &device.identity)?;
            if self
                .attached_usb_uuids(vm)?
                .iter()
                .any(|uuid| uuid.eq_ignore_ascii_case(&device.host_uuid))
            {
                return Ok(());
            }
        }
        self.execute(
            [
                OsStr::new("controlvm"),
                OsStr::new(vm.id.as_str()),
                OsStr::new("usbattach"),
                OsStr::new(&device.host_uuid),
            ],
            self.config.command_timeout,
            "attaching selected USB device",
        )?;
        if !self
            .attached_usb_uuids(vm)?
            .iter()
            .any(|uuid| uuid.eq_ignore_ascii_case(&device.host_uuid))
        {
            return Err(BridgeError::GuestUnhealthy {
                detail: "VirtualBox did not report the selected USB attachment".into(),
                action: "Inspect host USB ownership and the owned VM log.".into(),
            });
        }
        Ok(())
    }
}

pub fn resolve_usb_device<'a>(
    devices: &'a [HostUsbDevice],
    selected: &UsbIdentity,
) -> Result<&'a HostUsbDevice, BridgeError> {
    let candidates: Vec<&HostUsbDevice> = devices
        .iter()
        .filter(|device| {
            device.identity.vendor_id == selected.vendor_id
                && device.identity.product_id == selected.product_id
        })
        .collect();
    if let Some(serial) = &selected.serial {
        let exact: Vec<&HostUsbDevice> = candidates
            .into_iter()
            .filter(|device| device.identity.serial.as_deref() == Some(serial.as_str()))
            .collect();
        return match exact.as_slice() {
            [device] => Ok(*device),
            [] => Err(missing_usb(selected)),
            _ => Err(ambiguous_usb(selected)),
        };
    }
    match candidates.as_slice() {
        [] => Err(missing_usb(selected)),
        [device] if device.identity.serial.is_none() => Ok(*device),
        _ => Err(ambiguous_usb(selected)),
    }
}

fn resolve_usb_host_device<'a>(
    devices: &'a [HostUsbDevice],
    selected: &UsbIdentity,
    host_id: &str,
) -> Result<&'a HostUsbDevice, BridgeError> {
    devices
        .iter()
        .find(|device| {
            device.host_uuid.eq_ignore_ascii_case(host_id) && &device.identity == selected
        })
        .ok_or_else(|| BridgeError::PrinterMissing {
            printer: selected.to_string(),
            action: "The interactive USB selection changed; run usb list and select it again."
                .into(),
        })
}

fn missing_usb(selected: &UsbIdentity) -> BridgeError {
    BridgeError::PrinterMissing {
        printer: selected.to_string(),
        action: "Connect the selected USB device and run usb list again.".into(),
    }
}

fn ambiguous_usb(selected: &UsbIdentity) -> BridgeError {
    BridgeError::UsbBusy {
        device: selected.to_string(),
        action: "Multiple or serial-bearing matches require an exact persisted serial selection."
            .into(),
    }
}

fn filter_matches(filter: &VmUsbFilter, selected: &UsbIdentity) -> bool {
    filter.active
        && filter.vendor_id == Some(selected.vendor_id)
        && filter.product_id == Some(selected.product_id)
        && filter.serial == selected.serial
        && filter.remote.as_deref() == Some("no")
}

fn filter_name(marker: &str) -> String {
    format!("PrintBridge M3 {:016x}", stable_hash(marker))
}

fn owned_vm_name(marker: &str) -> String {
    format!("PrintBridge-M3-{:016x}", stable_hash(marker))
}

fn stable_hash(value: &str) -> u64 {
    value.bytes().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

fn validate_uuid(value: &str) -> Result<(), BridgeError> {
    let valid = value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        });
    if valid {
        Ok(())
    } else {
        Err(ownership_error("VM identity is not a canonical UUID"))
    }
}

fn ownership_error(detail: &str) -> BridgeError {
    BridgeError::PermissionDenied {
        operation: detail.into(),
        action: "Refusing to manage a VM that is not proven PrintBridge-owned.".into(),
    }
}

fn normalize_newlines(value: &str) -> String {
    value.replace("\r\n", "\n")
}

fn parse_host_info(value: &str) -> std::collections::BTreeMap<String, String> {
    value
        .lines()
        .filter_map(|line| {
            let (key, value) = line.split_once(':')?;
            Some((key.trim().to_string(), value.trim().to_string()))
        })
        .collect()
}

fn map_command_failure(operation: &str, output: &CommandOutput) -> BridgeError {
    let combined = format!("{} {}", output.stdout, output.stderr).to_ascii_lowercase();
    if combined.contains("access denied") || combined.contains("e_accessdenied") {
        return BridgeError::PermissionDenied {
            operation: operation.into(),
            action: "Run under the owning user and verify VirtualBox permissions.".into(),
        };
    }
    if combined.contains("resource busy") || combined.contains("usb device is busy") {
        return BridgeError::UsbBusy {
            device: "selected USB device".into(),
            action: "Release it from the current host or VM owner and retry.".into(),
        };
    }
    BridgeError::Internal {
        detail: format!(
            "VBoxManage failed while {operation} (exit {:?}): {}",
            output.exit_code,
            redacted_command_error(&output.stderr)
        ),
    }
}

fn redacted_command_error(stderr: &str) -> String {
    let first_line = stderr.lines().next().unwrap_or("no stderr");
    if first_line.to_ascii_lowercase().contains("serial") {
        "provider error contained sensitive device data".into()
    } else {
        first_line.chars().take(240).collect()
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;
    use std::fs;
    use std::path::Path;
    use std::sync::Mutex;
    use std::time::Duration;

    use printbridge_domain::{
        BridgeError, Hypervisor, OwnedVm, OwnershipMarker, UsbIdentity, VmId,
    };

    use super::{
        CommandOutput, CommandRunner, HostUsbDevice, HostUsbState, VirtualBoxConfig,
        VirtualBoxProvider, resolve_usb_device,
    };

    struct ScriptedRunner {
        outputs: Mutex<Vec<Result<CommandOutput, BridgeError>>>,
        calls: Mutex<Vec<Vec<OsString>>>,
    }

    impl ScriptedRunner {
        fn new(outputs: Vec<Result<CommandOutput, BridgeError>>) -> Self {
            Self {
                outputs: Mutex::new(outputs.into_iter().rev().collect()),
                calls: Mutex::new(Vec::new()),
            }
        }

        fn calls(&self) -> Vec<Vec<OsString>> {
            self.calls.lock().expect("calls mutex").clone()
        }
    }

    impl CommandRunner for ScriptedRunner {
        fn run(
            &self,
            _executable: &Path,
            arguments: &[OsString],
            _timeout: Duration,
        ) -> Result<CommandOutput, BridgeError> {
            self.calls
                .lock()
                .expect("calls mutex")
                .push(arguments.to_vec());
            self.outputs
                .lock()
                .expect("runner mutex")
                .pop()
                .expect("scripted output")
        }
    }

    fn output(stdout: &str) -> Result<CommandOutput, BridgeError> {
        Ok(CommandOutput {
            exit_code: Some(0),
            stdout: stdout.into(),
            stderr: String::new(),
        })
    }

    fn owned_vm() -> OwnedVm {
        OwnedVm {
            id: VmId::new("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            marker: OwnershipMarker::new("printbridge.m3.test-owned-vm"),
        }
    }

    fn machine(state: &str) -> Result<CommandOutput, BridgeError> {
        output(&format!(
            "UUID=\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\"\nVMState=\"{state}\"\n"
        ))
    }

    fn schema() -> Result<CommandOutput, BridgeError> {
        output("Value: printbridge.m3.owned-vm.v1\n")
    }

    fn marker() -> Result<CommandOutput, BridgeError> {
        output("Value: printbridge.m3.test-owned-vm\n")
    }

    fn failed(stderr: &str) -> Result<CommandOutput, BridgeError> {
        Ok(CommandOutput {
            exit_code: Some(1),
            stdout: String::new(),
            stderr: stderr.into(),
        })
    }

    #[test]
    fn detect_accepts_installed_supported_version() {
        let provider = VirtualBoxProvider::with_runner(
            VirtualBoxConfig::new("VBoxManage.exe"),
            ScriptedRunner::new(vec![output("7.2.22r175245\n")]),
        );
        assert_eq!(
            provider.detect().expect("supported version").version,
            "7.2.22"
        );
    }

    #[test]
    fn detect_rejects_unvalidated_future_major() {
        let provider = VirtualBoxProvider::with_runner(
            VirtualBoxConfig::new("VBoxManage.exe"),
            ScriptedRunner::new(vec![output("8.0.0\n")]),
        );
        assert_eq!(
            provider
                .detect()
                .expect_err("unsupported version")
                .kind()
                .as_str(),
            "missing_dependency"
        );
    }

    #[test]
    fn prerequisites_require_hardware_virtualization() {
        let provider = VirtualBoxProvider::with_runner(
            VirtualBoxConfig::new("VBoxManage.exe"),
            ScriptedRunner::new(vec![output(
                "Processor online count: 20\nProcessor supports HW virtualization: no\n",
            )]),
        );
        assert_eq!(
            provider
                .validate_host_prerequisites()
                .expect_err("virtualization must be available")
                .kind()
                .as_str(),
            "missing_dependency"
        );
    }

    #[test]
    fn repeated_start_is_idempotent_and_uses_exact_headless_uuid() {
        let mut provider = VirtualBoxProvider::with_runner(
            VirtualBoxConfig::new("VBoxManage.exe"),
            ScriptedRunner::new(vec![
                machine("poweroff"),
                schema(),
                marker(),
                output(""),
                machine("running"),
                schema(),
                marker(),
                machine("running"),
                schema(),
                marker(),
            ]),
        );
        let vm = owned_vm();
        provider.start_headless(&vm).expect("first start");
        provider.start_headless(&vm).expect("idempotent start");
        let starts: Vec<Vec<String>> = provider
            .runner
            .calls()
            .into_iter()
            .map(|call| {
                call.into_iter()
                    .map(|part| part.to_string_lossy().into_owned())
                    .collect()
            })
            .filter(|call: &Vec<String>| call.first().is_some_and(|part| part == "startvm"))
            .collect();
        assert_eq!(
            starts,
            [vec![
                "startvm".to_string(),
                "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".to_string(),
                "--type".to_string(),
                "headless".to_string(),
            ]]
        );
    }

    #[test]
    fn repeated_stop_is_idempotent_and_sends_one_acpi_request() {
        let mut provider = VirtualBoxProvider::with_runner(
            VirtualBoxConfig::new("VBoxManage.exe"),
            ScriptedRunner::new(vec![
                machine("running"),
                schema(),
                marker(),
                output(""),
                machine("poweroff"),
                schema(),
                marker(),
                machine("poweroff"),
                schema(),
                marker(),
            ]),
        );
        let vm = owned_vm();
        provider.stop_gracefully(&vm).expect("first stop");
        provider.stop_gracefully(&vm).expect("idempotent stop");
        let acpi_calls: Vec<Vec<String>> = provider
            .runner
            .calls()
            .into_iter()
            .map(|call| {
                call.into_iter()
                    .map(|part| part.to_string_lossy().into_owned())
                    .collect()
            })
            .filter(|call: &Vec<String>| call.first().is_some_and(|part| part == "controlvm"))
            .collect();
        assert_eq!(
            acpi_calls,
            [vec![
                "controlvm".to_string(),
                "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".to_string(),
                "acpipowerbutton".to_string(),
            ]]
        );
    }

    #[test]
    fn import_uses_generated_name_then_persists_live_ownership() {
        let appliance = std::env::temp_dir().join(format!(
            "printbridge-m3-import-test-{}.ova",
            std::process::id()
        ));
        fs::write(&appliance, b"mock appliance").expect("temp appliance");
        let mut provider = VirtualBoxProvider::with_runner(
            VirtualBoxConfig::new("VBoxManage.exe"),
            ScriptedRunner::new(vec![
                output("7.2.22r175245\n"),
                failed("Could not find a registered machine"),
                output(""),
                machine("poweroff"),
                output(""),
                output(""),
                machine("poweroff"),
                schema(),
                marker(),
            ]),
        );
        let vm = provider
            .import(
                &appliance,
                OwnershipMarker::new("printbridge.m3.test-owned-vm"),
            )
            .expect("mock import");
        fs::remove_file(&appliance).expect("remove temp appliance");
        assert_eq!(vm.id.as_str(), "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
        let calls: Vec<Vec<String>> = provider
            .runner
            .calls()
            .into_iter()
            .map(|call| {
                call.into_iter()
                    .map(|part| part.to_string_lossy().into_owned())
                    .collect()
            })
            .collect();
        let import = calls
            .iter()
            .find(|call| call.first().is_some_and(|part| part == "import"))
            .expect("import call");
        assert_eq!(import[1], appliance.to_string_lossy());
        assert!(import.contains(&"--options=importtovdi".to_string()));
        assert!(
            import
                .iter()
                .any(|part| part.starts_with("--vmname=PrintBridge-M3-"))
        );
        assert_eq!(
            calls
                .iter()
                .filter(|call| call.first().is_some_and(|part| part == "setextradata"))
                .count(),
            2
        );
    }

    #[test]
    fn ownership_mismatch_prevents_start_mutation() {
        let mut provider = VirtualBoxProvider::with_runner(
            VirtualBoxConfig::new("VBoxManage.exe"),
            ScriptedRunner::new(vec![
                machine("poweroff"),
                schema(),
                output("Value: someone-else\n"),
            ]),
        );
        let error = provider
            .start_headless(&owned_vm())
            .expect_err("ownership must match live metadata");
        assert_eq!(error.kind().as_str(), "permission_denied");
        assert!(provider.runner.calls().iter().all(|call| {
            call.first()
                .is_none_or(|part| part.to_string_lossy() != "startvm")
        }));
    }

    #[test]
    fn exact_filter_contains_serial_and_preserves_unrelated_filter() {
        let selected = UsbIdentity {
            vendor_id: 0x04f9,
            product_id: 0x0567,
            serial: Some("exact-sensitive-value".into()),
        };
        let owned_name = super::filter_name("printbridge.m3.test-owned-vm");
        let before = "UUID=\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\"\nVMState=\"running\"\nUSBFilterActive1=\"on\"\nUSBFilterName1=\"User filter\"\nUSBFilterVendorId1=\"1234\"\nUSBFilterProductId1=\"5678\"\nUSBFilterRemote1=\"no\"\n";
        let after = format!(
            "{before}USBFilterActive2=\"on\"\nUSBFilterName2=\"{owned_name}\"\nUSBFilterVendorId2=\"04f9\"\nUSBFilterProductId2=\"0567\"\nUSBFilterSerialNumber2=\"exact-sensitive-value\"\nUSBFilterRemote2=\"no\"\n"
        );
        let provider = VirtualBoxProvider::with_runner(
            VirtualBoxConfig::new("VBoxManage.exe"),
            ScriptedRunner::new(vec![
                output(before),
                schema(),
                marker(),
                output(""),
                output(&after),
                schema(),
                marker(),
            ]),
        );
        provider
            .ensure_filter(&owned_vm(), &selected)
            .expect("exact owned filter");
        let calls: Vec<Vec<String>> = provider
            .runner
            .calls()
            .into_iter()
            .map(|call| {
                call.into_iter()
                    .map(|part| part.to_string_lossy().into_owned())
                    .collect()
            })
            .collect();
        let add = calls
            .iter()
            .find(|call| call.first().is_some_and(|part| part == "usbfilter"))
            .expect("filter add call");
        assert_eq!(&add[0..3], ["usbfilter", "add", "1"]);
        assert!(add.contains(&"--vendorid=04f9".to_string()));
        assert!(add.contains(&"--productid=0567".to_string()));
        assert!(add.contains(&"--serialnumber=exact-sensitive-value".to_string()));
        assert!(
            !calls
                .iter()
                .any(|call| call.get(1).is_some_and(|part| part == "remove"))
        );
    }

    #[test]
    fn command_failures_map_permission_busy_and_redact_serial_output() {
        let denied = super::map_command_failure(
            "starting VM",
            &CommandOutput {
                exit_code: Some(1),
                stdout: String::new(),
                stderr: "E_ACCESSDENIED".into(),
            },
        );
        assert_eq!(denied.kind().as_str(), "permission_denied");
        let busy = super::map_command_failure(
            "attaching USB",
            &CommandOutput {
                exit_code: Some(1),
                stdout: String::new(),
                stderr: "USB device is busy".into(),
            },
        );
        assert_eq!(busy.kind().as_str(), "usb_busy");
        let secret = "SERIAL-DO-NOT-LEAK";
        let other = super::map_command_failure(
            "attaching USB",
            &CommandOutput {
                exit_code: Some(1),
                stdout: String::new(),
                stderr: format!("Serial value {secret}"),
            },
        );
        assert!(!other.to_string().contains(secret));
    }

    #[test]
    fn exact_serial_resolves_and_missing_serial_is_ambiguous() {
        let devices = vec![HostUsbDevice {
            host_uuid: "host-uuid".into(),
            identity: UsbIdentity {
                vendor_id: 0x04f9,
                product_id: 0x0567,
                serial: Some("exact".into()),
            },
            display_name: "printer".into(),
            state: HostUsbState::Available,
        }];
        let exact = UsbIdentity {
            vendor_id: 0x04f9,
            product_id: 0x0567,
            serial: Some("exact".into()),
        };
        assert_eq!(
            resolve_usb_device(&devices, &exact)
                .expect("exact match")
                .host_uuid,
            "host-uuid"
        );
        let incomplete = UsbIdentity {
            vendor_id: 0x04f9,
            product_id: 0x0567,
            serial: None,
        };
        assert_eq!(
            resolve_usb_device(&devices, &incomplete)
                .expect_err("serial required")
                .kind()
                .as_str(),
            "usb_busy"
        );
    }
}
