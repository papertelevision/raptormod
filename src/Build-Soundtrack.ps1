# Build-Soundtrack.ps1 -- turn a folder of MP3s into the game's CD audio layout.
#
# Reads Soundtrack_mp3\, matches each file to one of the eleven music cues BY NAME,
# works out where each lands on the disc, and writes:
#
#   <dest>\AZT.CUE            the data track plus one AUDIO track per MP3
#   <dest>\AZTRACK<nn>.mp3    the audio, beside the CUE where DOSBox can reach it
#   art\music-tracks.json     slot -> {lba, sectors, us} for Build-AztMod
#
# THE NAME IS THE MAPPING. A file called INGAME.mp3 replaces the ingame.xmi cue,
# which is slot 6 in the table at 0x152A34. Anything not named after a cue is
# ignored, and any cue without a file keeps its MIDI.
#
# SECTOR ARITHMETIC. A CD-DA sector is 1/75 s. Track 1 is AZT.BIN at exactly
# 217,272 sectors of 2352 with no remainder, so the first audio track starts on
# that boundary and each one after it follows the previous back to back.
#
# The layout here must agree with how DOSBox lays the CUE out. It does not read the
# TOC back, so if a track ever plays as the wrong piece this arithmetic is the first
# thing to check -- the robust alternative is to read the TOC at runtime through
# MSCDEX (IOCTL input, control block 11) and fill the table from the disc instead.
param(
    [string]$Src  = "$([Environment]::GetFolderPath('Desktop'))\AzraelTearSoundtrack",      # (2026-10-14: was <Steam>\music-export\Soundtrack_mp3 -- the same 11 MP3s; this one is in the asset pack)
    [string]$Dest = 'C:\Games\AzraelsTear-Modded',
    [string]$ArtDir = "$PSScriptRoot\..\art",
    [int]   $DataSectors = 0,       # 0 = derive from AZT.BIN
    # The visor boot effect. Placed LAST, as slot 11, so it can never shift a music LBA --
    # which is what makes it safe to swap for a track of a different length.
    #
    # PROCESSED BY tools\Add-Reverb.ps1, and the settings are not arbitrary: they were
    # recovered by sweeping them until the output was BYTE-IDENTICAL to the shipped
    # booting2-verb.wav, so a new track can be made to match the old one exactly.
    #
    #   .\tools\Add-Reverb.ps1 -In <track>.mp3 -Out <track>-verb.wav `
    #       -Rate 22050 -Channels 1 -Tail 0.4 -Rt60 1.0 -Wet 0.15 -PeakDb -1
    #
    # -PeakDb -1 rather than the default peak-match: see Add-Reverb's own note on why
    # normalising back to the source peak makes the dry content quieter than it started.
    [string]$Effect = "$([Environment]::GetFolderPath('Desktop'))\AzraelTearSoundtrack\Effects\new-booting-verb.wav"
)
$ErrorActionPreference = 'Stop'

# The music table's own order, read out of the name strings the GM branch installs
# at 0x138E6. Index here IS the slot number.
$CUES = @('AWEMYST','CATHEDRL','EGYPTIAN','FIGHT2','GHOSTS','GRAIL',
          'INGAME','INGAME2','KREEPY2','KREEPY3','PEACEFUL')

if (-not (Test-Path $Src)) { throw "no soundtrack folder: $Src" }
$bin = Join-Path $Dest 'AZT.BIN'
if (-not (Test-Path $bin)) { throw "no AZT.BIN in $Dest" }
if ($DataSectors -le 0) {
    $len = (Get-Item $bin).Length
    if ($len % 2352 -ne 0) { throw "AZT.BIN is not a whole number of 2352-byte sectors" }
    $DataSectors = [int]($len / 2352)
}

# ---- DURATIONS ARE DECODED, NOT READ FROM THE SHELL -------------------------
# The shell's metadata reports WHOLE SECONDS, and an earlier version of this script used it
# on the reasoning that a second is only 75 sectors. That was wrong, and the error is not
# per-track -- IT ACCUMULATES, because every track's start is the previous one's end:
#
#   trk            real      ours      drift
#    2 AWEMYST   14,612    14,550          0
#    8 INGAME    26,965    26,925     2.49 s
#   12 PEACEFUL  15,570    15,525     4.97 s
#   13 BOOTFX     1,050     1,050     5.57 s   <- 418 sectors early
#
# DOSBox lays the tracks out from the FILES; we only tell the game where to seek. So by the
# last track the game was asking the drive to start 5.57 s before the boot effect -- inside
# the fade-out at the end of PEACEFUL. That is the "2 second orchestral swell" heard before
# the boot effect on every launch, and it is also the whole of the supposed "~4 s of CD start
# latency" this mod spent two rounds of work compensating for. There is no drive latency.
#
# A CD-DA sector is 588 frames at 44,100 Hz, so decode and divide. Slower than a shell
# property, and the only way to land on the same sector DOSBox does.
Add-Type -Path (Join-Path $PSScriptRoot '..\tools\AudioFx.cs')
function Get-TrackSectors {
    param([string]$path)
    $ch  = 0
    $pcm = [AztTool.AudioFx]::DecodePcm((Resolve-Path $path).Path, 44100, 1, [ref]$ch)
    if ($pcm.Length -eq 0) { throw "decoded no audio from $path" }
    [pscustomobject]@{
        Secs    = $pcm.Length / 44100.0
        Sectors = [int][Math]::Ceiling($pcm.Length / 588.0)
    }
}

$found = @()
foreach ($name in $CUES) {
    $file = Join-Path $Src "$name.mp3"
    if (-not (Test-Path $file)) { continue }
    $m = Get-TrackSectors $file
    $found += [pscustomobject]@{ Slot = $CUES.IndexOf($name); Name = $name; File = $file
                                 Secs = $m.Secs; Sectors = $m.Sectors }
}
if ($found.Count -eq 0) { throw "no MP3s named after a cue were found in $Src" }

# SLOT 11 IS NOT A MUSIC CUE. It is the visor boot effect, laid down as an ordinary audio
# track after the eleven cues so the boot sequence can play it through the same CD path --
# the engine has no PCM playback at all, so redbook audio is the only route to a recorded
# sound. It is deliberately last: adding or removing it cannot move any music track's LBA.
if ($Effect -and (Test-Path $Effect)) {
    $m = Get-TrackSectors $Effect
    $found += [pscustomobject]@{ Slot = 11; Name = 'BOOTFX'; File = $Effect
                                 Secs = $m.Secs; Sectors = $m.Sectors }
}

# Lay them out after the data track, back to back.
$lba = $DataSectors
$cue = New-Object System.Collections.Generic.List[string]
$cue.Add('FILE "AZT.BIN" BINARY')
$cue.Add('  TRACK 01 MODE1/2352')
$cue.Add('    INDEX 01 00:00:00')
$tab = @{}
$trackNo = 2
foreach ($t in $found) {
    # The DECODED sector count, not Secs*75 -- see the note where the durations are read.
    $sectors = $t.Sectors
    # A processed effect comes back as WAV: there is no MP3 encoder on this machine, so
    # Add-Reverb can only write PCM. The CUE takes WAVE tracks just as happily, and the
    # extension decides which keyword is emitted -- get that wrong and DOSBox mis-reads
    # the track rather than failing, which is far harder to spot.
    $ext     = [IO.Path]::GetExtension($t.File).ToLower()
    $kind    = if ($ext -eq '.wav') { 'WAVE' } else { 'MP3' }
    $audio   = "AZTRACK{0:00}{1}" -f $trackNo, $ext
    Copy-Item $t.File (Join-Path $Dest $audio) -Force
    $cue.Add(('FILE "{0}" {1}' -f $audio, $kind))
    $cue.Add(('  TRACK {0:00} AUDIO' -f $trackNo))
    $cue.Add('    INDEX 01 00:00:00')
    $tab[[string]$t.Slot] = [ordered]@{ name = $t.Name; track = $trackNo; lba = $lba
                                        sectors = $sectors; us = [int][Math]::Round($t.Secs * 1000000) }
    Write-Host ("  slot {0,2} {1,-9} track {2:00}  LBA {3,7}  {4,6} sectors  {5}:{6:00}.{7:00}" -f `
        $t.Slot, $t.Name, $trackNo, $lba, $sectors, [Math]::Floor($t.Secs/60),
        [Math]::Floor($t.Secs % 60), [Math]::Floor(($t.Secs * 100) % 100))
    $lba += $sectors
    $trackNo++
}

# The CUE the game mounts. Keep one pristine copy of the original the first time.
$cuePath = Join-Path $Dest 'AZT.CUE'
if (-not (Test-Path "$cuePath.aztbak")) { Copy-Item $cuePath "$cuePath.aztbak" }
$cue -join "`r`n" | Set-Content $cuePath -Encoding ascii

New-Item -ItemType Directory -Force $ArtDir | Out-Null
$tab | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $ArtDir 'music-tracks.json') -Encoding utf8

Write-Host ("soundtrack: {0} track(s) on CD, data track {1:N0} sectors, disc ends at LBA {2:N0}" -f `
    $found.Count, $DataSectors, $lba)
