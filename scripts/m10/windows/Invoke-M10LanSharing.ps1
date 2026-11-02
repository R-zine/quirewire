[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Status', 'InstallFirewall', 'RemoveFirewall')]
    [string]$Action,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9A-Fa-f-]{36}$')]
    [string]$OwnerToken,

    [Parameter(Mandatory)]
    [ValidateRange(1, 65535)]
    [int]$IppPort,

    [ValidateRange(0, 65535)]
    [int]$ScanPort = 0,

    [Parameter(Mandatory)]
    [string]$AgentExecutable,

    [Parameter(Mandatory)]
    [string]$VBoxHeadlessExecutable,

    [string]$ApprovedInterfaceAlias,
    [string]$ApprovedSubnet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$protocol = 'QUIREWIRE_LAN_V2'
$marker = "quirewire.m10.firewall.v1 owner $($OwnerToken.ToLowerInvariant())"
$ippRuleName = "QuireWire $($OwnerToken.ToLowerInvariant()) LAN IPP"
$scanRuleName = "QuireWire $($OwnerToken.ToLowerInvariant()) LAN eSCL"
$mdnsRuleName = "QuireWire $($OwnerToken.ToLowerInvariant()) LAN mDNS"

function ConvertTo-Field([AllowEmptyString()][string]$Value) {
    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
}

function Write-Record(
    [bool]$Ok,
    [bool]$NetworkAllowed,
    [AllowEmptyString()][string]$InterfaceAlias,
    [AllowEmptyString()][string]$NetworkCategory,
    [AllowEmptyString()][string]$Address,
    [bool]$FirewallReady,
    [AllowEmptyString()][string]$Reason,
    [AllowEmptyString()][string]$ErrorCode = '',
    [AllowEmptyString()][string]$ErrorMessage = ''
) {
    $protocol
    'ok=' + $Ok.ToString().ToLowerInvariant()
    'network_allowed=' + $NetworkAllowed.ToString().ToLowerInvariant()
    'interface_alias=' + (ConvertTo-Field $InterfaceAlias)
    'network_category=' + (ConvertTo-Field $NetworkCategory)
    'address=' + (ConvertTo-Field $Address)
    'firewall_ready=' + $FirewallReady.ToString().ToLowerInvariant()
    'reason=' + (ConvertTo-Field $Reason)
    'error_code=' + $ErrorCode
    'error_message=' + (ConvertTo-Field $ErrorMessage)
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-Ipv4Number([Net.IPAddress]$Address) {
    $bytes = $Address.GetAddressBytes()
    if ($bytes.Count -ne 4) { throw 'Only IPv4 addresses are supported.' }
    [uint64]$value = 0
    foreach ($byte in $bytes) { $value = ($value -shl 8) -bor [uint64]$byte }
    $value
}

function Get-SubnetRecord([string]$Subnet) {
    if ($Subnet -notmatch '^([0-9]{1,3}(?:\.[0-9]{1,3}){3})/([0-9]{1,2})$') {
        throw 'ApprovedSubnet must be canonical IPv4 CIDR.'
    }
    $network = [Net.IPAddress]::Parse($Matches[1])
    $prefix = [int]$Matches[2]
    if ($prefix -lt 8 -or $prefix -gt 30) {
        throw 'ApprovedSubnet prefix must be between /8 and /30.'
    }
    [uint64]$fullMask = [Convert]::ToUInt64('FFFFFFFF', 16)
    [uint64]$mask = ($fullMask -shl (32 - $prefix)) -band $fullMask
    [uint64]$networkNumber = ConvertTo-Ipv4Number $network
    if (($networkNumber -band $mask) -ne $networkNumber) {
        throw 'ApprovedSubnet must use its canonical network address.'
    }
    [pscustomobject]@{ network = $networkNumber; prefix = $prefix; mask = $mask }
}

function Test-IpInSubnet([string]$Address, [object]$SubnetRecord) {
    [uint64]$number = ConvertTo-Ipv4Number ([Net.IPAddress]::Parse($Address))
    ($number -band $SubnetRecord.mask) -eq $SubnetRecord.network
}

function Test-RemoteAddressMatchesApproved([string]$RemoteAddress) {
    if ($RemoteAddress -eq $ApprovedSubnet) { return $true }
    if ($RemoteAddress -notmatch '^([^/]+)/([^/]+)$') { return $false }
    $remoteNetworkText = $Matches[1]
    $remoteMaskText = $Matches[2]
    if (-not $remoteMaskText.Contains('.')) { return $false }
    try {
        $approved = Get-SubnetRecord $ApprovedSubnet
        [uint64]$remoteNetwork = ConvertTo-Ipv4Number ([Net.IPAddress]::Parse($remoteNetworkText))
        [uint64]$remoteMask = ConvertTo-Ipv4Number ([Net.IPAddress]::Parse($remoteMaskText))
        return $remoteNetwork -eq $approved.network -and $remoteMask -eq $approved.mask
    }
    catch { return $false }
}

function Get-ApprovedLan {
    $hasAlias = -not [string]::IsNullOrWhiteSpace($ApprovedInterfaceAlias)
    $hasSubnet = -not [string]::IsNullOrWhiteSpace($ApprovedSubnet)
    if ($hasAlias -ne $hasSubnet) {
        throw 'ApprovedInterfaceAlias and ApprovedSubnet must be provided together.'
    }
    if (-not $hasAlias) {
        return [pscustomobject]@{
            available = $false
            interface_alias = ''
            network_category = ''
            address = ''
            reason = 'LAN sharing is off until an interface and local subnet are explicitly approved.'
        }
    }
    if ($ApprovedInterfaceAlias.IndexOfAny([char[]]"`r`n") -ge 0) {
        throw 'ApprovedInterfaceAlias contains a newline.'
    }
    $subnetRecord = Get-SubnetRecord $ApprovedSubnet
    $profiles = @(Get-NetConnectionProfile -InterfaceAlias $ApprovedInterfaceAlias -ErrorAction Stop)
    if ($profiles.Count -ne 1) {
        throw 'The approved interface must have exactly one Windows network profile.'
    }
    $profile = $profiles[0]
    if ($profile.IPv4Connectivity -eq 'Disconnected') {
        return [pscustomobject]@{
            available = $false; interface_alias = $ApprovedInterfaceAlias
            network_category = [string]$profile.NetworkCategory; address = ''
            reason = 'The explicitly approved local-network interface is disconnected.'
        }
    }
    $defaultRoute = @(Get-NetRoute -InterfaceIndex $profile.InterfaceIndex -AddressFamily IPv4 `
        -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Where-Object { $_.State -eq 'Alive' })
    if ($defaultRoute.Count -eq 0) {
        return [pscustomobject]@{
            available = $false; interface_alias = $ApprovedInterfaceAlias
            network_category = [string]$profile.NetworkCategory; address = ''
            reason = 'The explicitly approved interface is not an active default route.'
        }
    }
    $addresses = @(Get-NetIPAddress -InterfaceIndex $profile.InterfaceIndex -AddressFamily IPv4 `
        -ErrorAction Stop | Where-Object {
            $_.AddressState -eq 'Preferred' -and (Test-IpInSubnet $_.IPAddress $subnetRecord)
        })
    if ($addresses.Count -ne 1) {
        return [pscustomobject]@{
            available = $false; interface_alias = $ApprovedInterfaceAlias
            network_category = [string]$profile.NetworkCategory; address = ''
            reason = 'The approved interface does not have exactly one preferred address in the approved subnet.'
        }
    }
    [pscustomobject]@{
        available = $true
        interface_alias = [string]$profile.InterfaceAlias
        network_category = [string]$profile.NetworkCategory
        address = [string]$addresses[0].IPAddress
        reason = "The explicitly approved interface and subnet $ApprovedSubnet are active."
    }
}

function Get-ExactRule([string]$Name) {
    $rules = @(Get-NetFirewallRule -DisplayName $Name -ErrorAction SilentlyContinue)
    if ($rules.Count -gt 1) {
        throw "Multiple firewall rules use the owned name '$Name'; refusing mutation."
    }
    if ($rules.Count -eq 0) { return $null }
    if ($rules[0].Description -ne $marker) {
        throw "Firewall rule '$Name' does not have the exact QuireWire ownership marker."
    }
    $rules[0]
}

function Test-Rule(
    [string]$Name,
    [ValidateSet('TCP', 'UDP')][string]$Protocol,
    [int]$Port,
    [string]$Program
) {
    if ([string]::IsNullOrWhiteSpace($ApprovedInterfaceAlias) -or
        [string]::IsNullOrWhiteSpace($ApprovedSubnet)) { return $false }
    $rule = Get-ExactRule $Name
    if (-not $rule) { return $false }
    $portFilter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule
    $appFilter = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $rule
    $addressFilter = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule
    $interfaceFilter = Get-NetFirewallInterfaceFilter -AssociatedNetFirewallRule $rule
    $profiles = [string]$rule.Profile
    $remote = @($addressFilter.RemoteAddress)
    $interfaces = @($interfaceFilter.InterfaceAlias)
    $rule.Enabled -eq 'True' -and $rule.Direction -eq 'Inbound' -and
        $rule.Action -eq 'Allow' -and $profiles -match 'Private' -and $profiles -match 'Public' -and
        [string]$portFilter.Protocol -eq $Protocol -and
        [string]$portFilter.LocalPort -eq [string]$Port -and
        [string]$appFilter.Program -ieq [IO.Path]::GetFullPath($Program) -and
        $remote.Count -eq 1 -and (Test-RemoteAddressMatchesApproved $remote[0]) -and
        $interfaces.Count -eq 1 -and $interfaces[0] -eq $ApprovedInterfaceAlias
}

function Install-ExactRule(
    [string]$Name,
    [ValidateSet('TCP', 'UDP')][string]$Protocol,
    [int]$Port,
    [string]$Program
) {
    if ([string]::IsNullOrWhiteSpace($ApprovedInterfaceAlias) -or
        [string]::IsNullOrWhiteSpace($ApprovedSubnet)) {
        throw 'Firewall installation requires explicit interface and subnet approval.'
    }
    $null = Get-SubnetRecord $ApprovedSubnet
    $existing = Get-ExactRule $Name
    if ($existing -and (Test-Rule $Name $Protocol $Port $Program)) { return }
    if ($existing) { $existing | Remove-NetFirewallRule }
    $resolvedProgram = [IO.Path]::GetFullPath($Program)
    if (-not (Test-Path -LiteralPath $resolvedProgram -PathType Leaf)) {
        throw "Firewall program does not exist: $resolvedProgram"
    }
    New-NetFirewallRule -DisplayName $Name -Description $marker -Group 'QuireWire' `
        -Direction Inbound -Action Allow -Enabled True -Profile Private,Public `
        -InterfaceAlias $ApprovedInterfaceAlias -RemoteAddress $ApprovedSubnet `
        -Protocol $Protocol -LocalPort $Port -Program $resolvedProgram | Out-Null
}

try {
    $lan = Get-ApprovedLan
    switch ($Action) {
        'InstallFirewall' {
            if (-not (Test-IsAdministrator)) {
                throw 'Installing scoped firewall rules requires a one-time administrator approval.'
            }
            Install-ExactRule $ippRuleName TCP $IppPort $VBoxHeadlessExecutable
            if ($ScanPort -gt 0) {
                Install-ExactRule $scanRuleName TCP $ScanPort $VBoxHeadlessExecutable
            }
            else {
                $scanRule = Get-ExactRule $scanRuleName
                if ($scanRule) { $scanRule | Remove-NetFirewallRule }
            }
            Install-ExactRule $mdnsRuleName UDP 5353 $AgentExecutable
        }
        'RemoveFirewall' {
            if (-not (Test-IsAdministrator)) {
                throw 'Removing scoped firewall rules requires administrator approval.'
            }
            foreach ($name in @($ippRuleName, $scanRuleName, $mdnsRuleName)) {
                $rule = Get-ExactRule $name
                if ($rule) { $rule | Remove-NetFirewallRule }
            }
        }
    }
    $scanFirewallReady = $ScanPort -eq 0 -or
        (Test-Rule $scanRuleName TCP $ScanPort $VBoxHeadlessExecutable)
    $firewallReady = (Test-Rule $ippRuleName TCP $IppPort $VBoxHeadlessExecutable) -and
        $scanFirewallReady -and
        (Test-Rule $mdnsRuleName UDP 5353 $AgentExecutable)
    $reason = if (-not $lan.available) { $lan.reason }
    elseif (-not $firewallReady) {
        'LAN sharing is off because the exact interface/subnet firewall rules are not installed. Run QuireWire Repair and approve the scoped elevation.'
    }
    else { 'The explicitly approved local subnet and exact firewall rules are ready.' }
    Write-Record $true ($lan.available -and $firewallReady) $lan.interface_alias `
        $lan.network_category $lan.address $firewallReady $reason
}
catch {
    Write-Record $false $false '' '' '' $false '' 'lan_provider_failed' $_.Exception.Message
    exit 1
}
