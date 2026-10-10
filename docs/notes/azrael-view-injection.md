---
name: azrael-view-injection
description: "Host pixels CAN be put into the running game's viewport - AztViewInject, hooked at 0x1419D/0x141D2. Plus the tail-call rule that breaks the game if ignored."
metadata:
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-10-04T05:52:00.997Z
---

**Option 1 of the hybrid is PROVEN and confirmed on screen.** Host code can put arbitrary
pixels into the running DOS game's 3D viewport, every frame:

```
host writes staging buffer (overlay BSS)  ->  AztViewInject copies it mid-frame  ->  engine blits it
```

Writing the surface from outside never works — it is a shared pool the 2D/UI paths rewrite
every frame (see [[azrael-host-guest-bridge]]). The copy must happen inside the guest.

## The usable hook sites

| site | calls/sec | pixels survive? |
|---|---|---|
| `0x1419D` (-> `0x3F2F0`) | 22 = frame rate | **yes, 100%** |
| `0x141D2` (-> `0x1F222`) | 22 = frame rate | **yes, 100%** |
| `0x143B4`, `0x143ED` (HUD text) | **0 — never run** | — |
| `0x1434B` | **0 — never runs** | `[0x152AE6]`=0 sends `0x141FB` to `0x14386` |

Staging buffer lives at a FIXED BSS address (`$OVERLAY_BASE + 0x5000`), NOT emitted into
AZTCODE.BIN — `AztOverlayLoad` only reads 16 KB and the build asserts if the blob exceeds it.

## THE RULE THAT BROKE THE GAME

**A displaced call must be re-issued as a TAIL CALL, never `call` + `ret`.**

```
AztInjProbeN:
    pushfd / pushad        ; pushad does NOT save EFLAGS
    ... work ...
    popad / popfd
    jmp <displaced target> ; its own ret returns to the game, stack untouched
```

`call` + `ret` puts OUR return address on top of the caller's stack arguments. `0x38EC8`
reads its argument at `[esp+0x38]`, so every stack arg shifts by 4 — the game hung on the
intro movie. It was latent in the first build only because that site never fired.

**Do NOT hook the generic LFB blitters** (`0x34328` -> `0x50EA5`, `0x3534C` -> `0x513BF`):
they serve the intro movie too, so a probe there runs on unrelated paths.

## Method that paid for itself

Every probe increments a counter BEFORE any early-out. Without it a dead hook site and a
broken copy loop are indistinguishable — which is exactly how the first build failed
silently. Rebuilding with the feature flag OFF is the fastest way to separate "my hooks"
from "something else broke".

## FULL FRAME WORKS, and costs 1.5%

| | |
|---|---|
| staging buffer | `INJ_W * INJ_H` from the game's own heap (`0x32CE0`) at overlay init — **1,484,800 bytes at 1600x928**. The "576 KB" figure below and in the build comments is stale (it is 1024x576) and wrongly suggests a buffer overflow when the host pushes a full frame; the allocation is `A-MovEaxImm $ovl ($INJ_W * $INJ_H)` and tracks the resolution |
| fps injection OFF / ON | **22.3 / 22.0 — a 1.5% cost** |
| surface row 300 | 1008/1024 bytes match (98.4%) |

One flat `rep movsd` of 147,456 dwords; no row loop, because the surface stride (1024)
equals the frame width. The copy being nearly free matches [[azrael-perf-measured]]: the
rasteriser dominates, memory traffic does not.

**The 98.4% is correct behaviour, not a bug.** The missing 16 bytes are the game's own UI
drawing AFTER the injection point — which is the property the hybrid needs.

**The 576 KB comes out of the texture cache** — see [[azrael-texture-cache-reserve]]. First
suspect if big rooms start failing to load.

## TWO RULES FOR ANY HOST THAT DRIVES THE INJECTION (learned the hard way, 2026-10-04)

Three live sessions were lost to these; both are invisible offline.

**1. The handshake is the THROTTLE, not just the signal.** After writing the staging buffer
the host MUST set `aztInjReady = 1`, then wait for the guest to clear it. Omitting the write
left the guest never told a frame was waiting, so the viewport held one stale image while the
HUD kept animating — and because `aztInjReady` then stayed 0 forever, a `while (ready != 0)`
wait fell through instantly and the host hammered 1.48 MB writes into a single-threaded
emulator as fast as it could issue them, until the game died.

**On a sync timeout, DROP the frame — never push anyway.** The guest clears the flag when it
has finished its `rep movsd` out of the buffer; writing while it is still set is exactly the
tear the handshake exists to prevent. At a 1600-wide stride a torn frame reads as **thick
horizontal bands**. One run produced 50 of them in 93 frames.

**2. THE VISOR BOOT ANIMATION OWNS THE SAME STAGING BUFFER.** The build says so plainly
("the visor boot fills this same buffer from guest"). Taking the viewport while it is still
playing is two writers on one buffer: it corrupted the END of the boot animation, put lines
on screen at what would be the normal start of play, and crashed the game.

Gate on **`aztBootState`: 0 = not started, 1 = running, 2 = finished for good.** Wait for
`>= 2`. Nothing in the manifest says whether the boot sequence is even enabled, so a build
without it leaves the flag at 0 forever — bound the wait (30 s) and proceed, or the renderer
deadlocks instead.

**The tell that there is a second writer:** the guest's `aztInjShown` counter ran AHEAD of
the host's pushed count (222 vs 201). A guest displaying more frames than were sent is not a
rounding artefact.

## INDEX 0 IS BLACK *AND* TRANSPARENT — never let the quantiser emit it (2026-10-04)

The rasteriser treats index 0 as a transparent texel (`if (ink == 0) continue`), which is
correct for chroma-keyed art. But `Quant.Map` searched the whole palette **including 0**,
and index 0 in the captured palette is pure black — so every opaque NEAR-BLACK texel landed
on it and was skipped as a hole. In a game this dark that is most of the art:

| room | opaque texels quantised to 0 |
|---|---|
| CORICORI | **80.2%** |
| WASHCORI | 67.8% |
| MINEMAZE | 59.0% |

**One bug, three symptoms** — reported as "transparent walls", "corrupted textures" AND
"lots of bright dots". The dots were not an artefact being added: they were the *survivors*.
Everything dark was punched out, leaving only the brightest texels visible as speckles. The
host frame's drawn coverage went 40.9% -> 99.8% when it was fixed.

The palette has a **second pure black at index 54** (luminance 0.0, identical to 0), so
excluding 0 costs nothing visually. `Quant.Map` now takes an optional `skipIndex`; the five
host-render callers pass 0, and the HUD/art callers (which use `baseIndex` 1 or 128 and
legitimately want 0) keep the old behaviour.

**Diagnostic worth repeating:** count opaque source pixels landing on the transparent index,
and count isolated bright pixels in the SOURCE versus the QUANTISED output separately. The
second comparison is what proved quantisation was not inventing the speckles.

## THE CAPTURED PALETTE GOES STALE, AND IT FAILS AS SCATTERED WRONG COLOURS (2026-10-04)

Textures are quantised to palette INDICES once at load; the game displays those indices
through its live palette, merged at runtime from several PCX files. **Rebuilding the HUD art
moves those entries.** A palette captured 2026-09-27 used against the current build:

* **52 of 256 entries differed, 41 by more than 32 — and all 41 were inside 1..53, the HUD's
  range** ([[azrael-palette-budget]]).
* Index 33 was `73,73,49` (dark olive) and is now `243,166,12` (**bright orange**). The
  quantiser picked it for dark stone; every such texel displayed as an orange dot.
* **7.6-40.6% of every host frame lands in 1..53**, so this is not a rare collision. SPAROOM
  used that range nearly 3x as heavily as CORICORI, which is why some rooms looked far worse.

**The failure mode is the trap.** Only the entries that moved are wrong, so the image is not
obviously broken — it looks like scattered speckles, which reads as a renderer artefact and
sends the diagnosis to texture decoding, UV sampling and quantisation instead of the palette.

**How to tell it is the palette, cheaply:** the host's OWN saved frame is clean while the
screen is not. Our frames had 0-65 orange pixels; the screenshot had 13,082. If what you
hand over is clean and what appears is not, the indices are being displayed through a
different palette than they were mapped against.

**DO NOT verify this by comparing an engine capture to the .pal file** — `Capture-Reference`
WRITES that PNG using the .pal, so the comparison is circular and reports a perfect match.
It cost a round. Re-capture empirically with `tools\Capture-Palette.ps1` (game running,
watcher STOPPED) and diff against the previous file.

`Capture-Palette` now derives W/H/stride from the manifest; its old 1024/576/4096 defaults
were a dead resolution, and since it locates the buffer by matching `mov eax, W*H`, a stale
W/H finds nothing rather than finding something wrong. `Watch-HostRender` warns at startup
when the .pal is older than AZTCODE.BIN.

## SCENE SUPPRESSION CRASHES THE GAME — aztSceneParts = 4 (isolated 2026-10-04)

`aztSceneParts = 4` skips `0x5B820` and forces its caller's `test al,al` down the zero path
every frame, so `0x32E60` never runs. With it on, the game died with

```
RAPTOR ERROR in Rendermorphics ERROR:
Error: object expected in argument
```

after **4, 8, 9 and 19 seconds** of host rendering across four sessions — intermittent, so a
single clean run proves nothing. With it off (`-NoSuppress`, which changes **one guest write**
and nothing else) the same play session was stable. Suppression is now opt-in.

The skip stub is NOT at fault for the obvious reason: it does `xor eax,eax` after `popad`, so
the `test al,al` is correct. The suspicion is that `0x32E60` does bookkeeping as well as
drawing, and skipping it thousands of times leaves an object unreferenced.

**It also buys nothing while the frame cap is on.** The host renders in 5-10 ms and the loop
is pinned at 22.2 fps by `aztFramePeriod`, so the engine's 3D work happens inside time already
spent waiting. The saving is only real once the cap is lifted. Revisit then, narrowing to
parts 1 or 2 and measuring each.

**Capture the game's own report**: `GAME\AZRAEL\AZRAEL.BAT` -> `r %1 %2 %3 2> AZERR.TXT`.
An EMPTY AZERR.TXT is itself a result -- it rules out the texture cache, whose numbers head
every fatal report. (`-Install` rewrites the .BAT.)

## THE LIVE SCENE GRAPH HAS EVERYTHING THE RENDERER IS MISSING (read 2026-10-04)

`tools\SceneGraph.cs` + `tools\Read-SceneGraph.ps1` walk it in C# (per-frame in PowerShell is
thousands of round trips). CORICORI live: **132 frames, 124 carrying a visual**.

* Room geometry sits at **depth 2** with names matching the `.XAF` exactly (`wall01`,
  `floorbit03`, `doorcor01`).
* **Character rigs are present and fully posed** — `ZZ0003EU*` and `ZZ0004EU*`, 8 levels deep,
  every bone with a live world matrix.
* **Instance prefix is `ZZ` + 4 digits.** Strip `^ZZ\d{4}` and the remainder is the character
  `.XAF`'s object name, which identifies the FILE too: the live bone set includes `tailtop`,
  `tophead` and `BLOOD01-03`, which **EUGBLD.XAF (30 objects)** has and EUGENE.XAF (18) does
  not. Same set-cover match `Find-LiveRoom` already uses for rooms.

This is why doors do not animate, picked-up items keep being drawn and characters are absent:
the renderer draws the `.XAF` REST POSE and never consults the graph again. Fixing it needs
object-LOCAL vertices from the exporter (it currently bakes the hierarchy into the vertices)
plus a per-frame name -> world-matrix lookup.

## Latency: wait for the guest BEFORE sampling the camera

Read camera -> render -> wait -> push makes the displayed pose stale by the render time plus
the entire wait, and it feels like mouse lag the frame rate does not explain. Wait for the
guest to release the buffer FIRST, then sample the camera, then render and push.

## The palette is CAPTURED

`C:\Games\azrael-inject\azrael-palette.pal` — 768 bytes, **255 distinct colours**. Captured
by painting known indices through the injection path and reading the result out of the
display surface (`tools\Capture-Palette.ps1`). Contains the magenta chroma key, which
corroborates it.

**Display geometry (derived, not assumed):** a 256-band chart gave 8192 bytes per 2 game
rows, so DOSBox's surface is **1024 px wide, 32-bit, 4096 bytes/row, 1:1 with the game** —
NOT the 2x-scaled 2048-stride surface earlier sessions assumed.

**NEVER use index 0 or 255 as a probe or marker: both are BLACK.** Three attempts failed on
this — "fill 0 then fill 255" changes nothing (3-byte diff) and a 255 marker is invisible to
a non-zero search, which sent the marker hunt onto game content and produced a confident but
wrong answer. Verify any probe pair actually differs before building on it.

## The whole loop works

`tools\Show-LiveRender.ps1`: read the live camera -> Blender renders that exact pose ->
quantise to the captured palette -> inject. 9.2 s, and **the image lines up with where the
player is standing** (verified on screen). `LeTool.Quant::Map` does the quantisation
against the captured palette directly.

## Still open

**The 8-bit ceiling remains**: option 1 delivers geometry, resolution and model quality
inside the original game, but never more than 256 colours. That is what pushes an ambitious
remaster toward option 2 (host renders in its own window, game as simulation).
Also unmeasured: continuous per-frame rendering and its latency.

Related: [[azrael-host-guest-bridge]], [[aztmod-patch-framework]], [[azrael-cave-space]]
