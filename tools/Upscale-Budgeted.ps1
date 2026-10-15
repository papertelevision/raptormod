# Upscale-Budgeted.ps1 -- take the game's own art to 512 texels, PER ROOM, as far as
# that room's share of the texture cache allows.
#
#   .\tools\Upscale-Budgeted.ps1 -WhatIf          # plan only, change nothing
#   .\tools\Upscale-Budgeted.ps1
#   .\tools\Upscale-Budgeted.ps1 -Revert
#
# WHY THIS EXISTS RATHER THAN Upscale-Originals. That script upscales every record in
# the files you name, which is the right tool when you are judging a handful of rooms
# by eye. It cannot be pointed at the whole game, because the cost is not uniform: a
# blanket 256->512 across all 179 .RES files puts 47 of them over the texture cache,
# and the cache is not a soft limit you can ignore -- textures that do not fit get
# evicted and re-decoded (Huffman, per upload), which trades sharpness for frame rate
# in exactly the rooms that are already the heaviest.
#
# THE BUDGET IS THE WHOLE POINT. The cache is sized ONCE at startup as
# (largest free block - reserve), and both numbers are fixed:
#
#     block 29,891,584 - reserve 25,165,824 (24 MB) = cache 4,725,760 = 4.51 MB
#
# memsize cannot raise the block (64 MB exits after ~17 s) and the reserve cannot fall
# much, because at 1600x1200 it is holding 1.92 MB full-screen surfaces, a 2.97 MB
# z-buffer and a 1.95 MB movie buffer. See [[azrael-texture-cache-reserve]] and
# [[azrael-1600x1200]].
#
# So each .RES gets a ceiling, and the records are upscaled in priority order until the
# next one would not fit. A room under its ceiling is upscaled completely; a room over
# it gets its most-visible textures done and keeps the rest at 256. Nothing silently
# overshoots.
#
# PRIORITY IS A PROXY, NOT A MEASUREMENT. What actually deserves the texels is whatever
# fills the most screen, and that needs per-face world area out of the .XAF. This ranks
# by (record area) x (how many materials reference the texture) instead: a 256x256 used
# by six materials is on six objects and is almost certainly wall or floor, while one
# used once is usually a prop. It discriminates where plain area cannot -- every 256x256
# record has identical area, so without this the choice inside a heavy room would be
# arbitrary file order. If a room ever looks wrong, that ordering is the thing to
# improve, and the .XAF has the data.
#
# ALWAYS READS FROM .orig, like Upscale-Originals, so re-running cannot compound the
# interpolation or walk past 512. -Revert restores every .RES that has a .orig.
[CmdletBinding()]
param(
    [string]$TexDir = 'C:\Games\RaptorMod\game\GAME\AZTEX',
    # The startup split. Defaults are the measured block and the reserve this build
    # patches in; pass them if either changes.
    [long]  $BlockBytes   = 29891584,
    [long]  $ReserveBytes = 0x1800000,
    # Held back from every room's ceiling for CHARACTER textures, which load on top of
    # the room and live in the same cache. LURKA and friends are in the same 179 .RES
    # files and are upscaled by this script too, so the room's ceiling has to leave
    # room for them. 1.0 MB covers an upscaled character or two.
    [double]$MarginMB = 1.0,
    [double]$Sharpen = 0.8,
    [int]   $Factor  = 2,
    [int]   $MaxAxis = 512,
    [string[]]$Only = @(),
    [switch]$Revert,
    [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
Add-Type -AssemblyName System.Drawing
if (-not ("AztTool.Azf" -as [type])) {
    Add-Type -Path (Join-Path $toolDir 'AzfTool.cs'),(Join-Path $toolDir 'Uprez.cs') -ReferencedAssemblies System.Drawing
}

$cache  = $BlockBytes - $ReserveBytes
$budget = [long]($cache - ($MarginMB * 1MB))
if ($budget -le 0) { throw "margin ${MarginMB} MB leaves no budget in a $([Math]::Round($cache/1MB,2)) MB cache" }

$files = Get-ChildItem $TexDir -Filter '*.RES' | Sort-Object Name
if ($Only.Count) {
    $want = $Only | ForEach-Object { ($_ -replace '\.RES$','').ToUpperInvariant() }
    $files = $files | Where-Object { $want -contains $_.BaseName.ToUpperInvariant() }
}
if (-not $files) { throw 'no .RES files matched' }

if ($Revert) {
    $n = 0
    foreach ($f in $files) {
        $orig = "$($f.FullName).orig"
        if (Test-Path $orig) { Copy-Item $orig $f.FullName -Force; $n++ }
    }
    Write-Host ("reverted {0} of {1} .RES file(s) from their .orig backups" -f $n, $files.Count) -ForegroundColor Green
    return
}

Write-Host ("texture cache {0:N0} bytes ({1:N2} MB) = block {2:N0} - reserve {3:N0}" -f $cache,($cache/1MB),$BlockBytes,$ReserveBytes)
Write-Host ("per-room ceiling {0:N0} bytes ({1:N2} MB), holding {2:N1} MB back for characters" -f $budget,($budget/1MB),$MarginMB)
Write-Host ("{0} .RES file(s), factor x{1} up to {2} px, sharpen {3:N2}{4}" -f $files.Count,$Factor,$MaxAxis,$Sharpen,$(if($WhatIf){'   [WhatIf]'}else{''}))
Write-Host ''

$rep = @()
foreach ($f in $files) {
    $stem = $f.BaseName
    $orig = "$($f.FullName).orig"
    if (-not (Test-Path $orig)) {
        if ($WhatIf) { } else { Copy-Item $f.FullName $orig }
    }
    $src = $(if (Test-Path $orig) { $orig } else { $f.FullName })
    $texs = [AztTool.Azf]::Read($src)

    # Texture leaf names in first-appearance order -- the ONLY thing tying a record to
    # the room's art, because a .RES carries no names. Also count how many materials
    # reference each one; that is the priority proxy.
    $xaf = Join-Path $TexDir "$stem.XAF"
    $names = New-Object System.Collections.ArrayList
    $uses  = @{}
    if (Test-Path $xaf) {
        $txt = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($xaf))
        foreach ($m in [regex]::Matches($txt, 'texture\s+"([^"]+)"', 'IgnoreCase')) {
            $leaf = (($m.Groups[1].Value -split '[\\/]')[-1]) -replace '\.(azf|gif)$',''
            if (-not $names.Contains($leaf)) { [void]$names.Add($leaf) }
            if ($uses.ContainsKey($leaf)) { $uses[$leaf]++ } else { $uses[$leaf] = 1 }
        }
    }

    # Base cost counts EVERY record, including ones that do not decode: they still
    # occupy the cache, they just cannot be rescaled.
    $base = 0L
    foreach ($t in $texs) { $base += [int64]$t.Width * $t.Height }

    $cand = @()
    for ($i = 0; $i -lt $texs.Count; $i++) {
        $t = $texs[$i]
        if (-not $t.Decoded) { continue }
        if ($t.Width * $Factor -gt $MaxAxis -or $t.Height * $Factor -gt $MaxAxis) { continue }
        $nm  = $(if ($i -lt $names.Count) { $names[$i] } else { "rec$i" })
        $use = $(if ($uses.ContainsKey($nm)) { [int]$uses[$nm] } else { 1 })
        $area = [int64]$t.Width * $t.Height
        $cand += [pscustomobject]@{
            Index = $i; Name = $nm; Tex = $t; Area = $area
            # going to Factor^2 the pixels ADDS (Factor^2 - 1) x the current area
            Cost  = $area * ($Factor * $Factor - 1)
            Prio  = $area * $use
            Keyed = ($nm -match '#')
        }
    }

    $total = $base; $did = 0; $held = 0
    foreach ($c in ($cand | Sort-Object -Property Prio -Descending)) {
        if (($total + $c.Cost) -gt $budget) { $held++; continue }
        if (-not $WhatIf) {
            [AztTool.Uprez]::ScaleSmooth($c.Tex, $Factor, $c.Keyed, $Sharpen)
            $c.Tex.Dirty = $true
        }
        $total += $c.Cost; $did++
    }

    if (-not $WhatIf -and $did -gt 0) { [AztTool.Azf]::Write($f.FullName, $texs) }

    $rep += [pscustomobject]@{
        Room = $stem; Recs = $texs.Count; Cand = $cand.Count; Scaled = $did; Held = $held
        BaseMB = $base/1MB; FinalMB = $total/1MB
        Full = ($held -eq 0 -and $cand.Count -gt 0); Limited = ($held -gt 0)
    }
}

$full    = @($rep | Where-Object { $_.Full })
$limited = @($rep | Where-Object { $_.Limited })
Write-Host ("{0,-12} {1,5} {2,5} {3,6} {4,9} {5,9}" -f 'room','recs','up','held','before','after')
foreach ($r in ($rep | Sort-Object FinalMB -Descending | Select-Object -First 12)) {
    Write-Host ("{0,-12} {1,5} {2,5} {3,6} {4,6:N2} MB {5,6:N2} MB{6}" -f `
        $r.Room,$r.Recs,$r.Scaled,$r.Held,$r.BaseMB,$r.FinalMB,$(if($r.Limited){'   <- capped'}else{''}))
}
Write-Host ''
Write-Host ("{0} room(s) fully upscaled, {1} capped by the budget, {2} with nothing to do" -f `
    $full.Count, $limited.Count, ($rep.Count - $full.Count - $limited.Count))
Write-Host ("records upscaled {0:N0} of {1:N0} candidates" -f (($rep | Measure-Object Scaled -Sum).Sum), (($rep | Measure-Object Cand -Sum).Sum))
$over = @($rep | Where-Object { $_.FinalMB -gt ($budget/1MB) + 0.0001 })
if ($over.Count) {
    $over | ForEach-Object { Write-Host ("  OVER BUDGET: {0} at {1:N2} MB" -f $_.Room,$_.FinalMB) -ForegroundColor Red }
    throw "$($over.Count) room(s) ended up over the ceiling -- the greedy fill is wrong, do not install this"
}
Write-Host ("every room is within the {0:N2} MB ceiling; heaviest is {1:N2} MB" -f `
    ($budget/1MB), (($rep | Measure-Object FinalMB -Maximum).Maximum)) -ForegroundColor Green
if ($WhatIf) { Write-Host 'nothing written (-WhatIf)' -ForegroundColor Yellow }
