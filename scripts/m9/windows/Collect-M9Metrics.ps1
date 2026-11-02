[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Baseline', 'PostSoak', 'PostRecovery', 'Final')][string]$Phase,
    [ValidateRange(5, 300)][int]$DurationSeconds = 30,
    [ValidateRange(1, 30)][int]$SampleIntervalSeconds = 2,
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'QuireWire'),
    [string]$OutputDirectory,
    [string]$VBoxManage = (Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m9\metrics'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$DataRoot = [IO.Path]::GetFullPath($DataRoot)
$manifestPath = Join-Path $DataRoot 'installation.json'
$cliPath = Join-Path $DataRoot 'bin\quirewirectl.exe'
foreach ($required in @($manifestPath, $cliPath, $VBoxManage)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required metrics dependency is absent: $required" }
}
$ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.schema -ne 'quirewire.m8.installation.v1' -or $manifest.owner_sid -ne $ownerSid -or
    [IO.Path]::GetFullPath($manifest.data_root) -ne $DataRoot -or -not $manifest.vm) {
    throw 'The M8 manifest does not authorize metrics for this user, data root, and VM.'
}
$agentPath = [IO.Path]::GetFullPath($manifest.agent_path)
$vmUuid = [string]$manifest.vm.uuid
if ($vmUuid -notmatch '^[0-9a-fA-F-]{36}$') { throw 'The manifest VM UUID is invalid.' }
$ippUri = [Uri]$manifest.queue.ipp_url
$ownedVmConnection = Get-NetTCPConnection -LocalAddress ([Net.IPAddress]::Loopback.ToString()) `
    -LocalPort $ippUri.Port -State Listen -ErrorAction SilentlyContinue
$ownedVmPid = if (@($ownedVmConnection).Count -eq 1) { [int]$ownedVmConnection.OwningProcess } else { $null }
if ($ownedVmPid) {
    $ownedVmProcess = Get-Process -Id $ownedVmPid -ErrorAction SilentlyContinue
    if (-not $ownedVmProcess -or $ownedVmProcess.ProcessName -ne 'VBoxHeadless') { $ownedVmPid = $null }
}

function Invoke-VBox([string[]]$Arguments) {
    $lines = @(& $VBoxManage @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw "VBoxManage metrics query failed: $($Arguments[0])" }
    $lines
}

function Get-DirectoryBytes([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return [uint64]0 }
    [uint64](@(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction Stop |
        Measure-Object -Property Length -Sum).Sum)
}

function Get-Status {
    $output = @(& $cliPath status 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw 'The QuireWire agent is unavailable during metrics collection.' }
    ($output -join "`n") | ConvertFrom-Json
}

$vmInfo = @{}
foreach ($line in Invoke-VBox @('showvminfo', $vmUuid, '--machinereadable')) {
    if ($line -match '^([^=]+)="(.*)"$' -or $line -match '^([^=]+)=(.*)$') {
        $key = $Matches[1].Trim('"')
        $value = $Matches[2].Trim('"')
        if ($key -eq 'CfgFile') { $value = $value.Replace('\\', '\') }
        $vmInfo[$key] = $value
    }
}
if ($vmInfo.UUID -ne $vmUuid) { throw 'VBoxManage did not resolve the exact manifest VM UUID.' }
$vmDirectory = if ($vmInfo.CfgFile) { Split-Path -Parent $vmInfo.CfgFile } else { $null }
$statusBefore = Get-Status
$dataBytesBefore = Get-DirectoryBytes $DataRoot
$vmBytesBefore = if ($vmDirectory) { Get-DirectoryBytes $vmDirectory } else { [uint64]0 }
$samples = [Collections.Generic.List[object]]::new()
$watch = [Diagnostics.Stopwatch]::StartNew()
do {
    $cim = @(Get-CimInstance Win32_Process -Filter "Name='quirewire-agent.exe' OR Name='VBoxHeadless.exe' OR Name='quirewire-desktop.exe'" -ErrorAction Stop)
    foreach ($process in $cim) {
        $kind = $null
        if ($process.Name -eq 'quirewire-agent.exe' -and $process.ExecutablePath -and
            [IO.Path]::GetFullPath($process.ExecutablePath) -eq $agentPath) { $kind = 'agent' }
        elseif ($process.Name -eq 'VBoxHeadless.exe' -and $ownedVmPid -and
            $process.ProcessId -eq $ownedVmPid) { $kind = 'owned_vm' }
        elseif ($process.Name -eq 'quirewire-desktop.exe' -and $process.ExecutablePath -and
            [IO.Path]::GetFullPath($process.ExecutablePath).StartsWith($DataRoot, [StringComparison]::OrdinalIgnoreCase)) { $kind = 'desktop' }
        if (-not $kind) { continue }
        $live = Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
        if (-not $live) { continue }
        $samples.Add([pscustomobject][ordered]@{
            elapsed_ms = [math]::Round($watch.Elapsed.TotalMilliseconds, 1)
            kind = $kind
            pid = [int]$live.Id
            working_set_bytes = [uint64]$live.WorkingSet64
            private_bytes = [uint64]$live.PrivateMemorySize64
            cpu_seconds = if ($null -eq $live.CPU) { $null } else { [math]::Round([double]$live.CPU, 6) }
        })
    }
    if ($watch.Elapsed.TotalSeconds -lt $DurationSeconds) { Start-Sleep -Seconds $SampleIntervalSeconds }
} while ($watch.Elapsed.TotalSeconds -lt $DurationSeconds)
$actualSeconds = $watch.Elapsed.TotalSeconds
$statusAfter = Get-Status
$dataBytesAfter = Get-DirectoryBytes $DataRoot
$vmBytesAfter = if ($vmDirectory) { Get-DirectoryBytes $vmDirectory } else { [uint64]0 }

function Summarize([string]$Kind) {
    $values = @($samples | Where-Object kind -eq $Kind)
    if ($values.Count -eq 0) { return $null }
    $cpuDelta = 0.0
    foreach ($group in $values | Group-Object pid) {
        $ordered = @($group.Group | Sort-Object elapsed_ms)
        if ($ordered.Count -gt 1 -and $null -ne $ordered[0].cpu_seconds -and $null -ne $ordered[-1].cpu_seconds) {
            $cpuDelta += [math]::Max(0, [double]$ordered[-1].cpu_seconds - [double]$ordered[0].cpu_seconds)
        }
    }
    [ordered]@{
        pids = @($values | ForEach-Object pid | Sort-Object -Unique)
        sample_count = $values.Count
        working_set_peak_bytes = [uint64](($values | Measure-Object working_set_bytes -Maximum).Maximum)
        working_set_mean_bytes = [uint64](($values | Measure-Object working_set_bytes -Average).Average)
        private_peak_bytes = [uint64](($values | Measure-Object private_bytes -Maximum).Maximum)
        cpu_delta_seconds = [math]::Round($cpuDelta, 6)
        average_cpu_percent_one_core = [math]::Round(($cpuDelta / $actualSeconds) * 100, 4)
    }
}

$agent = Summarize 'agent'
$ownedVm = Summarize 'owned_vm'
$desktop = Summarize 'desktop'
if (-not $agent -or @($agent.pids).Count -ne 1) { throw 'Metrics require exactly one installed QuireWire agent.' }
$targets = [ordered]@{
    agent_working_set_max_bytes = 50MB
    agent_average_cpu_max_percent_one_core = 1.0
    guest_configured_memory_mib = 768
    data_growth_max_bytes_per_sample = 4MB
}
$comparisons = [ordered]@{
    agent_working_set = if ($agent.working_set_peak_bytes -le $targets.agent_working_set_max_bytes) { 'PASS' } else { 'ABOVE_TARGET' }
    agent_average_cpu = if ($agent.average_cpu_percent_one_core -le $targets.agent_average_cpu_max_percent_one_core) { 'PASS' } else { 'ABOVE_TARGET' }
    guest_memory = if ([int]$vmInfo.memory -eq $targets.guest_configured_memory_mib) { 'PASS' } else { 'OUTSIDE_TARGET' }
    sample_data_growth = if (([int64]$dataBytesAfter - [int64]$dataBytesBefore) -le $targets.data_growth_max_bytes_per_sample) { 'PASS' } else { 'ABOVE_TARGET' }
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$path = Join-Path $OutputDirectory "$stamp-$($Phase.ToLowerInvariant()).json"
[ordered]@{
    schema = 'quirewire.m9.metrics.v1'
    captured_utc = [DateTime]::UtcNow.ToString('o')
    phase = $Phase
    duration_seconds = [math]::Round($actualSeconds, 3)
    status_before = $statusBefore.value
    status_after = $statusAfter.value
    agent = $agent
    owned_vm_process = $ownedVm
    desktop = $desktop
    vm = [ordered]@{ uuid = $vmUuid; state = $vmInfo.VMState; configured_memory_mib = [int]$vmInfo.memory; configured_cpus = [int]$vmInfo.cpus }
    storage = [ordered]@{
        data_root_bytes_before = $dataBytesBefore
        data_root_bytes_after = $dataBytesAfter
        data_root_growth_bytes = [int64]$dataBytesAfter - [int64]$dataBytesBefore
        vm_directory_bytes_before = $vmBytesBefore
        vm_directory_bytes_after = $vmBytesAfter
        vm_directory_growth_bytes = [int64]$vmBytesAfter - [int64]$vmBytesBefore
    }
    targets = $targets
    comparisons = $comparisons
    redaction = 'USB serial, process command lines, environment, window titles, and file contents are omitted.'
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
[pscustomobject]@{ schema = 'quirewire.m9.metrics-result.v1'; path = $path; phase = $Phase; comparisons = $comparisons } | ConvertTo-Json -Depth 5
