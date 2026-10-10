---
name: azrael-palette-budget
description: The live 256-colour palette is assembled from THREE files at HUD init; only indices 1..53 belong to the HUD. Do not re-derive this.
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-21T18:56:53.871Z
---

`HUD3.PCX` carries the palette for the whole game — the code never mentions
`PALETTE.PCX` at all, which is only an artist's reference copy. But the live DAC
is **assembled from three files** by `0x28363`:

```
0x2840C  hud3.pcx palette -> [ebp-0x950]   the base, all 256 entries
0x2841C  pal.pcx  palette -> [ebp-0x650]
0x2842C  h1.pcx   palette -> [ebp-0x350]
0x2843D  edx = 58..71     base[edx] = h1[edx]         14 entries
0x28524  esi = 128..255   base[esi] = pal[esi-128]   128 entries
0x285AB  upload base to the DAC (0x353A0 writes all 256)
```

`0x28110` stores each entry twice: a 3-byte master at **0x163310** (what gets
re-uploaded on fades) and a **4-byte RGBA table at 0x163610** — the Reality Lab
rasteriser's own lookup. HUD, 2D and 3D all share these 256 colours.

## The budget

| range | source | ours? |
|---|---|---|
| 0 | transparency key / black | no — keep black |
| **1..53** | `hud3.pcx` | **YES — 53 colours, the whole HUD budget** |
| 54 | `hud3.pcx` | **MUST stay #000000**: the backdrop fill for 100% of HUD3 rows 0..488, and Build-Font's hardcoded glyph shadow |
| 55, 56 | `hud3.pcx` | cyan / gold font inks — reserved so the story log keeps two colours |
| 57 | `hud3.pcx` | spare, nothing uses it |
| 58..71 | `h1.pcx` | no — the status gauge ramp |
| 72..127 | `hud3.pcx` | **no — Reality Lab shading ramps** |
| 128..255 | `pal.pcx` | no — character / flesh tones |

**Why:** a reskin has 53 colours, barely more than the stock panel's 55. Narrow
brass/gunmetal gamuts quantize well, so this is workable — but do not plan for
more.

**How to apply:** two probes settled 72..127 and 128..255 in game, and the method
matters as much as the answer:

* A probe that repaints **128..255** proves NOTHING — the loader overwrites them
  from pal.pcx milliseconds later, so "everything looked normal" is what a void
  test looks like. This wasted a round.
* A valid probe repaints **72..127** (nothing overwrites those) and colour-codes
  each ramp separately. Result: the world went **red**, i.e. the greyscale ramp
  72..86 is in use by the renderer. Build a positive control in — the fonts
  borrow 76/78/80 and 104/114/119, so the story text visibly changes colour when
  the probe is live.

See [[azrael-hud-overlay-res]] and [[azrael-font-format]].
