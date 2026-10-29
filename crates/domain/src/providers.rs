use std::path::Path;

use crate::{
    BridgeError, ComponentStatus, DependencyInfo, DiagnosticEntry, OwnedVm, PrintJob, PrintQueue,
    PrinterEndpoint, StartupRegistration, UsbDevice, UsbIdentity, WindowsPrintSubmission,
    WindowsQueueStatus,
};

pub trait Hypervisor {
    fn detect(&self) -> Result<DependencyInfo, BridgeError>;
    fn validate_host_prerequisites(&self) -> Result<(), BridgeError>;
    fn import(
        &mut self,
        appliance: &Path,
        marker: crate::OwnershipMarker,
    ) -> Result<OwnedVm, BridgeError>;
    fn start_headless(&mut self, vm: &OwnedVm) -> Result<(), BridgeError>;
    fn stop_gracefully(&mut self, vm: &OwnedVm) -> Result<(), BridgeError>;
    fn hypervisor_state(&self) -> Result<ComponentStatus, BridgeError>;
    fn guest_state(&self, vm: &OwnedVm) -> Result<ComponentStatus, BridgeError>;
    fn delete_owned_vm(&mut self, vm: OwnedVm) -> Result<(), BridgeError>;
}

pub trait UsbAccess {
    fn list_devices(&self) -> Result<Vec<UsbDevice>, BridgeError>;
    fn capture_selected(&mut self, vm: &OwnedVm, device: &UsbIdentity) -> Result<(), BridgeError>;
    fn capture_selected_host(
        &mut self,
        vm: &OwnedVm,
        device: &UsbIdentity,
        host_id: &str,
    ) -> Result<(), BridgeError>;
    fn release_selected(&mut self, vm: &OwnedVm, device: &UsbIdentity) -> Result<(), BridgeError>;
    fn release_selected_host(
        &mut self,
        vm: &OwnedVm,
        device: &UsbIdentity,
        host_id: &str,
    ) -> Result<(), BridgeError>;
    fn attachment_status(
        &self,
        vm: &OwnedVm,
        device: &UsbIdentity,
    ) -> Result<ComponentStatus, BridgeError>;
}

pub trait GuestPrinting {
    fn probe_ipp(&self, endpoint: &PrinterEndpoint) -> Result<(), BridgeError>;
    fn list_queues(&self) -> Result<Vec<PrintQueue>, BridgeError>;
    fn queue_status(&self, queue: &str) -> Result<ComponentStatus, BridgeError>;
    fn submit_test_page(&mut self, queue: &str) -> Result<PrintJob, BridgeError>;
    fn jobs(&self, queue: &str) -> Result<Vec<PrintJob>, BridgeError>;
    fn diagnostics(&self) -> Result<Vec<DiagnosticEntry>, BridgeError>;
}

pub trait WindowsPrinting {
    fn detect_ipp_support(&self) -> Result<DependencyInfo, BridgeError>;
    fn register_owned_queue(
        &mut self,
        name: &str,
        endpoint: &PrinterEndpoint,
    ) -> Result<PrintQueue, BridgeError>;
    fn list_owned_queues(&self) -> Result<Vec<PrintQueue>, BridgeError>;
    fn remove_owned_queue(&mut self, name: &str) -> Result<(), BridgeError>;
    fn verify_driver(&self, name: &str) -> Result<(), BridgeError>;
    fn windows_queue_status(&self) -> Result<ComponentStatus, BridgeError>;
    fn inspect_owned_queue(&self, name: &str) -> Result<WindowsQueueStatus, BridgeError>;
    fn submit_windows_test_page(
        &mut self,
        name: &str,
    ) -> Result<WindowsPrintSubmission, BridgeError>;
}

pub trait Startup {
    fn enable_login_start(&mut self) -> Result<(), BridgeError>;
    fn disable_login_start(&mut self) -> Result<(), BridgeError>;
    fn verify_registration(&self) -> Result<StartupRegistration, BridgeError>;
}

pub trait Platform: Hypervisor + UsbAccess + GuestPrinting + WindowsPrinting + Startup {}

impl<T> Platform for T where T: Hypervisor + UsbAccess + GuestPrinting + WindowsPrinting + Startup {}
