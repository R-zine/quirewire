use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgePhase {
    NotConfigured,
    Provisioning,
    Starting,
    WaitingForUsb,
    Connecting,
    Ready,
    Degraded,
    Error,
    Stopping,
}

impl BridgePhase {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::NotConfigured => "not_configured",
            Self::Provisioning => "provisioning",
            Self::Starting => "starting",
            Self::WaitingForUsb => "waiting_for_usb",
            Self::Connecting => "connecting",
            Self::Ready => "ready",
            Self::Degraded => "degraded",
            Self::Error => "error",
            Self::Stopping => "stopping",
        }
    }
}

impl fmt::Display for BridgePhase {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ComponentState {
    NotConfigured,
    Provisioning,
    Stopped,
    Starting,
    Waiting,
    Connecting,
    Ready,
    Degraded,
    Error,
    Stopping,
}

impl ComponentState {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::NotConfigured => "not_configured",
            Self::Provisioning => "provisioning",
            Self::Stopped => "stopped",
            Self::Starting => "starting",
            Self::Waiting => "waiting",
            Self::Connecting => "connecting",
            Self::Ready => "ready",
            Self::Degraded => "degraded",
            Self::Error => "error",
            Self::Stopping => "stopping",
        }
    }
}

impl fmt::Display for ComponentState {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ComponentStatus {
    pub state: ComponentState,
    pub detail: Option<String>,
}

impl ComponentStatus {
    #[must_use]
    pub const fn new(state: ComponentState) -> Self {
        Self {
            state,
            detail: None,
        }
    }

    #[must_use]
    pub fn with_detail(state: ComponentState, detail: impl Into<String>) -> Self {
        Self {
            state,
            detail: Some(detail.into()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Components {
    pub hypervisor: ComponentStatus,
    pub guest: ComponentStatus,
    pub usb: ComponentStatus,
    pub cups: ComponentStatus,
    pub windows_queue: ComponentStatus,
}

impl Components {
    #[must_use]
    pub const fn not_configured() -> Self {
        Self {
            hypervisor: ComponentStatus::new(ComponentState::NotConfigured),
            guest: ComponentStatus::new(ComponentState::NotConfigured),
            usb: ComponentStatus::new(ComponentState::NotConfigured),
            cups: ComponentStatus::new(ComponentState::NotConfigured),
            windows_queue: ComponentStatus::new(ComponentState::NotConfigured),
        }
    }

    #[must_use]
    pub const fn ready() -> Self {
        Self {
            hypervisor: ComponentStatus::new(ComponentState::Ready),
            guest: ComponentStatus::new(ComponentState::Ready),
            usb: ComponentStatus::new(ComponentState::Ready),
            cups: ComponentStatus::new(ComponentState::Ready),
            windows_queue: ComponentStatus::new(ComponentState::Ready),
        }
    }

    #[must_use]
    pub fn phase(&self) -> BridgePhase {
        let states = [
            self.hypervisor.state,
            self.guest.state,
            self.usb.state,
            self.cups.state,
            self.windows_queue.state,
        ];
        if states
            .iter()
            .all(|state| *state == ComponentState::NotConfigured)
        {
            return BridgePhase::NotConfigured;
        }
        if states.contains(&ComponentState::Error) {
            return BridgePhase::Error;
        }
        if states.contains(&ComponentState::Stopping) {
            return BridgePhase::Stopping;
        }
        if states.contains(&ComponentState::Provisioning) {
            return BridgePhase::Provisioning;
        }
        if states.contains(&ComponentState::Starting) {
            return BridgePhase::Starting;
        }
        if self.usb.state == ComponentState::Waiting {
            return BridgePhase::WaitingForUsb;
        }
        if states.contains(&ComponentState::Connecting) {
            return BridgePhase::Connecting;
        }
        if states.iter().all(|state| *state == ComponentState::Ready) {
            return BridgePhase::Ready;
        }
        BridgePhase::Degraded
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeStatus {
    pub phase: BridgePhase,
    pub components: Components,
}

impl BridgeStatus {
    #[must_use]
    pub fn from_components(components: Components) -> Self {
        Self {
            phase: components.phase(),
            components,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{BridgePhase, ComponentState, ComponentStatus, Components};

    #[test]
    fn ready_requires_every_component() {
        let mut components = Components::ready();
        assert_eq!(components.phase(), BridgePhase::Ready);
        components.usb = ComponentStatus::new(ComponentState::Waiting);
        assert_eq!(components.phase(), BridgePhase::WaitingForUsb);
    }

    #[test]
    fn errors_take_priority() {
        let mut components = Components::ready();
        components.guest = ComponentStatus::new(ComponentState::Error);
        components.usb = ComponentStatus::new(ComponentState::Waiting);
        assert_eq!(components.phase(), BridgePhase::Error);
    }
}
