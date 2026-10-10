---
name: azrael-status-gauge
description: "SOLVED - the health gauge's two surfaces are an ERASE and a BAR; the erase has always held heap garbage, which is why widening it \"corrupted\" the panel. Now 130x15 and clean."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-02T18:20:33.454Z
---

## What the gauge is made of

Built back to back at `0x284A4..0x28518`, stock **105x15** each, now **134x15**:

| | |
|---|---|
| `0x163A10` | the **BAR** â€” the visible health bar; pixels at `[0x163A14]`, loaded from H1.PCX by `0x38A20` |
| `0x163A22` | the **ERASE** â€” bar + 0x12; pixels at `[0x163A26]`, filled by the memcpy at `0x28518` |

Drawn from `0x11E10`:

* `0x11E30` â†’ `0x33F80` draws the **erase** surface, which is what lets the bar SHRINK
* `0x11E5C` â†’ `0x34C40` draws the **bar** over the health portion of it, `columns` wide

Health â†’ columns is `(health >> 16) * 8 / divisor` at `0x11E13`. Divisor 1000 = 105 columns;
**783 = 134 columns**. Rescale it by `floor(1000 * 105 / newWidth)` â€” FLOOR, not round: 808
leaves the bar one pixel short at full health, which is the whole "looks like 80%" complaint.

Surface header (written by `0x37B04` from its own w/h arguments, struct stride 0x12):
`+0 w, +2 h, +4 pixels, +8/+0xA clip origin, +0xC w-1, +0xE h-1`.

## THE BUG, and it was never the resize

**The erase surface has always held heap garbage.** `0x28518` memcpy's `W*H` bytes from
`[ebp-0x10]`, which is not the panel behind the gauge. Stock never showed it because the bar
is drawn *after* the erase and exactly `columns` wide, covering it pixel for pixel. Widening
moved the allocation from 1575 to 1950+ bytes â€” a different heap block, noisier contents â€” and
every pixel the bar did not reach showed it.

**So the old "NEVER RESIZE IT" rule was a workaround for this, not a fact about resizing.**
Resizing was always fine; it just stopped the lid fitting the box.

### Found by experiment, not by reading

Static analysis went nowhere over many attempts. Two builds settled it:

* skip `0x34C40` â†’ the **bar vanished, the speckle remained** â†’ the bar is `0x163A10`
* skip `0x11E30` â†’ the **speckle vanished, the bar could no longer shrink** â†’ it is the erase

**When two draws overlap, turn each off in turn before theorising.**

### The fix

`AztGaugeFill`, 13 bytes in the stub cave â€” exactly its remaining slack â€” replacing the memcpy
and filling the surface with the well's own floor, index 1 (`#12130B`, measured across HUD3
rows 658..678):

```
60 1E 07 89 C7 89 D9 B0 01 F3 AA 61 C3
pushad / push ds / pop es / mov edi,eax / mov ecx,ebx / mov al,1 / rep stosb / popad / ret
```

`eax` = destination, `ebx` = length, `edx` = the ignored source â€” the register contract of the
memcpy it replaces. It lives in a FILE-BACKED cave, not the overlay, so there is no question
of whether the overlay is resident when the HUD initialises.

## Disabling either pass

* `0x34C40` is **callee-pops** (`ret 4` at `0x350C9`). NOPing its call strands `push 0x165`,
  the following `add esp,0xC` runs anyway, esp comes back 4 high and the game dies on first
  load. Use `add esp,4` (`83 C4 04`) + 2 NOPs.
* `0x33F80` takes all four arguments in registers, with no push before and no `add esp` after,
  and ends in a plain `ret` â€” which is why `AztOpenMovie` can tail-jump to it. Plain NOPs are
  safe.

## `$GAUGE_RESIZE_H` IS ON AGAIN AT 1600x1200 — 206x23 (2026-10-03)

The height half was left off because of a 2026-09-24 bisect: "a stray bright line appeared
in the panel a few rows ABOVE the bar and tracked the gauge resize exactly". **That was the
erase-surface garbage described above, not the height.** `AztGaugeFill` fills W*H with the
well floor, so it fixes the height for the same reason it made the width safe.

Needed because 15 rows is a 640x480 number: at 1600x1200 the well is 2.5x deeper and the
bar read as a thin line in a deep recess. The height now comes from the measured recess
(23), exactly as the width does, and `Build-Art.ps1` no longer passes `-H 15` to
Build-HudBar. H1.PCX is **206x23**; the build asserts the two agree.

## H1.PCX

105x15 stock, generated at **134x15** by `Build-HudBar.ps1` â€” a dithered rustâ†’amber ramp
(51, 46, 21, 27, 34, 50 out of HUD3's 1..53). Keep its PALETTE bytes verbatim: H1's palette
populates live indices 58..71 and the system menu's volume bars read their inks from that
slice. The build throws if `art\H1.PCX` is not exactly the gauge size.

**Preview it with HUD3's palette, not its own** â€” its own shows the ramp indices as dark olive
and makes a correct bar look broken.

## Dead ends â€” do not re-derive

* **Not the clip rect.** `0x37B04` sets `+0xC = w-1` from its arguments; widening updates it.
* **Not an art/surface size mismatch.** The build asserts it.
* **Not the panel artwork.** HUD3 is clean index 1 across the whole well, y 658..678.
* **Not a second stale H1.PCX.** Only one exists; `RESOURCE.CFG` does not cover `AZRAEL\`.
* **Not H1's transparent rows, the dither, or the bar height.** The artwork was changed three
  times chasing this â€” a 3-row inset, no dither, a well-floor pre-fill â€” and none of it helped.
  All reverted. **The user said twice that the artwork looked right; believe that.**

See [[azrael-hud-reskin]], [[azrael-palette-budget]], [[azrael-resolution-asserts]].

## Final width: 134, not the detected 130

The region detector returns the REGISTRATION rectangle (130 px at x=500), but the painted well
is wider. Measured on HUD3: the floor (index 1) runs x=500..635 or 636 on every row the bar
occupies (662..676), so **136 is the hard ceiling** and beyond it the bar paints onto the
bezel. `\ = 4` takes it to 134 (x 500..633), leaving 2 px of well showing at
the right so it still reads as a bar sitting IN the recess. `\ = 136` asserts it.

Widening is now cheap and safe: H1 is regenerated at the new width (`-W`), the buffers and
divisor follow automatically, and `AztGaugeFill` fills `W*H` so the erase scales with it.
