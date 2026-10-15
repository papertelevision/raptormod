---
name: azrael-phase1-life
description: "Phase 1 'life' effects (2026-10-14, Josh): reactive dust, eye shine, shot impacts (sparks/glow/scorch), visor condensation -- where each lives, room keys, switches, traps found."
metadata:
  type: project
---

Josh asked for these four on 2026-10-14 (phase 1). Phase 2 is the echo scan, the whole-complex map and the painted-light finder. All are graphics-card only; -Retro gets none. Built and checked offline; not yet seen in game.

**Dust that reacts**
- `Particles.cs`: shaft specks get a per-particle push velocity (`P.dvx/dvy/dvz`) from the player's body: a column from the floor to 6 above the eye, ReactRadius 42.
  - The push is outward, part along his way, and curls into a wake. It dies over ReactSettle 1.6 s.
  - A standing player stirs nothing (speed > 4 u/s).
  - Swirl shafts skip their cone clamp while pushed.
- `Motes.cs` does the same for the room motes.
- Room key `reactDust` (number = strength, false = none).
- BAPTIST got six speck-only lights (power 0), one cone per window from its sun. Lights are now 8/8 there.

**Eye shine**
- `Particles.cs EyeShine`, appended to the particle buffer after Gather: an additive halo plus a pin.
- Rules:
  - shown only while the lamp is on, by the lamp's hot spot and halo cones;
  - only while the creature faces the player (head middle -> eyes vs the eye -> player direction).
- Built in: EUGBLD (CORICORI's creatures) `EUEYE` with head `EUHEAD` and neck `EUNECK01`. It is the only rig with a real eye part.
- TRAP: EUEYE carries a stale transform in the engine (rest pose X~2500). When the eye cluster is not within 2.5 head-radii of the head, the eyes are placed on the head (forward of its middle, away from the neck).
- Room key `eyeShine`: false, or `{strength, size, halo, parts: {EYEPART: {head, neck, color}}}`. Other rigs need head/neck names (see the rig survey: LURKA `head`, RATTY `rathead`, TRILET01 `HEAD`...).
- `-NoEyeShine`.

**Shot impacts**
- The ammo-drop frame sets `$script:shotPending`. After posing, the cursor (`0x182D6C`; in combat the pointer is the crosshair) is mapped like `Write-PickProbe`. `Raster.PickHit` (new) gives the point, the eye-facing normal and the triangle.
- Not on characters (`Parts[TriPart].IsCharacter`).
- Effects:
  - `Particles.Impact`: SPARK, white-hot -> red, additive, plus a PUFF of dust;
  - `GpuRaster.AddScorch`: a ring of 16, ScorchLife 30 s, radius 4.5, ragged with noise; ember glow on the scorch's middle for its first ~0.6 s, counted into lightG so it shows through the volumetric fog;
  - ImpactK: a 0.35 s warm light as one extra wall wash, 6 units off the surface, aimed back at it.
- `ClearScorches` on room setup.
- Room key `impacts: false`. `-NoImpacts`.
- Offline: `Test-GpuLook -ShotAgo s` (a shot at the picture's middle).
- TRAP: a test shot at the inscription torch was invisible next to the torch's glow, and a dark corner hid the glow in fog. Test on a lit wall.

**Visor condensation**
- `ScanWire.cs VisorFog`: K rises over FogIn 1.6 s on entering a steam room, holds 2.5 s, clears over 7 s to Rest 0.22. A waft returns every ~22 s (0.75), and leaving clears it over 4 s.
- `FS_PRESENT condense()`: from the view's edges (the corners further in, the panel seam least), ragged fbm reach `0.21*K`. Behind it the picture is softened (8 taps) and veiled pale (with a 0.30 floor, so it reads over dark rooms). Water beads (24 cells per view height) along the mist's inner edge are lenses showing the scene inverted, each with a glint.
- Steam = `$script:fx.SteamRate > 0` (the spa class).
- Room key `visorFog` (false / true / strength). `-NoVisorFog`. Off under the map and the boot cover.
- Offline: scratchpad `visor-fog-test.ps1`.

**PowerShell trap hit:** a `'?'` inside a single-quoted replacement string ended the string early, and the edit silently lost its tail. Write long replacement blocks to a file first.

Related: [[azrael-light-kinds]], [[azrael-gpu-effects]], [[azrael-visor-damage]], [[azrael-gun-sound]], [[azrael-scan-wire]].
**Shot impacts lined up with the reticle (2026-10-14):** the shot's ray scaled the cursor row by the raster's FULL height. Under the widescreen panel the picture runs on below the view (Raster.ViewRows), so the hit landed ~150 px under the reticle ("centered in the viewport but does not accommodate the UI"). It now uses the view's rows for both axes.
- **Sparks made tiny (Josh, 2026-10-14: "much smaller ... too cartoonish. Think a bunch of 1-2 pixel sparks at different warm colors"):**
  - A spark goes to the card with seed -2..-3. VS_PART sizes it at 1 to 2.2 px whatever its distance, and FS_PART draws it as a hard point with no soft disc.
  - Each takes one of `Particles.SparkHues` by its seed (white-hot #FFF4D8, yellow #FFD878, amber #FFB050, orange #FF8A30, red-orange #F0602A), cooling toward a deep red (t^2) and dimming with a flicker.
  - SparkCount 22 -> 44.
- **Condensation beads shrink away (Josh, 2026-10-14: the droplets were "wiped with a harsh line that makes it look fake ... If they simply shrunk away instead"):**
  - The beads were drawn per pixel, clipped wherever the mist's edge fell (`m <= 0.001` returned early), and switched on or off against each pixel's mist.
  - Now `mistAt()` is read at each bead's OWN middle; the bead's radius scales smoothly with it (`sz = smoothstep(0, 0.22, band - 0.9 * hash)`). As the mist comes and goes, each bead grows or shrinks to nothing, and the mist's edge never cuts one.
- **WASHCORI lighter:** rooms\WASHCORI.json `"visorFog": 0.45` (SPAROOM stays at 1).
  - The strength already scaled the reach (uFogK); it now also scales the thickness: `GpuRaster.VisorFogAmount` -> uniform `uFogAmt`, density x (0.4 + 0.6 x amount).
  - The present shader is linked only when the window attaches. Check it compiles with scratchpad linktest.ps1 (reflection on Link(VS_CLEAR, FS_PRESENT)).
- **Round 2 (Josh, 2026-10-14: "disappear much slower, with animation more similar to the original method"; WASHCORI "droplets smaller and don't extend so far into the visor center ... same goes with the blur"):**
  - VisorFog: ClearSeconds 7 -> 18, LeaveSeconds 4 -> 10, evaporation rate 1/1.5 s -> 1/4 s.
  - Beads shrink over a wider span (smoothstep 0.5), so they go one by one as the edge recedes past them.
  - Bead radius x (0.45 + 0.55 x uFogAmt) and blur radius x (0.4 + 0.6 x uFogAmt), both by the room's strength.
  - WASHCORI `"visorFog"` 0.45 -> 0.3.
- **Round 3 (Josh, 2026-10-14: "Lets remove condensation in the wellcori room" -> WASHCORI):** `"visorFog": false`.
  - **TRAP, FOUND AND FIXED:** `Get-RoomAtmosphere` builds a `[pscustomobject]` and sets each room key on it, but `visorFog`, `reactDust`, `eyeShine` and `impacts` were not among its first properties. Setting a missing property on a pscustomobject THROWS, and the catch skipped the rest of the room file. So WASHCORI's 0.45 and 0.3 never applied (Josh saw no change), and the same would have hit any room using those four keys.
  - Fix: the four (and `footsteps`) are in the initial object. Any NEW room key must be added there as well as to the two key lists.
