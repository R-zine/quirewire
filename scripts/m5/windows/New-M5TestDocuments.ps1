[CmdletBinding()]
param([string]$OutputDirectory)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m5\test-documents'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$manifestPath = Join-Path $OutputDirectory 'manifest.json'
$ownedNames = @('m5-standard-app-text.txt', 'm5-standard-app-pdf.pdf', 'manifest.json')
$existing = @($ownedNames | Where-Object { Test-Path -LiteralPath (Join-Path $OutputDirectory $_) })
if ($existing.Count -gt 0) {
    $owned = $false
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $owned = $manifest.schema -eq 'quirewire.m5.test-documents.v1'
        }
        catch { $owned = $false }
    }
    if (-not $owned) {
        throw "Refusing to overwrite target files without the M5 ownership manifest: $($existing -join ', ')"
    }
}
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory

function ConvertTo-PdfLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return $Value.Replace('\', '\\').Replace('(', '\(').Replace(')', '\)')
}

function New-CheckerImageHex {
    $builder = [Text.StringBuilder]::new()
    for ($y = 0; $y -lt 16; $y++) {
        for ($x = 0; $x -lt 16; $x++) {
            $color = if ((($x + $y) % 2) -eq 0) { [byte[]](35, 85, 180) } else { [byte[]](225, 155, 25) }
            foreach ($component in $color) { [void]$builder.Append($component.ToString('X2')) }
        }
    }
    [void]$builder.Append('>')
    return $builder.ToString()
}

function Write-SimplePdf {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Objects
    )
    $encoding = [Text.Encoding]::ASCII
    $stream = [IO.MemoryStream]::new()
    try {
        $write = {
            param([string]$Text)
            $bytes = $encoding.GetBytes($Text)
            $stream.Write($bytes, 0, $bytes.Length)
        }
        & $write "%PDF-1.4`n"
        $offsets = [Collections.Generic.List[long]]::new()
        [void]$offsets.Add(0)
        for ($index = 0; $index -lt $Objects.Count; $index++) {
            [void]$offsets.Add($stream.Position)
            & $write ("{0} 0 obj`n{1}`nendobj`n" -f ($index + 1), $Objects[$index])
        }
        $xref = $stream.Position
        & $write ("xref`n0 {0}`n" -f ($Objects.Count + 1))
        & $write "0000000000 65535 f `n"
        for ($index = 1; $index -lt $offsets.Count; $index++) {
            & $write ("{0:D10} 00000 n `n" -f $offsets[$index])
        }
        & $write ("trailer`n<< /Size {0} /Root 1 0 R >>`nstartxref`n{1}`n%%EOF`n" -f ($Objects.Count + 1), $xref)
        [IO.File]::WriteAllBytes($Path, $stream.ToArray())
    }
    finally { $stream.Dispose() }
}

$sourceText = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\test-data\m5-standard-app-text.txt'))
Copy-Item -LiteralPath $sourceText -Destination (Join-Path $OutputDirectory 'm5-standard-app-text.txt') -Force

$generatedUtc = [DateTime]::UtcNow.ToString('o')
$escapedTime = ConvertTo-PdfLiteral -Value $generatedUtc
$content = @"
BT
/F1 20 Tf
72 730 Td
(QuireWire M5 standard-application PDF test) Tj
/F1 11 Tf
0 -25 Td
(Windows PDF viewer -> Microsoft IPP Class Driver -> CUPS -> USB printer) Tj
0 -18 Td
(Generated UTC: $escapedTime) Tj
0 -18 Td
(Acceptance token: QUIREWIRE-M5-PDF-IMAGE-2026) Tj
ET
q
210 0 0 210 72 410 cm
/Im1 Do
Q
BT
/F1 11 Tf
72 370 Td
(Confirm that this checkerboard and all text are legible on the physical sheet.) Tj
ET
"@ -replace "`r`n", "`n"
$imageHex = New-CheckerImageHex
$objects = @(
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >> /Contents 4 0 R >>',
    ("<< /Length {0} >>`nstream`n{1}endstream" -f ([Text.Encoding]::ASCII.GetByteCount($content)), $content),
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    ("<< /Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length {0} >>`nstream`n{1}`nendstream" -f ([Text.Encoding]::ASCII.GetByteCount($imageHex)), $imageHex)
)
Write-SimplePdf -Path (Join-Path $OutputDirectory 'm5-standard-app-pdf.pdf') -Objects $objects

[ordered]@{
    schema = 'quirewire.m5.test-documents.v1'
    generatedUtc = $generatedUtc
    files = @(
        [ordered]@{ name = 'm5-standard-app-text.txt'; token = 'QUIREWIRE-M5-TEXT-2026'; application = 'Notepad' },
        [ordered]@{ name = 'm5-standard-app-pdf.pdf'; token = 'QUIREWIRE-M5-PDF-IMAGE-2026'; application = 'normal PDF viewer' }
    )
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Get-ChildItem -LiteralPath $OutputDirectory | Select-Object Name, Length, LastWriteTimeUtc
