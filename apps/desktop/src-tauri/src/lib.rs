mod client;
mod runtime;

use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

#[cfg(windows)]
use std::os::windows::process::CommandExt;
#[cfg(windows)]
use std::process::Command as ProcessCommand;

use client::{AgentClient, DesktopError};
use printbridge_ipc::{
    AgentStatus, Command, DeviceSummary, Diagnostics, OperationResult, TestPrintResult,
};
use serde::Serialize;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, State, WindowEvent};

#[derive(Clone, Serialize)]
struct TrayOperation {
    ok: bool,
    message: String,
}

#[tauri::command]
async fn agent_get_status(client: State<'_, AgentClient>) -> Result<AgentStatus, DesktopError> {
    client.inner().clone().status().await
}

#[tauri::command]
async fn agent_discover_devices(
    client: State<'_, AgentClient>,
) -> Result<Vec<DeviceSummary>, DesktopError> {
    client.inner().clone().devices().await
}

#[tauri::command]
async fn agent_begin_setup(
    client: State<'_, AgentClient>,
    device_index: usize,
) -> Result<OperationResult, DesktopError> {
    client
        .inner()
        .clone()
        .operation(Command::BeginSetup { device_index })
        .await
}

#[tauri::command]
async fn agent_start(client: State<'_, AgentClient>) -> Result<OperationResult, DesktopError> {
    client.inner().clone().operation(Command::Start).await
}

#[tauri::command]
async fn agent_stop(client: State<'_, AgentClient>) -> Result<OperationResult, DesktopError> {
    client.inner().clone().operation(Command::Stop).await
}

#[tauri::command]
async fn agent_restart(client: State<'_, AgentClient>) -> Result<OperationResult, DesktopError> {
    client.inner().clone().operation(Command::Restart).await
}

#[tauri::command]
async fn agent_test_print(client: State<'_, AgentClient>) -> Result<TestPrintResult, DesktopError> {
    client.inner().clone().test_print().await
}

#[tauri::command]
async fn agent_get_diagnostics(
    client: State<'_, AgentClient>,
) -> Result<Diagnostics, DesktopError> {
    client.inner().clone().diagnostics().await
}

#[tauri::command]
async fn agent_repair(client: State<'_, AgentClient>) -> Result<OperationResult, DesktopError> {
    client.inner().clone().operation(Command::Repair).await
}

#[tauri::command]
async fn open_scanner(client: State<'_, AgentClient>) -> Result<(), DesktopError> {
    let status = client.inner().clone().status().await?;
    if !status.scanner.available || !valid_scanner_url(&status.scanner.loopback_url) {
        return Err(DesktopError {
            code: "scanner_unavailable".into(),
            message: "The local eSCL scanner is not ready.".into(),
            action: Some("Power on and connect the selected USB device, then run Repair.".into()),
            retryable: true,
        });
    }
    open_scanner_url(&status.scanner.loopback_url)
}

fn valid_scanner_url(value: &str) -> bool {
    value
        .strip_prefix("http://127.0.0.1:")
        .and_then(|value| value.strip_suffix('/'))
        .and_then(|port| port.parse::<u16>().ok())
        .is_some_and(|port| port != 0)
}

fn open_scanner_url(url: &str) -> Result<(), DesktopError> {
    #[cfg(windows)]
    {
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        ProcessCommand::new("explorer.exe")
            .arg(url)
            .creation_flags(CREATE_NO_WINDOW)
            .spawn()
            .map(drop)
            .map_err(scanner_open_error)
    }
    #[cfg(not(windows))]
    {
        let _ = url;
        Err(scanner_open_error(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "desktop scanner opening is supported only on Windows",
        )))
    }
}

fn scanner_open_error(error: std::io::Error) -> DesktopError {
    DesktopError {
        code: "scanner_open_failed".into(),
        message: format!("Cannot open the scanner page: {error}"),
        action: Some("Open the Scan screen and try again.".into()),
        retryable: true,
    }
}

#[tauri::command]
async fn export_diagnostics(
    app: AppHandle,
    client: State<'_, AgentClient>,
) -> Result<String, DesktopError> {
    let diagnostics = client.inner().clone().diagnostics().await?;
    let documents = app.path().document_dir().map_err(|error| DesktopError {
        code: "diagnostics_export_failed".into(),
        message: format!("Cannot locate the Documents folder: {error}"),
        action: Some("Check your Windows Documents folder and try again.".into()),
        retryable: true,
    })?;
    let directory = documents.join("PrintBridge");
    fs::create_dir_all(&directory).map_err(export_error)?;
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    let path = directory.join(format!("diagnostics-{timestamp}.json"));
    let bytes = serde_json::to_vec_pretty(&diagnostics).map_err(|error| DesktopError {
        code: "diagnostics_export_failed".into(),
        message: format!("Cannot serialize the diagnostic report: {error}"),
        action: Some("Refresh diagnostics and try again.".into()),
        retryable: true,
    })?;
    fs::write(&path, bytes).map_err(export_error)?;
    Ok(path.to_string_lossy().into_owned())
}

#[tauri::command]
async fn exit_printbridge(
    app: AppHandle,
    client: State<'_, AgentClient>,
) -> Result<(), DesktopError> {
    client.inner().clone().operation(Command::Shutdown).await?;
    app.exit(0);
    Ok(())
}

fn export_error(error: std::io::Error) -> DesktopError {
    DesktopError {
        code: "diagnostics_export_failed".into(),
        message: format!("Cannot write the diagnostic report: {error}"),
        action: Some("Check access to Documents\\PrintBridge and try again.".into()),
        retryable: true,
    }
}

fn show_main_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

fn emit_navigation(app: &AppHandle, screen: &str) {
    show_main_window(app);
    let _ = app.emit("printbridge:navigate", screen);
}

fn spawn_tray_command(app: AppHandle, command: Command) {
    let client = app.state::<AgentClient>().inner().clone();
    tauri::async_runtime::spawn(async move {
        let result = client.request(command).await;
        let event = match result {
            Ok(payload) => TrayOperation {
                ok: true,
                message: match payload {
                    printbridge_ipc::Payload::TestPrint(value) => format!(
                        "Test page accepted by Windows (job {}). Confirm the paper output.",
                        value
                            .spooler_job_id
                            .map_or_else(|| "unknown".into(), |id| id.to_string())
                    ),
                    printbridge_ipc::Payload::Operation(value) => value.detail,
                    _ => "Operation completed.".into(),
                },
            },
            Err(error) => TrayOperation {
                ok: false,
                message: error.message,
            },
        };
        let _ = app.emit("printbridge:operation", event);
    });
}

fn build_tray(app: &tauri::App) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "Open PrintBridge", true, None::<&str>)?;
    let test = MenuItem::with_id(app, "test", "Test page", true, None::<&str>)?;
    let restart = MenuItem::with_id(app, "restart", "Restart bridge", true, None::<&str>)?;
    let diagnostics =
        MenuItem::with_id(app, "diagnostics", "View diagnostics", true, None::<&str>)?;
    let exit = MenuItem::with_id(
        app,
        "exit",
        "Exit PrintBridge (stop sharing)",
        true,
        None::<&str>,
    )?;
    let menu = Menu::with_items(app, &[&open, &test, &restart, &diagnostics, &exit])?;

    TrayIconBuilder::with_id("printbridge-tray")
        .icon(app.default_window_icon().expect("desktop icon").clone())
        .tooltip("PrintBridge — LAN printing and scanning are available while this app is running")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show_main_window(app),
            "test" => {
                show_main_window(app);
                spawn_tray_command(app.clone(), Command::TestPrint);
            }
            "restart" => {
                show_main_window(app);
                spawn_tray_command(app.clone(), Command::Restart);
            }
            "diagnostics" => emit_navigation(app, "diagnostics"),
            "exit" => {
                let app = app.clone();
                let client = app.state::<AgentClient>().inner().clone();
                tauri::async_runtime::spawn(async move {
                    match client.operation(Command::Shutdown).await {
                        Ok(_) => app.exit(0),
                        Err(error) => {
                            let _ = app.emit(
                                "printbridge:operation",
                                TrayOperation {
                                    ok: false,
                                    message: error.message,
                                },
                            );
                            show_main_window(&app);
                        }
                    }
                });
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if matches!(
                event,
                TrayIconEvent::Click {
                    button: MouseButton::Left,
                    button_state: MouseButtonState::Up,
                    ..
                }
            ) {
                show_main_window(tray.app_handle());
            }
        })
        .build(app)?;
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(AgentClient::default())
        .setup(|app| {
            build_tray(app)?;
            let resource_dir = app.path().resource_dir()?;
            runtime::start(
                app.handle().clone(),
                resource_dir,
                app.state::<AgentClient>().inner().clone(),
            );
            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![
            agent_get_status,
            agent_discover_devices,
            agent_begin_setup,
            agent_start,
            agent_stop,
            agent_restart,
            agent_test_print,
            agent_get_diagnostics,
            agent_repair,
            open_scanner,
            export_diagnostics,
            exit_printbridge,
        ])
        .run(tauri::generate_context!())
        .expect("PrintBridge desktop runtime failed");
}

#[cfg(test)]
mod tests {
    #[test]
    fn scanner_launcher_accepts_only_fixed_loopback_http_shape() {
        assert!(super::valid_scanner_url("http://127.0.0.1:8645/"));
        for unsafe_url in [
            "https://127.0.0.1:8645/",
            "http://192.168.1.20:8645/",
            "http://127.0.0.1:8645/eSCL/ScannerCapabilities",
            "http://127.0.0.1:0/",
            "http://127.0.0.1:8645/?command=run",
        ] {
            assert!(!super::valid_scanner_url(unsafe_url));
        }
    }
}
