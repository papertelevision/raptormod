---
name: azrael-materialize
description: "The visor materializes the room (2026-10-13, v3 -- a load stays dark behind its panel until the view is steady; Scanning... label): after ANALYZING ENVIRONMENT 100%, a loaded game (once its loading panel is GONE: Step-LoadGuard) and a new game's boot animation -- a teal WIRE front outlines the whole room outward, a slower TEXTURE front follows with a lingering trail of outlines + specks; the water fades in with it. ~3 s. GpuRaster.StartMaterialize; -NoMaterialize; Test-GpuLook -MaterializeAt s."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-13T02:00:00.000Z
---

Josh (2026-10-13): "The visor 'materializes' the room. This ties into the new loading readout. When ANALYZING ENVIRONMENT reaches 100%, surfaces sweep in from an amber scan wireframe to full texture in a fast wave, as if the HUD has just rendered the room ... after the loading of a new room, like a pulse of the outlines of the wireframes. It should also occur when loading a game (after handed off to game after loading so the player can see it) and after the intro bootup sequence animation when starting a new game. This pulse outline of the polygons will be the teal color we've used." **BUILT 2026-10-13, checked offline, NOT yet seen in game.**

## Round 2 (Josh, 2026-10-13, after seeing v1)
"make the water join the wave too. Also the wave happens too quickly ... much more smooth/sleek ... a lingering trail after the main illuminations. Perhaps some dot based small pixels also surrounding the trailing pulse ... see the full wireframe being outlined in the outward manner even if they extend beyond the players visibility to remove ... a brief flicker of lines ... I never see the UI spanning in from the left/right because it's always happening in the background behind the loading screen, as is this new effect." -> v2 below. **Checked offline, NOT yet seen in game.**

## How (v2)
- **Two fronts from the eye, each easing up from rest** (`EaseFront(u) = u - (1 - e^-3u)/3`, x speed):
  - **wire front**: `MatWireSpeed` 950 units/s; it draws every polygon's outline over dark teal glass, flaring as it passes. It runs ahead of the textures, so the WHOLE room is wired before they arrive (no lines popping in late);
  - **texture front**: `MatDelay` 0.3 s later at `MatSpeed` 520; the surface comes up under a soft glow band (`MatBand` 80);
  - **trail**: behind the texture front the outlines stay at 75% and fade with `exp(-(seconds since the front passed) / MatTrail)`, MatTrail 0.9 s, plus a faint teal haze;
  - **specks**: one pixel in each 3x3 screen cell may light (pcg3d hash, re-drawn 12x a second), teal..flare; densest at the texture front (2.8% of cells), then the trail (1.4%) and the wire front (1.2%). `MatDots` scales them (0 = none). v2's first try at 10% covered the screen in SPAROOM.
- **Reach**: on the sweep's first frame `UpdateMaterialize` measures the farthest vertex from the eye (cap 4000); the sweep ends once the texture front is past it plus 3 trails + 2 bands, so nothing is cut short. CORICORI ~3 s all told.
- **Uniforms**: `uMatz` = (texture front, band, wire front, on), `uMatX` = (clock s, MatTrail, MatSpeed, MatDots), `uMatC/uMatF` teal / flare. Computed once a frame (`UpdateMaterialize`, called in Draw before the passes) and shared by MainUniforms and WaterUniforms.
- **Outlines**: VS_MAIN gives each corner a barycentric from `gl_VertexID % 3`; FS_MAIN takes `fwidth(vBary)` at the top (before any discard); 1.5 px lines.
- **Water** (FS_WATER): `matR` = the same reveal as the room's; pass 0's glow and pass 1's colour x matR, its alpha `1 - sh*matR` (so the unrevealed water lets the dark glass under it through).
- **Not in the sweep**: particles, the compose's fog/shafts/mist (they light the dark room a little before the textures arrive), the shader flames, reflections (uRefl).

## Round 3 -- a load shows nothing until it is all in; "Scanning..." (Josh, 2026-10-13)
"on loading a new game, it still loads the game in the background ... the game starts, hidden, behind the loading screen, and when it hands off to the viewport the visor animation is complete already, and the new wireframe animation is choppy. It should load the game and the textures all together, not displaying any of the game until all loading is complete ... a small 'Scanning...' label ... in the lower right of the visor area ... on screen the same amount of time as the wireframes". **Checked offline (label through the present pass); the load flow NOT yet seen in game.**
- **Found (watch.log 09:06:58, a title load):** the title was told the view was back on the renderer's FIRST frame (Step-TrueColour), the same second as the true colour search, 24 scanner wireframes and the panel's first build (frames ~38 ms); and BootHd's thread let the HUD go by itself the moment the game reached play (state 2, `BootHd.cs` M_DONE branch), fighting Step-LoadGuard's HoldOff -- so the slide-in was spent behind the title.
- **Now, while a load's panel is up (Step-LoadGuard):**
  - `BootHd.HudWait` -- the boot never releases the HUD itself (its beats, a re-boot, play); `HudIn()` clears it.
  - `GpuRaster.MatHold` -- the room is the sweep's start (dark glass, no outlines; water hidden), so the panel fading out shows nothing of the game; `StartMaterialize` lets it go on the frame the sweep begins.
  - **The panel lets go only once the view is steady:** the view's coming up (`Set-LoadViewUp`, at the boot's reveal or when the panel would have finished) starts a count of loop intervals; `Test-LoadViewSteady` = the last `$LoadSteadyFrames` (12) each <= 1.5x their median + 4 ms, >= 0.6 s after it came up, 12 s at most. Title load: `Request-TitleLoadShown` -> `Complete-TitleLoad` (TitleLoadShown, PickedSlot -1). Memory-core load: FinishReading waits the same way. Logged "load: the view is steady (...)".
  - Then, the panel gone: HUD slides in (its sound) and the sweep starts, together.
- **The label (ScanWire.cs `ScanTag`):** the damage badge's glass plate + corner brackets mirrored to the lower right (x right = 94.5% + 0.8 em, bottom = 86% of the view rows; em = view rows / 58, min 12), teal: a turning radar sweep, "Scanning" with its dots ticking on, a thin bar filling with `GpuRaster.MatProgress` (texture front / reach). Flickers on, fades with `MatTagK` (1 until the texture front passes the room's reach, then out over 1.5 trails). Drawn by GDI+ (premultiplied) 40x a second, laid over by the card's present pass (`GpuRaster.SetTag` / `TagOn`, FS_PRESENT `tagOver`, unit 7) -- never a read-back. Shown for every sweep (room change, load, new game). Off with -NoMaterialize; not in -Retro / -CpuPresent.
## Round 4 -- the wireframe through walls (Josh, 2026-10-13)
"Is it possible to see these wireframes through walls? Many of the rooms have the player positioned behind a door on first arrival, and I see only the wireframes of a small portion of the room ... so the player sees the full room mapping wireframe would be ideal." **Checked offline (CORICORI, SPAROOM, WASHCORI, MINEHEAD, BAPTIST); NOT yet seen in game.**
- **GpuRaster `DrawXray`** (step 3b', after the holograms, before flames/ghost/dust/particles; only while a sweep runs, not in the dark-glass hold): every edge of the room's own geometry -- not `Tex.Moves` (characters), not `Tex.Ghost`, not invisible volumes (triTex -1), and NOT an edge between two faces of one flat surface (normals within 0.9995: the room's shape, not its triangulation) -- gathered once a sweep (`BuildXray`: vertices merged at 0.05 units; 1,065-1,497 edges a room) and kept on the card.
- Drawn as the holograms' screen-constant quads (VS_XRAY; cut at the near plane instead of dropped), halo + core, added (alpha left alone for the fog). **Only where the room hides them**: the picture's depth is copied (`Blit(_fbo, _surfFbo)`, the water's copy, free by then) and FS_XRAY discards a pixel unless its distance (`uNear / gl_FragCoord.z`, reversed depth) is more than `MatXrayMargin` (3%) + 2 units beyond the shown surface's -- the room's own pass draws the outlines in view, so nothing doubles. Verified with a debug classification: visible edges come out "on the surface", the rocks' far sides "hidden".
- Timed and faded exactly as FS_MAIN's outlines (same fronts from the eye, same `lines` formula), x `MatXrayK` 0.6. Widths `MatXrayCore` 0.8 / `MatXrayHalo` 3 px at 1200 rows.
- Switch: `GpuRaster.MatXray` (no watcher flag; -NoMaterialize turns the whole sweep off). Test-GpuLook prints "materialize: lines through walls N edges"; `-XrayMargin` sets the margin (testing).
## Round 5 -- the scan recedes along its path (Josh, 2026-10-13)
"I'd like it to recede away (IE disappear) on that same path slightly faster. Currently a lot of it hangs around and then all fades at once." **Checked offline (MINEHEAD 0.7/1.1/1.5/1.9/2.4 s); NOT yet seen in game.**
- Why it hung: the texture front (520/s) was far slower than the wire front (950/s), so the whole room sat wired for seconds, and the lines' trail was an exponential tail (0.9 s) -- dim leftovers everywhere that went at the end together.
- Now the texture front IS the recede front: `MatSpeed` 1100 (~16% faster than the wire's 950), `MatDelay` 0.6 s; it would only catch the wire front ~4,200 units out (past any room's reach, capped 4,000). The trail is a defined edge: `trail = 1 - smoothstep(0.35, 1, behindT / (MatSpeed x MatTrail))`, MatTrail 0.35 s (~385 units) -- lines stay full just behind the texture front and are wiped by a soft edge, in FS_MAIN and FS_XRAY alike; 0 ahead of the front (no haze/specks on the unrevealed room). The sweep ends at reach + one trail + 3 bands; the label fades over one trail + a band.
- MINEHEAD: whole sweep ~2 s (was ~4.5 s), the wire band visibly travelling out and erasing behind itself.
## Triggers (Watch-HostRender.ps1)
- `Stop-RoomCover 'ready'` sets `$script:matPending`: the room's first real frame starts it.
- A new game: BootHd.Mode 'reveal' -> 'done'.
- **A loaded game -- Step-LoadGuard** (called each loop before the CAM1 check): from the moment a load starts (title PickedSlot >= 0 or VisorMenu.ReadWait) it holds the HUD panel off (`Panel.HoldOff`) and drops any pending sweep while ANY loading panel is up (title screen `GameGate.TitleShowing`, `VisorMenu.AnyPlaying`, `BootHd.Covering`). When the last one goes, `BootHd.HudIn()` (else HoldOff false) slides the HUD in from the sides and the sweep starts. Safety net: after 45 s it lets go anyway (logged).
- `-NoMaterialize` (GpuRaster.MaterializeOn). -Retro: none (GPU only).

## Checked offline (v2)
Test-GpuLook -MaterializeAt 0.25 / 0.6 / 1.0 / 1.6 / 2.4 / 3.4 in CORICORI: outlines grow out from the eye; the whole room is wired by 1.0 s; textures roll in by 1.6 s with the outlines trailing and specks; faint lines at 2.4; clean at 3.4. SPAROOM 0.9 / 1.7 / done: the pool fades in with the front (its near part first); the finished frame matches the normal one.
Related: [[azrael-room-cover]] (the readout it follows), [[azrael-gpu-boot]] / [[azrael-gpu-default-boot]] (BootHd modes), [[azrael-scan-wire]] (the teal).

**Scanning label moved to the lower LEFT (Josh, 2026-10-13: "on the left side of the visor, not the right"):** ScanTag.Render x = W*0.055 - em*0.8 (the damage badge's and the conversation badge's corner; none of them shows while a room materializes).

**...and then to the MIDDLE, just above the panel (Josh, 2026-10-14: "move the 'accessing map data' badge to the middle, just above the UI by about 20px padding, same goes for the 'Mapping Environment' badge"):** x = W/2 - w/2, its plate `AbovePanel` 20 px (scaled from a 1238-row view) above the view's last row (PanelTop). The same badge also serves the 3D map ("Accessing Map Data...") and the echo scan (amber "Gathering Environmental Data..."); the strongest of the three shows.
**Its words are now "Mapping environment..." (Josh, 2026-10-13; ScanTag.Text, was "Scanning").**
