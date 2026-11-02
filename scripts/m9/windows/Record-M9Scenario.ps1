[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('standard-app-text-pdf', 'sequential-text-pdf', 'long-pdf', 'usb-idle',
        'usb-during-print', 'host-reboot', 'vm-crash', 'sleep-resume', 'spooler-restart',
        'cups-restart', 'no-paper', 'port-conflict', 'second-instance',
        'uninstall-reinstall', 'ui-closed', 'low-disk', 'cold-start')]
    [string]$Scenario,
    [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$Result,
    [Parameter(Mandatory)][ValidateSet('yes', 'no', 'not-applicable')][string]$OwnerConfirmedPhysical,
    [Parameter(Mandatory)][string]$EvidencePath,
    [Parameter(Mandatory)][ValidateLength(1, 1000)][string]$Notes,
    [string]$OutputDirectory,
    [switch]$Replace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m9\scenarios'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) { throw 'Scenario evidence file is absent.' }
$resolvedEvidence = (Resolve-Path -LiteralPath $EvidencePath).Path
try { $evidence = Get-Content -Raw -LiteralPath $resolvedEvidence | ConvertFrom-Json }
catch { throw 'Scenario evidence is not valid JSON.' }
if ([string]::IsNullOrWhiteSpace([string]$evidence.schema) -or [string]$evidence.schema -notmatch '^quirewire\.') {
    throw 'Scenario evidence does not have a QuireWire schema.'
}
$physicalRequired = $Scenario -notin @('second-instance', 'low-disk')
if ($physicalRequired -and $OwnerConfirmedPhysical -eq 'not-applicable') {
    throw "$Scenario requires an explicit owner physical observation."
}
if (-not $physicalRequired -and $OwnerConfirmedPhysical -ne 'not-applicable') {
    throw "$Scenario is software-observable and must use not-applicable for physical confirmation."
}
if ($Result -eq 'PASS' -and $physicalRequired -and $OwnerConfirmedPhysical -ne 'yes') {
    throw 'A physically required scenario cannot pass without owner confirmation.'
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$destination = Join-Path $OutputDirectory "$Scenario.json"
if (Test-Path -LiteralPath $destination -PathType Leaf) {
    $existing = $null
    try { $existing = Get-Content -Raw -LiteralPath $destination | ConvertFrom-Json } catch { }
    if (-not $Replace -or -not $existing -or $existing.schema -ne 'quirewire.m9.scenario-record.v1' -or
        $existing.scenario -ne $Scenario) {
        throw 'Refusing to overwrite an existing scenario record without -Replace and matching ownership.'
    }
}
[ordered]@{
    schema = 'quirewire.m9.scenario-record.v1'
    recorded_utc = [DateTime]::UtcNow.ToString('o')
    scenario = $Scenario
    result = $Result
    physical_required = $physicalRequired
    owner_confirmed_physical = if ($OwnerConfirmedPhysical -eq 'not-applicable') { $null } else { $OwnerConfirmedPhysical -eq 'yes' }
    evidence = [ordered]@{
        path = $resolvedEvidence
        schema = [string]$evidence.schema
        sha256 = (Get-FileHash -LiteralPath $resolvedEvidence -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    notes = $Notes
    caution = 'Software submission, queue drain, and CUPS state never prove physical paper output.'
} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $destination -Encoding utf8
[pscustomobject]@{ schema = 'quirewire.m9.scenario-record-result.v1'; path = $destination; scenario = $Scenario; result = $Result } | ConvertTo-Json
if ($Result -ne 'PASS') { exit 2 }
