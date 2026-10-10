# Tune-Lighting.ps1 -- find the lighting parameters that MEASURABLY match the engine.
#
#   .\tools\Tune-Lighting.ps1
#   .\tools\Tune-Lighting.ps1 -Name opening2 -Top 6
#
# Offline. Sweeps fog range, curve and ambient against a captured reference and scores
# each combination against the ENGINE's own frame from the same camera.
#
# WHY SCORE IT RATHER THAN LOOK AT IT. "Too dark" and "too flat" are not actionable, and
# comparing two dark images by eye is unreliable in exactly the way that wastes a day.
# The engine's frame is a measurement available for free, so the tuning can be an
# optimisation rather than a series of guesses.
#
# THE METRIC IS A LUMINANCE HISTOGRAM, NOT PER-PIXEL DIFFERENCE. A pixel-by-pixel
# comparison would be dominated by things the host legitimately does not draw -- the two
# creature rigs, the HUD panel -- and by sub-pixel differences in geometry. What is being
# matched is the TONAL DISTRIBUTION: how much of the frame is black, how much is
# mid-tone, how much is highlight. That is what "the engine has more contrast" means.
[CmdletBinding()]
param(
    [string]$Name = 'opening2',
    [string]$RefDir = 'C:\Games\azrael-render\ref',
    [string]$CacheDir = 'C:\Games\azrael-render',
    [string]$TexDir = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX',
    [string]$Palette = 'C:\Games\azrael-inject\azrael-palette.pal',
    # 50, MEASURED, not 60. 60 was an assumption carried through every tool. Matching the
    # host's drawn-pixel mask against the engine's own frame (tools\Tune-Geometry.ps1)
    # gives a sharp unimodal peak at 50.0 -- recall 91.5%, against 81.6% at 49, 83.0% at
    # 50.5 and 55-58% out at 60 -- and the horizontal profile shift lands on exactly 0
    # there. At 60 the host was aimed wrong, which is what made it paint a lit ceiling the
    # engine does not show, and made every earlier lighting comparison fit noise.
    [double]$Fov = 50,
    [int]$ShadeLevels = 32,
    [int]$Top = 8,
    [double[]]$FogScales = @(0.4, 0.5, 0.7, 0.9, 1.2, 1.6),
    [double[]]$FogCurves = @(1.0, 1.5, 2.0, 3.0),
    # AMBIENT MUST REACH 0. The engine's depth cue falls to true black; starting this
    # range at 0.25 meant the setting that actually matches was never in the sweep.
    [double[]]$Ambients  = @(0.0, 0.05, 0.10, 0.20, 0.35, 0.45)
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'Quantize.cs')) -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop
Add-Type -AssemblyName System.Drawing

. (Join-Path $toolDir 'LoadRoom.ps1')
$room = Import-AztRoom -RefName $Name -RefDir $RefDir -CacheDir $CacheDir -TexDir $TexDir -Palette $Palette
$W = $room.W; $H = $room.H

# ---- the engine's tonal distribution ---------------------------------------
# THE WHOLE FRAME. The capture is the 3D viewport alone -- no HUD panel is in it -- and
# the top strip used to be cropped on the grounds that it is "ceiling the host draws but
# the engine leaves black". That is not noise to be excluded, it is the single clearest
# symptom: the host paints a lit vaulted ceiling where the engine shows nothing. Cropping
# it, like skipping the background below, hid the error the sweep exists to find.
$pal = $room.Pal
$eng = [System.Drawing.Bitmap]::FromFile((Join-Path $RefDir ("{0}-engine.png" -f $Name)))
$y0 = 0; $y1 = $H
# THE BACKGROUND IS IN THE HISTOGRAM, and that is the whole point.
#
# This used to skip index 0 on the grounds that including it made the score "mostly a
# measure of COVERAGE". That reasoning is backwards: coverage IS the difference. Measured
# against the engine's own frame from the same camera, the engine lights 19.5% of the
# frame and the host 37.3% -- nearly twice as much -- while the engine's lit pixels are
# BRIGHTER (mean 45.0 vs 34.1). The engine's depth cue falls all the way to black; ours
# bottomed out at Ambient, so every distant surface the engine drops to nothing we still
# drew as dim grey. That is the murk, and excluding the background made the metric blind
# to it -- which is why the old sweep declared "no lighting" the winner by 0.0001.
#
# Counting index 0 as bin 0 scores "how much of this frame is black" together with the
# tone of what remains, which is the thing being matched.
function LumaHist([byte[]]$idx, [int]$stride) {
    $h = New-Object double[] 16
    $n = 0
    for ($y = $y0; $y -lt $y1; $y++) {
        for ($x = 0; $x -lt $W; $x += 2) {
            $i = $idx[$y*$stride + $x]
            if ($i -eq 0) { $h[0]++; $n++; continue }
            $l = 0.299*$pal[$i*3] + 0.587*$pal[$i*3+1] + 0.114*$pal[$i*3+2]
            $b = [int]($l / 16); if ($b -gt 15) { $b = 15 }
            $h[$b]++; $n++
        }
    }
    if ($n -eq 0) { return $h }
    for ($i = 0; $i -lt 16; $i++) { $h[$i] = $h[$i] / $n }
    return $h
}
$rcE = New-Object System.Drawing.Rectangle -ArgumentList ([int]0),([int]0),([int]$W),([int]$H)
$bdE = $eng.LockBits($rcE, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
$engIdx = New-Object byte[] ($bdE.Stride * $H)
[System.Runtime.InteropServices.Marshal]::Copy($bdE.Scan0, $engIdx, 0, $engIdx.Length)
$engStride = $bdE.Stride
$eng.UnlockBits($bdE); $eng.Dispose()
$engH = LumaHist $engIdx $engStride
Write-Host ("engine tone (whole frame, black included): dark {0:P1}, mid {1:P1}, bright {2:P1}, mean luma {3:N1}" -f `
    ($engH[0]+$engH[1]+$engH[2]+$engH[3]), ($engH[4]+$engH[5]+$engH[6]+$engH[7]), (($engH[8..15] | Measure-Object -Sum).Sum), `
    ((0..15 | ForEach-Object { $engH[$_] * ($_*16+8) } | Measure-Object -Sum).Sum))

# ---- sweep ------------------------------------------------------------------
$r = New-Object AztTool.Raster($W, $H)
$r.SetVerticalFov($Fov); $r.NearZ = [single]0.5
$r.SetShadeTable([AztTool.Raster]::BuildShadeTable($pal, $ShadeLevels), $ShadeLevels)
$r.NormalLight = [single]0.25
$m = New-Object single[] 16
for ($i = 0; $i -lt 16; $i++) { $m[$i] = [single]$room.Cam[$i] }

$results = @()
# THE "NO LIGHTING AT ALL" BASELINE, always evaluated. The sweep can only report the
# best setting among the ones it tries, and if every one of those is worse than simply
# not lighting, the sweep would still confidently name a winner. The question "should
# this be lit?" has to be on the table as an option, not assumed.
$r.Shade = $null
$r.SetCameraWorld($m); $r.Clear([byte]0)
$r.DrawTextured($room.V, $room.UV, $room.T, $room.TexIdx, $room.Texes, $true, $true)
$noLightH = LumaHist $r.Color $W
$cumE = 0.0; $cumH = 0.0; $noLightScore = 0.0
for ($b = 0; $b -lt 16; $b++) { $cumE += $engH[$b]; $cumH += $noLightH[$b]; $noLightScore += [Math]::Abs($cumE - $cumH) }
Write-Host ("NO LIGHTING baseline: score {0:N4}, dark {1:P1}, bright {2:P2}, mean {3:N1}" -f `
    $noLightScore, ($noLightH[0]+$noLightH[1]+$noLightH[2]+$noLightH[3]), `
    (($noLightH[8..15] | Measure-Object -Sum).Sum), ((0..15 | ForEach-Object { $noLightH[$_]*($_*16+8) } | Measure-Object -Sum).Sum))
$r.SetShadeTable([AztTool.Raster]::BuildShadeTable($pal, $ShadeLevels), $ShadeLevels)

foreach ($fs in $FogScales) {
  foreach ($fc in $FogCurves) {
    foreach ($am in $Ambients) {
        $r.FogFar  = [single]($room.Span * $fs)
        $r.FogNear = [single]($room.Span * $fs * 0.04)
        $r.FogCurve = [single]$fc
        $r.Ambient = [single]$am
        $r.SetCameraWorld($m); $r.Clear([byte]0)
        $r.DrawTextured($room.V, $room.UV, $room.T, $room.TexIdx, $room.Texes, $true, $true)
        $hostH = LumaHist $r.Color $W
        # Earth mover's distance over the histogram: it penalises moving weight a long
        # way more than a little, which is what "too flat" versus "too dark" actually is.
        # Bin-by-bin difference would score a near-miss and a wild miss the same.
        $cumE = 0.0; $cumH = 0.0; $emd = 0.0
        for ($b = 0; $b -lt 16; $b++) { $cumE += $engH[$b]; $cumH += $hostH[$b]; $emd += [Math]::Abs($cumE - $cumH) }
        $results += [pscustomobject]@{
            FogScale = $fs; FogCurve = $fc; Ambient = $am; Score = $emd
            Dark = ($hostH[0]+$hostH[1]+$hostH[2]+$hostH[3]); Bright = (($hostH[8..15] | Measure-Object -Sum).Sum)
            Mean = ((0..15 | ForEach-Object { $hostH[$_] * ($_*16+8) } | Measure-Object -Sum).Sum)
        }
    }
  }
}
$results = @($results | Sort-Object Score)
Write-Host ''
Write-Host ("{0,9} {1,9} {2,8} {3,9} {4,8} {5,8} {6,7}" -f 'fogScale','fogCurve','ambient','score','dark','bright','mean')
$results | Select-Object -First $Top | ForEach-Object {
    Write-Host ("{0,9:N2} {1,9:N2} {2,8:N2} {3,9:N4} {4,8:P1} {5,8:P2} {6,7:N1}" -f $_.FogScale, $_.FogCurve, $_.Ambient, $_.Score, $_.Dark, $_.Bright, $_.Mean)
}
Write-Host ''
$best = $results[0]
if ($noLightScore -le $best.Score) {
    Write-Host ("BEST IS NO LIGHTING AT ALL (score {0:N4} vs {1:N4} for the best lit setting)." -f $noLightScore, $best.Score) -ForegroundColor Green
    Write-Host ''
    Write-Host 'The textures already carry this game''s lighting; adding more only moves it away from the engine.'
} else {
    Write-Host ("BEST: -FogScale {0} -FogCurve {1} -Ambient {2}   (score {3:N4}, beats no-lighting {4:N4})" -f `
        $best.FogScale, $best.FogCurve, $best.Ambient, $best.Score, $noLightScore) -ForegroundColor Green
}
