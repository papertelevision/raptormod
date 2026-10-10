---
name: azrael-modern-water
description: "GPU 'modern water' (2026-10-08, SPAROOM, Room Review round 4): rippled Fresnel reflection, glints, glow from lamps under the water, caustics on the walls; per-room 'water' block. Built + offline-rendered, not yet seen in game."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-08T18:38:37.952Z
---

Josh's notes SPAROOM/1 ("light sources beneath this water ... water-like light projections on the walls") and SPAROOM/2 ("modern water ... keep the turquoise dots ... shiny") -> built in GpuRaster.cs, GPU mode only.

**Switch:** a "water" block in `rooms\<ROOM>.json` sets `gpu.WaterFx` (Set-GpuAtmosphere). Without it the old flat mirror (WaterKeep/WaterDim) is unchanged. `-NoWaterFx` turns it off. Only SPAROOM has the block so far; other reflective-water rooms (BAPTIST, SLU01, POIS_GR, WALF01, DECK01, LAB -- see [[azrael-water-reflections]]) could take it on request.

**How it draws (DrawWater):**
- With WaterFx, the mirrored room renders into `_reflFbo`/`_reflTex`. It shares `_depthTex`; colour is cleared to alpha 1, which means "nothing reflected" (the main shader writes alpha 0).
- After the depth copy is restored, pass "e" draws the water tris with `_pWater`, under step a's stencil (still intact, because the blit copies depth only) and with alpha writes masked:
  - pass 0: `DST_COLOR, ONE` = picture x (1 + glow). This brightens the texture's own specks.
  - pass 1: `ONE, SRC_ALPHA` = Fresnel reflection sampled at a ripple-bent offset, plus glints from the lamp and up to 4 placed lights, plus glow from below. The picture is kept by 1 - share.
- Wall light lives in FS_MAIN (uWN/uWBox/uWY/uCaus/uGlowCol/uWSpot): a fill plus caustics on faces whose world normal is not facing up, fading with height above each pool's box. The colour is glow mixed 40% to white (pure cyan turned the brown stone green).
- Shared GLSL consts: NOISE_GLSL (pcg3d/grad3/noised) and WATER_GLSL (glowAt, caustic). FS_MAIN is now HEAD + NOISE + soft + WATER + FS_MAIN_TAIL.

**Tuning lessons (SPAROOM):**
- The first pass (glowPower 0.35) looked like a lit swimming pool. Now glowPower 0.14, base 0.25.
- An underwater lamp radius of 120 is wider than a typical view, so it reads as an even glow. Use 70 with power ~3.
- Caustic lines need `1-|n|*7` cubed; at 3.4 they are blobs.
- shine 2.5: at f0 0.04 the plain Fresnel was too faint to read as shiny.
- Cost: frame ~2.3 ms total offline.
- Round 5 (Josh): wall light "a bit too bright" -> caustics strength 1.5, fill 0.18. "Not in the hallways" -> `water.noLight` [[x0,z0,x1,z1],...] (AddWaterCut, uWCut, 12-unit soft edge). The pool quad is BIGGER than the room, so the light reached the tunnels. Verified numerically from inside the SW hallway: 12% darker with the cut.
- SPAROOM also got a torch (lights[0], SPAROOM/3) at (-181.7, 41.7, 49.8).
- Round 6:
  - placed-light glints were a white blowout -> colour SQUARED x (0.55 sharp + 0.05 broad), knob `water.lightSpec`;
  - SPAROOM embers off;
  - a second torch at (175.4, 2.77, -67.1).
- BAPTIST got it too (Josh, 2026-10-08): the bath (x 44..81, z 81..216, water y -38/-57). It has one lamp and a finer web (size 22), with wall light about half of SPAROOM's (strength 1.0, fill 0.14), because its green moss turned full strength neon.
- Round 7 changes:
  - lightSpec 0.5;
  - caustics 2.05 / fill 0.24, the midpoint Josh asked for;
  - FINE STEAM: `steam.fine` -> Particles.SteamFine -> seed 3+ -> FS_PART's sharp 3-octave wisp branch. SPAROOM has its own steam block (size 12, rate 90, alpha 0.28); WASHCORI keeps the soft puffs.
- Render-RoomView now lets particles build up for 4 s (`-Seconds`). Before that, renders barely showed steam.
- GLSL comments inside the C# @"" shader strings must not contain double quotes (they end the string).
- Test-GpuLook: splat a HASHTABLE. An array splat binds positionally (-Room went into X).

Related: [[azrael-room-review]], [[azrael-gpu-effects]], [[azrael-volumetric-fog]].

**Water-edge mist (Josh, Room Review SPAROOM/8, 2026-10-09):** "teal, subtle mist ... at the edges of the top of the water", the water's colour but lighter, ALONGSIDE the dark fine steam he likes.
- Particles kind WMIST, room key `"waterMist": { rate, size, life, rise, alpha, color, inset, drift, band }`. SPAROOM uses rate 30, alpha 0.12, #7FE6DA, about 360 puffs alive.
- **TRAP:** SPAROOM's water is ONE quad (two triangles, -369..259 x -377..252) running under the walls, so the mesh's own outline is hidden behind the walls (the first try put every puff out of sight).
- Particles.SetWaterEdges(vx, waterTris, roomIdx, roomTriTex, band) instead samples about 6000 points on the water and keeps those that are:
  - enclosed: 12 level rays at y+4 all hit something within 1500;
  - within `band` of a wall, pillar or step.
  - SPAROOM keeps about 1960 points in about 217 ms, once per room.
- Puffs drift away from the nearest wall. At rate 7 / alpha 0.07 they were invisible; the perimeter is about 2500 units long.
**Drip rings (Josh, Room Review SPAROOM/2, round 15, 2026-10-09):** "droplets from the ceiling to effect these ripples as if the drops are hitting the surface".
- Particles records each drip landing (x, z, height, age; the newest 16). `GatherDrops` hands them over and `GpuRaster.SetDrops` converts them to births in `Time`.
- FS_WATER adds a leading crest plus a fainter trailing one per drop, only where |vWorld.y - landing height| < 4, so walkway landings don't ring the water.
- SPAROOM has NO ceiling over the pool (18% of upward rays hit only the walkways), so `drips.fromDark` (240) starts a drip that far above the eye when ClearanceUp finds nothing.
- **MEASURED:** the first ring strength (slope ~0.04 at 1.5 s) changed 9 sampled px in an A/B of six landings. The current envelope (decay 0.8, amplitude 1.8) changed about 1,400. Particles are seeded (Random 11), so an A/B with ripples 0 isolates the rings.
- The same round raised SPAROOM's distort 60 -> 90 and ripple slope 0.15 -> 0.22.