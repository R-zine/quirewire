use std::fmt;

/// Stable error categories exposed by providers and orchestration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorKind {
    MissingDependency,
    PermissionDenied,
    UsbBusy,
    PrinterMissing,
    GuestUnhealthy,
    IppNegotiationFailed,
    PortConflict,
    UnsupportedDriver,
    Timeout,
    Internal,
}

impl ErrorKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::MissingDependency => "missing_dependency",
            Self::PermissionDenied => "permission_denied",
            Self::UsbBusy => "usb_busy",
            Self::PrinterMissing => "printer_missing",
            Self::GuestUnhealthy => "guest_unhealthy",
            Self::IppNegotiationFailed => "ipp_negotiation_failed",
            Self::PortConflict => "port_conflict",
            Self::UnsupportedDriver => "unsupported_driver",
            Self::Timeout => "timeout",
            Self::Internal => "internal",
        }
    }
}

/// Actionable domain error. Context is suitable for direct user display but must
/// not be written to telemetry without an explicit redaction classification.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BridgeError {
    MissingDependency { dependency: String, action: String },
    PermissionDenied { operation: String, action: String },
    UsbBusy { device: String, action: String },
    PrinterMissing { printer: String, action: String },
    GuestUnhealthy { detail: String, action: String },
    IppNegotiationFailed { endpoint: String, action: String },
    PortConflict { port: u16, action: String },
    UnsupportedDriver { observed: String, expected: String },
    Timeout { operation: String, seconds: u64 },
    Internal { detail: String },
}

impl BridgeError {
    #[must_use]
    pub const fn kind(&self) -> ErrorKind {
        match self {
            Self::MissingDependency { .. } => ErrorKind::MissingDependency,
            Self::PermissionDenied { .. } => ErrorKind::PermissionDenied,
            Self::UsbBusy { .. } => ErrorKind::UsbBusy,
            Self::PrinterMissing { .. } => ErrorKind::PrinterMissing,
            Self::GuestUnhealthy { .. } => ErrorKind::GuestUnhealthy,
            Self::IppNegotiationFailed { .. } => ErrorKind::IppNegotiationFailed,
            Self::PortConflict { .. } => ErrorKind::PortConflict,
            Self::UnsupportedDriver { .. } => ErrorKind::UnsupportedDriver,
            Self::Timeout { .. } => ErrorKind::Timeout,
            Self::Internal { .. } => ErrorKind::Internal,
        }
    }

    #[must_use]
    pub const fn retryable(&self) -> bool {
        matches!(
            self,
            Self::UsbBusy { .. }
                | Self::GuestUnhealthy { .. }
                | Self::IppNegotiationFailed { .. }
                | Self::Timeout { .. }
        )
    }

    /// Constant summary safe for structured logs. It never includes provider or
    /// user-supplied strings.
    #[must_use]
    pub const fn safe_summary(&self) -> &'static str {
        match self.kind() {
            ErrorKind::MissingDependency => "A required dependency is missing.",
            ErrorKind::PermissionDenied => "An operation was denied.",
            ErrorKind::UsbBusy => "The selected USB device is busy.",
            ErrorKind::PrinterMissing => "The selected printer is missing.",
            ErrorKind::GuestUnhealthy => "The guest is unhealthy.",
            ErrorKind::IppNegotiationFailed => "IPP negotiation failed.",
            ErrorKind::PortConflict => "The configured port is unavailable.",
            ErrorKind::UnsupportedDriver => "The selected printer driver is unsupported.",
            ErrorKind::Timeout => "An operation timed out.",
            ErrorKind::Internal => "An internal error occurred.",
        }
    }
}

impl fmt::Display for BridgeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingDependency { dependency, action } => {
                write!(formatter, "Missing dependency '{dependency}'. {action}")
            }
            Self::PermissionDenied { operation, action } => {
                write!(formatter, "Permission denied while {operation}. {action}")
            }
            Self::UsbBusy { device, action } => {
                write!(formatter, "USB device '{device}' is busy. {action}")
            }
            Self::PrinterMissing { printer, action } => {
                write!(formatter, "Printer '{printer}' is missing. {action}")
            }
            Self::GuestUnhealthy { detail, action } => {
                write!(formatter, "Guest unhealthy: {detail}. {action}")
            }
            Self::IppNegotiationFailed { endpoint, action } => {
                write!(
                    formatter,
                    "IPP negotiation failed for '{endpoint}'. {action}"
                )
            }
            Self::PortConflict { port, action } => {
                write!(formatter, "Loopback port {port} is unavailable. {action}")
            }
            Self::UnsupportedDriver { observed, expected } => {
                write!(
                    formatter,
                    "Unsupported driver '{observed}'; expected '{expected}'."
                )
            }
            Self::Timeout { operation, seconds } => {
                write!(
                    formatter,
                    "'{operation}' timed out after {seconds} seconds."
                )
            }
            Self::Internal { detail } => write!(formatter, "Internal error: {detail}"),
        }
    }
}

impl std::error::Error for BridgeError {}

#[cfg(test)]
mod tests {
    use super::{BridgeError, ErrorKind};

    #[test]
    fn every_required_error_has_a_stable_code() {
        let cases = [
            (
                BridgeError::MissingDependency {
                    dependency: "x".into(),
                    action: "a".into(),
                },
                ErrorKind::MissingDependency,
            ),
            (
                BridgeError::PermissionDenied {
                    operation: "x".into(),
                    action: "a".into(),
                },
                ErrorKind::PermissionDenied,
            ),
            (
                BridgeError::UsbBusy {
                    device: "x".into(),
                    action: "a".into(),
                },
                ErrorKind::UsbBusy,
            ),
            (
                BridgeError::PrinterMissing {
                    printer: "x".into(),
                    action: "a".into(),
                },
                ErrorKind::PrinterMissing,
            ),
            (
                BridgeError::GuestUnhealthy {
                    detail: "x".into(),
                    action: "a".into(),
                },
                ErrorKind::GuestUnhealthy,
            ),
            (
                BridgeError::IppNegotiationFailed {
                    endpoint: "x".into(),
                    action: "a".into(),
                },
                ErrorKind::IppNegotiationFailed,
            ),
            (
                BridgeError::PortConflict {
                    port: 8632,
                    action: "a".into(),
                },
                ErrorKind::PortConflict,
            ),
            (
                BridgeError::UnsupportedDriver {
                    observed: "x".into(),
                    expected: "y".into(),
                },
                ErrorKind::UnsupportedDriver,
            ),
            (
                BridgeError::Timeout {
                    operation: "x".into(),
                    seconds: 1,
                },
                ErrorKind::Timeout,
            ),
            (
                BridgeError::Internal { detail: "x".into() },
                ErrorKind::Internal,
            ),
        ];
        for (error, kind) in cases {
            assert_eq!(error.kind(), kind);
            assert_eq!(error.kind().as_str(), kind.as_str());
        }
    }

    #[test]
    fn safe_summary_omits_sensitive_context() {
        let secret = "SERIAL-DO-NOT-LOG";
        let error = BridgeError::UsbBusy {
            device: secret.into(),
            action: "retry".into(),
        };
        assert!(!error.safe_summary().contains(secret));
        assert!(error.retryable());
    }
}
