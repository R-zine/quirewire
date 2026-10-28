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
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrintQueue {
    pub name: String,
    pub driver: String,
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
    use super::{JobId, JobState, PrintJob, UsbIdentity};

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
}
