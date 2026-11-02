use quirewire_domain::{
    BridgeStatus, CheckState, ComponentState, ComponentStatus, Components, DoctorCheck,
    DoctorReport, OwnedVm, Platform, PrinterEndpoint, UsbIdentity,
};

pub struct Controller<P> {
    provider: P,
    vm: OwnedVm,
    usb: UsbIdentity,
    endpoint: PrinterEndpoint,
}

impl<P: Platform> Controller<P> {
    #[must_use]
    pub const fn new(
        provider: P,
        vm: OwnedVm,
        usb: UsbIdentity,
        endpoint: PrinterEndpoint,
    ) -> Self {
        Self {
            provider,
            vm,
            usb,
            endpoint,
        }
    }

    #[must_use]
    pub fn status(&self) -> BridgeStatus {
        let components = Components {
            hypervisor: self
                .provider
                .hypervisor_state()
                .unwrap_or_else(error_component),
            guest: self
                .provider
                .guest_state(&self.vm)
                .unwrap_or_else(error_component),
            usb: self
                .provider
                .attachment_status(&self.vm, &self.usb)
                .unwrap_or_else(error_component),
            cups: self
                .provider
                .queue_status(self.endpoint.queue())
                .unwrap_or_else(error_component),
            windows_queue: self
                .provider
                .windows_queue_status()
                .unwrap_or_else(error_component),
        };
        BridgeStatus::from_components(components)
    }

    #[must_use]
    pub fn doctor(&self) -> DoctorReport {
        let mut checks = Vec::with_capacity(5);
        checks.push(match self.provider.detect() {
            Ok(info) => DoctorCheck::pass(
                "hypervisor",
                format!("{} {} detected (fake)", info.name, info.version),
            ),
            Err(error) => failed_check("hypervisor", &error),
        });
        checks.push(match self.provider.attachment_status(&self.vm, &self.usb) {
            Ok(status) if status.state == ComponentState::Ready => {
                DoctorCheck::pass("usb", "selected fake USB is attached")
            }
            Ok(status) => DoctorCheck::fail(
                "usb",
                format!("state is {}", status.state),
                "Attach the selected device.",
            ),
            Err(error) => failed_check("usb", &error),
        });
        checks.push(match self.provider.probe_ipp(&self.endpoint) {
            Ok(()) => DoctorCheck::pass("guest_ipp", "fake IPP endpoint responded"),
            Err(error) => failed_check("guest_ipp", &error),
        });
        checks.push(match self.provider.detect_ipp_support() {
            Ok(info) => DoctorCheck::pass(
                "windows_ipp",
                format!("{} {} available (fake)", info.name, info.version),
            ),
            Err(error) => failed_check("windows_ipp", &error),
        });
        checks.push(match self.provider.verify_registration() {
            Ok(registration) if registration.enabled => {
                DoctorCheck::pass("login_start", "fake per-user registration enabled")
            }
            Ok(_) => DoctorCheck {
                name: "login_start",
                state: CheckState::Warn,
                detail: "fake per-user registration disabled".into(),
                action: Some("Enable login start during the M6 supervisor milestone.".into()),
            },
            Err(error) => failed_check("login_start", &error),
        });
        DoctorReport {
            provider: "fake-in-memory",
            checks,
        }
    }

    pub fn provider(&self) -> &P {
        &self.provider
    }

    pub fn provider_mut(&mut self) -> &mut P {
        &mut self.provider
    }

    pub fn into_provider(self) -> P {
        self.provider
    }
}

fn error_component(error: quirewire_domain::BridgeError) -> ComponentStatus {
    ComponentStatus::with_detail(ComponentState::Error, error.safe_summary())
}

fn failed_check(name: &'static str, error: &quirewire_domain::BridgeError) -> DoctorCheck {
    DoctorCheck::fail(
        name,
        error.safe_summary(),
        "Run quirewirectl doctor after correcting the reported condition.",
    )
}

#[cfg(test)]
mod tests {
    use quirewire_domain::{BridgeError, BridgePhase};

    use crate::fake::{FakeOperation, FakePlatform};

    use super::Controller;

    #[test]
    fn ready_fake_produces_ready_status_and_passing_doctor() {
        let fake = FakePlatform::ready();
        let (vm, usb, endpoint) = fake.selection();
        let controller = Controller::new(fake, vm, usb, endpoint);
        assert_eq!(controller.status().phase, BridgePhase::Ready);
        assert!(controller.doctor().passed());
    }

    #[test]
    fn provider_failure_maps_to_typed_error_status() {
        let mut fake = FakePlatform::ready();
        fake.set_error(
            FakeOperation::IppProbe,
            BridgeError::IppNegotiationFailed {
                endpoint: "secret-endpoint".into(),
                action: "repair".into(),
            },
        );
        let (vm, usb, endpoint) = fake.selection();
        let controller = Controller::new(fake, vm, usb, endpoint);
        assert!(!controller.doctor().passed());
        let check = &controller.doctor().checks[2];
        assert!(!check.detail.contains("secret-endpoint"));
    }
}
