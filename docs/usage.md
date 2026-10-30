# Using PrintBridge

PrintBridge supports one Windows 11 x64 user, one accepted VirtualBox appliance,
and one tested Brother DCP-L2600D USB printer. Printing—not scanning or faxing—is
the supported function.

## Normal printing

1. Log in to the Windows account that installed PrintBridge.
2. Turn on and connect the printer. Windows may stop exposing the native USB
   device while the Linux guest owns it; this is expected whole-device capture.
3. Wait for the PrintBridge dashboard/tray to show **Ready**. The window does not
   need to remain open.
4. In Notepad, Chrome, or another ordinary application, select
   **Brother via PrintBridge** and print normally.
5. If the application reports submission but no paper appears, check the
   dashboard and the printer itself. Software acceptance is not physical proof.

Closing the window hides it to the notification area. **Exit UI (engine keeps
running)** closes only the desktop client; the per-user agent and guest continue.
To intentionally stop printing, use the dashboard Stop action or:

```powershell
& "$env:LOCALAPPDATA\PrintBridge\bin\printbridgectl.exe" stop
```

Use `start`, `restart`, `status`, `test-print`, `diagnostics`, or `repair` with
the same CLI. `test-print` reports Windows spooler acceptance and still requires
you to inspect the sheet.

## Reconnect and recovery

- After unplugging USB, status should become **Waiting for USB**. Reconnect the
  same printer and allow bounded recovery; do not select a similar unknown USB
  device.
- After sleep, reboot, or a guest failure, allow several minutes for the task,
  VM, USB capture, CUPS, and Windows queue to reconcile.
- If status remains unhealthy, choose **Repair**. Queue creation may show one
  UAC prompt; the persistent agent remains non-elevated.
- The MVP runs only while this user is logged in. Pre-login and logged-off
  printing are not supported.

Installation, repair, upgrade, and uninstall details are in
[install.md](install.md). Actionable failures are indexed in
[troubleshooting.md](troubleshooting.md).
