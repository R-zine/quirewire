[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Detect', 'Install', 'Status', 'TestPage', 'Remove')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$PrinterName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$IppUrl,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$StatePath,

    [string]$CorrelationId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ExpectedDriver = 'Microsoft IPP Class Driver'
$OwnedSchema = 'quirewire.m5.owned-printer.v1'
$ProtocolHeader = 'QUIREWIRE_WINDOWS_V1'

function ConvertTo-ProtocolText {
    param([AllowNull()][object]$Value)

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
}

function Write-SuccessRecord {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$Fields)

    [Console]::Out.WriteLine($ProtocolHeader)
    [Console]::Out.WriteLine('ok=true')
    foreach ($entry in $Fields.GetEnumerator()) {
        if ($entry.Key -notmatch '^[a-z_]+$') {
            throw "Internal protocol field name is invalid: $($entry.Key)"
        }
        if ($entry.Value -is [bool]) {
            [Console]::Out.WriteLine("$($entry.Key)=$(([string]$entry.Value).ToLowerInvariant())")
        }
        elseif ($entry.Value -is [byte] -or $entry.Value -is [int16] -or
            $entry.Value -is [int32] -or $entry.Value -is [int64] -or
            $entry.Value -is [uint16] -or $entry.Value -is [uint32] -or
            $entry.Value -is [uint64]) {
            [Console]::Out.WriteLine("$($entry.Key)=$($entry.Value)")
        }
        else {
            [Console]::Out.WriteLine("$($entry.Key)=$(ConvertTo-ProtocolText -Value $entry.Value)")
        }
    }
}

function Write-FailureRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$ObservedDriver
    )

    [Console]::Out.WriteLine($ProtocolHeader)
    [Console]::Out.WriteLine('ok=false')
    [Console]::Out.WriteLine("error_code=$Code")
    [Console]::Out.WriteLine("error_message=$(ConvertTo-ProtocolText -Value $Message)")
    if (-not [string]::IsNullOrWhiteSpace($ObservedDriver)) {
        [Console]::Out.WriteLine("observed_driver=$(ConvertTo-ProtocolText -Value $ObservedDriver)")
    }
}

function Throw-ProviderError {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$ObservedDriver
    )

    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['QuireWireCode'] = $Code
    if (-not [string]::IsNullOrWhiteSpace($ObservedDriver)) {
        $exception.Data['ObservedDriver'] = $ObservedDriver
    }
    throw $exception
}

function Get-Capability {
    $addPrinter = Get-Command Add-Printer -ErrorAction SilentlyContinue
    $getPrinter = Get-Command Get-Printer -ErrorAction SilentlyContinue
    $removePrinter = Get-Command Remove-Printer -ErrorAction SilentlyContinue
    if ($null -eq $addPrinter -or $null -eq $getPrinter -or $null -eq $removePrinter) {
        Throw-ProviderError -Code 'missing_printmanagement' -Message `
            'Windows PrintManagement cmdlets are unavailable. Repair the Windows printing feature.'
    }
    return [pscustomobject]@{
        IppUrlSupported = $addPrinter.Parameters.ContainsKey('IppURL')
        Version = "$($addPrinter.Source) $($addPrinter.Version)"
    }
}

function Get-ValidatedTarget {
    if ($PrinterName -notmatch '^Brother via QuireWire(?: [A-Za-z0-9._-]+)?$' -or
        $PrinterName.Contains("`r") -or $PrinterName.Contains("`n")) {
        Throw-ProviderError -Code 'invalid_argument' -Message `
            'PrinterName must be the configured Brother via QuireWire owned name.'
    }
    $uri = $null
    if (-not [Uri]::TryCreate($IppUrl, [UriKind]::Absolute, [ref]$uri)) {
        Throw-ProviderError -Code 'invalid_argument' -Message 'The configured IPP URL is not absolute.'
    }
    if ($uri.Scheme -notin @('http', 'ipp') -or
        $uri.Host -notin @('127.0.0.1', 'localhost', '::1') -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Fragment) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        $uri.AbsolutePath -notmatch '^/printers/[A-Za-z0-9._-]+$') {
        Throw-ProviderError -Code 'invalid_argument' -Message `
            'M5 requires a credential-free loopback http/ipp URL with /printers/<safe-queue> path.'
    }
    if (-not [IO.Path]::IsPathRooted($StatePath) -or
        $StatePath.Contains("`r") -or $StatePath.Contains("`n")) {
        Throw-ProviderError -Code 'invalid_argument' -Message 'StatePath must be an absolute local path.'
    }
    return $uri
}

function Get-TargetQueue {
    return Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
}

function Get-DefaultPrinterName {
    $default = Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop |
        Where-Object { [bool]$_.Default } |
        Select-Object -First 1
    if ($null -eq $default) { return $null }
    return [string]$default.Name
}

function Test-IsDefault {
    param([Parameter(Mandatory = $true)][string]$Name)

    $escaped = $Name.Replace("'", "''")
    $printer = Get-CimInstance -ClassName Win32_Printer -Filter "Name='$escaped'" -ErrorAction SilentlyContinue
    return $null -ne $printer -and [bool]$printer.Default
}

function Read-OwnedState {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $null }
    try {
        return Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Throw-ProviderError -Code 'ownership_mismatch' -Message `
            'The M5 ownership record is unreadable; refusing to manage any live queue.'
    }
}

function Test-OwnedQueue {
    param(
        [AllowNull()]$Queue,
        [AllowNull()]$State,
        [Parameter(Mandatory = $true)][Uri]$Uri
    )

    return $null -ne $Queue -and $null -ne $State -and
        $State.schema -eq $OwnedSchema -and
        $State.printerName -eq $PrinterName -and
        $State.ippUrl -eq $Uri.AbsoluteUri -and
        $State.driverName -eq $ExpectedDriver -and
        $Queue.DriverName -eq $State.driverName -and
        $Queue.PortName -eq $State.portName -and
        $Queue.Comment -eq $State.ownedComment
}

function Write-OwnedState {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$State)

    $directory = Split-Path -Parent $StatePath
    $null = New-Item -ItemType Directory -Force -Path $directory
    $temporaryPath = Join-Path $directory ('.m5-printer-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        Move-Item -LiteralPath $temporaryPath -Destination $StatePath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Test-Endpoint {
    param([Parameter(Mandatory = $true)][Uri]$Uri)

    $port = if ($Uri.Port -gt 0) { $Uri.Port } else { 631 }
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $pending = $client.BeginConnect($Uri.DnsSafeHost, $port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(5000)) {
            Throw-ProviderError -Code 'endpoint_unreachable' -Message `
                "Timed out connecting to the loopback IPP endpoint on port $port. Start the owned appliance and retry."
        }
        $client.EndConnect($pending)
    }
    catch {
        if ($_.Exception.Data.Contains('QuireWireCode')) { throw }
        Throw-ProviderError -Code 'endpoint_unreachable' -Message `
            "The loopback IPP endpoint on port $port is unreachable. Start the owned appliance and retry."
    }
    finally {
        $client.Dispose()
    }
}

function Get-StatusFields {
    param(
        [Parameter(Mandatory = $true)][Uri]$Uri,
        [Parameter(Mandatory = $true)]$Capability,
        [string]$Correlation,
        [Nullable[uint32]]$SpoolerJobId
    )

    $queue = Get-TargetQueue
    $state = Read-OwnedState
    $spooler = Get-Service -Name Spooler -ErrorAction Stop
    $fields = [ordered]@{
        ipp_url_supported = [bool]$Capability.IppUrlSupported
        print_management_version = [string]$Capability.Version
        queue_found = $null -ne $queue
        ownership_verified = Test-OwnedQueue -Queue $queue -State $state -Uri $Uri
        spooler_running = $spooler.Status -eq [ServiceProcess.ServiceControllerStatus]::Running
        is_default = $null -ne $queue -and (Test-IsDefault -Name $PrinterName)
        ipp_url = $Uri.AbsoluteUri
        queue_name = if ($null -eq $queue) { '' } else { [string]$queue.Name }
        driver_name = if ($null -eq $queue) { '' } else { [string]$queue.DriverName }
        port_name = if ($null -eq $queue) { '' } else { [string]$queue.PortName }
        printer_status = if ($null -eq $queue) { '' } else { [string]$queue.PrinterStatus }
    }
    if (-not [string]::IsNullOrWhiteSpace($Correlation)) {
        $fields['correlation_id'] = $Correlation
        $fields['spooler_job_id'] = if ($null -eq $SpoolerJobId) { '' } else { [uint32]$SpoolerJobId }
    }
    return $fields
}

try {
    $capability = Get-Capability
    $uri = Get-ValidatedTarget

    if ($Action -eq 'Detect') {
        Write-SuccessRecord -Fields ([ordered]@{
            ipp_url_supported = [bool]$capability.IppUrlSupported
            print_management_version = [string]$capability.Version
        })
        exit 0
    }

    if ($Action -eq 'Status') {
        Write-SuccessRecord -Fields (Get-StatusFields -Uri $uri -Capability $capability)
        exit 0
    }

    if (-not $capability.IppUrlSupported) {
        Throw-ProviderError -Code 'ipp_url_unsupported' -Message `
            'This Windows build does not expose Add-Printer -IppURL. Use the documented Settings IPP Device fallback and verify Microsoft IPP Class Driver.'
    }

    $spooler = Get-Service -Name Spooler -ErrorAction Stop
    if ($spooler.Status -ne [ServiceProcess.ServiceControllerStatus]::Running) {
        Throw-ProviderError -Code 'spooler_not_running' -Message `
            'Start the Windows Print Spooler, then retry. QuireWire does not silently change its startup policy.'
    }

    if ($Action -eq 'Install') {
        $existing = Get-TargetQueue
        $existingState = Read-OwnedState
        if ($null -ne $existing) {
            if (-not (Test-OwnedQueue -Queue $existing -State $existingState -Uri $uri)) {
                Throw-ProviderError -Code 'ownership_mismatch' -Message `
                    "A queue named '$PrinterName' already exists but does not match the M5 ownership record; it was not changed."
            }
            if ($existing.DriverName -ne $ExpectedDriver) {
                Throw-ProviderError -Code 'unsupported_driver' -Message `
                    'The owned queue is not using the Microsoft inbox IPP driver.' -ObservedDriver $existing.DriverName
            }
            Write-SuccessRecord -Fields (Get-StatusFields -Uri $uri -Capability $capability)
            exit 0
        }

        Test-Endpoint -Uri $uri
        $defaultBefore = Get-DefaultPrinterName
        $token = [Guid]::NewGuid().ToString('D')
        $ownedComment = "QuireWire M5 owned queue [$token]"
        $created = $null
        try {
            $null = Add-Printer -Name $PrinterName -IppURL $uri.AbsoluteUri -Comment $ownedComment -ErrorAction Stop
            for ($attempt = 0; $attempt -lt 30 -and $null -eq $created; $attempt++) {
                Start-Sleep -Milliseconds 500
                $created = Get-TargetQueue
            }
            if ($null -eq $created) {
                Throw-ProviderError -Code 'provider_failure' -Message `
                    'Add-Printer returned successfully but the new queue did not appear.'
            }
            $null = Set-Printer -Name $PrinterName -Comment $ownedComment -ErrorAction Stop
            $created = Get-TargetQueue
            if ($null -eq $created -or $created.Comment -ne $ownedComment) {
                Throw-ProviderError -Code 'ownership_mismatch' -Message `
                    'Windows did not retain the M5 ownership comment.'
            }
            if ($created.DriverName -ne $ExpectedDriver) {
                Throw-ProviderError -Code 'unsupported_driver' -Message `
                    'Windows selected a non-Microsoft driver. The newly created queue will be removed.' `
                    -ObservedDriver $created.DriverName
            }

            $defaultAfter = Get-DefaultPrinterName
            if ($defaultAfter -ne $defaultBefore) {
                if ([string]::IsNullOrWhiteSpace($defaultBefore)) {
                    Throw-ProviderError -Code 'default_printer' -Message `
                        'Queue installation changed Windows default-printer state and no previous default could be restored.'
                }
                $network = New-Object -ComObject WScript.Network
                $network.SetDefaultPrinter($defaultBefore)
                if ((Get-DefaultPrinterName) -ne $defaultBefore) {
                    Throw-ProviderError -Code 'default_printer' -Message `
                        'Queue installation changed the default printer and restoring the previous default failed.'
                }
            }

            Write-OwnedState -State ([ordered]@{
                schema = $OwnedSchema
                createdUtc = [DateTime]::UtcNow.ToString('o')
                ownerToken = $token
                printerName = $created.Name
                ippUrl = $uri.AbsoluteUri
                driverName = $created.DriverName
                portName = $created.PortName
                ownedComment = $ownedComment
            })
        }
        catch {
            if ($null -ne (Get-TargetQueue)) {
                Remove-Printer -Name $PrinterName -ErrorAction SilentlyContinue
            }
            throw
        }
        $installed = Get-StatusFields -Uri $uri -Capability $capability
        if (-not $installed.ownership_verified) {
            Throw-ProviderError -Code 'ownership_mismatch' -Message `
                'The new queue did not match its ownership record.'
        }
        Write-SuccessRecord -Fields $installed
        exit 0
    }

    if ($Action -eq 'Remove') {
        $queue = Get-TargetQueue
        $state = Read-OwnedState
        if ($null -eq $queue) {
            if ($null -ne $state -and ($state.schema -ne $OwnedSchema -or
                $state.printerName -ne $PrinterName -or $state.ippUrl -ne $uri.AbsoluteUri)) {
                Throw-ProviderError -Code 'ownership_mismatch' -Message `
                    'The retained ownership record does not match this configured target.'
            }
            Write-SuccessRecord -Fields (Get-StatusFields -Uri $uri -Capability $capability)
            exit 0
        }
        if (-not (Test-OwnedQueue -Queue $queue -State $state -Uri $uri)) {
            Throw-ProviderError -Code 'ownership_mismatch' -Message `
                'The live queue does not exactly match the M5 ownership record; refusing removal.'
        }
        if (Test-IsDefault -Name $PrinterName) {
            Throw-ProviderError -Code 'default_printer' -Message `
                'The owned queue is the Windows default. Select another default before removal.'
        }
        Remove-Printer -Name $PrinterName -ErrorAction Stop
        if ($null -ne (Get-TargetQueue)) {
            Throw-ProviderError -Code 'provider_failure' -Message `
                'Remove-Printer returned but the owned queue is still present.'
        }
        Write-SuccessRecord -Fields (Get-StatusFields -Uri $uri -Capability $capability)
        exit 0
    }

    if ($Action -eq 'TestPage') {
        if ([string]::IsNullOrWhiteSpace($CorrelationId) -or
            $CorrelationId -notmatch '^m5-[a-f0-9-]+$') {
            Throw-ProviderError -Code 'invalid_argument' -Message `
                'TestPage requires the generated M5 correlation identifier.'
        }
        $queue = Get-TargetQueue
        $state = Read-OwnedState
        if ($null -eq $queue) {
            Throw-ProviderError -Code 'queue_not_found' -Message `
                "The configured queue '$PrinterName' is absent. Run printer install first."
        }
        if (-not (Test-OwnedQueue -Queue $queue -State $state -Uri $uri)) {
            Throw-ProviderError -Code 'ownership_mismatch' -Message `
                'The live queue does not exactly match the M5 ownership record; refusing test submission.'
        }
        if ($queue.DriverName -ne $ExpectedDriver) {
            Throw-ProviderError -Code 'unsupported_driver' -Message `
                'The queue is not using Microsoft IPP Class Driver.' -ObservedDriver $queue.DriverName
        }
        $beforeIds = @(Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue |
            ForEach-Object { [uint32]$_.Id })
        $escaped = $PrinterName.Replace("'", "''")
        $cimPrinter = Get-CimInstance -ClassName Win32_Printer -Filter "Name='$escaped'" -ErrorAction Stop
        if ($null -eq $cimPrinter) {
            Throw-ProviderError -Code 'queue_not_found' -Message 'Win32_Printer could not locate the owned queue.'
        }
        $result = Invoke-CimMethod -InputObject $cimPrinter -MethodName PrintTestPage -ErrorAction Stop
        if ([uint32]$result.ReturnValue -ne 0) {
            Throw-ProviderError -Code 'test_page_failed' -Message `
                "Windows rejected PrintTestPage with return code $($result.ReturnValue)."
        }
        $newJob = $null
        for ($attempt = 0; $attempt -lt 10 -and $null -eq $newJob; $attempt++) {
            $newJob = Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue |
                Where-Object { [uint32]$_.Id -notin $beforeIds } |
                Select-Object -First 1
            if ($null -eq $newJob) { Start-Sleep -Milliseconds 100 }
        }
        $jobId = if ($null -eq $newJob) { $null } else { [Nullable[uint32]]([uint32]$newJob.Id) }
        Write-SuccessRecord -Fields (Get-StatusFields -Uri $uri -Capability $capability `
            -Correlation $CorrelationId -SpoolerJobId $jobId)
        exit 0
    }

    Throw-ProviderError -Code 'invalid_argument' -Message 'Unsupported M5 provider action.'
}
catch {
    $code = 'provider_failure'
    $observed = $null
    $failureMessage = $_.Exception.Message
    if ($_.Exception.Data.Contains('QuireWireCode')) {
        $code = [string]$_.Exception.Data['QuireWireCode']
    }
    elseif ($_.Exception -is [UnauthorizedAccessException] -or
        $_.Exception.Message -match '(?i)access (?:is )?denied') {
        $code = 'permission_denied'
        $failureMessage = 'Windows denied the print-queue mutation. Re-run only the install/remove command in an elevated PowerShell window, then return to ordinary-user status and printing.'
    }
    if ($_.Exception.Data.Contains('ObservedDriver')) {
        $observed = [string]$_.Exception.Data['ObservedDriver']
    }
    Write-FailureRecord -Code $code -Message $failureMessage -ObservedDriver $observed
    exit 1
}
