---
name: azrael-boot-text-rasteriser
description: "For 1bpp boot text use GDI (TextRenderer.DrawText) at INTEGER pixel sizes, never GDI+ DrawString — the difference is dramatic, not subtle."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-03T16:57:38.717Z
---

## SCALING THE WHOLE ANIMATION AT 1600x1200 (2026-10-03)

Every size in the boot sequence was a literal tuned against a **1024-wide viewport**, so
at 1600 the readout sat as a small block in the middle of a big screen. There is now one
factor, `$BOOT_S`, and two helpers: `Bs()` scales and rounds, **`Bse()` rounds to EVEN**
for anything that positions a row (line height, the banner gap) because the animation
draws alternating scan lines and odd values invert the pattern line to line.

Scaled against **1024, not 640**, deliberately: 1024 is the layout that was signed off, so
this reproduces that look at the new size. At 1024 it is exactly 1.0 and nothing moves.

### THE OVERLAY CEILING CAPS IT AT 1.40, and that is a hard wall

The readout is stored as a **1bpp bitmap inside the overlay**, so its byte cost grows as
**S squared**. The honest 1600/1024 = 1.5625 assembles to **57,612 bytes against
AztOverlayLoad's 53,248** — and that window cannot grow, it ends exactly where obj2
begins. `$BOOT_S_MAX = 1.40` lands at **51,182 bytes with only ~2 KB spare**.

**The overlay is now nearly full.** Anything new in it needs that 2 KB or needs
`$BOOT_S_MAX` walked back first. See [[azrael-overlay-read-limit]].

### The hex cell had to go 8 -> 16 px, and that is a FORMAT change

The telemetry column packs one glyph row per **byte**, i.e. an 8-pixel cell, sized for a
13px Consolas (7px advance). Scaled, the digits reached ~18px and the build reported
**"144 row(s) reach the cell edge"** — silent clipping, not cosmetics.

16 px = two bytes per glyph row, strip stride 32. **The existing 256 x 8 expansion table
is run TWICE per row** rather than building a 256 x 16 one — two tables at 4 KB each do
not fit in 2 KB of spare overlay. Draw loop, per column: digit from `[edx+k]`, left bits
`movzx eax,[ebx+eax*2]` (`0F B6 04 43`), expand, two dword stores at `cell`/`cell+4`;
then **re-read the digit** and right bits `movzx eax,[ebx+eax*2+1]` (`0F B6 44 43 01`),
two more stores at `cell+8`/`cell+12`. The digit is re-read because there is no spare
register — esi is the obj1 delta, ebp the table, edi the destination, edx the cell cursor.
`add ebx,16` becomes `add ebx,32`.

## THE REAL CAUSE OF EVERY "DARK LINE": THE HUD PALETTE MOVED UNDER THE INK INDICES

**This is the single most useful thing in this file. Three wrong diagnoses died here.**

`Build-HudSkin` regenerates HUD3.PCX for each resolution and **its palette comes out in a
different ORDER**. Every hard-coded boot ink index therefore pointed at a colour it was
never chosen for. Measured on the 1600x1200 art (the screen fill went luma 119 -> 168):

| ink | designed offset | actual offset |
|---|---|---|
| scanline | -26 | **-102** (4x too dark) |
| corruption streaks | +30 | **-49 INVERTED** |
| refresh line | +44 | **-19 INVERTED** |
| shutter lip | +63 | **-36 INVERTED** |
| telemetry column | +14 | **-78 INVERTED** |

Four elements meant to FLARE were drawing *darker than the screen*. That is what Josh
kept reporting as "dark lines that shouldn't be there", and it survived being blamed on
display scaling, on scanline band height, and on block phase — none of which were it.

**Nothing asserted, because `$BOOT_LUMA` was a hand-maintained table that had drifted with
the art.** It claimed index 20 was luma 119 when the art said 168. Indices ABOVE 55 (the
scene-palette slice: 88, 92, 96, 100, 103) matched within 1 — only the HUD slice 1..53
moved, which is exactly the slice Build-HudSkin rewrites.

### The fix: inks are DERIVED BY INTENT, never written down

`BootPick <offset>` resolves a luma offset from the fill against whatever palette the art
actually has, restricted to the warm family (`R >= G >= B`) so a pick can never land on a
grey or the teal text ramp, and **throwing if the sign cannot be honoured** — a flare that
cannot be brighter than the screen is a build failure, not a silent inversion.
`BootPickL <luma>` does the same by absolute luma for the warm-up ramp, which is now
expressed as FRACTIONS of the fill (0.126, 0.126, 0.319, 0.529, 0.597, 0.706, then the
scan ink, then the fill) rather than literal indices — those had stopped climbing too,
stage 6 landing at luma 66 after stage 5's 149.

The palette is read raw from `art\HUD3.PCX` (last 769 bytes behind an `0x0C` marker)
because this runs long before the build Add-Types PcxTool. `Lum()` now measures the same
palette, so the printed report is true; `$BOOT_LUMA` survives only as the record of what
each ink was *chosen to look like*.

**Whenever the art is regenerated, the inks re-resolve themselves.** Interlacing is back
on with a gap of 19 (was 102), which is the "slightly darker" Josh asked for.

### Earlier, and now moot: interlacing was briefly turned OFF

Three attempts to make the scanline behave at this resolution all failed, and Josh asked
for it removed. **Do not reinstate it without being asked.**

**The timing is what identified it, after two wrong diagnoses.** Josh: the lines "only
appear towards the end of the 7s and text screen loading, and fully on the
mission/objective screen". That is a *timing* signature — during the disruption the
glitch code repaints the background every frame, and only once that stops (7.2 s) does
`AztBootClear`'s scanline pass own the screen. **A display-scaling artefact would have
been constant**, which is what I had wrongly argued twice; I had even asked him to test
`integer_scaling`. Ask "when does it appear?" before blaming the display.

**One edit does it, because the stripe has a single source.** Setting
`$BOOT_SCAN_IX = $BOOT_FILL_IX` (and collapsing every `$BOOT_WARM_STAGES` entry's Scan
onto its Fill) makes `aztScanDw == aztFillDw`, which simultaneously:
* makes `AztBootClear`'s dark pass paint the fill colour,
* makes `aztBootTab2` identical to `aztBootTab`, so the text blocks stop interlacing too
  — and with it the "rectangle around the text" goes away for free,
* makes the refresh-line eraser repaint correctly whichever table it picks.

The tube still warms up; the ramp just has no stripe. The build's "scan must be darker
than fill" assertion now requires *equality* when interlacing is off, rather than being
skipped.

### The band-scaling machinery is kept but UNUSED (`$BOOT_SCAN_H`)

The CRT scanline is **not drawn as lines**. Every pixel goes through a byte -> 8-pixel
expansion table and a row is bright or dark purely by WHICH table it uses —
`aztBootTab` emits the fill colour for background bits, `aztBootTab2` the scan colour.
So "band height" = how many consecutive rows share a table, and it was hard-wired to ONE.

One row was right at 640..1024. At 1600 it is 2.5x finer than designed: it stops reading
as scanlines, it beats against the display's scaling, and **any phase difference at a
block's edge draws the block as a faint rectangle** — which is what Josh photographed and
described as "the bitmap showing its background". `$BOOT_SCAN_H` is now
`round($INJ_W / 1024)`, so 1 at 1024 and 2 at 1600.

**Four sites generate the pattern, and two of them were the hard part:**

| site | selector | change |
|---|---|---|
| `AztBootClear` | writes 1 dark row, skips 1 | write SCAN_H rows, skip SCAN_H, `INJ_H/(2*SCAN_H)` times |
| `AztBootSweepOff` | `test dl,1` on an ABSOLUTE row up-counter | `test dl, SCAN_H` — one byte |
| text blit `ABX_row` | parity of a DOWN counter | see below |
| dump column `ADM_prow` | parity of a DOWN counter | see below |

**Parity survives negation, `mod 4` does not.** The down-counter trick works for 1-row
bands only because `-i == i (mod 2)`. For 2-row bands, with the block origin AND its row
total both multiples of 4:

```
i mod 4   = 0 1 2 3     band = ((start+i) >> 1) & 1 = 0 0 1 1
c = T - i  so c mod 4   = 0 3 2 1
=> c -> band: 0->0 1->1 2->1 3->0   ==   bit0(c) XOR bit1(c)
```

So three instructions (`mov ecx,eax / shr ecx,1 / xor eax,ecx`) before the existing
`test al,1`, with no new state and no need to reconstruct the absolute row. ecx is free
at both sites — it is not loaded until after the table is chosen.

**Everything that positions a row must be a multiple of `2*SCAN_H`**, not merely even:
`BOOT_TXT_Y`, `BOOT_TXT_H`, `BOOT_TXT_ROWS`, `BOOT_BAN_GAP`, `BOOT_MIS_Y`, `BOOT_MIS_H`,
`BOOT_FINAL_H`. The build now asserts all seven — and that assertion immediately caught
`BOOT_MIS_H` (a derived sum, 126) and `BOOT_FINAL_H` (a literal 16 declared ABOVE the
scale helpers, so never scaled at all). **An unaligned block does not look broken; it
looks like a rectangle round the text.**

**Cost: `$BOOT_S_MAX` fell 1.40 -> 1.25.** Rounding the line height up to a band pair
(22 -> 24) grew the 1bpp bitmaps ~9% and took the overlay to 54,739 against the 53,248
ceiling. At 1.25 the line height is 20 and the overlay is 45,739 with 7.5 KB spare.

### `BOOT_TXT_H` WAS ALSO HARD-CODED AS `shl eax, 4` IN THREE PLACES

Scaling the line height to 22 broke the animation in three ways at once — the readout
"populated randomly rather than line by line", it paced wrongly, and dark bands appeared
across the scan lines. One cause: **three sites converted line number -> row with a
hard-coded `shl eax, 4` (x16)**, one of which even had the comment "x BOOT_TXT_H" while
multiplying by a literal. Correct only while the height was 16, and silent until it was not.

All three are now `imul eax, eax, $BOOT_TXT_H`. Verify in the emitted overlay: three
`69 C0 <h> 00 00 00`, and exactly ONE surviving `C1 E0 04` — that one is `segment * 16`
for a real-mode address and must NOT be touched.

**Lesson, and it is the same one as the stride family: a shift IS a hard-coded constant.**
Before scaling any boot dimension, grep the overlay emitters for shifts whose comment
names a variable. See [[azrael-stride-derived-offsets]].

### The null-ordering trap bit a THIRD time, and silently

`$BOOT_HEX_CELL` was first defined next to `Render-BootHex`, ~400 lines BELOW
`$BOOT_DUMP_W = $BOOT_DUMP_COLS * $BOOT_HEX_CELL`. It read `$null` -> 0, and the build
happily printed a column running **"x=32..32"** — zero width — while the clearance
assertion passed *more easily* for being zero. Caught only by reading the printed
geometry. It now lives with `$BOOT_DUMP_COLS`. **Read the geometry report, not just the
exit code.** See [[azrael-powershell-null-ordering]].

The boot overlay's text is rendered at build time and thresholded to 1 bit per pixel, so
the glyph rasteriser is the *only* thing that decides how it looks. Two rules:

**Use GDI, not GDI+.** `Graphics.DrawString` at these sizes produces broken stems and
blobby counters that survive thresholding as visible mush — it reads as "blurry" even
though nothing is antialiased. `System.Windows.Forms.TextRenderer::DrawText` uses GDI's
hinted rasteriser and gives clean, even stems. Side by side it is not a close call.

```powershell
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
[System.Windows.Forms.TextRenderer]::DrawText($g, $text, $font, $point,
    [System.Drawing.Color]::White,
    (NoPrefix -bor NoPadding -bor SingleLine))
```

The `TextRenderingHint` still matters: TextRenderer maps it onto the DC's text quality, so
it is what stops GDI antialiasing according to the machine's ClearType setting.

**Integer pixel sizes only.** A fractional size (it was 11.5 and 15.6) defeats the hinting
that makes this crisp. Consolas also *quantises* its advance width — 12px and 13px are
both 7px/char, 14/15 are 8, 16/17 are 9 — so the larger of each pair is a free size
increase. Measure with `TextRenderer::MeasureText`; `MeasureString` disagrees with what
`DrawText` actually produces.

Current sizes: **13px** readout/banner/closing line/mission header, **16px** objective.
The longest readout line measures 434 of the 448-wide block, so 14px would clip.

Related: [[azrael-font-format]] (the in-game font, a different thing entirely),
[[azrael-hud-reskin]].
