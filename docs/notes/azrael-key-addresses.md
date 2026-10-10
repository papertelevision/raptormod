---
name: azrael-key-addresses
description: "Located input, camera, video-mode and viewport code in R.EXE, with linear and file offsets for patching."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-21T20:40:49.929Z
---

## The cave: where the space is, and how to get more -- 2026-09-21

**THE CAVE CANNOT BE GROWN BY RAISING obj1's VIRTUAL SIZE.** That buys address
space, which the loader zero-fills, but there are **no file bytes behind it** for
a patch to write into. `0x133000` is the end of the page image on disk and that
is the hard ceiling. Tried `0x124000`; every stub byte past `0x133000` failed its
expect-check against a file that is not that long.

**The way to get room is to stop assembling routines nothing hooks.** Set
`$env:AZT_DUMP_STUB=1` before running Build-AztMod and it prints every label with
its size. Two were dead and cost 112 bytes between them:

* `AztActorTick` + `AAT_skip` (56) -- hook-actor picks `AztActorTime` in the clock
  blob whenever `$ENABLE_ACTOR_TIME` is on, so the percentage stepper is only the
  fallback. Now gated on `$ENABLE_ACTOR_RATE -and -not $ENABLE_ACTOR_TIME`.
* `AztNoHudOverlay` (56) -- zeroes the HUDTOP/HUDBOT record counts so the overlays
  draw nothing. AztMod now SHIPS both overlays, so nothing had called it in ages.
  Now gated on `-not ($ENABLE_HUD_TOP -or $ENABLE_HUD_OVERLAY)`.

`AztHudPoint` / `AztHudEvent` were already gated out by `$ENABLE_CURSOR_REMAP`.
After this the stub is 1540 bytes with 124 free; the log-in-panel shims take 28.

## Modal-UI flags (which one means what) -- 2026-09-20

The frame hook forces pointer mode when any of these is set. Getting the wrong
one costs a whole debugging round, so they are pinned here with their writers:

* **`0x1523D6`** -- system fold-out / Q menu screen selector. Non-zero = a fold-out
  screen is up. Writers 0x154AA, 0x175FD, 0x2C83B, 0x2C35A, 0x17EAB.
* **`0x152B1C`** -- **A CONVERSATION IS ON SCREEN.** Exactly two writers: 0x17EDE
  sets it in the opener `0x17E52`, which `StartConversation` (0x1B156) calls at
  0x1B2DB; 0x17F77 clears it in the closer `0x17F2F`. Tested six times in the
  keyboard dispatch 0x12B88 (the dialogue list's arrow keys) and in the log draw.
  The opener also drops combat itself at 0x17EBE/0x17EC3 -- so without routing
  conversations to the cursor path, the hook's self-correcting block sees "combat
  off" and switches it straight back on.
* **`0x181F88`** -- **the ORRERY PUZZLE**, NOT talking to people. Its setter
  0x2FB88 loads `orrpuz\sun.pcx`, `orrpuz\orrback.pcx`, `%stop0%d.pcx`. This was
  mislabelled as the dialogue flag for a full release cycle.
* **`0x14721A`** -- a general "modal took over" flag with many writers (0x154A3,
  0x17616, 0x2B024, 0x129B9, 0x12AFB). Not exclusive to anything; use for
  "leave the game alone", never to identify a specific UI.

**Hot-spot screens** are 7 polygon tables at `[0x14712E + N*4]`, all prebuilt at
start-up by 0x2A3F4, into 14-byte slots at `0x164D9C + N*14`. Screen **4 is the
orrery** (two 27/28-point concentric ring polygons, 178,98..374,286). Screen **5
r0 (414,89..583,294) is the story log box** -- which is where dialogue choices are
clicked. Decode the tables before assuming what a screen is.

**The story log box size exists TWICE.** 0x10CF1/0x10D05 (`textbox-h`/`-w`) are the
surface; 0x14FAD/0x14FB2 push 206/170 to build the CONVERSATION list rect via
`0x335EC` (a rect builder: x0,y0,x1,y1 as four words). Shrinking only the first
set laid the dialogue list out against 206 inside a 175-tall box, so the bottom
four options were invisible and unpickable.

Addresses found while scoping a controls/resolution mod for Azrael's Tear (`GAME\AZRAEL\R.EXE`).
Linear → file offsets use the corrected base in [[azrael-le-image-layout]].

**Video**
- `0x33AA8` — video mode setter. `mov ecx, 0x101` at lin `0x33ABB` / **file `0x8550F`** is the
  VESA mode (0x101 = 640x480x8). Only 2 INT 10h sites exist in the whole game.
- Screen clip rect: maxX 639 at lin `0x33A8B` / file `0x854DF`; maxY 479 at lin `0x33A7F` / file `0x854D3`.
- `0x10FEC` — real render-resolution setter. 3D viewport is **552 x 282 divided by the level**
  (keys 1/2/3). Base height 282 at lin `0x11043` / file `0x62A97`; base width 552 at lin
  `0x11067` / file `0x62ABB`. (`0x10AA8` is only the on-screen "-1-"/"-auto-" indicator.)

**Reusable routines** (all Watcom register-calling; esi/edi/ebx/ebp are preserved)
- `0x39080` — `HudPrint(eax = HUD text obj, edx = font, ebx = char*)`, plain `ret`, 43 callers.
  Objects: text obj `[0x1521AC]`, in-game font `[0x15217C]`, boot font `[0x152178]`.
  **This is the primitive for an in-game console.**
- `0x35A45` — `SetMousePos(eax = x, edx = y)`: writes `0x182D6C`/`0x182D6E` *and* the driver
  (INT 33h AX=4). DOSBox's AX=4 does not touch mickey counters (verified in mouse.cpp
  case 0x04), so re-centring every frame does NOT disturb mickey-based mouselook.
- `0x3580C` — `GetMickeys(eax = &out[2])`, INT 33h AX=0Bh.
- `0x38EC8` — `DrawString(eax = surface, edx = font, ebx = x, ecx = y, pushed char*)`, `ret 4`.
- `0x33F80` — `Blit(eax = surface, edx = x, ebx = y)`.
- HUD boot banner "Model 7 Head Up Display" at file `0x184B68` and `0x18548E` (23 chars,
  two copies). Overwriting it is a **pure data** proof-of-life — no code, no load-address
  assumptions.

**3D viewport centre ≈ (320, 188)** — derived from the stock combat edge-turn thresholds
(x 49..589, y 54..322 → a 552x282 view at x 44..596, y 47..329).

**Mouse** (INT 33h event callback, installed by `InstallMouse` at `0x35B63`)
- `0x3584F` — C-level handler. Event bits → globals:
  `0x182DA6` = LMB held, **`0x182DAA` = RMB held**, `0x182D6C`/`0x182D6E` = X/Y,
  `0x182D50`/`0x182D58` = X/Y scale divisors (sensitivity), `0x182DA4` = mouse enabled.
- **`0x182DAA` is read in exactly one place: lin `0x13DD2` / file `0x65826`.** That is the
  mouselook gate — RMB held suppresses the HUD cursor path (`0x1166C`).

**Camera**
- `0x1CF3C` (file `0x6E990`) — `yaw[0x162DF8] += eax; pitch[0x162DFA] += edx`. That is all it does.
  Six callers: combat edge-turn `0x13F71`, PgUp `0x12F9D`, PgDn `0x12FB5`, auto-aim `0x24432/58/0x244E0`.

**Keyboard** — handler `0x12B88`; event struct has ASCII at `+6`, scancode at `+7`.
Scancode dispatch at lin `0x1304D` / file `0x64AA1`. Arrows set edge flags rather than moving:
`0x14721E` fwd, `0x147220` back, `0x147222` turn-left, `0x147224` turn-right, `0x147226` centre.
Turn integrator at `0x1D1C5` (file `0x6EC19`) adds/subtracts `0x5A` per frame, clamped to the
double at `0x147238`. **There is no strafe axis anywhere** — it would have to be added.

**Resolution-change cost**: ~19 call sites pass 640/480 as width/height, but there are **346
hardcoded screen-coordinate immediates** in `0x10000`-`0x33000` (top repeats: 552 x24, 282 x17,
640 x14, 480 x13, 320 x11), plus all HUD art is 640x480 8-bit PCX.

Related: [[azrael-re-tooling]]
