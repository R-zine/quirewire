[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MetricsBaselinePath,
    [Parameter(Mandatory)][string]$MetricsFinalPath,
    [Parameter(Mandatory)][string]$DocumentManifestPath,
    [Parameter(Mandatory)][string]$ScenarioDirectory,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m9\acceptance'
}
$requiredScenarios = @(
    'sequential-text-pdf', 'long-pdf', 'usb-idle', 'vm-crash',
    'spooler-restart', 'cups-restart', 'port-conflict', 'second-instance',
    'low-disk', 'cold-start'
)
$deferredScenarios = @(
    'standard-app-text-pdf', 'usb-during-print', 'host-reboot', 'sleep-resume',
    'no-paper', 'uninstall-reinstall', 'ui-closed'
)
function Read-Json([string]$Path, [string]$Schema) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { $value = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json } catch { return $null }
    if ($value.schema -ne $Schema) { return $null }
    $value
}
$baseline = Read-Json $MetricsBaselinePath 'printbridge.m9.metrics.v1'
$final = Read-Json $MetricsFinalPath 'printbridge.m9.metrics.v1'
$documents = Read-Json $DocumentManifestPath 'printbridge.m9.test-documents.v1'
$scenarioRecords = [ordered]@{}
$missing = [Collections.Generic.List[string]]::new()
foreach ($name in $requiredScenarios) {
    $path = Join-Path $ScenarioDirectory "$name.json"
    $record = Read-Json $path 'printbridge.m9.scenario-record.v1'
    if (-not $record -or $record.scenario -ne $name) { $missing.Add($name); continue }
    $scenarioRecords[$name] = $record
}
$checks = [ordered]@{
    baseline_metrics_valid = $null -ne $baseline -and $baseline.phase -eq 'Baseline'
    baseline_status_ready = $null -ne $baseline -and $baseline.status_before.overall -eq 'ready' -and $baseline.status_after.overall -eq 'ready'
    final_metrics_valid = $null -ne $final -and $final.phase -eq 'Final'
    document_manifest_valid = $null -ne $documents -and $documents.sequential_job_count -ge 20 -and $documents.long_pdf.pages -ge 10
    every_scenario_recorded = $missing.Count -eq 0
    every_scenario_passed = $missing.Count -eq 0 -and @($scenarioRecords.Values | Where-Object result -ne 'PASS').Count -eq 0
    every_physical_scenario_confirmed = $missing.Count -eq 0 -and @($scenarioRecords.Values | Where-Object { $_.physical_required -and -not $_.owner_confirmed_physical }).Count -eq 0
    final_status_ready = $null -ne $final -and $final.status_after.overall -eq 'ready'
    one_agent_final = $null -ne $final -and @($final.agent.pids).Count -eq 1
    agent_rss_target = $null -ne $final -and $final.comparisons.agent_working_set -eq 'PASS'
    agent_cpu_target = $null -ne $final -and $final.comparisons.agent_average_cpu -eq 'PASS'
    guest_memory_target = $null -ne $final -and $final.comparisons.guest_memory -eq 'PASS'
    bounded_data_growth = $null -ne $baseline -and $null -ne $final -and
        ([int64]$final.storage.data_root_bytes_after - [int64]$baseline.storage.data_root_bytes_before) -le 32MB
    bounded_vm_growth = $null -ne $baseline -and $null -ne $final -and
        ([int64]$final.storage.vm_directory_bytes_after - [int64]$baseline.storage.vm_directory_bytes_before) -le 128MB
    evidence_hashes_match = $missing.Count -eq 0 -and @($scenarioRecords.Values | Where-Object {
        -not (Test-Path -LiteralPath $_.evidence.path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $_.evidence.path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $_.evidence.sha256
    }).Count -eq 0
}

if ($scenarioRecords.Contains('sequential-text-pdf')) {
    $sequentialEvidence = Read-Json $scenarioRecords['sequential-text-pdf'].evidence.path 'printbridge.m9.application-soak.v1'
    $checks['sequential_20_mixed_jobs'] = $null -ne $sequentialEvidence -and @($sequentialEvidence.jobs).Count -ge 20 -and
        @($sequentialEvidence.jobs | Where-Object format -eq 'text/plain').Count -ge 10 -and
        @($sequentialEvidence.jobs | Where-Object format -eq 'application/pdf').Count -ge 10
    if ($sequentialEvidence) {
        $latencies = @($sequentialEvidence.jobs | ForEach-Object { [double]$_.cups_observed_ms } | Sort-Object)
        $p95Index = [math]::Max(0, [math]::Ceiling($latencies.Count * 0.95) - 1)
        $checks['submission_latency_p95'] = $latencies.Count -ge 20 -and $latencies[$p95Index] -le 10000
    }
    else { $checks['submission_latency_p95'] = $false }
}
else { $checks['sequential_20_mixed_jobs'] = $false; $checks['submission_latency_p95'] = $false }
if ($scenarioRecords.Contains('long-pdf')) {
    $longEvidence = Read-Json $scenarioRecords['long-pdf'].evidence.path 'printbridge.m9.application-soak.v1'
    $checks['long_pdf_submitted'] = $null -ne $longEvidence -and @($longEvidence.jobs).Count -eq 1 -and $documents.long_pdf.pages -ge 10
}
else { $checks['long_pdf_submitted'] = $false }

$timedScenarios = [ordered]@{
    'cold-start' = 'bridge_cold_start_seconds'
    'vm-crash' = 'recovery_seconds'
    'cups-restart' = 'recovery_seconds'
    'port-conflict' = 'recovery_seconds'
    'usb-idle' = 'recovery_seconds'
    'spooler-restart' = 'recovery_seconds_after_service_start'
}
$timingsPass = $true
foreach ($entry in $timedScenarios.GetEnumerator()) {
    if (-not $scenarioRecords.Contains($entry.Key)) { $timingsPass = $false; continue }
    try {
        $evidence = Get-Content -Raw -LiteralPath $scenarioRecords[$entry.Key].evidence.path | ConvertFrom-Json
        if ($entry.Key -eq 'usb-idle') {
            $loss = @($evidence.timeline | Where-Object {
                $_.label -eq 'waiting-for-usb' -and $_.usb -in @('waiting', 'error')
            } | Select-Object -First 1)
            $recovered = @($evidence.timeline | Where-Object {
                $_.label -eq 'usb-recovered' -and $_.overall -eq 'ready'
            } | Select-Object -First 1)
            if ($loss.Count -ne 1 -or $recovered.Count -ne 1) { throw 'USB transition timestamps are absent.' }
            $seconds = ([DateTimeOffset]::Parse([string]$recovered[0].observed_utc) -
                [DateTimeOffset]::Parse([string]$loss[0].observed_utc)).TotalSeconds
        }
        else {
            $seconds = [double]$evidence.details.($entry.Value)
        }
        if ($seconds -lt 0 -or $seconds -gt 180) { $timingsPass = $false }
    }
    catch { $timingsPass = $false }
}
$checks['recovery_time_targets'] = $timingsPass

$passed = @($checks.Values | Where-Object { -not $_ }).Count -eq 0
$result = if ($passed) { 'PASS: PHYSICAL' } elseif ($missing.Count -gt 0 -or -not $checks.every_physical_scenario_confirmed) { 'BLOCKED: REQUIRES HARDWARE' } else { 'FAIL' }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$path = Join-Path $OutputDirectory "$stamp-m9-acceptance.json"
[ordered]@{
    schema = 'printbridge.m9.acceptance.v1'
    recorded_utc = [DateTime]::UtcNow.ToString('o')
    result = $result
    checks = $checks
    missing_scenarios = $missing
    scenario_policy = [ordered]@{
        required = $requiredScenarios
        deferred_non_gating = $deferredScenarios
        rationale = 'Bounded owner-approved M9 gate; deferred stress checks are not claimed as passed.'
    }
    targets = [ordered]@{
        agent_working_set_max_bytes = 50MB
        agent_average_cpu_max_percent_one_core = 1.0
        guest_memory_mib = 768
        cold_start_max_seconds = 180
        recovery_max_seconds = 180
        data_growth_max_bytes = 32MB
        vm_growth_max_bytes = 128MB
    }
    evidence = [ordered]@{
        baseline_metrics = if ($baseline) { (Resolve-Path -LiteralPath $MetricsBaselinePath).Path } else { $MetricsBaselinePath }
        final_metrics = if ($final) { (Resolve-Path -LiteralPath $MetricsFinalPath).Path } else { $MetricsFinalPath }
        document_manifest = if ($documents) { (Resolve-Path -LiteralPath $DocumentManifestPath).Path } else { $DocumentManifestPath }
        scenario_directory = [IO.Path]::GetFullPath($ScenarioDirectory)
    }
    caution = 'Physical output fields originate only from explicit owner observations. Deferred scenarios are non-gating and are not reported as passed.'
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
[pscustomobject]@{ schema = 'printbridge.m9.acceptance-result.v1'; result = $result; path = $path; missing_scenarios = $missing } | ConvertTo-Json -Depth 5
if (-not $passed) { exit 2 }
