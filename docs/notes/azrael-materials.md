---
name: azrael-materials
description: "Materials + shine (2026-10-12, phase 1 of Josh's texture plan): every texture tagged by rooms\\_materials.json (names, ordered regex rules, characterRules, a room's own 'materials'/'shine'); the card's Blinn highlights from the lamp + placed lights, metals tinted; companion maps <name>_rough/_height/_glow (Tex.MatPx, unit 16) that Fit-RoomTextures carries through the fit. F6 / -NoShine / -Shine. Phase 2 WET (cave/spa 'wet' blocks, floor-height map GpuRaster.SetGround, damp walls/puddles/trickles, F5 / -NoWet / -WetDebug)."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-12T15:30:00.000Z
---

Josh (2026-10-12) picked from the texture ideas list and asked for phases he reviews one by one:
1. **Materials + shine:** idea 1 (material tags), 2 (shine where it belongs), 3 (companion maps).
2. **Wet surfaces** (4): "essentially in the rooms with dripping like damp caves, and of course the spa room and similar rooms". Darker, glossier lower walls and floors; drip streaks; puddles that catch the lamp.
3. **Texture repair:** 7 (stretched faces re-laid from the world), 8 (hide the repeats), 9 (seamless audit, the "rope pipe" lesson). Built 2026-10-12: [[azrael-texture-repair]].
4. **Depth:** 5 (parallax from height), 6 (depth in the painted doorway views). 4a (parallax) built 2026-10-12: [[azrael-parallax-depth]]; 4b (painted doorway views) REMOVED 2026-10-13 (Josh: "not working and not worth it") -- the texture plan is finished.

**PHASE 1 BUILT 2026-10-12 (not yet seen in game).**
- **`rooms\_materials.json`** (repo, junctioned into azrael-render\rooms; re-read when it changes):
  - `materials`: shine, gloss, metal, vary. The classes are matte, stone .05, floor .07, ceiling .02, rock .05, polished .30, wood .03, iron .22, copper .30, gold .75 (gloss 22), brass .45, gilded .35 (vary 1.8), glass .75 (gloss 140), blood .35, slime .30, skin .08, armour .25, and cloth, paper, view and water at 0.
  - `names` (exact, reviewed by eye on contact sheets for the 9 opening rooms + MINEMAZE).
  - `rules`: [regex, material], first match wins. Most important: portal views `^[a-z_]*[a-z]\d*2[a-z]` -> view (matte: they are paintings of other rooms).
  - `characterRules` for Tex.Moves textures (default skin). Rooms default to stone; a texture with no Leaf is matte.
  - A room file's `"materials": {leaf-or-name: material | {material, shine, ...}}` and `"shine": x` override them.
- **`tools\Show-Materials.ps1`:**
  - `-Room X [-Sheet png]` lists each texture's material and why, with a contact sheet grouped by material.
  - `-Character` uses the character rules.
  - `-All` gives counts for every unit plus the names left to the default (mostly walls).
- **Watcher:** `Get-MaterialTable`, `Resolve-TexMaterial`, `Set-RoomMaterials`.
  - Called in Set-GpuAtmosphere, and again when the characters change (beside Set-RoomGhosts).
  - Log: "materials: 12 stone, 3 iron, ...".
  - `-NoShine`, `-Shine x`, `-ShineKey` (0x75 = F6 toggles ShineOn). F5/F6 were used only by the old diag build.
- **Raster.Tex:** Material, Shine, Gloss, Metal, ShineVary; companion maps in MatPx (R = 255 - rough, G = height, B = glow), MatW, MatH, MatHas (1 rough, 2 height, 4 glow). `LoadMat` / `Raster.LoadMatAsync`.
- **GpuRaster FS_MAIN:**
  - **shineK per pixel:**
    - With a rough map: 2 x shine x smoothness, gloss x 2^(3(s - 0.5)).
    - Without one: shine x clamp(1 + vary (lum - lum4) / max(lum4, 12), 0, 2.5) x smoothstep(3, 24, lum), where lum4 is the colour 4 mip levels coarser. The level comes from the derivatives taken BEFORE the hole discard (no textureQueryLod after a discard).
  - **Highlights:**
    - The lamp: Blinn from uLampPos (view space (0, 8, 0), the pair's middle), x lampF (cone, falloff, shadow).
    - Each placed light: Blinn x its lc (colour, facing, distance, shadow), so torches glint in their own colour. Normalised (gloss + 2) / 8.
    - Added AFTER the relief tint: light colour on non-metals (Fresnel 1 + 2(1 - N.V)^5), surface hue on metals (mix by metal).
  - **Glow:** col = max(col, tex x GlowGain x glow).
  - **Off in water reflections.**
  - **Per texture in DrawSet:** uShine (x ShineGain), uGloss, uMetal, uShineVary, the companion texture on UNIT_MAT 16.
    - MatUnitOk = MAX_TEXTURE_IMAGE_UNITS > 16; units 0-15 were all taken.
    - GTex.Mat / MatSrc / MatHas / MatB, deleted on eviction.
    - Refreshed when Tex.MatPx changes reference, NOT when it goes null (the CPU cache dropping it keeps the card's).
  - **SharpFor:** a texture with a height map gets its sharp relief from the HEIGHT (a grey temp texture with mips, ReliefHeightK or ReliefSharpK), not from the colour's brightness.
  - Torch props: stake wood, sconce iron, coals matte.
- **LoadRoom Add-AztRgb step 3b:**
  - `<OverrideDir>\<name>_rough|_height|_glow.png` beside a replacement, sized like the colours (Get-AztSizedOverride), read at most 2048.
  - Counted in RgbBytes and dropped with the colours (Limit-AztRgbCache).
  - Returns Companions and CompanionErrors; the watcher logs "companion maps (shine / height / glow) for N".
- **Fit-RoomTextures step 5:** a colour's `<srcbase>_rough|_height|_glow.png` in the source folder gets the SAME shape fit (content boxes) and warp. The border is the previous map, else neutral (grey for rough and height, black for glow). Written beside the colour, backed up; the report gains a Companions column. Companion files themselves are SKIPPED as colours (no MTL leaf).
- **Guide for Josh:** `docs\companion-maps.md` (naming, black/white meaning, a ChatGPT prompt, install, checking).
- **Test-GpuLook:** -NoShine / -Shine / -TexOverrideDir; pulls Get-MaterialTable, Resolve-TexMaterial, Set-RoomMaterials.

**Measured offline (Test-GpuLook, `tc-test\materials`):**
- Cost is in the noise: the card's part ~6 ms either way.
- SPAROOM room view: stone near the torch glistens a little (6.8% of pixels +8, 0.4% +40).
- SPAROOM pipe (copper at 0.40): a hot highlight down the face toward the lamp, near blown out, so copper became 0.30.
- ORRERY gold at gloss 64: almost nothing showed (thin rings seen at an angle; the lamp sits at the eye, so only faces turned toward the eye catch it). At gloss 22, the front ring strips catch it and the brass planet gets a hot facet.
- Companion maps end to end (scratchpad companion-test.ps1, synthetic rough halves + a glow band): fit, then LoadMat values, then smooth and rough strips visible on the pipe.

**Open for Josh's review in game:** overall strength (Shine x), stone sparkle near torches, gold/brass visibility, F6 A/B. Phase 2 (wet) builds on uShine/uGloss: wetness = more shine, tighter gloss, darker albedo.

**Josh on phase 1 (2026-10-12): "I like it! lets move on to phase 2".**

**PHASE 2, WET SURFACES, BUILT 2026-10-12 (not yet seen in game).**
- **Rooms:**
  - `_defaults.json` class "cave" (the 32 rooms with drips) and class "spa" have a `wet` block.
  - BAPTIST has its own, lighter one. `MINEHEAD.json` has `"wet": null` (Josh set that room).
  - Get-RoomAtmosphere reads 'wet'.
- **Settings:**
  - Keys: strength, height (damp up the walls, units), dark (the colour's level at full wet), floor (floors' dampness), shine/gloss (the film), puddles (share) + puddleSize, streaks/streakSpacing/streakSpeed (trickles), ceiling, cell.
  - Cave: .85 / 40 / .66 / .4 / .16 / 40 / .25 / 70 / .55 / 24 / 3.5 / .15.
  - Spa: 1 / 120 / .6 / .6 / .2 / 44 / .35 / 60 / .75 / 20 / 4.5 / .3.
- **Each texture's share is its material's `wet`** (`_materials.json`): stone, floor, ceiling and rock 1; polished .7; wood .8; iron .5; copper .4; gilded .4; brass .3; gold .2; blood and slime .4; cloth .3; matte, glass, skin, armour, paper, view and water 0. In Raster.Tex.Wet; torch props: stake .5, iron .3.
- **GpuRaster.SetGround (the floor under every point, R32F on UNIT_GROUND 17; WetUnitOk = MAX_TEXTURE_IMAGE_UNITS > 17):**
  - Flat faces (|ny| > .6). Which winding is up = the area vote of the lowest fifth (floors).
  - Up-facing faces count unless they are metal (a pipe's top) or have under 30 units of room above them (RayDistance up).
  - Per 8-unit cell: the LOWEST of those within 150 of the cell's highest.
  - Dilated 4 cells, the rest -100000 (dry).
  - **Traps:**
    - MAX (the first try) took SPAROOM's door boxes' hidden tops at the lintel, so the alcove walls were wet to the top.
    - The headroom test alone missed them: the door top sits just ABOVE the tunnel's ceiling, in the void.
    - "Something above" fails too: SPAROOM has no ceiling.
    - So the damp under the walkway rises from the water, and the spa's height went to 120.
- **FS_MAIN wet block** (after relief, before shine; off in water reflections):
  - **Floor (up > .6):** dampness, plus puddles (2 octaves of noise thresholded at .32 x (.5 - share)).
  - **Ceiling:** its dampness.
  - **Wall:** h = (y - groundAt(xz + n.xz x 6)) / height. h <= 0: wet. h < 1.45: 1 - smoothstep(.45, 1, h + ragged noise). Otherwise dry. The noise is only evaluated in that band.
  - **Trickles:** columns along the wall (pcg3d per column: 30% x streaks); half-width 8-20% of the spacing; from a seep 30-230 above the floor; flow noise scrolling down at the speed; beads (fract of y + time) in its middle third.
  - **The surface:** tex x mix(1, dark, wet) x (1 - .18 puddle), saturation +25% x wet.
  - **The shine:** shine mixes to film shine x (1 + 5 puddle + 3 bead); gloss to film gloss x (1 + 5 puddle) + 80 bead.
  - **The highlight's normal:** Ns = mix(Np, N, .3 wet + puddle).
  - **The film's highlight is SOFT-CAPPED** at ~110 levels by wet x (1 - puddle): glints on the bumps, but no white blob on a flat door square to the lamp.
  - **Puddles also add the GI** from the reflected direction x Fresnel.
- **Tuning history (SPAROOM pipe view):**
  - Film .45 / 70 / smoothing .4: the door blew out white and the stone glittered like hammered metal.
  - .05 / 40 / smoothing .65: too subtle to read (only darker). A headlamp at the eye only lights faces turned to the eye, so wet rock reads by its GLINTS.
  - Final: .16 / 40, smoothing .3, and the cap.
  - CORICORI floor: two puddles catch the torch, as wanted.
- **Watcher:** Set-GpuWet in Set-GpuAtmosphere, after Set-RoomMaterials (SetGround reads Tex.Metal). Log: "wet surfaces: ... floor heights ...". `-NoWet`, `-WetKey` 0x74 = F5 (toggles WetOn). F6 off removes the film's shine but keeps the darkening.
- **Test-GpuLook:** -NoWet, -WetStrength / -WetStreaks / -WetPuddles, and **-WetDebug** (GpuRaster.WetDebug): red = wet, green = puddle + bead, blue = height over the floor. That is how the door and pipe traps were found.
- **Measured:** card +0..0.4 ms (SPAROOM 6.6 -> 6.6-7.0). The first big numbers were the machine being busy.

**Phase 2 round 2 (Josh, 2026-10-12): "the dripping water on the walls isn't working so let's remove those. The wet effect is okay, but ... on cave floors it should be relegated to ground textures only, like puddles ... wetness on cave walls needs reduce by about 50%. ... puddles ... defy gravity as they slope upward on the slanting tiles [CORICORI]. ... can this ... glossy sheen be applied to water surfaces to reflect the lights?"**
- **Trickles REMOVED** (shader, GpuRaster WetStreak*, the watcher's keys, Test-GpuLook). Don't bring them back unasked.
- **Cave class:** floor 0 (floors are wet only in puddles), walls 0.5 (new key `walls`: the walls' share, uWetC.x), ceiling .08. Spa and BAPTIST: walls 1.
- **Puddles only on LEVEL floor:** up > .975, faded smoothstep(.975, .993).
- **The film's soft cap now keeps the light's colour:** held by luminance at 80, scaled as a whole. A torch beside a wet spa wall is a warm sheen, not a pale wash. (The white cloud shapes by SPAROOM's torch are its STEAM puffs lit by the torch, not the wet stone: unchanged with the wet film on or off.)
- **WATER SHEEN:**
  - FS_WATER: uSheen / uSheenGloss, a broad lobe of the lamp and the 4 air lights (normalised (g + 2) / 8, the lights' colour squared as its glints) x (.35 + .65 Fresnel), soft-held at 0.4. It is ADDED to the existing sharp glints, which Josh had softened in SPAROOM/4 round 6.
  - GpuRaster.WaterSheen .35 / WaterSheenGloss 30; the water block's "sheen" / "sheenGloss"; off with F6 (ShineOn) and x ShineGain.
  - Water drawn by the room shader: the material "water" is now shine .15, gloss 30, vary .3.
  - SPAROOM: the pool reflects the torch as a warm glitter, 7.6% of the frame +8 vs without.
- **Test-GpuLook:** -WetWalls, -WaterSheen, -RoomsDir (a scratch copy of the room files, to compare settings without touching the real ones).
- **THE ART'S DARK PARTS STAY DRY (Josh, 2026-10-12, CORICORI: "some of the wet effect is on black portions of the textures ... map out the dark portions of the texture and have the wet areas fade into the darkness, not color all of it").**
  - In the wet block, before the strength: wet and puddle are multiplied by lit = smoothstep(darkFrom, darkTo, the luminance of the texture's own coarse mip, about 64 texels across whatever its size) x smoothstep(2, 12, the texel's own luminance).
  - The coarse copy maps the painted darkness, so the wet fades out into it; a black speck takes none.
  - The room wet keys `darkFrom` / `darkTo` (default 10 / 45, 0..255) are in uWetC.zw, GpuRaster.WetDarkFrom/To.
  - CORICORI debug: the wall damp is now patches where the art is lit, and the puddles are cut back on the black floor art.

**THREE SWITCHES TO COMPARE (Josh, 2026-10-12: "we may have 1 or two levels too many effects on the textures. Can you give me a toggle for the normal mapping as well so I can compare all three effects?").**
- F5 = wet (WetOn), F6 = shine (ShineOn: the material highlights and the water sheen), and F7 = RELIEF.
- **F7:** in the true-colour picture it did nothing (the 8-bit picture's texture filtering keeps it, gated by `-not $script:tcOn`). It now toggles GpuRaster.ReliefOn: uRelief and the micro relief (Detail) go to 0 while it is off, and the maps stay on the card. Watcher `-ReliefKey`.
- **Each switch types its state on the visor** (Show-ToggleNote: "RAPTOR H.U.D. // RELIEF MAPPING: OFF", VisorNote, 1.2 s hold). The flashlight's dismissal of room readouts skips it for 3 s.
- Josh suspects 1-2 effect layers too many: expect an outcome like dropping micro relief or lowering ReliefOpacity / the stone shine.
- **NO RELIEF ON SHINY SURFACES (Josh, 2026-10-12, after comparing with F5/F6/F7: "remove ... the relief mapping on shiny surfaces, because that makes them all look more grainy and textured where they should be shiny").**
  - Material key `relief` (default 1): polished, copper, gold, brass, gilded, glass, blood, slime, armour and water 0; iron .4 (it is mostly rust here); stone, rock, floor, ceiling and wood 1.
  - It is held in Raster.Tex.Relief and sent per batch as uReliefK. relK = uRelief x uReliefK gates and scales the relief bend, and uReliefK scales the micro relief's slope and its hollows (cavK). The torch prop's iron sconce is .4.
  - SPAROOM's copper pipe: the highlight is now one smooth band, no longer a grainy one.