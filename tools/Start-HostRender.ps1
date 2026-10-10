# Start-HostRender.ps1 -- TIER A, the whole thing: the HOST draws the game's 3D view.
#
#   .\tools\Start-HostRender.ps1 -Xaf 256ROOM -Seconds 30
#   .\tools\Start-HostRender.ps1 -Xaf 256ROOM -Fov 70        # tune to match the engine
#   .\tools\Start-HostRender.ps1 -Restore                     # hand the viewport back
#
# Start the game first and stand in the room named by -Xaf. Nothing is launched here.
#
#   live camera (aztCamRec) -> host rasteriser -> staging buffer -> AztInjBody -> screen
#
# Every piece of that chain is separately proven: the camera record by Read-LiveCamera,
# the rasteriser by Render-Offline's PNGs, and the injection path with its handshake by
# Start-HostView. This joins them.
#
# THE ROOM IS A PARAMETER, not yet discovered from the game. The engine knows which room
# is loaded (the music cue at aztCamCue is a usable hint, and AZONES.DAT maps rooms to
# files), but guessing wrong would silently render the wrong geometry at the right camera
# -- which looks like a broken renderer rather than a wrong room. Naming it keeps the
# failure honest while the rest is being proven.
#
# WHICH MATRIX. camWorld has been observed STUCK AT IDENTITY for a whole session while the
# movement frame tracked correctly, so movWorld is the pose used. That is a recorded
# engine behaviour, not a bug here -- and it is checked at run time rather than trusted.
[CmdletBinding()]
param(
    # EMPTY MEANS DETECT IT. Naming the room by hand cost a run every single time: I
    # rendered ATUNNEL2 while the player was in the minehead, then MINEHEAD while they
    # were in SPAROOM. The camera is right and the geometry is elsewhere, which looks
    # like a frozen, jumbled renderer rather than the wrong file -- so it wastes the
    # run AND points the diagnosis in the wrong direction.
    [string]$Xaf = '',
    [int]$Seconds = 30,
    # 50, MEASURED, not 60. 60 was an assumption carried through every tool. Matching the
    # host's drawn-pixel mask against the engine's own frame (tools\Tune-Geometry.ps1)
    # gives a sharp unimodal peak at 50.0 -- recall 91.5%, against 81.6% at 49, 83.0% at
    # 50.5 and 55-58% out at 60 -- and the horizontal profile shift lands on exactly 0
    # there. At 60 the host was aimed wrong, which is what made it paint a lit ceiling the
    # engine does not show, and made every earlier lighting comparison fit noise.
    [double]$Fov = 50,
    [switch]$Restore,
    # Inject the KNOWN-VISIBLE test pattern instead of the render, in the same session,
    # through the same code. If the pattern appears and the render does not, the
    # difference is the CONTENT, not the injection path -- and that halves the search
    # space in one run instead of arguing about which stage is at fault.
    [switch]$TestPattern,
    # THE POINT OF THE WHOLE EXERCISE, and until now never actually exercised.
    #
    # AztFrameLimit SPINS until aztFramePeriod elapses, so with the cap in place every
    # millisecond the host renderer saves is handed straight back as busy-wait and the
    # game delivers its usual 22 fps. Every live run so far has been capped, which means
    # the decoupling has been proven to WORK without once being shown to be FASTER.
    #
    # MOVEMENT IS FRAME-TIED ($MOVE_SCALE is calibrated for 24 fps), so uncapped the
    # player moves far too fast. That is the next real piece of work, not a reason to
    # avoid measuring: stand still and watch the number.
    [switch]$Uncap,
    [switch]$NoSuppress,          # leave the engine's own 3D drawing underneath
    [switch]$NoFlipV,
    [switch]$NoCull,
    # ---- lighting ------------------------------------------------------------
    # DELIBERATELY GENTLER THAN THE OFFLINE DEFAULTS. Those put FogFar at roughly the
    # model's own span, so the far wall of a room went fully black and the unlit render
    # looked better than the lit one. Fog now reaches well past the room (x1.6) and the
    # ambient floor is higher, so distance reads as depth rather than as darkness.
    # LIGHTING IS OPT-IN. The old verdict here -- "measurement says leave it off", from
    # NO LIGHTING scoring 0.1749 against 0.1750 for the best lit setting -- came from a
    # BROKEN measurement and should not be trusted.
    #
    # That sweep excluded the background from its histogram and cropped the top strip, so
    # it could not see the one thing that actually differs: COVERAGE. The host draws ~2.3x
    # as many lit pixels as the engine. It was also scoring a render aimed at the wrong
    # field of view (60 rather than the measured 50), so it was fitting tone to misaligned
    # geometry. Both corrected in Tune-Lighting.ps1; re-measured, no-lighting scores 0.4447
    # against 0.2581 for the best lit setting -- lighting DOES matter.
    #
    # Those lit settings still overshoot (99.2% dark against the engine's 94.2%, and 0.00%
    # bright against its 0.3%), so the remaining gap is draw distance, not attenuation.
    # Off is still the safer default until that is settled -- but not because it measured
    # better.
    #
    # The shade table stays in the renderer: it costs one lookup per pixel and is what
    # a torch, a muzzle flash or a dynamic object would need. It is simply not what a
    # static room needs.
    [switch]$Light,
    [int]$ShadeLevels = 32,
    [double]$FogScale = 1.6,      # FogFar = the geometry's span x this
    [double]$FogNearFrac = 0.04,  # FogNear as a fraction of FogFar
    [double]$Ambient = 0.45,
    [double]$NormalLight = 0.25,
    [string]$TexDir  = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX',
    [string]$CacheDir = 'C:\Games\azrael-render',
    [string]$Palette = 'C:\Games\azrael-inject\azrael-palette.pal',
    [string]$Sym      = "$PSScriptRoot\..\AztMod.overlay.sym",
    [string]$Manifest = "$PSScriptRoot\..\AztMod.manifest.json",
    [int]$Threads = 0
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'Quantize.cs'), (Join-Path $toolDir 'HostView.cs')) `
         -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop
Add-Type -AssemblyName System.Drawing

$symMap = @{}
foreach ($l in [IO.File]::ReadAllLines((Resolve-Path $Sym).Path)) {
    if ($l -match '^0x([0-9A-Fa-f]+)\s+(\S+)$') { $symMap[$Matches[2]] = [uint32]('0x' + $Matches[1]) }
}
function Sym([string]$n) {
    if (-not $symMap.ContainsKey($n)) { throw "$n is not in the overlay symbol map -- rebuild with the right flags on" }
    return [uint32]$symMap[$n]
}
$S_sup3D  = Sym 'aztSup3D'; $S_enable = Sym 'aztInjEnable'; $S_bufPtr = Sym 'aztInjBufPtr'
$S_parts  = Sym 'aztSceneParts'
$S_sync   = Sym 'aztInjSync'
$S_ready  = Sym 'aztInjReady'; $S_shown = Sym 'aztInjShown'; $S_starve = Sym 'aztInjStarve'
$S_camRec = Sym 'aztCamRec'

$g = Get-AztGuestBase
function H1([uint32]$l) { [long]($g.MemBase + $l + 0x1F0000) }

if ($Restore) {
    $h0 = New-Object AztTool.HostView($g.ProcessId, [long]1, 4, 4, [byte]1, [byte]1, [byte]1)
    foreach ($s in @($S_ready, $S_enable, $S_sup3D, $S_parts, $S_sync)) { [void]$h0.WriteU32((H1 $s), 0) }
    Write-Host 'viewport handed back to the engine.' -ForegroundColor Green
    $h0.Close(); return
}

$man = Get-Content (Resolve-Path $Manifest).Path -Raw | ConvertFrom-Json
$W = [int]$man.view.injW; $H = [int]$man.view.injH
$capLin = 0; $capWas = 0
foreach ($s in $man.settings) { if ($s.name -eq 'aztFramePeriod') { $capLin = [Convert]::ToUInt32((([string]$s.linear) -replace '^0x',''), 16) } }
if ($Uncap -and -not $capLin) { throw 'aztFramePeriod is not in the manifest settings -- cannot lift the cap' }

if (-not $Xaf) {
    $rooms = @(& (Join-Path $toolDir 'Find-LiveRoom.ps1') -TexDir $TexDir -Sym $Sym -Quiet)
    if ($rooms.Count -eq 0) { throw 'could not identify the live room' }
    Write-Host ("room detected from the live scene graph: {0}" -f ($rooms -join ' + ')) -ForegroundColor Green
} else {
    $rooms = @($Xaf -split '\+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
Write-Host ("frame {0}x{1}, geometry {2}" -f $W, $H, ($rooms -join ' + '))

# ---- geometry and textures, loaded ONCE ------------------------------------
# Re-exported only if the OBJ is missing: the .XAF -> OBJ -> PNG chain takes seconds,
# and doing it per run would dominate a 30 second session.
$verts = New-Object System.Collections.Generic.List[single]
$uvs   = New-Object System.Collections.Generic.List[single]
$tris  = New-Object System.Collections.Generic.List[int]
$triMat = New-Object System.Collections.Generic.List[int]
$matNames = New-Object System.Collections.Generic.List[string]
$matFile  = New-Object System.Collections.Generic.List[string]   # which OBJ each material came from
$uvOf = @{}        # vertex index -> vt index, filled from the faces
$curMat = -1
# MERGED ACROSS FILES, with per-file index bases. OBJ indices are per-file and
# 1-based, so concatenating without rebasing silently points every face after the
# first file at the wrong vertices -- geometry that is plausible and wrong.
$vBase = 0; $tBase = 0
foreach ($room in $rooms) {
  $obj = Join-Path $CacheDir ("{0}.obj" -f $room)
  # -IfStale, not Test-Path: a cached OBJ from an older exporter is worse than no cache,
  # because it silently keeps whatever that exporter got wrong at the time
  New-Item -ItemType Directory -Force $CacheDir | Out-Null
  & (Join-Path $toolDir 'Export-XafObj.ps1') -Xaf $room -TexDir $TexDir -OutDir $CacheDir -IfStale | Out-Null
  if (-not (Test-Path $obj)) { throw "could not produce $obj from $room.XAF" }
  $objDirThis = Split-Path $obj -Parent
  $vBase = [int]($verts.Count / 3); $tBase = [int]($uvs.Count / 2)
  $curMat = -1
  foreach ($line in [IO.File]::ReadAllLines((Resolve-Path $obj).Path)) {
    if ($line.Length -lt 2) { continue }
    if ($line[0] -eq 'v' -and $line[1] -eq ' ') {
        $p = $line.Substring(2).Trim() -split '\s+'
        $verts.Add([single]$p[0]); $verts.Add([single]$p[1]); $verts.Add([single]$p[2])
    } elseif ($line[0] -eq 'v' -and $line[1] -eq 't') {
        $p = $line.Substring(3).Trim() -split '\s+'
        $uvs.Add([single]$p[0]); $uvs.Add([single]$p[1])
    } elseif ($line.StartsWith('usemtl ')) {
        # Materials are keyed by FILE+NAME: two rooms can both have a `n_black` that
        # points at different art, and merging them by name alone would paint one room
        # with the other's textures.
        $n = $line.Substring(7).Trim()
        $key = "$room/$n"
        $curMat = $matNames.IndexOf($key)
        if ($curMat -lt 0) { $matNames.Add($key); $matFile.Add($room); $curMat = $matNames.Count - 1 }
    } elseif ($line[0] -eq 'f' -and $line[1] -eq ' ') {
        # RESOLVE UVs THROUGH THE FACE, not by assuming vt index == vertex index. That
        # assumption holds WITHIN a .XAF mesh, where texture_coordinates runs parallel to
        # vertices -- but not across a ROOM that mixes textured and untextured meshes:
        # MINEHEAD has 1,710 vertices and only 1,662 UVs, because some meshes carry none.
        # Taken globally the two lists drift out of step and every UV after the first
        # untextured mesh belongs to the wrong vertex.
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
# Build the per-vertex UV array the rasteriser wants, from the face mapping.
$nv = [int]($vArr.Count / 3)
$uvArr = New-Object single[] ($nv * 2)
$noUv = 0
for ($i = 0; $i -lt $nv; $i++) {
    $t = $(if ($uvOf.ContainsKey($i)) { $uvOf[$i] } else { -1 })
    if ($t -ge 0 -and ($t*2+1) -lt $uvs.Count) { $uvArr[$i*2] = $uvs[$t*2]; $uvArr[$i*2+1] = $uvs[$t*2+1] }
    else { $noUv++ }
}
if ($noUv -gt 0) { Write-Host ("{0:N0} of {1:N0} vertices have no texture coordinate" -f $noUv, $nv) -ForegroundColor Yellow }
Write-Host ("{0:N0} vertices, {1:N0} triangles, {2} materials" -f ($vArr.Count/3), ($tArr.Count/3), $matNames.Count)

$pal = [IO.File]::ReadAllBytes((Resolve-Path $Palette).Path)
# One .mtl per room file, keyed the same way the materials are: FILE/NAME.
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
    $nm = $matNames[$mi]
    $png = $(if ($mtlMap.ContainsKey($nm)) { Join-Path $CacheDir $mtlMap[$nm] } else { $null })
    if (-not $png -or -not (Test-Path $png)) { $matToTex[$mi] = -1; continue }
    $bm = [System.Drawing.Bitmap]::FromFile($png); $tw = $bm.Width; $th = $bm.Height
    $cv = New-Object System.Drawing.Bitmap($tw, $th, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gr = [System.Drawing.Graphics]::FromImage($cv); $gr.DrawImage($bm,0,0,$tw,$th); $gr.Dispose(); $bm.Dispose()
    $rc = New-Object System.Drawing.Rectangle(0,0,$tw,$th)
    $bd = $cv.LockBits($rc, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $raw = New-Object byte[] ($tw*$th*4)
    [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $raw, 0, $raw.Length)
    $cv.UnlockBits($bd); $cv.Dispose()
    $texes += (New-Object AztTool.Raster+Tex([LeTool.Quant]::Map($raw,$tw,$th,$pal,256,0,0,0), $tw, $th))
    $matToTex[$mi] = $texes.Count - 1
}
# A 1x1 FALLBACK TEXTURE, so untextured geometry is DRAWN rather than skipped.
#
# Several of a room's largest meshes carry no material at all -- in MINEHEAD those are
# `stuff` (290 faces), `minechasm` (118) and `car2` (68), which between them are most of
# the floor and the chasm. DrawTextured skips any triangle whose texture index is -1, so
# 246 of 1,161 triangles were never drawn and the viewport came back mostly BLACK. It
# read as a camera or culling fault; it was neither.
#
# Mid-luminance neutral out of the captured palette, so untextured surfaces read as
# untextured rather than as holes.
# ---- MATERIALS THAT ARE NOT SUPPOSED TO BE SEEN ----------------------------
# The game names its invisible volumes in the material: TRANSPARANT and ACTIVATION are
# trigger surfaces -- the same materials on the zx*/zy* objects AZONES.DAT lists as room
# portals -- and BLACKCOVER is a masking quad. The engine draws none of them.
#
# This is not a small error. CORICORI's 17 TRANSPARANT faces are large quads lying
# across the floor, and painting them flat covered a third of the screen in one colour.
# A face with no texture is not automatically a face that needs one.
$SKIP_MATS = @('TRANSPARANT','ACTIVATION','BLACKCOVER')
# The flat ink is for genuinely untextured GEOMETRY (MINEHEAD's `stuff` and `minechasm`
# are real surfaces carrying no material). DARK and strictly neutral: the previous
# mid-luminance pick landed on a pink that made every such face leap out.
$_fbLum = 1..254 | ForEach-Object {
    $r3=$pal[$_*3]; $g3=$pal[$_*3+1]; $b3=$pal[$_*3+2]
    $mx=[Math]::Max($r3,[Math]::Max($g3,$b3)); $mn=[Math]::Min($r3,[Math]::Min($g3,$b3))
    [pscustomobject]@{ I=$_; L=(0.299*$r3+0.587*$g3+0.114*$b3); S=($mx-$mn) } }
$_fbCand = @($_fbLum | Where-Object { $_.S -le 16 } | Sort-Object L)
if ($_fbCand.Count -lt 4) { $_fbCand = @($_fbLum | Sort-Object L) }
$fbInk = [byte]$_fbCand[[int]($_fbCand.Count * 0.20)].I
$texes += (New-Object AztTool.Raster+Tex((New-Object byte[] 1), 1, 1))
$texes[$texes.Count-1].Idx[0] = $fbInk
$fbIdx = $texes.Count - 1

$triTexArr = New-Object int[] ($triMat.Count)
$untex = 0; $skipped = 0
for ($i = 0; $i -lt $triMat.Count; $i++) {
    $m = $triMat[$i]
    $nm = $(if ($m -ge 0) { ($matNames[$m] -split '/')[-1] } else { '' })
    if ($SKIP_MATS -contains $nm) { $triTexArr[$i] = -1; $skipped++ }    # -1 = not drawn
    elseif ($m -ge 0 -and $matToTex.ContainsKey($m) -and $matToTex[$m] -ge 0) { $triTexArr[$i] = $matToTex[$m] }
    else { $triTexArr[$i] = $fbIdx; $untex++ }
}
Write-Host ("{0} textures quantised; {1:N0} textured, {2:N0} flat (ink {3}), {4:N0} skipped as invisible" -f `
    ($texes.Count-1), ($triTexArr.Count - $untex - $skipped), $untex, $fbInk, $skipped)

# ---- the bridge -------------------------------------------------------------
$bufGuest = [BitConverter]::ToUInt32([AztTool.ProcMem]::Read($g.ProcessId, (H1 $S_bufPtr), 4), 0)
if ($bufGuest -lt 0x1000) { throw "staging buffer is 0x$('{0:X}' -f $bufGuest) -- AztInjInit could not allocate" }
# REAL INKS, picked by luminance out of the captured palette. These were placeholder 1s,
# which made -TestPattern draw a black bar and a black grid on a black background: the only
# thing visible was the sequence marker, and the pattern read as "injection is broken" when
# it was working perfectly. A diagnostic that cannot be seen is worse than none.
$_lum = 1..254 | ForEach-Object { [pscustomobject]@{ I=$_; L=(0.299*$pal[$_*3] + 0.587*$pal[$_*3+1] + 0.114*$pal[$_*3+2]) } }
$_srt = @($_lum | Sort-Object L)
$hv = New-Object AztTool.HostView($g.ProcessId, [long]($g.MemBase + $bufGuest), $W, $H, `
        [byte]$_srt[$_srt.Count-2].I, [byte]$_srt[[int]($_srt.Count*0.20)].I, [byte]$_srt[[int]($_srt.Count*0.55)].I)
$r  = New-Object AztTool.Raster($W, $H)
# LEAVE THE GAME SOME CPU. Raster defaults to every logical processor, which on this
# box is 32 -- and DOSBox emulates the whole game on ONE thread. Taking every core for
# the renderer starves the thing being rendered, and an unresponsive game is a worse
# outcome than a slower render: the rasteriser already finishes in a fraction of the
# guest's 45 ms frame, so the spare threads were buying nothing.
if ($Threads -gt 0) { $r.Threads = $Threads }
else { $r.Threads = [Math]::Max(2, [int]([Environment]::ProcessorCount / 2)) }
Write-Host ("rasteriser threads {0} of {1} logical processors" -f $r.Threads, [Environment]::ProcessorCount)
$r.SetVerticalFov($Fov)
$r.NearZ = [single]0.5
if ($Light) {
    # Fog distances come from the GEOMETRY, not from a constant: rooms here range from a
    # couple of hundred units across to several thousand, and a fixed range would black
    # out a small room entirely and do nothing at all in a large one.
    $lo = @([single]::MaxValue,[single]::MaxValue,[single]::MaxValue)
    $hi = @([single]::MinValue,[single]::MinValue,[single]::MinValue)
    for ($i = 0; $i -lt $vArr.Count; $i += 3) {
        for ($a2 = 0; $a2 -lt 3; $a2++) {
            $v2 = $vArr[$i+$a2]
            if ($v2 -lt $lo[$a2]) { $lo[$a2] = $v2 }
            if ($v2 -gt $hi[$a2]) { $hi[$a2] = $v2 }
        }
    }
    $span = 0.0
    for ($a2 = 0; $a2 -lt 3; $a2++) { $d2 = $hi[$a2] - $lo[$a2]; if ($d2 -gt $span) { $span = $d2 } }
    if ($span -le 0) { $span = 1000.0 }
    $r.SetShadeTable([AztTool.Raster]::BuildShadeTable($pal, $ShadeLevels), $ShadeLevels)
    $r.FogFar  = [single]($span * $FogScale)
    $r.FogNear = [single]($span * $FogScale * $FogNearFrac)
    $r.Ambient = [single]$Ambient
    $r.NormalLight = [single]$NormalLight
    Write-Host ("lighting: {0} levels, span {1:N0}, fog {2:N0}..{3:N0}, ambient {4:N2}, normal {5:N2}" -f `
        $ShadeLevels, $span, $r.FogNear, $r.FogFar, $Ambient, $NormalLight)
} else {
    Write-Host 'lighting OFF'
}

# the record layout is the build's own, asserted contiguous there
$REC_MOVWORLD = 172
$bg = [byte]0

try {
    $probe = [AztTool.ProcMem]::Read($g.ProcessId, (H1 $S_camRec), 320)
    if (-not $probe) { throw 'could not read aztCamRec' }
    if ([Text.Encoding]::ASCII.GetString($probe,0,4) -ne 'CAM1') {
        throw ("aztCamRec does not start with 'CAM1' -- is `$ENABLE_CAM_PUBLISH on in the INSTALLED build?")
    }
    Write-Host ("camera record live: frame {0}, cue {1}" -f [BitConverter]::ToUInt32($probe,4), [BitConverter]::ToUInt32($probe,304))

    # SUPPRESS THE RASTERISER, NOT THE SCENE PASS.
    #
    # aztSup3D = 2 skips the whole of 0x3F1B0, and that call also ADVANCES THE
    # SIMULATION: measured, the player moved 0 units and turned 0 degrees across a 25 s
    # run under it. Setting aztSceneParts = 4 skips only 0x5B820 inside it -- which is
    # where the rendering cost actually lives (x17.3 on its own, against x1.08 for the
    # per-scene-element call) -- and the player still moved 266 units in 20 s under it.
    #
    # The viewport CLEAR (0x3F0D0) is deliberately left running. It costs 0.3% of the
    # frame and happens before the injection, so it is harmless, and switching it off
    # would mean setting aztSup3D, which would take the simulation with it.
    if ($Uncap) {
        $capWas = $hv.ReadU32((H1 $capLin))
        [void]$hv.WriteU32((H1 $capLin), 0)
        Write-Host ("frame cap LIFTED (aztFramePeriod {0} -> 0). Movement is frame-tied, so stand still." -f $capWas) -ForegroundColor Yellow
    }
    if (-not $NoSuppress) { [void]$hv.WriteU32((H1 $S_parts), 4) }
    [void]$hv.WriteU32((H1 $S_sync), 1)      # ask the guest for the one-frame handshake
    [void]$hv.WriteU32((H1 $S_enable), 1)

    $sh0 = $hv.ReadU32((H1 $S_shown)); $st0 = $hv.ReadU32((H1 $S_starve))
    $sk0 = [BitConverter]::ToUInt32([AztTool.ProcMem]::Read($g.ProcessId, (H1 (Sym 'aztSupSkips')), 4), 0)
    $dr0 = [BitConverter]::ToUInt32([AztTool.ProcMem]::Read($g.ProcessId, (H1 (Sym 'aztSupDraws')), 4), 0)
    $rs0 = [BitConverter]::ToUInt32([AztTool.ProcMem]::Read($g.ProcessId, (H1 (Sym 'AztScenePart2_skips')), 4), 0)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $frames = 0; $rasterMs = 0.0; $identity = 0; $covSamples = 0; $covTotal = 0.0
    # TRACK THE CAMERA ACROSS THE RUN. Logging only the first frame cannot tell "the view
    # followed the player" from "the player moved afterwards" -- and whether the game stays
    # responsive while the host owns the viewport is the thing most worth knowing. Path
    # length is summed per frame so a there-and-back walk still registers.
    $camFirst = $null; $camLast = $null; $pathLen = 0.0; $turnMax = 0.0; $syncTimeouts = 0
    while ($sw.ElapsedMilliseconds -lt ($Seconds * 1000)) {
        $rec = [AztTool.ProcMem]::Read($g.ProcessId, (H1 $S_camRec), 320)
        if (-not $rec) { Write-Host 'the game exited.' -ForegroundColor Yellow; break }
        $m = New-Object single[] 16
        for ($i = 0; $i -lt 16; $i++) { $m[$i] = [BitConverter]::ToSingle($rec, $REC_MOVWORLD + $i*4) }
        # An identity matrix means the engine has not populated that frame yet. Rendering
        # from it would put the camera at the world origin looking down +Z and produce a
        # plausible-looking but completely wrong view, so it is counted and skipped.
        if ($m[12] -eq 0 -and $m[13] -eq 0 -and $m[14] -eq 0 -and $m[0] -eq 1) { $identity++; Start-Sleep -Milliseconds 20; continue }

        if ($null -eq $camFirst) { $camFirst = @($m[12], $m[13], $m[14], $m[8], $m[9], $m[10]) }
        else {
            $pathLen += [Math]::Sqrt([Math]::Pow($m[12]-$camLast[0],2) + [Math]::Pow($m[13]-$camLast[1],2) + [Math]::Pow($m[14]-$camLast[2],2))
            # dot of the two forward vectors -> how far the heading has swung from the start
            $dot = $camFirst[3]*$m[8] + $camFirst[4]*$m[9] + $camFirst[5]*$m[10]
            if ($dot -lt -1) { $dot = -1 } elseif ($dot -gt 1) { $dot = 1 }
            $deg = [Math]::Acos($dot) * 180.0 / [Math]::PI
            if ($deg -gt $turnMax) { $turnMax = $deg }
        }
        $camLast = @($m[12], $m[13], $m[14], $m[8], $m[9], $m[10])

        $t0 = $sw.Elapsed.TotalMilliseconds
        if ($TestPattern) {
            $hv.Compose(($sw.Elapsed.TotalSeconds - [Math]::Floor($sw.Elapsed.TotalSeconds)), [byte](1 + ($frames % 200)))
        } else {
            $r.SetCameraWorld($m)
            $r.Clear($bg)
            $r.DrawTextured($vArr, $uvArr, $tArr, $triTexArr, [AztTool.Raster+Tex[]]$texes, (-not $NoCull), (-not $NoFlipV))
        }
        $rasterMs += ($sw.Elapsed.TotalMilliseconds - $t0)

        # COVERAGE: did the renderer actually draw anything? A frame of pure background
        # injected over a suppressed engine would be a black viewport, and "the renderer
        # produced nothing" and "the pixels did not reach the screen" are completely
        # different faults that look identical from the outside. Sampled, not counted in
        # full -- a 1.48 M element scan per frame would cost more than the render.
        if (-not $TestPattern -and ($frames % 30) -eq 0) {
            $covSamples++
            $covTotal += (100.0 * $r.CountNonBackground($bg) / ($W*$H))
            if ($covSamples -eq 1) {
                # The camera the FIRST rendered frame actually used. Without this, a render
                # that comes back empty gives no way to tell a bad camera from a bad scene.
                Write-Host ("  first frame: camera {0:N1} {1:N1} {2:N1}  fwd {3:N3} {4:N3} {5:N3}  tris {6}/{7} culled {8}" -f `
                    $m[12], $m[13], $m[14], $m[8], $m[9], $m[10], $r.TrisDrawn, $r.TrisIn, $r.TrisCulled)
            }
        }

        # Wait for the guest to consume the previous frame, then hand over this one.
        #
        # SLEEP, DO NOT SPIN. A tight ReadProcessMemory loop here burns a core flat out
        # for the ~45 ms between guest frames, on top of the rasteriser's threads. DOSBox
        # emulates on ONE thread, and starving it makes the game stop responding to input
        # -- which is what "it was frozen and I couldn't move" looks like from the inside.
        # At 22 fps a 2 ms granularity costs nothing.
        # A SHORT TIMEOUT, AND COUNT IT. At 500 ms a guest that stops consuming drags the
        # host to exactly 2.0 fps -- which is what one run reported, and it read as "the
        # renderer froze the game" when the game had already stopped running its per-frame
        # path for reasons of its own. 120 ms is still five guest frames at 45 ms, so it
        # cannot fire in normal operation, and when it does fire the count says so instead
        # of the frame rate quietly collapsing.
        $wait = $sw.ElapsedMilliseconds
        while ($hv.ReadU32((H1 $S_ready)) -ne 0) {
            if ($sw.ElapsedMilliseconds - $wait -gt 120) { $syncTimeouts++; break }
            if ($sw.ElapsedMilliseconds -ge ($Seconds*1000)) { break }
            Start-Sleep -Milliseconds 2
        }
        if ($TestPattern) { if (-not $hv.Push()) { if ($hv.GameExited) { break } else { continue } } }
        else { if (-not $hv.PushFrame($r.Color)) { if ($hv.GameExited) { break } else { continue } } }
        [void]$hv.WriteU32((H1 $S_ready), 1)
        $frames++
    }
    $sw.Stop()
    $sec = $sw.Elapsed.TotalSeconds
    Write-Host ''
    Write-Host ("over {0:N1}s: {1:N0} frames rendered and injected, {2:N1} fps" -f $sec, $frames, ($frames/$sec))
    if ($frames -gt 0) { Write-Host ("  rasteriser {0:N2} ms/frame" -f ($rasterMs/$frames)) }
    if ($camFirst -and $camLast) {
        Write-Host ("  camera  start {0,8:N1} {1,7:N1} {2,8:N1}" -f $camFirst[0], $camFirst[1], $camFirst[2])
        Write-Host ("          end   {0,8:N1} {1,7:N1} {2,8:N1}" -f $camLast[0], $camLast[1], $camLast[2])
        Write-Host ("  the player moved {0:N0} units and turned up to {1:N0} deg DURING the run" -f $pathLen, $turnMax)
        if ($pathLen -lt 1 -and $turnMax -lt 1) {
            Write-Host '  THE CAMERA NEVER CHANGED -- either nobody moved, or input is not reaching the game.' -ForegroundColor Yellow
        } else {
            Write-Host '  the game stayed responsive while the host owned the viewport.' -ForegroundColor Green
        }
    }
    if ($covSamples -gt 0) {
        $cov = $covTotal / $covSamples
        Write-Host ("  rendered coverage {0:N1}%  (non-background pixels in the host frame)" -f $cov)
        if ($cov -lt 0.5) { Write-Host '  THE RENDERER DREW ALMOST NOTHING -- the camera or the geometry is wrong, not the injection.' -ForegroundColor Red }
    }
    if (Get-Process -Id $g.ProcessId -ErrorAction SilentlyContinue) {
        $shNow = $hv.ReadU32((H1 $S_shown)); $stNow = $hv.ReadU32((H1 $S_starve))
        # ReadU32 returns 0 on a dead process, so a delta would come out NEGATIVE --
        # "guest displayed -371" is not a measurement, it is the game having exited.
        if ($shNow -ge $sh0) { Write-Host ("  guest displayed {0:N0}, starved {1:N0}" -f ($shNow-$sh0), ($stNow-$st0)) }
        else { Write-Host "  (the game exited before the counters could be read)" -ForegroundColor Yellow }
        $sk1 = [BitConverter]::ToUInt32([AztTool.ProcMem]::Read($g.ProcessId, (H1 (Sym 'aztSupSkips')), 4), 0)
        $dr1 = [BitConverter]::ToUInt32([AztTool.ProcMem]::Read($g.ProcessId, (H1 (Sym 'aztSupDraws')), 4), 0)
        # THE SCENE PASS IS SUPPOSED TO RUN. We suppress the RASTERISER inside it
        # (0x5B820, via aztSceneParts), not the pass itself -- the pass also advances
        # the simulation. So report the rasteriser skips; a warning keyed on the old
        # aztSup3D counters fired on every successful run and said the opposite of
        # the truth.
        # GUARDED. ProcMem.Read returns $null once the process is gone and
        # BitConverter::ToUInt32($null,0) throws, which turned a completed run into a
        # stack trace and buried its results. Every read after the loop has to assume
        # the game may have exited in the meantime.
        $rsRaw = [AztTool.ProcMem]::Read($g.ProcessId, (H1 (Sym 'AztScenePart2_skips')), 4)
        $rs1 = $(if ($rsRaw) { [BitConverter]::ToUInt32($rsRaw, 0) } else { $rs0 })
        Write-Host ("  engine scene passes drawn {0:N0} (wanted: they drive the simulation)" -f ($dr1-$dr0))
        Write-Host ("  engine RASTERISER calls skipped {0:N0}" -f ($rs1 - $rs0))
        if (($rs1 - $rs0) -eq 0 -and -not $NoSuppress) {
            Write-Host '  THE RASTERISER GATE NEVER FIRED -- the engine is still drawing its own 3D.' -ForegroundColor Red
        }

        # DID OUR BYTES REACH THE SURFACE? Read back the row the game is showing and
        # compare it to the row we last pushed. This separates "we never wrote it" from
        # "we wrote it and something else won" -- the two remaining explanations for a
        # screen that looks unchanged.
        $descRaw = [AztTool.ProcMem]::Read($g.ProcessId, [long]($g.MemBase + 0x14745C + 0x1F1000), 4)
        if ($descRaw) {
            $desc = [BitConverter]::ToUInt32($descRaw, 0)
            if ($desc -gt 0x1000) {
                $dd = [AztTool.ProcMem]::Read($g.ProcessId, [long]($g.MemBase + $desc), 0x40)
                $stride = [BitConverter]::ToUInt32($dd, 0x18); $pix = [BitConverter]::ToUInt32($dd, 0x1C)
                $yProbe = [int]($H/2)
                $got = [AztTool.ProcMem]::Read($g.ProcessId, [long]($g.MemBase + $pix + $yProbe*$stride), $W)
                $src = $(if ($TestPattern) { $null } else { $r.Color })
                if ($got -and $src) {
                    $same = 0
                    for ($i = 0; $i -lt $W; $i++) { if ($got[$i] -eq $src[$yProbe*$W + $i]) { $same++ } }
                    Write-Host ("  surface row {0}: {1:N0}/{2:N0} bytes match the frame we pushed ({3:P0})" -f `
                        $yProbe, $same, $W, ($same/[double]$W))
                    if ($same -lt ($W*0.5)) {
                        Write-Host '  OUR PIXELS ARE NOT IN THE SURFACE -- something overwrites it after the injection.' -ForegroundColor Red
                    }
                }
            }
        }
    }
    if ($identity -gt 0) { Write-Host ("  {0:N0} frames skipped: the movement frame read as identity" -f $identity) -ForegroundColor Yellow }
}
finally {
    [void]$hv.WriteU32((H1 $S_ready), 0)
    [void]$hv.WriteU32((H1 $S_enable), 0)
    [void]$hv.WriteU32((H1 $S_sup3D), 0)
    [void]$hv.WriteU32((H1 $S_parts), 0)
    [void]$hv.WriteU32((H1 $S_sync), 0)
    # THE CAP ALWAYS GOES BACK. A game left uncapped is one with frame-tied systems
    # running at several times their design rate, which is a far worse state to leave
    # behind than a slow one.
    if ($Uncap -and $capWas) { [void]$hv.WriteU32((H1 $capLin), $capWas) }
    Start-Sleep -Milliseconds 200
    Write-Host 'viewport handed back to the engine.' -ForegroundColor Green
    $hv.Close()
}
