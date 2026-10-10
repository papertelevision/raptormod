# Convert-ToAnim.ps1 -- build a .MOV the game can play.
#
#   # round-trip an existing movie through decode -> encode -> decode and prove it is exact
#   .\tools\Convert-ToAnim.ps1 -FromMov MOV_TOB.MOV -Out TOB_new.MOV -Verify
#
#   # encode replacement artwork, taking audio, fps and size from the original
#   .\tools\Convert-ToAnim.ps1 -InDir frames\ -Ref MOV_TOB.MOV -Out TOB_new.MOV -Verify
#
# AUDIO IS COPIED THROUGH VERBATIM. The audio chunks are lifted from the reference movie
# frame by frame and re-emitted with their original type, so replacing the picture cannot
# disturb the soundtrack. Movies whose sound lives outside the .MOV (MINDLOGO and the
# SOUNDS\ dialogue) are unaffected either way -- the game keeps playing those over the top.
#
# ONE PALETTE PER MOVIE. The format carries a single type-5 chunk, so all frames share 256
# colours. With -InDir the palette is built by median cut over frames sampled across the
# whole movie; -KeepPalette reuses the original's instead, which keeps a re-encode identical
# and is what -FromMov does by default.
#
# WHY -Verify MATTERS. A wrong encoder produces a file that decodes to something -- often
# something that looks fine for a while and then drifts. Verify decodes the file it just
# wrote and compares every pixel against what went in. A clean round-trip of an original
# movie is EXACT, because literal blocks reproduce their pixels and skipped blocks reproduce
# the previous frame, which was itself exact.

[CmdletBinding()]
param(
    [string]$FromMov,
    [string]$InDir,
    # An MP4 straight from an upscaler. Decoded with Windows Media Foundation (no ffmpeg on
    # this machine); its frame count must match the reference movie's or the audio, which is
    # copied through per frame, would drift.
    [string]$Mp4,
    [string]$Ref,
    [Parameter(Mandatory)][string]$Out,
    [int]$Fps = 0,
    [int]$Width = 0,
    [int]$Height = 0,
    # Fit the source inside the target instead of stretching to fill it, padding with black.
    # For a source whose aspect already matches the target this changes nothing.
    [switch]$Letterbox,
    # Take every Nth source frame. Upscalers often INTERPOLATE as well as enlarge --
    # TensorPix returned 192 frames for a 96-frame movie -- and the extra frames are not
    # free: this format's timing comes from the header fps, so doubling the frame count at
    # the same fps doubles the running time and desynchronises the soundtrack. 0 = auto:
    # decimate when the source is an exact integer multiple of the reference.
    [int]$FrameStep = 0,
    # Floyd-Steinberg error diffusion. OFF by default: it costs compression, because
    # dither noise makes blocks differ from the previous frame even in static areas and
    # the skip runs collapse. Worth it for banding on smooth gradients (logos, fades).
    [switch]$Dither,
    [switch]$KeepPalette,
    [int]$PaletteSamples = 24,
    [switch]$Verify,
    [int]$Progress = 0,        # print a progress line every N frames (0 = silent)
    # --- a BRAND-NEW movie, with no original to take anything from ---------------
    # Everything the reference would have supplied has to be given instead: geometry, fps,
    # how many frames to emit, and where the sound comes from. The audio is SYNTHESISED
    # rather than copied, which this format allows because its audio chunks are raw PCM --
    # type 6 is 8-bit unsigned mono, type 7 is stereo.
    [int]$Frames = 0,          # output frame count; 0 = whatever the source has
    [string]$AudioFrom,        # any file Media Foundation can read (the MP4 itself works)
    [int]$AudioRate = 22050,   # what the shipped movies use: 2205 bytes/frame at 10 fps
    [switch]$AudioStereo,
    # Scale the audio so its loudest peak just reaches -$AudioPeakDb. At 8 bits every decibel
    # of unused headroom is lost resolution, so a master mixed with normal headroom arrives
    # with several bits already thrown away. Off by default: it changes the level relative to
    # the rest of the game's movies, which is a mix decision, not a technical one.
    [switch]$AudioNormalize,
    [double]$AudioPeakDb = -1.0,
    # Bytes of audio in frame 0, which is the player's buffer lead. -1 = match the shipped
    # movie of the same chunk type (10,000 for stereo, 16,384 for mono). 0 disables priming,
    # which is what every movie built before this did -- and why they crackled.
    [int]$AudioPrime = -1
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path (Split-Path -Parent $PSCommandPath) 'LoadAnim.ps1')

$refMov = if ($Ref) { $Ref } elseif ($FromMov) { $FromMov } else { $null }
$newMovie = -not $refMov
if ($newMovie) {
    if (-not ($Mp4 -or $InDir)) { throw 'give -FromMov, or -InDir/-Mp4 with -Ref, or -Mp4 with -Width/-Height/-Fps for a new movie' }
    if ($Width -le 0 -or $Height -le 0 -or $Fps -le 0) {
        throw 'a new movie has no reference to copy from, so -Width, -Height and -Fps are all required'
    }
} elseif (-not (Test-Path $refMov)) { throw "no such reference movie: $refMov" }

# ---- harvest audio + geometry from the reference -----------------------------
$src = $null
$audio = New-Object System.Collections.ArrayList
$srcFrames = New-Object System.Collections.ArrayList
$audioType = 0
if (-not $newMovie) {
    $src = New-Object AztTool.Anim ($refMov)
    while ($src.NextFrame()) {
        if ($src.LastAudioLen -gt 0) {
            $a = New-Object byte[] $src.LastAudioLen
            [Array]::Copy($src.LastAudio, $a, $src.LastAudioLen)
            [void]$audio.Add($a)
            $audioType = $src.AudioType
        } else { [void]$audio.Add($null) }
        if ($FromMov) { [void]$srcFrames.Add($src.GetPixels()) }
    }
}
$W = if ($Width -gt 0) { $Width } else { $src.Width }
$H = if ($Height -gt 0) { $Height } else { $src.Height }
$useFps = if ($Fps -gt 0) { $Fps } else { $src.Fps }
if ($newMovie) {
    Write-Host ("new movie: {0}x{1} @ {2} fps, no reference" -f $W, $H, $useFps)
} else {
    Write-Host ("reference {0}: {1} frames {2}x{3} @ {4} fps, audio type {5}" -f `
                (Split-Path $refMov -Leaf), $audio.Count, $src.Width, $src.Height, $src.Fps, $audioType)
}

# resample a decoded MP4 frame (BGRA at its own size) to the target size
function Resize-Bgra {
    param([byte[]]$src, [int]$sw, [int]$sh, [int]$w, [int]$h)
    if ($sw -eq $w -and $sh -eq $h) { return ,$src }
    $a = New-Object System.Drawing.Bitmap($sw, $sh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $d = $a.LockBits((New-Object System.Drawing.Rectangle(0,0,$sw,$sh)),
            [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    [System.Runtime.InteropServices.Marshal]::Copy($src, 0, $d.Scan0, $src.Length)
    $a.UnlockBits($d)
    $b = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($b)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    # -Letterbox PRESERVES THE SOURCE'S SHAPE. Every shipped movie matches the target ratio,
    # so the default is a plain stretch and that stays the default -- but a cinematic rendered
    # at 2.33:1 squashed into the 1.78:1 viewport is 24% too narrow, which reads as a subtly
    # wrong picture rather than an obvious fault. With this on, the frame is fitted inside the
    # target and the remainder left black.
    if ($Letterbox) {
        $g.Clear([System.Drawing.Color]::Black)
        $sc = [Math]::Min($w/[double]$sw, $h/[double]$sh)
        $dw = [int][Math]::Round($sw*$sc); $dh = [int][Math]::Round($sh*$sc)
        $g.DrawImage($a, (New-Object System.Drawing.Rectangle([int](($w-$dw)/2), [int](($h-$dh)/2), $dw, $dh)))
    } else {
        $g.DrawImage($a, (New-Object System.Drawing.Rectangle(0,0,$w,$h)))
    }
    $g.Dispose(); $a.Dispose()
    $d2 = $b.LockBits((New-Object System.Drawing.Rectangle(0,0,$w,$h)),
            [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $out = New-Object byte[] ($w*$h*4)
    for ($y = 0; $y -lt $h; $y++) {
        [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]($d2.Scan0.ToInt64() + $y*$d2.Stride), $out, $y*$w*4, $w*4)
    }
    $b.UnlockBits($d2); $b.Dispose()
    ,$out
}

function Get-Bgra {
    param([string]$png, [int]$w, [int]$h)
    $img = [System.Drawing.Image]::FromFile($png)
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($img, (New-Object System.Drawing.Rectangle(0,0,$w,$h)))
    $g.Dispose(); $img.Dispose()
    $d = $bmp.LockBits((New-Object System.Drawing.Rectangle(0,0,$w,$h)),
            [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $buf = New-Object byte[] ($w*$h*4)
    for ($y = 0; $y -lt $h; $y++) {
        [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]($d.Scan0.ToInt64() + $y*$d.Stride), $buf, $y*$w*4, $w*4)
    }
    $bmp.UnlockBits($d); $bmp.Dispose()
    ,$buf
}

$enc = New-Object AztTool.AnimEncoder ($Out, $W, $H, $useFps)

# ---- palette ------------------------------------------------------------------
$pngs = @()
$mp4Frames = $null
if ($InDir) {
    $pngs = @(Get-ChildItem $InDir -Filter '*.png' | Sort-Object Name)
    if (-not $pngs.Count) { throw "no PNGs in $InDir" }
    Write-Host ("{0} replacement frames in {1}" -f $pngs.Count, $InDir)
} elseif ($Mp4) {
    if (-not (Test-Path $Mp4)) { throw "no such MP4: $Mp4" }
    # FRAMES ARE STREAMED, NEVER BUFFERED. An earlier version decoded the whole movie into
    # a list first, which is fine at 552x208 and impossible at 4x: OUTRO2 is 2,000 frames of
    # 2560x1920, which is 18.8 MB each and 36.6 GB in total. The twelve upscales together
    # would have wanted 73 GB.
    #
    # So the source is opened TWICE -- once to sample for the palette, once to encode -- and
    # only one frame is ever held. Reopening is the cheapest way to rewind; the Source Reader
    # has no free seek back to the start.
    $mp4Probe = & (Join-Path $toolDir 'Probe-Mp4.ps1') -Path $Mp4
    $mp4W = $mp4Probe.W; $mp4H = $mp4Probe.H; $mp4Count = $mp4Probe.Frames
    if ($mp4Count -le 0) { throw "could not read a frame count from $Mp4" }
    Write-Host ("{0}: {1} frames {2}x{3}  (streamed, {4:N1} MB per frame)" -f `
                (Split-Path $Mp4 -Leaf), $mp4Count, $mp4W, $mp4H, ($mp4W*$mp4H*4/1MB))

    # RESAMPLE TO THE REFERENCE'S FRAME COUNT, by position -- not by an integer step.
    # Upscalers change the frame RATE as well as the size and the ratio is not always whole:
    # an earlier TensorPix batch returned 2,880 frames for TALFNL's 1,199 (2.4x, i.e. 10 fps
    # retimed to 24). Playback is HARD-CODED to 10 fps at the call site, so surplus frames do
    # not play faster -- they play LONGER, and drift away from the soundtrack. Mapping each
    # output frame to its nearest source frame handles any ratio.
    $target = if ($Frames -gt 0) { $Frames }
              elseif ($FrameStep -gt 1) { [int][Math]::Ceiling($mp4Count / $FrameStep) }
              elseif ($audio.Count -gt 0) { $audio.Count }
              else { $mp4Count }
    if ($target -ne $mp4Count) {
        Write-Host ("  {0} source frames -> {1} ({2:N3}x); resampling by position" -f `
                    $mp4Count, $target, ($mp4Count/[double]$target)) -ForegroundColor Yellow
    }
}

# Pull frames from an Mp4Reader in output order, resampled by position, one at a time.
# $script:__rd / __srcIdx / __cur hold the single live frame between calls.
function Open-Mp4Stream { param([string]$path)
    if ($script:__rd) { $script:__rd.Dispose() }
    $script:__rd = New-Object AztTool.Mp4Reader ($path)
    $script:__srcIdx = -1
    $script:__cur = $null
}
function Get-Mp4FrameAt { param([int]$outIdx, [int]$srcCount, [int]$outCount)
    $want = [int][Math]::Round($outIdx * ($srcCount / [double]$outCount))
    if ($want -ge $srcCount) { $want = $srcCount - 1 }
    while ($script:__srcIdx -lt $want -or $null -eq $script:__cur) {
        $f = $script:__rd.ReadFrame()
        if ($null -eq $f) { break }
        $script:__cur = $f; $script:__srcIdx++
    }
    $script:__cur
}
function Close-Mp4Stream { if ($script:__rd) { $script:__rd.Dispose(); $script:__rd = $null } }

if ($KeepPalette -or $FromMov) {
    # *4, not *255/63: SetPalette stores value>>2, and (v*4)>>2 == v exactly for 0..63,
    # so the original palette survives the round trip bit for bit. Scaling by 255/63
    # would round some entries to a neighbouring 6-bit value.
    $p8 = New-Object byte[] 768
    for ($i = 0; $i -lt 768; $i++) { $p8[$i] = [byte]($src.Palette[$i] * 4) }
    $enc.SetPalette($p8)
    Write-Host "palette: reusing the original's"
} else {
    # Median cut over frames sampled across the movie, subsampled 1 pixel in 4. Each sample
    # is resized to the TARGET size before accumulating -- at 4x the source frames are up to
    # 18.8 MB each, so sampling them raw would defeat the point of streaming.
    $total = if ($Mp4) { $target } else { $pngs.Count }
    $step = [Math]::Max(1, [int]($total / $PaletteSamples))
    $acc = New-Object System.Collections.Generic.List[byte]
    if ($Mp4) { Open-Mp4Stream $Mp4 }
    for ($i = 0; $i -lt $total; $i += $step) {
        $b = if ($Mp4) { Resize-Bgra (Get-Mp4FrameAt $i $mp4Count $target) $mp4W $mp4H $W $H }
             else      { Get-Bgra $pngs[$i].FullName $W $H }
        for ($p = 0; $p -lt $b.Length; $p += 16) { $acc.Add($b[$p]); $acc.Add($b[$p+1]); $acc.Add($b[$p+2]); $acc.Add($b[$p+3]) }
    }
    if ($Mp4) { Close-Mp4Stream }
    $sample = $acc.ToArray()
    $n = [int]($sample.Length / 4)
    Write-Host ("palette: median cut over {0:N0} sampled pixels from {1} frames" -f $n, [Math]::Ceiling($total / $step))
    $pal3 = [LeTool.Quant]::MedianCut($sample, $n, 1, 256)
    $pal768 = New-Object byte[] 768
    [Array]::Copy($pal3, 0, $pal768, 0, [Math]::Min(768, $pal3.Length))
    $enc.SetPalette($pal768)
}

# ---- encode --------------------------------------------------------------------
$sw = [Diagnostics.Stopwatch]::StartNew()
# A HASH PER FRAME, NOT THE FRAME. Keeping every fed frame for the verify pass used to cost
# W*H bytes each -- 1.57 GB on OUTRO2 -- and, worse, those long-lived arrays sat on the Large
# Object Heap interleaved with the per-frame decode/resize garbage, so the heap could never be
# compacted around them. Measured on OUTRO1: retaining frames grew live memory 14.75 MB per
# frame and reached 3.2 GB by frame 200; not retaining them held flat at 226 MB for the whole
# run. 16 bytes a frame detects a single changed pixel just as surely.
$md5 = [System.Security.Cryptography.MD5]::Create()
$fed = New-Object 'System.Collections.Generic.List[string]'
$count = if ($FromMov) { $srcFrames.Count } elseif ($Mp4) { $target } else { $pngs.Count }

# ---- synthesised audio, for a movie with no reference to copy chunks from ------
# CHUNK BOUNDARIES BY POSITION, not by a fixed size. rate/fps is rarely a whole number --
# 22050 at 12 fps is 1837.5 -- and a rounded constant would walk the sound away from the
# picture over the length of the movie. Taking each frame's slice as
# floor((i+1)*rate/fps) - floor(i*rate/fps) makes the chunks sum to the sample count
# exactly, so the last frame ends on the last sample however the numbers fall.
if ($AudioFrom) {
    if (-not (Test-Path $AudioFrom)) { throw "no such audio source: $AudioFrom" }
    Add-Type -Path (Join-Path $toolDir 'AudioFx.cs')
    $wantCh = if ($AudioStereo) { 2 } else { 1 }
    $ch = 0
    $pcm = [AztTool.AudioFx]::DecodePcm((Resolve-Path $AudioFrom).Path, $AudioRate, $wantCh, [ref]$ch)
    if ($pcm.Length -eq 0) { throw "decoded no audio from $AudioFrom" }
    # ---- 16-bit signed -> 8-bit UNSIGNED, which is what chunk types 6 and 7 carry ----------
    # EIGHT BITS IS 48 dB OF RANGE IN TOTAL, so a quiet master has almost nothing left. The
    # opening render peaked at -5.2 dBFS with an RMS of -23.8, which at 8 bits means ordinary
    # content swinging over about +-9 of 128 steps -- roughly four effective bits. It reached
    # only 140 of the 256 codes, against 256 for the shipped INTRO and 208 for TOB, and it
    # sounded like crackle. The crackle is quantisation distortion, not a decode fault: the
    # error is CORRELATED with the signal, so it tracks the programme instead of sitting under
    # it. Three things fix that, and all three are cheap.
    #
    # 1. DC. Remove the offset before quantising, or it eats a code and biases the rounding.
    # 2. GAIN. Normalising to just under full scale is worth its decibels twice over here --
    #    every 6 dB recovered is a whole extra bit of the eight.
    # 3. DITHER. A triangular (TPDF) +-1 LSB noise added BEFORE rounding decorrelates the
    #    error, trading gritty distortion for a steady, much quieter-sounding hiss. Seeded, so
    #    a rebuild of the same source is byte-identical.
    #
    # ROUND, do not shift. `(v + 32768) -shr 8` truncates, which is a half-LSB downward bias on
    # every sample -- a DC step of its own and needless extra error.
    $nTot = $pcm.Length
    $dc = 0.0
    for ($k = 0; $k -lt $nTot; $k++) { $dc += [int]$pcm[$k] }
    $dc = $dc / $nTot
    $pk = 0.0
    for ($k = 0; $k -lt $nTot; $k++) {
        $m = [Math]::Abs([int]$pcm[$k] - $dc); if ($m -gt $pk) { $pk = $m }
    }
    $gain = 1.0
    if ($AudioNormalize -and $pk -gt 0) { $gain = (32767.0 * [Math]::Pow(10.0, $AudioPeakDb / 20.0)) / $pk }
    Write-Host ("  audio: DC {0:N1}, peak {1:N0} ({2:N2} dBFS), gain x{3:N3} ({4:N2} dB){5}" -f `
                $dc, $pk, (20*[Math]::Log10($pk/32768.0)), $gain, (20*[Math]::Log10($gain)),
                $(if ($AudioNormalize) { '' } else { ' -- pass -AudioNormalize to use the full 8-bit range' }))
    $u8  = New-Object byte[] $nTot
    $rng = New-Object System.Random(20260101)      # fixed: same input -> same output
    for ($k = 0; $k -lt $nTot; $k++) {
        # TPDF: two independent uniforms summed span +-1 LSB, and 1 LSB here is 256 counts.
        $d = ($rng.NextDouble() + $rng.NextDouble() - 1.0) * 256.0
        $q = [int][Math]::Round(((([double]$pcm[$k] - $dc) * $gain) + $d + 32768.0) / 256.0)
        if ($q -lt 0) { $q = 0 } elseif ($q -gt 255) { $q = 255 }
        $u8[$k] = [byte]$q
    }
    $audioType = if ($ch -eq 2) { 7 } else { 6 }
    $audio = New-Object System.Collections.ArrayList
    $nSamp = [int]($u8.Length / $ch)

    # THE OUTPUT FRAME COUNT MUST MATCH THE SOUND'S LENGTH, and nothing upstream can check it:
    # the $target that picks the frame count reads $audio.Count, but for -AudioFrom the audio
    # is not decoded until HERE, so $audio is still empty up there and the count silently falls
    # through to "whatever the MP4 has". A 361-frame 24 fps source emitted at 10 fps became a
    # 36-second movie carrying 15 seconds of sound, with no warning of any kind. Same shape as
    # the derived-above-constant trap in Build-AztMod: a value read before it is filled in.
    $audioSecs   = $nSamp / [double]$AudioRate
    $audioFrames = [int][Math]::Round($audioSecs * $useFps)
    if ([Math]::Abs($count - $audioFrames) -gt [Math]::Max(2, [int]($audioFrames * 0.05))) {
        throw ("{0} frames at {1} fps is {2:N1}s of picture, but the audio is {3:N1}s " +
               "({4} frames). Pass -Frames {4}." -f $count, $useFps, ($count/[double]$useFps),
               $audioSecs, $audioFrames)
    }

    # EVERY FRAME AFTER THE FIRST GETS THE SAME NUMBER OF SAMPLES -- and the FIRST ONE IS
    # DELIBERATELY OVERSIZED. Both halves of that matter and I had only the first half right.
    #
    # Steady state is constant: stock INTRO is t7/4,410 a frame, stock TOB t6/2,205. Slicing by
    # position, the obvious way, alternated 1837/1838 samples whenever rate/fps was not whole
    # (22050/12 = 1837.5), which walks the sound against the picture. The shipped movies avoid
    # it by running at 10 fps, where 22050/10 = 2205 exactly.
    #
    # BUT FRAME 0 IS A PRIMING CHUNK, which an earlier version of this note flatly denied:
    #
    #     stock INTRO (t7)   f0 = 10,000  then 4,410   -> 1.27 frames of lead
    #     stock TOB   (t6)   f0 = 16,384  then 2,205   -> 6.40 frames of lead
    #
    # It is extra REAL audio, not padding: INTRO's 10,000 + 681*4,410 is 68.3 s against 68.2 s
    # of picture, so the sound simply finishes a fraction early. Shipping without it gives the
    # player a buffer holding exactly one frame, and any frame that decodes slower than its
    # 100 ms starves it -- which is heard as a steady crackle, not a dropout. Our movies are
    # the ones that can't afford it: 1024x768 is 4.7x the pixels of stock INTRO's 600x280.
    #
    # The crackle is NOT in the file. Extracting the chunks back out of a finished movie and
    # measuring them found zero sample-to-sample discontinuities and zero at the chunk seams,
    # and the same audio as a WAV sounds clean. It is a playback-timing fault, so the fix
    # belongs in the buffer lead, not in the conversion.
    #
    # THIS IS ABOUT THE SOUND, NOT THE PICTURE. An earlier note claimed the varying chunk size
    # sheared the image too; it did not -- that was Mp4Reader believing MF_MT_DEFAULT_STRIDE on
    # a padded buffer, fixed there.
    $perFrame = $AudioRate / [double]$useFps
    if ([Math]::Abs($perFrame - [Math]::Round($perFrame)) -gt 1e-9) {
        throw ("audio rate {0} Hz does not divide evenly into {1} fps ({2:N1} samples per frame). " +
               "The chunk size must be constant across frames or the picture shears -- " +
               "use a rate/fps pair that divides, e.g. {0} Hz at 10 fps." -f $AudioRate, $useFps, $perFrame)
    }
    $perFrame  = [int][Math]::Round($perFrame)
    $stepBytes = $perFrame * $ch
    # Default the lead to whatever the shipped movie OF THE SAME CHUNK TYPE uses, rather than
    # picking a number: 10,000 is proven for t7 and 16,384 for t6, and a value the player's
    # buffer has never been asked to hold is not worth guessing at.
    $primeBytes = if ($AudioPrime -ge 0) { $AudioPrime }
                  elseif ($audioType -eq 7) { 10000 } else { 16384 }
    if ($primeBytes -lt $stepBytes) { $primeBytes = $stepBytes }   # never shorter than steady state
    $primeBytes = $primeBytes - ($primeBytes % $ch)                # whole sample-frames
    # Walk the source in BYTES: frame 0 consumes $primeBytes and every later frame $stepBytes,
    # so the stream stays continuous and simply ends early by the lead.
    $off = 0
    for ($k = 0; $k -lt $count; $k++) {
        $len = if ($k -eq 0) { $primeBytes } else { $stepBytes }
        # SILENCE IS 0x80, NOT 0x00. These chunks are UNSIGNED 8-bit, so a zero-filled array is
        # not quiet -- it is a full-scale negative DC step, and the audible result is a bang.
        # The tail is nearly always short, and more so now the first frame eats ahead, so this
        # fired on every movie built this way and showed up as a spurious 0 dBFS peak.
        $a = New-Object byte[] $len
        for ($z = 0; $z -lt $len; $z++) { $a[$z] = 128 }
        if ($off -lt $u8.Length) {
            [Array]::Copy($u8, $off, $a, 0, [Math]::Min($len, $u8.Length - $off))
        }
        $off += $len
        [void]$audio.Add($a)
    }
    $silent = [Math]::Max(0, $off - $u8.Length)
    Write-Host ("audio: {0:N0} samples, {1} ch, {2} Hz -> type {3}, {4:N2} s over {5} frames; {6} bytes/frame, frame 0 primed to {7} ({8:N2} frames of lead){9}" -f `
                $nSamp, $ch, $AudioRate, $audioType, ($nSamp / [double]$AudioRate), $count, $stepBytes,
                $primeBytes, (($primeBytes - $stepBytes) / [double]$stepBytes),
                $(if ($silent -gt 0) { ", {0:N2}s silent tail" -f ($silent / [double]($AudioRate * $ch)) } else { '' }))
}

if ($Mp4) { Open-Mp4Stream $Mp4 }
$srcW = if ($src) { $src.Width }  else { $W }
$srcH = if ($src) { $src.Height } else { $H }
$resizingOriginal = $FromMov -and ($W -ne $srcW -or $H -ne $srcH)
if ($resizingOriginal) {
    Write-Host ("  enlarging the ORIGINAL {0}x{1} -> {2}x{3}: no new detail, but it covers the screen" -f $srcW,$srcH,$W,$H) -ForegroundColor Cyan
}
for ($i = 0; $i -lt $count; $i++) {
    if ($FromMov -and -not $resizingOriginal) { $idx = $srcFrames[$i] }
    elseif ($resizingOriginal) {
        $bgra0 = [AztTool.AnimEncoder]::IndicesToBgra($srcFrames[$i], $src.Palette, $srcW, $srcH)
        $bgra = Resize-Bgra $bgra0 $srcW $srcH $W $H
        $idx = if ($Dither) { $enc.MapFrameDithered($bgra, $W, $H) } else { $enc.MapFrame($bgra, $W, $H) }
    }
    else {
        $bgra = if ($Mp4) { Resize-Bgra (Get-Mp4FrameAt $i $mp4Count $target) $mp4W $mp4H $W $H }
                else      { Get-Bgra $pngs[$i].FullName $W $H }
        $idx = if ($Dither) { $enc.MapFrameDithered($bgra, $W, $H) } else { $enc.MapFrame($bgra, $W, $H) }
    }
    $a = if ($i -lt $audio.Count) { $audio[$i] } else { $null }
    $alen = if ($a) { $a.Length } else { 0 }
    $enc.AddFrame($idx, $a, $alen, $audioType)
    if ($Verify) { $fed.Add([BitConverter]::ToString($md5.ComputeHash($idx))) }

    # EVERY buffer above is over 85 KB, so all of it lands on the Large Object Heap, which the
    # runtime never compacts and only reclaims on a gen-2 pass. A 2560x1920 source throws away
    # ~45 MB per frame (decoded frame + GDI+ copy + resize + output); left to itself that reached
    # 54 GB of commit on a 47.6 GB machine and the GC spent all its time walking the heap instead
    # of encoding -- OUTRO2 ran 7 hours without writing a byte. Collect on a fixed cadence, and
    # compact the LOH occasionally so the freed space is actually reusable rather than fragmented.
    if (($i % 4) -eq 3) {
        if (($i % 64) -eq 63) {
            [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode =
                [System.Runtime.GCLargeObjectHeapCompactionMode]::CompactOnce
        }
        [GC]::Collect()
    }

    # never be blind for hours again
    if ($Progress -and ($i % $Progress) -eq 0) {
        # GetTotalMemory($true) forces a blocking collection first, so this is LIVE bytes, not
        # committed-with-garbage. Private bytes beside it shows how much the heap is holding on
        # to that it is not actually using -- the gap is LOH fragmentation.
        $live = [GC]::GetTotalMemory($true) / 1MB
        $priv = (Get-Process -Id $PID).PrivateMemorySize64 / 1MB
        Write-Host ("  progress frame {0,6:N0}/{1:N0}  {2,5:N1}%  {3:N0}s  live {4:N0} MB  private {5:N0} MB" -f `
                    $i, $count, (100 * $i / [double]$count), ($sw.ElapsedMilliseconds/1000), $live, $priv)
    }
}
$enc.Close()
$sw.Stop()

$blocks = ($W/4) * ($H/4)
Write-Host ("wrote {0}  {1} frames {2}x{3} @ {4} fps  {5:N0} KB  {6:N0} ms" -f `
            (Split-Path $Out -Leaf), $count, $W, $H, $useFps, ((Get-Item $Out).Length/1KB), $sw.ElapsedMilliseconds)
Write-Host ("   literal blocks {0:N0}   skipped {1:N0} in {2:N0} runs   ({3:P1} of blocks skipped)" -f `
            $enc.LiteralBlocks, $enc.SkippedBlocks, $enc.SkipRuns,
            ($enc.SkippedBlocks / [double]([Math]::Max(1,$blocks*($count-1)))))

# ---- verify ---------------------------------------------------------------------
if ($Verify) {
    $chk = New-Object AztTool.Anim ($Out)
    # Compare MD5 per frame rather than pixel by pixel. The old loop ran one PowerShell
    # iteration per pixel -- 1.57 BILLION of them on OUTRO2 -- to produce a pixel count that
    # only ever mattered when something was already broken. A hash mismatch still pins the
    # first bad frame exactly, which is what the diagnosis actually starts from.
    $i = 0; $bad = 0; $worstFrame = -1
    while ($chk.NextFrame()) {
        if ($i -ge $fed.Count) { break }
        $h = [BitConverter]::ToString($md5.ComputeHash($chk.GetPixels()))
        if ($h -ne $fed[$i]) { $bad++; if ($worstFrame -lt 0) { $worstFrame = $i } }
        $i++
    }
    $ok = ($bad -eq 0 -and $i -eq $count)
    Write-Host ("   VERIFY: {0} of {1} frames decoded; {2} differ{3}" -f `
                $i, $count, $bad, $(if ($bad) { "  first at frame {0}" -f $worstFrame } else { '' })) `
               -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
    if ($ok) { Write-Host "   round-trip is EXACT" -ForegroundColor Green }
}
