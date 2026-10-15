---
name: azrael-true-colour
description: "Escaping the 256-colour palette: approved plan (2026-10-05) = host's own click-through window over the viewport, game gets a flat key colour. Phase 0 built and offline-tested, AWAITING Josh's in-game gate. Plan file + what each phase is."
metadata:
  type: project
---

Josh (2026-10-05) asked to escape the 256-colour palette; plan approved the same day
(`C:\Users\josh\.claude\plans\snoopy-wandering-curry.md`).

**Why this route:** the guest cannot carry true colour (`vmemsize = 4`, every blit/fade/movie is
1 byte a pixel, overlay has 8 bytes free). DOSBox runs `forced-borderless` + opengl on a
2560x1600 desktop, so another window can sit on top. Room textures are already 32-bit PNGs.

**Phase 0 (BUILT, offline-tested, NOT yet seen in game)** -- `-TrueColour`, shortcut
"Azrael's Tear (Host Renderer - true colour)", `Play-HostRender-TrueColour.cmd`:
- `tools\Overlay.cs`: layered + transparent + topmost + noactivate window on its OWN thread
  (per-monitor DPI aware; PowerShell is not, it sees 1707x1067), which scales (bilinear,
  1.5 ms to 2134x1238) and blits with SetDIBitsToDevice.
- The game is injected a FLAT KEY index (auto: darkest palette-unique colour in 54..254; was
  index 86 #101010) instead of the picture. The finished screen is read from DOSBox's 32-bit
  1:1 display surface (same one Capture-Palette reads); non-key pixels in the viewport are the
  game's own drawings (reticle, cursor, text, visor frame edges) and are laid over ours.
- The key is MEASURED each frame as the commonest colour in the view: follows palette fades,
  and a view with no dominant colour (< `-TcMinShare` 400/1000: movie, full-screen menu) hides
  the overlay. Also hidden when DOSBox is not in front, when Set-Engine3D hands back, and after
  400 ms without a frame.
- Finding the surface: calibration frame = key + one 256x128 rectangle of a second index at
  (400,200); scan DOSBox regions for rows [>=32 X][256 Y][>=32 X] x128 one stride apart; then
  move the patch (1000,620 / 250,560 / 1100,180) and keep the copy that followed. Needed because
  the viewport is as wide as the screen and the game overdraws its top/bottom rows and left edge.
- Any failure -> `Stop-TrueColour` -> the 8-bit picture is injected as before.
- Phase 0 shows the SAME 8-bit picture through the palette: it proves the route, not colours.
- `tools\Test-Overlay.ps1` = offline checks against a fake surface. `-TcRect x,y,w,h`,
  `-TcNudge dx,dy,dw,dh`, `-KeyIndex` for placement trouble.

**Gate (Josh, in game):** alignment, no lag/tear between view and HUD/cursor, clicks/keys fall
through, movies + alt-tab behave. Fail -> fallback is a DOSBox Staging fork (needs a C++
toolchain; separate plan).

**Then:** Phase 1 `tools\Raster32.cs` (BGRA textures, bilinear + real mips, lighting as true
multiplies with the SAME constants, smooth shadows, alpha reflections, render at overlay size
in bands; match the palette look first). Phase 2 integrate (skip the 8-bit render). Phase 3
later: coloured lights, fog, ripple, upscaled textures re-test, camera interpolation, HUD art.

Trap hit again: `$sw` IS `$SW` (stopwatch vs screen width) -- see [[azrael-powershell-silent-traps]].
A byte[] RETURNED from a PowerShell function arrives as object[]; hand it over in a script variable.

Related: [[azrael-tier-a-host-render]], [[azrael-view-injection]], [[azrael-palette-budget]],
[[azrael-texture-remaster-verdict]] (upscaling was judged inside 256 colours; re-test after Phase 1).

## First live run (2026-10-05 13:30) -- the route WORKS, the read was the fault

Josh: "floating white rectangle and otherwise black", then the view "at very very low frames".
Log: patch found in SIX places, overlay shown at 2134x1238 at 214,65 (DOSBox client 2562x1601),
key held 812/1000 -- but the first live copy took **277 ms to read 5.9 MB** (driver-mapped
memory), inline, so 3-5 fps; and the search took 4.4 s (the white rectangle).
Fixed 13:34, not yet re-run: (1) every live copy is timed, fastest wins; (2) the surface is
read on its OWN thread (`ReaderLoop`), the frame never waits on it; (3) regions whose first MB
takes > 6 ms are searched last and only if nothing fast has the screen.
If every copy turns out slow, the view will still be full speed but the game's own drawings
over it will lag -- then read less (only rows that held overlays) or less often.

## Phase 0 PASSED (13:36 run), Phase 1 BUILT (not yet seen in game)

Second run: five live copies of the screen at 0.4-0.5 ms each, overlay on screen, 60-65 fps.
Josh: "everything is running as expected but it looks no different" -- correct, phase 0 showed
the 8-bit picture. Phase 1 is what changes it.

**Phase 1 as built -- NOT a separate Raster32.** The true-colour pixel stage lives inside
`Raster.DrawFastCore` behind `Rgb`/`Color32` (`EnableRgb()`): coverage, depth, masks, shadows and
all triangle setup are shared, so the 8-bit path stays bit-identical (Test-RasterFast) and the
RGB path has identical coverage/depth by construction (`tools\Test-Raster32.ps1` checks it).
- `Tex.Rgb` = mip chain of 0x00RRGGBB; `LoadRgb(png)` for painted originals, `EnsureRgb(pal)`
  otherwise. Idx still decides holes (index 0), nearest texel.
- Units do not store texture names: `Add-AztRgb` (LoadRoom.ps1) re-derives the order (OBJ
  `usemtl` first-use order x .mtl `map_Kd`, PNG exists) and falls back to palette colours for a
  whole unit if any PNG size disagrees.
- Pixel: bilinear, blended between two mips (triLod + log2 depth, no dither); gain =
  (LampRoom*baseK + facing*LampPower*cone*dist*(1-occl)) * MaskDim as a real multiply, clamped.
  Reflections alpha-blend over the saved water colour (`_under32`) instead of dithering.
- Cost offline: 4.5-5 ms vs 3 ms for 8-bit at 1600x928. Mean difference from the 8-bit picture
  2.5-5.4/255 (same look), 16k-117k colours a frame instead of ~150.
- Watcher: on with `-TrueColour` unless `-NoRgb`; **F8** (`-RgbKey`) flips between true colour
  and the 8-bit picture in the overlay. FPS counter stamped via `Overlay.StampPal`.
- KNOWN GAPS: still rendered at 1600x928 and scaled to 2134x1238 (native-size render is next);
  `r.Color` is UNLIT while Rgb is on, so -SaveFrames/-Audit/-CaptureRef are not meaningful with
  true colour; portals (-Portals) untested in RGB; -TexScale textures get no RGB.

## Native-resolution render (built 2026-10-05 14:06, not yet seen in game)

Josh saw Phase 1 ("fascinating", a bit soft) and chose higher resolution next, with a hard
requirement: **this will be distributed, so nothing may be tuned to his machine** -- he floated
1920x1080 or 2560x1600. Answer built: NO fixed resolution. The picture is drawn at whatever
size the viewport occupies on the player's screen (`Overlay.RectW/RectH`, measured from the
DOSBox window): 1440x835 on 1080p, 2134x1238 on his 2560x1600, capped by `-TcMaxPixels`
(3.2 M, so 4K is scaled down evenly by default); `-TcScale` for slower machines; `-TcGameSize`
= old behaviour.
- `$r` is created at that size in Invoke-Session; the game still gets the 1600x928 key frame.
- `Overlay.Present*(…, pw, ph, …)`: the game's 1600x928 drawings are laid over the bigger
  picture with bilinear weights (key-aware 4-tap), 1.9 ms at 2134x1238.
- If true colour gives up mid-session the raster is the wrong size to inject:
  `$script:tcRestart` ends Invoke-Session and the outer do/while starts it again at game size.
- Followed the size: FPS stamp, pick probe (cursor scaled), Save-HostFrame (saves Color32 when
  RGB). Audit/CaptureRef are skipped in true colour.
- Offline at 2134x1238: 4.2-8.1 ms true colour (vs 2.5-5.1 8-bit), coverage/depth identical.
- NOT scaled with the picture: the shadow maps (still 964x560) -- edges may look coarser.
- Josh's other ask, queued AFTER this: the HUD panel is still the game's 8-bit drawing. Offered
  level 1 (same art un-squeezed where the static panel shows, dynamic parts keyed through) vs
  new artwork; he has not chosen yet.
- Keep in mind for distribution: anything machine-specific (paths, captured palette file,
  DOSBox fullscreen mode) needs the same treatment eventually.

## Native res CONFIRMED running; edge smoothing + sharpen built (14:17, not yet seen in game)

14:11 run: "drawing at 2134x1238", 50-55 fps, render 11 ms. Josh: "not sure I see the
difference" -- expected and explained: textures are mostly 256x256 (some 128/64), ~8 screen
pixels a texel on a full-screen wall, so the ART is now the limit, not the renderer. He chose
"light sharpening and anti-aliasing" next.
- `Raster.PostRgb(smoothEdges, sharpen)` on Color32, result swapped back into Color32:
  FXAA-style (luma from 4 diagonals, contrast gate `range >= 10 and range*6 >= max`, 4 bilinear
  taps along the edge) then a clamped unsharp (green decides the push, held between the 4
  neighbours' min/max, same delta to R and B). ~4 ms at 2134x1238 offline (2.5 + 1.7).
- Watcher: on in true colour; `-NoAA`, `-Sharpen 0.5` (0 = off), **F9** (`-PostKey`) toggles both.
  Logged as "picture WxH; edge smoothing on, sharpen 0.50: N ms a frame".
- Remaining options offered: AI-upscaled/detail textures (the 8-bit verdict no longer applies),
  HUD in true colour (level 1 vs new art, still undecided).

## Replacement textures in true colour (built 14:2x, not yet seen in game)

Josh: smoothing + sharpen "looks good". He then asked to put the September hi-res slab
`C:\Games\RaptorMod\textures\incoming\08-ecrflra2.png` (1254x1254, already relit to the original's
shadows) back into room 1 -- HE raised it, so the "do not propose texture remastering" rule in
[[azrael-texture-remaster-verdict]] is satisfied, and its two blockers (256 colours, the 4.5 MB
guest texture cache) do not apply to the host renderer at all.
- `-TexOverrideDir` (default `C:\Games\RaptorMod\textures\hires`): a PNG there named like the
  texture's exported file replaces its RGB at ANY size (`Add-AztRgb -OverrideDir`). The original
  is loaded first (proves the order) and its Idx still decides holes, so replacement art must
  keep the original's layout. Game files and guest memory untouched. Log: "REPLACEMENT ART from".
- 08-ecrflra2.png copied into hires\. Offline pair: C:\Games\RaptorMod\cache\tc-test\override-pair.png.
- NOTE: 09-ecrflra2.png is the SAME art in another slot (also used by R1.mtl) and is NOT overridden.

## Frame-rate pass (built 14:40, not yet seen in game)

In game after AA+sharpen and the 1254 slab: 30-40 fps, "render" 16-20 ms, post 6-8 ms (was
50-55 fps). Josh asked whether running both renderers was the cost and to optimise WITHOUT
removing features. Answer: no -- with Rgb on the 8-bit path is one nearest-texel read and a byte
write per pixel. Measured offline (CORICORI, 2134x1238, bench in scratchpad):
| | before (16 thr) | after (30 thr) |
|---|---|---|
| 2 lamp views | 3.1 | 1.8 |
| clear | 1.1 | 0.5 |
| main draw | 10.6 | 6.4 |
| smoothing + sharpen | 5.5 in the loop | 3.1, OFF the loop |
What was done:
- `[MethodImpl(AggressiveInlining)]` on SampleBi / Mix / SamplePx (biggest single win).
- True colour uses ProcessorCount-2 threads (per-pixel work is memory-bound; SMT helps). 8-bit
  path keeps half, unchanged.
- `Overlay.SubmitRgb` + worker thread: after-effects (`AztTool.PostJob`, attached with
  `$job.AsHook()` -- PowerShell cannot write `[Func[int[],...]]`) and compose run off the frame
  loop; the raster gets a spare buffer back (`$r.Color32 = $o.SubmitRgb(...)`). A picture still
  waiting when the next arrives is dropped (counted).
- Green stands in for luma in the edge test (no separate luma pass). Parallel clear.
  `Raster.DrawDepthPair` draws both lamp views at once.
- The key frame is no longer written to DOSBox every frame (1.48 MB): only the ready flag;
  full re-send every 30 frames and on every takeover.
- NEW LOG LINE every 4 s: "frame N ms = waiting for the game + pose + draw (lamp views) +
  hand-over + to the game + other". READ THIS before optimising further -- ~7 ms of the old
  frame was unaccounted for (suspects: the two Sleep(1) handshake waits, PowerShell itself).
- Nothing removed; picture identical (Test-RasterFast, Test-Raster32, Test-Overlay pass).

## The breakdown, MEASURED in game (14:49 run), and the second pass (built 14:53)

CORICORI, 2134x1238, AA+sharpen on, hi-res slab: **frame 20-22 ms (45-50 fps) = waiting for
the game 2.3 + pose 1.2 + draw 13 (lamp views 3.0) + hand-over 0.1 + push 0.4 + other 3.2.**
0 pictures dropped; effects 6 ms on their thread. So the "missing 7 ms" = wait + pose + script.
- Draw was 13 in game vs 9.9 alone because draw (30 threads) and effects (16) overlapped: 46 on
  32 logical. Offline with both running: 30/16 -> draw 12.0; **26/6 -> draw 9.6**. Now
  draw = N - N/5, effects+compose = N/5, lamp views half the draw each.
- Guest loop fell 400 -> ~230 fps with every core busy (that is the "waiting for the game").
  Watcher now runs at BelowNormal priority in true colour so DOSBox's one thread always wins.
- "other" is PowerShell itself (hundreds of statements a frame, a ProcMem.Read = OpenProcess +
  read + close each). Next line of attack if wanted: move the per-frame loop body into C#.
  NOT done: spinning on the ready flag instead of Sleep(1) (an earlier run starved DOSBox).
- Log line now also splits out "loop start" and "probes".

## Batch AI upscaling of textures (2026-10-05 15:1x) -- first room done, not yet seen in game

Josh: the 26/6 thread build "looks really good". Next ask: up-res textures IN BATCH (ChatGPT is
one image at a time). **His standing requirement: the textures ARE the lighting -- new textures
must keep the original's black space and painted light/shadow exactly.**
- He first downloaded the Python SOURCE (Real-ESRGAN-master: needs Python+PyTorch, none here,
  AMD GPU) -- wrong package; then the portable `realesrgan-ncnn-vulkan-20220424-windows`.
  Copied to **C:\Games\RaptorMod\sources\realesrgan** (exe + models; his desktop copies untouched).
- `tools\Upscale-Room.ps1 -Room X [-Sheet] [-Revert] [-Force]`: room's map_Kd PNGs from
  C:\Games\RaptorMod\cache -> flatten alpha to black -> 16-texel WRAPPED pad (tiling survives) ->
  one Real-ESRGAN run over the folder (x4, realesrgan-x4plus) -> crop -> **LIGHT LOCK**:
  out = upscaled * blur(original enlarged) / blur(upscaled), per channel, wrapping 3x box blur,
  reach `-LockTexels 2` original texels -> C:\Games\RaptorMod\textures\hires\<same name>.png.
  CORICORI: 21 textures in 17 s; low-frequency light error 0.3-3.4 -> 0.05-0.7 of 255.
- The hand-made ChatGPT slab was moved to C:\Games\RaptorMod\textures\hires-retired\ at his request.
- HONEST READ of the output (sheets in upscale-work\CORICORI-sheets: plain | upscaler | final):
  crisper block edges and cleaner surfaces, lighting intact, but the usual ESRGAN "smoothed
  painting" look and NO invented stone detail -- less dramatic than the generative slab he liked.
  If he wants that look in batch: generative upscaler output can be fed through the same light
  lock (it is exactly what makes arbitrary new art safe).
- RAM: a 1024 texture + mips is ~5.6 MB; a room of 21 is ~120 MB; the room cache holds 8 rooms.
Josh on the first ESRGAN room: "definitely look better, however a touch odd, and still a little
blurry"; asked for higher res, tuning between original feel and upscale, and SPAROOM.
- SPAROOM batch done (19 textures, 14 s), same settings as CORICORI (variant B). 40 files in hires.
- `Upscale-Room.ps1` gained `-Blend` (share of upscaler vs plainly enlarged original), `-Sharpen`,
  `-Grain` (mono, brightness-scaled, none on black) = `Fx.Finish`, all zero-mean so the light lock
  holds; and `-Ladder NAME.png [-LadderX/-LadderY/-LadderSize]` = one picture, 8 labelled variants
  A-H, reusing the saved upscaler output. Ladders written for 08-ecrflra2 and 18-ecrrwl01 in
  C:\Games\RaptorMod\textures\upscale-work\. AWAITING his pick; then re-run both rooms with -Force.
- Told him: more pixels (8x) will not cure the blur -- the model has no more detail to give;
  grain/sharpen is what restores the photographic feel. Other ESRGAN community models need a
  download; generative services remain the route to invented detail.
**Josh's pick (2026-10-05 15:35): "not loving the up-resolutioned textures" -- chose 80% upscaler
+ sharpen + heavy grain = `-Blend 0.8 -Sharpen 0.8 -Grain 2.0`.** Both rooms re-run with -Force
(CORICORI 21, SPAROOM 19). Use these three values for any further room unless he says otherwise;
the script's own defaults are still 1/0/0. His lukewarm reaction to ESRGAN stands: do not push
more rooms through it unprompted.
He liked 0.8/0.8/2.0 "much better", then asked for colour entirely from the original + the grain
texture. Added `-ColourFromOriginal` (hue/saturation from the enlarged original, only luminance
from the upscaler; untouched where the original is black) and `-GrainTint` (share of per-channel
noise). **CURRENT RECIPE for both rooms: `-Blend 0.8 -Sharpen 0.8 -Grain 2.0 -GrainTint 0.35
-ColourFromOriginal`** (ladder panel E). Ladder variants were rewritten around it (A-H).
Josh on the E recipe: "Those look really good now." Then: the small dinosaur creatures of room 1
= **EUGBLD.XAF** (two instances, ZZ0003/ZZ0004; 7 textures, side view is 512 -> 2048), and the
steam room with the trap door = **WASHCORI** (26 textures, 2 shared ones already done). Both run
with the recipe; `Upscale-Room.ps1 -Room` takes a character .XAF name exactly like a room.
hires now holds 71 files. LURKA.XAF (the other creature in room 1, 5 textures) NOT done -- not asked.
Texture file names are shared across rooms (e.g. 11-or_tunnl.png), so one upscale serves every
room that uses the file.
"This is looking really good" -- then asked for the SAME settings at 100% upscaler. All four
(CORICORI, SPAROOM, EUGBLD, WASHCORI) re-run with **`-Blend 1.0 -Sharpen 0.8 -Grain 2.0
-GrainTint 0.35 -ColourFromOriginal`**. This is a trial against the 0.8 version; await his verdict
before treating either as the recipe.
100% upscaler: "I think these look fantastic." He then asked to see 8x in game. `-Scale 8` added:
Real-ESRGAN twice (16x) then a 2x box average; grain and sharpen are sized against the ORIGINAL
texel (radius scale/4) and the coarse grain levelled to the 4x recipe's strength (RMS 0.32).
All four units re-run at 8x into hires (256 -> 2048, 512 -> 4096); ~13 min total (4 min a room).
**The 4x set he called fantastic is kept in C:\Games\RaptorMod\textures\hires-4x** (71 files) --
copy it back over hires to return. Offline: draw 7.1 -> 8.1 ms in room 1 with 8x.
FEEDBACK (2026-10-05): he rejected a tool call that was building a comparison image --
"You don't need to create comparisons, let's just run [it] so I can see in game." For texture
look decisions, just produce the result and let him judge in game; skip offline crops/ladders
unless he asks.

## Optimise + tidy pass (built 2026-10-05 17:07, not yet seen in game)

Josh: "I no longer need the anti-aliasing/smoothing feature we've mapped to F9"; make the F8
view an "original textures" view for players who want the core experience (like F4 for music);
anything else to optimise/clean up.
Last measured in game (17:02, 8x textures loaded): frame 20-26 ms = wait 1.7-2.1 + pose 1.1 +
draw 12-19 (lamp views 3-3.7) + loop start 1.5 + probes 0.8 + other 0.8; edge smoothing was
taking 15-17 ms a picture on its 6 threads (it reads the texture GRAIN as edges).
Done:
- Edge smoothing OFF by default (`-AA` to re-enable; `-NoAA` accepted/ignored). **F9 unbound**
  (`-PostKey 0`). The light sharpen (0.5) STAYS -- I kept it because his words were
  "anti-aliasing/smoothing"; he has not said whether he wants the sharpen gone too.
- Effects threads N/10 (3 of 32) now that only the sharpen runs; draw gets N - that (29).
- **F8 = "ORIGINAL TEXTURES"**: 8-bit palette art, texture filter forced off, no after-effects;
  lamp, shadows and native size stay. F7 only acts outside a true-colour session.
- Pick probe + collision watch are opt-in (`-Probes`): ~0.8 ms a frame and most of the log.
- RdU32 and the two camera reads use the session's open handle (`HostView.ReadBytes`) instead
  of OpenProcess/close per call.
Offered, NOT done (need his word): draw the two lamp views on alternate frames (~1.5 ms);
move the frame loop body into C# (~2-3 ms); retire dead experiments from the watcher (portals,
the 8-bit -TexScale upscaler, audit/capture launchers that do nothing in true colour);
delete ~1 GB of work files (upscale-work 631 MB, hires-8x 105 MB, tc-test 111 MB, frames 140 MB).

## Widescreen (built 2026-10-05 20:58, not yet seen in game)

Josh (after the whole texture set was done: "truly an upgraded game"): lamps/fires DEFERRED (he
wants to place them manually by the textures, later -- there is no light data in the game; a
name/colour scan found nothing usable); fog + dust and frame interpolation still wanted later.
First: doubted the resolution (windowed mode looks small) and asked the view to fill the screen
left-to-right, panel staying 4:3 for now.
- Resolution: the log proves 2134x1238 in borderless fullscreen; in WINDOWED mode the window is
  smaller so the view is drawn smaller -- the size is measured ONCE at session start from where
  the view sits on screen. Play fullscreen for full resolution.
- `Overlay.Wide` (watcher default ON in true colour, `-NoWide` for 4:3): the window spans the game
  window's full width; the picture is rendered that wide (2560x1238 here, 3.17 M px -- just under
  the 3.2 M cap) with the SAME vertical FOV, so the middle 2134 px is exactly the game's view and
  clicking still lines up; the game's own drawings are composed into that middle band only
  (`_cxi = -1` outside -> picture alone); the game's cursor cannot reach the extra width.
  Shadow maps now take the picture's aspect. Pick probe maps cursor into the middle band.
- The visor-frame edges and the top strip exist only across the 4:3 area, so the view pokes out
  past them at the sides -- accepted; "re-skin the interface later".
- (21:05) Josh: "amazing"; asked for FOV 70 and the top/bottom shading carried across the full
  widescreen width. Shading: done -- in the margins, whatever the game draws in the EDGE column
  of its view (visor frame top, panel curve bottom) is repeated sideways (Overlay compose,
  `ix < 0` branch). FOV: NOT done -- vertical FOV 50 is the game's own (measured,
  [[azrael-host-fov-calibration]]); raising it would put objects on screen where the game's
  cursor/hit test does not expect them (clicks miss). Widescreen already raised the horizontal
  FOV 78 -> 88 degrees. Told him; offered a remap of the game's drawings as a risky option.
  **2026-10-13: done the other way** -- the GAME's field is changed with the host's (its pick reads the field live), so
  clicks stay right: 60 by default, F12 50/60/70 ([[azrael-fov]]).
- (22:14) Josh: the frame counter was hidden under the extended shading, and the visor should be
  "shaded top and bottom, curving at the FAR edges" like the original, not curving at the 4:3 line.
  Built: `Overlay.Visor` -- in the wide compose the game's own corner wedges (outer quarter of its
  4:3 view, top/bottom rows) are treated as the view alone, and a frame is shaded on over the full
  width: thin band (`VisorBand` 1.4% of height) curving down into the far corners (`VisorCornerDepth`
  8.5%, `VisorCornerWidth` 22%, bottom 6%, `VisorStrength` 0.92, curve (1-u)^2.2). The old
  edge-column extension is gone. FPS counter moved to 11% down in true colour (below the band).- (22:25) Josh: "nothing in the middle needed changed" -- the synthesized frame was WRONG. Redone
  as a REMAP of the game's own frame art: in the top 9% / bottom 5% of rows the game's view is laid
  across the full width with its corner wedges (outer 25% of the game's width each) at the far
  corners at the game's own scale and the straight middle stretched between (`_cxiR/_cxfR`,
  `VisorTopRows/BottomRows/Wedge`); all other rows compose as before. No shading is invented.
  Lesson: when he says "same concept as the original", move the original's art, do not redraw it.

## Frames between frames = RE-PROJECTION (built 2026-10-05 22:45, not yet seen in game)

"Frame interpolation" from the ideas list. The camera is NOT 18 Hz: the player's movement is a
per-frame callback (never clock-gated) and the guest loop runs 200-400/s, so the camera is
always fresh; what limits smoothness is our ~35-50 real frames/s. So instead of interpolating
poses, the overlay's worker thread RE-PROJECTS the last real picture to the camera's current
pose between real frames (`Overlay.Reproject`, backward mapping with 3 depth-refinement
iterations, no holes; `SubmitRgb(rgb, depth, pw, ph, min, cam16, focalPx)` hands over depth +
camera, `SpareDepth()` gives the raster a fresh depth buffer; the worker reads the camera from
guest memory itself via `CameraAddr`/`CameraMatrixOffset`). Up to `-WarpHz` 90 extra frames/s,
only when the camera moved, skipped on jumps (>60 units or >~32 degrees). `-NoWarp` = off.
Offline, room 1: a re-projected frame differs from the really-drawn one by 0.6-0.7/255 (vs
7-14 for the stale picture), 3.4-3.9 ms each. Known limits: no new detail is revealed at
silhouettes (slight smear), creatures/doors do not move between real frames, dust is frozen.
Log line: "frames between frames: N re-projected ...".
FIRST RUN (22:49) DIED on the first frame: "'Depth' is a ReadOnly property" -- Raster.Depth was readonly; the session ended and the plain 8-bit injection took over (Josh: "isn't showing true colour... can't toggle via F8"). Fixed 22:52: Depth is a plain field + Raster.SetDepthBuffer(); the hand-over is now exercised offline against a real Raster. Lesson: a new hand-over path must be run against the real class, not only simulated.
SECOND RUN (22:54) died at the first 4-second report: "Attempted to divide by zero" -- my new 'frames between frames' log line used $secs BEFORE the report assigns it ($null -> 0). Fixed 22:56 with its own $secsW. Up to that point the session was healthy (true colour [run], 90 frames drawn). Josh had to launch twice for my bugs; test any new report-line arithmetic with first-report values before shipping.
**The map-close "dead space" (Josh, 2026-10-14):** after closing the map, sometimes a flat #101010 block covered part of the view, a different shape each time.
- **Cause:** the compose took as the key whichever colour was COMMONEST in the game's view (Overlay.ReadOnce). The map screen leaves much of the view black, so for the frames until the game had painted the key back, black was the commonest colour and was taken for the key. The real key's pixels (#101010, index 86 here) were then laid over the picture as the game's own.
  - Confirmed by sampling Josh's screenshot: the block is exactly #101010.
  - Its top edge fell on the bottom visor band, whose stretched x mapping explains why it reached past the game's own columns.
- **Fix:** the key the host hands the game (`tcPal32[keyA]`) is ALWAYS see-through as well: `Overlay.KeyAlso` / `GpuRaster.KeyAlso` (shader `uKey2`), in both the card's and the processor's compose.
  - The key's palette entry is unique (Initialize-TrueColour), so no game drawing can match it.
  - The watcher warns once if the measured key ever differs from the palette's.
- **The white square at fade-to-game (Josh, 2026-10-15).** The calibration patch (`Overlay.PatchFrame`, 256x128, pushed for the first takeover's find/confirm frames) used `keyB` = the palette's BRIGHTEST unique colour (#FFFFFF, index 72), so the DOSBox window showed a white block for a moment at a new game's shutter. `FindPatch` only needs an exact run of a colour unlike the key's, so `keyB` is now the next-darkest unique colour above the key's level (#202020, index 85 here). Falls back to the brightest only if no such colour exists.
