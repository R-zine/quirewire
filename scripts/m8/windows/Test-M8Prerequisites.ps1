[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'QuireWire'),
    [string]$VBoxManage = (Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-WebView2 {
    $keys = @(
        'HKCU:\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    )
    foreach ($key in $keys) {
        if (Test-Path -LiteralPath $key) {
            return [string](Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).pv
        }
    }
    $null
}

function Get-VirtualBoxVersion {
    if (-not (Test-Path -LiteralPath $VBoxManage -PathType Leaf)) { return $null }
    $value = (& $VBoxManage --version 2>$null | Select-Object -First 1).ToString().Trim()
    if ($LASTEXITCODE -ne 0) { return $null }
    $value
}

$os = Get-CimInstance Win32_OperatingSystem
$computer = Get-CimInstance Win32_ComputerSystem
$driveRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($InstallRoot))
$drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($driveRoot.TrimEnd('\'))'"
$virtualBoxVersion = Get-VirtualBoxVersion
$virtualBoxSupported = $false
if ($virtualBoxVersion -match '^(\d+)\.(\d+)\.') {
    $virtualBoxSupported = [int]$Matches[1] -eq 7 -and [int]$Matches[2] -ge 1
}
$printManagement = Get-Command Add-Printer -ErrorAction SilentlyContinue
$webView2Version = Test-WebView2
$isWindows11 = [int]$os.BuildNumber -ge 22000
$isX64 = [Environment]::Is64BitOperatingSystem
$memoryBytes = [uint64]$computer.TotalPhysicalMemory
$freeBytes = if ($drive) { [uint64]$drive.FreeSpace } else { 0 }
$requiredDiskBytes = 12GB
$guestMemoryBytes = 768MB
$blocking = @()
if (-not $isWindows11) { $blocking += 'Supported, fully patched Windows 11 is required.' }
if (-not $isX64) { $blocking += 'An x64 Windows host is required.' }
if (-not $printManagement -or -not $printManagement.Parameters.ContainsKey('IppURL')) {
    $blocking += 'Windows PrintManagement with Add-Printer -IppURL is required.'
}
if (-not $webView2Version) { $blocking += 'Microsoft Edge WebView2 Runtime is required to open the desktop UI.' }
if (-not $virtualBoxVersion) { $blocking += 'VirtualBox is not installed. Use Oracle installation guidance, then rerun this check.' }
elseif (-not $virtualBoxSupported) { $blocking += "VirtualBox $virtualBoxVersion is outside the supported 7.1+ major-7 range." }
if ($freeBytes -lt $requiredDiskBytes) { $blocking += 'At least 12 GiB free space is required for the app and owner-local appliance.' }
if ($memoryBytes -lt 4GB) { $blocking += 'At least 4 GiB host RAM is required; the guest reserves 768 MiB while running.' }

[pscustomobject]@{
    schema = 'quirewire.m8.prerequisites.v1'
    checked_utc = [DateTime]::UtcNow.ToString('o')
    ready = $blocking.Count -eq 0
    windows = [ordered]@{ caption = $os.Caption; build = $os.BuildNumber; x64 = $isX64 }
    webview2 = [ordered]@{ present = [bool]$webView2Version; version = $webView2Version; bundled = $false }
    print_management_ipp = [bool]($printManagement -and $printManagement.Parameters.ContainsKey('IppURL'))
    virtualbox = [ordered]@{
        present = [bool]$virtualBoxVersion
        version = $virtualBoxVersion
        supported = $virtualBoxSupported
        bundled = $false
        guided_download = 'https://www.virtualbox.org/wiki/Downloads'
    }
    resources = [ordered]@{
        guest_memory_mib = 768
        required_free_disk_gib = 12
        free_disk_bytes = $freeBytes
        host_memory_bytes = $memoryBytes
    }
    appliance = [ordered]@{
        bundled = $false
        reason = 'Brother driver redistribution permission is not established.'
        owner_local_configured_ova_required = $true
    }
    network = [ordered]@{
        quirewire_installer = 'offline'
        setup = 'required only to obtain VirtualBox, Debian inputs, and owner-licensed Brother packages when not already present'
    }
    usb_consent = 'The Linux guest captures the entire selected USB device; Windows cannot use that device while the bridge is running.'
    blocking = $blocking
} | ConvertTo-Json -Depth 6

if ($blocking.Count -ne 0) { exit 2 }
