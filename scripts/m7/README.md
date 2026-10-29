# M7 desktop acceptance

M7 is accepted only against the real owner-only M6 agent and a physically
printed page. Browser preview/fake-client tests do not satisfy this gate.

## Build and launch

From `apps\desktop` in a normal, non-elevated PowerShell window:

```powershell
npm ci
npm test
npm run build
cargo tauri build --no-bundle
..\..\target\release\printbridge-desktop.exe
```

Do not stop `printbridge-agent.exe`. The desktop must connect to the scheduled
per-user agent through the protocol-v4 owner-only named pipe.

## Owner checklist

1. On Overview, confirm the overall state and VirtualBox, Linux guest, USB,
   CUPS, and Windows queue cards reflect the live agent and are `Ready`.
2. Open Setup, scan for USB devices, select only the Brother DCP-L2600D,
   acknowledge whole-device USB capture, and run `Confirm and configure`.
   Confirm it returns to `Ready` without opening VirtualBox or SSH.
3. Open Print test, choose `Print test page`, and confirm both Windows
   acceptance in the UI and actual paper output. The UI must continue to say
   that physical output requires owner confirmation.
4. Open Diagnostics, export a report, confirm the JSON exists in
   `Documents\PrintBridge`, then run `Run safe repair`; confirm all components
   return to `Ready`. Do not share the export publicly because it contains
   local paths and the owner SID, though the USB serial is redacted.
5. Click the window close button. Confirm the window disappears, the tray icon
   remains, and `printbridge-agent.exe` is still running. Reopen with tray
   `Open PrintBridge`.
6. From the tray choose `Test page`; confirm a second physical page prints.
   Also confirm `Restart bridge` and `View diagnostics` work.
7. Submit one more test page and immediately choose tray
   `Exit UI (engine keeps running)`. Confirm the desktop/tray process exits,
   `printbridge-agent.exe` remains, and that submitted page physically prints.
8. Relaunch the desktop and confirm Overview returns to `Ready`. Record only
   observed results:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  scripts\m7\windows\Record-M7Acceptance.ps1 `
  -DashboardReady yes -SetupFlowWorked yes -UiPagePrinted yes `
  -TrayPagePrinted yes -DiagnosticsExported yes -RepairReturnedReady yes `
  -CloseKeptAgentRunning yes -ExitKeptAgentRunning yes `
  -PrintCompletedAfterUiExit yes
```

`Exit UI` is not `Stop printing engine`. The latter is a separately labelled,
confirmed Settings action and is not part of the exit-survival check.
