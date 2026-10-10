---
name: azrael-water-reflections
description: "Mirror reflections in water in the host renderer (2026-10-05): planar reflection through the portal mask, auto-detected by WATER/LIQUID materials on flat parts. Built + offline-rendered in SPAROOM; not yet seen in game."
metadata:
  type: project
---

Josh (2026-10-05): texture upscaling "isn't helping much, leave them as-is" (`-TexScale` default
back to 1; the code stays). Asked whether mirror-like water is possible, naming the steam room.

**Built.** SPAROOM's water is the part `zxspadeath` (the DEATH TRIGGER quad, textured
`WATERDEATH`/slwate1, y -87, 628x629) -- a zx object that IS drawn.
- Detection in the watcher's Get-Room: OBJ `usemtl` matching `WATER|LIQUID` on a part that is flat
  (y-range <= 2) -> `$rm.Water`; pieces within 60 units of height share a pass (`$rm.WaterGroups`:
  the dock's six sea quads are one level). Found also in BAPTIST, SLU01, POIS_GR, WALF01, DECK01,
  LAB; not in KITCHEN/WWCA/DRAIN1/ZIGGY2 (their water is not flat or not so named).
- Render (after the room and any portals): `BeginPortals` -> `AddPortal(dv, tris, 250, drawn:true)`
  (the water is already in the depth buffer, so the test is >= not >) -> `EndPortals(keepColour)` ->
  `Raster.Mirror(dv, mirV, y)` + `SwapWinding(T)` -> `DrawTexturedMasked` with `MaskBeyond` (only
  what is beyond the surface: kills the flipped pool floor and the water quad itself), `MaskKeep`
  0.30 (that share of pixels stay water texture, by dither), `MaskDim` 0.72. Lamp shadows are not
  looked up for reflected pixels.
- Cost 1.4-1.9 ms with water over 10-35% of the frame. Posed geometry is mirrored, so creatures
  and doors reflect.
Switches: `-NoReflections`, `-WaterKeep`, `-WaterDim`. Offline: the wall beside the walkway shows
dimly in the pool with the water's speckle over it. No ripple/distortion yet (obvious next step).

Related: [[azrael-doorway-portals]] (same mask machinery), [[azrael-helmet-lamp]], [[azrael-texture-filter]].