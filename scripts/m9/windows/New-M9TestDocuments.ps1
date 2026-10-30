[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [ValidateRange(20, 100)][int]$SequentialJobCount = 20,
    [ValidateRange(10, 100)][int]$LongPdfPages = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot '..\..\..\artifacts\m9\documents'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$manifestPath = Join-Path $OutputDirectory 'manifest.json'

if (Test-Path -LiteralPath $OutputDirectory -PathType Container) {
    $existingManifest = $null
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try { $existingManifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json }
        catch { $existingManifest = $null }
    }
    $ownedFiles = @(Get-ChildItem -LiteralPath $OutputDirectory -File -ErrorAction SilentlyContinue)
    if ($ownedFiles.Count -gt 0 -and
        ($null -eq $existingManifest -or $existingManifest.schema -ne 'printbridge.m9.test-documents.v1')) {
        throw 'Refusing to overwrite a non-empty document directory without the M9 ownership manifest.'
    }
    foreach ($file in $ownedFiles) {
        if ($file.Name -notmatch '^m9-(job-[0-9]{2}\.(txt|pdf)|long-[0-9]+-page\.pdf|manifest\.json)$') {
            throw "Refusing to remove an unrecognized file from the owned document directory: $($file.Name)"
        }
        Remove-Item -LiteralPath $file.FullName -Force
    }
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function ConvertTo-PdfLiteral([string]$Value) {
    $Value.Replace('\', '\\').Replace('(', '\(').Replace(')', '\)')
}

function Write-TextPdf([string]$Path, [string]$TokenPrefix, [int]$Pages) {
    $objects = [Collections.Generic.List[string]]::new()
    $pageStart = 3
    $contentStart = $pageStart + $Pages
    $fontObject = $contentStart + $Pages
    $kids = 0..($Pages - 1) | ForEach-Object { "$(($pageStart + $_)) 0 R" }
    $objects.Add('<< /Type /Catalog /Pages 2 0 R >>')
    $objects.Add("<< /Type /Pages /Kids [$($kids -join ' ')] /Count $Pages >>")
    for ($index = 0; $index -lt $Pages; $index++) {
        $objects.Add("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 $fontObject 0 R >> >> /Contents $(($contentStart + $index)) 0 R >>")
    }
    for ($index = 0; $index -lt $Pages; $index++) {
        $pageNumber = $index + 1
        $token = ConvertTo-PdfLiteral "$TokenPrefix-PAGE-$('{0:D2}' -f $pageNumber)"
        $content = @"
BT
/F1 22 Tf
72 720 Td
(PrintBridge M9 release-candidate PDF) Tj
/F1 12 Tf
0 -32 Td
(Page $pageNumber of $Pages) Tj
0 -22 Td
(Token: $token) Tj
0 -22 Td
(Windows spooler -> Microsoft IPP -> CUPS -> USB printer) Tj
0 -22 Td
(Physical output requires owner confirmation.) Tj
ET
"@ -replace "`r`n", "`n"
        $objects.Add("<< /Length $([Text.Encoding]::ASCII.GetByteCount($content)) >>`nstream`n$content" + 'endstream')
    }
    $objects.Add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')

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
        $offsets.Add(0)
        for ($index = 0; $index -lt $objects.Count; $index++) {
            $offsets.Add($stream.Position)
            & $write ("{0} 0 obj`n{1}`nendobj`n" -f ($index + 1), $objects[$index])
        }
        $xref = $stream.Position
        & $write ("xref`n0 {0}`n" -f ($objects.Count + 1))
        & $write "0000000000 65535 f `n"
        for ($index = 1; $index -lt $offsets.Count; $index++) {
            & $write ("{0:D10} 00000 n `n" -f $offsets[$index])
        }
        & $write ("trailer`n<< /Size {0} /Root 1 0 R >>`nstartxref`n{1}`n%%EOF`n" -f ($objects.Count + 1), $xref)
        [IO.File]::WriteAllBytes($Path, $stream.ToArray())
    }
    finally { $stream.Dispose() }
}

$jobs = [Collections.Generic.List[object]]::new()
for ($sequence = 1; $sequence -le $SequentialJobCount; $sequence++) {
    if (($sequence % 2) -eq 1) {
        $name = 'm9-job-{0:D2}.txt' -f $sequence
        $token = 'PRINTBRIDGE-M9-TEXT-{0:D2}-2026' -f $sequence
        $content = @(
            'PrintBridge M9 sequential text job',
            "Sequence: $sequence of $SequentialJobCount",
            "Token: $token",
            'Windows spooler -> Microsoft IPP -> CUPS -> USB printer',
            'Physical output requires owner confirmation.',
            [char]12
        ) -join "`r`n"
        [IO.File]::WriteAllText((Join-Path $OutputDirectory $name), $content, [Text.Encoding]::ASCII)
        $jobs.Add([ordered]@{ sequence = $sequence; name = $name; format = 'text/plain'; token = $token })
    }
    else {
        $name = 'm9-job-{0:D2}.pdf' -f $sequence
        $token = 'PRINTBRIDGE-M9-PDF-{0:D2}-2026' -f $sequence
        Write-TextPdf -Path (Join-Path $OutputDirectory $name) -TokenPrefix $token -Pages 1
        $jobs.Add([ordered]@{ sequence = $sequence; name = $name; format = 'application/pdf'; token = $token })
    }
}
$longName = "m9-long-$LongPdfPages-page.pdf"
$longToken = 'PRINTBRIDGE-M9-LONG-PDF-2026'
Write-TextPdf -Path (Join-Path $OutputDirectory $longName) -TokenPrefix $longToken -Pages $LongPdfPages

[ordered]@{
    schema = 'printbridge.m9.test-documents.v1'
    generated_utc = [DateTime]::UtcNow.ToString('o')
    sequential_job_count = $SequentialJobCount
    jobs = $jobs
    long_pdf = [ordered]@{ name = $longName; format = 'application/pdf'; pages = $LongPdfPages; token_prefix = $longToken }
} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $manifestPath -Encoding utf8

[pscustomobject]@{
    schema = 'printbridge.m9.test-documents-result.v1'
    directory = $OutputDirectory
    sequential_jobs = $SequentialJobCount
    text_jobs = @($jobs | Where-Object format -eq 'text/plain').Count
    pdf_jobs = @($jobs | Where-Object format -eq 'application/pdf').Count
    long_pdf_pages = $LongPdfPages
} | ConvertTo-Json
