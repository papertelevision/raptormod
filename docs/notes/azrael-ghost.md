---
name: azrael-ghost
description: "WELLROOM's ghost (Niamh) drawn by the card as glowing smoke: room 'ghost' block -> Tex.Ghost -> GpuRaster.DrawGhost (half-size thickness + colour, smoke layer, blur, screen-blended), wisps (Particles GHOST), her own dim light. Built 2026-10-11, offline only, not yet seen in game."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-11T04:53:57.256Z
---

Josh (2026-10-11): the floating ghost lady in WELLROOM (rig NIAMH: 19 parts, 400 triangles, textures 00-niabod / 01-niahed) should look "ethereal ... a ghost and not a bunch of polygons". He picked items 1-5 of a proposal plus a dim light: soft body, glowing edges, fade to mist below the waist, shimmer, wisps, her own light.

**How it works (GPU / true colour only; F9 processor picture and -Retro draw her solid as before):**
- Room key `"ghost"` (rooms\WELLROOM.json) names the rigs (`characters`). The watcher's `Set-GpuGhost` sets the GpuRaster fields; `Set-RoomGhosts` sets `Raster.Tex.Ghost` on the rig's textures (via `$script:AztUnitMem[rig].Tex`) and collects wisp source vertices.
  - It runs at room load AND after the character rebuild (characters are added to the room after it loads; Set-GpuAtmosphere is not re-run then).
- `DrawSet` skips Ghost textures (picture, shadow views, reflections). `GhostBounds` finds her box each frame from her triangles; `AddGhostLight` appends one placed light (no shadow slot) after `_nRoomLights` (CopyLighting's count). The GI bake never sees it.
- `DrawGhost` (after flames, before motes/particles), scissored to her screen box:
  1. half size: thickness (GL_MAX blend of -z/z, needs glBlendEquation) + nearest-surface colour, both hidden by the room's depth by a manual test;
  2. build: alpha = opacity x (0.3 + 0.7 x (1 - exp(-density x thickness/height))) x height fade x world-space fbm smoke (rising); colour = glow x her art's luminance;
  3. separable Gaussian (sigma = soft x her height, on screen);
  4. composite into _fbo: 3x3-smoothed sharp layer only where `r = soft.a / local max` is high (eight taps a glow-width out), soft glow brighter toward the outline, room behind wobbling (shimmer), SCREEN blend (never past white), alpha = max(light share, 0.9 x coverage) so the fog clears over her.
- Sizes are shares of HER HEIGHT (her live size is the engine's: the rest pose is 148 units tall incl. long ribbon "legs"; offline tests scaled her to 75).
- Wisps: `Particles` kind GHOST, additive soft puffs (seed 1+), from parts containing NSKIRT / NIHAND / NILEG, at random points between two source vertices; size/rise/spread are shares of the span of those parts.
- Watcher: `-NoGhost`; log lines "ghost: ...", "ghost: first seen -- N triangles, H units tall, at x y z" (read that for her live size), and an error line if the pass fails (she is then drawn solid).

**Tuning lessons (offline, Test-GpuLook):**
- Plain translucency/crisp rim = a glass mannequin with polygon outlines. The fix was feathering the sharp layer by "how far inside her" measured against a LOCAL max (soft/sharp ratios are non-monotonic at the outline: they made a bright line, then a dark band).
- Additive glow over the torch-lit wall blew out to white: screen blend.
- The big blotches and the dot pattern were the WISPS (first sizes 0.04-0.06 of span = puffs ~250 px over her body), not the smoke shader. Now size 0.025, alpha 0.4, rate 10.
- Her body is thin: density 20 (8 left even her middle "edge-like" and the smoke punched holes in it).
- Cost: within noise at 2560x1440 (< 0.5 ms).
- A fine dot texture over her bright parts is the room's own fog jitter (lit walls show it too).

**Her textures back (Josh, 2026-10-11: "add back her textures but leave the new effects"):** `textureColour` (GpuRaster.GhostTexColour, 0..1).
- A FULL-SIZE pass of her nearest surface's colours (`_gFullFbo`, made on first use). In the composite, inside her core: `mix(layer rgb, her colour x layer alpha x bright, textureColour)`, so the fade and smoke still apply through the alpha.
- The half-size layer takes her colours too, so the glow is tinted by her art.
- With textures, opacity 0.85 and core 1.0 (at 0.6/0.6 the textures were too faint to read).

**Offline harness:** `Test-GpuLook.ps1 -Room WELLROOM -Character NIAMH -CharAt -85,-35,8 -CharHeight 75 -CharYaw 0 -X -20 -Y 7 -Z -15 -Yaw 285 -Pitch 10 -Walk 0` (add `-NoGhost` for the solid model, `-NoParts` without wisps).

Related: [[azrael-wellroom]], [[azrael-characters-host-render]], [[azrael-gpu-effects]], [[azrael-volumetric-fog]].
