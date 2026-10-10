---
name: azrael-josh-hires-textures
description: "Josh's own hi-res room textures (C:\\Games\\azrael-gfx\\decals\\<ROOM>\\updated) go into the true-colour override folder at 2048 via an install script; CORICORI done 2026-10-08. Layout and size rules."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-10T03:49:22.589Z
---

Josh (2026-10-08): "very high resolution textures for the first room ... labeled the same as the current ones ... replace those in the game ... with the same normal mapping applied."

- **Where they go:** `C:\Games\azrael-textures\hires\<leaf>.png` (Watch-HostRender `-TexOverrideDir`, true colour only). The leaf is the texture's exported name (`00-r12r5.png`); Josh's files carry copy suffixes like `(3)`, so match on `^\d\d-name`. Add-AztRgb loads the override at any size.
  - The ORIGINAL still decides the holes, so a replacement must keep the original's layout.
  - Relief maps are built on the card from whatever colour texture loads, so "the same normal mapping" applies with no extra step.
- **NOW 4096 (Josh: "they still feel blurry ... are they being downsampled?"):**
  - Measured on a close inscription view: 4096 is +17% detail over 2048, so the "2048 is enough" claim was WRONG for close-ups.
  - GpuRaster.MaxTextureBytes is now `DefaultTextureBudget()` = RAM/8, clamped 1.5..4 GB (4 GB on Josh's machine). CORICORI with nine 4096 textures: 29 ms a frame at 4K, no thrash.
  - Fit-RoomTextures takes `-Size 4096`.
- **THE BIGGER BLUR IS -TcMaxPixels:**
  - Josh plays at 4K: the view is 3842x2072, but the picture is capped at 3.2 M px, so it is drawn at 2436x1314 and stretched 1.58x.
  - Measured on the CORICORI room view:
    - 3.2 M px: 13.9 ms
    - 5.5 M px: 22.6 ms
    - 8.0 M px: 32.5 ms (card 23.8)
  - The game runs ~22-24 fps (~42 ms a frame).
  - Raising the cap is Josh's call (fps): offered 2026-10-08.
- **(Superseded) size 2048, not 4096:** the card budget is MaxTextureBytes 1.5 GB (GpuRaster). Eight 4096² textures plus relief maps would cross it, so ForgetTextures would re-upload every frame. 2048 is already 8x the 256 originals. Josh's 4096 files stay as the masters.
- **Shape mismatch:** `02-vstpap01` came as a 2:1 crop of a 128² original (a scroll on black). Its content box (non-black) was fitted onto the original's content box in a black 2048 square.
- **Script:** session scratchpad `Install-CoriTextures.ps1` (-Src/-Dst/-Orig/-Size/-Sheet). It backs up the replaced hires files to `C:\Games\azrael-textures\hires-backup-20261008-coricori` and writes an original|new check sheet. Copy it into tools if this becomes a habit.
- **ALIGNMENT IS THE REAL PROBLEM (Josh: "some of the textures aren't lining up"):** ChatGPT redraws zoom in 8-18% and shift up to 9%. The fix is `tools\Fit-RoomTextures.ps1 -Room R` (+ `tools\TexFit.cs`):
  - It measures zoom and shift by edge NCC against the original (128 coarse, 256 refined) and warps the image back. The uncovered border fills from the previous aligned replacement (`-Backup`).
  - It scores the result (flag under 0.75 at 256) and writes a check sheet with the original's outlines in red.
  - It can only fix a whole-image zoom or shift. Details redrawn in different places inside the picture (00-r12r5, a painted corridor view) need a redraw.
  - CORICORI after the fit: 10 0.48->0.85, 12 0.53->0.84, 03 0.45->0.75, 01 0.42->0.63, 09 0.56->0.75.
- **Unplaced:** "Ominous Storm Cloudscape in Deep Blue (2).png" (1774x887) has no texture name, so it was skipped. Asked Josh where it goes.
- Not the same thing as [[azrael-texture-remaster-verdict]] (AI/upscaled originals rejected): this is Josh's own art, per room, on request.

**Clean (unlit) textures, CORICORI (2026-10-09):** Josh will re-render the room's textures with ChatGPT WITHOUT the painted lighting, then light them for real. The project instructions are in C:\Games\azrael-gfx\decals\CORICORI\ChatGPT-project-instructions.md.
- MEASURED: no CORICORI texture has a single palette-0 pixel, so ALL their black is painted lighting, not holes.
- The floor/ceiling/wall textures are fixed-camera RENDERS: a lit, perspective-drawn patch of surface fading to black. The new art must therefore keep the perspective and the positions, and be filled edge to edge.
- Real dark features to keep: the ceiling hole in 05-ecrflr05 (the light shafts) and the black around the 02 scroll. The 11-or_tunnl atlas keeps its panel gaps.
- The darkness map now comes from the ORIGINAL pixels (see [[azrael-painted-darkness-props]]), so the fog darkness survives the clean art.
- 2026-10-09: second CORICORI batch installed at 4096 via Fit-RoomTextures (05, 06, 07, 08, 10, 13, 14 new; 14 textures in all). 01-corirock is no longer in his folder; the earlier install stays. Outlines line up; the scores 0.67-0.75 come from stones redrawn inside the shapes.

**CORICORI full 4K set (2026-10-10, Josh's `updated` folder):** all 20 leaves installed at 4096.
- Staging first: strip copy suffixes (`_2`, `_3`, `_4` -> the MTL leaf; Fit-RoomTextures' `^\d\d-[A-Za-z0-9_]+` KEEPS `_N`, so it would not match) and drop the older `05-ecrflr05(3)`.
- 19 went through the fit: most "none needed", 12-ecrdor02 zoom 1.11 lined up.
- **01-corirock went in WITHOUT a fit**: centre crop to 2:1, then 4096x2048. The fit wanted a 0.80 vertical squash (the original's lit part only), the MINEHEAD-39 failure.
- Backup: hires-backup-coricori.

**LURKA (Room Review LURKA/1, 2026-10-09): the ChatGPT character textures installed at 2048.**
- Source: `AztMod\design\incoming\lurka\1-l_bod.png`.. (1254x1254, named without the leading 0). They replace the 10/5 ESRGAN upscales.
- Fit-RoomTextures works for a CHARACTER given a scratch `-Orig` folder holding a one-off `LURKA.mtl` plus the originals from `decals\LURKA`, and a `-Src` of renamed copies (`01-l_bod.png` ...).
- Zoom 1.12-1.34. Silhouettes line up; the scores (head 0.88, others 0.5-0.6) are low only because interiors are redrawn.
- **Shared texture:** l_bod is the same image as the CL-* models' `02-l_bod` and FIGHT's `07-l_bod`, so the fitted body was copied to those leaves too. Find sharing by hashing `decals\*\*<name>.png`.
- Backup: `C:\Games\azrael-textures\hires-backup-lurka`.
- **REVERTED (round 22, Josh: "this isn't working, revert"):** the fill smeared flat skin/beige over the back panels. The fitted unfilled textures are installed again and `TwoSidedMoves = false`. The filled set is kept in `hires-backup-lurka-filled`. Don't retry the push-pull fill on characters.
- **(Reverted) "Missing polygons" (LURKA/1 follow-up) = PAINTED BLACK, not holes:** 182 of 440 triangles map onto black in the original art (wrists, ankles, limb insides, skirt backs). Filled with push-pull from the surrounding art (scratchpad `fill-black.ps1`: big or edge-touching dark regions only). The fitted, unfilled versions are in `hires-backup-lurka-fitted`.
- The real joint seams are small: rigid parts 0.3-0.7 units apart at rest in a ~48-unit model. Closing them needs skin bridges that follow the pose; that was offered as a separate task, not done.
- **Skirt (LURKA/2):** GpuRaster `TwoSidedMoves` draws all character (Moves) textures without back-face culling.

**MINEHEAD next (2026-10-09):** `C:\Games\azrael-gfx\decals\MINEHEAD\updated` was created for Josh's clean re-renders (48 originals sit beside it). Its ChatGPT-project-instructions.md is written for this room:
- keep the original's aspect ratio at 4096 on the long side (sizes vary: 256x128, 128x256, 512x128...);
- MAGENTA cut-outs stay pure #FF00FF (04, 06, 07);
- the grate set must NOT paint the light the engine now makes: 37-mineplab cells (holes are cut from the ORIGINAL, so the new art there doesn't matter), 38-mineplat's light shafts, and 39-minewal1's painted grid (it IS the slope under the grate);
- also 36-minemw01, and the painted shadows on 19-m_floor / 41-mineflor.
- Install the same way as CORICORI: Fit-RoomTextures -Room MINEHEAD -Size 4096 once Josh says the files are in.- **MINEHEAD 39-minewal1 (2026-10-09, 1672x941, "not 4k but that's ok"):** Fit-RoomTextures FAILED on it and must not be used for textures like this. The original's only strong edges were the painted grid and its black falloff, exactly what the clean version removes, so the fit invented a 14% shift (score 0.19).
  - For a plain edge-to-edge surface with no layout features left, install WITHOUT a fit: centre-crop to the original's aspect, then scale (here 2048x1024).
  - The previous replacement is in hires-backup-minehead.