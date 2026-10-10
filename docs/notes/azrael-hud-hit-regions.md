---
name: azrael-hud-hit-regions
description: "Azrael's HUD click handling â€” cursor globals, the region dispatcher worth hooking, and the handful of hard-coded tests."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-19T15:50:33.561Z
---

HUD mouse input in Azrael's Tear reads two screen-space globals:

- **`word [0x182D6C]` = cursor X**, **`word [0x182D6E]` = cursor Y** (plain pixels)
- (`0x14748A` / `0x147490` are 16.16 and only drive cursor *drawing* â€” not hit tests)

Two separate mechanisms consume them:

**0. The event record â€” this is the one that matters for hover and click.**
A 4-way switch at `0x36D32` writes the event sub-type; every arm jumps to
`0x36D49`, which stamps the live cursor into the event record at
**`0x182DCA` (x) / `0x182DCC` (y)** and dispatches with `call 0x3668E` at
`0x36D74`. Because all arms converge on that one store, hooking the dispatch
call transforms each event exactly once on freshly written values. The four
stores themselves all carry LE fixups; the `call` does not.

**1. Region objects (the hot-spot scan).** `0x36B96` is the screen hot-spot
dispatcher: it copies the cursor into `[ebp-0x10]` / `[ebp-0x0E]`, then walks the
active screen object's region list at `obj+0x52`, calling the point-in-rect test
`0x336F8(eax=region, edx=packed x|y<<16)`. Rects live in runtime-built objects
(`word [eax+6]`=x0, `+8`=y0, `+0xA`=x1, `+0xC`=y1), so they cannot be patched
statically â€” hook the cursor read instead. AztMod hooks at **0x36BBB**, the first
two fixup-free instructions after the loads (the loads themselves carry LE fixups
in their disp32 operands).

Do **not** hook `0x336F8` itself: 5 of its 7 callers are the orrery puzzle
(`orrpuz\`), which builds points with `fistp` from 3D coordinates, not the mouse.

**2. Hard-coded compares** (not covered by the hook, patch individually):
- `0x2C462`/`0x2C472` inventory-window hot spot `x>50 && y>340`; `0x2C483`/`0x2C494` turn the
  click into window-local coords. Origin sits 20 left / 5 above the map's blit.
- `0x15A6D`/`0x15A7B` one inline panel button, `x>=554 && y>=437`
- `0x13F26`/`0x13F3C`/`0x13F4D`/`0x13F63` cursor-near-view-edge zones, the stock
  view inset by 5px (x 49..589, y 54..322)
- `0x14D26`/`0x14DB8` text scrollbars, value = `528 - cursorX`. Moving the anchor
  keeps the grab point right but the gain stays 1 unit per SCREEN pixel, so a
  scaled panel loses travel proportionally.
- `0x15945`/`0x15982`/`0x15A9B` `cmp x, 320` â€” screen centre, so it survives any
  centred panel rescale untouched.

**Why:** "make the shrunken panel clickable" looks like dozens of constants, but
it is really one hook plus ~10 stragglers.

**How to apply:** the hook inverts the artwork transform
(`stock = (screen - origin) * 65536/scale >> 16`) and is deliberately limited to
the panel's new rect, because `0x36B96` also dispatches full-screen menus whose
hot spots are already correct.

See [[azrael-hud-widgets]] and [[aztmod-patch-framework]].


