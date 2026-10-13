---
name: azrael-texture-repair
description: "Phase 3 of Josh's texture plan (2026-10-12): Test-TextureTiling.ps1 audit (repeats, dark edges/seams, stretched, smeared, garbage UVs, -Twins = shared art) + the card's TEXTURE REPAIR (GpuRaster.SetRelay): faces folded over an edge from an intact neighbour, stretched runs evened, clean repeats mixed. F11 / -NoRepair / room 'repair' block. Rules that keep it seam-free. Shared art FIXED by a loader alias (TexTwins.cs): old-upscale leaves show a twin's new art."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-12T21:00:00.000Z
---

Phase 3 of [[azrael-materials]] (Josh's items 7, 8, 9). **BUILT 2026-10-12. Josh in game, after the save-rock fix: "It looks good, what's the next step?" -> phase 4 (depth).**

## The audit: `tools\Test-TextureTiling.ps1` (+ `tools\TexAudit.cs`)
Reads every room's OBJ/MTL in `C:\Games\azrael-render` (86 rooms in ~3 s), per texture use:
- REPEATS xN (a face's UV span), DARK EDGES / SEAM (the art in use, hires or original: edge bands < 0.6 of the middle, opposite edges > 0.35 apart), STRETCHED (one way > 4x the texels/unit of the other), SMEARED (UVs in a line), BAD UV.
- **Cut-out art is not flagged for edges** (over 30% near black: ropes, chains, bubbles on their holes -- they are meant to repeat).
- `-Sheet` tiles each flagged texture 2x2; `-Out` CSV.
- `-Twins` (+ `-TwinsOut`): **shared art out of step** -- see below.

**The 1996 files hold garbage UVs** (-1.7e38: CHAPEL 25-cha_alta 40 faces, INTER2, MINEHED2, HINEAZF, PULPIT3, MINEHEAD n_black). Those faces show one texel. Left alone (no idea what was meant); listed.

**Art findings (2026-10-12):** 02-spacop01 in OLDSPA/SPAROOM3/SPAROOMX is the SAME original as SPAROOM's 09-spacop01 (the rope pipe) but its hires copy is the old upscale with the bands (now shows 09's seamless art through the loader alias below); 02/00-gi_gold (GIBBIT5 x30, GIBBIT7); lr_chut1 (LIGHT, DECISION x5); 16-edashen (EDCRTSIM); 05-mineramp (MINEHEAD, planks: probably meant).

**Shared art out of step -- FIXED 2026-10-12 by a LOADER ALIAS (`tools\TexTwins.cs`), not by copying.** The exporter writes one PNG per unit that holds a picture, so the same original appears under several leaves (03-baptapce in MINEMAZE == 00-baptapce in BAPTIST, byte for byte), and LoadRoom took `hires\<leaf>.png` by name. New art made for one leaf left its twins on the ESRGAN upscale: 382 copies in 93 rooms (4.1 GB of new art behind them).
- **How:** `Add-AztRgb` asks `Get-AztTwinArt` (LoadRoom.ps1) for leaf -> twin leaf and loads `hires\<twin>.png` instead. Companion maps (`<twin>_rough/_height/_glow`) and the Normal tier's 2K copy (`Get-AztSizedOverride` on the twin's master = Josh's `hires-2048\<twin>.png`) follow because they hang off the same name. `Tex.Leaf` stays the texture's OWN leaf (room settings and materials name it).
- **Rules (TexTwins.cs header):**
  - twins = originals in `C:\Games\azrael-render` with the same MD5;
  - **old upscale = exactly 4x the original both ways** (every Real-ESRGAN file is; none of Josh's: 2,153 vs 273 measured, his are 8-64x at 4096). A redraw installed at exactly 4x (a 512 original at 2048) would read as an upscale: install redraws at 4096;
  - a leaf with new art of its own keeps it (per-room redraws are never overridden);
  - several twins with new art: the one in the room with the most original pictures in common with this leaf's room, then the newer file (SPAROOM3/OLDSPA/SPAROOMX take SPAROOM's, HINEAZF/MINEHED2 MINEHEAD's, ORERYL5 ORRERY's, WELLDEMO/R7 WELLROOM's, R8 BAPTIST's, R1 CORICORI's);
  - not for a flat single-colour picture (41 leaves, the n_black family): nothing to show, and a 4096 square of black is ~85 MB.
- **Index:** `C:\Games\azrael-render\texture-twins-hires.tsv` (one per art folder): a stamp of the originals, the .mtl files and the art folder AS LISTED (count, sizes, times), the originals' MD5/sizes, the art sizes, the decisions. Checked on every Add-AztRgb that has textures to decode: **~5 ms**; rebuilt only when a folder changed, re-reading only changed files (all 2,426: 0.6 s). The watcher compiles TexTwins.cs in its main batch; elsewhere LoadRoom compiles it on first use (~0.2 s).
- **Result (2026-10-12): 342 leaves in 82 units (68 real rooms + 14 dev/test copies) show a twin's new art; 0 left out of step.** The old 3x-size rule had missed one: R8's 21-bapfont2 (BAPTIST's 22-bapfont2 is only 2.6x its bytes). CORICORI's door panel 20-spadoor is the same export as SPAROOM's 13-spadoor and now shows its new art.
- **Cost:** room entry time is the art itself (4K decodes instead of 1K: R1 0.23 -> 0.78 s, SPAROOM3 0.09 -> 0.52 s Ultra; Normal 0.12 -> 0.31 s), and memory (R1 colour 0.2 -> 1.7 GB on the CPU side at Ultra). The lookup is 5 ms; units (.unit cache) untouched. No 2K copies need making: every twin target has Josh's 2K, newer than its master.
- **Tools:** `Test-TextureTiling -Twins [-TwinsOut x.csv]` lists the loader's choices and cross-checks by the old rule (copies still out of step: expect 0). `Fit-RoomTextures` (into hires) lists the other leaves that will now show the art it installed, and rebuilds the index. Test-GpuLook prints the watcher's REPLACEMENT ART line ("..., the new art of <twin>").

## The repair: `GpuRaster.SetRelay` (once per room entry, and after the character rebuild)
Per triangle, from the room's own geometry and the ORIGINAL art (Idx + palette). Build swaps the coordinates in; vertex format is now VSTRIDE 15: + ping-pong range (loc 4, vec4 lo u/v, size u/v) + flags (loc 5: 1/2 ping-pong u/v, 4/8 mix u/v, 16 re-laid, 32 evened). VS_DEPTH/FS_DEPTH fold too (holes in the shadow views).
1. **FOLDED** (SMEAR or STRETCH): takes an intact same-texture neighbour's mapping, mirrored back across the shared edge (s along the edge, h = distance from it laid into the neighbour), ping-ponged inside the neighbour's UV box. Flat (|dot| >= .95) neighbours carry the same fold on.
2. **EVENED** (STRETCH runs): coordinates scaled about the run's area-weighted UV centre by exp(mean log anisotropy) on the stretched axis (cap 64): continuous across a curved run (a pipe's facets). Ping-pong inside the run's UV box unless it spans >= .98.
2b. **BOXED (whole object; Josh in game 2026-10-12: CORICORI's big save-point rock, part `save` / 01-corirock, "one of the more obvious smearing textures")**: a SOLID object of one texture (connected faces, >= 75% of edge-uses shared by two of its own faces -- `RelayBoxClosed`) that is stretched ON THE WHOLE (area-weighted |log anisotropy| >= log 1.8, a smear counting as 8x -- `RelayBoxAniso`) with >= 2 badly stretched/smeared faces, not keyed: every face re-laid from the world, box mapping (each face along its main axis; tops x/z, sides z/y or x/y, the art's top up), at the object's intact-face median texel density (else the room's), centred on its UV centre, ping-ponged inside its UV box. Flag 64 (debug magenta).
   - **The rock's worst face is NOT stretched** (anisotropy ~1-3 per face): the new 4K corirock art is streaky in the patches it samples. Only re-laying every face fixed it -- a version keeping faces under 1.5x brought the streaks back.
   - **Picture faces keep their laying** (intact, <= 1.5x, UV box >= 0.25 both ways: a chest's front); a rock's faces each sample a small patch.
   - **Open sheets are never boxed** (the closed test): MINEMAZE's cave walls got boxed by the first version and lost the torch glow painted into their art next to the torch.
   - Counts (played rooms): CORICORI 72 (the save rocks), WASHCORI 75, MINEMAZE 38, MINEHEAD 136, SPAROOM/BAPTIST/ORRERY/WELLROOM 0. Box mapping shows faint joins where faces change axis -- far less than the streaks.
   - Water material is left out of all of it (the modern water's look).
3. **MIXED**: surfaces (connected, same texture, intact or evened) whose UVs run >= 1.5 tiles one way: two shifted samples (8 shifts from pcg3d, picked by slow gradient noise over st x 0.6) blended (smoothstep .3-.7, biased by the colour difference) -- colour, relief map and companion maps; only along the repeating axis.

**Rules that came from offline checks (keep them):**
- **Fold only round a corner** (|dot| <= 0.9) **and only a face no deeper than its source** (depth from the edge <= the neighbour's x1.05): on MINEMAZE's big stretched chevron wall, mirroring the neighbour onto a big face opened a hard seam where two folds met.
- **Never change a face flush with an intact face of its texture** (shares an edge, |dot| > 0.9): the shared edge would seam. Same test decides whether an evened run "touches" -- round a corner (a pipe's end cap) is fine.
- **Mix only art that tiles cleanly that way** (TilesClean: no dark edge band, edges within 35%) and **never keyed art** (> 0.5% index 0) or folded faces: shifting a texture with dark bands scatters the bands (MINEMAZE mmzw1d/2d).
- **Leave flat-colour footprints** (FlatArt: 15 samples of the original under the face, std < 6 or mean < 6): black planes sample a dark corner on purpose (MINEMAZE's 960k-unit 'black').

**What it did (offline, Test-GpuLook -RepairDebug: red folded, blue evened, green mixed):** BAPTIST step risers (were vertical streaks) now the treads' stone; SPAROOM's big pipe (09-spacop01, anisotropy 172: streaks round it) evened to even copper grain; the rope/chain strips lost their stripy bands; the vertical pipe mixed (subtle, no ghosting). Counts: CORICORI 29 folded/2 evened, WASHCORI 87/4, SPAROOM 64/40/58 mixed, BAPTIST 58, ORRERY 50, MINEMAZE 16, MINEHEAD 107/34 (MINEHEAD is SET: Josh to say if it stays), CHAMBNEW 32 mixed. Set-up ~10-40 ms a room.

**Switches:** F11 (`-RepairKey`, 0x7A; visor note "TEXTURE REPAIR: ON/OFF") switches all of it (Build ignores the repair, the shader's uMixOn off). `-NoRepair`. Room file `"repair": {"skip": [leaves], "mix": false, "stretch": 4, "flat": 6}` or `"repair": null`. Test-GpuLook `-NoRepair -NoMix -RepairDebug`. The 8-bit renderer (-Retro) is untouched.

**C# 5 trap (Add-Type):** no ValueTuple -- the edge map uses a struct key (EKey).
