use std::ffi::OsString;
use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use printbridge_domain::BridgeError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandOutput {
    pub exit_code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

pub trait CommandRunner: Send + Sync {
    fn run(
        &self,
        executable: &Path,
        arguments: &[OsString],
        timeout: Duration,
    ) -> Result<CommandOutput, BridgeError>;
}

#[derive(Debug, Clone, Copy, Default)]
pub struct ProcessRunner;

impl CommandRunner for ProcessRunner {
    fn run(
        &self,
        executable: &Path,
        arguments: &[OsString],
        timeout: Duration,
    ) -> Result<CommandOutput, BridgeError> {
        let mut child = Command::new(executable)
            .args(arguments)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| BridgeError::MissingDependency {
                dependency: executable.display().to_string(),
                action: format!("Install Windows PowerShell and PrintManagement ({error})."),
            })?;
        let stdout = child.stdout.take().ok_or_else(|| BridgeError::Internal {
            detail: "PowerShell stdout pipe was unavailable".into(),
        })?;
        let stderr = child.stderr.take().ok_or_else(|| BridgeError::Internal {
            detail: "PowerShell stderr pipe was unavailable".into(),
        })?;
        let stdout_reader = thread::spawn(move || read_all(stdout));
        let stderr_reader = thread::spawn(move || read_all(stderr));
        let started = Instant::now();
        let status = loop {
            if let Some(status) = child.try_wait().map_err(|error| BridgeError::Internal {
                detail: format!("failed to poll Windows PrintManagement: {error}"),
            })? {
                break status;
            }
            if started.elapsed() >= timeout {
                let _ = child.kill();
                let _ = child.wait();
                let _ = stdout_reader.join();
                let _ = stderr_reader.join();
                return Err(BridgeError::Timeout {
                    operation: "waiting for Windows PrintManagement".into(),
                    seconds: timeout.as_secs(),
                });
            }
            thread::sleep(Duration::from_millis(25));
        };
        let stdout = stdout_reader.join().map_err(|_| BridgeError::Internal {
            detail: "PowerShell stdout reader panicked".into(),
        })??;
        let stderr = stderr_reader.join().map_err(|_| BridgeError::Internal {
            detail: "PowerShell stderr reader panicked".into(),
        })??;
        Ok(CommandOutput {
            exit_code: status.code(),
            stdout: String::from_utf8_lossy(&stdout).into_owned(),
            stderr: String::from_utf8_lossy(&stderr).into_owned(),
        })
    }
}

fn read_all(mut reader: impl Read) -> Result<Vec<u8>, BridgeError> {
    let mut bytes = Vec::new();
    reader
        .read_to_end(&mut bytes)
        .map_err(|error| BridgeError::Internal {
            detail: format!("failed to read PowerShell output: {error}"),
        })?;
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;
    use std::path::Path;
    use std::time::Duration;

    use super::{CommandRunner, ProcessRunner};

    #[test]
    fn missing_powershell_maps_to_dependency_error() {
        let result = ProcessRunner.run(
            Path::new("Z:/definitely/missing/powershell.exe"),
            &[OsString::from("-NoProfile")],
            Duration::from_secs(1),
        );
        assert_eq!(
            result.expect_err("missing executable").kind().as_str(),
            "missing_dependency"
        );
    }

    #[cfg(windows)]
    #[test]
    fn process_is_killed_after_bounded_timeout() {
        let result = ProcessRunner.run(
            Path::new("powershell.exe"),
            &[
                OsString::from("-NoProfile"),
                OsString::from("-Command"),
                OsString::from("Start-Sleep -Seconds 2"),
            ],
            Duration::from_millis(50),
        );
        assert_eq!(result.expect_err("timeout").kind().as_str(), "timeout");
    }
}
