# Upscale-Res.ps1 -- double a room's textures IN THE GAME, with Scale2x.
#
#   .\tools\Upscale-Res.ps1 -Res CORICORI            # do it
#   .\tools\Upscale-Res.ps1 -Res CORICORI -WhatIf    # just report what would change
#   .\tools\Upscale-Res.ps1 -Res CORICORI -Revert    # put the original .RES back
#
# Exports every record, runs Scale2x/EPX on the ones that can be doubled, and imports
# them back through src\Texture-Tool.ps1 (which rebuilds each texture's private palette
# from the new image rather than crushing it into the old one).
#
# WHAT IS SKIPPED, AND WHY IT MATTERS THAT THEY ARE SKIPPED RATHER THAN SHRUNK:
#   * anything with a 512 axis already -- the engine's ceiling is 512 per axis, so
#     these cannot be doubled at all
#   * records whose Huffman stream will not decode -- passed through byte-for-byte
# A skipped record simply gets no PNG, and Texture-Tool leaves that record alone.
#
# MEMORY IS THE REAL RISK, NOT DISK. Doubling each axis QUADRUPLES the decoded size,
# and the texture cache takes (largest free block - 4.5 MB), so a room that fitted
# before may not fit now -- see the azrael-texture-cache-reserve notes. This script
# prints the decoded-byte growth so that is a number you decide on, not a surprise.
# If the game runs out, -Revert restores the original and nothing else is affected.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Res,
    [string]$TexDir = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX',
    [int]$MaxAxis = 512,          # the engine's ceiling; both axes must end up <= this
    [int[]]$Keyed = @(),          # record indices whose .XAF name contains '#'
    [switch]$Revert,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
$root    = Split-Path -Parent $toolDir

Add-Type -AssemblyName System.Drawing
if (-not ("AztTool.Upscale" -as [type])) { Add-Type -Path (Join-Path $toolDir 'Upscale.cs') }

$stem    = $Res -replace '\.(RES|XAF)$',''
$resPath = Join-Path $TexDir ("$stem.RES")
$origPath = "$resPath.orig"
if (-not (Test-Path $resPath)) { throw "no such .RES: $resPath" }

if ($Revert) {
    if (-not (Test-Path $origPath)) { throw "no backup to revert to: $origPath" }
    Copy-Item -LiteralPath $origPath -Destination $resPath -Force
    Write-Host ("reverted {0} from {1} ({2:N0} bytes)" -f $stem, (Split-Path $origPath -Leaf), (Get-Item $resPath).Length) -ForegroundColor Green
    return
}

# ---- names, for the report and for spotting keyed textures ------------------
# Some .XAF files reference "name.azf", others "name.gif". Both forms appear in this
# game's data, and matching only one silently yields no names at all.
$xafPath = Join-Path $TexDir ("$stem.XAF")
$names = New-Object System.Collections.ArrayList
if (Test-Path $xafPath) {
    $xaf = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($xafPath))
    foreach ($m in [regex]::Matches($xaf, 'texture\s+"([^"]+)"', 'IgnoreCase')) {
        $leaf = ($m.Groups[1].Value -split '[\\/]')[-1]
        if (-not $names.Contains($leaf)) { [void]$names.Add($leaf) }
    }
}
$autoKeyed = @()
for ($i = 0; $i -lt $names.Count; $i++) { if ($names[$i] -like '*#*') { $autoKeyed += $i } }
if ($autoKeyed.Count -and -not $Keyed.Count) {
    $Keyed = $autoKeyed
    Write-Host ("auto-detected chroma-keyed records from the .XAF: {0}" -f ($Keyed -join ', ')) -ForegroundColor Cyan
}

$work = Join-Path $env:TEMP ("aztres-" + $stem)
$exp  = Join-Path $work 'export'
$imp  = Join-Path $work 'import'
foreach ($d in @($exp, $imp)) {
    if (Test-Path $d) { Get-ChildItem $d -Filter '*.png' -File | Remove-Item -Force }
    New-Item -ItemType Directory -Force $d | Out-Null
}

Write-Host ("=== exporting {0} ===" -f $stem) -ForegroundColor Cyan
& (Join-Path $root 'src\Texture-Tool.ps1') -Export -Res $stem -OutDir $exp -TexDir $TexDir | Out-Null

# ---- upscale ----------------------------------------------------------------
Write-Host ""
Write-Host ("=== Scale2x ===") -ForegroundColor Cyan
$oldBytes = 0L; $newBytes = 0L; $done = 0; $skipped = @()
foreach ($f in (Get-ChildItem $exp -Filter '*-tex.png' -File | Sort-Object { [int](($_.BaseName -split '-')[0]) })) {
    $idx = [int](($f.BaseName -split '-')[0])
    $nm  = if ($idx -lt $names.Count) { $names[$idx] } else { '?' }

    $im = [System.Drawing.Image]::FromFile($f.FullName)
    $w = $im.Width; $h = $im.Height
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.DrawImage($im, 0, 0, $w, $h); $g.Dispose(); $im.Dispose()

    $oldBytes += [int64]$w * $h
    if (($w * 2) -gt $MaxAxis -or ($h * 2) -gt $MaxAxis) {
        $skipped += ("{0} ({1}) {2}x{3} -- doubling exceeds the {4}px ceiling" -f $idx, $nm, $w, $h, $MaxAxis)
        $newBytes += [int64]$w * $h
        $bmp.Dispose()
        continue
    }

    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $d = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $px = New-Object 'int[]' ($w * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($d.Scan0, $px, 0, $px.Length)
    $bmp.UnlockBits($d); $bmp.Dispose()

    $nw = 0; $nh = 0
    $up = [AztTool.Upscale]::Scale2($px, $w, $h, [ref]$nw, [ref]$nh)

    $ob = New-Object System.Drawing.Bitmap($nw, $nh, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $r2 = New-Object System.Drawing.Rectangle(0, 0, $nw, $nh)
    $d2 = $ob.LockBits($r2, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    [System.Runtime.InteropServices.Marshal]::Copy($up, 0, $d2.Scan0, $up.Length)
    $ob.UnlockBits($d2)
    $ob.Save((Join-Path $imp ("{0}-tex.png" -f $idx)), [System.Drawing.Imaging.ImageFormat]::Png)
    $ob.Dispose()

    $newBytes += [int64]$nw * $nh
    $done++
    Write-Host ("  {0,2}  {1,-14} {2,3}x{3,-3} -> {4,3}x{5,-3}" -f $idx, ($nm -replace '\.(gif|azf)$',''), $w, $h, $nw, $nh)
}

Write-Host ""
foreach ($s in $skipped) { Write-Host ("  SKIPPED {0}" -f $s) -ForegroundColor Yellow }
Write-Host ""
Write-Host ("{0} texture(s) doubled, {1} left alone" -f $done, $skipped.Count)
Write-Host ("decoded pixel bytes: {0:N0} -> {1:N0}  (+{2:N0}, x{3:N2})" -f `
            $oldBytes, $newBytes, ($newBytes - $oldBytes), ($newBytes / [double]$oldBytes)) -ForegroundColor Yellow
Write-Host  "  ^ this is what the texture cache must hold. If the game reports out of memory," -ForegroundColor Yellow
Write-Host ("    run:  .\tools\Upscale-Res.ps1 -Res {0} -Revert" -f $stem) -ForegroundColor Yellow

if ($WhatIf) { Write-Host "`n-WhatIf: nothing written." -ForegroundColor Cyan; return }
if (-not $done) { throw "nothing to import" }

Write-Host ""
Write-Host ("=== importing into {0}.RES ===" -f $stem) -ForegroundColor Cyan
& (Join-Path $root 'src\Texture-Tool.ps1') -Import -Res $stem -InDir $imp -TexDir $TexDir -Keyed $Keyed

Write-Host ""
Write-Host ("original {0:N0} bytes -> new {1:N0} bytes" -f (Get-Item $origPath).Length, (Get-Item $resPath).Length) -ForegroundColor Green
