---
name: azrael-art-light
description: "Light from the artwork (GPU): the ORIGINAL art's painted light/shade per texel shades the room level + bounce (room key artLight); painted darkness has its own colour (volume.paint.color). MINEHEAD round 20, 2026-10-09, not yet seen in game."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-09T18:14:41.854Z
---

Built 2026-10-09 for Josh's Room Review notes MINEHEAD/2-4. His asks were "hard shading from the panel above (see original artwork)", "only the corners and edges use the very dark lighting", and beige fog.

- **How it works.** `GpuRaster.BuildArtLight` reads each texture's ORIGINAL indices (IdxOrig ?? Idx) through the palette as brightness, whatever hi-res art is loaded.
  - Filtering: an opening of radius `open` (removes painted light grids and glints), a closing of radius `close` (removes cracks), then a box blur of radius `blur`.
  - Scaling: the value is divided by the room's `percentile` brightness, raised to `gamma`, and kept between `floor` and 1.
  - The result goes into `Tex.ArtLight`. The card holds it as the hole mask's SECOND channel (the mask is RG8 now; `MaskBytes`). DrawSet re-uploads the mask whenever `ArtLight` or `Idx` changes reference.
- **Shader.** `artAt(st)` is a manual bilinear lookup with texelFetch, because the mask is NEAREST. It multiplies `roomK` and both `giAt` terms. The placed lights and the lamp are untouched.
  - `uRoomTint` colours only the room-level part (`roomPart`).
- **Room key `artLight`:** `{floor, gamma, open, close, blur, percentile, exclude[], tint: "#hex" | "art"}`.
  - `"art"` uses `ArtTint`: the mean colour of the well-lit texels, normalised so its brightest channel is 255. The raw mean (`ArtBrightColor`) used as a multiplier darkened everything.
  - Watcher switch: `-NoArtLight`. Shared Tex objects are cleared on every room entry (`ClearArtLight`).
- **`volume.paint.color`** (default black): the compose shares the hidden part between the fog's colour and the paint's colour, each by its own opacity. With both black it is identical to before.
- **MINEHEAD round 20 settings:**
  - artLight `floor 0.12, gamma 0.7, open 4, close 2, blur 1, percentile 0.85, tint art`. Well-lit level 50/255; colour #806F66, giving the tint #FFDECC.
  - Fog `#806F66`, paint black. The middle pool light at (-3, 160) was removed.
  - Backup: `tc-test\MINEHEAD.json.before-r20`.
- **Round 21 (same day), Josh:** "we don't need the beige fog. We only need the dark fog/mist in those corners and this room should be set."
  - `volume.density` is now 0 and the colour #000000, so only the black painted darkness remains.
  - `"drips": null` and `"mist": null` override the cave/misty class defaults; a room file's null removes a class key.
  - Floating specks: `lights[0].dust {count 220, size 0.8}` in the grate light, plus the cave-class dust motes. The fill tint (#FFDECC) stays.
  - MINEHEAD is SET: don't revisit it unasked. Backup: `tc-test\MINEHEAD.json.before-r21`.
- **Test-GpuLook prints "0 motes" for every room.** It reads LastMotes after its timing re-draws, which have none. That is not a bug in the room.

Related: [[azrael-baked-gi]], [[azrael-painted-darkness-props]], [[azrael-texture-holes-nocast]], [[azrael-volumetric-fog]].
