[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$InstallIdempotent,
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$DriverVerified,
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$CliTestPagePhysical,
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$WindowsTextPhysical,
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$WindowsPdfPhysical,
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$RestartPersistence,
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$IndependentRemoval,
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$DefaultPrinterPreserved,
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$UnrelatedPrintersPreserved,
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$FinalReinstall,
    [string]$PrinterName = 'Brother via PrintBridge',
    [string]$DriverName = 'Microsoft IPP Class Driver',
    [string]$IppUrl = 'http://127.0.0.1:8644/printers/PrintBridge_DCP_L2600D',
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Evidence,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Notes,
    [switch]$OwnerConfirmedPhysicalOutput,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m5\acceptance'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory

$checks = [ordered]@{
    installIdempotent = $InstallIdempotent
    driverVerified = $DriverVerified
    cliTestPagePhysical = $CliTestPagePhysical
    windowsTextPhysical = $WindowsTextPhysical
    windowsPdfPhysical = $WindowsPdfPhysical
    restartPersistence = $RestartPersistence
    independentRemoval = $IndependentRemoval
    defaultPrinterPreserved = $DefaultPrinterPreserved
    unrelatedPrintersPreserved = $UnrelatedPrintersPreserved
    finalReinstall = $FinalReinstall
}
$values = @($checks.Values)
$hasFailure = $values -contains 'FAIL'
$allPassed = @($values | Where-Object { $_ -ne 'PASS' }).Count -eq 0
$driverMatches = $DriverName -eq 'Microsoft IPP Class Driver'
$result = if ($hasFailure) {
    'FAIL'
}
elseif ($allPassed -and $driverMatches -and $OwnerConfirmedPhysicalOutput.IsPresent) {
    'PASS: PHYSICAL'
}
else {
    'BLOCKED: REQUIRES HARDWARE'
}

$record = [ordered]@{
    schema = 'printbridge.m5.acceptance.v1'
    recordedUtc = [DateTime]::UtcNow.ToString('o')
    result = $result
    printerName = $PrinterName
    driverName = $DriverName
    driverIsMicrosoftInboxIpp = $driverMatches
    ippUrl = $IppUrl
    checks = $checks
    ownerConfirmedPhysicalOutput = $OwnerConfirmedPhysicalOutput.IsPresent
    evidence = $Evidence
    notes = $Notes
    caution = 'Windows spooler submission and CUPS completion do not prove physical output.'
}
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$jsonPath = Join-Path $OutputDirectory "$stamp-m5-acceptance.json"
$markdownPath = Join-Path $OutputDirectory "$stamp-m5-acceptance.md"
$record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
$rows = foreach ($entry in $checks.GetEnumerator()) { "| $($entry.Key) | $($entry.Value) |" }
@"
# PrintBridge M5 physical acceptance

- Recorded UTC: $($record.recordedUtc)
- Result: **$result**
- Queue: ``$PrinterName``
- Driver: ``$DriverName``
- Endpoint: ``$IppUrl``
- Owner confirmed physical output: ``$($OwnerConfirmedPhysicalOutput.IsPresent)``

| Check | Result |
|---|---|
$($rows -join [Environment]::NewLine)

Evidence: $Evidence

Notes: $Notes

Spooler submission and CUPS completion do not establish physical output.
"@ | Set-Content -LiteralPath $markdownPath -Encoding UTF8

Write-Host "Acceptance JSON: $jsonPath"
Write-Host "Acceptance Markdown: $markdownPath"
Write-Host "Result: $result"
if ($result -eq 'FAIL') { exit 1 }
