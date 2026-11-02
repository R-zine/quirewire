[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CliExecutable,
    [Parameter(Mandatory)][string]$ResultPath,
    [ValidateRange(5, 600)][int]$DelaySeconds = 90
)

$ErrorActionPreference = 'Stop'
Start-Sleep -Seconds $DelaySeconds
$started = (Get-Date).ToUniversalTime().ToString('o')
$output = @(& $CliExecutable test-print 2>&1 | ForEach-Object { $_.ToString() })
$code = $LASTEXITCODE
$record = [ordered]@{
    schema = 'quirewire.m6.delayed-print.v1'
    executed_at_utc = $started
    exit_code = $code
    client_output = ($output -join "`n")
    physical_output = 'not_inferred'
}
$directory = Split-Path -Parent $ResultPath
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$temporary = "$ResultPath.$PID.tmp"
$record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporary -Encoding utf8
Move-Item -LiteralPath $temporary -Destination $ResultPath -Force
exit $code
