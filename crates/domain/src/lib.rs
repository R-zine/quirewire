//! Framework-free PrintBridge domain contracts.

mod doctor;
mod error;
mod model;
mod providers;
mod status;

pub use doctor::{CheckState, DoctorCheck, DoctorReport};
pub use error::{BridgeError, ErrorKind};
pub use model::{
    DependencyInfo, DiagnosticEntry, JobId, JobState, OwnedVm, OwnershipMarker, PrintJob,
    PrintQueue, PrinterEndpoint, StartupRegistration, UsbDevice, UsbIdentity, VmId,
    WindowsPrintSubmission, WindowsQueueStatus,
};
pub use providers::{GuestPrinting, Hypervisor, Platform, Startup, UsbAccess, WindowsPrinting};
pub use status::{BridgePhase, BridgeStatus, ComponentState, ComponentStatus, Components};
