---
name: azrael-story-log-scrollback
description: "How the story log's text surface, scrolling and render cursor work — and the Patch-Imm32 -Lin trap that corrupted the text object."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-22T00:01:28.243Z
---

The log in the panel (2026-09-21). Text object `[0x1521AC]`, 0x14 bytes:

```
+0   surface ptr        +4  x cursor (word)   +6  y cursor (word)
+8   string, realloc'd  +C  its length        +12 suppress-render flag
```

**The surface IS the scrollback bitmap.** `0x39120` renders INCREMENTALLY —
`HudPrint` (`0x39080`) appends to `[obj+8]` and draws only the new text; when the
y cursor runs past the surface height (`0x3927D`) it memmoves the surface up a
line (`0x392A9`) and carries on. So history lives in the surface, and a surface
sized exactly to the visible box has **no history at all**: offset 0 already
shows everything, there is only blank below. That was the first cut, and it is
exactly what it did.

**`0x37D98` clamps a POSITIVE y to zero** (`0x37DF1`) and reads a NEGATIVE one as
a source offset into the block (`0x37E2F`). The clip rect is built *before* that
clamp, so the box does not move. That is why scrolling is one `sub` in
`AztLogClearBx` and not a rewrite. Same shape in `0x37E74` (the conversation
list), except its args are two pushes: X at `[esp+4]`, **Y at `[esp+8]`**.

So: `$TEXTBOX_H` = window + `$LOG_HISTORY`, `aztLogScroll` = "pixels hidden above
the window" starting at `$LOG_HISTORY` (the bottom / newest). Keep `$LOG_WIN_H`
separate — the hot spot must use the VISIBLE height, never the surface.

**A fresh surface renders its first line at y=0**, which is above a
bottom-pinned window, so the box reads empty until enough text accumulates to
scroll it down. Fix: start the y cursor at `$LOG_HISTORY` (`0x3902A`). Its one
caller is `0x10D16`, the story log — verified by scanning obj1 for `E8` rel32.
**`0x39044` copies the x cursor FROM the y cursor**, which only looks sane while
both are zero; it becomes `xor eax,eax`.

**`Patch-Imm32 -Lin` IS THE INSTRUCTION, NOT THE IMMEDIATE.** It scans +1..+5 for
the old value. Handing it the immediate's own address walks the window past the
instruction: `0x3902E + 5` is the zero in the *next* one, `mov dword [ecx+8], 0`
— the string buffer pointer, which got set to 120. It assembled cleanly and
**verified cleanly**, because the expect-check was of the wrong bytes too. When
a Patch-Imm32 lands somewhere surprising, disassemble the site after installing.

## The expanding box (2026-09-21)

A toggle grows the box upward over the 3D view; a conversation expands it too.
It flips three fields of surface `0x152AD4` — height `+2`, clip y1 `+E`, pixel
base `+4` — and the blit Y together. Moving the BASE as well as the height is
what pins the bottom edge. Code lives in a SECOND CAVE at `0x511A0..0x51372`,
the middle blitter's bank-crossing path, dead because of `$ENABLE_LFB`.

**Three facts that each cost a round:**

* **`0x33F80` IS NOT TRANSPARENT ON INDEX 0.** The well looked like artwork, so
  it seemed to be — it is not, the box has always painted black over it, and
  `#2C2A18` vs `#000000` is too small a difference to notice. Anything of ours
  that overlaps the view has to be something we mean to show.
* **The box's own blit is in `0x11E68`, which the MOVEMENT code calls, not the
  frame loop.** `log-box-always` only made it unconditional *inside* that
  function. The view is opaque and repainted every frame, so an expanded box got
  wiped and only came back when something moved. Fix: wrap the view's own Blit at
  all **18** sites (`mov eax,0x152150` + `call 0x33F80` within 24 bytes) and
  repaint the box after it.
* **Extent and blit Y must be decided in ONE place.** Setting the height when the
  text draws and the Y when the box blits let them disagree: collapse, and a
  204-row blit started at 499 and ran off the panel. `AztBoxWindow` now returns
  base, height, clip, Y and the scroll offset together.

**Scrolling needs the text surface taller than the EXPANDED box**, or expanding
puts everything on screen and the arrows have nothing to do. `aztLogScroll`
counts pixels BACK FROM THE NEWEST text (0 = bottom) so one number works in both
states; the per-state upper limit is clamped in `AztBoxWindow` and written back,
because the key handlers cannot know it.

**THE BOX OWNS EVERY ROW IT CAN EVER COVER, IN BOTH STATES.** The ten rows
between the viewport's bottom edge (488) and the top of the well (499) belonged
to nobody: the view repaints 0..488 each frame, the panel art is drawn once at
start-up, so the expanded box left stale text there that drifted out of step with
the live box. Collapsed is now 489..582 (174x94) and expanded 369..582 (174x214),
derived as `$BOX_LIP = $SCAN_Y - ($VIEW_Y + $VIEW_H)`. It costs ten rows of the
panel's top bevel in that column, which the box artwork puts back.

**THE TEXT BLOCK IS PINNED TO THE BOX'S TOP-LEFT.** `0x37D98` clamps a positive
x or y to zero, so the `push 2` / `mov ecx,2` are ignored and the text always
lands at (0,0), 170 wide. Box frame artwork therefore has to be thin at the top
and left or glyphs sit on it; only the right 4 columns are free (widen by
narrowing `$TEXTBOX_W`). The block draw IS transparent on index 0 -- unlike the
surface blit -- which is why the index-2 fill shows through behind the text.

**Searching `$raw` for an obj2 address finds nothing.** The file holds the
OBJ-RELATIVE offset (`0x12150`, not `0x152150`); the loader writes the base over
it from the fixup record.

**`Patch-Imm32 -Lin` is the INSTRUCTION, not the immediate** — it scans +1..+5,
so passing the immediate's own address walks into the next instruction. It once
set the log's string pointer to 120, and verified clean, because the expect bytes
were wrong too.

**Font:** `[0x152178]` = rusgld2.pcx is what the log MOSTLY uses (24 of 43
HudPrint sites) and `[0x15217C]` = genblu2.pcx the other 15 — gold narration,
cyan for the conversation line. Shrinking only genblu2 looks like nothing
happened. Both were tried at 8/11 hinted-aliased and read as an approximation of
the typeface rather than a smaller one; if retried, move size down with
anti-aliasing left ON. `logFontEm/Height/Levels/Crisp` in the manifest are wired
through Build-Font and the installer for that.

## The box is TWO surfaces (2026-09-21, final shape)

The FRAME and the RECESS are separate surfaces, because 0x37D98 pins the text to
its destination's (0,0) and clamps a positive x away — a left inset is not
expressible. So: frame blits first, recess blits on top, text lands at the
recess's own origin. One surface meant the new bezel could only ever be drawn
INSIDE the panel's old one.

* frames `BOXOFF/BOXON.PCX` 207x111 / 207x231 at (537,489) / (537,369) — that
  rect is the old well assembly incl. bolts, measured off HUD3.PCX
* recess 156x82 / 156x202 at (547,504) / (547,384) = `SURF_BOX` (0x152AD4)
* `Build-HudBox.ps1` measures the recess out of the finished pixels into
  `art\hud-box.json`; Build-AztMod asserts the frame size matches and derives
  everything else. **Measure the recess by MATCHING THE CENTRE'S BRIGHTNESS,
  not by "luma < 70"** — the inner shadow is darker than the fill, so a dark
  test walks through it into the bevel and the text draws on the frame.
* three caves now: 0x132980 (stub), 0x511A0..0x51372 (box logic, 434/466),
  0x51440..0x515E3 (art: surfaces, filenames, loader, fill; 225/419)
* `AztBoxFill` copies the frame's own recess pixels in, a row at a time (strides
  differ). **It must preserve edx** — that carries the scroll offset back to
  AztLogClearBx; clobbering it subtracted a framebuffer address from the draw Y
  and the text vanished.
* toggle icon is IN the artwork (chevron per state), so swapping the image
  swaps it; only the click rect is code.

## OPEN, next session

1. **Interior padding** — text butts the recess edges. Grow the inset in
   Build-HudBox (`$x0++; $y0++; $x1--; $y1--`) to ~4px and rebuild.
2. **Flicker where the open box overlaps the viewport.** The 18 view-blit
   wrappers fixed the collapsed case; something still repaints there.
3. **Q-menu sound on toggle.** Menu open (0x175E9) is all blits; WAV names are
   not literals in the EXE. Pull on `StartAmbientSoundFX`, string at file
   0x1864CF, to find the SFX dispatcher.
4. **Inventory graphic** (left of the panel) does not fill its area — move to
   the top-left of the visible region and stretch to the full height.
5. Art re-render at exactly 207x111 / 207x231, left rail ~17px to match the
   right; the open frame is ~25% squashed.

Related: [[azrael-key-addresses]], [[azrael-hud-reskin]]
