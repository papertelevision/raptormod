---
name: azrael-baked-gi
description: "Bounced light (baked GI) in the GPU renderer - GiBake.cs probe grid + FS_MAIN giAt, per-room \"gi\" block, cached by signature; CORICORI pilot 2026-10-09, not yet seen in game. Why the albedo is 2.2 and how validity works."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-09T17:51:42.380Z
---

Josh (2026-10-09): "Bounced light (global illumination), pre-calculated per room ... recalculate whenever a room file changes."

- **Bake:** `tools\GiBake.cs`, on the processor.
  - A BVH over the room's triangles; Moves (character) textures are skipped, and texture holes (palette 0) let rays through.
  - The grid has one probe every `spacing` units. Each probe sends `rays` rays and stores an L1 spherical harmonic per colour channel (12 floats).
  - Bounces iterate over cached ray hits; the direct light uses FS_MAIN's formula plus a shadow ray.
  - Cost: CORICORI 0.2 s, MINEMAZE 0.4 s on all threads.
- **Validity is NOT by face winding.** This engine's winding is inconsistent (the shader flips normals toward the eye). A probe counts as in the room only if both hold:
  - a flood fill from the lights reaches it without crossing a surface;
  - at most `MaxEscape` (6) of its 32 rays escape into nothing. Without this test the flood leaked through doorways into the empty bounding box: 99.9% of probes came out "valid".
- **On the card:** GpuRaster.SetGi takes ONE RGBA16F 3D texture with four slabs along z (R, G, B, validity) on texture unit 15. FS_MAIN's `giAt` blends the 8 probes around a point, dropping invalid ones and favouring those on the side the surface faces. Inside the `uRefl==0` block it does `gain += uGiK*giAt(vWorld, room-space Np)`, and the room level becomes `uLampRoom*uGiAmb`.
  - GiFlicker: the bounce brightens and dims with the torches (power-weighted mean flicker), set in Update-RoomLights.
- **Watcher:**
  - Set-GpuGi runs from Set-GpuAtmosphere; Complete-GpuGi runs each frame after Update-RoomLights and uploads when the bake is ready.
  - Background bake: half the threads at BelowNormal priority. NEVER starve DOSBox.
  - Cache: `C:\Games\azrael-render\gi\<ROOM>-<signature>.gi`. The signature covers geometry, texture colours, lights and settings. A changed room file means a new bake on the next room entry; there is no live reload.
  - `-NoGi` turns it off. Test-GpuLook bakes synchronously and takes `-NoGi`, `-GiStrength` and `-GiAmbient`.
- **Calibration (MEASURED):** the original textures average 14% brightness because the lighting is painted into them. At albedo 1 the median bounce was 0.04 against a room level of 0.82, so it was invisible.
  - CORICORI uses `albedo 2.2` (each surface capped at 0.9), `strength 2.5`, `ambient 0.4`, `spacing 20`, `rays 64`, `bounces 3`.
  - Result: warm bounce onto the stone block and the walls by the torch, and darker corners.
  - Josh's clean textures will be brighter, so re-tune albedo down when they land.
- **Josh's verdict (2026-10-09):** "an amazing upgrade ... the lighting just looks so much more natural".
- **Per-light `bounce` (default 1):** multiplies that light's colour in the bake only; the visible beam is untouched.
  - CORICORI's ceiling shaft has `bounce` 3. A narrow 6-degree beam carries little light, so at 1 it lit about 1% of surfaces.
  - A light from outside the room (shaft, no shadow) also seeds the flood fill at the first enclosed probe along its beam. Without that, a shaft-only bake failed with "no probe reaches a light".
  - My SurfaceStats takes the brighter face of each triangle, so it shows impossible values (>1) on underside faces at the beam's spot. Ignore those.
- **Dancing shadows (same day):** each flickering light's point wanders round its flame.
  - Room key `dance` = units; the default is 7 x flicker, so 2.45 for a torch.
  - The motion is two sine sways per axis plus the flicker noise, and it rises when the torch flares. Measured: about +/-2 units, at most 0.7 units per frame.
  - In Update-RoomLights the position is stored as l.Jx/Jy/Jz. The shadow cube views use the moved position (Watch-HostRender and Test-GpuLook) and cost nothing extra, because they are redrawn every frame anyway.
- **Rooms (2026-10-09):** CORICORI, SPAROOM (same settings, measured alike) and MINEMAZE (ambient 0.6, gentler: the torches reach only 31% of the mine).
  - WASHCORI has NO placed lights, so there is nothing to bounce. Its art is uniformly dark (bright level 21), so Find-PaintedLights candidates are weak. Josh to place lights first.
- **Water reflections get it too:** the room level is scaled in the reflection pass, and giAt runs at the un-mirrored point (x, 2*uMirY - y, z) with the normal's y flipped. uMirY = planeY, set after MainUniforms(flipV, true).
- **MINEHEAD (round 19, 2026-10-09):** Josh: "way too dark ... a more bright room compared to the caves", and asked for lighting based on the artwork. The changes:
  - Four soft lights (no torch art) over the ORIGINAL art's painted light pools (Find-PaintedLights), 110 above the main floor at y -40.8: #FFE2B8, power 0.85, range 340.
  - gi strength 1.8, ambient 0.85: the gentlest room cut of any room.
  - Thinner volume fog (0.0018, max 0.55, level 1.0), with the painted darkness kept but softened (0.01, max 0.55).
  - The first pass (pools at 1.3, strength 2.5) clipped the floor and pillars to white, so I measure the clipped fraction as well as the mean.
  - Measured mean brightness: under the grate 47 -> 92, main floor 27 -> 63. Previous file: tc-test\MINEHEAD.json.before-r19.
  - Multi-level rooms: Find-PaintedLights must probe from the main floor's own height, or it picks the shaft bottom.
- WASHCORI got its first light (Josh, WASHCORI/2: a torch at 20.63, -23.99, 34.96), so it now has gi too (ambient 0.6). The CORICORI inscription torch moved under the text (102.39, -34.29, -30.72; CORICORI/8-9).