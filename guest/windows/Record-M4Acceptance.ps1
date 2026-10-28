[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StatePath,

    [Parameter(Mandatory = $true)]
    [ValidateSet('yes', 'no')]
    [string]$PhysicalPagePrinted
)

$ErrorActionPreference = 'Stop'
$state = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
if ($state.schema -ne 'printbridge.m4.acceptance-state.v1') {
    throw 'The supplied file is not an M4 acceptance state record.'
}
if (-not $state.fresh_ova_import -or -not $state.idempotent_reprovision -or $state.cups_health -ne 'pass') {
    throw 'Software acceptance prerequisites did not pass.'
}
if (-not $state.physical_token) {
    throw 'No physical page was submitted in this acceptance run.'
}

$record = [ordered]@{
    schema = 'printbridge.m4.owner-acceptance.v1'
    recorded_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    physical_token = $state.physical_token
    physical_page_printed = ($PhysicalPagePrinted -eq 'yes')
    result = if ($PhysicalPagePrinted -eq 'yes') { 'PASS: PHYSICAL' } else { 'FAIL' }
    note = 'Owner response only; software did not infer physical output.'
}
$destination = Join-Path (Split-Path -Parent $StatePath) 'owner-acceptance.json'
$record | ConvertTo-Json | Set-Content -LiteralPath $destination -Encoding UTF8
$record | Format-List
if ($PhysicalPagePrinted -ne 'yes') { exit 1 }
