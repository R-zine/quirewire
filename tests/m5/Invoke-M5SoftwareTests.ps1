[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$provider = Join-Path $repo 'scripts\m5\windows\Invoke-M5WindowsPrinting.ps1'
$collector = Join-Path $repo 'scripts\m5\windows\Collect-M5Diagnostics.ps1'
$recorder = Join-Path $repo 'scripts\m5\windows\Record-M5Acceptance.ps1'
$generator = Join-Path $repo 'scripts\m5\windows\New-M5TestDocuments.ps1'
$config = Join-Path $repo 'scripts\m5\m5.conf'
$artifacts = Join-Path $repo 'artifacts\m5\software-tests'
$null = New-Item -ItemType Directory -Force -Path $artifacts
$checks = [Collections.Generic.List[string]]::new()

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw "M5 software test failed: $Message" }
    $checks.Add($Message)
}

foreach ($path in @($provider, $collector, $recorder, $generator)) {
    $tokens = $null
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "PowerShell syntax: $([IO.Path]::GetFileName($path))"
}

$source = Get-Content -LiteralPath $provider -Raw
Assert-True ($source.Contains("'Microsoft IPP Class Driver'")) 'exact Microsoft inbox driver is enforced'
Assert-True ($source.Contains('Add-Printer -Name $PrinterName -IppURL')) 'registration uses Add-Printer -IppURL'
Assert-True (-not $source.Contains('Remove-PrinterDriver')) 'provider never removes printer drivers'
Assert-True (-not $source.Contains('Remove-PrinterPort')) 'provider never removes printer ports'
Assert-True ($source.Contains('Remove-Printer -Name $PrinterName')) 'removal is limited to the exact configured name'
Assert-True ($source.Contains('Test-OwnedQueue')) 'live queue mutation requires ownership verification'
Assert-True ($source.Contains('Test-IsDefault')) 'owned default queue removal is refused'
Assert-True ($source.Contains('Use the documented Settings IPP Device fallback')) 'manual IPP fallback is actionable'
Assert-True ($source.Contains('$code = ''permission_denied''')) 'Windows access denial is typed and actionable'
Assert-True ($source.Contains("Host -notin @('127.0.0.1', 'localhost', '::1')")) 'endpoint is restricted to loopback'

$before = @(Get-Printer | Sort-Object Name | ForEach-Object { "$($_.Name)|$($_.DriverName)|$($_.PortName)|$($_.Comment)" })
$defaultBefore = @(Get-CimInstance Win32_Printer | Where-Object Default | ForEach-Object Name)
$state = Join-Path $artifacts 'read-only-state.json'
$detect = @(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $provider -Action Detect -PrinterName 'Brother via PrintBridge' `
    -IppUrl 'http://127.0.0.1:8644/printers/PrintBridge_DCP_L2600D' -StatePath $state)
Assert-True ($LASTEXITCODE -eq 0) 'real PrintManagement detection succeeds'
Assert-True ($detect[0] -eq 'PRINTBRIDGE_WINDOWS_V1') 'provider emits the versioned protocol header'
Assert-True ($detect -contains 'ipp_url_supported=true') 'installed Add-Printer exposes IppURL'

$invalid = @(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $provider -Action Status -PrinterName 'Brother via PrintBridge' `
    -IppUrl 'http://192.0.2.10:631/printers/unsafe' -StatePath $state)
Assert-True ($LASTEXITCODE -ne 0) 'non-loopback endpoint is rejected'
Assert-True ($invalid -contains 'error_code=invalid_argument') 'unsafe endpoint returns a typed error'

$absentName = 'Brother via PrintBridge SoftwareTest_' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff')
$absentState = Join-Path $artifacts 'absent-owner.json'
$remove = @(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $provider -Action Remove -PrinterName $absentName `
    -IppUrl 'http://127.0.0.1:65534/printers/AbsentQueue' -StatePath $absentState)
Assert-True ($LASTEXITCODE -eq 0) 'removing an already absent owned target is idempotent'
Assert-True ($remove -contains 'queue_found=false') 'absent removal reports no queue'

Push-Location $repo
try {
    $help = @(cargo run -q -p printbridgectl -- help)
    Assert-True ($LASTEXITCODE -eq 0) 'CLI help runs'
    Assert-True (($help -join "`n").Contains('printer test-page')) 'CLI documents all M5 printer commands'
    $status = @(cargo run -q -p printbridgectl -- --config $config printer status)
    Assert-True ($LASTEXITCODE -eq 0) 'CLI read-only printer status runs'
    Assert-True (($status -join "`n").Contains('physical_output: not_inferred')) 'CLI does not infer physical output'
}
finally { Pop-Location }

$after = @(Get-Printer | Sort-Object Name | ForEach-Object { "$($_.Name)|$($_.DriverName)|$($_.PortName)|$($_.Comment)" })
$defaultAfter = @(Get-CimInstance Win32_Printer | Where-Object Default | ForEach-Object Name)
Assert-True (($before -join "`n") -eq ($after -join "`n")) 'software tests preserve every existing printer queue'
Assert-True (($defaultBefore -join "`n") -eq ($defaultAfter -join "`n")) 'software tests preserve the default printer'

$documents = Join-Path $artifacts 'documents'
& $generator -OutputDirectory $documents | Out-Null
$text = Get-Content -LiteralPath (Join-Path $documents 'm5-standard-app-text.txt') -Raw
$pdfBytes = [IO.File]::ReadAllBytes((Join-Path $documents 'm5-standard-app-pdf.pdf'))
$pdfText = [Text.Encoding]::ASCII.GetString($pdfBytes)
Assert-True ($text.Contains('PRINTBRIDGE-M5-TEXT-2026')) 'text fixture contains its physical token'
Assert-True ($pdfText.StartsWith('%PDF-1.4')) 'PDF fixture has a valid PDF header'
Assert-True ($pdfText.Contains('PRINTBRIDGE-M5-PDF-IMAGE-2026')) 'PDF fixture contains its physical token'

$acceptance = Join-Path $artifacts 'acceptance-negative'
& $recorder -InstallIdempotent 'NOT TESTED' -DriverVerified 'NOT TESTED' `
    -CliTestPagePhysical 'NOT TESTED' -WindowsTextPhysical 'NOT TESTED' `
    -WindowsPdfPhysical 'NOT TESTED' -RestartPersistence 'NOT TESTED' `
    -IndependentRemoval 'NOT TESTED' -DefaultPrinterPreserved 'NOT TESTED' `
    -UnrelatedPrintersPreserved 'NOT TESTED' -FinalReinstall 'NOT TESTED' `
    -Evidence 'software-only negative gate' -Notes 'must remain blocked' `
    -OutputDirectory $acceptance | Out-Null
$record = Get-ChildItem -LiteralPath $acceptance -Filter '*-m5-acceptance.json' |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1 |
    Get-Content -Raw | ConvertFrom-Json
Assert-True ($record.result -eq 'BLOCKED: REQUIRES HARDWARE') 'recorder cannot turn software checks into a physical pass'

Write-Host "M5 software checks passed: $($checks.Count)"
foreach ($check in $checks) { Write-Host "[PASS] $check" }
