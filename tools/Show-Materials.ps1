# Show-Materials.ps1 -- what each texture of a room (or a character) is, by rooms\_materials.json, and why (the room's own
# word, the table's names, which rule, or the default). -Sheet draws the textures grouped by material, to check the tags by eye.
#
#   .\tools\Show-Materials.ps1 -Room SPAROOM
#   .\tools\Show-Materials.ps1 -Room ORRERY -Sheet C:\Games\azrael-render\tc-test\materials-ORRERY.png
#   .\tools\Show-Materials.ps1 -Room LURKA -Character            (what a character wears: its own rules)
#   .\tools\Show-Materials.ps1 -All                              (every unit: counts, and the names left to the default)
param([string]$Room = '', [switch]$Character, [string]$Sheet = '', [switch]$All,
      [string]$RenderDir = 'C:\Games\azrael-render', [string]$Hires = 'C:\Games\azrael-textures\hires', [string]$RoomsDir = '')
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
if (-not $RoomsDir) { $RoomsDir = Join-Path $RenderDir 'rooms' }
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $toolDir 'Watch-HostRender.ps1'), [ref]$null, [ref]$null)
foreach ($fn in 'Get-MaterialTable', 'Resolve-TexMaterial') { $fd = $ast.Find({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $fn }, $true); . ([scriptblock]::Create($fd.Extent.Text)) }
function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
$script:matTable = $null; $script:matStamp = $null
$tbl = Get-MaterialTable; if (-not $tbl) { throw "no $RoomsDir\_materials.json" }
function Get-Leaves([string]$unit) {
    $mtl = Join-Path $RenderDir "$unit.mtl"; if (-not (Test-Path $mtl)) { return @() }
    @([IO.File]::ReadAllLines($mtl) | Where-Object { $_.Trim().StartsWith('map_Kd ') } | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Trim().Substring(7).Trim()) } | Select-Object -Unique)
}
# (a character: an .ANI-driven rig -- its unit's textures are worn by something that moves)
$charUnits = @{}; foreach ($x in 'LURKA', 'RAPTOR', 'THEO', 'EUGBLD', 'NIAMH', 'LEO', 'CLAUDE') { $charUnits[$x] = 1 }
if ($All) {
    $tot = @{}; $dflt = @{}
    foreach ($m in Get-ChildItem $RenderDir -Filter '*.mtl') {
        $isChar = $charUnits.ContainsKey($m.BaseName.ToUpper())
        foreach ($lf in Get-Leaves $m.BaseName) {
            $r = Resolve-TexMaterial $tbl ([pscustomobject]@{ Leaf = $lf; Moves = $isChar }) $null
            $tot[$r.Material] = 1 + [int]$tot[$r.Material]
            if ($r.How -eq 'default') { $dflt[$r.Name] = 1 }
        }
    }
    'every unit: ' + (($tot.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { '{0} {1}' -f $_.Value, $_.Key }) -join ', ')
    "left to the default ({0} names): {1}" -f $dflt.Count, ((@($dflt.Keys) | Sort-Object) -join ' ')
    return
}
if (-not $Room) { throw 'give -Room (or -All)' }
$rm = @{}; $own = Join-Path $RoomsDir "$Room.json"
if (Test-Path $own) { $o = [IO.File]::ReadAllText($own) | ConvertFrom-Json; if ($o.materials) { foreach ($pp in $o.materials.PSObject.Properties) { $rm[$pp.Name.ToLowerInvariant()] = $pp.Value } } }
$rows = foreach ($lf in Get-Leaves $Room) {
    $r = Resolve-TexMaterial $tbl ([pscustomobject]@{ Leaf = $lf; Moves = [bool]$Character }) $rm
    [pscustomobject]@{ Texture = $lf; Material = $r.Material; Why = $r.How }
}
$rows | Sort-Object Material, Texture | Format-Table -AutoSize | Out-String -Width 200
if ($Sheet) {
    Add-Type -AssemblyName System.Drawing
    $groups = @($rows | Group-Object Material | Sort-Object Name); $S = 150; $per = 8
    $lines = 0; foreach ($gp in $groups) { $lines += [Math]::Ceiling($gp.Count / $per) }
    $bm = New-Object Drawing.Bitmap ($per * ($S + 6) + 130), ($lines * ($S + 24) + 10); $g = [Drawing.Graphics]::FromImage($bm)
    $g.Clear([Drawing.Color]::FromArgb(24, 24, 24)); $g.InterpolationMode = 'HighQualityBicubic'
    $f = New-Object Drawing.Font('Segoe UI', 8); $fb = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold); $y = 5
    foreach ($gp in $groups) {
        $g.DrawString($gp.Name, $fb, [Drawing.Brushes]::Gold, 4, $y + 4); $i = 0
        foreach ($rw in $gp.Group) {
            $x = 130 + ($i % $per) * ($S + 6); if ($i -gt 0 -and ($i % $per) -eq 0) { $y += $S + 24 }
            $p = Join-Path $Hires ($rw.Texture + '.png'); if (-not (Test-Path $p)) { $p = Join-Path $RenderDir ($rw.Texture + '.png') }
            if (Test-Path $p) { $im = [Drawing.Image]::FromFile($p); $k = [Math]::Min($S / $im.Width, $S / $im.Height); $g.DrawImage($im, $x, $y, [int]($im.Width * $k), [int]($im.Height * $k)); $im.Dispose() }
            $g.DrawString($rw.Texture, $f, [Drawing.Brushes]::White, $x, $y + $S + 4); $i++
        }
        $y += $S + 24
    }
    $bm.Save($Sheet); $g.Dispose(); $bm.Dispose(); "sheet: $Sheet"
}
