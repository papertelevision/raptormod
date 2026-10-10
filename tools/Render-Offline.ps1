# Render-Offline.ps1 -- prove the rasteriser WITHOUT the game running.
#
#   .\tools\Render-Offline.ps1 -Xaf 256ROOM
#   .\tools\Render-Offline.ps1 -Obj C:\Games\azrael-models\lurka\LURKA.obj
#   .\tools\Render-Offline.ps1 -Xaf 256ROOM -Fov 70 -Orbit 4
#
# Nothing is injected and nothing is read from a live process. A .XAF (or an OBJ) goes in,
# a PNG comes out, rendered through the CAPTURED GAME PALETTE so the picture shows what
# the game would actually be able to display -- not a 24-bit render that would flatter the
# result and hide the 8-bit ceiling.
#
# WHY OFFLINE FIRST. The two things most likely to be wrong in a new renderer -- which way
# the camera looks and which way triangles wind -- are invisible in any statistic and
# obvious in a picture. Wiring this to the live camera before looking at one frame would
# mean debugging the transform, the projection, the winding and the bridge all at once.
#
# -Orbit N renders N views from around the model, which is how a handedness or winding
# error is caught: a model that looks plausible head-on reads as inside-out from the side.
[CmdletBinding()]
param(
    [string]$Xaf,
    [string]$Obj,
    [string]$TexDir  = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX',
    [string]$OutDir  = 'C:\Games\azrael-render',
    [string]$Palette = 'C:\Games\azrael-inject\azrael-palette.pal',
    [string]$Manifest = "$PSScriptRoot\..\AztMod.manifest.json",
    [int]$Width  = 0,          # 0 = take the real injection size from the manifest
    [int]$Height = 0,
    # 50, MEASURED, not 60. 60 was an assumption carried through every tool. Matching the
    # host's drawn-pixel mask against the engine's own frame (tools\Tune-Geometry.ps1)
    # gives a sharp unimodal peak at 50.0 -- recall 91.5%, against 81.6% at 49, 83.0% at
    # 50.5 and 55-58% out at 60 -- and the horizontal profile shift lands on exactly 0
    # there. At 60 the host was aimed wrong, which is what made it paint a lit ceiling the
    # engine does not show, and made every earlier lighting comparison fit noise.
    [double]$Fov = 50,
    [int]$Orbit  = 1,
    [int]$UpAxis = 1,          # the game is Y-UP
    [switch]$Inside,           # camera INSIDE the model, panning -- the real case for a room
    # OBJ's V axis runs the opposite way to a bitmap's rows, so textures flip unless this
    # is applied. Declared explicitly: an undeclared switch is $null, `-not $null` is
    # TRUE, and the flip would silently always be on -- the same phantom-variable trap
    # that left $INJ_X untested in the build for months.
    [switch]$NoFlipV,
    [switch]$NoCull,
    # ---- lighting (see Raster.BuildShadeTable) -------------------------------
    [int]$ShadeLevels = 32,
    [double]$FogNear = 60,
    [double]$FogFar  = 900,
    [double]$Ambient = 0.30,
    [double]$NormalLight = 0.35,
    [switch]$NoLight,
    [int]$Threads = 0
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'Quantize.cs')) -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $OutDir | Out-Null

if (-not $Xaf -and -not $Obj) { throw 'pass -Xaf <name> or -Obj <path>' }

# ---- the frame size is the REAL one ----------------------------------------
if ($Width -le 0 -or $Height -le 0) {
    $man = Get-Content (Resolve-Path $Manifest).Path -Raw | ConvertFrom-Json
    if (-not $man.view) { throw 'the manifest has no view section -- rebuild' }
    $Width = [int]$man.view.injW; $Height = [int]$man.view.injH
}
Write-Host ("rendering at {0}x{1}, the real injection size" -f $Width, $Height)

# ---- geometry ---------------------------------------------------------------
if ($Xaf) {
    $Obj = Join-Path $OutDir ("{0}.obj" -f $Xaf)
    if (-not (Test-Path $Obj)) {
        Write-Host ("exporting {0}.XAF -> {1}" -f $Xaf, (Split-Path $Obj -Leaf))
        & (Join-Path $toolDir 'Export-XafObj.ps1') -Xaf $Xaf -TexDir $TexDir -OutDir $OutDir | Out-Null
    }
    if (-not (Test-Path $Obj)) { throw "the exporter did not produce $Obj" }
}
if (-not (Test-Path $Obj)) { throw "no such OBJ: $Obj" }

# A deliberately small OBJ reader: positions and faces only. Triangulated by fanning,
# which is correct for the convex polygons a .XAF holds. Normals and UVs are skipped --
# shading here is per-face from the geometry, and textures are the NEXT stage.
$verts = New-Object System.Collections.Generic.List[single]
$uvs   = New-Object System.Collections.Generic.List[single]
$tris  = New-Object System.Collections.Generic.List[int]
$triMat = New-Object System.Collections.Generic.List[int]
$matNames = New-Object System.Collections.Generic.List[string]
$curMat = -1
$nFaceLines = 0
foreach ($line in [IO.File]::ReadAllLines((Resolve-Path $Obj).Path)) {
    if ($line.Length -lt 2) { continue }
    if ($line[0] -eq 'v' -and $line[1] -eq ' ') {
        $p = $line.Substring(2).Trim() -split '\s+'
        $verts.Add([single]$p[0]); $verts.Add([single]$p[1]); $verts.Add([single]$p[2])
    } elseif ($line[0] -eq 'v' -and $line[1] -eq 't') {
        $p = $line.Substring(3).Trim() -split '\s+'
        $uvs.Add([single]$p[0]); $uvs.Add([single]$p[1])
    } elseif ($line.StartsWith('usemtl ')) {
        $n = $line.Substring(7).Trim()
        $curMat = $matNames.IndexOf($n)
        if ($curMat -lt 0) { $matNames.Add($n); $curMat = $matNames.Count - 1 }
    } elseif ($line[0] -eq 'f' -and $line[1] -eq ' ') {
        $nFaceLines++
        $f = $line.Substring(2).Trim() -split '\s+'
        $vi = @()
        foreach ($tok in $f) { $vi += [int](($tok -split '/')[0]) - 1 }   # OBJ is 1-based
        for ($k = 1; $k -lt $vi.Count - 1; $k++) {
            $tris.Add($vi[0]); $tris.Add($vi[$k]); $tris.Add($vi[$k+1])
            $triMat.Add($curMat)
        }
    }
}
$vArr = $verts.ToArray(); $tArr = $tris.ToArray(); $uvArr = $uvs.ToArray()
# The .XAF format runs texture_coordinates PARALLEL TO VERTICES, so the UV index is the
# vertex index and the exporter writes them one-for-one. If that ever stops being true
# the UVs would silently belong to the wrong vertices, so it is checked rather than assumed.
$texturedOK = ($uvArr.Count -eq ($vArr.Count / 3) * 2) -and ($matNames.Count -gt 0)
if ($uvArr.Count -gt 0 -and -not $texturedOK) {
    Write-Host ("UV count {0} does not match {1} vertices -- falling back to flat shading" -f ($uvArr.Count/2), ($vArr.Count/3)) -ForegroundColor Yellow
}
$nv = [int]($vArr.Count / 3); $nt = [int]($tArr.Count / 3)
Write-Host ("{0:N0} vertices, {1:N0} face lines -> {2:N0} triangles" -f $nv, $nFaceLines, $nt)
if ($nt -eq 0) { throw 'no triangles -- the OBJ has no faces this reader understood' }

# bounds, so the camera can be placed without guessing at the model's scale
$lo = @([single]::MaxValue, [single]::MaxValue, [single]::MaxValue)
$hi = @([single]::MinValue, [single]::MinValue, [single]::MinValue)
for ($i = 0; $i -lt $vArr.Count; $i += 3) {
    for ($a = 0; $a -lt 3; $a++) {
        if ($vArr[$i+$a] -lt $lo[$a]) { $lo[$a] = $vArr[$i+$a] }
        if ($vArr[$i+$a] -gt $hi[$a]) { $hi[$a] = $vArr[$i+$a] }
    }
}
$ctr = @(0,0,0); $span = 0
for ($a = 0; $a -lt 3; $a++) { $ctr[$a] = ($lo[$a]+$hi[$a])/2; $d = $hi[$a]-$lo[$a]; if ($d -gt $span) { $span = $d } }
Write-Host ("bounds x {0:N1}..{1:N1}  y {2:N1}..{3:N1}  z {4:N1}..{5:N1}   span {6:N1}" -f `
    $lo[0],$hi[0],$lo[1],$hi[1],$lo[2],$hi[2],$span)

# ---- the shade ramp, out of the CAPTURED palette ---------------------------
# Indices 1..254 only: 0 and 255 are BOTH BLACK in this game and three separate probes
# have been lost to that. A single hue family is chosen and sorted by luminance so the
# ramp reads as lighting rather than as a colour wheel.
if (-not (Test-Path $Palette)) { throw "need the captured palette at $Palette -- see Capture-Palette.ps1" }
$pal = [IO.File]::ReadAllBytes((Resolve-Path $Palette).Path)
if ($pal.Length -lt 768) { throw "$Palette is only $($pal.Length) bytes" }
$cand = 1..254 | ForEach-Object {
    $r = $pal[$_*3]; $g = $pal[$_*3+1]; $b = $pal[$_*3+2]
    $mx = [Math]::Max($r, [Math]::Max($g,$b)); $mn = [Math]::Min($r, [Math]::Min($g,$b))
    [pscustomobject]@{ I = $_; L = (0.299*$r + 0.587*$g + 0.114*$b); Sat = ($mx - $mn) }
}
# near-neutral entries make the cleanest lighting ramp: a saturated ramp would tint the
# whole room a colour the artwork never had
$ramp = @($cand | Where-Object { $_.Sat -le 40 } | Sort-Object L | ForEach-Object { [byte]$_.I })
if ($ramp.Count -lt 8) { $ramp = @($cand | Sort-Object L | ForEach-Object { [byte]$_.I }) }
# thin it to ~24 steps so adjacent faces differ visibly
$step = [Math]::Max(1, [int]($ramp.Count / 24))
$ramp = @(0..([int](($ramp.Count-1)/$step)) | ForEach-Object { $ramp[$_ * $step] })
$bg = [byte]$ramp[0]
Write-Host ("shade ramp: {0} steps, indices {1} .. {2}; background {3}" -f $ramp.Count, $ramp[0], $ramp[$ramp.Count-1], $bg)

# ---- textures, reduced to palette indices ONCE ------------------------------
# This is the step that makes the per-frame cost nothing: every texture is mapped into
# the game's own 256 colours at load, so the inner loop reads a byte and writes a byte.
# A renderer that quantised per frame would be converting 1.48 million pixels a frame to
# produce exactly the same result.
$texes = @(); $matToTex = @{}
if ($texturedOK) {
    $mtlPath = [IO.Path]::ChangeExtension($Obj, '.mtl')
    $mtlMap = @{}
    if (Test-Path $mtlPath) {
        $cur = $null
        foreach ($l in [IO.File]::ReadAllLines($mtlPath)) {
            $s = $l.Trim()
            if ($s.StartsWith('newmtl ')) { $cur = $s.Substring(7).Trim() }
            elseif ($s.StartsWith('map_Kd ') -and $cur) { $mtlMap[$cur] = $s.Substring(7).Trim() }
        }
    }
    $objDir = Split-Path $Obj -Parent
    for ($mi = 0; $mi -lt $matNames.Count; $mi++) {
        $nm = $matNames[$mi]
        $png = $(if ($mtlMap.ContainsKey($nm)) { Join-Path $objDir $mtlMap[$nm] } else { $null })
        if (-not $png -or -not (Test-Path $png)) { $matToTex[$mi] = -1; continue }
        $bm = [System.Drawing.Bitmap]::FromFile($png)
        $tw = $bm.Width; $th = $bm.Height
        $conv = New-Object System.Drawing.Bitmap($tw, $th, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $gr = [System.Drawing.Graphics]::FromImage($conv); $gr.DrawImage($bm, 0, 0, $tw, $th); $gr.Dispose(); $bm.Dispose()
        $rc = New-Object System.Drawing.Rectangle(0,0,$tw,$th)
        $bd = $conv.LockBits($rc, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $raw = New-Object byte[] ($tw*$th*4)
        [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $raw, 0, $raw.Length)
        $conv.UnlockBits($bd); $conv.Dispose()
        # dither 0: a dithered wall pattern crawls as the camera moves, which looks far
        # worse in motion than the banding it removes
        $idxMap = [LeTool.Quant]::Map($raw, $tw, $th, $pal, 256, 0, 0, 0)
        $texes += (New-Object AztTool.Raster+Tex($idxMap, $tw, $th))
        $matToTex[$mi] = $texes.Count - 1
    }
    Write-Host ("{0} materials -> {1} textures quantised into the game palette" -f $matNames.Count, $texes.Count)
}

# ---- render -----------------------------------------------------------------
$r = New-Object AztTool.Raster($Width, $Height)
if ($Threads -gt 0) { $r.Threads = $Threads }
$r.SetVerticalFov($Fov)
$r.NearZ = [single]([Math]::Max(0.05, $span / 2000.0))
if (-not $NoLight) {
    # FOG DISTANCES SCALE WITH THE MODEL. A room spans hundreds of units and a character
    # tens, so a fixed FogFar would black out a creature entirely and leave a room flat.
    # The defaults are tuned for a room; anything much smaller gets them scaled down.
    $scale = [Math]::Max(0.05, $span / 900.0)
    $r.SetShadeTable([AztTool.Raster]::BuildShadeTable($pal, $ShadeLevels), $ShadeLevels)
    $r.FogNear = [single]($FogNear * $scale)
    $r.FogFar  = [single]($FogFar * $scale)
    $r.Ambient = [single]$Ambient
    $r.NormalLight = [single]$NormalLight
    Write-Host ("lighting: {0} levels, fog {1:N0}..{2:N0}, ambient {3:N2}, normal {4:N2}" -f `
        $ShadeLevels, $r.FogNear, $r.FogFar, $Ambient, $NormalLight)
}
Write-Host ("fov {0}deg, nearZ {1:N3}, threads {2}" -f $Fov, $r.NearZ, $r.Threads)

# one texture index per triangle, resolved from the material groups
$triTexArr = New-Object int[] ($triMat.Count)
for ($i = 0; $i -lt $triMat.Count; $i++) {
    $m = $triMat[$i]
    $triTexArr[$i] = $(if ($m -ge 0 -and $matToTex.ContainsKey($m)) { $matToTex[$m] } else { -1 })
}
$withTex = @($triTexArr | Where-Object { $_ -ge 0 }).Count
if ($texturedOK -and $texes.Count -gt 0) {
    Write-Host ("{0:N0} of {1:N0} triangles have a texture" -f $withTex, $triTexArr.Count)
    if ($withTex -eq 0) { throw 'no triangle resolved to a texture -- the material mapping is broken' }
}

$dist = $span * 1.1
# WARM-UP, discarded. The first DrawTriangles call pays JIT and Parallel.For start-up
# and measured 9.8 ms against 0.8 ms for identical work on the next view -- a 12x lie
# about the renderer's speed if the first view is the one reported.
$r.Clear($bg)
$r.LookAt([single]($ctr[0]+$dist),[single]$ctr[1],[single]$ctr[2], [single]$ctr[0],[single]$ctr[1],[single]$ctr[2], $UpAxis)
if ($texturedOK -and $texes.Count -gt 0) { $r.DrawTextured($vArr, $uvArr, $tArr, $triTexArr, [AztTool.Raster+Tex[]]$texes, (-not $NoCull), (-not $NoFlipV)) } else { $r.DrawTriangles($vArr, $tArr, [byte[]]$ramp, [single]0.3, [single]1.0, [single]0.5, (-not $NoCull)) }

$outs = @()
for ($o = 0; $o -lt $Orbit; $o++) {
    $ang = [Math]::PI * 2 * $o / [Math]::Max(1,$Orbit)
    $r.Clear($bg)
    if ($Inside) {
        # STANDING IN THE ROOM, PANNING. An exterior orbit of an interior space is
        # nearly useless: the near wall occludes the room and 90 of 645 triangles
        # survive. From the middle, looking outward, is what the player actually sees
        # and what the live camera will do.
        #
        # Eye height is a FRACTION of the model, not a constant: rooms here span
        # hundreds of units and a fixed height would be on the floor in one and in the
        # ceiling in another.
        $eh = $lo[$UpAxis] + ($hi[$UpAxis] - $lo[$UpAxis]) * 0.45
        switch ($UpAxis) {
            1 { $ex = $ctr[0]; $ey = $eh; $ez = $ctr[2]
                $tx = $ctr[0] + [Math]::Sin($ang) * $span; $ty = $eh; $tz = $ctr[2] + [Math]::Cos($ang) * $span }
            default { $ex = $ctr[0]; $ey = $ctr[1]; $ez = $eh
                $tx = $ctr[0] + [Math]::Sin($ang) * $span; $ty = $ctr[1] + [Math]::Cos($ang) * $span; $tz = $eh }
        }
        $r.LookAt([single]$ex,[single]$ey,[single]$ez, [single]$tx,[single]$ty,[single]$tz, $UpAxis)
    } else {
        switch ($UpAxis) {
            0 { $ex = $ctr[0]; $ey = $ctr[1] + $dist*[Math]::Cos($ang); $ez = $ctr[2] + $dist*[Math]::Sin($ang) }
            1 { $ex = $ctr[0] + $dist*[Math]::Sin($ang); $ey = $ctr[1] + $span*0.15; $ez = $ctr[2] + $dist*[Math]::Cos($ang) }
            default { $ex = $ctr[0] + $dist*[Math]::Sin($ang); $ey = $ctr[1] + $dist*[Math]::Cos($ang); $ez = $ctr[2] }
        }
        $r.LookAt([single]$ex,[single]$ey,[single]$ez, [single]$ctr[0],[single]$ctr[1],[single]$ctr[2], $UpAxis)
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if ($texturedOK -and $texes.Count -gt 0) {
        $r.DrawTextured($vArr, $uvArr, $tArr, $triTexArr, [AztTool.Raster+Tex[]]$texes, (-not $NoCull), (-not $NoFlipV))
    } else {
        $r.DrawTriangles($vArr, $tArr, [byte[]]$ramp, [single]0.3, [single]1.0, [single]0.5, (-not $NoCull))
    }
    $sw.Stop()

    $cov = 0; $c = $r.Color
    for ($i = 0; $i -lt $c.Length; $i++) { if ($c[$i] -ne $bg) { $cov++ } }
    Write-Host ("view {0}: {1:N1} ms  ({2:N0} fps)  triangles drawn {3:N0}/{4:N0}, culled {5:N0}, coverage {6:P1}" -f `
        $o, $sw.Elapsed.TotalMilliseconds, (1000.0/[Math]::Max(0.01,$sw.Elapsed.TotalMilliseconds)), `
        $r.TrisDrawn, $r.TrisIn, $r.TrisCulled, ($cov / [double]$c.Length))

    # PNG through the game's palette -- the point is to see what the game could show
    $bmp = New-Object System.Drawing.Bitmap($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
    $cp = $bmp.Palette
    for ($i = 0; $i -lt 256; $i++) { $cp.Entries[$i] = [System.Drawing.Color]::FromArgb(255, $pal[$i*3], $pal[$i*3+1], $pal[$i*3+2]) }
    $bmp.Palette = $cp
    $rect = New-Object System.Drawing.Rectangle(0,0,$Width,$Height)
    $d = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
    for ($y = 0; $y -lt $Height; $y++) {
        [System.Runtime.InteropServices.Marshal]::Copy($c, $y*$Width, [IntPtr]($d.Scan0.ToInt64() + $y*$d.Stride), $Width)
    }
    $bmp.UnlockBits($d)
    # -LeafBase is PowerShell 6+. This box is Windows PowerShell 5.1.
    $stem = [IO.Path]::GetFileNameWithoutExtension($Obj)
    $name = if ($Orbit -gt 1) { "render-{0}-{1:d2}.png" -f $stem, $o } else { "render-{0}.png" -f $stem }
    $p = Join-Path $OutDir $name
    $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    $outs += $p
}
Write-Host ''
Write-Host 'wrote:'
$outs | ForEach-Object { Write-Host ("  " + $_) }
