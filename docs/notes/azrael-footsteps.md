---
name: azrael-footsteps
description: "Footsteps (2026-10-14, Josh): host-made steps by floor surface (stone/tile/wood/metal/water) -- BootHd.cs Footsteps, rooms\\_footsteps.json, Step-Footsteps; how steps are detected and gated, switches."
metadata:
  type: project
---

Josh, 2026-10-14: "footsteps ... subtle sound effects, which would change based on the different flooring being walked on (mainly stone, tile, wood)". The game has no footsteps of its own. Built and checked offline (compiles, demo WAV, simulated walks, real rooms' tables); **not yet heard in game**.

**Where it lives**
- `tools\BootHd.cs` `Footsteps` (after `BootSound`): detection, surface lookup, synthesis.
  - It plays through its own `BootSound` mixer: `PlayStereo`, plus a new `BootSound.Warm()` that keeps the device open. The mixer gives the device back after 4 s of silence, and re-opening takes ~0.5 s, which would make the first step late.
- `tools\Watch-HostRender.ps1`:
  - `Step-Footsteps` is called every GPU frame, just before `fx.Update`, and runs even with `-NoParticles`.
  - `Set-RoomFootsteps` is called from `Set-GpuAtmosphere` on each room.
  - Switches: `-NoFootsteps`, and `-FootstepVolume` (a walking step's peak, default 0.2).
- GPU (true colour) only, like the other new effects; `-Retro` gets none.

**Detecting a step**
- **Source:** the eye's own horizontal movement (`$m[12]/$m[14]`), the same way the kicked-up dust works.
- **Teleports:** a move of 30+ units in one frame (horizontal or vertical) is a teleport or load and resets the walk.
- **Speed:**
  - The game moves the player on its own tick, so many host frames see no movement. Speed is therefore smoothed over 0.2 s.
  - The player counts as stopped only after 0.22 s with no movement at all.
  - Below MinSpeed 24 u/s counts as standing still.
- **Stride:** StrideBase 46 + StrideK 0.16 x speed.
  - Walking (~146 u/s): ~70 units, about 2 steps a second.
  - Running (~290 u/s): ~93 units, about 3.3 a second, MEASURED in the simulated walk.
  - The first step comes half a stride in.
- **No sound when:**
  - falling (smoothed vertical speed < -120 u/s);
  - nothing is found within EyeHeight 45 + AirGap 40 below the eye.
- **Quiet (followed, no sound)** while any of these has the player:
  - the map (`mapFreezeCam`);
  - a boot cover;
  - the room cover;
  - a conversation (`convWas`);
  - a visor panel playing.
- **The game's own effects setting is obeyed.** It is read twice a second from 0x14693A (SFX on) and 0x14693E (level 0..127).
  - SFX off means no steps; the level scales them.
  - The first read is logged ("footsteps: the game's effects on, level N/127").

**What is underfoot**
- **The ray:** `Footsteps.RayDown` looks straight down from the eye, using the footprint and the height at the point (as `Raster.ClearanceUp` does). It returns the nearest triangle below, and its texture is taken from `$room.Texes`, the copy `Set-RoomMaterials` tags.
- **Lookup order:**
  1. The texture's name in `Named`, with or without its number. These come from `rooms\_footsteps.json` "surfaces" plus the room's own `"footsteps"` block.
  2. Its material: wood -> wood; polished/glass -> tile; iron/copper/brass/gold/gilded -> metal; water/slime -> water.
  3. Name hints (tile|marb|mosaic|parq, wood|plank|board|deck, grat|grid|mesh|metal).
  4. The room's "default", else stone.
- **The table holds a separate floor-surface list.** Most floors are the generic `floor` material, which means stone. The 62 floor textures were looked at by eye (scratchpad floor-sheet / floor-big), and the tile and wood ones are named in `rooms\_footsteps.json`:
  - **Tile:** 2flor, bapflor_key, edfloor2, gra_fl01, lib_flor, lr_floor, or_flor, poi_flor, r35floor, red_flor, intflr01.
  - **Wood:** 2tapfl, aquflor1, bapbalfl, clo_flor, tre_bflo, tre_cflo, cob_cflo. cob_cflo is the same art as tre_cflo.
- **Why not change the material:** that would change the shine, relief and parallax. The footsteps table changes nothing visual.
- **A room's block:** `"footsteps": false` = none in that room; `{ "default": "wood", "<texture>": "tile" }` adds or overrides.

**The sounds** (synthesised fresh per step on a pool thread, a few ms each)
- **Every step:**
  - a heel, then a softer toe 34-60 ms later (18-34 ms running);
  - pitch +/-8% and weight 82-100%;
  - running steps x1.25;
  - feet alternate pan +/-0.14;
  - a two-pole low-pass and a 30 ms tail fade.
- **Per surface:**
  - **Stone:** 95 Hz thud, a dry band-passed tap (1.7 kHz) and sparse grit (3.2 kHz).
  - **Tile:** a bright click (3.6 kHz), a short glassy ring (modes ~1.95/2.87/4.15 kHz) and a slap-back at 26 ms x0.13.
  - **Wood:** a hollow knock (modes ~150/335/610 Hz), a mid tap, and a faint creak on 12% of heel strikes.
  - **Metal:** a clank (modes ~520/1235/2140/3360 Hz, ringing up to 110 ms).
  - **Water:** a splash plus bubbles.
- **Levels:** walking-step peaks MEASURED at -14 to -17 dBFS at the default Level 0.2 and full SFX. The RMS over 300 ms is -32 to -42 dBFS, so the steps are subtle by design.
- **Offline listening:** `Footsteps.SaveDemo(path)` writes a WAV with 6 steps per surface (4 walking, 2 running).

**Known risks (untested in game)**
- Anything that carries the player horizontally (a cart or raft ride, if the game has one) would sound like walking. A room's `"footsteps": false` silences such a room.
- Scripted camera moves that are not covered by the quiet list would step.
- **Flashlight switch sound (Josh, 2026-10-15):** "the tile footstep is actually perfect for the sound of the flashlight turning on/off" -- he listened to exported tile steps (Desktop\RaptorMod tile steps) and chose "run 3" for ON and "run 4" for OFF = `Footsteps.Step(Tile, run: true, leftFoot: on, seed 1011 / 1012)` (`LampOnSeed`/`LampOffSeed`). `Footsteps.LampClick(on)`, called by Watch-HostRender `Invoke-LampClick` on the F key's toggle only (not the automatic off at a new game); through `$script:steps` (the game's effects level) or, before/without footsteps, its own Footsteps instance. Verified sample-exact against the files he heard.
