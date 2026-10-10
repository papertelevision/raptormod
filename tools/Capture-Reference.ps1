# Capture-Reference.ps1 -- everything needed to work on a room OFFLINE, in one go.
#
#   .\tools\Capture-Reference.ps1
#   .\tools\Capture-Reference.ps1 -Name opening
#
# Stand where you want the reference taken and run it. Nothing is injected, nothing is
# suppressed, the game is not disturbed -- it only reads.
#
# WHY. Tuning the renderer has meant a relaunch per experiment, which is a slow and
# tiring loop for the person holding the keyboard. Everything the renderer needs is
# READABLE: which room, the exact camera, and what the engine itself draws from there.
# Captured once, the whole tuning cycle runs offline against a fixed reference, and the
# game is only needed again to confirm the result.
#
# It writes, into -OutDir:
#   <name>.json      room files, camera matrix, position, cue
#   <name>-engine.png  what the ENGINE draws right now -- the thing to match
#   <name>-cover.txt   per-material texture coverage, so "no textures" is a number
[CmdletBinding()]
param(
    [string]$Name = 'ref',
    [string]$OutDir = 'C:\Games\azrael-render\ref',
    [string]$TexDir = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX',
    [string]$CacheDir = 'C:\Games\azrael-render',
    [string]$Palette = 'C:\Games\azrael-inject\azrael-palette.pal',
    [string]$Sym = "$PSScriptRoot\..\AztMod.overlay.sym",
    [string]$Manifest = "$PSScriptRoot\..\AztMod.manifest.json"
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $OutDir | Out-Null

$symMap = @{}
foreach ($l in [IO.File]::ReadAllLines((Resolve-Path $Sym).Path)) {
    if ($l -match '^0x([0-9A-Fa-f]+)\s+(\S+)$') { $symMap[$Matches[2]] = [uint32]('0x'+$Matches[1]) }
}
$man = Get-Content (Resolve-Path $Manifest).Path -Raw | ConvertFrom-Json
$W = [int]$man.view.injW; $H = [int]$man.view.injH

$g = Get-AztGuestBase
function H1([uint32]$l) { [long]($g.MemBase + $l + 0x1F0000) }
function H2([uint32]$l) { [long]($g.MemBase + $l + 0x1F1000) }

# ---- which room -------------------------------------------------------------
$rooms = @(& (Join-Path $toolDir 'Find-LiveRoom.ps1') -TexDir $TexDir -Sym $Sym -Quiet)
if ($rooms.Count -eq 0) { throw 'could not identify the live room' }
Write-Host ("room: {0}" -f ($rooms -join ' + '))

# ---- the camera, exactly as the renderer will use it ------------------------
$rec = [AztTool.ProcMem]::Read($g.ProcessId, (H1 $symMap['aztCamRec']), 320)
if (-not $rec) { throw 'could not read aztCamRec' }
if ([Text.Encoding]::ASCII.GetString($rec,0,4) -ne 'CAM1') { throw "aztCamRec has no 'CAM1' magic" }
$m = @(0..15 | ForEach-Object { [BitConverter]::ToSingle($rec, 172 + $_*4) })
$cue = [BitConverter]::ToUInt32($rec, 304)
Write-Host ("camera: {0:N1} {1:N1} {2:N1}  fwd {3:N3} {4:N3} {5:N3}  cue {6}" -f $m[12],$m[13],$m[14],$m[8],$m[9],$m[10],$cue)

# ---- what the ENGINE draws, which is the thing to match ---------------------
# Read while the engine owns the viewport and nothing of ours is injected, so this is
# the game's own output and can be compared against like for like.
$pal = [IO.File]::ReadAllBytes((Resolve-Path $Palette).Path)
$desc = [BitConverter]::ToUInt32([AztTool.ProcMem]::Read($g.ProcessId, (H2 0x14745C), 4), 0)
if ($desc -le 0x1000) { throw 'no 3D surface descriptor -- is a room actually loaded?' }
$dd = [AztTool.ProcMem]::Read($g.ProcessId, [long]($g.MemBase + $desc), 0x40)
$stride = [BitConverter]::ToUInt32($dd, 0x18); $pix = [BitConverter]::ToUInt32($dd, 0x1C)
$surf = [AztTool.ProcMem]::Read($g.ProcessId, [long]($g.MemBase + $pix), ($stride * $H))
if (-not $surf) { throw 'could not read the 3D surface' }
$bmp = New-Object System.Drawing.Bitmap($W, $H, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
$cp = $bmp.Palette
for ($i = 0; $i -lt 256; $i++) { $cp.Entries[$i] = [System.Drawing.Color]::FromArgb(255, $pal[$i*3], $pal[$i*3+1], $pal[$i*3+2]) }
$bmp.Palette = $cp
$rc = New-Object System.Drawing.Rectangle(0,0,$W,$H)
$bd = $bmp.LockBits($rc, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
for ($y = 0; $y -lt $H; $y++) {
    [System.Runtime.InteropServices.Marshal]::Copy($surf, $y*$stride, [IntPtr]($bd.Scan0.ToInt64() + $y*$bd.Stride), $W)
}
$bmp.UnlockBits($bd)
$enginePng = Join-Path $OutDir ("{0}-engine.png" -f $Name)
$bmp.Save($enginePng, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()

# ---- how much of this room actually HAS a texture ---------------------------
# "no actual textures" deserves a number rather than an impression: the exporter reports
# some meshes as having no material at all, and those are drawn flat.
$lines = New-Object System.Collections.Generic.List[string]
$totV = 0; $totF = 0; $noMat = 0
foreach ($room in $rooms) {
    $obj = Join-Path $CacheDir ("{0}.obj" -f $room)
    # -IfStale, not Test-Path: a cached OBJ from an older exporter is worse than no cache,
    # because it silently keeps whatever that exporter got wrong at the time
    & (Join-Path $toolDir 'Export-XafObj.ps1') -Xaf $room -TexDir $TexDir -OutDir $CacheDir -IfStale | Out-Null
    if (-not (Test-Path $obj)) { $lines.Add("$room : export failed"); continue }
    $mtl = [IO.Path]::ChangeExtension($obj, '.mtl')
    $withMap = @{}
    if (Test-Path $mtl) {
        $cur = $null
        foreach ($l in [IO.File]::ReadAllLines($mtl)) {
            $s = $l.Trim()
            if ($s.StartsWith('newmtl ')) { $cur = $s.Substring(7).Trim() }
            elseif ($s.StartsWith('map_Kd ') -and $cur) { $withMap[$cur] = $s.Substring(7).Trim() }
        }
    }
    $curMat = $null; $facesByMat = @{}; $nF = 0; $nV = 0
    foreach ($l in [IO.File]::ReadAllLines($obj)) {
        if ($l.StartsWith('usemtl ')) { $curMat = $l.Substring(7).Trim() }
        elseif ($l.Length -gt 2 -and $l[0] -eq 'f' -and $l[1] -eq ' ') {
            $nF++
            $k = $(if ($curMat) { $curMat } else { '(none)' })
            $facesByMat[$k] = 1 + $(if ($facesByMat.ContainsKey($k)) { $facesByMat[$k] } else { 0 })
        }
        elseif ($l.Length -gt 2 -and $l[0] -eq 'v' -and $l[1] -eq ' ') { $nV++ }
    }
    $totV += $nV; $totF += $nF
    $lines.Add("$room : $nV verts, $nF faces")
    foreach ($k in ($facesByMat.Keys | Sort-Object { -$facesByMat[$_] })) {
        $has = $(if ($withMap.ContainsKey($k)) { $withMap[$k] } else { 'NO TEXTURE' })
        if ($has -eq 'NO TEXTURE') { $noMat += $facesByMat[$k] }
        $lines.Add(("    {0,-22} {1,5} faces  {2}" -f $k, $facesByMat[$k], $has))
    }
}
$lines.Insert(0, ("TOTAL {0} verts, {1} faces, {2} faces ({3:P0}) have NO texture" -f $totV, $totF, $noMat, $(if($totF){$noMat/$totF}else{0})))
$coverTxt = Join-Path $OutDir ("{0}-cover.txt" -f $Name)
[IO.File]::WriteAllLines($coverTxt, $lines)
Write-Host $lines[0]

$json = [ordered]@{
    name = $Name; rooms = $rooms; cue = $cue
    camera = $m; pos = @($m[12],$m[13],$m[14]); fwd = @($m[8],$m[9],$m[10])
    width = $W; height = $H
    captured = (Get-Date).ToString('s')
}
$jsonPath = Join-Path $OutDir ("{0}.json" -f $Name)
($json | ConvertTo-Json -Depth 4) | Set-Content -Path $jsonPath -Encoding UTF8
Write-Host ''
Write-Host 'wrote:'
Write-Host ("  " + $jsonPath)
Write-Host ("  " + $enginePng)
Write-Host ("  " + $coverTxt)
