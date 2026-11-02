[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$DashboardReady,
    [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$SetupFlowWorked,
    [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$UiPagePrinted,
    [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$TrayPagePrinted,
    [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$DiagnosticsExported,
    [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$RepairReturnedReady,
    [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$CloseKeptAgentRunning,
    [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$ExitKeptAgentRunning,
    [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$PrintCompletedAfterUiExit,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot 'artifacts\m7\acceptance'
}
$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null

$checks = [ordered]@{
    dashboard_ready = $DashboardReady
    setup_flow_worked = $SetupFlowWorked
    ui_page_physically_printed = $UiPagePrinted
    tray_page_physically_printed = $TrayPagePrinted
    diagnostics_exported = $DiagnosticsExported
    repair_returned_ready = $RepairReturnedReady
    close_kept_agent_running = $CloseKeptAgentRunning
    exit_kept_agent_running = $ExitKeptAgentRunning
    print_completed_after_ui_exit = $PrintCompletedAfterUiExit
}
$allPassed = @($checks.Values | Where-Object { $_ -ne 'yes' }).Count -eq 0
$timestamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$record = [ordered]@{
    schema = 'quirewire.m7.acceptance.v1'
    recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    result = if ($allPassed) { 'PASS: PHYSICAL' } else { 'FAIL' }
    checks = $checks
    note = 'Physical output values are owner observations; this script does not infer paper output.'
}
$path = Join-Path $resolvedOutput "$timestamp-m7-acceptance.json"
$record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8
Write-Host "M7 acceptance record: $path"
Write-Host "Result: $($record.result)"
if (-not $allPassed) { exit 1 }
