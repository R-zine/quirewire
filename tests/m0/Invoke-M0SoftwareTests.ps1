[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$testOutput = Join-Path $RepositoryRoot "artifacts\m0\software-tests\$stamp"
New-Item -ItemType Directory -Force -Path $testOutput | Out-Null
$results = [System.Collections.Generic.List[object]]::new()

function Add-TestResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [string]$Detail
    )

    [void]$results.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Detail = $Detail })
    $label = if ($Passed) { 'PASS' } else { 'FAIL' }
    Write-Host "[$label] $Name - $Detail"
}

function Assert-Test {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Detail
    )

    Add-TestResult -Name $Name -Passed $Condition -Detail $Detail
    if (-not $Condition) { throw "Test failed: $Name - $Detail" }
}

function Test-PdfXref {
    param([Parameter(Mandatory = $true)][string]$Path)

    $content = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($Path))
    $match = [regex]::Match($content, 'startxref\n(?<offset>[0-9]+)\n%%EOF')
    if (-not $match.Success) { return $false }
    $xrefOffset = [int]$match.Groups['offset'].Value
    if ($xrefOffset -ge $content.Length -or $content.Substring($xrefOffset, 4) -ne 'xref') { return $false }

    $objectMatches = [regex]::Matches($content, '(?m)^(?<number>[1-9][0-9]*) 0 obj$')
    foreach ($objectMatch in $objectMatches) {
        $number = [int]$objectMatch.Groups['number'].Value
        $entryPattern = '(?m)^' + [regex]::Escape($objectMatch.Index.ToString('D10')) + ' 00000 n $'
        if (-not [regex]::IsMatch($content, $entryPattern)) {
            Write-Host "Missing xref entry for object $number at offset $($objectMatch.Index)."
            return $false
        }
    }
    return $objectMatches.Count -gt 0
}

Push-Location $RepositoryRoot
try {
    $powerShellScripts = @(Get-ChildItem -LiteralPath 'scripts\feasibility\windows' -Filter '*.ps1')
    foreach ($script in $powerShellScripts) {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
        Assert-Test -Condition ($parseErrors.Count -eq 0) -Name "PowerShell syntax: $($script.Name)" -Detail "$($parseErrors.Count) parser error(s)"
    }

    $bash = 'C:\Program Files\Git\bin\bash.exe'
    Assert-Test -Condition (Test-Path -LiteralPath $bash) -Name 'Bash test runtime' -Detail $bash
    $shellScripts = @(Get-ChildItem -LiteralPath 'scripts\feasibility\linux' -Filter '*.sh')
    foreach ($script in $shellScripts) {
        & $bash -n $script.FullName
        Assert-Test -Condition ($LASTEXITCODE -eq 0) -Name "Bash syntax: $($script.Name)" -Detail "bash -n exit $LASTEXITCODE"
        & $bash $script.FullName --help | Out-Null
        Assert-Test -Condition ($LASTEXITCODE -eq 0) -Name "Help path: $($script.Name)" -Detail "--help exit $LASTEXITCODE"
    }

    $cupsSharingSource = Get-Content -Raw -LiteralPath 'scripts\feasibility\linux\manage-m0-cups-sharing.sh'
    Assert-Test -Condition ($cupsSharingSource -notmatch '(?m)^\s*cupsctl\s+--remote-any(?:\s|$)') -Name 'No remote-any command' -Detail 'CUPS script contains no executable cupsctl --remote-any line'
    Assert-Test -Condition ($cupsSharingSource -notmatch '(?m)^\s*lpadmin\s+-x(?:\s|$)') -Name 'No CUPS queue deletion' -Detail 'CUPS script contains no lpadmin -x line'
    $cupsSharingPreDispatch = $cupsSharingSource.Substring(0, $cupsSharingSource.IndexOf('case "$action" in', [StringComparison]::Ordinal))
    Assert-Test -Condition ($cupsSharingPreDispatch -notmatch '(?m)^\s*mkdir\s') -Name 'CUPS status and plan stay read-only' -Detail 'State-directory creation occurs only inside an applying action'

    $windowsManageSource = Get-Content -Raw -LiteralPath 'scripts\feasibility\windows\Manage-M0IppPrinter.ps1'
    Assert-Test -Condition ($windowsManageSource -notmatch 'Remove-Printer(?:Driver|Port)') -Name 'No Windows driver/port deletion' -Detail 'POC cleanup removes neither printer drivers nor ports'
    Assert-Test -Condition ($windowsManageSource -match 'Set-Printer\s+-Name\s+\$PrinterName\s+-Comment\s+\$OwnedComment') -Name 'IPP ownership comment reapplied' -Detail 'Windows IPP metadata cannot silently replace the cleanup ownership marker'

    $documentsDirectory = Join-Path $testOutput 'documents'
    & '.\scripts\feasibility\windows\New-M0TestDocuments.ps1' -OutputDirectory $documentsDirectory | Out-Null
    $textPath = Join-Path $documentsDirectory 'm0-text-test.txt'
    $pdfPath = Join-Path $documentsDirectory 'm0-pdf-image-test.pdf'
    $duplexPath = Join-Path $documentsDirectory 'm0-duplex-color-test.pdf'
    Assert-Test -Condition (Test-Path -LiteralPath $textPath) -Name 'Text fixture generated' -Detail $textPath
    Assert-Test -Condition ((Get-Content -Raw -LiteralPath $textPath) -match 'PRINTBRIDGE-M0-TEXT-2026') -Name 'Text fixture token' -Detail 'Known physical token is present'

    foreach ($path in @($pdfPath, $duplexPath)) {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
        Assert-Test -Condition ($ascii.StartsWith('%PDF-1.4')) -Name "PDF header: $([IO.Path]::GetFileName($path))" -Detail 'PDF 1.4 header present'
        Assert-Test -Condition ($ascii -match '/Subtype /Image') -Name "PDF image object: $([IO.Path]::GetFileName($path))" -Detail 'Raster image XObject present'
        Assert-Test -Condition (Test-PdfXref -Path $path) -Name "PDF xref: $([IO.Path]::GetFileName($path))" -Detail 'Every indirect object offset is represented in xref'
    }
    $duplexAscii = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($duplexPath))
    Assert-Test -Condition ($duplexAscii -match '/Count 2') -Name 'Duplex fixture page count' -Detail 'Two-page page tree present'

    $collisionDirectory = Join-Path $testOutput 'fixture-collision'
    New-Item -ItemType Directory -Force -Path $collisionDirectory | Out-Null
    $collisionPath = Join-Path $collisionDirectory 'm0-text-test.txt'
    'UNOWNED-SENTINEL' | Set-Content -LiteralPath $collisionPath -Encoding ASCII
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $collisionOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\scripts\feasibility\windows\New-M0TestDocuments.ps1' -OutputDirectory $collisionDirectory 2>&1 | Out-String
    $collisionExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedErrorActionPreference
    Assert-Test -Condition ($collisionExitCode -ne 0) -Name 'Fixture collision refusal' -Detail 'Generator rejected an unowned target filename'
    Assert-Test -Condition ((Get-Content -Raw -LiteralPath $collisionPath).Trim() -eq 'UNOWNED-SENTINEL') -Name 'Unowned file preserved' -Detail 'Collision sentinel was not overwritten'

    $dryRunName = "PrintBridge M0 Dry Run $([guid]::NewGuid().ToString('N'))"
    $dryRunEvidence = Join-Path $testOutput 'manage-dry-run'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\scripts\feasibility\windows\Manage-M0IppPrinter.ps1' `
        -Action Register -PrinterName $dryRunName -IppUrl 'ipp://192.0.2.1:631/printers/example' -EvidenceDirectory $dryRunEvidence | Out-Null
    Assert-Test -Condition ($LASTEXITCODE -eq 0) -Name 'Windows registration dry run' -Detail "exit $LASTEXITCODE"
    Assert-Test -Condition ($null -eq (Get-Printer -Name $dryRunName -ErrorAction SilentlyContinue)) -Name 'Dry run creates no queue' -Detail $dryRunName
    Assert-Test -Condition (-not (Test-Path -LiteralPath (Join-Path $dryRunEvidence 'ownership\ipp-poc-printer.json'))) -Name 'Dry run creates no ownership marker' -Detail 'No system mutation marker was emitted'

    $acceptanceDirectory = Join-Path $testOutput 'acceptance-blocked'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\scripts\feasibility\windows\Record-M0Acceptance.ps1' `
        -LinuxUsbBaseline 'NOT TESTED' -WindowsTextPhysical 'NOT TESTED' -WindowsPdfPhysical 'NOT TESTED' `
        -DriverName '<not observed>' -Notes 'Software test fixture; no physical claim.' -OutputDirectory $acceptanceDirectory | Out-Null
    Assert-Test -Condition ($LASTEXITCODE -eq 0) -Name 'Blocked acceptance recorder' -Detail "exit $LASTEXITCODE"
    $acceptanceJsonPath = (Get-ChildItem -LiteralPath $acceptanceDirectory -Filter '*.json' | Select-Object -First 1).FullName
    $acceptance = Get-Content -Raw -LiteralPath $acceptanceJsonPath | ConvertFrom-Json
    Assert-Test -Condition ($acceptance.result -eq 'BLOCKED: REQUIRES HARDWARE') -Name 'No synthetic physical pass' -Detail $acceptance.result

    $report = [ordered]@{
        schema = 'printbridge.m0.software-tests.v1'
        completedUtc = [DateTime]::UtcNow.ToString('o')
        result = 'PASS: SOFTWARE ONLY'
        physicalAcceptance = 'NOT TESTED'
        tests = $results
    }
    $reportPath = Join-Path $testOutput 'software-test-results.json'
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-Host "Software-only report: $reportPath"
    Write-Host 'Result: PASS: SOFTWARE ONLY (physical acceptance remains NOT TESTED)'
}
catch {
    $failurePath = Join-Path $testOutput 'software-test-failure.txt'
    $_ | Out-String | Set-Content -LiteralPath $failurePath -Encoding UTF8
    Write-Error "M0 software test failed. Evidence: $failurePath"
    exit 1
}
finally {
    Pop-Location
}

