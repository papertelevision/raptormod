# RoomNotes.ps1 -- the Room Review notes files, shared by the server (Start-RoomReview.ps1) and Claude's tools
# (Reply-RoomNote.ps1, Start-RoomRound.ps1). Dot-source it.
#
# A note is a CONVERSATION about one spot (or the whole room), worked in rounds (Josh, 2026-10-08):
#   new       -- Josh has written (the first note, or a follow-up): Claude's turn
#   review    -- Claude has made the change and replied (what changed, a render from the note's view): Josh's turn
#   complete  -- Josh is happy: it leaves the list (kept in the file's 'completed', never erased)
# Every message is kept in the note's 'log': {who: josh|claude, text, at, shot?, render?, changes?, round?}.
#
# File: room-notes\<ROOM>.json = { schema 2, room, rev, nextId, notes[], completed[], deleted[] }, UTF-8 without BOM,
# written atomically (temp + replace). Schema 1 files (status open/done, text + reply) are converted on read.
$script:RN_utf8 = New-Object System.Text.UTF8Encoding($false)
$script:RN_Statuses = @('new', 'review', 'complete')

function Get-RoomNotesPath([string]$NotesDir, [string]$Room) { Join-Path $NotesDir ($Room.ToUpperInvariant() + '.json') }

function Read-RoomNotes([string]$NotesDir, [string]$Room) {
    $p = Get-RoomNotesPath $NotesDir $Room
    if (-not (Test-Path $p)) { return [pscustomobject]@{ schema = 2; room = $Room.ToUpperInvariant(); rev = 0; nextId = 1; notes = [object[]]@(); completed = [object[]]@(); deleted = [object[]]@() } }
    $doc = [IO.File]::ReadAllText($p, $script:RN_utf8) | ConvertFrom-Json
    foreach ($k in 'notes', 'completed', 'deleted') {
        if (-not $doc.PSObject.Properties[$k]) { $doc | Add-Member $k @() }
        $doc.$k = [object[]]@($doc.$k | Where-Object { $_ })
    }
    if ([int]$doc.schema -lt 2) {
        # schema 1: text + reply + status open/done/question/wontfix -> a log, and new/review
        foreach ($n in @($doc.notes) + @($doc.deleted)) {
            if ($n.PSObject.Properties['log']) { continue }
            $log = @([pscustomobject]@{ who = 'josh'; text = [string]$n.text; at = $n.created; shot = $n.screenshot })
            if ($n.reply) { $log += [pscustomobject]@{ who = 'claude'; text = [string]$n.reply; at = $n.replied; changes = @($n.changes) } }
            $n | Add-Member log ([object[]]$log) -Force
            $n.status = $(if ($n.status -eq 'open') { 'new' } else { 'review' })
        }
        $doc.schema = 2
    }
    return $doc
}

function Write-RoomNotes([string]$NotesDir, [string]$Room, $doc) {
    $doc.rev = [int]$doc.rev + 1
    $p = Get-RoomNotesPath $NotesDir $Room; $tmp = $p + '.tmp'
    $json = ConvertTo-Json -InputObject $doc -Depth 14
    for ($try = 0; $try -lt 4; $try++) {
        try {
            [IO.File]::WriteAllText($tmp, $json, $script:RN_utf8)
            # ([NullString]: PowerShell passes $null to a string parameter as "", which Replace refuses)
            if (Test-Path $p) { [IO.File]::Replace($tmp, $p, [NullString]::Value) } else { [IO.File]::Move($tmp, $p) }
            return
        } catch [IO.IOException] { Start-Sleep -Milliseconds 80 }
    }
    throw "could not write $p"
}

# a message on a note: who, text, and (Claude) what changed, a render, the round; sets the status for the other side
function Add-RoomNoteMessage($note, [string]$who, [string]$text, [hashtable]$extra = @{}) {
    $m = [ordered]@{ who = $who; text = $text; at = [DateTime]::UtcNow.ToString('o') }
    foreach ($k in $extra.Keys) { $m[$k] = $extra[$k] }
    if (-not $note.PSObject.Properties['log']) { $note | Add-Member log @() }
    $note.log = [object[]](@($note.log) + @([pscustomobject]$m))
    $note.status = $(if ($who -eq 'claude') { 'review' } else { 'new' })
    $note.updated = $m.at
    return ($note.log.Count - 1)
}

# move a note to 'completed' (Josh's call)
function Complete-RoomNote($doc, [int]$id) {
    $n = @($doc.notes | Where-Object { [int]$_.id -eq $id }) | Select-Object -First 1
    if (-not $n) { return $null }
    $n.status = 'complete'; $n | Add-Member completedAt ([DateTime]::UtcNow.ToString('o')) -Force
    $doc.notes = [object[]]@($doc.notes | Where-Object { [int]$_.id -ne $id })
    $doc.completed = [object[]](@($doc.completed) + @($n))
    return $n
}

# ---- rounds: one per pass Claude makes over the notes; the room settings are snapshotted before each --------------
function Get-RoomRounds([string]$NotesDir) {
    $p = Join-Path $NotesDir 'rounds.json'
    if (Test-Path $p) { $r = [IO.File]::ReadAllText($p, $script:RN_utf8) | ConvertFrom-Json; $r.rounds = [object[]]@($r.rounds | Where-Object { $_ }); return $r }
    return [pscustomobject]@{ current = 0; rounds = [object[]]@() }
}
function Save-RoomRounds([string]$NotesDir, $r) { [IO.File]::WriteAllText((Join-Path $NotesDir 'rounds.json'), (ConvertTo-Json -InputObject $r -Depth 6), $script:RN_utf8) }

# ---- "Submit update" (2026-10-08): Josh tells Claude from the viewer that notes are ready. room-notes\submit.json =
# { id, at, total, rooms {ROOM: new count}, state: waiting -> working (Start-RoomRound picks it up) -> done (no 'new' left) }
function Get-RoomSubmit([string]$NotesDir) {
    $p = Join-Path $NotesDir 'submit.json'
    if (Test-Path $p) { return [IO.File]::ReadAllText($p, $script:RN_utf8) | ConvertFrom-Json }
    return [pscustomobject]@{ id = 0; at = $null; total = 0; rooms = $null; state = 'idle'; round = $null }
}
function Save-RoomSubmit([string]$NotesDir, $s) {
    $p = Join-Path $NotesDir 'submit.json'; $tmp = $p + '.tmp'
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $s -Depth 5), $script:RN_utf8)
    if (Test-Path $p) { [IO.File]::Replace($tmp, $p, [NullString]::Value) } else { [IO.File]::Move($tmp, $p) }
}
# every room's notes waiting on Claude
function Get-RoomNewCounts([string]$NotesDir) {
    $c = [ordered]@{}
    foreach ($nf in @(Get-ChildItem $NotesDir -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -notin 'rounds', 'submit' })) {
        $doc = Read-RoomNotes $NotesDir $nf.BaseName; $n = @($doc.notes | Where-Object { $_.status -eq 'new' }).Count
        if ($n) { $c[$doc.room] = $n }
    }
    return $c
}
