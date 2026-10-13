---
name: azrael-josh-hires-textures
description: "Josh's own hi-res room textures (C:\\Games\\azrael-gfx\\decals\\<ROOM>\\updated) go into the true-colour override folder (4096; 2K tier in hires-2048) via Fit-RoomTextures; CORICORI done 2026-10-08. Layout and size rules. Twins (the same picture under other leaves) follow by themselves through the loader alias."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-11T14:17:13.294Z
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

**CORICORI FINAL set (2026-10-11, Josh: "my final textures ... the most high quality textures yet"):** 19 new files in `updated` (clean names, all 4096; 02-vstpap01 unchanged from 10-09, so skipped).
- Staged 18 (all but 01 and 02) in the scratchpad: `Fit-RoomTextures -Room CORICORI -Src <stage> -Size 4096 -Backup C:\Games\azrael-textures\hires-backup-coricori-20261011`.
  - Pass a NEW `-Backup`: the script only backs up a leaf that is not already in the backup folder, so the old folder would have let the 10-09 set be overwritten unsaved.
- Mostly "none needed"; six got tiny corrections (zoom 0.988-1.008, shift <= 0.4%).
- Flagged 0.71-0.73: 00-r12r5, 04-cor2wash, 07-ecrflra3. Outlines checked on the sheet; they line up, only interiors are redrawn.
- 01-corirock is 4096x2048 (2:1, as the original), copied straight with no fit.
- The GI bake signature samples the texture colours, so the room re-bakes by itself.
- Relief: the settled settings are the watcher defaults (ReliefSharpRooms '*', micro 0.4 @ 0.8, tint 3, opacity 0.5, mid 0.35, gain 1.6). Sharp maps are made at the texture's FULL size: CORICORI = 25 maps, 1.67 GB; 3.3 GB of a 10 GB budget.

**THE WHOLE GAME AT 4K: the scale (measured 2026-10-11, Josh plans to up-rez every texture):**
- Content: 76 real rooms (portals.json minus the hidden dev copies) hold 1,946 texture files = **1,090 distinct images** (MD5), plus character rigs. 620 images are shared by 2+ rooms (all 173 decal folders).
- Disk: about **5.6 GB** installed at 4096 on the long side (CORICORI masters average 6 MB), plus masters. The hires folder is 3.0 GB today.
- Card memory per room (colour + full-size sharp relief, with mips):
  - CORICORI 3.3 GB; average 2.4 GB; R22G 8.2 GB (56 textures); MODROOM1 7.1, DECK01 7.0, MINEHEAD 6.3.
  - At 2048: average 0.6 GB, at most 2.0 GB.
  - The budget is 10 GB on Josh's 8060S (48 GB shared memory), and RAM/8 (1.5-4 GB) elsewhere. Over budget used to mean ForgetTextures re-uploaded every frame; since 2026-10-12 the least recently used textures are evicted instead ([[azrael-room-cover]]).
- Room entry: CORICORI's 20 4K PNG decodes took **2.7 s** (watch.log 01:36), against ~20 ms before. The biggest rooms would take ~7 s (ORRERY took 6.6 s on 2026-10-12, and Josh saw the 8-bit view the whole time). Decoding is now parallel, under a loading cover: [[azrael-room-cover]].
- CPU copies: ~85 MB per 4K texture (int[] + mips), kept in `$script:AztUnitMem` for the session. Each room visited adds 1-4 GB; since 2026-10-12 this is capped by -TextureCacheGB (Limit-AztRgbCache, [[azrael-room-cover]]).
- Drawing cost barely changes (mipmapped); the costs are memory and loading.
- Before a game-wide push: fit-to-memory resolution (or GPU compression), fast/background loading, eviction; size tiers (4096 for big/close surfaces, 2048 for the rest).

**THE GOAL: TEXTURE QUALITY Normal / Ultra (Josh, 2026-10-11).** A title-menu setting: Normal loads 2K textures, Ultra loads 4K.
- Josh is re-rendering every texture himself first; 4K art goes to other rooms only as he delivers it.
- Plumbing built:
  - `Add-AztRgb -MaxSize` (LoadRoom.ps1): a replacement larger than MaxSize is read from a scaled copy in `<OverrideDir>-<MaxSize>` (`C:\Games\azrael-textures\hires-2048`), made once and remade when the master is newer (`Get-AztSizedOverride`, PNG header size via `Get-AztPngSize`). The RgbDir key includes the size.
  - Watcher `-TextureQuality Normal|Ultra`, else `<GameDir>\raptormod-settings.json` "textureQuality", else **Ultra** (today's look while the menu says coming soon). `$script:texMax` 2048 / 0; logged as "texture quality: ...". Test-GpuLook has `-TextureQuality`.
- MEASURED on CORICORI:
  - Normal: 20 at 2048, 848 MB on the card, room load 1.0 s. The FIRST Normal load took 9.0 s, making the 20 copies (41 MB).
  - Ultra: 20 at 4096, 3.3 GB, 3.1 s.
  - Pre-make the copies offline before Normal ships, or the first entry of each room stalls.

**ALL DOORS for Josh to up-rez (2026-10-11):** `Desktop\all doors`, 42 originals plus `_where these go.txt` (file -> every room: leaf it replaces).
- Chosen from the decals as textures NAMED door/dor, deduplicated by MD5. spadoor alone is 11 rooms' leaves.
- Left out (named "dor" but not door panels): ecrdor01 / ecrdor02 (CORICORI's door walls and inscription), dorcor, dotopdor, dowaldor, cha_ddor, clfdoor.
- CORICORI's own door panel `20-spadoor` is NOT in decals\CORICORI, and it is a different picture from the shared spadoor. It was taken from C:\Games\azrael-render as `spadoor-coricori.png`.
- To install the up-rez: each file name -> its leaves from the txt; Fit-RoomTextures per room, or copy to every leaf of a shared image.

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

**MINEMAZE 4K set (2026-10-11, Josh: "added new textures for MineMaze ... in a 2k-4k folder ... add the 4k textures ... the 2k can come later and are labeled 2k").**
- Source `C:\Games\azrael-gfx\decals\MINEMAZE\4k-2k`: 22 at 4096 on the long side (01, 02, 04-23; 00-n_black and 03-baptapce not redone) plus `_2k` twins (left for the Normal tier; the plumbing makes its own 2048 copies until then). All match the originals' aspects (square, 128x256, 256x128).
- **NAMES:** the decals call two of them `11-mmzgun#` / `14-mmzamul#`, but the MTL leaves (and the hires files) are `11-mmzgun_key` / `14-mmzamul_key` -- the exporter turns `#` into `_key`. Fit-RoomTextures' `^\d\d-[A-Za-z0-9_]+` stops at `#`, so stage renamed copies.
- **18 through Fit-RoomTextures** (-Size 4096, -Backup `hires-backup-minemaze-20261011`): mostly "none needed", tiny fixes on 12/13/16/19/20 (zoom 0.978-1.004, shift <= 1.8%). Flagged 07/09/16/18/21/22 (0.35-0.74) checked on the sheet: the outlines line up; interiors are redrawn.
- **04-ent_rope and 05-minelad1 WITHOUT the fit** (copied as delivered, 2048x4096 / 4096x2048): the fit wanted 0.80 x / 0.85 y squeezes chasing the painted light falloff (the MINEHEAD-39 failure) while the outlines already lined up. Note Fit-RoomTextures sizes by WIDTH (`H = Size*oh/ow`): a PORTRAIT texture at -Size 4096 would come out 4096x8192 -- don't run portraits through it at 4096.
- **KEYED textures (11, 14): new `tools\Fill-KeyedTexture.ps1`.** The renderer cuts holes from the ORIGINAL's index-0 mask (GpuRaster uMask, nearest, 256 px) while the 4K colour is filtered and mipmapped, so any magenta in the art bleeds pink at the cut. AI art has no exact #FF00FF (~80-90% near-magenta, pink/purple edge blends, and a magenta CAST on the object itself). What works: keep the art inside the original's SOLID area (despilled: red and blue above green taken off both), replace bright magenta there and EVERYTHING in the original's holes with the nearest kept colour (multi-source flood). Two failed first: keying only bright magenta (purple edge blends flooded the background), and keying magenta of any brightness everywhere (ate the gun's dark purple-cast stock).
- Shared leaves picked up the new art too (same original file): 06-all2chab -> WASHCORI; 08-or_tunnl -> AQUADUCT, FIGHT_R, SPAROOM, STAIRS2, STAIRS3.
- Offline render (Test-GpuLook -Room MINEMAZE -TextureQuality Ultra): loads clean.
- **Josh in game: "the stairs texture is only showing half the texture ... make sure all textures are accounted for".** The plank walkway is part `ramp1` (texture `05-minelad1`). Its UVs sample only a STRIP: u 0.367..1, rows 3.2-31.3% from the top. The original's slats fill exactly that strip (rows 4..38 of 128); the new art drew its planks in rows 2.3-15.3% (48..312 of 2048) with a smooth smeared band below. The ramp lays the strip across its width, so one half showed planks and the other a plain ramp.
  - FIX: the plank rows 48..312 stretched (vertically, along the board grain) onto rows 64..623, black elsewhere, as in the original.
  - The rope (`04-ent_rope`, part `chain`) was the same width as the original but 4.5% to the right (column-profile correlation: 23/512): moved 92 px left, black in the gap. Correlation 0.39 -> 0.53.
- **NEW `tools\Test-TextureCoverage.ps1 -Room R`:** per texture, the UV triangles that use it are drawn into a mask, and inside it the original and the installed art are compared: correlation, edge energy (DETAIL MISSING < 0.7), and 8x8 cells where the original has detail and the new art is smooth ("SMOOTH IN n%"). On the delivered ramp it said smooth in 24%; after the fix it is clean. `-Only a,b -Sheet x.png` draws the flagged cells.
  - MINEMAZE remaining flags checked and fine: 11-mmzgun_key (its outline matches the original's to 0.002; the metal is just darker and smoother) and 16-mmzsupp (cells near-black in both, mean 1-7: dither noise).
  - Run it after every room install, before Josh plays it.
- **Josh's own 2K set installed (same day, "fix for the 2k textures too")** into `C:\Games\azrael-textures\hires-2048` (the Normal tier's folder; backup folder `hires-2048-backup-minemaze-20261011`, empty: nothing was there).
  - The 22 `_2k` files are exact halves of the 4K ones.
  - 18 went through Fit-RoomTextures -Size 2048 -Dst hires-2048 (the same tiny fixes as at 4K).
  - The rope and the walkway were RE-MEASURED on the 2K files: rope 23/512 again (46 px); planks rows 24..156 of 1024, stretched onto 32..311.
  - Keyed 11/14 went through Fill-KeyedTexture.
  - Test-TextureCoverage -Hires hires-2048 gives the same values and flags as 4K.
- **HOW NORMAL USES THEM:** Get-AztSizedOverride takes a hires-2048 file as long as it is NEWER than its 4K master; otherwise it makes its own copy from the master.
  - So **re-installing a 4K master later replaces that leaf's 2K with an automatic copy** -- redo the 2K after.
  - A Normal render (Test-GpuLook -TextureQuality Normal) rewrote no hires-2048 file: it used Josh's.
  - 00-n_black (512) and 03-baptapce (1024) are at or under 2048, so Normal reads them from hires directly.

**Fit-RoomTextures changes (2026-10-12, for the opening rooms' batch):**
- `-Size` is now the LONG side. It was the width, so a 128x256 original came out 4096x8192; portraits can go through the fit now.
- `-MaxFix 0.08` REFUSES a big correction: zoom beyond 8%, or a shift beyond 4%. The picture is installed as delivered and flagged "big fix refused" (the MINEHEAD-39 / MINEMAZE rope failure, automated). 0 = no limit.
- `-Report x.csv` writes the result table.
- Josh's `4k-2k` folders: `NN-name.png` (4096 long side) plus `NN-name_2k.png` (exact halves). Fit skips the `_2k` twins by itself (their leaf is not in the MTL). Stage `#` -> `_key` copies.

**THE OPENING ROOMS (2026-10-12, Josh's `4k-2k` folders):** WASHLOCK, WASHCORI, SPAROOM, MINEHEAD, BAPTIST, WELLROOM, ORRERY and the LURKA / RAPTOR characters (MINEMAZE was done 10-11).
- **How:** scratchpad `tex-install-1012.ps1 -Tier 4k|2k [-Only rooms]`, rooms in play order (an earlier room wins a shared leaf).
  - For each room: stage (`#` -> `_key`, skip list), then `Fit-RoomTextures -Size 4096|2048 -MaxFix 0.08 -Report <room>.csv -Sheet`, then Fill-KeyedTexture for `#` decals.
  - Backups: `hires-backup-<room>-20261012` / `hires-2048-backup-<room>-20261012`.
  - 4K first, then 2K, so every 2K file is newer than its master and Normal uses it.
- **Leaves in each room (number that needed a fix):**

  | Room | Leaves | Fixed |
  |---|---|---|
  | WASHLOCK | 12 | 4 |
  | WASHCORI | 24 | 10 |
  | SPAROOM | 17 | 6 |
  | MINEHEAD | 48 | 23 |
  | BAPTIST | 30 | 11 |
  | WELLROOM | 27 | 5 |
  | ORRERY | 30 | 9 |
  | LURKA | 5 | 0 |
  | RAPTOR | 12 | 12 |

  The flagged ones were checked on the sheets: the outlines line up and the interiors are redrawn. 2K gives the same fixes.
- **KEYED = `#` in the DECAL's name, not a leaf ending `_key`:**
  - 16-mine_key and 05-wel_key are pictures of keys. The first run filled them; they were restored.
  - 04-#brkkey's leaf is `04-_keybrkkey`.
- **Kept the PREVIOUS version (redraws asked of Josh):**
  - MINEHEAD 04-#brkkey and 07-mineton#: a strong magenta CAST on the objects (gold key pieces mauve, tongs purple).
  - MINEHEAD 20-minemc02: malformed, the panel squeezed into the left 40%.
  - Their 10-05 files are back in hires; they are 2048 or smaller, so Normal reads them as they are.
- **MINEHEAD 06-minecha_key (the chain):** aligned by hand on the original's mask at both sizes (scratchpad `align-chain.ps1`); the fit failed on it.
- **Shared leaves:**
  - Kept from approved rooms: CORICORI's 11-or_tunnl, MINEMAZE's 08-or_tunnl and 06-all2chab.
  - Delivered twice with different art: 05-all2cori from WASHCORI (not SPAROOM's) and 00-blood2_key from LURKA (not RAPTOR's).
- **Characters' other models**, found by the MD5 of the original, get the installed result copied to their leaves:
  - LURKA's l_bod -> the CL-* models' 02-l_bod and FIGHT's 07-l_bod;
  - RAPTOR's 12 -> the AMRAP copies;
  - the blood -> six characters' blood2_key.
- **Checks:**
  - scratchpad `check-2k.ps1`: in every room, every leaf over 2048 has Josh's 2K, newer than its master, at the master's aspect.
  - Test-TextureCoverage at 2K == at 4K. WASHCORI is clean (04-n_black is black by design). ORRERY flags tun_flor / tun_wal1 / tun_top / or_panel (smooth in 10-34%), or_texs2 (4% sampled) and or_flord (smooth in 71%), identically at 4K, which Josh has seen in game ("These textures look great").
- **What it cost on entry:** ORRERY's 32 4K textures took 6.6 s to decode, and Josh saw the 8-bit view all that time. The fix is [[azrael-room-cover]].
- **SPAROOM's big pipe looked like a ROPE (Josh in game, 2026-10-12).**
  - **Cause:** not a wrong texture. The pipe (PIPE = `09-spacop01`, parts spapipe01 / spipe1) repeats it ~22 times down its length, slanted (u drifts 0.57 per face). The art has dark bands along its top (0-16%) and bottom (80-100%), and on every repeat they line up into a spiral of dark grooves.
  - The original game maps it the same way; at 256 px it was too soft to read as rope.
  - **Fix:** a SEAMLESS version of Josh's art (scratchpad `pipe-seamless.ps1` + `SeamTex.cs`):
    - rows 17-80% kept, stretched back to 4096;
    - made seamless one axis at a time (a 20% cross-fade into itself shifted by half along that axis; doing both axes at once leaves steps mid-edge);
    - tone x0.91;
    - plus a box-halved 2K copy, written after the 4K so Normal uses it.
  - The texture is used only by SPAROOM (also by its WHEEL); the dev copies use 02-spacop01.
  - Backups: `hires-backup-sparoom-pipe-20261012` / `hires-2048-backup-sparoom-pipe-20261012`.
  - Test-TextureCoverage will now flag 09 (the bands are gone on purpose).
  - **Watch for the same thing** on any texture with dark edges that a model repeats many times.

**SHARED PICTURES FOLLOW BY THEMSELVES (2026-10-12, loader alias -- [[azrael-texture-repair]] "Shared art out of step").** One original is exported under several leaves (other rooms, later-story variants, other character models). Installing art for ONE leaf is now enough:
- every other leaf of the same picture whose own hires file is still the old 4x upscale loads the new art at run time (`tools\TexTwins.cs` via LoadRoom `Get-AztTwinArt`), 2K copies and companion maps included. Nothing is copied, so the hires folder stays one file per picture delivered.
- So the old habit of copying an installed result to the twin leaves (LURKA's l_bod -> CL-* / FIGHT, RAPTOR -> AMRAP, blood -> six characters) is no longer needed for leaves on the upscale. It still matters only when a twin should show DIFFERENT art: give that leaf its own file (anything not exactly 4x the original counts as new art and is never overridden).
- Install redraws at 4096 (Fit-RoomTextures -Size 4096). A redraw at exactly 4x its original (a 512 original at 2048) would read as an old upscale and could be swapped for a twin's art.
- Fit-RoomTextures now prints which other leaves will show what it installed ("the same pictures elsewhere ... now show this art").
- First run (2026-10-12): 342 leaves in 68 real rooms. The most changed: HINEAZF 40 (MINEHEAD's art), MINEHED2 31 (MINEHEAD), WELLDEMO 24 (WELLROOM), R8 23 (BAPTIST), ORERYL5 22 (ORRERY), R1 19 (CORICORI), R22G 17 (MINEHEAD), R7 13 (WELLROOM), SPAROOM3 / OLDSPA / SPAROOMX 11 each (SPAROOM, so the rope pipe is gone there too), MAZENEW 9 (MINEMAZE). In the opening rooms only two textures changed: MINEMAZE 03-baptapce (BAPTIST's) and CORICORI's door panel 20-spadoor, which is byte for byte SPAROOM's 13-spadoor and shows its new art.