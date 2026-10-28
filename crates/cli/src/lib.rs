use std::io::Write;

use printbridge_agent::AgentService;
use printbridge_core::{TraceEvent, TraceField, TraceLevel};
use printbridge_domain::{BridgeStatus, CheckState, DoctorReport};
use printbridge_ipc::{Client, InProcessClient, Request, Response};

pub fn run(args: &[String], output: &mut impl Write, error: &mut impl Write) -> i32 {
    let (trace, command) = parse_args(args);
    if trace {
        let event = TraceEvent {
            level: TraceLevel::Info,
            event: "cli_command",
            fields: vec![
                TraceField::public("command", command),
                TraceField::public("provider", "fake-in-memory"),
            ],
        };
        if writeln!(error, "{}", event.to_json_line()).is_err() {
            return 1;
        }
    }

    let agent = AgentService::fake_ready();
    let mut client = InProcessClient::new(agent);
    let response = match command {
        "status" => client.send(Request::GetStatus),
        "doctor" => client.send(Request::Doctor),
        "help" | "--help" | "-h" | "" => client.send(Request::Help),
        _ => {
            let _ = writeln!(error, "Unknown command. Run 'printbridgectl help'.");
            return 2;
        }
    };
    render_response(response, output, error)
}

fn parse_args(args: &[String]) -> (bool, &str) {
    match args {
        [flag, command, ..] if flag == "--trace" => (true, command.as_str()),
        [command, ..] => (false, command.as_str()),
        [] => (false, ""),
    }
}

fn render_response(response: Response, output: &mut impl Write, error: &mut impl Write) -> i32 {
    match response {
        Response::Status(status) => write_status(&status, output),
        Response::Doctor(report) => write_doctor(&report, output),
        Response::Help(text) => match writeln!(output, "{text}") {
            Ok(()) => 0,
            Err(_) => 1,
        },
        Response::Error { code, message } => {
            let _ = writeln!(error, "{code}: {message}");
            1
        }
    }
}

fn write_status(status: &BridgeStatus, output: &mut impl Write) -> i32 {
    let result = writeln!(output, "provider: fake-in-memory")
        .and_then(|()| writeln!(output, "overall: {}", status.phase))
        .and_then(|()| writeln!(output, "hypervisor: {}", status.components.hypervisor.state))
        .and_then(|()| writeln!(output, "guest: {}", status.components.guest.state))
        .and_then(|()| writeln!(output, "usb: {}", status.components.usb.state))
        .and_then(|()| writeln!(output, "cups: {}", status.components.cups.state))
        .and_then(|()| {
            writeln!(
                output,
                "windows_queue: {}",
                status.components.windows_queue.state
            )
        })
        .and_then(|()| writeln!(output, "physical_output: not_inferred"));
    if result.is_ok() { 0 } else { 1 }
}

fn write_doctor(report: &DoctorReport, output: &mut impl Write) -> i32 {
    if writeln!(output, "provider: {}", report.provider).is_err() {
        return 1;
    }
    for check in &report.checks {
        let label = match check.state {
            CheckState::Pass => "PASS",
            CheckState::Warn => "WARN",
            CheckState::Fail => "FAIL",
        };
        if writeln!(output, "[{label}] {} - {}", check.name, check.detail).is_err() {
            return 1;
        }
        if let Some(action) = &check.action
            && writeln!(output, "       action: {action}").is_err()
        {
            return 1;
        }
    }
    let passed = report.passed();
    if writeln!(output, "doctor: {}", if passed { "PASS" } else { "FAIL" }).is_err() {
        return 1;
    }
    if passed { 0 } else { 1 }
}

#[cfg(test)]
mod tests {
    use super::run;

    #[test]
    fn status_uses_fake_and_never_claims_physical_output() {
        let mut output = Vec::new();
        let mut error = Vec::new();
        let code = run(&["status".into()], &mut output, &mut error);
        let text = String::from_utf8(output).expect("CLI emits UTF-8");
        assert_eq!(code, 0);
        assert!(text.contains("provider: fake-in-memory"));
        assert!(text.contains("overall: ready"));
        assert!(text.contains("physical_output: not_inferred"));
        assert!(error.is_empty());
    }

    #[test]
    fn doctor_passes_all_fake_contract_checks() {
        let mut output = Vec::new();
        let mut error = Vec::new();
        let code = run(&["doctor".into()], &mut output, &mut error);
        let text = String::from_utf8(output).expect("CLI emits UTF-8");
        assert_eq!(code, 0);
        assert!(text.contains("doctor: PASS"));
        assert_eq!(text.matches("[PASS]").count(), 5);
    }

    #[test]
    fn trace_is_structured_and_does_not_echo_extra_arguments() {
        let secret = "SERIAL-DO-NOT-LOG";
        let mut output = Vec::new();
        let mut error = Vec::new();
        let code = run(
            &["--trace".into(), "status".into(), secret.into()],
            &mut output,
            &mut error,
        );
        let trace = String::from_utf8(error).expect("trace emits UTF-8");
        assert_eq!(code, 0);
        assert!(trace.starts_with('{'));
        assert!(trace.contains("\"event\":\"cli_command\""));
        assert!(!trace.contains(secret));
    }

    #[test]
    fn unknown_command_is_actionable() {
        let mut output = Vec::new();
        let mut error = Vec::new();
        let code = run(&["not-a-command".into()], &mut output, &mut error);
        assert_eq!(code, 2);
        assert!(
            String::from_utf8(error)
                .expect("error emits UTF-8")
                .contains("printbridgectl help")
        );
    }
}
