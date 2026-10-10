---
name: azrael-painted-darkness-props
description: "Round 9 (2026-10-08): painted darkness (the fog thickens where the texture ART is painted dark, built from the room's own surfaces) and solid props (a torch in a wall sconce under a light). Both GPU, per-room settings. Not yet seen in game."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-09T03:30:34.742Z
---

**Painted darkness (CORICORI/5-6, Josh):** "match the dark black areas ... with black volumetric fog ... to emulate the lighting the original developers tried to achieve with the texture art".
- `GpuRaster.BuildPaintField(vx, uv, idx, triTex, texes, flipV, cell, smooth, gamma)` builds the map at room load.
  - It samples every triangle's texture (the Rgb mip about 64 px wide; holes skipped) at points spread by area, into an XZ grid.
  - The grid is gaussian-smoothed (normalised).
  - darkness = (1 - lum / p85)^gamma, uploaded as an R8 texture.
- FS_COMP's volMarch accumulates `tau += map * uPaint.x * cutK * stepL` per step (cutK = the flashlight thinning, dens/uVol.x). The in-scatter Tt includes it, and the compose multiplies T by max(exp(-tau), 1 - max).
  - The half-size target now holds (ins, tau). volUp reads each sample's line length from the DEPTH (sightLen), no longer from alpha.
- Room file: `volume.paint {density, max, cell, smooth, gamma}`. It only works with a volume block.
- Checking tools: `Test-GpuLook -PaintMap file.png` saves the map; `-NoPaint` gives an A/B.
- CORICORI: density 0.02, max 0.85, cell 8, smooth 30, gamma 1.5. 22% of its plan is darker than half; the SW end (wall03) is among the darkest.

**Props (CORICORI/7, Josh):** "a torch shaped mesh ... wooden stake ... topped with a cylindrical piece of metal which would contain the flame".
- `GpuRaster.ClearProps` / `AddTorch(lx, ly, lz, nx, nz, scale, wallDist)` builds a sconce: a wall plate and an iron arm (back to the wall along the light's dir), a holder ring, a wooden stake leaning 20 degrees out, a flared iron cup (rim band) with a coal disc, its mouth 3 units below the light. The light is not moved.
- The geometry is two-sided triangles. MergeProps appends it to the room's arrays at the top of Draw, so it is shadowed, relief-mapped, fogged and reflected like the room.
- Textures are procedural (wood, iron, coals; 256 px, made once). Not in the CPU (F9) renderer.
- Room file: a light gets `"torch": {scale, wall}` (needs `dir`). Set-GpuAtmosphere rebuilds the props per room load.
- PowerShell trap again: `$l` IS `$L` (it wiped a lines array).

Related: [[azrael-volumetric-fog]], [[azrael-holograms]], [[azrael-room-review]].

**Round 10 (2026-10-08):**
- Josh will replace textures with CLEAN renders (no painted lighting) and build real lighting that keeps the original's patterns. BuildPaintField now takes pal: with it, the map comes from the ORIGINAL pixels (Idx + game palette), so replacements never change it. It matches the loaded-texture map to within 2/255. paint.fromLoaded: true uses the loaded textures instead.
- Proposed for when his clean textures land:
  - a 'painted ambient' part: the room level lowered on surfaces where the original art is dark, because the fog only darkens with distance;
  - real lights suggested at the map's brightest spots, the painted light pools.
- Torch: 50% closer to the wall (wall 15). The LIGHT MOVED with it to (97.29, -8, -30.62) on the same wall point. Arm bug fixed: back = wallDist + (ring - L).n (the old sign made the arm 10 units too long, hidden in the wall).
- FLAMES: AddFlame(x, y, z, height, width); AddTorch adds one at the cup (13 x 6.6). FS_FLAME is an fbm teardrop with a heat ramp and a blue root. Two upright billboards (outer + core) plus a glow, additive, depth-tested, drawn after the holos. ClearProps clears flames.

**Round 12 (2026-10-09), MINEMAZE:** rooms\MINEMAZE.json (new).
- Lights: 	ools\Find-PaintedLights.ps1 -Room R [-Count -Spacing -Height 72 -OffWall 15 -Map] puts torches at the ORIGINAL art's bright places.
  - It uses GpuRaster.PaintLum, the brightness field behind the paint map, read from the original pixels.
  - Default is even coverage (brightest first, Spacing apart); -Peaks = local maxima only. The mine is painted bright in BROAD areas, so peaks found only one spot in the cave.
  - For each spot: the floor (a ray up from below the room), then the nearest wall (24 rays at torch height); the torch faces the pool.
  - It prints lights[] JSON with 'torch'. MINEMAZE got 7 torches.
- Volume as CORICORI + paint; mist {density 0.035, height 12, max 0.06, wisps 1, wispSize 55, drift 7}; embers off.
- Seven shadowed all-round torches: watch the frame cost in game. Only the first 4 lights scatter in the volumetric air.
- Round 13 (Josh): MINEMAZE cut to 4 torches (Find-PaintedLights -Count 4 -Spacing 420: big cave, east stretch, 2 upper level) and the ground mist removed ('mist': null, which also overrides the shared misty class). The thick pale mist did not look good: don't re-propose a pale ground mist there.

**Sconce shadows (Josh, Room Review MINEMAZE/4, 2026-10-09: "too blobby ... only the stake portion casts a shadow"):**
- Raster.Tex.NoCast: the prop iron and coals textures (`_pTex[1..2]`) are skipped by DrawSet(!colour), i.e. the shadow views.
- A placed light's own shadow view also discards prop fragments within `_propReach` of the light. FS_DEPTH uses uSkip = light position + reach^2, set per slot (i >= 2) and reset after each set, because the player-body caster pass shares the program.
- Why: the stake sits straight below its light, so it shadowed END-ON, a round blob down the wall. The stake still casts shadows from other lights and the flashlight.
**Torches are 15 off the wall everywhere (round 14, 2026-10-09):** the SPAROOM lights got sconces (SPAROOM/6-7) and moved from 30 to 15 out, the CORICORI rule. MINEMAZE light 6 is torch-like with NO graphic: dir [0,-1,0], all-round.
- Test-GpuLook needed the watcher's upAx rule (a light facing straight up or down leans on x) or LookAt throws "looking straight along the up axis". That broke Reply-RoomNote's render.
**Lincoln (MINEMAZE, the wounded raptor) is rig ZZ0004 (RAPTOR.XAF)**, slumped at body ~(307, -45, 361), head (315, -28, 364), floor -61.5. Found from the watch.log bone dumps ("ZZ0004<bone> ... world t (...)"); none of the offline tools know where characters stand.
- The passage there runs east-west, about 90 units wide (north wall ~40, south ~48 from him). Viewed from the west, the RIGHT wall is the SOUTH one (left-handed engine: facing +x, right is -z).
- Light 6 (2026-10-09, Josh "cast directly at the raptor ... shadow on the nearby wall to the right, dim it a bit") is now a spot (cone 28/50, power 1.0) at (265, -15, 402) aimed at him.
- A/B diff render (light 6 power 0 vs 1, -PlayerShadow 308,361) confirmed the body's shadow lands on the south wall.
**Torch size (round 16, 2026-10-09, Josh: "make ... all torches the size I instructed in the washroom torch"):** every torch is `torch.scale` 0.8 now (9 torches in CORICORI, SPAROOM, MINEMAZE, WASHCORI). Use 0.8 for new ones.