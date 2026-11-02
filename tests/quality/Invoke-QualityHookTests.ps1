[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$passed = 0
$failed = 0

function Check([string]$Name, [scriptblock]$Test) {
    try {
        $result = & $Test
        if (-not $result) { throw 'condition returned false' }
        $script:passed++
        Write-Host "PASS $Name"
    }
    catch {
        $script:failed++
        Write-Host "FAIL $Name - $($_.Exception.Message)"
    }
}

$qualityPath = Join-Path $repositoryRoot 'scripts\quality\Invoke-PreCommit.ps1'
$installerPath = Join-Path $repositoryRoot 'scripts\quality\Install-GitHooks.ps1'
$hookPath = Join-Path $repositoryRoot '.githooks\pre-commit'
$quality = Get-Content -Raw -LiteralPath $qualityPath
$installer = Get-Content -Raw -LiteralPath $installerPath
$hook = Get-Content -Raw -LiteralPath $hookPath
$hookBytes = [IO.File]::ReadAllBytes($hookPath)
$attributes = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot '.gitattributes')
$workflow = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot '.github\workflows\ci.yml')
$development = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'docs\development.md')

foreach ($path in @($qualityPath, $installerPath, $PSCommandPath)) {
    Check "PowerShell syntax: $([IO.Path]::GetFileName($path))" {
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile(
            $path, [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count -eq 0
    }
}

Check 'hook uses fixed repository-owned PowerShell gate' {
    $hook -match '^#!/bin/sh' -and $hook -match 'set -eu' -and
        $hook -match 'git rev-parse --show-toplevel' -and
        $hook -match 'scripts/quality/Invoke-PreCommit\.ps1' -and
        $hook -notmatch '(?i)curl|wget|invoke-webrequest'
}
Check 'hook is LF-only and protected by Git attributes' {
    $hookBytes -notcontains [byte]13 -and
        $attributes -match '(?m)^\.githooks/\* text eol=lf\r?$' -and
        $attributes -match '(?m)^\*\.patch text eol=lf\r?$'
}
Check 'installer configures only the local hooks path' {
    $installer -match 'config --local core\.hooksPath \.githooks' -and
        $installer -notmatch 'config --global' -and $installer -notmatch 'Copy-Item|Set-Content'
}
Check 'gate checks staged diff, locked dependency graph, formatting and Clippy' {
    $quality -match 'diff --cached --check' -and $quality -match 'metadata --locked --offline' -and
        $quality -match 'fmt --all -- --check' -and
        $quality -match 'clippy --workspace --all-targets --all-features --offline -- -D warnings'
}
Check 'gate prefers Git Bash over the Windows WSL launcher' {
    $quality -match "gitInstallRoot 'bin\\bash\.exe'" -and
        $quality -match 'Test-Path -LiteralPath \$gitBash'
}
Check 'gate runs Rust and frontend tests plus production build' {
    $quality -match 'test --workspace --all-features --offline' -and
        $quality -match '& \$npm test' -and $quality -match '& \$npm run build'
}
Check 'gate includes public, hook-contract and every milestone software suite' {
    $quality -match 'Invoke-PublicSourceTests\.ps1' -and
        $quality -match 'Invoke-QualityHookTests\.ps1' -and
        $quality -match 'Invoke-M\*SoftwareTests\.ps1'
}
Check 'gate never selects physical or disposable VirtualBox integration tests' {
    $quality -notmatch 'Invoke-M3WindowsIntegration\.ps1' -and
        $quality -notmatch 'Record-M[0-9]+Acceptance\.ps1' -and
        $quality -match 'Hardware and physical-output tests were not run'
}
Check 'gate does not install dependencies or access the network' {
    $quality -notmatch '(?i)&\s+\$npm\s+(ci|install)|&\s+\$cargo\s+install|invoke-webrequest|start-bitstransfer'
}
Check 'CI runs the repository quality gate' {
    $workflow -match 'scripts/quality/Invoke-PreCommit\.ps1'
}
Check 'CI primes the locked Cargo cache before the offline gate' {
    $fetchIndex = $workflow.IndexOf('cargo fetch --locked --target x86_64-pc-windows-msvc', [StringComparison]::Ordinal)
    $gateIndex = $workflow.IndexOf('scripts/quality/Invoke-PreCommit.ps1', [StringComparison]::Ordinal)
    $fetchIndex -ge 0 -and $gateIndex -gt $fetchIndex
}
Check 'developer guide documents hook installation and boundaries' {
    $development -match 'Install-GitHooks\.ps1' -and
        $development -match 'never invokes M3' -and $development -match 'physical\s+acceptance test'
}

Write-Host "Quality-hook tests: $passed passed, $failed failed"
if ($failed -ne 0) { exit 1 }
