# Read-Perf.ps1 -- decode AZTFPS.LOG and the game's own startup memory report.
#
#   .\tools\Read-Perf.ps1
#   .\tools\Read-Perf.ps1 -Label '1600x1200, upscaled textures'
#
# AZTFPS.LOG is one 16-bit frame count per second, appended by AztFpsTick while
# $ENABLE_FPS_LOG is on. Two things make raw samples misleading and both are handled
# here:
#
#   * THE FIRST SAMPLES ARE THE INTRO, not gameplay. Movies and menus render almost
#     free -- the movie path pins to exactly 40 -- so the opening ~25-30 samples
#     flatter the result badly. -Skip drops them.
#   * IT MEASURES THE CAP, not the machine, wherever the machine could go faster.
#     Samples sitting exactly at the cap are counted separately, because "how often
#     did we hit the ceiling" is the question that decides whether raising the cap
#     would buy anything at all.
#
# The memory report is the game's own printf at startup, captured by the AZRAEL.BAT
# redirect. It gives the REAL split rather than our arithmetic:
#     MAXIMIUM MEMORY BLOCK FOUND: <block>
#     TEXTURE CACHE ALLOCATION:    <cache>
[CmdletBinding()]
param(
    [string]$GameDir = 'C:\Games\RaptorMod\game\GAME\AZRAEL',
    [int]   $Skip    = 30,     # samples to discard as intro/menu
    [int]   $Cap     = 24,     # the build's frame cap, for the ceiling count
    [string]$Label   = ''
)
$ErrorActionPreference = 'Stop'

$log = Join-Path $GameDir 'AZTFPS.LOG'
if (-not (Test-Path $log)) { throw "no $log -- is `$ENABLE_FPS_LOG on, and has the game been run?" }
$b = [IO.File]::ReadAllBytes($log)
if ($b.Length -lt 4) { throw "$log is only $($b.Length) bytes -- the run was too short to sample" }
$raw = @(0..([int]($b.Length/2) - 1) | ForEach-Object { [BitConverter]::ToUInt16($b, $_*2) })

# ---- TAGGED SAMPLES ---------------------------------------------------------
# With $ENABLE_FPS_TAGS on, AztFpsTag packs the experiment's conditions into the
# high nibble of each sample: bits 0..11 count, 12..13 render level - 1, 14..15
# the 3D-suppression phase. Detected rather than assumed, so logs from either
# build decode: a count of 4096+ is impossible (the cap is 24 and the fastest
# thing ever measured was 98), so any high bit means a tagged log.
#
# 0xFFFF is AztFpsTick's FIRST-CALL MARKER, not a sample. It exists because a log
# that is present but empty cannot distinguish "the per-frame chain never ran"
# from "it ran and every write failed" -- AztFpsInit is reached from the early
# hook, so the file appears either way. Phase 3 is impossible, so the value is
# unambiguous.
$markers = @($raw | Where-Object { $_ -eq 0xFFFF }).Count
if ($markers) {
    Write-Host ("AztFpsTick marker present ({0}) -- the per-frame chain IS running" -f $markers) -ForegroundColor Green
}
$raw = @($raw | Where-Object { $_ -ne 0xFFFF })
if ($raw.Count -eq 0) {
    Write-Host 'the log holds the marker and NOTHING else: the frame chain runs but the per-second write never fired.' -ForegroundColor Yellow
    return
}
$tagged = @($raw | Where-Object { $_ -ge 0x1000 }).Count -gt 0
$all    = @($raw | ForEach-Object { if ($tagged) { $_ -band 0x0FFF } else { $_ } })
$levels = @($raw | ForEach-Object { if ($tagged) { ((($_ -shr 12) -band 3) + 1) } else { 0 } })
$phases = @($raw | ForEach-Object { if ($tagged) { (($_ -shr 14) -band 3) } else { 0 } })

if ($Label) { Write-Host $Label -ForegroundColor Cyan }
Write-Host ("{0} one-second samples, {1:N1}s of wall clock{2}" -f $all.Count, $all.Count, `
    $(if ($tagged) { ' (tagged with render level + suppression phase)' } else { '' }))

$play = @($all | Select-Object -Skip $Skip)
if ($play.Count -lt 5) {
    Write-Host ("only {0} sample(s) after skipping {1} of intro -- play longer before trusting this" -f $play.Count,$Skip) -ForegroundColor Yellow
    $play = $all
}
$s = $play | Measure-Object -Minimum -Maximum -Average
$sorted = @($play | Sort-Object)
$median = $sorted[[int]($sorted.Count/2)]
$atCap  = @($play | Where-Object { $_ -ge $Cap }).Count
$below15 = @($play | Where-Object { $_ -lt 15 }).Count

Write-Host ''
Write-Host ("gameplay samples   {0}  (first {1} discarded as intro)" -f $play.Count, $Skip)
Write-Host ("min / max          {0} / {1}" -f $s.Minimum, $s.Maximum)
Write-Host ("mean / median      {0:N1} / {1}" -f $s.Average, $median)
Write-Host ("at or above the {0} fps cap   {1} of {2}  ({3:P0})" -f $Cap, $atCap, $play.Count, ($atCap/$play.Count))
Write-Host ("below 15 fps                 {0} of {1}  ({2:P0})" -f $below15, $play.Count, ($below15/$play.Count))
Write-Host ''
# A histogram beats a mean here: the complaint is about the DIPS, and a mean hides them.
$buckets = @(0,10,15,18,21,24,30,40,999)
for ($i = 0; $i -lt $buckets.Count-1; $i++) {
    $lo = $buckets[$i]; $hi = $buckets[$i+1]
    $n = @($play | Where-Object { $_ -ge $lo -and $_ -lt $hi }).Count
    if ($n -eq 0) { continue }
    $bar = '#' * [int][Math]::Ceiling(40.0 * $n / $play.Count)
    Write-Host ("  {0,3}-{1,-3} {2,4}  {3}" -f $lo, $(if($hi -ge 999){'+'}else{$hi}), $n, $bar)
}

# ---- the 2x2 the experiment exists to produce -------------------------------
# Rows are the 3D-suppression phase, columns the game's own render level. Every
# cell is a mean of seconds measured in the SAME sitting, so scene complexity,
# texture-cache state and where the player was standing cannot differ between
# the conditions being compared -- which is the entire reason the phases
# alternate inside one run instead of across two builds.
if ($tagged) {
    # Phase 0 is CAPPED and exists only so the game is navigable between windows;
    # it is reported but never compared. The first run of this experiment ran three
    # phases with the cap left on and returned 22 fps in every one of them -- the
    # limiter spins out whatever the renderer saves, so a capped A/B measures the
    # cap. Phases 1-3 are uncapped and are the only comparable cells.
    $PHASE_NAME = @('capped (not a measurement)', 'uncapped, 3D on', 'uncapped, scene OFF', 'uncapped, scene + clear OFF')
    # DROP THE FIRST SAMPLE OF EACH PHASE BLOCK. The phase flips on whichever
    # frame crosses the 10 s boundary, so exactly one second per transition
    # straddles two conditions. Keeping it would drag every mean toward the
    # others and understate whatever difference is really there.
    # AND IGNORE EVERYTHING UP TO THE FIRST PHASE CHANGE. AztSupTick does not run
    # while the boot overlay owns the viewport, so the intro and the 16.9 s visor
    # sequence all log as phase 0 at level 1 -- the baseline cell, the one the
    # headline divides by. They are near-free to render (the movie path pins to
    # 40), so leaking even a few of them inflates the baseline and makes the
    # offload gain look smaller than it is. Waiting for the first flip is proof
    # the phase clock is running on a live room, which -Skip alone cannot give.
    $firstFlip = -1
    for ($i = 1; $i -lt $all.Count; $i++) { if ($phases[$i] -ne $phases[$i-1]) { $firstFlip = $i; break } }
    $from = [Math]::Max($Skip, $firstFlip + 1)
    $keep = New-Object System.Collections.Generic.List[object]
    if ($firstFlip -ge 0) {
        for ($i = $from; $i -lt $all.Count; $i++) {
            if ($phases[$i] -ne $phases[$i-1]) { continue }            # boundary second
            $keep.Add([pscustomobject]@{ Fps = $all[$i]; Level = $levels[$i]; Phase = $phases[$i] })
        }
    }
    Write-Host ''
    if ($keep.Count -lt 6) {
        Write-Host ("only {0} clean tagged sample(s) -- let it run through a few full 30 s cycles" -f $keep.Count) -ForegroundColor Yellow
    } else {
        $lvlsSeen = @($keep | ForEach-Object { $_.Level } | Sort-Object -Unique)
        Write-Host 'MEAN FPS BY SUPPRESSION PHASE AND RENDER LEVEL' -ForegroundColor Cyan
        Write-Host ("  {0,-20}{1}" -f 'phase', (($lvlsSeen | ForEach-Object { '{0,14}' -f ("level $_") }) -join ''))
        foreach ($p in 0..3) {
            $row = "  {0,-20}" -f $PHASE_NAME[$p]
            foreach ($L in $lvlsSeen) {
                $cell = @($keep | Where-Object { $_.Phase -eq $p -and $_.Level -eq $L })
                if ($cell.Count -eq 0) { $row += '{0,14}' -f '-' }
                else {
                    $m = ($cell | Measure-Object -Property Fps -Average).Average
                    $row += '{0,14}' -f ("{0:N1} (n={1})" -f $m, $cell.Count)
                }
            }
            Write-Host $row
        }
        # THE HEADLINE NUMBER. Phase 3 against phase 1 -- BOTH UNCAPPED, so the only
        # difference between them is the engine's 3D pass. That ratio is the ceiling
        # of the whole host-offload design: what the game runs at with its renderer
        # gone. If it is barely above the baseline, moving the renderer to the host
        # cannot buy frames and the plan is dead.
        foreach ($L in $lvlsSeen) {
            $b1 = @($keep | Where-Object { $_.Phase -eq 1 -and $_.Level -eq $L })
            $b3 = @($keep | Where-Object { $_.Phase -eq 3 -and $_.Level -eq $L })
            if ($b1.Count -lt 3 -or $b3.Count -lt 3) { continue }
            $m1 = ($b1 | Measure-Object -Property Fps -Average).Average
            $m3 = ($b3 | Measure-Object -Property Fps -Average).Average
            Write-Host ''
            Write-Host ("  level {0}: no 3D pass is {1:N1} fps against {2:N1} uncapped baseline -- x{3:N2}, the offload ceiling" -f `
                $L, $m3, $m1, ($m3 / [Math]::Max(0.1, $m1))) -ForegroundColor Green
            if (@($keep | Where-Object { $_.Phase -eq 1 -and $_.Level -eq $L -and $_.Fps -ge 4095 }).Count) {
                Write-Host '  (samples are CLAMPED at 4095 -- the 12-bit count field overflowed)' -ForegroundColor Yellow
            }
        }
    }
}

Write-Host ''
# BOTH files, because the report comes out on STDERR, not stdout -- measured
# 2026-10-03, when the texture-cache crash landed in AZERR.TXT and AZTOUT.TXT was
# never even created. Check stderr FIRST for that reason.
$outTxt = @(Join-Path $GameDir 'AZERR.TXT'; Join-Path $GameDir 'AZTOUT.TXT') |
            Where-Object { (Test-Path $_) -and (Get-Item $_).Length -gt 0 } | Select-Object -First 1
if ($outTxt) {
    $t = Get-Content $outTxt -Raw
    Write-Host ("memory report read from {0}" -f (Split-Path $outTxt -Leaf))
    $mBlock = [regex]::Match($t, 'MAXIMIUM MEMORY BLOCK FOUND:\s*(\d+)')
    $mCache = [regex]::Match($t, 'TEXTURE CACHE ALLOCATION:\s*(\d+)')
    if ($mBlock.Success -and $mCache.Success) {
        $block = [int64]$mBlock.Groups[1].Value; $cache = [int64]$mCache.Groups[1].Value
        Write-Host 'the game''s OWN memory report (not our arithmetic):'
        Write-Host ("  largest block   {0,12:N0}  ({1,6:N2} MB)" -f $block, ($block/1MB))
        Write-Host ("  texture cache   {0,12:N0}  ({1,6:N2} MB)" -f $cache, ($cache/1MB))
        Write-Host ("  reserve (rest)  {0,12:N0}  ({1,6:N2} MB)" -f ($block-$cache), (($block-$cache)/1MB))
    } else {
        Write-Host "no memory report in it -- the printf may not have reached either stream."
    }
    # The fatal reporter's own lines, which name the function AND the request that
    # failed. This is the whole value of the redirect: "Not enough space in texture
    # cache for N bytes" identifies both the wall and how far over it we went.
    $fatal = @($t -split "`r?`n" | Where-Object { $_ -match 'RAPTOR ERROR|Not enough space|No memory available|Failed to allocate|^TOTAL:' })
    if ($fatal.Count) {
        Write-Host ''
        Write-Host 'THE GAME REPORTED A FATAL ERROR:' -ForegroundColor Red
        $fatal | ForEach-Object { Write-Host ('  '+$_.Trim()) -ForegroundColor Red }
        $m = [regex]::Match($t, 'TOTAL:\s*(\d+)')
        $w = [regex]::Match($t, 'Not enough space in texture cache for (\d+) bytes')
        if ($m.Success -and $w.Success -and $mCache.Success) {
            $need = [int64]$m.Groups[1].Value + [int64]$w.Groups[1].Value
            Write-Host ('  -> wanted {0:N0}, cache is {1:N0}: over by {2:N0} bytes' -f `
                $need, [int64]$mCache.Groups[1].Value, ($need - [int64]$mCache.Groups[1].Value)) -ForegroundColor Red
        }
    }
} else {
    Write-Host 'no AZERR.TXT/AZTOUT.TXT -- re-apply the AZRAEL.BAT redirect (the installer overwrites it).'
}
