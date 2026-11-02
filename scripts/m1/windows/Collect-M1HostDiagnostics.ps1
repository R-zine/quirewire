[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$')]
    [string]$VmUuid,

    [string]$OutputDirectory,
    [string]$PrinterName = 'Brother via QuireWire M1',
    [string]$IppUrl = 'ipp://127.0.0.1:8632/printers/DCPL2600D',
    [ValidatePattern('^[0-9A-Fa-f]{4}$')][string]$UsbVendorId = '04f9',
    [ValidatePattern('^[0-9A-Fa-f]{4}$')][string]$UsbProductId = '0567',
    [string]$VBoxManagePath = "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m1\host-diagnostics'
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Invoke-Diagnostic {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    try {
        $value = @(& $ScriptBlock)
        return [ordered]@{ name = $Name; status = 'ok'; value = $value; error = $null }
    }
    catch {
        return [ordered]@{ name = $Name; status = 'error'; value = @(); error = $_.Exception.Message }
    }
}

function ConvertFrom-MachineReadableLine {
    param([Parameter(Mandatory = $true)][string]$Line)

    $separator = $Line.IndexOf('=')
    if ($separator -lt 1) { return $null }
    $name = $Line.Substring(0, $separator)
    $value = $Line.Substring($separator + 1).Trim('"')
    return [pscustomobject]@{ Name = $name; Value = $value }
}

function Get-BoundedVmInfo {
    if (-not (Test-Path -LiteralPath $VBoxManagePath -PathType Leaf)) {
        throw "VBoxManage was not found at '$VBoxManagePath'."
    }

    $raw = @(& $VBoxManagePath showvminfo $VmUuid --machinereadable 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ($raw -join [Environment]::NewLine) }
    $allowedExact = @(
        'name', 'UUID', 'CfgFile', 'memory', 'cpus', 'ostype', 'VMState',
        'VMStateChangeTime', 'defaultfrontend', 'autostart-enabled',
        'autostart-delay', 'nic1', 'natnet1', 'localhostReachable', 'xhci',
        'usb', 'ehci', 'description'
    )
    $result = [ordered]@{}
    foreach ($line in $raw) {
        $entry = ConvertFrom-MachineReadableLine -Line ([string]$line)
        if ($null -eq $entry) { continue }
        $isForward = $entry.Name -match '^Forwarding\([0-9]+\)$'
        $isSafeFilterField = $entry.Name -match '^USBFilter(?:Active|Name|VendorId|ProductId|Remote)[0-9]+$'
        if ($entry.Name -in $allowedExact -or $isForward -or $isSafeFilterField) {
            $result[$entry.Name] = $entry.Value
        }
    }
    return [pscustomobject]$result
}

function Get-TargetUsbHostState {
    if (-not (Test-Path -LiteralPath $VBoxManagePath -PathType Leaf)) {
        throw "VBoxManage was not found at '$VBoxManagePath'."
    }

    $raw = @(& $VBoxManagePath list usbhost 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ($raw -join [Environment]::NewLine) }
    $text = $raw -join "`n"
    $blocks = @($text -split '(?:\r?\n){2,}')
    $vendorPattern = '(?im)^VendorId:\s+0x' + [regex]::Escape($UsbVendorId) + '(?:\s|$)'
    $productPattern = '(?im)^ProductId:\s+0x' + [regex]::Escape($UsbProductId) + '(?:\s|$)'
    $matches = @($blocks | Where-Object { $_ -match $vendorPattern -and $_ -match $productPattern })
    return @($matches | ForEach-Object {
        $block = $_
        [pscustomobject]@{
            uuid = [regex]::Match($block, '(?im)^UUID:\s+(.+)$').Groups[1].Value.Trim()
            vendorId = $UsbVendorId.ToLowerInvariant()
            productId = $UsbProductId.ToLowerInvariant()
            currentState = [regex]::Match($block, '(?im)^Current State:\s+(.+)$').Groups[1].Value.Trim()
            serial = '<redacted by collector>'
        }
    })
}

function Test-LoopbackEndpoint {
    $uri = [Uri]$IppUrl
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('ipp', 'ipps', 'http', 'https')) {
        throw 'IppUrl must be an absolute ipp, ipps, http, or https URI.'
    }
    if (-not [System.Net.IPAddress]::IsLoopback(([System.Net.Dns]::GetHostAddresses($uri.DnsSafeHost) | Select-Object -First 1))) {
        throw 'M1 diagnostics intentionally probe only a loopback endpoint.'
    }
    $port = $uri.Port
    if ($port -lt 1) { $port = if ($uri.Scheme -in @('ipps', 'https')) { 443 } else { 631 } }
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $async = $client.BeginConnect($uri.DnsSafeHost, $port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(5000)) { throw 'TCP connection timed out after 5 seconds.' }
        $client.EndConnect($async)
        return [pscustomobject]@{ url = $uri.AbsoluteUri; host = $uri.DnsSafeHost; port = $port; tcpSucceeded = $true }
    }
    finally { $client.Dispose() }
}

$targetQueue = $null
$targetJobs = @()
$queueError = $null
try {
    $targetQueue = Get-Printer -Name $PrinterName -ErrorAction Stop
    $targetJobs = @(Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue |
        Select-Object Id, DocumentName, JobStatus, SubmittedTime, Size, TotalPages, PagesPrinted)
}
catch { $queueError = $_.Exception.Message }

$targetPnp = Invoke-Diagnostic -Name 'Target Brother USB PnP state' -ScriptBlock {
    Get-PnpDevice -PresentOnly -ErrorAction Stop |
        Where-Object { $_.InstanceId -like "USB\VID_$($UsbVendorId.ToUpperInvariant())&PID_$($UsbProductId.ToUpperInvariant())*" } |
        Select-Object Status, Class, FriendlyName, Manufacturer, Problem, Present
}

$report = [ordered]@{
    schema = 'quirewire.m1.host-diagnostics.v1'
    collectedUtc = [DateTime]::UtcNow.ToString('o')
    scopeNotice = 'Read-only inventory. Job completion does not prove that paper physically printed.'
    requestedVmUuid = $VmUuid.ToLowerInvariant()
    vboxVersion = Invoke-Diagnostic -Name 'VBoxManage version' -ScriptBlock { & $VBoxManagePath --version }
    ownedVm = Invoke-Diagnostic -Name 'Bounded VM configuration' -ScriptBlock { Get-BoundedVmInfo }
    targetUsb = Invoke-Diagnostic -Name 'VirtualBox target USB visibility' -ScriptBlock { Get-TargetUsbHostState }
    targetPnp = $targetPnp
    ippEndpoint = Invoke-Diagnostic -Name 'Loopback IPP TCP endpoint' -ScriptBlock { Test-LoopbackEndpoint }
    windowsQueue = [ordered]@{
        requestedName = $PrinterName
        found = $null -ne $targetQueue
        error = $queueError
        driverIsMicrosoftInboxIpp = $null -ne $targetQueue -and $targetQueue.DriverName -eq 'Microsoft IPP Class Driver'
        queue = if ($null -ne $targetQueue) { $targetQueue | Select-Object Name, DriverName, PortName, Comment, PrinterStatus, Type, Shared } else { $null }
        jobs = $targetJobs
    }
}

$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$jsonPath = Join-Path $OutputDirectory "$stamp-m1-host-diagnostics.json"
$summaryPath = Join-Path $OutputDirectory "$stamp-m1-host-summary.txt"
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$vmState = '<unavailable>'
if ($report.ownedVm.status -eq 'ok' -and $report.ownedVm.value.Count -gt 0) {
    $vmState = $report.ownedVm.value[0].VMState
}
$endpointSucceeded = $report.ippEndpoint.status -eq 'ok' -and $report.ippEndpoint.value.Count -gt 0 -and $report.ippEndpoint.value[0].tcpSucceeded
$usbCount = if ($report.targetUsb.status -eq 'ok') { $report.targetUsb.value.Count } else { 0 }
$driver = if ($null -eq $targetQueue) { '<queue unavailable>' } else { $targetQueue.DriverName }
@"
QuireWire M1 host diagnostics
Collected UTC: $($report.collectedUtc)
Owned VM UUID: $($VmUuid.ToLowerInvariant())
Owned VM state: $vmState
Target USB devices visible to VirtualBox: $usbCount
Target Windows queue: $PrinterName
Target Windows driver: $driver
Expected driver: Microsoft IPP Class Driver
Loopback endpoint reachable: $endpointSucceeded

USB serials are deliberately omitted. This report cannot establish a physical
print PASS. Review document names and machine-local data before sharing.
"@ | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host "Diagnostics JSON: $jsonPath"
Write-Host "Summary:          $summaryPath"
Write-Host 'USB serials:       redacted by collector'
Write-Host 'Physical result:   NOT INFERRED'
