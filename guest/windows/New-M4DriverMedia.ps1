[CmdletBinding()]
param(
    [ValidateSet('open-brlaser', 'official-brother')]
    [string]$Mode = 'open-brlaser',

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [string]$BrotherPatchPath,

    [string]$BrotherDriverPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$sourceManifest = Join-Path $repositoryRoot 'guest\manifests\brother-dcpl2600d.env'
$output = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($output) | Out-Null

$values = @{}
foreach ($line in Get-Content -LiteralPath $sourceManifest) {
    if (-not $line -or $line.StartsWith('#')) { continue }
    $parts = $line.Split('=', 2)
    if ($parts.Count -ne 2 -or $values.ContainsKey($parts[0])) { throw 'Malformed driver manifest.' }
    $values[$parts[0]] = $parts[1]
}

function Quote-VisoPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Contains("'")) { throw 'VISO input paths may not contain a single quote.' }
    return "'$full'"
}

$manifestLines = @(
    "QUIREWIRE_DRIVER_SCHEMA=$($values.QUIREWIRE_DRIVER_SCHEMA)",
    "DRIVER_MODE=$Mode",
    "QUEUE_NAME=$($values.QUEUE_NAME)",
    "USB_VENDOR_ID=$($values.USB_VENDOR_ID)",
    "USB_PRODUCT_ID=$($values.USB_PRODUCT_ID)"
)
$mediaFiles = @()
if ($Mode -eq 'official-brother') {
    if (-not $BrotherPatchPath -or -not $BrotherDriverPath) {
        throw 'Official mode requires both owner-downloaded Brother package paths.'
    }
    foreach ($pair in @(
        @($BrotherPatchPath, $values.PATCH_SHA256, 'Brother legacy USB patch'),
        @($BrotherDriverPath, $values.DRIVER_SHA256, 'Brother driver')
    )) {
        if (-not (Test-Path -LiteralPath $pair[0] -PathType Leaf)) { throw "$($pair[2]) is missing." }
        $actual = (Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $pair[1]) { throw "$($pair[2]) SHA-256 mismatch." }
    }
    $officialKeys = @(
        'PATCH_FILENAME', 'PATCH_PACKAGE', 'PATCH_VERSION', 'PATCH_ARCHITECTURE', 'PATCH_SHA256', 'PATCH_SOURCE_URL',
        'DRIVER_FILENAME', 'DRIVER_PACKAGE', 'DRIVER_VERSION', 'DRIVER_ARCHITECTURE', 'DRIVER_SHA256', 'DRIVER_SOURCE_URL',
        'PPD_PATH', 'PPD_SHA256', 'REDISTRIBUTION'
    )
    $manifestLines += $officialKeys | ForEach-Object { "$_=$($values[$_])" }
    $mediaFiles += "/quirewire-driver/$($values.PATCH_FILENAME)=$(Quote-VisoPath $BrotherPatchPath)"
    $mediaFiles += "/quirewire-driver/$($values.DRIVER_FILENAME)=$(Quote-VisoPath $BrotherDriverPath)"
}

$manifestPath = Join-Path $output "manifest-$Mode.env"
[IO.File]::WriteAllText($manifestPath, (($manifestLines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
$visoPath = Join-Path $output "quirewire-m4-$Mode.viso"
$entries = @(
    '--iprt-iso-maker-file-marker-bourne-sh', [guid]::NewGuid().ToString(),
    '--file-mode=0444', '--dir-mode=0555', '--no-file-mode', '--no-dir-mode',
    "/quirewire-driver/manifest.env=$(Quote-VisoPath $manifestPath)"
) + $mediaFiles
[IO.File]::WriteAllText($visoPath, ($entries -join ' '), [Text.UTF8Encoding]::new($false))

[pscustomobject]@{
    schema = 'quirewire.m4.driver-media-result.v1'
    mode = $Mode
    media = $visoPath
    redistribution = if ($Mode -eq 'official-brother') { 'owner-local-only-pending-license-review' } else { 'source-only' }
} | Format-List
