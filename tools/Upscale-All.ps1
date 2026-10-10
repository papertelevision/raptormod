# Upscale-All.ps1 -- every texture in the game, in batches, with the approved recipe.
#
#   .\tools\Upscale-All.ps1 -List            what the batches are and how far along each is
#   .\tools\Upscale-All.ps1 -Batch 1         run one batch (skips textures already done)
#   .\tools\Upscale-All.ps1 -Batch 1,2,3     several
#
# THE ORDER IS THE GAME'S. Rooms come first, walked outward from the first room through the
# doorways in portals.json (tools\Build-PortalMap.ps1), so each batch is a stretch of the game
# the player reaches together; rooms the graph does not reach follow alphabetically; then every
# other unit (creatures, characters, items). Written once to -PlanFile and reused, so batch
# numbers never shift under you.
#
# The recipe is THE approved one (see memory: azrael-texture-upscale-recipe); change it here
# only when Josh changes it. Textures already in -OutDir are skipped, so a batch can be run
# again, or interrupted and resumed, without redoing anything. Texture files are shared between
# rooms, so later batches get smaller.
param(
    [int[]]$Batch = @(),
    [switch]$List,
    [int]$BatchSize = 12,
    [string]$PlanFile = 'C:\Games\azrael-textures\upscale-plan.txt',
    [string]$LogFile  = 'C:\Games\azrael-textures\upscale-all.log',
    [string]$CacheDir = 'C:\Games\azrael-render',
    [string]$OutDir   = 'C:\Games\azrael-textures\hires',
    [string]$Portals  = 'C:\Games\azrael-render\portals.json',
    [string]$First    = 'CORICORI'
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
$RECIPE = @{ Blend = 1.0; Sharpen = 0.8; Grain = 2.0; GrainTint = 0.35; ColourFromOriginal = $true }
$RECIPE.Blend = 0.9

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c; try { [IO.File]::AppendAllText($LogFile, ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) + [Environment]::NewLine) } catch { } }

# ---- the plan ----------------------------------------------------------------------------
if (-not (Test-Path $PlanFile)) {
    $units = @(Get-ChildItem $CacheDir -Filter *.mtl | ForEach-Object { $_.BaseName } | Sort-Object)
    $graph = @{}
    if (Test-Path $Portals) {
        $pl = Get-Content $Portals -Raw | ConvertFrom-Json
        foreach ($p in $pl.PSObject.Properties) { $from = $p.Name.ToUpper(); if (-not $graph.ContainsKey($from)) { $graph[$from] = @() }
            foreach ($e in @($p.Value)) { if ($e.to) { $to = ([string]$e.to).ToUpper(); $graph[$from] += $to; if (-not $graph.ContainsKey($to)) { $graph[$to] = @() } } } }
    }
    $rooms = @{}; foreach ($k in $graph.Keys) { $rooms[$k] = 1 }
    $order = New-Object System.Collections.Generic.List[string]; $seen = @{}
    $queue = New-Object System.Collections.Generic.Queue[string]
    if ($graph.ContainsKey($First.ToUpper())) { $queue.Enqueue($First.ToUpper()); $seen[$First.ToUpper()] = 1 }
    while ($queue.Count) { $u = $queue.Dequeue(); if ($units -contains $u) { $order.Add($u) }
        foreach ($v in ($graph[$u] | Sort-Object -Unique)) { if (-not $seen.ContainsKey($v)) { $seen[$v] = 1; $queue.Enqueue($v) } } }
    foreach ($u in $units) { if ($rooms.ContainsKey($u) -and -not $seen.ContainsKey($u)) { $order.Add($u); $seen[$u] = 1 } }   # rooms the graph does not reach
    foreach ($u in $units) { if (-not $seen.ContainsKey($u)) { $order.Add($u) } }                                             # everything else: creatures, characters, items
    $lines = @(); for ($i = 0; $i -lt $order.Count; $i++) { $lines += (([string]([int][Math]::Floor($i / $BatchSize) + 1)) + "`t" + $order[$i] + "`t" + $(if ($rooms.ContainsKey($order[$i])) { 'room' } else { 'model' })) }
    [IO.File]::WriteAllLines($PlanFile, $lines)
    Say ("plan written: {0} units in {1} batches of {2} -> {3}" -f $order.Count, ([int][Math]::Floor(($order.Count - 1) / $BatchSize) + 1), $BatchSize, $PlanFile) Green
}
$plan = @([IO.File]::ReadAllLines($PlanFile) | Where-Object { $_ } | ForEach-Object { $p = $_ -split "`t"; [pscustomobject]@{ Batch = [int]$p[0]; Unit = $p[1]; Kind = $p[2] } })

function Get-UnitTextures([string]$u) {
    $mtl = Join-Path $CacheDir ("{0}.mtl" -f $u); if (-not (Test-Path $mtl)) { return @() }
    @([IO.File]::ReadAllLines($mtl) | Where-Object { $_.Trim().StartsWith('map_Kd ') } | ForEach-Object { $_.Trim().Substring(7).Trim() } | Select-Object -Unique | Where-Object { Test-Path (Join-Path $CacheDir $_) })
}

if ($List -or -not $Batch.Count) {
    $all = @{}; foreach ($u in $plan.Unit) { foreach ($t in (Get-UnitTextures $u)) { $all[$t] = 1 } }
    $done = @($all.Keys | Where-Object { Test-Path (Join-Path $OutDir $_) }).Count
    Write-Host ("{0} units, {1} distinct textures, {2} done ({3:P0})`n" -f $plan.Count, $all.Count, $done, ($done / [Math]::Max(1, $all.Count)))
    foreach ($b in ($plan | Group-Object Batch | Sort-Object { [int]$_.Name })) {
        $tex = @{}; foreach ($u in $b.Group.Unit) { foreach ($t in (Get-UnitTextures $u)) { $tex[$t] = 1 } }
        $d = @($tex.Keys | Where-Object { Test-Path (Join-Path $OutDir $_) }).Count
        $state = $(if ($tex.Count -eq 0) { 'nothing' } elseif ($d -eq $tex.Count) { 'DONE' } elseif ($d -gt 0) { "{0}/{1}" -f $d, $tex.Count } else { "{0} to do" -f $tex.Count })
        Write-Host ("batch {0,2}  {1,-9} {2}" -f $b.Name, $state, (($b.Group | ForEach-Object { if ($_.Kind -eq 'model') { $_.Unit.ToLower() } else { $_.Unit } }) -join ' '))
    }
    Write-Host "`n(lower-case = a creature, character or item model; textures shared with earlier batches are already counted as done)"
    return
}

# ---- run --------------------------------------------------------------------------------
$clockAll = [Diagnostics.Stopwatch]::StartNew(); $nTex = 0; $nUnits = 0; $problems = @()
foreach ($bn in $Batch) {
    $group = @($plan | Where-Object { $_.Batch -eq $bn })
    if (-not $group.Count) { Say "batch $bn does not exist" Yellow; continue }
    Say ("==== batch {0}: {1}" -f $bn, ($group.Unit -join ' ')) Cyan
    foreach ($u in $group.Unit) {
        $todo = @(Get-UnitTextures $u | Where-Object { -not (Test-Path (Join-Path $OutDir $_)) })
        if (-not $todo.Count) { Say ("  {0,-10} nothing to do" -f $u) DarkGray; continue }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $toolDir 'Upscale-Room.ps1'), '-Room', $u, '-OutDir', $OutDir, '-CacheDir', $CacheDir,
                  '-Blend', $RECIPE.Blend, '-Sharpen', $RECIPE.Sharpen, '-Grain', $RECIPE.Grain, '-GrainTint', $RECIPE.GrainTint)
        if ($RECIPE.ColourFromOriginal) { $args += '-ColourFromOriginal' }
        $out = & powershell @args 2>&1 | Out-String
        $made = @(Get-UnitTextures $u | Where-Object { Test-Path (Join-Path $OutDir $_) }).Count
        $bad = ($out -match 'produced nothing|skipped|ORDER FAILED|error|exception')
        Say ("  {0,-10} {1,3} textures, {2,3} of {3} now done, {4,4:N0} s{5}" -f $u, $todo.Count, $made, @(Get-UnitTextures $u).Count, $clock.Elapsed.TotalSeconds, $(if ($bad) { '  ** see log' } else { '' })) $(if ($bad) { 'Yellow' } else { 'Gray' })
        if ($bad) { $problems += $u; try { [IO.File]::AppendAllText($LogFile, $out) } catch { } }
        $nTex += $todo.Count; $nUnits++
    }
}
Say ("done: {0} units, {1} textures, {2:N0} min{3}" -f $nUnits, $nTex, $clockAll.Elapsed.TotalMinutes, $(if ($problems.Count) { '; PROBLEMS: ' + ($problems -join ', ') } else { '' })) Green
