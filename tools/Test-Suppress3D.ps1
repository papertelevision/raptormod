# Test-Suppress3D.ps1 -- can the 3D pass be suppressed while the HUD keeps drawing?
#
#   .\tools\Test-Suppress3D.ps1
#   .\tools\Test-Suppress3D.ps1 -Flag 0x15257C -HoldMs 1500
#
# The remaining half of unknown 8. NO CODE IS PATCHED and no file is modified: the engine
# already contains the switch.
#
#     00014158  cmp word [0x15257C], 0
#     00014160  jnz 0x1418C          <-- skips the whole 3D block
#     00014162  mov eax, [0x152138]  ; the viewport
#     00014182  call 0x3F0D0         ; render
#     00014187  call 0x3F1B0
#     0001418C  ... HUD work continues here
#
# Two flags gate that block, and the game sets them itself when a full-screen 2D view is
# up (0x1525F2 is referenced right beside the map viewer at 0x12954). So suppressing the
# 3D pass means writing a value the game writes anyway, through the host bridge -- which
# is far safer than NOPing instructions, and is trivially reversible.
#
# Both flags live in obj2, so the runtime delta is +0x1F1000, NOT obj1's +0x1F0000.
#
# The flag is ALWAYS restored, including on error. Evidence is collected as framebuffer
# dumps so the result can be judged from the images rather than from a description.

[CmdletBinding()]
param(
    [long]$Flag = 0x1525F2,
    [int]$HoldMs = 1200,
    [string]$OutDir = 'C:\Games\azrael-suppress3d',
    [long]$VideoBase = 0,          # 0 = locate it by page-diffing
    [long]$FbOffset = 0x140000,
    [int]$Stride = 2048,
    [int]$Rows = 900
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')
Add-Type -AssemblyName System.Drawing

$OBJ2_DELTA = 0x1F1000
New-Item -ItemType Directory -Force $OutDir | Out-Null

$g = Get-AztGuestBase
Write-Host ("guest RAM 0x{0:X11}, MemBase 0x{1:X11}" -f $g.RamBase, $g.MemBase)

# ---- locate the display surface ---------------------------------------------
if (-not $VideoBase) {
    $regs = [AztTool.ProcMem]::Regions($g.ProcessId, 0x7FFFFFFFFFFF)
    $best = $null; $bestRun = 0
    foreach ($r in ($regs | Where-Object { $_.Size -ge 8MB -and $_.Size -le 128MB })) {
        $pg = [AztTool.ProcMem]::ChangedPages($g.ProcessId, $r.Base, [int][Math]::Min($r.Size, 16MB), 90)
        if ($null -eq $pg) { continue }
        $run = 0; $cur = 0
        foreach ($x in $pg) { if ($x) { $cur++; if ($cur -gt $run) { $run = $cur } } else { $cur = 0 } }
        if ($run -gt $bestRun) { $bestRun = $run; $best = $r }
    }
    if (-not $best) { throw "could not locate a changing video region -- is the game in a room?" }
    $VideoBase = $best.Base
    Write-Host ("display surface: host 0x{0:X11} ({1:N0} MB), longest changed run {2} pages" -f `
                $VideoBase, ($best.Size / 1MB), $bestRun)
}
$fb = $VideoBase + $FbOffset

function Save-Frame {
    param([string]$name)
    $buf = [AztTool.ProcMem]::Read($g.ProcessId, $fb, ($Stride * $Rows))
    if ($null -eq $buf) { throw "framebuffer read failed" }
    $bmp = New-Object System.Drawing.Bitmap($Stride, $Rows, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
    $pal = $bmp.Palette
    for ($i = 0; $i -lt 256; $i++) { $pal.Entries[$i] = [System.Drawing.Color]::FromArgb(255, $i, $i, $i) }
    $bmp.Palette = $pal
    $rect = New-Object System.Drawing.Rectangle(0, 0, $Stride, $Rows)
    $d = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
    for ($y = 0; $y -lt $Rows; $y++) {
        [System.Runtime.InteropServices.Marshal]::Copy($buf, $y * $Stride, [IntPtr]($d.Scan0.ToInt64() + $y * $d.Stride), $Stride)
    }
    $bmp.UnlockBits($d)
    $p = Join-Path $OutDir ($name + '.png')
    $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    return @{ Path = $p; Bytes = $buf }
}

function Frame-Delta { param($a, $b)
    # fraction of bytes differing, split at the HUD boundary so "did the 3D stop while
    # the HUD kept going" is answerable from numbers, not just from looking
    $split = 600 * $Stride
    $top = 0; $bot = 0
    for ($i = 0; $i -lt $a.Length -and $i -lt $b.Length; $i++) {
        if ($a[$i] -ne $b[$i]) { if ($i -lt $split) { $top++ } else { $bot++ } }
    }
    return @{ Top = (100.0 * $top / $split); Bottom = (100.0 * $bot / ($a.Length - $split)) }
}

$flagRuntime = $Flag + $OBJ2_DELTA
$flagHost = $g.MemBase + $flagRuntime
$orig = [AztTool.ProcMem]::Read($g.ProcessId, $flagHost, 2)
Write-Host ("flag 0x{0:X6} (runtime 0x{1:X}) currently = {2}" -f $Flag, $flagRuntime, [BitConverter]::ToUInt16($orig, 0))

try {
    Write-Host ""
    Write-Host "--- baseline (3D running) ---"
    $a1 = Save-Frame 'a-baseline-1'
    Start-Sleep -Milliseconds 250
    $a2 = Save-Frame 'a-baseline-2'
    $d = Frame-Delta $a1.Bytes $a2.Bytes
    Write-Host ("  two frames 250 ms apart differ: viewport {0:N2}%, panel {1:N2}%" -f $d.Top, $d.Bottom)

    Write-Host ""
    Write-Host ("--- setting flag 0x{0:X6} = 1 (the engine's own 3D-skip path) ---" -f $Flag)
    [void][AztTool.ProcMem]::Write($g.ProcessId, $flagHost, [BitConverter]::GetBytes([uint16]1))
    Start-Sleep -Milliseconds $HoldMs
    $b1 = Save-Frame 'b-suppressed-1'
    Start-Sleep -Milliseconds 250
    $b2 = Save-Frame 'b-suppressed-2'
    $d2 = Frame-Delta $b1.Bytes $b2.Bytes
    Write-Host ("  two frames 250 ms apart differ: viewport {0:N2}%, panel {1:N2}%" -f $d2.Top, $d2.Bottom)

    $d3 = Frame-Delta $a2.Bytes $b1.Bytes
    Write-Host ("  before vs after suppression:    viewport {0:N2}%, panel {1:N2}%" -f $d3.Top, $d3.Bottom)
}
finally {
    [void][AztTool.ProcMem]::Write($g.ProcessId, $flagHost, $orig)
    Start-Sleep -Milliseconds 400
    $now = [AztTool.ProcMem]::Read($g.ProcessId, $flagHost, 2)
    Write-Host ""
    Write-Host ("flag restored to {0} (was {1})" -f [BitConverter]::ToUInt16($now, 0), [BitConverter]::ToUInt16($orig, 0)) -ForegroundColor Green
    $c = Save-Frame 'c-restored'
    Write-Host ("  restored frame -> {0}" -f $c.Path)
}
