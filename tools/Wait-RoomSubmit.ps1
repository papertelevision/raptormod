# Wait-RoomSubmit.ps1 -- Claude's side of Room Review's "Submit update" button (2026-10-08). Run in the background; it
# returns (and so wakes Claude) when Josh presses Submit -- room-notes\submit.json in state 'waiting' -- with what was
# sent. Then Claude runs Start-RoomRound.ps1, works the notes, replies (Reply-RoomNote.ps1), and starts this again.
#
#   .\tools\Wait-RoomSubmit.ps1 [-PollSeconds 3]
param(
    [string]$RenderDir = 'C:\Games\azrael-render',
    [string]$NotesDir = '',
    [double]$PollSeconds = 3
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolDir 'RoomNotes.ps1')
if (-not $NotesDir) { $NotesDir = Join-Path $RenderDir 'room-notes' }
New-Item -ItemType Directory -Force $NotesDir | Out-Null
while ($true) {
    try {
        $s = Get-RoomSubmit $NotesDir
        if ($s.state -eq 'waiting') {
            $rooms = $(if ($s.rooms) { ($s.rooms.PSObject.Properties | ForEach-Object { '{0} {1}' -f $_.Name, $_.Value }) -join ', ' } else { '' })
            Write-Output ("SUBMITTED #{0} at {1}: {2} note(s) for Claude -- {3}" -f $s.id, $s.at, $s.total, $rooms)
            Write-Output 'Next: .\tools\Start-RoomRound.ps1, work the notes, .\tools\Reply-RoomNote.ps1 for each, then run this again.'
            exit 0
        }
    } catch { }
    Start-Sleep -Seconds $PollSeconds
}
