# Make-LoadingAudio.ps1 -- the loading screen's sound, built into AztMod\art\loading (Josh, 2026-10-07):
#   loading-voice.wav  "Loading ... Raptor Mod." (from Make-LoadingVoice.ps1), its silent reverb tail trimmed off, so
#                      "always finish the voice" does not mean waiting on inaudible silence
#   loading-track.wav  Josh's raptormod_loading.mp3, decoded once to 44.1 kHz stereo PCM: the loading screen plays both
#                      through winmm MCI, whose MP3 device does not open on every Windows ("A problem occurred in
#                      initializing MCI", seen on the dev machine) -- WAV always does.
#
#   .\Make-LoadingAudio.ps1 [-Track <mp3>] [-Voice <wav>] [-CutDb -55]
param(
    [string]$Track = 'C:\Games\RaptorMod\sources\soundtrack\NewSounds\raptormod_loading.mp3',
    [string]$Voice = '',
    [string]$Ratchet = 'C:\Games\RaptorMod\sources\soundtrack\NewSounds\ratchet.mp3',     # the HUD's slide-in (Josh's own)
    [double]$CutDb = -55
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mod = Resolve-Path (Join-Path $here '..\..')
if (-not $Voice) { $Voice = Join-Path $here '11-loading-raptormod.wav' }
$out = Join-Path $mod 'art\loading'; New-Item -ItemType Directory -Force $out | Out-Null
Add-Type -Path (Join-Path $mod 'tools\AudioFx.cs') -ErrorAction Stop

# the track: MP3 -> PCM through Media Foundation
$ch = 0; $pcm = [AztTool.AudioFx]::DecodePcm($Track, 44100, 2, [ref]$ch)
[AztTool.AudioFx]::WriteWav((Join-Path $out 'loading-track.wav'), $pcm, 44100, $ch)
"track: {0:N2} s, {1} ch -> loading-track.wav" -f ($pcm.Length / $ch / 44100.0), $ch

# the voice: cut where the tail stays under CutDb for good, with a short fade
$b = [IO.File]::ReadAllBytes($Voice)
if ([Text.Encoding]::ASCII.GetString($b, 36, 4) -ne 'data') { throw "unexpected WAV layout in $Voice (expects a plain 44-byte header)" }
$vch = [BitConverter]::ToInt16($b, 22); $rate = [BitConverter]::ToInt32($b, 24); $n = [BitConverter]::ToInt32($b, 40) / 2
$v = New-Object Int16[] $n; [Buffer]::BlockCopy($b, 44, $v, 0, $n * 2)
$lim = [Math]::Pow(10, $CutDb / 20) * 32768; $last = 0
for ($i = 0; $i -lt $n; $i++) { if ([Math]::Abs([int]$v[$i]) -gt $lim) { $last = $i } }
$fade = [int](0.35 * $rate) * $vch; $end = [Math]::Min($n, $last + $fade); $end -= $end % $vch
$cut = New-Object Int16[] $end; [Array]::Copy($v, $cut, $end)
for ($i = [Math]::Max(0, $end - $fade); $i -lt $end; $i++) { $cut[$i] = [Int16]($cut[$i] * (($end - $i) / [double]$fade)) }
[AztTool.AudioFx]::WriteWav((Join-Path $out 'loading-voice.wav'), $cut, $rate, $vch)
"voice: {0:N2} s of {1:N2} s kept (tail under {2} dB cut) -> loading-voice.wav" -f ($end / $vch / [double]$rate), ($n / $vch / [double]$rate), $CutDb

# the HUD's slide-in: Josh's ratchet.mp3, decoded the same way, to art\boot (BootHd plays it as the HUD is let go)
if ($Ratchet -and (Test-Path $Ratchet)) {
    $bootDir = Join-Path $mod 'art\boot'; New-Item -ItemType Directory -Force $bootDir | Out-Null
    $rch = 0; $rp = [AztTool.AudioFx]::DecodePcm($Ratchet, 44100, 2, [ref]$rch)
    [AztTool.AudioFx]::WriteWav((Join-Path $bootDir 'hud-ratchet.wav'), $rp, 44100, $rch)
    "ratchet: {0:N2} s, {1} ch -> art\boot\hud-ratchet.wav" -f ($rp.Length / $rch / 44100.0), $rch
}
