# Reverse-engineering toolchain

Written from scratch because this machine has no disassembler, no Python and no compiler —
only PowerShell and .NET's `csc` via `Add-Type`.

| File | What it is |
|---|---|
| `LeTool.cs` | LE loader — objects, page map, **fixup application**, `FileOffsetOfLinear()` |
| `Disasm.cs` | x86-32 disassembler (one-byte + `0F` maps, ModRM/SIB, FPU length-correct) |
| `Analyzer.cs` | Recursive-descent explorer, xref database, string table |
| `load.ps1` | Dot-source this, then `Initialize-Azt` |
| `helpers.ps1` | `U`, `UF`, `Find-Str`, `Addr-Of-Str`, `Refs`, `Callers`, `FuncOf` |
| `Test-Patch.ps1` | Verifies a patch manifest without running the game |

## Usage

```powershell
cd "<game>\AztMod"
. .\tools\load.ps1
Initialize-Azt
```

`Initialize-Azt` takes ~200 ms and yields 828 strings, 299,464 instructions and 1,533 functions.

```powershell
UF 0x11640                  # disassemble EnterMouselook
Refs 0x147218               # every instruction touching the mouselook flag
Callers 0x1CF3C             # who calls the camera yaw/pitch adder
Find-Str "mouse"            # string search
Lin2File 0x33ABB            # linear -> file offset, for patching
Test-FixupsIn 0x13DC8 25    # ALWAYS run this before choosing a hook site
```

## Two things that will bite you

**1. The LE header lies.** `R.EXE`'s "data pages offset" field (LE+0x80) claims `0x3B400`
(→ `0x644FC`). The real offset is **`0x61A54`**, derived from the file tail:
`fileLength − ((numPages−1) × pageSize + lastPageSize)`. With the header value, 0 of page 1's
217 fixups line up; with the derived value, all 217 do. `LeTool.cs` derives it and reports both
in `Show-Layout`.

**2. Fixups destroy patched bytes.** Every absolute operand carries an LE relocation that the
loader rewrites at load time. Patch bytes inside a fixup slot and they are silently replaced
with a relocation value — the v0.1.0 frame hook lost four bytes of its `call` target this way
and would have jumped to `0x721A2990`. Run `Test-FixupsIn` before picking a site, and
`Test-Patch.ps1` after building.

## Verifying a patch

```powershell
.\tools\Test-Patch.ps1
.\tools\Test-Patch.ps1 -Manifest .\AztMod.diag.manifest.json
```

This applies the manifest to a scratch copy, reloads it through the LE loader — which applies
fixups exactly as DOS/4GW does — and disassembles every hook site and the injected stub. If all
branches resolve to named symbols and no game bytes were clobbered by a relocation, the patch is
structurally sound. It is not a substitute for play-testing.
