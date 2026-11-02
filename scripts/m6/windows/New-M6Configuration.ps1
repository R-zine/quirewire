[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$M4StatePath,
    [Parameter(Mandatory)][string]$AgentExecutable,
    [string]$OutputPath = (Join-Path $env:LOCALAPPDATA 'PrintBridge\m6.conf'),
    [string]$VBoxManage = (Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe')
)

$ErrorActionPreference = 'Stop'

function Invoke-VBox([string[]]$Arguments) {
    $output = @(& $VBoxManage @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw "VBoxManage failed for a bounded M6 ownership check." }
    $output
}

function Get-ExtraData([string]$Vm, [string]$Key) {
    $line = (Invoke-VBox @('getextradata', $Vm, $Key) | Select-Object -First 1)
    if ($line -notmatch '^Value:\s*(.+)$') { throw "Missing live VM ownership field $Key." }
    $Matches[1].Trim()
}

if (-not (Test-Path -LiteralPath $M4StatePath -PathType Leaf)) { throw 'M4 acceptance state is missing.' }
if (-not (Test-Path -LiteralPath $AgentExecutable -PathType Leaf)) { throw 'Built printbridge-agent.exe is missing.' }
if (-not (Test-Path -LiteralPath $VBoxManage -PathType Leaf)) { throw 'VBoxManage.exe is missing.' }

$statePath = (Resolve-Path -LiteralPath $M4StatePath).Path
$state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
$ownerPath = Join-Path (Split-Path -Parent $statePath) 'owner-acceptance.json'
if ($state.schema -ne 'printbridge.m4.acceptance-state.v1') { throw 'State is not M4 acceptance evidence.' }
if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) { throw 'M4 owner acceptance is missing.' }
$owner = Get-Content -Raw -LiteralPath $ownerPath | ConvertFrom-Json
if ($owner.schema -ne 'printbridge.m4.owner-acceptance.v1' -or $owner.result -ne 'PASS: PHYSICAL' -or
    -not $owner.physical_page_printed -or $owner.physical_token -ne $state.physical_token) {
    throw 'M4 physical acceptance does not match the selected state.'
}
if ($state.usb_id -ne '04f9:0567' -or $state.ipp_port -ne 8644) {
    throw 'The selected M4 evidence does not match the accepted USB/IPP endpoint.'
}

$liveSchema = Get-ExtraData $state.vm_uuid 'PrintBridge/Schema'
$liveMarker = Get-ExtraData $state.vm_uuid 'PrintBridge/Owner'
if ($liveSchema -ne 'printbridge.m4.acceptance-vm.v1' -or $liveMarker -ne $state.ownership_marker) {
    throw 'Live VM ownership metadata does not match accepted M4 evidence.'
}

$usbBlocks = ((Invoke-VBox @('list', 'usbhost')) -join "`n") -split "(?:`r?`n){2,}"
$matching = @($usbBlocks | Where-Object { $_ -match '(?m)^VendorId:\s+0x04f9' -and $_ -match '(?m)^ProductId:\s+0x0567' })
if ($matching.Count -ne 1) { throw 'Expected exactly one connected 04f9:0567 device while creating M6 config.' }
$serial = if ($matching[0] -match '(?m)^SerialNumber:\s+(.+)$') { $Matches[1].Trim() } else { '' }
if (-not $serial) { throw 'The accepted printer serial is unavailable; refusing ambiguous persistent selection.' }
if ($serial.IndexOfAny([char[]]"`r`n=") -ge 0) { throw 'USB serial contains an unsupported configuration character.' }

$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$destination = [IO.Path]::GetFullPath($OutputPath)
$directory = Split-Path -Parent $destination
New-Item -ItemType Directory -Force -Path $directory | Out-Null

$lines = @(
    'schema=printbridge.m6.config.v1'
    "owner_sid=$sid"
    "vm_uuid=$($state.vm_uuid)"
    "vm_marker=$($state.ownership_marker)"
    "vm_schema=$liveSchema"
    'usb_vendor_id=04f9'
    'usb_product_id=0567'
    "usb_serial=$serial"
    'printer_name=Brother via PrintBridge'
    "endpoint_port=$($state.ipp_port)"
    'scanner_port=8645'
    'guest_queue=PrintBridge_DCP_L2600D'
)
$temporary = Join-Path $directory ".m6-$PID.tmp"
[IO.File]::WriteAllLines($temporary, $lines, [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temporary -Destination $destination -Force

& icacls.exe $directory '/inheritance:r' '/grant:r' "*$sid`:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Failed to protect the PrintBridge data directory ACL.' }
& icacls.exe $destination '/inheritance:r' '/grant:r' "*$sid`:F" '*S-1-5-18:F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Failed to protect the M6 configuration ACL.' }

[pscustomobject]@{
    schema = 'printbridge.m6.configuration-result.v1'
    config_path = $destination
    owner_sid = $sid
    vm_uuid = $state.vm_uuid
    vm_schema = $liveSchema
    usb_id = '04f9:0567'
    usb_serial = 'present (redacted)'
    endpoint = 'http://127.0.0.1:8644/printers/PrintBridge_DCP_L2600D'
    agent_executable = (Resolve-Path -LiteralPath $AgentExecutable).Path
} | ConvertTo-Json
