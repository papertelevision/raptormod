# Start-RoomRound.ps1 -- Claude starts a ROUND of work on Josh's Room Review notes (2026-10-08).
#
# Before any room setting is touched, every atmosphere file (C:\Games\azrael-render\rooms\*.json) is copied to
# rooms-history\round-NNN -- the state BEFORE that round -- so any round can be undone (Restore-RoomRound.ps1). Then the
# notes waiting on Claude (status 'new') are listed, oldest first, with everything needed to act on them.
#
#   .\tools\Start-RoomRound.ps1            snapshot, number the round, list the work
#   .\tools\Start-RoomRound.ps1 -ListOnly  just list (no new round)
param(
    [string]$RenderDir = 'C:\Games\azrael-render',
    [string]$NotesDir = '',
    [switch]$ListOnly
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolDir 'RoomNotes.ps1')
if (-not $NotesDir) { $NotesDir = Join-Path $RenderDir 'room-notes' }
New-Item -ItemType Directory -Force $NotesDir | Out-Null

# the work: every note whose turn is Claude's
$work = @()
foreach ($nf in @(Get-ChildItem $NotesDir -Filter '*.json' | Where-Object { $_.BaseName -notin 'rounds', 'submit' -and $_.Name -notlike '*.suggest.json' } | Sort-Object Name)) {      # (not the painted-light finder's pins)
    $doc = Read-RoomNotes $NotesDir $nf.BaseName
    foreach ($n in @($doc.notes | Where-Object { $_.status -eq 'new' })) { $work += [pscustomobject]@{ Room = $doc.room; Note = $n } }
}

$rounds = Get-RoomRounds $NotesDir
if (-not $ListOnly) {
    $n = [int]$rounds.current + 1
    $snap = Join-Path $RenderDir ('rooms-history\round-{0:D3}' -f $n)
    New-Item -ItemType Directory -Force $snap | Out-Null
    $files = @(Get-ChildItem (Join-Path $RenderDir 'rooms') -Filter '*.json' -File)
    foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $snap $f.Name) -Force }
    $rounds.current = $n
    $rounds.rounds = [object[]](@($rounds.rounds) + @([pscustomobject]@{ n = $n; started = [DateTime]::UtcNow.ToString('o'); snapshot = $snap; files = $files.Count; notes = @($work | ForEach-Object { '{0}/{1}' -f $_.Room, $_.Note.id }) }))
    Save-RoomRounds $NotesDir $rounds
    # a waiting "Submit update" is now being worked on (the viewer shows it)
    $sub = Get-RoomSubmit $NotesDir
    if ($sub.state -eq 'waiting') { $sub.state = 'working'; $sub.round = $n; Save-RoomSubmit $NotesDir $sub }
    Write-Host ("ROUND {0}: {1} room settings files snapshotted to {2}" -f $n, $files.Count, $snap) -ForegroundColor Cyan
}
Write-Host ("{0} note(s) waiting on Claude" -f $work.Count) -ForegroundColor $(if ($work.Count) { 'Yellow' } else { 'Green' })
foreach ($w in $work) {
    $n = $w.Note
    Write-Host ''
    Write-Host ("{0}/{1}  [{2}]  {3}" -f $w.Room, $n.id, $n.kind, $(if ($n.part) { "on $($n.part) ($($n.material); $($n.texture)) at $($n.point -join ', ')" } elseif ($n.target) { "on $($n.target.name)" } else { 'the whole room' })) -ForegroundColor Cyan
    if ($n.normal) { Write-Host ("   facing {0}; suggested light {1},{2},{3} dir {4}" -f ($n.normal -join ','), $n.suggest.light.x, $n.suggest.light.y, $n.suggest.light.z, ($n.suggest.light.dir -join ',')) -ForegroundColor DarkGray }
    if ($n.camera) { $g = $n.camera.gpuLook; Write-Host ("   view: -X {0} -Y {1} -Z {2} -Yaw {3} -Pitch {4}" -f $g.X, $g.Y, $g.Z, $g.Yaw, $g.Pitch) -ForegroundColor DarkGray }
    foreach ($m in @($n.log)) { Write-Host ("   {0,-6} {1}{2}" -f $m.who, $m.text, $(if ($m.shot) { "   [shot $($m.shot)]" } elseif ($m.render) { "   [render $($m.render)]" } else { '' })) }
}
