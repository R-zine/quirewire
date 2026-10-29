use std::env;
use std::io::Write;
use std::path::{Path, PathBuf};

use printbridge_agent::{M3AgentService, M3Config, M5AgentService, M5Config};
use printbridge_core::{TraceEvent, TraceField, TraceLevel};
use printbridge_domain::{
    CheckState, ComponentStatus, DoctorReport, JobState, UsbDevice, WindowsPrintSubmission,
    WindowsQueueStatus,
};
use printbridge_ipc::{
    Client, Command, CommandResult, InProcessClient, Payload, Request, RequestEnvelope, Response,
};

pub fn run(args: &[String], output: &mut impl Write, error: &mut impl Write) -> i32 {
    match parse_m6_command(args) {
        Some(Ok(command)) => return run_m6(command, output, error),
        Some(Err(message)) => {
            let _ = writeln!(error, "{message}\nRun 'printbridgectl help'.");
            return 2;
        }
        None => {}
    }
    let invocation = match parse_args(args) {
        Ok(invocation) => invocation,
        Err(message) => {
            let _ = writeln!(error, "{message}\nRun 'printbridgectl help'.");
            return 2;
        }
    };
    if invocation.request == Request::Help {
        return render_response(Response::Help(cli_help_text().into()), output, error);
    }
    if is_printer_request(&invocation.request) {
        let config = match load_m5_config(invocation.config_path.as_deref()) {
            Ok(config) => config,
            Err(config_error) => {
                return render_response(error_response(config_error), output, error);
            }
        };
        let agent = match M5AgentService::discover(config) {
            Ok(agent) => agent,
            Err(provider_error) => {
                return render_response(error_response(provider_error), output, error);
            }
        };
        let mut client = InProcessClient::new(agent);
        run_invocation(invocation, &mut client, output, error)
    } else {
        let config = match load_m3_config(invocation.config_path.as_deref()) {
            Ok(config) => config,
            Err(config_error) => {
                return render_response(error_response(config_error), output, error);
            }
        };
        let agent = match M3AgentService::discover(config) {
            Ok(agent) => agent,
            Err(provider_error) => {
                return render_response(error_response(provider_error), output, error);
            }
        };
        let mut client = InProcessClient::new(agent);
        run_invocation(invocation, &mut client, output, error)
    }
}

fn parse_m6_command(args: &[String]) -> Option<Result<Command, String>> {
    let command = args
        .iter()
        .position(|value| !matches!(value.as_str(), "--trace" | "--config"))
        .and_then(|position| {
            if position > 0
                && args
                    .get(position - 1)
                    .is_some_and(|value| value == "--config")
            {
                args.get(position + 1..)
            } else {
                args.get(position..)
            }
        })
        .unwrap_or(args);
    let parsed = match command {
        [value] if value == "status" => Ok(Command::GetStatus),
        [value] if value == "devices" => Ok(Command::DiscoverDevices),
        [value] if value == "start" => Ok(Command::Start),
        [value] if value == "stop" => Ok(Command::Stop),
        [value] if value == "restart" => Ok(Command::Restart),
        [value] if value == "test-print" => Ok(Command::TestPrint),
        [value] if value == "diagnostics" => Ok(Command::GetDiagnostics),
        [value] if value == "repair" => Ok(Command::Repair),
        [value, flag, index] if value == "setup" && flag == "--index" => index
            .parse::<usize>()
            .ok()
            .filter(|value| *value > 0)
            .map(|device_index| Command::BeginSetup { device_index })
            .ok_or_else(|| "setup --index requires a positive one-based integer".into()),
        [value, ..]
            if matches!(
                value.as_str(),
                "status"
                    | "devices"
                    | "setup"
                    | "start"
                    | "stop"
                    | "restart"
                    | "test-print"
                    | "diagnostics"
                    | "repair"
            ) =>
        {
            Err("Invalid M6 agent command arguments.".into())
        }
        _ => return None,
    };
    Some(parsed)
}

fn run_m6(command: Command, output: &mut impl Write, error: &mut impl Write) -> i32 {
    #[cfg(not(windows))]
    {
        let _ = command;
        let _ = output;
        let _ = writeln!(
            error,
            "unsupported_platform: M6 named-pipe IPC requires Windows"
        );
        return 1;
    }
    #[cfg(windows)]
    {
        let sid = match printbridge_ipc::windows_pipe::current_user_sid() {
            Ok(value) => value,
            Err(failure) => {
                let _ = writeln!(error, "ipc_identity: {failure}");
                return 1;
            }
        };
        let pipe_name = printbridge_ipc::windows_pipe::pipe_name_for_sid(&sid);
        let request_id = format!(
            "cli-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        );
        let request = RequestEnvelope::new(request_id, command);
        let runtime = match tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
        {
            Ok(value) => value,
            Err(failure) => {
                let _ = writeln!(error, "ipc_runtime: {failure}");
                return 1;
            }
        };
        let response = match runtime.block_on(printbridge_ipc::windows_pipe::send(
            &pipe_name,
            &request,
            std::time::Duration::from_secs(90),
        )) {
            Ok(value) => value,
            Err(failure) => {
                let _ = writeln!(
                    error,
                    "agent_unavailable: {failure}. Start the per-user PrintBridge agent."
                );
                return 1;
            }
        };
        match response.result {
            CommandResult::Ok { payload } => render_m6_payload(&payload, output),
            CommandResult::Error { error: payload } => {
                let _ = writeln!(error, "{}: {}", payload.code, payload.message);
                1
            }
        }
    }
}

fn render_m6_payload(payload: &Payload, output: &mut impl Write) -> i32 {
    let rendered = match serde_json::to_string_pretty(payload) {
        Ok(value) => value,
        Err(error) => {
            let _ = writeln!(output, "serialization_error: {error}");
            return 1;
        }
    };
    if writeln!(output, "{rendered}").is_ok() {
        0
    } else {
        1
    }
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
                TraceField::public("provider", provider_label(&invocation.request)),
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
        [group, action] if group == "printer" && action == "install" => {
            (Request::PrinterInstall, "printer_install")
        }
        [group, action] if group == "printer" && action == "status" => {
            (Request::PrinterStatus, "printer_status")
        }
        [group, action] if group == "printer" && action == "test-page" => {
            (Request::PrinterTestPage, "printer_test_page")
        }
        [group, action] if group == "printer" && action == "remove" => {
            (Request::PrinterRemove, "printer_remove")
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

fn load_m3_config(
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

fn load_m5_config(explicit: Option<&Path>) -> Result<M5Config, printbridge_domain::BridgeError> {
    let configured = explicit
        .map(Path::to_path_buf)
        .or_else(|| env::var_os("PRINTBRIDGE_M5_CONFIG").map(PathBuf::from));
    if let Some(path) = configured {
        return M5Config::load(&path);
    }
    let local_app_data = env::var_os("LOCALAPPDATA").ok_or_else(|| {
        printbridge_domain::BridgeError::MissingDependency {
            dependency: "M5 configuration".into(),
            action: "Pass --config <path> using printbridge.m5.config.v1.".into(),
        }
    })?;
    let default = PathBuf::from(local_app_data).join("PrintBridge/m5.conf");
    if default.is_file() {
        M5Config::load(&default)
    } else {
        Err(printbridge_domain::BridgeError::MissingDependency {
            dependency: format!("M5 configuration at {}", default.display()),
            action: "Pass --config <path> or create the documented per-user m5.conf.".into(),
        })
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
        Response::PrinterStatus(status) => write_printer_status(&status, output),
        Response::PrinterTestPage(submission) => write_print_submission(&submission, output),
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

fn write_printer_status(status: &WindowsQueueStatus, output: &mut impl Write) -> i32 {
    let queue_found = status.queue.is_some();
    let result = writeln!(output, "provider: windows-printmanagement-real")
        .and_then(|()| writeln!(output, "ipp_url_supported: {}", status.ipp_url_supported))
        .and_then(|()| {
            writeln!(
                output,
                "spooler: {}",
                if status.spooler_running {
                    "running"
                } else {
                    "stopped"
                }
            )
        })
        .and_then(|()| writeln!(output, "queue_found: {queue_found}"))
        .and_then(|()| writeln!(output, "ownership_verified: {}", status.ownership_verified))
        .and_then(|()| writeln!(output, "default_printer: {}", status.is_default))
        .and_then(|()| writeln!(output, "endpoint: {}", status.endpoint));
    if result.is_err() {
        return 1;
    }
    if let Some(queue) = &status.queue {
        if writeln!(output, "queue_name: {}", queue.name)
            .and_then(|()| writeln!(output, "driver: {}", queue.driver))
            .and_then(|()| {
                writeln!(
                    output,
                    "port: {}",
                    status.port_name.as_deref().unwrap_or("<unavailable>")
                )
            })
            .and_then(|()| {
                writeln!(
                    output,
                    "printer_status: {}",
                    status.printer_status.as_deref().unwrap_or("<unavailable>")
                )
            })
            .is_err()
        {
            return 1;
        }
    }
    if writeln!(output, "physical_output: not_inferred").is_ok() {
        0
    } else {
        1
    }
}

fn write_print_submission(submission: &WindowsPrintSubmission, output: &mut impl Write) -> i32 {
    let state = match submission.state {
        JobState::Accepted => "accepted_by_windows_spooler",
        JobState::CompletedByCups => "completed_by_cups",
        JobState::PhysicalOutputConfirmed => "physical_output_confirmed",
        JobState::Failed => "failed",
    };
    let job_id = submission
        .spooler_job_id
        .map_or_else(|| "not_observed".into(), |value| value.to_string());
    let result = writeln!(output, "provider: windows-printmanagement-real")
        .and_then(|()| writeln!(output, "submission: {state}"))
        .and_then(|()| writeln!(output, "correlation_id: {}", submission.correlation_id))
        .and_then(|()| writeln!(output, "spooler_job_id: {job_id}"))
        .and_then(|()| writeln!(output, "cups_processing: not_inferred"))
        .and_then(|()| writeln!(output, "physical_output: not_inferred"));
    if result.is_ok() { 0 } else { 1 }
}

fn is_printer_request(request: &Request) -> bool {
    matches!(
        request,
        Request::PrinterInstall
            | Request::PrinterStatus
            | Request::PrinterTestPage
            | Request::PrinterRemove
    )
}

fn provider_label(request: &Request) -> &'static str {
    if is_printer_request(request) {
        "windows-printmanagement-real"
    } else {
        "virtualbox-real"
    }
}

const fn cli_help_text() -> &'static str {
    "PrintBridge M6 CLI\n\
Usage: printbridgectl [--trace] [--config <path>] <command>\n\n\
Headless agent commands (named-pipe IPC):\n\
  status | devices | setup --index N | start | stop | restart\n\
  test-print | diagnostics | repair\n\n\
VirtualBox commands (M3 config):\n\
  doctor | vm status | vm start | vm stop\n\
  usb list | usb attach [--index N] | usb release [--index N]\n\n\
Windows printing commands (M5 config):\n\
  printer install | printer status | printer test-page | printer remove\n\n\
The printer test page proves Windows spooler submission only. CUPS processing and physical paper output are reported separately."
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
    use printbridge_domain::{
        ComponentState, ComponentStatus, JobState, UsbDevice, UsbIdentity, WindowsPrintSubmission,
        WindowsQueueStatus,
    };
    use printbridge_ipc::{Client, Command, Request, Response};

    use super::{parse_args, parse_m6_command, run_invocation};

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
    fn parses_every_supported_command_and_one_based_usb_selection() {
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
            (vec!["printer", "install"], Request::PrinterInstall),
            (vec!["printer", "status"], Request::PrinterStatus),
            (vec!["printer", "test-page"], Request::PrinterTestPage),
            (vec!["printer", "remove"], Request::PrinterRemove),
        ];
        for (arguments, expected) in cases {
            let arguments: Vec<String> = arguments.into_iter().map(str::to_string).collect();
            assert_eq!(parse_args(&arguments).expect("command").request, expected);
        }
    }

    #[test]
    fn parses_every_m6_named_pipe_command() {
        let cases = [
            (vec!["status"], Command::GetStatus),
            (vec!["devices"], Command::DiscoverDevices),
            (vec!["start"], Command::Start),
            (vec!["stop"], Command::Stop),
            (vec!["restart"], Command::Restart),
            (vec!["test-print"], Command::TestPrint),
            (vec!["diagnostics"], Command::GetDiagnostics),
            (vec!["repair"], Command::Repair),
            (
                vec!["setup", "--index", "2"],
                Command::BeginSetup { device_index: 2 },
            ),
        ];
        for (arguments, expected) in cases {
            let arguments: Vec<String> = arguments.into_iter().map(str::to_string).collect();
            assert_eq!(
                parse_m6_command(&arguments).expect("M6").expect("valid"),
                expected
            );
        }
        assert!(
            parse_m6_command(&["setup".into(), "--index".into(), "0".into()])
                .expect("M6")
                .is_err()
        );
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

    #[test]
    fn printer_status_and_submission_are_truthful() {
        let invocation = parse_args(&["printer".into(), "status".into()]).expect("args");
        let mut client = StubClient::returning(Response::PrinterStatus(WindowsQueueStatus {
            queue: Some(printbridge_domain::PrintQueue {
                name: "Brother via PrintBridge".into(),
                driver: "Microsoft IPP Class Driver".into(),
            }),
            endpoint: "http://127.0.0.1:8644/printers/PrintBridge_DCP_L2600D".into(),
            port_name: Some("WSD-test".into()),
            printer_status: Some("Normal".into()),
            spooler_running: true,
            ipp_url_supported: true,
            ownership_verified: true,
            is_default: false,
        }));
        let mut output = Vec::new();
        let mut error = Vec::new();
        assert_eq!(
            run_invocation(invocation, &mut client, &mut output, &mut error),
            0
        );
        let output = String::from_utf8(output).expect("UTF-8");
        assert!(output.contains("driver: Microsoft IPP Class Driver"));
        assert!(output.contains("physical_output: not_inferred"));

        let invocation = parse_args(&["printer".into(), "test-page".into()]).expect("args");
        let mut client = StubClient::returning(Response::PrinterTestPage(WindowsPrintSubmission {
            correlation_id: "m5-test".into(),
            spooler_job_id: Some(7),
            state: JobState::Accepted,
        }));
        let mut output = Vec::new();
        assert_eq!(
            run_invocation(invocation, &mut client, &mut output, &mut error),
            0
        );
        let output = String::from_utf8(output).expect("UTF-8");
        assert!(output.contains("accepted_by_windows_spooler"));
        assert!(output.contains("cups_processing: not_inferred"));
    }
}
