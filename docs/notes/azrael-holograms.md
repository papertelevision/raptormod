---
name: azrael-holograms
description: "Room holograms (GPU): world-space teal wireframes from a per-room 'holograms' list. The CORICORI chalice was REMOVED at Josh's request (2026-10-08); the code stays for later. How the lines are drawn."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-09T00:08:17.618Z
---

Josh (2026-10-08, CORICORI/4): "Add the polygonal chalice from the intro here."

"The polygonal chalice from the intro" = BootHd's ARTIFACT TRACE (DrawChalice): a lathe profile (CupR/CupY, 13 points: foot, knotted stem, bowl), 14 meridians, rings CupRings, spin 0.75 rad/s, teal = palette 88 #71DFD7, near-side flare = palette 55 #BEFBFF. It is NOT a model file.

**GpuRaster holograms:**
- `ClearHolos` / `AddHoloChalice(x, y floor, z, height, spin, colour, flare, glow, hover, bob, scan)`.
- Segments are built per frame in world space (BuildHolos, uses Time). Each segment is 6 vertices expanded to a screen-width quad in VS_HOLO (no geometry shaders on this driver).
- Drawn after the water, before the dust, into _fbo: depth test GREATER, no depth write, additive. A halo pass (HoloHalo 5 px at 1200 rows, alpha 0.22) then a core pass (HoloCore 1.25 px, alpha 0.95, flare on the near side).
- The scan ring: a ring 1.25x the profile radius passing down every 2.4 s.

**Watcher:** Set-GpuAtmosphere reads the room file's `holograms` [{shape, x, y, z, height, spin, hover, bob, glow, color, flare, scan}]; Get-RoomAtmosphere carries the key.
- CORICORI: the chalice at (-36.15, -113.95, 7.02), height 26, hover 8, plus lights[3], a soft teal no-shadow light at its middle (air 2, so it glows in the volumetric fog).

Related: [[azrael-room-review]], [[azrael-gpu-boot]], [[azrael-scan-wire]].

**2026-10-08, later: Josh asked to remove the chalice but KEEP the code (for later).** Its holograms entry and the teal glow light are gone from CORICORI.json (the file was restored from rooms-history\round-008). No room has holograms now; the feature is idle until a room lists one.
