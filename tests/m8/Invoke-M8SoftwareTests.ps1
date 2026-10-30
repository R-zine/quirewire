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

$scripts = @(
    'scripts\m8\windows\Build-M8Installer.ps1',
    'scripts\m8\windows\Collect-M8Diagnostics.ps1',
    'scripts\m8\windows\Invoke-M8Lifecycle.ps1',
    'scripts\m8\windows\Record-M8Acceptance.ps1',
    'scripts\m8\windows\Test-M8Prerequisites.ps1',
    'scripts\m8\windows\Trace-M8ProcessStarts.ps1'
)
foreach ($relative in $scripts) {
    Check "PowerShell syntax: $relative" {
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repositoryRoot $relative), [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count -eq 0
    }
}

$configPath = Join-Path $repositoryRoot 'apps\desktop\src-tauri\tauri.m8.conf.json'
$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
$configText = Get-Content -Raw -LiteralPath $configPath
$hooks = Get-Content -Raw (Join-Path $repositoryRoot 'apps\desktop\src-tauri\windows\hooks.nsh')
$lifecycle = Get-Content -Raw (Join-Path $repositoryRoot 'scripts\m8\windows\Invoke-M8Lifecycle.ps1')
$prerequisites = Get-Content -Raw (Join-Path $repositoryRoot 'scripts\m8\windows\Test-M8Prerequisites.ps1')
$builder = Get-Content -Raw (Join-Path $repositoryRoot 'scripts\m8\windows\Build-M8Installer.ps1')
$provider = Get-Content -Raw (Join-Path $repositoryRoot 'crates\provider-windows\src\lib.rs')
$windowsRunner = Get-Content -Raw (Join-Path $repositoryRoot 'crates\provider-windows\src\runner.rs')
$virtualBoxRunner = Get-Content -Raw (Join-Path $repositoryRoot 'crates\provider-virtualbox\src\runner.rs')
$agentMain = Get-Content -Raw (Join-Path $repositoryRoot 'crates\agent\src\main.rs')
$processTracer = Get-Content -Raw (Join-Path $repositoryRoot 'scripts\m8\windows\Trace-M8ProcessStarts.ps1')
$licensing = Get-Content -Raw (Join-Path $repositoryRoot 'docs\licensing.md')
$installGuide = Get-Content -Raw (Join-Path $repositoryRoot 'docs\install.md')

Check 'NSIS packaging is active and scoped to NSIS' {
    $config.bundle.active -and @($config.bundle.targets).Count -eq 1 -and $config.bundle.targets[0] -eq 'nsis'
}
Check 'installer is current-user and never persistently elevated' {
    $config.bundle.windows.nsis.installMode -eq 'currentUser' -and
        $hooks -notmatch '(?i)RequestExecutionLevel\s+admin' -and
        $lifecycle -match 'persistent_agent_elevated\s*=\s*\$false'
}
Check 'printer elevation is one-time and scoped to the owned queue' {
    $lifecycle -match 'InstallQueueElevated' -and $lifecycle -match 'RemoveQueueElevated' -and
        $lifecycle -match 'Test-IsAdministrator' -and $lifecycle -match '-Verb RunAs' -and
        $lifecycle -match '-WindowStyle Hidden' -and
        $lifecycle -match 'Invoke-OwnedQueue -QueueAction Install' -and
        $lifecycle -match 'Invoke-OwnedQueue -QueueAction Remove' -and
        $lifecycle -notmatch '(?i)RunLevel\s+Highest'
}
Check 'offline Windows 11 WebView mode is explicit' {
    $config.bundle.windows.webviewInstallMode.type -eq 'skip' -and $prerequisites -match 'WebView2 Runtime is required'
}
Check 'agent CLI and fixed provider scripts are packaged' {
    $configText -match 'printbridge-agent\.exe' -and $configText -match 'printbridgectl\.exe' -and
        $configText -match 'Invoke-M5WindowsPrinting\.ps1' -and $configText -match 'Invoke-M6Startup\.ps1'
}
Check 'VirtualBox and vendor binaries are not bundled' {
    $configText -notmatch '(?i)VirtualBox-[0-9].*\.exe' -and
        $configText -notmatch '(?i)dcpl2600dpdrv.*\.(deb|rpm)' -and
        $configText -notmatch '(?i)brotherlegacyusb.*\.deb' -and
        $configText -notmatch '(?i)\.ova"'
}
Check 'provider resolves installed resources before source fallback' {
    $provider -match 'PRINTBRIDGE_RESOURCE_ROOT' -and $provider -match 'current_exe' -and
        $provider -match 'ancestors\(\)\.take\(4\)'
}
Check 'release agent and background providers cannot flash consoles' {
    $agentMain -match 'windows_subsystem = "windows"' -and
        $windowsRunner -match 'CREATE_NO_WINDOW' -and $windowsRunner -match 'creation_flags' -and
        $virtualBoxRunner -match 'CREATE_NO_WINDOW' -and $virtualBoxRunner -match 'creation_flags'
}
Check 'process tracer omits command lines and window titles' {
    $processTracer -notmatch '(?i)CommandLine|MainWindowTitle|window_title'
}
Check 'installer hooks cover upgrade install and uninstall' {
    $hooks -match 'NSIS_HOOK_PREINSTALL' -and $hooks -match 'PrepareUpgrade' -and
        $hooks -match 'NSIS_HOOK_POSTINSTALL' -and $hooks -match 'NSIS_HOOK_PREUNINSTALL'
}
Check 'hook aborts lifecycle failures' { $hooks -match 'Abort' -and $hooks -match 'No unowned printer' }
Check 'manifest binds SID and exact roots' {
    $lifecycle -match 'printbridge\.m8\.installation\.v1' -and
        $lifecycle -match 'manifest\.owner_sid -ne \$ownerSid' -and
        $lifecycle -match 'manifest\.install_root' -and $lifecycle -match 'manifest\.data_root'
}
Check 'startup remains limited interactive through packaged provider' {
    $startup = Get-Content -Raw (Join-Path $repositoryRoot 'scripts\m6\windows\Invoke-M6Startup.ps1')
    $startup -match 'LogonType Interactive' -and $startup -match 'RunLevel Limited' -and
        $startup -match 'colliding Task Scheduler entry'
}
Check 'queue cleanup uses marker-owning provider only' {
    $lifecycle -match '-ProviderAction Remove' -and $lifecycle -match 'm5-windows-printer\.json' -and
        $lifecycle -notmatch 'Remove-PrinterDriver' -and $lifecycle -notmatch 'Remove-PrinterPort'
}
Check 'VM deletion requires manifest disposition and live extradata' {
    $lifecycle -match "disposition -ne 'installation-owned'" -and
        $lifecycle -match 'Get-VBoxExtraData \$Vm\.uuid ''PrintBridge/Schema''' -and
        $lifecycle -match 'Get-VBoxExtraData \$Vm\.uuid ''PrintBridge/Owner''' -and
        $lifecycle -match '''unregistervm'', \$Vm\.uuid, ''--delete'''
}
Check 'recursive cleanup is bounded below DataRoot' {
    $lifecycle -match 'Assert-ChildPath' -and $lifecycle -notmatch '(?i)Remove-Item\s+[^\r\n]*(\$env:LOCALAPPDATA|~|\$HOME)\s+-Recurse'
}
Check 'migrated appliance is explicitly preserved' {
    $lifecycle -match "disposition = 'preexisting-owned-resource-preserved'"
}
Check 'upgrades retain installation identifier and config' {
    $lifecycle -match 'Previous\.installation_id' -and $lifecycle -match 'Read-Config' -and
        $installGuide -match 'preserves configuration/desired'
}
Check 'build requires explicit signing choice' {
    $builder -match 'UnsignedDevelopmentBuild' -and $builder -match 'CertificateThumbprint' -and
        $builder -match 'mutually exclusive' -and $builder -match 'Get-AuthenticodeSignature'
}
Check 'license inventory keeps Brother artifacts owner-local' {
    $licensing -match 'Owner-local only; never bundled' -and
        $licensing -match 'Extension Pack' -and $licensing -match 'Network disclosure'
}
Check 'resource and USB consent estimates are disclosed' {
    $prerequisites -match 'required_free_disk_gib = 12' -and
        $prerequisites -match 'guest_memory_mib = 768' -and
        $prerequisites -match 'captures the entire selected USB device'
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('printbridge-m8-tests-' + [Guid]::NewGuid().ToString('N'))
try {
    $install = Join-Path $fixture 'install'
    $data = Join-Path $fixture 'data'
    New-Item -ItemType Directory -Force -Path $install, $data | Out-Null
    $statusText = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File (Join-Path $repositoryRoot 'scripts\m8\windows\Invoke-M8Lifecycle.ps1') `
        -Action Status -InstallRoot $install -DataRoot $data
    $status = $statusText | ConvertFrom-Json
    Check 'unconfigured status is read-only and truthful' {
        $status.schema -eq 'printbridge.m8.installation.v1' -and -not $status.installed -and
            -not $status.configured -and -not (Test-Path -LiteralPath (Join-Path $data 'installation.json'))
    }
}
finally {
    if (Test-Path -LiteralPath $fixture) {
        $resolved = (Resolve-Path -LiteralPath $fixture).Path
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to remove a fixture outside the temporary directory.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

Write-Host "M8 software tests: $passed passed, $failed failed"
if ($failed -ne 0) { exit 1 }
