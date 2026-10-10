# Find-BufferWriter.ps1 -- what keeps rewriting the engine's offscreen 3D colour buffer?
#
#   .\tools\Find-BufferWriter.ps1
#
# A host image written into that buffer does not reach the screen: a 16-byte write sticks
# and reads back, but a full frame is gone within ~50 ms even with the 3D block patched
# out. This narrows down why, by measuring rather than guessing.
#
# THREE QUESTIONS, each with a measurement that can answer it on its own:
#
# 1. HOW FAST does a sentinel decay, with and without the 3D block patched?
#    If the patch makes no difference, the writer is NOT the block we patched.
#    A decay that tracks the ~45 ms frame period means a per-frame writer.
#
# 2. WHAT does the buffer become? If the sentinel is replaced by ZEROS it is a clear;
#    if it is replaced by plausible IMAGE data it is a re-render. Those imply completely
#    different fixes, and the histogram distinguishes them without any disassembly.
#
# 3. IS THIS BUFFER EVEN THE BLIT SOURCE? A pattern that persists but never appears on
#    screen would mean the display is fed from somewhere else entirely -- which would
#    explain the failure without anything "rewriting" the buffer at all.
#
# Nothing is left modified: the branch byte is restored in a finally block, and the
# buffer is the engine's own to repaint.

[CmdletBinding()]
param(
    [long]$JumpSite = 0x14160,
    [int]$Samples = 14,
    [int]$IntervalMs = 12
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')

$g = Get-AztGuestBase
$desc = [BitConverter]::ToUInt32((Read-AztGuest -Base $g -Lin 0x14745C -Length 4 -Obj2), 0)
if ($desc -lt 0x1000) { throw "colour descriptor pointer is 0x$($desc.ToString('X')) -- is the game in a room?" }
$d = [AztTool.ProcMem]::Read($g.ProcessId, ($g.MemBase + $desc), 0x3C)
$W   = [BitConverter]::ToUInt32($d, 0)
$H   = [BitConverter]::ToUInt32($d, 4)
$bpl = [BitConverter]::ToUInt32($d, 0x18)
$pix = [BitConverter]::ToUInt32($d, 0x1C)
Write-Host ("colour surface {0}x{1} bpl {2}, pixels at guest 0x{3:X}" -f $W, $H, $bpl, $pix)

$SENT = [byte]0xC7
$img = New-Object byte[] ($bpl * $H)
for ($i = 0; $i -lt $img.Length; $i++) { $img[$i] = $SENT }
$sampOff = $pix + (300 * $bpl)      # a middle row, away from borders

$target = $g.MemBase + $JumpSite + 0x1F0000
$orig = [AztTool.ProcMem]::Read($g.ProcessId, $target, 1)
if ($orig[0] -ne 0x75) { throw ("expected 0x75 at 0x{0:X5}, found 0x{1:X2}" -f $JumpSite, $orig[0]) }

function Decay {
    param([string]$label)
    [void][AztTool.ProcMem]::Write($g.ProcessId, ($g.MemBase + $pix), $img)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $line = @()
    $last = $null
    for ($k = 0; $k -lt $Samples; $k++) {
        $b = [AztTool.ProcMem]::Read($g.ProcessId, ($g.MemBase + $sampOff), 4096)
        $n = 0; foreach ($x in $b) { if ($x -eq $SENT) { $n++ } }
        $line += ('{0,4:N0}ms:{1,5:N1}%' -f $sw.Elapsed.TotalMilliseconds, (100.0 * $n / $b.Length))
        $last = $b
        Start-Sleep -Milliseconds $IntervalMs
    }
    $sw.Stop()
    Write-Host ("  {0}" -f $label)
    Write-Host ("    " + ($line -join '  '))

    # what did it BECOME?
    $hist = @{}
    foreach ($x in $last) { $hist[$x] = [int]$hist[$x] + 1 }
    $top = $hist.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5
    $zero = [int]$hist[[byte]0]
    Write-Host ("    became: {0}   (zeros {1:N1}%)" -f `
        (($top | ForEach-Object { '0x{0:X2}x{1}' -f $_.Name, $_.Value }) -join ' '), (100.0 * $zero / $last.Length))
    $distinct = $hist.Count
    $verdict = if ((100.0 * $zero / $last.Length) -gt 90) { 'CLEARED to zero' }
               elseif ($distinct -gt 20) { 'RE-RENDERED (varied image data)' }
               else { 'something else' }
    Write-Host ("    {0} distinct byte values -> {1}" -f $distinct, $verdict)
}

try {
    Write-Host ""
    Write-Host "=== Q1/Q2: decay of a sentinel written into the colour buffer ===" -ForegroundColor Cyan
    Decay 'UNPATCHED (3D rendering normally)'
    [void][AztTool.ProcMem]::Write($g.ProcessId, $target, [byte[]](0xEB))
    Start-Sleep -Milliseconds 500
    Decay 'PATCHED (3D block skipped)'

    Write-Host ""
    Write-Host "=== Q3: is this buffer the blit source? ===" -ForegroundColor Cyan
    # still patched. Write the sentinel and immediately look at the DISPLAY surface for it.
    $vb = (@([AztTool.ProcMem]::Regions($g.ProcessId, 0x7FFFFFFFFFFF) |
              Where-Object { $_.Size -ge 60MB -and $_.Size -le 80MB })[0]).Base
    $hits = 0
    for ($t = 0; $t -lt 25; $t++) {
        [void][AztTool.ProcMem]::Write($g.ProcessId, ($g.MemBase + $pix), $img)
        $row = [AztTool.ProcMem]::Read($g.ProcessId, ($vb + 0x140000 + 300 * 2048), 2048)
        foreach ($x in $row) { if ($x -eq $SENT) { $hits++; break } }
    }
    Write-Host ("  sentinel seen on the display surface in {0} of 25 attempts" -f $hits)
    if ($hits -gt 0) {
        Write-Host "  -> this buffer IS the blit source; the problem is purely the race." -ForegroundColor Green
    } else {
        Write-Host "  -> the sentinel NEVER reached the display: the screen is fed from" -ForegroundColor Yellow
        Write-Host "     somewhere else, so 'rewriting' may not be the real obstacle." -ForegroundColor Yellow
    }
}
finally {
    [void][AztTool.ProcMem]::Write($g.ProcessId, $target, $orig)
    Write-Host ""
    Write-Host ("branch byte restored to 0x{0:X2}" -f ([AztTool.ProcMem]::Read($g.ProcessId, $target, 1))[0]) -ForegroundColor Green
}
