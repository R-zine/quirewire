[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('UsbIdle', 'UsbDuringPrint', 'SleepResume', 'NoPaper')][string]$Scenario,
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'QuireWire'),
    [string]$DocumentDirectory,
    [string]$PdfToolPath,
    [string]$OutputDirectory,
    [ValidateRange(60, 900)][int]$TimeoutSeconds = 600,
    [ValidateRange(5, 60)][int]$ActionDelaySeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($DocumentDirectory)) {
    $DocumentDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m9\documents'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m9\manual'
}
if ([string]::IsNullOrWhiteSpace($PdfToolPath)) {
    $PdfToolPath = Join-Path $PSScriptRoot '..\..\..\artifacts\m9\tools\SumatraPDF-3.6.1-64\SumatraPDF-3.6.1-64.exe'
}
$DataRoot = [IO.Path]::GetFullPath($DataRoot)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$cliPath = Join-Path $DataRoot 'bin\quirewirectl.exe'
$manifestPath = Join-Path $DataRoot 'installation.json'
foreach ($required in @($cliPath, $manifestPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required manual-test dependency is absent: $required" }
}
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($manifest.schema -ne 'quirewire.m8.installation.v1' -or $manifest.owner_sid -ne $ownerSid -or
    [IO.Path]::GetFullPath($manifest.data_root) -ne $DataRoot) {
    throw 'The M8 manifest does not authorize this exact manual-test target.'
}

function Invoke-Cli([string[]]$Arguments) {
    $output = @(& $cliPath @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw "QuireWire CLI failed: $($Arguments -join ' ')" }
    ($output -join "`n")
}
function Get-Status {
    (Invoke-Cli @('status')) | ConvertFrom-Json
}
$timeline = [Collections.Generic.List[object]]::new()
function Observe([string]$Label) {
    $status = Get-Status
    $timeline.Add([pscustomobject][ordered]@{
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
function Wait-Condition([scriptblock]$Predicate, [string]$Label) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $status = Observe $Label
            if (& $Predicate $status) { return $status }
        }
        catch { }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out during manual scenario $Scenario ($Label)."
}

$before = Observe 'before'
if ($before.value.overall -ne 'ready') { throw "Manual scenario requires ready; observed $($before.value.overall)." }
$started = [DateTime]::UtcNow
$details = [ordered]@{}
$submission = $null
switch ($Scenario) {
    'UsbIdle' {
        Write-Host "ACTION REQUIRED: unplug the Brother USB cable within $ActionDelaySeconds seconds, wait for detection, then reconnect it."
        Start-Sleep -Seconds $ActionDelaySeconds
        $null = Wait-Condition { param($s) $s.value.components.usb.state -in @('waiting', 'error') } 'waiting-for-usb'
        $disconnectObservedAt = [DateTime]::UtcNow
        Write-Host 'USB disconnect detected. Reconnect the same printer now.'
        $null = Wait-Condition { param($s) $s.value.overall -eq 'ready' } 'usb-recovered'
        $details = [ordered]@{
            recovery_seconds = [math]::Round(([DateTime]::UtcNow - $disconnectObservedAt).TotalSeconds, 3)
            recovery_measurement_origin = 'observed USB loss'
            disconnect_detected = $true
        }
        $submission = Invoke-Cli @('test-print')
    }
    'UsbDuringPrint' {
        Write-Host "ACTION REQUIRED: after the long PDF starts printing, unplug USB during a page; reconnect it after status detects the loss. Submission begins in $ActionDelaySeconds seconds."
        Start-Sleep -Seconds $ActionDelaySeconds
        $soak = Join-Path $PSScriptRoot 'Invoke-M9ApplicationSoak.ps1'
        $spoolOutput = @(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $soak `
            -Action LongPdf -DocumentDirectory $DocumentDirectory -PdfToolPath $PdfToolPath -SkipCupsCompletionWait 2>&1 | ForEach-Object { $_.ToString() })
        if ($LASTEXITCODE -ne 0) { throw 'Long PDF submission failed before USB interruption monitoring.' }
        $null = Wait-Condition { param($s) $s.value.components.usb.state -in @('waiting', 'error') } 'print-usb-loss'
        $disconnectObservedAt = [DateTime]::UtcNow
        Write-Host 'USB loss detected. Reconnect the same printer now.'
        $null = Wait-Condition { param($s) $s.value.overall -eq 'ready' } 'print-usb-recovered'
        $details = [ordered]@{
            recovery_seconds = [math]::Round(([DateTime]::UtcNow - $disconnectObservedAt).TotalSeconds, 3)
            recovery_measurement_origin = 'observed USB loss'
            application_soak_result = ($spoolOutput -join "`n")
        }
        $submission = Invoke-Cli @('test-print')
    }
    'SleepResume' {
        Write-Host "ACTION REQUIRED: put Windows to sleep within $ActionDelaySeconds seconds, wait at least 30 seconds, then resume and unlock."
        $last = [DateTime]::UtcNow
        $largestGap = 0.0
        Start-Sleep -Seconds $ActionDelaySeconds
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        do {
            $now = [DateTime]::UtcNow
            $gap = ($now - $last).TotalSeconds
            if ($gap -gt $largestGap) { $largestGap = $gap }
            $last = $now
            try { $status = Observe 'sleep-resume-monitor' } catch { $status = $null }
            if ($largestGap -ge 20 -and $status -and $status.value.overall -eq 'ready') { break }
            Start-Sleep -Seconds 2
        } while ([DateTime]::UtcNow -lt $deadline)
        if ($largestGap -lt 20) { throw 'No sleep/resume-sized observation gap was detected.' }
        $details = [ordered]@{ largest_observation_gap_seconds = [math]::Round($largestGap, 3); resumed_ready = $true }
        $submission = Invoke-Cli @('test-print')
    }
    'NoPaper' {
        Write-Host "ACTION REQUIRED: remove/empty the paper tray within $ActionDelaySeconds seconds. A long PDF will be submitted; observe the UI/printer, then refill paper."
        Start-Sleep -Seconds $ActionDelaySeconds
        $soak = Join-Path $PSScriptRoot 'Invoke-M9ApplicationSoak.ps1'
        $spoolOutput = @(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $soak `
            -Action LongPdf -DocumentDirectory $DocumentDirectory -PdfToolPath $PdfToolPath -SkipCupsCompletionWait 2>&1 | ForEach-Object { $_.ToString() })
        if ($LASTEXITCODE -ne 0) { throw 'Long PDF submission failed during the no-paper scenario.' }
        $monitorUntil = [DateTime]::UtcNow.AddSeconds([math]::Min(90, $TimeoutSeconds / 2))
        do { $null = Observe 'no-paper-observation'; Start-Sleep -Seconds 2 } while ([DateTime]::UtcNow -lt $monitorUntil)
        Write-Host 'Refill the paper tray now. Waiting for the bridge to be ready.'
        $null = Wait-Condition { param($s) $s.value.overall -eq 'ready' } 'paper-refilled'
        $nonReady = @($timeline | Where-Object { $_.label -eq 'no-paper-observation' -and $_.overall -ne 'ready' }).Count -gt 0
        $details = [ordered]@{
            software_reported_non_ready = $nonReady
            limitation = if ($nonReady) { 'The software reported a non-ready state.' } else { 'No-paper was not observable through current IPP telemetry; owner/printer observation is required.' }
            application_soak_result = ($spoolOutput -join "`n")
        }
        $submission = Invoke-Cli @('test-print')
    }
}
$final = Observe 'final'
if ($final.value.overall -ne 'ready') { throw "Manual scenario did not finish ready: $($final.value.overall)" }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$path = Join-Path $OutputDirectory "$stamp-$($Scenario.ToLowerInvariant()).json"
[ordered]@{
    schema = 'quirewire.m9.manual-scenario.v1'
    scenario = $Scenario
    started_utc = $started.ToString('o')
    completed_utc = [DateTime]::UtcNow.ToString('o')
    details = $details
    timeline = $timeline
    test_print = if ($submission) { [ordered]@{ output = $submission; physical_output = 'requires_owner_confirmation' } } else { $null }
    physical_output = 'requires_owner_confirmation'
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
[pscustomobject]@{ schema = 'quirewire.m9.manual-result.v1'; path = $path; scenario = $Scenario; physical_output = 'requires_owner_confirmation' } | ConvertTo-Json
