# Install, repair, upgrade, and uninstall

PrintBridge supports Windows 11 x64 for one interactive user. The UI and
on-demand agent run at ordinary user privilege. The NSIS installer is
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
in the desktop. No login startup is enabled.

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
prompt if the exact owned IPP queue or approved-interface/subnet firewall rules must
be created; the on-demand desktop and agent remain non-elevated:

```powershell
$root = Join-Path $env:LOCALAPPDATA 'PrintBridge'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$root\scripts\m8\windows\Invoke-M8Lifecycle.ps1" `
  -Action Repair -InstallRoot $root
& "$root\printbridge-desktop.exe"
```

In Setup, discover USB devices, select only the recorded printer, read the whole
device ownership notice, check consent, and choose **Confirm & enable bridge**.
The agent then reconciles the guest, USB, CUPS, Microsoft IPP queue, and scoped
eSCL service, and scoped LAN sharing without importing setup code into the UI.
LAN access is off until
the owner explicitly approves one current interface alias and its directly
attached local IPv4 subnet. For the reference host:

```powershell
$root = Join-Path $env:LOCALAPPDATA 'PrintBridge'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$root\scripts\m10\windows\Set-M10LanApproval.ps1" `
  -Action Approve -ConfigPath "$root\m6.conf" `
  -InterfaceAlias 'Ethernet 3' -Subnet '192.168.100.0/24'
```

Run Repair after changing approval. The exact firewall exception covers the
approved interface/subnet even when Windows categorizes it Public; it does not
authorize another adapter, subnet, port, or program. Use `-Action Remove` to
withdraw LAN approval, then run Repair or explicitly Exit.

LAN scanning requires a second, separate approval because it permits devices on
the trusted subnet to acquire documents. After LAN printing is approved:

```powershell
$root = Join-Path $env:LOCALAPPDATA 'PrintBridge'
& "$root\scripts\m11\windows\Set-M11ScanApproval.ps1" `
  -Action Approve -ConfigPath "$root\m6.conf"
& "$root\scripts\m8\windows\Invoke-M8Lifecycle.ps1" `
  -Action Repair -InstallRoot $root
```

This adds only the configured TCP 8645 rule to the same exact interface/subnet.
Use `-Action Remove` and Repair to withdraw scan access while preserving print.

## Existing M6/M7 installation or upgrade

The installer detects the protected M6 configuration, validates and removes the
exact old PrintBridge login task, stops only that executable, preserves the
configuration, installs new binaries, and leaves the agent/VM stopped until the
desktop is opened. Re-running the same installer is an idempotent repair.

Manual repair is the same fixed lifecycle command shown above. It refuses a task,
manifest, queue, config, or VM identity mismatch rather than guessing ownership.
It requests one-time elevation only for the owned queue and exact scoped
firewall rules; healthy marker-owned resources are verified without broad
mutation.

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
5. removes only the M10 firewall rules whose names and descriptions match the
   VM-bound ownership token;
6. deletes a VM only if its manifest disposition is `installation-owned` and
   both live VirtualBox ownership extradata values match; migrated M4 appliances
   are explicitly preserved;
7. removes tracked config, logs, state, and manifest, leaving diagnostic exports
   and unrelated user files untouched.

If the owned queue is the Windows default, choose another default first. Any
ownership mismatch aborts uninstall before broad cleanup. VirtualBox itself,
printer drivers/ports, unrelated queues, other VMs, and user documents are never
removed.

After installation, continue with [usage.md](usage.md). See
[troubleshooting.md](troubleshooting.md) for recovery and
[known-limitations.md](known-limitations.md) for the supported boundary.
