# Test-TextureTiling.ps1 -- PHASE 3's AUDIT (Josh, 2026-10-12): every room's textures as its models lay them --
#   REPEATS xN   a face repeats the texture N times (the SPAROOM pipe: 22, sheared -- "the rope pipe")
#   DARK EDGES   ...and the art is dark along the edges that meet in those repeats: a stripe per repeat
#   SEAM         ...or those edges do not match: a hard line per repeat
#   STRETCHED    faces laying it far more thinly one way than the other (over -StretchK times)
#   SMEARED      faces with their texture coordinates in a line: the art streaked across them
#   BAD UV       faces whose texture coordinates are garbage in the 1996 files (-1.7e38): one texel of the art, flat
# Judged on the art in use (the hi-res replacement if there is one, else the original). In play the graphics card's TEXTURE
# REPAIR (GpuRaster.SetRelay, F11) re-lays smeared and stretched faces where it safely can and mixes clean repeats; DARK EDGES and
# SEAM are for the ART (cut-out art -- ropes, chains on black holes -- is not flagged).
#
#   .\tools\Test-TextureTiling.ps1                                   (every room in portals.json)
#   .\tools\Test-TextureTiling.ps1 -Rooms CORICORI,SPAROOM -Sheet C:\Games\RaptorMod\cache\tc-test\tiling.png
param([string[]]$Rooms = @(), [string]$RenderDir = 'C:\Games\RaptorMod\cache', [string]$Hires = 'C:\Games\RaptorMod\textures\hires',
      [double]$StretchK = 4, [string]$Out = '', [string]$Sheet = '', [int]$Top = 30,
      # SHARED ART (2026-10-12): the same original picture is exported once per unit that holds it (03-baptapce in MINEMAZE is
      # 00-baptapce in BAPTIST, pixel for pixel), and the replacement art goes in by file name -- so new art made for one room's
      # copy left the others on the old upscale. The loader now shows a twin's new art there (tools\TexTwins.cs). -Twins lists
      # what it does, and any copy still OUT OF STEP by the older rule (the twin's file > 3x the size and > 2 days newer) that
      # it does not cover; -TwinsOut writes both as CSV.
      [switch]$Twins, [string]$TwinsOut = '')
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
Add-Type -Path @((Join-Path $toolDir 'TexAudit.cs'), (Join-Path $toolDir 'TexTwins.cs')) -ReferencedAssemblies System.Drawing
if (-not $Rooms.Count) {
    $pj = Join-Path $RenderDir 'portals.json'
    $Rooms = @(([IO.File]::ReadAllText($pj) | ConvertFrom-Json).PSObject.Properties.Name)
}
# the art each leaf shows in play: its own replacement, a twin's new art (as the loader picks it), else the original
$twinMap = $(if (Test-Path -LiteralPath $Hires) { [AztTool.TexTwins]::Load($RenderDir, $Hires) } else { @{} })
function Get-ArtLeaf([string]$leaf) { if ($twinMap.ContainsKey($leaf)) { $twinMap[$leaf] } else { $leaf } }
$edges = @{}
function Get-Edges([string]$leaf) {
    if (-not $edges.ContainsKey($leaf)) {
        $p = Join-Path $Hires ((Get-ArtLeaf $leaf) + '.png'); if (-not (Test-Path -LiteralPath $p)) { $p = Join-Path $RenderDir "$leaf.png" }
        $edges[$leaf] = $(if (Test-Path -LiteralPath $p) { try { [AztTool.TexAudit]::Edges($p) } catch { $null } } else { $null })
    }
    return $edges[$leaf]
}
$rows = New-Object System.Collections.Generic.List[object]
$t0 = [Diagnostics.Stopwatch]::StartNew()
foreach ($room in $Rooms) {
    $obj = Join-Path $RenderDir "$room.obj"; $mtl = Join-Path $RenderDir "$room.mtl"
    if (-not (Test-Path $obj) -or -not (Test-Path $mtl)) { continue }
    foreach ($s in [AztTool.TexAudit]::Room($obj, $mtl, $RenderDir, $StretchK)) {
        if ($s.Area -le 0) { continue }
        $flags = @(); $sev = 0.0
        $rep = [Math]::Max($s.MaxSpanU, $s.MaxSpanV)
        if ($rep -ge 1.5) {
            $flags += ('REPEATS x{0:N0}' -f [Math]::Ceiling($rep))
            $e = Get-Edges $s.Leaf
            if ($e -and $e[6] -gt 12 -and $e[7] -lt 0.3) {      # (not cut-out art -- a rope or chain on black holes is meant to repeat so)
                $dark = @(); $seam = @()
                if ($s.MaxSpanV -ge 1.5) { if ($e[0] -lt 0.6) { $dark += 'top' }; if ($e[1] -lt 0.6) { $dark += 'bottom' }; if ($e[4] -gt 0.35) { $seam += 'top-bottom' } }
                if ($s.MaxSpanU -ge 1.5) { if ($e[2] -lt 0.6) { $dark += 'left' }; if ($e[3] -lt 0.6) { $dark += 'right' }; if ($e[5] -gt 0.35) { $seam += 'left-right' } }
                if ($dark.Count) { $flags += ('DARK EDGES ' + ($dark -join '/')); $sev += 3 * [Math]::Min(30.0, $rep) }
                if ($seam.Count) { $flags += ('SEAM ' + ($seam -join ', ')); $sev += 1.5 * [Math]::Min(30.0, $rep) }
            }
            $sev += [Math]::Min(30.0, $rep) * 0.2
        }
        $stretchShare = $s.StretchArea / $s.Area
        if ($stretchShare -ge 0.15) { $flags += ('STRETCHED {0:P0} of its area' -f $stretchShare); $sev += 10 * $stretchShare }
        if ($s.BadFaces -gt 0) { $flags += ('BAD UV {0} faces ({1:P0})' -f $s.BadFaces, ($s.BadArea / $s.Area)); $sev += 10 * ($s.BadArea / $s.Area) }
        if ($s.SmearFaces -gt 0) { $flags += ('SMEARED {0} faces ({1:P0})' -f $s.SmearFaces, ($s.SmearArea / $s.Area)); $sev += 10 * ($s.SmearArea / $s.Area) }
        if (-not $flags.Count) { continue }
        $rows.Add([pscustomobject]@{ Room = $room; Texture = $s.Leaf; Repeats = [Math]::Round($rep, 1); Stretched = [Math]::Round($stretchShare, 2); Smeared = $s.SmearFaces; BadUv = $s.BadFaces; Shear = [Math]::Round($s.MaxShear, 2); Flags = ($flags -join '; '); Severity = [Math]::Round($sev, 1) })
    }
}
"{0} rooms, {1} flagged texture uses, {2:N1} s" -f $Rooms.Count, $rows.Count, $t0.Elapsed.TotalSeconds
foreach ($k in 'REPEATS', 'DARK EDGES', 'SEAM', 'STRETCHED', 'SMEARED', 'BAD UV') { "  {0,-11} {1}" -f $k, @($rows | Where-Object { $_.Flags -match $k }).Count }
''
"the worst {0}:" -f $Top
$rows | Sort-Object Severity -Descending | Select-Object -First $Top Room, Texture, Repeats, Stretched, Smeared, BadUv, Shear, Flags | Format-Table -AutoSize | Out-String -Width 260
if ($Out) { $rows | Sort-Object Severity -Descending | Export-Csv -NoTypeInformation -Encoding UTF8 $Out; "report: $Out" }
if ($Sheet) {
    # each flagged repeating texture laid 2 x 2, as a face repeats it -- dark edges and seams show as a cross
    Add-Type -AssemblyName System.Drawing
    $pick = @($rows | Where-Object { $_.Flags -match 'DARK EDGES|SEAM' } | Sort-Object Severity -Descending | Select-Object -First 48)
    $done = @{}; $pick = @($pick | Where-Object { if ($done.ContainsKey($_.Texture)) { $false } else { $done[$_.Texture] = 1; $true } })
    $S = 220; $per = 6; $nr = [Math]::Max(1, [Math]::Ceiling($pick.Count / $per))
    $bm = New-Object Drawing.Bitmap ($per * ($S + 10) + 10), ($nr * ($S + 44) + 10); $g = [Drawing.Graphics]::FromImage($bm); $g.Clear([Drawing.Color]::FromArgb(24, 24, 24))
    $f = New-Object Drawing.Font('Segoe UI', 8)
    for ($i = 0; $i -lt $pick.Count; $i++) {
        $rw = $pick[$i]; $x = 10 + ($i % $per) * ($S + 10); $y = 10 + [Math]::Floor($i / $per) * ($S + 44)
        $p = Join-Path $Hires ((Get-ArtLeaf $rw.Texture) + '.png'); if (-not (Test-Path -LiteralPath $p)) { $p = Join-Path $RenderDir ($rw.Texture + '.png') }
        try { $im = [Drawing.Image]::FromFile($p); $h2 = $S / 2; for ($q = 0; $q -lt 4; $q++) { $g.DrawImage($im, $x + ($q % 2) * $h2, $y + [Math]::Floor($q / 2) * $h2, $h2, $h2) }; $im.Dispose() } catch { }
        $g.DrawString(('{0} ({1})' -f $rw.Texture, $rw.Room), $f, [Drawing.Brushes]::White, $x, $y + $S + 2)
        $g.DrawString(($rw.Flags -replace 'REPEATS ', 'x' -replace '; ', '  '), $f, [Drawing.Brushes]::Gold, $x, $y + $S + 16)
    }
    $bm.Save($Sheet); $g.Dispose(); $bm.Dispose(); "sheet: $Sheet"
}
if ($Twins) {
    # the rooms each leaf is in
    $use = @{}
    foreach ($m in Get-ChildItem -LiteralPath $RenderDir -Filter '*.mtl') {
        foreach ($l in [IO.File]::ReadLines($m.FullName)) {
            if (-not $l.StartsWith('map_Kd ')) { continue }
            $lf = [IO.Path]::GetFileNameWithoutExtension($l.Substring(7).Trim())
            if (-not $use[$lf]) { $use[$lf] = New-Object System.Collections.Generic.List[string] }; if (-not $use[$lf].Contains($m.BaseName)) { $use[$lf].Add($m.BaseName) }
        }
    }
    $mb = { param($leaf) $p = Join-Path $Hires "$leaf.png"; if (Test-Path -LiteralPath $p) { [Math]::Round((Get-Item -LiteralPath $p).Length / 1MB, 1) } else { 0.0 } }
    $list = New-Object System.Collections.Generic.List[object]
    # 1. what the loader does (TexTwins.cs): a leaf on the old upscale whose picture has new art under another leaf shows that art
    $pairs = @([AztTool.TexTwins]::LastPairs)
    foreach ($p in $pairs) {
        $list.Add([pscustomobject]@{ Leaf = $p.Leaf; Rooms = (@($use[$p.Leaf]) -join ' '); OwnMb = (& $mb $p.Leaf); Shows = $p.Twin; ShowsMb = (& $mb $p.Twin); ShowsRooms = (@($use[$p.Twin]) -join ' ')
            Status = $(if ($p.Flat) { 'flat colour: left on its own art' } else { 'twin''s new art (loader)' }); RoomsInCommon = $p.Score })
    }
    $on = @($pairs | Where-Object { -not $_.Flat })
    ''
    "SHARED ART: {0} leaves show a twin's new art through the loader; {1} of one flat colour left on their own" -f $on.Count, ($pairs.Count - $on.Count)
    "  index: " + [AztTool.TexTwins]::LastNote
    $per = @{}; foreach ($p in $on) { foreach ($rm in @($use[$p.Leaf])) { if ($rm) { $per[$rm] = 1 + [int]$per[$rm] } } }
    "  rooms with textures that now show a twin's new art: {0}" -f $per.Count
    $per.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 25 | ForEach-Object { "    {0,-9} {1}" -f $_.Key, $_.Value }
    # 2. CROSS-CHECK by the older rule, on the art each leaf now shows: a copy whose art is far smaller (3x) and older (2 days)
    # than its picture's largest replacement -- new art the loader does not reach (e.g. a redraw installed at exactly 4x)
    $md5 = [Security.Cryptography.MD5]::Create(); $byHash = @{}
    foreach ($f in [IO.Directory]::GetFiles($RenderDir, '*.png')) {
        $n = [IO.Path]::GetFileNameWithoutExtension($f); if ($n -notmatch '^\d\d-') { continue }
        $k = [BitConverter]::ToString($md5.ComputeHash([IO.File]::ReadAllBytes($f))); if (-not $byHash[$k]) { $byHash[$k] = New-Object System.Collections.Generic.List[string] }; $byHash[$k].Add($n)
    }
    $flat = @{}; foreach ($p in $pairs) { if ($p.Flat) { $flat[$p.Leaf] = 1 } }
    $stale = 0
    foreach ($g in $byHash.Values) {
        if ($g.Count -lt 2) { continue }
        $info = @($g | ForEach-Object { $p = Join-Path $Hires ((Get-ArtLeaf $_) + '.png'); if (Test-Path -LiteralPath $p) { $i = Get-Item -LiteralPath $p; [pscustomobject]@{ Leaf = $_; Mb = $i.Length / 1MB; Date = $i.LastWriteTime } } else { [pscustomobject]@{ Leaf = $_; Mb = 0.0; Date = [datetime]::MinValue } } })
        $new = $info | Sort-Object Mb -Descending | Select-Object -First 1
        foreach ($x in $info) {
            if ($x.Leaf -eq $new.Leaf -or $flat.ContainsKey($x.Leaf) -or $new.Mb -le 3 * [Math]::Max(0.01, $x.Mb) -or $new.Date -le $x.Date.AddDays(2)) { continue }
            $stale++
            $list.Add([pscustomobject]@{ Leaf = $x.Leaf; Rooms = (@($use[$x.Leaf]) -join ' '); OwnMb = [Math]::Round($x.Mb, 1); Shows = (Get-ArtLeaf $x.Leaf); ShowsMb = [Math]::Round($x.Mb, 1); ShowsRooms = ''
                Status = ('OUT OF STEP: {0} ({1:N1} MB, {2:yyyy-MM-dd}) is new art the loader does not reach' -f $new.Leaf, $new.Mb, $new.Date); RoomsInCommon = '' })
        }
    }
    "  still OUT OF STEP by the older rule (art > 3x smaller and > 2 days older than its picture's largest): {0}" -f $stale
    if ($stale) { $list | Where-Object { $_.Status -like 'OUT OF STEP*' } | Format-Table Leaf, Rooms, Status -AutoSize | Out-String -Width 220 }
    if ($TwinsOut) { $list | Export-Csv -NoTypeInformation -Encoding UTF8 $TwinsOut; "  list: $TwinsOut" }
}
