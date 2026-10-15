# Reply-RoomNote.ps1 -- Claude answers one Room Review note (2026-10-08): the reply text, what was changed, and a RENDER
# of the note's own view through the true-colour renderer -- flashlight off and on, side by side -- so Josh sees the
# real lit, fogged result in the viewer without reaching that room in the game. The note goes to 'review' (Josh's turn).
#
#   .\tools\Reply-RoomNote.ps1 -Room CORICORI -Id 3 -Text "Added a warm torch..." -Changes 'rooms\CORICORI.json lights[1] added'
#   ... -NoRender     (a reply that needs no picture, e.g. a question)
param(
    [Parameter(Mandatory)][string]$Room,
    [Parameter(Mandatory)][int]$Id,
    [Parameter(Mandatory)][string]$Text,
    [string[]]$Changes = @(),
    [switch]$NoRender,
    [string]$RenderFile = '',     # (an image made elsewhere -- e.g. a map note's before | after of the 3D map -- attached instead of the view render)
    [int]$Width = 960, [int]$Height = 540,
    [string]$RenderDir = 'C:\Games\RaptorMod\cache',
    [string]$NotesDir = ''
)
$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $toolDir 'RoomNotes.ps1')
if (-not $NotesDir) { $NotesDir = Join-Path $RenderDir 'room-notes' }
$Room = $Room.ToUpperInvariant()
$doc = Read-RoomNotes $NotesDir $Room
$n = @($doc.notes | Where-Object { [int]$_.id -eq $Id }) | Select-Object -First 1
if (-not $n) { throw "no open note $Room/$Id" }
$k = @($n.log).Count          # (the index this reply will have)

$render = $null
if ($RenderFile) {
    if (-not (Test-Path $RenderFile)) { throw "no such image: $RenderFile" }
    $render = '{0}-{1}-{2}-render.png' -f $Room, $Id, $k; Copy-Item $RenderFile (Join-Path $NotesDir $render) -Force
} elseif (-not $NoRender -and $n.camera -and $n.camera.gpuLook) {
    # the note's view through the renderer (tools\Render-RoomView.ps1: flashlight off | on)
    $g = $n.camera.gpuLook; $render = '{0}-{1}-{2}-render.png' -f $Room, $Id, $k
    & (Join-Path $toolDir 'Render-RoomView.ps1') -Room $Room -X $g.X -Y $g.Y -Z $g.Z -Yaw $g.Yaw -Pitch $g.Pitch -Out (Join-Path $NotesDir $render) -Width $Width -Height $Height
}
# re-read just before writing (the viewer may have changed the file while rendering), then add the reply
$doc = Read-RoomNotes $NotesDir $Room
$n = @($doc.notes | Where-Object { [int]$_.id -eq $Id }) | Select-Object -First 1
if (-not $n) { throw "note $Room/$Id is no longer open" }
$extra = @{ round = [int](Get-RoomRounds $NotesDir).current; changes = [object[]]@($Changes) }
if ($render) { $extra.render = $render }
[void](Add-RoomNoteMessage $n 'claude' $Text $extra)
Write-RoomNotes $NotesDir $Room $doc
Write-Host ("{0}/{1} -> review{2}" -f $Room, $Id, $(if ($render) { " (render $render)" } else { '' })) -ForegroundColor Green
