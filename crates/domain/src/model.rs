use std::fmt;
use std::net::{IpAddr, Ipv4Addr};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DependencyInfo {
    pub name: String,
    pub version: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct VmId(String);

impl VmId {
    #[must_use]
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnershipMarker(String);

impl OwnershipMarker {
    #[must_use]
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnedVm {
    pub id: VmId,
    pub marker: OwnershipMarker,
}

#[derive(Clone, PartialEq, Eq, Hash)]
pub struct UsbIdentity {
    pub vendor_id: u16,
    pub product_id: u16,
    pub serial: Option<String>,
}

impl fmt::Debug for UsbIdentity {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("UsbIdentity")
            .field("vendor_id", &format_args!("{:04x}", self.vendor_id))
            .field("product_id", &format_args!("{:04x}", self.product_id))
            .field("serial", &self.serial.as_ref().map(|_| "[REDACTED]"))
            .finish()
    }
}

impl fmt::Display for UsbIdentity {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{:04x}:{:04x}", self.vendor_id, self.product_id)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsbDevice {
    pub identity: UsbIdentity,
    pub display_name: String,
    /// Provider-scoped, ephemeral host handle used for an explicit interactive
    /// choice when otherwise identical serial-less devices are present.
    pub host_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PrinterEndpoint {
    Loopback {
        port: u16,
        queue: String,
    },
    HostOnly {
        address: IpAddr,
        port: u16,
        queue: String,
    },
}

impl PrinterEndpoint {
    #[must_use]
    pub fn m2_fake() -> Self {
        Self::Loopback {
            port: 8632,
            queue: "DCPL2600D".into(),
        }
    }

    #[must_use]
    pub fn host(&self) -> IpAddr {
        match self {
            Self::Loopback { .. } => IpAddr::V4(Ipv4Addr::LOCALHOST),
            Self::HostOnly { address, .. } => *address,
        }
    }

    #[must_use]
    pub const fn port(&self) -> u16 {
        match self {
            Self::Loopback { port, .. } | Self::HostOnly { port, .. } => *port,
        }
    }

    #[must_use]
    pub fn queue(&self) -> &str {
        match self {
            Self::Loopback { queue, .. } | Self::HostOnly { queue, .. } => queue,
        }
    }

    /// URI passed to Windows directed IPP discovery. Queue names are validated
    /// by the configuration parser before reaching this boundary.
    #[must_use]
    pub fn windows_ipp_url(&self) -> String {
        let host = match self.host() {
            IpAddr::V4(address) => address.to_string(),
            IpAddr::V6(address) => format!("[{address}]"),
        };
        format!("http://{host}:{}/printers/{}", self.port(), self.queue())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScannerEndpoint {
    pub address: IpAddr,
    pub port: u16,
}

impl ScannerEndpoint {
    #[must_use]
    pub const fn loopback(port: u16) -> Self {
        Self {
            address: IpAddr::V4(Ipv4Addr::LOCALHOST),
            port,
        }
    }

    #[must_use]
    pub fn web_url(&self) -> String {
        let host = match self.address {
            IpAddr::V4(address) => address.to_string(),
            IpAddr::V6(address) => format!("[{address}]"),
        };
        format!("http://{host}:{}/", self.port)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScannerCapabilities {
    pub make_model: String,
    pub uuid: Option<String>,
    pub sources: Vec<String>,
    pub duplex: bool,
    pub color_modes: Vec<String>,
    pub document_formats: Vec<String>,
    pub resolutions_dpi: Vec<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrintQueue {
    pub name: String,
    pub driver: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WindowsQueueStatus {
    pub queue: Option<PrintQueue>,
    pub endpoint: String,
    pub port_name: Option<String>,
    pub printer_status: Option<String>,
    pub spooler_running: bool,
    pub ipp_url_supported: bool,
    pub ownership_verified: bool,
    pub is_default: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WindowsPrintSubmission {
    pub correlation_id: String,
    pub spooler_job_id: Option<u32>,
    pub state: JobState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct JobId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobState {
    Accepted,
    CompletedByCups,
    PhysicalOutputConfirmed,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrintJob {
    pub id: JobId,
    pub state: JobState,
    pub physical_confirmation_source: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiagnosticEntry {
    pub name: String,
    pub value: String,
    pub sensitive: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StartupRegistration {
    pub enabled: bool,
    pub owner: String,
}

#[cfg(test)]
mod tests {
    use super::{JobId, JobState, PrintJob, PrinterEndpoint, UsbIdentity};

    #[test]
    fn usb_display_never_includes_serial() {
        let identity = UsbIdentity {
            vendor_id: 0x04f9,
            product_id: 0x0567,
            serial: Some("SECRET".into()),
        };
        assert_eq!(identity.to_string(), "04f9:0567");
        assert!(!identity.to_string().contains("SECRET"));
        assert!(!format!("{identity:?}").contains("SECRET"));
        assert!(format!("{identity:?}").contains("[REDACTED]"));
    }

    #[test]
    fn cups_completion_is_not_physical_confirmation() {
        let job = PrintJob {
            id: JobId(1),
            state: JobState::CompletedByCups,
            physical_confirmation_source: None,
        };
        assert_ne!(job.state, JobState::PhysicalOutputConfirmed);
        assert!(job.physical_confirmation_source.is_none());
    }

    #[test]
    fn windows_ipp_url_uses_the_stable_endpoint_and_queue() {
        let endpoint = PrinterEndpoint::Loopback {
            port: 8644,
            queue: "QuireWire_DCP_L2600D".into(),
        };
        assert_eq!(
            endpoint.windows_ipp_url(),
            "http://127.0.0.1:8644/printers/QuireWire_DCP_L2600D"
        );
    }
}
