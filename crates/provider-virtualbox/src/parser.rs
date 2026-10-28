use std::collections::BTreeMap;

use printbridge_domain::{BridgeError, UsbIdentity};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct VBoxVersion {
    pub major: u16,
    pub minor: u16,
    pub patch: u16,
    pub revision: Option<u32>,
}

impl VBoxVersion {
    pub fn parse(value: &str) -> Result<Self, BridgeError> {
        let trimmed = value.trim();
        let (number, revision) = match trimmed.split_once('r') {
            Some((number, revision)) => (number, revision.parse().ok()),
            None => (trimmed, None),
        };
        let mut parts = number.split('.');
        let major = parse_version_part(parts.next(), "major", trimmed)?;
        let minor = parse_version_part(parts.next(), "minor", trimmed)?;
        let patch = parse_version_part(parts.next(), "patch", trimmed)?;
        if parts.next().is_some() {
            return Err(version_error(trimmed));
        }
        Ok(Self {
            major,
            minor,
            patch,
            revision,
        })
    }

    #[must_use]
    pub const fn supported(self) -> bool {
        self.major == 7 && self.minor >= 1 && self.minor <= 2
    }
}

fn parse_version_part(value: Option<&str>, name: &str, original: &str) -> Result<u16, BridgeError> {
    value
        .ok_or_else(|| version_error(original))?
        .parse::<u16>()
        .map_err(|_| BridgeError::Internal {
            detail: format!("invalid VirtualBox {name} version component in '{original}'"),
        })
}

fn version_error(value: &str) -> BridgeError {
    BridgeError::Internal {
        detail: format!("unrecognized VirtualBox version '{value}'"),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VmPowerState {
    PoweredOff,
    Running,
    Starting,
    Stopping,
    Saved,
    Paused,
    Aborted,
    Unknown,
}

impl VmPowerState {
    #[must_use]
    pub fn parse(value: &str) -> Self {
        match value.to_ascii_lowercase().as_str() {
            "poweroff" => Self::PoweredOff,
            "running" => Self::Running,
            "starting" => Self::Starting,
            "stopping" => Self::Stopping,
            "saved" => Self::Saved,
            "paused" => Self::Paused,
            "aborted" => Self::Aborted,
            _ => Self::Unknown,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostUsbState {
    Available,
    Captured,
    Busy,
    Unavailable,
    Unknown,
}

impl HostUsbState {
    #[must_use]
    fn parse(value: &str) -> Self {
        match value.to_ascii_lowercase().as_str() {
            "available" => Self::Available,
            "captured" => Self::Captured,
            "busy" | "held" => Self::Busy,
            "unavailable" => Self::Unavailable,
            _ => Self::Unknown,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostUsbDevice {
    pub host_uuid: String,
    pub identity: UsbIdentity,
    pub display_name: String,
    pub state: HostUsbState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VmUsbFilter {
    pub position: usize,
    pub active: bool,
    pub name: String,
    pub vendor_id: Option<u16>,
    pub product_id: Option<u16>,
    pub serial: Option<String>,
    pub remote: Option<String>,
}

#[must_use]
pub fn parse_machine_readable(input: &str) -> BTreeMap<String, String> {
    input
        .lines()
        .filter_map(|line| {
            let (key, value) = line.split_once('=')?;
            Some((key.trim().to_string(), unquote(value.trim())))
        })
        .collect()
}

fn unquote(value: &str) -> String {
    value
        .strip_prefix('"')
        .and_then(|inner| inner.strip_suffix('"'))
        .unwrap_or(value)
        .replace("\\\"", "\"")
        .replace("\\\\", "\\")
}

pub fn parse_usb_host(input: &str) -> Result<Vec<HostUsbDevice>, BridgeError> {
    input
        .split("\n\n")
        .filter(|block| {
            block
                .lines()
                .any(|line| line.trim_start().starts_with("UUID:"))
        })
        .map(parse_usb_block)
        .collect()
}

fn parse_usb_block(block: &str) -> Result<HostUsbDevice, BridgeError> {
    let fields = parse_colon_fields(block);
    let host_uuid = required_field(&fields, "UUID")?.to_string();
    let vendor_id = parse_hex_field(required_field(&fields, "VendorId")?, "VendorId")?;
    let product_id = parse_hex_field(required_field(&fields, "ProductId")?, "ProductId")?;
    let serial = optional_field(&fields, "SerialNumber");
    let product = optional_field(&fields, "Product");
    let manufacturer = optional_field(&fields, "Manufacturer");
    let display_name = product
        .or(manufacturer)
        .unwrap_or_else(|| format!("USB {vendor_id:04x}:{product_id:04x}"));
    let state = HostUsbState::parse(required_field(&fields, "Current State")?);
    Ok(HostUsbDevice {
        host_uuid,
        identity: UsbIdentity {
            vendor_id,
            product_id,
            serial,
        },
        display_name,
        state,
    })
}

fn parse_colon_fields(input: &str) -> BTreeMap<String, String> {
    input
        .lines()
        .filter_map(|line| {
            let (key, value) = line.split_once(':')?;
            Some((key.trim().to_string(), value.trim().to_string()))
        })
        .collect()
}

fn required_field<'a>(
    fields: &'a BTreeMap<String, String>,
    name: &str,
) -> Result<&'a str, BridgeError> {
    fields
        .get(name)
        .map(String::as_str)
        .ok_or_else(|| BridgeError::Internal {
            detail: format!("VBoxManage USB output omitted '{name}'"),
        })
}

fn optional_field(fields: &BTreeMap<String, String>, name: &str) -> Option<String> {
    fields
        .get(name)
        .filter(|value| !value.is_empty() && value.as_str() != "<none>")
        .cloned()
}

fn parse_hex_field(value: &str, name: &str) -> Result<u16, BridgeError> {
    let token = value.split_whitespace().next().unwrap_or(value);
    let digits = token.strip_prefix("0x").unwrap_or(token);
    u16::from_str_radix(digits, 16).map_err(|_| BridgeError::Internal {
        detail: format!("invalid hexadecimal {name} '{token}'"),
    })
}

pub fn parse_vm_usb_filters(machine: &BTreeMap<String, String>) -> Vec<VmUsbFilter> {
    let mut filters = Vec::new();
    for suffix in 1..=64 {
        let active_key = format!("USBFilterActive{suffix}");
        if !machine.contains_key(&active_key) {
            continue;
        }
        filters.push(VmUsbFilter {
            position: suffix - 1,
            active: machine.get(&active_key).is_some_and(|value| value == "on"),
            name: machine
                .get(&format!("USBFilterName{suffix}"))
                .cloned()
                .unwrap_or_default(),
            vendor_id: machine
                .get(&format!("USBFilterVendorId{suffix}"))
                .and_then(|value| parse_filter_hex(value)),
            product_id: machine
                .get(&format!("USBFilterProductId{suffix}"))
                .and_then(|value| parse_filter_hex(value)),
            serial: machine
                .get(&format!("USBFilterSerialNumber{suffix}"))
                .filter(|value| !value.is_empty())
                .cloned(),
            remote: machine.get(&format!("USBFilterRemote{suffix}")).cloned(),
        });
    }
    filters
}

fn parse_filter_hex(value: &str) -> Option<u16> {
    u16::from_str_radix(value.trim_start_matches("0x"), 16).ok()
}

#[must_use]
pub fn parse_attached_usb_uuids(input: &str) -> Vec<String> {
    let heading = "currently attached usb devices:";
    let lowercase = input.to_ascii_lowercase();
    let Some(start) = lowercase.find(heading) else {
        return Vec::new();
    };
    let remainder = &input[start + heading.len()..];
    let section = remainder
        .split("Bandwidth groups:")
        .next()
        .unwrap_or(remainder);
    section
        .lines()
        .filter_map(|line| {
            line.trim()
                .strip_prefix("UUID:")
                .map(str::trim)
                .map(str::to_string)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{
        HostUsbState, VBoxVersion, VmPowerState, parse_attached_usb_uuids, parse_machine_readable,
        parse_usb_host, parse_vm_usb_filters,
    };

    #[test]
    fn parses_supported_and_unsupported_versions() {
        let installed = VBoxVersion::parse("7.2.22r175245\n").expect("version");
        assert!(installed.supported());
        assert_eq!(installed.revision, Some(175_245));
        assert!(
            !VBoxVersion::parse("8.0.0")
                .expect("future version parses")
                .supported()
        );
    }

    #[test]
    fn parses_machine_state_and_exact_filter() {
        let values = parse_machine_readable(
            "UUID=\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\"\nVMState=\"running\"\nUSBFilterActive1=\"on\"\nUSBFilterName1=\"PrintBridge M3 owned\"\nUSBFilterVendorId1=\"04f9\"\nUSBFilterProductId1=\"0567\"\nUSBFilterSerialNumber1=\"secret\"\nUSBFilterRemote1=\"no\"\n",
        );
        assert_eq!(
            VmPowerState::parse(&values["VMState"]),
            VmPowerState::Running
        );
        let filter = &parse_vm_usb_filters(&values)[0];
        assert_eq!(filter.position, 0);
        assert_eq!(filter.vendor_id, Some(0x04f9));
        assert_eq!(filter.serial.as_deref(), Some("secret"));
    }

    #[test]
    fn parses_usb_devices_and_redacted_debug() {
        let output = "Host USB Devices:\n\nUUID:               11111111-2222-3333-4444-555555555555\nVendorId:           0x04f9 (04F9)\nProductId:          0x0567 (0567)\nManufacturer:       Brother\nProduct:            DCP-L2600D\nSerialNumber:       super-secret\nCurrent State:      Captured\n";
        let devices = parse_usb_host(output).expect("USB output");
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].state, HostUsbState::Captured);
        assert!(!format!("{:?}", devices[0].identity).contains("super-secret"));
    }

    #[test]
    fn parses_currently_attached_usb_section() {
        let output = "Name: test\n\nCurrently attached USB devices:\n\nUUID:               11111111-2222-3333-4444-555555555555\nVendorId:           0x04f9\n\nBandwidth groups:  <none>\n";
        assert_eq!(
            parse_attached_usb_uuids(output),
            ["11111111-2222-3333-4444-555555555555"]
        );
    }
}
