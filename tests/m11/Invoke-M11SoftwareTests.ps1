[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$passed = 0
$failed = 0

function Check([string]$Name, [scriptblock]$Test) {
    try {
        if (-not (& $Test)) { throw 'condition returned false' }
        $script:passed++
        "PASS $Name"
    }
    catch {
        $script:failed++
        "FAIL $Name - $($_.Exception.Message)"
    }
}

function Text([string]$RelativePath) {
    Get-Content -LiteralPath (Join-Path $root $RelativePath) -Raw -Encoding utf8
}

$requiredFiles = @(
    'crates\provider-scan\Cargo.toml',
    'crates\provider-scan\src\lib.rs',
    'guest\manifests\scanner-dcpl2600d.env',
    'guest\linux\provision-scanner.sh',
    'guest\patches\airsane-brscan5-session.patch',
    'scripts\m11\linux\Repair-M11GuestDisk.sh',
    'scripts\m11\linux\Read-M11GuestJournal.sh',
    'scripts\m11\linux\Enable-M11GuestDebugClone.sh',
    'scripts\m11\windows\Set-M11ScanApproval.ps1',
    'scripts\m11\windows\Test-M11Escl.ps1',
    'docs\m11-acceptance.md',
    'docs\milestones\M11.md'
)
Check 'M11 implementation and acceptance files exist' {
    @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf) }).Count -eq 0
}

foreach ($relative in @(
    'scripts\m10\windows\Invoke-M10LanSharing.ps1',
    'scripts\m11\windows\Set-M11ScanApproval.ps1',
    'scripts\m11\windows\Test-M11Escl.ps1',
    'scripts\m8\windows\Invoke-M8Lifecycle.ps1'
)) {
    Check "PowerShell syntax: $relative" {
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $root $relative), [ref]$tokens, [ref]$errors) | Out-Null
        $errors.Count -eq 0
    }
}

foreach ($relative in @(
    'guest\linux\provision-scanner.sh',
    'scripts\m11\linux\Repair-M11GuestDisk.sh',
    'scripts\m11\linux\Read-M11GuestJournal.sh',
    'scripts\m11\linux\Enable-M11GuestDebugClone.sh'
)) {
    Check "Bash syntax: $relative" {
        $bash = 'C:\Program Files\Git\bin\bash.exe'
        if (-not (Test-Path -LiteralPath $bash)) { $bash = (Get-Command bash -ErrorAction Stop).Source }
        & $bash -n (Join-Path $root $relative)
        $LASTEXITCODE -eq 0
    }
}

$manifest = Text 'guest\manifests\scanner-dcpl2600d.env'
$provision = Text 'guest\linux\provision-scanner.sh'
$airsanePatch = Text 'guest\patches\airsane-brscan5-session.patch'
$repair = Text 'scripts\m11\linux\Repair-M11GuestDisk.sh'
$debugClone = Text 'scripts\m11\linux\Enable-M11GuestDebugClone.sh'
$scanProvider = Text 'crates\provider-scan\src\lib.rs'
$agent = Text 'crates\agent\src\m6.rs'
$ipc = Text 'crates\ipc\src\wire.rs'
$ipcVersion = Text 'crates\ipc\src\lib.rs'
$virtualbox = Text 'crates\provider-virtualbox\src\lib.rs'
$lan = Text 'crates\provider-lan\src\lib.rs'
$firewall = Text 'scripts\m10\windows\Invoke-M10LanSharing.ps1'
$scanApproval = Text 'scripts\m11\windows\Set-M11ScanApproval.ps1'
$desktop = Text 'apps\desktop\src\App.tsx'
$desktopHost = Text 'apps\desktop\src-tauri\src\lib.rs'
$lifecycle = Text 'scripts\m8\windows\Invoke-M8Lifecycle.ps1'
$bundle = Text 'apps\desktop\src-tauri\tauri.m8.conf.json'
$spec = Text 'SPEC.md'

Check 'exact owner-local Brother brscan5 input is pinned and never bundled' {
    $manifest -match 'BRSCAN_VERSION=1\.7\.0-0' -and
    $manifest -match 'BRSCAN_SHA256=9c3a200d' -and
    $manifest -match 'BRSCAN_REDISTRIBUTION=owner-local-only' -and
    $bundle -notmatch 'brscan5-1\.7\.0-0\.amd64\.deb'
}
Check 'AirSane GPL source and Debian build inputs are pinned' {
    $patchHash = (Get-FileHash -Algorithm SHA256 -LiteralPath `
        (Join-Path $root 'guest\patches\airsane-brscan5-session.patch')).Hash.ToLowerInvariant()
    $manifest -match 'AIRSANE_COMMIT=08ff4d798d718e2e50ef805404ddef82f6d03cc1' -and
    $manifest -match 'AIRSANE_SHA256=300e8362' -and
    $manifest -match 'AIRSANE_LICENSE=GPL-3\.0-only' -and
    $manifest -match 'SANE_UTILS_VERSION=1\.3\.1-3\+b1' -and
    $manifest -match "AIRSANE_PATCH_SHA256=$patchHash" -and
    $manifest -match 'AIRSANE_PATCH_UPSTREAM_ISSUE=https://github\.com/SimulPiscator/AirSane/issues/132' -and
    $airsanePatch -match 'release it before accepting scan jobs' -and
    $airsanePatch -match '(?m)^\+\s*\{$' -and
    $provision -match 'patch --directory="\$source_root" --strip=1 --fuzz=0' -and
    $provision -match 'airsane_patch_sha256'
}
Check 'guest access is exact-device, unprivileged, host-discovery-only, and content-free' {
    $provision -match 'ATTR\{idVendor\}=="\$vendor_id"' -and
    $provision -match 'ATTR\{idProduct\}=="\$product_id"' -and
    $provision -match 'GROUP:="scanner"' -and
    $provision -match 'MDNS_ANNOUNCE=false' -and
    $provision -match 'allow 10\.0\.0\.0/8' -and
    $provision -match 'allow 172\.16\.0\.0/12' -and
    $provision -match 'allow 192\.168\.0\.0/16' -and
    $provision -notmatch 'allow 0\.0\.0\.0/0' -and
    $provision -match 'runuser -u saned -- scanimage -L' -and
    $provision -notmatch 'scanimage.*--format'
}
Check 'offline clone repair proves ownership and does not retain source packages' {
    $repair -match 'PRINTBRIDGE_GUEST_SCHEMA=printbridge\.m4\.guest\.v1' -and
    $repair -match 'QUEUE_NAME=PrintBridge_DCP_L2600D' -and
    $repair -match '--offline' -and
    $repair -match 'rm -rf --one-file-system "\$input"' -and
    $debugClone -match 'PRINTBRIDGE_GUEST_SCHEMA=printbridge\.m4\.guest\.v1' -and
    $debugClone -match 'QUEUE_NAME=PrintBridge_DCP_L2600D' -and
    $debugClone -match 'printbridge\.m11\.debug-clone\.v1' -and
    $debugClone -match 'airsaned-debug\.log'
}
Check 'eSCL probe is loopback-only, bounded, timeout-controlled, and rejects XML entities' {
    $scanProvider -match 'MAX_RESPONSE_BYTES: usize = 512 \* 1024' -and
    $scanProvider -match 'connect_timeout' -and
    $scanProvider -match 'address\.is_loopback' -and
    $scanProvider -match 'Event::DocType\(_\) \| Event::GeneralRef\(_\)' -and
    $scanProvider -match '/eSCL/ScannerCapabilities'
}
Check 'protocol v7 exposes capabilities without scan bytes' {
    $ipcVersion -match 'PROTOCOL_VERSION: u16 = 7' -and
    $ipc -match 'pub struct ScannerStatus' -and
    $ipc -match 'document_formats: Vec<String>' -and
    $ipc -notmatch 'scan_(?:bytes|content|image):' -and
    $agent -match 'Scan documents and image bytes never pass through agent IPC'
}
Check 'VirtualBox owns distinct loopback and LAN eSCL forwards' {
    $virtualbox -match 'printbridge-m11-escl' -and
    $virtualbox -match 'printbridge-m11-lan-escl' -and
    $virtualbox -match 'printbridge\.m11\.scan-loopback\.v1' -and
    $virtualbox -match 'printbridge\.m11\.scan-lan\.v1' -and
    $agent -match 'GUEST_SCANNER_PORT: u16 = 8090'
}
Check 'LAN scan firewall and DNS-SD require separate exact-port approval' {
    $firewall -match 'LAN eSCL' -and
    $firewall -match 'Install-ExactRule \$scanRuleName TCP \$ScanPort \$VBoxHeadlessExecutable' -and
    $scanApproval -match 'lan_scan_port=' -and
    $agent -match 'approved_scan_port' -and
    $lan -match '_uscan\._tcp\.local\.' -and
    $lan -match '"rs"\.into\(\), "eSCL"\.into\(\)' -and
    $lan -match '"vers"\.into\(\), "2\.0"\.into\(\)' -and
    $lan -match '"cs"\.into\(\)' -and
    $lan -match '"is"\.into\(\)' -and
    $lan -match '"duplex"\.into\(\)' -and
    $lan -match '"adminurl"\.into\(\)' -and
    $lan -match '"uuid"\.into\(\)'
}
Check 'desktop scan path launches only a fixed loopback URL without a console window' {
    $desktop -match 'function ScanScreen' -and
    $desktop -match 'client\.openScanner\(\)' -and
    $desktopHost -match 'http://127\.0\.0\.1:' -and
    $desktopHost -match 'creation_flags\(CREATE_NO_WINDOW\)' -and
    $desktopHost -match 'status\.scanner\.available'
}
Check 'installer packages scanning diagnostics and preserves scoped elevation' {
    $bundle -match 'Test-M11Escl\.ps1' -and
    $bundle -match 'Set-M11ScanApproval\.ps1' -and
    $lifecycle -match '''-ScanPort'', \$Config\.lan_scan_port' -and
    $lifecycle -match 'InstallLanElevated'
}
Check 'lifecycle removes only exact non-default legacy milestone queues' {
    $lifecycle -match 'function Remove-LegacyOwnedQueues' -and
    $lifecycle -match 'Brother via PrintBridge POC' -and
    $lifecycle -match 'PrintBridge M0 feasibility POC - owned by Manage-M0IppPrinter\.ps1' -and
    $lifecycle -match 'Brother via PrintBridge M1' -and
    $lifecycle -match 'PrintBridge M1 manual spike - owned by Manage-M1IppPrinter\.ps1' -and
    $lifecycle -match '\$queue\.DriverName -ne ''Microsoft IPP Class Driver''' -and
    $lifecycle -match '\$queue\.PortName -notlike ''WSD-\*''' -and
    $lifecycle -match '\[bool\]\$cimPrinter\.Default' -and
    $lifecycle -notmatch 'Remove-PrinterPort|Remove-PrinterDriver'
}
Check 'authoritative M11 gate is bounded and consumes no paper' {
    $spec -match 'M11 .*Driverless scanning.*consumers' -and
    $spec -match 'no paper consumed' -and
    $spec -match 'do not start M12 or commit M11'
}

"M11 software tests: $passed passed, $failed failed"
if ($failed -ne 0) { exit 1 }
