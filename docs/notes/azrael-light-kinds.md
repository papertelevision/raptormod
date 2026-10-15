---
name: azrael-light-kinds
description: "Room light options added 2026-10-14 (Room Review round 25): wall washes past the 8-light cap, glass in cut-out holes, one-sided lights, light gates (windows in a room with no ceiling), air only inside the room."
metadata:
  type: project
---

Added for Room Review round 25 (2026-10-14): CHAMBNEW's twelve uplights and BAPTIST's sunlit windows. All of these are graphics-card only; -Retro and the processor picture ignore them. Room file keys are in `rooms\<ROOM>.json`.

**Wall washes** -- `lights[]` entries with `"wash": true`.
- Steady spotlights with NO shadow, up to 16 a room, on top of the 8 placed lights (`Raster.MaxLights`: each placed light owns a shadow texture unit, so raising that cap is expensive).
- Keys: x y z, dir, cone, color, power, range, bounce.
- Code: `GpuRaster.SetWashes` and uWash* in FS_MAIN. They use 40% of the relief, because a grazing wash turned the stone to speckle.
- They feed the GI bake (traced with shadows there). A room with only washes still gets gi.
- CHAMBNEW recipe: 8 units off the wall, 5 above the floor, tilted 20 degrees into the wall, cone 24/44, range 120, power 1.6. A beam 14 out and tilted 12 degrees lit too high up the wall.

**Glass in holes** -- `holes[]` entry keys `"glass": 0.3, "glassTint": "#RRGGBB"`.
- The cut texels are drawn as a pane at that share of their own colour, unlit, alpha 0.8 for the fog. The shadow views and the bake still treat them as holes, so light passes.
- Code: `Raster.Tex.Glass` / `GlassTint`, uGlass in FS_MAIN.
- `holes[]` also takes `"boxes": [[x0,y0,x1,y1], ...]` now (`CutHoles` loops over the boxes).
- One rule per texture (keyed by name).

**One-sided light** -- `"oneSided": true`.
- Lights only the side of a face the eye is on. A sun behind a wall no longer lights the wall's inner face. Lighting is otherwise two-sided (`abs(dot)`), because some game faces have flipped normals.
- Code: the sign of uLightP.w (`SetLightOneSided`).

**Light gate** -- `"gate": [x0,y0,z0,x1,y1,z1]`.
- The light reaches a point only if the segment from the light to the point passes through the box (the window band).
- Applied on surfaces (uGateLo/Hi), in the air (uVGLo/Hi) and in the bake (`GiBake.Light.Gate` + `SegThrough`). The bake signature changes only when a gate exists, so no cache went stale.
- BAPTIST NEEDS it: the room has NO ceiling, so the sun also poured in over the walls.

**Air only in the room** -- `volume.airInRoom: true | [x0,y0,z0,x1,y1,z1]`.
- Placed lights light the fog only inside the box. `true` = the geometry's bounds, which parked parts can make far too big (BAPTIST's tapestries sit at x 386..516), so give the box.
- Without it, BAPTIST's suns lit the open sky over the walls.

**BAPTIST windows:**
- The six painted windows on the x=80 wall, at z -96, 3, 101, 198, 297, 396 and y 152..224.
- In the original art the glass is 40..160 bright and the bars 0..21, so the cut uses minLum 36.

**ATUNNEL2** has no placed lights. CORICORI's fog strength turned it black, so it runs at about a third, with artLight floor 0.3. Its gi waits for a light.

Related: [[azrael-texture-holes-nocast]], [[azrael-atmosphere]], [[azrael-volumetric-fog]], [[azrael-baked-gi]], [[azrael-room-review]].
