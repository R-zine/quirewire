# Install, repair, upgrade, and uninstall

PrintBridge M8 supports Windows 11 x64 for one interactive user. The UI and
persistent agent run at ordinary user privilege. The NSIS installer is
`currentUser`; no always-elevated process or service is installed.

## Before setup

Run the packaged prerequisite report from PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$env:LOCALAPPDATA\PrintBridge\scripts\m8\windows\Test-M8Prerequisites.ps1"
```

Allow at least 12 GiB free disk space. The headless guest reserves 768 MiB RAM
while running. PrintBridge captures the **whole selected USB device**, so Windows
cannot use that device while the guest owns it. Setup asks for explicit consent
in the desktop before enabling login startup.

VirtualBox, WebView2, and a configured appliance are prerequisites, not silently
installed dependencies. See [licensing.md](licensing.md) for the exact offline
and network boundary.

## Fresh owner-local appliance

The configured appliance cannot be distributed because it contains Brother
vendor binaries. From a clean checkout or the packaged `guest` source,
follow `guest/README.md` to build the pinned base and configured owner-local OVA,
then run the M4 acceptance import. Create the protected agent configuration with
the packaged `New-M6Configuration.ps1`; this validates the physical-acceptance
state, live VM UUID plus extradata, exact USB serial, and loopback endpoint.

Once `%LOCALAPPDATA%\PrintBridge\m6.conf` exists, run lifecycle repair from the
installation directory and open PrintBridge. Windows shows one UAC consent
prompt if the exact owned IPP queue must be created; the background agent and
startup task remain non-elevated:

```powershell
$root = Join-Path $env:LOCALAPPDATA 'PrintBridge'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$root\scripts\m8\windows\Invoke-M8Lifecycle.ps1" `
  -Action Repair -InstallRoot $root
& "$root\printbridge-desktop.exe"
```

In Setup, discover USB devices, select only the recorded printer, read the whole
device ownership notice, check consent, and choose **Confirm & enable bridge**.
The agent then reconciles the guest, USB, CUPS, Microsoft IPP queue, and startup
task without importing setup code into the UI.

## Existing M6/M7 installation or upgrade

The installer detects the protected M6 configuration, validates the exact old
PrintBridge task, stops only that executable, preserves configuration/desired
state, installs new binaries, rewrites the same per-user task to the installed
agent, and starts it. Re-running the same installer is an idempotent repair.

Manual repair is the same fixed lifecycle command shown above. It refuses a task,
manifest, queue, config, or VM identity mismatch rather than guessing ownership.
It requests one-time elevation only when the owned queue is absent; a healthy
marker-owned queue is verified without prompting.

## Unsigned development build

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\m8\windows\Build-M8Installer.ps1 -UnsignedDevelopmentBuild
```

The resulting `target\release\bundle\nsis\*-setup.exe` is deliberately unsigned
and may trigger SmartScreen. Verify the SHA-256 printed by the build command.
Production builds must use the documented certificate-thumbprint path.

## Uninstall safety

Use Windows **Installed apps → PrintBridge → Uninstall**. Before NSIS removes
files, the lifecycle hook:

1. verifies the M8 manifest SID and exact install/data roots;
2. disables only `\PrintBridge\Agent` after validating its description, SID,
   executable, and arguments;
3. stops only the manifest-recorded agent executable;
4. removes only the Windows queue matching the marker file, live comment, port,
   endpoint, and Microsoft IPP driver;
5. deletes a VM only if its manifest disposition is `installation-owned` and
   both live VirtualBox ownership extradata values match; migrated M4 appliances
   are explicitly preserved;
6. removes tracked config, logs, state, and manifest, leaving diagnostic exports
   and unrelated user files untouched.

If the owned queue is the Windows default, choose another default first. Any
ownership mismatch aborts uninstall before broad cleanup. VirtualBox itself,
printer drivers/ports, unrelated queues, other VMs, and user documents are never
removed.

After installation, continue with [usage.md](usage.md). See
[troubleshooting.md](troubleshooting.md) for recovery and
[known-limitations.md](known-limitations.md) for the supported boundary.
