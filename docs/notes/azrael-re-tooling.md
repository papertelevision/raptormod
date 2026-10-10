---
name: azrael-re-tooling
description: The custom LE loader/disassembler/analyzer for R.EXE lives in AztMod\tools; load it with tools\load.ps1.
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-26T23:01:17.422Z
---

This machine has **no standalone Python (only the Store alias stub), no node, no git, no compiler,
and no disassembler**. Only PowerShell 5.1 + .NET Framework 4.0 `csc` (via `Add-Type`) and `tar.exe`.

**Exception, found 2026-09-26: Blender 5.2 is installed** at
`C:\Program Files\Blender Foundation\Blender 5.2\blender.exe`, and it bundles a full Python. It can
be driven headless — `& $blender -b -P script.py` — which renders the extracted OBJs *without asking
the user to do anything in the GUI*. EEVEE works in background mode; the engine id is
`BLENDER_EEVEE_NEXT` with a fallback to `BLENDER_EEVEE`. Use this for any render comparison rather
than handing the user a script to run. (Its Python is Blender's own: `bpy` and `mathutils` only, no
numpy/PIL, and it is not a general-purpose interpreter for non-Blender work.)

So the Azrael's Tear reverse-engineering toolchain was written from scratch in C#. It lives at
`...\Azrael's Tear\AztMod\tools\` (moved there 2026-09-18 — it was originally in the session
scratchpad and would have been lost):

- `LeTool.cs`    — LE loader: objects, page map, **applies fixups**, `FileOffsetOfLinear()`
- `Disasm.cs`    — x86-32 decoder (one-byte + `0F` maps, ModRM/SIB, FPU length-correct)
- `Analyzer.cs`  — recursive descent; seeds = entry point + every fixup value landing in code
                   (catches vtables and jump tables). Builds `ImmRefs` as an xref database.
- `load.ps1`     — dot-source it, then `Initialize-Azt`. Gives `$IMG`, `$DIS`, `$AN`, plus
                   `Show-Layout`, `Lin2File`, and **`Test-FixupsIn <addr> <len>`**
- `helpers.ps1`  — `U`, `UF`, `Find-Str`, `Addr-Of-Str`, `Refs`, `Callers`, `FuncOf`
- `Test-Patch.ps1` — applies a manifest to a scratch copy, reloads it through the LE loader
                   (which applies fixups exactly as DOS/4GW does) and disassembles the hook
                   sites. **This is what catches fixup-overlap bugs before they reach the game.**

Typical session:
```powershell
cd "...\Azrael's Tear\AztMod"
. .\tools\load.ps1
Initialize-Azt          # ~200 ms: 828 strings, 299k instructions, 1533 functions
UF 0x11640              # disassemble a function
Refs 0x147218           # every instruction touching a global
Test-FixupsIn 0x13DC8 25
```

Two things make the binary unusually tractable: it is uncompressed and unprotected, and the
Watcom error idiom `ErrorFunc(msgString, "FunctionName")` at `0x334A0` acts as a de-facto symbol
table — its callers name themselves.

Related: [[azrael-le-image-layout]], [[azrael-key-addresses]], [[aztmod-patch-framework]]

## PowerShell's comma binds tighter than arithmetic -- this has bitten 3 times

`@($a, $b, $a + 102, $b + 68)` does NOT build four elements. The comma wins, so it
parses as `($a,$b,$a) + (102,$b) + 68` and yields **six**: `(41,401,41,102,401,68)`.
Elements [2] and [3] are then silently the wrong numbers.

That shipped for weeks as `$MAP_RECT_NEW`, collapsing the notes/inventory hot spot
to a 1-pixel sliver `(41,401) (41,401) (41,102) (41,102)` so the window could not
be clicked at all. Every other hot spot on the screen transformed correctly, which
is what made it hard to spot.

Same trap, other shapes:
- `,@($s, $x-$s)` -> `@($s,$x) - $s`
- `$arr[$base + $x, $y]` -> `$arr[$base + @($x,$y)]`

**Always parenthesise arithmetic inside an array literal or an index:**
`@($a, $b, ($a + 102), ($b + 68))`, `$arr[($base + $x), $y]`.

Symptom to watch for: an array whose `.Count` is larger than the number of commas
suggests, or a value that equals a *later* element instead of a sum.

## Downscaling art: never nearest-neighbour

`Pcx.BlitScaled` is nearest-neighbour -- one source pixel per destination pixel.
At the 55% panel scale that discards ~70% of the artwork and is why the HUD read
as rougher than stock. Use **`BlitScaledSmooth`**, which box-averages every source
pixel covering a destination pixel and snaps the result to the nearest palette
entry *already used in the source region*, so nothing off-palette appears. It
takes a `keyIndex`: that colour never contributes to an average, and a mostly-key
destination pixel stays key, which keeps sprite edges clean instead of haloing.

**Regenerate art from the STOCK game files, never from the modded copy** -- the
modded folder already holds rescaled art, so pointing the generator at it scales
twice (83x36 -> 46x20 -> 25x11). Use the Steam install, or the `*.PCX.aztbak`
backups.
