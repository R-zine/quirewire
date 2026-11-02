[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Inspect', 'Register', 'Remove')]
    [string]$Action,

    [string]$IppUrl,
    [ValidateNotNullOrEmpty()][string]$PrinterName = 'Brother via QuireWire M1',
    [string]$EvidenceDirectory,
    [switch]$Apply,
    [switch]$SkipNetworkProbe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OwnedComment = 'QuireWire M1 manual spike - owned by Manage-M1IppPrinter.ps1'
$ExpectedDriver = 'Microsoft IPP Class Driver'
$OwnedSchema = 'quirewire.m1.owned-printer.v1'

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m1\windows-printer'
}
$EvidenceDirectory = [System.IO.Path]::GetFullPath($EvidenceDirectory)
$ownershipDirectory = Join-Path $EvidenceDirectory 'ownership'
$markerPath = Join-Path $ownershipDirectory 'ipp-m1-printer.json'
$recordsDirectory = Join-Path $EvidenceDirectory 'printer-actions'
New-Item -ItemType Directory -Force -Path $recordsDirectory | Out-Null

function Get-ValidatedIppUri {
    param([Parameter(Mandatory = $true)][string]$Value)

    $parsed = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$parsed)) {
        throw "IppUrl must be an absolute URI. Received: $Value"
    }
    if ($parsed.Scheme -notin @('ipp', 'ipps', 'http', 'https')) {
        throw "IppUrl scheme must be ipp, ipps, http, or https. Received: $($parsed.Scheme)"
    }
    if ($parsed.Host -notin @('127.0.0.1', 'localhost', '::1')) {
        throw 'M1 IPP registration is restricted to a loopback host.'
    }
    if (-not [string]::IsNullOrEmpty($parsed.UserInfo) -or -not [string]::IsNullOrEmpty($parsed.Fragment)) {
        throw 'IppUrl must not include credentials or a fragment.'
    }
    return $parsed
}

function Get-OwnedQueue {
    return Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
}

function Get-QueueSnapshot {
    param($Queue)
    if ($null -eq $Queue) { return $null }
    $jobs = @()
    try {
        $jobs = @(Get-PrintJob -PrinterName $Queue.Name -ErrorAction Stop |
            Select-Object Id, DocumentName, JobStatus, SubmittedTime, Size, TotalPages, PagesPrinted)
    }
    catch { }
    return [ordered]@{
        name = $Queue.Name
        driverName = $Queue.DriverName
        portName = $Queue.PortName
        comment = $Queue.Comment
        printerStatus = [string]$Queue.PrinterStatus
        jobs = $jobs
    }
}

function Write-ActionRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)]$Payload
    )
    $record = [ordered]@{
        schema = 'quirewire.m1.windows-printer-action.v1'
        recordedUtc = [DateTime]::UtcNow.ToString('o')
        action = $Operation
        data = $Payload
    }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $path = Join-Path $recordsDirectory "$stamp-$($Operation.ToLowerInvariant()).json"
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host "Evidence: $path"
}

function Test-EndpointTcp {
    param([Parameter(Mandatory = $true)][Uri]$Uri)
    $port = $Uri.Port
    if ($port -lt 1) { $port = if ($Uri.Scheme -in @('ipps', 'https')) { 443 } else { 631 } }
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $async = $client.BeginConnect($Uri.DnsSafeHost, $port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(5000)) {
            throw "Timed out connecting to $($Uri.DnsSafeHost):$port after 5 seconds."
        }
        $client.EndConnect($async)
        Write-Host "TCP preflight passed: $($Uri.DnsSafeHost):$port"
    }
    finally { $client.Dispose() }
}

$addPrinter = Get-Command Add-Printer -ErrorAction SilentlyContinue
if ($null -eq $addPrinter -or $null -eq (Get-Command Get-Printer -ErrorAction SilentlyContinue)) {
    throw 'The Windows PrintManagement module is unavailable.'
}
if (-not $addPrinter.Parameters.ContainsKey('IppURL')) {
    throw 'This Windows build does not expose Add-Printer -IppURL.'
}

switch ($Action) {
    'Inspect' {
        $queue = Get-OwnedQueue
        $payload = [ordered]@{
            expectedDriver = $ExpectedDriver
            queueFound = $null -ne $queue
            driverMatchesMicrosoftInboxIpp = $null -ne $queue -and $queue.DriverName -eq $ExpectedDriver
            queue = Get-QueueSnapshot -Queue $queue
        }
        $payload | ConvertTo-Json -Depth 8
        Write-ActionRecord -Operation Inspect -Payload $payload
        if ($null -eq $queue) { exit 2 }
        if ($queue.DriverName -ne $ExpectedDriver) { exit 3 }
        exit 0
    }

    'Register' {
        if ([string]::IsNullOrWhiteSpace($IppUrl)) { throw '-IppUrl is required for Register.' }
        $uri = Get-ValidatedIppUri -Value $IppUrl
        $existing = Get-OwnedQueue
        if ($null -ne $existing) {
            $owned = $false
            if (Test-Path -LiteralPath $markerPath) {
                try {
                    $marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
                    $owned = $marker.schema -eq $OwnedSchema -and
                        $marker.printerName -eq $PrinterName -and
                        $marker.ippUrl -eq $uri.AbsoluteUri -and
                        $existing.Comment -eq $OwnedComment -and
                        $existing.PortName -eq $marker.portName -and
                        $existing.DriverName -eq $marker.driverName
                }
                catch { $owned = $false }
            }
            if (-not $owned) {
                throw "A printer named '$PrinterName' already exists but is not proven M1-owned; it will not be changed."
            }
            Write-Host 'Owned M1 queue already exists; registration is idempotent.'
            Write-ActionRecord -Operation RegisterNoOp -Payload (Get-QueueSnapshot -Queue $existing)
            if ($existing.DriverName -ne $ExpectedDriver) {
                throw "Existing owned queue uses '$($existing.DriverName)', not '$ExpectedDriver'."
            }
            exit 0
        }

        Write-Host "Planned command: Add-Printer -Name '$PrinterName' -IppURL '$($uri.AbsoluteUri)'"
        Write-Host "Expected inbox driver: $ExpectedDriver"
        if (-not $Apply) {
            Write-Host 'Dry run only. Re-run with -Apply after verifying the dedicated M1 loopback forward.'
            exit 0
        }
        if (-not $SkipNetworkProbe) { Test-EndpointTcp -Uri $uri }

        Add-Printer -Name $PrinterName -IppURL $uri.AbsoluteUri -Comment $OwnedComment -ErrorAction Stop
        $created = $null
        for ($attempt = 0; $attempt -lt 15 -and $null -eq $created; $attempt++) {
            Start-Sleep -Seconds 1
            $created = Get-OwnedQueue
        }
        if ($null -eq $created) { throw "Add-Printer returned but '$PrinterName' was not found." }
        try {
            Set-Printer -Name $PrinterName -Comment $OwnedComment -ErrorAction Stop
            $created = Get-OwnedQueue
            if ($null -eq $created -or $created.Comment -ne $OwnedComment) {
                throw 'Windows did not retain the M1 ownership comment.'
            }
        }
        catch {
            Remove-Printer -Name $PrinterName -ErrorAction SilentlyContinue
            throw "The new queue could not be marked as M1-owned and was removed. $($_.Exception.Message)"
        }

        New-Item -ItemType Directory -Force -Path $ownershipDirectory | Out-Null
        $marker = [ordered]@{
            schema = $OwnedSchema
            createdUtc = [DateTime]::UtcNow.ToString('o')
            printerName = $created.Name
            ippUrl = $uri.AbsoluteUri
            driverName = $created.DriverName
            portName = $created.PortName
            ownedComment = $OwnedComment
        }
        $marker | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $markerPath -Encoding UTF8
        Write-ActionRecord -Operation Register -Payload (Get-QueueSnapshot -Queue $created)
        if ($created.DriverName -ne $ExpectedDriver) {
            throw "Queue selected '$($created.DriverName)' instead of '$ExpectedDriver'. Do not print; use this script's Remove action."
        }
        Write-Host "PASS: M1 queue uses '$ExpectedDriver'."
        exit 0
    }

    'Remove' {
        if (-not (Test-Path -LiteralPath $markerPath)) {
            throw "Ownership marker not found at '$markerPath'; refusing removal."
        }
        $marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
        if ($marker.schema -ne $OwnedSchema -or $marker.printerName -ne $PrinterName) {
            throw 'Ownership marker does not match the requested queue; refusing removal.'
        }
        $queue = Get-OwnedQueue
        if ($null -eq $queue) {
            Write-Host 'Owned M1 queue is already absent; no printer was removed.'
            Write-ActionRecord -Operation RemoveNoOp -Payload ([ordered]@{ printerName = $PrinterName; alreadyAbsent = $true })
            exit 0
        }
        if ($queue.Comment -ne $OwnedComment -or $queue.PortName -ne $marker.portName -or $queue.DriverName -ne $marker.driverName) {
            throw 'Live queue no longer matches its ownership marker; refusing removal.'
        }
        $cimPrinter = Get-CimInstance -ClassName Win32_Printer -Filter "Name='$($PrinterName.Replace("'", "''"))'" -ErrorAction SilentlyContinue
        if ($null -ne $cimPrinter -and [bool]$cimPrinter.Default) {
            throw 'The owned M1 queue is the Windows default. Select another default before removal.'
        }
        Write-Host "Planned command: Remove-Printer -Name '$PrinterName'"
        Write-Host 'No printer driver or port will be removed.'
        if (-not $Apply) { Write-Host 'Dry run only. Re-run with -Apply to remove only this M1-owned queue.'; exit 0 }
        $before = Get-QueueSnapshot -Queue $queue
        Remove-Printer -Name $PrinterName -ErrorAction Stop
        if ($null -ne (Get-OwnedQueue)) { throw "'$PrinterName' still exists after Remove-Printer." }
        Write-ActionRecord -Operation Remove -Payload ([ordered]@{ removed = $before; markerRetainedForAudit = $markerPath })
        Write-Host "Removed only the owned queue '$PrinterName'."
        exit 0
    }
}
