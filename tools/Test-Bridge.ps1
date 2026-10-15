# Test-Bridge.ps1 -- the two halves of unknown 7 that Â§14g left open: WRITE and FRAME SYNC.
#
#   .\tools\Test-Bridge.ps1
#
# SAFETY. The write test targets AztMod's OWN unused BSS, not engine structures. The
# overlay occupies AZTCODE.BIN bytes from 0x133000, and the BSS region runs to 0x140000,
# so everything past the blob is memory we allocated and nothing reads. The original
# bytes are restored afterwards regardless, so even that is left as found.
#
# A second, deliberately different probe writes to `aztCamFrameNo` -- a field the guest
# rewrites every single frame. That cannot corrupt anything (the next frame overwrites
# it) and it demonstrates something the first probe cannot: that the address we are
# writing is genuinely the one the GUEST is also writing, not a private copy.
#
# FRAME SYNC is measured by watching the frame counter as fast as the OS allows, from
# C# rather than PowerShell -- the question is whether the host can observe every frame,
# and a PowerShell polling loop's own overhead would swamp the thing being measured.

[CmdletBinding()]
param(
    [string]$Overlay = 'C:\Games\RaptorMod\game\GAME\AZRAEL\AZTCODE.BIN',
    [long]$OverlayBase = 0x133000,
    [long]$BssEnd = 0x140000,
    [int]$WatchMs = 4000
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')

$g = Get-AztGuestBase
Write-Host ("guest RAM 0x{0:X11} ({1:N0} MB), MemBase 0x{2:X11}" -f $g.RamBase, ($g.RamSize/1MB), $g.MemBase)

$ovl = [IO.File]::ReadAllBytes($Overlay)
$off = -1
for ($i = 0; $i + 4 -le $ovl.Length; $i++) {
    if ($ovl[$i] -eq 0x43 -and $ovl[$i+1] -eq 0x41 -and $ovl[$i+2] -eq 0x4D -and $ovl[$i+3] -eq 0x31) { $off = $i; break }
}
if ($off -lt 0) { throw "'CAM1' not found" }
$recLin  = $OverlayBase + $off
$frameNoLin = $recLin + 4
$frameNoRt  = $frameNoLin + 0x1F0000
Write-Host ("aztCamRec 0x{0:X}, frameNo 0x{1:X} (runtime 0x{2:X})" -f $recLin, $frameNoLin, $frameNoRt)

# =============================================================================
Write-Host ""
Write-Host "=== TEST 1: write into AztMod's own unused BSS, then read it back ===" -ForegroundColor Cyan
# well past the blob, well before the end of the BSS window
$scratchLin = $OverlayBase + $ovl.Length + 0x400
if (($scratchLin + 64) -ge $BssEnd) { throw "no room for a scratch area below 0x{0:X}" -f $BssEnd }
Write-Host ("scratch at guest 0x{0:X} (blob ends 0x{1:X}, BSS ends 0x{2:X})" -f `
            $scratchLin, ($OverlayBase + $ovl.Length), $BssEnd)

$before = Read-AztGuest -Base $g -Lin $scratchLin -Length 32
if ($null -eq $before) { throw "could not read the scratch area" }
Write-Host ("  before: {0}" -f (($before | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))

$payload = [Text.Encoding]::ASCII.GetBytes('AZT-HOST-WRITE-OK-0123456789ABCD')
$addr = $g.MemBase + $scratchLin + 0x1F0000
$ok = [AztTool.ProcMem]::Write($g.ProcessId, $addr, $payload)
Write-Host ("  WriteProcessMemory returned {0}" -f $ok)

$after = Read-AztGuest -Base $g -Lin $scratchLin -Length 32
$asText = ''
foreach ($b in $after) { $asText += $(if ($b -ge 32 -and $b -lt 127) { [char]$b } else { '.' }) }
Write-Host ("  after : {0}" -f (($after | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))
Write-Host ("  as text: {0}" -f $asText)

$same = $true
for ($i = 0; $i -lt $payload.Length; $i++) { if ($after[$i] -ne $payload[$i]) { $same = $false; break } }
if ($same) { Write-Host "  WRITE PATH CONFIRMED -- the bytes landed in guest memory." -ForegroundColor Green }
else       { Write-Host "  write did not take effect." -ForegroundColor Yellow }

# put it back exactly as found
[void][AztTool.ProcMem]::Write($g.ProcessId, $addr, $before)
$restored = Read-AztGuest -Base $g -Lin $scratchLin -Length 32
$rok = $true
for ($i = 0; $i -lt 32; $i++) { if ($restored[$i] -ne $before[$i]) { $rok = $false; break } }
Write-Host ("  restored to original bytes: {0}" -f $rok)

# =============================================================================
Write-Host ""
Write-Host "=== TEST 2: write a field the GUEST rewrites every frame ===" -ForegroundColor Cyan
Write-Host  "(proves the address we write is the one the guest writes, not a private copy)"
# NOT [uint32]0xDEADBEEF: PowerShell parses that literal as a NEGATIVE Int32 and the
# cast then throws "value was either too large or too small".
$SENT = [uint32]3735928559          # 0xDEADBEEF
$sentinel = [BitConverter]::GetBytes($SENT)
$fnAddr = $g.MemBase + $frameNoRt
$pre = [BitConverter]::ToUInt32((Read-AztGuest -Base $g -Lin $frameNoLin -Length 4), 0)
[void][AztTool.ProcMem]::Write($g.ProcessId, $fnAddr, $sentinel)
$immediate = [BitConverter]::ToUInt32((Read-AztGuest -Base $g -Lin $frameNoLin -Length 4), 0)
Start-Sleep -Milliseconds 500
$post = [BitConverter]::ToUInt32((Read-AztGuest -Base $g -Lin $frameNoLin -Length 4), 0)
Write-Host ("  frameNo before write : {0}" -f $pre)
Write-Host ("  immediately after    : 0x{0:X8}" -f $immediate)
Write-Host ("  after 500 ms         : {0}" -f $post)
if ($immediate -eq $SENT -and $post -ne $SENT -and $post -gt $pre) {
    $advanced = [int64]$post - [int64]$SENT
    if ($advanced -gt 0 -and $advanced -lt 1000) {
        # The counter is incremented in place, so the guest did not merely overwrite our
        # value -- it READ it and added to it. That is stronger than the test set out to
        # show: it demonstrates shared state in both directions, not just a shared address.
        Write-Host ("  CONFIRMED, and better than expected: the guest INCREMENTED our sentinel") -ForegroundColor Green
        Write-Host ("  by {0} over 500 ms. It read the host's value and built on it -- shared" -f $advanced) -ForegroundColor Green
        Write-Host  "  state in both directions, not just a shared address." -ForegroundColor Green
    } else {
        Write-Host "  CONFIRMED: the sentinel landed and the guest replaced it with a live value." -ForegroundColor Green
    }
    Write-Host ""
    Write-Host  "  NOTE: this leaves the frame counter offset by the sentinel. It is AztMod's" -ForegroundColor Yellow
    Write-Host  "  own diagnostic counter so nothing breaks, but write a sane value back if" -ForegroundColor Yellow
    Write-Host  "  you care about the numbers in AZTCAM.LOG afterwards." -ForegroundColor Yellow
} elseif ($immediate -eq $SENT) {
    Write-Host "  sentinel landed, but the guest did not overwrite it -- is the game paused?" -ForegroundColor Yellow
} else {
    Write-Host "  sentinel did not land." -ForegroundColor Yellow
}

# =============================================================================
Write-Host ""
Write-Host "=== TEST 3: frame sync -- can the host observe EVERY frame? ===" -ForegroundColor Cyan
$ticks = [AztTool.ProcMem]::WatchDword($g.ProcessId, $fnAddr, $WatchMs, 100000)
Write-Host ("  watched {0} ms, saw {1} distinct values" -f $WatchMs, $ticks.Count)
if ($ticks.Count -lt 3) { Write-Host "  not enough samples -- is the game running?" -ForegroundColor Yellow; return }

$freq = [Diagnostics.Stopwatch]::Frequency
$gaps = @(); $skips = 0; $maxSkip = 0
for ($i = 1; $i -lt $ticks.Count; $i++) {
    $gaps += (($ticks[$i].Ticks - $ticks[$i-1].Ticks) * 1000.0 / $freq)
    $d = [int64]$ticks[$i].Value - [int64]$ticks[$i-1].Value
    if ($d -gt 1) { $skips++; if ($d -gt $maxSkip) { $maxSkip = $d } }
}
$sorted = $gaps | Sort-Object
$mean = ($gaps | Measure-Object -Average).Average
$median = $sorted[[int]($sorted.Count/2)]
$span = ($ticks[-1].Value - $ticks[0].Value)
Write-Host ("  frame counter advanced {0} over {1} observations" -f $span, $ticks.Count)
Write-Host ("  inter-frame gap: mean {0:N2} ms, median {1:N2} ms, min {2:N2}, max {3:N2}" -f `
            $mean, $median, $sorted[0], $sorted[-1])
Write-Host ("  implied frame rate: {0:N1} fps" -f (1000.0 / $mean))
Write-Host ("  observations where the counter jumped by more than 1: {0}{1}" -f `
            $skips, $(if ($skips) { "  (largest jump $maxSkip)" } else { '' }))
if ($skips -eq 0) {
    Write-Host "  NO FRAMES MISSED -- host polling can observe every frame the game renders." -ForegroundColor Green
} else {
    Write-Host ("  {0} of {1} transitions skipped a frame; polling alone is not frame-exact." -f $skips, ($ticks.Count-1)) -ForegroundColor Yellow
}

