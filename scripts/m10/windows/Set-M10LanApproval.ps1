[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Approve', 'Remove', 'Status')]
    [string]$Action,

    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [string]$InterfaceAlias,
    [string]$Subnet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$configPathFull = [IO.Path]::GetFullPath($ConfigPath)

if (-not (Test-Path -LiteralPath $configPathFull -PathType Leaf)) {
    throw "QuireWire configuration does not exist: $configPathFull"
}

$lines = @([IO.File]::ReadAllLines($configPathFull))
if ($lines -notcontains 'schema=quirewire.m6.config.v1') {
    throw 'The configuration schema is not the supported owner-protected M6 schema.'
}
$aliases = @($lines | Where-Object { $_ -like 'lan_interface_alias=*' })
$subnets = @($lines | Where-Object { $_ -like 'lan_subnet=*' })
if ($aliases.Count -gt 1 -or $subnets.Count -gt 1 -or $aliases.Count -ne $subnets.Count) {
    throw 'LAN approval fields are duplicated or incomplete; refusing to guess.'
}

if ($Action -eq 'Status') {
    [pscustomobject]@{
        schema = 'quirewire.m10.lan-approval.v1'
        approved = $aliases.Count -eq 1
        interface_alias = if ($aliases.Count) { $aliases[0].Substring('lan_interface_alias='.Length) } else { $null }
        subnet = if ($subnets.Count) { $subnets[0].Substring('lan_subnet='.Length) } else { $null }
    } | ConvertTo-Json
    exit 0
}

$next = @($lines | Where-Object {
    $_ -notlike 'lan_interface_alias=*' -and $_ -notlike 'lan_subnet=*' -and
    $_ -notlike 'lan_scan_port=*'
})
if ($Action -eq 'Approve') {
    if ([string]::IsNullOrWhiteSpace($InterfaceAlias) -or
        $InterfaceAlias.IndexOfAny([char[]]"`r`n") -ge 0 -or $InterfaceAlias.Length -gt 128) {
        throw 'InterfaceAlias must be a non-empty single-line Windows interface alias.'
    }
    if ($Subnet -notmatch '^[0-9]{1,3}(?:\.[0-9]{1,3}){3}/(?:[89]|[12][0-9]|30)$') {
        throw 'Subnet must be an IPv4 CIDR with a /8 through /30 prefix.'
    }
    $profile = @(Get-NetConnectionProfile -InterfaceAlias $InterfaceAlias -ErrorAction Stop)
    if ($profile.Count -ne 1) {
        throw 'InterfaceAlias must identify exactly one current Windows network profile.'
    }
    $next += "lan_interface_alias=$InterfaceAlias"
    $next += "lan_subnet=$Subnet"
}

$temporary = Join-Path ([IO.Path]::GetDirectoryName($configPathFull)) `
    ('.m10-approval-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($temporary, (($next -join "`n") + "`n"), $encoding)
    Set-Acl -LiteralPath $temporary -AclObject (Get-Acl -LiteralPath $configPathFull)
    Move-Item -LiteralPath $temporary -Destination $configPathFull -Force
}
finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
        Remove-Item -LiteralPath $temporary -Force
    }
}

[pscustomobject]@{
    schema = 'quirewire.m10.lan-approval.v1'
    action = $Action
    approved = $Action -eq 'Approve'
    interface_alias = if ($Action -eq 'Approve') { $InterfaceAlias } else { $null }
    subnet = if ($Action -eq 'Approve') { $Subnet } else { $null }
} | ConvertTo-Json
