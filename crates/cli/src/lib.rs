use std::env;
use std::io::Write;
use std::path::{Path, PathBuf};

use printbridge_agent::{M3AgentService, M3Config, m3_help_text};
use printbridge_core::{TraceEvent, TraceField, TraceLevel};
use printbridge_domain::{CheckState, ComponentStatus, DoctorReport, UsbDevice};
use printbridge_ipc::{Client, InProcessClient, Request, Response};

pub fn run(args: &[String], output: &mut impl Write, error: &mut impl Write) -> i32 {
    let invocation = match parse_args(args) {
        Ok(invocation) => invocation,
        Err(message) => {
            let _ = writeln!(error, "{message}\nRun 'printbridgectl help'.");
            return 2;
        }
    };
    if invocation.request == Request::Help {
        return render_response(Response::Help(m3_help_text().into()), output, error);
    }
    let config = match load_config(invocation.config_path.as_deref()) {
        Ok(config) => config,
        Err(config_error) => {
            return render_response(error_response(config_error), output, error);
        }
    };
    let agent = match M3AgentService::discover(config) {
        Ok(agent) => agent,
        Err(provider_error) => {
            return render_response(
                Response::Error {
                    code: provider_error.kind().as_str().into(),
                    message: provider_error.to_string(),
                },
                output,
                error,
            );
        }
    };
    let mut client = InProcessClient::new(agent);
    run_invocation(invocation, &mut client, output, error)
}

fn run_invocation(
    invocation: Invocation,
    client: &mut impl Client,
    output: &mut impl Write,
    error: &mut impl Write,
) -> i32 {
    if invocation.trace {
        let event = TraceEvent {
            level: TraceLevel::Info,
            event: "cli_command",
            fields: vec![
                TraceField::public("command", invocation.command_label),
                TraceField::public("provider", "virtualbox-real"),
            ],
        };
        if writeln!(error, "{}", event.to_json_line()).is_err() {
            return 1;
        }
    }
    render_response(client.send(invocation.request), output, error)
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Invocation {
    trace: bool,
    config_path: Option<PathBuf>,
    request: Request,
    command_label: &'static str,
}

fn parse_args(args: &[String]) -> Result<Invocation, String> {
    let mut trace = false;
    let mut config_path = None;
    let mut position = 0;
    while position < args.len() {
        match args[position].as_str() {
            "--trace" => {
                trace = true;
                position += 1;
            }
            "--config" => {
                let path = args
                    .get(position + 1)
                    .ok_or_else(|| "--config requires a path".to_string())?;
                config_path = Some(PathBuf::from(path));
                position += 2;
            }
            _ => break,
        }
    }
    let command = &args[position..];
    let (request, command_label) = match command {
        [] => (Request::Help, "help"),
        [value] if matches!(value.as_str(), "help" | "--help" | "-h") => (Request::Help, "help"),
        [value] if value == "doctor" => (Request::Doctor, "doctor"),
        [group, action] if group == "vm" && action == "status" => (Request::VmStatus, "vm_status"),
        [group, action] if group == "vm" && action == "start" => (Request::VmStart, "vm_start"),
        [group, action] if group == "vm" && action == "stop" => (Request::VmStop, "vm_stop"),
        [group, action] if group == "usb" && action == "list" => (Request::UsbList, "usb_list"),
        [group, action] if group == "usb" && action == "attach" => {
            (Request::UsbAttach, "usb_attach")
        }
        [group, action, flag, index]
            if group == "usb" && action == "attach" && flag == "--index" =>
        {
            (Request::UsbAttachAt(parse_index(index)?), "usb_attach")
        }
        [group, action] if group == "usb" && action == "release" => {
            (Request::UsbRelease, "usb_release")
        }
        [group, action, flag, index]
            if group == "usb" && action == "release" && flag == "--index" =>
        {
            (Request::UsbReleaseAt(parse_index(index)?), "usb_release")
        }
        _ => return Err("Unknown or incomplete command.".into()),
    };
    Ok(Invocation {
        trace,
        config_path,
        request,
        command_label,
    })
}

fn parse_index(value: &str) -> Result<usize, String> {
    let parsed = value
        .parse::<usize>()
        .map_err(|_| "--index must be a positive integer".to_string())?;
    if parsed == 0 {
        return Err("--index uses one-based values and must be at least 1".into());
    }
    Ok(parsed)
}

fn load_config(
    explicit: Option<&Path>,
) -> Result<Option<M3Config>, printbridge_domain::BridgeError> {
    let configured = explicit
        .map(Path::to_path_buf)
        .or_else(|| env::var_os("PRINTBRIDGE_M3_CONFIG").map(PathBuf::from));
    if let Some(path) = configured {
        return M3Config::load(&path).map(Some);
    }
    let Some(local_app_data) = env::var_os("LOCALAPPDATA") else {
        return Ok(None);
    };
    let default = PathBuf::from(local_app_data).join("PrintBridge/m3.conf");
    if default.is_file() {
        M3Config::load(&default).map(Some)
    } else {
        Ok(None)
    }
}

fn error_response(error: printbridge_domain::BridgeError) -> Response {
    Response::Error {
        code: error.kind().as_str().into(),
        message: error.to_string(),
    }
}

fn render_response(response: Response, output: &mut impl Write, error: &mut impl Write) -> i32 {
    match response {
        Response::Status(_) => {
            let _ = writeln!(
                error,
                "unsupported_response: M3 does not render aggregate status"
            );
            1
        }
        Response::Doctor(report) => write_doctor(&report, output),
        Response::VmStatus(status) => write_component("vm", &status, output),
        Response::UsbDevices(devices) => write_usb_devices(&devices, output),
        Response::OperationComplete { operation } => match writeln!(output, "{operation}: ok") {
            Ok(()) => 0,
            Err(_) => 1,
        },
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

fn write_component(name: &str, status: &ComponentStatus, output: &mut impl Write) -> i32 {
    let result = writeln!(output, "provider: virtualbox-real")
        .and_then(|()| writeln!(output, "{name}: {}", status.state))
        .and_then(|()| match &status.detail {
            Some(detail) => writeln!(output, "detail: {detail}"),
            None => Ok(()),
        });
    if result.is_ok() { 0 } else { 1 }
}

fn write_usb_devices(devices: &[UsbDevice], output: &mut impl Write) -> i32 {
    if writeln!(output, "provider: virtualbox-real").is_err() {
        return 1;
    }
    if devices.is_empty() {
        return if writeln!(output, "usb_devices: none").is_ok() {
            0
        } else {
            1
        };
    }
    for (position, device) in devices.iter().enumerate() {
        let serial = if device.identity.serial.is_some() {
            "present (redacted)"
        } else {
            "absent"
        };
        if writeln!(
            output,
            "{}: {} | {} | serial={serial}",
            position + 1,
            device.identity,
            device.display_name
        )
        .is_err()
        {
            return 1;
        }
    }
    0
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
    use printbridge_domain::{ComponentState, ComponentStatus, UsbDevice, UsbIdentity};
    use printbridge_ipc::{Client, Request, Response};

    use super::{parse_args, run_invocation};

    struct StubClient {
        response: Option<Response>,
        request: Option<Request>,
    }

    impl StubClient {
        fn returning(response: Response) -> Self {
            Self {
                response: Some(response),
                request: None,
            }
        }
    }

    impl Client for StubClient {
        fn send(&mut self, request: Request) -> Response {
            self.request = Some(request);
            self.response.take().expect("one response")
        }
    }

    #[test]
    fn parses_every_m3_command_and_one_based_usb_selection() {
        let cases = [
            (vec!["doctor"], Request::Doctor),
            (vec!["vm", "status"], Request::VmStatus),
            (vec!["vm", "start"], Request::VmStart),
            (vec!["vm", "stop"], Request::VmStop),
            (vec!["usb", "list"], Request::UsbList),
            (vec!["usb", "attach"], Request::UsbAttach),
            (
                vec!["usb", "attach", "--index", "2"],
                Request::UsbAttachAt(2),
            ),
            (vec!["usb", "release"], Request::UsbRelease),
            (
                vec!["usb", "release", "--index", "1"],
                Request::UsbReleaseAt(1),
            ),
        ];
        for (arguments, expected) in cases {
            let arguments: Vec<String> = arguments.into_iter().map(str::to_string).collect();
            assert_eq!(parse_args(&arguments).expect("command").request, expected);
        }
    }

    #[test]
    fn vm_status_is_rendered_as_real_provider() {
        let invocation = parse_args(&["vm".into(), "status".into()]).expect("args");
        let mut client = StubClient::returning(Response::VmStatus(ComponentStatus::new(
            ComponentState::Ready,
        )));
        let mut output = Vec::new();
        let mut error = Vec::new();
        assert_eq!(
            run_invocation(invocation, &mut client, &mut output, &mut error),
            0
        );
        let output = String::from_utf8(output).expect("UTF-8");
        assert!(output.contains("provider: virtualbox-real"));
        assert!(output.contains("vm: ready"));
        assert_eq!(client.request, Some(Request::VmStatus));
    }

    #[test]
    fn usb_list_redacts_serial_value() {
        let secret = "SERIAL-DO-NOT-PRINT";
        let invocation = parse_args(&["usb".into(), "list".into()]).expect("args");
        let mut client = StubClient::returning(Response::UsbDevices(vec![UsbDevice {
            identity: UsbIdentity {
                vendor_id: 0x04f9,
                product_id: 0x0567,
                serial: Some(secret.into()),
            },
            display_name: "Brother DCP-L2600D".into(),
            host_id: Some("opaque-host-id".into()),
        }]));
        let mut output = Vec::new();
        let mut error = Vec::new();
        assert_eq!(
            run_invocation(invocation, &mut client, &mut output, &mut error),
            0
        );
        let output = String::from_utf8(output).expect("UTF-8");
        assert!(output.contains("serial=present (redacted)"));
        assert!(!output.contains(secret));
        assert!(!output.contains("opaque-host-id"));
    }

    #[test]
    fn trace_does_not_echo_config_path_or_extra_values() {
        let invocation = parse_args(&[
            "--trace".into(),
            "--config".into(),
            "C:\\secret\\serial.conf".into(),
            "vm".into(),
            "status".into(),
        ])
        .expect("args");
        let mut client = StubClient::returning(Response::VmStatus(ComponentStatus::new(
            ComponentState::Stopped,
        )));
        let mut output = Vec::new();
        let mut error = Vec::new();
        assert_eq!(
            run_invocation(invocation, &mut client, &mut output, &mut error),
            0
        );
        let trace = String::from_utf8(error).expect("UTF-8");
        assert!(trace.contains("\"command\":\"vm_status\""));
        assert!(!trace.contains("serial.conf"));
    }

    #[test]
    fn unknown_and_zero_index_are_rejected() {
        assert!(parse_args(&["not-a-command".into()]).is_err());
        assert!(
            parse_args(&["usb".into(), "attach".into(), "--index".into(), "0".into()]).is_err()
        );
    }
}
