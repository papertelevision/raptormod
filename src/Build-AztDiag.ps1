# Builds AztMod.diag.manifest.json -- a DIAGNOSTIC build, not for playing.
#
# Purpose: work out why mouselook never engages. Every path here is
# position-independent (rel32 calls only, NO absolute data references), so it
# keeps working even if DOS/4GW does not load the image at the object table's
# stated bases -- which is the main thing we are trying to rule in or out.
#
# What it does:
#   * per-frame hook -> unconditional EnterMouselook()
#     If mouselook engages at startup, the frame hook IS executing.
#   * F4 -> EnterMouselook(), no base check     (tests the key hook alone)
#   * F5 -> EnterMouselook(), base-check gated  (tests the base assumption)
#   * F6 -> ExitMouselook()                     (gets the cursor back)
#
# Reading the result:
#   mouselook on at startup            -> frame hook runs; bug is in the guard logic
#   not at startup, F4 works, F5 works  -> frame hook is not executing
#   not at startup, F4 works, F5 dead   -> DOS/4GW relocates; absolute refs are wrong
#   F4 dead too                         -> hooks are not running at all

[CmdletBinding()]
param(
    [string]$GameExe = "$PSScriptRoot\..\..\GAME\AZRAEL\R.EXE",
    [string]$OutFile = "$PSScriptRoot\..\AztMod.diag.manifest.json"
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Asm.ps1"

$OBJ1_BASE  = 0x10000
$DATA_PAGES = 0x61A54
function Lin2File([uint32]$lin) { return [int]($DATA_PAGES + ($lin - $OBJ1_BASE)) }

$EnterMouselook = [uint32]0x11640
$ExitMouselook  = [uint32]0x1166C
$KeyHandler     = [uint32]0x12B88

# HudPrint(eax = HUD text object, edx = font, ebx = char*) -- plain ret, no stack args.
# This is the routine the game uses for "W A R N I N G" and the HUD boot text; it is
# also the primitive the eventual in-game console will be built on.
$HudPrint       = [uint32]0x39080
$g_hudTextObj   = [uint32]0x1521AC
$g_hudFont      = [uint32]0x15217C

# The HUD boot banner, drawn on screen during HUD startup. Two identical copies.
# Patching this is PURE DATA -- no code, no hooks, no load-address assumptions.
# If it shows up in game, the patched R.EXE is definitely the one running.
$BANNER_TEXT  = 'Model 7 Head Up Display'
$BANNER_NEW   = 'JOSH IS IN THE GAME    '   # must be exactly the same length
$BANNER_FILES = @(0x184B68, 0x18548E)

$HOOK_FRAME     = [uint32]0x13DC8
$HOOK_FRAME_LEN = 25
$HOOK_KEY       = [uint32]0x15E7E

$CAVE_BASE  = [uint32]0x132980
$CAVE_LIMIT = [uint32]0x133000

$LE_BASE        = 0x290FC
$OBJTAB_FILE    = $LE_BASE + 0xC4
$OBJ1_VSIZE_OFF = $OBJTAB_FILE + 0
$OBJ1_FLAGS_OFF = $OBJTAB_FILE + 8

$a = New-Asm -Base $CAVE_BASE

Add-Label $a 'diagMagic'
A-Db $a ([byte[]][char[]]'AZTD')
Add-Label $a 'msgKeyHook'
A-Asciiz $a 'AZTMOD KEY HOOK OK'

# ---- base check (the only thing that uses an absolute, deliberately) ----
Add-Label $a 'DiagBaseCheck'
A-CallNext $a
Add-Label $a 'DiagBaseRef'
A-PopEax $a
A-SubEaxAbs $a 'DiagBaseRef'
A-Ret $a

# ---- per-frame: force mouselook on, unconditionally, PIC only ----
Add-Label $a 'DiagFrame'
A-PushEax $a
A-Call $a $EnterMouselook          # early-outs internally if already on
A-PopEax $a
A-Ret $a

# ---- key hook ----
Add-Label $a 'DiagKey'
A-PushEdx $a
A-PushEax $a
A-CmpByteEaxDispImm $a 6 0
A-Jnz $a 'DK_pass'
A-MovDxEaxDisp $a 7
A-CmpDxImm $a 0x3E                 # F4
A-Jz $a 'DK_f4'
A-CmpDxImm $a 0x3F                 # F5
A-Jz $a 'DK_f5'
A-CmpDxImm $a 0x40                 # F6
A-Jz $a 'DK_f6'
A-CmpDxImm $a 0x41                 # F7
A-Jz $a 'DK_f7'
A-Jmp $a 'DK_pass'

Add-Label $a 'DK_f4'               # PIC enter, no base check
A-PopEax $a
A-PopEdx $a
A-Jmp $a $EnterMouselook

Add-Label $a 'DK_f5'               # enter only if the base is what we built for
A-Call $a 'DiagBaseCheck'
A-Jnz $a 'DK_f5_no'
A-PopEax $a
A-PopEdx $a
A-Jmp $a $EnterMouselook
Add-Label $a 'DK_f5_no'
A-PopEax $a
A-PopEdx $a
A-Ret $a

Add-Label $a 'DK_f6'
A-PopEax $a
A-PopEdx $a
A-Jmp $a $ExitMouselook

# F7: print a line to the HUD readout. Uses absolute data refs, so it only works
# if the image really is loaded at the object table's stated bases.
Add-Label $a 'DK_f7'
A-MovEbxAbs $a 'msgKeyHook'
A-MovEdxMem $a $g_hudFont
A-MovEaxMem $a $g_hudTextObj
A-Call $a $HudPrint
A-PopEax $a
A-PopEdx $a
A-Ret $a

Add-Label $a 'DK_pass'
A-PopEax $a
A-PopEdx $a
A-Jmp $a $KeyHandler

$asm = Invoke-Asm $a
if ($asm.End -gt $CAVE_LIMIT) { throw "diag stub overflows the cave" }
Write-Host ("diag stub: {0} bytes, 0x{1:X}..0x{2:X}" -f $asm.Bytes.Length, $asm.Base, $asm.End)

# ===========================================================================
$raw = [System.IO.File]::ReadAllBytes($GameExe)
function Hex([byte[]]$b) { ($b | ForEach-Object { '{0:X2}' -f $_ }) -join '' }

function New-Patch {
    param([string]$Name, [int]$FileOffset, [byte[]]$Expect, [byte[]]$Replace, [string]$Note)
    $actual = $raw[$FileOffset..($FileOffset + $Expect.Length - 1)]
    if ((Hex $actual) -ne (Hex $Expect)) { throw ("{0}: unexpected bytes at 0x{1:X}" -f $Name, $FileOffset) }
    if ($Replace.Length -ne $Expect.Length) { throw ("{0}: length mismatch" -f $Name) }
    [ordered]@{ name=$Name; note=$Note; offset=$FileOffset; expect=(Hex $Expect); replace=(Hex $Replace) }
}
function CallRel32([uint32]$from, [uint32]$to) {
    $rel = [int64]$to - ([int64]$from + 5)
    $u = [uint32]($rel -band [int64]4294967295)
    return ,([byte[]]@(0xE8, ($u -band 0xFF), (($u -shr 8) -band 0xFF), (($u -shr 16) -band 0xFF), (($u -shr 24) -band 0xFF)))
}

$patches = @()
$patches += New-Patch -Name 'obj1-vsize' -FileOffset $OBJ1_VSIZE_OFF `
    -Expect ([byte[]]@(0x73,0x29,0x12,0x00)) -Replace ([byte[]]@(0x00,0x30,0x12,0x00)) -Note 'cover the cave'
$patches += New-Patch -Name 'obj1-flags' -FileOffset $OBJ1_FLAGS_OFF `
    -Expect ([byte[]]@(0x45,0x20,0x00,0x00)) -Replace ([byte[]]@(0x47,0x20,0x00,0x00)) -Note 'add WRITE'
$patches += New-Patch -Name 'stub' -FileOffset (Lin2File $CAVE_BASE) `
    -Expect ([byte[]](, 0 * $asm.Bytes.Length)) -Replace $asm.Bytes -Note 'diagnostic stub'

# PURE DATA probe: rewrite the HUD boot banner. No code involved at all.
$i = 0
foreach ($bf in $BANNER_FILES) {
    $i++
    $patches += New-Patch -Name ("banner-$i") -FileOffset $bf `
        -Expect ([System.Text.Encoding]::ASCII.GetBytes($BANNER_TEXT)) `
        -Replace ([System.Text.Encoding]::ASCII.GetBytes($BANNER_NEW)) `
        -Note ("HUD banner -> '{0}' (pure data: proves the patched EXE is running)" -f $BANNER_NEW.Trim())
}

# frame hook: route around the LE fixups at +3 and +13 (see README)
$frameOff  = Lin2File $HOOK_FRAME
$frameOrig = $raw[$frameOff..($frameOff + $HOOK_FRAME_LEN - 1)]
$frameRepl = $frameOrig.Clone()
$frameRepl[0] = 0xEB; $frameRepl[1] = 0x0F
(CallRel32 ([uint32]($HOOK_FRAME + 17)) $asm.Labels['DiagFrame']).CopyTo($frameRepl, 17)
$frameRepl[22] = 0x90; $frameRepl[23] = 0x90; $frameRepl[24] = 0x90
foreach ($fx in @(3,13)) { for ($k=0; $k -lt 4; $k++) {
    if ($frameRepl[$fx+$k] -ne $frameOrig[$fx+$k]) { throw "would overwrite fixup slot" } } }
$patches += New-Patch -Name 'hook-frame' -FileOffset $frameOff -Expect $frameOrig -Replace $frameRepl `
    -Note 'per-frame -> unconditional EnterMouselook'

$koff = Lin2File $HOOK_KEY
$patches += New-Patch -Name 'hook-keydown' -FileOffset $koff `
    -Expect $raw[$koff..($koff+4)] -Replace (CallRel32 $HOOK_KEY $asm.Labels['DiagKey']) -Note 'F4/F5/F6 probes'

$manifest = [ordered]@{
    modName      = 'AztMod-DIAGNOSTIC'
    modVersion   = '0.1.1-diag'
    feature      = 'diagnostic probes (not for playing)'
    targetFile   = 'GAME/AZRAEL/R.EXE'
    targetSha256 = (Get-FileHash -Path $GameExe -Algorithm SHA256).Hash
    targetLength = $raw.Length
    caveBase     = ('0x{0:X}' -f $CAVE_BASE)
    caveEnd      = ('0x{0:X}' -f $asm.End)
    symbols      = ($asm.Labels.GetEnumerator() | Sort-Object Value | ForEach-Object { [ordered]@{ name=$_.Key; linear=('0x{0:X}' -f $_.Value) } })
    keys         = @(
        'BANNER  the HUD boot text should read "JOSH IS IN THE GAME" instead of'
        '        "Model 7 Head Up Display". Pure data patch -- no code, no hooks.'
        '        If you see it, the patched R.EXE is definitely running.'
        'START   mouselook should already be ON before you press anything'
        '        (frame hook forces it every frame, position-independent)'
        'F1      toggles the MAP -- stock key, proves F-keys reach the game at all'
        'F4      EnterMouselook, position-independent, no base check'
        'F5      EnterMouselook, only if the load address is what we built for'
        'F6      ExitMouselook  (gets the cursor back)'
        'F7      prints "AZTMOD KEY HOOK OK" to the HUD readout (needs correct base)'
    )
    settings     = @()
    patches      = $patches
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $OutFile -Encoding utf8
Write-Host "wrote $OutFile  ($($patches.Count) patches)"
