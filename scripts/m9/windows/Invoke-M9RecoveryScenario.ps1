[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('SecondInstance', 'VmCrash', 'GuestCupsRestart', 'PortConflict',
        'SpoolerRestart', 'ColdStart', 'LowDiskGuard')]
    [string]$Scenario,
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'QuireWire'),
    [string]$OutputDirectory,
    [string]$VBoxManage = (Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'),
    [ValidateRange(30, 600)][int]$RecoveryTimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m9\recovery'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$DataRoot = [IO.Path]::GetFullPath($DataRoot)
$manifestPath = Join-Path $DataRoot 'installation.json'
$configPath = Join-Path $DataRoot 'm6.conf'
foreach ($required in @($manifestPath, $configPath, $VBoxManage)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required recovery dependency is absent: $required" }
}
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($manifest.schema -ne 'quirewire.m8.installation.v1' -or $manifest.owner_sid -ne $ownerSid -or
    [IO.Path]::GetFullPath($manifest.data_root) -ne $DataRoot -or -not $manifest.vm) {
    throw 'The M8 manifest does not authorize this exact recovery target.'
}
$agentPath = [IO.Path]::GetFullPath($manifest.agent_path)
$cliPath = [IO.Path]::GetFullPath($manifest.cli_path)
$vmUuid = [string]$manifest.vm.uuid
$config = @{}
foreach ($line in Get-Content -LiteralPath $configPath) {
    $parts = $line.Split('=', 2)
    if ($parts.Count -ne 2 -or $config.ContainsKey($parts[0])) { throw 'The M6 configuration is malformed.' }
    $config[$parts[0]] = $parts[1]
}
if ($config.vm_uuid -ne $vmUuid -or $config.endpoint_port -notmatch '^[0-9]{1,5}$') {
    throw 'The configuration and installation manifest identify different recovery targets.'
}

function Invoke-VBox([string[]]$Arguments, [switch]$AllowFailure) {
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& $VBoxManage @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousErrorAction }
    if (-not $AllowFailure -and $code -ne 0) { throw "VBoxManage failed: $($Arguments[0])" }
    [pscustomobject]@{ code = $code; output = $lines }
}
function Get-ExtraData([string]$Key) {
    $line = (Invoke-VBox @('getextradata', $vmUuid, $Key)).output | Select-Object -First 1
    if ($line -notmatch '^Value:\s*(.+)$') { throw "The owned VM is missing $Key." }
    $Matches[1].Trim()
}
if ((Get-ExtraData 'QuireWire/Schema') -ne $manifest.vm.schema -or
    (Get-ExtraData 'QuireWire/Owner') -ne $manifest.vm.marker) {
    throw 'The live VM no longer matches both manifest ownership values.'
}

function Invoke-Cli([string[]]$Arguments, [switch]$AllowFailure) {
    $lines = @(& $cliPath @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $code = $LASTEXITCODE
    if (-not $AllowFailure -and $code -ne 0) { throw "QuireWire CLI failed: $($Arguments -join ' ')" }
    [pscustomobject]@{ code = $code; output = ($lines -join "`n") }
}
function Get-Status {
    $result = Invoke-Cli @('status')
    $result.output | ConvertFrom-Json
}
$timeline = [Collections.Generic.List[object]]::new()
function Add-Status([string]$Label) {
    $status = Get-Status
    $timeline.Add([ordered]@{
        observed_utc = [DateTime]::UtcNow.ToString('o')
        label = $Label
        overall = $status.value.overall
        hypervisor = $status.value.components.hypervisor.state
        guest = $status.value.components.guest.state
        usb = $status.value.components.usb.state
        cups = $status.value.components.cups.state
        windows_queue = $status.value.components.windows_queue.state
    })
    $status
}
function Wait-Overall([string[]]$Accepted, [string]$Label) {
    $deadline = [DateTime]::UtcNow.AddSeconds($RecoveryTimeoutSeconds)
    do {
        try {
            $status = Add-Status $Label
            if ($status.value.overall -in $Accepted) { return $status }
        }
        catch { }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for status: $($Accepted -join ', ')."
}
function Exact-AgentProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name='quirewire-agent.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -eq $agentPath })
}
function Inventory {
    [ordered]@{
        printers = @(Get-Printer | ForEach-Object Name | Sort-Object)
        default_printer = @((Get-CimInstance Win32_Printer | Where-Object { [bool]$_.Default }).Name) -join "`n"
        vm_uuids = @((Invoke-VBox @('list', 'vms')).output | ForEach-Object { if ($_ -match '\{([0-9a-fA-F-]{36})\}$') { $Matches[1].ToLowerInvariant() } } | Sort-Object)
    }
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$before = Inventory
$started = [DateTime]::UtcNow
$submission = $null
$details = [ordered]@{}
$listener = $null
try {
    $null = Add-Status 'before'
    switch ($Scenario) {
        'SecondInstance' {
            $agents = @(Exact-AgentProcesses)
            if ($agents.Count -ne 1) { throw 'Second-instance test requires exactly one original agent.' }
            $originalPid = $agents[0].ProcessId
            $process = Start-Process -FilePath $agentPath -ArgumentList @('run', '--config', ('"{0}"' -f $configPath)) `
                -WindowStyle Hidden -Wait -PassThru
            Start-Sleep -Seconds 1
            $afterAgents = @(Exact-AgentProcesses)
            if ($process.ExitCode -eq 0 -or $afterAgents.Count -ne 1 -or $afterAgents[0].ProcessId -ne $originalPid) {
                throw 'A second agent was not rejected without disturbing the original.'
            }
            $details = [ordered]@{ original_pid_preserved = $true; rejected_exit_code = $process.ExitCode }
        }
        'VmCrash' {
            $null = Wait-Overall @('ready') 'pre-crash-ready'
            $crashedAt = [DateTime]::UtcNow
            $null = Invoke-VBox @('controlvm', $vmUuid, 'poweroff')
            $null = Wait-Overall @('connecting', 'error', 'waiting_for_usb') 'crash-observed'
            $null = Wait-Overall @('ready') 'crash-recovered'
            $details = [ordered]@{ recovery_seconds = [math]::Round(([DateTime]::UtcNow - $crashedAt).TotalSeconds, 3); hard_poweroff = $true }
            $submission = Invoke-Cli @('test-print')
        }
        'GuestCupsRestart' {
            $null = Wait-Overall @('ready') 'pre-restart-ready'
            $restartAt = [DateTime]::UtcNow
            $null = Invoke-Cli @('restart')
            $null = Wait-Overall @('connecting', 'waiting_for_usb', 'error') 'guest-cups-restart-observed'
            $null = Wait-Overall @('ready') 'guest-cups-restart-recovered'
            $details = [ordered]@{ recovery_seconds = [math]::Round(([DateTime]::UtcNow - $restartAt).TotalSeconds, 3); method = 'owned guest restart, which restarts CUPS' }
            $submission = Invoke-Cli @('test-print')
        }
        'PortConflict' {
            $port = [int]$config.endpoint_port
            $null = Invoke-Cli @('stop')
            $null = Wait-Overall @('stopped') 'bridge-stopped'
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
            $listener.Start()
            $start = Invoke-Cli @('start') -AllowFailure
            $null = Wait-Overall @('error') 'port-conflict-observed'
            $listener.Stop(); $listener = $null
            $repairAt = [DateTime]::UtcNow
            $null = Invoke-Cli @('repair')
            $null = Wait-Overall @('ready') 'port-conflict-recovered'
            $details = [ordered]@{ port = $port; start_exit_code = $start.code; recovery_seconds = [math]::Round(([DateTime]::UtcNow - $repairAt).TotalSeconds, 3) }
            $submission = Invoke-Cli @('test-print')
        }
        'SpoolerRestart' {
            $helper = Join-Path $PSScriptRoot '..\..\m6\windows\Invoke-M6SpoolerInterruption.ps1'
            $helperResult = Join-Path $OutputDirectory ('.spooler-' + [Guid]::NewGuid().ToString('N') + '.json')
            $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $helper),'-HoldSeconds','15','-ResultPath',('"{0}"' -f $helperResult))
            $process = Start-Process -FilePath $powershellPath -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
            if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $helperResult -PathType Leaf)) { throw 'The scoped Spooler restart failed or was declined.' }
            $helperEvidence = Get-Content -Raw -LiteralPath $helperResult | ConvertFrom-Json
            Remove-Item -LiteralPath $helperResult -Force
            $recoveryAt = [DateTime]::UtcNow
            $null = Wait-Overall @('ready') 'spooler-recovered'
            $details = [ordered]@{ hold_seconds = $helperEvidence.hold_seconds; recovery_seconds_after_service_start = [math]::Round(([DateTime]::UtcNow - $recoveryAt).TotalSeconds, 3) }
            $submission = Invoke-Cli @('test-print')
        }
        'ColdStart' {
            $null = Invoke-Cli @('stop')
            $null = Wait-Overall @('stopped') 'cold-start-stopped'
            $coldAt = [DateTime]::UtcNow
            $null = Invoke-Cli @('start')
            $null = Wait-Overall @('ready') 'cold-start-ready'
            $details = [ordered]@{ bridge_cold_start_seconds = [math]::Round(([DateTime]::UtcNow - $coldAt).TotalSeconds, 3); agent_restart_included = $false }
            $submission = Invoke-Cli @('test-print')
        }
        'LowDiskGuard' {
            $applicationSoak = Join-Path $PSScriptRoot 'Invoke-M9ApplicationSoak.ps1'
            $driveRoot = [IO.Path]::GetPathRoot($DataRoot).TrimEnd('\')
            $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$driveRoot'"
            $required = [uint64]$drive.FreeSpace + 1
            $jobsBefore = @(Get-PrintJob -PrinterName $manifest.queue.name -ErrorAction SilentlyContinue).Count
            $previousErrorAction = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $output = @(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $applicationSoak -Action Plan -MinimumFreeBytes $required 2>&1 | ForEach-Object { $_.ToString() })
                $exitCode = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $previousErrorAction }
            $jobsAfter = @(Get-PrintJob -PrinterName $manifest.queue.name -ErrorAction SilentlyContinue).Count
            if ($exitCode -eq 0 -or ($output -join "`n") -notmatch 'LOW_DISK:' -or $jobsBefore -ne $jobsAfter) {
                throw 'The simulated low-disk guard did not refuse before print submission.'
            }
            $details = [ordered]@{ simulated = $true; actual_disk_not_filled = $true; no_job_submitted = $true; guard_exit_code = $exitCode }
        }
    }
}
finally {
    if ($listener) { $listener.Stop() }
}
$after = Inventory
if (($before.printers -join "`n") -ne ($after.printers -join "`n") -or
    $before.default_printer -ne $after.default_printer -or
    ($before.vm_uuids -join "`n") -ne ($after.vm_uuids -join "`n")) {
    throw 'The recovery scenario changed unrelated printer/default/VM inventory.'
}
$finalStatus = Add-Status 'final'
if ($finalStatus.value.overall -ne 'ready') { throw "The scenario did not finish ready: $($finalStatus.value.overall)" }
$finalAgents = @(Exact-AgentProcesses)
$finalAgentCount = $finalAgents.Count
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$path = Join-Path $OutputDirectory "$stamp-$($Scenario.ToLowerInvariant()).json"
[ordered]@{
    schema = 'quirewire.m9.recovery-scenario.v1'
    scenario = $Scenario
    started_utc = $started.ToString('o')
    completed_utc = [DateTime]::UtcNow.ToString('o')
    details = $details
    timeline = $timeline
    test_print = if ($submission) { [ordered]@{ exit_code = $submission.code; output = $submission.output; physical_output = 'requires_owner_confirmation' } } else { $null }
    exact_agent_processes = $finalAgentCount
    unrelated_printers_preserved = $true
    default_printer_preserved = $true
    unrelated_vms_preserved = $true
    physical_output = if ($submission) { 'requires_owner_confirmation' } else { 'not_applicable' }
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
[pscustomobject]@{ schema = 'quirewire.m9.recovery-result.v1'; path = $path; scenario = $Scenario; physical_output = if ($submission) { 'requires_owner_confirmation' } else { 'not_applicable' } } | ConvertTo-Json
