# Read-LiveScene.ps1 -- walk the game's scene graph from the HOST, with no guest code.
#
#   .\tools\Read-LiveScene.ps1
#   .\tools\Read-LiveScene.ps1 -Depth 3 -WithVisualsOnly
#   .\tools\Read-LiveScene.ps1 -Json C:\Games\RaptorMod\scratch\azrael-scene.json
#
# §10 of the feasibility report calls "scene graph -> renderer" the best-leverage seam,
# and §13 puts object transforms as the step after camera extraction. Both are now
# reachable without running ANY code inside the game: the frame tree is ordinary linked
# structures in emulated RAM, so the host can chase the pointers itself.
#
# This is strictly more capable than the in-guest scene logger it parallels: no overlay
# code, no file writing, no room-change trigger, and it can be run at any instant rather
# than only when the engine happens to rebuild a room.
#
# FRAME LAYOUT (recovered in §14b/§14c, and used verbatim by the in-guest walker):
#     +0x24   char* name          +0x30  parent      +0x34  next sibling
#     +0x3C   first child         +0x4C  local 4x4   +0x90  world 4x4
#     +0x268  visual count        +0x26C capacity    +0x270 Visual*[]
#     Frame is 736 (0x2E0) bytes.
#
# STARTING POINT. The overlay's camera record holds the live camera frame pointer at
# +16 ('aztCamObj'), which is a genuine runtime pointer rather than an engine handle --
# handles would need 0x39E50 to resolve and that means calling into the guest. Walking
# UP through +0x30 to the root sidesteps the question entirely.
#
# SAFETY. Every pointer is range-checked before it is dereferenced and the node count is
# capped, so a corrupt or mid-update pointer ends the walk instead of hanging it. The
# graph is being read WHILE the game mutates it, so a torn read is possible; that is a
# real limit of polling rather than something this can fix.

[CmdletBinding()]
param(
    [string]$Overlay = 'C:\Games\RaptorMod\game\GAME\AZRAEL\AZTCODE.BIN',
    [long]$OverlayBase = 0x133000,
    [int]$MaxNodes = 4000,
    [int]$Depth = 99,
    [int]$WaitForRoom = 0,       # seconds to wait for the game to actually be in a room
    [switch]$WithVisualsOnly,
    [string]$Json
)

$ErrorActionPreference = 'Stop'
$toolDir = Split-Path -Parent $PSCommandPath
. (Join-Path $toolDir 'GuestBase.ps1')

$F_NAME = 0x24; $F_PARENT = 0x30; $F_SIB = 0x34; $F_CHILD = 0x3C
$F_LOCAL = 0x4C; $F_WORLD = 0x90; $F_VISCNT = 0x268; $F_VISARR = 0x270
$FRAME_SIZE = 0x2E0

$g = Get-AztGuestBase
Write-Host ("guest RAM 0x{0:X11} ({1:N0} MB), MemBase 0x{2:X11}, {3} needles" -f `
            $g.RamBase, ($g.RamSize / 1MB), $g.MemBase, $g.Needles.Count)

# ---- find the camera frame through the overlay's own record -----------------
$ovl = [IO.File]::ReadAllBytes($Overlay)
$off = -1
for ($i = 0; $i + 4 -le $ovl.Length; $i++) {
    if ($ovl[$i] -eq 0x43 -and $ovl[$i+1] -eq 0x41 -and $ovl[$i+2] -eq 0x4D -and $ovl[$i+3] -eq 0x31) { $off = $i; break }
}
if ($off -lt 0) { throw "'CAM1' not found in $Overlay" }
# aztCamObj stays 0 until the game is actually in a room -- during the intro and menus
# there is no camera frame to point at. Poll rather than fail, so this can be started
# before the player has finished loading in.
$camObj = 0; $frameNo = 0
$deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(0, $WaitForRoom))
do {
    $rec = Read-AztGuest -Base $g -Lin ($OverlayBase + $off) -Length 320
    if ($null -eq $rec) { throw "could not read the camera record (game closed?)" }
    $camObj  = [BitConverter]::ToUInt32($rec, 16)
    $frameNo = [BitConverter]::ToUInt32($rec, 4)
    if (Test-AztPointer -Addr $camObj -Base $g) { break }
    if ([DateTime]::UtcNow -ge $deadline) { break }
    Start-Sleep -Milliseconds 1000
} while ($true)

Write-Host ("camera frame pointer (aztCamObj) = 0x{0:X}  at game frame {1}" -f $camObj, $frameNo)
if (-not (Test-AztPointer -Addr $camObj -Base $g)) {
    throw ("aztCamObj is 0x{0:X}: the game is not in a room yet. Load a game / walk in, then re-run (or pass -WaitForRoom 240)." -f $camObj)
}

# ---- climb to the root ------------------------------------------------------
$root = [long]$camObj
$climb = 0
while ($climb -lt 64) {
    $p = Read-AztRuntime -Base $g -Addr ($root + $F_PARENT) -Length 4
    if ($null -eq $p) { break }
    $parent = [BitConverter]::ToUInt32($p, 0)
    if (-not (Test-AztPointer -Addr $parent -Base $g) -or $parent -eq $root) { break }
    $root = [long]$parent
    $climb++
}
Write-Host ("root 0x{0:X} ({1} level(s) above the camera)" -f $root, $climb)
Write-Host ""

# ---- read one frame ---------------------------------------------------------
$nameCache = @{}
function Get-FrameName {
    param([long]$Ptr)
    if ($nameCache.ContainsKey($Ptr)) { return $nameCache[$Ptr] }
    $s = ''
    if (Test-AztPointer -Addr $Ptr -Base $g) {
        $b = Read-AztRuntime -Base $g -Addr $Ptr -Length 64
        if ($null -ne $b) {
            foreach ($c in $b) { if ($c -eq 0) { break }; if ($c -lt 32 -or $c -gt 126) { $s = ''; break }; $s += [char]$c }
        }
    }
    $nameCache[$Ptr] = $s
    return $s
}

function Read-Frame {
    param([long]$Addr)
    $b = Read-AztRuntime -Base $g -Addr $Addr -Length $FRAME_SIZE
    if ($null -eq $b -or $b.Length -lt $FRAME_SIZE) { return $null }
    $namePtr = [BitConverter]::ToUInt32($b, $F_NAME)
    $w = @(); for ($i = 0; $i -lt 16; $i++) { $w += [BitConverter]::ToSingle($b, $F_WORLD + $i*4) }
    [pscustomobject]@{
        Addr     = $Addr
        Name     = Get-FrameName -Ptr $namePtr
        Parent   = [BitConverter]::ToUInt32($b, $F_PARENT)
        Sibling  = [BitConverter]::ToUInt32($b, $F_SIB)
        Child    = [BitConverter]::ToUInt32($b, $F_CHILD)
        VisCount = [BitConverter]::ToUInt32($b, $F_VISCNT)
        VisArr   = [BitConverter]::ToUInt32($b, $F_VISARR)
        World    = $w
        X = $w[12]; Y = $w[13]; Z = $w[14]
    }
}

# ---- depth-first walk, iterative so a deep tree cannot blow the stack -------
$nodes = New-Object System.Collections.ArrayList
$seen = @{}
$stack = New-Object System.Collections.Stack
$stack.Push(@{ Addr = $root; Depth = 0 })
$truncated = $false

while ($stack.Count -gt 0) {
    if ($nodes.Count -ge $MaxNodes) { $truncated = $true; break }
    $cur = $stack.Pop()
    $addr = [long]$cur.Addr
    if ($seen.ContainsKey($addr)) { continue }      # cycle guard
    $seen[$addr] = $true

    $f = Read-Frame -Addr $addr
    if ($null -eq $f) { continue }
    $f | Add-Member -NotePropertyName Depth -NotePropertyValue $cur.Depth
    [void]$nodes.Add($f)

    # push sibling first so the child is visited first (DFS in tree order)
    # The parentheses matter: without them PowerShell binds `-and` as a PARAMETER of
    # Test-AztPointer and the call fails with "a parameter cannot be found".
    if ((Test-AztPointer -Addr $f.Sibling -Base $g) -and ($cur.Depth -gt 0)) {
        $stack.Push(@{ Addr = $f.Sibling; Depth = $cur.Depth })
    }
    if (Test-AztPointer -Addr $f.Child -Base $g) {
        $stack.Push(@{ Addr = $f.Child; Depth = $cur.Depth + 1 })
    }
}

# ---- report ------------------------------------------------------------------
$withVis = @($nodes | Where-Object { $_.VisCount -gt 0 -and $_.VisCount -lt 10000 })
$named   = @($nodes | Where-Object { $_.Name })
Write-Host ("{0} frames walked   {1} named   {2} carrying visuals{3}" -f `
            $nodes.Count, $named.Count, $withVis.Count, $(if ($truncated) { "   (TRUNCATED at $MaxNodes)" } else { '' }))
Write-Host ""
Write-Host ("{0,-28} {1,10} {2,10} {3,10} {4,5} {5}" -f 'name', 'X', 'Y', 'Z', 'vis', 'address')

$show = if ($WithVisualsOnly) { $withVis } else { $nodes }
foreach ($f in ($show | Where-Object { $_.Depth -le $Depth })) {
    $indent = '  ' * [Math]::Min($f.Depth, 8)
    $label = $indent + $(if ($f.Name) { $f.Name } else { '(unnamed)' })
    Write-Host ("{0,-28} {1,10:N2} {2,10:N2} {3,10:N2} {4,5} 0x{5:X}" -f `
                $label.PadRight(28).Substring(0, [Math]::Min(28, $label.Length)), $f.X, $f.Y, $f.Z, $f.VisCount, $f.Addr)
}

if ($Json) {
    $nodes | Select-Object Name, Depth, X, Y, Z, VisCount, @{n='Addr';e={'0x{0:X}' -f $_.Addr}}, World |
        ConvertTo-Json -Depth 4 | Set-Content -Path $Json -Encoding utf8
    Write-Host ""
    Write-Host ("written -> {0}" -f $Json)
}
