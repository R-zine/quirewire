[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('PASS', 'FAIL', 'NOT TESTED')]
    [string]$LinuxUsbBaseline,

    [Parameter(Mandatory = $true)]
    [ValidateSet('PASS', 'FAIL', 'NOT TESTED')]
    [string]$WindowsTextPhysical,

    [Parameter(Mandatory = $true)]
    [ValidateSet('PASS', 'FAIL', 'NOT TESTED')]
    [string]$WindowsPdfPhysical,

    [ValidateSet('PASS', 'FAIL', 'NOT TESTED', 'NOT_SUPPORTED')]
    [string]$ColorDuplexPhysical = 'NOT TESTED',

    [string]$DriverName,
    [string]$PrinterName = 'Brother via QuireWire POC',
    [string]$IppUrl,
    [string]$LinuxQueue,
    [string]$WindowsTextApplication,
    [string]$WindowsPdfApplication,
    [string[]]$CupsJobIds = @(),
    [string[]]$PhotoPaths = @(),
    [string]$Notes,
    [string]$OutputDirectory,

    [switch]$ConfirmPhysicalObservation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedDriver = 'Microsoft IPP Class Driver'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m0\acceptance'
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$photoEvidence = @()
foreach ($photoPath in $PhotoPaths) {
    $resolved = Resolve-Path -LiteralPath $photoPath -ErrorAction Stop
    $hash = Get-FileHash -LiteralPath $resolved.Path -Algorithm SHA256
    $photoEvidence += [ordered]@{
        path = $resolved.Path
        sha256 = $hash.Hash
        length = (Get-Item -LiteralPath $resolved.Path).Length
    }
}

$requiredResults = @($LinuxUsbBaseline, $WindowsTextPhysical, $WindowsPdfPhysical)
$driverMatches = $DriverName -ceq $ExpectedDriver
$anyFailure = $requiredResults -contains 'FAIL'
$allRequiredPass = @($requiredResults | Where-Object { $_ -eq 'PASS' }).Count -eq 3
$parsedIppUri = $null
$validIppUri = [Uri]::TryCreate($IppUrl, [UriKind]::Absolute, [ref]$parsedIppUri) -and
    $parsedIppUri.Scheme -in @('ipp', 'ipps', 'http', 'https') -and
    -not [string]::IsNullOrWhiteSpace($parsedIppUri.Host)
$metadataComplete = $validIppUri -and
    -not [string]::IsNullOrWhiteSpace($LinuxQueue) -and
    -not [string]::IsNullOrWhiteSpace($WindowsTextApplication) -and
    -not [string]::IsNullOrWhiteSpace($WindowsPdfApplication) -and
    $CupsJobIds.Count -ge 2

if ($anyFailure -or (($WindowsTextPhysical -eq 'PASS' -or $WindowsPdfPhysical -eq 'PASS') -and -not $driverMatches)) {
    $result = 'FAIL'
    $reason = if (-not $driverMatches -and ($WindowsTextPhysical -eq 'PASS' -or $WindowsPdfPhysical -eq 'PASS')) {
        "A Windows physical test was reported, but the queue driver was '$DriverName' rather than '$ExpectedDriver'."
    }
    else {
        'At least one required physical test was reported as FAIL.'
    }
}
elseif ($allRequiredPass -and $driverMatches -and $metadataComplete -and $ConfirmPhysicalObservation) {
    $result = 'PASS: PHYSICAL'
    $reason = 'Linux USB baseline plus Windows text and PDF pages were explicitly confirmed on paper with the Microsoft inbox IPP driver.'
}
else {
    $result = 'BLOCKED: REQUIRES HARDWARE'
    $reason = 'A required physical result, exact driver check, job/application metadata, or explicit physical-observation confirmation is missing.'
}

$record = [ordered]@{
    schema = 'quirewire.m0.physical-acceptance.v1'
    recordedUtc = [DateTime]::UtcNow.ToString('o')
    result = $result
    reason = $reason
    physicalObservationExplicitlyConfirmed = [bool]$ConfirmPhysicalObservation
    expectedWindowsDriver = $ExpectedDriver
    observedWindowsDriver = $DriverName
    driverMatches = $driverMatches
    requiredMetadataComplete = $metadataComplete
    endpoint = [ordered]@{
        ippUrl = $IppUrl
        linuxQueue = $LinuxQueue
        windowsPrinterName = $PrinterName
    }
    tests = [ordered]@{
        linuxUsbBaseline = $LinuxUsbBaseline
        windowsTextPhysical = $WindowsTextPhysical
        windowsTextApplication = $WindowsTextApplication
        windowsPdfPhysical = $WindowsPdfPhysical
        windowsPdfApplication = $WindowsPdfApplication
        colorDuplexPhysical = $ColorDuplexPhysical
        cupsJobIds = $CupsJobIds
    }
    photoEvidence = $photoEvidence
    notes = $Notes
}

$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$jsonPath = Join-Path $OutputDirectory "$stamp-m0-physical-acceptance.json"
$markdownPath = Join-Path $OutputDirectory "$stamp-m0-physical-acceptance.md"
$record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$photoLines = if ($photoEvidence.Count -eq 0) {
    '- No photo paths recorded; the explicit owner result is still preserved.'
}
else {
    @($photoEvidence | ForEach-Object { "- $($_.path) (SHA-256: $($_.sha256))" }) -join "`n"
}
$jobText = if ($CupsJobIds.Count -eq 0) { '<not recorded>' } else { $CupsJobIds -join ', ' }
$markdown = @"
# QuireWire M0 physical acceptance record

- Recorded UTC: $($record.recordedUtc)
- Result: **$result**
- Reason: $reason
- Explicit physical observation confirmed: $([bool]$ConfirmPhysicalObservation)
- Windows driver expected: ``$ExpectedDriver``
- Windows driver observed: ``$DriverName``
- Driver match: $driverMatches
- Required metadata complete: $metadataComplete
- IPP URL: ``$IppUrl``
- Linux queue: ``$LinuxQueue``
- Windows queue: ``$PrinterName``

## Required results

- Linux CUPS -> USB physical baseline: **$LinuxUsbBaseline**
- Windows text physical print ($WindowsTextApplication): **$WindowsTextPhysical**
- Windows PDF/image physical print ($WindowsPdfApplication): **$WindowsPdfPhysical**
- Optional color/duplex physical print: **$ColorDuplexPhysical**
- CUPS job IDs: $jobText

## Photo evidence

$photoLines

## Notes

$Notes
"@
$markdown | Set-Content -LiteralPath $markdownPath -Encoding UTF8

Write-Host "M0 result: $result"
Write-Host "JSON evidence:     $jsonPath"
Write-Host "Markdown evidence: $markdownPath"
if ($result -ne 'PASS: PHYSICAL') {
    Write-Host 'Do not begin M1.'
}

