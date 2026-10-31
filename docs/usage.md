# Using PrintBridge

PrintBridge supports one Windows 11 x64 user, one accepted VirtualBox appliance,
and one tested Brother DCP-L2600D USB printer. Printing—not scanning or faxing—is
the supported function.

## Normal printing

1. Log in to the Windows account that installed PrintBridge and open
   **PrintBridge**. It does not start at Windows login.
2. Turn on and connect the printer. Windows may stop exposing the native USB
   device while the Linux guest owns it; this is expected whole-device capture.
3. Wait for the PrintBridge dashboard/tray to show **Ready**. The window may be
   closed to the tray, but the tray app must keep running.
4. In Notepad, Chrome, or another ordinary application, select
   **Brother via PrintBridge** and print normally.
5. If the application reports submission but no paper appears, check the
   dashboard and the printer itself. Software acceptance is not physical proof.

For a phone or another computer, connect it to the same trusted, non-isolated
local network and select the discovered **Brother via PrintBridge** printer.
LAN sharing is limited to the explicitly approved Windows interface and IPv4
subnet and exists only while the app is running. The reference approval permits
`Ethernet 3` and `192.168.100.0/24` even though Windows labels that adapter
Public; it permits nothing else on the Public profile.

Closing the window hides it to the notification area and keeps printing active.
**Exit PrintBridge (stop sharing)** unregisters LAN discovery, stops the owned
VM and agent, and releases their memory. The CLI equivalent is:

```powershell
& "$env:LOCALAPPDATA\PrintBridge\bin\printbridgectl.exe" shutdown
```

Use `start`, `restart`, `status`, `test-print`, `diagnostics`, or `repair` with
the same CLI. `test-print` reports Windows spooler acceptance and still requires
you to inspect the sheet.

## Reconnect and recovery

- After unplugging USB, status should become **Waiting for USB**. Reconnect the
  same printer and allow bounded recovery; do not select a similar unknown USB
  device.
- After sleep or a guest failure, keep the app running and allow several minutes
  for the VM, USB capture, CUPS, and queues to reconcile. After reboot, open the
  app yourself.
- If status remains unhealthy, choose **Repair**. Queue creation may show one
  UAC prompt; the persistent agent remains non-elevated.
- Printing is intentionally unavailable while the app is exited, before login,
  and after logoff.

Installation, repair, upgrade, and uninstall details are in
[install.md](install.md). Actionable failures are indexed in
[troubleshooting.md](troubleshooting.md).
