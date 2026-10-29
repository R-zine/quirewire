[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$UiNeverLaunched,
    [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$LockedSessionPrinted,
    [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$LogonRecoveryPrinted,
    [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$CupsRecoveryPrinted,
    [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$SpoolerRecoveryPrinted,
    [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$UsbReconnectPrinted,
    [Parameter(Mandatory)][ValidateSet('yes', 'no')][string]$PhysicalPagePrinted,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m6\acceptance'
}
$answers = @($UiNeverLaunched, $LockedSessionPrinted, $LogonRecoveryPrinted, $CupsRecoveryPrinted,
    $SpoolerRecoveryPrinted, $UsbReconnectPrinted, $PhysicalPagePrinted)
$passed = $answers -notcontains 'no'
$record = [ordered]@{
    schema = 'printbridge.m6.owner-acceptance.v1'
    recorded_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    result = if ($passed) { 'PASS: PHYSICAL' } else { 'FAIL' }
    ui_never_launched = ($UiNeverLaunched -eq 'yes')
    locked_session_printed = ($LockedSessionPrinted -eq 'yes')
    logon_recovery_printed = ($LogonRecoveryPrinted -eq 'yes')
    cups_recovery_printed = ($CupsRecoveryPrinted -eq 'yes')
    spooler_recovery_printed = ($SpoolerRecoveryPrinted -eq 'yes')
    usb_reconnect_printed = ($UsbReconnectPrinted -eq 'yes')
    physical_page_printed = ($PhysicalPagePrinted -eq 'yes')
    logoff_behavior = 'Per-user Interactive Token task terminates at logoff; pre-login printing is not promised. Agent resumes at next logon.'
    note = 'Owner observations only; software cannot infer physical paper output.'
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$name = "{0}-m6-acceptance.json" -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
$path = Join-Path $OutputDirectory $name
$record | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8
$record | Format-List
Write-Host "Acceptance record: $path"
if (-not $passed) { exit 1 }
