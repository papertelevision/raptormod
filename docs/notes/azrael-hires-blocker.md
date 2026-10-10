---
name: azrael-hires-blocker
description: Azrael cannot exceed 640x480 â€” its screen writer is hand-unrolled for exactly four 64 KB VESA bank boundaries and there is no linear-framebuffer path.
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-20T17:47:19.013Z
---

**SUPERSEDED 2026-09-20 â€” 800x600 RUNS.** The linear framebuffer
([[azrael-lfb-plan]]) removed blocker 2 entirely, and DOSBox logs
`DISPLAY: VESA 800x600 256-colour graphics mode 103h`. The 3D renders correctly.
Read the rest of this file as the history of why it was hard, not as a verdict.

**Mode 0x103 details** (BIOS-queried under a matching conf): ModeAttributes
0x009B (bit 7 = LFB), 800x600, 8bpp, BytesPerScanLine 800, and **PhysBasePtr
0xC0000000 â€” the same base as 0x101**, so the LFB patches need no change.

800x600 rather than 1024x768 for two reasons: it is 4:3 like the stock 640x480,
so every coordinate scales by a uniform **1.25** with no aspect correction; and
the rasteriser is the bottleneck ([[azrael-blit-vs-rasteriser]]), so 1.56x the
pixels is affordable where 2.56x is not.

Set `$ENABLE_HIRES = $true` with 800/600/0x103; the pre-existing scaffolding adds
~61 patches (mode sites, surface dims, strides, byte sizes, clip limits, mouse
limits, centres) and Apply-AztMod moves UVCONFIG.DAT aside on its own. Staging
conf `memsize` raised 16 -> 32 for the larger surfaces.

## How the layout scales (implemented)

**One factor, applied once.** `$HS = $SCREEN_W / 640` in Build-AztMod, and
`$PANEL_SCALE_EFF = $PANEL_SCALE * $HS`. Folding the screen scale into the panel
scale means `To-PanelX/Y` keep working untouched and emit screen-space
coordinates at any resolution. `Hi(v)` scales anything else. A guard throws if
the target is not 4:3, because then one factor would not do.

The layout is still DESIGNED in 640x480 and scaled at the end â€” e.g. the
inventory housing is at (90, 391) in design space, `Hi()`d to the real screen,
and Build-HudArt scales the copy by the same factor so bezel and window stay
registered.

Build-HudArt now takes `-ScreenW/-ScreenH`, builds a fresh canvas at that size
(rather than editing a 640x480 copy), scales the compass strip as well as the
panel, and resizes MAPBKGRD â€” it is a full-screen image, so at hi-res it must
grow rather than sit in the corner. The resolution is published in the manifest
as `art.screenW/H` and Apply-AztMod forwards it.

At 800x600 (scale 1.25): panel 440x111 at (180,489), viewport 800x428 at (0,61),
housing 212x111 at (112,489). 347 patches.

**800x600 IS THE WORKING CEILING. 1024x768 sets the mode but dies ~15 s in.**

Mode 0x105 (scale 1.6) sets correctly â€” DOSBox logs
`DISPLAY: VESA 1024x768 256-colour graphics mode 105h` â€” and renders. Panel
563x143 at (230,625), viewport 1024x547 at (0,78), housing 272x143. But it
**exits after 10-20 seconds**, reproducibly.

Ruled OUT, with evidence:
* **Not memory size.** Identical failure at `memsize` 32 and 64. DOSBox confirmed
  it allocated what was asked (`Using 16384 DOS memory pages (64 MB)`). Note
  DOSBox warns `Memory sizes above 31 MB aren't recommended for most DOS games`,
  so 64 is if anything worse â€” keep 32.
* **Not a DOS/4GW fault.** `r > AZERR.TXT` comes back **0 bytes**, and DOSBox's
  own log shows a clean ordered shutdown ending in `atexit`, no exception. This
  is the **silent-exit** signature already recorded for the UVCONFIG mode-scan
  failure below â€” the game decides to quit, it does not crash.
* **Not the row*552 stride family.** Those are all patched consistently, and a
  scan for hidden multiples of the SCREEN stride 640 turned up only coincidences
  (0xFF00 masks, 86400 = seconds/day).

A diagnostic `pause` in AZRAEL.BAT does NOT hold the window, so R.EXE takes the
whole DOS session down with it rather than returning to the batch.

**Next lead:** it survives init and the mode set, then quits ~15 s in, silently â€”
so look for the game's own "give up" paths (the `0x334A0` error printer and
whatever calls exit) rather than for a fault. PhysBasePtr is `0xC0000000` for
0x101, 0x103 AND 0x105, so the LFB is not the difference.

### Two hot-spot branches did not scale (fixed)

Both were silent â€” the build succeeded and the art looked right, but the UI could
not be hovered:

* `inHousing` did `x + $INV_DX` / `y + $INV_DY`, a 640-space SHIFT, while the art
  generator draws the housing at `Hi(src + 62)` with the copy scaled. Now
  `Hi($x + $INV_DX)` and `$PANEL_TOP_NEW + Hi($y - $INV_SRC_Y)`. At 640x480
  (HS = 1) that is identical to the old arithmetic, so it is a no-op there.
* `isFullScreen` left the whole-screen catch-all at 639x479, i.e. covering only
  the top-left corner of a hi-res screen. Now maps to `$SCREEN_W/H - 1`
  (this is what added `hotspots-screen6`).

**Lesson: anything that "shifts" rather than "transforms" is a hi-res bug
waiting to happen.** Audit for `+ $` deltas applied to stock coordinates.

### The cursor was trapped in a 640x480 box â€” and raising the limit made it WORSE

Symptom: at 800x600 the pointer could not leave the top-left 640x480, so the
lower panel was unreachable. Telling detail from the user: the story text drew in
the right place but sat OUTSIDE the reachable area â€” so the layout was fine and
only the cursor was wrong.

The mouse event handler at `0x358E3` does `cursorX = driverX / [0x182D50]`, and
that divisor is built at `0x35C7A..0x35C86` as **`(maxX + 1) / [0x14388A]`**,
where `0x14388A` is a **double holding 640.0** (`0x143892` holds 480.0). Stock:
(639+1)/640 = 1.0, so the cursor tracks the driver exactly.

Patching maxX to 799 and leaving the constant at 640 gives 800/640 = **1.25**,
which DIVIDES the position DOWN and pins the cursor inside 0..639. **The existing
`scr-w1-35C48` / `scr-h1-35C4E` patches were actively harmful on their own.**

Fix, part 1: `mouse-norm-14388A` / `mouse-norm-143892` move those doubles to
SCREEN_W/H, restoring the ratio to 1.0. Plain obj2 doubles, no fixups, no other
readers.

â€¦but that is NOT the fix, because **the numerator is the DRIVER's number, not
ours.** `0x35C2B` calls `int386(0x33, ...)` with `AX=0x31` (get current virtual
coordinates) â€” Watcom convention, `eax`=int no, `edx`/`ebx`=REGS struct, fields
`eax+0 ebx+4 ecx+8 edx+12`. If AX comes back unchanged the driver doesn't support
it and `0x35C48` supplies 639/479 as a **fallback only**. So `scr-w1-35C48` moves
a value that usually isn't even used, and the ratio can't be balanced from our
side. Both `scr-w1-35C48` and `mouse-norm-*` are effectively no-ops now; they are
kept only so the fallback path stays self-consistent.

### The divisor is half of a MATCHED PAIR â€” never delete one side

| addr | operation | direction |
|---|---|---|
| `0x35939` | driver range = screen rect **Ã—** `[0x182D50]` | screen â†’ driver |
| `0x358E6` | cursor = driver coord **Ã·** `[0x182D50]` | driver â†’ screen |
| `0x35A45` | set cursor = screen coord **Ã—** `[0x182D50]` | screen â†’ driver |

`0x35939` is the range setter: it scales the rect, **writes the scaled value back
into the rect in place** (`0x35964`), then issues `INT 33h AX=7` and `AX=8`.

Deleting just the divide (the `mouse-nodiv` attempt) left the multiply shrinking
the range unopposed, and because the scaling is in-place it **compounds on every
call**: 799 â†’ 639 â†’ 511 â€¦ That produced "the cursor box gets even smaller after a
room change", which is the diagnostic signature of divisor â‰  1.0. Fixing one half
of a symmetric pair is always wrong here.

### The actual fix: `mouse-unity`

The game already contains a 1:1 path, gated at `0x35CA0` on `[0x147592]`: it
writes 1.0 into `[0x182D58]` (as `0`/`0x3FF00000`) and copies it to `[0x182D50]`.
NOPing the `jnz` at **`0x35CA8`** (`75 20` â†’ `90 90`) forces it, making all three
sites identity at once with the pair still matched. Two bytes, no fixups.

**Do NOT NOP the `fdiv`s** â€” there are fixups at `0x358E8`/`0x35902` and the
loader writes the operand back; see [[azrael-le-image-layout]].

### The seven range setters â€” enumerate them, don't guess

`0x35939` is the ONLY thing that issues `INT 33h AX=7/8`, and it has **exactly
seven callers**. Find them by scanning obj1 for `E8` whose `i+5+rel32` equals the
target â€” the game reaches `INT 33h` through the DOS/4GW thunk table (`int nn;
ret` entries around `0x528A8`), so scanning for `CD 33` finds only the table.

Six build the rect from a `mov ecx,<w-1>` / `push <h-1>` pair via the rect ctor
`0x335EC` (Watcom: `eax`=&rect, `edx`=left, `ebx`=top, `ecx`=right, stack=bottom):

| caller | imm pair | covered by |
|---|---|---|
| `0x1027A` | `0x10239` / `0x1024A` | `scr-w1-*` / `scr-h1-*` |
| `0x132DF` | `0x132B9` / `0x132C5` | â€ |
| `0x16DCF` | `0x16DAF` / `0x16FF1` | â€ |
| `0x1700A` | `0x16FF6` / `0x17A08` | â€ |
| `0x17A1A` | `0x179FC` / `0x35CF8` | â€ |
| `0x35D12` | `0x35CFE` / `0x35C48` | â€ |
| `0x13292` | **rect (44,49,595,330)** | `confine-*` (was MISSED) |

The seventh is the other half of a toggle at `0x13240` on `[0x14721C]`:
`jz 0x132AF` â†’ full-screen rect; fall through â†’ **confine the pointer to the 3D
viewport**, using the stock viewport rect. `0x3561D` and `0x35A45` both preserve
`edx`/`ebx`/`ecx`, so the values set before them survive into the rect build.
`confine-l/t/r/b/cx/cy` scale it, and they live inside `if ($ENABLE_BIG_VIEW)` so
they track the viewport rather than the screen.

**Method note:** `0x3544D`, called after every cursor update, is only the
software-cursor redraw â€” not a clamp. Ruled out by reading it.

Still 640-space at hi-res: the cursor's start position `mov word [0x182D6C],0x140`
/ `[0x182D6E],0xF0` at `0x35CDC`/`0x35CE5` (320,240). Cosmetic only.

### THE REAL CAP: an absolute clip rect, `mouse-clip-*`

`0x35939` never hands the caller's rect to the driver. It first builds

    (0, 0, round(divX * [0x143858]), round(divY * [0x143850]))

at `0x35986..0x359D0` and **intersects the caller's rect with it** (`0x33550`)
before issuing `AX=7`/`AX=8`. Those doubles are **639.0 and 479.0**. So all seven
callers were clipped back to 640x480 whatever they asked for.

`mouse-clip-143858` / `mouse-clip-143850` move them to SCREEN_W-1 / SCREEN_H-1.
Plain obj2 doubles, no fixups.

**These are a DIFFERENT pair from `mouse-norm` at `0x14388A`/`0x143892`**
(640.0/480.0, which feed the divisor). Four screen-sized doubles sit within 0x48
bytes of each other and do two unrelated jobs. Patching one pair and not the
other is what made this take five rounds.

### The user observations that cracked it

Prose beat disassembly here â€” each of these eliminated a whole class of cause:

* *"stops 4/5 of the way right"* â€” 640/800 AND 480/600 are both exactly 4/5, so
  one square 640x480 box, not a per-axis error or a scale factor.
* *"can span upwards into the compass"* â€” rect top is 0, so the FULL-SCREEN rect
  was active, not the confine-to-viewport rect (top 61). Killed that hypothesis.
* *"gets even smaller after a room change"* â€” compounding, i.e. the in-place
  multiply in `0x35939`, i.e. divisor != 1.0.
* *"the text draws in the right place but sits outside the reachable area"* â€”
  separated the layout problem from the cursor problem at the very start.

**Ask for the cursor's stopping point as a FRACTION of the screen.** A ratio
identifies the constant; "it doesn't reach" identifies nothing.

Ruled out along the way, each by reading the code: `0x3544D` (software-cursor
redraw, not a clamp); `INT 33h AX=0` reset at `0x35D3F` (one caller, `0x102CD`,
shutdown only); the DOSBox driver itself (it was never asked for more than 639).

Also added `scr-hc-*` at `0x132AF`, `0x16DA5`, `0x179F2` â€” the cursor's START Y
(240). There was a `scr-wc` family for X but the matching Y was never patched.

**The general trap: a ratio of two patched constants.** Scaling one end of
`(a+1)/b` and not the other silently inverts the intent. Look for divisors built
from screen constants, not just the constants themselves.

**Still open at hi-res:** `$ENABLE_HUD_OVERLAY` is OFF â€” HUDBOT.RES is authored
in 640-space view coordinates and Build-HudOverlay has not been scaled. The
system fold-out and story log are drawn from unscaled art (SAVE*.PCX is 206x170),
so they sit small. Some rectangular artefacts remain visible in the 3D view and
have not been diagnosed.

---

Historical verdict below (both blockers, in the order they were found):

Two separate blockers were found, in order. The first is solvable, the second is
not â€” not without rewriting the renderer.

## 1. UVCONFIG.DAT (solved)

`GAME\AZRAEL\UVCONFIG.DAT` is a saved SciTech UniVBE config; its strings read
`S3 SuperVGA (Trio64) with 1 Mb`. While present, the driver only offers the mode
list it was detected with, the game's mode scan fails, and it exits **silently** â€”
nothing in DOSBox's log, and nothing on the game's own stdout either (verified by
redirecting it inside DOSBox; the file comes back empty). Move it aside and
VESA `0x103`/`0x105` set correctly.

Bisect that found it â€” change ONE variable, the mode number, sizes untouched:
`0x100` (640x400) runs; `0x103`/`0x105` exit; `0x103` with the file moved aside
runs. A *lower* mode working proves the mode-set path and the four patch sites
are fine.

Mode sites (a code-wide scan confirms there are only four): `0x33ABB` (fed to
INT 10h AX=4F02h at `0x33AD4`), `0x33C03` and `0x33C17` (mode-list scan, imm16),
`0x33C4C` (AX=4F01h frame).

## 2. Banked VESA with four unrolled boundaries (fatal)

At 1024x768 the game runs and renders **total corruption, including video**.
Cause: the video layer is **VBE 1.2 banked**, writing through a 64 KB window.

`0x33EB8` precomputes where each window boundary falls, as an (x,y) pair, by
dividing the boundary offset by the scanline stride. `[0x182510]` is the **window
size in bytes** (WinSize KB << 10, set at `0x33D24`), not a page size.

It computes exactly **four** boundaries â€” `0x182514/16`, `0x182518/1A`,
`0x18251C/1E`, `0x182520/22` â€” and those are **hand-unrolled into five separate
blit routines** (around `0x3413F`, `0x34E25`, `0x35182`, `0x3457D`, `0x349DE`),
11â€“16 references each. It is not a loop over a table.

| mode | bytes | 64 KB windows | boundaries needed |
|---|---|---|---|
| 640x480 | 307,200 | 4.69 | 4 â€” **fits exactly** |
| 800x600 | 480,000 | 7.32 | 7 |
| 1024x768 | 786,432 | 12.00 | 11 |

**There is no linear-framebuffer fallback.** The layer reads WinA/WinB attributes
(`+0x2`/`+0x3`) and never touches PhysBasePtr (`+0x28`) or the `0x4000` LFB mode
flag â€” confirmed by scanning the whole video layer for both.

## REVISED 2026-09-20 after profiling the blit

"A renderer rewrite" was too pessimistic, but the real constraint turned out to
be somewhere else entirely.

**The banking surface is bounded, not diffuse.** The actual pixel movement is
four hand-written asm functions â€” `0x50E40`, `0x50EA5`, `0x5111C`, `0x513BF` â€”
containing **8** `movzx edi,[ebp+0x2C]; shl edi,4` window-base computations
(segment<<4 = 0xA0000, which is why no 0xA0000 immediate exists) and **9**
`mov ax,0x4F05; int 0x10` bank switches. The copy itself is `rep movsw`.

**An LFB route exists in principle:** set the mode with bit 14, read PhysBasePtr
(ModeInfoBlock +0x28), map it with DPMI INT 31h AX=0800h, patch the 8 base sites
to load that 32-bit linear base (8 bytes -> a 6-byte `mov edi,[base]`, it fits),
and set `[0x182510]` huge so `0x33EB8` puts all four boundaries past the end of
the screen and the unrolled crossing never fires. Untested.

**But the binding constraint is the RASTERISER, not the blit.** See
[[azrael-blit-vs-rasteriser]]. Rasteriser cost is linear in pixels, so 800x600
costs 1.56x and 1024x768 costs 2.56x â€” and we are already CPU-bound in the
emulator. Higher resolution buys looks and spends smoothness, which fights the
project's other goal. Plus 346 hardcoded coordinate immediates and all-new art.

The practical ceiling stays 640x480 unless that trade is explicitly accepted;
the viewport reaches 640x342 (1.41x stock area) with the panel at 55%.

memsize does matter at 1024x768 (16 MB exits after ~18s, 32 MB stays up) â€” the
full-screen surfaces go from 307,200 to 786,432 bytes each. Irrelevant now.

See [[azrael-stride-derived-offsets]] and [[azrael-panel-button-rects]].

## The 1024x768 "silent exit" is a NAMED fatal error (2026-09-20)

It was never silent. **`0x334A0` is the game's fatal error handler**, and it prints
nothing you can capture because of the order it does things:

    call 0x102B0            ; tear down video/mouse/sound
    system("cls")           ; string at 0x1436A8
    printf("RAPTOR ERROR in %s\n", <function>)   ; fmt at 0x1436AC
    vprintf(<detail>)                            ; via 0x50C5A
    printf("\n\n")                               ; 0x1436C0
    call 0x50C71            ; exit

`r > AZERR.TXT` comes back empty because DOS `>` only redirects stdout and this
goes elsewhere; and trapping at the tail (`EB FE` over the exit call, or even
after the first printf) does NOT hang -- control dies inside the teardown or the
`system("cls")`. So the message is unreachable in practice.

### The technique that DOES work: trap-and-bisect

`EB FE` (`jmp $`) over a `call 0x334A0` turns "quits" into "hangs", and a hung
process is trivially observable from PowerShell (`-not $p.HasExited`).

1. Trap `0x334A0` itself to confirm the quit is a fatal error at all.
2. Enumerate every `call 0x334A0` -- there are **184** -- and read the two pushed
   string literals before each; they give the function name AND the message, e.g.
   `GetTextureMemory / "Not enough space in texture cache for %d bytes."`
3. Bisect: trap half, run ~38 s, see whether it hangs. 8 rounds, fully scriptable.
   Original bytes are recomputable (`E8` + `int32(0x334A0 - (site+5))`), so any
   subset can be patched and restored without a rebuild.

**Result: `0x2AC60` = `Teleport Player in WORLDENG`, "Cannot find teleport object
%s".** It looks the object up BY NAME (`0x3A448` on `object[i]+0x34`, table at
`0x1841D0`) and dies if absent -- nothing to do with pixels, which is why none of
the memory/texture/SVGA traps fired.

**CAVEAT, unresolved:** every one of these runs was UNATTENDED. A teleport firing
~15 s into an idle game may be a scripted or attract-mode event rather than a
consequence of the resolution, so this may be a property of idling, not of
1024x768. Confirm by actually playing before concluding.

Also worth knowing: `-SkipIntro` made no difference (15.1 s vs 21.8 s), so the
movie player is NOT involved.
