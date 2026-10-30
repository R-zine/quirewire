[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$passed = 0
$failed = 0
function Check([string]$Name, [scriptblock]$Test) {
    try {
        $value = & $Test
        if (-not $value) { throw 'condition returned false' }
        $script:passed++
        Write-Host "PASS $Name"
    }
    catch {
        $script:failed++
        Write-Host "FAIL $Name - $($_.Exception.Message)"
    }
}

$scriptFiles = @(
    'scripts\m9\windows\New-M9TestDocuments.ps1',
    'scripts\m9\windows\Invoke-M9ApplicationSoak.ps1',
    'scripts\m9\windows\Collect-M9Metrics.ps1',
    'scripts\m9\windows\Invoke-M9RecoveryScenario.ps1',
    'scripts\m9\windows\Watch-M9ManualScenario.ps1',
    'scripts\m9\windows\Invoke-M9HostReboot.ps1',
    'scripts\m9\windows\Record-M9Scenario.ps1',
    'scripts\m9\windows\Record-M9Acceptance.ps1'
)
foreach ($relative in $scriptFiles) {
    Check "PowerShell syntax: $relative" {
        $tokens = $null; $errors = $null
        [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $relative), [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count -eq 0
    }
}

$requiredDocs = @(
    'scripts\m9\README.md', 'docs\usage.md', 'docs\troubleshooting.md',
    'docs\development.md', 'docs\security.md', 'docs\known-limitations.md',
    'docs\release-checklist.md', 'docs\m9-acceptance.md'
)
foreach ($relative in $requiredDocs) {
    Check "Required documentation: $relative" { Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf }
}

$soak = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\m9\windows\Invoke-M9ApplicationSoak.ps1')
$metrics = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\m9\windows\Collect-M9Metrics.ps1')
$recovery = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\m9\windows\Invoke-M9RecoveryScenario.ps1')
$manual = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\m9\windows\Watch-M9ManualScenario.ps1')
$recorder = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\m9\windows\Record-M9Acceptance.ps1')
$security = Get-Content -Raw -LiteralPath (Join-Path $root 'docs\security.md')
$limitations = Get-Content -Raw -LiteralPath (Join-Path $root 'docs\known-limitations.md')
$release = Get-Content -Raw -LiteralPath (Join-Path $root 'docs\release-checklist.md')

Check 'application soak is bound to exact marker-owned Microsoft IPP queue' {
    $soak -match 'printbridge\.m5\.owned-printer\.v1' -and
        $soak -match 'Microsoft IPP Class Driver' -and $soak -match 'ownedComment' -and
        $soak -match "'/pt'" -and $soak -match "'-print-to'" -and
        $soak -match 'Get-AuthenticodeSignature' -and $soak -match 'lpstat -W' -and
        $soak -notmatch 'SetDefaultPrinter|Set-Printer\s+.*-IsDefault'
}
Check 'application soak preserves printer inventory and does not infer paper' {
    $soak -match 'unrelated_printers_preserved' -and $soak -match 'default_printer_preserved' -and
        $soak -match "physical_output = 'not_inferred'" -and
        $soak -notmatch 'Remove-Printer|Remove-PrinterDriver|Remove-PrinterPort'
}
Check 'metrics are redacted and compare explicit resource targets' {
    $metrics -match '50MB' -and $metrics -match '768' -and $metrics -match 'average_cpu_percent_one_core' -and
        $metrics -match 'USB serial, process command lines, environment, window titles, and file contents are omitted' -and
        $metrics -notmatch '(?i)usb_serial|SerialNumber'
}
Check 'recovery mutations require exact VM ownership and preserve inventories' {
    $recovery -match "Get-ExtraData 'PrintBridge/Schema'" -and
        $recovery -match "Get-ExtraData 'PrintBridge/Owner'" -and
        $recovery.Contains("'controlvm', `$vmUuid, 'poweroff'") -and
        $recovery -notmatch "'unregistervm'|'--delete'|Remove-Printer"
}
Check 'low-disk test never fills or deletes disk data' {
    $recovery -match 'actual_disk_not_filled = \$true' -and $recovery -match 'no_job_submitted = \$true' -and
        $recovery -notmatch '(?i)fsutil|diskpart|format\.com|Remove-Item\s+[^\r\n]*-Recurse'
}
Check 'manual scenarios identify physical output as owner-only' {
    $manual -match "physical_output = 'requires_owner_confirmation'" -and
        $manual -match 'No-paper was not observable' -and
        $manual -match "recovery_measurement_origin = 'observed USB loss'" -and
        $manual -notmatch 'physical_output\s*=\s*''printed'''
}
Check 'acceptance requires bounded core scenarios and resource bounds' {
    @('sequential-text-pdf','long-pdf','usb-idle','vm-crash','spooler-restart',
      'cups-restart','port-conflict','second-instance','low-disk','cold-start') |
        ForEach-Object { if ($recorder -notmatch [regex]::Escape($_)) { throw "missing scenario $_" } }
    @('standard-app-text-pdf','usb-during-print','host-reboot','sleep-resume','no-paper',
      'uninstall-reinstall','ui-closed') |
        ForEach-Object { if ($recorder -notmatch [regex]::Escape($_)) { throw "missing deferred scenario $_" } }
    $recorder -match 'PASS: PHYSICAL' -and $recorder -match 'BLOCKED: REQUIRES HARDWARE' -and
        $recorder -match 'deferred_non_gating' -and $recorder -match 'waiting-for-usb' -and
        $recorder -match 'usb-recovered' -and $recorder -match '32MB' -and $recorder -match '128MB'
}
Check 'security and limitations disclose unsigned and non-observable boundaries' {
    $security -match 'unsigned development artifact' -and $security -match 'USB serial' -and
        $limitations -match 'Physical output' -and $limitations -match 'Actual disk exhaustion is not induced'
}
Check 'release checklist keeps public release blocked on signing and bounded physical matrix' {
    $release -match 'Authenticode' -and $release -match 'All 10 required M9 scenarios' -and
        $release -match 'Deferred stress checks' -and
        $release -match 'Do not publish while any required item is unchecked'
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('printbridge-m9-tests-' + [Guid]::NewGuid().ToString('N'))
try {
    $documents = Join-Path $fixture 'documents'
    $result = @(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File (Join-Path $root 'scripts\m9\windows\New-M9TestDocuments.ps1') -OutputDirectory $documents 2>&1 | ForEach-Object { $_.ToString() })
    Check 'document generator succeeds' { $LASTEXITCODE -eq 0 }
    $manifestPath = Join-Path $documents 'manifest.json'
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    Check 'document set has 10 text and 10 PDF sequential jobs' {
        $manifest.schema -eq 'printbridge.m9.test-documents.v1' -and @($manifest.jobs).Count -eq 20 -and
            @($manifest.jobs | Where-Object format -eq 'text/plain').Count -eq 10 -and
            @($manifest.jobs | Where-Object format -eq 'application/pdf').Count -eq 10
    }
    Check 'long PDF has 20 pages and valid PDF/xref structure' {
        $longPath = Join-Path $documents $manifest.long_pdf.name
        $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($longPath))
        $manifest.long_pdf.pages -eq 20 -and $text.StartsWith('%PDF-1.4') -and
            ([regex]::Matches($text, '/Type /Page\b').Count -eq 20) -and $text -match 'xref' -and $text -match '%%EOF'
    }
    Check 'generator refuses unrelated collision' {
        $collision = Join-Path $fixture 'collision'; New-Item -ItemType Directory -Path $collision | Out-Null
        Set-Content -LiteralPath (Join-Path $collision 'm9-job-01.txt') -Value 'unowned'
        $exit = 0
        try {
            & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                -File (Join-Path $root 'scripts\m9\windows\New-M9TestDocuments.ps1') -OutputDirectory $collision 2>&1 | Out-Null
            $exit = $LASTEXITCODE
        }
        catch { $exit = 1 }
        $exit -ne 0 -and (Get-Content -LiteralPath (Join-Path $collision 'm9-job-01.txt') -Raw).Trim() -eq 'unowned'
    }

    $evidence = Join-Path $fixture 'evidence.json'
    @{ schema = 'printbridge.m9.test-evidence.v1' } | ConvertTo-Json | Set-Content -LiteralPath $evidence
    $scenarios = Join-Path $fixture 'scenarios'
    $recordOutput = @(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File (Join-Path $root 'scripts\m9\windows\Record-M9Scenario.ps1') `
        -Scenario second-instance -Result PASS -OwnerConfirmedPhysical not-applicable `
        -EvidencePath $evidence -Notes 'fixture' -OutputDirectory $scenarios 2>&1 | ForEach-Object { $_.ToString() })
    Check 'software-only scenario recorder succeeds with not-applicable physical field' { $LASTEXITCODE -eq 0 }
    Check 'physical scenario cannot pass without owner confirmation' {
        $exit = 0
        try {
            & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                -File (Join-Path $root 'scripts\m9\windows\Record-M9Scenario.ps1') `
                -Scenario long-pdf -Result PASS -OwnerConfirmedPhysical not-applicable `
                -EvidencePath $evidence -Notes 'fixture' -OutputDirectory $scenarios 2>&1 | Out-Null
            $exit = $LASTEXITCODE
        }
        catch { $exit = 1 }
        $exit -ne 0
    }

    $baseline = Join-Path $fixture 'baseline.json'; $final = Join-Path $fixture 'final.json'
    $metricBase = @{ schema='printbridge.m9.metrics.v1'; phase='Baseline'; status_before=@{overall='ready'}; status_after=@{overall='ready'}; agent=@{pids=@(1)}; comparisons=@{agent_working_set='PASS';agent_average_cpu='PASS';guest_memory='PASS'}; storage=@{data_root_bytes_before=1;data_root_bytes_after=1;vm_directory_bytes_before=1;vm_directory_bytes_after=1} }
    $metricFinal = $metricBase.Clone(); $metricFinal.phase='Final'
    $metricBase | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $baseline
    $metricFinal | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $final
    $acceptanceDirectory = Join-Path $fixture 'acceptance'
    $acceptOutput = @(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File (Join-Path $root 'scripts\m9\windows\Record-M9Acceptance.ps1') `
        -MetricsBaselinePath $baseline -MetricsFinalPath $final -DocumentManifestPath $manifestPath `
        -ScenarioDirectory $scenarios -OutputDirectory $acceptanceDirectory 2>&1 | ForEach-Object { $_.ToString() })
    $acceptRecord = Get-ChildItem -LiteralPath $acceptanceDirectory -Filter '*-m9-acceptance.json' | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
    Check 'incomplete matrix remains blocked hardware and exits nonzero' {
        $LASTEXITCODE -ne 0 -and $acceptRecord.result -eq 'BLOCKED: REQUIRES HARDWARE' -and @($acceptRecord.missing_scenarios).Count -gt 0
    }
}
finally {
    if (Test-Path -LiteralPath $fixture) {
        $resolved = (Resolve-Path -LiteralPath $fixture).Path
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to remove a fixture outside the temp directory.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

Write-Host "M9 software tests: $passed passed, $failed failed"
if ($failed -ne 0) { exit 1 }
