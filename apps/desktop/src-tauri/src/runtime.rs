use std::path::{Path, PathBuf};
use std::process::Command as ProcessCommand;
use std::time::Duration;

use quirewire_ipc::Command;
use tauri::{AppHandle, Emitter};

use crate::TrayOperation;
use crate::client::{AgentClient, DesktopError};

const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(5);
const RETRY_INTERVAL: Duration = Duration::from_millis(500);

#[derive(Clone)]
struct AgentLaunch {
    executable: PathBuf,
    config: PathBuf,
}

impl AgentLaunch {
    fn resolve(resource_dir: &Path) -> Result<Self, DesktopError> {
        let local_app_data = std::env::var_os("LOCALAPPDATA").ok_or_else(|| {
            DesktopError::runtime("LOCALAPPDATA is unavailable for the owner configuration.")
        })?;
        let config = PathBuf::from(local_app_data)
            .join("QuireWire")
            .join("m6.conf");
        let current = std::env::current_exe().map_err(|error| {
            DesktopError::runtime(format!("Cannot resolve the desktop executable: {error}"))
        })?;
        let parent = current.parent().unwrap_or(resource_dir);
        let candidates = [
            resource_dir.join("bin/quirewire-agent.exe"),
            parent.join("bin/quirewire-agent.exe"),
            parent.join("quirewire-agent.exe"),
            parent
                .parent()
                .unwrap_or(parent)
                .join("quirewire-agent.exe"),
        ];
        let executable = candidates
            .into_iter()
            .find(|path| path.is_file())
            .ok_or_else(|| DesktopError::runtime("The on-demand agent executable is missing."))?;
        if !config.is_file() {
            return Err(DesktopError::runtime(format!(
                "The owner configuration is missing at {}.",
                config.display()
            )));
        }
        Ok(Self { executable, config })
    }

    fn spawn_hidden(&self) -> Result<(), DesktopError> {
        let mut command = ProcessCommand::new(&self.executable);
        command.args([
            "run",
            "--config",
            self.config.to_string_lossy().as_ref(),
            "--on-demand",
        ]);
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000);
        }
        command.spawn().map(drop).map_err(|error| {
            DesktopError::runtime(format!("Cannot start the on-demand agent: {error}"))
        })
    }
}

pub fn start(app: AppHandle, resource_dir: PathBuf, client: AgentClient) {
    tauri::async_runtime::spawn(async move {
        let launch = match AgentLaunch::resolve(&resource_dir) {
            Ok(value) => value,
            Err(error) => {
                emit(&app, false, error.message);
                return;
            }
        };
        let mut connected = false;
        loop {
            match client.request(Command::Heartbeat).await {
                Ok(_) => {
                    if !connected {
                        match client.operation(Command::Start).await {
                            Ok(result) => emit(&app, true, result.detail),
                            Err(error) => emit(&app, false, error.message),
                        }
                        connected = true;
                    }
                    tokio::time::sleep(HEARTBEAT_INTERVAL).await;
                }
                Err(_) => {
                    connected = false;
                    if let Err(error) = launch.spawn_hidden() {
                        emit(&app, false, error.message);
                        tokio::time::sleep(HEARTBEAT_INTERVAL).await;
                    } else {
                        tokio::time::sleep(RETRY_INTERVAL).await;
                    }
                }
            }
        }
    });
}

fn emit(app: &AppHandle, ok: bool, message: String) {
    let _ = app.emit("quirewire:operation", TrayOperation { ok, message });
}
