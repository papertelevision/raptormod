---
name: azrael-map-3d
description: "The 3D map (2026-10-14; ALL rooms since round 2 -- doorway pictures, black occluders, stray/parked parts and characters left out): the map button shows the room as the scan's wireframe (cut-away, flat teal shading, glowing edges, amber door arrows from portals.json, player ring) over the dimmed, frozen visor view; drag with the left button to turn, wheel to zoom; screen 6's click region moved onto the MAP button at run time. Plus the game's map screen RE (flag 0x1525F2, MAPS.DAT)."
metadata:
  type: project
---

Josh (2026-10-14): "revamp the maps ... the same 3d wireframes we've used for roomscanning ... a dimmed version of the visor view, the world behind faded back but still visible ... the 3d wireframe, with basic shading in place but no textures. The user can click to rotate the map, and the arrows that indicate doors etc are still in place ... in modern vector graphics ... start with the coricori room first". **Host-only; checked offline (Test-GpuLook -Map); NOT yet seen in game.**

## The game's map screen (RE, read-only)
- **Toggle `0x12954(eax = room, -1 = help)`** flips **word `0x1525F2`** (map AND help share it).
  - Opening sets `[0x14721A]=1`.
  - It loads only a PALETTE (from MAPS\CORICORI.PCX for every map; from HELP.PCX for help) into 0x1525F4.
  - It switches hot spots to **screen 6** (object 0x164DF0): ONE whole-screen region, command 6.
  - It composes surface 0x1525E0 with **DecodeMapView 0x1EC7A**.
  - Closing (0x12A7A) restores the HUD, hot spots and palette.
- **NOT modal:** the main loop 0x16043 keeps running and our frame hook 0x13DC8 still runs. Gated off while the map is up: actors (0x13DE1), the 3D pass (0x1414A), scripts (0x148ED) and the HUD (0x156E2). 0x1588C blits the map surface to (0,0) every frame.
- **Ways in:**
  - the MAP button (NBUT1, screen 0 region 5, command 6 -> 0x2C615 -> toggle with the room from word [[0x1841C8]]);
  - `m` (only when [0x14721C] combat is 0);
  - help: h / H / ? / / / F1.
- **Ways out:**
  - a left click anywhere (screen 6's region, through the pump 0x16071, skipped while [0x147218]);
  - right-button-down (0x15E15);
  - m / help keys. ESC is ignored.
- **MAPS.DAT (GAME\AZRAEL)**, plain text:
  - `ROOM n` / self image `NAME x y` / neighbours `NBR_C x y room` (drawn if visited word 0x162E4C+2n) / arrows `A<dir>_<len> x y` (single-ink PCX, always drawn) / `END`;
  - 76 rooms; arrows are pictures, NOT clickable, not linked to rooms (only by position); no player marker;
  - story swaps for rooms 5, 44, 62.
- **CORICORI = room 0:** CORICORI.PCX at (160,127), WASH_C / SPA_C thumbs, ARYT_50 / ADN_50.
- **FOUND:** the installed `GAME\AZTEX\MAPS\CORICORI.PCX` is NOT stock (a re-quantised copy, `.PCX.orig` beside it, 2026-09-22). Its palette is the whole map screen's, so the original maps likely show wrong colours. Not changed; restoring the .orig would fix it.

## The 3D map (host)
- **GpuRaster `DrawMap`** (end of Draw, when MapK > 0) renders into its own layer `_mapFbo` / `_mapLayerTex` (unit 19, MapUnitOk):
  - an orbit camera round the room's static geometry (MapYaw / MapPitch / MapZoom / MapFovDeg 34), squeezed into the view band (picture row 0 = top: y flipped);
  - **faces:** flat teal (MapInk), lambert + floor lift + rim. **CUT-AWAY:** keep faces whose winding normal faces the eye (the room's inside faces its middle, so the near walls and the ceiling drop out). `MapCullFlip` false is right (checked side-on);
  - **edges:** BuildXray's feature edges, as constant-width glowing lines (FS_MAPL halo + core), dimmer where hidden (MapHiddenK);
  - **marks** (`SetMapMarks`, 8 floats: x, y, z, out x, out z, kind 0 door / 1 player, size): amber chevrons sliding out over a pad outline; the player as a ring + pulse + facing wedge.
- **FS_COMP** (`uMapLayer`, `uMapK`, `uMapDim` 0.72): the picture is darkened and greyed by MapK, and the layer laid over it (premultiplied).
- **Doors: `Get-AztMapDoors` (LoadRoom.ps1)** from `portals.json` (Build-PortalMap): `door` x, y, z and `axis` = the way OUT. CORICORI: WASHCORI at (-366, -376) and SPAROOM at (650, 292).
- **Watcher `Step-Map`** (Step-TrueColour, before the hide rects):
  - **Detection:** the 0x1525F2 rising edge; help is told apart by the live palette at 0x1525F4 vs HELP.PCX / CORICORI.PCX.
  - **Rooms:** `-Map3DRooms` (default CORICORI), `-Map3DAll`, `-NoMap3D`.
  - **While up:**
    - hide rect = the whole game screen (no old map picture);
    - the camera held as it was (`$script:mapFreezeCam`, applied before `$r.SetCameraWorld`);
    - the map opens looking the way the player faces: yaw = atan2(-fwd.x, -fwd.z);
    - the player marker on the floor under the eye, found by ray from the loop's `$room` through dynamic scope.
  - **Fades:** in 0.35 s, out 0.2 s.
- **Turning: `RawMouse` (Keys.cs)**, a message-only window with raw input (RIDEV_INPUTSINK). It counts while the game or this process is in front; drag counts only while the left button is held, plus the wheel; it restores the previous raw-mouse registration on stop. Drag x -> yaw x 0.22 deg/count, y -> pitch 12..88; wheel -> zoom 0.6..3; eased 80 ms.
- **Clicks: `Set-MapHot`** moves screen 6's one region (object 0x164DF0, region 0: points + box) onto screen 0 region 5's box (the MAP button) at run time. `Restore-MapHot` runs on close and in Close-TrueColour. A click on the map no longer closes it; the MAP button, right-click and M do.

## To check in game
- The map opens from the button, with no flash of the old picture.
- The drag turns it (and whether mouselook also turns the world behind: the host camera is frozen, but the game's might not be).
- The MAP button closes it.
- Help (H / F1) is still the game's.
- Other rooms keep the game's map.
- The player marker sits on the floor.

Related: [[azrael-materialize]], [[azrael-zones-room-graph]], [[azrael-doorway-portals]], [[azrael-system-menu]] (run-time hot spots: move the region BOX too), [[azrael-room-review]].

## Round 2 (Josh, 2026-10-14: "we dont want to include door geometry in the maps ... the alternate door polygons which float outside of the actual map ... After that, I want this map solution added to all rooms in the game")
**Every room now: `-Map3DRooms` defaults to `*`.**

**Left out of the map** (`Get-AztMapSkip` in LoadRoom.ps1 -> `GpuRaster.SetMapSkip`, which clears the triangles' textures in a copy, so faces and edges both skip them):
- **Doorway pictures:** every doorway's painted views of the next room (portals.json `views` + `parked`; the parked alternates float outside), matched by exact part name in that file.
- **Characters** (IsCharacter).
- **Occluder sheets** named `black...`: blackcover, blackout01, BLACKTOP01, MINEMAZE's `black` planes (whose material is a TUNNEL texture, so a colour test misses them).
- **Dark flat materials:** 1x1 textures with palette luma < 40.
- **Anything not part of the room's body** (`GpuRaster.MapStrayParts`):
  - parts whose boxes touch within 6 units are one piece;
  - the room is the piece holding the most door pads (then the most vertices);
  - another piece is stray if its box's middle lies outside the room's box grown by 10%, so free-standing props inside stay.
  - **ORRERY's rings are parked at y -37,000:** they used to make its map a dot; now dropped (995 triangles).

**Checked offline** (Test-GpuLook -Map): CORICORI, MINEHEAD, WELLROOM, ORRERY, SPAROOM, MINEMAZE, BAPTIST, CHAPEL, KITCHEN.

**Still visible, by design or to judge:**
- WELLROOM's water plane is wider than the room;
- ropes/chains as long lines;
- a slanted plane at MINEMAZE's east end.

## M opens and closes the map (Josh, 2026-10-14)
The key handler 0x12B88 matched only lower-case 'm' (0x135BC) and 0x13391 then refused while the weapon is out ([0x14721C]): with the weapon drawn, or Shift / Caps Lock, M did nothing. Patch `m-key-map-135BC` (`$ENABLE_M_MAP`) jumps to overlay `AztMKey`: 'm' or 'M' -> 0x1339F (the toggle 0x12954 with the room, past the weapon test), else back to 0x135C4. No fixups and no branch into the 8 bytes (checked by decoding the whole handler; `Refs` does NOT list branch targets). The map screen's own key gate 0x12BA3 already lets m/M through, so the same key closes it. Manifest 451 -> 452. Installed 2026-10-14.

## No shot on the map + the pulse-in (Josh, 2026-10-14)
**"The gun must be disabled while viewing maps, as it keeps shooting while I click to drag":**
- The left-press handler 0x15A5C fires when the weapon is out ([0x14721C]: shot.wav, ammo 0x14694C - 1).
- Patch `map-no-fire-15AFC` (`$ENABLE_MAP_NO_FIRE`) routes its `jz 0x1607C` (no weapon -> the ordinary click) through overlay `AztFireGate`. While word 0x1525F2 (map / help) is up, that also takes the ordinary click.
- It reads the flag through AztDeltas (eax / esi / edi saved).
- No fixups, and no branch into the 6 bytes. Manifest 452 -> 453.

**"Quickly animate in by the wireframes 'pulsing' in ... grow from nothing to larger, then back to normal size in a wave across the geometry, then becoming interactive":** `GpuRaster.MapIntro` (seconds since opening; -1 = none).
- **The wave:** each edge (about its middle) and each face (about its centroid, a 3rd vertex attribute) grows from 0 to 1 + MapPulse (0.35) and settles to 1. The `MAP_WAVE` GLSL is shared by both programs.
- **Its path:** the screen's left to right. The axis is the map eye's right, (cos yaw, 0, -sin yaw), over MapIntroSeconds 1.1. The front is MapWaveWidth 0.35 of the room wide and glows as it passes.
- **Unreached pieces are culled.** Zero-length lines otherwise left SPECKS: their caps.
- **The marks** fade in over the last 30%.
- **The watcher** (`$script:mapIntroClock`) ignores drag and wheel until the intro is done.
- **Offline:** `Test-GpuLook -Map -MapIntroAt s`.
## The game's own map: corrupted, now drawn right or not at all (Josh, 2026-10-14)
**"The old map is still showing in some rooms. Those maps became corrupted ... They can be removed completely ... In retro mode we will need to include the original low rez map art but make sure they are not corrupted."**

**Causes:**
1. **The map is composed into a 640x480 surface.** 0x12954 creates 0x1525E0 at 0x280 x 0x1E0, and MAPS.DAT places every piece in 640x480. 0x1588C blits the surface to (0, 0) every frame. On the 1600x1200 screen that is a 640x480 picture in the top-left corner, and its top rows lie ABOVE the 3D view, where the host's picture does not cover them. That was the piece left showing after the compose's hide.
2. **Build-HudArt had resized the backdrop to the screen** (MAPBKGRD 1600x1200, 2026-10-02), so it no longer fitted the 640x480 surface: the corruption.
3. **GAME\AZTEX\MAPS\CORICORI.PCX was a re-quantised copy** (2026-09-22; all 255 palette entries differ). Its palette is the map screen's, so every old map showed in the wrong colours. It is restored from `.orig`: 0 bytes differ from the disc backdrop's palette. The bad copy is kept as `CORICORI.PCX.requant`.

**Fixes (installed; manifest 453 -> 454):**
- **Build-HudArt** keeps MAPBKGRD at 640x480 at every resolution. It was regenerated from AZT.BIN into art\.
- **Patch `map-blit-1589F`** (`$ENABLE_MAP_BLIT`): the blit's call goes to overlay **AztMapBlit**.
  - It returns at once while **`aztOldMapOff`** != 0.
  - Otherwise it tail-jumps to 0x33F80 with edx = x, ebx = y = the 640x480 centred in the view: (480, 273) at 1600x1200.
  - No fixups at the site.
- **Watcher:** Step-Map writes `aztOldMapOff` = 1 every 500 ms in true colour (0 with -NoMap3D). Close-TrueColour writes 0.
- **Retro (no true colour):** the original low-res map, uncorrupted, centred in the view over the frozen frame.
**The pale banner at the top (Josh, 2026-10-14):** with the game's map no longer drawn in true colour, the strip ABOVE the view (screen rows 0..48, outside the host's window, which starts at the view's top) kept the HUD's last frame: the compass and the top band. The map's palette was loaded, so it showed as a pale banner. AztMapBlit's skip branch now covers that strip with the backdrop's own black: the backdrop's bottom rows (the wiped panel band, 322..479) blitted at y = VIEW_Y - 480 (-431), x = 0, 640, 1280. The blit (0x33F80) clips: it takes its source offsets from the clipped rectangle.

**The panel dims while the map is up (Josh, 2026-10-14; per-room light to come):** `Panel.Light` (1 = as drawn) darkens its colour in Present (ScaleRgb: alpha kept) and re-presents on a change. Step-Map sets it to `1 - (1 - MapPanelLight) * mapKNow`, so it follows the map's fade. `-MapPanelLight 0.6`. Later: a room brightness value will feed the same Light.
**Every map was MIRRORED (Josh, 2026-10-14, WASHCORI).** The game's world has the other handedness from DrawMap's look-at, so x came out turned over: WASHCORI's balcony sat on the left of its map and on the right in the room.
- Checked by rendering the room's own view and the map looking the same way (`Test-GpuLook -Yaw 180` vs `-Map -MapYaw 0`).
- Fixed by negating the mvp's x row after the y squeeze.
- The intro wave's axis is negated with it, so it still sweeps from the screen's left to right.
- The drag's yaw sign is flipped (`+= dx * 0.22`), so a drag turns the map the same way it did.
**The visor's lights -- CURRENT design (Josh, 2026-10-14, round 7):** "that pulse with the sort of ribbing light effect is the only one I want to see ... extend indefinitely and off screen". The rounds below are history.
1. **ONE pulse per light** (`beamPulse`): as the echo scan's shell, a bright band with ribs of light trailing it (rings D*0.07 apart, fading over D*0.3 behind). It has NO fall-off with distance.
   - It runs out from the light over `MapBeamPulse` 1.8 s to `MapBeamPulseOut` 2.8x the reach, so it goes well off the screen; it eases out (exponent 1.3).
   - Its fan widens from 15% to the full `MapBeamFan` 40 deg over the first 45% of the run. Soft on both sides (`fanAcross`), with a small glow at the light.
   - Strength `MapBeamPulseK` 0.4 until 72% of the run, then it fades out FLICKERING.
   - Its top edge lies on the spotlight's top edge: middle = axis + atan(`MapBeamSpread`) - fan/2.
2. **Spotlights ride out WITH the pulse** (round 8, Josh: "make the cone glow included in the initial pulse, spanning outward with it ... a bit brighter than how it appears in its final resting version"):
   - the soft round spotlights (`beamCone`) reach only as far as the pulse has (`uMlConeR` = the pulse's radius, a soft 0.2 D edge);
   - they run at `MapBeamBoost` 1.6x their resting strength (`MapBeamK` 0.15);
   - from `MapBeamMorphAt` 0.5 of the run they settle to rest over `MapBeamMorph` 0.9 s, flickering.
   - The lead band: x0.6 ("a bit less bright"), then (round 10, "about 50% its weight ... and 20% more transparent") width D*0.0175 (was 0.035) at x0.48. The ribs are unchanged. Josh: the shape and timing are "perfect".
   - **ONE SHAPE (round 9, Josh: "a wider version of those initial cones, and the pulsing effect needs to adhere to those same shapes"):**
     - The pulse no longer has its own fan (`fanAcross`/the offset middle are gone). `coneAcross` (gaussian about the spotlight's axis, `uMlC`) shapes both the pulse's ribs and the travelling spotlight.
     - Both use one spread (`uMlA.z`): `MapBeamPulseSpread` 0.45 while the pulse runs, easing back to the resting `MapBeamSpread` 0.22 as they settle.
     - The "widening fan" step is gone: a cone already widens with distance. `uMlD` and `MapBeamFan` are unused.
3. **Flicker for good:** the spotlights keep flickering a little, each its own way (`_beamClock`, `MapBeamWaver` 0.06, dips `MapBeamDipOdds` 0.06 x up to `MapBeamDip` 0.35, uniform `uMlFl`).
- **Run time:** about 1.8 s (`MapBeamRun`); the "Accessing Map Data..." badge follows it.
- **Removed:** the plain fan fill and its spreading front (round 6), the sweep, the hard edge line, MapBeamGrow/DrawK.
- `GLSL`: `half` is a RESERVED word; the shader uses `hw`.
(History) **The visor's lights (Josh, 2026-10-14: "very subtle 'lights' that come from the top left and right portion of the lower UI ... as if this lighting was drawing the map, and then still persisting as a very faint, cone shaped glow").**
- **Where:** two light-teal (`MapBeamInk` 0xA6F0E6) cones start at the panel art's two corner horns: art column 18, row 15 from the image origin, the right one mirrored about x 800. The watcher works them out from art\wide\wide.json (gameX0/gameY0/k) into `GpuRaster.MapBeamView`, which takes VIEW px with rows from 49.
- **Aim:** they point at (`MapBeamAimX` 0.5 of the picture width, `MapBeamAimY` 0.5 of the view's rows). Each cone has a small soft glow at its source.
- **Drawn in FS_COMP's map block** (`beamCone`, uniforms `uMl*`; `uBeam*` already belong to the flashlight). They are screened over the map view before the interlace, with a little grain so the faint gradients do not band. The emitters are placed in the picture from the compose map itself (SetComposeMap derives `_cmX0/_cmSx/_cmVr` from cxi/riy).
- **Timing:** `MapBeamT` is the seconds since the map opened (the watcher sets it from mapIntroClock).
  - **While it pulses in:** the cones are at `MapBeamDrawK` 0.26 with a faint shimmer, and a hot narrow core (`MapBeamRayK` 0.45) runs down each cone's axis.
  - **THE SWEEP, mirrored (Josh, 2026-10-14: "make the panning animation symmetrical, the spotlights should scan from top to bottom, so from the opposite upward corner downward, then to their resting place"):** each WHOLE cone turns. It starts aimed at the TOP CENTRE (Josh, 2026-10-14: "start them pointing higher so the scan is bigger"; it was the opposite top corner, too close to rest to read as a scan) and swings down to `MapBeamLow` 0.92 of the view's rows at the far side over `MapBeamDown` 0.7 of the pulse-in. It then eases back up to rest by the end of the settle, and the core fades as it does. The angle is worked out for the left light and mirrored for the right (uniform `uMlD` = the two directions). It replaced a first version whose ray followed the left-to-right wave, which made the two sides move differently.
  - **"Accessing Map Data..." badge (Josh, 2026-10-14):** the room cover's ScanTag (ScanWire.cs) -- now CENTRED just above the panel, its plate `AbovePanel` 20 px (at a 1238-row view) over the view's last row = PanelTop (Josh, 2026-10-14, for this badge and the room cover's alike) -- with `MapText` and the bar filling with `GpuRaster.MapTagProgress`. It shows while `MapTagK` > 0: from the map opening to the end of the settle (pulse-in 1.1 + 0.9 s), then fades over 0.3 s. It only runs where the materialize label does (not under -NoMaterialize).
  - **Afterwards:** over `MapBeamSettle` 0.9 s they settle to `MapBeamK` 0.15, a faint cone that stays.
- **FANS, not spotlights (Josh, 2026-10-14: "flat on one side, and fanning outward on the inner portion in a triangle shape where it fades"):**
  - `beamFan` draws each light as a wedge `MapBeamFan` 30 deg wide: a crisp straight LOWER edge (about a pixel of softening), with light opening above it that fades as (1 - phi/fan)^2 toward the open side and with distance.
  - The sweep turns the fan's middle; its flat edge lies half the fan below (`uMlD` = the flat edges, side +1 left / -1 right).
  - The bright line during the sweep now runs ALONG the flat edge.
  - Strength rest/draw 0.21/0.30 (was 0.15/0.26 for the cones; a fading wedge carries less light).
  - The fans end by 1.6x the distance to the aim.
- **Round 3 (Josh, 2026-10-14: "a little wider and slightly brighter, but also when they come to rest, have them fade into the previous spotlight versions ... make sure the starting point is the top middle, so they would overlap at first"):**
  - `MapBeamFan` 40 deg; the fans' strength `MapBeamDrawK` 0.36 (with the shimmer) all through the sweep.
  - **Hold at the start:** each fan's middle starts ON the top middle and HOLDS there `MapBeamHold` 0.35 s, the two overlapping. The lights fade in with the map (x MapK, 0.35 s), so without the hold they had already left the top before they could be seen. The down sweep and the way back now start after the hold.
  - **Melt into spotlights:** as a fan comes to rest it cross-fades (`MapBeamMorph` 0.7 s, starting a quarter of that before it stops) into the original round spotlight (`beamCone`, axis = the fan's middle, `MapBeamSpread` 0.22, strength `MapBeamK` 0.15), which is what stays. Uniforms: `uMlC` = the cone axes, `uMlA.w` = the morph, `uMlK` = (fan, edge line, cone).
  - The badge's span includes the hold.
- **Round 4 (Josh, 2026-10-14):**
  - **Flat edge on TOP.** "we need each starting point to point to the top center ... Then they will span inward/downward": the fan is placed by its flat UPPER edge (side -1 left / +1 right in `beamFan`) and opens DOWNWARD. That edge starts exactly on the top centre, where the two edges meet and the fans overlap below, then sweeps down to MapBeamLow and back.
  - **Rests on the spotlight's TOP edge:** "make their final resting point the top edge of the spotlight versions". The edge rests at the cone's axis + atan(`MapBeamSpread`), so the fan lies over the spotlight it melts into. The cone's axis stays fixed on the aim.
  - **Grows in:** "they span out from their projection points rather than simply appearing". `uMlGrow` 0..1 over `MapBeamGrow` 0.45 s: the reach grows from the light with a slightly brighter front. The hold on the top centre is now `MapBeamHold` 0.45 s.
  - **Flickers as it fades:** "have the fan versions flicker a bit as they fade". During the morph, in steps of 1/24 s, a random dip to 15-65% (`FlickNoise`), more often as it fades. The fan's strength (`uMlK.x`) carries the fade and the flicker.
  - `MapBeamDrawK` 0.30 ("a touch less bright"). The whole run is ~2.9 s.
- **Round 5 (Josh, 2026-10-14):**
  - "make the opacity the same as the faded spotlight versions": `MapBeamDrawK` = `MapBeamK` = 0.15. The edge line scales with it.
  - The fans' spreading FRONT ("a pulse ripple effect that I liked", his pick) is boosted: its glow factor in `beamFan` went from 0.6 to 1.5, about 0.22 effective against 0.18 before the halving.
- `-NoMapLights` turns them off. Offline: `Test-GpuLook -Map -MapIntroAt s` passes s to them too.
- First try (draw 0.42, spread 0.30) washed the whole upper view: too strong.
**The map-close "dead space" (Josh, 2026-10-14):** after closing the map, sometimes a flat #101010 block covered part of the view, a different shape each time.
- **Cause:** the compose took as the key whichever colour was COMMONEST in the game's view (Overlay.ReadOnce). The map screen leaves much of the view black, so for the frames until the game had painted the key back, black was the commonest colour and was taken for the key. The real key's pixels (#101010, index 86 here) were then laid over the picture as the game's own.
  - Confirmed by sampling Josh's screenshot: the block is exactly #101010.
  - Its top edge fell on the bottom visor band, whose stretched x mapping explains why it reached past the game's own columns.
- **Fix:** the key the host hands the game (`tcPal32[keyA]`) is ALWAYS see-through as well: `Overlay.KeyAlso` / `GpuRaster.KeyAlso` (shader `uKey2`), in both the card's and the processor's compose.
  - The key's palette entry is unique (Initialize-TrueColour), so no game drawing can match it.
  - The watcher warns once if the measured key ever differs from the palette's.
**Map rules beyond parts (Room Review round 26, 2026-10-14):** rooms\<ROOM>.json `"map"` now takes:
- `"hide"`: part names (as before).
- `"hideMaterials"`: material or texture names, e.g. `"BLACK"`, `"10-n_black.png"` or `"n_black"`. Write `"part/material"` to limit an entry to one part (MINEHEAD: `"stuff/BLACK"`, the ceiling inside the main mesh).
  - Names come from the room's OBJ/MTL (`Get-AztTexNames`): the texture order is the first-`usemtl` order with the untextured materials (TRANSPARANT, ATRANNIE) left out.
  - A unit may end with a spare unused 1x1 texture (MINEHEAD's 49th), which is allowed.
  - `Tex.Leaf` is only set when the true colours load, so it is NOT used.
- `"hideBelow": y` with `"keep": [parts]`: a real CUT. `Get-AztMapCut` -> `GpuRaster.SetMapCut(y, bool[] per triangle)`; `BuildMap` clips the flagged triangles with `ClipMapBelow` (Sutherland-Hodgman).
  - Walls that run on down under the floor end at the cut. New vertices are shared per edge, and BuildXray welds by position, so the cut shows as a clean edge.
  - The complex map (`Get-AztComplexGeo`) clips its rooms the same way. `Get-AztMapSkip` also drops what lies WHOLLY under the cut.
  - `keep` parts are exempt from the cut and from room-wide hideMaterials.
- `"hideBoxes": [{ "box": [x0,y0,z0,x1,y1,z1], "part": optional }]` (round 27, MINEHEAD/13: the two shafts inside the kept chasm mesh): triangles whose middle lies inside a box leave the map. A box overrides `keep`. It does not clip: use it for things wholly inside. (A clipping cut-out box was drafted for MINEHEAD/12, the floor sheet past the east wall, but Josh dropped that note.)
- Answering a map note: `Reply-RoomNote -RenderFile <img>` attaches a before | after of the MAP. `tools\Render-MapBeforeAfter.ps1 -Room R -Yaw -Pitch -Zoom -Out` swaps in rooms-history\round-NNN\<ROOM>.json for the "before".
**Pick-ups off every map (Room Review MINEMAZE/12, round 28, 2026-10-14: "Omit all items that are able to be picked up from the player from all maps"):**
- No data file marks a pick-up. OBJECTS.DAT's 603-byte records hold only names and text (the trailing bytes are identical leftover memory), and OBJLIST.DAT is `name, 0` x 567.
- An item reaches the inventory only through the scripts: interpreter jump table at 0x2AC9C (opcodes 0..0x28; command byte op + word object id at +1). Op 08 = AddInventoryItem (case 0x2AFAC -> 0x288E2); 09 = remove.
- The decoded scripts are in memory: word [0x1841F0] = list count, [0x1841F4] = 6-byte {word count, dword -> command pointers}. world.dat is parsed by 0x3DB5C (19 record types); a raw byte search of world.dat for `08 id` does NOT work.
- **Watcher `Update-Pickups`** (when a map opens, once a session; retries every 10 s until the world is loaded):
  - collects every op-08 id and maps it to OBJECTS.DAT record id's part (+0x78);
  - trusts that mapping only if the live object table ([0x1841D0], name at +0x3F) matches the display names for >= 80%;
  - writes <CacheDir>\pickups.json {parts, objects}.
- Get-AztMapSkip hides those part names in EVERY room. The map caches (watcher $mst, Get-AztComplexGeo, the review server's mapview) refresh when the file changes.
- NOT YET SEEN RUNNING (written 2026-10-14 without the game). Look for "pickups:" in watch.log.
