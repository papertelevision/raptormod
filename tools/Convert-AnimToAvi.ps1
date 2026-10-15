# Convert-AnimToAvi.ps1 -- turn Azrael's .MOV cutscenes into playable AVI files.
#
#   .\tools\Convert-AnimToAvi.ps1 -Path MOV_TOB.MOV -Out C:\tmp\TOB.avi
#   .\tools\Convert-AnimToAvi.ps1 -InDir <folder of .MOV> -OutDir C:\Games\RaptorMod\sources\video
#
# Motion-JPEG video plus 8-bit PCM audio, muxed by tools\AviWriter.cs. There is no ffmpeg on
# this machine, so the container is written directly.
#
# FRAME RATE. The file header says 12, and for the eight movies that carry audio that is
# wrong: every audio chunk holds 2205 sample-frames, which at 22050 Hz is exactly 0.1s, so
# they run at 10 fps. Playing them at 12 would run the picture 20% fast and desynchronise it
# from its own soundtrack. -Fps forces a value for the four silent movies if you disagree.
#
# AUDIO. Chunk type 6 is mono, type 7 is stereo -- established from the samples, not from a
# header field: type 7's bytes resolve into two independently smooth waveforms on the even
# and odd indices. Four movies (COBANI, LEOCATH, LEOEXE, LIBEMPTY) carry no audio chunks at
# all; their dialogue lives in SOUNDS\ on the CD and is played separately by the game.

[CmdletBinding()]
param(
    [string]$Path,
    [string]$Out,
    [string]$InDir,
    [string]$OutDir,
    [int]$Fps = 0,                 # 0 = decide from the audio, else force
    [int]$Quality = 92,
    [int]$MaxFrames = 0,
    # An EXTERNAL soundtrack to mux in, for movies that carry no audio chunks.
    # MINDLOGO is the known case: it has no type 6/7 chunks at all, and its sound is
    # LOGO.WAV sitting next to it in GAME\AZRAEL -- 22,050 Hz 8-bit stereo, 8.31s. The
    # game plays the two together; the .MOV alone is silent by design.
    [string]$Wav,
    [string]$GameDir = 'C:\Games\RaptorMod\game\GAME\AZRAEL'
)

# movies with no embedded audio whose soundtrack is a separate file
$EXTERNAL_AUDIO = @{ 'MINDLOGO' = 'LOGO.WAV' }

function Read-Wav {
    param([string]$path)
    $b = [IO.File]::ReadAllBytes($path)
    if ([Text.Encoding]::ASCII.GetString($b,0,4) -ne 'RIFF') { throw "$path is not RIFF" }
    $p = 12; $fmt = $null; $dOff = -1; $dLen = 0
    while ($p + 8 -le $b.Length) {
        $id = [Text.Encoding]::ASCII.GetString($b,$p,4)
        $sz = [int][BitConverter]::ToUInt32($b,$p+4)
        if ($id -eq 'fmt ') {
            $fmt = [pscustomobject]@{
                Tag  = [BitConverter]::ToUInt16($b,$p+8)
                Ch   = [BitConverter]::ToUInt16($b,$p+10)
                Rate = [int][BitConverter]::ToUInt32($b,$p+12)
                Bits = [BitConverter]::ToUInt16($b,$p+22)
            }
        }
        if ($id -eq 'data') { $dOff = $p + 8; $dLen = $sz }
        $p += 8 + $sz + ($sz -band 1)
    }
    if (-not $fmt -or $dOff -lt 0) { throw "$path has no fmt/data chunk" }
    if ($fmt.Tag -ne 1) { throw "$path is not PCM (format tag $($fmt.Tag))" }
    [pscustomobject]@{ Bytes=$b; Off=$dOff; Len=[Math]::Min($dLen, $b.Length-$dOff)
                       Ch=$fmt.Ch; Rate=$fmt.Rate; Bits=$fmt.Bits }
}

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path (Split-Path -Parent $PSCommandPath) 'LoadAnim.ps1')

function Convert-One {
    param([string]$src, [string]$dst, [string]$wavPath)

    # a first pass just to learn whether there is audio, and of which kind
    $probe = New-Object AztTool.Anim ($src)
    [void]$probe.NextFrame()
    $hasEmbedded = $probe.HasAudio
    $stem = ([IO.Path]::GetFileNameWithoutExtension($src)) -replace '^MOV_',''

    # fall back to a known external soundtrack when there are no audio chunks
    if (-not $hasEmbedded -and -not $wavPath -and $EXTERNAL_AUDIO.ContainsKey($stem)) {
        $cand = Join-Path $GameDir $EXTERNAL_AUDIO[$stem]
        if (Test-Path $cand) { $wavPath = $cand }
    }
    $wav = if ($wavPath) { Read-Wav $wavPath } else { $null }

    $hasAudio = $hasEmbedded -or ($null -ne $wav)
    $channels = if ($wav) { $wav.Ch } else { $probe.AudioChannels }
    $rate     = if ($wav) { $wav.Rate } else { [AztTool.Anim]::SampleRate }
    $bits     = if ($wav) { $wav.Bits } else { 8 }

    # Embedded audio pins the rate: 2205 sample-frames per video frame at 22,050 Hz is
    # 0.1s, so those movies are 10 fps whatever the header says. An EXTERNAL soundtrack
    # pins nothing, so the header value stands -- MINDLOGO is 96 frames and LOGO.WAV is
    # 8.31s, which matches 12 fps far better than 10.
    $useFps = if ($Fps -gt 0) { $Fps }
              elseif ($hasEmbedded) { [int]([AztTool.Anim]::SampleRate / [AztTool.Anim]::SamplesPerFrame) }
              else { $probe.Fps }

    $anim = New-Object AztTool.Anim ($src)
    $avi = New-Object AztTool.AviWriter ($dst, $anim.Width, $anim.Height, $useFps, $hasAudio, $channels, $rate, $bits)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $n = 0; $audioBytes = 0
    $blockAlign = $channels * [Math]::Max(1, [int]($bits / 8))
    $wavPerFrame = [int]([Math]::Floor($rate / [double]$useFps)) * $blockAlign
    $wavPos = 0
    $slice = if ($wav) { New-Object byte[] $wavPerFrame } else { $null }
    try {
        while ($anim.NextFrame()) {
            $bmp = $anim.ToBitmap()
            try { $avi.AddFrame($bmp, [long]$Quality) } finally { $bmp.Dispose() }
            if ($wav) {
                $take = [Math]::Min($wavPerFrame, $wav.Len - $wavPos)
                if ($take -gt 0) {
                    [Array]::Copy($wav.Bytes, $wav.Off + $wavPos, $slice, 0, $take)
                    $avi.AddAudio($slice, $take)
                    $audioBytes += $take; $wavPos += $take
                }
            } elseif ($hasEmbedded -and $anim.LastAudioLen -gt 0) {
                $avi.AddAudio($anim.LastAudio, $anim.LastAudioLen)
                $audioBytes += $anim.LastAudioLen
            }
            $n++
            if ($MaxFrames -gt 0 -and $n -ge $MaxFrames) { break }
        }
    } finally { $avi.Close() }
    $sw.Stop()

    $secs = $n / [double]$useFps
    $src2 = if ($wav) { "WAV " + (Split-Path $wavPath -Leaf) } else { 'embedded' }
    $aud = if ($hasAudio) { "{0} {1}ch {2:N0}Hz {3}b {4:N1}s" -f $src2, $channels, $rate, $bits, ($audioBytes / [double]($rate * $blockAlign)) } else { 'none' }
    Write-Host ("{0,-18} {1,4} frames {2}x{3} @ {4} fps = {5,5:N1}s   audio {6,-34} {7,9:N0} KB  {8,6:N0} ms" -f `
                (Split-Path $dst -Leaf), $n, $anim.Width, $anim.Height, $useFps, $secs, $aud,
                ((Get-Item $dst).Length / 1KB), $sw.ElapsedMilliseconds) -ForegroundColor Green
}

if ($InDir) {
    if (-not $OutDir) { throw '-InDir needs -OutDir' }
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    foreach ($f in (Get-ChildItem $InDir -Filter '*.MOV' | Sort-Object Name)) {
        $name = ($f.BaseName -replace '^MOV_','') + '.avi'
        Convert-One $f.FullName (Join-Path $OutDir $name) $Wav
    }
} elseif ($Path) {
    if (-not $Out) { throw '-Path needs -Out' }
    Convert-One $Path $Out $Wav
} else {
    throw 'give -Path/-Out or -InDir/-OutDir'
}
