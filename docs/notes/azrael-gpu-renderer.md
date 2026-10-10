---
name: azrael-gpu-renderer
description: The GPU (OpenGL via P/Invoke, tools\GpuRaster.cs) draws, sharpens and composes the true-colour picture by default; all 4 phases done 2026-10-06, matched to the CPU (compose bit-identical). F9 = processor. Driver traps inside.
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-06T03:54:17.815Z
---

**Plan Josh approved (2026-10-05):** Phase 0 go/no-go (textures only, measure) -> Phase 1 core look
(room level, flashlight beam, fog, torch, filtering, characters; parity-checked offline, judged in
game with a CPU/GPU key) -> Phase 2 shadows (lamp + torch), water reflections, dust -> Phase 3
sharpen + HUD compose on the GPU. CPU renderer stays as automatic fallback (other people's
machines) and for the F8 original-textures view.

**Why GPU is possible now** (not a contradiction of [[azrael-opengl-verdict]]): that verdict was
about the game's own engine inside DOSBox. The true-colour picture is drawn by our host renderer
into our own overlay window ([[azrael-true-colour]]), so the GPU is free to use.

**Phase 0 as built:** `tools\GpuRaster.cs` -- hidden STATIC window + wglCreateContext (AMD gives
4.6 compatibility), GL 1.1 via DllImport, later functions via wglGetProcAddress delegates (no
SharpDX/NuGet needed). Off-screen FBO RGBA8 + DEPTH32F; reverse Z via glClipControl (depth =
near/z, GL_GREATER, clear 0 = Raster's 1/z). Projection = Raster.Prepare exactly, drawn with y
flipped so glReadPixels returns top row first; front faces CCW. Each Raster.Tex -> RGBA8 texture
with Raster's OWN mip chain (Tex.Rgb levels, BGRA upload of 0x00RRGGBB) + an R8 hole mask from
Tex.Idx at its own size, GL_NEAREST (discard on index 0) -- matches Raster's hole rule. Triangles
bucketed by texture per frame (CurTex changes). Texture cache keyed by Tex object, 1.5 GB cap.
`ReadBack(int[])` into Raster.Color32 so the overlay pipeline is unchanged; `ReadDepth` returns 1/z.

**Measured (tools\Test-GpuRaster.ps1, 2562x1238, full-screen views in CORICORI):** CPU 6.3-7.0 ms
vs GPU 1.3 ms INCLUDING read-back; colour diff 0.5-1.1/255, coverage identical to a few edge
pixels; SPAROOM and MINEHEAD agree too. Card: AMD Radeon 8060S, driver 26.8.1.

**Watcher wiring:** `-NoGpu`, `-GpuKey` **F9** (F10 is the GAME's invert-mouse-Y key -- never use
it). Card set up at session start in true colour, failure = message + CPU. F9 toggles; while on,
the CPU's lamp/torch views, doorways, water and dust are skipped (phase 0 has none); gain fixed at
LampRoomOff. A draw exception switches back to CPU for the session. Disposed after each session.
Frame log's "the draw, split" line says ON THE GRAPHICS CARD with its draw/read-back ms.

**Phase 0 in game (Josh, 2026-10-05 23:56): "insane frame rates ... feels stable".** Log: CORICORI 29 fps
CPU -> ~150 fps card (frame 6.6 ms, room 1.6 ms), SPAROOM ~180, MINEHEAD ~145. Remaining frame
time is the script loop (wait for game ~2.3, pose 0.8, loop start 0.7), not drawing.

**Phase 1 built 2026-10-06:** Raster's true-colour look term for term -- explicit mip level (per-
triangle texel density + log2(depth), MipBias inside; no GL LOD bias), room level + lamp (cone/
halo/spill by screen distance from LampC, falloff by depth clamped at 2046, per-triangle facing),
placed lights (|dd.n| / (d (1 + d^2/r^2))), per-channel clamp, then fog. `CopyLighting(Raster)`
every frame takes everything from the CPU raster the watcher already drives. Offline
(`Test-GpuRaster.ps1 -Lit`, 3 rooms): 0.1-0.6/255, 0-2 stray pixels per view.
**DRIVER TRAP:** a GEOMETRY SHADER on this AMD driver received the same values for all three
corners (gUv/gView constant per triangle, textureSize ~0) even with explicit locations -- do not
use geometry shaders. Per-triangle values are computed in C# and sent as non-indexed vertex data
(10 floats: pos, uv, facing+normal, lod; glDrawArrays per texture bucket).
Still CPU-only (skipped when F9 is on): lamp + torch shadows, water reflection, dust, doorways.
**Phase 1 seen in game (Josh, 2026-10-06): "It looks great".**
**Phase 2 built 2026-10-06 -- the card now draws EVERYTHING and is the DEFAULT** (F9 -> processor,
`-NoGpu` keeps the processor; card failure -> processor for the session, frame redrawn on CPU):
- Shadows: depth-only views on the card (DEPTH_COMPONENT32F textures, near/z) for the lamp (slot
  0/1, `SetLampShadow(i, lampM, w, h, focalPx, ox, oy)`) and each placed light (slots 2-9,
  `SetLightShadow(li, x, y, z, LastBasis, size, focalPx)`); FS ports Raster.ShadowTap/ShadowSoftAt
  exactly (texelFetch, -1 outside, 2 diagonal taps), lim scaled by NearZ, ShadowNear/Far fade.
- Water: `AddWater(triVerts, planeY)`; stencil-mark (depth program, polygon offset 0/64, GEQUAL),
  depth wiped in the stencil by a full-screen triangle at z=0, mirrored room built in C#, drawn
  twice (depth, then EQUAL + blend ONE_MINUS_CONSTANT_ALPHA/CONSTANT_ALPHA with keep), "beyond the
  surface" against a BLITTED COPY of the depth picture (per pixel, x0.998, as MaskBeyond), front
  face CW for the mirror, depth blitted back afterwards.
- Dust: `Motes.Gather(r, buf)` (6 floats/mote) -> `SetMotes`; GL_POINTS of 2*ceil(r)+1 px, blend
  (ONE, ONE_MINUS_SRC_ALPHA) = Motes.Draw's mix + add. Only known difference: a mote half behind an
  edge draws its visible half (CPU skips the whole mote) -- a few hundred pixels per frame.
- Watcher: per-frame setters are USED UP by Draw; the card's Draw runs AFTER the water and dust
  blocks. Frame log "the draw, split" ends "+ THE GRAPHICS CARD x (its draw, read-back; N shadow
  views, pools, motes; MB)".
- Measured (`Test-GpuRaster.ps1 -Full`, 2562x1238): CORICORI CPU 11.6 ms vs card 2.0; SPAROOM CPU
  24.1 vs card 3.1; picture difference 0.1-0.7/255. Also run through the watcher's own draw
  section (cut from the file) in both modes: 0.47 / 0.73 / 255.
- PowerShell trap hit again: `$gr` (loop var) IS `$gR` (a timing list) -- case-insensitive names.
**Phase 2 seen in game? (not yet reported).** **Phase 3 built 2026-10-06:** the overlay's background
work (Raster.PostCore sharpen ~11-16 ms on 3 threads + Overlay.Present compose 4-9 ms) is on the card:
- ONE pass (FS_COMP): sharpen of the pixel's own value (integer, as PostCore) + compose (column/row
  maps from `Overlay.ComposeMap`, visor band map, key test, Mix4 integer blend). Screen reading from
  `Overlay.TakeSurface` uploaded through a mapped PIXEL_UNPACK buffer (0.6 ms).
- NOT WAITING: `PostCompose` + `StartRead` (glReadPixels into a PACK buffer) each frame;
  `FinishRead` at the NEXT hand-over -> `Overlay.ShowComposed(buf)` (buffer swap, spare returned).
  One loop of display delay (~7 ms), as the old worker thread had. Main-thread cost 1.4 ms, same
  as the plain read-back it replaced.
- Watcher: `$script:gpuFrame` = card drew AND tc 'run' AND overlay AND no -AA; then the draw skips
  ReadBack, Add-FpsCounter stamps via `gpu.Stamp`, Step-TrueColour composes on the card. Otherwise
  (F8, -AA, calibration, F9) the old SubmitRgb/PostHook path, and any started card read is dropped.
- Verified: `tools\Test-GpuCompose.ps1` (fake DOSBox screen in its own memory, real Overlay):
  0 differing pixels in 63M, widescreen+visor and game size, also -Pipelined; the watcher's own
  Step-TrueColour run on it: each frame shown one loop later, 0 pixels different.
**Sharpen OFF by default (Josh, 2026-10-06: "not much benefit"):** watcher -Sharpen default 0.0 (was 0.5); the card's compose skips it at uK=0. Phase 3 seen in game: CORICORI ~130 fps, frame 7.7 ms = wait for game 2.0 + pose 1.0 + draw 0.8 + hand-over 1.8 + to game 0.5 + loop start 0.9 + other 0.7 -- the draw is no longer the cost.
