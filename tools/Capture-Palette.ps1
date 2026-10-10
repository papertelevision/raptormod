# Capture-Palette.ps1 -- read the game's LIVE 256-colour palette, empirically.
#
#   .\tools\Capture-Palette.ps1
#
# Anything the host draws into the viewport has to be expressed in the game's own palette,
# which is merged at runtime from several PCX files and is not a file we can just read.
# So it is MEASURED: paint known indices through the injection path and read the resulting
# colours out of DOSBox's 32-bit display surface.
#
# DISPLAY GEOMETRY, derived rather than assumed (a 256-band chart makes it self-evident):
# band spacing came out at 8192 bytes for 2 game rows, so the display is 1024 px wide,
# 32-bit, 4096 bytes per row, 1:1 with the game -- NOT the 2x-scaled 2048-stride surface
# an earlier session assumed.
#
# THE MISTAKE THIS TOOL EXISTS TO AVOID: the first two attempts used index 0 and index 255
# as probes and markers. Both are black in this palette, so "fill 0 then fill 255" changed
# nothing (longest changing run: 3 bytes) and a 255 marker was invisible to a non-zero
# search. Probe indices MUST be verified to differ before anything is built on them.

[CmdletBinding()]
param(
    [string]$Overlay = 'C:\Games\AzraelsTear-Modded\GAME\AZRAEL\AZTCODE.BIN',
    # DERIVED FROM THE MANIFEST, not hard-coded. These were 1024/576/4096, the geometry of a
    # resolution the game no longer runs at -- and the search at the bottom of this block
    # looks for `mov eax, W*H`, so a stale W/H does not find a wrong buffer, it finds NOTHING.
    # The stored azrael-palette.pal dates from 2026-09-27, before 1600x1200 and before the HUD
    # was rebuilt, which is why re-running this matters: the live palette is merged at runtime
    # from several PCX files and 7.6-40.6% of every host frame lands on indices 1..53, the
    # HUD's own range.
    [int]$W = 0,
    [int]$H = 0,
    [int]$Stride = 0,             # display bytes per row (screen width x 4)
    [string]$Manifest = '',
    [string]$OutDir = 'C:\Games\azrael-inject'
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')
Add-Type -AssemblyName System.Drawing

if (-not $Manifest) { $Manifest = Join-Path $toolDir '..\AztMod.manifest.json' }
$_man = Get-Content (Resolve-Path $Manifest).Path -Raw | ConvertFrom-Json
if ($W -le 0)      { $W = [int]$_man.view.injW }
if ($H -le 0)      { $H = [int]$_man.view.injH }
if ($Stride -le 0) { $Stride = [int]$_man.view.screenW * 4 }
Write-Host ("injection buffer {0}x{1}, display stride {2} bytes ({3} px x 4)" -f $W, $H, $Stride, ($Stride/4))
New-Item -ItemType Directory -Force $OutDir | Out-Null

$b = [IO.File]::ReadAllBytes($Overlay)
$bp = 0; $en = 0
for ($i = 0; $i -lt $b.Length - 16; $i++) {
    if ($b[$i] -eq 0xB8 -and [BitConverter]::ToUInt32($b, $i+1) -eq ($W*$H) -and
        $b[$i+5] -eq 0xE8 -and $b[$i+10] -eq 0x89 -and $b[$i+11] -eq 0x86) { $bp = [BitConverter]::ToUInt32($b, $i+12); break }
}
for ($i = 0; $i -lt $b.Length - 8; $i++) {
    if ($b[$i] -eq 0x8B -and $b[$i+1] -eq 0x9E -and $b[$i+6] -eq 0x85 -and $b[$i+7] -eq 0xDB) { $en = [BitConverter]::ToUInt32($b, $i+2); break }
}
if (-not $bp -or -not $en) { throw 'overlay symbols not found' }

$g = Get-AztGuestBase
$buf = [BitConverter]::ToUInt32((Read-AztGuest -Base $g -Lin $bp -Length 4), 0)
if ($buf -lt 0x1000) { throw 'staging buffer not allocated' }
$vb = (@([AztTool.ProcMem]::Regions($g.ProcessId, 0x7FFFFFFFFFFF) |
          Where-Object { $_.Size -ge 60MB -and $_.Size -le 80MB })[0]).Base
Write-Host ("staging 0x{0:X}, display region 0x{1:X11}" -f $buf, $vb)

$frame = New-Object byte[] ($W * $H)
$rowbuf = New-Object byte[] $W
function PushFrame { [void][AztTool.ProcMem]::Write($g.ProcessId, ($g.MemBase + $buf), $frame) }
function FillIdx([byte]$v) { for ($i = 0; $i -lt $frame.Length; $i++) { $frame[$i] = $v }; PushFrame }

[void][AztTool.ProcMem]::Write($g.ProcessId, ($g.MemBase + $en + 0x1F0000), [BitConverter]::GetBytes([uint32]1))

try {
    # ---- 1. find the viewport, using two indices PROVEN to differ ------------
    $probeA = 0; $probeB = 0; $first = -1
    foreach ($pair in @(@(100,200), @(64,192), @(40,160), @(20,220))) {
        FillIdx ([byte]$pair[0]); Start-Sleep -Milliseconds 650; $A = [AztTool.ProcMem]::Read($g.ProcessId, $vb, 20MB)
        FillIdx ([byte]$pair[1]); Start-Sleep -Milliseconds 650; $B = [AztTool.ProcMem]::Read($g.ProcessId, $vb, 20MB)
        $f = -1; $n = 0
        for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { if ($f -lt 0) { $f = $i }; $n++ } }
        Write-Host ("  probe {0}/{1}: {2:N0} bytes differ" -f $pair[0], $pair[1], $n)
        if ($n -gt 200000) { $probeA = $pair[0]; $probeB = $pair[1]; $first = $f; break }
    }
    if ($first -lt 0) { throw 'no index pair produced a visible change -- is injection on and the game in a room?' }
    $base = $first
    Write-Host ("viewport row 0 at display +0x{0:X7} (probe pair {1}/{2})" -f $base, $probeA, $probeB) -ForegroundColor Green

    # ---- 2. the band chart --------------------------------------------------
    # index i on game rows 2i..2i+1, so band i sits at base + 2*i*Stride
    for ($y = 0; $y -lt $H; $y++) {
        $v = if ($y -lt 512) { [int][Math]::Floor($y / 2) } else { 0 }   # [int](511/2) ROUNDS to 256
        for ($x = 0; $x -lt $W; $x++) { $rowbuf[$x] = [byte]$v }
        [Array]::Copy($rowbuf, 0, $frame, $y * $W, $W)
    }
    PushFrame
    Start-Sleep -Milliseconds 900
    $D = [AztTool.ProcMem]::Read($g.ProcessId, $vb, 20MB)

    $pal = New-Object byte[] 768
    for ($idx = 0; $idx -lt 256; $idx++) {
        # middle of the band's first row. Was a literal 2048 = the midpoint of a 1024-px
    # surface; at any other width that samples off-centre or past the row entirely.
    $off = $base + (2 * $idx) * $Stride + [int]($Stride / 2)
        if ($off + 4 -gt $D.Length) { throw "band $idx runs past the captured buffer" }
        $pal[$idx*3]     = $D[$off+2]
        $pal[$idx*3 + 1] = $D[$off+1]
        $pal[$idx*3 + 2] = $D[$off]
    }

    # ---- 3. self-checks ------------------------------------------------------
    # The two probe indices were measured directly in step 1, so the chart must agree.
    $pa = ('{0:X2}{1:X2}{2:X2}' -f $pal[$probeA*3], $pal[$probeA*3+1], $pal[$probeA*3+2])
    $pb = ('{0:X2}{1:X2}{2:X2}' -f $pal[$probeB*3], $pal[$probeB*3+1], $pal[$probeB*3+2])
    $ea = [BitConverter]::ToUInt32($A, $first); $eb = [BitConverter]::ToUInt32($B, $first)
    $ma = ('{0:X2}{1:X2}{2:X2}' -f (($ea -shr 16) -band 255), (($ea -shr 8) -band 255), ($ea -band 255))
    $mb = ('{0:X2}{1:X2}{2:X2}' -f (($eb -shr 16) -band 255), (($eb -shr 8) -band 255), ($eb -band 255))
    Write-Host ""
    Write-Host ("  chart says index {0} = #{1}; the direct fill measured #{2}  -> {3}" -f $probeA, $pa, $ma, $(if ($pa -eq $ma) { 'MATCH' } else { 'MISMATCH' }))
    Write-Host ("  chart says index {0} = #{1}; the direct fill measured #{2}  -> {3}" -f $probeB, $pb, $mb, $(if ($pb -eq $mb) { 'MATCH' } else { 'MISMATCH' }))
    if ($pa -ne $ma -or $pb -ne $mb) { throw 'band alignment does not agree with the direct measurement -- not writing a palette' }

    $d = @{}; for ($i = 0; $i -lt 256; $i++) { $d[('{0},{1},{2}' -f $pal[$i*3], $pal[$i*3+1], $pal[$i*3+2])] = 1 }
    Write-Host ("  {0} distinct colours across 256 indices" -f $d.Count)

    [IO.File]::WriteAllBytes((Join-Path $OutDir 'azrael-palette.pal'), $pal)
    $bm = New-Object System.Drawing.Bitmap(512, 512)
    $gr = [System.Drawing.Graphics]::FromImage($bm)
    for ($i = 0; $i -lt 256; $i++) {
        $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, $pal[$i*3], $pal[$i*3+1], $pal[$i*3+2]))
        $gr.FillRectangle($br, ($i % 16)*32, [int][Math]::Floor($i/16)*32, 32, 32); $br.Dispose()
    }
    $gr.Dispose(); $bm.Save((Join-Path $OutDir 'azrael-palette.png'), [System.Drawing.Imaging.ImageFormat]::Png); $bm.Dispose()
    Write-Host ("  palette -> {0}\azrael-palette.pal and .png" -f $OutDir) -ForegroundColor Green
}
finally {
    [void][AztTool.ProcMem]::Write($g.ProcessId, ($g.MemBase + $en + 0x1F0000), [BitConverter]::GetBytes([uint32]0))
    Write-Host 'injection disabled' -ForegroundColor Green
}
