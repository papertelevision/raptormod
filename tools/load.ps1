# Loads the Azrael's Tear reverse-engineering toolchain.
#
#   . .\tools\load.ps1                       # uses the Steam R.EXE next to this repo
#   . .\tools\load.ps1 -Exe C:\path\R.EXE    # or any other copy
#
# Exposes:
#   $IMG  LeTool.LeImage   - LE loader with fixups applied
#   $DIS  LeTool.Disasm    - x86-32 disassembler
#   $AN   LeTool.Analyzer  - recursive-descent explorer + xref database
#
# then helpers.ps1 gives:  U, UF, Find-Str, Addr-Of-Str, Refs, Callers, FuncOf
#
# Typical session:
#   . .\tools\load.ps1
#   Initialize-Azt            # build strings + explore (a couple of seconds)
#   UF 0x11640                # disassemble EnterMouselook
#   Refs 0x147218             # everything that touches the mouselook flag

param(
    [string]$Exe
)

$ErrorActionPreference = 'Stop'

if (-not $Exe) {
    # tools\ -> AztMod\ -> game root
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $Exe  = Join-Path $root 'GAME\AZRAEL\R.EXE'
}
if (-not (Test-Path $Exe)) { throw "R.EXE not found at $Exe -- pass -Exe <path>" }

if (-not ("LeTool.LeImage" -as [type])) {
    Add-Type -Path @(
        (Join-Path $PSScriptRoot 'LeTool.cs'),
        (Join-Path $PSScriptRoot 'Disasm.cs'),
        (Join-Path $PSScriptRoot 'Analyzer.cs')
    ) -ErrorAction Stop
}

$global:IMG = New-Object LeTool.LeImage ($Exe)
$global:DIS = New-Object LeTool.Disasm ($global:IMG)
$global:AN  = New-Object LeTool.Analyzer ($global:IMG, $global:DIS)

. (Join-Path $PSScriptRoot 'helpers.ps1')

function Show-Layout {
    Write-Output ("LE base 0x{0:X}  pages={1}  pagesize={2}" -f $IMG.LeBase, $IMG.NumPages, $IMG.PageSize)
    Write-Output ("data pages: derived 0x{0:X}   (LE header CLAIMS 0x{1:X} -- it is wrong)" -f $IMG.DataPagesOff, $IMG.HeaderDataPagesOff)
    for ($i = 1; $i -le $IMG.NObj; $i++) {
        Write-Output ("obj{0}: base=0x{1:X} vsize=0x{2:X} flags=0x{3:X} pageIdx={4} pages={5}" -f `
            $i, $IMG.ObjBase[$i], $IMG.ObjSize[$i], $IMG.ObjFlags[$i], $IMG.ObjPageIdx[$i], $IMG.ObjPageCnt[$i])
    }
    Write-Output ("entry point = 0x{0:X}   fixups applied = {1}" -f $IMG.EntryPoint, $IMG.Fixups.Count)
}

# Build the string table and run recursive descent. Seeds are the entry point plus
# every fixup value landing in code, which picks up vtables and jump tables.
function Initialize-Azt {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $AN.BuildStrings()
    $seeds = New-Object System.Collections.Generic.List[uint32]
    $seeds.Add([uint32]$IMG.EntryPoint)
    $seen = @{}
    foreach ($f in $IMG.Fixups) {
        if ($AN.InCode($f.Value) -and -not $seen.ContainsKey($f.Value)) {
            $seen[$f.Value] = 1; $seeds.Add([uint32]$f.Value)
        }
    }
    $AN.Explore($seeds)
    Write-Output ("strings {0}  seeds {1}  instructions {2}  functions {3}  ({4} ms)" -f `
        $AN.Strings.Count, $seeds.Count, $AN.InsnStarts.Count, $AN.CallTargets.Count, $sw.ElapsedMilliseconds)
}

# Disassemble N instructions from a linear address (raw; UF stops at the first ret).
function U ([uint32]$addr, [int]$n = 24) {
    $a = [uint32]$addr
    for ($i = 0; $i -lt $n; $i++) {
        if (-not $IMG.Valid($a)) { Write-Output ("{0:X8}  <unmapped>" -f $a); break }
        $ins = $DIS.Decode($a)
        $by  = ($IMG.Slice($a, [Math]::Min($ins.Len, 8)) | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
        $note = ""
        if ($ins.HasImm32  -and $AN.StringAt.ContainsKey([uint32]$ins.Imm32))  { $note = '   ; "' + $AN.StringAt[[uint32]$ins.Imm32]  + '"' }
        elseif ($ins.HasDisp32 -and $AN.StringAt.ContainsKey([uint32]$ins.Disp32)) { $note = '   ; "' + $AN.StringAt[[uint32]$ins.Disp32] + '"' }
        Write-Output ("{0:X8}  {1,-24}  {2}{3}" -f $a, $by, $ins.Text, $note)
        $a = [uint32]($a + $ins.Len)
    }
}

# Linear address -> file offset. obj1's pages are contiguous, so this is exact.
function Lin2File([uint32]$lin) { return $IMG.FileOffsetOfLinear($lin) }

# Does any LE fixup land inside [addr, addr+len)?  ALWAYS check this before
# choosing a hook site -- the loader rewrites fixup slots at load time and will
# destroy patched bytes there.
function Test-FixupsIn([uint32]$addr, [int]$len) {
    $hits = @()
    foreach ($f in $IMG.Fixups) {
        if ($f.Site -ge $addr -and $f.Site -lt ($addr + $len)) { $hits += ("+{0}" -f ($f.Site - $addr)) }
    }
    if ($hits.Count) { Write-Output ("FIXUPS at " + ($hits -join ', ') + " -- do not patch those bytes") }
    else { Write-Output "no fixups in range -- safe to patch" }
}

Write-Output "loaded. run Initialize-Azt to build the xref database."
