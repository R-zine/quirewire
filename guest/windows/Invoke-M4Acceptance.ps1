[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfiguredOvaPath,

    [Parameter(Mandatory = $true)]
    [string]$DriverMediaPath,

    [Parameter(Mandatory = $true)]
    [string]$SshPrivateKeyPath,

    [string]$OutputDirectory,

    [string]$VBoxManagePath = "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",

    [int]$SshPort = 2244,

    [int]$IppPort = 8644,

    [switch]$SubmitPhysicalPage
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $OutputDirectory) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $OutputDirectory = Join-Path $repositoryRoot "artifacts\m4\acceptance\$stamp"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$transcriptPath = Join-Path $OutputDirectory 'transcript.txt'
$knownHostsPath = Join-Path $OutputDirectory 'known_hosts'
$statePath = Join-Path $OutputDirectory 'acceptance-state.json'
$token = "M4-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))"

function Write-Evidence {
    param([string]$Message)
    $line = "[$((Get-Date).ToUniversalTime().ToString('o'))] $Message"
    Add-Content -LiteralPath $transcriptPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Invoke-VBox {
    param([string[]]$Arguments, [switch]$SensitiveOutput)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $VBoxManagePath @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($code -ne 0) {
        if ($SensitiveOutput) { throw "VBoxManage failed with exit code $code; USB output suppressed." }
        throw "VBoxManage $($Arguments[0]) failed with exit code ${code}: $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Get-VmProperty {
    param([string]$Vm, [string]$Property)
    $prefix = "$Property="
    $line = Invoke-VBox -Arguments @('showvminfo', $Vm, '--machinereadable') |
        Where-Object { $_.StartsWith($prefix) } | Select-Object -First 1
    if (-not $line) { throw "VirtualBox did not report $Property." }
    return $line.Substring($prefix.Length).Trim('"')
}

function Assert-OwnedVm {
    param([string]$Vm, [string]$Marker)
    $schema = Invoke-VBox -Arguments @('getextradata', $Vm, 'PrintBridge/Schema')
    $owner = Invoke-VBox -Arguments @('getextradata', $Vm, 'PrintBridge/Owner')
    if (($schema -join "`n") -notmatch 'Value: printbridge\.m4\.acceptance-vm\.v1' -or
        ($owner -join "`n") -notmatch "Value: $([regex]::Escape($Marker))") {
        throw 'Refusing to manage a VM without the exact M4 acceptance ownership marker.'
    }
}

function Wait-PowerOff {
    param([string]$Vm, [int]$Minutes)
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        $state = Get-VmProperty $Vm 'VMState'
        if ($state -eq 'poweroff') { return }
        if ($state -in @('aborted', 'guru_meditation')) { throw "Acceptance VM stopped in unexpected state $state." }
        Start-Sleep -Seconds 5
    }
    throw "Timed out waiting for acceptance VM poweroff after $Minutes minutes. If USB was busy, power-cycle the selected printer and retry with a new owned fixture."
}

function Get-ExactUsb {
    $raw = Invoke-VBox -Arguments @('list', 'usbhost') -SensitiveOutput
    $usbDevices = @()
    foreach ($block in (($raw -join "`n") -split "(?:`r?`n){2,}")) {
        if ($block -match '(?im)^VendorId:\s+0x04f9' -and $block -match '(?im)^ProductId:\s+0x0567') {
            $uuid = [regex]::Match($block, '(?im)^UUID:\s+([^\s]+)').Groups[1].Value
            $serial = [regex]::Match($block, '(?im)^SerialNumber:\s+(.+)$').Groups[1].Value.Trim()
            $usbDevices += [pscustomobject]@{ Uuid = $uuid; Serial = $serial }
        }
    }
    if ($usbDevices.Count -ne 1) { throw "Expected one Brother 04f9:0567, observed $($usbDevices.Count)." }
    return $usbDevices[0]
}

function Wait-TcpPort {
    param([int]$Port, [int]$Seconds)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $client = [Net.Sockets.TcpClient]::new()
        try {
            $task = $client.ConnectAsync('127.0.0.1', $Port)
            if ($task.Wait(1000) -and $client.Connected) { return }
        }
        catch { }
        finally { $client.Dispose() }
        Start-Sleep -Seconds 2
    }
    throw "Loopback port $Port did not become ready within $Seconds seconds."
}

function Invoke-Ssh {
    param([string]$Command)
    $arguments = @('-i', $SshPrivateKeyPath, '-p', "$SshPort", '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', "UserKnownHostsFile=$knownHostsPath", 'printbridge@127.0.0.1', $Command)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& ssh.exe @arguments 2>&1 | ForEach-Object { $_.ToString() })
        $sshCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($sshCode -ne 0) { throw "Guest SSH command failed: $($output -join [Environment]::NewLine)" }
    return $output
}

foreach ($required in @($ConfiguredOvaPath, $DriverMediaPath, $SshPrivateKeyPath, $VBoxManagePath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required input is missing: $required" }
}
if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) { throw 'Windows OpenSSH client is required.' }
if (-not (Get-Command scp.exe -ErrorAction SilentlyContinue)) { throw 'Windows OpenSSH scp client is required.' }
if (-not (Get-Command cargo.exe -ErrorAction SilentlyContinue)) { throw 'Rust cargo is required to run the real M4 IPP provider probe.' }

$marker = "printbridge.m4.acceptance.$([guid]::NewGuid())"
$name = "PrintBridge-M4-Acceptance-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
$machineFolder = Join-Path $OutputDirectory 'vm'
[IO.Directory]::CreateDirectory($machineFolder) | Out-Null
Write-Evidence 'Importing a fresh configured OVA into a new owned VM.'
Invoke-VBox -Arguments @('import', [IO.Path]::GetFullPath($ConfiguredOvaPath), '--options=importtovdi', '--vsys=0', "--vmname=$name", "--basefolder=$machineFolder", '--memory=768', '--cpus=1') | Out-Null
$vm = Get-VmProperty $name 'UUID'
Invoke-VBox -Arguments @('setextradata', $vm, 'PrintBridge/Schema', 'printbridge.m4.acceptance-vm.v1') | Out-Null
Invoke-VBox -Arguments @('setextradata', $vm, 'PrintBridge/Owner', $marker) | Out-Null
Assert-OwnedVm $vm $marker

Invoke-VBox -Arguments @('modifyvm', $vm, '--nic1', 'nat', '--audio-enabled', 'off', '--clipboard-mode', 'disabled', '--drag-and-drop', 'disabled', '--usb-ohci', 'on', '--usb-ehci', 'off', '--usb-xhci', 'off', '--boot1', 'disk', '--boot2', 'dvd', '--boot3', 'none', '--boot4', 'none') | Out-Null
Invoke-VBox -Arguments @('modifyvm', $vm, '--nat-pf1', "printbridge-m4-ssh,tcp,127.0.0.1,$SshPort,,22") | Out-Null
Invoke-VBox -Arguments @('modifyvm', $vm, '--nat-pf1', "printbridge-m4-ipp,tcp,127.0.0.1,$IppPort,,631") | Out-Null
Invoke-VBox -Arguments @('storageattach', $vm, '--storagectl', 'SATA Controller', '--port', '1', '--device', '0', '--type', 'dvddrive', '--medium', [IO.Path]::GetFullPath($DriverMediaPath)) | Out-Null

$usb = Get-ExactUsb
$filter = @('usbfilter', 'add', '0', '--target', $vm, '--name', 'PrintBridge M4 acceptance exact Brother', '--active', 'yes', '--vendorid', '04f9', '--productid', '0567', '--remote', 'no')
if ($usb.Serial) { $filter += @('--serialnumber', $usb.Serial) }
Invoke-VBox -Arguments $filter -SensitiveOutput | Out-Null

Write-Evidence 'Booting fresh import with the same driver media to prove repair/reprovision safety.'
Invoke-VBox -Arguments @('startvm', $vm, '--type', 'headless') | Out-Null
Wait-PowerOff $vm 15
Write-Evidence 'Idempotent driver-media rerun completed and powered off normally.'
Assert-OwnedVm $vm $marker
Invoke-VBox -Arguments @('storageattach', $vm, '--storagectl', 'SATA Controller', '--port', '1', '--device', '0', '--type', 'dvddrive', '--medium', 'none') | Out-Null

Write-Evidence 'Starting the repaired appliance headlessly without build media.'
Invoke-VBox -Arguments @('startvm', $vm, '--type', 'headless') | Out-Null
Wait-TcpPort $SshPort 180
Wait-TcpPort $IppPort 180
$ippDeadline = (Get-Date).AddSeconds(180)
do {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $ippProbe = @(& cargo.exe run --quiet -p printbridge-provider-cups --example m4_probe -- "$IppPort" PrintBridge_DCP_L2600D 2>&1 | ForEach-Object { $_.ToString() })
        $ippProbeCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($ippProbeCode -ne 0) { Start-Sleep -Seconds 3 }
} while ($ippProbeCode -ne 0 -and (Get-Date) -lt $ippDeadline)
if ($ippProbeCode -ne 0) { throw "Real host IPP provider did not become ready within 180 seconds: $($ippProbe -join [Environment]::NewLine)" }
$ippProbe | Set-Content -LiteralPath (Join-Path $OutputDirectory 'host-ipp-diagnostics.txt') -Encoding UTF8
$ippProbeText = $ippProbe -join "`n"
if ($ippProbeText -notmatch '(?m)^ipp=pass$' -or $ippProbeText -notmatch '(?m)^state=ready$') {
    throw 'Real host IPP provider did not report a ready queue.'
}
$health = Invoke-Ssh '/usr/local/sbin/printbridge-health --diagnostics'
$health | Set-Content -LiteralPath (Join-Path $OutputDirectory 'guest-diagnostics.txt') -Encoding UTF8
$healthText = $health -join "`n"
foreach ($requiredHealth in @('cups=active', 'queue=idle', 'accepting=yes', 'ipp=pass', 'usb=present', 'driver_mode=official-brother', 'physical_output=not_inferred')) {
    if ($healthText -notmatch "(?m)^$([regex]::Escape($requiredHealth))$") {
        throw "Guest health is missing required result: $requiredHealth"
    }
}
Write-Evidence 'Guest reports CUPS active, queue idle/accepting, IPP healthy, USB present, and official driver selected.'

$job = $null
if ($SubmitPhysicalPage) {
    $source = Join-Path $repositoryRoot 'scripts\m4\test-data\m4-appliance-physical-test.txt'
    $staged = Join-Path $OutputDirectory "m4-appliance-physical-test-$token.txt"
    (Get-Content -Raw -LiteralPath $source).Replace('The unique run token is recorded in the local M4 acceptance evidence.', "Run token: $token") |
        Set-Content -LiteralPath $staged -Encoding UTF8
    $scpArgs = @('-i', $SshPrivateKeyPath, '-P', "$SshPort", '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', '-o', "UserKnownHostsFile=$knownHostsPath", $staged, 'printbridge@127.0.0.1:/tmp/m4-physical-test.txt')
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & scp.exe @scpArgs 2>&1 | Out-Null
        $scpCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($scpCode -ne 0) { throw 'Failed to stage the M4 physical test page through loopback SSH.' }
    $jobOutput = Invoke-Ssh "lp -d PrintBridge_DCP_L2600D -t '$token' /tmp/m4-physical-test.txt"
    $job = ($jobOutput -join ' ').Trim()
    Write-Evidence "Submitted physical page $token; CUPS response recorded."
    Start-Sleep -Seconds 8
    $postHealth = Invoke-Ssh '/usr/local/sbin/printbridge-health --health'
    if (($postHealth -join "`n") -notmatch '(?m)^queue=idle$') { throw 'CUPS did not return to idle after the acceptance submission.' }
    Write-Evidence 'CUPS returned to idle; physical output remains owner-confirmed only.'
}

$state = [ordered]@{
    schema = 'printbridge.m4.acceptance-state.v1'
    result = if ($SubmitPhysicalPage) { 'BLOCKED: OWNER PHYSICAL CONFIRMATION' } else { 'PASS: SOFTWARE ONLY' }
    vm_uuid = $vm
    ownership_marker = $marker
    ssh_port = $SshPort
    ipp_port = $IppPort
    fresh_ova_import = $true
    idempotent_reprovision = $true
    cups_health = 'pass'
    usb_id = '04f9:0567'
    physical_token = if ($SubmitPhysicalPage) { $token } else { $null }
    cups_submission = $job
    physical_output = 'not_inferred'
    owner_confirmed = $false
}
$state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
Write-Evidence "Acceptance state written to $statePath"
Write-Host "Owned acceptance VM remains running: $vm"
if ($SubmitPhysicalPage) {
    Write-Host "OWNER ACTION: confirm whether the printed page contains token $token."
}
