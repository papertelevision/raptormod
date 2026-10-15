# Test-Movie.ps1 -- watch any cutscene without playing to it.
#
#   .\tools\Test-Movie.ps1 -Name OUTRO2          # stage it, print the launch command
#   .\tools\Test-Movie.ps1 -Name OUTRO2 -Launch  # stage it and launch
#   .\tools\Test-Movie.ps1 -Restore              # put the startup movies back
#   .\tools\Test-Movie.ps1 -List                 # what is available and how big
#
# HOW IT WORKS. Only two movies play without being earned: MINDLOGO.MOV and INTRO.MOV, both in
# GAME\AZRAEL, both at startup. This copies the movie under test over one of those slots, so it
# plays a few seconds after launch. Nothing is patched and nothing in GAME\MOV is touched.
#
# FRAME RATE. The rate is hard-coded at each CALL SITE, not read from the movie header --
# mindlogo runs 15 fps and intro 10, while the in-game cutscenes are authored at 12. So by
# default a movie tested here would play fast or slow, with its audio at that same wrong rate.
# This patches the call site's immediate to the movie's own fps while a test is staged, and puts
# the original value back on -Restore, so speed and audio pitch are representative too. Use
# -KeepFps to leave the engine's rate alone.
#
#   Trustworthy: picture, palette, sharpness, whether it fills the screen, whether the keyframe
#                fits the 819,200-byte movie buffer (a bad fit corrupts the heap and the HUD
#                disappears), whether it decodes to the end, playback speed and audio pitch.
#   Still not:   how the cutscene sits against the music bed, and any script side effects --
#                those only happen at the real trigger.
#
# The patched bytes are the `mov edx, <fps>` immediate feeding the movie player at 0x20BD4.
# It is a plain immediate, NOT a relocated operand, so writing it is safe -- see
# azrael-le-image-layout for why that distinction matters. The original value is recorded in a
# sidecar next to this script and restored byte-exactly; if Apply-AztMod rebuilds R.EXE while a
# test is staged, restoring simply rewrites the same default the build produces.
#
# The backups are <name>.testbak and are only ever created, never overwritten, so an interrupted
# run cannot lose the startup movies. -Restore is safe to run at any time, including twice.

[CmdletBinding(DefaultParameterSetName = 'stage')]
param(
    [Parameter(ParameterSetName = 'stage', Position = 0)][string]$Name,
    [Parameter(ParameterSetName = 'stage')][ValidateSet('mindlogo','intro')][string]$Slot = 'mindlogo',
    [Parameter(ParameterSetName = 'stage')][switch]$Launch,
    [Parameter(ParameterSetName = 'stage')][switch]$KeepFps,
    [Parameter(ParameterSetName = 'restore')][switch]$Restore,
    [Parameter(ParameterSetName = 'list')][switch]$List,
    [string]$GameRoot = 'C:\Games\RaptorMod\game'
)

$ErrorActionPreference = 'Stop'
$azrael = Join-Path $GameRoot 'GAME\AZRAEL'
$movdir = Join-Path $GameRoot 'GAME\MOV'
$slots  = @{ mindlogo = (Join-Path $azrael 'MINDLOGO.MOV'); intro = (Join-Path $azrael 'INTRO.MOV') }
$BUFFER = 819200        # the patched movie buffer; frame 0 must fit inside it
$EXE    = Join-Path $azrael 'R.EXE'
$SIDE   = Join-Path $PSScriptRoot 'Test-Movie.state.json'

# `mov edx, <fps>` immediately before the call to the movie player at 0x20BD4.
# File offset = linear - 0x10000 + 0x61A54 (obj1 base), verified against the opcode below.
$FPS_SITES = @{
    mindlogo = @{ Lin = 0x1FF5D; File = 0x0719B1; Default = 15 }
    intro    = @{ Lin = 0x1FFB6; File = 0x071A0A; Default = 10 }
}

function Set-CallSiteFps([string]$slot, [int]$fps) {
    $site = $FPS_SITES[$slot]
    $b = [IO.File]::ReadAllBytes($EXE)
    if ($b[$site.File] -ne 0xBA) {
        Write-Host ("  ! 0x{0:X6} is not a 'mov edx, imm32' -- leaving the frame rate alone" -f $site.File) -ForegroundColor Yellow
        return $null
    }
    $was = [BitConverter]::ToInt32($b, $site.File + 1)
    [Array]::Copy([BitConverter]::GetBytes([int]$fps), 0, $b, $site.File + 1, 4)
    [IO.File]::WriteAllBytes($EXE, $b)
    return $was
}

function Restore-CallSiteFps {
    if (-not (Test-Path $SIDE)) { return }
    $st = Get-Content $SIDE -Raw | ConvertFrom-Json
    if ($null -ne $st.FpsOffset) {
        $b = [IO.File]::ReadAllBytes($EXE)
        if ($b[$st.FpsOffset] -eq 0xBA) {
            [Array]::Copy([BitConverter]::GetBytes([int]$st.FpsOriginal), 0, $b, [int]$st.FpsOffset + 1, 4)
            [IO.File]::WriteAllBytes($EXE, $b)
            Write-Host ("restored the {0} call site to {1} fps" -f $st.Slot, $st.FpsOriginal) -ForegroundColor Green
        } else {
            Write-Host '  ! R.EXE no longer looks patched there (rebuilt?); left as is' -ForegroundColor Yellow
        }
    }
    [IO.File]::Delete($SIDE)
}

function Get-MovInfo([string]$path) {
    # Header: magic, then width/height/frames/fps. Frame 0's payload is the sum of its chunk
    # sizes, which is what has to fit the buffer -- see azrael-mov-format.
    $b = [IO.File]::ReadAllBytes($path)
    if ($b.Length -lt 32) { return $null }
    if ([BitConverter]::ToUInt32($b,0) -ne [Convert]::ToUInt32('AB12EF90',16)) { return $null }
    # layout per AnimTool.Anim: frames@4, fps@6, width@8, height@10; frames start at 30
    $frames = [BitConverter]::ToUInt16($b,4)
    $fps    = [BitConverter]::ToUInt16($b,6)
    $w      = [BitConverter]::ToUInt16($b,8)
    $h      = [BitConverter]::ToUInt16($b,10)

    # THE HEADER FPS IS WRONG AND THE AUDIO KNOWS BETTER.
    # Every movie carrying audio carries exactly 0.1 s of it per frame -- 10 fps -- and the
    # game's own call sites hard-code 10 (mov edx,0xA), ignoring the header's 12. Measured on
    # OUTRO2: 8,825,590 bytes of stereo 8-bit 22,050 Hz = 200.1 s, which is 2000 frames at 10 fps
    # exactly, not the 166.7 s that 12 fps implies. Asking for 12 while the audio supplies 10
    # makes the engine block on the sound buffer every frame, and that reads as stutter -- worst
    # on OUTRO2, the only movie that is both full-screen 1024x768 AND carries stereo audio.
    $trueFps = $fps; $src = 'header'
    $pos = 30
    for ($f = 0; $f -lt 2 -and $pos + 16 -le $b.Length; $f++) {
        $nChunks = [BitConverter]::ToUInt16($b, $pos+4)
        $raw     = [BitConverter]::ToUInt32($b, $pos+6)
        $cmp     = [BitConverter]::ToUInt32($b, $pos+10)
        $pay     = $pos + 16
        if ($cmp -ne 0) { break }        # compressed frame; not worth inflating just for this
        if ($f -eq 1) {
            $cp = $pay
            for ($c = 0; $c -lt $nChunks -and $cp + 16 -le $b.Length; $c++) {
                $ctype = [BitConverter]::ToUInt16($b, $cp+4)
                $csize = [BitConverter]::ToUInt32($b, $cp+6)
                if ($ctype -eq 6 -or $ctype -eq 7) {
                    $bps = 22050 * $(if ($ctype -eq 7) { 2 } else { 1 })
                    if ($csize -gt 0) { $trueFps = [int][Math]::Round($bps / [double]$csize); $src = "audio, $csize B/frame" }
                    break
                }
                $cp += 16 + $csize
            }
        }
        $pos = $pay + $raw
    }
    [pscustomobject]@{ Width=$w; Height=$h; Frames=$frames; Fps=$trueFps
                       HeaderFps=$fps; FpsSource=$src; Bytes=(Get-Item $path).Length }
}

if ($List) {
    Write-Host ''
    Write-Host ('{0,-14} {1,11} {2,8} {3,7}   {4}' -f 'movie','size','frames','size','state')
    foreach ($f in (Get-ChildItem $movdir -Filter '*.MOV' -File | Sort-Object Name)) {
        $i = Get-MovInfo $f.FullName
        $orig = Join-Path $movdir ('orig\' + $f.Name)
        $state = if (Test-Path $orig) { if ((Get-Item $orig).Length -eq $f.Length) { 'stock' } else { 'upscaled' } } else { '-' }
        Write-Host ('{0,-14} {1,8:N1} MB {2,8:N0} {3,7}   {4}' -f `
                    $f.BaseName, ($f.Length/1MB), $i.Frames, ("$($i.Width)x$($i.Height)"), $state)
    }
    Write-Host ''
    foreach ($k in 'mindlogo','intro') {
        $bak = $slots[$k] + '.testbak'
        if (Test-Path $bak) { Write-Host ("  ! the $k slot currently holds a TEST movie -- run -Restore") -ForegroundColor Yellow }
    }
    return
}

if ($Restore) {
    $n = 0
    foreach ($k in 'mindlogo','intro') {
        $live = $slots[$k]; $bak = "$live.testbak"
        if (Test-Path $bak) {
            Copy-Item $bak $live -Force
            [IO.File]::Delete($bak)
            Write-Host ("restored the $k slot") -ForegroundColor Green
            $n++
        }
    }
    Restore-CallSiteFps
    if (-not $n) { Write-Host 'nothing staged; the startup movies are already the real ones' }
    return
}

if (-not $Name) { throw 'give a movie name, e.g. -Name OUTRO2   (or use -List / -Restore)' }

$src = Join-Path $movdir ($Name.ToUpper().Replace('.MOV','') + '.MOV')
if (-not (Test-Path $src)) { throw "no such movie: $src   (try -List)" }

$info = Get-MovInfo $src
if (-not $info) { throw "$src is not an IAnimation .MOV (bad magic)" }

# Frame 0 = palette + keyframe + the audio priming chunk. Reject anything that cannot fit the
# buffer rather than letting it corrupt the heap in game.
$key = $info.Width * $info.Height
Write-Host ''
Write-Host ("{0}: {1} frames {2}x{3} @ {4} fps, {5:N1} MB" -f `
            $Name.ToUpper(), $info.Frames, $info.Width, $info.Height, $info.Fps, ($info.Bytes/1MB))
Write-Host ("  keyframe {0:N0} bytes of a {1:N0} byte buffer, {2:N0} spare" -f $key, $BUFFER, ($BUFFER - $key))
if ($key -ge $BUFFER) {
    Write-Host '  REFUSING TO STAGE: the keyframe alone does not fit the movie buffer.' -ForegroundColor Red
    return
}

$live = $slots[$Slot]; $bak = "$live.testbak"
if (-not (Test-Path $bak)) { Copy-Item $live $bak }     # created once, never overwritten
Copy-Item $src $live -Force
Write-Host ("staged into the {0} slot ({1})" -f $Slot, (Split-Path $live -Leaf)) -ForegroundColor Green

$state = @{ Slot = $Slot }
$siteFps = $FPS_SITES[$Slot].Default
if ($KeepFps) {
    Write-Host ("  engine rate left at {0} fps; the movie is {1} fps, so it will play {2}" -f `
                $siteFps, $info.Fps, $(if ($siteFps -gt $info.Fps) { 'fast' } else { 'slow' })) -ForegroundColor DarkGray
} elseif ($siteFps -eq $info.Fps) {
    Write-Host ("  call site already runs at {0} fps, no patch needed" -f $siteFps) -ForegroundColor DarkGray
} else {
    $was = Set-CallSiteFps $Slot $info.Fps
    if ($null -ne $was) {
        $state.FpsOffset   = $FPS_SITES[$Slot].File
        $state.FpsOriginal = $was
        Write-Host ("  patched the {0} call site {1} -> {2} fps so it plays at its authored speed" -f `
                    $Slot, $was, $info.Fps) -ForegroundColor Green
    }
}
$state | ConvertTo-Json | Set-Content $SIDE -Encoding utf8
Write-Host ''

$bat = Join-Path $GameRoot 'Play-Azrael-Staging.bat'
if ($Launch) {
    Write-Host 'launching...'
    & $bat | Out-Null
    Write-Host 'game exited.'
    Write-Host 'run  .\tools\Test-Movie.ps1 -Restore  when you are done testing.' -ForegroundColor Yellow
} else {
    Write-Host 'now run:'
    Write-Host ("    {0}" -f $bat)
    Write-Host 'and afterwards:'
    Write-Host '    .\tools\Test-Movie.ps1 -Restore'
}
