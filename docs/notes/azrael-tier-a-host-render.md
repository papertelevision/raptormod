---
name: azrael-tier-a-host-render
description: "Tier A chosen 2026-10-03: host renders the viewport, 8-bit injection. aztSup3D is the host-written 3D kill switch; the manifest now publishes the view geometry and the overlay symbol map."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-04T03:41:41.592Z
---

**Josh chose Tier A on 2026-10-03**: the host renders the 3D viewport and injects 8-bit
frames through the proven `AztViewInject` path, with the game left running as the simulation.
Tier B (a DOSBox fork with a hypercall and 32-bit compositing) is deferred because it needs a
C++ toolchain this box does not have — see [[azrael-re-tooling]].

Justified by measurement, not hope: the engine's scene pass is **95.6% of the frame** and the
offload ceiling is **x24**, rising to ~x36 in heavy rooms. See
[[azrael-3d-block-anatomy]] for the numbers and how they were obtained.

## `aztSup3D` — the host's 3D kill switch

`$ENABLE_HOST_RENDER` emits two gate stubs and nothing else. They read a dword **only the
host ever writes**:

| value | effect |
|---|---|
| 0 (shipped) | the engine draws normally — a build with this on is unchanged in play |
| 1 | skip the scene pass `0x3F1B0` |
| 2 | skip the viewport clear `0x3F0D0` as well — what a host-render session wants |

**Deliberately NOT keyed on `aztInjEnable`**, even though "the host is painting" and "stop
drawing 3D" nearly coincide: `aztInjEnable` is the visor boot's flag too, and the boot wants
the engine's 3D left running underneath it. One flag per decision.

No guest code writes it, so the game cannot strand itself without a picture — if the host
dies mid-run the viewport freezes and the next launch starts at 0.

## Two things the build now publishes, because host tools kept guessing

* **`AztMod.overlay.sym`** — every overlay label, sorted by address, written on every build.
  Before this, host tools located overlay variables by hunting byte signatures in
  `AZTCODE.BIN`; that is how a probe once "found" the overlay eight times in a run of zeros.
* **`manifest.view`** — `screenW/screenH/injX/injY/injW/injH/stride/bytes/hookAt`. Host tools
  had hard-coded 1024x576 and so silently belonged to one resolution (`Test-FullFrame.ps1`
  still does). A frame of the wrong width does not fail, it **shears** — the same silent
  failure as [[azrael-mf-stride-trap]].

`injX` is **0 and can only be 0**: `AztInjBody` is one flat `rep movsd` with no row loop, so
the staging stride must equal the surface stride. It had been a PHANTOM — an assertion read
`$INJ_X` while nothing defined it, so it tested `$null + $INJ_W` and passed by luck. Now
defined and the check means something. A check that silently tests nothing is worse than no
check, because it reads as coverage.

## Stage 1: test the LOOP before writing a rasteriser

`tools\HostView.cs` + `tools\Start-HostView.ps1`. The mechanism is proven; the **loop** never
was — the recorded gaps are exactly "continuous per-frame rendering and its latency" and
"a host renderer that must not tear still needs a sync mechanism". So stage 1 pushes a
SYNTHETIC frame continuously and answers three questions in minutes instead of discovering
them after weeks of rasteriser work:

1. host frames/sec through the bridge, 2. guest frames/sec observed, 3. **is it tearing**.

The pattern is an instrument: a bar sweeping once a second (judder shows on a moving edge,
never on a static image), a 64 px grid (shears on a stride error), and **a per-row sequence
byte in columns 0..3** so a frame assembled from two host writes is *detected* by reading the
displayed surface back, not eyeballed.

The fill and the write must both be in C#: one frame is 1,484,800 bytes and PowerShell cannot
fill that per frame.

`-Uncap` lifts `aztFramePeriod` (address from `manifest.settings`) and **makes the player move
far too fast** — movement is frame-tied to a 24 fps calibration. Stand still; it measures a
ceiling, it is not for playing. Every flag is restored in a `finally`.

## A1 RESULT (2026-10-03): the loop works, and sync is mandatory

Two 15 s runs against a live game, 1600x928 frames:

| | capped (host target 60) | uncapped, unthrottled |
|---|---|---|
| host frames pushed | 938 = **62.5/s** | 26,603 = **1,773/s** |
| guest frames drawn | 334 = **22.3/s** (the cap) | 6,034 = **402/s** |
| write failures | 0 | 0 |
| scene passes skipped / drawn | 333 / **0** | 6,033 / **0** |
| torn rows (of 928) | 38 = **4%** | 843 = **91%** |

* **The guest sustains 402 fps displaying host-painted frames** — 18x the 21.4 baseline.
* Against the 522 fps pure-logic ceiling the 1.48 MB copy costs **0.57 ms/frame**, which
  cross-checks exactly against the old "1.5% at 22 fps" figure. At 60 fps it is 3.4%.
* **The bridge is not a bottleneck**: 1,773 frames/s, 0 failures in 27,541 frames.
* The gate is perfect: the engine drew its scene pass **zero** times.
* The 64 px grid was **square, no shearing** — stride confirmed correct end to end.

**Tearing is the only problem, and it is measured, not suspected.** It is the host writing
the staging buffer while `AztInjBody` copies out of it.

## A2 (built, not yet installed): the one-frame handshake

`aztInjReady` is a one-way baton. Host: fill buffer -> set ready -> wait for it to clear.
Guest, in `AztInjBody`: copy only if set, clear it on the way out. One host frame per guest
frame, so the host can never write the buffer being read, and the host paces itself to the
game automatically. Counters `aztInjStarve` (guest had nothing fresh) and `aztInjShown`
(frames that reached the screen) make the pacing visible.

**Gated on `aztSup3D != 0`, i.e. host-render mode ONLY.** The visor boot fills the same
buffer from guest code and has no producer to set `ready`; gating unconditionally would have
silently killed the boot animation.

**The esi trap, again.** esi becomes the copy source, so the "consumed" write cannot read
`[esi+aztInjReady]` after the copy — it would land a megabyte into the staging buffer
([[azrael-inject-esi-clobber]]). The delta is saved with `push esi` AFTER the gate and
restored at a new `AIB_copied` label that **only the copy paths reach**; the four early-outs
jump to `AIB_done` past the pop, having never pushed. Verified in the built blob: exactly one
`push esi` (0x13342A) and one `pop esi` (0x13349E), balanced on all six paths.

## A2 CONFIRMED (2026-10-03): the handshake holds

| | unsynchronised | **handshake** |
|---|---|---|
| host pushed | 626 (62.5/s) | 224 (22.4/s) |
| displayed | 223 | 222 |
| **thrown away** | **403** | **2** |
| rows with a clean marker | 137/928 | **819/928** |
| **host frames mixed on screen** | **24** | **1** (809 of 819 rows) |
| transitions | 70 | 5 |

One frame in, one frame out, 0 starved, 0 timeouts. The host now paces itself to the guest
instead of racing it.

## MEASUREMENT TRAPS, all three of which produced a confidently wrong answer first

**1. Do NOT measure tearing by reading the surface back.** The destination is a SHARED
SURFACE POOL — one allocation aliased by `0x152154`/`0x1521BC`/`0x162E2C`/`0x163A34`, with 54
references across 19 functions, eight in the per-frame draw path
([[azrael-host-guest-bridge]]). Those run *after* the injection, which is the property the
hybrid needs, and they rewrite the buffer continuously. The counts are only valid as a
COMPARISON between modes, never as an absolute tear percentage. A first attempt reported
"78% of rows torn DESPITE the handshake — the protocol is not holding", which was false.

**2. The marker must be MID-FRAME and the read must be ONE SNAPSHOT.** At columns 0..3 the
game's own widgets overdraw it, so a correct frame read as torn on most rows (rows 300/500/700
carried the right sequence; rows 0/1/900/927 carried the game's indices). And a read per row
lets the game draw between reads, so rows milliseconds apart get compared as simultaneous.
Marker is now 4 columns at `w/2`, all required to agree; the whole surface comes over in one
`ReadProcessMemory`.

**3. CONTIGUITY is the discriminator.** A real tear splits the frame at ONE row — one
transition. Scattered disagreement across many transitions is overdraw, not tearing. A single
"% of rows differ" figure cannot tell them apart.

**Surface descriptor `[0x14745C]` field map (measured):** `+0x00` w, `+0x04` h, `+0x18`
bytesPerLine, `+0x1C` pixels — and `+0x1C` must equal `[0x163A34]` or you are reading a buffer
nothing injects into. `+0x08` is NOT the stride (it reads 1); an earlier guess that it was
happened to be rescued by a `max(field, W)` fallback.

## IMPOSSIBLE NUMBERS ARE WORSE THAN NO NUMBERS

A 90 s run ended reporting **"guest frames drawn -14,531"**, 2,319 write failures, and
"restored: aztFramePeriod 0" — then threw `ToUInt32: Value cannot be null`. Cause: the game
had been closed ~89 s in. Once the process is gone every read returns 0, so every delta goes
negative and the "restore" read-back reports a 0 that was never written.

The tool now detects the exit (32 consecutive failed pushes, plus a `Get-Process` check),
refuses to print any counters, guards every `ProcMem.Read` against `$null`, and never claims a
restore it did not perform.

**And the FPS log settled whether it crashed, because the samples are tagged with `aztSup3D`:
a rock-steady 22-23 fps at sup3D=2 right to the final sample means the game was healthy and
simply closed.** Keep `$ENABLE_FPS_LOG` on during host-render work for exactly this reason.

## Cannot install while the game is running

**DOSBox holds `R.EXE` open exclusively**, so `Apply-AztMod` fails mid-install if the game is
up. Build the manifest, wait for the game to close, then install. (Reading guest memory is
fine while it runs — only writing the file is not.)

## Staged plan

* ~~**A1** the loop~~ — DONE, numbers above
* ~~**A2** the handshake~~ — BUILT, awaiting install and a run
## A3 FIRST LIGHT (2026-10-03): the rasteriser renders rooms, ~9x faster than the engine

`tools\Raster.cs` + `tools\Render-Offline.ps1`. Flat-shaded, Z-buffered, backface-culled,
banded across 32 threads, emitting PALETTE INDICES directly.

| | |
|---|---|
| 256ROOM, inside, 1600x928, 94-100% coverage | **4.4 - 7.0 ms** (144-226 fps) |
| the engine's scene pass, same job | 44.7 ms |

**No per-frame colour conversion anywhere**: a shade ramp is picked ONCE out of the
captured palette (near-neutral entries only, sorted by luminance, 1..254 — never 0 or 255,
both black), and the inner loop writes a byte it already has.

**Verify OFFLINE before touching the live camera.** The two things most likely to be wrong
in a new renderer — which way the camera looks and which way triangles wind — are invisible
in any statistic and obvious in a picture. A PNG through the game's palette is the test.

### Three bugs the offline test caught immediately

1. **The view matrix inverse was transposed.** `(t * R^T).x` is `t` dotted with **row 0** of
   R, not its column 0. Axis-aligned cameras hide it completely: views along ±Z rendered
   fine while views along ±X put the model ten units BEHIND the camera, so everything failed
   the near plane and came back **empty with nothing culled**. *That* signature — zero drawn
   AND zero culled — means the geometry never reached the rasteriser at all. **An orbit test
   is what exposes it; a single head-on view never will.**
2. **"700 of 440 triangles drawn."** The drawn counter was per-band, so a triangle spanning
   three scanline bands counted three times. Now a flag per triangle.
3. **The first `DrawTriangles` call measured 9.8 ms against 0.8 ms for identical work** —
   JIT plus `Parallel.For` start-up. A discarded warm-up pass runs before any timing, or the
   renderer's speed is misreported by 12x.

### Shape of the thing

* Banded by scanline, one thread per band, so **no locking anywhere in the inner loop** —
  that is what lets it use all 16 cores. Triangle setup is repeated per band, which is cheap
  next to filling pixels and far cheaper than synchronising a shared framebuffer.
* **Interpolate 1/z, never z** — depth is linear in screen space only in its reciprocal.
* Near plane REJECTS rather than clips: a partially visible triangle is dropped. Visible as
  geometry vanishing at the very edge when you walk into a wall. Proper clipping is known
  outstanding work, called out rather than hidden.
* `-Inside` is the realistic camera for a room. An exterior orbit of an interior space is
  nearly useless — the near wall occludes everything and 90 of 645 triangles survive.

## A3 LIVE (2026-10-03): the chain works end to end; the geometry was the wrong room

Measured in-game, host rendering the viewport with the engine's 3D off:

```
556 frames rendered and injected over 25 s, 22.2 fps (the guest's cap)
  rasteriser              6.81 ms/frame
  rendered coverage       68.5%
  engine scene passes     skipped 556, drawn 0
  surface row 464         1,600/1,600 bytes match the frame we pushed (100%)
```

**Injection, suppression and the rasteriser are all confirmed working in the live game.**

### "It looks 100% identical" was THREE faults stacked, none of them the injection

1. **The test pattern was invisible because of placeholder inks.** `Start-HostRender`
   constructed `HostView` with `(1,1,1)` — bar, grid and background all palette index 1,
   near-black. The only thing visible was the sequence marker: a single line down the
   middle. It read as "injection is broken" when injection was perfect. **A diagnostic
   that cannot be seen is worse than no diagnostic.**
2. **A frozen viewport is indistinguishable from a live one if the player stands still.**
   With `aztSup3D = 2` the engine draws neither scene nor clear, so the viewport holds its
   last frame. "Identical" is exactly what that looks like.
3. **The room was wrong.** See below.

### IDENTIFY THE ROOM FROM THE LIVE SCENE GRAPH, not from filenames or bounding boxes

Guessing `ATUNNEL2` from the name "tunnel" was wrong, and the bounding-box test that
"confirmed" it is worthless: rooms are modelled around their own origin, so **15 of 20
candidates contained the player**. The floor-height coincidence (ATUNNEL2's floor at
y −70.27 against an eye at −70.71) was also a coincidence.

`Read-LiveScene.ps1` settles it in one call: the live objects were `mhbigdoor1/2`,
`mh_smasher`, `mh_saw01..04`, `mhmcontrol`, `zxmineh2R7`, `zxminehdef` — the `mh_` prefix
and `zxmineh*` portal triggers mean **MINEHEAD**, and `MINEHEAD.XAF` exists.
**Object-name prefixes in the live graph are the room's identity.** Room discovery should
be automatic from this, not a parameter.

### OPEN: the camera record and the scene walk disagree

For the SAME frame (`aztCamObj` = 0x89D708) the record's `camWorld` reads
**(0, −70.71, 0)** while `Read-LiveScene` reports **(−158.16, 4.25, −169.62)**. Both claim
to read frame+0x90. One has the matrix layout wrong — likely row vs column major for the
translation (indices 12,13,14 against 3,7,11). `scratchpad\matprobe.ps1` dumps both plus a
direct read of the live frame; it needs the game running.

**Until that is resolved the host camera may be wrong**, and the 68.5%-coverage render of
the wrong room would have hidden it either way.

## TIER A WORKS END TO END (2026-10-03)

```
666 frames rendered and injected over 30 s, 22.2 fps
  rasteriser        6.64 ms/frame
  camera moved 1,156 units and turned 179 deg DURING the run
  guest displayed   665, starved 1
  surface row 464   1,600/1,600 bytes match the frame we pushed (100%)
```

**The player walks around a host-rendered room.** Room auto-detected, engine's rasteriser
off, simulation running, one host frame per guest frame, every probed pixel ours.

### The configuration that works, and why each piece is what it is

| | |
|---|---|
| `aztSceneParts = 4` | skips **only `0x5B820`**, the rasteriser (x17.3 of the cost). NOT `aztSup3D`, which skips the whole scene pass and takes the simulation with it |
| `aztInjSync = 1` | the handshake, **on its own flag** |
| `aztInjEnable = 1` | the copy |
| `aztSup3D = 0` | left alone; the viewport clear costs 0.3% and runs before the injection, so it is harmless |
| room | detected from the live scene graph, never named by hand |

### THE HANDSHAKE WAS SILENTLY DISABLING ITSELF

`AztInjBody`'s ready gate was keyed on `aztSup3D != 0`, on the assumption that "the host
suppressed the engine" and "the host wants a handshake" are the same thing. **They are
not.** The working configuration suppresses the rasteriser via `aztSceneParts` and leaves
`aztSup3D` at 0 — under which the gate was bypassed and the tearing came straight back,
with nothing reporting it. Same class as the phantom `$INJ_X`: **a condition that quietly
stops testing what it was written to test.** Now `aztInjSync`, which nothing else touches.

### 2.0 fps meant MY TIMEOUT, not a frozen game

A run reported exactly 2.0 fps = 500 ms/frame = the handshake timeout firing every frame,
with `aztInjShown` at 0. `aztSupDraws` was **also** 0 — and that counter increments every
frame the gate is *not* suppressing — so `0x3F1B0` was never called and the game was not
in its per-frame path at all. The renderer was innocent. Timeout now 120 ms (still five
guest frames) and **counted**, so a stall is reported instead of the frame rate quietly
collapsing into something that looks like the renderer's fault.

### A diagnostic keyed on the wrong counter says the opposite of the truth

"THE SUPPRESSION GATE NEVER FIRED" fired on every *successful* run, because it checked
`aztSupSkips` (the `aztSup3D` path) while the working setup uses `aztSceneParts`. The
scene pass is *supposed* to be drawn — it drives the simulation. Report
`AztScenePart2_skips` instead.

## THE PREMISE IS PROVEN: 131.9 fps vs 22.2 — a 6x SPEEDUP (2026-10-03)

```
over 25.0s: 3,298 frames rendered and injected, 131.9 fps
  rasteriser              6.21 ms/frame
  guest displayed         3,296, starved 3,232
  engine scene passes     drawn 6,528 (wanted -- they drive the simulation)
  engine RASTERISER calls skipped 6,527
  surface row 464         1,600/1,600 bytes match the frame we pushed
```

**Josh caught that this had never been tested.** Every earlier live run reported 22.2 fps
and I read that as success — but `AztFrameLimit` SPINS until the frame period elapses, so
with the cap in place every millisecond the host saves is handed straight back as
busy-wait. The decoupling had been shown to WORK without ever being shown to be FASTER,
and `Start-HostRender` had no cap handling at all. **"It runs at the same speed as before"
is not a neutral result; it is evidence the thing you are measuring is not reaching the
output.**

### Where the remaining time goes

| | |
|---|---|
| guest, engine rasteriser off | **~261 fps** (6,528 scene passes in 25 s) |
| host rasteriser alone | **~161 fps** (6.21 ms/frame) |
| achieved together | **132 fps** |

**The HOST is now the bottleneck**, not the emulated game — the guest starved on 3,232 of
its ~6,528 frames waiting for frames the host could not supply fast enough. That inverts
the original problem completely. The next gains are in the host rasteriser (6.21 ms for
589 triangles at 44% coverage is slow) and in moving the drive loop out of PowerShell.

### Unexplained, do not assume

The camera travelled 7,147 units of path (378 net) while Josh reported standing still.
Uncapped the game runs ~11x its design rate and movement is frame-tied, so this may be
drift, stray input, or the path metric counting rotation again. **Not evidence of
anything until a metric that separates translation from rotation says so.**

### MOVEMENT IS THE BLOCKER FOR A PLAYABLE FAST BUILD

`$MOVE_SCALE` is calibrated for 24 fps, so uncapped the player moves several times too
fast. The fix is designed but unbuilt, and is recorded in [[azrael-perf-measured]]: the
per-frame step is two floats in obj2 (`[0x141800]` = 16.0 run, `[0x1417FC]` = 8.0 walk),
rewritten each frame from elapsed time via a 256-entry precomputed table, no FPU at the
hook. **The frame cap is load-bearing for the whole frame-tied class, not just movement** —
raising it without that work re-speeds every other frame-tied system too.

## LIGHTING: MEASURED, AND THE ANSWER IS "DO NOT" (2026-10-03)

Built the full 8-bit lighting model — a precomputed shade table (the classic colormap:
nearest palette entry for every index at every light level), distance fog with a curve,
and a per-face `|N.L|` term. One lookup per pixel, never leaving palette space.

**Then scored it against the engine's own frame and it loses to doing nothing:**

```
NO LIGHTING baseline   score 0.1749
best lit setting       score 0.1750   (fog 6x the room span, ambient 1.0 -- i.e. almost no lighting)
```

**This game's textures already have their lighting painted in.** A second pass over the
top can only move the result away from the engine. Josh said "the unlit looks best" from
the first comparison and was right; the measurement caught up later.

Lighting is now **opt-in** (`-Light`). The shade table stays in `Raster.cs` — it costs one
lookup per pixel and is exactly what a torch, a muzzle flash or a dynamic object would
need. It is just not what a static room needs.

### How to tune anything against the engine: `Tune-Lighting.ps1`

Scores a parameter sweep against the engine's captured frame. Three things made it work
that did not at first:

1. **Measure DRAWN PIXELS ONLY.** Index 0 is undrawn background and 57-64% of the frame,
   so a histogram including it is mostly a measure of COVERAGE — every lighting setting
   scored the same because the variable was swamped.
2. **Print enough decimals.** `{0:P0}` showed the engine's 0.79% bright as "1%" and the
   host's 0.3% as "0%", which read as "the host has NO highlights" and sent me looking
   for a bug that did not exist.
3. **Put "don't do it at all" in the sweep.** A sweep can only name the best of what it
   tries; without a no-lighting baseline it would have confidently recommended settings
   that are worse than nothing.

Metric is an **earth mover's distance over a 16-bin luminance histogram**, not per-pixel
difference: per-pixel would be dominated by what the host legitimately does not draw (the
creature rigs, the HUD) and by sub-pixel geometry differences. What is being matched is
the tonal distribution.

Residual gap, unlit: host mean luma 49.0 against the engine's 51.4, bright 1.40% against
2.0%. **A good part of that is probably the two gold creature figures the host does not
draw at all** — they are bright, and they are missing.

## THE INVISIBLE MATERIALS: TRANSPARANT, ACTIVATION, BLACKCOVER

The game names its trigger volumes in the material. `TRANSPARANT` and `ACTIVATION` are
the materials on the `zx*`/`zy*` objects `AZONES.DAT` lists as room portals; `BLACKCOVER`
is a masking quad. **The engine draws none of them.**

CORICORI has 17 `TRANSPARANT` faces and they are large quads lying flat across the floor
— drawing them covered a third of the screen in one colour. The "draw untextured faces
flat" fallback was right for MINEHEAD (whose `stuff` and `minechasm` are real geometry
with no material) and wrong here. **A face with no texture is not automatically a face
that needs one.**

The flat ink for genuine untextured geometry must also be **dark and strictly neutral**:
a mid-luminance pick out of the palette landed on a pink.

## `LoadRoom.ps1` — one copy of the room-loading rules

Merging several `.XAF` files with rebased indices, resolving UVs through the faces,
keying materials by FILE+name, skipping trigger volumes, quantising to the palette. That
logic had been copied into three scripts and a fix applied to one (the TRANSPARANT skip)
did not reach the others — so the live renderer and the comparison tool were drawing
different pictures from the same room.

## Working OFFLINE: `Capture-Reference.ps1` + `Compare-Reference.ps1`

Josh relaunched the game ~15 times in one session, most of them so I could look at
something. Nearly everything needed is readable: `Capture-Reference` saves the room
files, the exact camera matrix, **the engine's own frame from that camera**, and a
per-material texture-coverage report. After that the whole tuning cycle runs offline
against a fixed reference and the game is only needed to confirm a result.

`Render-Demo.ps1` writes an AVI flythrough (walk then pan, because forward motion shows
depth sorting and fog while rotation shows texture stability — either alone hides half).

### Still to do for A3

* textures (decode `.azf`, pre-quantise to the game palette once, perspective-correct UVs)
* near-plane clipping instead of rejection
* the live camera: `SetCameraWorld` takes the engine's frame+0x90 matrix directly and
  asserts rigidity, but the engine's FOV has never been read from its code — only matched by
  eye in Blender. The offline `-Fov` sweep is how it gets settled.

* **A3** the renderer — multithreaded C# software rasteriser. Textures and geometry are
  already decoded ([[azrael-xaf-scene-format]], [[azrael-texture-format]]) and the live camera
  and transforms already read over the bridge ([[azrael-host-guest-bridge]]).
  **Pre-quantise the textures to the game's captured palette ONCE at load**, then the
  rasteriser emits palette indices directly and there is no per-frame colour conversion at all.
* This is also where Josh's original "use more cores" lands: the host rasteriser threads
  across 16 cores, which DOSBox never can.

Related: [[azrael-view-injection]], [[azrael-project-direction]], [[azrael-perf-measured]]


## Host-render frame cap (2026-10-04)

Watcher param `-Fps` (default 60, 0 = off). On takeover it writes aztFramePeriod = 1e6/Fps and on hand-back/exit restores it. Because movement is distance-per-frame it ALSO rewrites the two obj2 step floats [0x141800]/[0x1417FC] every 250 ms as (16|8 x 18.2065) / measured guest fps (from aztCamFrameNo, clamped 10..Fps, 50% EMA), restoring the build's values on hand-back. No guest code. Caveats: a watcher killed with Stop-Process leaves the cap and step in the running game; other frame-tied systems run faster. Untested at time of writing.


## The guest frame cap is QUANTISED to the PIT tick (2026-10-04)

AztFrameLimit spins on AztNow, which only advances per timer interrupt, and sets last = now with no remainder carry -- so a frame lasts a whole number of PIT ticks. Inferred tick 5 ms in play (cap 41667 us gave 45 ms = 22.2 fps; cap 16667 gave 20 ms = 50 fps), so reachable rates are 200/100/66.7/50/40. The watcher now reads the live divisor (dword at obj2 0x14866E, written at 0x605D7; us = divisor / 1.193182), snaps `-Fps` to the nearest reachable rate AT OR ABOVE the request (60 -> 66.7) and writes period = ticks*tick - tick/2. The tick value itself is still UNVERIFIED live -- the first log line after takeover states it. Host delivery was 49 of 50 fps after replacing Start-Sleep in the sync wait; host ceiling not yet measured (`-Fps 200` is the test). Crash-hunt instrumentation (stack ring, heap report, stall dump) is behind `-Diag`; the RL trap readout always runs. AZRAEL.BAT hold loop removed.


## Measured ceiling and the uncapped default (2026-10-04 17:47 run, `-Fps 200`)

Guest tick CONFIRMED 5.00 ms live. Guest loop 196 fps median; **host delivered 63.7 median, 75.8 max**, render 10.8 ms, pose 1.4 ms -- so the HOST is the ceiling (render + 1.48 MB push + handshake), not the guest. Watcher default is now `-Fps 0` = cap removed while rendering (period 0), `-KeepCap` keeps the build's 24; `-Uncap` is retired. An on-screen counter (top right, DELIVERED fps, 5x7 font x4, strips cached per value, stamped by BlockCopy, never index 0) is on unless `-NoFpsCounter`. Next gains are host-side: rasteriser time and the per-frame copy.


## Rasteriser fast path + display rate (2026-10-04 18:10)

`Raster.DrawTexturedFast` / `FastClear` (prepare each triangle once, conservative per-row x-span then the reference's exact per-pixel test, nearest-first sort, local pixel counter instead of a false-shared `px[band]++`, int floor, 4x thinner bands). **Measured by `tools\Test-RasterFast.ps1`: 3.4-4.2x (MINEHEAD 8.57 -> 2.23 ms, CORICORI 7.73 -> 1.85), ZERO differing pixels and identical depth on 160 cameras**, sorted or not. Watcher uses it by default; `-SlowRaster` = reference. Re-run the test after ANY change to the fast path. Display: Staging 0.83 only samples the framebuffer per EMULATED refresh (~70 Hz for this mode) on a 180 Hz panel, so `dos_rate = host` was added to [dosbox] in azrael-staging.conf (backup .pre-dosrate); `host_rate` does not exist in this build. Not yet run in game. With render ~2 ms the frame is now dominated by 'everything else' (2.5-4.4 ms: 1.48 MB WriteProcessMemory, handshake, guest copy) plus pose 1-2 ms.
