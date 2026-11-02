[CmdletBinding()]
param(
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m0\test-documents'
}

$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$manifestPath = Join-Path $OutputDirectory 'manifest.json'
$ownedNames = @('m0-text-test.txt', 'm0-pdf-image-test.pdf', 'm0-duplex-color-test.pdf', 'manifest.json')
$existingOwnedNames = @($ownedNames | Where-Object { Test-Path -LiteralPath (Join-Path $OutputDirectory $_) })
if ($existingOwnedNames.Count -gt 0) {
    $existingManifestIsOwned = $false
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $existingManifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
            $existingManifestIsOwned = $existingManifest.schema -eq 'quirewire.m0.test-documents.v1'
        }
        catch { $existingManifestIsOwned = $false }
    }
    if (-not $existingManifestIsOwned) {
        throw "Output contains one or more target filenames without a valid QuireWire ownership manifest: $($existingOwnedNames -join ', '). Refusing to overwrite."
    }
}

function ConvertTo-PdfLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)

    return $Value.Replace('\', '\\').Replace('(', '\(').Replace(')', '\)')
}

function New-CheckerImageHex {
    param(
        [Parameter(Mandatory = $true)][byte[]]$ColorA,
        [Parameter(Mandatory = $true)][byte[]]$ColorB
    )

    $builder = [System.Text.StringBuilder]::new()
    for ($y = 0; $y -lt 16; $y++) {
        for ($x = 0; $x -lt 16; $x++) {
            $color = if ((($x + $y) % 2) -eq 0) { $ColorA } else { $ColorB }
            foreach ($component in $color) {
                [void]$builder.Append($component.ToString('X2'))
            }
        }
    }
    [void]$builder.Append('>')
    return $builder.ToString()
}

function Write-SimplePdf {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Objects,
        [Parameter(Mandatory = $true)][int]$RootObjectNumber
    )

    $encoding = [System.Text.Encoding]::ASCII
    $stream = [System.IO.MemoryStream]::new()
    try {
        $writeAscii = {
            param([string]$Text)
            $bytes = $encoding.GetBytes($Text)
            $stream.Write($bytes, 0, $bytes.Length)
        }

        & $writeAscii "%PDF-1.4`n"
        $offsets = [System.Collections.Generic.List[long]]::new()
        [void]$offsets.Add(0)

        for ($index = 0; $index -lt $Objects.Count; $index++) {
            [void]$offsets.Add($stream.Position)
            & $writeAscii ("{0} 0 obj`n{1}`nendobj`n" -f ($index + 1), $Objects[$index])
        }

        $xrefOffset = $stream.Position
        & $writeAscii ("xref`n0 {0}`n" -f ($Objects.Count + 1))
        & $writeAscii "0000000000 65535 f `n"
        for ($index = 1; $index -lt $offsets.Count; $index++) {
            & $writeAscii ("{0:D10} 00000 n `n" -f $offsets[$index])
        }
        & $writeAscii ("trailer`n<< /Size {0} /Root {1} 0 R >>`nstartxref`n{2}`n%%EOF`n" -f ($Objects.Count + 1), $RootObjectNumber, $xrefOffset)

        [System.IO.File]::WriteAllBytes($Path, $stream.ToArray())
    }
    finally {
        $stream.Dispose()
    }
}

$generatedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$textSource = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\test-data\m0-text-test.txt'))
$textDestination = Join-Path $OutputDirectory 'm0-text-test.txt'
Copy-Item -LiteralPath $textSource -Destination $textDestination -Force

$imageHex = New-CheckerImageHex -ColorA ([byte[]](220, 35, 55)) -ColorB ([byte[]](20, 110, 210))
$pageText = ConvertTo-PdfLiteral "Generated UTC: $generatedUtc"
$content = @"
BT
/F1 20 Tf
72 730 Td
(QuireWire M0 PDF/image test) Tj
/F1 11 Tf
0 -24 Td
(Required path: Windows app -> Microsoft IPP Class Driver -> CUPS -> USB printer) Tj
0 -18 Td
($pageText) Tj
0 -18 Td
(Token: QUIREWIRE-M0-PDF-IMAGE-2026) Tj
ET
q
180 0 0 180 72 430 cm
/Im1 Do
Q
BT
/F1 11 Tf
72 390 Td
(Confirm that the red and blue checkerboard is visible and the text is legible.) Tj
ET
"@ -replace "`r`n", "`n"

$onePageObjects = @(
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 6 0 R >> >> /Contents 4 0 R >>',
    ("<< /Length {0} >>`nstream`n{1}endstream" -f ([System.Text.Encoding]::ASCII.GetByteCount($content)), $content),
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    ("<< /Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length {0} >>`nstream`n{1}`nendstream" -f ([System.Text.Encoding]::ASCII.GetByteCount($imageHex)), $imageHex)
)
Write-SimplePdf -Path (Join-Path $OutputDirectory 'm0-pdf-image-test.pdf') -Objects $onePageObjects -RootObjectNumber 1

$frontImageHex = New-CheckerImageHex -ColorA ([byte[]](235, 45, 60)) -ColorB ([byte[]](250, 190, 30))
$backImageHex = New-CheckerImageHex -ColorA ([byte[]](25, 150, 90)) -ColorB ([byte[]](45, 95, 210))
$frontContent = @"
BT
/F1 26 Tf
72 725 Td
(QuireWire optional duplex test - FRONT / PAGE 1) Tj
/F1 12 Tf
0 -30 Td
(Token: QUIREWIRE-M0-DUPLEX-FRONT-2026) Tj
ET
q
220 0 0 220 72 420 cm
/Im1 Do
Q
"@ -replace "`r`n", "`n"
$backContent = @"
BT
/F1 26 Tf
72 725 Td
(QuireWire optional duplex test - BACK / PAGE 2) Tj
/F1 12 Tf
0 -30 Td
(Token: QUIREWIRE-M0-DUPLEX-BACK-2026) Tj
ET
q
220 0 0 220 72 420 cm
/Im2 Do
Q
"@ -replace "`r`n", "`n"

$duplexObjects = @(
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 6 0 R >> /XObject << /Im1 7 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 6 0 R >> /XObject << /Im2 9 0 R >> >> /Contents 8 0 R >>',
    ("<< /Length {0} >>`nstream`n{1}endstream" -f ([System.Text.Encoding]::ASCII.GetByteCount($frontContent)), $frontContent),
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    ("<< /Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length {0} >>`nstream`n{1}`nendstream" -f ([System.Text.Encoding]::ASCII.GetByteCount($frontImageHex)), $frontImageHex),
    ("<< /Length {0} >>`nstream`n{1}endstream" -f ([System.Text.Encoding]::ASCII.GetByteCount($backContent)), $backContent),
    ("<< /Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length {0} >>`nstream`n{1}`nendstream" -f ([System.Text.Encoding]::ASCII.GetByteCount($backImageHex)), $backImageHex)
)
Write-SimplePdf -Path (Join-Path $OutputDirectory 'm0-duplex-color-test.pdf') -Objects $duplexObjects -RootObjectNumber 1

$manifest = [ordered]@{
    schema = 'quirewire.m0.test-documents.v1'
    generatedUtc = $generatedUtc
    files = @(
        [ordered]@{ name = 'm0-text-test.txt'; purpose = 'Required one-page text print from Notepad or another normal Windows text application' },
        [ordered]@{ name = 'm0-pdf-image-test.pdf'; purpose = 'Required one-page PDF/image print from a normal Windows PDF viewer' },
        [ordered]@{ name = 'm0-duplex-color-test.pdf'; purpose = 'Optional two-page color and duplex capability check' }
    )
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Host "Created M0 test documents in: $OutputDirectory"
Get-ChildItem -LiteralPath $OutputDirectory | Select-Object Name, Length, LastWriteTimeUtc

