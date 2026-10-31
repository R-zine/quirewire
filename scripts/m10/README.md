# M10 on-demand trusted-LAN acceptance

M10 replaces login-start/always-on behavior with an app-owned lifecycle. It
keeps the Windows queue on loopback and adds a temporary, exact-owned LAN IPP
forward plus `_ipp._tcp` DNS-SD advertisement only on an explicitly approved
active default-route Windows interface and IPv4 subnet.

## Software checks

```powershell
./tests/m10/Invoke-M10SoftwareTests.ps1
cargo test --workspace --all-features
cargo clippy --workspace --all-targets --all-features -- -D warnings
```

Read-only LAN policy status:

```powershell
$root = Join-Path $env:LOCALAPPDATA 'PrintBridge'
$config = Get-Content -LiteralPath "$root\m6.conf" | ConvertFrom-StringData
& "$root\scripts\m10\windows\Invoke-M10LanSharing.ps1" `
  -Action Status -OwnerToken $config.vm_uuid -IppPort ([int]$config.endpoint_port) `
  -AgentExecutable "$root\bin\printbridge-agent.exe" `
  -VBoxHeadlessExecutable "$env:ProgramFiles\Oracle\VirtualBox\VBoxHeadless.exe" `
  -ApprovedInterfaceAlias $config.lan_interface_alias `
  -ApprovedSubnet $config.lan_subnet
```

The fixed protocol base64-encodes human text. `network_allowed=false` is a safe
refusal, not a reason to add an Any-interface, Any-subnet, or Any-profile rule.

Read-only live protocol checks after status reaches Ready:

```powershell
$LanAddress = '192.168.100.72' # copy the current address from CLI status
& "$root\scripts\m10\windows\Test-M10LanIpp.ps1" `
  -Address $LanAddress -Port ([int]$config.endpoint_port)
$DnsSdResult = Join-Path $env:TEMP 'printbridge-m10-dnssd.txt'
$diagnostic = Start-Process -FilePath "$root\bin\printbridge-agent.exe" -Wait -PassThru `
  -ArgumentList @('diagnose-lan', $LanAddress, $config.endpoint_port, '--output', $DnsSdResult)
if ($diagnostic.ExitCode -ne 0) { throw 'PrintBridge DNS-SD resolution failed.' }
Get-Content -LiteralPath $DnsSdResult
```

Use the address reported by `printbridgectl status`; the reference address is
shown only as an example. The DNS-SD command must run from the installed agent
path because the exact-program firewall deliberately excludes arbitrary tools.
It writes an explicit result file because the release agent is deliberately a
windowless executable and must not create a flashing terminal.

## Physical gate

Use the bounded owner checklist in [docs/m10-acceptance.md](../../docs/m10-acceptance.md).
Only one small physical page is required. Do not advance or commit M10 until the
LAN page and explicit-exit shutdown are confirmed.
