# AztTester.ps1 -- a small window for testing cutscenes and warping between rooms,
# so none of it needs the command prompt. Launch it from AztTester.bat.
#
# It does not reimplement anything: every button shells out to the same scripts you would
# run by hand (tools\Test-Movie.ps1, tools\Set-SaveRoom.ps1, Play-Azrael-Staging.bat) and
# shows their output in the log pane. If a button works here it works there, and vice versa.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$AZTMOD   = $PSScriptRoot
$GAMEROOT = 'C:\Games\AzraelsTear-Modded'
$MOVDIR   = Join-Path $GAMEROOT 'GAME\MOV'
$PLAYBAT  = Join-Path $GAMEROOT 'Play-Azrael-Staging.bat'
$ROOMCSV  = 'C:\Games\azrael-rooms.csv'
$BUFFER   = 819200

# ---------- helpers ---------------------------------------------------------------------

$script:log = $null
function Log([string]$text, [string]$colour = 'Black') {
    if (-not $script:log) { return }
    $script:log.SelectionStart  = $script:log.TextLength
    $script:log.SelectionColor  = [System.Drawing.Color]::FromName($colour)
    $script:log.AppendText($text.TrimEnd() + [Environment]::NewLine)
    $script:log.SelectionStart  = $script:log.TextLength
    $script:log.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# Run one of the tool scripts and echo everything it printed. Write-Host goes to the
# information stream, so *>&1 is what actually captures it -- a plain pipe returns nothing.
function Run-Tool([string]$script, [hashtable]$params) {
    $path = Join-Path $AZTMOD $script
    try {
        $out = & $path @params *>&1 | Out-String
        foreach ($line in ($out -split "`r?`n")) { if ($line.Trim()) { Log ('    ' + $line.TrimEnd()) } }
        return $true
    } catch {
        Log ('    ERROR: ' + $_.Exception.Message) 'Firebrick'
        return $false
    }
}

function Get-MovInfo([string]$path) {
    $fs = [IO.File]::OpenRead($path)
    try {
        $br = New-Object IO.BinaryReader $fs
        if ($br.ReadUInt32() -ne [Convert]::ToUInt32('AB12EF90',16)) { return $null }
        $null = $br.ReadUInt32()
        $frames = $br.ReadUInt16(); $fps = $br.ReadUInt16()
        $w = $br.ReadUInt16(); $h = $br.ReadUInt16()
        [pscustomobject]@{ Frames=$frames; Fps=$fps; Width=$w; Height=$h; Bytes=(Get-Item $path).Length }
    } finally { $fs.Dispose() }
}

function Launch-Game([string]$what) {
    Log ''
    Log "launching the game ($what) -- this window waits until you quit it..." 'DarkBlue'
    [System.Windows.Forms.Application]::DoEvents()
    try { Start-Process -FilePath $PLAYBAT -WorkingDirectory $GAMEROOT -Wait }
    catch { Log ('    could not launch: ' + $_.Exception.Message) 'Firebrick'; return $false }
    Log 'game exited.' 'DarkBlue'
    return $true
}

# ---------- window ----------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "Azrael's Tear - test bench"
$form.Size = New-Object System.Drawing.Size(720, 640)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(10, 10)
$tabs.Size = New-Object System.Drawing.Size(685, 320)
$form.Controls.Add($tabs)

# ===== MOVIES tab =======================================================================
$tabMov = New-Object System.Windows.Forms.TabPage
$tabMov.Text = 'Cutscenes'
$tabMov.BackColor = [System.Drawing.Color]::White
$tabs.TabPages.Add($tabMov)

$l1 = New-Object System.Windows.Forms.Label
$l1.Text = 'Movie:'; $l1.Location = New-Object System.Drawing.Point(18, 24); $l1.AutoSize = $true
$tabMov.Controls.Add($l1)

$cbMovie = New-Object System.Windows.Forms.ComboBox
$cbMovie.Location = New-Object System.Drawing.Point(120, 20)
$cbMovie.Size = New-Object System.Drawing.Size(260, 24)
$cbMovie.DropDownStyle = 'DropDownList'
$tabMov.Controls.Add($cbMovie)

$lblMovInfo = New-Object System.Windows.Forms.Label
$lblMovInfo.Location = New-Object System.Drawing.Point(120, 52)
$lblMovInfo.Size = New-Object System.Drawing.Size(530, 40)
$lblMovInfo.ForeColor = [System.Drawing.Color]::DimGray
$tabMov.Controls.Add($lblMovInfo)

$l2 = New-Object System.Windows.Forms.Label
$l2.Text = 'Play in slot:'; $l2.Location = New-Object System.Drawing.Point(18, 104); $l2.AutoSize = $true
$tabMov.Controls.Add($l2)

$cbSlotM = New-Object System.Windows.Forms.ComboBox
$cbSlotM.Location = New-Object System.Drawing.Point(120, 100)
$cbSlotM.Size = New-Object System.Drawing.Size(260, 24)
$cbSlotM.DropDownStyle = 'DropDownList'
[void]$cbSlotM.Items.Add('mindlogo  (first thing at startup)')
[void]$cbSlotM.Items.Add('intro     (second thing at startup)')
$cbSlotM.SelectedIndex = 0
$tabMov.Controls.Add($cbSlotM)

$chkFps = New-Object System.Windows.Forms.CheckBox
$chkFps.Text = "Play at the movie's own frame rate (patches the call site, reverted afterwards)"
$chkFps.Location = New-Object System.Drawing.Point(120, 132)
$chkFps.Size = New-Object System.Drawing.Size(520, 24)
$chkFps.Checked = $true
$tabMov.Controls.Add($chkFps)

$btnMovGo = New-Object System.Windows.Forms.Button
$btnMovGo.Text = 'Test this cutscene'
$btnMovGo.Location = New-Object System.Drawing.Point(120, 172)
$btnMovGo.Size = New-Object System.Drawing.Size(170, 34)
$tabMov.Controls.Add($btnMovGo)

$btnMovStage = New-Object System.Windows.Forms.Button
$btnMovStage.Text = 'Stage only'
$btnMovStage.Location = New-Object System.Drawing.Point(300, 172)
$btnMovStage.Size = New-Object System.Drawing.Size(110, 34)
$tabMov.Controls.Add($btnMovStage)

$btnMovRestore = New-Object System.Windows.Forms.Button
$btnMovRestore.Text = 'Put originals back'
$btnMovRestore.Location = New-Object System.Drawing.Point(420, 172)
$btnMovRestore.Size = New-Object System.Drawing.Size(150, 34)
$tabMov.Controls.Add($btnMovRestore)

$lblMovNote = New-Object System.Windows.Forms.Label
$lblMovNote.Text = "The cutscene replaces a startup movie, so it plays a few seconds after launch. When you quit the game the originals go back automatically."
$lblMovNote.Location = New-Object System.Drawing.Point(120, 218)
$lblMovNote.Size = New-Object System.Drawing.Size(530, 50)
$lblMovNote.ForeColor = [System.Drawing.Color]::DimGray
$tabMov.Controls.Add($lblMovNote)

# ===== ROOMS tab ========================================================================
$tabRoom = New-Object System.Windows.Forms.TabPage
$tabRoom.Text = 'Warp'
$tabRoom.BackColor = [System.Drawing.Color]::White
$tabs.TabPages.Add($tabRoom)

$r1 = New-Object System.Windows.Forms.Label
$r1.Text = 'Save slot to edit:'; $r1.Location = New-Object System.Drawing.Point(18, 24); $r1.AutoSize = $true
$tabRoom.Controls.Add($r1)

$cbSaveSlot = New-Object System.Windows.Forms.ComboBox
$cbSaveSlot.Location = New-Object System.Drawing.Point(150, 20)
$cbSaveSlot.Size = New-Object System.Drawing.Size(120, 24)
$cbSaveSlot.DropDownStyle = 'DropDownList'
$tabRoom.Controls.Add($cbSaveSlot)

$r2 = New-Object System.Windows.Forms.Label
$r2.Text = 'Warp to room:'; $r2.Location = New-Object System.Drawing.Point(18, 60); $r2.AutoSize = $true
$tabRoom.Controls.Add($r2)

$cbRoom = New-Object System.Windows.Forms.ComboBox
$cbRoom.Location = New-Object System.Drawing.Point(150, 56)
$cbRoom.Size = New-Object System.Drawing.Size(360, 24)
$cbRoom.DropDownStyle = 'DropDownList'
$tabRoom.Controls.Add($cbRoom)

$r3 = New-Object System.Windows.Forms.Label
$r3.Text = 'or room id:'; $r3.Location = New-Object System.Drawing.Point(522, 60); $r3.AutoSize = $true
$tabRoom.Controls.Add($r3)

$numRoom = New-Object System.Windows.Forms.NumericUpDown
$numRoom.Location = New-Object System.Drawing.Point(592, 56)
$numRoom.Size = New-Object System.Drawing.Size(70, 24)
$numRoom.Minimum = 0; $numRoom.Maximum = 65535
$tabRoom.Controls.Add($numRoom)

$r5 = New-Object System.Windows.Forms.Label
$r5.Text = 'Spawn point:'; $r5.Location = New-Object System.Drawing.Point(18, 92); $r5.AutoSize = $true
$tabRoom.Controls.Add($r5)

# Candidates come from the room's geometry. The FIRST is the best guess; if it strands you,
# pick the next and warp again -- that is faster and more honest than me guessing at walkability
# in a room I cannot see.
$cbSpawn = New-Object System.Windows.Forms.ComboBox
$cbSpawn.Location = New-Object System.Drawing.Point(150, 88)
$cbSpawn.Size = New-Object System.Drawing.Size(512, 24)
$cbSpawn.DropDownStyle = 'DropDownList'
$tabRoom.Controls.Add($cbSpawn)

$r4 = New-Object System.Windows.Forms.Label
$r4.Text = 'Position:'; $r4.Location = New-Object System.Drawing.Point(18, 126); $r4.AutoSize = $true
$tabRoom.Controls.Add($r4)

$rbSpawn = New-Object System.Windows.Forms.RadioButton
$rbSpawn.Text = 'Use the spawn point above'
$rbSpawn.Location = New-Object System.Drawing.Point(150, 124)
$rbSpawn.Size = New-Object System.Drawing.Size(430, 22)
$rbSpawn.Checked = $true
$tabRoom.Controls.Add($rbSpawn)

$rbKeep = New-Object System.Windows.Forms.RadioButton
$rbKeep.Text = "Keep this slot's position (strands you outside the level)"
$rbKeep.Location = New-Object System.Drawing.Point(150, 146)
$rbKeep.Size = New-Object System.Drawing.Size(430, 22)
$tabRoom.Controls.Add($rbKeep)

$rbFrom = New-Object System.Windows.Forms.RadioButton
$rbFrom.Text = 'Copy room AND position from slot:'
$rbFrom.Location = New-Object System.Drawing.Point(150, 168)
$rbFrom.Size = New-Object System.Drawing.Size(230, 22)
$tabRoom.Controls.Add($rbFrom)

$cbFromSlot = New-Object System.Windows.Forms.ComboBox
$cbFromSlot.Location = New-Object System.Drawing.Point(385, 166)
$cbFromSlot.Size = New-Object System.Drawing.Size(120, 24)
$cbFromSlot.DropDownStyle = 'DropDownList'
$cbFromSlot.Enabled = $false
$tabRoom.Controls.Add($cbFromSlot)

$btnWarp = New-Object System.Windows.Forms.Button
$btnWarp.Text = 'Warp and launch'
$btnWarp.Location = New-Object System.Drawing.Point(150, 196)
$btnWarp.Size = New-Object System.Drawing.Size(150, 34)
$tabRoom.Controls.Add($btnWarp)

$btnWarpOnly = New-Object System.Windows.Forms.Button
$btnWarpOnly.Text = 'Write only'
$btnWarpOnly.Location = New-Object System.Drawing.Point(310, 196)
$btnWarpOnly.Size = New-Object System.Drawing.Size(110, 34)
$tabRoom.Controls.Add($btnWarpOnly)

$btnWarpUndo = New-Object System.Windows.Forms.Button
$btnWarpUndo.Text = 'Undo this slot'
$btnWarpUndo.Location = New-Object System.Drawing.Point(430, 196)
$btnWarpUndo.Size = New-Object System.Drawing.Size(130, 34)
$tabRoom.Controls.Add($btnWarpUndo)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = 'Show slots'
$btnRefresh.Location = New-Object System.Drawing.Point(150, 236)
$btnRefresh.Size = New-Object System.Drawing.Size(110, 28)
$tabRoom.Controls.Add($btnRefresh)

$lblRoomNote = New-Object System.Windows.Forms.Label
$lblRoomNote.Text = "Warping moves you, it does not advance the story: flags and inventory stay as the slot had them. Room names past index 29 are unverified - ids are reliable, names may be off."
$lblRoomNote.Location = New-Object System.Drawing.Point(150, 270)
$lblRoomNote.Size = New-Object System.Drawing.Size(510, 46)
$lblRoomNote.ForeColor = [System.Drawing.Color]::DimGray
$tabRoom.Controls.Add($lblRoomNote)

# ===== log ==============================================================================
$script:log = New-Object System.Windows.Forms.RichTextBox
$script:log.Location = New-Object System.Drawing.Point(10, 340)
$script:log.Size = New-Object System.Drawing.Size(685, 250)
$script:log.ReadOnly = $true
$script:log.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:log.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($script:log)

# ---------- populate --------------------------------------------------------------------

foreach ($f in (Get-ChildItem $MOVDIR -Filter '*.MOV' -File | Sort-Object Name)) {
    [void]$cbMovie.Items.Add($f.BaseName)
}
if ($cbMovie.Items.Count) { $cbMovie.SelectedIndex = 0 }

$slots = @()
foreach ($n in 0,1,2,3,4,6) {
    if (Test-Path (Join-Path $GAMEROOT "GAME\AZRAEL\SAVE$n.DAT")) { $slots += $n }
}
foreach ($n in $slots) { [void]$cbSaveSlot.Items.Add("slot $n"); [void]$cbFromSlot.Items.Add("slot $n") }
[void]$cbFromSlot.Items.Add('slot 65535')
if ($cbSaveSlot.Items.Count) { $cbSaveSlot.SelectedIndex = [Math]::Min(2, $cbSaveSlot.Items.Count-1) }
if ($cbFromSlot.Items.Count) { $cbFromSlot.SelectedIndex = 0 }

if (Test-Path $ROOMCSV) {
    foreach ($row in (Import-Csv $ROOMCSV)) {
        $mark = if ($row.Note) { '  [?]' } else { '' }
        [void]$cbRoom.Items.Add(('{0,3}  {1}  ({2}){3}' -f $row.CandidateIndex, $row.Name, $row.Scene, $mark))
    }
}
if ($cbRoom.Items.Count) { $cbRoom.SelectedIndex = 0 }

# ---------- behaviour -------------------------------------------------------------------

$updateMovInfo = {
    if (-not $cbMovie.SelectedItem) { return }
    $p = Join-Path $MOVDIR ($cbMovie.SelectedItem.ToString() + '.MOV')
    $i = Get-MovInfo $p
    if (-not $i) { $lblMovInfo.Text = 'not a readable .MOV'; return }
    $key = $i.Width * $i.Height
    $spare = $BUFFER - $key
    $lblMovInfo.Text = ('{0:N0} frames   {1}x{2} @ {3} fps   {4:N1} MB' -f $i.Frames,$i.Width,$i.Height,$i.Fps,($i.Bytes/1MB)) +
                       [Environment]::NewLine +
                       ('keyframe {0:N0} of {1:N0} byte buffer, {2:N0} spare' -f $key,$BUFFER,$spare)
    $lblMovInfo.ForeColor = if ($spare -lt 40000) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::DimGray }
}
$cbMovie.Add_SelectedIndexChanged($updateMovInfo)
& $updateMovInfo

$script:spawns = @()
function Load-Spawns {
    $cbSpawn.Items.Clear(); $script:spawns = @()
    if (-not $cbRoom.SelectedItem) { return }
    if ($cbRoom.SelectedItem.ToString() -notmatch '\(([^)]+)\)') { return }
    $scene = $matches[1]
    try {
        $script:spawns = @(& (Join-Path $AZTMOD 'tools\Get-RoomSpawn.ps1') -Scene $scene -List)
    } catch { Log ("  no spawn candidates for $scene : " + $_.Exception.Message) 'DarkGoldenrod'; return }
    foreach ($s in $script:spawns) {
        [void]$cbSpawn.Items.Add(('{0}   ({1}, {2}, {3})' -f $s.Source, $s.X, $s.Y, $s.Z))
    }
    if ($cbSpawn.Items.Count) { $cbSpawn.SelectedIndex = 0 }
}

$cbRoom.Add_SelectedIndexChanged({
    if ($cbRoom.SelectedItem -match '^\s*(\d+)') { $numRoom.Value = [int]$matches[1] }
    Load-Spawns
})
$rbFrom.Add_CheckedChanged({ $cbFromSlot.Enabled = $rbFrom.Checked })

function Stage-Movie {
    $name = $cbMovie.SelectedItem.ToString()
    $slot = if ($cbSlotM.SelectedIndex -eq 0) { 'mindlogo' } else { 'intro' }
    Log ''
    Log ("staging $name into the $slot slot") 'DarkBlue'
    $p = @{ Name = $name; Slot = $slot }
    if (-not $chkFps.Checked) { $p['KeepFps'] = $true }
    return (Run-Tool 'tools\Test-Movie.ps1' $p)
}
function Restore-Movie {
    Log ''
    Log 'restoring the startup movies' 'DarkBlue'
    [void](Run-Tool 'tools\Test-Movie.ps1' @{ Restore = $true })
}

$btnMovStage.Add_Click({ [void](Stage-Movie) })
$btnMovRestore.Add_Click({ Restore-Movie })
$btnMovGo.Add_Click({
    $form.Enabled = $false
    try {
        if (Stage-Movie) { [void](Launch-Game $cbMovie.SelectedItem.ToString()); Restore-Movie }
    } finally { $form.Enabled = $true }
})

function Write-Warp {
    if (-not $cbSaveSlot.SelectedItem) { Log 'no save slot selected' 'Firebrick'; return $false }
    $slot = [int]($cbSaveSlot.SelectedItem.ToString() -replace '\D','')
    $p = @{ Slot = $slot }
    if ($rbFrom.Checked) {
        $p['FromSlot'] = [int]($cbFromSlot.SelectedItem.ToString() -replace '\D','')
    } else {
        $p['Room'] = [int]$numRoom.Value
        if ($rbSpawn.Checked) {
            $i = $cbSpawn.SelectedIndex
            if ($i -ge 0 -and $i -lt $script:spawns.Count) {
                $s = $script:spawns[$i]
                $p['X'] = [double]$s.X; $p['Y'] = [double]$s.Y; $p['Z'] = [double]$s.Z
                Log ('  spawn: {0} at ({1}, {2}, {3})' -f $s.Source, $s.X, $s.Y, $s.Z)
            } else {
                Log '  no spawn point available for this room; keeping the current position' 'DarkGoldenrod'
                Log '  (if this strands you, pick a room from the list rather than typing an id)' 'DarkGoldenrod'
            }
        }
    }
    Log ''
    Log ("writing slot $slot") 'DarkBlue'
    return (Run-Tool 'tools\Set-SaveRoom.ps1' $p)
}

$btnWarpOnly.Add_Click({ [void](Write-Warp) })
$btnWarpUndo.Add_Click({
    $slot = [int]($cbSaveSlot.SelectedItem.ToString() -replace '\D','')
    Log ''
    Log ("undoing slot $slot") 'DarkBlue'
    [void](Run-Tool 'tools\Set-SaveRoom.ps1' @{ Slot = $slot; Restore = $true })
})
$btnRefresh.Add_Click({
    Log ''
    [void](Run-Tool 'tools\Set-SaveRoom.ps1' @{ Show = $true })
})
$btnWarp.Add_Click({
    $form.Enabled = $false
    try {
        if (Write-Warp) {
            $slot = [int]($cbSaveSlot.SelectedItem.ToString() -replace '\D','')
            Log ("now load slot $slot from the in-game menu.") 'DarkBlue'
            [void](Launch-Game "warp, slot $slot")
        }
    } finally { $form.Enabled = $true }
})

Log "Azrael's Tear test bench"
Log ''
Log 'Cutscenes: pick a movie and press Test -- it replaces a startup movie, so it plays'
Log '           a few seconds after launch, then the originals are put back when you quit.'
Log 'Warp:      pick a slot and a room, press Warp, then load that slot in game.'
Log ''
[void](Run-Tool 'tools\Set-SaveRoom.ps1' @{ Show = $true })

[void]$form.ShowDialog()
