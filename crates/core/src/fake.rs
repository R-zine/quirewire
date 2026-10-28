use std::collections::BTreeMap;
use std::path::Path;

use printbridge_domain::{
    BridgeError, ComponentState, ComponentStatus, DependencyInfo, DiagnosticEntry, GuestPrinting,
    Hypervisor, JobId, JobState, OwnedVm, OwnershipMarker, PrintJob, PrintQueue, PrinterEndpoint,
    Startup, StartupRegistration, UsbAccess, UsbDevice, UsbIdentity, VmId, WindowsPrinting,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum FakeOperation {
    HypervisorDetect,
    UsbStatus,
    IppProbe,
    WindowsIppSupport,
    StartupVerify,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FakeAction {
    Imported,
    StartedHeadless,
    StoppedGracefully,
    DeletedOwnedVm,
    UsbCaptured,
    UsbReleased,
    TestPageSubmitted(JobId),
    WindowsQueueRegistered(String),
    WindowsQueueRemoved(String),
    LoginStartEnabled,
    LoginStartDisabled,
}

/// Stateful in-memory implementation used only by M2 tests and CLI commands.
#[derive(Debug, Clone)]
pub struct FakePlatform {
    vm: OwnedVm,
    selected_usb: UsbIdentity,
    endpoint: PrinterEndpoint,
    hypervisor: ComponentStatus,
    guest: ComponentStatus,
    usb: ComponentStatus,
    cups: ComponentStatus,
    windows: ComponentStatus,
    vm_exists: bool,
    devices: Vec<UsbDevice>,
    guest_queues: Vec<PrintQueue>,
    owned_windows_queues: Vec<PrintQueue>,
    jobs: Vec<PrintJob>,
    startup_enabled: bool,
    actions: Vec<FakeAction>,
    errors: BTreeMap<FakeOperation, BridgeError>,
}

impl FakePlatform {
    #[must_use]
    pub fn ready() -> Self {
        let vm = OwnedVm {
            id: VmId::new("00000000-0000-0000-0000-000000000002"),
            marker: OwnershipMarker::new("printbridge.m2.fake-owned-vm.v1"),
        };
        let selected_usb = UsbIdentity {
            vendor_id: 0x04f9,
            product_id: 0x0567,
            serial: Some("fake-sensitive-serial".into()),
        };
        Self {
            vm,
            selected_usb: selected_usb.clone(),
            endpoint: PrinterEndpoint::m2_fake(),
            hypervisor: ready_status(),
            guest: ready_status(),
            usb: ready_status(),
            cups: ready_status(),
            windows: ready_status(),
            vm_exists: true,
            devices: vec![UsbDevice {
                identity: selected_usb,
                display_name: "Fake Brother printer".into(),
            }],
            guest_queues: vec![PrintQueue {
                name: "DCPL2600D".into(),
                driver: "Fake Linux driver".into(),
            }],
            owned_windows_queues: vec![PrintQueue {
                name: "Brother via PrintBridge (fake)".into(),
                driver: "Microsoft IPP Class Driver".into(),
            }],
            jobs: Vec::new(),
            startup_enabled: true,
            actions: Vec::new(),
            errors: BTreeMap::new(),
        }
    }

    #[must_use]
    pub fn selection(&self) -> (OwnedVm, UsbIdentity, PrinterEndpoint) {
        (
            self.vm.clone(),
            self.selected_usb.clone(),
            self.endpoint.clone(),
        )
    }

    pub fn set_error(&mut self, operation: FakeOperation, error: BridgeError) {
        self.errors.insert(operation, error);
    }

    #[must_use]
    pub fn actions(&self) -> &[FakeAction] {
        &self.actions
    }

    fn configured_error(&self, operation: FakeOperation) -> Option<BridgeError> {
        self.errors.get(&operation).cloned()
    }

    fn ensure_owned_vm(&self, vm: &OwnedVm) -> Result<(), BridgeError> {
        if self.vm_exists && vm == &self.vm {
            Ok(())
        } else {
            Err(BridgeError::PermissionDenied {
                operation: "accessing a VM not proven to be PrintBridge-owned".into(),
                action: "Select the persisted owned VM UUID and marker.".into(),
            })
        }
    }

    fn ensure_selected_usb(&self, device: &UsbIdentity) -> Result<(), BridgeError> {
        if device == &self.selected_usb {
            Ok(())
        } else {
            Err(BridgeError::PrinterMissing {
                printer: device.to_string(),
                action: "Select the configured VID:PID and serial.".into(),
            })
        }
    }
}

impl Hypervisor for FakePlatform {
    fn detect(&self) -> Result<DependencyInfo, BridgeError> {
        if let Some(error) = self.configured_error(FakeOperation::HypervisorDetect) {
            return Err(error);
        }
        Ok(DependencyInfo {
            name: "Fake Hypervisor".into(),
            version: "m2".into(),
        })
    }

    fn import(
        &mut self,
        _appliance: &Path,
        marker: OwnershipMarker,
    ) -> Result<OwnedVm, BridgeError> {
        self.vm = OwnedVm {
            id: VmId::new("00000000-0000-0000-0000-000000000002"),
            marker,
        };
        self.vm_exists = true;
        self.hypervisor = ready_status();
        self.actions.push(FakeAction::Imported);
        Ok(self.vm.clone())
    }

    fn start_headless(&mut self, vm: &OwnedVm) -> Result<(), BridgeError> {
        self.ensure_owned_vm(vm)?;
        self.hypervisor = ready_status();
        self.guest = ready_status();
        self.actions.push(FakeAction::StartedHeadless);
        Ok(())
    }

    fn stop_gracefully(&mut self, vm: &OwnedVm) -> Result<(), BridgeError> {
        self.ensure_owned_vm(vm)?;
        self.guest = ComponentStatus::new(ComponentState::Stopped);
        self.actions.push(FakeAction::StoppedGracefully);
        Ok(())
    }

    fn hypervisor_state(&self) -> Result<ComponentStatus, BridgeError> {
        Ok(self.hypervisor.clone())
    }

    fn guest_state(&self, vm: &OwnedVm) -> Result<ComponentStatus, BridgeError> {
        self.ensure_owned_vm(vm)?;
        Ok(self.guest.clone())
    }

    fn delete_owned_vm(&mut self, vm: OwnedVm) -> Result<(), BridgeError> {
        self.ensure_owned_vm(&vm)?;
        self.vm_exists = false;
        self.hypervisor = ComponentStatus::new(ComponentState::NotConfigured);
        self.guest = ComponentStatus::new(ComponentState::NotConfigured);
        self.actions.push(FakeAction::DeletedOwnedVm);
        Ok(())
    }
}

impl UsbAccess for FakePlatform {
    fn list_devices(&self) -> Result<Vec<UsbDevice>, BridgeError> {
        Ok(self.devices.clone())
    }

    fn capture_selected(&mut self, vm: &OwnedVm, device: &UsbIdentity) -> Result<(), BridgeError> {
        self.ensure_owned_vm(vm)?;
        self.ensure_selected_usb(device)?;
        self.usb = ready_status();
        self.actions.push(FakeAction::UsbCaptured);
        Ok(())
    }

    fn release_selected(&mut self, vm: &OwnedVm, device: &UsbIdentity) -> Result<(), BridgeError> {
        self.ensure_owned_vm(vm)?;
        self.ensure_selected_usb(device)?;
        self.usb = ComponentStatus::new(ComponentState::Waiting);
        self.actions.push(FakeAction::UsbReleased);
        Ok(())
    }

    fn attachment_status(
        &self,
        vm: &OwnedVm,
        device: &UsbIdentity,
    ) -> Result<ComponentStatus, BridgeError> {
        if let Some(error) = self.configured_error(FakeOperation::UsbStatus) {
            return Err(error);
        }
        self.ensure_owned_vm(vm)?;
        self.ensure_selected_usb(device)?;
        Ok(self.usb.clone())
    }
}

impl GuestPrinting for FakePlatform {
    fn probe_ipp(&self, endpoint: &PrinterEndpoint) -> Result<(), BridgeError> {
        if let Some(error) = self.configured_error(FakeOperation::IppProbe) {
            return Err(error);
        }
        if endpoint == &self.endpoint && self.cups.state == ComponentState::Ready {
            Ok(())
        } else {
            Err(BridgeError::IppNegotiationFailed {
                endpoint: format!("{}:{}", endpoint.host(), endpoint.port()),
                action: "Verify the fake endpoint fixture.".into(),
            })
        }
    }

    fn list_queues(&self) -> Result<Vec<PrintQueue>, BridgeError> {
        Ok(self.guest_queues.clone())
    }

    fn queue_status(&self, queue: &str) -> Result<ComponentStatus, BridgeError> {
        if self.guest_queues.iter().any(|item| item.name == queue) {
            Ok(self.cups.clone())
        } else {
            Err(BridgeError::PrinterMissing {
                printer: queue.into(),
                action: "Select a queue returned by list_queues.".into(),
            })
        }
    }

    fn submit_test_page(&mut self, queue: &str) -> Result<PrintJob, BridgeError> {
        self.queue_status(queue)?;
        let id = JobId(
            u64::try_from(self.jobs.len())
                .unwrap_or(u64::MAX)
                .saturating_add(1),
        );
        let job = PrintJob {
            id,
            state: JobState::CompletedByCups,
            physical_confirmation_source: None,
        };
        self.jobs.push(job.clone());
        self.actions.push(FakeAction::TestPageSubmitted(id));
        Ok(job)
    }

    fn jobs(&self, queue: &str) -> Result<Vec<PrintJob>, BridgeError> {
        self.queue_status(queue)?;
        Ok(self.jobs.clone())
    }

    fn diagnostics(&self) -> Result<Vec<DiagnosticEntry>, BridgeError> {
        Ok(vec![
            DiagnosticEntry {
                name: "provider".into(),
                value: "fake-in-memory".into(),
                sensitive: false,
            },
            DiagnosticEntry {
                name: "usb_serial".into(),
                value: "[REDACTED]".into(),
                sensitive: true,
            },
        ])
    }
}

impl WindowsPrinting for FakePlatform {
    fn detect_ipp_support(&self) -> Result<DependencyInfo, BridgeError> {
        if let Some(error) = self.configured_error(FakeOperation::WindowsIppSupport) {
            return Err(error);
        }
        Ok(DependencyInfo {
            name: "Fake Microsoft IPP Class Driver".into(),
            version: "m2".into(),
        })
    }

    fn register_owned_queue(
        &mut self,
        name: &str,
        endpoint: &PrinterEndpoint,
    ) -> Result<PrintQueue, BridgeError> {
        if endpoint != &self.endpoint {
            return Err(BridgeError::IppNegotiationFailed {
                endpoint: format!("{}:{}", endpoint.host(), endpoint.port()),
                action: "Use the configured fake endpoint.".into(),
            });
        }
        if !name.starts_with("Brother via PrintBridge") {
            return Err(BridgeError::PermissionDenied {
                operation: "registering an unowned queue name".into(),
                action: "Use the PrintBridge-owned name prefix.".into(),
            });
        }
        if let Some(existing) = self
            .owned_windows_queues
            .iter()
            .find(|queue| queue.name == name)
        {
            return Ok(existing.clone());
        }
        let queue = PrintQueue {
            name: name.into(),
            driver: "Microsoft IPP Class Driver".into(),
        };
        self.owned_windows_queues.push(queue.clone());
        self.windows = ready_status();
        self.actions
            .push(FakeAction::WindowsQueueRegistered(name.into()));
        Ok(queue)
    }

    fn list_owned_queues(&self) -> Result<Vec<PrintQueue>, BridgeError> {
        Ok(self.owned_windows_queues.clone())
    }

    fn remove_owned_queue(&mut self, name: &str) -> Result<(), BridgeError> {
        let Some(index) = self
            .owned_windows_queues
            .iter()
            .position(|queue| queue.name == name)
        else {
            return Err(BridgeError::PermissionDenied {
                operation: "removing a queue without a fake ownership record".into(),
                action: "Remove only a queue returned by list_owned_queues.".into(),
            });
        };
        self.owned_windows_queues.remove(index);
        self.actions
            .push(FakeAction::WindowsQueueRemoved(name.into()));
        Ok(())
    }

    fn verify_driver(&self, name: &str) -> Result<(), BridgeError> {
        let Some(queue) = self
            .owned_windows_queues
            .iter()
            .find(|queue| queue.name == name)
        else {
            return Err(BridgeError::PrinterMissing {
                printer: name.into(),
                action: "Register the owned queue.".into(),
            });
        };
        if queue.driver == "Microsoft IPP Class Driver" {
            Ok(())
        } else {
            Err(BridgeError::UnsupportedDriver {
                observed: queue.driver.clone(),
                expected: "Microsoft IPP Class Driver".into(),
            })
        }
    }

    fn windows_queue_status(&self) -> Result<ComponentStatus, BridgeError> {
        Ok(self.windows.clone())
    }
}

impl Startup for FakePlatform {
    fn enable_login_start(&mut self) -> Result<(), BridgeError> {
        self.startup_enabled = true;
        self.actions.push(FakeAction::LoginStartEnabled);
        Ok(())
    }

    fn disable_login_start(&mut self) -> Result<(), BridgeError> {
        self.startup_enabled = false;
        self.actions.push(FakeAction::LoginStartDisabled);
        Ok(())
    }

    fn verify_registration(&self) -> Result<StartupRegistration, BridgeError> {
        if let Some(error) = self.configured_error(FakeOperation::StartupVerify) {
            return Err(error);
        }
        Ok(StartupRegistration {
            enabled: self.startup_enabled,
            owner: "printbridge.m2.fake".into(),
        })
    }
}

const fn ready_status() -> ComponentStatus {
    ComponentStatus::new(ComponentState::Ready)
}

#[cfg(test)]
mod tests {
    use printbridge_domain::{GuestPrinting, JobState};

    use super::FakePlatform;

    #[test]
    fn fake_test_page_never_claims_physical_output() {
        let mut fake = FakePlatform::ready();
        let job = fake
            .submit_test_page("DCPL2600D")
            .expect("fake queue exists");
        assert_eq!(job.state, JobState::CompletedByCups);
        assert!(job.physical_confirmation_source.is_none());
    }
}
