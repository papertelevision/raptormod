---
name: azrael-hud-widgets
description: "The \"floating UI\" inside Azrael's enlarged viewport is three live widgets at hard-coded screen coords, not decoration."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-19T15:34:45.853Z
---

## A FOURTH widget: the compass (found 2026-09-20)

**`COMPMAP.PCX` is a 348x24 sprite blitted straight to the screen**, surface built
at `0x10C09`/`0x10C0E` (`ebx`=0x18=24, `edx`=0x15C=348), drawn at `0x13F0C` with
**`ebx` = Y at `0x13EFD` (15)** and **`edx` = X at `0x13F02` (0x92 = 146)**.

146 = (640 - 348) / 2, i.e. hand-centred for a 640-wide screen and NOT derived
from any screen constant, so nothing in the `scr-*` family moved it and it sat
80px left of centre at 800x600. `hud-comp-x-13F02` re-centres it.

**It does not scale, and scaling it is a trap.** Its pixel buffer is sized by two
`mov eax,0x20A0` (8352 = 348x24) at `0x10C89`/`0x10C9F`, the clear at `0x13E92` is
`rep stosd` with `ecx=0x828` (2088 dwords = exactly 8352 bytes, so a new size must
stay divisible by 4), and the degree-label loop at `0x13EA3..0x13EE1` steps
`add esi,0xF` to `cmp esi,0x168` — 15 px per 15 degrees, hard-coded. Only X moved.

**Therefore the strip above the viewport must NOT scale either.** Rows 0..48 of
HUD3.PCX are **completely empty** (verified: every pixel is background index 54),
so the compass is the only thing up there. `$VIEW_Y` was `Hi 49` = 61 at 800x600,
reserving 61 rows for a 24-row sprite — dead band at the top, and the viewport
pushed down. It is now a flat **49 at every resolution**.

That also fixed the viewport running 12 rows past the panel top: `$VIEW_H` used a
hard-coded `- 49` while `$VIEW_Y` was 61. It is now `$PANEL_TOP_NEW - $VIEW_Y`.
**Never repeat a coordinate literal that another variable already holds.**

---

Azrael's Tear draws three HUD widgets at hard-coded SCREEN coordinates that used
to fall inside the stock instrument panel. Once the viewport was enlarged past
y=331 they float in the middle of the 3D scene. They are live UI, not artwork:

| surface | size | stock pos | what it is |
|---|---|---|---|
| `0x163A40` | 103x69 | (70,345) | notes/inventory list window (invback2.pcx 103x69 + eye.pcx marker) |
| `0x163A10` | 105x15 | (320,357) | status gauge frame (drawn via `0x34C40`) |
| `0x163A22` | 105x15 | (320,357) | gauge fill; `ecx` = amount, scaled /1000 |
| `0x152AD4` | 170x100 | (470,380) | object scan readout â€” owns the "Unknown Object.." string at `0x14030F` |

Sizes come from the create calls, not from measuring artwork:
`0x37B04` / `0x287DA` / `0x37AC8` all take **eax=surface, edx=width, ebx=height**,
same register order as Blit (`0x33F80`, eax=surface, edx=x, ebx=y). Surface struct
is 18 bytes: word width @+0, word height @+2, pixel pointer @+4.

Position immediates to patch (v0.9.1 moved all of them):
- inventory window: `mov ebx,345`/`mov edx,70` at 12B4E/12B59, 15873/15878, 1654F/1655A, 15DDE/15DE9
- gauge: 11E1F/11E24 (blit), 11E47/11E4C (`push y` + `mov ecx,x`), 284D8/284DD (init)
- scan: 12336/1233B (blit), 10B9E/10BA3 (create w/h)

**Why:** I first assumed these were a decorative overlay the dev painted over the
viewport edge and could simply be deleted. Deleting them would have removed the
inventory window and the object scanner.

**How to apply:** when the viewport grows, relocate these into the HUD strip below
it rather than blanking them. The scan box is plain text, so shrinking it only
clips the tail of the string.

**Correction (2026-09-19):** `0x163A40` is NOT an automap and NOT 3D-rendered --
I labelled it that for several rounds on the strength of nearby 3D-API calls. It
is the notes/inventory list window: `invback2.pcx` (103x69) is loaded into a
backing surface at `0x163A3C` (`0x28838`), `eye.pcx` (16x10) into `0x163B8A`
(`0x2889D`), and `0x288E2` appends entries to a list at `+0x14` (count),
`+0x16` (ids), `+0x7A` (pointers). So it CAN be rescaled -- rescale
`invback2.pcx` and patch the create at `0x138C4`/`0x138C9` -- but the list drawn
inside it does not scale, so shrinking the window shrinks what you can read.

See [[azrael-key-addresses]] and [[aztmod-patch-framework]].

## Sweep for hand-centred readouts, don't hunt them one at a time

Several stock elements are blitted to the SCREEN at an X hand-computed as
`(640 - surfaceWidth) / 2`. None is derived from a screen constant, so nothing in
the `scr-*` family finds them. **Enumerate them mechanically:** find every
`call 0x33F80` (blit surface to screen), look back ~28 bytes for `BA imm32`
(`mov edx,X`), and test each X against `(640 - w) / 2`.

Doing that on the installed build left only three unpatched; everything else was
already 0 (view-relative) or in the `hud-*` family:

| site | surface | stock X | what |
|---|---|---|---|
| `0x13F02` | COMPMAP 348x24 | 146 | compass — `hud-comp-x-13F02` |
| `0x10B7E` | 80x13, built `0x10AC0` | 280 | the **"-1-"** counter — `hud-num-x-10B7E` |
| `0x10877` | `0x152390` 180x40, built `0x10926` | 230 | caption box — `hud-cap-x-10877` |

The **"-1-"** is a STOCK readout, not something the mod added: `0x10AF5` sprintf's
the format `-%d-` at `0x1400C3` into an 80-wide surface, centres the text inside
it, and blits it at (280, 0). It only looked like debris because it sat 80px off
centre. Y stays put in all three — none of the Y values is a centring expression.

**Also: the scan readout is drawn from TWO places.** `hud-scan-*-12336` moved one;
`0x127F9`/`0x127FE` (surface `0x152AD4`, same stock 380/470) is the other. When a
widget has a stock position, grep for ALL sites holding that pair, not the first.

## Book / document pages: centred by offsetting the LOAD

Pages are `D:\TEXTURES\books\<name><n>.pcx` (format `%s\books\%s%d.pcx` at
`0x14076C`), and **measured off the disc they are all 640x480**. `0x1647B` loads
one into surface `0x152580`, which `scr-w/h-116C2` grew to the full screen, so at
800x600 a page landed in the TOP-LEFT corner — 80px left and 60px up of centre.
That is the "off-centre scroll".

`0x38A20(eax=surface, edx=name, ebx=X, ecx=Y)` passes X/Y to `0x3E330`, which
proves the order: it tests `xOff + imageWidth` against the surface width at
`0x3E420` and `yOff + imageHeight` against its height at `0x3E447`. Both were
zeroed at `0x1646B`/`0x1646D`.

Setting both needs 8 bytes of immediates where the original has 4, so
**`book-centre`** replaces 11 bytes (the two `xor`s plus the `lea edx,[esp+0x300]`
after them) with `jmp AztBookPos` + 6 NOPs, and `AztBookPos` — appended to the
clock blob at `0x50F2D` — sets `cx`/`bx`, re-issues the `lea` and jumps back.

Two things make that safe and fixup-free: it is a **JMP, not a call**, so `esp` is
unchanged and `[esp+0x300]` still addresses the filename buffer; and everything in
the routine is esp-relative, an immediate, or PC-relative. Only `cx`/`bx` are set
(not the full registers) because `0x38A20` reads them with `movsx edx, cx` /
`movsx edx, bx` — which keeps the immediates at 4 bytes each.
