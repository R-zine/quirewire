[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Plan', 'Sequential', 'LongPdf', 'Single')][string]$Action,
    [string]$DocumentDirectory,
    [string]$SinglePath,
    [string]$PdfToolPath,
    [string]$SshPrivateKeyPath,
    [ValidatePattern('^Brother via QuireWire$')][string]$PrinterName = 'Brother via QuireWire',
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'QuireWire'),
    [string]$OutputDirectory,
    [ValidateRange(10, 900)][int]$WaitForCupsSeconds = 300,
    [ValidateRange(0, 5000)][int]$BetweenJobsMilliseconds = 500,
    [uint64]$MinimumFreeBytes = 1GB,
    [switch]$SkipCupsCompletionWait
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
if ([string]::IsNullOrWhiteSpace($DocumentDirectory)) {
    $DocumentDirectory = Join-Path $repositoryRoot 'artifacts\m9\documents'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot 'artifacts\m9\soak'
}
if ([string]::IsNullOrWhiteSpace($PdfToolPath)) {
    $PdfToolPath = Join-Path $repositoryRoot 'artifacts\m9\tools\SumatraPDF-3.6.1-64\SumatraPDF-3.6.1-64.exe'
}
if ([string]::IsNullOrWhiteSpace($SshPrivateKeyPath)) {
    $SshPrivateKeyPath = Join-Path $repositoryRoot 'artifacts\m4\ssh\id_ed25519'
}
$DocumentDirectory = [IO.Path]::GetFullPath($DocumentDirectory)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$PdfToolPath = [IO.Path]::GetFullPath($PdfToolPath)
$SshPrivateKeyPath = [IO.Path]::GetFullPath($SshPrivateKeyPath)
$manifestPath = Join-Path $DocumentDirectory 'manifest.json'
$installationPath = Join-Path $DataRoot 'installation.json'
$statePath = Join-Path $DataRoot 'm5-windows-printer.json'
$cliPath = Join-Path $DataRoot 'bin\quirewirectl.exe'
foreach ($required in @($manifestPath, $installationPath, $statePath, $cliPath, $PdfToolPath, $SshPrivateKeyPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required M9 input is absent: $required" }
}
$ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$installation = Get-Content -Raw -LiteralPath $installationPath | ConvertFrom-Json
if ($installation.schema -ne 'quirewire.m8.installation.v1' -or $installation.owner_sid -ne $ownerSid -or
    [IO.Path]::GetFullPath($installation.data_root) -ne [IO.Path]::GetFullPath($DataRoot) -or
    $installation.queue.name -ne $PrinterName) {
    throw 'The M8 installation manifest does not authorize this exact user, data root, and queue.'
}
$state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
$queue = Get-Printer -Name $PrinterName -Full -ErrorAction Stop
if ($state.schema -ne 'quirewire.m5.owned-printer.v1' -or $state.printerName -ne $PrinterName -or
    $state.driverName -ne 'Microsoft IPP Class Driver' -or $queue.DriverName -ne $state.driverName -or
    $queue.PortName -ne $state.portName -or $queue.Comment -ne $state.ownedComment) {
    throw 'The live Windows queue does not exactly match its QuireWire ownership record.'
}
$pdfSignature = Get-AuthenticodeSignature -LiteralPath $PdfToolPath
if ($pdfSignature.Status -ne 'Valid') { throw 'The owner-local PDF test tool does not have a valid Authenticode signature.' }
$documents = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($documents.schema -ne 'quirewire.m9.test-documents.v1' -or $documents.sequential_job_count -lt 20) {
    throw 'The document manifest does not contain the required M9 sequential workload.'
}
$driveRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($DataRoot)).TrimEnd('\')
$drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$driveRoot'"
if (-not $drive -or [uint64]$drive.FreeSpace -lt $MinimumFreeBytes) {
    throw "LOW_DISK: fewer than $MinimumFreeBytes bytes are free; no print job was submitted."
}
$statusText = @(& $cliPath status 2>&1 | ForEach-Object { $_.ToString() })
if ($LASTEXITCODE -ne 0) { throw 'The QuireWire agent is unavailable.' }
$status = ($statusText -join "`n") | ConvertFrom-Json
if ($status.value.overall -ne 'ready') { throw "QuireWire is not ready: $($status.value.overall)" }

$selected = switch ($Action) {
    'Plan' { @($documents.jobs) }
    'Sequential' { @($documents.jobs) }
    'LongPdf' { @([pscustomobject]@{ sequence = 0; name = $documents.long_pdf.name; format = $documents.long_pdf.format; token = $documents.long_pdf.token_prefix }) }
    'Single' {
        if ([string]::IsNullOrWhiteSpace($SinglePath)) { throw 'Single requires -SinglePath.' }
        $fullSingle = [IO.Path]::GetFullPath($SinglePath)
        $documentRoot = $DocumentDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $fullSingle.StartsWith($documentRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'SinglePath must be below the M9 owned document directory.'
        }
        $extension = [IO.Path]::GetExtension($fullSingle).ToLowerInvariant()
        if ($extension -notin @('.txt', '.pdf')) { throw 'Single supports only an owned text or PDF fixture.' }
        @([pscustomobject]@{ sequence = 0; name = [IO.Path]::GetFileName($fullSingle); format = if ($extension -eq '.pdf') { 'application/pdf' } else { 'text/plain' }; token = 'single' })
    }
}
foreach ($item in $selected) {
    $path = Join-Path $DocumentDirectory $item.name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Owned fixture is absent: $($item.name)" }
}
if ($Action -eq 'Plan') {
    [pscustomobject]@{
        schema = 'quirewire.m9.application-plan.v1'
        printer = $PrinterName
        driver = $queue.DriverName
        jobs = $selected.Count
        text_application = 'Windows Notepad /pt'
        pdf_application = [IO.Path]::GetFileName($PdfToolPath)
        pdf_tool_signature = [string]$pdfSignature.Status
        physical_output = 'not_inferred'
    } | ConvertTo-Json
    exit 0
}

function Invoke-Guest([string]$Command) {
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& ssh.exe -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 `
            -i $SshPrivateKeyPath -p 2244 quirewire@127.0.0.1 $Command 2>&1 | ForEach-Object { $_.ToString() })
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousErrorAction }
    if ($code -ne 0) { throw 'The loopback-only CUPS evidence query failed.' }
    $output
}
function Get-CupsJobIds([switch]$ActiveOnly) {
    $scope = if ($ActiveOnly) { 'not-completed' } else { 'all' }
    @((Invoke-Guest "lpstat -W $scope -o QuireWire_DCP_L2600D") | ForEach-Object {
        if ($_ -match '^QuireWire_DCP_L2600D-([0-9]+)\s') { [int]$Matches[1] }
    } | Sort-Object -Unique)
}
function Wait-NewCupsJob([int[]]$Before) {
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitForCupsSeconds)
    do {
        $ids = @(Get-CupsJobIds)
        $newIds = @($ids | Where-Object { $_ -notin $Before } | Sort-Object)
        if ($newIds.Count -gt 0) { return [int]$newIds[-1] }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'The application job did not reach the owned CUPS queue within the timeout.'
}
function Wait-CupsCompletion([int]$JobId) {
    if ($SkipCupsCompletionWait) { return 'not-waited' }
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitForCupsSeconds)
    do {
        if ($JobId -notin @(Get-CupsJobIds -ActiveOnly)) { return 'completed-or-no-longer-active' }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "CUPS job $JobId remained active beyond the timeout."
}
function Submit-ApplicationJob([object]$Item) {
    $path = Join-Path $DocumentDirectory $Item.name
    if ($Item.format -eq 'text/plain') {
        $notepad = Join-Path $env:SystemRoot 'System32\notepad.exe'
        $arguments = @('/pt', ('"{0}"' -f $path), ('"{0}"' -f $PrinterName),
            ('"{0}"' -f $queue.DriverName), ('"{0}"' -f $queue.PortName))
        Start-Process -FilePath $notepad -ArgumentList $arguments -WindowStyle Hidden -PassThru
    }
    elseif ($Item.format -eq 'application/pdf') {
        $arguments = @('-print-to', ('"{0}"' -f $PrinterName), '-silent', ('"{0}"' -f $path))
        Start-Process -FilePath $PdfToolPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
    }
    else { throw "Unsupported fixture format: $($Item.format)" }
}

$beforePrinters = @(Get-Printer | ForEach-Object { $_.Name } | Sort-Object)
$defaultBefore = @(Get-CimInstance Win32_Printer | Where-Object { [bool]$_.Default } | ForEach-Object { $_.Name }) -join "`n"
$knownCupsIds = @(Get-CupsJobIds)
$results = [Collections.Generic.List[object]]::new()
foreach ($item in $selected) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = Submit-ApplicationJob $item
    $cupsId = Wait-NewCupsJob $knownCupsIds
    $observedMs = [math]::Round($watch.Elapsed.TotalMilliseconds, 1)
    $knownCupsIds += $cupsId
    $forcedClose = $false
    if (-not $process.WaitForExit(5000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction Stop
        $process.WaitForExit()
        $forcedClose = $true
    }
    $applicationExitCode = if ($forcedClose) { $null } else { $process.ExitCode }
    if (-not $forcedClose -and $applicationExitCode -ne 0) {
        throw "Application print failed for $($item.name): exit $applicationExitCode"
    }
    $cupsTerminal = Wait-CupsCompletion $cupsId
    $results.Add([pscustomobject][ordered]@{
        sequence = [int]$item.sequence
        name = [string]$item.name
        format = [string]$item.format
        application = if ($item.format -eq 'text/plain') { 'Windows Notepad /pt' } else { [IO.Path]::GetFileName($PdfToolPath) }
        application_exit_code = $applicationExitCode
        application_closed_after_cups_submission = $true
        application_forced_closed_after_cups_submission = $forcedClose
        cups_job_id = $cupsId
        cups_observed_ms = $observedMs
        cups_terminal = $cupsTerminal
        physical_output = 'not_inferred'
    })
    if ($BetweenJobsMilliseconds -gt 0) { Start-Sleep -Milliseconds $BetweenJobsMilliseconds }
}
$afterPrinters = @(Get-Printer | ForEach-Object { $_.Name } | Sort-Object)
$defaultAfter = @(Get-CimInstance Win32_Printer | Where-Object { [bool]$_.Default } | ForEach-Object { $_.Name }) -join "`n"
if (($beforePrinters -join "`n") -ne ($afterPrinters -join "`n") -or $defaultBefore -ne $defaultAfter) {
    throw 'Printer inventory or default-printer state changed during the M9 workload.'
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$resultPath = Join-Path $OutputDirectory "$stamp-$($Action.ToLowerInvariant()).json"
[ordered]@{
    schema = 'quirewire.m9.application-soak.v1'
    recorded_utc = [DateTime]::UtcNow.ToString('o')
    action = $Action
    printer = $PrinterName
    driver = $queue.DriverName
    jobs = $results
    pdf_tool = [ordered]@{
        path = $PdfToolPath
        sha256 = (Get-FileHash -LiteralPath $PdfToolPath -Algorithm SHA256).Hash.ToLowerInvariant()
        signature_status = [string]$pdfSignature.Status
        signer = $pdfSignature.SignerCertificate.Subject
        bundled = $false
    }
    unrelated_printers_preserved = $true
    default_printer_preserved = $true
    physical_output = 'requires_owner_confirmation'
} | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $resultPath -Encoding utf8
[pscustomobject]@{ schema = 'quirewire.m9.application-soak-result.v1'; path = $resultPath; jobs = $results.Count; physical_output = 'requires_owner_confirmation' } | ConvertTo-Json
