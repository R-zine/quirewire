[CmdletBinding()]
param(
    [ValidateRange(10, 300)][int]$DurationSeconds = 75,
    [Parameter(Mandatory)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$destination = [IO.Path]::GetFullPath($OutputPath)
$directory = Split-Path -Parent $destination
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$known = [Collections.Generic.HashSet[int]]::new()
foreach ($process in [Diagnostics.Process]::GetProcesses()) { $null = $known.Add($process.Id) }
$records = [Collections.Generic.List[object]]::new()
$stopwatch = [Diagnostics.Stopwatch]::StartNew()

while ($stopwatch.Elapsed.TotalSeconds -lt $DurationSeconds) {
    foreach ($process in [Diagnostics.Process]::GetProcesses()) {
        if (-not $known.Add($process.Id)) { $process.Dispose(); continue }
        try {
            try { $processPath = $process.MainModule.FileName } catch { $processPath = $null }
            try { $hasWindow = $process.MainWindowHandle -ne [IntPtr]::Zero } catch { $hasWindow = $false }
            $records.Add([pscustomobject][ordered]@{
                observed_utc = [DateTime]::UtcNow.ToString('o')
                pid = $process.Id
                name = $process.ProcessName
                path = $processPath
                has_main_window = $hasWindow
            })
        }
        finally { $process.Dispose() }
    }
    Start-Sleep -Milliseconds 25
}

[ordered]@{
    schema = 'printbridge.m8.process-start-trace.v1'
    started_utc = [DateTime]::UtcNow.AddSeconds(-$stopwatch.Elapsed.TotalSeconds).ToString('o')
    completed_utc = [DateTime]::UtcNow.ToString('o')
    duration_seconds = $DurationSeconds
    records = $records
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $destination -Encoding utf8
