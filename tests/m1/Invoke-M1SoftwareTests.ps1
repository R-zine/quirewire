[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$testOutput = Join-Path $RepositoryRoot "artifacts\m1\software-tests\$stamp"
New-Item -ItemType Directory -Force -Path $testOutput | Out-Null
$results = [System.Collections.Generic.List[object]]::new()

function Assert-Test {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Detail
    )

    $label = if ($Condition) { 'PASS' } else { 'FAIL' }
    [void]$results.Add([pscustomobject]@{ name = $Name; passed = $Condition; detail = $Detail })
    Write-Host "[$label] $Name - $Detail"
    if (-not $Condition) { throw "Test failed: $Name - $Detail" }
}

Push-Location $RepositoryRoot
try {
    $powerShellScripts = @(Get-ChildItem -LiteralPath 'scripts\m1\windows' -Filter '*.ps1')
    Assert-Test -Condition ($powerShellScripts.Count -ge 3) -Name 'M1 PowerShell tools discovered' -Detail "$($powerShellScripts.Count) script(s)"
    foreach ($script in $powerShellScripts) {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
        Assert-Test -Condition ($parseErrors.Count -eq 0) -Name "PowerShell syntax: $($script.Name)" -Detail "$($parseErrors.Count) parser error(s)"
    }

    $bash = 'C:\Program Files\Git\bin\bash.exe'
    Assert-Test -Condition (Test-Path -LiteralPath $bash) -Name 'Bash test runtime' -Detail $bash
    $shellScripts = @(Get-ChildItem -LiteralPath 'scripts\m1\linux' -Filter '*.sh')
    Assert-Test -Condition ($shellScripts.Count -ge 1) -Name 'M1 guest diagnostics discovered' -Detail "$($shellScripts.Count) script(s)"
    foreach ($script in $shellScripts) {
        & $bash -n $script.FullName
        Assert-Test -Condition ($LASTEXITCODE -eq 0) -Name "Bash syntax: $($script.Name)" -Detail "bash -n exit $LASTEXITCODE"
        & $bash $script.FullName --help | Out-Null
        Assert-Test -Condition ($LASTEXITCODE -eq 0) -Name "Help path: $($script.Name)" -Detail "--help exit $LASTEXITCODE"
    }

    $collectorSource = Get-Content -Raw -LiteralPath 'scripts\m1\windows\Collect-M1HostDiagnostics.ps1'
    Assert-Test -Condition ($collectorSource -match '(?s)\[Parameter\(Mandatory = \$true\)\].{0,240}\[string\]\$VmUuid') -Name 'Host collector requires VM UUID' -Detail 'Owned VM cannot be selected by display name alone'
    Assert-Test -Condition ($collectorSource -notmatch '(?i)\b(startvm|controlvm|modifyvm|unregistervm|usbattach|usbdetach)\b') -Name 'Host collector is lifecycle read-only' -Detail 'No VirtualBox mutation verb is present'
    Assert-Test -Condition ($collectorSource -notmatch '(?i)\b(Remove-Printer|Remove-PrinterDriver|Remove-PrinterPort)\b') -Name 'Host collector preserves printers' -Detail 'No Windows print removal command is present'
    Assert-Test -Condition ($collectorSource -notmatch "USBFilterSerialNumber") -Name 'VM USB filter serial excluded from evidence' -Detail 'Collector does not select the serial-valued VM field'
    Assert-Test -Condition ($collectorSource -match "serial = '<redacted by collector>'") -Name 'USB host serial explicitly redacted' -Detail 'Evidence schema marks the omission'
    Assert-Test -Condition ($collectorSource -match 'M1 diagnostics intentionally probe only a loopback endpoint') -Name 'Endpoint probe is loopback-scoped' -Detail 'Collector refuses non-loopback network probes'

    $managerSource = Get-Content -Raw -LiteralPath 'scripts\m1\windows\Manage-M1IppPrinter.ps1'
    Assert-Test -Condition ($managerSource -notmatch 'Remove-Printer(?:Driver|Port)') -Name 'M1 manager preserves Windows drivers and ports' -Detail 'Cleanup can remove only its marker-owned queue'
    Assert-Test -Condition ($managerSource -match 'Set-Printer\s+-Name\s+\$PrinterName\s+-Comment\s+\$OwnedComment') -Name 'M1 ownership comment reapplied' -Detail 'IPP metadata cannot silently replace the cleanup ownership marker'
    Assert-Test -Condition ($managerSource -match 'restricted to a loopback host') -Name 'M1 registration is loopback-only' -Detail 'LAN IPP endpoints are rejected'

    $dryRunName = "QuireWire M1 Dry Run $([guid]::NewGuid().ToString('N'))"
    $dryRunEvidence = Join-Path $testOutput 'manage-dry-run'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\scripts\m1\windows\Manage-M1IppPrinter.ps1' `
        -Action Register -PrinterName $dryRunName `
        -IppUrl 'ipp://127.0.0.1:8632/printers/DCPL2600D' `
        -EvidenceDirectory $dryRunEvidence | Out-Null
    Assert-Test -Condition ($LASTEXITCODE -eq 0) -Name 'M1 registration dry run' -Detail "exit $LASTEXITCODE"
    Assert-Test -Condition ($null -eq (Get-Printer -Name $dryRunName -ErrorAction SilentlyContinue)) -Name 'M1 dry run creates no queue' -Detail $dryRunName
    Assert-Test -Condition (-not (Test-Path -LiteralPath (Join-Path $dryRunEvidence 'ownership\ipp-m1-printer.json'))) -Name 'M1 dry run creates no ownership marker' -Detail 'No system mutation marker was emitted'

    $guestSource = Get-Content -Raw -LiteralPath 'scripts\m1\linux\collect-m1-guest-diagnostics.sh'
    Assert-Test -Condition ($guestSource -match 'REDACTED') -Name 'Guest URI serial redaction' -Detail 'CUPS device URI serial parameters are filtered'
    Assert-Test -Condition ($guestSource -notmatch '(?m)^\s*(sudo\s+)?(lpadmin|cupsctl\s+--|systemctl\s+(start|stop|restart|enable|disable)|apt|dpkg\s+-i)\b') -Name 'Guest collector is read-only' -Detail 'No provisioning or service mutation commands are present'

    $fixtureExpectations = [ordered]@{
        'm1-windows-text-test.txt' = 'QUIREWIRE-M1-WINDOWS-TEXT-2026'
        'm1-clean-boot-text-test.txt' = 'QUIREWIRE-M1-CLEAN-BOOT-2026'
        'm1-usb-reconnect-text-test.txt' = 'QUIREWIRE-M1-USB-RECONNECT-2026'
        'm1-host-reboot-text-test.txt' = 'QUIREWIRE-M1-HOST-REBOOT-2026'
    }
    foreach ($entry in $fixtureExpectations.GetEnumerator()) {
        $path = Join-Path 'scripts\m1\test-data' $entry.Key
        Assert-Test -Condition (Test-Path -LiteralPath $path) -Name "Fixture exists: $($entry.Key)" -Detail $path
        Assert-Test -Condition ((Get-Content -Raw -LiteralPath $path) -match [regex]::Escape($entry.Value)) -Name "Fixture token: $($entry.Key)" -Detail $entry.Value
    }
    $allFixtureText = ($fixtureExpectations.Keys | ForEach-Object { Get-Content -Raw -LiteralPath (Join-Path 'scripts\m1\test-data' $_) }) -join "`n"
    foreach ($token in $fixtureExpectations.Values) {
        Assert-Test -Condition ([regex]::Matches($allFixtureText, [regex]::Escape($token)).Count -eq 1) -Name "Fixture token unique: $token" -Detail 'Exactly one stage owns the token'
    }

    $acceptanceScript = '.\scripts\m1\windows\Record-M1Acceptance.ps1'
    $blockedDirectory = Join-Path $testOutput 'acceptance-not-tested'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $acceptanceScript `
        -VmUuid '00000000-0000-0000-0000-000000000001' `
        -GuestUsbBaseline 'NOT TESTED' -WindowsTextPhysical 'NOT TESTED' `
        -WindowsPdfPhysical 'NOT TESTED' -CleanGuestBootPhysical 'NOT TESTED' `
        -UsbReconnectPhysical 'NOT TESTED' -HostRebootPhysical 'NOT TESTED' `
        -ExactUsbCapture 'NOT TESTED' -HeadlessOperation 'NOT TESTED' `
        -DriverName '<not observed>' -QueueName '<not observed>' `
        -JobEvidence 'No jobs; software negative-path test.' `
        -Notes 'Synthetic software test; no physical claim.' `
        -OutputDirectory $blockedDirectory | Out-Null
    Assert-Test -Condition ($LASTEXITCODE -eq 0) -Name 'Not-tested acceptance path executes' -Detail "exit $LASTEXITCODE"
    $blockedRecord = Get-Content -Raw -LiteralPath ((Get-ChildItem -LiteralPath $blockedDirectory -Filter '*.json' | Select-Object -First 1).FullName) | ConvertFrom-Json
    Assert-Test -Condition ($blockedRecord.result -eq 'BLOCKED: REQUIRES HARDWARE') -Name 'Not-tested result remains blocked' -Detail $blockedRecord.result

    $unconfirmedDirectory = Join-Path $testOutput 'acceptance-unconfirmed'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $acceptanceScript `
        -VmUuid '00000000-0000-0000-0000-000000000001' `
        -GuestUsbBaseline PASS -WindowsTextPhysical PASS -WindowsPdfPhysical PASS `
        -CleanGuestBootPhysical PASS -UsbReconnectPhysical PASS -HostRebootPhysical PASS `
        -ExactUsbCapture PASS -HeadlessOperation PASS `
        -DriverName 'Microsoft IPP Class Driver' -QueueName 'Synthetic M1 Test' `
        -JobEvidence 'Synthetic identifiers only.' `
        -Notes 'All flags supplied without human confirmation.' `
        -OutputDirectory $unconfirmedDirectory | Out-Null
    $unconfirmedRecord = Get-Content -Raw -LiteralPath ((Get-ChildItem -LiteralPath $unconfirmedDirectory -Filter '*.json' | Select-Object -First 1).FullName) | ConvertFrom-Json
    Assert-Test -Condition ($unconfirmedRecord.result -eq 'BLOCKED: REQUIRES HARDWARE') -Name 'Owner confirmation cannot be omitted' -Detail $unconfirmedRecord.result

    Assert-Test -Condition (Test-Path -LiteralPath 'docs\m1-acceptance.md') -Name 'Physical checklist exists' -Detail 'docs/m1-acceptance.md'
    Assert-Test -Condition (Test-Path -LiteralPath 'docs\milestones\M01.md') -Name 'M1 milestone report exists' -Detail 'docs/milestones/M01.md'

    $report = [ordered]@{
        schema = 'quirewire.m1.software-tests.v1'
        completedUtc = [DateTime]::UtcNow.ToString('o')
        result = 'PASS: SOFTWARE ONLY'
        physicalAcceptance = 'NOT INFERRED'
        tests = $results
    }
    $reportPath = Join-Path $testOutput 'software-test-results.json'
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-Host "Software-only report: $reportPath"
    Write-Host 'Result: PASS: SOFTWARE ONLY (physical lifecycle acceptance remains separate)'
}
catch {
    $failurePath = Join-Path $testOutput 'software-test-failure.txt'
    $_ | Out-String | Set-Content -LiteralPath $failurePath -Encoding UTF8
    Write-Error "M1 software test failed. Evidence: $failurePath"
    exit 1
}
finally {
    Pop-Location
}
