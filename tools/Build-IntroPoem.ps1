# Build-IntroPoem.ps1 -- the story intro (MOV\INTRO.MOV, the poem) rebuilt as VECTOR text (RaptorMod, 2026-10-16; Josh:
# "extract the design and text ... a vector based version of this text would be ideal so it is crisp on all screens").
#
#   powershell -ExecutionPolicy Bypass -File tools\Build-IntroPoem.ps1 -Measure            # scene.json -> scene.measured.json
#   powershell -ExecutionPolicy Bypass -File tools\Build-IntroPoem.ps1 -Preview 150        # my frame beside the video's
#   powershell -ExecutionPolicy Bypass -File tools\Build-IntroPoem.ps1 -Render -Encode     # frames -> the game's movie
#
# art\intro-poem\scene.json is the SOURCE: every phrase's text (**bold**, _italic_), its card's typeface, and a rough rect
# in the measuring video's space. -Measure reads the video (TensorPix's upscale of the original, which has the timing and
# the layout but blurry letters) and, per phrase: the ink's left edge and BASELINE on its card's fullest frame, the size
# that makes the typeset phrase exactly as wide as the measured ink (or as tall, for a lone quote mark), and the phrase's
# brightness on every frame -- its fade curve. -Render draws each frame as anti-aliased outlines (tools\IntroPoem.cs) at
# -Width x -Height, the video's strip centred (black above and below); -Encode makes the .MOV with the ORIGINAL movie's
# narration and frame count (-Ref). A native build can draw the same measured scene live, at any resolution.
param(
    [switch]$Measure, [int]$Preview = -1, [switch]$Render, [switch]$Encode,
    [string]$Scene = '',
    [string]$Ref = 'C:\Games\RaptorMod\sources\video\movies-1024-backup\MOV\INTRO.MOV',
    [string]$Out = 'C:\Games\RaptorMod\sources\video\intro-poem\INTRO.MOV',
    [int]$Width = 1600, [int]$Height = 1200,
    [double]$Weight = 0.0,          # extra stroke weight, as a share of the em (0 = the typeface's own)
    [int]$White = 240,
    [int]$Ink = 70,                 # green above this = ink, for the boxes and baselines
    [int]$Floor = 24                # green above this counts toward a phrase's brightness
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (-not $Scene) { $Scene = Join-Path $repo 'art\intro-poem\scene.json' }
$measured = [IO.Path]::ChangeExtension($Scene, '.measured.json')
Add-Type -AssemblyName System.Drawing
if (-not ('AztTool.IntroPoem' -as [type])) { Add-Type -Path (Join-Path $repo 'tools\IntroPoem.cs') -ReferencedAssemblies System.Drawing }
. (Join-Path $repo 'tools\LoadAnim.ps1')      # (the animation toolchain -- Mp4Reader, Anim, the encoder -- loaded ONCE, as every movie script does)
$sc = Get-Content $Scene -Raw | ConvertFrom-Json
$SW = [int]$sc.sourceW; $SH = [int]$sc.sourceH

# "the hordes of **madness** hurtle" -> runs
function Get-Runs([string]$text) {
    $runs = New-Object System.Collections.Generic.List[object]
    foreach ($m in [regex]::Matches($text, '\*\*(.+?)\*\*|_(.+?)_|([^*_]+)')) {
        $t = $(if ($m.Groups[1].Success) { $m.Groups[1].Value } elseif ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[3].Value }).Trim()
        if (-not $t) { continue }
        $r = [AztTool.IntroPoem+Run]::new(); $r.Text = $t; $r.Bold = $m.Groups[1].Success; $r.Italic = $m.Groups[2].Success; $runs.Add($r)
    }
    , $runs.ToArray()
}

# ---- MEASURE ----------------------------------------------------------------------------------------------------------------
if ($Measure) {
    $phs = New-Object System.Collections.Generic.List[object]
    for ($c = 0; $c -lt $sc.cards.Count; $c++) { foreach ($p in $sc.cards[$c].phrases) { $phs.Add([pscustomobject]@{ Card = $c; Win = @([int]$sc.cards[$c].window[0], [int]$sc.cards[$c].window[1]); Peak = [int]$sc.cards[$c].peak; Font = $sc.cards[$c].font; P = $p; Box = $null; Light = (New-Object System.Collections.Generic.List[double]) }) } }
    $rd = [AztTool.Mp4Reader]::new([string]$sc.source); $f = 0
    while ($true) {
        $fr = $rd.ReadFrame(); if ($null -eq $fr) { break }
        foreach ($ph in $phs) {
            $r = $ph.P.rect
            $ph.Light.Add([AztTool.IntroPoem]::RectLight($fr, $SW, [int]$r[0], [int]$r[1], [int]$r[2], [int]$r[3], $Floor))
            if ($f -eq $ph.Peak) { $ph.Box = [AztTool.IntroPoem]::MeasureInk($fr, $SW, [int]$r[0], [int]$r[1], [int]$r[2], [int]$r[3], $Ink, 0.45) }
        }
        $f++
    }
    $rd.Dispose(); $frames = $f
    $res = New-Object System.Collections.Generic.List[object]
    foreach ($ph in $phs) {
        if (-not $ph.Box) { throw "no ink for '$($ph.P.text)' in its rect on frame $($ph.Peak)" }
        # (only its own card's frames: a later card's text in the same spot is not this phrase)
        $l = $ph.Light.ToArray(); for ($i = 0; $i -lt $l.Length; $i++) { if ($i -lt $ph.Win[0] -or $i -gt $ph.Win[1]) { $l[$i] = 0 } }; $mx = ($l | Measure-Object -Maximum).Maximum; $wl = @($l[$ph.Win[0]..$ph.Win[1]]); $base = ($wl | Sort-Object | Select-Object -First ([Math]::Max(1, [int]($wl.Count * 0.1))) | Measure-Object -Average).Average
        # the curve: brightness over its quietest tenth, as a share of its peak; a 3-frame average; specks below 4% are dark
        $cv = New-Object double[] $l.Length
        for ($i = 0; $i -lt $l.Length; $i++) { $v = 0.0; $n = 0; for ($k = [Math]::Max(0, $i - 1); $k -le [Math]::Min($l.Length - 1, $i + 1); $k++) { $v += $l[$k]; $n++ }; $v = $(if ($i -lt $ph.Win[0] -or $i -gt $ph.Win[1]) { 0.0 } else { ($v / $n - $base) / [Math]::Max(1, $mx - $base) }); $cv[$i] = $(if ($v -lt 0.04) { 0.0 } else { [Math]::Min(1.0, $v) }) }
        $phr = [AztTool.IntroPoem+Phrase]::new(); $phr.Font = $ph.Font; $phr.Runs = Get-Runs $ph.P.text
        $b = $ph.Box; $inkW = $b[2] - $b[0] + 1; $inkH = $b[3] - $b[1] + 1
        $size = $(if ($ph.P.fit -eq 'height') { $phr.Size = 100; $pp = [AztTool.IntroPoem]::PhrasePath($phr, 1); $hh = $pp.GetBounds().Height; $pp.Dispose(); 100.0 * $inkH / $hh } else { [AztTool.IntroPoem]::FitPhrase($phr, $inkW) })
        $first = [Array]::FindIndex($cv, [Predicate[double]] { param($x) $x -gt 0 }); $last = [Array]::FindLastIndex($cv, [Predicate[double]] { param($x) $x -gt 0 })
        $res.Add([ordered]@{ card = $ph.Card; text = $ph.P.text; font = $ph.Font; size = [Math]::Round($size, 2); x = $b[0]; baseline = $b[4]; top = $(if ($ph.P.fit -eq 'height') { $b[1] } else { -1 }); ink = @($b[0], $b[1], $b[2], $b[3]); fit = $(if ($ph.P.fit) { $ph.P.fit } else { 'width' }); shown = @($first, $last); curve = @($cv | ForEach-Object { [Math]::Round($_, 3) }) })
        Write-Host ("  card {0}  {1,-62} {2,-8} size {3,6:N1}  ink {4}-{5} base {6}  frames {7}-{8}" -f $ph.Card, $ph.P.text, $ph.Font, $size, $b[0], $b[2], $b[4], $first, $last)
    }
    $json = [ordered]@{ about = 'MEASURED from scene.json by tools\Build-IntroPoem.ps1 -Measure -- do not edit; edit scene.json and measure again'; sourceW = $SW; sourceH = $SH; frames = $frames; phrases = $res }
    [IO.File]::WriteAllText($measured, ($json | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
    Write-Host "measured $($res.Count) phrases over $frames frames -> $measured" -ForegroundColor Green
}

# ---- the measured scene, as renderer phrases ------------------------------------------------------------------------------
function Get-Phrases {
    $m = Get-Content $measured -Raw | ConvertFrom-Json
    $list = foreach ($p in $m.phrases) {
        $ph = [AztTool.IntroPoem+Phrase]::new(); $ph.Font = $p.font; $ph.Runs = Get-Runs $p.text; $ph.Size = [single]$p.size; $ph.X = [single]$p.x; $ph.Baseline = [single]$p.baseline; if ($null -ne $p.top) { $ph.Top = [single]$p.top }; $ph.Weight = [single]$Weight
        $ph.Curve = [single[]]@($p.curve); $ph }
    @{ Phrases = [AztTool.IntroPoem+Phrase[]]@($list); Frames = [int]$m.frames }
}
$s = [single]($Width / [double]$SW); $ox = [single]0; $oy = [single](($Height - $SH * $s) / 2)

if ($Preview -ge 0) {
    $sp = Get-Phrases
    $mine = [AztTool.IntroPoem]::RenderPhrases($sp.Phrases, $Preview, $SW, $SH, [single]1, [single]0, [single]0, $White)
    $rd = [AztTool.Mp4Reader]::new([string]$sc.source); $f = 0; $theirs = $null
    while ($true) { $fr = $rd.ReadFrame(); if ($null -eq $fr) { break }; if ($f -eq $Preview) { $theirs = $fr; break }; $f++ }; $rd.Dispose()
    $dir = Join-Path ([IO.Path]::GetTempPath()) 'intro-poem-preview'; New-Item -ItemType Directory -Force $dir | Out-Null
    [AztTool.IntroPoem]::SavePng($theirs, $SW, $SH, (Join-Path $dir "video-$Preview.png")); [AztTool.IntroPoem]::SavePng($mine, $SW, $SH, (Join-Path $dir "vector-$Preview.png"))
    # and the two laid over each other: the video in red, the vector in green (yellow where they agree)
    $ov = New-Object byte[] $mine.Length; for ($i = 0; $i -lt $mine.Length; $i += 4) { $ov[$i + 2] = $theirs[$i + 1]; $ov[$i + 1] = $mine[$i + 1]; $ov[$i + 3] = 255 }
    [AztTool.IntroPoem]::SavePng($ov, $SW, $SH, (Join-Path $dir "overlay-$Preview.png"))
    Write-Host "preview: $dir (video-, vector-, overlay- $Preview.png)" -ForegroundColor Green
}

# ---- RENDER + ENCODE ----------------------------------------------------------------------------------------------------------
$frameDir = Join-Path (Split-Path -Parent $Out) 'frames'
if ($Render) {
    $sp = Get-Phrases
    $ra = [AztTool.Anim]::new($Ref); $n = 0; while ($ra.NextFrame()) { $n++ }
    New-Item -ItemType Directory -Force $frameDir | Out-Null; Get-ChildItem $frameDir -Filter '*.png' -ErrorAction SilentlyContinue | Remove-Item
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # the measuring video's frames onto the original's (685 -> 682, by position)
    for ($k = 0; $k -lt $n; $k++) {
        $src = [int][Math]::Round($k * ($sp.Frames - 1) / [double]([Math]::Max(1, $n - 1)))
        $px = [AztTool.IntroPoem]::RenderPhrases($sp.Phrases, $src, $Width, $Height, $s, $ox, $oy, $White)
        [AztTool.IntroPoem]::SavePng($px, $Width, $Height, (Join-Path $frameDir ('f{0:D4}.png' -f $k)))
    }
    Write-Host ("rendered {0} frames {1}x{2} in {3:N0} s -> {4}" -f $n, $Width, $Height, $sw.Elapsed.TotalSeconds, $frameDir) -ForegroundColor Green
}
if ($Encode) {
    New-Item -ItemType Directory -Force (Split-Path -Parent $Out) | Out-Null
    & (Join-Path $repo 'tools\Convert-ToAnim.ps1') -InDir $frameDir -Ref $Ref -Out $Out -Width $Width -Height $Height -Verify
}
