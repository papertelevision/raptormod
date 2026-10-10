# Start-HostView.ps1 -- TIER A, STAGE 1: does the host-render LOOP work?
#
#   .\tools\Start-HostView.ps1                    # 15 s, capped game, measure
#   .\tools\Start-HostView.ps1 -Seconds 30
#   .\tools\Start-HostView.ps1 -Uncap             # also lift the guest's 24 fps cap
#   .\tools\Start-HostView.ps1 -TargetFps 0       # host pushes as fast as it can
#   .\tools\Start-HostView.ps1 -Leave             # leave it on screen afterwards
#
# Start the game first and get into a room. This does NOT launch anything.
#
# WHAT IT ANSWERS. The injection mechanism is proven; the LOOP is not. Three numbers
# come out: host frames pushed per second, guest frames consumed per second, and how
# many displayed rows are torn. A rasteriser is only worth writing if those are sane.
#
# WHAT IT CHANGES IN THE GAME, and all of it is restored on exit (including Ctrl+C):
#   aztSup3D     0 -> 2   the engine stops drawing its scene pass AND its clear
#   aztInjEnable 0 -> 1   AztInjBody copies the staging buffer in every frame
#   aztFramePeriod        only with -Uncap, and see the warning below
#
# -Uncap MAKES THE PLAYER MOVE FAR TOO FAST. Movement is frame-tied and $MOVE_SCALE
# is calibrated for 24 fps, so do not try to walk around with it on -- stand still.
# It is there to measure the ceiling, not to play.
[CmdletBinding()]
param(
    [int]$Seconds   = 15,
    [double]$TargetFps = 60,      # 0 = unthrottled, which measures the bridge itself
    [switch]$Free,                # skip the handshake: the ORIGINAL tearing behaviour
    [int]$SyncTimeoutMs = 500,
    [switch]$Uncap,
    [switch]$Leave,
    [switch]$Restore,             # clear every flag and exit: the way back from -Leave
    [string]$Sym      = "$PSScriptRoot\..\AztMod.overlay.sym",
    [string]$Manifest = "$PSScriptRoot\..\AztMod.manifest.json",
    [string]$Palette  = 'C:\Games\azrael-inject\azrael-palette.pal'
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')
Add-Type -Path (Join-Path $toolDir 'HostView.cs') -ErrorAction Stop

# ---- symbols, from the BUILD's own map ---------------------------------------
# Not by hunting byte signatures in AZTCODE.BIN, which is how the earlier injection
# tools did it. Signature hunting is why a probe once "found" the overlay eight
# times in a run of zeros, and the build now writes the real map on every build.
if (-not (Test-Path $Sym)) { throw "no $Sym -- build once to produce the overlay symbol map" }
$symMap = @{}
foreach ($line in [IO.File]::ReadAllLines((Resolve-Path $Sym).Path)) {
    if ($line -match '^0x([0-9A-Fa-f]+)\s+(\S+)$') { $symMap[$Matches[2]] = [uint32]('0x' + $Matches[1]) }
}
function Sym([string]$n) {
    if (-not $symMap.ContainsKey($n)) { throw "$n is not in the overlay symbol map -- is `$ENABLE_HOST_RENDER on?" }
    return [uint32]$symMap[$n]
}
$S_sup3D   = Sym 'aztSup3D'
$S_enable  = Sym 'aztInjEnable'
$S_bufPtr  = Sym 'aztInjBufPtr'
$S_count   = Sym 'aztInjCount0'
$S_skips   = Sym 'aztSupSkips'
$S_draws   = Sym 'aztSupDraws'
$S_ready   = Sym 'aztInjReady'
$S_starve  = Sym 'aztInjStarve'
$S_shown   = Sym 'aztInjShown'

# The frame size and the cap address come from the manifest, so this tool cannot
# disagree with the build about either. A hard-coded 1024x576 here is exactly how
# the older tool became wrong when the resolution changed.
$man = Get-Content (Resolve-Path $Manifest).Path -Raw | ConvertFrom-Json
$capLin = 0
foreach ($s in $man.settings) { if ($s.name -eq 'aztFramePeriod') { $capLin = [Convert]::ToUInt32((([string]$s.linear) -replace '^0x',''), 16) } }
if ($Uncap -and -not $capLin) { throw 'aztFramePeriod is not in the manifest settings -- cannot lift the cap' }
if (-not $man.view) { throw 'the manifest has no view section -- rebuild to publish the injection geometry' }
$W = [int]$man.view.injW
$H = [int]$man.view.injH
if ($W -le 0 -or $H -le 0) { throw "the manifest's view section gives a bad frame size ${W}x${H}" }
Write-Host ("frame {0}x{1} = {2:N0} bytes, hook {3}" -f $W, $H, ($W * $H), $man.view.hookAt)

# ---- inks, from the CAPTURED palette ----------------------------------------
# NEVER index 0 or 255: both are black in this game, and three separate probes were
# wasted discovering that. Picked by luminance out of the real captured palette so
# the pattern is actually visible on screen.
$ink = 0; $dim = 0; $grid = 0
if (Test-Path $Palette) {
    $pal = [IO.File]::ReadAllBytes((Resolve-Path $Palette).Path)
    if ($pal.Length -lt 768) { throw "$Palette is only $($pal.Length) bytes" }
    $lum = 1..254 | ForEach-Object {
        [pscustomobject]@{ I = $_; L = (0.299*$pal[$_*3] + 0.587*$pal[$_*3+1] + 0.114*$pal[$_*3+2]) }
    }
    $sorted = @($lum | Sort-Object L)
    $dim  = [byte]$sorted[[int]($sorted.Count * 0.20)].I
    $grid = [byte]$sorted[[int]($sorted.Count * 0.55)].I
    $ink  = [byte]$sorted[$sorted.Count - 2].I
    Write-Host ("inks from the captured palette: bar {0}, grid {1}, background {2}" -f $ink, $grid, $dim)
} else {
    $ink = 200; $grid = 120; $dim = 40
    Write-Host ("no captured palette at {0} -- using indices {1}/{2}/{3} unverified" -f $Palette, $ink, $grid, $dim) -ForegroundColor Yellow
}

# ---- the guest -------------------------------------------------------------
$g = Get-AztGuestBase
Write-Host ("guest pid {0}, MemBase 0x{1:X}" -f $g.ProcessId, $g.MemBase)
function H1([uint32]$lin) { return [long]($g.MemBase + $lin + 0x1F0000) }   # obj1
function H2([uint32]$lin) { return [long]($g.MemBase + $lin + 0x1F1000) }   # obj2

# -Restore is the way back from -Leave, which deliberately strands the viewport in
# host-render mode. Nothing in the guest can clear aztSup3D, so without this the only
# way out would be quitting the game.
if ($Restore) {
    $hv0 = New-Object AztTool.HostView($g.ProcessId, [long]1, 4, 4, [byte]1, [byte]1, [byte]1)
    foreach ($s in @($S_ready, $S_enable, $S_sup3D)) { [void]$hv0.WriteU32((H1 $s), 0) }
    Start-Sleep -Milliseconds 200
    Write-Host ("restored: aztInjReady {0}, aztInjEnable {1}, aztSup3D {2} -- the engine is drawing again" -f `
        $hv0.ReadU32((H1 $S_ready)), $hv0.ReadU32((H1 $S_enable)), $hv0.ReadU32((H1 $S_sup3D))) -ForegroundColor Green
    $hv0.Close()
    return
}

$bufGuest = [BitConverter]::ToUInt32([AztTool.ProcMem]::Read($g.ProcessId, (H1 $S_bufPtr), 4), 0)
if ($bufGuest -lt 0x1000) {
    throw ("the staging buffer is 0x{0:X} -- AztInjInit could not get {1:N0} bytes from the game's heap, so nothing else here would mean anything" -f $bufGuest, ($W*$H))
}
Write-Host ("staging buffer at guest 0x{0:X}" -f $bufGuest)

$hv = New-Object AztTool.HostView($g.ProcessId, [long]($g.MemBase + $bufGuest), $W, $H, $ink, $dim, $grid)
$capWas = 0
try {
    # ---- baseline: what is the guest doing before we touch anything? --------
    $c0 = $hv.ReadU32((H1 $S_count)); Start-Sleep -Milliseconds 2000
    $c1 = $hv.ReadU32((H1 $S_count))
    $fpsBefore = ($c1 - $c0) / 2.0
    Write-Host ("guest frame rate before: {0:N1} fps" -f $fpsBefore)

    if ($Uncap) {
        $capWas = $hv.ReadU32((H1 $capLin))
        # the cap lives in the clock blob, which is obj1 like everything else here
        [void]$hv.WriteU32((H1 $capLin), 0)
        Write-Host ("frame cap lifted (aztFramePeriod {0} -> 0) -- MOVEMENT IS NOW FAR TOO FAST, stand still" -f $capWas) -ForegroundColor Yellow
    }

    # ---- hand the viewport over -------------------------------------------
    # One frame composed and pushed BEFORE the flags flip, so the first thing the
    # guest copies is a complete picture rather than whatever the heap held.
    $hv.Compose(0.0, [byte]1)
    [void]$hv.Push()
    [void]$hv.WriteU32((H1 $S_sup3D), 2)     # engine: stop the scene pass and the clear
    [void]$hv.WriteU32((H1 $S_enable), 1)    # AztInjBody: copy our buffer every frame

    $sk0 = $hv.ReadU32((H1 $S_skips)); $dr0 = $hv.ReadU32((H1 $S_draws))
    $st0 = $hv.ReadU32((H1 $S_starve)); $sh0 = $hv.ReadU32((H1 $S_shown))
    $g0 = $hv.ReadU32((H1 $S_count))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if ($Free) {
        Write-Host 'running UNSYNCHRONISED (-Free): expect tearing, this is the pre-A2 behaviour' -ForegroundColor Yellow
        $hv.Run([int]($Seconds * 1000), $TargetFps)
    } else {
        # Paced BY THE GUEST: the achieved rate here is the game's frame rate, not a
        # target we chose, which is the number actually worth having.
        $hv.RunSynced([int]($Seconds * 1000), (H1 $S_ready), $SyncTimeoutMs)
    }
    $sw.Stop()

    # DID THE GAME SURVIVE? Every read returns 0 once the process is gone, so every
    # delta computed below would come out NEGATIVE -- which is exactly what one run
    # reported: "guest frames drawn -14,531". Impossible numbers presented as results
    # are worse than an honest "the game exited", so check before reporting anything.
    $alive = [bool](Get-Process -Id $g.ProcessId -ErrorAction SilentlyContinue)
    if (-not $alive -or $hv.GameExited) {
        Write-Host ''
        Write-Host ("THE GAME EXITED after {0:N1}s of the {1}s run ({2:N0} frames pushed, then {3:N0} failed writes)." -f `
            $sw.Elapsed.TotalSeconds, $Seconds, $hv.HostFrames, $hv.WriteFailures) -ForegroundColor Yellow
        Write-Host '  No counters are reported: with the process gone every read is 0 and every delta negative.'
        Write-Host '  Check GAME\AZRAEL\AZTFPS.LOG for how the game was doing when it stopped -- the samples are'
        Write-Host '  tagged with aztSup3D, so a healthy tail means it was fine and simply closed.'
        return
    }

    $g1 = $hv.ReadU32((H1 $S_count))
    $sk1 = $hv.ReadU32((H1 $S_skips)); $dr1 = $hv.ReadU32((H1 $S_draws))
    $st1 = $hv.ReadU32((H1 $S_starve)); $sh1 = $hv.ReadU32((H1 $S_shown))

    $sec = $sw.Elapsed.TotalSeconds
    Write-Host ''
    Write-Host ("over {0:N1}s:" -f $sec)
    Write-Host ("  host frames pushed   {0,8:N0}   {1,7:N1} /s" -f $hv.HostFrames, ($hv.HostFrames / $sec))
    Write-Host ("  guest frames drawn   {0,8:N0}   {1,7:N1} /s" -f ($g1 - $g0), (($g1 - $g0) / $sec))
    Write-Host ("  write failures       {0,8:N0}" -f $hv.WriteFailures)
    Write-Host ("  engine scene passes  skipped {0:N0}, drawn {1:N0}" -f ($sk1 - $sk0), ($dr1 - $dr0))
    if (-not $Free) {
        Write-Host ("  frames displayed     {0,8:N0}   {1,7:N1} /s" -f ($sh1 - $sh0), (($sh1 - $sh0) / $sec))
        Write-Host ("  guest starved        {0,8:N0}   (frames with nothing fresh to show)" -f ($st1 - $st0))
        Write-Host ("  host waited          {0,8:N0} spins, {1:N0} timeout(s)" -f $hv.SyncWaits, $hv.SyncTimeouts)
        if ($hv.SyncTimeouts -gt 0) {
            Write-Host '  TIMEOUTS: the guest stopped consuming -- is the game paused or in a menu?' -ForegroundColor Yellow
        }
    }
    if (($sk1 - $sk0) -eq 0) {
        Write-Host '  THE GATE NEVER FIRED -- the engine is still drawing its own 3D.' -ForegroundColor Yellow
    }

    # ---- tearing, measured rather than eyeballed ---------------------------
    # The surface geometry comes from the engine's own descriptor rather than from
    # our constants: +0x00 w, +0x04 h, +0x18 bytesPerLine, +0x1C pixels. That +0x1C
    # pointer is also the check that we are reading the buffer AztInjBody writes --
    # it must equal [0x163A34], and the earlier guess that bytesPerLine lived at
    # +0x08 was wrong (that field reads 1).
    # ProcMem.Read returns $null on failure, and BitConverter::ToUInt32($null,0) throws
    # "Value cannot be null" -- which is how a closed game turned a finished run into a
    # stack trace. Guarded rather than assumed.
    $descRaw = [AztTool.ProcMem]::Read($g.ProcessId, (H2 0x14745C), 4)
    $sharedRaw = [AztTool.ProcMem]::Read($g.ProcessId, (H2 0x163A34), 4)
    $desc   = $(if ($descRaw)   { [BitConverter]::ToUInt32($descRaw, 0) }   else { 0 })
    $shared = $(if ($sharedRaw) { [BitConverter]::ToUInt32($sharedRaw, 0) } else { 0 })
    if ($desc -gt 0x1000) {
        $dd = [AztTool.ProcMem]::Read($g.ProcessId, [long]($g.MemBase + $desc), 0x40)
        if (-not $dd) { $dd = New-Object byte[] 0x40 }
        $sw2 = [BitConverter]::ToUInt32($dd, 0x00)
        $sh2 = [BitConverter]::ToUInt32($dd, 0x04)
        $stride = [BitConverter]::ToUInt32($dd, 0x18)
        $pix    = [BitConverter]::ToUInt32($dd, 0x1C)
        Write-Host ''
        Write-Host ("surface {0}x{1}, stride {2}, pixels 0x{3:X}" -f $sw2, $sh2, $stride, $pix)
        if ($pix -ne $shared) {
            Write-Host ("  descriptor pixels 0x{0:X} != [0x163A34] 0x{1:X} -- reading a buffer nothing injects into" -f $pix, $shared) -ForegroundColor Red
        }
        if ($stride -lt $W) { $stride = $W }
        $v = $hv.VerifySnapshot([long]($g.MemBase + $pix), $stride, $H)
        Write-Host ("marker column {0}: {1} of {2} rows still carry our marker, {3} overwritten" -f `
            $hv.MarkCol, $v[0], $H, $v[1])
        # READ THIS AS NOISE, NOT AS TEARING. The destination is a SHARED SURFACE POOL:
        # one allocation aliased by 0x152154 / 0x1521BC / 0x162E2C / 0x163A34, with 54
        # references across 19 functions -- UI, map, book viewer, scan readout -- eight
        # of them in the per-frame draw path. Those run AFTER our injection, which is
        # the property the hybrid depends on, and they rewrite the buffer continuously.
        # So reading it back cannot isolate one host frame, and an earlier version of
        # this tool reported its noise as a tearing percentage. It is reported here only
        # as a sanity check that our pixels reach the surface at all.
        if ($v[0] -eq 0) {
            Write-Host '  our pixels are NOT reaching the surface -- that is a real failure.' -ForegroundColor Red
        } else {
            Write-Host ("  host frames present {0}, transitions {1}, largest covers {2} of {3} readable rows" -f `
                $v[2], $v[3], $v[5], $v[0])
            Write-Host '  (absolute counts here are contaminated by the game''s own overdraw, so read them'
            Write-Host '   as a COMPARISON between modes, not as a tear percentage.)'
        }
    }
    # THE PACING IS THE VALID MEASUREMENT, and in synced mode it is also the proof the
    # handshake is working as a producer/consumer pair: pushed should equal displayed,
    # with starve at or near zero.
    if (-not $Free) {
        $pushed = $hv.HostFrames; $disp = $sh1 - $sh0
        if ($pushed -gt 0 -and [Math]::Abs($pushed - $disp) -le ([Math]::Max(2, $pushed * 0.02))) {
            Write-Host ''
            Write-Host ("HANDSHAKE HOLDING: {0:N0} pushed, {1:N0} displayed, {2:N0} starved -- one frame in, one frame out." -f `
                $pushed, $disp, ($st1 - $st0)) -ForegroundColor Green
        }
    }
}
finally {
    # ALWAYS hand the viewport back, on every exit path. A stuck aztSup3D means a
    # game with no 3D and no way to recover it from inside, and a stuck aztInjReady
    # would leave the guest copying a buffer nobody is refreshing.
    #
    # -Leave USED TO BE INCOHERENT: it cleared aztInjEnable but left aztSup3D set, so
    # the engine stayed switched off with nothing feeding the viewport -- the opposite
    # of leaving something on screen. It now leaves BOTH set, so the guest keeps
    # re-copying the last host frame and the picture is stable and inspectable. The
    # cap always goes back regardless: hyperspeed movement is never what anyone wants
    # left behind.
    [void]$hv.WriteU32((H1 $S_ready), 0)
    if ($Leave) {
        [void]$hv.WriteU32((H1 $S_enable), 1)
        [void]$hv.WriteU32((H1 $S_sup3D), 2)
    } else {
        [void]$hv.WriteU32((H1 $S_enable), 0)
        [void]$hv.WriteU32((H1 $S_sup3D), 0)
    }
    if ($Uncap -and $capWas) { [void]$hv.WriteU32((H1 $capLin), $capWas) }
    Start-Sleep -Milliseconds 300
    Write-Host ''
    # ONLY READ BACK IF THERE IS SOMETHING TO READ. A dead process reads as 0, and
    # printing "restored: aztFramePeriod 0" then claims the cap was zeroed when in
    # fact nothing was written at all -- a false statement about the game's state,
    # which is the worst kind of diagnostic output.
    if (Get-Process -Id $g.ProcessId -ErrorAction SilentlyContinue) {
        Write-Host ("aztInjEnable {0}, aztSup3D {1}, aztFramePeriod {2}" -f `
            $hv.ReadU32((H1 $S_enable)), $hv.ReadU32((H1 $S_sup3D)), $(if ($capLin) { $hv.ReadU32((H1 $capLin)) } else { 'n/a' })) -ForegroundColor Green
    } else {
        Write-Host 'the game is no longer running -- nothing to restore, and its flags die with it.' -ForegroundColor Yellow
    }
    if ($Leave -and (Get-Process -Id $g.ProcessId -ErrorAction SilentlyContinue)) {
        Write-Host 'LEFT ON SCREEN. The engine is still switched off -- restore it with:' -ForegroundColor Yellow
        Write-Host '    .\tools\Start-HostView.ps1 -Restore' -ForegroundColor Yellow
    }
    $hv.Close()
}
