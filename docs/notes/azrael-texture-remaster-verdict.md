---
name: azrael-texture-remaster-verdict
description: "SETTLED 2026-09-27 - texture remastering at 512 is not worth it in this engine. Both AI art and upscaled originals were built, tested in game and reverted."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-03T05:30:56.866Z
---

**Josh's verdict, 2026-09-27: "this texture update is no longer worth it, it actually looks
worse" and, on upscaled originals, "yeah its not worth it."** Everything was reverted and
verified byte-identical to the `.orig` backups. **Do not propose in-engine texture
remastering again** unless he raises it.

Two separate approaches were built end to end, imported, and judged **in the running game**
— this is a tested conclusion, not an estimate.

## What was tried

**1. AI-generated replacement art at 512.** Full pipeline, all of it working: measured
per-texture hex palettes, a generated brief, contact-sheet slicing, relighting from the
original's luminance, fractional softening. The nine floor slabs of room 1 went in. Verdict:
looks *worse* than 1996.

**2. The game's own art upscaled 256 -> 512.** Bicubic plus unsharp, re-quantised into each
texture's existing palette. Tried at sharpen 0.8 and 1.6. Verdict: not worth it.

## Why it cannot work, which is the part worth keeping

* **Upscaling adds no detail.** All it buys is smaller texels — the rasteriser point-samples
  with no filtering, so 512 halves the on-screen block size. That is the entire effect.
* **The art regions are tiny.** Most textures are sampled over a UV SUB-rectangle, so the
  visible area is ~90-190 texels wide even at 512. The corridor wall strips get ~96.
* **256 colours per texture, and the originals only use about six.** Six colours describe
  76-100% of each lit surface. Anything more detailed dithers into noise.
* **The engine does no lighting at all.** All the mood is hand-painted into the textures,
  so new art must be relit from the original's luminance or the room goes flat — and that
  constrains how different the new art can be in the first place.

## Measured facts, so they are not re-derived

* **Scale2x is useless on this art.** It alters **5.9%** of CORICORI's source pixels and
  **3.2%** of LURKA's; the rest is plain pixel doubling — an identical picture at 4x the
  memory. It needs neighbouring pixels to be EQUAL and digitised photographic texture never
  obliges. Kept in `Uprez.cs` only for future clean pixel art.
* **Cache cost of 512 across one room + one character: +4.09 MB** decoded (CORICORI +3.33,
  LURKA +0.76). That comes out of the texture cache — see [[azrael-texture-cache-reserve]],
  which is why `memsize` can never help.
* **Shadow-match calibration:** output luminance correlates with the original's at ~0.87 for
  a *good* result, never near 1.0, because the new detail is itself what decorrelates it.
  A first attempt used 0.90 as a pass mark and failed nine perfectly good tiles.

## The tooling still exists and works

`Prepare-Textures.ps1` (relight, blend, soften, flatten), `Split-ContactSheet.ps1`,
`Measure-TexturePalette.ps1`, `Build-TexturePrompt.ps1`, `Build-PaletteSheet.ps1`,
`Upscale-Originals.ps1` (has `-Revert`). All import from `.RES.orig` so nothing compounds
and no change is destructive. Reusable if textures are ever needed for the **Unity** layer,
where the 8-bit ceiling and the tiny UV windows do not apply — that is the context in which
this work pays off, not this engine.

## IT CRASHED THE GAME. Reverted 2026-10-03. Verdict now settled TWICE.

The budgeted upscale below was built, installed and played — and it **crashed in a mine
room**, by 13,312 bytes, asking for one 512x512 texture. The per-room ceiling it was
built on was simply the wrong model: **the texture cache accumulates across rooms and
hard-fails rather than evicting** — see [[azrael-texture-cache-reserve]] for the captured
report. All 179 .RES reverted from their .orig; the live set is stock again (48/512/1994/355).

So the in-engine answer is now settled on two independent grounds: it *looked* not worth
it in September, and at 1600x1200 it is *arithmetically impossible* — every 512x512 record
costs 262,144 bytes of a 4.46 MB arena that spans a whole region plus 1 MB of character.

**Do not rebuild this without first moving the renderer off the emulated CPU**, where
there is no 4.46 MB arena and no 8-bit palette at all.

## The attempt, kept for its measurements — budget-aware upscale (2026-10-02)

He asked for it himself ("can we try upsampling them again"), so the "do not propose"
rule above was satisfied. **Outcome still unjudged — he has not played it yet.**

**His premise needed correcting: the textures were NOT at 512.** The September work was
fully reverted. Measured census of the shipped art — 2,909 records in 179 `.RES`:
**68.5% max-edge 256, 17.6% at 128, 1.7% at 64, 12.2% already 512.** So the move is
256->512, the same one rejected in September; 512->1024 is what the tooling refuses.

**Why the higher resolution did not sharpen surfaces — it blurred them.** Screen pixels
per texel, which is all that matters on a point-sampling rasteriser:

| build | px per texel |
|---|---|
| 1024x768, 256 tex (old) | 4.00 |
| 1600x1200, 256 tex | **6.25** |
| 1600x1200, 512 tex | 3.13 |
| 1280x960, 512 tex | 2.50 |

The HUD, text, geometry edges and boot animation genuinely sharpened because they are
*generated* at the new scale. The textures are the same bitmaps over 2.44x the pixels.
Sharper edges + blockier fills nets to "looks about the same", which is exactly what he
reported. **Resolution and texture detail pull in opposite directions here.**

### The cache HALVED, which is what makes this different from September

The split is `(largest block - reserve)` and both ends are fixed — `memsize` cannot
raise the block (64 MB exits after ~17 s). Going to 1600x1200 took the reserve to 24 MB:

    block 29,891,584 - 25,165,824 = cache 4,725,760 = 4.51 MB   (was 8.51 MB at 1024x768)

Stock art is comfortable: heaviest room decodes to 2.84 MB, **0 of 179 over**. A blanket
256->512 puts **47 of 179 over** (worst R22G at 9.81 MB) and would need the reserve down
to 18.7 MB — *less* than 1024x768 used while the surfaces are 2.44x bigger. **A blanket
upscale is arithmetically impossible at this resolution.**

A `(room + resident characters)` model is the right one, and the game proves it: 179
rooms total 177 MB decoded against a 4.51 MB cache, so it must already flush per room.

### `tools\Upscale-Budgeted.ps1` — the new approach

Per-`.RES` ceiling, greedy fill in priority order, never overshoots (it throws if it
does). Reads from `.orig` like its predecessor so re-runs cannot compound.

Margin is sized from measurement, not taste: **LURKA upscaled is 1.02 MB** (TOBIAS 0.91,
EUGBLD 0.80, LEO 0.63), so 1.1 MB is held back and the room ceiling is 3.41 MB —
3.41 + 1.02 = 4.43 < 4.51. Result: **103 rooms fully upscaled, 67 capped, 9 empty;
1,408 of 2,550 candidate records done; 512-class went 12.2% -> 52.1%**; every room
within ceiling, all 179 still decode, all 179 have `.orig`. AZTEX grew to 374 MB.

Two caveats recorded honestly: **two upscaled characters in a heavy room would exceed
the cache** (consequence is texture re-decoding and a frame-rate dip, not a crash —
`MarginMB` is the one dial), and **the priority metric is a proxy** — record area x how
many `.XAF` materials reference the texture, because every 256x256 record has identical
area and plain area cannot discriminate. Real per-face world area is in the `.XAF` if
the ordering ever looks wrong.

**No rebuild or reinstall is needed for a texture change**: `azrael-game.conf` does
`mount c .\GAME` and RESOURCE.CFG points at `C:\AZTEX\`, so editing
`GAME\AZTEX\*.RES` in place is live immediately.

Related: [[azrael-project-direction]], [[azrael-texture-format]], [[azrael-palette-budget]],
[[azrael-texture-cache-reserve]], [[azrael-hud-reskin]], [[azrael-1600x1200]]
