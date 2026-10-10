# Start-RoomReview.ps1 -- ROOM REVIEW (Josh, 2026-10-08): every room in 3D in a web browser, without the game. Click any
# point on the geometry and leave a note there; the assistant reads the notes (C:\Games\azrael-render\room-notes) and
# makes the changes -- mostly in the rooms' atmosphere files (rooms\<ROOM>.json: lights, fog, mist...).
#
# A small LOCAL server: it serves the viewer (tools\room-review), each room's offline export (the .obj/.mtl/.png written
# by Export-XafObj.ps1 into C:\Games\azrael-render, with the hi-res texture where there is one), the room's merged
# atmosphere, and the notes. It listens on localhost only, never writes a room's settings, and never touches the game.
#
#   Review-Rooms.cmd                       (double-click: starts this and opens the browser)
#   .\tools\Start-RoomReview.ps1 [-Port 8642] [-NoBrowser] [-StrictPort] [-Transport Auto|HttpListener|Tcp]
param(
    [string]$RenderDir = 'C:\Games\azrael-render',
    [string]$HiresDir = 'C:\Games\azrael-textures\hires',
    [string]$TexDir = 'C:\Games\AzraelsTear-Modded\GAME\AZTEX',
    [string]$NotesDir = '',
    [int]$Port = 8642,
    [switch]$StrictPort,
    [switch]$NoBrowser,
    [ValidateSet('Auto', 'HttpListener', 'Tcp')][string]$Transport = 'Auto'
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path      # ($PSScriptRoot is empty in param defaults under -File)
$webDir = Join-Path $toolDir 'room-review'
if (-not $NotesDir) { $NotesDir = Join-Path $RenderDir 'room-notes' }
$RoomsDir = Join-Path $RenderDir 'rooms'
$RendersDir = Join-Path $RenderDir 'room-renders'
$utf8 = New-Object System.Text.UTF8Encoding($false)

# the atmosphere merge, exactly as the renderer does it: Get-RoomAtmosphere (and ConvertTo-Rgb24) out of the watcher
function Say([string]$m, [string]$c = 'Gray') { }
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $toolDir 'Watch-HostRender.ps1'), [ref]$null, [ref]$null)
foreach ($fn in 'ConvertTo-Rgb24', 'Get-RoomAtmosphere') {
    $fd = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $fn }, $true)
    if ($fd) { . ([scriptblock]::Create($fd.Extent.Text)) } else { throw "Watch-HostRender.ps1 has no $fn" }
}
Add-Type -Path (Join-Path $toolDir 'RoomReviewHttp.cs')
$cfg = Get-Content (Join-Path $webDir 'rooms.json') -Raw | ConvertFrom-Json
$batch = @($cfg.batch | ForEach-Object { ([string]$_).ToUpperInvariant() })
$hidden = @($cfg.hidden | ForEach-Object { ([string]$_).ToUpperInvariant() })
$portals = $null; $portalsPath = Join-Path $RenderDir 'portals.json'
if (Test-Path $portalsPath) { try { $portals = Get-Content $portalsPath -Raw | ConvertFrom-Json } catch { } }
New-Item -ItemType Directory -Force $NotesDir | Out-Null

# ---- responses --------------------------------------------------------------------------------------------------
function New-Resp([int]$status, [string]$type, [byte[]]$body, [hashtable]$headers = @{}) { [pscustomobject]@{ Status = $status; Type = $type; Body = $body; Headers = $headers } }
function Json($obj, [int]$status = 200) { New-Resp $status 'application/json; charset=utf-8' ($utf8.GetBytes((ConvertTo-Json -InputObject $obj -Depth 12 -Compress))) @{ 'Cache-Control' = 'no-store' } }
function Err([int]$status, [string]$msg) { Json @{ error = $msg } $status }
function FileResp([string]$path, [string]$type, [hashtable]$headers = @{}) {
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $b = New-Object byte[] $fs.Length; $n = 0; while ($n -lt $b.Length) { $k = $fs.Read($b, $n, $b.Length - $n); if ($k -le 0) { break }; $n += $k } } finally { $fs.Dispose() }
    New-Resp 200 $type $b $headers
}
# a path below root, or $null (no '..', no separators sneaking in, and the resolved path must stay inside)
function Inside([string]$root, [string]$leaf) {
    if (-not $leaf -or $leaf -match '\.\.|[\\/:]' -or $leaf -match '%') { return $null }
    $full = [IO.Path]::GetFullPath((Join-Path $root $leaf)); $r = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
    if ($full.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { return $full } else { return $null }
}
function Test-Room([string]$r) { return ($r -match '^[A-Za-z0-9_-]{1,32}$') -and (Test-Path (Join-Path $RenderDir ($r + '.obj'))) }

# ---- the rooms ----------------------------------------------------------------------------------------------------
# A room's materials, with the renderer's own rules for what is never drawn (tools\LoadRoom.ps1, Import-AztRoomSlow):
# TRANSPARANT / ACTIVATION (trigger surfaces) and BLACKCOVER (a masking quad); a flat material with alpha 0; and (in the
# viewer) a face with no material at all -- an authoring dummy.
$SKIP_MATS = @('TRANSPARANT', 'ACTIVATION', 'BLACKCOVER')
function Get-Materials([string]$room) {
    $mats = New-Object System.Collections.Generic.List[object]; $cur = $null
    foreach ($ln in [IO.File]::ReadAllLines((Join-Path $RenderDir ($room + '.mtl')))) {
        $t = $ln.Trim(); if (-not $t -or $t.StartsWith('#')) { continue }
        $sp = $t.IndexOf(' '); $k = $(if ($sp -gt 0) { $t.Substring(0, $sp) } else { $t }); $v = $(if ($sp -gt 0) { $t.Substring($sp + 1).Trim() } else { '' })
        switch ($k) {
            'newmtl' { $cur = [ordered]@{ name = $v; kd = @(1.0, 1.0, 1.0); d = 1.0; map = $null; keyed = $false; skip = $false; why = $null; hires = $false }; $mats.Add($cur) }
            'Kd' { if ($cur) { $p = $v -split '\s+'; $cur.kd = @([double]$p[0], [double]$p[1], [double]$p[2]) } }
            'd' { if ($cur) { $cur.d = [double]$v } }
            'map_Kd' { if ($cur) { $cur.map = $v } }
            'map_d' { if ($cur) { $cur.keyed = $true } }
        }
    }
    foreach ($m in $mats) {
        if ($SKIP_MATS -contains $m.name) { $m.skip = $true; $m.why = 'trigger' }
        elseif (-not $m.map -and $m.d -le 0) { $m.skip = $true; $m.why = 'invisible' }
        if ($m.map -and $HiresDir -and (Test-Path (Join-Path $HiresDir $m.map))) { $m.hires = $true }
    }
    return , $mats.ToArray()
}
function Get-Manifest([string]$room) {
    $obj = Join-Path $RenderDir ($room + '.obj')
    $ver = ''; $sr = New-Object IO.StreamReader($obj); try { $ver = $sr.ReadLine() } finally { $sr.Dispose() }
    $doors = @()
    if ($portals -and $portals.PSObject.Properties[$room]) {
        foreach ($p in @($portals.$room)) { $doors += [ordered]@{ to = [string]$p.to; zone = [string]$p.zone; door = @($p.door); land = $(if ($p.land) { @($p.land) } else { $null }) } }
    }
    # EXTRA LINKS (room-review\links.json, read fresh every time): ways between rooms that portals.json does not hold --
    # e.g. WASHCORI's door01, past which the player drops through a false floor into MINEMAZE (zone WashRoomMineMaze,
    # trigger zxwshrR3: a drop, not a doorway, so the doorway export never saw it). Josh, 2026-10-09.
    $lp = Join-Path $webDir 'links.json'
    if (Test-Path $lp) {
        try {
            $lk = Get-Content $lp -Raw | ConvertFrom-Json
            if ($lk.PSObject.Properties[$room]) { foreach ($p in @($lk.$room)) { if ($p.to -and $p.door) { $doors += [ordered]@{ to = [string]$p.to; zone = [string]$p.zone; door = @($p.door); land = $(if ($p.land) { @($p.land) } else { $null }) } } } }
        } catch { }
    }
    # where the player arrives: the landing spot of the door from the previous room in play order (else none)
    $bi = [Array]::IndexOf($batch, $room); $prev = $(if ($bi -gt 0) { $batch[$bi - 1] } else { $null }); $next = $(if ($bi -ge 0 -and $bi -lt $batch.Count - 1) { $batch[$bi + 1] } else { $null })
    $arrive = $null
    if ($portals) {
        foreach ($from in @($prev) + @($batch)) {
            if (-not $from -or -not $portals.PSObject.Properties[$from]) { continue }
            $d = @($portals.$from | Where-Object { [string]$_.to -eq $room -and $_.land }) | Select-Object -First 1
            if ($d) { $arrive = [ordered]@{ from = $from; land = @($d.land) }; break }
        }
    }
    $own = Join-Path $RoomsDir ($room + '.json')
    [ordered]@{
        room = $room; objVersion = $ver; objMtime = (Get-Item $obj).LastWriteTimeUtc.ToString('o')
        roomFile = $(if (Test-Path $own) { 'rooms\' + $room + '.json' } else { $null }); roomFileMtime = $(if (Test-Path $own) { (Get-Item $own).LastWriteTimeUtc.ToString('o') } else { $null })
        materials = (Get-Materials $room); doors = $doors; arrive = $arrive; prev = $prev; next = $next
        mirrorZ = [bool]$cfg.mirrorZ; eyeHeight = [double]$cfg.eyeHeight
    }
}
function Get-RoomList {
    $count = @{}
    foreach ($nf in @(Get-ChildItem $NotesDir -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -notin 'rounds', 'submit' })) {
        try { $doc = Read-RoomNotes $NotesDir $nf.BaseName; $count[$nf.BaseName.ToUpperInvariant()] = @(@($doc.notes | Where-Object { $_.status -eq 'new' }).Count, @($doc.notes | Where-Object { $_.status -eq 'review' }).Count) } catch { }
    }
    $all = @(Get-ChildItem $RenderDir -Filter '*.obj' | ForEach-Object { $_.BaseName.ToUpperInvariant() } | Sort-Object -Unique)
    $list = @()
    foreach ($r in @($batch | Where-Object { $all -contains $_ }) + @($all | Where-Object { $batch -notcontains $_ })) {
        $c = $count[$r]
        $list += [ordered]@{ name = $r; batch = [Array]::IndexOf($batch, $r); hidden = ($hidden -contains $r); new = $(if ($c) { $c[0] } else { 0 }); review = $(if ($c) { $c[1] } else { 0 }) }
    }
    return , $list
}

# ---- notes: the shared notes module (tools\RoomNotes.ps1: the note's log, new -> review -> complete, rounds) --------
. (Join-Path $toolDir 'RoomNotes.ps1')
$NOTE_FIELDS = 'kind', 'point', 'normal', 'part', 'material', 'texture', 'uv', 'target', 'camera', 'suggest', 'seen'
# ---- keeping a room's export current: if its .XAF (geometry) or .RES (textures) is newer than the export, export
# again before serving it (Export-XafObj's own -IfStale only checks the format version, not the files' dates)
function Update-RoomExport([string]$room) {
    $obj = Join-Path $RenderDir ($room + '.obj'); $xaf = Join-Path $TexDir ($room + '.XAF'); $res = Join-Path $TexDir ($room + '.RES')
    if (-not (Test-Path $xaf) -or -not (Test-Path $obj)) { return $null }
    $ot = (Get-Item $obj).LastWriteTimeUtc
    $why = @(); if ((Get-Item $xaf).LastWriteTimeUtc -gt $ot) { $why += 'geometry' }; if ((Test-Path $res) -and (Get-Item $res).LastWriteTimeUtc -gt $ot) { $why += 'textures' }
    if (-not $why.Count) { return $null }
    Write-Host ("  {0}: the game's {1} changed since the export -- exporting again" -f $room, ($why -join ' and ')) -ForegroundColor Cyan
    try { & (Join-Path $toolDir 'Export-XafObj.ps1') -Xaf $room -TexDir $TexDir -OutDir $RenderDir *>&1 | Out-Null; return ($why -join ' and ') }
    catch { Write-Host ("  export failed: {0}" -f $_.Exception.Message) -ForegroundColor Red; return $null }
}

# ---- "Render this view": the true-colour renderer, offline, from the viewer's camera (tools\Render-RoomView.ps1) --------
# One at a time, in its own process (the server keeps answering meanwhile); the newest 40 pictures are kept.
$script:renderJob = $null
function Start-RenderJob([string]$room, $pose) {
    if ($script:renderJob -and -not $script:renderJob.Proc.HasExited) { return $null }
    New-Item -ItemType Directory -Force $RendersDir | Out-Null
    $old = @(Get-ChildItem $RendersDir -Filter '*.png' | Where-Object { $_.Name -match '^[A-Z0-9_-]+-\d{9,12}\.png$' } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 39)
    foreach ($o in $old) { [IO.File]::Delete($o.FullName) }
    $id = (Get-Date).ToString('MMddHHmmssf'); $out = Join-Path $RendersDir ('{0}-{1}.png' -f $room, $id)
    $inv = [Globalization.CultureInfo]::InvariantCulture; $num = { param($v) ([double]$v).ToString('0.###', $inv) }
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Room {1} -X {2} -Y {3} -Z {4} -Yaw {5} -Pitch {6} -Out "{7}"' -f (Join-Path $toolDir 'Render-RoomView.ps1'), $room, (& $num $pose.X), (& $num $pose.Y), (& $num $pose.Z), (& $num $pose.Yaw), (& $num $pose.Pitch), $out
    $p = Start-Process powershell -ArgumentList $argLine -WindowStyle Hidden -PassThru
    $script:renderJob = [pscustomobject]@{ Id = $id; Room = $room; Out = $out; Proc = $p; Started = [DateTime]::UtcNow }
    return $id
}

# ---- routing ------------------------------------------------------------------------------------------------------
$STATIC = @{ 'viewer.js' = 'text/javascript; charset=utf-8'; 'viewer.css' = 'text/css; charset=utf-8' }
function Invoke-Route([string]$method, [string]$path, [string]$query, [hashtable]$hdr, [byte[]]$body) {
    $q = @{}; foreach ($kv in ($query -split '&')) { if ($kv) { $i = $kv.IndexOf('='); if ($i -gt 0) { $q[$kv.Substring(0, $i)] = [Uri]::UnescapeDataString($kv.Substring($i + 1)) } else { $q[$kv] = '1' } } }
    $seg = @($path.Trim('/') -split '/' | Where-Object { $_ -ne '' } | ForEach-Object { [Uri]::UnescapeDataString($_) })
    $mutating = $method -ne 'GET' -and $method -ne 'HEAD'
    if ($mutating) {
        # only the viewer itself may change notes: a custom header (a cross-site page cannot send it without a
        # preflight this server never approves) and, if the browser says where it came from, this origin
        if ($hdr['X-Review'] -ne '1') { return (Err 403 'missing X-Review header') }
        $origin = $hdr['Origin']; if ($origin -and $origin -ne "http://localhost:$script:port" -and $origin -ne "http://127.0.0.1:$script:port") { return (Err 403 'foreign origin') }
    }
    if ($seg.Count -eq 0) { return (FileResp (Join-Path $webDir 'index.html') 'text/html; charset=utf-8' @{ 'Cache-Control' = 'no-store' }) }
    switch ($seg[0]) {
        'static' {
            if ($seg.Count -ne 2 -or -not $STATIC.ContainsKey($seg[1])) { return (Err 404 'no such file') }
            return (FileResp (Join-Path $webDir $seg[1]) $STATIC[$seg[1]] @{ 'Cache-Control' = 'no-store' })
        }
        'renders' {
            if ($seg.Count -ne 3 -or -not (Test-Room $seg[1]) -or $seg[2] -notmatch '^\d{9,12}\.png$') { return (Err 404 'no such render') }
            $f = Inside $RendersDir ('{0}-{1}' -f $seg[1].ToUpperInvariant(), $seg[2]); if (-not $f -or -not (Test-Path $f)) { return (Err 404 'no such render') }
            return (FileResp $f 'image/png' @{ 'Cache-Control' = 'max-age=3600' })
        }
        'shots' {
            if ($seg.Count -ne 3 -or -not (Test-Room $seg[1]) -or $seg[2] -notmatch '^\d{1,6}(-\d{1,4})?(-render)?\.png$') { return (Err 404 'no such shot') }
            $f = Inside $NotesDir ('{0}-{1}' -f $seg[1].ToUpperInvariant(), $seg[2]); if (-not $f -or -not (Test-Path $f)) { return (Err 404 'no such shot') }
            return (FileResp $f 'image/png' @{ 'Cache-Control' = 'max-age=600' })
        }        'rooms' {
            if ($seg.Count -lt 3 -or -not (Test-Room $seg[1])) { return (Err 404 'no such room') }
            $room = $seg[1].ToUpperInvariant()
            if ($seg.Count -eq 3 -and $seg[2] -ieq ($room + '.obj')) { return (FileResp (Join-Path $RenderDir ($room + '.obj')) 'text/plain; charset=utf-8' @{ 'Cache-Control' = 'no-store' }) }
            if ($seg.Count -eq 4 -and ($seg[2] -eq 'tex' -or $seg[2] -eq 'tex-orig')) {
                # only a texture this room's own materials name
                $leaf = $seg[3]; $mats = Get-Materials $room; $m = $null; foreach ($mm in $mats) { if ($mm.map -and $mm.map -ieq $leaf) { $m = $mm; break } }
                if (-not $m) { return (Err 404 'not one of this room''s textures') }
                if ($seg[2] -eq 'tex' -and -not $q['lo'] -and $HiresDir) { $h = Inside $HiresDir $m.map; if ($h -and (Test-Path $h)) { return (FileResp $h 'image/png' @{ 'X-Texture-Source' = 'hires'; 'Cache-Control' = 'max-age=600' }) } }
                $c = Inside $RenderDir $m.map; if (-not $c -or -not (Test-Path $c)) { return (Err 404 'texture missing') }
                return (FileResp $c 'image/png' @{ 'X-Texture-Source' = 'cache'; 'Cache-Control' = 'max-age=600' })
            }
            return (Err 404 'no such file')
        }
        'api' {
            if ($seg.Count -eq 2 -and $seg[1] -eq 'rooms') { return (Json (Get-RoomList)) }
            if ($seg.Count -ge 3 -and $seg[1] -eq 'rooms') {
                if (-not (Test-Room $seg[2])) { return (Err 404 'no such room') }
                $room = $seg[2].ToUpperInvariant()
                if ($seg.Count -eq 3) { $ref = Update-RoomExport $room; $man = Get-Manifest $room; $man.refreshed = $ref; return (Json $man) }
                if ($seg[3] -eq 'render') {
                    if ($seg.Count -eq 4 -and $method -eq 'POST') {
                        $in = $utf8.GetString($body) | ConvertFrom-Json
                        foreach ($k in 'X', 'Y', 'Z', 'Yaw', 'Pitch') { $v = 0.0; if (-not [double]::TryParse([string]$in.$k, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return (Err 400 "bad $k") } }
                        $id = Start-RenderJob $room $in
                        if (-not $id) { return (Err 409 'a render is already running') }
                        return (Json @{ id = $id })
                    }
                    if ($seg.Count -eq 5 -and $method -eq 'GET') {
                        $j = $script:renderJob
                        if (-not $j -or $j.Id -ne $seg[4] -or $j.Room -ne $room) { return (Err 404 'no such render') }
                        $secs = [Math]::Round(([DateTime]::UtcNow - $j.Started).TotalSeconds, 1)
                        $state = $(if (-not $j.Proc.HasExited) { 'running' } elseif (Test-Path $j.Out) { 'done' } else { 'error' })
                        return (Json @{ state = $state; seconds = $secs; image = $(if ($state -eq 'done') { '/renders/{0}/{1}.png' -f $room, $j.Id } else { $null }) })
                    }
                    return (Err 405 'not allowed')
                }
                if ($seg[3] -eq 'atmosphere') {
                    $atm = Get-RoomAtmosphere @($room)
                    return (Json ([ordered]@{ fog = $atm.Fog; dust = $atm.Dust; lights = @($atm.Lights); mist = $atm.Mist; drips = $atm.Drips; steam = $atm.Steam; kickup = $atm.Kickup; embers = $atm.Embers; volume = $atm.Volume; source = @($atm.Source) }))
                }
                if ($seg[3] -eq 'notes') {
                    $doc = Read-RoomNotes $NotesDir $room
                    if ($seg.Count -eq 4 -and $method -eq 'GET') { return (Json $doc) }
                    if ($body.Length -gt 1MB -and -not ($seg.Count -eq 6 -and $seg[5] -eq 'shot')) { return (Err 413 'too large') }
                    if ($seg.Count -eq 4 -and $method -eq 'POST') {
                        # a new note: its place and view, and Josh's first message
                        $in = $utf8.GetString($body) | ConvertFrom-Json
                        if (-not [string]$in.text) { return (Err 400 'a note needs text') }
                        $now = [DateTime]::UtcNow.ToString('o'); $id = [int]$doc.nextId
                        $note = [ordered]@{ id = $id; ref = ('{0}/{1}' -f $room, $id); status = 'new'; created = $now; updated = $now }
                        foreach ($k in $NOTE_FIELDS) { $note[$k] = $(if ($in.PSObject.Properties[$k]) { $in.$k } else { $null }) }
                        $note.log = [object[]]@([pscustomobject]@{ who = 'josh'; text = [string]$in.text; at = $now })
                        $n = [pscustomobject]$note
                        $doc.notes = [object[]](@($doc.notes) + @($n)); $doc.nextId = $id + 1
                        Write-RoomNotes $NotesDir $room $doc
                        return (Json $n)
                    }
                    if ($seg.Count -ge 5) {
                        $id = 0; if (-not [int]::TryParse($seg[4], [ref]$id)) { return (Err 404 'no such note') }
                        $n = @($doc.notes | Where-Object { [int]$_.id -eq $id }) | Select-Object -First 1
                        if (-not $n) { return (Err 404 'no such note') }
                        if ($seg.Count -eq 6 -and $seg[5] -eq 'messages' -and $method -eq 'POST') {
                            # Josh iterates: a follow-up, and it is Claude's turn again
                            $in = $utf8.GetString($body) | ConvertFrom-Json
                            if (-not [string]$in.text) { return (Err 400 'empty message') }
                            $k = Add-RoomNoteMessage $n 'josh' ([string]$in.text)
                            Write-RoomNotes $NotesDir $room $doc
                            return (Json @{ note = $n; index = $k })
                        }
                        if ($seg.Count -eq 5 -and $method -eq 'PATCH') {
                            $in = $utf8.GetString($body) | ConvertFrom-Json
                            if ($in.PSObject.Properties['status']) {
                                # Josh marks it complete: it leaves the list (kept in 'completed')
                                if ([string]$in.status -ne 'complete') { return (Err 400 'only "complete" can be set here') }
                                $c = Complete-RoomNote $doc $id; Write-RoomNotes $NotesDir $room $doc
                                return (Json $c)
                            }
                            if ($in.PSObject.Properties['kind']) { $n.kind = [string]$in.kind }
                            if ($in.PSObject.Properties['text']) {
                                # (only his latest message, and only before Claude has answered it)
                                $last = @($n.log)[-1]
                                if ($last.who -ne 'josh') { return (Err 409 'Claude has already answered: add a follow-up instead') }
                                $last.text = [string]$in.text
                            }
                            $n.updated = [DateTime]::UtcNow.ToString('o')
                            Write-RoomNotes $NotesDir $room $doc
                            return (Json $n)
                        }
                        if ($seg.Count -eq 5 -and $method -eq 'DELETE') {
                            # recoverable: moved to 'deleted', never erased
                            $doc.notes = [object[]]@($doc.notes | Where-Object { [int]$_.id -ne $id }); $doc.deleted = [object[]](@($doc.deleted) + @($n))
                            Write-RoomNotes $NotesDir $room $doc
                            return (Json @{ deleted = $id })
                        }
                        if ($seg.Count -eq 6 -and $seg[5] -eq 'shot' -and $method -eq 'PUT') {
                            # a screenshot for one of Josh's messages (?msg=k; the first by default)
                            if ($body.Length -lt 8 -or $body.Length -gt 8MB -or $body[0] -ne 0x89 -or $body[1] -ne 0x50) { return (Err 400 'not a PNG') }
                            $k = 0; if ($q['msg']) { [void][int]::TryParse($q['msg'], [ref]$k) }
                            $log = @($n.log); if ($k -lt 0 -or $k -ge $log.Count -or $log[$k].who -ne 'josh') { return (Err 400 'no such message of yours') }
                            $leaf = '{0}-{1}-{2}.png' -f $room, $id, $k; [IO.File]::WriteAllBytes((Join-Path $NotesDir $leaf), $body)
                            $log[$k] | Add-Member shot $leaf -Force; Write-RoomNotes $NotesDir $room $doc
                            return (Json @{ shot = $leaf })
                        }
                    }
                    return (Err 405 'not allowed')
                }
            }
            if ($seg.Count -eq 2 -and $seg[1] -eq 'rounds') { return (Json (Get-RoomRounds $NotesDir)) }
            if ($seg.Count -eq 2 -and $seg[1] -eq 'submit') {
                # "Submit update": tell Claude the notes are ready (Claude's background watcher sees submit.json change)
                $sub = Get-RoomSubmit $NotesDir; $counts = Get-RoomNewCounts $NotesDir; $total = 0; foreach ($v in $counts.Values) { $total += [int]$v }
                if ($method -eq 'POST') {
                    if ($total -eq 0) { return (Json @{ state = 'empty'; total = 0; message = 'No new notes or follow-ups to send.' }) }
                    $sub = [pscustomobject]@{ id = [int]$sub.id + 1; at = [DateTime]::UtcNow.ToString('o'); total = $total; rooms = $counts; state = 'waiting'; round = $null }
                    Save-RoomSubmit $NotesDir $sub
                    Write-Host ("  SUBMITTED: {0} note(s) for Claude ({1})" -f $total, (($counts.Keys | ForEach-Object { '{0} {1}' -f $_, $counts[$_] }) -join ', ')) -ForegroundColor Green
                    return (Json $sub)
                }
                # (GET) where it stands; 'working' becomes 'done' once nothing is waiting on Claude
                if ($sub.state -eq 'working' -and $total -eq 0) { $sub.state = 'done'; Save-RoomSubmit $NotesDir $sub }
                $sub | Add-Member pending $total -Force
                return (Json $sub)
            }            if ($seg.Count -eq 2 -and $seg[1] -eq 'shutdown' -and $method -eq 'POST') { $script:stop = $true; return (Json @{ stopping = $true }) }
            return (Err 404 'no such api')
        }
    }
    return (Err 404 'not found')
}
function Invoke-Safe([string]$method, [string]$path, [string]$query, [hashtable]$hdr, [byte[]]$body) {
    try { return (Invoke-Route $method $path $query $hdr $body) }
    catch { Write-Host ("  error: {0}" -f $_.Exception.Message) -ForegroundColor Red; return (Err 500 $_.Exception.Message) }
}

# ---- the transport -------------------------------------------------------------------------------------------------
$script:stop = $false; $script:port = $Port
$ports = $(if ($StrictPort) { @($Port) } else { $Port..($Port + 10) })
$hl = $null; $mini = $null
foreach ($p in $ports) {
    if ($Transport -ne 'Tcp') {
        $l = New-Object System.Net.HttpListener; $l.Prefixes.Add("http://localhost:$p/")
        try { $l.Start(); $hl = $l; $script:port = $p; break }
        catch { $l.Close() }
    }
    if ($Transport -ne 'HttpListener') {
        try { $m = New-Object AztTool.MiniHttp; $m.Start($p); $mini = $m; $script:port = $p; break } catch { }
    }
}
if (-not $hl -and -not $mini) { throw "no free port in $($ports -join ', ')" }
$url = "http://localhost:$script:port/"
Write-Host ''
Write-Host ("ROOM REVIEW at {0}  ({1})" -f $url, $(if ($hl) { 'HttpListener' } else { 'loopback TCP' })) -ForegroundColor Cyan
Write-Host ("  rooms from {0}; notes to {1}" -f $RenderDir, $NotesDir) -ForegroundColor Gray
Write-Host '  Close this window (or Ctrl+C) to stop.' -ForegroundColor Gray
if (-not $NoBrowser) { Start-Process $url }

function Log([string]$m, [string]$p, [int]$s, [double]$ms) { Write-Host ('{0:HH:mm:ss} {1,-6} {2} {3} {4:N0} ms' -f (Get-Date), $m, $p, $s, $ms) -ForegroundColor $(if ($s -ge 400) { 'Yellow' } else { 'DarkGray' }) }
try {
    while (-not $script:stop) {
        if ($hl) {
            $ar = $hl.BeginGetContext($null, $null)
            while (-not $ar.AsyncWaitHandle.WaitOne(250)) { if ($script:stop) { break } }
            if ($script:stop) { break }
            $ctx = $hl.EndGetContext($ar); $rq = $ctx.Request; $sw = [Diagnostics.Stopwatch]::StartNew()
            $hdr = @{}; foreach ($k in $rq.Headers.AllKeys) { $hdr[$k] = $rq.Headers[$k] }
            $body = New-Object byte[] 0
            if ($rq.HasEntityBody) { $ms = New-Object IO.MemoryStream; $rq.InputStream.CopyTo($ms); $body = $ms.ToArray() }
            $res = Invoke-Safe $rq.HttpMethod $rq.Url.AbsolutePath $rq.Url.Query.TrimStart('?') $hdr $body
            try {
                $ctx.Response.StatusCode = $res.Status; $ctx.Response.ContentType = $res.Type
                foreach ($k in $res.Headers.Keys) { $ctx.Response.Headers[$k] = [string]$res.Headers[$k] }
                $ctx.Response.ContentLength64 = $res.Body.Length
                if ($rq.HttpMethod -ne 'HEAD') { $ctx.Response.OutputStream.Write($res.Body, 0, $res.Body.Length) }
            } catch { } finally { try { $ctx.Response.Close() } catch { } }
            Log $rq.HttpMethod $rq.Url.AbsolutePath $res.Status $sw.Elapsed.TotalMilliseconds
        } else {
            $rq = $mini.Accept(250); if (-not $rq) { continue }
            $sw = [Diagnostics.Stopwatch]::StartNew(); $hdr = @{}; foreach ($k in $rq.Headers.Keys) { $hdr[$k] = $rq.Headers[$k] }
            $res = Invoke-Safe $rq.Method $rq.Path $rq.Query $hdr $rq.Body
            $hd = New-Object 'System.Collections.Generic.Dictionary[string,string]'; foreach ($k in $res.Headers.Keys) { $hd[$k] = [string]$res.Headers[$k] }
            $rq.Respond($res.Status, $res.Type, $res.Body, $hd)
            Log $rq.Method $rq.Path $res.Status $sw.Elapsed.TotalMilliseconds
        }
    }
} finally {
    if ($script:renderJob -and -not $script:renderJob.Proc.HasExited) { try { $script:renderJob.Proc.Kill() } catch { } }
    if ($hl) { try { $hl.Stop(); $hl.Close() } catch { } }
    if ($mini) { $mini.Stop() }
    Write-Host 'room review stopped.' -ForegroundColor Gray
}
