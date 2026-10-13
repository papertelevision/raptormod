---
name: azrael-parallax-depth
description: "Phase 4a of Josh's texture plan (2026-10-12): parallax occlusion mapping in the card's room shader from per-texture height maps (GpuRaster.MakeHeight/HeightOf: companion _height, else the art's GROOVES by morphological closing -- brightness-as-height failed). Rides on F7 with the relief; -NoParallax / -ParallaxDepth / room 'parallax'. ~0.6 ms at 4.8 Mpx, ~5 ms a texture to build."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-12T23:00:00.000Z
---

Phase 4a of [[azrael-materials]] (Josh's item 5: "Mortar lines, planks and stone blocks appear sunken as you move past, using the height we already compute. Flat walls and floors gain real depth."). **BUILT 2026-10-12, checked offline, NOT yet seen in game.** Phase 4b (depth in the painted doorway views) waits for Josh's `<name>_depth.png` maps.

## How
- **Height maps** (`GpuRaster.MakeHeight`, unit 18 `UNIT_HEIGHT`, R8 with mipmaps; `DepthUnitOk` = MAX_TEXTURE_IMAGE_UNITS > 18): 255 = the face, 0 = ParallaxDepth below it. Made when a texture goes to the card (and again if its companion maps change); deleted with it (6 GL ids per GTex now).
  - From a companion `_height` map (MatPx G, Josh's own depth) when there is one, at most 1024 across.
  - Else from the art's **grooves** (`HeightOf`): the Rgb level <= 512 across, luminance, **closed** (dilate then erode, square radius max(2, size/128)) minus itself = narrow dark lines only (mortar, plank gaps, cracks, joints); 3x3 box; depth 1 at the 98th percentile. Stone faces stay at the top.
- **Shader** (FS_MAIN, before the hole mask and every texture read, so holes/colour/relief/companions move together): the face's st-per-world-unit gradients from the screen derivatives (cotangent frame: q2p = cross(dFdy(vView), N), q1p = cross(N, dFdx(vView)), grad = (q2p*gx + q1p*gy)/dot(dFdx, q2p)); view ray's tangential part / max(N.V, 0.3) x depth = the st offset at full depth; up to uPom.z steps (fewer when looking straight on), stop where the layer passes the surface, then linear between the last two steps. Surface pixels (height 1) take ONE fetch: only grooves march.
- **Depth fades:** to nothing by ParallaxFar (260 units, from half way), and at glancing views (`smoothstep(0.12, 0.4, N.V)` -- the offsets run away into a smear there).
- **Not on:** shiny surfaces (material relief 0 -> uRelief*uReliefK), what moves (Tex.Moves), faces mixed against repeats (vFix & 12), reflections, water (relief 0). With F7 off (ReliefOn false) it is off.

## Round 2 -- WALLS AND FLOORS ONLY (Josh in game, 2026-10-12)
Josh: "cool in some cases and others not. I like it on some of the doors and in some of the caves, but most of the time its not really matching up correctly, and for some cases, like the bridge in the spa room, it just looks weirdly bumpy and unnatural ... limit this to walls and floors, but not the wooden plank style floors like in the spa room." Now a texture takes it only if ALL of:
- **its material's `parallax` share** (rooms\_materials.json): stone, floor, rock 1; everything else 0 -- wood (the spa bridge 14-spabri_key, the doors), metal, cloth, paper, polished, ceiling... (`Raster.Tex.Parallax`, set by Set-RoomMaterials);
- **it is a wall or floor of the room** (`GpuRaster.SetParallaxShell`, per room from Set-GpuAtmosphere): >= 5000 square units of the room in triangles averaging >= 100 (`ParallaxShellArea/Mean`). Props drop out: WELLROOM wel_bdy1/2 (232 / 3232), BAPTIST bapmsg (1805), the mirror bapwhite (858), bappillr (1044);
- **its art is not planks** (`ParallaxGrainMax` 0.58 on the gradients' coherence, computed with the height map): planks 0.52-0.65 (spabri 0.52, spadoor 0.63, MINEHEAD 05-mineramp 0.65), cobbles/rock 0.02-0.22, carved stone walls up to 0.53 (spawal05) -- a safety net for planks whose names say stone.
- **By hand** (wins over all three): rooms\_materials.json `"parallax": { "on": [...], "off": [...] }` (name or file name), or a room's `"materials": { "13-spadoor": { "parallax": 1 } }`. For the doors Josh liked: put them in "on". **Done for the CORICORI doors (Josh, 2026-10-12):** rooms\CORICORI.json "materials": { "20-spadoor": { "parallax": 1 } } (room only: the spa doors stay flat).
- Height maps are built only for textures that take it (CORICORI 16, SPAROOM 5 now; ~45-100 ms a room). Test-GpuLook's "parallax depth:" line lists who takes it and who was kept flat (planks / not wall or floor).

## Settings
- `GpuRaster.ParallaxOn / ParallaxDepth (1 unit) / ParallaxFar (260) / ParallaxSteps (24)`.
- Watcher: `-NoParallax`, `-ParallaxDepth 1.0`; **F7** now says "RELIEF + DEPTH: ON/OFF" and switches both. Room file `"parallax": 2` = twice as deep there, `"parallax": null` = none.
- Test-GpuLook: `-NoParallax -ParallaxDepth`; prints "parallax depth: N height maps, MB, made in ms".

## Measured (offline, 2026-10-12)
- **First try, brightness as height** (Rgb <= 512 minus a copy 16x coarser, 2-98% stretched), depth 2: cobbles went shaggy with visible layer stepping, carved pillars shredded, a far wall smeared at a glance. Painted shading and painted carving are NOT height. -> grooves by closing, depth 1, glancing fade.
- Look: CORICORI cobbles read as raised stones with sunken joints; WASHCORI block joints become gaps; BAPTIST step carving and MINEMAZE rock crevices a little deeper. Subtle on purpose; Josh judges.
- Cost: card +0.6 ms at 2880x1670 on a floor-filling close-up (12.9 vs 12.3 ms median of 3 alternating). Build: ~30 ms a texture with a modulo per tap -> **~5 ms** with wrap tables + Parallel.For (CORICORI 24 maps 128 ms, MINEHEAD 48 maps 245 ms, under the loading cover; then cached on the card). 0.3 MB a 512 map.

## Phase 4b -- painted doorway views: BUILT AND REMOVED (2026-10-13)
Wired (_depth.png companion maps in MatPx's alpha, a per-view POM with a big depth clamped to the picture, an automatic radial guess), then switched on everywhere with the guess for Josh to see. Josh in game: **"That feature isnt working and not worth it. Please remove entirely."** All of it is gone (loader, fitter, renderer, switches, room keys, guide). Do not re-propose depth for the painted views.
