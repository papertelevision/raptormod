# Test-InjectProbes.ps1 -- which point in the frame can host pixels survive?
#
#   .\tools\Test-InjectProbes.ps1
#
# Six candidate hook sites, each with its own counter and its own horizontal band, so a
# single run answers both questions instead of one guess per play session:
#
#   counter advances -> the site IS on the per-frame path
#   band visible     -> the site is late enough for host pixels to survive the frame
#
# The counter matters because the first attempt hooked a site that never ran: without it
# a blank screen is indistinguishable from a broken copy loop.
#
# ADDRESSES ARE DISCOVERED, NOT HARD-CODED. Each probe stub ends with
#   89 C7  FF 86 <counter32>  B8 <index32>
# (mov edi,eax / inc dword [esi+counter] / mov eax,index), and AztInjBody starts with
#   8B 9E <enable32>  85 DB
# so both are recovered from AZTCODE.BIN itself. A rebuild shifts these; re-deriving them
# every run means the tool cannot silently read a stale address.

[CmdletBinding()]
param(
    [string]$Overlay = 'C:\Games\RaptorMod\game\GAME\AZRAEL\AZTCODE.BIN',
    [long]$OverlayBase = 0x133000,
    [long]$BufAt = 0x138000,
    [int]$InjW = 256,
    [int]$InjBand = 16,
    [string]$OutDir = 'C:\Games\RaptorMod\cache'
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $OutDir | Out-Null

# ---- discover the overlay symbols -------------------------------------------
$blob = [IO.File]::ReadAllBytes($Overlay)
$counters = @()
for ($i = 0; $i -lt $blob.Length - 16; $i++) {
    if ($blob[$i] -eq 0x89 -and $blob[$i+1] -eq 0xC7 -and $blob[$i+2] -eq 0xFF -and $blob[$i+3] -eq 0x86 -and $blob[$i+8] -eq 0xB8) {
        $counters += [pscustomobject]@{
            Index = [BitConverter]::ToUInt32($blob, $i + 9)
            Addr  = [BitConverter]::ToUInt32($blob, $i + 4)
        }
    }
}
$enable = 0
for ($i = 0; $i -lt $blob.Length - 8; $i++) {
    if ($blob[$i] -eq 0x8B -and $blob[$i+1] -eq 0x9E -and $blob[$i+6] -eq 0x85 -and $blob[$i+7] -eq 0xDB) {
        $enable = [BitConverter]::ToUInt32($blob, $i + 2); break
    }
}
if (-not $counters.Count) { throw "no probe stubs found in $Overlay -- is this the multi-probe build?" }
if (-not $enable) { throw "aztInjEnable not found in $Overlay" }
Write-Host ("{0} probes found; aztInjEnable at 0x{1:X}" -f $counters.Count, $enable)
$counters = $counters | Sort-Object Index

$SITES = @('0x1419D just after the 3D block', '0x141D2 after the 3D block',
           '0x143B4 HUD text', '0x143ED HUD text, later',
           '0x34328 LFB blitter A', '0x3534C LFB blitter B')

$g = Get-AztGuestBase
function RdU32([long]$lin) { [BitConverter]::ToUInt32((Read-AztGuest -Base $g -Lin $lin -Length 4), 0) }
function WrU32([long]$lin, [uint32]$v) {
    [void][AztTool.ProcMem]::Write($g.ProcessId, ($g.MemBase + $lin + 0x1F0000), [BitConverter]::GetBytes($v))
}

# ---- 1. which sites are on the per-frame path? ------------------------------
$before = @($counters | ForEach-Object { RdU32 $_.Addr })
Start-Sleep -Milliseconds 1000
$after  = @($counters | ForEach-Object { RdU32 $_.Addr })

Write-Host ""
Write-Host ("{0,-6} {1,-34} {2,12} {3}" -f 'probe', 'site', 'calls/sec', 'on the frame path?')
$live = @()
for ($i = 0; $i -lt $counters.Count; $i++) {
    $d = [int64]$after[$i] - [int64]$before[$i]
    $verdict = if ($d -gt 0) { 'YES' } else { 'no -- never runs' }
    if ($d -gt 0) { $live += $i }
    Write-Host ("{0,-6} {1,-34} {2,12} {3}" -f $counters[$i].Index, $SITES[$counters[$i].Index], $d, $verdict)
}
if (-not $live.Count) { Write-Host "`nNo probe fires at all -- stopping." -ForegroundColor Yellow; return }

# ---- 2. paint the bands -----------------------------------------------------
$img = New-Object byte[] ($InjW * $InjBand)
for ($row = 0; $row -lt $InjBand; $row++) {
    for ($col = 0; $col -lt $InjW; $col++) {
        $v = if ($row -lt 2 -or $row -ge ($InjBand - 2) -or $col -lt 2 -or $col -ge ($InjW - 2)) { 255 }
             else { @(32, 150, 230)[([int](($col + $row) / 16)) % 3] }
        $img[$row * $InjW + $col] = [byte]$v
    }
}
[void][AztTool.ProcMem]::Write($g.ProcessId, ($g.MemBase + $BufAt + 0x1F0000), $img)

try {
    WrU32 $enable 1
    Start-Sleep -Milliseconds 900

    # which bands actually landed in the surface the engine is about to blit?
    $desc = [BitConverter]::ToUInt32((Read-AztGuest -Base $g -Lin 0x14745C -Length 4 -Obj2), 0)
    $dd = [AztTool.ProcMem]::Read($g.ProcessId, ($g.MemBase + $desc), 0x3C)
    $pix = [BitConverter]::ToUInt32($dd, 0x1C)
    Write-Host ""
    Write-Host ("viewport surface at 0x{0:X} -- checking each band's middle row" -f $pix)
    $survived = @()
    foreach ($c in $counters) {
        $bandY = 80 + $c.Index * 24 + 8
        $row = [AztTool.ProcMem]::Read($g.ProcessId, ($g.MemBase + $pix + $bandY * 1024 + 384), $InjW)
        $hit = 0; foreach ($b in $row) { if ($b -eq 32 -or $b -eq 150 -or $b -eq 230 -or $b -eq 255) { $hit++ } }
        $pct = 100.0 * $hit / $InjW
        $ok = $pct -gt 80
        if ($ok) { $survived += $c.Index }
        Write-Host ("  probe {0}  row {1,3}  {2,6:N1}% injected  {3}" -f $c.Index, $bandY, $pct,
                    $(if ($ok) { 'SURVIVES' } else { '' }))
    }

    $vb = (@([AztTool.ProcMem]::Regions($g.ProcessId, 0x7FFFFFFFFFFF) |
              Where-Object { $_.Size -ge 60MB -and $_.Size -le 80MB })[0]).Base
    $stride = 2048; $rows = 700
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
    $out = Join-Path $OutDir 'probes.png'
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    Write-Host ""
    Write-Host ("display dumped -> {0}" -f $out)
    if ($survived.Count) {
        Write-Host ("SURVIVING PROBES: {0} -- these are the usable hook points." -f ($survived -join ', ')) -ForegroundColor Green
    } else {
        Write-Host "No band survived: every firing site is too early in the frame." -ForegroundColor Yellow
    }
}
finally {
    WrU32 $enable 0
    Start-Sleep -Milliseconds 300
    Write-Host ("injection disabled (aztInjEnable = {0})" -f (RdU32 $enable)) -ForegroundColor Green
}
