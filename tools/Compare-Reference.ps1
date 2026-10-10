# Compare-Reference.ps1 -- render a captured reference OFFLINE and put the two side by
# side, so the renderer can be tuned without the game running.
#
#   .\tools\Compare-Reference.ps1
#   .\tools\Compare-Reference.ps1 -Ambient 0.6 -FogScale 2.5 -NoLight
#
# Takes what Capture-Reference wrote -- room files, the exact camera, and the ENGINE's
# own frame from that camera -- and renders the same view with the host rasteriser. The
# output is one image: engine on top, host below, same size, same palette.
#
# THE POINT IS THE COMPARISON, not the render. A host frame on its own always looks
# plausible; it is only against the engine's frame from the SAME camera that a wrong
# field of view, a wrong brightness or a missing surface becomes obvious.
[CmdletBinding()]
param(
    [string]$Name = 'opening',
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
    [switch]$NoLight,
    [int]$ShadeLevels = 32,
    [double]$FogScale = 1.6,
    [double]$FogNearFrac = 0.04,
    [double]$Ambient = 0.45,
    [double]$NormalLight = 0.25,
    [switch]$NoCull,
    [switch]$NoFlipV,
    [string]$Tag = ''
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'Quantize.cs')) -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop
Add-Type -AssemblyName System.Drawing

$ref = Get-Content (Join-Path $RefDir ("{0}.json" -f $Name)) -Raw | ConvertFrom-Json
$W = [int]$ref.width; $H = [int]$ref.height
$rooms = @($ref.rooms)
Write-Host ("reference '{0}': {1}  camera {2:N1} {3:N1} {4:N1}" -f $Name, ($rooms -join ' + '), $ref.pos[0], $ref.pos[1], $ref.pos[2])

# ---- geometry, merged across the room's files (same rules as the live renderer) ----
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
    $vBase = [int]($verts.Count / 3); $tBase = [int]($uvs.Count / 2); $curMat = -1
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
            for ($k = 1; $k -lt $vi.Count - 1; $k++) { $tris.Add($vi[0]); $tris.Add($vi[$k]); $tris.Add($vi[$k+1]); $triMat.Add($curMat) }
        }
    }
}
$vArr = $verts.ToArray(); $tArr = $tris.ToArray()
$nv = [int]($vArr.Count/3); $uvArr = New-Object single[] ($nv*2)
for ($i = 0; $i -lt $nv; $i++) {
    $t = $(if ($uvOf.ContainsKey($i)) { $uvOf[$i] } else { -1 })
    if ($t -ge 0 -and ($t*2+1) -lt $uvs.Count) { $uvArr[$i*2] = $uvs[$t*2]; $uvArr[$i*2+1] = $uvs[$t*2+1] }
}

# ---- textures ---------------------------------------------------------------
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
    $cv = New-Object System.Drawing.Bitmap($tw, $th, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gr = [System.Drawing.Graphics]::FromImage($cv); $gr.DrawImage($bm,0,0,$tw,$th); $gr.Dispose(); $bm.Dispose()
    $rc = New-Object System.Drawing.Rectangle(0,0,$tw,$th)
    $bd = $cv.LockBits($rc,[System.Drawing.Imaging.ImageLockMode]::ReadOnly,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $raw = New-Object byte[] ($tw*$th*4)
    [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0,$raw,0,$raw.Length)
    $cv.UnlockBits($bd); $cv.Dispose()
    $texes += (New-Object AztTool.Raster+Tex([LeTool.Quant]::Map($raw,$tw,$th,$pal,256,0,0,0), $tw, $th))
    $matToTex[$mi] = $texes.Count - 1
}
# ---- MATERIALS THAT ARE NOT SUPPOSED TO BE SEEN ----------------------------
# The game marks its invisible volumes in the material name. TRANSPARANT and ACTIVATION
# are trigger surfaces -- the same materials carried by the zx*/zy* objects AZONES.DAT
# lists as room portals -- and BLACKCOVER is a masking quad. The engine does not draw
# them.
#
# Drawing them is not a small error: the 17 TRANSPARANT faces in this room are large
# quads lying across the floor, so painting them flat covered a third of the screen in
# one colour. A face with no texture is not automatically a face that needs one.
$SKIP_MATS = @('TRANSPARANT','ACTIVATION','BLACKCOVER')
# The flat ink is for genuinely untextured GEOMETRY (MINEHEAD's `stuff` and `minechasm`
# are real surfaces with no material). Picked DARK and strictly neutral: the previous
# mid-luminance pick landed on a pink and made every such face obvious.
$_fb = @(1..254 | ForEach-Object {
    $r3=$pal[$_*3]; $g3=$pal[$_*3+1]; $b3=$pal[$_*3+2]
    $mx=[Math]::Max($r3,[Math]::Max($g3,$b3)); $mn=[Math]::Min($r3,[Math]::Min($g3,$b3))
    [pscustomobject]@{ I=$_; L=(0.299*$r3+0.587*$g3+0.114*$b3); S=($mx-$mn) } } | Where-Object { $_.S -le 16 } | Sort-Object L)
if ($_fb.Count -lt 4) { $_fb = @(1..254 | ForEach-Object { [pscustomobject]@{ I=$_; L=(0.299*$pal[$_*3]+0.587*$pal[$_*3+1]+0.114*$pal[$_*3+2]) } } | Sort-Object L) }
$texes += (New-Object AztTool.Raster+Tex((New-Object byte[] 1), 1, 1))
$fbInk = [byte]$_fb[[int]($_fb.Count*0.20)].I
$texes[$texes.Count-1].Idx[0] = $fbInk
$fbIdx = $texes.Count - 1
$triTexArr = New-Object int[] ($triMat.Count)
$untex = 0; $skipped = 0
for ($i = 0; $i -lt $triMat.Count; $i++) {
    $m = $triMat[$i]
    $nm = $(if ($m -ge 0) { ($matNames[$m] -split '/')[-1] } else { '' })
    if ($SKIP_MATS -contains $nm) { $triTexArr[$i] = -1; $skipped++ }   # -1 = not drawn
    elseif ($m -ge 0 -and $matToTex.ContainsKey($m) -and $matToTex[$m] -ge 0) { $triTexArr[$i] = $matToTex[$m] }
    else { $triTexArr[$i] = $fbIdx; $untex++ }
}
Write-Host ("{0:N0} triangles, {1} textures, {2:N0} flat (ink {3}), {4:N0} skipped as invisible" -f `
    ($tArr.Count/3), ($texes.Count-1), $untex, $fbInk, $skipped)

# ---- render -----------------------------------------------------------------
$r = New-Object AztTool.Raster($W, $H)
$r.SetVerticalFov($Fov)
$r.NearZ = [single]0.5
if (-not $NoLight) {
    $lo = @([single]::MaxValue,[single]::MaxValue,[single]::MaxValue); $hi = @([single]::MinValue,[single]::MinValue,[single]::MinValue)
    for ($i = 0; $i -lt $vArr.Count; $i += 3) { for ($a=0;$a -lt 3;$a++) { $v=$vArr[$i+$a]; if($v -lt $lo[$a]){$lo[$a]=$v}; if($v -gt $hi[$a]){$hi[$a]=$v} } }
    $span = 0.0; for ($a=0;$a -lt 3;$a++) { $d=$hi[$a]-$lo[$a]; if ($d -gt $span) { $span = $d } }
    if ($span -le 0) { $span = 1000.0 }
    $r.SetShadeTable([AztTool.Raster]::BuildShadeTable($pal, $ShadeLevels), $ShadeLevels)
    $r.FogFar = [single]($span*$FogScale); $r.FogNear = [single]($span*$FogScale*$FogNearFrac)
    $r.Ambient = [single]$Ambient; $r.NormalLight = [single]$NormalLight
    Write-Host ("lighting: span {0:N0}, fog {1:N0}..{2:N0}, ambient {3:N2}, normal {4:N2}" -f $span, $r.FogNear, $r.FogFar, $Ambient, $NormalLight)
} else { Write-Host 'lighting OFF' }

$m = New-Object single[] 16
for ($i = 0; $i -lt 16; $i++) { $m[$i] = [single]$ref.camera[$i] }
$r.SetCameraWorld($m); $r.Clear([byte]0)
$sw = [Diagnostics.Stopwatch]::StartNew()
$r.DrawTextured($vArr, $uvArr, $tArr, $triTexArr, [AztTool.Raster+Tex[]]$texes, (-not $NoCull), (-not $NoFlipV))
$sw.Stop()
$cov = $r.CountNonBackground([byte]0)
Write-Host ("host render: {0:N1} ms, {1:N0}/{2:N0} triangles, coverage {3:P1}" -f `
    $sw.Elapsed.TotalMilliseconds, $r.TrisDrawn, $r.TrisIn, ($cov/[double]($W*$H)))

# ---- stack the two, engine above host ---------------------------------------
# The engine frame is OPTIONAL. It can only be captured with the game running, so when it
# is absent this still writes the host render on its own rather than throwing after having
# already done all the work -- the comparison is the point, but a host-only frame is worth
# more than an exception.
$enginePng = Join-Path $RefDir ("{0}-engine.png" -f $Name)
$eng = $(if (Test-Path $enginePng) { [System.Drawing.Bitmap]::FromFile($enginePng) } else { $null })
if (-not $eng) { Write-Host ("no {0} -- writing the host render alone" -f (Split-Path $enginePng -Leaf)) -ForegroundColor Yellow }
# EXPLICIT [int]s. $W and $H come from JSON, where ConvertFrom-Json hands back values
# that PowerShell will happily pass to a DIFFERENT Bitmap overload -- the one taking a
# stride and an IntPtr -- and the binder then complains about converting Object[] to
# UInt32, naming neither the real argument nor the real line.
[int]$wI = $W; [int]$hI = $H
$panes = $(if ($eng) { 2 } else { 1 })
$out = New-Object System.Drawing.Bitmap -ArgumentList $wI, ($hI*$panes), ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$gfx = [System.Drawing.Graphics]::FromImage($out)
$hostTop = 0
if ($eng) { $gfx.DrawImage($eng, [int]0, [int]0, $wI, $hI); $eng.Dispose(); $hostTop = $hI }
$hostBmp = New-Object System.Drawing.Bitmap -ArgumentList $wI, $hI, ([System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
$cp = $hostBmp.Palette
for ($i = 0; $i -lt 256; $i++) { $cp.Entries[$i] = [System.Drawing.Color]::FromArgb(255,$pal[$i*3],$pal[$i*3+1],$pal[$i*3+2]) }
$hostBmp.Palette = $cp
$rc2 = New-Object System.Drawing.Rectangle -ArgumentList ([int]0), ([int]0), $wI, $hI
$bd2 = $hostBmp.LockBits($rc2,[System.Drawing.Imaging.ImageLockMode]::WriteOnly,[System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
for ($y = 0; $y -lt $hI; $y++) { [System.Runtime.InteropServices.Marshal]::Copy($r.Color, ($y*$wI), [IntPtr]($bd2.Scan0.ToInt64()+$y*$bd2.Stride), $wI) }
$hostBmp.UnlockBits($bd2)
$gfx.DrawImage($hostBmp, [int]0, [int]$hostTop, $wI, $hI)
$hostBmp.Dispose(); $gfx.Dispose()
$outPath = Join-Path $RefDir ("{0}-compare{1}.png" -f $Name, $Tag)
$out.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png); $out.Dispose()
Write-Host ("wrote {0}   {1}" -f $outPath, $(if ($hostTop) { '(engine on top, host below)' } else { '(host render only)' }))
