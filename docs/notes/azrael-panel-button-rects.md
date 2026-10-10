---
name: azrael-panel-button-rects
description: "FOUND â€” Azrael's HUD hot spots are polygon tables in obj2's file-backed data (0x146A7C..0x14712E), patched directly; no cursor remap needed."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-19T17:19:51.793Z
---

The instrument-panel hot spots are **static polygon tables in R.EXE's data**,
not runtime objects. `0x2A349(al = screen 0..6)` builds screen N's list at
`0x164D9C + N*14` from the table at `[0x14712E + N*4]`:

```
word count
count x { word n;  int16 x,y [n];  word flagA; word flagB; word cursorIcon }
```

`0x33698(eax=region, ebx=points, edx=n)` stores n at +0, the point pointer at
+2, and derives the bounding box (+6..+0xC) **from the points at runtime**;
`0x336F8` tests bbox then point-in-polygon. `cursorIcon` indexes 30 cursor
shapes (`mice\pointer.pcx`, `active`, `look`, `use`, `take`â€¦) that `0x2A2EA`
loads as 30x30 surfaces at `0x164B80 + i*18` â€” so a "hover effect" is the cursor
changing, and it follows the mouse.

The block is contiguous, `0x146A7C..0x14712E`, in obj2's file-backed region
(`file = 0x184A54 + (lin - 0x140000)`; screen 6 ends exactly where the pointer
table starts). Rewriting the int16 points there fixes hit-testing AND anything
drawn from the region, with no hook. AztMod does this as `hotspots-screen0..6`,
one patch per table, and the two cursor-remap hooks (`AztHudPoint`,
`AztHudEvent`) are retired â€” with the data patched they would double-transform.

What the seven screens hold:
- 0 = in-game HUD: viewport rect `(44,49)-(596,331)`, inventory window `(70,345)-(172,413)`,
  five panel polygons (y 338..426)
- 1..3 = HUD + overlays composited INTO the view (text-box arrows at x 441..576,
  list rows at x 198..389) + the same panel polygon; 3 adds one more
- 4 = orrery puzzle (icon 10, two 27/28-point rings)
- 5 = a text panel `(414,89)-(583,294)` + the inline control `(554,437)-(639,479)`
- 6 = full-screen catch-all `(0,0)-(639,479)` â€” leave alone

Transform rules used: y >= 318 â†’ panel transform; the inventory window rect â†’ its
relocated rect (not scaled); the viewport rect â†’ the new viewport; anything
inside the stock view â†’ shift by the view-origin delta (-44), or +44 for the
right-anchored text-box cluster that `view-text-x` moved +88 view-relative.

## The highlight graphic is separate from the hot spot

Patching the polygons fixes the CLICK but not the visual. The lit state is three
sprite pairs loaded at `0x2D1E4` â€” `nbut0off/on` 83x36 (`0x164E38`/`0x164E4A`),
`nbut1off/on` 77x42 (`0x164E5C`/`0x164E6E`), `nbut2off/on` 90x43
(`0x164E80`/`0x164E92`) â€” blitted straight onto the panel.

Their draw anchor is **static data, not code**. The call sites read
`dword [0x147486]` and `dword [0x14748C]` and take the high word, i.e. the words
at **`0x147488` = 235** and **`0x14748E` = 343** â€” which matches screen 0's hot
spot #0 (x 233..310, y 338..372). Nothing in code writes them and they are inside
obj2's file-backed window, so they patch as data (`nbut-anchor-X/Y`).
`0x14748C` / `0x147492` are the live cursor; leave those alone.

Sizes also need scaling or the highlight is twice the size of its button. Watcom
leaves `ebx`/`edx` set for the NEXT create across the intervening malloc, so the
(height, width, buffer) sites are not adjacent â€” see the explicit list in
`Build-AztMod.ps1` (`nbut-h/w/buf-*`), and rescale the six PCX files to match.

**Why the earlier hunt failed:** the objects the code *reads* are BSS, built from
these tables at startup, and the immediate-address scan only ever showed uses.
My data scan for panel-shaped rects DID hit this block (0x146A80, 0x146B14â€¦) and
I dismissed the hits as sliding-window noise. The `sscanf` lead, `0x335EC`,
`0x3561D`, and the BSS widget array were all dead ends.

See [[azrael-hud-hit-regions]].

