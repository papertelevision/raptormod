# Upscale-Originals.ps1 -- take the GAME'S OWN art to 512 texels. No new artwork.
#
#   .\tools\Upscale-Originals.ps1 -Res CORICORI,LURKA -Sharpen 0.8
#   .\tools\Upscale-Originals.ps1 -Res CORICORI -Revert
#
# WHAT THIS CAN AND CANNOT DO. An upscale invents no detail. What it buys on this engine is
# SMALLER TEXELS: the rasteriser point-samples with no filtering, so a 256px texture
# magnified on a nearby wall shows hard texel blocks, and at 512 those blocks are half the
# size. That is the whole effect. Anyone expecting more resolution in the ARTWORK will be
# disappointed -- the artwork is 1996 artwork either way.
#
# WHY NOT SCALE2X. It is the obvious choice (edge-preserving, palette-exact, immune to the
# chroma-key fringe problem) and it was measured on this data before being rejected: it
# alters 5.9% of CORICORI's source pixels and 3.2% of LURKA's. The other 94-97% is plain
# pixel doubling, i.e. an identical picture at four times the memory. Scale2x needs
# neighbouring pixels to be EQUAL, and digitised photographic texture almost never obliges.
# The method is still in Uprez.cs if a future asset is clean pixel art.
#
# So this uses a bicubic upscale plus an unsharp mask, re-quantised into each texture's OWN
# palette -- no colour is invented, nothing is dithered, and keyed textures keep an exact
# magenta key.
#
# COST. Every record that doubles takes 4x its decoded bytes, and that memory comes out of
# the texture cache, which is the known cause of the big-room out-of-memory crash. The
# script totals this up and prints it. Records already at 512 on either axis are LEFT ALONE:
# 512 is the largest the game ships and 1024 is untested.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Res,
    [string]$TexDir = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX',
    # unsharp amount after the bicubic upscale. 0 = plain bicubic (soft), 0.8 = default,
    # above ~1.5 it rings on high-contrast grout lines.
    [double]$Sharpen = 0.8,
    [int]$Factor = 2,
    [int]$MaxAxis = 512,
    [switch]$Scale2x,        # palette-exact, but see the note above before using it
    [switch]$Revert          # restore every named .RES from its .orig and stop
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
Add-Type -AssemblyName System.Drawing
if (-not ("AztTool.Azf" -as [type])) {
    Add-Type -Path (Join-Path $toolDir 'AzfTool.cs'),(Join-Path $toolDir 'Uprez.cs') -ReferencedAssemblies System.Drawing
}

$totalBefore = 0L; $totalAfter = 0L

foreach ($name in $Res) {
    $stem = $name -replace '\.(RES|XAF)$',''
    $resPath = Join-Path $TexDir "$stem.RES"
    $origRes = "$resPath.orig"
    if (-not (Test-Path $resPath)) { Write-Host ("no such .RES: {0}" -f $resPath) -ForegroundColor Yellow; continue }
    if (-not (Test-Path $origRes)) { Copy-Item $resPath $origRes }

    if ($Revert) {
        Copy-Item $origRes $resPath -Force
        Write-Host ("{0}.RES reverted to original ({1:N0} bytes)" -f $stem, (Get-Item $resPath).Length) -ForegroundColor Green
        continue
    }

    # ALWAYS from the pristine backup, never from the live file: upscaling an already
    # upscaled record would compound the interpolation and blow past 512.
    $texs = [AztTool.Azf]::Read($origRes)

    # keyed records, by name -- '#' in the .XAF texture name means chroma key on magenta
    $xafPath = Join-Path $TexDir "$stem.XAF"
    $names = New-Object System.Collections.ArrayList
    if (Test-Path $xafPath) {
        $xaf = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($xafPath))
        foreach ($m in [regex]::Matches($xaf, 'texture\s+"([^"]+)"', 'IgnoreCase')) {
            $leaf = (($m.Groups[1].Value -split '[\\/]')[-1]) -replace '\.(azf|gif)$',''
            if (-not $names.Contains($leaf)) { [void]$names.Add($leaf) }
        }
    }

    Write-Host ("=== {0} ===" -f $stem)
    $before = 0L; $after = 0L; $scaled = 0; $skipped = 0
    for ($i = 0; $i -lt $texs.Count; $i++) {
        $t = $texs[$i]
        $nm = if ($i -lt $names.Count) { $names[$i] } else { "rec$i" }
        if (-not $t.Decoded) {
            Write-Host ("  {0,2} {1,-12} does not decode -- passed through untouched" -f $i, $nm) -ForegroundColor DarkGray
            continue
        }
        $before += [int64]$t.Width * $t.Height
        if ($t.Width * $Factor -gt $MaxAxis -or $t.Height * $Factor -gt $MaxAxis) {
            Write-Host ("  {0,2} {1,-12} {2}x{3} already at or near the {4} limit -- left alone" -f `
                        $i, $nm, $t.Width, $t.Height, $MaxAxis) -ForegroundColor DarkGray
            $after += [int64]$t.Width * $t.Height
            $skipped++
            continue
        }
        $keyed = $nm -match '#'
        $ow = $t.Width; $oh = $t.Height
        if ($Scale2x) {
            if ($Factor -ne 2) { throw '-Scale2x only does a factor of 2' }
            $ch = [AztTool.Uprez]::Scale2x($t)
            $extra = ("  scale2x altered {0:P1} of source px" -f ($ch / [double]($ow*$oh)))
        } else {
            [AztTool.Uprez]::ScaleSmooth($t, $Factor, $keyed, $Sharpen)
            $extra = ("  bicubic + sharpen {0:N2}" -f $Sharpen)
        }
        $t.Dirty = $true
        $after += [int64]$t.Width * $t.Height
        $scaled++
        Write-Host ("  {0,2} {1,-12} {2}x{3} -> {4}x{5}{6}{7}" -f `
                    $i, $nm, $ow, $oh, $t.Width, $t.Height, $extra, $(if ($keyed) { '  [KEYED]' } else { '' }))
    }

    [AztTool.Azf]::Write($resPath, $texs)
    Write-Host ("  {0} scaled, {1} left alone.  decoded bytes {2:N0} -> {3:N0}  (+{4:N2} MB)   file {5:N0} bytes" -f `
                $scaled, $skipped, $before, $after, (($after-$before)/1MB), (Get-Item $resPath).Length) -ForegroundColor Green
    $totalBefore += $before; $totalAfter += $after
}

if (-not $Revert) {
    Write-Host ""
    Write-Host ("TEXTURE CACHE COST: decoded bytes {0:N0} -> {1:N0}, an extra {2:N2} MB" -f `
                $totalBefore, $totalAfter, (($totalAfter-$totalBefore)/1MB)) -ForegroundColor Cyan
    Write-Host  "That memory comes out of the cache, which is sized from the largest free block" -ForegroundColor Cyan
    Write-Host  "minus 4.5 MB -- so walk into a large room before trusting it." -ForegroundColor Cyan
}
