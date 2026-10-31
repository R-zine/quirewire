[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$evidence = Join-Path $repositoryRoot "artifacts\m4\software-tests\$stamp"
[IO.Directory]::CreateDirectory($evidence) | Out-Null
$passed = 0
$failed = 0
$results = [Collections.Generic.List[object]]::new()

function Check([string]$Name, [scriptblock]$Test) {
    try {
        & $Test
        $script:passed++
        $script:results.Add([pscustomobject]@{ name = $Name; result = 'pass' })
        Write-Host "PASS $Name"
    }
    catch {
        $script:failed++
        $script:results.Add([pscustomobject]@{ name = $Name; result = 'fail'; detail = $_.Exception.Message })
        Write-Host "FAIL $Name - $($_.Exception.Message)"
    }
}

function Require([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$powershellFiles = @(
    'guest\windows\New-M4Appliance.ps1',
    'guest\windows\New-M4DriverMedia.ps1',
    'guest\windows\Invoke-M4Acceptance.ps1',
    'guest\windows\Record-M4Acceptance.ps1',
    'tests\m4\Invoke-M4SoftwareTests.ps1'
)
foreach ($relative in $powershellFiles) {
    Check "PowerShell parser: $relative" {
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repositoryRoot $relative), [ref]$tokens, [ref]$errors
        ) | Out-Null
        Require ($errors.Count -eq 0) (($errors | ForEach-Object { $_.ToString() }) -join '; ')
    }
}

$bashPath = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path -LiteralPath $bashPath)) { $bashPath = (Get-Command bash -ErrorAction Stop).Source }
$shellFiles = @(
    'guest/linux/provision-base.sh',
    'guest/linux/firstboot.sh',
    'guest/linux/apply-driver-media.sh',
    'guest/linux/health.sh'
    'guest/linux/configure-lan-cups.sh'
)
Check 'Bash syntax for every guest script' {
    & $bashPath -n @($shellFiles | ForEach-Object { Join-Path $repositoryRoot $_ })
    Require ($LASTEXITCODE -eq 0) 'bash -n failed'
}

$baseManifest = Get-Content -Raw (Join-Path $repositoryRoot 'guest\manifests\debian-13.7-amd64.env')
$driverManifest = Get-Content -Raw (Join-Path $repositoryRoot 'guest\manifests\brother-dcpl2600d.env')
$baseScript = Get-Content -Raw (Join-Path $repositoryRoot 'guest\linux\provision-base.sh')
$driverScript = Get-Content -Raw (Join-Path $repositoryRoot 'guest\linux\apply-driver-media.sh')
$healthScript = Get-Content -Raw (Join-Path $repositoryRoot 'guest\linux\health.sh')
$acceptanceScript = Get-Content -Raw (Join-Path $repositoryRoot 'guest\windows\Invoke-M4Acceptance.ps1')

Check 'Debian release, snapshot, package versions, and ISO hash are pinned' {
    foreach ($pattern in @(
        '(?m)^DEBIAN_VERSION=13\.7$',
        '(?m)^DEBIAN_SNAPSHOT_TIMESTAMP=\d{8}T\d{6}Z$',
        '(?m)^DEBIAN_ISO_SHA256=[0-9a-f]{64}$',
        '(?m)^CUPS_VERSION=.+$',
        '(?m)^DBUS_VERSION=.+$',
        '(?m)^BRLASER_VERSION=.+$'
    )) { Require ([regex]::IsMatch($baseManifest, $pattern)) "missing pin $pattern" }
}
Check 'Official driver source, metadata, PPD, and hashes are pinned' {
    foreach ($pattern in @(
        '(?m)^PATCH_VERSION=1\.1\.0-0$',
        '(?m)^PATCH_ARCHITECTURE=all$',
        '(?m)^PATCH_SHA256=[0-9a-f]{64}$',
        '(?m)^DRIVER_VERSION=4\.1\.0-1$',
        '(?m)^DRIVER_ARCHITECTURE=i386$',
        '(?m)^DRIVER_SHA256=[0-9a-f]{64}$',
        '(?m)^PPD_SHA256=[0-9a-f]{64}$',
        '(?m)^REDISTRIBUTION=owner-local-only-pending-license-review$'
    )) { Require ([regex]::IsMatch($driverManifest, $pattern)) "missing driver pin $pattern" }
}
Check 'Base provisioning is minimal, key-only, and has no GUI task' {
    Require ($baseScript.Contains('--no-install-recommends')) 'minimal apt policy absent'
    Require ($baseScript.Contains('systemctl set-default multi-user.target')) 'headless target absent'
    Require (-not [regex]::IsMatch($baseScript, '(?i)gnome|kde|xfce|task-desktop')) 'GUI package found'
}
Check 'CUPS sharing forbids remote admin and remote-any' {
    Require ($baseScript.Contains('--share-printers --no-remote-admin --no-remote-any')) 'protected cupsctl flags absent'
    Require (-not $baseScript.Contains('--remote-any')) 'unsafe CUPS remote-any flag present'
}
Check 'CUPS LAN access is limited to the owned print queue' {
    $policy = Get-Content -Raw (Join-Path $repositoryRoot 'guest\linux\configure-lan-cups.sh')
    Require ($policy.Contains('<Location /printers/PrintBridge_DCP_L2600D>')) 'owned queue location absent'
    Require ($policy.Contains('ServerAlias printbridge-m4.local')) 'fixed advertised alias absent'
    Require (-not $policy.Contains('<Location />')) 'root CUPS location was exposed'
    Require (-not $policy.Contains('<Location /admin>')) 'CUPS administration was exposed'
}
Check 'Driver workflows separate open and official paths before queue mutation' {
    $open = $driverScript.IndexOf('open-brlaser)')
    $official = $driverScript.IndexOf('official-brother)')
    $queueMutation = $driverScript.IndexOf('lpadmin -p "$queue_name"')
    Require ($open -ge 0 -and $official -ge 0 -and $queueMutation -gt $open -and $queueMutation -gt $official) 'driver paths or safe queue ordering absent'
    Require ($driverScript.Contains('refusing to replace known-good driver mode')) 'repair preservation guard absent'
}
Check 'Health is actionable and never infers physical output' {
    foreach ($field in @('cups=', 'queue=', 'accepting=', 'ipp=', 'usb=', 'driver_mode=', 'physical_output=not_inferred')) {
        Require ($healthScript.Contains($field)) "health field absent: $field"
    }
    Require ($healthScript.Contains('serial=)[^&[:space:]]+')) 'serial redaction absent'
}
Check 'Host acceptance binds SSH and IPP to loopback only' {
    Require ($acceptanceScript.Contains('127.0.0.1,$SshPort')) 'SSH forward is not loopback explicit'
    Require ($acceptanceScript.Contains('127.0.0.1,$IppPort')) 'IPP forward is not loopback explicit'
    Require ($acceptanceScript.Contains('physical_output = ''not_inferred''')) 'truthful physical state absent'
}

Check 'Open-driver media is source-only and contains no Brother binary mapping' {
    $openOut = Join-Path $evidence 'open-driver'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repositoryRoot 'guest\windows\New-M4DriverMedia.ps1') -Mode open-brlaser -OutputDirectory $openOut | Out-Null
    Require ($LASTEXITCODE -eq 0) 'open driver media builder failed'
    $manifest = Get-Content -Raw (Join-Path $openOut 'manifest-open-brlaser.env')
    $viso = Get-Content -Raw (Join-Path $openOut 'printbridge-m4-open-brlaser.viso')
    Require ($manifest.Contains('DRIVER_MODE=open-brlaser')) 'open mode absent'
    Require (-not $viso.Contains('.deb')) 'open media unexpectedly maps a vendor binary'
}

Check 'Appliance builder rejects an unpinned ISO before creating a VM' {
    $badIso = Join-Path $evidence 'not-debian.iso'
    $publicKey = Join-Path $evidence 'test.pub'
    [IO.File]::WriteAllText($badIso, 'not an ISO')
    [IO.File]::WriteAllText($publicKey, 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF58rMJ8a807pQSAHw5R8BmD33MHcxoQIzTU0gjSvqSZ test')
    $vbox = "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe"
    $before = if (Test-Path $vbox) { @(& $vbox list vms 2>&1) -join "`n" } else { '' }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repositoryRoot 'guest\windows\New-M4Appliance.ps1') -Stage Base -DebianIsoPath $badIso -SshPublicKeyPath $publicKey -OutputDirectory (Join-Path $evidence 'bad-build') *> $null
    $rejectionCode = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference
    Require ($rejectionCode -ne 0) 'bad ISO was accepted'
    $after = if (Test-Path $vbox) { @(& $vbox list vms 2>&1) -join "`n" } else { '' }
    Require ($before -eq $after) 'VM inventory changed after bad input rejection'
}

Check 'Acceptance recorder refuses software-only state' {
    $statePath = Join-Path $evidence 'software-only-state.json'
    [ordered]@{
        schema = 'printbridge.m4.acceptance-state.v1'; fresh_ova_import = $true
        idempotent_reprovision = $true; cups_health = 'pass'; physical_token = $null
    } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repositoryRoot 'guest\windows\Record-M4Acceptance.ps1') -StatePath $statePath -PhysicalPagePrinted yes *> $null
    $rejectionCode = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference
    Require ($rejectionCode -ne 0) 'recorder accepted a state with no physical submission'
}

Check 'No restricted appliance or driver binary is tracked' {
    $safeDirectory = $repositoryRoot.Replace('\', '/')
    $tracked = @(& git -c "safe.directory=$safeDirectory" -C $repositoryRoot ls-files)
    Require ($LASTEXITCODE -eq 0) 'git ls-files failed'
    $forbidden = @($tracked | Where-Object { $_ -match '(?i)\.(deb|rpm|iso|ova|ovf|vdi|vmdk)$' })
    Require ($forbidden.Count -eq 0) "tracked restricted/binary artifact: $($forbidden -join ', ')"
}

$summary = [ordered]@{
    schema = 'printbridge.m4.software-tests.v1'
    result = if ($failed -eq 0) { 'PASS: SOFTWARE ONLY' } else { 'FAIL' }
    passed = $passed
    failed = $failed
    physical_hardware = 'NOT TESTED'
    checks = $results
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $evidence 'software-test-results.json') -Encoding UTF8
Write-Host "M4 software checks: $passed passed, $failed failed. Evidence: $evidence"
if ($failed -ne 0) { exit 1 }
