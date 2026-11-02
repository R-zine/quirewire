[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$SourceVmUuid,

    [string]$VBoxManage = "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",

    [string]$EvidenceRoot,

    [ValidateRange(5, 300)]
    [int]$SourcePowerOffWaitSeconds = 120,

    [ValidateRange(30, 180)]
    [int]$GuestBootSettleSeconds = 90,

    [ValidateRange(30, 300)]
    [int]$GuestReadyWaitSeconds = 120,

    [switch]$KeepFixture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    $EvidenceRoot = [System.IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot '..\..\artifacts\m3\windows-integration')
    )
}

$schemaKey = 'QuireWire/Schema'
$schemaValue = 'quirewire.m3.owned-vm.v1'
$ownerKey = 'QuireWire/Owner'
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$marker = "quirewire.m3.integration.$stamp.$([guid]::NewGuid().ToString('N'))"
$fixtureName = "QuireWire-M3-Integration-$stamp"
$evidenceDirectory = Join-Path $EvidenceRoot $stamp
$configPath = Join-Path $evidenceDirectory 'm3-integration.conf'
$summaryPath = Join-Path $evidenceDirectory 'summary.txt'
$fixtureUuid = $null
$testFailed = $true

New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null

function Invoke-VBox {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )
    $previousErrorAction = $ErrorActionPreference
    try {
        # VBoxManage writes successful progress to stderr. Windows PowerShell
        # otherwise promotes that stream to a terminating NativeCommandError.
        $ErrorActionPreference = 'Continue'
        $lines = & $VBoxManage @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "VBoxManage failed with exit $exitCode while running '$($Arguments[0])'."
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        Lines = @($lines | ForEach-Object { $_.ToString() })
    }
}

function Get-VmValues {
    param([Parameter(Mandatory)][string]$Uuid)
    $result = Invoke-VBox -Arguments @('showvminfo', $Uuid, '--machinereadable')
    $values = @{}
    foreach ($line in $result.Lines) {
        if ($line -match '^([^=]+)="(.*)"$') {
            # `$Matches` is mutable automatic state in Windows PowerShell.
            # Capture both sides before the indexed assignment.
            $key = $Matches[1]
            $value = $Matches[2]
            $values[$key] = $value
        }
    }
    $values
}

function Get-ExtraDataValue {
    param(
        [Parameter(Mandatory)][string]$Uuid,
        [Parameter(Mandatory)][string]$Key
    )
    $result = Invoke-VBox -Arguments @('getextradata', $Uuid, $Key)
    $line = $result.Lines | Select-Object -First 1
    if ($line -eq 'No value set!') {
        return $null
    }
    if ($line -match '^Value:\s*(.*)$') {
        return $Matches[1]
    }
    throw "Unexpected getextradata response for '$Key'."
}

function Test-LoopbackTcpPort {
    param([Parameter(Mandatory)][int]$Port)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connect = $client.ConnectAsync([System.Net.IPAddress]::Loopback, $Port)
        if (-not $connect.Wait(500)) {
            return $false
        }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Assert-FixtureOwnership {
    if (-not $fixtureUuid) {
        throw 'Fixture UUID is not available.'
    }
    $values = Get-VmValues -Uuid $fixtureUuid
    if ($values['UUID'] -ne $fixtureUuid) {
        throw 'Live fixture UUID changed; refusing mutation.'
    }
    if ((Get-ExtraDataValue -Uuid $fixtureUuid -Key $schemaKey) -ne $schemaValue) {
        throw 'Fixture schema marker is missing; refusing mutation.'
    }
    if ((Get-ExtraDataValue -Uuid $fixtureUuid -Key $ownerKey) -ne $marker) {
        throw 'Fixture owner marker changed; refusing mutation.'
    }
}

function Invoke-QuireWire {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$ExpectedExit = 0
    )
    & cargo run --quiet -p quirewirectl -- --config $configPath @Arguments
    if ($LASTEXITCODE -ne $ExpectedExit) {
        throw "quirewirectl exit was $LASTEXITCODE; expected $ExpectedExit for '$($Arguments -join ' ')'."
    }
}

try {
    if (-not (Test-Path -LiteralPath $VBoxManage -PathType Leaf)) {
        throw "VBoxManage was not found at '$VBoxManage'."
    }

    $sourceDeadline = (Get-Date).AddSeconds($SourcePowerOffWaitSeconds)
    $consecutiveStopped = 0
    do {
        $source = Get-VmValues -Uuid $SourceVmUuid
        if ($source['UUID'] -ne $SourceVmUuid) {
            throw 'The source VM did not resolve to the exact requested UUID.'
        }
        Write-Host "Source VM state observed by harness: $($source['VMState'])"
        if ($source['VMState'] -in @('poweroff', 'aborted')) {
            $consecutiveStopped++
        }
        else {
            $consecutiveStopped = 0
        }
        if ($consecutiveStopped -lt 2) {
            Start-Sleep -Seconds 2
        }
    } while ($consecutiveStopped -lt 2 -and (Get-Date) -lt $sourceDeadline)
    if ($consecutiveStopped -lt 2) {
        throw 'The source VM did not remain in a closed non-running state; no source mutation was attempted.'
    }
    $runningVms = Invoke-VBox -Arguments @('list', 'runningvms')
    if ($runningVms.Lines -match [regex]::Escape($SourceVmUuid)) {
        throw 'The source UUID still has a running process; no source mutation was attempted.'
    }

    Write-Host 'Creating disposable full clone from the read-only source VM...'
    Invoke-VBox -Arguments @(
        'clonevm', $SourceVmUuid,
        "--name=$fixtureName",
        '--mode=machine',
        '--register'
    ) | Out-Null

    $created = Get-VmValues -Uuid $fixtureName
    $fixtureUuid = $created['UUID']
    if ($fixtureUuid -notmatch '^[0-9a-fA-F-]{36}$') {
        throw 'The disposable clone did not expose a canonical UUID.'
    }

    # Mark the new UUID immediately so every later cleanup path can prove exact
    # ownership. The VM remains powered off.
    Invoke-VBox -Arguments @('setextradata', $fixtureUuid, $schemaKey, $schemaValue) | Out-Null
    Invoke-VBox -Arguments @('setextradata', $fixtureUuid, $ownerKey, $marker) | Out-Null
    Assert-FixtureOwnership

    # Remove inherited capture filters from the newly created clone before its
    # first boot. The source VM is never modified.
    $filterPositions = @(
        $created.Keys |
            Where-Object { $_ -match '^USBFilterActive(\d+)$' } |
            ForEach-Object { [int]($_ -replace '^USBFilterActive', '') - 1 } |
            Sort-Object -Descending
    )
    foreach ($position in $filterPositions) {
        Invoke-VBox -Arguments @('usbfilter', 'remove', $position.ToString(), "--target=$fixtureUuid") | Out-Null
    }

    # Retain the cloned NAT adapter so the guest reaches normal boot readiness,
    # but remove every inherited host forwarding rule before first boot. The
    # source is closed, and the clone exposes no host service port.
    foreach ($key in @($created.Keys | Where-Object { $_ -match '^Forwarding\(\d+\)$' })) {
        $ruleName = ($created[$key] -split ',', 2)[0]
        if ([string]::IsNullOrWhiteSpace($ruleName)) {
            throw "Inherited NAT rule '$key' omitted its name."
        }
        Invoke-VBox -Arguments @(
            'modifyvm', $fixtureUuid,
            '--natpf1', 'delete', $ruleName
        ) | Out-Null
    }
    $portProbe = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Loopback,
        0
    )
    $portProbe.Start()
    $readinessPort = ([System.Net.IPEndPoint]$portProbe.LocalEndpoint).Port
    $portProbe.Stop()
    Invoke-VBox -Arguments @(
        'modifyvm', $fixtureUuid,
        '--natpf1', "m3-readiness,tcp,127.0.0.1,$readinessPort,,631"
    ) | Out-Null

    @(
        'schema=quirewire.m3.config.v1'
        "vm_uuid=$fixtureUuid"
        "vm_marker=$marker-intentional-mismatch"
        'usb_vendor_id=ffff'
        'usb_product_id=ffff'
    ) | Set-Content -LiteralPath $configPath -Encoding ascii

    Write-Host 'Proving that unmarked clones are rejected before lifecycle mutation...'
    Invoke-QuireWire -Arguments @('vm', 'status') -ExpectedExit 1
    if ((Get-VmValues -Uuid $fixtureUuid)['VMState'] -notin @('poweroff', 'aborted')) {
        throw 'Ownership-negative test changed VM state unexpectedly.'
    }

    @(
        'schema=quirewire.m3.config.v1'
        "vm_uuid=$fixtureUuid"
        "vm_marker=$marker"
        'usb_vendor_id=ffff'
        'usb_product_id=ffff'
    ) | Set-Content -LiteralPath $configPath -Encoding ascii
    Assert-FixtureOwnership

    Write-Host 'Exercising exact-UUID lifecycle and idempotence through the M3 CLI...'
    Invoke-QuireWire -Arguments @('vm', 'status')
    Invoke-QuireWire -Arguments @('vm', 'start')
    Invoke-QuireWire -Arguments @('vm', 'start')
    Invoke-QuireWire -Arguments @('vm', 'status')
    Write-Host "Waiting for loopback-only guest CUPS readiness..."
    $readyDeadline = (Get-Date).AddSeconds($GuestReadyWaitSeconds)
    do {
        $guestReady = Test-LoopbackTcpPort -Port $readinessPort
        if (-not $guestReady) {
            Start-Sleep -Seconds 1
        }
    } while (-not $guestReady -and (Get-Date) -lt $readyDeadline)
    if (-not $guestReady) {
        throw "Guest CUPS did not become reachable within $GuestReadyWaitSeconds seconds."
    }
    Write-Host "Guest CUPS is reachable; settling for $GuestBootSettleSeconds seconds before ACPI..."
    Start-Sleep -Seconds $GuestBootSettleSeconds
    Invoke-QuireWire -Arguments @('vm', 'stop')
    Invoke-QuireWire -Arguments @('vm', 'stop')
    Invoke-QuireWire -Arguments @('vm', 'status')
    Invoke-QuireWire -Arguments @('doctor')

    if ((Get-VmValues -Uuid $fixtureUuid)['VMState'] -ne 'poweroff') {
        throw 'Disposable fixture did not finish powered off.'
    }
    $testFailed = $false
    @(
        'result=PASS'
        'test=disposable-owned-vm-lifecycle'
        "fixture_uuid=$fixtureUuid"
        'ownership_negative_test=PASS'
        'repeated_start=PASS'
        'repeated_stop=PASS'
        'final_state=poweroff'
        'usb_capture=NOT_RUN'
    ) | Set-Content -LiteralPath $summaryPath -Encoding ascii
    Write-Host "PASS: disposable owned VM lifecycle integration ($fixtureUuid)."
}
finally {
    if ($fixtureUuid -and -not $KeepFixture) {
        try {
            Assert-FixtureOwnership
            $state = (Get-VmValues -Uuid $fixtureUuid)['VMState']
            if ($state -eq 'running') {
                Invoke-VBox -Arguments @('controlvm', $fixtureUuid, 'acpipowerbutton') | Out-Null
                $deadline = (Get-Date).AddSeconds(90)
                do {
                    Start-Sleep -Milliseconds 500
                    $state = (Get-VmValues -Uuid $fixtureUuid)['VMState']
                } while ($state -eq 'running' -and (Get-Date) -lt $deadline)
            }
            if ($state -ne 'poweroff') {
                # This is restricted to the UUID created in this run and only
                # after both live ownership markers were revalidated.
                Invoke-VBox -Arguments @('controlvm', $fixtureUuid, 'poweroff') | Out-Null
            }
            Assert-FixtureOwnership
            Invoke-VBox -Arguments @('unregistervm', $fixtureUuid, '--delete') | Out-Null
            Write-Host 'Deleted the exact disposable owned integration fixture.'
        }
        catch {
            Write-Warning "Automatic cleanup stopped safely: $($_.Exception.Message)"
            Write-Warning "Review exact fixture UUID '$fixtureUuid'; no other VM was targeted."
            if (-not $testFailed) {
                throw
            }
        }
    }
}

if ($testFailed) {
    exit 1
}
