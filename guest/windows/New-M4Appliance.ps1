[CmdletBinding()]
param(
    [ValidateSet('All', 'Base', 'Configured')]
    [string]$Stage = 'All',

    [Parameter(Mandatory = $true)]
    [string]$DebianIsoPath,

    [Parameter(Mandatory = $true)]
    [string]$SshPublicKeyPath,

    [string]$BaseOvaPath,

    [string]$BrotherPatchPath,

    [string]$BrotherDriverPath,

    [string]$OutputDirectory,

    [string]$VBoxManagePath = "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",

    [int]$BuildMemoryMiB = 1024,

    [int]$RuntimeMemoryMiB = 768,

    [int]$DiskMiB = 10240,

    [int]$BuildTimeoutMinutes = 45,

    [switch]$KeepBuildVms
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$debianManifestPath = Join-Path $repositoryRoot 'guest\manifests\debian-13.7-amd64.env'
$driverManifestPath = Join-Path $repositoryRoot 'guest\manifests\brother-dcpl2600d.env'

if (-not $OutputDirectory) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $OutputDirectory = Join-Path $repositoryRoot "artifacts\m4\builds\$stamp"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

function Read-Manifest {
    param([Parameter(Mandatory = $true)][string]$Path)
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if (-not $line -or $line.StartsWith('#')) { continue }
        $parts = $line.Split('=', 2)
        if ($parts.Count -ne 2 -or $values.ContainsKey($parts[0])) {
            throw "Malformed or duplicate manifest entry in $Path"
        }
        $values[$parts[0]] = $parts[1]
    }
    return $values
}

function Assert-FileHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label input is missing: $Path"
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "$Label SHA-256 mismatch. Expected $Expected, observed $actual"
    }
}

function Invoke-VBox {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$SensitiveOutput
    )
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $nativeOutput = @(& $VBoxManagePath @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        if ($SensitiveOutput) {
            throw "VBoxManage operation failed with exit code $exitCode; output suppressed because it may contain a USB serial."
        }
        throw "VBoxManage $($Arguments[0]) failed with exit code ${exitCode}: $($nativeOutput -join [Environment]::NewLine)"
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $nativeOutput }
}

function Get-VmProperty {
    param([string]$Vm, [string]$Property)
    $info = (Invoke-VBox -Arguments @('showvminfo', $Vm, '--machinereadable')).Output
    $prefix = "$Property="
    $line = $info | Where-Object { $_.StartsWith($prefix) } | Select-Object -First 1
    if (-not $line) { throw "VirtualBox did not report $Property for owned build VM." }
    return $line.Substring($prefix.Length).Trim('"')
}

function Set-BuildOwnership {
    param([string]$Vm, [string]$Marker)
    Invoke-VBox -Arguments @('setextradata', $Vm, 'QuireWire/Schema', 'quirewire.m4.build-vm.v1') | Out-Null
    Invoke-VBox -Arguments @('setextradata', $Vm, 'QuireWire/BuildMarker', $Marker) | Out-Null
}

function Assert-BuildOwnership {
    param([string]$Vm, [string]$Marker)
    $schema = (Invoke-VBox -Arguments @('getextradata', $Vm, 'QuireWire/Schema')).Output -join "`n"
    $observed = (Invoke-VBox -Arguments @('getextradata', $Vm, 'QuireWire/BuildMarker')).Output -join "`n"
    if ($schema -notmatch 'Value: quirewire\.m4\.build-vm\.v1' -or $observed -notmatch "Value: $([regex]::Escape($Marker))") {
        throw 'Refusing to mutate a VM without the exact M4 build ownership marker.'
    }
}

function Remove-OwnedBuildVm {
    param([string]$Vm, [string]$Marker)
    Assert-BuildOwnership -Vm $Vm -Marker $Marker
    $state = Get-VmProperty -Vm $Vm -Property 'VMState'
    if ($state -eq 'running') {
        Invoke-VBox -Arguments @('controlvm', $Vm, 'poweroff') | Out-Null
    }
    Invoke-VBox -Arguments @('unregistervm', $Vm, '--delete') | Out-Null
}

function Wait-VmPowerOff {
    param([string]$Vm, [int]$TimeoutMinutes)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        $state = Get-VmProperty -Vm $Vm -Property 'VMState'
        if ($state -eq 'poweroff') { return }
        if ($state -in @('aborted', 'guru_meditation')) {
            throw "Owned build VM stopped unexpectedly in state '$state'."
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    throw "Timed out after $TimeoutMinutes minutes waiting for the owned build VM to power off."
}

function Quote-VisoPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Contains("'")) { throw 'VISO input paths may not contain a single quote.' }
    return "'$full'"
}

function New-BaseViso {
    param([string]$IsoPath, [string]$PublicKeyPath, [string]$Destination)
    $entries = @(
        '--iprt-iso-maker-file-marker-bourne-sh', [guid]::NewGuid().ToString(),
        '--file-mode=0444', '--dir-mode=0555', '--no-file-mode', '--no-dir-mode',
        '--import-iso', (Quote-VisoPath $IsoPath),
        'isolinux/isolinux.cfg=:must-remove:',
        "isolinux/isolinux.cfg=$(Quote-VisoPath (Join-Path $repositoryRoot 'guest\config\isolinux.cfg'))",
        '/isolinux/txt.cfg=:must-remove:',
        "/isolinux/txt.cfg=$(Quote-VisoPath (Join-Path $repositoryRoot 'guest\config\txt.cfg'))",
        "/preseed.cfg=$(Quote-VisoPath (Join-Path $repositoryRoot 'guest\config\preseed.cfg'))",
        "/quirewire/base/provision-base.sh=$(Quote-VisoPath (Join-Path $repositoryRoot 'guest\linux\provision-base.sh'))",
        "/quirewire/base/firstboot.sh=$(Quote-VisoPath (Join-Path $repositoryRoot 'guest\linux\firstboot.sh'))",
        "/quirewire/base/apply-driver-media.sh=$(Quote-VisoPath (Join-Path $repositoryRoot 'guest\linux\apply-driver-media.sh'))",
        "/quirewire/base/health.sh=$(Quote-VisoPath (Join-Path $repositoryRoot 'guest\linux\health.sh'))",
        "/quirewire/base/configure-lan-cups.sh=$(Quote-VisoPath (Join-Path $repositoryRoot 'guest\linux\configure-lan-cups.sh'))",
        "/quirewire/base/authorized_keys=$(Quote-VisoPath $PublicKeyPath)",
        "/quirewire/manifests/debian-13.7-amd64.env=$(Quote-VisoPath $debianManifestPath)",
        "/quirewire/config/90-quirewire-sshd.conf=$(Quote-VisoPath (Join-Path $repositoryRoot 'guest\config\90-quirewire-sshd.conf'))",
        "/quirewire/config/quirewire-logrotate=$(Quote-VisoPath (Join-Path $repositoryRoot 'guest\config\quirewire-logrotate'))"
    )
    [IO.File]::WriteAllText($Destination, ($entries -join ' '), [Text.UTF8Encoding]::new($false))
}

function New-DriverViso {
    param([string]$PatchPath, [string]$DriverPath, [string]$Destination)
    $entries = @(
        '--iprt-iso-maker-file-marker-bourne-sh', [guid]::NewGuid().ToString(),
        '--file-mode=0444', '--dir-mode=0555', '--no-file-mode', '--no-dir-mode',
        "/quirewire-driver/manifest.env=$(Quote-VisoPath $driverManifestPath)",
        "/quirewire-driver/$($driverManifest.PATCH_FILENAME)=$(Quote-VisoPath $PatchPath)",
        "/quirewire-driver/$($driverManifest.DRIVER_FILENAME)=$(Quote-VisoPath $DriverPath)"
    )
    [IO.File]::WriteAllText($Destination, ($entries -join ' '), [Text.UTF8Encoding]::new($false))
}

function New-MinimalVm {
    param([string]$Name, [string]$Marker, [string]$MachineFolder, [string]$DiskPath, [string]$InstallViso)
    Invoke-VBox -Arguments @('createvm', '--name', $Name, '--ostype', 'Debian_64', '--basefolder', $MachineFolder, '--register') | Out-Null
    $uuid = Get-VmProperty -Vm $Name -Property 'UUID'
    Set-BuildOwnership -Vm $uuid -Marker $Marker
    Invoke-VBox -Arguments @('modifyvm', $uuid, '--cpus', '1', '--memory', "$BuildMemoryMiB", '--vram', '16', '--graphicscontroller', 'vmsvga', '--nic1', 'nat', '--nic-type1', '82540EM', '--audio-enabled', 'off', '--clipboard-mode', 'disabled', '--drag-and-drop', 'disabled', '--usb-ohci', 'on', '--usb-ehci', 'off', '--usb-xhci', 'off', '--boot1', 'dvd', '--boot2', 'disk', '--boot3', 'none', '--boot4', 'none') | Out-Null
    Invoke-VBox -Arguments @('createmedium', 'disk', '--filename', $DiskPath, '--size', "$DiskMiB", '--format', 'VDI', '--variant', 'Standard') | Out-Null
    Invoke-VBox -Arguments @('storagectl', $uuid, '--name', 'SATA Controller', '--add', 'sata', '--controller', 'IntelAhci') | Out-Null
    Invoke-VBox -Arguments @('storageattach', $uuid, '--storagectl', 'SATA Controller', '--port', '0', '--device', '0', '--type', 'hdd', '--medium', $DiskPath) | Out-Null
    Invoke-VBox -Arguments @('storageattach', $uuid, '--storagectl', 'SATA Controller', '--port', '1', '--device', '0', '--type', 'dvddrive', '--medium', $InstallViso) | Out-Null
    return $uuid
}

function Get-ExactBrotherUsb {
    $raw = (Invoke-VBox -Arguments @('list', 'usbhost') -SensitiveOutput).Output
    $blocks = (($raw -join "`n") -split "(?:`r?`n){2,}")
    $usbDevices = @()
    foreach ($block in $blocks) {
        if ($block -match '(?im)^VendorId:\s+0x04f9' -and $block -match '(?im)^ProductId:\s+0x0567') {
            $uuid = [regex]::Match($block, '(?im)^UUID:\s+([^\s]+)').Groups[1].Value
            $serial = [regex]::Match($block, '(?im)^SerialNumber:\s+(.+)$').Groups[1].Value.Trim()
            if (-not $uuid) { throw 'Target Brother USB record did not contain a host UUID.' }
            $usbDevices += [pscustomobject]@{ Uuid = $uuid; Serial = $serial }
        }
    }
    if ($usbDevices.Count -ne 1) {
        throw "Expected exactly one Brother 04f9:0567 USB device, observed $($usbDevices.Count)."
    }
    return $usbDevices[0]
}

function Add-ExactUsbFilter {
    param([string]$Vm, [pscustomobject]$Usb)
    $arguments = @('usbfilter', 'add', '0', '--target', $Vm, '--name', 'QuireWire M4 exact Brother', '--active', 'yes', '--vendorid', '04f9', '--productid', '0567', '--remote', 'no')
    if ($Usb.Serial) { $arguments += @('--serialnumber', $Usb.Serial) }
    Invoke-VBox -Arguments $arguments -SensitiveOutput | Out-Null
}

if (-not (Test-Path -LiteralPath $VBoxManagePath -PathType Leaf)) {
    throw "VBoxManage was not found at $VBoxManagePath"
}
$version = (Invoke-VBox -Arguments @('--version')).Output -join ''
if ($version -notmatch '^7\.(1|2)\.') {
    throw "VirtualBox $version is outside the M4 validated 7.1-7.2 range."
}

$debianManifest = Read-Manifest -Path $debianManifestPath
$driverManifest = Read-Manifest -Path $driverManifestPath
Assert-FileHash -Path $DebianIsoPath -Expected $debianManifest.DEBIAN_ISO_SHA256 -Label 'Debian ISO'
if (-not (Test-Path -LiteralPath $SshPublicKeyPath -PathType Leaf)) {
    throw "SSH public key is missing: $SshPublicKeyPath"
}
if ((Get-Content -Raw -LiteralPath $SshPublicKeyPath) -notmatch '^ssh-(ed25519|rsa)\s+') {
    throw 'SSH public key is not in an accepted OpenSSH public-key format.'
}

$baseOva = if ($BaseOvaPath) { [IO.Path]::GetFullPath($BaseOvaPath) } else { Join-Path $OutputDirectory 'quirewire-m4-base.ova' }
$driverViso = Join-Path $OutputDirectory 'quirewire-m4-owner-driver.viso'
$configuredOva = Join-Path $OutputDirectory 'quirewire-m4-dcpl2600d.owner-local.ova'
$builtBaseHere = $false

if ($Stage -in @('All', 'Base')) {
    $baseMarker = "quirewire.m4.base.$([guid]::NewGuid())"
    $baseName = "QuireWire-M4-Base-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
    $baseFolder = Join-Path $OutputDirectory 'base-vm'
    $baseViso = Join-Path $OutputDirectory 'quirewire-m4-base-installer.viso'
    $disk = Join-Path $baseFolder 'quirewire-m4-base.vdi'
    [IO.Directory]::CreateDirectory($baseFolder) | Out-Null
    New-BaseViso -IsoPath $DebianIsoPath -PublicKeyPath $SshPublicKeyPath -Destination $baseViso
    $baseVm = New-MinimalVm -Name $baseName -Marker $baseMarker -MachineFolder $baseFolder -DiskPath $disk -InstallViso $baseViso
    try {
        Invoke-VBox -Arguments @('startvm', $baseVm, '--type', 'headless') | Out-Null
        Wait-VmPowerOff -Vm $baseVm -TimeoutMinutes $BuildTimeoutMinutes
        Assert-BuildOwnership -Vm $baseVm -Marker $baseMarker
        Invoke-VBox -Arguments @('storageattach', $baseVm, '--storagectl', 'SATA Controller', '--port', '1', '--device', '0', '--type', 'dvddrive', '--medium', 'none') | Out-Null
        Invoke-VBox -Arguments @('modifyvm', $baseVm, '--memory', "$RuntimeMemoryMiB", '--boot1', 'disk', '--boot2', 'none', '--boot3', 'none', '--boot4', 'none') | Out-Null
        Invoke-VBox -Arguments @('export', $baseVm, "--output=$baseOva", '--ovf20', '--manifest', '--options=nomacs', '--vsys=0', '--product=QuireWire Base Appliance', '--vendor=QuireWire', '--version=m4') | Out-Null
        $builtBaseHere = $true
    }
    finally {
        if (-not $KeepBuildVms -and $baseVm) {
            Remove-OwnedBuildVm -Vm $baseVm -Marker $baseMarker
        }
    }
}

if ($Stage -in @('All', 'Configured')) {
    if (-not (Test-Path -LiteralPath $baseOva -PathType Leaf)) {
        throw "Base OVA is missing: $baseOva"
    }
    if (-not $BrotherPatchPath -or -not $BrotherDriverPath) {
        throw 'Configured stage requires -BrotherPatchPath and -BrotherDriverPath owner-provided inputs.'
    }
    Assert-FileHash -Path $BrotherPatchPath -Expected $driverManifest.PATCH_SHA256 -Label 'Brother legacy USB patch'
    Assert-FileHash -Path $BrotherDriverPath -Expected $driverManifest.DRIVER_SHA256 -Label 'Brother DCP-L2600D driver'
    New-DriverViso -PatchPath $BrotherPatchPath -DriverPath $BrotherDriverPath -Destination $driverViso

    $configuredMarker = "quirewire.m4.configured.$([guid]::NewGuid())"
    $configuredName = "QuireWire-M4-Configured-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
    $configuredFolder = Join-Path $OutputDirectory 'configured-vm'
    [IO.Directory]::CreateDirectory($configuredFolder) | Out-Null
    Invoke-VBox -Arguments @('import', $baseOva, '--options=importtovdi', '--vsys=0', "--vmname=$configuredName", "--basefolder=$configuredFolder", "--memory=$RuntimeMemoryMiB", '--cpus=1') | Out-Null
    $configuredVm = Get-VmProperty -Vm $configuredName -Property 'UUID'
    Set-BuildOwnership -Vm $configuredVm -Marker $configuredMarker
    try {
        Invoke-VBox -Arguments @('modifyvm', $configuredVm, '--nic1', 'nat', '--audio-enabled', 'off', '--clipboard-mode', 'disabled', '--drag-and-drop', 'disabled', '--usb-ohci', 'on', '--usb-ehci', 'off', '--usb-xhci', 'off', '--boot1', 'disk', '--boot2', 'dvd', '--boot3', 'none', '--boot4', 'none') | Out-Null
        Invoke-VBox -Arguments @('storageattach', $configuredVm, '--storagectl', 'SATA Controller', '--port', '1', '--device', '0', '--type', 'dvddrive', '--medium', $driverViso) | Out-Null
        $usb = Get-ExactBrotherUsb
        Add-ExactUsbFilter -Vm $configuredVm -Usb $usb
        Invoke-VBox -Arguments @('startvm', $configuredVm, '--type', 'headless') | Out-Null
        Wait-VmPowerOff -Vm $configuredVm -TimeoutMinutes 15
        Assert-BuildOwnership -Vm $configuredVm -Marker $configuredMarker
        Invoke-VBox -Arguments @('storageattach', $configuredVm, '--storagectl', 'SATA Controller', '--port', '1', '--device', '0', '--type', 'dvddrive', '--medium', 'none') | Out-Null
        Invoke-VBox -Arguments @('export', $configuredVm, "--output=$configuredOva", '--ovf20', '--manifest', '--options=nomacs', '--vsys=0', '--product=QuireWire DCP-L2600D Appliance (owner-local)', '--vendor=QuireWire', '--version=m4') | Out-Null
    }
    finally {
        if (-not $KeepBuildVms -and $configuredVm) {
            Remove-OwnedBuildVm -Vm $configuredVm -Marker $configuredMarker
        }
    }
}

$result = [ordered]@{
    schema = 'quirewire.m4.build-result.v1'
    virtualbox_version = $version
    build_memory_mib = $BuildMemoryMiB
    runtime_memory_mib = $RuntimeMemoryMiB
    disk_mib = $DiskMiB
    debian_iso_sha256 = $debianManifest.DEBIAN_ISO_SHA256
    driver_media = if (Test-Path -LiteralPath $driverViso) { $driverViso } else { $null }
    brother_patch_sha256 = if (Test-Path -LiteralPath $driverViso) { $driverManifest.PATCH_SHA256 } else { $null }
    brother_driver_sha256 = if (Test-Path -LiteralPath $driverViso) { $driverManifest.DRIVER_SHA256 } else { $null }
    base_ova = if (Test-Path -LiteralPath $baseOva) { $baseOva } else { $null }
    base_ova_sha256 = if (Test-Path -LiteralPath $baseOva) { (Get-FileHash -LiteralPath $baseOva -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
    configured_ova = if (Test-Path -LiteralPath $configuredOva) { $configuredOva } else { $null }
    configured_ova_sha256 = if (Test-Path -LiteralPath $configuredOva) { (Get-FileHash -LiteralPath $configuredOva -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
    configured_redistribution = if (Test-Path -LiteralPath $configuredOva) { 'owner-local-only-pending-license-review' } else { $null }
    built_base_in_this_run = $builtBaseHere
}
$resultPath = Join-Path $OutputDirectory 'build-result.json'
$result | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
$result | Format-List
Write-Host "M4 build result: $resultPath"
