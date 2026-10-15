# Export-RoomTextures.ps1 -- decode a room's .RES textures to named PNGs.
#
#   .\tools\Export-RoomTextures.ps1 -Res R1 -OutDir design\room1-tex
#
# Why this exists alongside src\Texture-Tool.ps1: that script's [AztTool.Azf]::Read
# throws an index-out-of-range on R1.RES, while a tolerant walk of the SAME file
# consumes all 510,044 bytes across 22 records exactly. So the data is fine and the
# record walk here is deliberately defensive -- it validates each payload length
# against the bytes remaining and stops cleanly rather than running off the end.
#
# A .RES HAS NO NAMES AND NO INDEX. Records match the room's .XAF texture references
# by FIRST-APPEARANCE ORDER. Getting that wrong silently mislabels every texture in
# the room, so the names are recovered by scanning the .XAF for `*.azf` strings in
# file order and de-duplicating on first sight -- and the count is checked against
# the number of records, with a loud warning if they disagree.
#
# Record layout (from tools\AzfTool.cs):
#   dword payloadLength        bytes after this dword
#   D3DRMIMAGE, 60 bytes       width, height, aspectx, aspecty, depth, rgb,
#                              bytes_per_line, buffer1, buffer2, r/g/b/a masks,
#                              palette_size, palette*
#   palette, palette_size * 4  (r, g, b, flags)
#   pixels                     static-Huffman stream, decoded by Azf.Inflate

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Res,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$TexDir = 'C:\Games\RaptorMod\game\GAME\AZTEX'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$toolDir = Split-Path -Parent $PSCommandPath
if (-not ("AztTool.Azf" -as [type])) { Add-Type -Path (Join-Path $toolDir 'AzfTool.cs') }

$stem    = $Res -replace '\.(RES|XAF)$',''
$resPath = if (Test-Path $Res) { $Res } else { Join-Path $TexDir ("$stem.RES") }
$xafPath = Join-Path $TexDir ("$stem.XAF")
if (-not (Test-Path $resPath)) { throw "no such .RES: $resPath" }

# ---- names, in first-appearance order ---------------------------------------
$names = New-Object System.Collections.ArrayList
if (Test-Path $xafPath) {
    $xaf = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($xafPath))
    # Some .XAF files reference "name.azf", others "name.gif" -- CORICORI.XAF uses .gif, and
    # matching only .azf found ZERO names, which silently mislabels every texture in the room
    # as "unnamed". Match the `texture "..."` declaration itself and take the leaf, so both
    # forms work and a future third spelling shows up as a name rather than as nothing.
    foreach ($m in [regex]::Matches($xaf, 'texture\s+"([^"]+)"', 'IgnoreCase')) {
        $leaf = ($m.Groups[1].Value -split '[\\/]')[-1]
        if (-not $names.Contains($leaf)) { [void]$names.Add($leaf) }
    }
    Write-Host ("{0}: {1} distinct texture references, in first-appearance order" -f (Split-Path $xafPath -Leaf), $names.Count)
} else {
    Write-Host ("no {0} -- PNGs will be numbered only" -f (Split-Path $xafPath -Leaf)) -ForegroundColor Yellow
}

# ---- walk the records -------------------------------------------------------
$bytes = [IO.File]::ReadAllBytes($resPath)
Write-Host ("{0}: {1:N0} bytes" -f (Split-Path $resPath -Leaf), $bytes.Length)
New-Item -ItemType Directory -Force $OutDir | Out-Null

function U32 { param([int]$o) [BitConverter]::ToUInt32($bytes, $o) }

$pos = 0; $idx = 0; $written = 0
while ($pos + 4 -le $bytes.Length) {
    $len = [int64](U32 $pos)
    if ($len -le 60 -or ($pos + 4 + $len) -gt $bytes.Length) {
        if ($pos -ne $bytes.Length) {
            Write-Host ("  stopped at 0x{0:X}: payload {1:N0} does not fit in {2:N0} remaining" -f `
                        $pos, $len, ($bytes.Length - $pos - 4)) -ForegroundColor Yellow
        }
        break
    }
    $w   = [int](U32 ($pos + 4));  $h    = [int](U32 ($pos + 8))
    $dep = [int](U32 ($pos + 20)); $bpl  = [int](U32 ($pos + 28))
    $psz = [int](U32 ($pos + 56))

    if ($w -le 0 -or $h -le 0 -or $w -gt 2048 -or $h -gt 2048 -or $dep -ne 8 -or $psz -le 0 -or $psz -gt 256) {
        Write-Host ("  record {0}: implausible header ({1}x{2} depth {3} pal {4}) -- skipped" -f $idx,$w,$h,$dep,$psz) -ForegroundColor Yellow
        $pos += 4 + $len; $idx++; continue
    }

    $palOff = $pos + 4 + 60
    $pixOff = $palOff + $psz * 4
    try   { $pix = [AztTool.Azf]::Inflate($bytes, $pixOff) }
    catch { Write-Host ("  record {0}: pixel decode failed -- {1}" -f $idx, $_.Exception.Message) -ForegroundColor Yellow
            $pos += 4 + $len; $idx++; continue }

    if ($pix.Length -lt $bpl * $h) {
        Write-Host ("  record {0}: got {1:N0} pixel bytes, need {2:N0} -- skipped" -f $idx,$pix.Length,($bpl*$h)) -ForegroundColor Yellow
        $pos += 4 + $len; $idx++; continue
    }

    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
    $pal = $bmp.Palette
    for ($e = 0; $e -lt 256; $e++) {
        if ($e -lt $psz) {
            $pal.Entries[$e] = [System.Drawing.Color]::FromArgb(255,
                $bytes[$palOff + $e*4], $bytes[$palOff + $e*4 + 1], $bytes[$palOff + $e*4 + 2])
        } else {
            $pal.Entries[$e] = [System.Drawing.Color]::FromArgb(255, 0, 0, 0)
        }
    }
    $bmp.Palette = $pal
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $dat  = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
                          [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
    for ($y = 0; $y -lt $h; $y++) {
        [System.Runtime.InteropServices.Marshal]::Copy($pix, $y*$bpl,
            [IntPtr]($dat.Scan0.ToInt64() + $y*$dat.Stride), $w)
    }
    $bmp.UnlockBits($dat)

    $nm = if ($idx -lt $names.Count) { ($names[$idx] -replace '\.(azf|gif)$','') } else { 'unnamed' }
    $safe = $nm -replace '[^A-Za-z0-9_#\-]','_'
    $out = Join-Path $OutDir ("{0:d2}-{1}.png" -f $idx, $safe)
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host ("  {0,2}  {1,4}x{2,-4} pal {3,3}  -> {4}" -f $idx, $w, $h, $psz, (Split-Path $out -Leaf))
    $written++
    $pos += 4 + $len; $idx++
}

Write-Host ""
Write-Host ("{0} records walked, {1} PNGs written, {2:N0} of {3:N0} bytes consumed" -f `
            $idx, $written, $pos, $bytes.Length)
if ($names.Count -and $names.Count -ne $idx) {
    Write-Host ("WARNING: {0} .XAF names but {1} .RES records -- the name mapping is by" -f $names.Count, $idx) -ForegroundColor Yellow
    Write-Host  "         first-appearance order, so a mismatch means some labels are WRONG." -ForegroundColor Yellow
    Write-Host  "         Trust the index, not the name, until this is reconciled." -ForegroundColor Yellow
}
