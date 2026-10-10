---
name: azrael-hud-overlay-res
description: HUDTOP.RES/HUDBOT.RES are run-length overlays hard-coded to a 552-pixel scanline; they corrupt the heap once the viewport is widened. THE TWO TRAILERS ARE DIFFERENT LENGTHS -- 4 bytes for TOP, 8 for BOT.
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-19T16:05:41.233Z
---

`HUDTOP.RES` (2522 bytes) and `HUDBOT.RES` (4781 bytes) are run-length overlays
the game composites **directly into the 3D framebuffer**, so the instrument-panel
artwork bleeds over the edges of the view. This is the real "partial graphic the
dev overlapped on the viewport" â€” not the automap/scan widgets.

## HUDTOP IS A VISOR, and its curve is recoverable (2026-09-23)

Decode the stock file and the shape falls out exactly. Per-row spans inward from
each edge, on the 552x282 view it was authored for:

| row | left / right | row | left / right |
|---|---|---|---|
| 0 | **full width** | 8 | 56 / 51 |
| 1 | 137 / 134 | 12 | 29 / 25 |
| 2 | 121 / 117 | 16 | 12 / 8 |
| 4 | 94 / 90 | 21 | 1 / 0 |

**22 rows deep, a quarter of the width per side.** Nothing like a corner radius --
AztMod approximated it with r=26 for a long time and it read as a clipped corner
rather than a faceplate. `src\Build-HudTop.ps1` now READS THE STOCK FILE and
resamples that profile to the current view, so the curve is the artists' own at
any resolution. Bottom corners stay an ordinary radius; they meet the panel.

The bevel (pearl 45 -> brass 40 -> dark 10 -> black 54, 2x2 ordered dither) is
depth-measured PER COLUMN from the curve's inner edge. Eroding from every
boundary instead collapses the band wherever the sweep is only a pixel or two
deep, which looks like speckle.

## Verify POSITIONS, not pixel counts

The generator's old round trip checked how many bytes decoded and whether they
were in bounds. **Both hold for a stream that puts every pixel in the wrong
place**, so it could never have caught a positional drift. It now compares the
decoded offset set and ink value against the mask, element by element.

## The trap that cost the most here: PowerShell is CASE-INSENSITIVE

A decoder written with `$w` for the word counter and `$W` for the view width uses
ONE variable. Every row came out "151 px", then "87 px" -- those were the word
counts. That false evidence caused a working generator to be reverted. The same
collision inside the generator had `$r` (a per-row span) silently zero `$R` (the
corner radius), which is why the bottom corners vanished with `bottom r=0`.

**Never use a single-letter loop counter in these scripts.** See
[[azrael-re-tooling]].

Format: `word run; run bytes of pixels; word skip;` repeated. The skips are
authored for a **552-pixel scanline** â€” the first records read 1+551, 2+550,
3+549, 4+548 â€¦ = 552 exactly.

Loaded by `0x109B8` (`LoadHUDTransData`), which stores:
`0x1523CC`/`0x1523C4` = top data/count, `0x1523D0`/`0x1523C8` = bottom data/count,
`0x1523BC` = the bottom overlay's byte offset into the framebuffer (also computed
for 552x282). Applied by `0x1E65C(eax=data, edx=dest pixels, ebx=count)`, a cdecl
thunk onto `0x1E789`, from **32 call sites** (16 places, top+bottom at each).

At 640 wide every skip advances the wrong amount: the overlay smears as a
full-width band across the view AND walks off the end of the framebuffer. That
heap corruption is what produced the `Illegal write to <pool end>` floods, and it
happens from the first frame â€” not only at the scripted story point where it was
first noticed.

**Why:** the 32 NOPs named `no-hudres-*` in AztMod exist for this. With them the
startup log is completely clean.

**How to apply:** disable by NOPing the 32 `call 0x1E65C` sites. Do NOT try
zeroing the record counts at `0x1523C4`/`0x1523C8` instead â€” `0x1E789` treats the
count as a do-while, so zero means "loop forever" and the game dies with
`INT:Gate Selector points to illegal descriptor`.

See [[azrael-hud-widgets]] and [[azrael-dosbox-runtime]].

## RESTORED in v0.14 -- the format, fully decoded

**Layout:** `<data> <dword wordCount> [<dword destOffset>]`. HUDTOP has a 4-byte
trailer (count only, implicit offset 0); HUDBOT has 8 (count + offset). Loader at
**0x109B8** reads `size-4` / `size-8` bytes of data, then the trailer into
`0x1523C4` (top count), `0x1523C8` (bot count) and `0x1523BC` (bot offset).

**Data:** `word run; run bytes; word skip`, repeated. Applier **0x1E789**
(thunk `0x1E65C`, eax=data edx=dest ebx=count) copies `run` bytes then does
`edi += skip`, so **run+skip per row must equal the framebuffer stride**.

**`ebx` counts WORDS, not records** -- `dec ebx` after the run word and again
after the skip word. A 50-record file is 100. Stock: HUDTOP 41 words / 21 rows,
HUDBOT 100 words / 26 rows, offset **141312 = 256 * 552**.

**Count and offset live in the FILE**, so re-authoring needs no code patch at
all -- just replacement .RES files and dropping the 32 `no-hudres` NOPs.

## What actually produced the "overlap" character

Stock geometry **overlaps**: view y 49..331, panel starts y 318 -- they share 14
rows, and HUDBOT draws the panel's curved edge over the 3D there. Our layout does
**not** overlap (view ends 390, panel starts 391), so simply translating HUDBOT
reproduces nothing: the part above the stock panel top is a narrow tip (row
profile 1,1,2,3,4,5,6,7,8,10 px) and re-authored to 60 pixels -- invisible.

The fix is to **bottom-align** HUDBOT into the view instead of placing it by
absolute position: 1335 px across 15 rows at view row 327, scaled 0.55 and mapped
through the panel's x transform. Viewport geometry is untouched.

HUDTOP keeps its stock vertical position (the compass strip was never scaled) and
is only stretched 552 -> 640.

**Map INVERSELY** -- for each destination pixel ask which source pixel it came
from. Mapping forwards leaves 1px holes, and filling those afterwards blew HUDTOP
up 5x, because each row is TWO separate arcs and "fill between leftmost and
rightmost" filled the transparent gap between them.

`Build-HudOverlay.ps1` does all this. It also asserts the bound: last byte written
is **218071 of 218880**, which is the thing that previously walked off the end of
the framebuffer and corrupted the heap.

## Re-enabled at 800x600 (2026-09-20)

`$ENABLE_HUD_OVERLAY = $true`. HUDBOT.RES is regenerated per resolution; only the
16 HUDTOP sites stay NOPed.

`Build-HudOverlay.ps1` now scales with the art instead of mapping 1:1:
* source rows are `$InvSrcTop`(318)..`$InvSrcY - 1`(339) -- everything above where
  Build-HudArt starts its panel-band copy, i.e. exactly what gets cut off;
* `x = round(($InvSrcX + $InvDx) * HS)`, width `round($invW * HS)` -- the SAME
  expressions Build-HudArt uses, so they cannot drift apart;
* source row `$InvSrcY` lands on `$PanelTop`, and the rows above run upward from
  it at the same scale. At HS=1 this reduces to the old `y + $InvDy`, and the
  script asserts that.
* **It iterates over DESTINATION pixels.** Scaling up maps several dest pixels to
  one source pixel, so a source-driven loop leaves holes through the lens.

At 800x600: rows 318..339 -> screen y 461..488, x 112..323, 3046 px, 3220 bytes,
last byte 351523 of 352000.

### Two wiring traps, both silent

1. **`Apply-AztMod` called the generator with NO geometry**, so it silently built
   a 640x480 overlay. HUDBOT.RES is addressed by framebuffer OFFSET and is valid
   for exactly one viewport -- hence `viewY/viewW/viewH/panelTop` are now published
   in the manifest's `art` block and splatted in.
2. **A prebuilt `AztMod\art\` skips art generation entirely** (`if (-not (Test-Path
   $artDir) ...)` at Apply-AztMod line 249). On this dev box that folder exists, so
   enabling the overlay changed nothing and the installer just said *"restored
   stock HUDBOT.RES (this build does not replace it)"*. **After changing any
   generator, regenerate into `AztMod\art\` or the change never ships.** Feed the
   generator the pristine Steam `GAME\AZRAEL`, never the installed copy.

### The vertical scale is the PANEL's, not the screen's

The housing blit in Build-HudArt maps src(170 x 162) -> dst(212 x 111), i.e. **x by
`$HS` (1.25) but y by `newPanelH/162` (0.685)** -- the housing keeps screen scale
horizontally but is SQUASHED vertically to fit the rescaled panel band. The two
axes genuinely do not share a scale.

Using `$HS` for Y stretched the lens top by 1.27 while the lens body below it was
squashed by 0.685 -- a 1.9x mismatch, seen as a hard seam with a far-too-tall dome
above it. The overlay is a CONTINUATION of the panel artwork, so:

    $vScale = ($ScreenH - $PanelTop) / (480 - $PanelSrcTop)

Sanity check that this is the authentic amount: at 640x480 / scale 0.55 it gives
`round(22 * 89/162)` = **12 rows**, which is exactly the stock overlap (viewport
ended at 330, panel began at 318).

### Do NOT chase the graininess -- it is Mindscape's

The lens top looks dithered and has a horizontal tone boundary partway down.
**Rendering the STOCK HUD3.PCX lens at 1:1 shows the identical grain and the
identical tone boundary**, so it is in the original 8-bit artwork, not in our
resampling. Verified by direct comparison before changing anything else.

The overlay still takes its colour from a `BlitScaledSmooth` canvas rather than
nearest-neighbour, so it uses the same resampler as the art below it (the mask is
still decided in source space). That is correctness, not a cure for the grain.

## The trailer length trap -- this cost a crash on 2026-09-20

`Build-HudTop.ps1` was written by copying `Build-HudOverlay.ps1`'s encoder, which
emits HUDBOT's **8**-byte trailer. HUDTOP takes **4**. The loader really is two
different code paths, 60 bytes apart:

    ; HUDTOP  (0x109BB)                   ; HUDBOT  (0x10A52)
    lea ebx, [eax-0x4]                    lea ebx, [eax-0x8]
    read ebx -> [0x1523CC]                read ebx -> [0x1523D0]
    read 4   -> [0x1523C4]  count         read 4   -> [0x1523C8]  count
                                          read 4   -> [0x1523BC]  dest offset

With the wrong trailer the game reads the word-count dword as stream data and
takes the **destOffset dword (0)** as the count -- and `0x1E789` is a do-while, so
0 decrements to 0xFFFFFFFF and sprays memory. Symptom: **boots, plays the intro
movies, then dies at the first HUD composite.** Same signature as zeroing the
counts, because it IS zeroing the count.

Corollary: because HUDTOP has no dest field, its mask **must be authored from
offset 0**. `Build-HudTop.ps1` asserts that, and now also decodes its own output
back the way `0x1E789` will and refuses to write a file with any out-of-bounds
pixel.

Stock HUDTOP read correctly: `wordCount=41`, 2431 px, 0 out-of-bounds, rows
taper 552, 271, 238, 208, 184, 162, 142, 123, 107, 91, 78, 66, 54, 44 -- two top
corner wedges. (Read with the 8-byte trailer it gives a nonsense count of
268777210, which is what made stock HUDTOP look unparseable.)

### Offline preview beats guessing

Composite `art\HUDBOT.RES` onto `art\HUD3.PCX` and save a PNG -- decode is
`run word / run bytes / skip word`, screen y = `offset / ViewW + ViewY`. Two
PowerShell traps cost a round each:
* **`$W` and `$w` are the SAME variable** (case-insensitive), so a word counter
  clobbered the image width and silently decoded 0 pixels.
* **`[int]` ROUNDS, it does not truncate**: `[int](339/2)` is 170, so a 2x zoom
  loop indexed one row past the end. Use `[int][Math]::Floor()`.
