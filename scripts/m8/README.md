# M8 Windows packaging and acceptance

- `Build-M8Installer.ps1` builds the release agent/CLI and Tauri NSIS package.
  It requires an explicit unsigned-development or signed-release choice.
- `Test-M8Prerequisites.ps1` reports Windows, WebView2, PrintManagement,
  VirtualBox, disk/RAM, network, appliance, and whole-device USB requirements.
- `Invoke-M8Lifecycle.ps1` is the fixed NSIS install/upgrade/repair/uninstall
  entry point. Mutations require exact SID, manifest, task, queue, and VM
  ownership matches. Queue creation/removal first runs a read-only ownership
  check and requests one-time UAC only when the exact operation needs it; the
  persistent task always remains limited.
- `Collect-M8Diagnostics.ps1` records non-secret baseline/install/repair/
  uninstall state. It never records the USB serial.
- `Trace-M8ProcessStarts.ps1` is a bounded, opt-in process-name/path tracer for
  diagnosing visible console flashes without collecting command-line arguments.
- `Record-M8Acceptance.ps1` compares those snapshots and requires explicit
  owner confirmation for both the install and repair physical pages.

The configured Brother appliance remains owner-local. See
`docs/install.md` and `docs/licensing.md` before running the physical gate.
