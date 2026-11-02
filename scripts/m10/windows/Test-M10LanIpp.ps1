[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ipaddress]$Address,

    [ValidateRange(1, 65535)]
    [int]$Port = 8644,

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$Queue = 'QuireWire_DCP_L2600D'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
    $Address.Equals([ipaddress]::Loopback)) {
    throw 'Address must be the approved non-loopback IPv4 LAN address.'
}

Add-Type -AssemblyName System.Net.Http
$bytes = [Collections.Generic.List[byte]]::new()
function Add-U16([int]$Value) {
    $bytes.Add([byte](($Value -shr 8) -band 255))
    $bytes.Add([byte]($Value -band 255))
}
function Add-Text([byte]$Tag, [string]$Name, [string]$Value) {
    $bytes.Add($Tag)
    $nameBytes = [Text.Encoding]::UTF8.GetBytes($Name)
    Add-U16 $nameBytes.Length
    $bytes.AddRange($nameBytes)
    $valueBytes = [Text.Encoding]::UTF8.GetBytes($Value)
    Add-U16 $valueBytes.Length
    $bytes.AddRange($valueBytes)
}

$printerUri = "ipp://$($Address.IPAddressToString):$Port/printers/$Queue"
$httpUri = "http://$($Address.IPAddressToString):$Port/printers/$Queue"
$bytes.AddRange([byte[]](2, 0, 0, 11, 0, 0, 0, 1, 1))
Add-Text 0x47 'attributes-charset' 'utf-8'
Add-Text 0x48 'attributes-natural-language' 'en'
Add-Text 0x45 'printer-uri' $printerUri
$bytes.Add(3)

$client = [Net.Http.HttpClient]::new()
try {
    $client.Timeout = [TimeSpan]::FromSeconds(10)
    $content = [Net.Http.ByteArrayContent]::new($bytes.ToArray())
    $content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/ipp')
    $response = $client.PostAsync($httpUri, $content).GetAwaiter().GetResult()
    $body = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $valid = [int]$response.StatusCode -eq 200 -and $body.Length -ge 9 -and
        $body[0] -eq 2 -and $body[1] -eq 0 -and $body[2] -eq 0 -and $body[3] -eq 0
    [pscustomobject]@{
        schema = 'quirewire.m10.lan-ipp-probe.v1'
        ok = $valid
        endpoint = $printerUri
        http_status = [int]$response.StatusCode
        content_type = [string]$response.Content.Headers.ContentType
        ipp_version = if ($body.Length -ge 2) { "$($body[0]).$($body[1])" } else { $null }
        ipp_status = if ($body.Length -ge 4) { '0x{0:X2}{1:X2}' -f $body[2], $body[3] } else { $null }
        response_bytes = $body.Length
    } | ConvertTo-Json
    if (-not $valid) { exit 1 }
}
finally {
    $client.Dispose()
}
