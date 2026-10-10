# Test-SceneSplit.ps1 -- which part of the scene pass is the RENDERER, and which is the
# SIMULATION?
#
#   .\tools\Test-SceneSplit.ps1
#   .\tools\Test-SceneSplit.ps1 -Hold 4
#
# Start the game, get into a room, and STAND STILL. Nothing is launched here.
#
# WHY THIS EXISTS. Suppressing the whole scene pass (0x3F1B0) took the game from 21.4 to
# 522 fps -- but it also froze the player solid: 0 units moved and 0 degrees turned
# across a 25 s run, against 789 units and 175 degrees with it left alone. So that call
# both draws AND advances the simulation, and the x24 "offload ceiling" it produced was
# the game with no simulation, not the game with no renderer.
#
# The call has three parts. If the expensive one is the draw and the cheap one is the
# update, Tier A keeps its speedup AND stays playable. If they are the same call, it
# does not, and that is worth knowing before any more is built on the assumption.
#
# THE CAP MUST COME OFF OR THIS MEASURES NOTHING. AztFrameLimit spins until the frame
# period elapses, so work removed is handed straight back as spin and every mask reads
# 22 fps. That mistake has already cost one full round of this experiment.
# Movement is frame-tied, so the player will move far too fast while uncapped: stand
# still. Everything is restored in the finally, including on Ctrl+C.
[CmdletBinding()]
param(
    [int]$Hold = 4,                 # seconds per mask
    # -Mask holds ONE mask and watches whether the player can still move, which is the
    # question the fps sweep cannot answer. The cap stays ON for this: the point is
    # whether the game responds, and hyperspeed movement makes that harder to judge,
    # not easier.
    [int]$Mask = -1,
    [int]$Seconds = 20,
    [string]$Sym      = "$PSScriptRoot\..\AztMod.overlay.sym",
    [string]$Manifest = "$PSScriptRoot\..\AztMod.manifest.json"
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')

$symMap = @{}
foreach ($l in [IO.File]::ReadAllLines((Resolve-Path $Sym).Path)) {
    if ($l -match '^0x([0-9A-Fa-f]+)\s+(\S+)$') { $symMap[$Matches[2]] = [uint32]('0x'+$Matches[1]) }
}
function Sym([string]$n) {
    if (-not $symMap.ContainsKey($n)) { throw "$n is not in the overlay symbol map -- rebuild with `$ENABLE_SCENE_SPLIT on" }
    return [uint32]$symMap[$n]
}
$S_parts = Sym 'aztSceneParts'
$S_count = Sym 'aztInjCount0'
$S_cam   = Sym 'aztCamRec'

$man = Get-Content (Resolve-Path $Manifest).Path -Raw | ConvertFrom-Json
$capLin = 0
foreach ($s in $man.settings) { if ($s.name -eq 'aztFramePeriod') { $capLin = [Convert]::ToUInt32((([string]$s.linear) -replace '^0x',''), 16) } }
if (-not $capLin) { throw 'aztFramePeriod is not in the manifest settings' }

$g = Get-AztGuestBase
function H1([uint32]$l) { [long]($g.MemBase + $l + 0x1F0000) }
# NOT `Rd` / `Wr`. POWERSHELL RESOLVES ALIASES BEFORE FUNCTIONS, and `rd` is a built-in
# alias for Remove-Item. A helper called Rd is therefore never called at all: `Rd $addr`
# becomes `Remove-Item $addr`, and the first run of this died trying to delete a path
# named after the address it meant to read. Two-letter helper names are a trap here --
# rd, md, ls, cd, rm, mv, cp, cat and friends are all taken.
function GetU32([uint32]$l) {
    $b = [AztTool.ProcMem]::Read($g.ProcessId, (H1 $l), 4)
    if (-not $b) { throw 'the game exited' }
    return [BitConverter]::ToUInt32($b, 0)
}
function SetU32([uint32]$l, [uint32]$v) {
    [void][AztTool.ProcMem]::Write($g.ProcessId, (H1 $l), [BitConverter]::GetBytes($v))
}
# The creature rigs animate every frame, so the camera is not the only evidence that the
# simulation is alive -- but it is the one that needs no scene walk. Read it before and
# after each mask: if the engine is still simulating, a frame that was moving keeps
# moving. With the player standing still this mostly detects nothing, so the REAL
# responsiveness test is the player trying to walk under the winning mask.
function CamPos {
    $r = [AztTool.ProcMem]::Read($g.ProcessId, (H1 $S_cam), 320)
    if (-not $r) { throw 'the game exited' }
    return @([BitConverter]::ToSingle($r,172+48), [BitConverter]::ToSingle($r,172+52), [BitConverter]::ToSingle($r,172+56))
}

$capWas = GetU32 $capLin

if ($Mask -ge 0) {
    # ---- hold one mask and see whether the game still simulates --------------
    try {
        SetU32 $S_parts ([uint32]$Mask)
        Write-Host ("aztSceneParts = {0}. WALK AND LOOK AROUND for {1}s." -f $Mask, $Seconds) -ForegroundColor Cyan
        $p0 = CamPos
        $last = $p0; $path = 0.0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $c0 = GetU32 $S_count
        while ($sw.ElapsedMilliseconds -lt ($Seconds*1000)) {
            Start-Sleep -Milliseconds 100
            $p = CamPos
            $path += [Math]::Sqrt([Math]::Pow($p[0]-$last[0],2) + [Math]::Pow($p[1]-$last[1],2) + [Math]::Pow($p[2]-$last[2],2))
            $last = $p
        }
        $c1 = GetU32 $S_count
        $fps = ($c1 - $c0) / $sw.Elapsed.TotalSeconds
        Write-Host ''
        Write-Host ("  start {0,9:N1} {1,8:N1} {2,9:N1}" -f $p0[0], $p0[1], $p0[2])
        Write-Host ("  end   {0,9:N1} {1,8:N1} {2,9:N1}" -f $last[0], $last[1], $last[2])
        Write-Host ("  moved {0:N0} units over {1:N0}s at {2:N1} fps" -f $path, $sw.Elapsed.TotalSeconds, $fps)
        if ($path -lt 1) {
            Write-Host '  THE PLAYER COULD NOT MOVE -- this mask breaks the simulation.' -ForegroundColor Red
        } else {
            Write-Host '  THE SIMULATION SURVIVES THIS MASK.' -ForegroundColor Green
        }
    }
    finally {
        SetU32 $S_parts 0
        Start-Sleep -Milliseconds 200
        Write-Host ("restored: aztSceneParts {0}" -f (GetU32 $S_parts)) -ForegroundColor Green
    }
    return
}

$masks = @(
    @{ M = 0; Name = 'nothing skipped (baseline)' }
    @{ M = 1; Name = 'skip 0x5B7F0  (per scene element)' }
    @{ M = 2; Name = 'skip 0x39C14' }
    @{ M = 4; Name = 'skip 0x5B820' }
    @{ M = 5; Name = 'skip 0x5B7F0 + 0x5B820' }
    @{ M = 7; Name = 'skip all three' }
)
try {
    SetU32 $capLin 0
    Write-Host ("frame cap lifted ({0} -> 0). MOVEMENT IS NOW FAR TOO FAST -- stand still." -f $capWas) -ForegroundColor Yellow
    Write-Host ''
    Write-Host ("{0,-38} {1,9} {2,9}" -f 'mask', 'fps', 'vs base')
    $base = 0.0
    foreach ($m in $masks) {
        SetU32 $S_parts ([uint32]$m.M)
        Start-Sleep -Milliseconds 600            # let it settle before counting
        $c0 = GetU32 $S_count
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Start-Sleep -Milliseconds ($Hold * 1000)
        $sw.Stop()
        $c1 = GetU32 $S_count
        $fps = ($c1 - $c0) / $sw.Elapsed.TotalSeconds
        if ($m.M -eq 0) { $base = $fps }
        $rel = if ($base -gt 0) { 'x{0:N2}' -f ($fps / $base) } else { '-' }
        Write-Host ("{0,-38} {1,9:N1} {2,9}" -f $m.Name, $fps, $rel)
    }
}
finally {
    SetU32 $S_parts 0
    SetU32 $capLin $capWas
    Start-Sleep -Milliseconds 300
    Write-Host ''
    Write-Host ("restored: aztSceneParts {0}, aztFramePeriod {1}" -f (GetU32 $S_parts), (GetU32 $capLin)) -ForegroundColor Green
    Write-Host 'If one mask is both FAST and still lets you walk, that is the split Tier A needs.'
}
