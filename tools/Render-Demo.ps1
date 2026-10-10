# Render-Demo.ps1 -- a moving flythrough from the host renderer, written to an AVI.
#
#   .\tools\Render-Demo.ps1
#   .\tools\Render-Demo.ps1 -Name opening2 -Frames 240 -Fps 30
#
# Entirely OFFLINE. It takes a captured reference (room files + the camera you were
# standing at) and flies a path from there, so the demo is the real renderer on the real
# geometry at the real injection size -- not a mock-up.
#
# A still cannot show what a renderer is actually like. Texture swim, depth sorting,
# the fog moving over a surface and the near-plane clipping only exist in motion, and
# they are the things most likely to be wrong.
#
# MOVEMENT IS SYNTHETIC, not recorded. The camera walks forward along its own heading
# and then pans, because a recorded path would need the game running and the point of
# this tool is that it does not.
[CmdletBinding()]
param(
    [string]$Name = 'opening2',
    [string]$RefDir = 'C:\Games\azrael-render\ref',
    [string]$CacheDir = 'C:\Games\azrael-render',
    [string]$TexDir = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX',
    [string]$Palette = 'C:\Games\azrael-inject\azrael-palette.pal',
    [string]$Out = '',
    [int]$Frames = 180,
    [int]$Fps = 30,
    [double]$Walk = 420,            # units travelled over the walk segment
    [double]$PanDeg = 70,           # degrees swept over the pan segment
    # 50, MEASURED, not 60. 60 was an assumption carried through every tool. Matching the
    # host's drawn-pixel mask against the engine's own frame (tools\Tune-Geometry.ps1)
    # gives a sharp unimodal peak at 50.0 -- recall 91.5%, against 81.6% at 49, 83.0% at
    # 50.5 and 55-58% out at 60 -- and the horizontal profile shift lands on exactly 0
    # there. At 60 the host was aimed wrong, which is what made it paint a lit ceiling the
    # engine does not show, and made every earlier lighting comparison fit noise.
    [double]$Fov = 50,
    [int]$Scale = 2,                # 1 = full 1600x928; 2 halves it, for a sane file size
    # LIGHTING IS OPT-IN, AND MEASUREMENT SAYS LEAVE IT OFF.
    #
    # Scored against the engine's own frame from the same camera, over a sweep of fog
    # range, curve and ambient: NO LIGHTING scores 0.1749 and the best lit setting
    # 0.1750 -- and that "best" setting is fog at 6x the room span with ambient 1.0,
    # which is itself almost no lighting. This game's textures already have their
    # lighting painted in, so a second pass over the top can only move it away from
    # the engine.
    #
    # The shade table stays in the renderer: it costs one lookup per pixel and is what
    # a torch, a muzzle flash or a dynamic object would need. It is simply not what a
    # static room needs.
    [switch]$Light,
    [int]$ShadeLevels = 32,
    [double]$FogScale = 1.6,
    [double]$FogNearFrac = 0.04,
    [double]$Ambient = 0.45,
    [double]$NormalLight = 0.25,
    [switch]$NoCull,
    [switch]$NoFlipV
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'Quantize.cs'), (Join-Path $toolDir 'AviWriter.cs')) `
         -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop
Add-Type -AssemblyName System.Drawing

$ref = Get-Content (Join-Path $RefDir ("{0}.json" -f $Name)) -Raw | ConvertFrom-Json
[int]$W = $ref.width; [int]$H = $ref.height
$rooms = @($ref.rooms)
if (-not $Out) { $Out = Join-Path $RefDir ("{0}-demo.avi" -f $Name) }
Write-Host ("demo: {0}  {1}x{2} -> {3}x{4}, {5} frames at {6} fps" -f `
    ($rooms -join ' + '), $W, $H, [int]($W/$Scale), [int]($H/$Scale), $Frames, $Fps)

# ---- geometry + textures (same rules as the live renderer) -------------------
$verts = New-Object System.Collections.Generic.List[single]
$uvs   = New-Object System.Collections.Generic.List[single]
$tris  = New-Object System.Collections.Generic.List[int]
$triMat = New-Object System.Collections.Generic.List[int]
$matNames = New-Object System.Collections.Generic.List[string]
$uvOf = @{}
foreach ($room in $rooms) {
    $obj = Join-Path $CacheDir ("{0}.obj" -f $room)
    # -IfStale, not Test-Path: a cached OBJ from an older exporter is worse than no cache,
    # because it silently keeps whatever that exporter got wrong at the time
    & (Join-Path $toolDir 'Export-XafObj.ps1') -Xaf $room -TexDir $TexDir -OutDir $CacheDir -IfStale | Out-Null
    if (-not (Test-Path $obj)) { throw "no geometry for $room" }
    $vBase = [int]($verts.Count/3); $tBase = [int]($uvs.Count/2); $curMat = -1
    foreach ($line in [IO.File]::ReadAllLines($obj)) {
        if ($line.Length -lt 2) { continue }
        if ($line[0] -eq 'v' -and $line[1] -eq ' ') {
            $p = $line.Substring(2).Trim() -split '\s+'
            $verts.Add([single]$p[0]); $verts.Add([single]$p[1]); $verts.Add([single]$p[2])
        } elseif ($line[0] -eq 'v' -and $line[1] -eq 't') {
            $p = $line.Substring(3).Trim() -split '\s+'
            $uvs.Add([single]$p[0]); $uvs.Add([single]$p[1])
        } elseif ($line.StartsWith('usemtl ')) {
            $key = "$room/" + $line.Substring(7).Trim()
            $curMat = $matNames.IndexOf($key)
            if ($curMat -lt 0) { $matNames.Add($key); $curMat = $matNames.Count - 1 }
        } elseif ($line[0] -eq 'f' -and $line[1] -eq ' ') {
            $vi = @(); $ti = @()
            foreach ($tok in ($line.Substring(2).Trim() -split '\s+')) {
                $parts = $tok -split '/'
                $vi += [int]$parts[0] - 1 + $vBase
                $ti += $(if ($parts.Count -ge 2 -and $parts[1]) { [int]$parts[1] - 1 + $tBase } else { -1 })
            }
            for ($c = 0; $c -lt $vi.Count; $c++) { if ($ti[$c] -ge 0) { $uvOf[$vi[$c]] = $ti[$c] } }
            for ($k = 1; $k -lt $vi.Count-1; $k++) { $tris.Add($vi[0]); $tris.Add($vi[$k]); $tris.Add($vi[$k+1]); $triMat.Add($curMat) }
        }
    }
}
$vArr = $verts.ToArray(); $tArr = $tris.ToArray()
$nv = [int]($vArr.Count/3); $uvArr = New-Object single[] ($nv*2)
for ($i = 0; $i -lt $nv; $i++) {
    $t = $(if ($uvOf.ContainsKey($i)) { $uvOf[$i] } else { -1 })
    if ($t -ge 0 -and ($t*2+1) -lt $uvs.Count) { $uvArr[$i*2] = $uvs[$t*2]; $uvArr[$i*2+1] = $uvs[$t*2+1] }
}
$pal = [IO.File]::ReadAllBytes((Resolve-Path $Palette).Path)
$mtlMap = @{}
foreach ($room in $rooms) {
    $mtl = Join-Path $CacheDir ("{0}.mtl" -f $room)
    if (-not (Test-Path $mtl)) { continue }
    $cur = $null
    foreach ($l in [IO.File]::ReadAllLines($mtl)) {
        $s = $l.Trim()
        if ($s.StartsWith('newmtl ')) { $cur = $s.Substring(7).Trim() }
        elseif ($s.StartsWith('map_Kd ') -and $cur) { $mtlMap["$room/$cur"] = $s.Substring(7).Trim() }
    }
}
$texes = @(); $matToTex = @{}
for ($mi = 0; $mi -lt $matNames.Count; $mi++) {
    $png = $(if ($mtlMap.ContainsKey($matNames[$mi])) { Join-Path $CacheDir $mtlMap[$matNames[$mi]] } else { $null })
    if (-not $png -or -not (Test-Path $png)) { $matToTex[$mi] = -1; continue }
    $bm = [System.Drawing.Bitmap]::FromFile($png); $tw = $bm.Width; $th = $bm.Height
    $cv = New-Object System.Drawing.Bitmap -ArgumentList $tw, $th, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gr = [System.Drawing.Graphics]::FromImage($cv); $gr.DrawImage($bm,0,0,$tw,$th); $gr.Dispose(); $bm.Dispose()
    $rc = New-Object System.Drawing.Rectangle -ArgumentList ([int]0),([int]0),$tw,$th
    $bd = $cv.LockBits($rc,[System.Drawing.Imaging.ImageLockMode]::ReadOnly,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $raw = New-Object byte[] ($tw*$th*4)
    [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0,$raw,0,$raw.Length)
    $cv.UnlockBits($bd); $cv.Dispose()
    $texes += (New-Object AztTool.Raster+Tex([LeTool.Quant]::Map($raw,$tw,$th,$pal,256,0,0,0), $tw, $th))
    $matToTex[$mi] = $texes.Count - 1
}
$SKIP_MATS = @('TRANSPARANT','ACTIVATION','BLACKCOVER')
$_fb = @(1..254 | ForEach-Object {
    $r3=$pal[$_*3]; $g3=$pal[$_*3+1]; $b3=$pal[$_*3+2]
    $mx=[Math]::Max($r3,[Math]::Max($g3,$b3)); $mn=[Math]::Min($r3,[Math]::Min($g3,$b3))
    [pscustomobject]@{ I=$_; L=(0.299*$r3+0.587*$g3+0.114*$b3); S=($mx-$mn) } } | Where-Object { $_.S -le 16 } | Sort-Object L)
$texes += (New-Object AztTool.Raster+Tex((New-Object byte[] 1), 1, 1))
$texes[$texes.Count-1].Idx[0] = [byte]$_fb[[int]($_fb.Count*0.20)].I
$fbIdx = $texes.Count - 1
$triTexArr = New-Object int[] ($triMat.Count)
for ($i = 0; $i -lt $triMat.Count; $i++) {
    $m = $triMat[$i]
    $nm = $(if ($m -ge 0) { ($matNames[$m] -split '/')[-1] } else { '' })
    if ($SKIP_MATS -contains $nm) { $triTexArr[$i] = -1 }
    elseif ($m -ge 0 -and $matToTex.ContainsKey($m) -and $matToTex[$m] -ge 0) { $triTexArr[$i] = $matToTex[$m] }
    else { $triTexArr[$i] = $fbIdx }
}

# ---- renderer ---------------------------------------------------------------
$r = New-Object AztTool.Raster($W, $H)
$r.SetVerticalFov($Fov); $r.NearZ = [single]0.5
if ($Light) {
    $lo = @([single]::MaxValue,[single]::MaxValue,[single]::MaxValue); $hi = @([single]::MinValue,[single]::MinValue,[single]::MinValue)
    for ($i = 0; $i -lt $vArr.Count; $i += 3) { for ($a=0;$a -lt 3;$a++) { $v=$vArr[$i+$a]; if($v -lt $lo[$a]){$lo[$a]=$v}; if($v -gt $hi[$a]){$hi[$a]=$v} } }
    $span = 0.0; for ($a=0;$a -lt 3;$a++) { $d=$hi[$a]-$lo[$a]; if ($d -gt $span) { $span=$d } }
    if ($span -le 0) { $span = 1000.0 }
    $r.SetShadeTable([AztTool.Raster]::BuildShadeTable($pal,$ShadeLevels), $ShadeLevels)
    $r.FogFar=[single]($span*$FogScale); $r.FogNear=[single]($span*$FogScale*$FogNearFrac)
    $r.Ambient=[single]$Ambient; $r.NormalLight=[single]$NormalLight
}

# the captured pose: rows 0..2 are right/up/forward, row 3 the position
$cam = @(0..15 | ForEach-Object { [double]$ref.camera[$_] })
$rx=$cam[0];$ry=$cam[1];$rz=$cam[2]
$ux=$cam[4];$uy=$cam[5];$uz=$cam[6]
$fx=$cam[8];$fy=$cam[9];$fz=$cam[10]
$px=$cam[12];$py=$cam[13];$pz=$cam[14]

[int]$ow = [int]($W/$Scale); [int]$oh = [int]($H/$Scale)
$avi = New-Object AztTool.AviWriter -ArgumentList $Out, $ow, $oh, $Fps, $false, 0, 0
$frame = New-Object System.Drawing.Bitmap -ArgumentList $W, $H, ([System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
$cp = $frame.Palette
for ($i = 0; $i -lt 256; $i++) { $cp.Entries[$i] = [System.Drawing.Color]::FromArgb(255,$pal[$i*3],$pal[$i*3+1],$pal[$i*3+2]) }
$frame.Palette = $cp
$rcF = New-Object System.Drawing.Rectangle -ArgumentList ([int]0),([int]0),$W,$H
$m = New-Object single[] 16
$sw = [Diagnostics.Stopwatch]::StartNew(); $totalMs = 0.0
try {
    for ($f = 0; $f -lt $Frames; $f++) {
        $t = $f / [double]($Frames - 1)
        # Half the run walks forward, half pans -- forward motion shows depth sorting and
        # fog, rotation shows texture stability. One or the other alone hides half of it.
        if ($t -lt 0.5) { $adv = ($t/0.5) * $Walk; $yaw = 0.0 }
        else            { $adv = $Walk;            $yaw = (($t-0.5)/0.5) * $PanDeg * [Math]::PI/180.0 }
        $cx2 = $px + $fx*$adv; $cy2 = $py + $fy*$adv; $cz2 = $pz + $fz*$adv
        # yaw about the camera's own up axis: forward and right rotate, up is fixed
        $cs = [Math]::Cos($yaw); $sn = [Math]::Sin($yaw)
        $nfx = $fx*$cs + $rx*$sn; $nfy = $fy*$cs + $ry*$sn; $nfz = $fz*$cs + $rz*$sn
        $nrx = $rx*$cs - $fx*$sn; $nry = $ry*$cs - $fy*$sn; $nrz = $rz*$cs - $fz*$sn
        $vals = @($nrx,$nry,$nrz,0, $ux,$uy,$uz,0, $nfx,$nfy,$nfz,0, $cx2,$cy2,$cz2,1)
        for ($i = 0; $i -lt 16; $i++) { $m[$i] = [single]$vals[$i] }
        $r.SetCameraWorld($m); $r.Clear([byte]0)
        $t0 = $sw.Elapsed.TotalMilliseconds
        $r.DrawTextured($vArr,$uvArr,$tArr,$triTexArr,[AztTool.Raster+Tex[]]$texes,(-not $NoCull),(-not $NoFlipV))
        $totalMs += ($sw.Elapsed.TotalMilliseconds - $t0)
        $bd = $frame.LockBits($rcF,[System.Drawing.Imaging.ImageLockMode]::WriteOnly,[System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
        for ($y = 0; $y -lt $H; $y++) { [System.Runtime.InteropServices.Marshal]::Copy($r.Color, ($y*$W), [IntPtr]($bd.Scan0.ToInt64()+$y*$bd.Stride), $W) }
        $frame.UnlockBits($bd)
        if ($Scale -eq 1) { $avi.AddFrame($frame, 90) }
        else {
            $small = New-Object System.Drawing.Bitmap -ArgumentList $ow, $oh, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
            $g2 = [System.Drawing.Graphics]::FromImage($small)
            $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g2.DrawImage($frame, [int]0, [int]0, $ow, $oh); $g2.Dispose()
            $avi.AddFrame($small, 90); $small.Dispose()
        }
        if (($f % 30) -eq 0) { Write-Host ("  frame {0}/{1}" -f $f, $Frames) }
    }
}
finally { $avi.Close(); $frame.Dispose() }
Write-Host ("rasteriser mean {0:N2} ms/frame over {1} frames" -f ($totalMs/$Frames), $Frames)
Write-Host ("wrote {0}  ({1:N1} MB)" -f $Out, ((Get-Item $Out).Length/1MB))
