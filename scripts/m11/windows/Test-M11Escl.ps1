[CmdletBinding()]
param(
    [string]$Address = '127.0.0.1',
    [ValidateRange(1, 65535)]
    [int]$Port = 8645,
    [ValidateRange(1, 30)]
    [int]$TimeoutSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$parsedAddress = [Net.IPAddress]::Parse($Address)
if ($parsedAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
    $parsedAddress.Equals([Net.IPAddress]::Any) -or $parsedAddress.IsIPv6Multicast) {
    throw 'Address must be one exact IPv4 endpoint.'
}
$uri = [Uri]::new("http://$Address`:$Port/eSCL/ScannerCapabilities")
$request = [Net.HttpWebRequest]::CreateHttp($uri)
$request.Method = 'GET'
$request.Accept = 'text/xml, application/xml'
$request.Timeout = $TimeoutSeconds * 1000
$request.ReadWriteTimeout = $TimeoutSeconds * 1000
$request.AllowAutoRedirect = $false
$request.Proxy = $null
$response = $null
$stream = $null
$memory = [IO.MemoryStream]::new()
try {
    $response = [Net.HttpWebResponse]$request.GetResponse()
    if ([int]$response.StatusCode -ne 200 -or
        $response.ContentType -notmatch '(?i)(?:application|text)/xml') {
        throw "eSCL capability probe returned HTTP $([int]$response.StatusCode) $($response.ContentType)."
    }
    $stream = $response.GetResponseStream()
    $buffer = [byte[]]::new(8192)
    while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        if ($memory.Length + $count -gt 524288) {
            throw 'eSCL capability response exceeded the 512 KiB safety limit.'
        }
        $memory.Write($buffer, 0, $count)
    }
}
finally {
    if ($stream) { $stream.Dispose() }
    if ($response) { $response.Dispose() }
}

$settings = [Xml.XmlReaderSettings]::new()
$settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
$settings.XmlResolver = $null
$settings.MaxCharactersInDocument = 524288
$inputStream = [IO.MemoryStream]::new($memory.ToArray(), $false)
$reader = [Xml.XmlReader]::Create($inputStream, $settings)
$document = [Xml.XmlDocument]::new()
$document.XmlResolver = $null
try { $document.Load($reader) }
finally {
    $reader.Dispose()
    $inputStream.Dispose()
    $memory.Dispose()
}

function Get-LocalText([string]$Name) {
    @($document.SelectNodes("//*[local-name()='$Name']") | ForEach-Object {
        $_.InnerText.Trim()
    } | Where-Object { $_ }) | Select-Object -Unique
}

$makeModel = @(Get-LocalText 'MakeAndModel') | Select-Object -First 1
$uuid = @(Get-LocalText 'UUID') | Select-Object -First 1
$sources = @()
if ($document.SelectSingleNode("//*[local-name()='Platen' or local-name()='PlatenInputCaps']")) {
    $sources += 'platen'
}
if ($document.SelectSingleNode("//*[local-name()='Adf' or local-name()='AdfSimplexInputCaps' or local-name()='AdfDuplexInputCaps']")) {
    $sources += 'adf'
}
$formats = @(@(Get-LocalText 'DocumentFormat') + @(Get-LocalText 'DocumentFormatExt') | Select-Object -Unique)
$colors = @(Get-LocalText 'ColorMode')
$resolutions = @(Get-LocalText 'XResolution' | ForEach-Object { [int]$_ } |
    Where-Object { $_ -ge 50 -and $_ -le 2400 } | Sort-Object -Unique)
if (-not $makeModel -or $sources.Count -eq 0 -or $formats.Count -eq 0) {
    throw 'eSCL capabilities omitted the model, scan source, or document formats.'
}

[pscustomobject]@{
    schema = 'quirewire.m11.escl-probe.v1'
    endpoint = $uri.AbsoluteUri
    http_status = 200
    make_model = [string]$makeModel
    uuid = if ($uuid) { [string]$uuid } else { $null }
    sources = @($sources)
    color_modes = @($colors)
    document_formats = @($formats)
    resolutions_dpi = @($resolutions)
    scan_content_retained = $false
} | ConvertTo-Json -Depth 5
