[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$desktopRoot = Join-Path $repositoryRoot 'apps\desktop'
$passed = 0
$failed = 0

function Check([string]$Name, [scriptblock]$Test) {
    try {
        if (& $Test) { $script:passed++; Write-Host "PASS $Name" }
        else { $script:failed++; Write-Host "FAIL $Name" }
    }
    catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}

function Parse-Script([string]$RelativePath) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repositoryRoot $RelativePath), [ref]$tokens, [ref]$errors) | Out-Null
    $errors.Count -eq 0
}

$required = @(
    'apps\desktop\package.json',
    'apps\desktop\package-lock.json',
    'apps\desktop\src\App.tsx',
    'apps\desktop\src\client.ts',
    'apps\desktop\src\fakeClient.ts',
    'apps\desktop\src\styles.css',
    'apps\desktop\src-tauri\Cargo.toml',
    'apps\desktop\src-tauri\src\client.rs',
    'apps\desktop\src-tauri\src\lib.rs',
    'apps\desktop\src-tauri\tauri.conf.json',
    'apps\desktop\src-tauri\capabilities\main-window.json',
    'scripts\m7\README.md',
    'scripts\m7\windows\Record-M7Acceptance.ps1'
)
foreach ($path in $required) {
    Check "required $path" { Test-Path -LiteralPath (Join-Path $repositoryRoot $path) -PathType Leaf }
}
Check 'PowerShell syntax acceptance recorder' {
    Parse-Script 'scripts\m7\windows\Record-M7Acceptance.ps1'
}

$desktopManifest = Get-Content -Raw (Join-Path $desktopRoot 'src-tauri\Cargo.toml')
$tauriBackend = Get-Content -Raw (Join-Path $desktopRoot 'src-tauri\src\lib.rs')
$frontendClient = Get-Content -Raw (Join-Path $desktopRoot 'src\client.ts')
$frontend = (Get-ChildItem (Join-Path $desktopRoot 'src') -File -Recurse | ForEach-Object {
    Get-Content -Raw -LiteralPath $_.FullName
}) -join "`n"
$config = Get-Content -Raw (Join-Path $desktopRoot 'src-tauri\tauri.conf.json') | ConvertFrom-Json
$capability = Get-Content -Raw (Join-Path $desktopRoot 'src-tauri\capabilities\main-window.json') |
    ConvertFrom-Json

Check 'desktop links only the shared IPC crate' {
    $desktopManifest -match 'printbridge-ipc' -and
        $desktopManifest -notmatch 'printbridge-(agent|core|provider)'
}
Check 'frontend imports no provider or operating-system control code' {
    $frontend -notmatch 'VBoxManage|provider-virtualbox|provider-cups|provider-windows|Add-Printer|PowerShell|ssh '
}
foreach ($command in @(
    'agent_get_status', 'agent_discover_devices', 'agent_begin_setup', 'agent_start',
    'agent_stop', 'agent_restart', 'agent_test_print', 'agent_get_diagnostics',
    'agent_repair', 'export_diagnostics', 'exit_printbridge'
)) {
    Check "fixed desktop command $command" {
        $frontendClient -match [regex]::Escape($command) -and
            $tauriBackend -match [regex]::Escape($command)
    }
}
Check 'webview stores no credentials or downloads' {
    $frontend -notmatch 'localStorage|sessionStorage|indexedDB'
}
Check 'close hides UI without stopping engine' {
    $tauriBackend -match 'CloseRequested' -and
        $tauriBackend -match 'prevent_close' -and
        $tauriBackend -match 'window\.hide'
}
Check 'explicit Exit requests graceful agent shutdown before app exit' {
    $tauriBackend -match '(?s)fn exit_printbridge\(.+?Command::Shutdown.+?app\.exit\(0\)'
}
foreach ($label in @('Open PrintBridge', 'Test page', 'Restart bridge', 'View diagnostics', 'Exit PrintBridge (stop sharing)')) {
    Check "tray item $label" { $tauriBackend -match [regex]::Escape($label) }
}
Check 'tray Exit explains sharing shutdown' { $tauriBackend -match 'Exit PrintBridge \(stop sharing\)' }
Check 'explicit non-null content security policy' {
    -not [string]::IsNullOrWhiteSpace($config.app.security.csp) -and
        $config.app.security.csp -match "default-src 'self'"
}
Check 'main window has explicit minimal capability' {
    $config.app.security.capabilities -contains 'main-window' -and
        $capability.windows -contains 'main'
}
Check 'frontend includes reduced-motion support' {
    (Get-Content -Raw (Join-Path $desktopRoot 'src\styles.css')) -match 'prefers-reduced-motion'
}
Check 'frontend has fake and real client implementations' {
    $frontend -match 'FakePrintBridgeClient' -and $frontend -match 'TauriPrintBridgeClient'
}

$negativeAcceptance = Join-Path $repositoryRoot "artifacts\m7\software-tests\acceptance-negative-$([guid]::NewGuid().ToString('N'))"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
    (Join-Path $repositoryRoot 'scripts\m7\windows\Record-M7Acceptance.ps1') `
    -DashboardReady no -SetupFlowWorked no -UiPagePrinted no -TrayPagePrinted no `
    -DiagnosticsExported no -RepairReturnedReady no -CloseKeptAgentRunning no `
    -ExitKeptAgentRunning no -PrintCompletedAfterUiExit no -OutputDirectory $negativeAcceptance *> $null
$negativeExit = $LASTEXITCODE
$negativeRecord = Get-ChildItem -LiteralPath $negativeAcceptance -Filter '*-m7-acceptance.json' |
    Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
Check 'acceptance recorder rejects an unconfirmed UI/physical matrix' { $negativeExit -eq 1 }
Check 'acceptance recorder cannot synthesize a physical pass' { $negativeRecord.result -eq 'FAIL' }

$npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
if ($null -eq $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
if ($null -eq $npm) {
    $wingetRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    $candidate = Get-ChildItem -LiteralPath $wingetRoot -Filter npm.cmd -File -Recurse `
        -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match 'OpenJS\.NodeJS\.LTS_' } |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($candidate) { $npm = $candidate }
}
Check 'Node npm toolchain available' { $null -ne $npm }
if ($null -ne $npm) {
    Push-Location $desktopRoot
    try {
        & $npm.Source test -- --reporter=dot
        Check 'frontend unit and functional flows' { $LASTEXITCODE -eq 0 }
        & $npm.Source run build
        Check 'frontend type-check and production build' { $LASTEXITCODE -eq 0 }
    }
    finally { Pop-Location }
}

Push-Location $repositoryRoot
try {
    & cargo.exe test -p printbridge-desktop --all-features --offline
    Check 'desktop Rust tests' { $LASTEXITCODE -eq 0 }
}
finally { Pop-Location }

Write-Host "M7 software checks: $passed passed, $failed failed."
if ($failed -ne 0) { exit 1 }
