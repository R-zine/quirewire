[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Approve', 'Remove', 'Status')]
    [string]$Action,

    [Parameter(Mandatory)]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$configPathFull = [IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath $configPathFull -PathType Leaf)) {
    throw "PrintBridge configuration does not exist: $configPathFull"
}
$lines = @([IO.File]::ReadAllLines($configPathFull))
if ($lines -notcontains 'schema=printbridge.m6.config.v1') {
    throw 'The configuration schema is not the supported owner-protected schema.'
}
$scanPorts = @($lines | Where-Object { $_ -like 'scanner_port=*' })
$approvals = @($lines | Where-Object { $_ -like 'lan_scan_port=*' })
$aliases = @($lines | Where-Object { $_ -like 'lan_interface_alias=*' })
$subnets = @($lines | Where-Object { $_ -like 'lan_subnet=*' })
if ($scanPorts.Count -gt 1 -or $approvals.Count -gt 1 -or
    $aliases.Count -ne 1 -or $subnets.Count -ne 1) {
    throw 'A valid approved LAN is required before scanner exposure can be changed.'
}
$scannerPort = if ($scanPorts.Count -eq 1) {
    $scanPorts[0].Substring('scanner_port='.Length)
} else { '8645' }
if ($scannerPort -notmatch '^[0-9]{1,5}$' -or [int]$scannerPort -lt 1 -or
    [int]$scannerPort -gt 65535) {
    throw 'The configured scanner port is invalid.'
}
if ($approvals.Count -eq 1 -and
    $approvals[0].Substring('lan_scan_port='.Length) -ne $scannerPort) {
    throw 'The existing scanner approval does not match the configured scanner port.'
}

if ($Action -eq 'Status') {
    [pscustomobject]@{
        schema = 'printbridge.m11.scan-approval.v1'
        approved = $approvals.Count -eq 1
        port = [int]$scannerPort
        interface_alias = $aliases[0].Substring('lan_interface_alias='.Length)
        subnet = $subnets[0].Substring('lan_subnet='.Length)
    } | ConvertTo-Json
    exit 0
}

$next = @($lines | Where-Object { $_ -notlike 'lan_scan_port=*' })
if ($Action -eq 'Approve') { $next += "lan_scan_port=$scannerPort" }
$temporary = Join-Path ([IO.Path]::GetDirectoryName($configPathFull)) `
    ('.m11-scan-approval-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    [IO.File]::WriteAllText($temporary, (($next -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    Set-Acl -LiteralPath $temporary -AclObject (Get-Acl -LiteralPath $configPathFull)
    Move-Item -LiteralPath $temporary -Destination $configPathFull -Force
}
finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
        Remove-Item -LiteralPath $temporary -Force
    }
}
[pscustomobject]@{
    schema = 'printbridge.m11.scan-approval.v1'
    action = $Action
    approved = $Action -eq 'Approve'
    port = [int]$scannerPort
} | ConvertTo-Json
