# Add-Reverb.ps1 -- decode an audio file, add reverb, write a WAV for the CD track.
#
#   .\tools\Add-Reverb.ps1 -In "...\booting2.mp3" -Out "...\booting2-verb.wav"
#   .\tools\Add-Reverb.ps1 -In .. -Out .. -Rt60 1.2 -Wet 0.25 -Tail 1.5
#
# THE OUTPUT IS A WAV, NOT AN MP3. There is no MP3 encoder on this machine (no ffmpeg, no
# LAME), so a processed track can only come back as PCM. Build-Soundtrack emits WAVE in the
# CUE for a .wav effect, which DOSBox reads just as happily.
#
# -Tail appends silence before the reverb runs, so the tail has somewhere to decay into
# instead of being cut off at the last sample of the source.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$In,
    [Parameter(Mandatory)][string]$Out,
    [double]$Rt60 = 1.2,        # decay to -60 dB, in seconds
    [double]$Wet  = 0.25,       # 0 = dry, 1 = reverb only
    [double]$Tail = 1.5,        # silence appended for the tail
    [int]   $Rate = 44100,
    [int]   $Channels = 2,      # 1 = mono; with -Rate this is the size lever
    [switch]$NoNormalise,       # keep the louder, reverb-boosted level
    # Normalise to an ABSOLUTE peak (dBFS) instead of back to the source's own peak.
    # Scaling back to the source peak sounds intuitive but makes the result QUIETER than
    # the dry original: the reverb supplies the new peak, so the dry content underneath it
    # is scaled down by the whole correction -- 0.684, or -3.3 dB, at wet 0.25. Give this
    # a target near full scale and the dry content comes back up instead.
    [double]$PeakDb = 0
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $In)) { throw "no such file: $In" }
Add-Type -Path "$PSScriptRoot\AudioFx.cs"

Write-Host ("decoding {0}" -f (Split-Path $In -Leaf))
$ch = 0
$pcm = [AztTool.AudioFx]::DecodePcm((Resolve-Path $In).Path, $Rate, $Channels, [ref]$ch)
if ($pcm.Length -eq 0) { throw 'decoded no audio -- is the file readable by Media Foundation?' }
$secs = $pcm.Length / [double]($Rate * $ch)
Write-Host ("  {0:N0} samples, {1} ch, {2:N2} s" -f $pcm.Length, $ch, $secs)

# Peak before, so the effect of the wet mix on level is visible rather than guessed at.
$peak0 = 0; foreach ($s in $pcm) { $a = [Math]::Abs([int]$s); if ($a -gt $peak0) { $peak0 = $a } }

$pcm = [AztTool.AudioFx]::Pad($pcm, $Rate, $ch, $Tail)
[AztTool.AudioFx]::Reverb($pcm, $Rate, $ch, $Rt60, $Wet)

$peak1 = 0; foreach ($s in $pcm) { $a = [Math]::Abs([int]$s); if ($a -gt $peak1) { $peak1 = $a } }
Write-Host ("  reverb rt60 {0}s, wet {1:P0}, tail {2}s" -f $Rt60, $Wet, $Tail)
Write-Host ("  peak {0} -> {1}  ({2:N1} dBFS -> {3:N1} dBFS)" -f `
            $peak0, $peak1, (20*[Math]::Log10($peak0/32768)), (20*[Math]::Log10($peak1/32768)))

# REVERB ADDS ENERGY, so the wet mix alone pushed this from -2.7 dBFS to 0.0 -- right on the
# clipping edge. Scale back to the source's own peak: that keeps the chosen wet ratio intact
# and the level unchanged, rather than quietly making the effect louder than it was.
if ($PeakDb -ne 0 -and $peak1 -gt 0) {
    if ($PeakDb -gt 0) { throw "-PeakDb is a dBFS target and must be negative; got $PeakDb" }
    $target = 32767 * [Math]::Pow(10, $PeakDb / 20)
    $g = $target / [double]$peak1
    for ($i = 0; $i -lt $pcm.Length; $i++) {
        $v = [Math]::Round($pcm[$i] * $g)
        if ($v -gt 32767) { $v = 32767 } elseif ($v -lt -32768) { $v = -32768 }
        $pcm[$i] = [int16]$v
    }
    Write-Host ("  normalised to {0:N1} dBFS (x{1:N3}); the dry level moves {2:N1} dB" -f `
                $PeakDb, $g, (20*[Math]::Log10($g)))
}
elseif (-not $NoNormalise -and $peak1 -gt $peak0 -and $peak1 -gt 0) {
    $g = $peak0 / [double]$peak1
    for ($i = 0; $i -lt $pcm.Length; $i++) { $pcm[$i] = [int16]([Math]::Round($pcm[$i] * $g)) }
    Write-Host ("  normalised back to the source peak (x{0:N3}) -> {1:N1} dBFS" -f $g, (20*[Math]::Log10($peak0/32768)))
}
elseif ($peak1 -ge 32767) { Write-Host '  ! clipped -- lower -Wet' -ForegroundColor Yellow }

[AztTool.AudioFx]::WriteWav($Out, $pcm, $Rate, $ch)
$o = Get-Item $Out
Write-Host ("wrote {0}  ({1:N2} MB, {2:N2} s)" -f $o.Name, ($o.Length/1MB), ($pcm.Length / [double]($Rate*$ch))) -ForegroundColor Green
