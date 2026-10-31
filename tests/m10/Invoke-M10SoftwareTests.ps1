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

foreach ($relative in @(
    'scripts\m10\windows\Invoke-M10LanSharing.ps1',
    'scripts\m10\windows\Set-M10LanApproval.ps1',
    'scripts\m10\windows\Test-M10LanIpp.ps1',
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

Check 'live DNS-SD diagnostic avoids competing for UDP 5353' {
    (Text 'crates\provider-lan\src\lib.rs') -match 'UdpSocket::bind' -and
    (Text 'crates\provider-lan\src\lib.rs') -match 'ptr_query' -and
    (Text 'crates\provider-lan\src\lib.rs') -match 'printers/PrintBridge_DCP_L2600D' -and
    (Text 'crates\provider-lan\src\lib.rs') -match 'AIRPRINT_SERVICE_TYPE' -and
    (Text 'crates\agent\src\main.rs') -match 'diagnose-lan' -and
    (Text 'crates\agent\src\main.rs') -match 'std::fs::write' -and
    (Text 'crates\agent\src\main.rs') -match '--output'
}

Check 'Bash syntax: scripts/m10/linux/Repair-M10GuestDisk.sh' {
    $bash = 'C:\Program Files\Git\bin\bash.exe'
    if (-not (Test-Path -LiteralPath $bash)) { $bash = (Get-Command bash -ErrorAction Stop).Source }
    & $bash -n (Join-Path $root 'scripts\m10\linux\Repair-M10GuestDisk.sh')
    $LASTEXITCODE -eq 0
}

$lanScript = Text 'scripts\m10\windows\Invoke-M10LanSharing.ps1'
$approvalScript = Text 'scripts\m10\windows\Set-M10LanApproval.ps1'
$agent = Text 'crates\agent\src\m6.rs'
$virtualbox = Text 'crates\provider-virtualbox\src\lib.rs'
$cups = Text 'crates\provider-cups\src\lib.rs'
$lan = Text 'crates\provider-lan\src\lib.rs'
$desktop = Text 'apps\desktop\src-tauri\src\lib.rs'
$runtime = Text 'apps\desktop\src-tauri\src\runtime.rs'
$lifecycle = Text 'scripts\m8\windows\Invoke-M8Lifecycle.ps1'
$spec = Text 'SPEC.md'
$guestPolicy = Text 'guest\linux\configure-lan-cups.sh'

Check 'firewall is explicit-interface/subnet and exact-program scoped' {
    $lanScript -match '-Profile Private,Public' -and
    $lanScript -match '-InterfaceAlias \$ApprovedInterfaceAlias' -and
    $lanScript -match '-RemoteAddress \$ApprovedSubnet' -and
    $lanScript -match '-Program \$resolvedProgram' -and
    $lanScript -notmatch '-Profile Any' -and
    $lanScript -notmatch 'LocalSubnet4'
}
Check 'LAN requires a paired explicit interface and subnet approval' {
    $lanScript -match 'must be provided together' -and
    $lanScript -match 'LAN sharing is off until an interface and local subnet are explicitly approved' -and
    $approvalScript -match "ValidateSet\('Approve', 'Remove', 'Status'\)" -and
    $approvalScript -match 'lan_interface_alias=' -and
    $approvalScript -match 'lan_subnet='
}
Check 'subnet mask arithmetic avoids signed PowerShell hexadecimal literals' {
    $lanScript -match "ToUInt64\('FFFFFFFF', 16\)" -and
    $lanScript -notmatch '\[uint64\]0xffffffff' -and
    $lanScript -match 'Test-RemoteAddressMatchesApproved'
}
Check 'LAN NAT rule has independent ownership metadata and collision refusal' {
    $virtualbox -match 'printbridge\.m10\.lan-forward\.v1' -and
    $virtualbox -match 'printbridge-m10-lan-ipp' -and
    $virtualbox -match 'refusing to remove a LAN forward without exact ownership metadata'
}
Check 'DNS-SD data comes from actual CUPS attributes' {
    foreach ($name in @('document-format-supported', 'urf-supported', 'printer-uuid',
        'color-supported', 'sides-supported')) {
        if ($cups -notmatch [regex]::Escape($name)) { return $false }
    }
    $true
}
Check 'DNS-SD includes the AirPrint universal IPP subtype' {
    $lan -match '_universal\._sub\._ipp\._tcp\.local\.'
}
Check 'guest permits only the owned queue path through CUPS' {
    $guestPolicy -match '<Location /printers/PrintBridge_DCP_L2600D>' -and
    $guestPolicy -match 'ServerAlias printbridge-m4\.local' -and
    $guestPolicy -notmatch '<Location />' -and
    $guestPolicy -notmatch '<Location /admin>'
}
Check 'agent disables login startup and supports lease plus shutdown' {
    $agent -match 'startup\.disable_login_start\(\)' -and
    $agent -notmatch 'startup\.enable_login_start\(\)' -and
    $agent -match 'DESKTOP_LEASE' -and
    $agent -match 'Command::Heartbeat' -and
    $agent -match 'Command::Shutdown'
}
Check 'desktop launches hidden on-demand agent and explicit Exit shuts down' {
    $runtime -match 'creation_flags\(0x0800_0000\)' -and
    $runtime -match 'Command::Heartbeat' -and
    $runtime -match 'Command::Start' -and
    $desktop -match 'Command::Shutdown' -and
    $desktop -match 'Exit PrintBridge \(stop sharing\)'
}
Check 'installer removes legacy task and never enables or starts it' {
    $lifecycle -notmatch 'Invoke-Startup Enable' -and
    $lifecycle -notmatch 'Start-ScheduledTask' -and
    $lifecycle -match 'Disable-ExistingOwnedTask' -and
    $lifecycle -match 'InstallLanElevated'
}
Check 'installer packages approval helper and forwards only approved scope' {
    $lifecycle -match 'Set-M10LanApproval\.ps1' -and
    $lifecycle -match "'-ApprovedInterfaceAlias'" -and
    $lifecycle -match "'-ApprovedSubnet'" -and
    $lifecycle -match 'Test-LanApproved'
}
Check 'authoritative spec contains the bounded M10 physical gate' {
    $spec -match 'M10 .* On-demand trusted-LAN sharing' -and
    $spec -match 'print one small page' -and
    $spec -match 'No M11 work or M10 commit before'
}

"M10 software tests: $passed passed, $failed failed"
if ($failed -ne 0) { exit 1 }
