[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$PrinterName = 'Brother via PrintBridge POC',
    [string]$IppUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m0\windows'
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

function Get-PrintEvents {
    param([Parameter(Mandatory = $true)][string]$LogName)

    $log = Get-WinEvent -ListLog $LogName -ErrorAction Stop
    if (-not $log.IsEnabled) {
        return [pscustomobject]@{ LogName = $LogName; State = 'disabled'; Events = @() }
    }
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = $LogName; StartTime = (Get-Date).AddHours(-4) } -MaxEvents 100 -ErrorAction Stop |
        Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message)
    return [pscustomobject]@{ LogName = $LogName; State = 'enabled'; Events = $events }
}

$currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$addPrinterCommand = Get-Command Add-Printer -ErrorAction SilentlyContinue
$targetQueue = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
$allPrinters = @(Get-Printer -ErrorAction SilentlyContinue)
$allDrivers = @(Get-PrinterDriver -ErrorAction SilentlyContinue)
$allPorts = @(Get-PrinterPort -ErrorAction SilentlyContinue)
$presentPnpDevices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)
$relevantPnpDevices = @($presentPnpDevices | Where-Object {
    $_.Class -in @('Printer', 'PrintQueue', 'USB') -or
    $_.FriendlyName -match 'Brother|printer' -or
    $_.InstanceId -match 'VID_[0-9A-F]{4}&PID_[0-9A-F]{4}'
} | Select-Object Status, Class, FriendlyName, InstanceId, Manufacturer, Problem, Present)

$wppPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\WPP'
$wppPolicy = if (Test-Path -LiteralPath $wppPolicyPath) {
    Get-ItemProperty -LiteralPath $wppPolicyPath |
        Select-Object WindowsProtectedPrintGroupPolicyState, WindowsProtectedPrintMode, EnabledBy
}
else {
    $null
}

$endpointProbe = $null
if (-not [string]::IsNullOrWhiteSpace($IppUrl)) {
    try {
        $uri = [Uri]$IppUrl
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('ipp', 'ipps', 'http', 'https') -or [string]::IsNullOrWhiteSpace($uri.Host)) {
            throw 'Expected an absolute ipp, ipps, http, or https URI.'
        }
        $port = $uri.Port
        if ($port -lt 1) { $port = if ($uri.Scheme -in @('ipps', 'https')) { 443 } else { 631 } }
        $tcpSucceeded = $false
        $tcpError = $null
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $async = $client.BeginConnect($uri.DnsSafeHost, $port, $null, $null)
            if (-not $async.AsyncWaitHandle.WaitOne(5000)) {
                throw 'TCP connection timed out after 5 seconds.'
            }
            $client.EndConnect($async)
            $tcpSucceeded = $true
        }
        catch { $tcpError = $_.Exception.Message }
        finally { $client.Dispose() }
        $endpointProbe = [ordered]@{
            url = $uri.AbsoluteUri
            host = $uri.DnsSafeHost
            port = $port
            tcpSucceeded = $tcpSucceeded
            error = $tcpError
            note = 'This is a TCP reachability probe, not IPP negotiation.'
        }
    }
    catch {
        $endpointProbe = [ordered]@{ url = $IppUrl; tcpSucceeded = $false; error = $_.Exception.Message }
    }
}

$targetJobs = @()
$targetConfiguration = $null
if ($null -ne $targetQueue) {
    try {
        $targetJobs = @(Get-PrintJob -PrinterName $PrinterName -ErrorAction Stop |
            Select-Object Id, DocumentName, JobStatus, Status, SubmittedTime, Size, TotalPages, PagesPrinted)
    }
    catch { }
    try {
        $targetConfiguration = Get-PrintConfiguration -PrinterName $PrinterName -ErrorAction Stop |
            Select-Object PrinterName, PaperSize, Color, DuplexingMode, Collate
    }
    catch { }
}

$report = [ordered]@{
    schema = 'printbridge.m0.windows-diagnostics.v1'
    collectedUtc = [DateTime]::UtcNow.ToString('o')
    scopeNotice = 'Software-only inventory. Physical printing cannot be inferred from this report.'
    os = [ordered]@{
        productNameRegistry = $currentVersion.ProductName
        displayVersion = $currentVersion.DisplayVersion
        currentBuild = $currentVersion.CurrentBuild
        updateBuildRevision = $currentVersion.UBR
        editionId = $currentVersion.EditionID
        installationType = $currentVersion.InstallationType
        runtimeDescription = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        osArchitecture = [string][Runtime.InteropServices.RuntimeInformation]::OSArchitecture
        powershellVersion = $PSVersionTable.PSVersion.ToString()
        powershellEdition = $PSVersionTable.PSEdition
    }
    printManagement = [ordered]@{
        moduleAvailable = $null -ne $addPrinterCommand
        addPrinterIppUrlSupported = $null -ne $addPrinterCommand -and $addPrinterCommand.Parameters.ContainsKey('IppURL')
        addPrinterParameterSets = if ($null -ne $addPrinterCommand) { @($addPrinterCommand.ParameterSets | ForEach-Object { $_.ToString() }) } else { @() }
        expectedInboxDriver = 'Microsoft IPP Class Driver'
    }
    protectedPrint = [ordered]@{
        policyRegistryPath = $wppPolicyPath
        policyKeyPresent = $null -ne $wppPolicy
        rawPolicyValues = $wppPolicy
        interpretation = if ($null -eq $wppPolicy) { 'Group Policy key is not configured. Confirm the current setting in Settings > Bluetooth & devices > Printers & scanners.' } else { 'Raw values captured; do not change them for M0. Confirm the effective state in Windows Settings.' }
    }
    spooler = Invoke-Diagnostic -Name 'Spooler service' -ScriptBlock {
        Get-Service -Name Spooler | Select-Object Name, Status, StartType
    }
    endpointProbe = $endpointProbe
    target = [ordered]@{
        requestedPrinterName = $PrinterName
        found = $null -ne $targetQueue
        driverIsMicrosoftInboxIpp = $null -ne $targetQueue -and $targetQueue.DriverName -eq 'Microsoft IPP Class Driver'
        queue = if ($null -ne $targetQueue) { $targetQueue | Select-Object Name, DriverName, PortName, Comment, PrinterStatus, Type, Shared } else { $null }
        configuration = $targetConfiguration
        jobs = $targetJobs
    }
    printers = @($allPrinters | Select-Object Name, DriverName, PortName, Comment, PrinterStatus, Type, Shared)
    printerDrivers = @($allDrivers | Select-Object Name, Manufacturer, MajorVersion, InfPath, PrinterEnvironment, IsPackageAware, DriverPath, ConfigFile, DataFile)
    printerPorts = @($allPorts | Select-Object Name, Description, PrinterHostAddress, PortNumber, Protocol, SNMPEnabled)
    usbAndPrintDevices = $relevantPnpDevices
    pnpCounts = [ordered]@{
        presentDevicesVisible = $presentPnpDevices.Count
        relevantDevices = $relevantPnpDevices.Count
        note = 'A zero count can mean the execution context cannot enumerate devices; it is not proof that no hardware exists.'
    }
    network = Invoke-Diagnostic -Name 'IPv4 addresses' -ScriptBlock {
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -ne '127.0.0.1' } |
            Select-Object InterfaceAlias, IPAddress, PrefixLength, AddressState
    }
    printServiceAdminLog = Invoke-Diagnostic -Name 'PrintService Admin events (last 4h)' -ScriptBlock {
        Get-PrintEvents -LogName 'Microsoft-Windows-PrintService/Admin'
    }
    printServiceOperationalLog = Invoke-Diagnostic -Name 'PrintService Operational events (last 4h)' -ScriptBlock {
        Get-PrintEvents -LogName 'Microsoft-Windows-PrintService/Operational'
    }
}

$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$jsonPath = Join-Path $OutputDirectory "$stamp-windows-diagnostics.json"
$summaryPath = Join-Path $OutputDirectory "$stamp-windows-summary.txt"
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$targetDriver = if ($null -eq $targetQueue) { '<queue not found>' } else { $targetQueue.DriverName }
$summary = @"
PrintBridge M0 Windows diagnostics
Collected UTC: $($report.collectedUtc)
OS registry display/build: $($currentVersion.DisplayVersion) $($currentVersion.CurrentBuild).$($currentVersion.UBR) ($([Runtime.InteropServices.RuntimeInformation]::OSArchitecture))
Add-Printer -IppURL available: $($report.printManagement.addPrinterIppUrlSupported)
Windows Protected Print policy key present: $($report.protectedPrint.policyKeyPresent)
Target queue: $PrinterName
Target driver: $targetDriver
Expected driver: Microsoft IPP Class Driver
Target driver matches: $($report.target.driverIsMicrosoftInboxIpp)
Relevant USB/print devices visible: $($relevantPnpDevices.Count)
Endpoint TCP probe: $(if ($null -eq $endpointProbe) { '<not requested>' } else { $endpointProbe.tcpSucceeded })

This report does not prove that a page physically printed. Review it for machine
names, local addresses, USB serials, document names, and other sensitive details
before sharing or committing it.
"@
$summary | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host "Diagnostics JSON: $jsonPath"
Write-Host "Summary:          $summaryPath"
Write-Host 'Expected Windows inbox driver: Microsoft IPP Class Driver'
Write-Host 'Reminder: these diagnostics cannot establish a physical-print PASS.'

