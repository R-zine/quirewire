[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare', 'Complete')][string]$Action,
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'QuireWire'),
    [string]$CheckpointPath,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m9\host-reboot'
}
if ([string]::IsNullOrWhiteSpace($CheckpointPath)) {
    $CheckpointPath = Join-Path $OutputDirectory 'pending-reboot.json'
}
$DataRoot = [IO.Path]::GetFullPath($DataRoot)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$CheckpointPath = [IO.Path]::GetFullPath($CheckpointPath)
$cliPath = Join-Path $DataRoot 'bin\quirewirectl.exe'
$manifestPath = Join-Path $DataRoot 'installation.json'
foreach ($required in @($cliPath, $manifestPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required reboot-test dependency is absent: $required" }
}
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($manifest.schema -ne 'quirewire.m8.installation.v1' -or $manifest.owner_sid -ne $ownerSid -or
    [IO.Path]::GetFullPath($manifest.data_root) -ne $DataRoot) {
    throw 'The M8 manifest does not authorize this host-reboot test.'
}
function Status {
    $output = @(& $cliPath status 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw 'The QuireWire agent is unavailable.' }
    ($output -join "`n") | ConvertFrom-Json
}
function ExactAgents {
    @(Get-CimInstance Win32_Process -Filter "Name='quirewire-agent.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -eq [IO.Path]::GetFullPath($manifest.agent_path) })
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
if ($Action -eq 'Prepare') {
    $status = Status
    $agents = @(ExactAgents)
    if ($status.value.overall -ne 'ready' -or $agents.Count -ne 1) { throw 'Reboot preparation requires ready and exactly one agent.' }
    [ordered]@{
        schema = 'quirewire.m9.reboot-checkpoint.v1'
        prepared_utc = [DateTime]::UtcNow.ToString('o')
        boot_utc = $boot.ToString('o')
        agent_pid = [int]$agents[0].ProcessId
        state_revision = [uint64]$status.value.revision
        desired = $status.value.desired
    } | ConvertTo-Json | Set-Content -LiteralPath $CheckpointPath -Encoding utf8
    [pscustomobject]@{ schema = 'quirewire.m9.reboot-prepare-result.v1'; checkpoint = $CheckpointPath; action_required = 'Restart Windows, log in normally, then run -Action Complete.' } | ConvertTo-Json
    exit 0
}
if (-not (Test-Path -LiteralPath $CheckpointPath -PathType Leaf)) { throw 'The M9 reboot checkpoint is absent.' }
$checkpoint = Get-Content -Raw -LiteralPath $CheckpointPath | ConvertFrom-Json
if ($checkpoint.schema -ne 'quirewire.m9.reboot-checkpoint.v1') { throw 'The M9 reboot checkpoint schema is invalid.' }
if ($boot -le [DateTime]::Parse($checkpoint.boot_utc).ToUniversalTime()) { throw 'Windows has not rebooted since the M9 checkpoint.' }
$deadline = [DateTime]::UtcNow.AddMinutes(5)
do {
    try { $status = Status; $agents = @(ExactAgents) } catch { $status = $null; $agents = @() }
    if ($status -and $status.value.overall -eq 'ready' -and $agents.Count -eq 1) { break }
    Start-Sleep -Seconds 3
} while ([DateTime]::UtcNow -lt $deadline)
if (-not $status -or $status.value.overall -ne 'ready' -or $agents.Count -ne 1) { throw 'QuireWire did not become ready with exactly one agent after reboot.' }
if ($agents[0].ProcessId -eq [int]$checkpoint.agent_pid -or $status.value.desired -ne $checkpoint.desired -or
    [uint64]$status.value.revision -ne [uint64]$checkpoint.state_revision) {
    throw 'The reboot did not preserve the expected new process and immutable desired-state generation.'
}
$printOutput = @(& $cliPath test-print 2>&1 | ForEach-Object { $_.ToString() })
if ($LASTEXITCODE -ne 0) { throw 'Post-reboot test-page submission failed.' }
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$path = Join-Path $OutputDirectory "$stamp-host-reboot.json"
[ordered]@{
    schema = 'quirewire.m9.host-reboot.v1'
    prepared_utc = $checkpoint.prepared_utc
    previous_boot_utc = $checkpoint.boot_utc
    completed_utc = [DateTime]::UtcNow.ToString('o')
    current_boot_utc = $boot.ToString('o')
    new_agent_process = $true
    state_revision_preserved = $true
    desired_state_preserved = $true
    overall = $status.value.overall
    test_print_output = ($printOutput -join "`n")
    physical_output = 'requires_owner_confirmation'
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8
Remove-Item -LiteralPath $CheckpointPath -Force
[pscustomobject]@{ schema = 'quirewire.m9.host-reboot-result.v1'; path = $path; physical_output = 'requires_owner_confirmation' } | ConvertTo-Json
