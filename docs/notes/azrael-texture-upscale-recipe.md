---
name: azrael-texture-upscale-recipe
description: "THE approved texture upscale recipe (Josh, 2026-10-05): Real-ESRGAN 4x, 100% upscaler, sharpen 0.8, grain 2.0 tint 0.35, colour from original, light lock. He wants it applied to ALL textures in a later step. 8x judged not worth it."
metadata:
  type: project
---

**Approved by Josh on 2026-10-05 after judging in game** ("fantastic", "a good balance"):

```
tools\Upscale-Room.ps1 -Room <ROOM or character XAF name> -Blend 0.9 -Sharpen 0.8 -Grain 2.0 -GrainTint 0.35 -ColourFromOriginal
```
(`-Scale 4`, model `realesrgan-x4plus`, `-LockTexels 2`, `-Pad 16` are the script defaults.
NOTE the script's own defaults for Blend/Sharpen/Grain are 1/0/0 -- pass the switches.)

- Tool: Real-ESRGAN portable (ncnn-vulkan) at `C:\Games\realesrgan`. ~15 s a room.
- Output: `C:\Games\azrael-textures\hires\<texture file name>.png`, read by the TRUE-COLOUR host
  renderer only (`-TexOverrideDir`). Game files untouched. `-Revert` removes a room's set.
- Done so far with this recipe: CORICORI, SPAROOM, WASHCORI, EUGBLD (71 files). Backup copy of
  exactly this set: `C:\Games\azrael-textures\hires-4x`.

**Standing wish: apply this to ALL textures "in a later step"** -- do NOT start it unprompted.
When he asks: every unit with a `.mtl` in `C:\Games\azrael-render` (rooms AND character .XAFs;
~179 .RES / ~2,900 textures; file names are shared between rooms so many are done once).
Things to settle then: rooms the renderer has never loaded have no exported PNG/.mtl yet;
RAM (a 1024 texture + mips is ~5.6 MB; the room cache holds 8 rooms); total time ~45-60 min.

**Why this recipe (his requirement):** the game has no lights -- every shadow and all black
space is painted into the textures. The light lock (upscaled x blur(original)/blur(upscaled))
and colour-from-original keep that exactly; grain puts back the photographic feel ESRGAN
strips ("a touch odd" without it).

**Rejected, do not re-propose:** 8x (two ESRGAN passes; tried in game 2026-10-05: "those aren't
worth it"; 4 min a room, 4096 textures); 80% blend (he preferred 100%); plain ESRGAN without
grain. `hires-8x` and the 8x code path (`-Scale 8`) still exist.

Related: [[azrael-true-colour]], [[azrael-texture-remaster-verdict]] (the old 8-bit verdict --
superseded for the host renderer), [[azrael-judge-in-game]].

## Model sampling (2026-10-05 18:00) -- Josh wants the originals' GRIME back; x4plus is "too smooth/painted"

He downloaded the Upscayl `custom-models` pack (NCNN .bin/.param); 10 of its models were copied to
`C:\Games\realesrgan\models` and ALL load in realesrgan-ncnn-vulkan (`-n <name>`, 1-4 s per 256
texture). chaiNNer was NOT installed: it would run the same models on the same engine (NCNN on AMD).
Five sets were built with the approved recipe for CORICORI/EUGBLD/SPAROOM/WASHCORI, into
`C:\Games\azrael-textures\sets\<set>` (71 files each):
  1-siax = 4x_NMKD-Siax_200k, 2-superscale = 4x_NMKD-Superscale-SP_178000_G, 3-nomos8k = 4xNomos8kSC,
  4-lsdir = 4xLSDIR, 5-lsdirplus = 4xLSDIRplusC  (set 0 = hires = realesrgan-x4plus).
Also in the models folder, untried: 4xLSDIRCompactC3, RealESRGAN_General_x4_v3, uniscale_restore,
4xHFA2k (anime), unknown-2.0.1.
**F7 in a true-colour session steps through the sets** (`-TexSetsDir`, `-TexSetKey`); the set's
number is stamped top-left for 2 s; `Add-AztRgb` reloads a unit when the folder differs
(`mem.RgbDir`), and a room object carries `RgbDir` so cached rooms catch up. AWAITING his pick.

Josh (18:10): try set 3 (4xNomos8kSC) first, first room only -> CORICORI in hires is now nomos8k; SPAROOM/WASHCORI/EUGBLD in hires are still x4plus. He also asked that upscaling always start from the game's ORIGINAL textures (it does: inputs are the C:\Games\azrael-render exports, never a previous upscale).
Then (18:15): CORICORI in hires re-made with 4x_NMKD-Siax_200k (its native and only scale is 4x).
Siax: "no good" (18:20). CORICORI in hires re-made with 4x_NMKD-Superscale-SP_178000_G.
Then 4xLSDIR for CORICORI (18:25); no verdict yet on nomos8k / superscale.
Revised (18:30): of the new models Siax is the best. CORICORI in hires re-made with Siax at the EARLIER recipe he picked on request: -Blend 0.8 -Sharpen 0.8 -Grain 2.0 (grey grain, no colour-from-original). Awaiting verdict.
**VERDICT 2026-10-05 18:35: "None of the new models worked. Let's go with the original Real-ESRGAN."**
hires restored byte-for-byte from hires-4x (realesrgan-x4plus, the approved recipe above, all four
units). The recipe at the top of this file stands. The five model sets remain under
C:\Games\azrael-textures\sets (F7 still steps through them) -- do not re-propose other models.
(18:50) At his request the five model sets, the ten extra models and the F7 set-switching code were REMOVED. Only realesrgan-x4plus (+ the pack's anime models) remain in C:\Games\realesrgan\models. Add-AztRgb keeps its folder-aware reload (harmless).

## Grit added (2026-10-05 19:05) -- RECIPE UPDATED

He liked the grittier feel of the other models but not the models. Added to Upscale-Room:
`-Detail` (the ORIGINAL's fine texture = original minus its blur over one texel, laid back over
the upscale) and `-Clarity` (local contrast, radius 3 texels). Ladder of 8 shown; he chose
**100% upscaler, grime (Detail) 1.0, clarity 0.8, colour from original, plus the standing
sharpen 0.8 / grain 2.0 tint 0.35**. Applied to CORICORI, SPAROOM, WASHCORI and EUGBLD (hires).
The command at the top of this file now includes -Detail 1.0 -Clarity 0.8. hires-4x is the
OLDER approved set (without grit) -- do not copy it back over hires unless he asks.
Not built: grain added BEFORE upscaling (needs the upscaler re-run per variant).

## REVERTED (19:15): grime + clarity made the textures "too hot", lost the desaturated look

**CURRENT RECIPE: `-Blend 0.9 -Sharpen 0.8 -Grain 2.0 -GrainTint 0.35 -ColourFromOriginal`**
(no -Detail, no -Clarity). Applied to CORICORI, SPAROOM, WASHCORI, EUGBLD. The command at the
top of this file is updated. Do not re-propose Detail/Clarity; the code stays, off.

## THE FULL RUN STARTED (2026-10-05 19:30) -- `tools\Upscale-All.ps1`

Josh: do all textures in organised batches with check-ins. `Upscale-All.ps1 -List` / `-Batch N`:
174 units in 15 batches of 12 (plan fixed in C:\Games\azrael-textures\upscale-plan.txt; rooms
first, walked from CORICORI through portals.json, then alphabetical, then models). The recipe
lives in the script's $RECIPE (Blend 0.9 etc.) -- change it there if Josh changes it. Textures
already in hires are skipped, so batches are resumable. Log: C:\Games\azrael-textures\upscale-all.log.
**Batch 1 done** (9 new units, 261 textures, 6 min): MINEHEAD STAIRS3 CHAMBNEW BAPTIST MINEMAZE
TRACK01 WELLROOM INTRVIEW ORRERY. Next: `-Batch 2`. Check in with Josh between batches.
Deleted at his request: hires-4x, hires-8x, hires-retired, all of upscale-work. His September
folders under C:\Games\azrael-textures (incoming, incoming2, room01, variants) were NOT touched.
**Batches 2-4 done** (19:55): 36 units, 786 textures, 22 min, no problems; hires = 1,118 files, 1.26 GB. Next: -Batch 5. TRAP: -Batch 2,3,4 under powershell -File arrives as ONE number (234) -- loop over single batches instead.
**Batches 5-8 done** (20:25): 46 units, 926 textures, 25 min, no problems; hires = 2,044 files, 2.4 GB, 84%. All ROOMS are done; batches 9-15 (creatures/characters/items, ~380 textures) remain.
**ALL 15 BATCHES DONE (2026-10-05 ~20:45): every one of the 2,426 textures (174 units) is in C:\Games\azrael-textures\hires with the recipe above. Not yet seen in game beyond the first rooms.**
