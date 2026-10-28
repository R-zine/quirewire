use printbridge_domain::{
    BridgeError, BridgePhase, BridgeStatus, ComponentState, ComponentStatus, Components,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Component {
    Hypervisor,
    Guest,
    Usb,
    Cups,
    WindowsQueue,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeEvent {
    BeginProvisioning,
    ProvisioningComplete,
    GuestStarted,
    UsbCaptured,
    CupsReady,
    WindowsQueueReady,
    RecoverableFailure(Component),
    RecoveryStarted(Component),
    ComponentRecovered(Component),
    FatalFailure(Component),
    StopRequested,
    Stopped,
}

#[derive(Debug, Clone)]
pub struct BridgeStateMachine {
    components: Components,
}

impl Default for BridgeStateMachine {
    fn default() -> Self {
        Self {
            components: Components::not_configured(),
        }
    }
}

impl BridgeStateMachine {
    #[must_use]
    pub fn status(&self) -> BridgeStatus {
        BridgeStatus::from_components(self.components.clone())
    }

    pub fn apply(&mut self, event: BridgeEvent) -> Result<BridgeStatus, BridgeError> {
        let phase = self.components.phase();
        match (phase, event) {
            (BridgePhase::NotConfigured, BridgeEvent::BeginProvisioning) => {
                self.components.hypervisor = status(ComponentState::Provisioning);
            }
            (BridgePhase::Provisioning, BridgeEvent::ProvisioningComplete) => {
                self.components.hypervisor = status(ComponentState::Ready);
                self.components.guest = status(ComponentState::Starting);
            }
            (BridgePhase::Starting, BridgeEvent::GuestStarted) => {
                self.components.guest = status(ComponentState::Ready);
                self.components.usb = status(ComponentState::Waiting);
            }
            (BridgePhase::WaitingForUsb, BridgeEvent::UsbCaptured) => {
                self.components.usb = status(ComponentState::Ready);
                self.components.cups = status(ComponentState::Connecting);
            }
            (BridgePhase::Connecting, BridgeEvent::CupsReady) => {
                self.components.cups = status(ComponentState::Ready);
                self.components.windows_queue = status(ComponentState::Connecting);
            }
            (BridgePhase::Connecting, BridgeEvent::WindowsQueueReady) => {
                self.components.windows_queue = status(ComponentState::Ready);
            }
            (BridgePhase::Ready, BridgeEvent::RecoverableFailure(component)) => {
                *self.component_mut(component) = status(ComponentState::Degraded);
            }
            (BridgePhase::Degraded, BridgeEvent::RecoveryStarted(component)) => {
                *self.component_mut(component) = status(ComponentState::Connecting);
            }
            (BridgePhase::Connecting, BridgeEvent::ComponentRecovered(component)) => {
                *self.component_mut(component) = status(ComponentState::Ready);
            }
            (_, BridgeEvent::FatalFailure(component)) => {
                *self.component_mut(component) = status(ComponentState::Error);
            }
            (
                BridgePhase::Ready
                | BridgePhase::Degraded
                | BridgePhase::Error
                | BridgePhase::Starting
                | BridgePhase::WaitingForUsb
                | BridgePhase::Connecting,
                BridgeEvent::StopRequested,
            ) => {
                self.components.guest = status(ComponentState::Stopping);
            }
            (BridgePhase::Stopping, BridgeEvent::Stopped) => {
                self.components.guest = status(ComponentState::Stopped);
                self.components.usb = status(ComponentState::NotConfigured);
                self.components.cups = status(ComponentState::NotConfigured);
            }
            _ => {
                return Err(BridgeError::Internal {
                    detail: format!("invalid transition from {phase} using {event:?}"),
                });
            }
        }
        Ok(self.status())
    }

    fn component_mut(&mut self, component: Component) -> &mut ComponentStatus {
        match component {
            Component::Hypervisor => &mut self.components.hypervisor,
            Component::Guest => &mut self.components.guest,
            Component::Usb => &mut self.components.usb,
            Component::Cups => &mut self.components.cups,
            Component::WindowsQueue => &mut self.components.windows_queue,
        }
    }
}

const fn status(state: ComponentState) -> ComponentStatus {
    ComponentStatus::new(state)
}

#[cfg(test)]
mod tests {
    use printbridge_domain::BridgePhase;

    use super::{BridgeEvent, BridgeStateMachine, Component};

    #[test]
    fn full_happy_path_reaches_ready() {
        let mut machine = BridgeStateMachine::default();
        assert_eq!(machine.status().phase, BridgePhase::NotConfigured);
        let sequence = [
            BridgeEvent::BeginProvisioning,
            BridgeEvent::ProvisioningComplete,
            BridgeEvent::GuestStarted,
            BridgeEvent::UsbCaptured,
            BridgeEvent::CupsReady,
            BridgeEvent::WindowsQueueReady,
        ];
        for event in sequence {
            machine
                .apply(event)
                .expect("happy-path transition should succeed");
        }
        assert_eq!(machine.status().phase, BridgePhase::Ready);
    }

    #[test]
    fn recoverable_failure_can_return_to_ready() {
        let mut machine = ready_machine();
        assert_eq!(
            machine
                .apply(BridgeEvent::RecoverableFailure(Component::Usb))
                .expect("degrade")
                .phase,
            BridgePhase::Degraded
        );
        assert_eq!(
            machine
                .apply(BridgeEvent::RecoveryStarted(Component::Usb))
                .expect("recovering")
                .phase,
            BridgePhase::Connecting
        );
        assert_eq!(
            machine
                .apply(BridgeEvent::ComponentRecovered(Component::Usb))
                .expect("recovered")
                .phase,
            BridgePhase::Ready
        );
    }

    #[test]
    fn invalid_transition_is_rejected_without_state_change() {
        let mut machine = BridgeStateMachine::default();
        let error = machine
            .apply(BridgeEvent::UsbCaptured)
            .expect_err("invalid transition must fail");
        assert_eq!(error.kind().as_str(), "internal");
        assert_eq!(machine.status().phase, BridgePhase::NotConfigured);
    }

    fn ready_machine() -> BridgeStateMachine {
        let mut machine = BridgeStateMachine::default();
        for event in [
            BridgeEvent::BeginProvisioning,
            BridgeEvent::ProvisioningComplete,
            BridgeEvent::GuestStarted,
            BridgeEvent::UsbCaptured,
            BridgeEvent::CupsReady,
            BridgeEvent::WindowsQueueReady,
        ] {
            machine
                .apply(event)
                .expect("fixture transition should succeed");
        }
        machine
    }
}
