# Test-FullFrame.ps1 -- the host draws the whole 1024x576 viewport, and what it costs.
#
#   .\tools\Test-FullFrame.ps1
#   .\tools\Test-FullFrame.ps1 -Leave      # leave injection ON so you can look at it
#
# The 256x16 strip proved the mechanism. This is the same path at full size:
#   host writes 589,824 bytes -> AztInjBody rep movsd's them in -> the engine blits them
#
# The staging buffer is a GUEST HEAP allocation made at overlay init, so the first thing
# reported is whether that allocation actually succeeded -- 0 means the game could not
# spare 576 KB and everything after would be meaningless.
#
# FRAME RATE IS MEASURED BOTH WAYS, because a full-frame copy inside the emulated CPU is
# the one cost that could make this idea impractical. 147,456 dwords per frame is real
# work for DOSBox, and guessing at it would be worthless.

[CmdletBinding()]
param(
    [string]$Overlay = 'C:\Games\AzraelsTear-Modded\GAME\AZRAEL\AZTCODE.BIN',
    [int]$W = 1024,
    [int]$H = 576,
    [switch]$Leave,
    [string]$Image,                       # optional: an existing 1024x576 image to show
    [string]$OutDir = 'C:\Games\azrael-inject'
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $OutDir | Out-Null

# ---- discover the overlay symbols from the blob -----------------------------
$b = [IO.File]::ReadAllBytes($Overlay)
$bufPtrVar = 0; $enableVar = 0; $countVar = 0
for ($i = 0; $i -lt $b.Length - 16; $i++) {
    if ($b[$i] -eq 0xB8 -and [BitConverter]::ToUInt32($b, $i+1) -eq ($W * $H) -and
        $b[$i+5] -eq 0xE8 -and $b[$i+10] -eq 0x89 -and $b[$i+11] -eq 0x86) {
        $bufPtrVar = [BitConverter]::ToUInt32($b, $i+12); break
    }
}
for ($i = 0; $i -lt $b.Length - 8; $i++) {
    if ($b[$i] -eq 0x8B -and $b[$i+1] -eq 0x9E -and $b[$i+6] -eq 0x85 -and $b[$i+7] -eq 0xDB) {
        $enableVar = [BitConverter]::ToUInt32($b, $i+2); break
    }
}
for ($i = 0; $i -lt $b.Length - 10; $i++) {
    if ($b[$i] -eq 0x89 -and $b[$i+1] -eq 0xC7 -and $b[$i+2] -eq 0xFF -and $b[$i+3] -eq 0x86) {
        $countVar = [BitConverter]::ToUInt32($b, $i+4); break
    }
}
if (-not $bufPtrVar -or -not $enableVar) { throw "overlay symbols not found in $Overlay -- is this the full-frame build?" }
Write-Host ("aztInjEnable 0x{0:X}   aztInjBufPtr 0x{1:X}   aztInjCount0 0x{2:X}" -f $enableVar, $bufPtrVar, $countVar)

$g = Get-AztGuestBase
function RdU32([long]$lin) { [BitConverter]::ToUInt32((Read-AztGuest -Base $g -Lin $lin -Length 4), 0) }
function WrU32([long]$lin, [uint32]$v) {
    [void][AztTool.ProcMem]::Write($g.ProcessId, ($g.MemBase + $lin + 0x1F0000), [BitConverter]::GetBytes($v))
}

# ---- 1. did the allocation succeed? -----------------------------------------
$buf = RdU32 $bufPtrVar
Write-Host ("staging buffer: 0x{0:X}" -f $buf)
if ($buf -lt 0x1000) {
    Write-Host "ALLOCATION FAILED -- the game could not spare 576 KB. Nothing else would mean anything." -ForegroundColor Yellow
    return
}
Write-Host ("-> allocated {0:N0} bytes from the game's own heap" -f ($W * $H)) -ForegroundColor Green

# ---- 2. frame rate with injection OFF ---------------------------------------
function Fps([int]$ms = 3000) {
    $a = RdU32 $countVar
    Start-Sleep -Milliseconds $ms
    $c = RdU32 $countVar
    return (($c - $a) * 1000.0 / $ms)
}
WrU32 $enableVar 0
Start-Sleep -Milliseconds 400
$fpsOff = Fps
Write-Host ("frame rate, injection OFF: {0:N1} fps" -f $fpsOff)

# ---- 3. build a frame --------------------------------------------------------
$img = New-Object byte[] ($W * $H)
if ($Image -and (Test-Path $Image)) {
    # Use a real picture. It is reduced to the game's 8-bit indices by brightness only:
    # without the live palette this cannot be a correct colour match, and pretending
    # otherwise would be worse than saying so.
    $src = [System.Drawing.Image]::FromFile($Image)
    $bm = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gr = [System.Drawing.Graphics]::FromImage($bm)
    $gr.DrawImage($src, 0, 0, $W, $H); $gr.Dispose(); $src.Dispose()
    $rect = New-Object System.Drawing.Rectangle(0, 0, $W, $H)
    $d = $bm.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $px = New-Object 'int[]' ($W * $H)
    [System.Runtime.InteropServices.Marshal]::Copy($d.Scan0, $px, 0, $px.Length)
    $bm.UnlockBits($d); $bm.Dispose()
    for ($i = 0; $i -lt $px.Length; $i++) {
        $p = $px[$i]
        $lum = (0.299 * (($p -shr 16) -band 255) + 0.587 * (($p -shr 8) -band 255) + 0.114 * ($p -band 255))
        $img[$i] = [byte][int]$lum
    }
    Write-Host ("frame content: {0} (brightness-mapped to indices -- NOT a palette match)" -f (Split-Path $Image -Leaf))
} else {
    # A test card: horizontal index ramp plus a grid, so the whole viewport is obviously
    # host-drawn and any mis-stride would show up as a skew.
    for ($y = 0; $y -lt $H; $y++) {
        $row = $y * $W
        for ($x = 0; $x -lt $W; $x++) {
            $v = [int](($x * 256) / $W)
            if (($x % 64) -lt 2 -or ($y % 64) -lt 2) { $v = 255 }
            if ($y -lt 4 -or $y -ge ($H - 4) -or $x -lt 4 -or $x -ge ($W - 4)) { $v = 255 }
            $img[$row + $x] = [byte]$v
        }
    }
    Write-Host "frame content: index ramp + 64px grid test card"
}
[void][AztTool.ProcMem]::Write($g.ProcessId, ($g.MemBase + $buf), $img)

# ---- 4. frame rate with injection ON ----------------------------------------
WrU32 $enableVar 1
Start-Sleep -Milliseconds 600
$fpsOn = Fps
Write-Host ("frame rate, injection ON : {0:N1} fps" -f $fpsOn)
$cost = if ($fpsOff -gt 0) { 100.0 * ($fpsOff - $fpsOn) / $fpsOff } else { 0 }
Write-Host ("-> cost of a full-frame copy: {0:N1}%" -f $cost)

# ---- 5. did it land? ---------------------------------------------------------
$desc = [BitConverter]::ToUInt32((Read-AztGuest -Base $g -Lin 0x14745C -Length 4 -Obj2), 0)
$dd = [AztTool.ProcMem]::Read($g.ProcessId, ($g.MemBase + $desc), 0x3C)
$pix = [BitConverter]::ToUInt32($dd, 0x1C)
$mid = [AztTool.ProcMem]::Read($g.ProcessId, ($g.MemBase + $pix + 300 * $W), $W)
$match = 0
for ($x = 0; $x -lt $W; $x++) { if ($mid[$x] -eq $img[300 * $W + $x]) { $match++ } }
Write-Host ""
Write-Host ("viewport surface row 300: {0}/{1} bytes match the host frame ({2:N1}%)" -f $match, $W, (100.0 * $match / $W))
if ($match -gt ($W * 0.95)) {
    Write-Host "FULL-FRAME INJECTION CONFIRMED." -ForegroundColor Green
} else {
    Write-Host "the frame did not land intact." -ForegroundColor Yellow
}

if ($Leave) {
    Write-Host ""
    Write-Host "Injection left ON -- look at the game window." -ForegroundColor Green
} else {
    WrU32 $enableVar 0
    Start-Sleep -Milliseconds 300
    Write-Host ("injection disabled (aztInjEnable = {0})" -f (RdU32 $enableVar)) -ForegroundColor Green
}
