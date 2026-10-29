//! Windows named-pipe transport with an explicit owner-only security descriptor.
//!
//! This is the sole reviewed unsafe boundary in the workspace. Tokio requires a
//! raw `SECURITY_ATTRIBUTES` pointer to create a named pipe with a non-default
//! DACL. The descriptor remains alive until `CreateNamedPipeW` returns.

#![allow(unsafe_code)]

use std::ffi::c_void;
use std::io;
use std::process::Command as ProcessCommand;
use std::ptr;
use std::time::Duration;

use tokio::io::BufReader;
use tokio::net::windows::named_pipe::{ClientOptions, NamedPipeServer, ServerOptions};
use tokio::time::{sleep, timeout};
use windows_sys::Win32::Foundation::LocalFree;
use windows_sys::Win32::Security::Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW;
use windows_sys::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};

use crate::{RequestEnvelope, ResponseEnvelope, WireError, read_response, write_request};

const SDDL_REVISION_1: u32 = 1;
pub const PIPE_PREFIX: &str = r"\\.\pipe\PrintBridge-Agent-v4-";

#[derive(Debug, Clone)]
pub struct SecurePipeFactory {
    pipe_name: String,
    owner_sid: String,
}

impl SecurePipeFactory {
    pub fn new(owner_sid: impl Into<String>) -> io::Result<Self> {
        let owner_sid = owner_sid.into();
        validate_sid(&owner_sid)?;
        Ok(Self {
            pipe_name: pipe_name_for_sid(&owner_sid),
            owner_sid,
        })
    }

    #[must_use]
    pub fn pipe_name(&self) -> &str {
        &self.pipe_name
    }

    #[must_use]
    pub fn owner_sid(&self) -> &str {
        &self.owner_sid
    }

    pub fn create_first(&self) -> io::Result<NamedPipeServer> {
        self.create(true)
    }

    pub fn create_next(&self) -> io::Result<NamedPipeServer> {
        self.create(false)
    }

    fn create(&self, first: bool) -> io::Result<NamedPipeServer> {
        let sddl = owner_only_sddl(&self.owner_sid)?;
        let descriptor = SecurityDescriptor::from_sddl(&sddl)?;
        let mut attributes = SECURITY_ATTRIBUTES {
            nLength: u32::try_from(std::mem::size_of::<SECURITY_ATTRIBUTES>())
                .expect("SECURITY_ATTRIBUTES size fits u32"),
            lpSecurityDescriptor: descriptor.0,
            bInheritHandle: 0,
        };
        let mut options = ServerOptions::new();
        options
            .first_pipe_instance(first)
            .reject_remote_clients(true)
            .max_instances(8);
        // SAFETY: `attributes` and the local-allocated self-relative descriptor
        // both remain valid for the duration of this synchronous create call.
        unsafe {
            options.create_with_security_attributes_raw(
                &self.pipe_name,
                (&raw mut attributes).cast::<c_void>(),
            )
        }
    }
}

struct SecurityDescriptor(PSECURITY_DESCRIPTOR);

impl SecurityDescriptor {
    fn from_sddl(sddl: &str) -> io::Result<Self> {
        let wide: Vec<u16> = sddl.encode_utf16().chain(Some(0)).collect();
        let mut descriptor = ptr::null_mut();
        // SAFETY: `wide` is NUL terminated and `descriptor` is an out pointer.
        let ok = unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                wide.as_ptr(),
                SDDL_REVISION_1,
                &raw mut descriptor,
                ptr::null_mut(),
            )
        };
        if ok == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Self(descriptor))
    }
}

impl Drop for SecurityDescriptor {
    fn drop(&mut self) {
        // SAFETY: successful conversion allocates this descriptor with LocalAlloc.
        unsafe {
            LocalFree(self.0.cast());
        }
    }
}

pub fn current_user_sid() -> io::Result<String> {
    let output = ProcessCommand::new("whoami.exe")
        .args(["/user", "/fo", "csv", "/nh"])
        .output()?;
    if !output.status.success() {
        return Err(io::Error::other("whoami /user failed"));
    }
    parse_whoami_sid(&String::from_utf8_lossy(&output.stdout))
}

pub fn parse_whoami_sid(output: &str) -> io::Result<String> {
    let sid = output
        .split(|character: char| character == ',' || character == '"' || character.is_whitespace())
        .find(|part| part.starts_with("S-1-"))
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "whoami omitted user SID"))?;
    validate_sid(sid)?;
    Ok(sid.to_string())
}

pub fn validate_sid(sid: &str) -> io::Result<()> {
    if !sid.starts_with("S-1-")
        || sid.len() > 184
        || !sid
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'S' | b'-'))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "owner SID is not a canonical Windows SID string",
        ));
    }
    Ok(())
}

#[must_use]
pub fn pipe_name_for_sid(sid: &str) -> String {
    format!("{PIPE_PREFIX}{sid}")
}

pub fn owner_only_sddl(sid: &str) -> io::Result<String> {
    validate_sid(sid)?;
    Ok(format!("D:P(A;;GA;;;{sid})"))
}

pub async fn send(
    pipe_name: &str,
    request: &RequestEnvelope,
    operation_timeout: Duration,
) -> Result<ResponseEnvelope, WireError> {
    let client = timeout(operation_timeout, async {
        loop {
            match ClientOptions::new().open(pipe_name) {
                Ok(client) => return Ok(client),
                Err(error) if error.raw_os_error() == Some(231) => {
                    sleep(Duration::from_millis(50)).await;
                }
                Err(error) => return Err(WireError::Io(error)),
            }
        }
    })
    .await
    .map_err(|_| {
        WireError::Io(io::Error::new(
            io::ErrorKind::TimedOut,
            "IPC connect timed out",
        ))
    })??;
    timeout(operation_timeout, async {
        let (reader, mut writer) = tokio::io::split(client);
        write_request(&mut writer, request).await?;
        read_response(&mut BufReader::new(reader)).await
    })
    .await
    .map_err(|_| {
        WireError::Io(io::Error::new(
            io::ErrorKind::TimedOut,
            "IPC request timed out",
        ))
    })?
}

#[cfg(test)]
mod tests {
    use super::{SecurePipeFactory, owner_only_sddl, parse_whoami_sid};

    const SID: &str = "S-1-5-21-111-222-333-1001";

    #[test]
    fn security_descriptor_is_protected_and_owner_only() {
        assert_eq!(
            owner_only_sddl(SID).expect("SDDL"),
            format!("D:P(A;;GA;;;{SID})")
        );
    }

    #[test]
    fn parses_csv_without_retaining_account_name() {
        let parsed = parse_whoami_sid("\"WORKGROUP\\owner\",\"S-1-5-21-111-222-333-1001\"\r\n")
            .expect("SID");
        assert_eq!(parsed, SID);
    }

    #[tokio::test]
    async fn first_instance_is_an_os_enforced_singleton() {
        let sid = super::current_user_sid().expect("current SID");
        let factory = SecurePipeFactory::new(sid).expect("factory");
        let first = match factory.create_first() {
            Ok(server) => Some(server),
            Err(error) if error.raw_os_error() == Some(5) => None,
            Err(error) => panic!("first instance: {error}"),
        };
        let second_factory = SecurePipeFactory::new(factory.owner_sid()).expect("second factory");
        let duplicate = match second_factory.create_first() {
            Ok(_) => panic!("another first instance must be refused"),
            Err(error) => error,
        };
        assert_eq!(duplicate.raw_os_error(), Some(5));
        drop(first);
    }
}
