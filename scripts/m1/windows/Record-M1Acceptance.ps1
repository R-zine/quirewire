[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$')]
    [string]$VmUuid,

    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$GuestUsbBaseline,
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$WindowsTextPhysical,
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$WindowsPdfPhysical,
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$CleanGuestBootPhysical,
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$UsbReconnectPhysical,
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$HostRebootPhysical,
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$ExactUsbCapture,
    [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$HeadlessOperation,
    [Parameter(Mandatory = $true)][string]$DriverName,
    [Parameter(Mandatory = $true)][string]$QueueName,
    [Parameter(Mandatory = $true)][string]$JobEvidence,
    [Parameter(Mandatory = $true)][string]$Notes,
    [switch]$OwnerConfirmedPhysicalOutput,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m1\acceptance'
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$checks = [ordered]@{
    guestUsbBaseline = $GuestUsbBaseline
    windowsTextPhysical = $WindowsTextPhysical
    windowsPdfPhysical = $WindowsPdfPhysical
    cleanGuestBootPhysical = $CleanGuestBootPhysical
    usbReconnectPhysical = $UsbReconnectPhysical
    hostRebootPhysical = $HostRebootPhysical
    exactUsbCapture = $ExactUsbCapture
    headlessOperation = $HeadlessOperation
}
$values = @($checks.Values)
$hasFailure = $values -contains 'FAIL'
$allPassed = @($values | Where-Object { $_ -ne 'PASS' }).Count -eq 0
$driverMatches = $DriverName -eq 'Microsoft IPP Class Driver'
$metadataComplete = -not [string]::IsNullOrWhiteSpace($QueueName) -and
    -not [string]::IsNullOrWhiteSpace($JobEvidence) -and
    -not [string]::IsNullOrWhiteSpace($Notes)

$result = if ($hasFailure) {
    'FAIL'
}
elseif ($allPassed -and $driverMatches -and $metadataComplete -and $OwnerConfirmedPhysicalOutput.IsPresent) {
    'PASS: PHYSICAL'
}
else {
    'BLOCKED: REQUIRES HARDWARE'
}

$report = [ordered]@{
    schema = 'quirewire.m1.acceptance.v1'
    recordedUtc = [DateTime]::UtcNow.ToString('o')
    result = $result
    vmUuid = $VmUuid.ToLowerInvariant()
    queueName = $QueueName
    driverName = $DriverName
    driverIsMicrosoftInboxIpp = $driverMatches
    checks = $checks
    ownerConfirmedPhysicalOutput = $OwnerConfirmedPhysicalOutput.IsPresent
    jobEvidence = $JobEvidence
    notes = $Notes
    caution = 'CUPS/Windows job completion alone does not prove physical output.'
}

$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$jsonPath = Join-Path $OutputDirectory "$stamp-m1-acceptance.json"
$markdownPath = Join-Path $OutputDirectory "$stamp-m1-acceptance.md"
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$rows = foreach ($entry in $checks.GetEnumerator()) {
    "| $($entry.Key) | $($entry.Value) |"
}
@"
# QuireWire M1 physical acceptance

- Recorded UTC: $($report.recordedUtc)
- Result: **$result**
- Owned VM UUID: ``$($report.vmUuid)``
- Windows queue: ``$QueueName``
- Windows driver: ``$DriverName``
- Owner confirmed paper output: ``$($OwnerConfirmedPhysicalOutput.IsPresent)``

| Check | Result |
|---|---|
$($rows -join [Environment]::NewLine)

Job evidence: $JobEvidence

Notes: $Notes

Job completion by itself is not evidence that paper physically printed.
"@ | Set-Content -LiteralPath $markdownPath -Encoding UTF8

Write-Host "Acceptance JSON:     $jsonPath"
Write-Host "Acceptance Markdown: $markdownPath"
Write-Host "Result:              $result"

if ($result -eq 'FAIL') { exit 1 }
