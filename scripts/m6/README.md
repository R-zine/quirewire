# M6 headless supervisor runbook

M6 has no desktop UI. `printbridge-agent.exe` owns VirtualBox/CUPS/USB/Windows
reconciliation; `printbridgectl.exe` is only a named-pipe client. The pipe name
contains the current SID, rejects remote clients, and has a protected DACL that
grants access only to that SID. The Task Scheduler principal is the same user,
Interactive Token, Limited run level, with `IgnoreNew` duplicate handling.
The task retries an ordinary failure up to three times and has a separate
one-minute repeating watchdog trigger in addition to its logon trigger.
`IgnoreNew` makes watchdog ticks no-ops while healthy; the named-pipe
first-instance flag remains the final singleton enforcement if launches race.

## Build and configure

From a normal PowerShell window at the repository root:

```powershell
cargo build --workspace --all-features
$m4 = '.\artifacts\m4\acceptance\20261028T204354Z\acceptance-state.json'
.\scripts\m6\windows\New-M6Configuration.ps1 `
  -M4StatePath $m4 `
  -AgentExecutable (Resolve-Path .\target\debug\printbridge-agent.exe)
$config = Join-Path $env:LOCALAPPDATA 'PrintBridge\m6.conf'
Start-Process -WindowStyle Hidden .\target\debug\printbridge-agent.exe `
  -ArgumentList @('run', '--config', $config)
Start-Sleep -Seconds 4
.\target\debug\printbridgectl.exe devices
.\target\debug\printbridgectl.exe setup --index 1
.\target\debug\printbridgectl.exe status
```

`setup --index 1` succeeds only if index 1 is the exact serial-bearing device in
the accepted M4 evidence; it then registers `\PrintBridge\Agent` at logon. The
configuration and state directory ACLs allow only the owner SID and SYSTEM.
Serial values are never emitted by the CLI, logs, or diagnostics.

## Physical acceptance checklist

Keep Tauri/desktop code absent and closed throughout this checklist. For every
print, confirm the paper actually appears and is legible; CLI acceptance alone
proves only Windows spooler submission.

1. Baseline/headless: confirm `status` becomes `ready`, run `test-print`, and
   confirm the page. Try to launch a second agent with the same command; it must
   exit with a single-instance error while the original PID remains alive.
2. Locked session: in one PowerShell window start a delayed client:
   `Start-Job { Start-Sleep 15; & '<absolute-cli-path>' test-print }`. Press
   `Win+L` before 15 seconds elapse, wait for printer output, unlock, receive the
   job, and confirm the page. The agent process must have remained running.
3. USB reconnect: unplug the Brother USB cable. Within the bounded retry window,
   `status` must report `waiting_for_usb` without a crash or tight loop. Replug
   it, wait for `ready`, run `test-print`, and confirm the page.
4. Recoverable CUPS/guest failure: run `printbridgectl restart`. During recovery,
   status must be `connecting`, then `ready` without opening VirtualBox. Run
   `test-print` and confirm the page. An externally restarted CUPS service is
   handled by the same polling path; M6's non-root guest account does not expose
   a remote arbitrary service-control command.
5. Spooler restart (Administrator PowerShell only for this test): run
   `Restart-Service Spooler`. The ordinary non-elevated agent must report the
   transition and return to `ready`; run `test-print` and confirm the page. It
   never elevates itself or changes unrelated queues.
6. Logon startup: reboot or sign out and back in. Do not manually launch the
   agent. Verify exactly one agent process, the task's last result, `status`
   becoming `ready`, then `test-print` and confirm the page.
7. Port conflict test uses a controlled maintenance window: first `stop`, verify
   the VM is stopped, bind `127.0.0.1:8644` with a temporary listener, then
   `start`. Status must report a port error and must not start the VM. Stop the
   listener, run `repair`, wait for `ready`, print, and confirm the page.
8. Run `Collect-M6Diagnostics.ps1`, inspect it for redaction, then record all
   seven physical outcomes with `Record-M6Acceptance.ps1`.

The logoff behavior is intentional and required to be reported: this MVP task
runs only in the owner's interactive session. Logoff terminates that context;
pre-login printing is not promised. The task starts a fresh agent at next logon,
which loads the last complete immutable state generation and reconciles.

Do not begin M7 until every required physical item above passes and M6 is
committed separately.
