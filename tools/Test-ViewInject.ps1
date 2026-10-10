# Test-ViewInject.ps1 -- drive AztViewInject: host pixels INSIDE the running game.
#
#   .\tools\Test-ViewInject.ps1
#
# This is hybrid option 1 end to end. Writing the viewport surface from the host does not
# work -- it is a shared pool the 2D/UI paths rewrite every frame. So the guest does the
# copy instead: AztViewInject runs late in the frame and copies from a staging buffer in
# the overlay's BSS, which is the one region a host write survives in.
#
# THE FIRST CHECK IS THE COUNTER, and it is deliberately the first thing reported.
# AztViewInject increments aztInjCount before any early-out, so if the counter does not
# advance the hook site simply is not on the per-frame path and everything after it is
# meaningless. That was the one thing this experiment must not have to infer.
#
# Overlay layout (image-linear; obj1, so runtime is +0x1F0000):
#   0x133370 aztInjCount    0x133374 aztInjEnable
#   0x133378 aztInjX        0x13337C aztInjY
#   0x133380 aztInjW        0x133384 aztInjH
#   0x138000 staging buffer (NOT part of AZTCODE.BIN -- the loader only reads 16 KB)

[CmdletBinding()]
param(
    [long]$Count  = 0x133370,
    [long]$Enable = 0x133374,
    [long]$VarX   = 0x133378,
    [long]$VarY   = 0x13337C,
    [long]$VarW   = 0x133380,
    [long]$VarH   = 0x133384,
    [long]$BufAt  = 0x138000,
    [string]$OutDir = 'C:\Games\azrael-inject'
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $OutDir | Out-Null

$g = Get-AztGuestBase
function RdU32([long]$lin) { [BitConverter]::ToUInt32((Read-AztGuest -Base $g -Lin $lin -Length 4), 0) }
function WrU32([long]$lin, [uint32]$v) {
    [void][AztTool.ProcMem]::Write($g.ProcessId, ($g.MemBase + $lin + 0x1F0000), [BitConverter]::GetBytes($v))
}

# ---- 1. is the hook even on the per-frame path? -----------------------------
$c0 = RdU32 $Count
Start-Sleep -Milliseconds 700
$c1 = RdU32 $Count
Write-Host ("aztInjCount: {0} -> {1}  ({2} calls in 700 ms)" -f $c0, $c1, ($c1 - $c0))
if ($c1 -le $c0) {
    Write-Host ""
    Write-Host "THE HOOK IS NOT FIRING. 0x1434B is not reached on the normal per-frame path," -ForegroundColor Yellow
    Write-Host "so the hook site has to move. Nothing below would mean anything -- stopping." -ForegroundColor Yellow
    return
}
Write-Host "-> the hook runs every frame." -ForegroundColor Green

$w = RdU32 $VarW; $h = RdU32 $VarH; $x = RdU32 $VarX; $y = RdU32 $VarY
Write-Host ("rectangle {0}x{1} at ({2},{3}); staging buffer at guest 0x{4:X}" -f $w, $h, $x, $y, $BufAt)

# ---- 2. fill the staging buffer --------------------------------------------
# Broad diagonal bands plus a bright border: unmistakably not the game's own art.
$img = New-Object byte[] ($w * $h)
$shades = @(32, 150, 230)
for ($row = 0; $row -lt $h; $row++) {
    $base = $row * $w
    for ($col = 0; $col -lt $w; $col++) {
        $v = $shades[([int](($col + $row) / 24)) % 3]
        if ($row -lt 3 -or $row -ge ($h - 3) -or $col -lt 3 -or $col -ge ($w - 3)) { $v = 255 }
        $img[$base + $col] = [byte]$v
    }
}
[void][AztTool.ProcMem]::Write($g.ProcessId, ($g.MemBase + $BufAt + 0x1F0000), $img)

# the staging buffer is overlay BSS, so this SHOULD survive where the surface did not
Start-Sleep -Milliseconds 500
$back = [AztTool.ProcMem]::Read($g.ProcessId, ($g.MemBase + $BufAt + 0x1F0000), 256)
$same = 0; for ($i = 0; $i -lt 256; $i++) { if ($back[$i] -eq $img[$i]) { $same++ } }
Write-Host ("staging buffer still holds the pattern after 500 ms: {0}/256 bytes" -f $same)

# ---- 3. turn injection on and look at the screen ----------------------------
try {
    WrU32 $Enable 1
    Start-Sleep -Milliseconds 800

    $vb = (@([AztTool.ProcMem]::Regions($g.ProcessId, 0x7FFFFFFFFFFF) |
              Where-Object { $_.Size -ge 60MB -and $_.Size -le 80MB })[0]).Base
    $stride = 2048; $rows = 900
    $buf = [AztTool.ProcMem]::Read($g.ProcessId, ($vb + 0x140000), ($stride * $rows))
    $bmp = New-Object System.Drawing.Bitmap($stride, $rows, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
    $pal = $bmp.Palette
    for ($i = 0; $i -lt 256; $i++) { $pal.Entries[$i] = [System.Drawing.Color]::FromArgb(255, $i, $i, $i) }
    $bmp.Palette = $pal
    $rect = New-Object System.Drawing.Rectangle(0, 0, $stride, $rows)
    $d = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
    for ($r = 0; $r -lt $rows; $r++) {
        [System.Runtime.InteropServices.Marshal]::Copy($buf, $r * $stride, [IntPtr]($d.Scan0.ToInt64() + $r * $d.Stride), $stride)
    }
    $bmp.UnlockBits($d)
    $out = Join-Path $OutDir 'injected.png'
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    Write-Host ("display dumped -> {0}" -f $out)

    # did the pattern reach the SURFACE? read it back through the engine's own pointer
    $desc = [BitConverter]::ToUInt32((Read-AztGuest -Base $g -Lin 0x14745C -Length 4 -Obj2), 0)
    $dd = [AztTool.ProcMem]::Read($g.ProcessId, ($g.MemBase + $desc), 0x3C)
    $pix = [BitConverter]::ToUInt32($dd, 0x1C)
    $srow = [AztTool.ProcMem]::Read($g.ProcessId, ($g.MemBase + $pix + ($y + 10) * 1024 + $x), $w)
    $hits = 0; foreach ($b in $srow) { if ($b -eq 255 -or $b -eq 230 -or $b -eq 150 -or $b -eq 32) { $hits++ } }
    Write-Host ("viewport surface row {0}: {1}/{2} bytes match the injected palette" -f ($y + 10), $hits, $w)
    if ($hits -gt ($w * 0.8)) {
        Write-Host "INJECTION CONFIRMED -- host pixels are surviving in the guest's viewport." -ForegroundColor Green
    } else {
        Write-Host "the pattern is not in the surface; the hook fires but runs too early." -ForegroundColor Yellow
    }
}
finally {
    WrU32 $Enable 0
    Start-Sleep -Milliseconds 300
    Write-Host ("injection disabled (aztInjEnable = {0})" -f (RdU32 $Enable)) -ForegroundColor Green
}
