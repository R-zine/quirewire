//! Scoped DNS-SD advertisement for an on-demand LAN IPP endpoint.
//!
//! The Windows network/firewall and VirtualBox NAT boundaries are managed by
//! their respective providers. This provider publishes only the explicitly
//! approved interface IPv4 address and unregisters it on stop.

use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, SocketAddrV4, UdpSocket};
use std::time::{Duration, Instant};

use mdns_sd::{IfKind, ServiceDaemon, ServiceInfo};
use quirewire_domain::BridgeError;

pub const IPP_SERVICE_TYPE: &str = "_ipp._tcp.local.";
pub const AIRPRINT_SERVICE_TYPE: &str = "_universal._sub._ipp._tcp.local.";
pub const AIRSCAN_SERVICE_TYPE: &str = "_uscan._tcp.local.";
const TXT_VALUE_MAX: usize = 251;
const PDL_PRIORITY: [&str; 7] = [
    "image/urf",
    "image/pwg-raster",
    "application/pdf",
    "image/jpeg",
    "image/png",
    "application/postscript",
    "application/octet-stream",
];

pub fn browse_live_advertisement(
    instance_name: &str,
    expected_address: Ipv4Addr,
    expected_port: u16,
    timeout: Duration,
) -> Result<String, BridgeError> {
    let deadline = Instant::now() + timeout;
    let printer_markers: [&[u8]; 4] = [
        instance_name.as_bytes(),
        b"printers/QuireWire_DCP_L2600D",
        b"pdl=",
        b"URF=",
    ];
    let ipp_bytes = legacy_query(
        IPP_SERVICE_TYPE,
        expected_address,
        deadline,
        &printer_markers,
    )?;
    let airprint_bytes = legacy_query(
        AIRPRINT_SERVICE_TYPE,
        expected_address,
        deadline,
        &printer_markers,
    )?;
    Ok(format!(
        "resolved={} address={} port={} ipp_response_bytes={} airprint_response_bytes={}",
        instance_name, expected_address, expected_port, ipp_bytes, airprint_bytes
    ))
}

pub fn browse_live_scan_advertisement(
    instance_name: &str,
    expected_address: Ipv4Addr,
    expected_port: u16,
    timeout: Duration,
) -> Result<String, BridgeError> {
    let deadline = Instant::now() + timeout;
    let markers: [&[u8]; 9] = [
        instance_name.as_bytes(),
        b"eSCL",
        b"pdl=",
        b"vers=2.0",
        b"cs=",
        b"is=",
        b"duplex=",
        b"adminurl=",
        b"uuid=",
    ];
    let response_bytes = legacy_query(AIRSCAN_SERVICE_TYPE, expected_address, deadline, &markers)?;
    Ok(format!(
        "resolved={} address={} port={} airscan_compatibility=airsane-v2 airscan_response_bytes={}",
        instance_name, expected_address, expected_port, response_bytes
    ))
}

fn legacy_query(
    service_type: &str,
    expected_address: Ipv4Addr,
    deadline: Instant,
    expected_markers: &[&[u8]],
) -> Result<usize, BridgeError> {
    let socket = UdpSocket::bind(SocketAddrV4::new(expected_address, 0))
        .map_err(|error| lan_error(format!("cannot bind mDNS diagnostic socket: {error}")))?;
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(lan_error(
            "mDNS diagnostic timed out before the query was sent",
        ));
    }
    let query = ptr_query(service_type)?;
    socket
        .send_to(
            &query,
            SocketAddrV4::new(Ipv4Addr::new(224, 0, 0, 251), 5353),
        )
        .map_err(|error| lan_error(format!("cannot send mDNS diagnostic query: {error}")))?;

    let mut response = [0_u8; 4096];
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(lan_error(format!("no valid {service_type} mDNS response")));
        }
        socket
            .set_read_timeout(Some(remaining))
            .map_err(|error| lan_error(format!("cannot set mDNS diagnostic timeout: {error}")))?;
        let (length, source) = socket
            .recv_from(&mut response)
            .map_err(|error| lan_error(format!("no {service_type} mDNS response: {error}")))?;
        let valid_source = source.ip() == IpAddr::V4(expected_address) && source.port() == 5353;
        let is_response = length >= 12 && response[2] & 0x80 != 0;
        let has_answer = is_response && u16::from_be_bytes([response[6], response[7]]) > 0;
        let markers_match = expected_markers.iter().all(|marker| {
            response[..length]
                .windows(marker.len())
                .any(|part| part == *marker)
        });
        if valid_source && has_answer && markers_match {
            return Ok(length);
        }
    }
}

fn ptr_query(service_type: &str) -> Result<Vec<u8>, BridgeError> {
    let mut query = vec![0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0];
    for label in service_type.trim_end_matches('.').split('.') {
        if label.is_empty() || label.len() > 63 || !label.is_ascii() {
            return Err(lan_error("invalid DNS-SD service type in diagnostic"));
        }
        query.push(label.len() as u8);
        query.extend_from_slice(label.as_bytes());
    }
    query.extend_from_slice(&[0, 0, 12, 0, 1]);
    Ok(query)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LanAdvertisement {
    pub instance_name: String,
    pub hostname: String,
    pub address: Ipv4Addr,
    pub port: u16,
    pub queue: String,
    pub make_model: String,
    pub formats: Vec<String>,
    pub urf: Vec<String>,
    pub uuid: String,
    pub color: bool,
    pub duplex: bool,
}

impl LanAdvertisement {
    #[must_use]
    pub fn fullname(&self) -> String {
        format!("{}.{}", self.instance_name, IPP_SERVICE_TYPE)
    }

    fn properties(&self) -> HashMap<String, String> {
        let mut properties = HashMap::from([
            ("txtvers".into(), "1".into()),
            ("qtotal".into(), "1".into()),
            ("rp".into(), format!("printers/{}", self.queue)),
            ("ty".into(), self.make_model.clone()),
            ("product".into(), format!("({})", self.make_model)),
            (
                "pdl".into(),
                bounded_csv(&self.formats, &PDL_PRIORITY, TXT_VALUE_MAX),
            ),
            ("Color".into(), bool_txt(self.color).into()),
            ("Duplex".into(), bool_txt(self.duplex).into()),
            ("Copies".into(), "T".into()),
            ("priority".into(), "0".into()),
            (
                "UUID".into(),
                self.uuid
                    .strip_prefix("urn:uuid:")
                    .unwrap_or(&self.uuid)
                    .to_string(),
            ),
            ("TLS".into(), "none".into()),
            (
                "note".into(),
                "Shared by QuireWire while the app is running".into(),
            ),
        ]);
        if !self.urf.is_empty() {
            properties.insert("URF".into(), bounded_csv(&self.urf, &[], TXT_VALUE_MAX));
        }
        properties
    }

    fn validate(&self) -> Result<(), BridgeError> {
        if self.port == 0
            || self.address.is_unspecified()
            || self.address.is_loopback()
            || self.address.is_link_local()
            || self.address.is_multicast()
        {
            return Err(lan_error(
                "advertisement address and port must identify a routable LAN endpoint",
            ));
        }
        if self.instance_name.is_empty()
            || self.instance_name.len() > 63
            || !self.hostname.ends_with(".local.")
            || self.queue.is_empty()
            || self.formats.is_empty()
            || bounded_csv(&self.formats, &PDL_PRIORITY, TXT_VALUE_MAX).is_empty()
        {
            return Err(lan_error("advertisement metadata is incomplete or unsafe"));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScanAdvertisement {
    pub instance_name: String,
    pub hostname: String,
    pub address: Ipv4Addr,
    pub port: u16,
    pub make_model: String,
    pub formats: Vec<String>,
    pub sources: Vec<String>,
    pub color_modes: Vec<String>,
    pub duplex: bool,
    pub uuid: Option<String>,
}

impl ScanAdvertisement {
    #[must_use]
    pub fn fullname(&self) -> String {
        format!("{}.{}", self.instance_name, AIRSCAN_SERVICE_TYPE)
    }

    fn properties(&self) -> HashMap<String, String> {
        let color_spaces = self
            .color_modes
            .iter()
            .filter_map(|mode| match mode.as_str() {
                "BlackAndWhite1" => Some("binary".to_string()),
                "Grayscale8" => Some("grayscale".to_string()),
                "RGB24" => Some("color".to_string()),
                _ => None,
            })
            .collect::<Vec<_>>();
        let input_sources = self
            .sources
            .iter()
            .filter_map(|source| match source.as_str() {
                "platen" => Some("platen".to_string()),
                "adf" => Some("adf".to_string()),
                _ => None,
            })
            .collect::<Vec<_>>();
        let mut properties = HashMap::from([
            ("txtvers".into(), "1".into()),
            ("vers".into(), "2.0".into()),
            ("ty".into(), self.make_model.clone()),
            ("rs".into(), "eSCL".into()),
            (
                "pdl".into(),
                bounded_csv(&self.formats, &PDL_PRIORITY, TXT_VALUE_MAX),
            ),
            (
                "note".into(),
                "Shared by QuireWire while the app is running".into(),
            ),
            ("cs".into(), bounded_csv(&color_spaces, &[], TXT_VALUE_MAX)),
            ("is".into(), bounded_csv(&input_sources, &[], TXT_VALUE_MAX)),
            ("duplex".into(), bool_txt(self.duplex).into()),
            (
                "adminurl".into(),
                format!("http://{}:{}/eSCL", self.address, self.port),
            ),
        ]);
        if let Some(uuid) = &self.uuid {
            properties.insert(
                "uuid".into(),
                uuid.strip_prefix("urn:uuid:").unwrap_or(uuid).to_string(),
            );
        }
        properties
    }

    fn validate(&self) -> Result<(), BridgeError> {
        if self.port == 0
            || self.address.is_unspecified()
            || self.address.is_loopback()
            || self.address.is_link_local()
            || self.address.is_multicast()
            || self.instance_name.is_empty()
            || self.instance_name.len() > 63
            || !self.hostname.ends_with(".local.")
            || self.make_model.is_empty()
            || self.formats.is_empty()
            || self.sources.is_empty()
            || self.color_modes.is_empty()
            || bounded_csv(&self.formats, &PDL_PRIORITY, TXT_VALUE_MAX).is_empty()
            || bounded_csv(
                &input_sources_for_validation(&self.sources),
                &[],
                TXT_VALUE_MAX,
            )
            .is_empty()
            || bounded_csv(
                &color_spaces_for_validation(&self.color_modes),
                &[],
                TXT_VALUE_MAX,
            )
            .is_empty()
        {
            return Err(lan_error(
                "scanner advertisement metadata is incomplete or unsafe",
            ));
        }
        Ok(())
    }
}

fn input_sources_for_validation(values: &[String]) -> Vec<String> {
    values
        .iter()
        .filter(|value| matches!(value.as_str(), "platen" | "adf"))
        .cloned()
        .collect()
}

fn color_spaces_for_validation(values: &[String]) -> Vec<String> {
    values
        .iter()
        .filter_map(|value| match value.as_str() {
            "BlackAndWhite1" => Some("binary".to_string()),
            "Grayscale8" => Some("grayscale".to_string()),
            "RGB24" => Some("color".to_string()),
            _ => None,
        })
        .collect()
}

fn bounded_csv(values: &[String], preferred: &[&str], maximum: usize) -> String {
    let mut ordered = Vec::with_capacity(values.len());
    let mut seen = HashSet::new();
    for candidate in preferred
        .iter()
        .filter_map(|preferred| values.iter().find(|value| value.as_str() == *preferred))
        .chain(values.iter())
    {
        if !candidate.is_empty()
            && !candidate.contains(',')
            && !candidate.chars().any(char::is_control)
            && seen.insert(candidate.as_str())
        {
            ordered.push(candidate.as_str());
        }
    }
    let mut result = String::new();
    for value in ordered {
        let additional = value.len() + usize::from(!result.is_empty());
        if result.len() + additional > maximum {
            continue;
        }
        if !result.is_empty() {
            result.push(',');
        }
        result.push_str(value);
    }
    result
}

pub struct LanAdvertiser {
    daemon: Option<ServiceDaemon>,
    active: Option<LanAdvertisement>,
    active_scan: Option<ScanAdvertisement>,
}

impl LanAdvertiser {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            daemon: None,
            active: None,
            active_scan: None,
        }
    }

    pub fn start(&mut self, advertisement: LanAdvertisement) -> Result<(), BridgeError> {
        self.start_services(advertisement, None)
    }

    pub fn start_services(
        &mut self,
        advertisement: LanAdvertisement,
        scan: Option<ScanAdvertisement>,
    ) -> Result<(), BridgeError> {
        advertisement.validate()?;
        if let Some(scan) = &scan {
            scan.validate()?;
            if scan.address != advertisement.address || scan.hostname != advertisement.hostname {
                return Err(lan_error(
                    "print and scan advertisements must use the same approved interface",
                ));
            }
        }
        if self.active.as_ref() == Some(&advertisement) && self.active_scan == scan {
            return Ok(());
        }
        self.stop()?;

        let daemon = ServiceDaemon::new()
            .map_err(|error| lan_error(format!("cannot create mDNS daemon: {error}")))?;
        daemon
            .disable_interface(IfKind::All)
            .map_err(|error| lan_error(format!("cannot scope mDNS interfaces: {error}")))?;
        daemon
            .enable_interface(IfKind::Addr(IpAddr::V4(advertisement.address)))
            .map_err(|error| lan_error(format!("cannot select approved LAN interface: {error}")))?;

        let service = ServiceInfo::new(
            AIRPRINT_SERVICE_TYPE,
            &advertisement.instance_name,
            &advertisement.hostname,
            IpAddr::V4(advertisement.address),
            advertisement.port,
            advertisement.properties(),
        )
        .map_err(|error| lan_error(format!("invalid DNS-SD service metadata: {error}")))?;
        daemon
            .register(service)
            .map_err(|error| lan_error(format!("cannot register IPP DNS-SD service: {error}")))?;
        if let Some(scan_advertisement) = &scan {
            let service = ServiceInfo::new(
                AIRSCAN_SERVICE_TYPE,
                &scan_advertisement.instance_name,
                &scan_advertisement.hostname,
                IpAddr::V4(scan_advertisement.address),
                scan_advertisement.port,
                scan_advertisement.properties(),
            )
            .map_err(|error| lan_error(format!("invalid eSCL DNS-SD metadata: {error}")))?;
            daemon.register(service).map_err(|error| {
                lan_error(format!("cannot register eSCL DNS-SD service: {error}"))
            })?;
        }
        self.daemon = Some(daemon);
        self.active = Some(advertisement);
        self.active_scan = scan;
        Ok(())
    }

    pub fn stop(&mut self) -> Result<(), BridgeError> {
        let Some(daemon) = self.daemon.take() else {
            self.active = None;
            self.active_scan = None;
            return Ok(());
        };
        if let Some(active) = self.active.take() {
            let receiver = daemon
                .unregister(&active.fullname())
                .map_err(|error| lan_error(format!("cannot unregister IPP service: {error}")))?;
            let _ = receiver.recv_timeout(std::time::Duration::from_secs(2));
        }
        if let Some(active) = self.active_scan.take() {
            let receiver = daemon
                .unregister(&active.fullname())
                .map_err(|error| lan_error(format!("cannot unregister eSCL service: {error}")))?;
            let _ = receiver.recv_timeout(std::time::Duration::from_secs(2));
        }
        daemon
            .shutdown()
            .map_err(|error| lan_error(format!("cannot stop mDNS daemon: {error}")))?;
        Ok(())
    }

    #[must_use]
    pub fn active(&self) -> Option<&LanAdvertisement> {
        self.active.as_ref()
    }

    #[must_use]
    pub fn active_scan(&self) -> Option<&ScanAdvertisement> {
        self.active_scan.as_ref()
    }
}

impl Default for LanAdvertiser {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for LanAdvertiser {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

const fn bool_txt(value: bool) -> &'static str {
    if value { "T" } else { "F" }
}

fn lan_error(detail: impl Into<String>) -> BridgeError {
    BridgeError::GuestUnhealthy {
        detail: detail.into(),
        action: "Keep QuireWire on the explicitly approved local subnet and retry LAN sharing."
            .into(),
    }
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

    use super::{AIRPRINT_SERVICE_TYPE, AIRSCAN_SERVICE_TYPE, LanAdvertisement, ScanAdvertisement};

    fn advertisement() -> LanAdvertisement {
        LanAdvertisement {
            instance_name: "Brother via QuireWire".into(),
            hostname: "quirewire-00000000.local.".into(),
            address: Ipv4Addr::new(192, 168, 1, 10),
            port: 8644,
            queue: "QuireWire_DCP_L2600D".into(),
            make_model: "Brother DCP-L2600D for CUPS".into(),
            formats: vec!["application/pdf".into(), "image/pwg-raster".into()],
            urf: vec!["V1.4".into(), "W8".into()],
            uuid: "urn:uuid:26263578-aca1-3e00-66bb-590c653b6fe7".into(),
            color: false,
            duplex: true,
        }
    }

    #[test]
    fn airprint_txt_is_truthful_and_contains_the_queue_resource() {
        let advertisement = advertisement();
        let properties = advertisement.properties();
        assert_eq!(properties["rp"], "printers/QuireWire_DCP_L2600D");
        assert_eq!(properties["pdl"], "image/pwg-raster,application/pdf");
        assert_eq!(properties["Color"], "F");
        assert_eq!(properties["Duplex"], "T");
        assert_eq!(properties["URF"], "V1.4,W8");
        assert_eq!(properties["UUID"], "26263578-aca1-3e00-66bb-590c653b6fe7");
        assert_eq!(
            advertisement.fullname(),
            "Brother via QuireWire._ipp._tcp.local."
        );
        assert_eq!(AIRPRINT_SERVICE_TYPE, "_universal._sub._ipp._tcp.local.");
    }

    #[test]
    fn loopback_and_incomplete_metadata_are_rejected() {
        let mut advertisement = advertisement();
        advertisement.address = Ipv4Addr::LOCALHOST;
        assert!(advertisement.validate().is_err());
        advertisement.address = Ipv4Addr::new(192, 168, 1, 10);
        advertisement.formats.clear();
        assert!(advertisement.validate().is_err());
    }

    #[test]
    fn oversized_format_list_is_a_truthful_bounded_subset() {
        let mut advertisement = advertisement();
        advertisement.formats = (0..80)
            .map(|index| format!("application/vnd.example-format-{index}"))
            .chain(["application/pdf".into(), "image/pwg-raster".into()])
            .collect();
        let pdl = advertisement.properties()["pdl"].clone();
        assert!(pdl.len() <= 251);
        assert!(pdl.starts_with("image/pwg-raster,application/pdf"));
        assert!(
            pdl.split(',')
                .all(|format| advertisement.formats.iter().any(|value| value == format))
        );
        assert!(advertisement.validate().is_ok());
    }

    #[test]
    fn diagnostic_builds_a_bounded_ptr_query() {
        let query = super::ptr_query(AIRPRINT_SERVICE_TYPE).expect("PTR query");
        assert_eq!(&query[..12], &[0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
        assert_eq!(&query[query.len() - 5..], &[0, 0, 12, 0, 1]);
        assert!(query.windows(10).any(|part| part == b"_universal"));
        assert!(query.len() < 512);
    }

    #[test]
    fn airscan_txt_uses_escl_and_truthful_formats() {
        let scanner = ScanAdvertisement {
            instance_name: "Brother via QuireWire Scanner".into(),
            hostname: "quirewire-m4.local.".into(),
            address: Ipv4Addr::new(192, 168, 1, 10),
            port: 8645,
            make_model: "Brother DCP-L2600D".into(),
            formats: vec!["image/jpeg".into(), "application/pdf".into()],
            sources: vec!["platen".into()],
            color_modes: vec!["Grayscale8".into(), "RGB24".into()],
            duplex: false,
            uuid: Some("urn:uuid:test-scanner".into()),
        };
        let properties = scanner.properties();
        assert_eq!(properties["rs"], "eSCL");
        assert_eq!(properties["pdl"], "application/pdf,image/jpeg");
        assert_eq!(properties["uuid"], "test-scanner");
        assert_eq!(properties["vers"], "2.0");
        assert_eq!(properties["cs"], "grayscale,color");
        assert_eq!(properties["is"], "platen");
        assert_eq!(properties["duplex"], "F");
        assert_eq!(properties["adminurl"], "http://192.168.1.10:8645/eSCL");
        assert_eq!(AIRSCAN_SERVICE_TYPE, "_uscan._tcp.local.");
        assert!(scanner.validate().is_ok());
    }

    #[test]
    fn airscan_rejects_capabilities_that_cannot_be_advertised_truthfully() {
        let mut scanner = ScanAdvertisement {
            instance_name: "Brother via QuireWire Scanner".into(),
            hostname: "quirewire-m4.local.".into(),
            address: Ipv4Addr::new(192, 168, 1, 10),
            port: 8645,
            make_model: "Brother DCP-L2600D".into(),
            formats: vec!["image/jpeg".into()],
            sources: vec!["platen".into()],
            color_modes: vec!["Grayscale8".into()],
            duplex: false,
            uuid: Some("urn:uuid:test-scanner".into()),
        };
        scanner.sources = vec!["proprietary-source".into()];
        assert!(scanner.validate().is_err());
        scanner.sources = vec!["platen".into()];
        scanner.color_modes = vec!["VendorColor42".into()];
        assert!(scanner.validate().is_err());
    }
}
