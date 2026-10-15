# Export-LiveTextures.ps1 -- AZTTEX.BIN -> named PNGs, straight from the live game.
#
# Each record is a 64-byte header followed by payloads that are present ONLY if their
# pointer passed the stub's range check, so the decoder has to re-derive which ones
# were actually written rather than assume a fixed layout:
#
#   +0x00 'TEX1'  +0x04 texPtr  +0x08 handle  +0x0C width  +0x10 height  +0x14 log2w
#   +0x18 p04     +0x1C p20     +0x20 p24     +0x24 p54 (-> D3DRMIMAGE)
#   +0x28 probeLen  +0x2C bufLen (= w*h)  +0x30 palLen
#   +0x34 pix (= image+0x1C, buffer1)     +0x38 pal (= image+0x38)
#
# payloads, each written only if its pointer was in [FLOOR, 0x3000000):
#   probe(256 from p04), buf(bufLen from p20), buf(bufLen from p24),
#   1024 from p54, bufLen from pix, 1024 from pal
#
# THE FLOOR IS 0x80000, NOT 0x800000. The texture pixel buffers sit at
# 0x38A038..0x582038, and the stub's floor was lowered to reach them -- which also
# changed which of the EARLIER payloads pass, so this must use the same value or the
# payload offsets drift and every image comes out as garbage.
#
# The palette is (r, g, b, flags) per entry. A texture whose name contains '#' is
# chroma-keyed on magenta by the engine, so those entries are written with alpha 0.

[CmdletBinding()]
param(
    [string]$Path = 'C:\Games\RaptorMod\game\GAME\AZRAEL\AZTTEX.BIN',
    [Parameter(Mandatory)][string]$OutDir
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not (Test-Path $Path)) { throw "not found: $Path" }
New-Item -ItemType Directory -Force $OutDir | Out-Null

$FLOOR = 0x00080000
$CEIL  = 0x03000000
$bytes = [IO.File]::ReadAllBytes($Path)
Write-Host ("{0}: {1:N0} bytes" -f (Split-Path $Path -Leaf), $bytes.Length)

function U32 { param([int]$o) [BitConverter]::ToUInt32($bytes, $o) }
function InRange { param($p) ($p -ge $FLOOR) -and ($p -lt $CEIL) }
function AsciiAt { param([int]$o)
    $s = ''
    for ($k = 0; $k -lt 80; $k++) {
        $c = $bytes[$o + $k]; if ($c -eq 0) { break }
        if ($c -lt 32 -or $c -gt 126) { return '' }
        $s += [char]$c
    }
    $s
}

$pos = 0; $n = 0; $wrote = 0
$byName = @{}          # filename -> png, so payload-less repeat records still resolve
$rows = New-Object System.Collections.ArrayList
while ($pos + 64 -le $bytes.Length) {
    if ((U32 $pos) -ne 0x31584554) { break }                 # 'TEX1'
    $hnd = [int](U32 ($pos + 0x08)); $w = [int](U32 ($pos + 0x0C)); $h = [int](U32 ($pos + 0x10))
    $p04 = U32 ($pos + 0x18); $p20 = U32 ($pos + 0x1C); $p24 = U32 ($pos + 0x20); $p54 = U32 ($pos + 0x24)
    $probeLen = [int](U32 ($pos + 0x28)); $bufLen = [int](U32 ($pos + 0x2C)); $palLen = [int](U32 ($pos + 0x30))
    $pixPtr = U32 ($pos + 0x34); $palPtr = U32 ($pos + 0x38)

    $bufOk = ($bufLen -gt 0 -and $bufLen -lt 0x100000)

    # NEW RECORD SHAPE. The header is 128 bytes and carries the .azf FILENAME at +0x40;
    # the four old probe blobs are gone (they only ever existed to identify which pointer
    # held the pixels, which is settled). A record now has EITHER pixels+palette, or
    # nothing at all -- nothing when this filename's pixels were already written earlier
    # in the session, which is how revisits and shared textures stop costing anything.
    #
    # Presence is decided by probing for the next record's magic, exactly as before: a
    # guess that does not land on 'TEX1' or EOF is wrong, so this is self-validating.
    $off = $pos + 128
    $oPix = -1; $oPal = -1
    $guess = $off + $bufLen + 1024
    if ($bufOk -and $guess -le $bytes.Length -and
        ($guess -eq $bytes.Length -or (U32 $guess) -eq 0x31584554)) {
        $oPix = $off; $oPal = $off + $bufLen; $off = $guess
    } elseif ($off -lt $bytes.Length -and $off -le ($bytes.Length - 4) -and (U32 $off) -ne 0x31584554) {
        Write-Host ("  record {0}: cannot place the payloads -- stopping" -f $n) -ForegroundColor Yellow
        break
    }
    # the filename is in the header now
    $name = AsciiAt ($pos + 0x40)       # the filename, straight out of the header
    $leaf = if ($name) { (($name -split '\\')[-1] -replace '\.azf$','') } else { ("tex{0}" -f $hnd) }

    if ($oPix -lt 0 -or $oPal -lt 0) {
        # No payload: this filename's pixels were written by an earlier record. Record the
        # handle -> file mapping anyway so per-face materials still resolve. If the name
        # was NEVER seen with pixels, that is a filename-hash collision and it is said so
        # loudly -- which is the whole reason the name is in every header.
        if ($byName.ContainsKey($leaf)) {
            [void]$rows.Add([pscustomobject]@{ Handle = $hnd; TexPtr = ("0x{0:X8}" -f (U32 ($pos + 0x04))); Name = $leaf; File = $byName[$leaf]; W = $w; H = $h })
            Write-Host ("  {0,4}  {1,4}x{2,-4} {3,-16} repeat -> {4}" -f $hnd,$w,$h,$leaf,$byName[$leaf]) -ForegroundColor DarkGray
        } else {
            Write-Host ("  {0,4}  {1,4}x{2,-4} {3,-16} NO PIXELS ANYWHERE -- filename hash collision" -f $hnd,$w,$h,$leaf) -ForegroundColor Red
        }
    } else {
        $keyed = $leaf.Contains('#')
        $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
        $pal = $bmp.Palette
        for ($e = 0; $e -lt 256; $e++) {
            $r = $bytes[$oPal + $e*4]; $g = $bytes[$oPal + $e*4 + 1]; $b = $bytes[$oPal + $e*4 + 2]
            $a = 255
            if ($keyed -and $r -gt 200 -and $g -lt 60 -and $b -gt 200) { $a = 0 }   # magenta key
            $pal.Entries[$e] = [System.Drawing.Color]::FromArgb($a, $r, $g, $b)
        }
        $bmp.Palette = $pal
        $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
        $dat = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
                             [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
        for ($y = 0; $y -lt $h; $y++) {
            [System.Runtime.InteropServices.Marshal]::Copy($bytes, $oPix + $y*$w,
                [IntPtr]($dat.Scan0.ToInt64() + $y*$dat.Stride), $w)
        }
        $bmp.UnlockBits($dat)
        $safe = $leaf -replace '[^A-Za-z0-9_\-]','_'
        $file = "{0}.png" -f $safe
        $bmp.Save((Join-Path $OutDir $file), [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        # how many distinct palette indices are actually used -- a blank image would
        # be 1, and is the giveaway that the pixel pointer was wrong
        $seen = @{}
        for ($s = 0; $s -lt [Math]::Min($bufLen, 4096); $s++) { $seen[$bytes[$oPix + $s]] = $true }
        Write-Host ("  {0,4}  {1,4}x{2,-4} {3,-16} {4,3} distinct idx{5} -> {6}" -f `
                    $hnd, $w, $h, $leaf, $seen.Count, $(if ($keyed) { ' keyed' } else { '' }), $file)
        # TexPtr is the join key for PER-FACE materials: a Face's +0x3C holds this
        # exact pointer, so faces can be matched to textures without going through the
        # handle at all -- which matters for the meshes that use several textures.
        [void]$rows.Add([pscustomobject]@{ Handle = $hnd; TexPtr = ("0x{0:X8}" -f (U32 ($pos + 0x04))); Name = $leaf; File = $file; W = $w; H = $h })
        $byName[$leaf] = $file
        $wrote++
    }
    $pos = $off; $n++
}

Write-Host ""
Write-Host ("{0} records, {1} PNGs written, {2:N0} of {3:N0} bytes consumed" -f $n, $wrote, $pos, $bytes.Length)
$rows | Export-Csv -NoTypeInformation -Encoding utf8 (Join-Path $OutDir 'textures.csv')
Write-Host ("index -> {0}" -f (Join-Path $OutDir 'textures.csv'))
