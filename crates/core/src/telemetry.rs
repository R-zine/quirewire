use std::fmt::Write;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TraceLevel {
    Error,
    Warn,
    Info,
}

impl TraceLevel {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Error => "error",
            Self::Warn => "warn",
            Self::Info => "info",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TraceValue {
    Public(String),
    Sensitive,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TraceField {
    pub name: &'static str,
    pub value: TraceValue,
}

impl TraceField {
    #[must_use]
    pub fn public(name: &'static str, value: impl Into<String>) -> Self {
        Self {
            name,
            value: TraceValue::Public(value.into()),
        }
    }

    #[must_use]
    pub const fn sensitive(name: &'static str) -> Self {
        Self {
            name,
            value: TraceValue::Sensitive,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TraceEvent {
    pub level: TraceLevel,
    pub event: &'static str,
    pub fields: Vec<TraceField>,
}

impl TraceEvent {
    #[must_use]
    pub fn to_json_line(&self) -> String {
        let mut output = String::from("{\"level\":\"");
        output.push_str(self.level.as_str());
        output.push_str("\",\"event\":\"");
        push_json_escaped(&mut output, self.event);
        output.push('"');
        for field in &self.fields {
            output.push_str(",\"");
            push_json_escaped(&mut output, field.name);
            output.push_str("\":\"");
            match &field.value {
                TraceValue::Public(value) => push_json_escaped(&mut output, value),
                TraceValue::Sensitive => output.push_str("[REDACTED]"),
            }
            output.push('"');
        }
        output.push('}');
        output
    }
}

fn push_json_escaped(output: &mut String, value: &str) {
    for character in value.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            control if control.is_control() => {
                let _ = write!(output, "\\u{:04x}", u32::from(control));
            }
            other => output.push(other),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{TraceEvent, TraceField, TraceLevel};

    #[test]
    fn sensitive_fields_are_redacted_by_type() {
        let secret = "usb-serial-secret";
        let event = TraceEvent {
            level: TraceLevel::Info,
            event: "usb_observed",
            fields: vec![
                TraceField::public("vid_pid", "04f9:0567"),
                TraceField::sensitive("serial"),
            ],
        };
        let json = event.to_json_line();
        assert!(!json.contains(secret));
        assert!(json.contains("[REDACTED]"));
        assert!(json.contains("04f9:0567"));
    }

    #[test]
    fn public_values_are_json_escaped() {
        let event = TraceEvent {
            level: TraceLevel::Warn,
            event: "unsafe_input",
            fields: vec![TraceField::public("value", "quote\"\nline")],
        };
        assert!(event.to_json_line().contains("quote\\\"\\nline"));
    }
}
