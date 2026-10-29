[CmdletBinding()]
param(
    [ValidateRange(15, 120)][int]$HoldSeconds = 20,
    [Parameter(Mandatory)][string]$ResultPath
)

$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This controlled Spooler interruption requires an elevated PowerShell process.'
}

$before = Get-Service -Name Spooler
$stoppedAt = $null
$startedAt = $null
try {
    Stop-Service -Name Spooler -Force
    $stoppedAt = (Get-Date).ToUniversalTime().ToString('o')
    Start-Sleep -Seconds $HoldSeconds
}
finally {
    Start-Service -Name Spooler
    $startedAt = (Get-Date).ToUniversalTime().ToString('o')
}
$after = Get-Service -Name Spooler
$record = [ordered]@{
    schema = 'printbridge.m6.spooler-interruption.v1'
    before_status = $before.Status.ToString()
    stopped_at_utc = $stoppedAt
    hold_seconds = $HoldSeconds
    started_at_utc = $startedAt
    after_status = $after.Status.ToString()
}
$directory = Split-Path -Parent $ResultPath
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$record | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding utf8
