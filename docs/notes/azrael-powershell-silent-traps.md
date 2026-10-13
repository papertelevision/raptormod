---
name: azrael-powershell-silent-traps
description: "Two PowerShell 5.1 traps that corrupt data without erroring - bitwise shifts keep the LEFT operand's type, and variable names are case-insensitive."
metadata:
  node_type: memory
  type: feedback
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-07T16:44:43.774Z
---

Two PowerShell 5.1 behaviours that produce **wrong data with no error**, both hit while
building the texture-measurement tools on 2026-09-27.

## 1. `-shl` / `-shr` keep the LEFT operand's type

`[byte]41 -shl 16` is **0**, not 2686976 — the result is truncated back to a byte.

```powershell
$b = [byte]41
$b -shl 16          # 0        (Byte)
[int]$b -shl 16     # 2686976  (Int32)
```

**Why it matters here:** every pixel routine in this project packs palette bytes into an
int with `(r -shl 16) -bor (g -shl 8) -bor b`. `$t.Palette[...]` returns a **byte**, so
without an explicit `[int]` the red and green channels vanish and only blue survives.

It cost two bugs in one session. The visible one rendered every thumbnail on a palette
contact sheet blue. The **invisible** one was worse: a colour-histogram key
`(($r -shr 4) -shl 8) -bor ...` silently binned on green and blue only, so a whole set of
measured "dominant colours" had red excluded from the clustering. Nothing errored, and the
hex values looked plausible. After the fix, `corirock` moved from a false blue-grey
`#16171A` to a correct neutral `#1A191B` and several saturation figures roughly halved.

**How to apply:** cast to `[int]` at the point the byte is read, not at the shift:

```powershell
$r = [int]$t.Palette[$c*4]; $g = [int]$t.Palette[$c*4+1]; $b = [int]$t.Palette[$c*4+2]
```

Values that came out of `Marshal::Copy` into an `int[]` are already `Int32` and are safe —
the trap is specific to reading from a `byte[]`.

## 2. Variable names are case-insensitive, so `$top` IS `$Top`

A loop variable that differs from a parameter only in case **overwrites the parameter**:

```powershell
param([int]$Top = 6)
$top = @($bins | Select-Object -First $Top)   # $Top is now an Object[]
# next iteration: "Cannot convert System.Object[] to Int32"
```

Hit twice in one session — `$top`/`$Top` and `$h`/`$H` (a hex string clobbering a canvas
height). The second only surfaced as a garbled `Write-Host` because the height had already
been used; had the order differed it would have produced a wrongly-sized image instead.

**How to apply:** never name a local after a parameter with different casing. Use
`$topBins`, `$hex`, `$rowIdx`. If a loop errors on a type conversion in its *second*
iteration, suspect this first.

## 3. `Write-Host` output does NOT reach the pipeline — capture needs `*>&1`

Nearly every tool in this repo prints with `Write-Host` (Read-Anim, Read-Zones, Set-SaveRoom,
Test-Movie...). `$out = & .\tools\Read-Zones.ps1 | Out-String` returns an **empty string**: the
text appears on the console, so it looks like it worked, and the parse that follows silently
finds nothing.

```powershell
$out = & $path @params *>&1 | Out-String     # captures it
```

Cost two wrong answers in one session: a room-name harvest that reported "0 room names" and an
earlier frame-payload parse that reported 0 bytes. Both times the data was on screen while the
variable was empty. **If a regex over captured tool output matches nothing, check the capture
before blaming the regex.**

Note `@{ }` written inline is a hashtable ARGUMENT, not splatting — splatting requires a
variable: `$p = @{Show=$true}; & $script @p`.


## 4. `A-Dd` in src\Asm.ps1 IGNORES its argument and emits four ZERO bytes

`function A-Dd { param($a,$v) Add-Bytes $a @(0,0,0,0) }` -- it is the PLACEHOLDER used to
declare overlay variables (`Add-Label $ovl 'aztFoo'; A-Dd $ovl 0`), so the ignored argument is
invisible in every normal use. The literal form is **`A-Dd32`**.

Passing a real value to `A-Dd` is silent and builds clean. Used to emit the imm32 of
`add edi, <row advance>` in the boot readout blit, it assembled as `add edi, 0`: the
destination never stepped a row, all 192 rows wrote as one continuous run at the wrong pitch,
and the text sheared across the whole screen as coloured stripes.

**How to apply:** `A-Dd` to DECLARE a variable, `A-Dd32` for any value that matters. When a
hand-emitted instruction misbehaves, disassemble the built blob and read the immediate back --
searching the manifest's overlay hex for the opcode (`81C7` here) and decoding the following
dword found it in one step.

## 5. `[int]($x / 8)` ROUNDS, it does not truncate -- and it rounds half to EVEN

PowerShell's `[int]` cast uses banker's rounding. `[int](12/8)` is **2**, not 1. `[int](28/8)`
is **4**, not 3. Only values whose fraction is exactly .5 are affected, which for a divide-by-8
means every input congruent to **4 mod 8** -- one in eight.

Used to pack a 1bpp font bitmap (`byte = $x / 8`), it put one pixel in eight into the NEXT
byte. The result rendered as almost-text: clearly letters, spaced right, completely unreadable.
It survived three rounds of verification because the check scripts shared the same expression,
so the "reference" reproduced the same corruption and compared equal.

**How to apply:** use `-shr` for a power-of-two divide (`\$x -shr 3`) or `[Math]::Floor`.
When verifying generated data, the reference MUST be computed a different way than the thing
being checked -- here, counting set bits and comparing against the source pixel count is what
finally exposed it (1626 pixels in, 1578 bits out).

## 6. `$PSScriptRoot` is EMPTY while parameter defaults bind under `powershell -File`

```powershell
param([string]$Sym = "$PSScriptRoot\..\AztMod.overlay.sym")
```

Run with `& .\tools\X.ps1` this is correct. Run with `powershell -File .\tools\X.ps1` --
which is how a double-clicked `.cmd` launcher runs it -- `$PSScriptRoot` is empty during
parameter binding, so the default becomes `\..\AztMod.overlay.sym` and resolves against
the current drive root as **`C:\AztMod.overlay.sym`**. Every tool in this repo uses that
pattern, so it only shows up when one is launched a new way.

**How to apply:** default such parameters to `''` and fill them in the BODY, where
`$PSCommandPath` is reliable:

```powershell
param([string]$Sym = '')
$toolDir = Split-Path -Parent $PSCommandPath
if (-not $Sym) { $Sym = Join-Path $toolDir '..\AztMod.overlay.sym' }
```

Inside a function in a dot-sourced file `$PSScriptRoot` is fine (verified: `Import-AztRoom`
loads correctly under `-File`) -- the trap is specific to the top-level script's `param()`.

Two neighbours hit in the same five minutes, both from this project's own path:
* `-File` with an unquoted path under `C:\Program Files (x86)\...` takes **`C:\Program`**
  as the script name and exits immediately. Quote it.
* `"Azrael's Tear"` contains an apostrophe, so embedding that path in a **single-quoted**
  PowerShell string inside a generated script terminates the string early. Pass it as a
  parameter instead of interpolating it into generated code.

Related: [[azrael-powershell-utf8-trap]], [[azrael-re-tooling]], [[azrael-geometry-export]], [[azrael-viewport-paint-not-suppress]]


**The watcher's session loop is ONE scope.** Watch-HostRender's run loop is thousands of lines in a single scope, so a new short temporary silently overwrites a long-lived one. 2026-10-07: the F7 relief handler used `$rs` for the chosen step -- `$rs` is the lamp's shadow-map Raster -- and the next frame asked the card for a 0x0 shadow map ("off-screen buffer not usable (status 0x8CD6)"), ending the session (Josh saw it fall back to the CPU picture with F9 dead). Before adding any variable to that loop, grep `\$name\b` for existing uses; prefer descriptive names (`$relStep`, not `$rs`).

**Aliases beat functions.** A helper named `GP` silently ran `Get-ItemProperty` (alias `gp`) instead; inside a bare `catch {}` that cost a whole live test run with no output. Check `Get-Alias <name>` before naming a short helper (`gp`, `gc`, `gi`, `sl`, `si`, `r`, `h`...), and never leave a catch empty in diagnostic code.

**`Start-Sleep -Milliseconds 2` takes 15.3 ms**, and `timeBeginPeriod(1)` does NOT fix it (measured on this box, PS 5.1). `[Threading.Thread]::Sleep(1)` after `timeBeginPeriod(1)` takes ~2 ms. One Start-Sleep per frame in the watcher's sync wait capped host render at 31-36 fps with a 7-12 ms render.

## A type compiled inside a function vanishes when that function is skipped (2026-10-07)

`ProcMem.cs` was only Add-Type'd inside `Get-AztGuestBase`. Once the loading gate found the game first, the watcher skipped that search, the first `RdU32` threw `Unable to find type [AztTool.ProcMem]` outside any try, and the whole watcher stopped: no GPU renderer, panel and scanner failed too. It's now compiled up front beside the main Add-Type list. **Any type a script uses on more than one path must be compiled unconditionally at the top**, never lazily inside one path's helper. Related: [[azrael-gpu-boot]].

## A failed edit that still writes (2026-10-08)
Under the default ErrorActionPreference a failing expression (IndexOf out of range, Substring) only prints an error and leaves the variable $null; the next line's [IO.File]::WriteAllText then wrote an EMPTY CORICORI.json. Any read-modify-write of a settings file: set $ErrorActionPreference = 'Stop' (or check the new text is non-empty and parses) BEFORE writing. The rooms-history round snapshots are the backup.

## One .cs file in two Add-Types: "Cannot add type ... already exists" (2026-10-11)

PowerShell refuses a type NAME it has already added in the session -- public or internal, it makes no difference. The watcher compiles the title (loading gate) and the renderer as two Add-Types, and both needed the cursor shapes (`tools\CursorShapes.cs`): the second compile failed outright, which would have ended the watcher. Referencing the first assembly is not possible either (in-memory, no path).

**How to apply:** give one copy another name with a define. CursorShapes.cs declares `TitleShapes` under `#if TITLE_GATE`, else `CursorShapes`, and the gate compiles with `-CompilerParameters` (`$cp.CompilerOptions = '/define:TITLE_GATE'`; `-CompilerParameters` replaces `-ReferencedAssemblies`, so add `System.dll` and `System.Drawing.dll` to `$cp.ReferencedAssemblies` yourself; `GenerateInMemory = $true`). Test the two compiles together in ONE fresh `powershell` -- each alone passes. See [[azrael-raptor-docs]].
