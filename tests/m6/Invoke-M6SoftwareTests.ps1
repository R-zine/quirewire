[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
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
    'crates\agent\src\main.rs',
    'crates\agent\src\m6.rs',
    'crates\ipc\src\wire.rs',
    'crates\ipc\src\windows_pipe.rs',
    'scripts\m6\README.md',
    'scripts\m6\windows\New-M6Configuration.ps1',
    'scripts\m6\windows\Invoke-M6Startup.ps1',
    'scripts\m6\windows\Collect-M6Diagnostics.ps1',
    'scripts\m6\windows\Invoke-M6DelayedPrint.ps1',
    'scripts\m6\windows\Invoke-M6SpoolerInterruption.ps1',
    'scripts\m6\windows\Record-M6Acceptance.ps1'
)
foreach ($path in $required) {
    Check "required $path" { Test-Path -LiteralPath (Join-Path $repositoryRoot $path) -PathType Leaf }
}

foreach ($script in $required | Where-Object { $_ -like '*.ps1' }) {
    Check "PowerShell syntax $script" { Parse-Script $script }
}

$wire = Get-Content -Raw (Join-Path $repositoryRoot 'crates\ipc\src\wire.rs')
$pipe = Get-Content -Raw (Join-Path $repositoryRoot 'crates\ipc\src\windows_pipe.rs')
$agent = Get-Content -Raw (Join-Path $repositoryRoot 'crates\agent\src\m6.rs')
$startup = Get-Content -Raw (Join-Path $repositoryRoot 'scripts\m6\windows\Invoke-M6Startup.ps1')
$config = Get-Content -Raw (Join-Path $repositoryRoot 'scripts\m6\windows\New-M6Configuration.ps1')
$diagnostics = Get-Content -Raw (Join-Path $repositoryRoot 'scripts\m6\windows\Collect-M6Diagnostics.ps1')

foreach ($command in @('GetStatus', 'DiscoverDevices', 'BeginSetup', 'Start', 'Stop', 'Restart', 'TestPrint', 'GetDiagnostics', 'Repair')) {
    Check "typed command $command" { $wire -match "\b$command\b" }
}
Check 'no arbitrary IPC exec variant' { $wire -notmatch '(?m)^\s*(Exec|Execute|Shell)\s*[{,(]' }
Check '64 KiB IPC frame bound' { $wire -match '64 \* 1024' }
Check 'protected owner-only pipe DACL' { $pipe -match 'D:P\(A;;GA;;;' }
Check 'first-pipe-instance singleton' { $pipe -match 'first_pipe_instance\(first\)' }
Check 'remote pipe clients rejected' { $pipe -match 'reject_remote_clients\(true\)' }
Check 'immutable state generations' { $agent -match 'create_new\(true\)' -and $agent -match 'state-\{:020\}\.json' }
Check 'bounded 30-second backoff' { $agent -match 'MAX_BACKOFF.*30' }
Check 'request ID idempotency cache' { $agent -match 'MAX_REQUEST_CACHE' -and $agent -match 'completed\.get' }
Check 'accepted M4 schema required' { $agent -match 'quirewire\.m4\.acceptance-vm\.v1' }
Check 'interactive limited startup principal' {
    $startup -match 'LogonType Interactive' -and $startup -match 'RunLevel Limited'
}
Check 'Task Scheduler ignores duplicates' { $startup -match 'MultipleInstances IgnoreNew' }
Check 'Task Scheduler has bounded process restarts' {
    $startup -match 'RestartCount 3' -and $startup -match 'RestartInterval.*Minutes 1'
}
Check 'Task Scheduler has singleton-safe watchdog trigger' {
    $startup -match 'New-ScheduledTaskTrigger -Once' -and
        $startup -match 'RepetitionInterval.*Minutes 1' -and
        $startup -match 'MultipleInstances IgnoreNew'
}
Check 'task collision is refused' { $startup -match 'colliding Task Scheduler entry' }
Check 'configuration requires physical M4 evidence' {
    $config -match 'PASS: PHYSICAL' -and $config -match 'physical_token'
}
Check 'configuration directory ACL is protected' {
    $config -match '/inheritance:r' -and $config -match 'S-1-5-18'
}
Check 'diagnostics explicitly redact USB serial' {
    $diagnostics -match 'USB serial values.*intentionally omitted'
}
Check 'headless crates have no Tauri dependency' {
    -not (Select-String -Path (Join-Path $repositoryRoot 'crates\*\Cargo.toml') -Pattern 'tauri' -Quiet)
}

$negativeAcceptance = Join-Path $repositoryRoot "artifacts\m6\software-tests\acceptance-negative-$([guid]::NewGuid().ToString('N'))"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
    (Join-Path $repositoryRoot 'scripts\m6\windows\Record-M6Acceptance.ps1') `
    -UiNeverLaunched no -LockedSessionPrinted no -LogonRecoveryPrinted no `
    -CupsRecoveryPrinted no -SpoolerRecoveryPrinted no -UsbReconnectPrinted no `
    -PhysicalPagePrinted no -OutputDirectory $negativeAcceptance *> $null
$negativeExit = $LASTEXITCODE
$negativeRecord = Get-ChildItem -LiteralPath $negativeAcceptance -Filter '*-m6-acceptance.json' |
    Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
Check 'acceptance recorder fails an unconfirmed hardware matrix' { $negativeExit -eq 1 }
Check 'acceptance recorder cannot synthesize a physical pass' { $negativeRecord.result -eq 'FAIL' }

Push-Location $repositoryRoot
try {
    & cargo.exe test -p quirewire-ipc -p quirewire-agent -p quirewirectl --all-features --offline
    Check 'focused Rust test suites' { $LASTEXITCODE -eq 0 }
}
finally { Pop-Location }

Write-Host "M6 software checks: $passed passed, $failed failed."
if ($failed -ne 0) { exit 1 }
