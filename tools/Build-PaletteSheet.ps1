# Build-PaletteSheet.ps1 -- one reference page: every original texture beside its measured
# palette, grouped by material family.
#
#   .\tools\Build-PaletteSheet.ps1 -Res CORICORI -Out C:\Games\RaptorMod\textures\room01\PALETTE.png
#
# Attach this to the image model along with the text brief. The hex list tells it what the
# colours ARE; this shows it what they look like together, and -- more usefully -- what the
# ORIGINAL surface looked like, which is the thing being matched. The visible window is drawn
# as a box on each thumbnail, because that is the only part of the image the game ever draws
# and composition outside it is wasted effort.

[CmdletBinding()]
param(
    [string]$Res = 'CORICORI',
    [string]$TexDir = 'C:\Games\RaptorMod\game\GAME\AZTEX',
    [Parameter(Mandatory)][string]$Out,
    [int]$Thumb = 150
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
Add-Type -AssemblyName System.Drawing
if (-not ("AztTool.Azf" -as [type])) { Add-Type -Path (Join-Path $toolDir 'AzfTool.cs') -ReferencedAssemblies System.Drawing }

$stem = $Res -replace '\.(RES|XAF)$',''
# the ENRICHED table from Build-TexturePrompt -- it carries Family, CanvasW and FormTexels,
# which the raw measurement csv does not.
$csv = Join-Path $env:TEMP "$stem-brief.csv"
if (-not (Test-Path $csv)) { throw "run .\tools\Build-TexturePrompt.ps1 first -- no $csv" }
$rows = @(Import-Csv $csv)

$resPath = Join-Path $TexDir "$stem.RES"
$origRes = "$resPath.orig"
$texs = [AztTool.Azf]::Read($(if (Test-Path $origRes) { $origRes } else { $resPath }))

# UV windows, to draw the visible box
$xafPath = Join-Path $TexDir "$stem.XAF"
$xaf = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($xafPath))
$matTex = @{}
foreach ($m in [regex]::Matches($xaf, 'material\s+"([^"]+)"\s*\{([^}]*)\}', 'IgnoreCase')) {
    $t = [regex]::Match($m.Groups[2].Value, 'texture\s+"([^"]+)"')
    if ($t.Success) { $matTex[$m.Groups[1].Value] = ((($t.Groups[1].Value -split '[\\/]')[-1]) -replace '\.(azf|gif)$','') }
}
$uv = @{}
$objs = @([regex]::Matches($xaf, 'object\s+"([^"]+)"\s*\{', 'IgnoreCase'))
for ($k = 0; $k -lt $objs.Count; $k++) {
    $a = $objs[$k].Index
    $b = if ($k+1 -lt $objs.Count) { $objs[$k+1].Index } else { $xaf.Length }
    $body = $xaf.Substring($a, $b - $a)
    $mm = [regex]::Match($body, 'material\s+"([^"]+)"')
    if (-not $mm.Success -or -not $matTex.ContainsKey($mm.Groups[1].Value)) { continue }
    $tex = $matTex[$mm.Groups[1].Value]
    $tc = [regex]::Match($body, 'texture_coordinates\s*\{([^}]*)\}')
    if (-not $tc.Success) { continue }
    $nums = @([regex]::Matches($tc.Groups[1].Value, '-?\d+(?:\.\d+)?(?:e-?\d+)?') | ForEach-Object { [double]$_.Value })
    $us = @(); $vs = @()
    for ($i = 0; $i -lt $nums.Count - 1; $i += 2) { $us += $nums[$i]; $vs += $nums[$i+1] }
    if (-not $us.Count) { continue }
    $u0 = ($us | Measure-Object -Minimum).Minimum; $u1 = ($us | Measure-Object -Maximum).Maximum
    $v0 = ($vs | Measure-Object -Minimum).Minimum; $v1 = ($vs | Measure-Object -Maximum).Maximum
    if (-not $uv.ContainsKey($tex)) { $uv[$tex] = @($u0,$u1,$v0,$v1) }
    else { $r = $uv[$tex]
        $uv[$tex] = @([Math]::Min($r[0],$u0), [Math]::Max($r[1],$u1), [Math]::Min($r[2],$v0), [Math]::Max($r[3],$v1)) }
}

function TexBitmap { param($t)
    $bm = New-Object System.Drawing.Bitmap($t.Width, $t.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $d = $bm.LockBits((New-Object System.Drawing.Rectangle(0,0,$t.Width,$t.Height)),
        [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $px = New-Object 'int[]' ($t.Width * $t.Height)
    for ($y = 0; $y -lt $t.Height; $y++) {
        $row = $y * $t.BytesPerLine
        for ($x = 0; $x -lt $t.Width; $x++) {
            $c = $t.Pixels[$row + $x]
            # [int] IS LOAD-BEARING: PowerShell's -shl keeps the left operand's type, so
            # ([byte]41 -shl 16) is 0. Without these casts red and green vanish and every
            # thumbnail renders blue.
            $px[$y*$t.Width + $x] = (-16777216 -bor ([int]$t.Palette[$c*4] -shl 16) `
                                              -bor ([int]$t.Palette[$c*4+1] -shl 8) `
                                              -bor [int]$t.Palette[$c*4+2])
        }
    }
    [System.Runtime.InteropServices.Marshal]::Copy($px, 0, $d.Scan0, $px.Length)
    $bm.UnlockBits($d)
    $bm
}

$famOrder  = @('COOLGREEN','WARM','NEUTRALWARM','NEUTRAL')
$famLabel  = @{ 'COOLGREEN'='FAMILY A - COOL GREY-GREEN STONE (the floor)'
                'WARM'='FAMILY B - WARM BROWN STONE (walls, tunnel)'
                'NEUTRALWARM'='FAMILY C - NEUTRAL WARM-GREY (doors and surround)'
                'NEUTRAL'='FAMILY D - ODD ONES OUT' }

$SW = 44                       # swatch size
$PAD = 12
$HDR = 34
$ROWH = [Math]::Max($Thumb, $SW) + $PAD
$LBLW = 300
$W = $PAD + $Thumb + $PAD + $LBLW + ($SW * 6) + $PAD

$nRows = $rows.Count
$nFams = 0
foreach ($f in $famOrder) { if (@($rows | Where-Object { $_.Family -eq $f }).Count) { $nFams++ } }
$H = $PAD + 58 + ($nFams * ($HDR + $PAD)) + ($nRows * $ROWH) + $PAD

$bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(16,16,18))
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

$fTitle = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$fFam   = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$fName  = New-Object System.Drawing.Font('Consolas', 11, [System.Drawing.FontStyle]::Bold)
$fInfo  = New-Object System.Drawing.Font('Consolas', 9)
$bTitle = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(240,234,214))
$bInfo  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(160,158,150))
$bFam   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(212,180,120))
$bFamBg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(30,30,34))
$pWin   = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255,230,90,90), 2)

$y = $PAD
$g.DrawString(("{0} - room 1 original textures and their measured palettes" -f $stem), $fTitle, $bTitle, [single]$PAD, [single]$y)
$y += 26
$g.DrawString('red box = the only part of the image the game actually draws.  swatches = dominant colours of the LIT pixels.',
              $fInfo, $bInfo, [single]$PAD, [single]$y)
$y += 32

foreach ($fam in $famOrder) {
    $set = @($rows | Where-Object { $_.Family -eq $fam } | Sort-Object { [int]$_.Index })
    if (-not $set.Count) { continue }
    $g.FillRectangle($bFamBg, $PAD, $y, ($W - 2*$PAD), $HDR)
    $g.DrawString($famLabel[$fam], $fFam, $bFam, [single]($PAD + 10), [single]($y + 8))
    $y += $HDR + $PAD

    foreach ($r in $set) {
        $t = $texs[[int]$r.Index]
        $tb = TexBitmap $t
        # letterbox the thumbnail so non-square records keep their aspect
        $sc = [Math]::Min($Thumb / $t.Width, $Thumb / $t.Height)
        $dw = [int]($t.Width * $sc); $dh = [int]($t.Height * $sc)
        $tx = $PAD; $ty = $y + [int](($Thumb - $dh) / 2)
        $g.DrawImage($tb, (New-Object System.Drawing.Rectangle($tx, $ty, $dw, $dh)))
        $tb.Dispose()
        if ($uv.ContainsKey($r.Name)) {
            $u = $uv[$r.Name]
            $g.DrawRectangle($pWin, ($tx + [int]($u[0]*$dw)), ($ty + [int]($u[2]*$dh)),
                             [Math]::Max(2,[int](($u[1]-$u[0])*$dw)), [Math]::Max(2,[int](($u[3]-$u[2])*$dh)))
        }

        $lx = $PAD + $Thumb + $PAD
        $g.DrawString(("{0:d2}  {1}" -f [int]$r.Index, $r.Name), $fName, $bTitle, [single]$lx, [single]($y + 4))
        $g.DrawString(("{0}x{1} record" -f $r.RecW, $r.RecH), $fInfo, $bInfo, [single]$lx, [single]($y + 26))
        $g.DrawString(("visible {0} x {1} texels" -f $r.ArtW, $r.ArtH), $fInfo, $bInfo, [single]$lx, [single]($y + 42))
        $g.DrawString(("~6 forms across -> {0} texels each" -f $r.FormTexels), $fInfo, $bInfo, [single]$lx, [single]($y + 58))
        $g.DrawString(("saturation under {0}%" -f $r.SatMaxPct), $fInfo, $bInfo, [single]$lx, [single]($y + 74))
        $g.DrawString(("canvas {0}x{1}" -f $r.CanvasW, $r.CanvasH), $fInfo, $bInfo, [single]$lx, [single]($y + 90))

        $sx = $PAD + $Thumb + $PAD + $LBLW
        $k = 0
        # NOT $h -- PowerShell names are case-insensitive, so $h IS the $H canvas height.
        foreach ($hex in ($r.Hex -split ' ')) {
            if (-not $hex) { continue }
            $col = [System.Drawing.ColorTranslator]::FromHtml($hex)
            $br = New-Object System.Drawing.SolidBrush($col)
            $g.FillRectangle($br, ($sx + $k*$SW), $y, ($SW - 2), $SW); $br.Dispose()
            $g.DrawString($hex.Substring(1), $fInfo, $bInfo, [single]($sx + $k*$SW - 2), [single]($y + $SW + 3))
            $k++
        }
        $y += $ROWH
    }
}

$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
foreach ($o in @($fTitle,$fFam,$fName,$fInfo,$bTitle,$bInfo,$bFam,$bFamBg,$pWin)) { $o.Dispose() }
Write-Host ("wrote {0}  ({1}x{2}, {3:N0} bytes)" -f $Out, $W, $H, (Get-Item $Out).Length) -ForegroundColor Green
