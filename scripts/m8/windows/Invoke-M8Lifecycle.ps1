[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Install', 'Repair', 'PrepareUpgrade', 'Status', 'Uninstall',
        'InstallQueueElevated', 'RemoveQueueElevated', 'InstallLanElevated', 'RemoveLanElevated')]
    [string]$Action,

    [Parameter(Mandatory)]
    [string]$InstallRoot,

    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'QuireWire'),
    [string]$QueueResultPath,
    [string]$VBoxManage = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$schema = 'quirewire.m8.installation.v1'
$scriptPath = $MyInvocation.MyCommand.Path
$taskPath = '\QuireWire\'
$taskName = 'Agent'
$configPath = Join-Path $DataRoot 'm6.conf'
$manifestPath = Join-Path $DataRoot 'installation.json'
$printerStatePath = Join-Path $DataRoot 'm5-windows-printer.json'
$agentPath = Join-Path $InstallRoot 'bin\quirewire-agent.exe'
$cliPath = Join-Path $InstallRoot 'bin\quirewirectl.exe'
$startupScript = Join-Path $InstallRoot 'scripts\m6\windows\Invoke-M6Startup.ps1'
$printerScript = Join-Path $InstallRoot 'scripts\m5\windows\Invoke-M5WindowsPrinting.ps1'
$lanScript = Join-Path $InstallRoot 'scripts\m10\windows\Invoke-M10LanSharing.ps1'
$lanApprovalScript = Join-Path $InstallRoot 'scripts\m10\windows\Set-M10LanApproval.ps1'
$lanIppProbe = Join-Path $InstallRoot 'scripts\m10\windows\Test-M10LanIpp.ps1'
$scanProbe = Join-Path $InstallRoot 'scripts\m11\windows\Test-M11Escl.ps1'
$scanApprovalScript = Join-Path $InstallRoot 'scripts\m11\windows\Set-M11ScanApproval.ps1'
$nativeProgramFiles = [Environment]::GetEnvironmentVariable('ProgramW6432')
if ([string]::IsNullOrWhiteSpace($nativeProgramFiles)) {
    $nativeProgramFiles = [Environment]::GetEnvironmentVariable('ProgramFiles')
}
if ([string]::IsNullOrWhiteSpace($VBoxManage)) {
    $VBoxManage = Join-Path $nativeProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
}
$vboxHeadless = Join-Path $nativeProgramFiles 'Oracle\VirtualBox\VBoxHeadless.exe'
$ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

function Get-FullPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOfAny([char[]]"`r`n") -ge 0) {
        throw 'Lifecycle paths must be non-empty single-line values.'
    }
    [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
}

$InstallRoot = Get-FullPath $InstallRoot
$DataRoot = Get-FullPath $DataRoot
$configPath = Join-Path $DataRoot 'm6.conf'
$manifestPath = Join-Path $DataRoot 'installation.json'
$printerStatePath = Join-Path $DataRoot 'm5-windows-printer.json'
$agentPath = Join-Path $InstallRoot 'bin\quirewire-agent.exe'
$cliPath = Join-Path $InstallRoot 'bin\quirewirectl.exe'
$startupScript = Join-Path $InstallRoot 'scripts\m6\windows\Invoke-M6Startup.ps1'
$printerScript = Join-Path $InstallRoot 'scripts\m5\windows\Invoke-M5WindowsPrinting.ps1'
$lanScript = Join-Path $InstallRoot 'scripts\m10\windows\Invoke-M10LanSharing.ps1'
$lanApprovalScript = Join-Path $InstallRoot 'scripts\m10\windows\Set-M10LanApproval.ps1'
$lanIppProbe = Join-Path $InstallRoot 'scripts\m10\windows\Test-M10LanIpp.ps1'
$scanProbe = Join-Path $InstallRoot 'scripts\m11\windows\Test-M11Escl.ps1'
$scanApprovalScript = Join-Path $InstallRoot 'scripts\m11\windows\Set-M11ScanApproval.ps1'

function Assert-ChildPath([string]$Candidate, [string]$Parent) {
    $candidatePath = Get-FullPath $Candidate
    $parentPath = (Get-FullPath $Parent) + [IO.Path]::DirectorySeparatorChar
    if (-not $candidatePath.StartsWith($parentPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing a lifecycle operation outside the exact owned root: $candidatePath"
    }
    $candidatePath
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $null }
    $values = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $configPath) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Split('=', 2)
        if ($parts.Count -ne 2 -or $values.Contains($parts[0])) {
            throw 'The QuireWire configuration is malformed or contains duplicate keys.'
        }
        $values[$parts[0]] = $parts[1]
    }
    $required = @('schema', 'owner_sid', 'vm_uuid', 'vm_marker', 'vm_schema', 'usb_vendor_id',
        'usb_product_id', 'usb_serial', 'printer_name', 'endpoint_port', 'guest_queue')
    $optional = @('scanner_port', 'lan_interface_alias', 'lan_subnet', 'lan_scan_port')
    $unknown = @($values.Keys | Where-Object { $_ -notin ($required + $optional) })
    if (@($required | Where-Object { -not $values.Contains($_) }).Count -ne 0 -or
        $unknown.Count -ne 0 -or
        $values.Contains('lan_interface_alias') -ne $values.Contains('lan_subnet')) {
        throw 'The QuireWire configuration does not match the exact supported schema.'
    }
    if ($values.schema -ne 'quirewire.m6.config.v1' -or $values.owner_sid -ne $ownerSid) {
        throw 'The QuireWire configuration is not owned by the current Windows user.'
    }
    if ($values.vm_uuid -notmatch '^[0-9a-fA-F-]{36}$' -or
        $values.printer_name -ne 'Brother via QuireWire' -or
        $values.endpoint_port -notmatch '^[0-9]{1,5}$' -or
        $values.guest_queue -notmatch '^[A-Za-z0-9._-]+$') {
        throw 'The QuireWire configuration contains an unsupported managed identity.'
    }
    if (-not $values.Contains('scanner_port')) { $values['scanner_port'] = '8645' }
    if ($values.scanner_port -notmatch '^[0-9]{1,5}$' -or
        [int]$values.scanner_port -lt 1 -or [int]$values.scanner_port -gt 65535 -or
        [int]$values.scanner_port -eq [int]$values.endpoint_port) {
        throw 'The QuireWire scanner port is invalid or conflicts with the IPP port.'
    }
    if ($values.Contains('lan_interface_alias')) {
        if ([string]::IsNullOrWhiteSpace($values.lan_interface_alias) -or
            $values.lan_interface_alias.IndexOfAny([char[]]"`r`n") -ge 0 -or
            $values.lan_subnet -notmatch '^[0-9]{1,3}(?:\.[0-9]{1,3}){3}/(?:[89]|[12][0-9]|30)$') {
            throw 'The QuireWire LAN approval is malformed.'
        }
    }
    if ($values.Contains('lan_scan_port') -and
        (-not $values.Contains('lan_interface_alias') -or
        $values.lan_scan_port -ne $values.scanner_port)) {
        throw 'The LAN scanner port requires separate approval and must match scanner_port.'
    }
    [pscustomobject]$values
}

function Test-LanApproved([object]$Config) {
    $names = @($Config.PSObject.Properties.Name)
    ('lan_interface_alias' -in $names) -and ('lan_subnet' -in $names)
}

function Read-Manifest([switch]$Required) {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        if ($Required) { throw 'The M8 ownership manifest is absent; refusing cleanup.' }
        return $null
    }
    try { $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json }
    catch { throw 'The M8 ownership manifest is unreadable; refusing cleanup.' }
    if ($manifest.schema -ne $schema -or $manifest.owner_sid -ne $ownerSid -or
        (Get-FullPath $manifest.install_root) -ne $InstallRoot -or
        (Get-FullPath $manifest.data_root) -ne $DataRoot -or
        (Get-FullPath $manifest.config_path) -ne $configPath) {
        throw 'The M8 ownership manifest does not exactly match this user and installation.'
    }
    $manifest
}

function Write-Manifest([object]$Manifest) {
    New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
    $temporary = Join-Path $DataRoot ('.installation-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding utf8
        Move-Item -LiteralPath $temporary -Destination $manifestPath -Force
        & icacls.exe $DataRoot '/inheritance:r' '/grant:r' "*$ownerSid`:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Failed to protect the QuireWire data directory ACL.' }
        & icacls.exe $manifestPath '/inheritance:r' '/grant:r' "*$ownerSid`:F" '*S-1-5-18:F' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Failed to protect the M8 ownership manifest ACL.' }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Invoke-Startup([string]$StartupAction, [string]$Executable = $agentPath) {
    if (-not (Test-Path -LiteralPath $startupScript -PathType Leaf)) {
        throw 'The packaged startup provider is missing. Repair the QuireWire installation.'
    }
    $output = @(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $startupScript -Action $StartupAction -AgentExecutable $Executable `
        -AgentConfig $configPath -OwnerSid $ownerSid 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0 -or $output -notcontains 'ok=true') {
        throw "The exact QuireWire startup task operation '$StartupAction' failed."
    }
}

function Stop-ExactAgent([string]$Executable) {
    if ([string]::IsNullOrWhiteSpace($Executable)) { return }
    $expected = Get-FullPath $Executable
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='quirewire-agent.exe'" -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        if (-not [string]::IsNullOrWhiteSpace($process.ExecutablePath) -and
            (Get-FullPath $process.ExecutablePath) -eq $expected) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        }
    }
}

function Disable-ExistingOwnedTask {
    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) { return $null }
    if (@($task.Actions).Count -ne 1 -or [string]::IsNullOrWhiteSpace($task.Actions[0].Execute)) {
        throw 'The colliding QuireWire task does not contain one exact executable action.'
    }
    $oldExecutable = [string]$task.Actions[0].Execute
    Invoke-Startup -StartupAction Status -Executable $oldExecutable
    Invoke-Startup -StartupAction Disable -Executable $oldExecutable
    Stop-ExactAgent $oldExecutable
    $oldExecutable
}

function Get-IppUrl([object]$Config) {
    "http://127.0.0.1:$($Config.endpoint_port)/printers/$($Config.guest_queue)"
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Remove-LegacyOwnedQueues {
    $getPrinter = Get-Command Get-Printer -ErrorAction SilentlyContinue
    $removePrinter = Get-Command Remove-Printer -ErrorAction SilentlyContinue
    if ($null -eq $getPrinter -or $null -eq $removePrinter) {
        throw 'Windows PrintManagement cmdlets are unavailable; legacy queue ownership cannot be verified.'
    }

    $legacyOwnedQueues = @(
        [pscustomobject]@{
            Name = 'Brother via QuireWire POC'
            Comment = 'QuireWire M0 feasibility POC - owned by Manage-M0IppPrinter.ps1'
        },
        [pscustomobject]@{
            Name = 'Brother via QuireWire M1'
            Comment = 'QuireWire M1 manual spike - owned by Manage-M1IppPrinter.ps1'
        }
    )
    $removed = @()
    foreach ($legacy in $legacyOwnedQueues) {
        $queue = Get-Printer -Name $legacy.Name -ErrorAction SilentlyContinue
        if ($null -eq $queue) { continue }

        # These immutable names and comments were written only by the M0/M1
        # feasibility scripts. Preserve every collision or modified queue, and
        # never disturb a default printer, driver, or WSD port.
        if ($queue.Comment -ne $legacy.Comment -or
            $queue.DriverName -ne 'Microsoft IPP Class Driver' -or
            $queue.PortName -notlike 'WSD-*') {
            continue
        }
        $escapedName = $legacy.Name.Replace("'", "''")
        $cimPrinter = Get-CimInstance -ClassName Win32_Printer `
            -Filter "Name='$escapedName'" -ErrorAction SilentlyContinue
        if ($null -ne $cimPrinter -and [bool]$cimPrinter.Default) { continue }

        Remove-Printer -Name $legacy.Name -ErrorAction Stop
        if ($null -ne (Get-Printer -Name $legacy.Name -ErrorAction SilentlyContinue)) {
            throw "The exact legacy QuireWire queue '$($legacy.Name)' remained after removal."
        }
        $removed += $legacy.Name
    }
    @($removed)
}

function Invoke-PrinterProvider([string]$ProviderAction, [object]$Config) {
    if (-not (Test-Path -LiteralPath $printerScript -PathType Leaf)) {
        throw 'The packaged Windows printing provider is missing; queue ownership cannot be proved.'
    }
    $output = @(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $printerScript -Action $ProviderAction -PrinterName $Config.printer_name `
        -IppUrl (Get-IppUrl $Config) -StatePath $printerStatePath 2>&1 | ForEach-Object { $_.ToString() })
    [pscustomobject]@{
        exit_code = $LASTEXITCODE
        output = @($output)
    }
}

function Assert-ProviderSuccess([object]$Result, [string]$Operation) {
    if ($Result.exit_code -ne 0 -or $Result.output -notcontains 'ok=true') {
        $detail = @($Result.output | Where-Object { $_ -match '^(error_code|error_message)=' }) -join '; '
        throw "The exact marker-owned Windows queue $Operation failed. $detail"
    }
}

function Invoke-LanProvider([string]$ProviderAction, [object]$Config) {
    if (-not (Test-Path -LiteralPath $lanScript -PathType Leaf)) {
        throw 'The packaged M10 LAN provider is missing.'
    }
    $providerArguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $lanScript, '-Action', $ProviderAction, '-OwnerToken', $Config.vm_uuid,
        '-IppPort', $Config.endpoint_port, '-AgentExecutable', $agentPath,
        '-VBoxHeadlessExecutable', $vboxHeadless
    )
    if ('lan_scan_port' -in @($Config.PSObject.Properties.Name)) {
        $providerArguments += @('-ScanPort', $Config.lan_scan_port)
    }
    if (Test-LanApproved $Config) {
        $providerArguments += @(
            '-ApprovedInterfaceAlias', $Config.lan_interface_alias,
            '-ApprovedSubnet', $Config.lan_subnet
        )
    }
    $output = @(& powershell.exe @providerArguments 2>&1 | ForEach-Object { $_.ToString() })
    [pscustomobject]@{ exit_code = $LASTEXITCODE; output = @($output) }
}

function Invoke-ElevatedLanOperation([ValidateSet('InstallLanElevated', 'RemoveLanElevated')][string]$ElevatedAction) {
    New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
    $resultPath = Join-Path $DataRoot ('.lan-operation-' + [Guid]::NewGuid().ToString('N') + '.json')
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $scriptPath), '-Action', $ElevatedAction,
        '-InstallRoot', ('"{0}"' -f $InstallRoot), '-DataRoot', ('"{0}"' -f $DataRoot),
        '-QueueResultPath', ('"{0}"' -f $resultPath), '-VBoxManage', ('"{0}"' -f $VBoxManage)
    )
    try {
        $process = Start-Process -FilePath $powershellPath -ArgumentList $arguments -Verb RunAs `
            -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw 'The one-time scoped LAN firewall operation was declined or failed.'
        }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if ($process.ExitCode -ne 0 -or $result.exit_code -ne 0 -or
            $result.output -notcontains 'ok=true' -or
            ($ElevatedAction -eq 'InstallLanElevated' -and $result.output -notcontains 'firewall_ready=true')) {
            throw 'The exact approved-interface/subnet firewall operation failed.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
            Remove-Item -LiteralPath $resultPath -Force
        }
    }
}

function Invoke-ElevatedQueueOperation([string]$ElevatedAction, [object]$Config) {
    if ($ElevatedAction -notin @('InstallQueueElevated', 'RemoveQueueElevated')) {
        throw 'Internal queue elevation action is unsupported.'
    }
    New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
    $resultPath = Join-Path $DataRoot ('.queue-operation-' + [Guid]::NewGuid().ToString('N') + '.json')
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $scriptPath),
        '-Action', $ElevatedAction,
        '-InstallRoot', ('"{0}"' -f $InstallRoot),
        '-DataRoot', ('"{0}"' -f $DataRoot),
        '-QueueResultPath', ('"{0}"' -f $resultPath),
        '-VBoxManage', ('"{0}"' -f $VBoxManage)
    )
    try {
        $process = Start-Process -FilePath $powershellPath -ArgumentList $arguments -Verb RunAs `
            -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw 'The one-time Windows printer operation was declined or failed.'
        }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        Assert-ProviderSuccess -Result $result -Operation $ElevatedAction
        if ($process.ExitCode -ne 0) {
            throw 'The one-time Windows printer operation returned a failure exit code.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
            Remove-Item -LiteralPath $resultPath -Force
        }
    }
}

function Invoke-OwnedQueue([ValidateSet('Install', 'Remove')][string]$QueueAction, [object]$Config) {
    $status = Invoke-PrinterProvider -ProviderAction Status -Config $Config
    Assert-ProviderSuccess -Result $status -Operation 'status check'
    $queueFound = $status.output -contains 'queue_found=true'
    $ownershipVerified = $status.output -contains 'ownership_verified=true'
    if ($queueFound -and -not $ownershipVerified) {
        throw 'The configured queue name exists without the exact QuireWire ownership record; it was not changed.'
    }
    if (($QueueAction -eq 'Install' -and $ownershipVerified) -or
        ($QueueAction -eq 'Remove' -and -not $queueFound)) {
        return
    }

    if (Test-IsAdministrator) {
        $result = Invoke-PrinterProvider -ProviderAction $QueueAction -Config $Config
        Assert-ProviderSuccess -Result $result -Operation $QueueAction
        return
    }

    $elevatedAction = if ($QueueAction -eq 'Install') { 'InstallQueueElevated' } else { 'RemoveQueueElevated' }
    Invoke-ElevatedQueueOperation -ElevatedAction $elevatedAction -Config $Config
}

function Invoke-VBox([string[]]$Arguments) {
    $output = @(& $VBoxManage @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw 'VBoxManage failed during an exact M8 ownership operation.' }
    $output
}

function Get-VBoxExtraData([string]$Vm, [string]$Key) {
    $line = Invoke-VBox @('getextradata', $Vm, $Key) | Select-Object -First 1
    if ($line -notmatch '^Value:\s*(.+)$') { throw "The owned VM is missing $Key." }
    $Matches[1].Trim()
}

function Remove-InstallationOwnedVm([object]$Vm) {
    if ($Vm.disposition -ne 'installation-owned') { return }
    if (-not (Test-Path -LiteralPath $VBoxManage -PathType Leaf)) {
        throw 'VirtualBox is unavailable; refusing to leave an installation-owned VM untracked.'
    }
    $schemaValue = Get-VBoxExtraData $Vm.uuid 'QuireWire/Schema'
    $markerValue = Get-VBoxExtraData $Vm.uuid 'QuireWire/Owner'
    if ($schemaValue -ne $Vm.schema -or $markerValue -ne $Vm.marker) {
        throw 'The live VM no longer matches the M8 manifest; refusing deletion.'
    }
    $state = (Invoke-VBox @('showvminfo', $Vm.uuid, '--machinereadable') | Where-Object { $_ -match '^VMState=' }) -join ''
    if ($state -ne 'VMState="poweroff"') {
        Invoke-VBox @('controlvm', $Vm.uuid, 'acpipowerbutton') | Out-Null
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        do {
            Start-Sleep -Seconds 2
            $state = (Invoke-VBox @('showvminfo', $Vm.uuid, '--machinereadable') | Where-Object { $_ -match '^VMState=' }) -join ''
        } while ($state -ne 'VMState="poweroff"' -and [DateTime]::UtcNow -lt $deadline)
        if ($state -ne 'VMState="poweroff"') { Invoke-VBox @('controlvm', $Vm.uuid, 'poweroff') | Out-Null }
    }
    Invoke-VBox @('unregistervm', $Vm.uuid, '--delete') | Out-Null
}

function New-InstallationManifest([object]$Config, [object]$Previous) {
    $installationId = if ($Previous) { $Previous.installation_id } else { [Guid]::NewGuid().ToString('D') }
    $vm = if ($Config) {
        [ordered]@{
            uuid = $Config.vm_uuid
            schema = $Config.vm_schema
            marker = $Config.vm_marker
            disposition = 'preexisting-owned-resource-preserved'
        }
    } else { $null }
    [ordered]@{
        schema = $schema
        version = '0.1.0'
        installation_id = $installationId
        installed_utc = [DateTime]::UtcNow.ToString('o')
        owner_sid = $ownerSid
        install_root = $InstallRoot
        data_root = $DataRoot
        config_path = $configPath
        configuration_present = [bool]$Config
        agent_path = $agentPath
        cli_path = $cliPath
        startup = [ordered]@{ task_path = $taskPath; task_name = $taskName }
        queue = if ($Config) {
            [ordered]@{ name = $Config.printer_name; ipp_url = Get-IppUrl $Config; state_path = $printerStatePath }
        } else { $null }
        vm = $vm
        owned_data = @($manifestPath, $configPath, $printerStatePath,
            (Join-Path $DataRoot 'state'), (Join-Path $DataRoot 'logs'))
    }
}

function Remove-OwnedData([object]$Manifest) {
    $recursive = @((Join-Path $DataRoot 'state'), (Join-Path $DataRoot 'logs'))
    foreach ($path in $recursive) {
        $verified = Assert-ChildPath $path $DataRoot
        if (Test-Path -LiteralPath $verified) { Remove-Item -LiteralPath $verified -Recurse -Force }
    }
    foreach ($path in @($printerStatePath, $configPath, $manifestPath)) {
        $verified = Assert-ChildPath $path $DataRoot
        if (Test-Path -LiteralPath $verified -PathType Leaf) { Remove-Item -LiteralPath $verified -Force }
    }
    if ((Test-Path -LiteralPath $DataRoot -PathType Container) -and
        @(Get-ChildItem -LiteralPath $DataRoot -Force).Count -eq 0) {
        Remove-Item -LiteralPath $DataRoot -Force
    }
}

try {
switch ($Action) {
    'InstallLanElevated' {
        if (-not (Test-IsAdministrator)) { throw 'The scoped LAN helper requires elevation.' }
        $verifiedResultPath = Assert-ChildPath $QueueResultPath $DataRoot
        $config = Read-Config
        if (-not $config) { throw 'The scoped LAN helper needs the protected configuration.' }
        $result = Invoke-LanProvider -ProviderAction InstallFirewall -Config $config
        $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $verifiedResultPath -Encoding utf8
        if ($result.exit_code -ne 0 -or $result.output -notcontains 'ok=true') { exit 1 }
        exit 0
    }
    'RemoveLanElevated' {
        if (-not (Test-IsAdministrator)) { throw 'The scoped LAN helper requires elevation.' }
        $verifiedResultPath = Assert-ChildPath $QueueResultPath $DataRoot
        $config = Read-Config
        if (-not $config) { throw 'The scoped LAN helper needs the protected configuration.' }
        $result = Invoke-LanProvider -ProviderAction RemoveFirewall -Config $config
        $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $verifiedResultPath -Encoding utf8
        if ($result.exit_code -ne 0 -or $result.output -notcontains 'ok=true') { exit 1 }
        exit 0
    }
    'InstallQueueElevated' {
        if (-not (Test-IsAdministrator)) { throw 'The scoped printer helper requires an elevated Windows token.' }
        $verifiedResultPath = Assert-ChildPath $QueueResultPath $DataRoot
        $config = Read-Config
        if (-not $config) { throw 'The scoped printer helper needs the protected QuireWire configuration.' }
        $result = Invoke-PrinterProvider -ProviderAction Install -Config $config
        $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $verifiedResultPath -Encoding utf8
        if ($result.exit_code -ne 0 -or $result.output -notcontains 'ok=true') { exit 1 }
        exit 0
    }
    'RemoveQueueElevated' {
        if (-not (Test-IsAdministrator)) { throw 'The scoped printer helper requires an elevated Windows token.' }
        $verifiedResultPath = Assert-ChildPath $QueueResultPath $DataRoot
        $config = Read-Config
        if (-not $config) { throw 'The scoped printer helper needs the protected QuireWire configuration.' }
        $result = Invoke-PrinterProvider -ProviderAction Remove -Config $config
        $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $verifiedResultPath -Encoding utf8
        if ($result.exit_code -ne 0 -or $result.output -notcontains 'ok=true') { exit 1 }
        exit 0
    }
    'PrepareUpgrade' {
        $manifest = Read-Manifest -Required
        $null = Disable-ExistingOwnedTask
        Stop-ExactAgent $manifest.agent_path
        [pscustomobject]@{ schema = $schema; action = $Action; ready = $true } | ConvertTo-Json
    }
    'Install' {
        foreach ($required in @($agentPath, $cliPath, $startupScript, $printerScript,
                $lanScript, $lanApprovalScript, $lanIppProbe, $scanProbe, $scanApprovalScript)) {
            if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
                throw "The installer did not place required resource: $required"
            }
        }
        $config = Read-Config
        $previous = Read-Manifest
        if ($config) {
            $null = Disable-ExistingOwnedTask
            Invoke-OwnedQueue -QueueAction Install -Config $config
            $legacyQueuesRemoved = @(Remove-LegacyOwnedQueues)
            if (Test-LanApproved $config) {
                Invoke-ElevatedLanOperation -ElevatedAction InstallLanElevated
            }
        }
        else { $legacyQueuesRemoved = @() }
        $manifest = New-InstallationManifest -Config $config -Previous $previous
        Write-Manifest $manifest
        [pscustomobject]@{
            schema = $schema
            action = $Action
            configured = [bool]$config
            persistent_agent_elevated = $false
            network_required_for_quirewire = $false
            owner_appliance_required = -not [bool]$config
            legacy_queues_removed = @($legacyQueuesRemoved)
        } | ConvertTo-Json
    }
    'Repair' {
        $manifest = Read-Manifest -Required
        $config = Read-Config
        if (-not $config) { throw 'Repair needs an owner-created appliance configuration; see the packaged install guide.' }
        $null = Disable-ExistingOwnedTask
        Invoke-OwnedQueue -QueueAction Install -Config $config
        $legacyQueuesRemoved = @(Remove-LegacyOwnedQueues)
        if (Test-LanApproved $config) {
            Invoke-ElevatedLanOperation -ElevatedAction InstallLanElevated
        }
        Write-Manifest (New-InstallationManifest -Config $config -Previous $manifest)
        [pscustomobject]@{
            schema = $schema
            action = $Action
            repaired = $true
            legacy_queues_removed = @($legacyQueuesRemoved)
        } | ConvertTo-Json
    }
    'Status' {
        $manifest = Read-Manifest
        $config = Read-Config
        $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
        [pscustomobject]@{
            schema = $schema
            action = $Action
            installed = [bool]$manifest
            configured = [bool]$config
            startup_task_present = [bool]$task
            agent_present = Test-Path -LiteralPath $agentPath -PathType Leaf
            cli_present = Test-Path -LiteralPath $cliPath -PathType Leaf
            manifest_path = $manifestPath
        } | ConvertTo-Json
    }
    'Uninstall' {
        $manifest = Read-Manifest -Required
        $config = Read-Config
        $null = Disable-ExistingOwnedTask
        Stop-ExactAgent $manifest.agent_path
        if ($config) {
            Invoke-OwnedQueue -QueueAction Remove -Config $config
            Invoke-ElevatedLanOperation -ElevatedAction RemoveLanElevated
        }
        $legacyQueuesRemoved = @(Remove-LegacyOwnedQueues)
        if ($manifest.vm) { Remove-InstallationOwnedVm $manifest.vm }
        Remove-OwnedData $manifest
        [pscustomobject]@{
            schema = $schema
            action = $Action
            startup_task_removed = $true
            owned_queue_removed = [bool]$config
            legacy_queues_removed = @($legacyQueuesRemoved)
            installation_owned_vm_removed = [bool]($manifest.vm -and $manifest.vm.disposition -eq 'installation-owned')
            unrelated_resources_preserved = $true
        } | ConvertTo-Json
    }
}
}
catch {
    $lifecycleError = $_
    try {
        $logDirectory = Join-Path $DataRoot 'logs'
        New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
        $record = '{0} action={1} error={2}' -f [DateTime]::UtcNow.ToString('o'), $Action,
            ($lifecycleError.Exception.Message -replace '[\r\n]+', ' ')
        Add-Content -LiteralPath (Join-Path $logDirectory 'installer-lifecycle-errors.log') `
            -Value $record -Encoding utf8
    }
    catch {
        # Preserve the original lifecycle exception even if owner-local logging fails.
    }
    Write-Error -ErrorRecord $lifecycleError
    exit 1
}
