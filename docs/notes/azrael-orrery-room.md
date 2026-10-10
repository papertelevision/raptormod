---
name: azrael-orrery-room
description: "ORRERY room settings (round 22, 2026-10-09): golden ceiling cone + dust, four colour-cycling blob lights (new light key 'cycle'), light fog, GI. Parked orrery parts at y -37,000 broke the GI grid (fixed). The puzzle full-screen ask is a SEPARATE task."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-09T20:27:56.426Z
---

Josh's Room Review notes ORRERY/1-7 (2026-10-09). Not yet seen in game.

- **Golden cone:** light at (2, 395, 1) in the ceiling shaft orr_top (y 330..406), pointing straight down.
  - cone [16, 22], #FFC25A, power 1.1, bounce 1.2, air 9, rays 0.4, dust 320.
  - The first pass (power 2.2, bounce 2, GI strength 2.5, air 18) washed the room gold, mean 150. Now mean ~75.
- **Four blobs:** 25 above the floor at Josh's points. Power 0.5, range 140, flicker 0.35, air 3. No dir, so they cast no shadow.
  - New light key **`cycle`**: `{colors[], seconds, offset}`. Update-RoomLights eases (smoothstep) between the colours in the frame colour only; the GI bake uses the base colour.
  - The blobs run #FF6A14, #C8508C, #FF3A12, #8A3AB0 over 22 s, at offsets 0 / .25 / .5 / .75.
  - `"embers": null` stops sparks coming off them.
- **Fog air order:** the air takes 4 lights, now sorted by distance / air², so a strong-air shaft is not displaced by nearer blobs. With all air at 1 the order is unchanged.
- **GiBake bounds** ignore geometry more than FarFromLights (4000) from every light. The orrery's animated parts sit at y ≈ -37,000 in the static geometry and stretched the grid to 1,179 probes tall.
- **Round 23 (Josh, chat):**
  - Cone 30% narrower: [16, 22] -> [11, 16].
  - The blobs got NO particles: they had been throwing embers. **TRAP: `"embers": null` does NOT disable embers** (a missing or null block means the defaults are on); use `{"rate": 0}`.
  - The blobs are now air 8 with airReach 45: compact coloured glows in the mist.
  - Dark room mist: volume density 0.004, max 0.72, lightThrough 0.9, lightThroughAir 0.8, lightReach 90, so every light cuts through it.
  - Backup: `tc-test\ORRERY.json.before-r23`.
- **Round 24 (Josh in game, 2026-10-09): "the golden beam has disappeared"; blobs to spread only across their floor ring.**
  - Cone power 1.8, air 13, rays 0.6.
  - **The air glow is steeply nonlinear for a wide cone:** air 4.5-9 showed no column, air 24 was a blinding white wall, 13 is a readable column. CORICORI's 26 works only because its shaft is 3-6 degrees.
  - Blobs: y 16 (12 above the floor), range 38, airReach 32, **bounce 0**. With bounce they had spread their red through the whole room via GI.
  - Backup: `tc-test\ORRERY.json.before-r24`.
- **Round 25 (Josh in game: the beam's brightness was "insane"; match CORICORI's shaft, keep the colour; much more, more varied dust):**
  - **REAL CAUSE of the 9-vs-13 "nonlinearity" in round 24:** the fog's 4-light ranking (dist/air²) dropped the beam for the nearer blobs (air 8). New light key **`airFirst`** (GpuRaster.SetAirFirst) always keeps a light in the four.
  - Beam matched to CORICORI by arithmetic: power 0.5 (its range is 900 vs 3000), air 9 (26 / 2.8, the cone's width ratio), bounce 3, airFirst.
  - Shaft dust gained a 16th float **`vary`** (Particles.cs stride 15 -> 16): sizes 0.3x .. (0.3 + 2.7 x vary)x, r³-weighted. Beam dust: 1100, size 1.0, vary 1.
  - The room's motes: count 1100, size 2.6, sizeMin 0.12.
  - Backup: `tc-test\ORRERY.json.before-r25`.
- **Round 26 (Josh):** the beam 30% less opaque: air 9 -> 6.3. The dust was "all at the bottom and too large"; he wants bokeh specks swirling bottom to top.
  - **CAUSE:** the shaft span rule takes the first surface along the axis as a ceiling to enter through. Here that is the orrery's top, so every speck spawned between it and the pit floor.
  - Shaft data is now **18 floats**:
    - [16] `swirl`: rad/s round the axis, per-speck pace 0.6-1.4x; the specks also rise and sink and are clamped inside the cone.
    - [17] `fromLight`: the span runs from the light down to the last surface.
  - Defaults are 0, so CORICORI and MINEHEAD are unchanged. The rule was deliberately NOT changed globally: MINEHEAD's first hit really is the slab it shines through.
  - Dust: 1200, size 0.7, vary 0.5, swirl 0.35, fromLight. Backup: `tc-test\ORRERY.json.before-r26`.
- **Round 27 (Josh wants subtlety):** air 6.3 -> 3.8; blobs flicker 0, so only the colour cycle "breathes".
  - Dust "more natural, floating, MUCH slower": swirl 0.35 -> 0.03.
  - With swirl > 0 each speck now eases (0.6/s) toward a smooth per-speck sine drift field under 1 u/s instead of a vertical random walk. Initial vy ±0.3.
  - **Rigid rotation speed scales with radius:** 0.35 rad/s was ~17 u/s at the beam's edge.
  - Backup: `tc-test\ORRERY.json.before-r27`.
- **Round 28 (Josh):** gi ambient 0.5 -> 0.8. MEASURED: only +6% mean in the level view (31.0 -> 32.8). The black mist (density 0.004, max 0.72) is the dominant darkener here. Backup: `tc-test\ORRERY.json.before-r28`.
- **ORRERY/1 (open):** the orrery puzzle (orr_puzzle) is tiny on screen; Josh wants it full screen like the books. It needs RE of the game's puzzle drawing and hot spots, done the way [[azrael-memory-core]] was. It was proposed as its own session.

Related: [[azrael-baked-gi]], [[azrael-room-review]], [[azrael-art-light]].
