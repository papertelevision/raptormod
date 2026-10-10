---
name: azrael-texture-holes-nocast
description: Room settings that act on textures BY NAME -- "holes" (cut a texture's bright painted art into real openings) and "noCast" (a texture casts no shadow); Tex.Leaf, CutHoles, RefreshMask. MINEHEAD grate light (Room Review MINEHEAD/1), 2026-10-09, not yet seen in game.
metadata:
  type: project
---

Josh (MINEHEAD/1): "cut this texture up so light can actually shine through it ... place a lightsource behind it that casts light through, being divided by the grid".

- **Texture names:** `Raster.Tex.Leaf` = the exported file name ("37-mineplab"), set by Add-AztRgb (LoadRoom.ps1).
  - The NUMBER in the file name is NOT the room's texture index: 37-mineplab is Texes[40] in MINEHEAD, and Texes[37] is an unrelated wall.
  - Texture i of a room unit is the PNG of the i-th material its OBJ uses.
- **`holes`:** `[{ texture, minLum, box: [x0, y0, x1, y1] }]`.
  - Implemented by `Tex.CutHoles(pal, minLum, box)`: index 0 where the ORIGINAL palette colour is >= minLum; IdxOrig is kept, and RestoreHoles puts it back.
  - Then `GpuRaster.RefreshMask(tex)` re-uploads the mask, which was uploaded once per texture.
  - Holes affect the picture, the shadow views (FS_DEPTH discards them) and the bounce bake.
- **`noCast`:** `[leaf, ...]` -> `Tex.NoCast`, which also drops the texture from the bounce bake.
- `Set-RoomTextureRules` runs first in Set-GpuAtmosphere. Textures are shared across rooms, so each room entry restores what its own file doesn't ask for. GiBake's signature includes the hole counts and the NoCast flags.
- **MINEHEAD layout:**
  - The grate is one big quad at y 153 (x -392..195, z 56..349). Its two panels are at x -51..72 and -263..-140, z ~229..328. V is FLIPPED when mapping texture rows to world.
  - The slab top (38-mineplat) is at y 166, with open space above it up to y 477.
  - The painted grid under the grate is a STEEP SLOPE (y -6..81 at z 281..318), not a floor.
- **The light:** a light straight down only GRAZED that slope (measured: no change). It now slants: (-95, 330, 150), dir (0, -0.888, 0.459), cone 32/42.
- **Debug method that worked:** A/B with the light's power 0, then shadow:false, then both textures noCast.- **Round 18 (Josh: "the light on the left is getting clipped"):**
  - The LEFT grate sits under the mine-head CRUSHER (part mh_smasher, texture 34-minesmas, x -247..-159, y 181..350) standing on the platform; it shadowed the whole left grid. Now `noCast`.
  - Also there: part `crushgrill`, a FLAT black plate 2 units under the left grate. The GPU never draws flat (TexIdx -1) triangles (GpuRaster Build skips ti < 0), so it doesn't block there. Raster.RayDistance and GiBake DO see flats, so CPU probes report it as a blocker -- don't be fooled.
  - The light moved to (-95, 440, 120), aimed (0, -0.876, 0.482), cone 34/40, power 1.7. Both grids now land inside the slope quad (x -391..193): left -350..-143, right -48..158.
  - MINEHEAD now has CORICORI's `volume` + `paint` (built from the ORIGINAL art), so 39-minewal1's painted darkness survives the clean texture.