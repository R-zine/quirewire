#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CheckState {
    Pass,
    Warn,
    Fail,
}

impl CheckState {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pass => "pass",
            Self::Warn => "warn",
            Self::Fail => "fail",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DoctorCheck {
    pub name: &'static str,
    pub state: CheckState,
    pub detail: String,
    pub action: Option<String>,
}

impl DoctorCheck {
    #[must_use]
    pub fn pass(name: &'static str, detail: impl Into<String>) -> Self {
        Self {
            name,
            state: CheckState::Pass,
            detail: detail.into(),
            action: None,
        }
    }

    #[must_use]
    pub fn fail(name: &'static str, detail: impl Into<String>, action: impl Into<String>) -> Self {
        Self {
            name,
            state: CheckState::Fail,
            detail: detail.into(),
            action: Some(action.into()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DoctorReport {
    pub provider: &'static str,
    pub checks: Vec<DoctorCheck>,
}

impl DoctorReport {
    #[must_use]
    pub fn passed(&self) -> bool {
        self.checks
            .iter()
            .all(|check| check.state != CheckState::Fail)
    }
}
