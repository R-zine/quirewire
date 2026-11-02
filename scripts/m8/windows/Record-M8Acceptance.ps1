[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaselinePath,
    [Parameter(Mandatory)][string]$InstalledPath,
    [Parameter(Mandatory)][string]$RepairedPath,
    [Parameter(Mandatory)][string]$UninstalledPath,
    [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$InstalledPagePrinted,
    [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$RepairedPagePrinted,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path 'artifacts\m8\acceptance'
}

function Read-Diagnostic([string]$Path, [string]$Phase) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing $Phase diagnostics." }
    $value = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    if ($value.schema -ne 'quirewire.m8.diagnostics.v1' -or $value.phase -ne $Phase) {
        throw "The $Phase diagnostics have the wrong schema or phase."
    }
    $value
}

function Names-ExceptOwned([object]$Value) {
    @($Value.printers | Where-Object { $_.name -ne 'Brother via QuireWire' } | ForEach-Object { $_.name } | Sort-Object)
}

function VmUuids([object]$Value) {
    @($Value.virtual_machines | ForEach-Object { $_.uuid } | Sort-Object)
}

$baseline = Read-Diagnostic $BaselinePath 'Baseline'
$installed = Read-Diagnostic $InstalledPath 'Installed'
$repaired = Read-Diagnostic $RepairedPath 'Repaired'
$uninstalled = Read-Diagnostic $UninstalledPath 'Uninstalled'
$installedQueue = @($installed.printers | Where-Object { $_.name -eq 'Brother via QuireWire' })
$repairedQueue = @($repaired.printers | Where-Object { $_.name -eq 'Brother via QuireWire' })
$uninstalledQueue = @($uninstalled.printers | Where-Object { $_.name -eq 'Brother via QuireWire' })
$unrelatedPrintersPreserved = ((Names-ExceptOwned $baseline) -join "`n") -eq ((Names-ExceptOwned $uninstalled) -join "`n")
$unrelatedVmsPreserved = ((VmUuids $baseline) -join "`n") -eq ((VmUuids $uninstalled) -join "`n")

$checks = [ordered]@{
    installer_manifest_present = [bool]$installed.manifest_present
    installed_task_limited = [bool]($installed.task.present -and $installed.task.run_level -eq 'Limited')
    installed_queue_owned_driver = [bool]($installedQueue.Count -eq 1 -and $installedQueue[0].driver -eq 'Microsoft IPP Class Driver')
    installed_page_physically_printed = $InstalledPagePrinted -eq 'yes'
    repair_retained_manifest = [bool]$repaired.manifest_present
    repair_task_limited = [bool]($repaired.task.present -and $repaired.task.run_level -eq 'Limited')
    repair_queue_owned_driver = [bool]($repairedQueue.Count -eq 1 -and $repairedQueue[0].driver -eq 'Microsoft IPP Class Driver')
    repaired_page_physically_printed = $RepairedPagePrinted -eq 'yes'
    uninstall_task_absent = -not [bool]$uninstalled.task.present
    uninstall_owned_queue_absent = $uninstalledQueue.Count -eq 0
    uninstall_manifest_absent = -not [bool]$uninstalled.manifest_present
    uninstall_config_absent = -not [bool]$uninstalled.config_present
    uninstall_printer_state_absent = -not [bool]$uninstalled.printer_state_present
    uninstall_state_absent = -not [bool]$uninstalled.state_directory_present
    uninstall_logs_absent = -not [bool]$uninstalled.log_directory_present
    uninstall_app_executable_absent = -not [bool]$uninstalled.app_executable_present
    uninstall_uninstaller_absent = -not [bool]$uninstalled.uninstaller_present
    uninstall_registration_absent = -not [bool]$uninstalled.uninstall_registration_present
    unrelated_printers_preserved = $unrelatedPrintersPreserved
    unrelated_vms_preserved = $unrelatedVmsPreserved
}
$passed = @($checks.Values | Where-Object { -not $_ }).Count -eq 0
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$path = Join-Path $OutputDirectory "$stamp-m8-acceptance.json"
[ordered]@{
    schema = 'quirewire.m8.acceptance.v1'
    recorded_utc = [DateTime]::UtcNow.ToString('o')
    result = if ($passed) { 'PASS: PHYSICAL' } else { 'FAIL' }
    checks = $checks
    evidence = [ordered]@{
        baseline = (Resolve-Path -LiteralPath $BaselinePath).Path
        installed = (Resolve-Path -LiteralPath $InstalledPath).Path
        repaired = (Resolve-Path -LiteralPath $RepairedPath).Path
        uninstalled = (Resolve-Path -LiteralPath $UninstalledPath).Path
    }
} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $path -Encoding utf8
[pscustomobject]@{ schema = 'quirewire.m8.acceptance-result.v1'; result = if ($passed) { 'PASS: PHYSICAL' } else { 'FAIL' }; path = $path } | ConvertTo-Json
if (-not $passed) { exit 2 }
