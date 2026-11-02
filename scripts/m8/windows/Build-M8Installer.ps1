[CmdletBinding()]
param(
    [switch]$UnsignedDevelopmentBuild,
    [ValidatePattern('^[0-9A-Fa-f]{40}$')]
    [string]$CertificateThumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [switch]$SkipFrontendInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$desktopRoot = Join-Path $repositoryRoot 'apps\desktop'
$releaseRoot = Join-Path $repositoryRoot 'target\release'

if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
    $wingetRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    $npm = Get-ChildItem -LiteralPath $wingetRoot -Filter npm.cmd -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'OpenJS\.NodeJS\.LTS_' } |
        Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $npm) { throw 'Node.js LTS with npm is required to build the desktop installer.' }
    $env:Path = "$($npm.DirectoryName);$env:Path"
}

if (-not $UnsignedDevelopmentBuild -and [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    throw 'Choose -UnsignedDevelopmentBuild explicitly or provide -CertificateThumbprint for a signed build.'
}
if ($UnsignedDevelopmentBuild -and -not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    throw 'UnsignedDevelopmentBuild and CertificateThumbprint are mutually exclusive.'
}

Push-Location $repositoryRoot
try {
    & cargo.exe build --locked --release -p quirewire-agent -p quirewirectl
    if ($LASTEXITCODE -ne 0) { throw 'Release agent/CLI build failed.' }
}
finally { Pop-Location }

$agent = Join-Path $releaseRoot 'quirewire-agent.exe'
$cli = Join-Path $releaseRoot 'quirewirectl.exe'
foreach ($binary in @($agent, $cli)) {
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw "Missing release binary: $binary" }
}

$tauriConfig = 'src-tauri/tauri.m8.conf.json'
$temporarySignedConfig = $null
if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
    $signTool = Get-Command signtool.exe -ErrorAction Stop
    foreach ($binary in @($agent, $cli)) {
        & $signTool.Source sign /sha1 $CertificateThumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 $binary
        if ($LASTEXITCODE -ne 0) { throw "Authenticode signing failed for $binary" }
    }
    $signedConfig = Get-Content -Raw -LiteralPath (Join-Path $desktopRoot $tauriConfig) | ConvertFrom-Json
    $signedConfig.bundle.windows | Add-Member -NotePropertyName certificateThumbprint -NotePropertyValue $CertificateThumbprint
    $signedConfig.bundle.windows | Add-Member -NotePropertyName digestAlgorithm -NotePropertyValue 'sha256'
    $signedConfig.bundle.windows | Add-Member -NotePropertyName timestampUrl -NotePropertyValue $TimestampUrl
    $signedConfig.bundle.windows | Add-Member -NotePropertyName tsp -NotePropertyValue $true
    $temporarySignedConfig = Join-Path $desktopRoot 'src-tauri\tauri.m8.signed.local.json'
    $signedConfig | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporarySignedConfig -Encoding utf8
    $tauriConfig = 'src-tauri/tauri.m8.signed.local.json'
}

Push-Location $desktopRoot
try {
    if (-not $SkipFrontendInstall) {
        & npm.cmd ci
        if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }
    }
    $arguments = @('tauri', 'build', '--bundles', 'nsis', '--config', $tauriConfig)
    & cargo.exe @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Tauri NSIS build failed.' }
}
finally {
    Pop-Location
    if ($temporarySignedConfig -and (Test-Path -LiteralPath $temporarySignedConfig)) {
        Remove-Item -LiteralPath $temporarySignedConfig -Force
    }
}

$bundleRoot = Join-Path $releaseRoot 'bundle\nsis'
$installer = Get-ChildItem -LiteralPath $bundleRoot -Filter '*-setup.exe' -File |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
if (-not $installer) { throw 'Tauri completed without producing an NSIS setup executable.' }
$signature = Get-AuthenticodeSignature -LiteralPath $installer.FullName
if ($UnsignedDevelopmentBuild -and $signature.Status -eq 'Valid') {
    throw 'The development build was requested as unsigned but the installer has a valid signature.'
}
if ($CertificateThumbprint -and $signature.Status -ne 'Valid') {
    throw "The signed installer failed Authenticode validation: $($signature.Status)"
}

[pscustomobject]@{
    schema = 'quirewire.m8.build-result.v1'
    installer = $installer.FullName
    bytes = $installer.Length
    sha256 = (Get-FileHash -LiteralPath $installer.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    signature_status = [string]$signature.Status
    channel = if ($UnsignedDevelopmentBuild) { 'unsigned-development' } else { 'signed-release' }
    virtualbox_bundled = $false
    brother_driver_bundled = $false
    configured_appliance_bundled = $false
} | ConvertTo-Json
