---
name: azrael-texture-filter
description: "Texture filtering in the host renderer (2026-10-05): dithered 4-texel choice close up + palette mipmaps far away, per-pixel mip from triangle texel density and depth. Built, offline-rendered; not yet seen in game. F7 toggles."
metadata:
  type: project
---

Josh (2026-10-05), after signing off the lamp: "run some tests on increasing texture
resolution/quality", starting with the texture-filtering idea.

**Built in Raster.cs (`Raster.Filter`, off => old path, Test-RasterFast still identical):**
- MAGNIFICATION: dithered bilinear -- each pixel reads ONE texel at `u*W - 0.5 + bayer`, so the
  four neighbours are chosen with the right odds by a fixed 4x4 screen pattern (two decorrelated
  patterns for x and y). No extra reads, wraps at the texture edge.
- MINIFICATION: `Tex.Mips` (BuildMips: 2x2 RGB average back to the palette through a 32^3
  `BuildRgbLut`, never index 0; a block that is half holes stays a hole). 49 textures in 9 ms.
- Mip per PIXEL: `lod = triLod + log2(w)`, triLod = 0.5*log2(texelArea/worldArea) - log2(focalPx)
  - 0.5*log2(facing) + MipBias(-0.35); log2 by a depth table; dithered between levels.
- Cost +0.5 ms at 1600x928. Offline (MINEHEAD) the big close-up blocks blend away; floors read
  softer.

Watcher: on by default; `-NoTexFilter`, `-FilterKey` 0x76 (F7) toggles live for A/B, `-MipBias`.
Mips are built in Get-Room via `$script:rgbLut` (built at session start).

Key check: the game's handler 0x12B88 has compares that could be T (0x14) and G (0x22/0x47), so
those were avoided for host keys; F (lamp) is clean. F7 is unverified against the game.

Still open from the "texture quality" list: high-resolution replacement textures on the host
(the old texture-cache blocker does not apply to the host renderer).

Related: [[azrael-helmet-lamp]], [[azrael-texture-remaster-verdict]], [[azrael-tier-a-host-render]].

## Texture-resolution experiment (2026-10-05 12:30) -- built, offline-rendered, not yet seen

Josh asked to raise texture resolution "to see where it puts us" (he believed they were 512).
MEASURED source sizes in the render cache (2,426 PNGs): 256x256 x1304, 128x128 x369, 128x256
x205, 256x128 x181, 512x512 x125 ... -- mostly 256, not 512.
`Tex.Upscaled(factor, pal, lut6, sharpen)`: Catmull-Rom bicubic in RGB with wrap, 4-neighbour
unsharp, back to the palette through a 6-bit-per-channel LUT (`BuildRgbLut6`, 20 ms; the 5-bit
mip LUT bands), holes carried by nearest texel; cached on the Tex (`Hi`). `UpscaleAll`.
MINEHEAD, 49 textures: x2 = 192 ms + 8 MB, x4 = 472 ms + 34 MB; draw time unchanged.
Watcher: `-TexScale 1|2|4` (default 2), `-TexSharpen` 0.6, `-HiTexKey` 0x77 (F8) switches
enlarged/original live (`$room.TexesHi`); the lamp shadow passes always use the originals.
Offline at x4 the close-up blend has tighter edges than filtering alone; it adds NO detail --
same conclusion as [[azrael-texture-remaster-verdict]], just without the engine's cache limit.
The real route to more detail is new art or procedural detail texturing (not built).

2026-10-05 12:50: Josh: "really push it with 8X textures. Let's not worry about a toggle for now." `-TexScale` default is now 8 (256 -> 2048), `-HiTexKey` default 0 (no F8). Measured: MINEHEAD 49 textures 1.1 s + 0.4 s mips, 179 MB; CORICORI 22 textures 1.1 s, 121 MB; draw time unchanged (3.5 ms). Enlarged copies are cached on each Tex for the life of the watcher, so a long session grows by ~3.6 MB per 256 texture met (box has 48 GB). Not yet seen in game.
