[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Inspect', 'Register', 'Remove')]
    [string]$Action,

    [string]$IppUrl,

    [ValidateNotNullOrEmpty()]
    [string]$PrinterName = 'Brother via PrintBridge POC',

    [string]$EvidenceDirectory,

    [switch]$Apply,

    [switch]$SkipNetworkProbe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OwnedComment = 'PrintBridge M0 feasibility POC - owned by Manage-M0IppPrinter.ps1'
$ExpectedDriver = 'Microsoft IPP Class Driver'

if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m0\windows'
}
$EvidenceDirectory = [System.IO.Path]::GetFullPath($EvidenceDirectory)
$ownershipDirectory = Join-Path $EvidenceDirectory 'ownership'
$markerPath = Join-Path $ownershipDirectory 'ipp-poc-printer.json'
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
    if ([string]::IsNullOrWhiteSpace($parsed.Host)) {
        throw 'IppUrl must include a host.'
    }
    if (-not [string]::IsNullOrEmpty($parsed.UserInfo)) {
        throw 'Credentials must not be embedded in IppUrl.'
    }
    if (-not [string]::IsNullOrEmpty($parsed.Fragment)) {
        throw 'IppUrl must not contain a URI fragment.'
    }
    return $parsed
}

function Get-Queue {
    return Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
}

function Get-QueueSnapshot {
    param($Queue)

    if ($null -eq $Queue) {
        return $null
    }

    $configuration = $null
    $jobs = @()
    try {
        $configuration = Get-PrintConfiguration -PrinterName $Queue.Name -ErrorAction Stop |
            Select-Object PrinterName, PaperSize, Color, DuplexingMode, Collate
    }
    catch { }
    try {
        $jobs = @(Get-PrintJob -PrinterName $Queue.Name -ErrorAction Stop |
            Select-Object Id, DocumentName, JobStatus, Status, SubmittedTime, Size, TotalPages, PagesPrinted)
    }
    catch { }

    return [ordered]@{
        name = $Queue.Name
        driverName = $Queue.DriverName
        portName = $Queue.PortName
        comment = $Queue.Comment
        printerStatus = [string]$Queue.PrinterStatus
        type = [string]$Queue.Type
        shared = [bool]$Queue.Shared
        configuration = $configuration
        jobs = $jobs
    }
}

function Write-ActionRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)]$Payload
    )

    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $path = Join-Path $recordsDirectory "$stamp-$($Operation.ToLowerInvariant()).json"
    $record = [ordered]@{
        schema = 'printbridge.m0.windows-printer-action.v1'
        recordedUtc = [DateTime]::UtcNow.ToString('o')
        action = $Operation
        data = $Payload
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host "Evidence: $path"
}

function Test-EndpointTcp {
    param([Parameter(Mandatory = $true)][Uri]$Uri)

    $port = $Uri.Port
    if ($port -lt 1) {
        $port = if ($Uri.Scheme -in @('ipps', 'https')) { 443 } else { 631 }
    }

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $async = $client.BeginConnect($Uri.DnsSafeHost, $port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(5000)) {
            throw "Timed out connecting to $($Uri.DnsSafeHost):$port after 5 seconds."
        }
        $client.EndConnect($async)
        Write-Host "TCP preflight passed: $($Uri.DnsSafeHost):$port"
    }
    finally {
        $client.Dispose()
    }
}

$addPrinter = Get-Command Add-Printer -ErrorAction SilentlyContinue
$getPrinter = Get-Command Get-Printer -ErrorAction SilentlyContinue
if ($null -eq $addPrinter -or $null -eq $getPrinter) {
    throw 'The Windows PrintManagement module is unavailable. Use supported Windows 11 x64 and capture this failure in M0 evidence.'
}
if (-not $addPrinter.Parameters.ContainsKey('IppURL')) {
    throw 'This host''s Add-Printer cmdlet does not expose -IppURL. Record the OS build and use the documented manual IPP-add path.'
}

switch ($Action) {
    'Inspect' {
        $queue = Get-Queue
        $snapshot = Get-QueueSnapshot -Queue $queue
        $payload = [ordered]@{
            expectedDriver = $ExpectedDriver
            queueFound = $null -ne $queue
            driverMatchesMicrosoftInboxIpp = ($null -ne $queue -and $queue.DriverName -eq $ExpectedDriver)
            queue = $snapshot
        }
        $payload | ConvertTo-Json -Depth 8
        Write-ActionRecord -Operation 'Inspect' -Payload $payload
        if ($null -eq $queue) { exit 2 }
        if ($queue.DriverName -ne $ExpectedDriver) { exit 3 }
        exit 0
    }

    'Register' {
        if ([string]::IsNullOrWhiteSpace($IppUrl)) {
            throw '-IppUrl is required for Register.'
        }
        $uri = Get-ValidatedIppUri -Value $IppUrl
        $existing = Get-Queue

        if ($null -ne $existing) {
            $owned = $false
            if (Test-Path -LiteralPath $markerPath) {
                try {
                    $marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
                    $owned = $marker.schema -eq 'printbridge.m0.owned-printer.v1' -and
                        $marker.printerName -eq $PrinterName -and
                        $marker.ippUrl -eq $uri.AbsoluteUri -and
                        $existing.Comment -eq $OwnedComment -and
                        $existing.PortName -eq $marker.portName -and
                        $existing.DriverName -eq $marker.driverName
                }
                catch { $owned = $false }
            }
            if (-not $owned) {
                throw "A printer named '$PrinterName' already exists but cannot be proven to be owned by this M0 script. It will not be changed."
            }

            Write-Host "Owned queue already exists; registration is idempotent."
            $snapshot = Get-QueueSnapshot -Queue $existing
            Write-ActionRecord -Operation 'RegisterNoOp' -Payload $snapshot
            if ($existing.DriverName -ne $ExpectedDriver) {
                throw "Existing owned queue uses '$($existing.DriverName)', not '$ExpectedDriver'."
            }
            exit 0
        }

        Write-Host "Planned command: Add-Printer -Name '$PrinterName' -IppURL '$($uri.AbsoluteUri)'"
        Write-Host "Expected inbox driver after registration: $ExpectedDriver"
        if (-not $Apply) {
            Write-Host 'Dry run only. Re-run with -Apply after checking the URL and CUPS sharing scope.'
            exit 0
        }

        if (-not $SkipNetworkProbe) {
            Test-EndpointTcp -Uri $uri
        }

        Add-Printer -Name $PrinterName -IppURL $uri.AbsoluteUri -Comment $OwnedComment -ErrorAction Stop
        $created = $null
        for ($attempt = 0; $attempt -lt 15 -and $null -eq $created; $attempt++) {
            Start-Sleep -Seconds 1
            $created = Get-Queue
        }
        if ($null -eq $created) {
            throw "Add-Printer returned without error, but '$PrinterName' was not found afterward."
        }

        # IPP discovery can replace Add-Printer's requested comment with the
        # server-side printer-info value. Reapply and verify the ownership
        # comment before writing the marker; otherwise cleanup would correctly
        # refuse to touch the queue that this invocation just created.
        try {
            Set-Printer -Name $PrinterName -Comment $OwnedComment -ErrorAction Stop
            $created = Get-Queue
            if ($null -eq $created -or $created.Comment -ne $OwnedComment) {
                throw 'Windows did not retain the PrintBridge ownership comment.'
            }
        }
        catch {
            # The name was proven absent immediately before Add-Printer, so this
            # queue is owned by the current invocation even though no persistent
            # marker has been written yet.
            Remove-Printer -Name $PrinterName -ErrorAction SilentlyContinue
            throw "The IPP queue was created, but its ownership comment could not be established; the newly created queue was removed. $($_.Exception.Message)"
        }

        New-Item -ItemType Directory -Force -Path $ownershipDirectory | Out-Null
        $marker = [ordered]@{
            schema = 'printbridge.m0.owned-printer.v1'
            createdUtc = [DateTime]::UtcNow.ToString('o')
            printerName = $created.Name
            ippUrl = $uri.AbsoluteUri
            driverName = $created.DriverName
            portName = $created.PortName
            ownedComment = $OwnedComment
        }
        $marker | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $markerPath -Encoding UTF8

        $snapshot = Get-QueueSnapshot -Queue $created
        Write-ActionRecord -Operation 'Register' -Payload $snapshot
        if ($created.DriverName -ne $ExpectedDriver) {
            throw "Queue was created but selected driver '$($created.DriverName)' instead of '$ExpectedDriver'. Keep the evidence, do not print, and run Remove with the same EvidenceDirectory to clean up."
        }

        Write-Host "PASS: queue uses the Microsoft inbox driver '$ExpectedDriver'."
        exit 0
    }

    'Remove' {
        if (-not (Test-Path -LiteralPath $markerPath)) {
            throw "Ownership marker not found at '$markerPath'. Refusing to remove any printer."
        }

        $marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
        if ($marker.schema -ne 'printbridge.m0.owned-printer.v1' -or $marker.printerName -ne $PrinterName) {
            throw 'Ownership marker does not match the requested queue. Refusing removal.'
        }

        $queue = Get-Queue
        if ($null -eq $queue) {
            Write-Host "Owned queue is already absent; no printer was removed."
            Write-ActionRecord -Operation 'RemoveNoOp' -Payload ([ordered]@{ printerName = $PrinterName; alreadyAbsent = $true })
            exit 0
        }
        if ($queue.Comment -ne $OwnedComment -or $queue.PortName -ne $marker.portName -or $queue.DriverName -ne $marker.driverName) {
            throw 'The live queue no longer matches its ownership marker (comment, port, or driver changed). Refusing removal.'
        }

        $isDefault = $false
        try {
            $cimPrinter = Get-CimInstance -ClassName Win32_Printer -Filter "Name='$($PrinterName.Replace("'", "''"))'" -ErrorAction Stop
            $isDefault = $null -ne $cimPrinter -and [bool]$cimPrinter.Default
        }
        catch {
            Write-Warning "Could not determine whether the queue is the Windows default: $($_.Exception.Message)"
        }
        if ($isDefault) {
            throw 'The owned POC queue is currently the default printer. Select a different default before removing it.'
        }

        Write-Host "Planned command: Remove-Printer -Name '$PrinterName'"
        Write-Host 'The printer driver and any unrelated queues or ports will not be removed.'
        if (-not $Apply) {
            Write-Host 'Dry run only. Re-run with -Apply to remove this script-owned POC queue.'
            exit 0
        }

        $before = Get-QueueSnapshot -Queue $queue
        Remove-Printer -Name $PrinterName -ErrorAction Stop
        $remaining = Get-Queue
        for ($attempt = 0; $attempt -lt 10 -and $null -ne $remaining; $attempt++) {
            Start-Sleep -Milliseconds 500
            $remaining = Get-Queue
        }
        if ($null -ne $remaining) {
            throw "Remove-Printer returned without error, but '$PrinterName' still exists."
        }
        Write-ActionRecord -Operation 'Remove' -Payload ([ordered]@{ removed = $before; markerRetainedForAudit = $markerPath })
        Write-Host "Removed only the owned queue '$PrinterName'. Ownership evidence was retained."
        exit 0
    }
}

