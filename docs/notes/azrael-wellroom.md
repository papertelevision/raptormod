---
name: azrael-wellroom
description: "WELLROOM (round 23, 2026-10-10): the well's water is the part 'death' (not named water) -> room key water.parts; SPAROOM water scaled down, artLight + paint fog, torch, two faint teal lights. Not yet seen in game."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-11T04:48:23.351Z
---

Josh's Room Review round 23: six WELLROOM notes. `rooms\WELLROOM.json` is new.

- **The well's water is the part `death`** (material NIBODYBASE, texture 06-wel_bdy2, a drowned body under black water). It sits at y -35 as a hexagon x 7..78, z -100..-39. Its name has no WATER/LIQUID, so the watcher never treated it as water.
  - New room key `water.parts: [part names]`. Get-Room (Watch-HostRender.ps1) reads it through Get-RoomAtmosphere, so Test-GpuLook sees it too.
  - Get-Room CACHES rooms: a change to `parts` needs a watcher restart.
- **Water (notes 1-2):** SPAROOM's settings scaled to a pool about 70 units across: one lamp at the centre (radius 26, power 3), ripple size 14, caustic size 20, distort 50.
  - caustics.height 200: the ceiling (85.5, 120 above the water) gets about 55%.
  - The wall light spreads height/2 units past the pool's box (the `edge` in FS_MAIN). That one knob sets both the ceiling falloff and the sideways reach.
- **Dark mist (note 3):**
  - The paint fog (as CORICORI) does almost nothing here. Measured: a mean change of 0.1-0.4/255, even at density 0.05. The room is small and its painted dark lies along the walls and corners (paint map 54x72).
  - What works is `artLight` (MINEHEAD's settings, no tint). It darkens the painted black on the floor and walls clearly. Keep both.
- **Lights:**
  - torch at (-146.85, 10.86, -19.84) facing +x;
  - teal #5FD8CA (no flicker, air 2) at (3.65, -18.04, -107.04) power 0.3 and (70.82, -4.12, -17.65) power 0.2. 0.35 made a hot spot on the pale wall.
  - gi with ambient 0.6; embers off.
- Josh's note-3 viewer camera sits ABOVE the ceiling (y 105). Test from inside the room.
- **The ghost (2026-10-11):** Niamh (rig NIAMH) is drawn as glowing smoke with wisps and her own dim light, via the room's `ghost` block. See [[azrael-ghost]].

Related: [[azrael-modern-water]], [[azrael-art-light]], [[azrael-painted-darkness-props]], [[azrael-room-review]].
