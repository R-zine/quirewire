[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'The QuireWire pre-commit gate currently requires Windows because milestone software tests inspect Windows printing APIs.'
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$desktopRoot = Join-Path $repositoryRoot 'apps\desktop'
$startedAt = [DateTimeOffset]::UtcNow

function Resolve-Executable {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [string[]]$Fallbacks = @()
    )

    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
    }
    foreach ($fallback in $Fallbacks) {
        if ($fallback -and (Test-Path -LiteralPath $fallback -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $fallback).Path
        }
    }
    return $null
}

function Resolve-Npm {
    $resolved = Resolve-Executable -Names @('npm.cmd', 'npm')
    if ($resolved) { return $resolved }

    $candidates = [Collections.Generic.List[IO.FileInfo]]::new()
    if ($env:NVM_SYMLINK) {
        $candidate = Join-Path $env:NVM_SYMLINK 'npm.cmd'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $candidates.Add((Get-Item -LiteralPath $candidate))
        }
    }
    if ($env:NVM_HOME -and (Test-Path -LiteralPath $env:NVM_HOME -PathType Container)) {
        Get-ChildItem -LiteralPath $env:NVM_HOME -Directory -Filter 'v*' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $candidate = Join-Path $_.FullName 'npm.cmd'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    $candidates.Add((Get-Item -LiteralPath $candidate))
                }
            }
    }
    $wingetRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $wingetRoot -PathType Container) {
        Get-ChildItem -LiteralPath $wingetRoot -Filter npm.cmd -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'OpenJS\.NodeJS' } |
            ForEach-Object { $candidates.Add($_) }
    }

    $selected = $candidates | Sort-Object -Property @{
        Expression = {
            $node = Join-Path $_.DirectoryName 'node.exe'
            $version = [version]'0.0'
            if (Test-Path -LiteralPath $node -PathType Leaf) {
                $raw = (& $node --version 2>$null).Trim().TrimStart('v')
                [version]::TryParse($raw, [ref]$version) | Out-Null
            }
            $version
        }
        Descending = $true
    }, FullName | Select-Object -First 1
    if ($selected) { return $selected.FullName }
    return $null
}

function Invoke-NativeStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )

    Write-Host "`n==> $Name" -ForegroundColor Cyan
    $stepStartedAt = [DateTimeOffset]::UtcNow
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE."
    }
    $elapsed = [DateTimeOffset]::UtcNow - $stepStartedAt
    Write-Host ("PASS {0} ({1:n1}s)" -f $Name, $elapsed.TotalSeconds) -ForegroundColor Green
}

$cargo = Resolve-Executable -Names @('cargo.exe', 'cargo') -Fallbacks @(
    (Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe')
)
$git = Resolve-Executable -Names @('git.exe', 'git')
$powerShell = Resolve-Executable -Names @('powershell.exe')
$npm = Resolve-Npm

if (-not $cargo) { throw 'Rust/Cargo is required. Install the toolchain from rust-toolchain.toml.' }
if (-not $git) { throw 'Git is required to validate the staged diff.' }
if (-not $powerShell) { throw 'Windows PowerShell 5.1 is required for milestone software tests.' }
if (-not $npm) { throw 'Node.js/npm is required. Install Node.js 24.15+ and run npm ci in apps/desktop.' }
if (-not (Test-Path -LiteralPath (Join-Path $desktopRoot 'node_modules') -PathType Container)) {
    throw 'Frontend dependencies are missing. Run npm ci in apps/desktop before committing.'
}

$npmRoot = Split-Path -Parent $npm
$env:Path = "$npmRoot;$env:Path"
$repositoryForGit = $repositoryRoot.Replace('\', '/')
$gitInstallRoot = Split-Path -Parent (Split-Path -Parent $git)
$gitBash = Join-Path $gitInstallRoot 'bin\bash.exe'
$bash = if (Test-Path -LiteralPath $gitBash -PathType Leaf) {
    (Resolve-Path -LiteralPath $gitBash).Path
}
else {
    Resolve-Executable -Names @('bash.exe', 'bash')
}
if (-not $bash) { throw 'Git Bash is required to validate tracked shell scripts and the hook wrapper.' }

Push-Location $repositoryRoot
try {
    Invoke-NativeStep 'staged whitespace and conflict-marker check' {
        & $git -c "safe.directory=$repositoryForGit" diff --cached --check
    }
    Invoke-NativeStep 'PowerShell syntax' {
        $powerShellFiles = @(& $git -c "safe.directory=$repositoryForGit" `
            ls-files --cached --others --exclude-standard -- '*.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate PowerShell files.' }
        foreach ($relative in $powerShellFiles) {
            $tokens = $null
            $errors = $null
            [Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $repositoryRoot $relative), [ref]$tokens, [ref]$errors) | Out-Null
            if ($errors.Count -ne 0) {
                $messages = @($errors | ForEach-Object { $_.Message }) -join '; '
                throw "$relative has PowerShell syntax errors: $messages"
            }
        }
    }
    Invoke-NativeStep 'shell and hook-wrapper syntax' {
        $shellFiles = @(& $git -c "safe.directory=$repositoryForGit" `
            ls-files --cached --others --exclude-standard -- '*.sh' '.githooks/pre-commit')
        if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate shell files.' }
        foreach ($relative in $shellFiles) {
            & $bash -n (Join-Path $repositoryRoot $relative)
            if ($LASTEXITCODE -ne 0) { throw "$relative failed bash -n." }
        }
    }
    Invoke-NativeStep 'locked offline Cargo metadata' {
        & $cargo metadata --locked --offline --no-deps --format-version 1 | Out-Null
    }
    Invoke-NativeStep 'Rust formatting' {
        & $cargo fmt --all -- --check
    }
    Invoke-NativeStep 'Rust Clippy' {
        & $cargo clippy --workspace --all-targets --all-features --offline -- -D warnings
    }
    Invoke-NativeStep 'Rust tests' {
        & $cargo test --workspace --all-features --offline
    }

    Push-Location $desktopRoot
    try {
        Invoke-NativeStep 'frontend tests' {
            & $npm test -- --reporter=dot
        }
        Invoke-NativeStep 'frontend type-check and production build' {
            & $npm run build
        }
    }
    finally { Pop-Location }

    Invoke-NativeStep 'public-source, license, and secret-boundary audit' {
        & $powerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File (Join-Path $repositoryRoot 'tests\public\Invoke-PublicSourceTests.ps1')
    }
    Invoke-NativeStep 'quality-hook contract tests' {
        & $powerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File (Join-Path $repositoryRoot 'tests\quality\Invoke-QualityHookTests.ps1')
    }

    $milestoneTests = Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'tests') `
        -Filter 'Invoke-M*SoftwareTests.ps1' -File -Recurse | Sort-Object FullName
    if ($milestoneTests.Count -eq 0) {
        throw 'No milestone software test suites were found.'
    }
    foreach ($test in $milestoneTests) {
        $relative = $test.FullName.Substring($repositoryRoot.Length + 1)
        Invoke-NativeStep "milestone software suite: $relative" {
            & $powerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $test.FullName
        }
    }
}
finally { Pop-Location }

$elapsed = [DateTimeOffset]::UtcNow - $startedAt
Write-Host ("`nQuireWire pre-commit gate passed in {0:n1}s. Hardware and physical-output tests were not run." -f $elapsed.TotalSeconds) -ForegroundColor Green
