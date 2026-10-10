---
name: azrael-gpu-effects
description: "Card-only effects Josh asked for 2026-10-06 -- relief (bump) maps, AO, visible flashlight beam, ground mist, particles (embers, drips, steam, footstep dust). Where they live, tuning, and the traps hit building them."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-07T17:13:01.326Z
---

Josh picked these from the "now we're on OpenGL" list (2026-10-06): ground mist, particles (embers
from torches, ceiling drips, steam in WASHCORI = the steam room with the trap door, dust kicked up
walking), relief from the flashlight, visible beam, corner/contact darkening. NOT chosen yet (still
on the list): better shadows (pair/PCSS), bloom, light-placement mode, living water, MSAA,
anisotropic, eye adaptation, colour grading, supersampling, visor glass, visor modes, glowing eyes.
All are GRAPHICS CARD ONLY: the processor picture (F9) and -AA/F8 paths have none of them.

**Where:** `tools\GpuRaster.cs` + `tools\Particles.cs`; watcher `-Relief 1.0 -AO 0.6 -Beam 0.7
-NoMist -NoParticles`; room files `C:\Games\azrael-render\rooms`: `_defaults.json` everywhere =
mist + kickup, cave = drips; `WASHCORI.json` = steam + its own lighter mist; embers come from every
light with flicker > 0 (room file "embers" can tune or set rate 0). `Set-GpuAtmosphere` at room load.
- RELIEF: built ON THE CARD at texture upload (MakeRelief: luminance at the half-size mip minus
  the mip 4 levels coarser = band-pass, central differences, ReliefBuild 4), half-size RGBA8 with
  mips; main FS bends the normal via a cotangent frame from dFdx/dFdy (no tangents stored);
  lamp facing scaled by (0.35+0.65 fP)/(0.35+0.65 fG); torches use the bent normal. No offline
  maps (was the plan; this is equivalent and needs no 3 GB).
- AO, MIST, BEAM: in the COMPOSE pass (it can read _depthTex: not attached to compFbo). AO = 12
  kernel taps, radius 24, fades out 350-800 units. MIST = exact exponential-height-fog integral
  along the ray (no march) x wisps from fbm at 2 points; floor = Particles.FloorY (ray down from
  the eye). BEAM = 16-step march, hot spot only (+0.2 of the corona), lamp shadow map per step.
- Particles: CPU sim (drips: ClearanceUp + RayDistance; steam: ray down), GL_POINTS premultiplied,
  alpha group back-to-front then additive embers.

**Tuning lessons (offline, tools\Test-GpuLook.ps1 renders PNGs + times):** a mist colour lighter
than the room's shadows greys the whole picture -- mist must be near-black (#140E0A) and SHOW only
where the beam lights it; the void (dz=0) must not be marched far (220 units) or it fills with
mist; the beam scattering across the whole corona is a veil, the hot spot is a shaft; a steam puff
in the hot spot became a white blob -> cap its lit level 0.9. Cost: ~3 ms of card time on top of
~3 (relief+AO ~0, mist was 3 ms when marched with fbm per step -> analytic fixed it).
Test traps: `$room` IS `$Room` (a [string] param) -- the room object became text; walking the
test camera 70 u/s for 9 s starts it outside the room (no floor -> no steam).
**First in-game run (2026-10-06 01:12): Josh saw NO mist, particles or relief.** Log showed all running. Causes:
- PARTICLES INVISIBLE: the compatibility context needs `glEnable(GL_POINT_SPRITE)` (0x8861) or gl_PointCoord
  is 0 and every fragment is discarded. Motes never hit it (shaped from gl_FragCoord). Fixed.
- RELIEF too shallow: measured (GpuRaster.ReliefStats) ReliefBuild 4 tilted the typical bump 2-6 deg -> 24
  (5-25 deg); lamp response (0.1+0.9 fP)/(0.1+0.9 fG).
- MIST near-black on dark floors = invisible -> density 0.004, height 16, max 0.03, #2A241E; then the beam
  in denser mist blew out to white -> BeamMistScatter 0.5 and a saturating beam (<= 45% of white).
- Embers rate 16 size 2.2 brighter; drips rate 6 size 1.3 + a minimum glint; kickup 60 units AHEAD of the
  feet (KickAhead; at the feet it is below the view); WASHCORI steam alpha 0.16 size 34, base lit 0.3.
- Test-GpuLook trap: its timing re-draws have no particles/motes left -- it now saves the REAL frame.

## 2026-10-06 (later): mist lit, beam OFF
- Josh: mist only showed with the flashlight on (a dark mist only dims lit surfaces; on dark floors it vanishes). Mist is now a PALE haze: defaults #6A6258, density 0.006, height 20, max 0.04; WASHCORI #7A766E, 0.008, height 30, max 0.035. Checked lamp on and off: visible both ways, not a veil.
- Josh: the visible flashlight BEAM "gets in the way" -> watcher -Beam default 0.0 (code kept; -Beam 0.7 restores). Don't turn it back on unasked.
- Test-GpuLook now takes -MistColor/-MistDensity/-MistHeight/-MistMax to try settings before writing room files.
## 2026-10-06 (later still): mist per room, focused beam
- Mist is NOT everywhere any more: class "misty" in _defaults.json = CORICORI/R1 + the mines (MINEHEAD, MINEHED2, HINEAZF, MINEMAZE, MAZENEW, LIGHT; picked by rock/mine material names in the .XAF). WASHCORI's own mist removed (steam kept). Never put mist where there is water to see: it hid SPAROOM's water and reflections.
- First room's portals: zxcoriR2 -> WASHCORI (steam room, trap door), zxcoriR5 -> SPAROOM (the walkway over the water). Josh calls SPAROOM "the level with the walkway".
- SPAROOM (class "spa", plus SPAROOM3/SPAROOMX/OLDSPA): steam rate 40, rise 5, life 9, size 40, alpha 0.35. Steam alpha ~0.1 is INVISIBLE over dark water: puffs add ~10 levels. Test-GpuLook prints a "steam:" line (count, height, colour, alpha) to check this numerically.
- Beam back ON (-Beam 0.7) as a NARROW shaft: own cone BeamInnerDeg 2.5 / BeamOuterDeg 6, starting at BeamOrg (5 right, 6 up) from the eye so it reads as a shaft, not a glow; haze 0.003. Exact ray-cone interval for the march (no missed slices).
- BUG found: the lamp-map shadow test in the compose (lampAir) put ALL air past ~20 units in shadow (only off-map points counted as lit), so the old wide beam was mostly near-field too. Removed from the beam (the shaft starts at the eye, nothing visible can block it). The surface shadow test in FS_MAIN is separate and fine. Cause not pinned down.
## Beam, third version (2026-10-06): faint FAN from under the visor
- Josh disliked the narrow side shaft; wants a fan rising from beneath the viewport toward the centre, VERY light (the beam was blocking visibility). Now: BeamOrg (0, -18, 0), cone 4/22 deg, BeamFalloff 70 (half as bright 70 units from the lamp, so it is brightest rising from below, not a disc at the far end), BeamMax 0.15 (cap, was 0.45). Adds ~15 levels at most.
- Judge beam changes with scratchpad beam-diff.ps1 (amplified beam-on minus beam-off). Torch flicker runs on wall-clock time, so surfaces also differ between runs: ignore texture-shaped differences.
## Lamp-independent particles + FLICKER WATCH (built 2026-10-06 11:44, not yet seen in game)
- Josh: effects must not depend on the flashlight (steam vanished with it off: lit by the room alone it matched the room). Steam is now self-lit 0.72 (+0.35 x beam, max 0.95); kickup floor 0.62. WASHCORI steam alpha 0.3. Rule: any new effect needs its own base brightness.
- Josh: "screen keeps flickering/tearing, a portion flickers black then back to normal". NOT reproduced offline (cannot run the game). Log of that run was clean (150 fps, 0 hidden). Two guards + counters added, logged every 4 s as "flicker watch: ...":
  - Overlay.ReadOnce: a DOSBox screen reading where >=1% of grid samples went key -> pure black (black not the new key) is kept back (max 3 in a row, then accepted as real). Theory: a reading caught mid-redraw; black non-key pixels are composed over the picture as "the game's drawings".
  - GpuRaster.FinishRead: a card picture with >=15% pure-black sample rows when the one before had <5% is held back once.
  - Window hide counters by reason (no picture / not placed / stale / not in front).
  NEXT: read the "flicker watch" lines from Josh's next run. All zero while he still sees flicker -> the cause is elsewhere (window blit, DWM).- RUN 11:51 (build 11:44:55): flicker still there; "torn screen readings kept back" 20-27 per 4 s => the BLACK IS IN DOSBOX'S SCREEN. ROOT CAUSE (from Build-AztMod AztInjBody + tier-A notes): aztSup3D = 0 so the engine CLEARS the viewport to black every guest frame; the guest copies our key frame only when aztInjReady is set; "starved" frames (hundreds per 4 s in true colour) therefore show BLACK, not "the last frame" as the guest comment assumes. FIX (build 11:56:15): while true colour is in 'run' and only the key frame is handed over, the watcher writes aztInjSync = 0 -> the guest copies the key every frame (AIB_nogate) and STILL clears aztInjReady after each copy, so pacing holds. Gated (1) again for calibration and 8-bit. Log line "game copies the key frame ..." on each switch. Expect starved ~0 and torn readings ~0 in the next run.- RUN 11:57 (build 11:56:15): starved 0, torn readings 0 in most windows -- the sync fix WORKS. Remaining spikes (11:57:54, 11:58:30/31) were silent HAND-BACKS: "viewport handed back (nothing to draw yet)" then immediate takeover, no "new room" line => one of the silent per-frame checks (CAM1 magic, camObj, identity camera, no room) blinked for a frame; each hand-back shows the engine's own 3D for a few frames + resets aztInjSync to 1. FIX (build 12:0x): Step-NothingToDraw rides out blinks < -HandBackAfterMs 250 (skip the frame, keep the picture), logs the reason when it does hand back; counter "blinks with nothing to draw ridden out" in the flicker-watch line. The teleport/room-change hand-back is deliberate (floors) and unchanged.
## SHARP RELIEF (2026-10-07, built, first room only, not yet seen in game)
- Josh: relief "makes the textures look lower resolution". Cause: the first maps are HALF the colour's size, built from its half-size mip (lod 1) minus lod 5, a 2-texel central difference, and sampled at lod-1 -> bumps 2-4x coarser than the 4x ESRGAN colour (blobby lumps, seen offline).
- GpuRaster.ReliefSharp: second map per texture (GTex.NormHi), FULL colour size, RG8 (z rebuilt in the shader for both kinds), height = (L0-L2) + 0.4*(L2-L5), Sobel 3x3, sampled at the colour's own lod (uNormLod 0 vs -1). ReliefSharpK 36 MEASURED to match the old steepness (mean 0.150 vs 0.160). 22 CORICORI maps = 61 MB, frame cost unchanged.
- Watcher: -ReliefSharpRooms (default CORICORI; '*' = all; per room via ReliefSharpBuild, set at room load, shared textures get one when a listed room meets them), -ReliefSharpK; F7 in true colour toggles sharp/old (F7's 8-bit filter role untouched). Test-GpuLook -ReliefSharp [-ReliefSharpK] prints slope stats for both kinds.
- Risk to watch: the ESRGAN recipe adds GRAIN 2.0; the finest band picks it up as a fine pebbly bump. If Josh finds it "sandy", lower ReliefFine or raise the fine band's blur.
- Josh 12:06 run (F7 in WASHCORI): sharp v1 "feels too large". v2 (12:20): sharp map is RGBA8 with TWO layers mixed live in the shader (as slopes): RG = L0-L1 (1-2 texel bumps), BA = L1-L3; ReliefFine 1 / ReliefMid 0.35; the 4-32 texel lumps dropped. reliefK (lamp brightening of a tilted bump) CAPPED at ReliefGain 1.6 for sharp maps only (was ~3.5x on glancing floors = white blobs that read as big bumps). ReliefTile (lay the map smaller) exists but MEASURED on MINEHEAD: x2/x3 pull in sharp-edged patches of other art sharing the texture file (atlas) -> default 1, F7 step only. Hard limit: texture-derived relief can't be finer than the texel; on stretched textures (MINEHEAD floor) it still reads coarse -- the next step would be procedural world-space micro-detail (not built, Josh's call).
- PER-PIXEL MIPMAPS (Josh: "texture detail softens in the distance to prevent shimmering"): PixelMip = textureGrad from dFdx/dFdy(st) instead of the per-triangle CPU-parity lod (one level from the centroid angle); Anisotropy 8 (was 1); PixelMipBias 0; relief NormMipBias +1.0 (0.5 still sparkled). Cost +0.1 ms. CORICORI is too small/close to show much; long floors are where it matters. Watcher -NoPixelMip/-GpuMipBias/-Anisotropy; F7 steps FINE -> FINEST -> x2 -> OLD.
- Josh 12:2x: "mipmapping looks perfect"; wants the "finer still" route. MICRO RELIEF built 12:33 (first room only, not yet seen): FS_MAIN gets vWorld (aPos) + uView; 3D gradient noise with exact derivatives (pcg3d integer hash -- a sin() hash breaks far from the origin), up to 6 layers each half size and domain-rotated, slope kept constant per layer (height = amp x size), each layer faded by smoothstep(2,5, size / world-units-per-pixel) = no shimmer; slope laid along the surface (surface-gradient) bends Np before reliefK; hollows darkened DetailAO 0.10. GpuRaster.Detail (0 = off) set per room by the watcher (ReliefSharpRooms); reflections 0. MEASURED: scale 4 / rough 0.6 = blotchy mottling (coarse layer wins); scale 1.2 units, rough 0.85, strength 0.3 = fine rock grain; Josh "looks great", then asked 15% finer -> 1.02 (12:38), then picked F7's "finer and subtler" -> DEFAULT strength 0.4 at scale 0.8 (12:54). F7 crash 12:42 = my `$rs` clobbering the lamp shadow raster (fixed; see powershell-silent-traps). RELIEF TINT (12:54, Josh: relief's "dark gray shadows feel muddy", wants a Photoshop multiply look): in FS_MAIN after col = tex*gain, shade = (g / gFlat) * cavK (gFlat = the same lamp with reliefK 1), q = ReliefTint*(1-shade), col *= pow(cn,q)/lum(pow(cn,q)) with cn = tex/max channel -> weaker channels drop more, luminance kept. Sharp maps only. MEASURED (mist off) tint 3: shadow saturation 0.42 -> 0.46, grey-black grain reads brown; default 3. NOTE the first room's pale mist (#6A6258) greys everything after this -- a bigger greying source than the shading in measurements. F7: default -> same with grey shadows -> micro 0.3@1.02 -> OLD. Shader strings are C# @"..." verbatim: NEVER put a double quote in a shader comment (it ended the string; build broke). Josh liked the tint (13:00). RELIEF OPACITY 0.8 (his ask): reliefK = mix(1, reliefK, op), Np = mix(N, Np, op) for torches, cavK scaled -- the lamp is linear in reliefK so this is a true layer opacity; MEASURED on lit pixels: effect at 80% = 80% of the 100% effect. Sharp maps only. Watcher -ReliefOpacity. Josh (13:03): keep the first option, try 50% -> DEFAULT ReliefOpacity 0.5.
- **FINAL, GAME-WIDE (13:11, Josh: "that's the one ... remove the others and apply this game-wide"):** ReliefSharpRooms '*' (every room), micro 0.4 @ 0.8 units, tint 3, opacity 50%, ReliefMid 0.35, gain cap 1.6. F7 relief stepping REMOVED (F7 does nothing in true colour; still the 8-bit filter). Old half-size maps are only built when a texture is uploaded with ReliefSharpBuild off (Make builds ONE kind; DrawSet uses NormHi when Norm is 0). Micro relief OFF on character/creature textures: Raster.Tex.Moves set in Import-AztRoom for character units (verified: CORICORI + EUGBLD = 8 of 30 flagged), DrawSet sets uDetail 0 for them (_detailNow). MEASURED cost: upload 25-31 ms a room (same as old), card memory +60% (CORICORI 153 -> 244 MB, MINEHEAD 225 -> 359 MB; the 1.5 GB ForgetTextures ceiling just trips sooner); frame 4.3-5.0 ms. Not yet seen in game beyond the first room. Cost +1.6 ms card time. Watcher -Detail -DetailScale -DetailRough -DetailAO; F7: MICRO+fine -> MICRO finer (0.4 @ 0.8) -> FINE only -> OLD. Known: one stone grain on every material (wood too); world-space so it slides on moving doors/creatures. Next ideas if wanted: per-material grain (wood/metal), texture-driven strength.
- Test-GpuLook gained -ReliefSharp -ReliefSharpK -ReliefMid -ReliefTile -ReliefGain -NoPixelMip -GpuMipBias -Anisotropy -NormMipBias -NoDustMotes -NoTorches (the last two make runs deterministic: motes and torch flicker are random/wall-clock). Scratchpad crops.ps1 (brightened 2x crops) is how the relief was judged; absolute-difference metrics were useless in these dark rooms.

- Josh also asked whether the HUD panel's text-log flicker (always there) is related: it is the game's own 8-bit panel, outside the overlay; not the viewport flashes. Not investigated yet.