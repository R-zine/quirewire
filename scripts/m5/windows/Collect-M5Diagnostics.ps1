[CmdletBinding()]
param(
    [ValidateSet('Baseline', 'Installed', 'Restarted', 'Removed', 'Final')]
    [string]$Phase = 'Baseline',
    [string]$PrinterName = 'Brother via PrintBridge',
    [string]$IppUrl = 'http://127.0.0.1:8644/printers/PrintBridge_DCP_L2600D',
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m5\diagnostics'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
$statePath = Join-Path $env:LOCALAPPDATA 'PrintBridge\m5-windows-printer.json'
$providerScript = Join-Path $PSScriptRoot 'Invoke-M5WindowsPrinting.ps1'

$addPrinter = Get-Command Add-Printer -ErrorAction SilentlyContinue
$spooler = Get-Service -Name Spooler -ErrorAction Stop
$default = Get-CimInstance Win32_Printer -ErrorAction Stop |
    Where-Object { [bool]$_.Default } | Select-Object -First 1 Name, DriverName, PortName
$target = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
$jobs = if ($null -eq $target) { @() } else {
    @(Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue |
        Select-Object Id, JobStatus, SubmittedTime, TotalPages, PagesPrinted)
}
$allQueues = @(Get-Printer | Sort-Object Name |
    Select-Object Name, DriverName, PortName, PrinterStatus, Type, Shared, Published, Comment)

$uri = [Uri]$IppUrl
$tcpSucceeded = $false
$client = [Net.Sockets.TcpClient]::new()
try {
    $pending = $client.BeginConnect($uri.DnsSafeHost, $uri.Port, $null, $null)
    if ($pending.AsyncWaitHandle.WaitOne(3000)) {
        $client.EndConnect($pending)
        $tcpSucceeded = $true
    }
}
catch { $tcpSucceeded = $false }
finally { $client.Dispose() }

$providerOutput = @(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $providerScript -Action Status -PrinterName $PrinterName -IppUrl $IppUrl -StatePath $statePath)
$providerExitCode = $LASTEXITCODE

$os = Get-ComputerInfo -Property WindowsProductName, WindowsVersion, OsBuildNumber, OsArchitecture
$report = [ordered]@{
    schema = 'printbridge.m5.diagnostics.v1'
    collectedUtc = [DateTime]::UtcNow.ToString('o')
    phase = $Phase
    caution = 'Spooler/job/CUPS completion does not prove physical paper output.'
    os = $os
    powershell = [ordered]@{
        version = [string]$PSVersionTable.PSVersion
        edition = [string]$PSVersionTable.PSEdition
    }
    printManagement = [ordered]@{
        available = $null -ne $addPrinter
        version = if ($null -eq $addPrinter) { $null } else { [string]$addPrinter.Version }
        ippUrlSupported = $null -ne $addPrinter -and $addPrinter.Parameters.ContainsKey('IppURL')
    }
    spooler = [ordered]@{ status = [string]$spooler.Status; startType = [string]$spooler.StartType }
    endpoint = [ordered]@{ ippUrl = $IppUrl; tcpSucceeded = $tcpSucceeded }
    defaultPrinter = $default
    target = [ordered]@{
        requestedName = $PrinterName
        found = $null -ne $target
        queue = if ($null -eq $target) { $null } else {
            $target | Select-Object Name, DriverName, PortName, PrinterStatus, Type, Shared, Published, Comment
        }
        driverIsMicrosoftInboxIpp = $null -ne $target -and $target.DriverName -eq 'Microsoft IPP Class Driver'
        jobs = $jobs
    }
    allQueues = $allQueues
    ownershipRecordPresent = Test-Path -LiteralPath $statePath -PathType Leaf
    providerStatus = [ordered]@{ exitCode = $providerExitCode; protocolLines = $providerOutput }
}

$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$path = Join-Path $OutputDirectory "$stamp-$($Phase.ToLowerInvariant()).json"
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
Write-Host "Diagnostics: $path"
Write-Host "Target found: $($report.target.found)"
Write-Host "Microsoft IPP driver: $($report.target.driverIsMicrosoftInboxIpp)"
Write-Host "Default printer: $($default.Name)"
Write-Host "Endpoint TCP: $tcpSucceeded"
Write-Host 'Physical output: NOT INFERRED'
