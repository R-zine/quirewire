[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Baseline', 'Installed', 'Repaired', 'Uninstalled', 'Reinstalled')]
    [string]$Phase,
    [string]$OutputDirectory,
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'PrintBridge'),
    [string]$VBoxManage = (Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path 'artifacts\m8\diagnostics'
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$task = Get-ScheduledTask -TaskPath '\PrintBridge\' -TaskName 'Agent' -ErrorAction SilentlyContinue
$defaultNames = @(Get-CimInstance Win32_Printer -ErrorAction Stop | Where-Object { [bool]$_.Default } | ForEach-Object { $_.Name })
$printers = @(Get-Printer -ErrorAction Stop | Sort-Object Name | ForEach-Object {
    [ordered]@{ name = $_.Name; driver = $_.DriverName; port = $_.PortName; comment = $_.Comment; is_default = $_.Name -in $defaultNames }
})
$vms = @()
if (Test-Path -LiteralPath $VBoxManage -PathType Leaf) {
    foreach ($line in @(& $VBoxManage list vms 2>$null)) {
        if ($line -match '^"(.*)"\s+\{([0-9a-fA-F-]{36})\}$') {
            $vms += [ordered]@{ name = $Matches[1]; uuid = $Matches[2].ToLowerInvariant() }
        }
    }
}
$manifestPath = Join-Path $DataRoot 'installation.json'
$appPath = Join-Path $DataRoot 'printbridge-desktop.exe'
$uninstallerPath = Join-Path $DataRoot 'uninstall.exe'
$manifest = $null
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $source = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $manifest = [ordered]@{
        schema = $source.schema
        installation_id = $source.installation_id
        owner_sid = $source.owner_sid
        install_root = $source.install_root
        configuration_present = [bool]$source.configuration_present
        vm_uuid = if ($source.vm) { $source.vm.uuid } else { $null }
        vm_disposition = if ($source.vm) { $source.vm.disposition } else { $null }
    }
}

$record = [ordered]@{
    schema = 'printbridge.m8.diagnostics.v1'
    captured_utc = [DateTime]::UtcNow.ToString('o')
    phase = $Phase
    owner_sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    task = if ($task) {
        [ordered]@{
            present = $true
            path = $task.TaskPath
            name = $task.TaskName
            description = $task.Description
            user_id = $task.Principal.UserId
            run_level = [string]$task.Principal.RunLevel
            execute = if (@($task.Actions).Count -eq 1) { $task.Actions[0].Execute } else { $null }
            arguments = if (@($task.Actions).Count -eq 1) { $task.Actions[0].Arguments } else { $null }
        }
    } else { [ordered]@{ present = $false } }
    printers = $printers
    virtual_machines = $vms
    manifest_present = Test-Path -LiteralPath $manifestPath -PathType Leaf
    manifest = $manifest
    config_present = Test-Path -LiteralPath (Join-Path $DataRoot 'm6.conf') -PathType Leaf
    printer_state_present = Test-Path -LiteralPath (Join-Path $DataRoot 'm5-windows-printer.json') -PathType Leaf
    state_directory_present = Test-Path -LiteralPath (Join-Path $DataRoot 'state') -PathType Container
    log_directory_present = Test-Path -LiteralPath (Join-Path $DataRoot 'logs') -PathType Container
    app_executable_present = Test-Path -LiteralPath $appPath -PathType Leaf
    uninstaller_present = Test-Path -LiteralPath $uninstallerPath -PathType Leaf
    uninstall_registration_present = Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PrintBridge'
}

$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$path = Join-Path $OutputDirectory "$stamp-$($Phase.ToLowerInvariant()).json"
$record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8
[pscustomobject]@{ schema = 'printbridge.m8.diagnostics-result.v1'; path = $path; phase = $Phase } | ConvertTo-Json
