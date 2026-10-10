# Minimal x86-32 assembler for AztMod patch stubs.
#
# Only the instructions the mod actually needs are implemented. Everything is
# emitted through named helpers so the stub source reads like assembly and can
# be reviewed, rather than being a wall of hand-typed hex.
#
# Two passes: items are appended with a known size, labels resolve to absolute
# linear addresses, then branch displacements are computed.

function New-Asm {
    param([Parameter(Mandatory)][uint32]$Base)
    [pscustomobject]@{
        Base   = $Base
        Items  = (New-Object System.Collections.ArrayList)
        # Ordinal (case-SENSITIVE) so a lookup can never silently resolve to a
        # differently-cased label. A plain PowerShell hashtable is case-insensitive,
        # which once let a data label 'aztStrafe' be overwritten by a routine
        # 'AztStrafe' -- the stub then read its own code as a variable.
        Labels = (New-Object 'System.Collections.Generic.Dictionary[string,uint32]' ([System.StringComparer]::Ordinal))
        Defined= (New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase))
    }
}

# ---- low-level item helpers -------------------------------------------------

function Add-Bytes {
    param($Asm, [byte[]]$Data)
    [void]$Asm.Items.Add(@{ Kind = 'bytes'; Data = $Data; Size = $Data.Length })
}

function Add-Abs32 {
    param($Asm, $Value)   # uint32 literal, or a label name (string)
    [void]$Asm.Items.Add(@{ Kind = 'abs32'; Value = $Value; Size = 4 })
}

function Add-Rel32 {
    param($Asm, $Target)  # label name (string) or uint32 absolute address
    [void]$Asm.Items.Add(@{ Kind = 'rel32'; Target = $Target; Size = 4 })
}

# Short branch. The size is FIXED at one byte, so the two-pass layout is
# unaffected -- there is no branch relaxation here, the displacement is simply
# checked and the build fails if it does not reach. Worth four bytes a jump in
# code that has to fit an exact hole.
function Add-Rel8 {
    param($Asm, $Target)
    [void]$Asm.Items.Add(@{ Kind = 'rel8'; Target = $Target; Size = 1 })
}

function Add-Label {
    param($Asm, [string]$Name)
    # Reject case-insensitive collisions too: 'aztStrafe' vs 'AztStrafe' is a
    # readability trap, and it used to resolve silently to the wrong address.
    if (-not $Asm.Defined.Add($Name)) {
        throw ("duplicate label '{0}' (names must differ by more than case)" -f $Name)
    }
    [void]$Asm.Items.Add(@{ Kind = 'label'; Name = $Name; Size = 0 })
}

# ---- instruction helpers ----------------------------------------------------
# $addr arguments accept a uint32 or a label name.

function A-Ret      { param($a)            Add-Bytes $a @(0xC3) }
function A-PushEax  { param($a)            Add-Bytes $a @(0x50) }
function A-PopEax   { param($a)            Add-Bytes $a @(0x58) }
function A-PushEdx  { param($a)            Add-Bytes $a @(0x52) }
function A-PopEdx   { param($a)            Add-Bytes $a @(0x5A) }
function A-XorEdxEdx{ param($a)            Add-Bytes $a @(0x31,0xD2) }
function A-IncDx    { param($a)            Add-Bytes $a @(0x66,0x42) }

function A-Jmp      { param($a,$t)         Add-Bytes $a @(0xE9);      Add-Rel32 $a $t }
function A-Call     { param($a,$t)         Add-Bytes $a @(0xE8);      Add-Rel32 $a $t }
function A-Jz       { param($a,$t)         Add-Bytes $a @(0x0F,0x84); Add-Rel32 $a $t }
function A-Jnz      { param($a,$t)         Add-Bytes $a @(0x0F,0x85); Add-Rel32 $a $t }

# Short forms, 2 bytes instead of 5/6. Only for branches that are provably near.
function A-JmpS     { param($a,$t)         Add-Bytes $a @(0xEB); Add-Rel8 $a $t }
function A-JzS      { param($a,$t)         Add-Bytes $a @(0x74); Add-Rel8 $a $t }
function A-JnzS     { param($a,$t)         Add-Bytes $a @(0x75); Add-Rel8 $a $t }
function A-JbS      { param($a,$t)         Add-Bytes $a @(0x72); Add-Rel8 $a $t }
function A-JbeS     { param($a,$t)         Add-Bytes $a @(0x76); Add-Rel8 $a $t }
function A-JaS      { param($a,$t)         Add-Bytes $a @(0x77); Add-Rel8 $a $t }

# cmp word [addr], imm8   ->  66 83 3D <abs32> <imm8>
function A-CmpWordAbsImm { param($a,$addr,[byte]$imm)
    Add-Bytes $a @(0x66,0x83,0x3D); Add-Abs32 $a $addr; Add-Bytes $a @($imm) }

# mov word [addr], imm16  ->  66 C7 05 <abs32> <imm16>
function A-MovWordAbsImm { param($a,$addr,[uint16]$imm)
    Add-Bytes $a @(0x66,0xC7,0x05); Add-Abs32 $a $addr
    Add-Bytes $a @([byte]($imm -band 0xFF), [byte](($imm -shr 8) -band 0xFF)) }

# mov ax, word [addr]     ->  66 A1 <abs32>
function A-MovAxAbs { param($a,$addr)
    Add-Bytes $a @(0x66,0xA1); Add-Abs32 $a $addr }

# or  ax, word [addr]     ->  66 0B 05 <abs32>
function A-OrAxAbs { param($a,$addr)
    Add-Bytes $a @(0x66,0x0B,0x05); Add-Abs32 $a $addr }

# test ax, ax             ->  66 85 C0
function A-TestAxAx { param($a) Add-Bytes $a @(0x66,0x85,0xC0) }

# mov word [addr], dx     ->  66 89 15 <abs32>
function A-MovAbsDx { param($a,$addr)
    Add-Bytes $a @(0x66,0x89,0x15); Add-Abs32 $a $addr }

# cmp byte [eax+disp8], imm8 -> 80 78 <disp8> <imm8>
function A-CmpByteEaxDispImm { param($a,[byte]$disp,[byte]$imm)
    Add-Bytes $a @(0x80,0x78,$disp,$imm) }

# mov dx, word [eax+disp8]   -> 66 8B 50 <disp8>
function A-MovDxEaxDisp { param($a,[byte]$disp)
    Add-Bytes $a @(0x66,0x8B,0x50,$disp) }

# cmp dx, imm8 (sign-extended) -> 66 83 FA <imm8>
function A-CmpDxImm { param($a,[byte]$imm)
    Add-Bytes $a @(0x66,0x83,0xFA,$imm) }

# mov ebx, imm32/label   ->  BB <abs32>
function A-MovEbxAbs { param($a,$addr) Add-Bytes $a @(0xBB); Add-Abs32 $a $addr }

# mov eax, dword [addr]  ->  A1 <abs32>
function A-MovEaxMem { param($a,$addr) Add-Bytes $a @(0xA1); Add-Abs32 $a $addr }

# mov edx, dword [addr]  ->  8B 15 <abs32>
function A-MovEdxMem { param($a,$addr) Add-Bytes $a @(0x8B,0x15); Add-Abs32 $a $addr }

# NUL-terminated ASCII literal
function A-Asciiz { param($a,[string]$s)
    Add-Bytes $a ([byte[]]([System.Text.Encoding]::ASCII.GetBytes($s) + [byte]0)) }

# call $+5  ->  E8 00 00 00 00   (pushes the address of the next instruction)
function A-CallNext { param($a) Add-Bytes $a @(0xE8,0x00,0x00,0x00,0x00) }

# sub eax, imm32/label  ->  2D <abs32>
function A-SubEaxAbs { param($a,$addr)
    Add-Bytes $a @(0x2D); Add-Abs32 $a $addr }

# ---- base-relative forms -------------------------------------------------------
# The image is fully relocatable, so absolute data addresses are only correct if
# DOS/4GW happens to load at the object table's stated bases. These forms index
# off a register holding the runtime delta instead, which is correct either way.
#   esi = obj1 delta (code + our cave), edi = obj2 delta (game data)
# ModRM mod=10: rm=110 -> [esi+disp32], rm=111 -> [edi+disp32]

function A-MovEsiEax { param($a) Add-Bytes $a @(0x89,0xC6) }
function A-MovEaxEsi { param($a) Add-Bytes $a @(0x89,0xF0) }
function A-MovEdiEax { param($a) Add-Bytes $a @(0x89,0xC7) }
function A-PushEsi   { param($a) Add-Bytes $a @(0x56) }
function A-PopEsi    { param($a) Add-Bytes $a @(0x5E) }
function A-PushEdi   { param($a) Add-Bytes $a @(0x57) }
function A-PopEdi    { param($a) Add-Bytes $a @(0x5F) }

function A-MovEaxImm { param($a,$v)      Add-Bytes $a @(0xB8); Add-Abs32 $a $v }
function A-MovEdxImm { param($a,$v)      Add-Bytes $a @(0xBA); Add-Abs32 $a $v }

# cmp word [esi|edi + addr], imm8
function A-CmpWordSiImm { param($a,$addr,[byte]$i) Add-Bytes $a @(0x66,0x83,0xBE); Add-Abs32 $a $addr; Add-Bytes $a @($i) }
function A-CmpWordDiImm { param($a,$addr,[byte]$i) Add-Bytes $a @(0x66,0x83,0xBF); Add-Abs32 $a $addr; Add-Bytes $a @($i) }

# mov word [esi|edi + addr], imm16
function A-MovWordSiImm { param($a,$addr,[uint16]$v)
    Add-Bytes $a @(0x66,0xC7,0x86); Add-Abs32 $a $addr
    Add-Bytes $a @([byte]($v -band 0xFF),[byte](($v -shr 8) -band 0xFF)) }
function A-MovWordDiImm { param($a,$addr,[uint16]$v)
    Add-Bytes $a @(0x66,0xC7,0x87); Add-Abs32 $a $addr
    Add-Bytes $a @([byte]($v -band 0xFF),[byte](($v -shr 8) -band 0xFF)) }

# mov word [esi + addr], dx
function A-MovSiDx { param($a,$addr) Add-Bytes $a @(0x66,0x89,0x96); Add-Abs32 $a $addr }

# mov ax, word [edi + addr]   /   or ax, word [edi + addr]
function A-MovAxDi { param($a,$addr) Add-Bytes $a @(0x66,0x8B,0x87); Add-Abs32 $a $addr }
function A-OrAxDi  { param($a,$addr) Add-Bytes $a @(0x66,0x0B,0x87); Add-Abs32 $a $addr }

# mov eax, dword [esi|edi + addr]  /  mov edx, dword [edi + addr]
function A-MovEaxSi { param($a,$addr) Add-Bytes $a @(0x8B,0x86); Add-Abs32 $a $addr }
function A-MovEaxDi { param($a,$addr) Add-Bytes $a @(0x8B,0x87); Add-Abs32 $a $addr }
function A-MovEdxDi { param($a,$addr) Add-Bytes $a @(0x8B,0x97); Add-Abs32 $a $addr }
function A-MovEcxDi { param($a,$addr) Add-Bytes $a @(0x8B,0x8F); Add-Abs32 $a $addr }  # mov ecx,[edi+d32]
# 16-bit immediates: the PCX loader only ever reads CX/BX, so the upper halves
# do not need clearing and these stay 4 bytes instead of 5.
function A-MovCxImm { param($a,[uint16]$v) Add-Bytes $a @(0x66,0xB9,[byte]($v -band 0xFF),[byte](($v -shr 8) -band 0xFF)) }
function A-MovBxImm { param($a,[uint16]$v) Add-Bytes $a @(0x66,0xBB,[byte]($v -band 0xFF),[byte](($v -shr 8) -band 0xFF)) }
function A-LeaEdxEspDisp { param($a,[uint32]$d) Add-Bytes $a @(0x8D,0x94,0x24); Add-Bytes $a ([byte[]][BitConverter]::GetBytes([uint32]$d)) }
function A-AddEaxDi { param($a,$addr) Add-Bytes $a @(0x03,0x87); Add-Abs32 $a $addr }  # add eax,[edi+d32]
function A-MulEcx   { param($a) Add-Bytes $a @(0xF7,0xE1) }                            # edx:eax = eax*ecx
function A-MovEbxSi { param($a,$addr) Add-Bytes $a @(0x8B,0x9E); Add-Abs32 $a $addr }

# lea eax, [esi + addr]
function A-LeaEaxSi { param($a,$addr) Add-Bytes $a @(0x8D,0x86); Add-Abs32 $a $addr }

# mov ax, word [esi + addr]   /   mov word [edi + addr], ax   /   or ax, word [esi + addr]
function A-MovAxSi { param($a,$addr) Add-Bytes $a @(0x66,0x8B,0x86); Add-Abs32 $a $addr }
function A-OrAxSi  { param($a,$addr) Add-Bytes $a @(0x66,0x0B,0x86); Add-Abs32 $a $addr }
function A-MovDiAx { param($a,$addr) Add-Bytes $a @(0x66,0x89,0x87); Add-Abs32 $a $addr }

# mov byte [eax + disp8], imm8    /   mov word [eax + disp8], imm16
function A-MovByteEaxDispImm { param($a,[byte]$d,[byte]$v) Add-Bytes $a @(0xC6,0x40,$d,$v) }
function A-MovWordEaxDispImm { param($a,[byte]$d,[uint16]$v)
    Add-Bytes $a @(0x66,0xC7,0x40,$d,[byte]($v -band 0xFF),[byte](($v -shr 8) -band 0xFF)) }

# movzx eax|edx, word [esi + addr]
function A-MovzxEaxSi { param($a,$addr) Add-Bytes $a @(0x0F,0xB7,0x86); Add-Abs32 $a $addr }
function A-MovzxEdxSi { param($a,$addr) Add-Bytes $a @(0x0F,0xB7,0x96); Add-Abs32 $a $addr }

# sub eax, imm32
function A-SubEaxImm { param($a,$v) Add-Bytes $a @(0x2D); Add-Abs32 $a $v }

# flag save/restore, for hooks that replace a conditional branch
function A-Pushfd { param($a) Add-Bytes $a @(0x9C) }
function A-Popfd  { param($a) Add-Bytes $a @(0x9D) }

# add esp, imm8  -- used to discard a return address when emulating a taken branch
function A-AddEspImm { param($a,[byte]$v) Add-Bytes $a @(0x83,0xC4,$v) }

# xor eax|edx, imm32  -- flipping bit 31 of an IEEE float negates it
function A-XorEaxImm { param($a,$v) Add-Bytes $a @(0x35); Add-Abs32 $a $v }
function A-XorEdxImm { param($a,$v) Add-Bytes $a @(0x81,0xF2); Add-Abs32 $a $v }

# mov dword [edi + addr], eax|edx
function A-MovDiEax32 { param($a,$addr) Add-Bytes $a @(0x89,0x87); Add-Abs32 $a $addr }
function A-MovDiEdx32 { param($a,$addr) Add-Bytes $a @(0x89,0x97); Add-Abs32 $a $addr }

# ---- 32-bit arithmetic on ebx/ecx -------------------------------------------
# Used by AztHudPoint, which rescales a screen point into stock-panel space.
# ebx/ecx are chosen because the hook saves and restores exactly those two.

# push/pop ebx, ecx
function A-PushEbx { param($a) Add-Bytes $a @(0x53) }
function A-PopEbx  { param($a) Add-Bytes $a @(0x5B) }
function A-PushEcx { param($a) Add-Bytes $a @(0x51) }
function A-PopEcx  { param($a) Add-Bytes $a @(0x59) }

# movsx ebx|ecx, word [ebp+disp8]   ->  0F BF /r  mod=01
function A-MovsxEbxEbpDisp { param($a,[byte]$d) Add-Bytes $a @(0x0F,0xBF,0x5D,$d) }
function A-MovsxEcxEbpDisp { param($a,[byte]$d) Add-Bytes $a @(0x0F,0xBF,0x4D,$d) }

# mov word [ebp+disp8], bx|cx       ->  66 89 /r  mod=01
function A-MovEbpDispBx { param($a,[byte]$d) Add-Bytes $a @(0x66,0x89,0x5D,$d) }
function A-MovEbpDispCx { param($a,[byte]$d) Add-Bytes $a @(0x66,0x89,0x4D,$d) }

# mov word [ebp+disp8], imm16       ->  66 C7 45 <disp8> <imm16>
function A-MovEbpDispImm16 { param($a,[byte]$d,[uint16]$v)
    Add-Bytes $a @(0x66,0xC7,0x45,$d,[byte]($v -band 0xFF),[byte](($v -shr 8) -band 0xFF)) }

# cmp/sub/add ebx|ecx, imm32
function A-CmpEbxImm { param($a,$v) Add-Bytes $a @(0x81,0xFB); Add-Abs32 $a $v }
function A-CmpEcxImm { param($a,$v) Add-Bytes $a @(0x81,0xF9); Add-Abs32 $a $v }
function A-SubEbxImm { param($a,$v) Add-Bytes $a @(0x81,0xEB); Add-Abs32 $a $v }
function A-SubEcxImm { param($a,$v) Add-Bytes $a @(0x81,0xE9); Add-Abs32 $a $v }
function A-AddEcxImm { param($a,$v) Add-Bytes $a @(0x81,0xC1); Add-Abs32 $a $v }

# imul ebx|ecx|edx, same, imm32     ->  69 /r <imm32>
function A-ImulEbxImm { param($a,$v) Add-Bytes $a @(0x69,0xDB); Add-Abs32 $a $v }
function A-ImulEcxImm { param($a,$v) Add-Bytes $a @(0x69,0xC9); Add-Abs32 $a $v }
function A-ImulEdxImm { param($a,$v) Add-Bytes $a @(0x69,0xD2); Add-Abs32 $a $v }

# sar ebx|ecx, imm8                 ->  C1 /7 <imm8>
function A-SarEbxImm { param($a,[byte]$i) Add-Bytes $a @(0xC1,0xFB,$i) }
function A-SarEcxImm { param($a,[byte]$i) Add-Bytes $a @(0xC1,0xF9,$i) }

# jl/jg rel32
function A-Jl { param($a,$t) Add-Bytes $a @(0x0F,0x8C); Add-Rel32 $a $t }
function A-Jg { param($a,$t) Add-Bytes $a @(0x0F,0x8F); Add-Rel32 $a $t }

# mov eax, dword [ebp+disp8]        ->  8B 45 <disp8>
function A-MovEaxEbpDisp { param($a,[byte]$d) Add-Bytes $a @(0x8B,0x45,$d) }

# cmp dword [eax+disp8], imm8       ->  83 78 <disp8> <imm8>
function A-CmpDwordEaxDispImm { param($a,[byte]$d,[byte]$i) Add-Bytes $a @(0x83,0x78,$d,$i) }

# nop
function A-Nop { param($a) Add-Bytes $a @(0x90) }

# ---- forms used by the wall-slide stubs -------------------------------------
# The movement integrator keeps its position locals at fixed esp offsets (the
# function fixes esp in its prologue and every callee is stdcall), so the stubs
# reach them with plain [esp+disp8].

# mov eax, dword [esp+disp8]  /  mov dword [esp+disp8], eax
function A-MovEaxEspDisp { param($a,[byte]$d) Add-Bytes $a @(0x8B,0x44,0x24,$d) }
function A-MovEspDispEax { param($a,[byte]$d) Add-Bytes $a @(0x89,0x44,0x24,$d) }

# mov dword [esi + addr], eax   (store into the mod's own data block)
function A-MovSiEax32 { param($a,$addr) Add-Bytes $a @(0x89,0x86); Add-Abs32 $a $addr }

# mov dword [edi + addr], imm32  -- used to zero a float component of the
# movement vector; 0.0f is all-bits-zero so no FPU is needed
function A-MovDwordDiImm { param($a,$addr,$v) Add-Bytes $a @(0xC7,0x87); Add-Abs32 $a $addr; Add-Abs32 $a $v }

# and eax|edx, imm32  -- masking off the sign bit turns an IEEE float into its
# magnitude, and magnitudes compare correctly as unsigned integers
function A-AndEaxImm { param($a,$v) Add-Bytes $a @(0x25); Add-Abs32 $a $v }
function A-AndEdxImm { param($a,$v) Add-Bytes $a @(0x81,0xE2); Add-Abs32 $a $v }

function A-CmpEaxEdx { param($a) Add-Bytes $a @(0x39,0xD0) }

# jmp eax -- the wall-slide stub serves two movement paths and returns to
# whichever one called it, so its retry target is a computed runtime address
function A-JmpEax { param($a) Add-Bytes $a @(0xFF,0xE0) }

# ja rel32  /  inc word [esi + addr]
function A-Ja        { param($a,$t) Add-Bytes $a @(0x0F,0x87); Add-Rel32 $a $t }
function A-IncWordSi { param($a,$addr) Add-Bytes $a @(0x66,0xFF,0x86); Add-Abs32 $a $addr }
function A-Jbe { param($a,$t) Add-Bytes $a @(0x0F,0x86); Add-Rel32 $a $t }

# fadd dword [esp+disp8]  /  fxch  -- reproduced by the save hook, which replaces
# them. Integer-only stub code leaves the FPU stack untouched either way.
function A-FaddEspDisp { param($a,[byte]$d) Add-Bytes $a @(0xD8,0x44,0x24,$d) }
function A-Fxch { param($a) Add-Bytes $a @(0xD9,0xC9) }

# movsx ebx|ecx, word [edi + addr]   ->  0F BF /r  mod=10 rm=edi
function A-MovsxEbxDi { param($a,$addr) Add-Bytes $a @(0x0F,0xBF,0x9F); Add-Abs32 $a $addr }
function A-MovsxEcxDi { param($a,$addr) Add-Bytes $a @(0x0F,0xBF,0x8F); Add-Abs32 $a $addr }

# mov word [edi + addr], bx|cx       ->  66 89 /r  mod=10 rm=edi
function A-MovDiBx { param($a,$addr) Add-Bytes $a @(0x66,0x89,0x9F); Add-Abs32 $a $addr }
function A-MovDiCx { param($a,$addr) Add-Bytes $a @(0x66,0x89,0x8F); Add-Abs32 $a $addr }

# raw data
function A-Db { param($a,[byte[]]$d) Add-Bytes $a $d }
function A-Dw { param($a,[uint16]$v)
    Add-Bytes $a @([byte]($v -band 0xFF), [byte](($v -shr 8) -band 0xFF)) }

# ---- assemble ---------------------------------------------------------------

function Invoke-Asm {
    param($Asm)

    # pass 1: assign addresses
    $addr = [uint32]$Asm.Base
    foreach ($it in $Asm.Items) {
        if ($it.Kind -eq 'label') { $Asm.Labels[$it.Name] = $addr }
        $it.Addr = $addr
        $addr = [uint32]($addr + $it.Size)
    }
    $end = $addr

    $resolve = {
        param($v)
        if ($v -is [string]) {
            if (-not $Asm.Labels.ContainsKey($v)) { throw "undefined label '$v'" }
            return [uint32]$Asm.Labels[$v]
        }
        # PowerShell parses hex literals above 0x7FFFFFFF as negative Int32
        # (0x80000000 -> -2147483648), so reinterpret rather than fail the cast.
        return [uint32]([int64]$v -band [int64]4294967295)
    }

    # pass 2: emit
    $out = New-Object System.Collections.Generic.List[byte]
    foreach ($it in $Asm.Items) {
        switch ($it.Kind) {
            'label' { }
            'bytes' { foreach ($b in $it.Data) { $out.Add([byte]$b) } }
            'abs32' {
                $v = & $resolve $it.Value
                for ($i = 0; $i -lt 4; $i++) { $out.Add([byte](($v -shr (8*$i)) -band 0xFF)) }
            }
            'rel32' {
                $t = & $resolve $it.Target
                $next = [int64]$it.Addr + 4
                $rel  = [int64]$t - $next
                if ($rel -lt -2147483648 -or $rel -gt 2147483647) { throw "rel32 out of range" }
                # NB: PowerShell parses 0xFFFFFFFF as [int] -1, so mask with an explicit Int64.
                $u = [uint32]($rel -band [int64]4294967295)
                for ($i = 0; $i -lt 4; $i++) { $out.Add([byte](($u -shr (8*$i)) -band 0xFF)) }
            }
            'rel8' {
                $t = & $resolve $it.Target
                $rel = [int64]$t - ([int64]$it.Addr + 1)
                if ($rel -lt -128 -or $rel -gt 127) {
                    throw ("short branch to '{0}' is {1} bytes away -- use the rel32 form" -f $it.Target, $rel)
                }
                $out.Add([byte]($rel -band 0xFF))
            }
            default { throw "unknown item kind $($it.Kind)" }
        }
    }

    [pscustomobject]@{
        Base   = $Asm.Base
        End    = $end
        Bytes  = $out.ToArray()
        Labels = $Asm.Labels
    }
}



# --- x87, disp32 off the esi (cave) / edi (obj2) delta registers ---------------
# modrm mod=10: rm=110 for esi, rm=111 for edi; reg field is the /digit.
function A-FldSi   { param($a,$addr) Add-Bytes $a @(0xD9,0x86); Add-Abs32 $a $addr }   # fld  dword [esi+d32]
function A-FldDi   { param($a,$addr) Add-Bytes $a @(0xD9,0x87); Add-Abs32 $a $addr }   # fld  dword [edi+d32]
function A-FmulSi  { param($a,$addr) Add-Bytes $a @(0xD8,0x8E); Add-Abs32 $a $addr }   # fmul dword [esi+d32]
function A-FmulDi  { param($a,$addr) Add-Bytes $a @(0xD8,0x8F); Add-Abs32 $a $addr }   # fmul dword [edi+d32]
function A-FsubrSi { param($a,$addr) Add-Bytes $a @(0xD8,0xAE); Add-Abs32 $a $addr }   # fsubr dword [esi+d32]  (st0 = mem - st0)
function A-FstpSi  { param($a,$addr) Add-Bytes $a @(0xD9,0x9E); Add-Abs32 $a $addr }   # fstp dword [esi+d32]
function A-FstpDi  { param($a,$addr) Add-Bytes $a @(0xD9,0x9F); Add-Abs32 $a $addr }   # fstp dword [edi+d32]
function A-FldSt0  { param($a) Add-Bytes $a @(0xD9,0xC0) }                             # fld st(0)
function A-FaddpSt1{ param($a) Add-Bytes $a @(0xDE,0xC1) }                             # faddp st(1),st(0)
function A-MovDwordSiImm { param($a,$addr,$v) Add-Bytes $a @(0xC7,0x86); Add-Abs32 $a $addr; Add-Abs32 $a $v }

# --- actor-rate throttle -------------------------------------------------------
function A-AddSiAx      { param($a,$addr) Add-Bytes $a @(0x66,0x01,0x86); Add-Abs32 $a $addr }   # add word [esi+d32], ax
function A-SubWordSiImm { param($a,$addr,[byte]$i) Add-Bytes $a @(0x66,0x83,0xAE); Add-Abs32 $a $addr; Add-Bytes $a @($i) }
function A-Jb           { param($a,$t) Add-Bytes $a @(0x0F,0x82); Add-Rel32 $a $t }

# ---- emitters added for the LFB init (AztLfbInit, 0x33EB8) ------------------
function A-TestEaxEax   { param($a) Add-Bytes $a @(0x85,0xC0) }
function A-MovEaxEaxDisp{ param($a,[byte]$d) Add-Bytes $a @(0x8B,0x40,$d) }   # mov eax,[eax+d8]
function A-MovEbxEax    { param($a) Add-Bytes $a @(0x89,0xC3) }
function A-MovEcxEax    { param($a) Add-Bytes $a @(0x89,0xC1) }
function A-ShrEbxImm    { param($a,[byte]$i) Add-Bytes $a @(0xC1,0xEB,$i) }
function A-ShlEbxImm    { param($a,[byte]$i) Add-Bytes $a @(0xC1,0xE3,$i) }
function A-MovzxEcxCx   { param($a) Add-Bytes $a @(0x0F,0xB7,0xC9) }
function A-OrEbxEcx     { param($a) Add-Bytes $a @(0x09,0xCB) }
function A-MovEsiImm    { param($a,$v) Add-Bytes $a @(0xBE); Add-Abs32 $a $v }
function A-MovEdiImm    { param($a,$v) Add-Bytes $a @(0xBF); Add-Abs32 $a $v }
function A-Int          { param($a,[byte]$n) Add-Bytes $a @(0xCD,$n) }
function A-MovSiEbx32   { param($a,$addr) Add-Bytes $a @(0x89,0x9E); Add-Abs32 $a $addr }  # mov [esi+d32],ebx

# ---- emitters for the delta-time actor gate (AztActorTime) -------------------
function A-MovEaxEaxPtr { param($a) Add-Bytes $a @(0x8B,0x00) }                 # mov eax,[eax]
function A-SubEaxEbx    { param($a) Add-Bytes $a @(0x29,0xD8) }
function A-CmpEaxImm    { param($a,$v) Add-Bytes $a @(0x3D); Add-Abs32 $a $v }
function A-ImulEaxImm   { param($a,$v) Add-Bytes $a @(0x69,0xC0); Add-Abs32 $a $v }
function A-MovBxSi      { param($a,$addr) Add-Bytes $a @(0x66,0x8B,0x9E); Add-Abs32 $a $addr }  # mov bx,[esi+d32]
function A-MovSiAx      { param($a,$addr) Add-Bytes $a @(0x66,0x89,0x86); Add-Abs32 $a $addr }  # mov [esi+d32],ax
function A-CmpAxBx      { param($a) Add-Bytes $a @(0x66,0x39,0xD8) }
function A-SubAxBx      { param($a) Add-Bytes $a @(0x66,0x29,0xD8) }
function A-MovEaxEspPtr { param($a) Add-Bytes $a @(0x8B,0x04,0x24) }            # mov eax,[esp]
function A-Dd           { param($a,$v) Add-Bytes $a @(0,0,0,0) }               # placeholder dword

# ---- emitters for the frame limiter (PIT channel 0, ~1.193 MHz) -------------
function A-Cli        { param($a) Add-Bytes $a @(0xFA) }
function A-OutImmAl   { param($a,[byte]$p) Add-Bytes $a @(0xE6,$p) }            # out imm8, al
function A-InAlImm    { param($a,[byte]$p) Add-Bytes $a @(0xE4,$p) }            # in  al, imm8
function A-MovClAl    { param($a) Add-Bytes $a @(0x88,0xC1) }
function A-MovChAl    { param($a) Add-Bytes $a @(0x88,0xC5) }
function A-NegEcx     { param($a) Add-Bytes $a @(0xF7,0xD9) }
function A-LeaEaxEbxEcx { param($a) Add-Bytes $a @(0x8D,0x04,0x0B) }            # lea eax,[ebx+ecx]
function A-MovEbxImm  { param($a,$v) Add-Bytes $a @(0xBB); Add-Abs32 $a $v }
function A-MovEbxEbxPtr { param($a) Add-Bytes $a @(0x8B,0x1B) }                 # mov ebx,[ebx]
function A-XorEaxEax  { param($a) Add-Bytes $a @(0x31,0xC0) }
function A-CmpEaxSi   { param($a,$addr) Add-Bytes $a @(0x3B,0x86); Add-Abs32 $a $addr }  # cmp eax,[esi+d32]

# ---- emitters for the animation clock gate (AztAnimStep) --------------------
function A-SubEaxSi   { param($a,$addr) Add-Bytes $a @(0x2B,0x86); Add-Abs32 $a $addr }  # sub eax,[esi+d32]
function A-MovEcxSi   { param($a,$addr) Add-Bytes $a @(0x8B,0x8E); Add-Abs32 $a $addr }  # mov ecx,[esi+d32]
function A-AddSiEcx   { param($a,$addr) Add-Bytes $a @(0x01,0x8E); Add-Abs32 $a $addr }  # add [esi+d32],ecx

# ---- emitters for the BSS overlay loader (AztOverlayLoad) -------------------
# DOS file I/O rather than the game's stdio: INT 21h AH=3Dh/3Fh/3Eh is 2 bytes a
# call where fopen/fread/fclose would each cost a 5-byte rel32, and DOS/4GW
# translates the flat DS:EDX for us.
function A-Pushad       { param($a) Add-Bytes $a @(0x60) }
function A-Popad        { param($a) Add-Bytes $a @(0x61) }
function A-XchgEaxEbx   { param($a) Add-Bytes $a @(0x93) }                               # 1 byte; mov ebx,eax is 2
function A-MovAhImm     { param($a,[byte]$v) Add-Bytes $a @(0xB4,$v) }
function A-MovEcxImm    { param($a,$v) Add-Bytes $a @(0xB9); Add-Abs32 $a $v }
function A-CallEax      { param($a) Add-Bytes $a @(0xFF,0xD0) }
function A-LeaEdxSi     { param($a,$addr) Add-Bytes $a @(0x8D,0x96); Add-Abs32 $a $addr } # lea edx,[esi+d32]
function A-CmpDwordSiImm { param($a,$addr,[byte]$v) Add-Bytes $a @(0x83,0xBE); Add-Abs32 $a $addr; Add-Bytes $a @($v) }

# ---- emitters for the fold-out slider trampolines --------------------------
# The game pushes the slider's Y as `push imm8`, which cannot reach the new
# panel's position; these re-issue it at full width from the overlay.
function A-Jle          { param($a,$t) Add-Bytes $a @(0x0F,0x8E); Add-Rel32 $a $t }
function A-PushImm32    { param($a,$v) Add-Bytes $a @(0x68); Add-Abs32 $a $v }         # push imm32
function A-AddEsiImm32  { param($a,$v) Add-Bytes $a @(0x81,0xC6); Add-Abs32 $a $v }   # add esi, imm32

# ---- DPMI / real-mode-call helpers (CD audio) --------------------------------
function A-MovzxEaxAx   { param($a) Add-Bytes $a @(0x0F,0xB7,0xC0) }              # movzx eax,ax
function A-ShlEaxImm    { param($a,[byte]$n) Add-Bytes $a @(0xC1,0xE0,$n) }       # shl eax,n
function A-LeaEdiSi     { param($a,$addr) Add-Bytes $a @(0x8D,0xBE); Add-Abs32 $a $addr }   # lea edi,[esi+d32]
function A-MovSiEcx32   { param($a,$addr) Add-Bytes $a @(0x89,0x8E); Add-Abs32 $a $addr }   # mov [esi+d32],ecx
function A-MovEcxSi32   { param($a,$addr) Add-Bytes $a @(0x8B,0x8E); Add-Abs32 $a $addr }   # mov ecx,[esi+d32]
function A-MovEdxSi32   { param($a,$addr) Add-Bytes $a @(0x8B,0x96); Add-Abs32 $a $addr }   # mov edx,[esi+d32]
function A-MovSiEdx32   { param($a,$addr) Add-Bytes $a @(0x89,0x96); Add-Abs32 $a $addr }   # mov [esi+d32],edx
function A-PushDsPopEs  { param($a) Add-Bytes $a @(0x1E,0x07) }                   # push ds / pop es
function A-AddEaxEbx    { param($a) Add-Bytes $a @(0x01,0xD8) }                   # add eax,ebx
function A-SubEaxEsi    { param($a) Add-Bytes $a @(0x29,0xF0) }                   # sub eax,esi
function A-MovEbxEsi    { param($a) Add-Bytes $a @(0x89,0xF3) }                   # mov ebx,esi
function A-Dd32 { param($a,$v) Add-Bytes $a ([byte[]][BitConverter]::GetBytes([uint32]$v)) }   # literal dword
function A-SubEaxEdi  { param($a) Add-Bytes $a @(0x29,0xF8) }                                  # sub eax,edi
function A-JaeS       { param($a,$t) Add-Bytes $a @(0x73); Add-Rel8 $a $t }                    # jae short
function A-DivEcx     { param($a) Add-Bytes $a @(0xF7,0xF1) }                                  # div ecx
function A-MovzxEaxDi { param($a,$addr) Add-Bytes $a @(0x0F,0xB7,0x87); Add-Abs32 $a $addr }   # movzx eax,word [edi+d32]
function A-MovDiAx    { param($a,$addr) Add-Bytes $a @(0x66,0x89,0x87); Add-Abs32 $a $addr }   # mov [edi+d32],ax
function A-AddEaxImm32   { param($a,$v) Add-Bytes $a @(0x05); Add-Abs32 $a $v }                     # add eax,imm32
function A-MovEdxDi      { param($a,$addr) Add-Bytes $a @(0x8B,0x97); Add-Abs32 $a $addr }         # mov edx,[edi+d32]
function A-MovzxEaxByteDi{ param($a,$addr) Add-Bytes $a @(0x0F,0xB6,0x87); Add-Abs32 $a $addr }    # movzx eax,byte [edi+d32]

# ---- struct walking, for the camera-transform log ---------------------------
# Reality Lab frame objects are reached through a handle, so reading one means
# holding the object in eax and a destination in ebp -- neither of which can be
# esi or edi, because those carry the two object deltas the whole overlay is
# addressed through. Hence a small set of eax-based and ebp-based forms.
function A-XorEbxEbx     { param($a) Add-Bytes $a @(0x31,0xDB) }                                  # xor ebx,ebx
function A-RepMovsd      { param($a) Add-Bytes $a @(0xF3,0xA5) }                                  # rep movsd  (es:edi <- ds:esi)
function A-MovEbxEaxD8   { param($a,[byte]$d) Add-Bytes $a @(0x8B,0x58,$d) }                      # mov ebx,[eax+d8]
function A-MovEbpD8Eax   { param($a,[byte]$d) Add-Bytes $a @(0x89,0x45,$d) }                      # mov [ebp+d8],eax
function A-MovEbpD8Ebx   { param($a,[byte]$d) Add-Bytes $a @(0x89,0x5D,$d) }                      # mov [ebp+d8],ebx
function A-LeaEbpSi      { param($a,$addr) Add-Bytes $a @(0x8D,0xAE); Add-Abs32 $a $addr }        # lea ebp,[esi+d32]
function A-LeaEbxSi      { param($a,$addr) Add-Bytes $a @(0x8D,0x9E); Add-Abs32 $a $addr }        # lea ebx,[esi+d32]
function A-LeaEsiEaxD32  { param($a,$v) Add-Bytes $a @(0x8D,0xB0); Add-Abs32 $a $v }              # lea esi,[eax+d32]
function A-LeaEdiEbpD8   { param($a,[byte]$d) Add-Bytes $a @(0x8D,0x7D,$d) }                      # lea edi,[ebp+d8]
function A-PushEbp       { param($a) Add-Bytes $a @(0x55) }
function A-PopEbp        { param($a) Add-Bytes $a @(0x5D) }
# Store the two object deltas themselves. Anything the game hands back is a
# RELOCATED pointer, so a logged value can only be checked against a linear
# address from the notes if the delta that relates them is recorded alongside it.
function A-MovSiEsi32    { param($a,$addr) Add-Bytes $a @(0x89,0xB6); Add-Abs32 $a $addr }   # mov [esi+d32],esi
function A-MovSiEdi32    { param($a,$addr) Add-Bytes $a @(0x89,0xBE); Add-Abs32 $a $addr }   # mov [esi+d32],edi

# ---- scene-graph walking ----------------------------------------------------
# Frame fields past +0x7F cannot use an 8-bit displacement (it is SIGNED, so 0xC0
# would be read as -64), hence the disp32 forms. The tree is first-child at +0x3C
# and next-sibling at +0x34, per the recursive propagator at 0x55378.
function A-MovEbxEaxD32  { param($a,$v) Add-Bytes $a @(0x8B,0x98); Add-Abs32 $a $v }         # mov ebx,[eax+d32]
function A-OrEbxEaxD32   { param($a,$v) Add-Bytes $a @(0x0B,0x98); Add-Abs32 $a $v }         # or  ebx,[eax+d32]
function A-MovEaxEbx     { param($a) Add-Bytes $a @(0x89,0xD8) }                             # mov eax,ebx
function A-CmpEbxDi      { param($a,$addr) Add-Bytes $a @(0x3B,0x9F); Add-Abs32 $a $addr }   # cmp ebx,[edi+d32]
function A-IncDwordSi    { param($a,$addr) Add-Bytes $a @(0xFF,0x86); Add-Abs32 $a $addr }   # inc dword [esi+d32]
function A-DecDwordSi    { param($a,$addr) Add-Bytes $a @(0xFF,0x8E); Add-Abs32 $a $addr }   # dec dword [esi+d32]
function A-CmpDwordSiImm32 { param($a,$addr,$v) Add-Bytes $a @(0x81,0xBE); Add-Abs32 $a $addr; Add-Abs32 $a $v }  # cmp dword [esi+d32],imm32
function A-TestEbxEbx    { param($a) Add-Bytes $a @(0x85,0xDB) }                             # test ebx,ebx
function A-CmpEbxSi      { param($a,$addr) Add-Bytes $a @(0x3B,0x9E); Add-Abs32 $a $addr }    # cmp ebx,[esi+d32]
function A-XorEbxEax     { param($a) Add-Bytes $a @(0x31,0xC3) }                              # xor ebx,eax
function A-Jae           { param($a,$t) Add-Bytes $a @(0x0F,0x83); Add-Rel32 $a $t }         # jae (near)
function A-RepStosd      { param($a) Add-Bytes $a @(0xF3,0xAB) }                             # rep stosd (es:edi <- eax)
function A-MovEdiEbp     { param($a) Add-Bytes $a @(0x89,0xEF) }

# ---- viewport injection (AztViewInject) --------------------------------------
# A row copy needs: a row counter that decrements, a saved dword-count that rep
# movsd does not destroy, and a way to step the destination by one scanline.
function A-ShrEdxImm     { param($a,[byte]$i) Add-Bytes $a @(0xC1,0xEA,$i) }                    # shr edx,imm8
function A-MovEbpSi      { param($a,$addr) Add-Bytes $a @(0x8B,0xAE); Add-Abs32 $a $addr }      # mov ebp,[esi+d32]
function A-MovEcxEdx     { param($a) Add-Bytes $a @(0x89,0xD1) }                                # mov ecx,edx
function A-AddEdiImm32   { param($a,$v) Add-Bytes $a @(0x81,0xC7); Add-Abs32 $a $v }            # add edi,imm32
function A-DecEbp        { param($a) Add-Bytes $a @(0x4D) }
function A-TestEbpEbp    { param($a) Add-Bytes $a @(0x85,0xED) }

function A-AddEaxImm     { param($a,$v) Add-Bytes $a @(0x05); Add-Abs32 $a $v }                 # add eax,imm32
function A-MovEbxDi      { param($a,$addr) Add-Bytes $a @(0x8B,0x9F); Add-Abs32 $a $addr }      # mov ebx,[edi+d32]
function A-MovEbpImm     { param($a,$v) Add-Bytes $a @(0xBD); Add-Abs32 $a $v }                 # mov ebp,imm32                                # test ebp,ebp  -- guards the row loop; ebp=0 would wrap dec to 4G                                     # dec ebp                             # mov edi,ebp
function A-TestEcxEcx    { param($a) Add-Bytes $a @(0x85,0xC9) }                             # test ecx,ecx
# ---- texture de-duplication table walking -----------------------------------
# ModRM is reg-then-rm: for `cmp ebx,[edx]` the reg field is ebx (011) and rm is edx
# (010), giving 00 011 010 = 0x1A. Writing 0x13 instead encodes `cmp edx,[ebx]` -- the
# operands swapped -- and the matching `mov` bug wrote ebx into [ebx], which would have
# corrupted the first dword of the game's own Texture object. Verified by disassembling
# the built overlay; do that for every hand-encoded ModRM.
function A-CmpEbxEdxPtr  { param($a) Add-Bytes $a @(0x3B,0x1A) }                             # cmp ebx,[edx]
function A-AddEdxImm8    { param($a,[byte]$d) Add-Bytes $a @(0x83,0xC2,$d) }                 # add edx,imm8
function A-DecEcx        { param($a) Add-Bytes $a @(0x49) }                                  # dec ecx
function A-ShlEcxImm     { param($a,[byte]$n) Add-Bytes $a @(0xC1,0xE1,$n) }                 # shl ecx,n
function A-AddEdxEcx     { param($a) Add-Bytes $a @(0x01,0xCA) }                             # add edx,ecx
function A-MovEdxPtrEbx  { param($a) Add-Bytes $a @(0x89,0x1A) }                             # mov [edx],ebx
function A-MovEcxEaxD8   { param($a,[byte]$d) Add-Bytes $a @(0x8B,0x48,$d) }                 # mov ecx,[eax+d8]
function A-MovEdxEbx     { param($a) Add-Bytes $a @(0x89,0xDA) }                             # mov edx,ebx
function A-MovEbxEdx     { param($a) Add-Bytes $a @(0x89,0xD3) }                             # mov ebx,edx
function A-CmpEdxImm     { param($a,$v) Add-Bytes $a @(0x81,0xFA); Add-Abs32 $a $v }         # cmp edx,imm32
function A-MovEsiEbx     { param($a) Add-Bytes $a @(0x89,0xDE) }                             # mov esi,ebx

# ---- filename hashing, for de-duplicating texture pixels across rooms -------
function A-MovzxEdxByteEax { param($a) Add-Bytes $a @(0x0F,0xB6,0x10) }                       # movzx edx,byte [eax]
function A-XorEcxEdx     { param($a) Add-Bytes $a @(0x31,0xD1) }                              # xor ecx,edx
function A-IncEax        { param($a) Add-Bytes $a @(0x40) }                                   # inc eax
function A-TestDlDl      { param($a) Add-Bytes $a @(0x84,0xD2) }                              # test dl,dl
function A-CmpEcxEdxPtr  { param($a) Add-Bytes $a @(0x3B,0x0A) }                              # cmp ecx,[edx]
function A-MovEdxPtrEcx  { param($a) Add-Bytes $a @(0x89,0x0A) }                              # mov [edx],ecx
function A-MovEaxEbxD8   { param($a,[byte]$d) Add-Bytes $a @(0x8B,0x43,$d) }                  # mov eax,[ebx+d8]
function A-MovSiEcx32b   { param($a,$addr) Add-Bytes $a @(0x89,0x8E); Add-Abs32 $a $addr }    # mov [esi+d32],ecx
function A-DecEax        { param($a) Add-Bytes $a @(0x48) }                                   # dec eax
function A-AddEdxEax     { param($a) Add-Bytes $a @(0x01,0xC2) }                              # add edx,eax

# ---- the 3D-suppression A/B gates and the tagged FPS sample -----------------
# `ret imm16` is NOT interchangeable with `ret`. A stub standing in for a
# CALLEE-POPS function has to pop the arguments itself or the caller's stack
# comes back wrong -- the lesson from 0x34C40, recorded in the status-gauge
# notes. 0x3F0D0 ends in `ret 4`, so AztClrGate's skip path must too.
function A-RetImm        { param($a,[uint16]$n) Add-Bytes $a @(0xC2,[byte]([int]$n -band 0xFF),[byte](([int]$n -shr 8) -band 0xFF)) }
function A-XorEaxEax     { param($a) Add-Bytes $a @(0x31,0xC0) }                              # xor eax,eax
function A-TestEdxEdx    { param($a) Add-Bytes $a @(0x85,0xD2) }                              # test edx,edx
function A-IncEdx        { param($a) Add-Bytes $a @(0x42) }                                   # inc edx
function A-DecEdx        { param($a) Add-Bytes $a @(0x4A) }                                   # dec edx
function A-AndEdxImm8    { param($a,[byte]$v) Add-Bytes $a @(0x83,0xE2,$v) }                  # and edx,imm8
function A-ShlEdxImm     { param($a,[byte]$n) Add-Bytes $a @(0xC1,0xE2,$n) }                  # shl edx,imm8
function A-MovEdxSi      { param($a,$addr) Add-Bytes $a @(0x8B,0x96); Add-Abs32 $a $addr }    # mov edx,[esi+d32]
function A-MovzxEdxWordDi { param($a,$addr) Add-Bytes $a @(0x0F,0xB7,0x97); Add-Abs32 $a $addr } # movzx edx,word [edi+d32]
# 16-bit forms, for packing tag bits into the one word the FPS log writes.
# [int] casts on purpose: `-shr` keeps the LEFT operand's type, so shifting a
# narrow value can silently yield 0 -- see the PowerShell silent-traps notes.
function A-AndAxImm      { param($a,[uint16]$v) Add-Bytes $a @(0x66,0x25,[byte]([int]$v -band 0xFF),[byte](([int]$v -shr 8) -band 0xFF)) }
# ---- the self-healing FPS log: reopen + seek-to-end ------------------------
function A-MovAxImm16    { param($a,[uint16]$v) Add-Bytes $a @(0x66,0xB8,[byte]([int]$v -band 0xFF),[byte](([int]$v -shr 8) -band 0xFF)) } # mov ax,imm16
function A-MovAlImm      { param($a,[byte]$v) Add-Bytes $a @(0xB0,$v) }                       # mov al,imm8
function A-XorEcxEcx     { param($a) Add-Bytes $a @(0x31,0xC9) }                              # xor ecx,ecx
function A-MovBxAx       { param($a) Add-Bytes $a @(0x66,0x89,0xC3) }                         # mov bx,ax
function A-CmpAxImm16    { param($a,[uint16]$v) Add-Bytes $a @(0x66,0x3D,[byte]([int]$v -band 0xFF),[byte](([int]$v -shr 8) -band 0xFF)) } # cmp ax,imm16
function A-OrAxImm       { param($a,[uint16]$v) Add-Bytes $a @(0x66,0x0D,[byte]([int]$v -band 0xFF),[byte](([int]$v -shr 8) -band 0xFF)) }
function A-OrAxDx        { param($a) Add-Bytes $a @(0x66,0x09,0xD0) }                         # or ax,dx
