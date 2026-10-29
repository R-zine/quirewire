[CmdletBinding()]
param(
    [string]$CliExecutable = (Join-Path $PSScriptRoot '..\..\..\target\debug\printbridgectl.exe'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\..\..\artifacts\m6\diagnostics')
)

$ErrorActionPreference = 'Stop'
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$destination = Join-Path $OutputDirectory "$timestamp-m6-diagnostics.json"

$cliOutput = @(& $CliExecutable diagnostics 2>&1 | ForEach-Object { $_.ToString() })
$cliExit = $LASTEXITCODE
$task = Get-ScheduledTask -TaskPath '\PrintBridge\' -TaskName 'Agent' -ErrorAction SilentlyContinue
$taskInfo = if ($task) { Get-ScheduledTaskInfo -TaskPath '\PrintBridge\' -TaskName 'Agent' } else { $null }
$processes = @(Get-Process -Name 'printbridge-agent' -ErrorAction SilentlyContinue | ForEach-Object {
    [ordered]@{ id = $_.Id; start_time_utc = $_.StartTime.ToUniversalTime().ToString('o'); working_set_bytes = $_.WorkingSet64 }
})
$queue = Get-Printer -Name 'Brother via PrintBridge' -Full -ErrorAction SilentlyContinue

$record = [ordered]@{
    schema = 'printbridge.m6.diagnostics.v1'
    generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    cli_exit_code = $cliExit
    agent_diagnostics = ($cliOutput -join "`n")
    agent_processes = $processes
    startup_task = if ($task) {
        [ordered]@{
            path = '\PrintBridge\Agent'
            state = $task.State.ToString()
            principal_user_id = $task.Principal.UserId
            logon_type = $task.Principal.LogonType.ToString()
            run_level = $task.Principal.RunLevel.ToString()
            last_run_time_utc = $taskInfo.LastRunTime.ToUniversalTime().ToString('o')
            last_task_result = $taskInfo.LastTaskResult
        }
    } else { $null }
    windows_queue = if ($queue) {
        [ordered]@{
            name = $queue.Name
            driver_name = $queue.DriverName
            port_name = $queue.PortName
            printer_status = $queue.PrinterStatus.ToString()
            is_default = [bool]$queue.Default
        }
    } else { $null }
    physical_output = 'not_inferred'
    redaction = 'USB serial values and raw VirtualBox output are intentionally omitted.'
}
$record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $destination -Encoding utf8
Write-Host "M6 diagnostics: $destination"
if ($cliExit -ne 0) { exit 1 }
