[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
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

$requiredFiles = @(
    'LICENSE',
    'LICENSE-APACHE',
    'LICENSE-MIT',
    'LICENSES\GPL-3.0-only.txt',
    'NOTICE',
    'README.md',
    'REUSE.toml',
    'THIRD_PARTY_NOTICES.md',
    'docs\licensing.md',
    'guest\patches\README.md'
)

Check 'required public-source license files exist' {
    @($requiredFiles | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $repositoryRoot $_) -PathType Leaf)
    }).Count -eq 0
}

$license = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'LICENSE')
$apache = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'LICENSE-APACHE')
$mit = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'LICENSE-MIT')
$gpl = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'LICENSES\GPL-3.0-only.txt')
$reuse = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'REUSE.toml')
$notices = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'THIRD_PARTY_NOTICES.md')
$patchNotice = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'guest\patches\README.md')

Check 'root license declares dual license and AirSane exception' {
    $license -match 'Apache License, Version 2\.0' -and
        $license -match 'MIT License' -and
        $license -match 'GPL-3\.0-only' -and
        $license -match 'airsane-brscan5-session\.patch'
}
Check 'canonical license texts are present' {
    $apache -match 'Apache License\s+Version 2\.0' -and
        $mit -match 'Permission is hereby granted, free of charge' -and
        $gpl -match 'GNU GENERAL PUBLIC LICENSE' -and $gpl -match 'Version 3, 29 June 2007'
}
Check 'AirSane patch has SPDX mapping and provenance' {
    $reuse -match 'guest/patches/airsane-brscan5-session\.patch' -and
        $reuse -match 'SPDX-License-Identifier = "GPL-3\.0-only"' -and
        $patchNotice -match '08ff4d798d718e2e50ef805404ddef82f6d03cc1' -and
        $patchNotice -match 'complete corresponding patched AirSane source'
}
Check 'third-party notice records MPL source duties and vendor boundary' {
    $notices -match 'MPL-2\.0' -and $notices -match 'cssparser 0\.36\.0' -and
        $notices -match 'license inventory' -and
        $notices -match 'does not redistribute VirtualBox' -and
        $notices -match 'Brother print/scanner packages'
}

$manifest = Get-Content -LiteralPath (Join-Path $repositoryRoot 'guest\manifests\scanner-dcpl2600d.env')
$expectedPatchHash = ($manifest | Where-Object { $_ -like 'AIRSANE_PATCH_SHA256=*' }) -replace '^AIRSANE_PATCH_SHA256=', ''
$actualPatchHash = (Get-FileHash -LiteralPath (Join-Path $repositoryRoot 'guest\patches\airsane-brscan5-session.patch') -Algorithm SHA256).Hash.ToLowerInvariant()
Check 'AirSane patch hash matches scanner manifest' {
    $expectedPatchHash -match '^[0-9a-f]{64}$' -and $actualPatchHash -eq $expectedPatchHash
}

$rootManifest = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'Cargo.toml')
Check 'Rust workspace declares author and dual license' {
    $rootManifest -match 'authors = \["Ivan Radev"\]' -and
        $rootManifest -match 'license = "MIT OR Apache-2\.0"'
}

$cargoManifests = @(
    Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'crates') -Filter Cargo.toml -File -Recurse
    Get-Item -LiteralPath (Join-Path $repositoryRoot 'apps\desktop\src-tauri\Cargo.toml')
)
Check 'every Rust package inherits author and license metadata' {
    @($cargoManifests | Where-Object {
        $text = Get-Content -Raw -LiteralPath $_.FullName
        $text -notmatch 'authors\.workspace = true' -or $text -notmatch 'license\.workspace = true'
    }).Count -eq 0
}

$npmPackage = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'apps\desktop\package.json') | ConvertFrom-Json
$npmLock = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'apps\desktop\package-lock.json')
Check 'desktop package and lockfile declare the dual license' {
    $npmPackage.license -eq 'MIT OR Apache-2.0' -and
        $npmLock -match '(?s)"packages"\s*:\s*\{\s*""\s*:\s*\{.{0,500}?"license"\s*:\s*"MIT OR Apache-2\.0"'
}

$tauri = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'apps\desktop\src-tauri\tauri.m8.conf.json') | ConvertFrom-Json
$resourceNames = @($tauri.bundle.resources.PSObject.Properties.Name)
Check 'installer packages project and third-party notices' {
    @(
        '../../../LICENSE',
        '../../../LICENSE-APACHE',
        '../../../LICENSE-MIT',
        '../../../LICENSES/GPL-3.0-only.txt',
        '../../../NOTICE',
        '../../../THIRD_PARTY_NOTICES.md'
    ) | Where-Object { $_ -notin $resourceNames } | Measure-Object | Select-Object -ExpandProperty Count | ForEach-Object { $_ -eq 0 }
}

$readme = Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot 'README.md')
$readmeSections = @('Features', 'Requirements', 'Installation status', 'Set up from source', 'Daily use', 'Tests and project status', 'Security and privacy', 'Licensing')
$missingReadmeSections = @($readmeSections | Where-Object { $readme -notmatch "(?m)^## $([regex]::Escape($_))$" })
Check 'README covers product, features, requirements, setup, use, tests, security and licensing' {
    $readme -match '(?m)^# QuireWire$' -and $missingReadmeSections.Count -eq 0
}

$repoForGit = $repositoryRoot.Replace('\', '/')
$sourceFiles = @(& git.exe -c "safe.directory=$repoForGit" ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed' }
$forbidden = @($sourceFiles | Where-Object {
    $_ -match '(?i)(^|/)(id_rsa|id_ed25519)$' -or
        $_ -match '(?i)\.(exe|dll|msi|msix|ova|ovf|vdi|vmdk|iso|deb|rpm|pfx|p12|key|pem)$' -or
        $_ -match '(?i)(dcpl2600d.*\.(deb|rpm)|brotherlegacyusb.*\.deb)'
})
Check 'source tree contains no bundled binary, appliance, vendor package or private key' {
    $forbidden.Count -eq 0
}

$textExtensions = @('.cfg', '.conf', '.env', '.html', '.json', '.lock', '.md', '.nsh', '.ps1', '.rs', '.sh', '.toml', '.ts', '.tsx', '.txt', '.yaml', '.yml')
$oldBrandHits = [Collections.Generic.List[string]]::new()
$oldBrandPattern = '(?i)' + [regex]::Escape(('Print' + 'Bridge'))
foreach ($relative in $sourceFiles) {
    $path = Join-Path $repositoryRoot ($relative -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()
    $name = [IO.Path]::GetFileName($path)
    if ($extension -notin $textExtensions -and $name -notin @('LICENSE', 'NOTICE')) { continue }
    $content = Get-Content -Raw -LiteralPath $path
    if ($content -match $oldBrandPattern) { $oldBrandHits.Add($relative) }
}
Check 'active source contains no previous project identity' {
    if ($oldBrandHits.Count -ne 0) { throw ($oldBrandHits -join ', ') }
    $true
}

Write-Host "Public source tests: $passed passed, $failed failed"
if ($failed -ne 0) { exit 1 }
