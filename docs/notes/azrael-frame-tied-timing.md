---
name: azrael-frame-tied-timing
description: "Azrael is frame-tied end to end, so emulated CPU cycles drive frame rate AND game speed together; AztMod throttles actors at one call site."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-20T16:53:23.058Z
---

**The game has no delta time anywhere in its gameplay path.**

- Movement is `pos += dir * constant` at `0x1D747` â€” a per-FRAME step, not
  per-second.
- The whole animation system, `0x20000..0x25000` (`ICharacterAnim`,
  `PlayCharacterAnimation`, `DecodeAnimationFrame`), **never reads a clock**.
  Verified by tracing every caller of both timer functions: none lands in range.

So raising `cpu_cycles_protected` buys frame rate and game speed *together* â€”
at `max` the characters move like cartoons. Cycles are one dial, not two.

The game *does* have clocks, just not in gameplay: **`0x1BC5F`** and
**`0x35D50`** both snapshot the BIOS tick at linear **`0x46C`** (18.2 Hz) and
return a millisecond value (`0x162B64` / `0x182DAC` â€” read by the EXE but never
written by it, so maintained by the Miles audio timer callback). They are used
for an LRU resource cache (`[esi+0x10]` timestamps, evicting the oldest) and a
couple of UI timeouts.

## The actor stepper â€” one call site

**`0x261C0`** walks the actor list and advances each actor's keyframe cursor:
`inc word [eax+0x3C]`, **seven sites** at `0x26233..0x26488`, all inside that one
function. `0x2626B` reads the cursor back, scales by the **0x23-byte** keyframe
record and pulls the actor's transform out of it â€” so the cursor drives pose AND
position together, and throttling it slows both coherently.

**It has exactly one caller: `0x13DF0`**, inside the per-frame loop
(`mov eax,0x1521C4` / `call 0x261C0`, gated on `[0x1525F2] == 0`).

That is why `hook-actor` gates the call rather than the seven `inc`s: each `inc`
is 4 bytes, too short for a 5-byte call, while `0x13DF0` is one clean 5-byte
`call` reached once per frame from one place in the whole binary.

`AztActorTick` uses a **percentage, not an integer divider** â€” "every Nth frame"
can only express 1/2, 1/3â€¦, but the honest ratio is old-cycles / new-cycles
(280000/400000 = 70%). It accumulates `aztActorPct` each frame and steps when the
total crosses 100, then subtracts 100. Pure 16-bit integer maths, no FPU, no
clock, and it tail-jumps to `0x261C0` so that function's own `ret` returns to the
game.

`aztActorPct` is published in the manifest settings, so it is tunable in an
installed build without rebuilding: **`AztMod\Set-ActorRate.ps1 <percent>`** pokes
it straight into the installed R.EXE, and the stub reads it fresh every frame, so
only a relaunch is needed.

**The right percentage is not a constant** â€” it tracks the actual frame rate, so
re-dial it whenever `cpu_cycles_protected` changes OR a rendering change lands.
The linear framebuffer ([[azrael-lfb-plan]]) raised the frame rate enough to need
it again: 70% -> ~50%.

## Superseded: AztActorTime, a real delta-time gate (v0.16.0)

**The percentage is the wrong SHAPE of fix.** A fixed share of frames can only be
right at one frame rate, and the frame rate is not one number â€” it depends on how
much geometry the room has. The symptom that proved it: animations too fast in
the opening area, correct after walking through to a heavier one, with nothing
changed in between.

So gate on the clock. **The BIOS tick dword at linear `0x46C`** runs at 18.2065 Hz
regardless of the renderer, and the game reads it exactly that way itself â€”
`0x1BC5F` and `0x35D50` both do `mov eax,0x46C; mov ecx,[eax]`, which also proves
low memory is identity-mapped under DOS/4GW: **no base register, no fixups**.
(Their return values `[0x162B64]` / `[0x182DAC]` are millisecond counters kept by
the Miles timer callback â€” finer, but they go stale if audio fails, so the raw
tick is the safer clock.)

`AztActorTime` accumulates elapsed ticks x 100, steps whenever the total reaches
`aztPeriod`, and loops to catch up if more than one period is due. It **calls**
`0x261C0` rather than tail-jumping (that function pushes esi at entry, so esi
survives), and clamps elapsed ticks to 8 so the first call and any loading screen
cannot make the actors sprint. 128 bytes, living in the freed bank-crossing
region at `0x50F2D`.

`aztPeriod` is in hundredths of a tick: 100 = 18.2 Hz, 50 = 36.4, 200 = 9.1.
Rides with `$ENABLE_LFB`, since that is what makes `0x50F2D` dead.

## â€¦but gating ONE system is not enough

Symptom after AztActorTime shipped: the first room on load still ran at
"hyperspeed", and a round trip through another room and back fixed it â€” same
room, so not geometry.

Proved by test, not guessed: with `aztPeriod` set to 2000 (0.9 Hz, actors
crawling) the first room was STILL fast. So the fast thing never goes through
`0x261C0` â€” confirmed independently, since it has exactly one caller, zero
fixup/vtable references, and all seven keyframe increments inside it.

**The user then reported that their OWN movement is fast too.** Movement is
`pos += dir * constant` per frame at `0x1D747`, so this is not any one animation
system â€” the whole loop is simply running more often. The first room has less
going on (fewer live actors/scripts) than the same room after the game has warmed
up, so it renders faster, and *everything* frame-tied speeds up with it.

**So the divider and the clock gate were both treating a symptom.** The game is
frame-tied in many places; fixing them one at a time is endless. The robust fix
is a **frame limiter** â€” cap the per-frame loop to a fixed rate that every room
can sustain, so everything frame-tied runs consistently. Capping ABOVE the stock
~18 Hz still leaves it much smoother than original while making speed stable.

## AztFrameLimit â€” the actual fix (v0.16.0)

**`AztNow`** builds a ~1.193 MHz timer from PIT channel 0, the counter *behind*
the BIOS tick: `out 0x43,0` to latch, then two `in al,0x40` for lo/hi. It counts
DOWN, so the offset within the tick is `65535 - count`, and the full time is
`[0x46C]*65536 + offset`. The tick and the counter are a two-part read that a
timer interrupt can land inside, so it runs under `pushfd`/`cli`/`popfd` â€”
restoring the caller's IF rather than forcing `sti`.

**`AztFrameLimit`** spins until a whole period has passed. A spin is the right
call in an emulator: the surplus cycles have to go somewhere, and burning them is
precisely what caps the loop. `aztLastFrame` is set to NOW rather than advanced
by one period, so an overrunning frame simply does not wait â€” no debt, no
catch-up burst after a loading screen. Subtraction is unsigned, so the timer
wrapping (~60 min) costs one unthrottled frame and nothing worse.

**It must hang off `AztFrameHook`, NOT the actor hook.** The actor call at
`0x13DF0` is guarded by `cmp word [0x1525F2],0 / jnz` at `0x13DE1` â€” a
hold-the-actors flag that is SET in the opening room and cleared by a room load.
Hanging the limiter there meant the first room ran completely uncapped until you
walked out and back, which is the exact bug the limiter existed to fix, and it
cost a full round of "it's back again". `AztFrameHook` at `0x13DC8` is reached
unconditionally every frame (all of mouselook and WASD depend on it).

It is called by literal address, because `AztFrameLimit` lives in a second blob
assembled *after* the cave stub. It is therefore emitted FIRST in that blob so
its address is exactly `$ACTOR_TIME_AT`, and the build asserts that rather than
trusting it. It preserves every register.

`aztFramePeriod` is a published 4-byte setting, so **`AztMod\Set-FrameCap.ps1
<fps>`** re-caps an installed build without rebuilding. 239 bytes total at
0x50F2D, inside the space the LFB freed ([[azrael-lfb-plan]]).

**The cap is a taste dial with a real trade:** lower is steadier and closer to
the ~18 fps the game was built around; higher is smoother but makes everything
frame-tied move faster than the 1996 design intended. Default 30.

**The cap must be ACHIEVABLE.** If the machine cannot sustain it, the limiter
never waits and speeds start varying by room again. Set it at or below the
worst-case sustainable rate, not the best case.

## Movement constants, rescaled from the cap

Once the frame rate is pinned, every remaining frame-tied constant can be
corrected **statically** â€” no runtime gate, no percentage. That is the payoff of
the limiter, and it is why the old percentage idea is obsolete rather than just
retuned.

Movement is `pos += dir * k` per frame, and k is a plain obj2 float with **no
fixup on it**:

| addr | value | read at |
|---|---|---|
| `0x141800` | 16.0 | 0x1D74D, 0x1D761 (2 sites, run) |
| `0x1417FC` | 8.0 | 0x1D901..0x1DD46 (8 sites, walk + wall slide) |

`move-scale-*` multiplies both by `18.2065 / $FRAME_CAP_FPS`, so distance per
SECOND is unchanged: 16.0 x 18.2065 = 291.3/s == 9.7101 x 30 = 291.3/s. Change
`$FRAME_CAP_FPS` and the scale follows automatically.

18.2065 is the reference because it is the BIOS tick rate, which is what
`aztPeriod=100` pins the actors to â€” so movement and animation share one
reference and stay coherent at any cap. **Actors need no compensation when the
cap changes**; they are already on the clock.

Still frame-tied and NOT yet rescaled: the keyboard/edge turn integrator at
`0x1D1C5` (adds 0x5A per frame, clamped by the double at `0x147238`). Mouselook
is mickey-based and unaffected.

The per-frame loop itself is around **`0x13D00..0x14200`**; `hook-frame` at
`0x13DC8` already lives there. To find what else runs per frame, enumerate that
range's call targets â€” that is how `0x261C0` was found.

See [[azrael-dosbox-staging]] and [[azrael-hud-viewport-locked]].

## AztNow was reading a PIT the game reprograms (fixed 2026-09-20)

**Your instinct "maybe the frame limiter isn't working" was right.** It was
failing OPEN -- not capping at all -- whenever audio held a fast timer slot.

`AztNow` used to latch PIT channel 0 (`out 0x43,0`, two `in al,0x40`) and return
`tick*65536 + (65535-count)`. That is only a clock if the BIOS divisor of 65536
is still loaded. **It usually is not.**

The game installs its own INT 8 handler at **`0x604A2`** and runs a 16-slot timer
service. `0x60640` takes the SHORTEST period any slot requests and reprograms
channel 0 to match via `0x605C8` (`mov al,0x36 / out 0x43,al`, divisor to port
0x40, saved at **`0x14866E`**). Periods are in MICROSECONDS; `0x605F8` converts
with `us * 10000/8380` = us * 1.193182 PIT ticks per us. Miles registering a fast
mixing slot drops the divisor far below 65536, and then `(65535-count)` oscillates
in a narrow band and goes BACKWARDS on every counter wrap -- the unsigned
`elapsed` becomes enormous and the spin exits instantly.

Symptom: opening room uncapped and "too fast", later rooms "normal" (they were
just too heavy to exceed 40 anyway). Room-dependent because the active audio
slots are. It only became visible after 800x600 + Staging made the opening room
fast enough to notice.

### The fix: slot 15 is a free microsecond clock

Slot arrays, read straight off the ISR (`i` is a BYTE offset):

| array | base | slot 15 |
|---|---|---|
| state | `0x148524` | `0x148560` |
| accumulator (us) | `0x148564` | **`0x1485A0`** |
| period (us) | `0x1485A4` | **`0x1485E0`** |
| pending | `0x1485E4` | `0x148620` |

The accumulate loop covers all 16 slots (`edi < 0x40`) but the callback loop only
covers 0..14 (`edi < 0x3C`) -- because **slot 15 IS the BIOS-tick slot**: its
pending counter `0x148620` is the one the ISR uses to chain to the original INT 8.
`0x60753` sets its state to 2 and registers period `0xD68D` = 54925 us = 18.2065 Hz.

So its accumulator is a microsecond count INSIDE the current tick, reset in
lockstep with `0x46C`:

    now_us = [0x46C] * [0x1485E0] + [0x1485A0]

Correct for ANY divisor. Read the period rather than hard-coding it. `mul`
discards edx, so this wraps at 2^32 us ~ 71.6 min; unsigned subtraction makes a
wrap cost one unthrottled frame.

**Resolution is the current PIT period**, so it is fine while audio runs and
degrades to 54.9 ms if nothing wants anything faster -- the cap then becomes
18.2 fps. That is a SAFE failure: the game's own design rate, never too fast.

**`aztFramePeriod` is now MICROSECONDS, not PIT ticks** (25000 = 40 fps).
`Set-FrameCap.ps1` updated to match -- and it still does NOT rescale the
`move-scale` constants, so a cap change needs a rebuild.

## 0x261C0 IS NOT THE ANIMATION SYSTEM (corrected 2026-09-23)

Everything above about `aztPeriod` still holds, but the name is wrong and it
cost two rounds of chasing. **`0x261C0` is a SCRIPT INTERPRETER**: a per-actor
program counter at `[actor+0x3C]` over 0x23-byte opcodes -- move toward a point,
wait, play a sound, *start* an animation. It is worth gating, but it is not what
makes a walk cycle look hurried, and `aztPeriod=400` (4x slower) changes nothing
visible. Its one caller is also skipped in the opening room by the
`[0x1525F2]` hold-the-actors flag, so it is doubly invisible there.

**Animation is driven by Reality Lab MOVE CALLBACKS**, invoked once per RENDERED
frame from the engine's own traversal. `0x44DD0` = `AddMoveCallback`,
`0x44D7C` = `SetTime`. Three callbacks, and **SIX** `+1` sites:

| callback | registered at | advance sites |
|---|---|---|
| `0x229A4` characters | `0x22CE0` | `0x22C05` |
| `0x24090` characters, direct entry | (indirect) | `0x24294` |
| `0x1E2A8` room anims | `0x1E49F` | `0x1E347` (bumps `[ecx+4]`) |
| `0x1E4B0` room anims | `0x1E067`, `0x1E5D8` | `0x1E509`, `0x1E536`, `0x1E568` (bump `[edx+4]`) |

**THERE ARE TWO ROOM-ANIMATION CALLBACKS.** Missing `0x1E4B0` is why the opening
room stayed at full speed while every other room obeyed the gate -- the exact
"leave the room and come back and it's fine" symptom this file already describes
twice for other causes. It can bump TWICE in one frame (`0x1E509` and again at
`0x1E568`), so it ran at up to 2x the frame rate.

**Find these by SWEEPING for the pattern, not by following callbacks.** Following
callbacks found three of six. The two shapes are
`fld1 ... fild [r+4] ... fistp [r+4]` and `inc r / mov word [r+0x284],r16`;
a linear decode of 0x10000..0x60000 with a 7-instruction window finds all of
them. `0x1E536` needs a wider window -- it uses `fxch`/`fadd st,st(1)` instead of
`faddp` and interleaves a fixed-up `mov ax,[0x182DD0]` into the sequence, so only
the nine bytes BEFORE that load may be replaced.

AztMod gates all six on `aztAnimDue`, a word set once per frame inside
`AztFrameLimit` (it already has `now` in eax from `AztNow`, so the clock is
free). One flag rather than per-site accumulators is required, not a shortcut:
animations in a room must step on the SAME frames or they visibly drift apart.
Default `aztAnimPeriod` = 54925 us = 18.2 Hz = the BIOS tick, so animation and
`aztPeriod=100` share one reference. Tunable live: **`AztMod\Set-AnimRate.ps1
<hz>`** (LOWER is slower -- the opposite sense to `Set-ActorRate`).

Holding is safe because every one of these callbacks re-applies `SetTime` from
the frame number each frame regardless, so a skipped frame just re-poses the
animation where it already was.


## The RL move pass is frame-tied too: built-in velocity / rotation (2026-10-04)

0x5B7F0 (called per root child from the scene pass 0x3F1EA, every rendered frame) -> 0x551BC, which besides the move callbacks does `if [obj+0x45]: [obj+0x120] += [obj+0x124]` (rotation) and `if [obj+0x46]: pos(+0x7C/+0x80/+0x84) += vel(+0x128/+0x12C/+0x130)` -- a fixed step per frame. Setters: 0x49D30 (rotation; wrappers 0x29F70, 0x2A7B8) and 0x55450 (velocity; wrappers 0x3B260, 0x3B3B0). Game callers include the script interpreter (0x265C6), character code (0x24608, 0x22D3D, 0x214C4), room anims (0x1DF28, 0x1E01C) and the keyboard-turn code (0x1CC3A, 0x1CDF4). So doors, scripted moves, character locomotion and KEYBOARD TURNING all ran at frame rate -- ~10x fast with the host renderer's cap off. FIX: `AztScenePart0` now skips the whole pass unless `aztAnimDue` is set when the host sets **aztSceneParts bit 3 (value 8)**; the watcher writes 12 (4 = skip draw, 8 = gate move), `-NoMoveGate` writes 4. Engine-drawn mode is unchanged (still per-frame at the 24 cap, i.e. ~20% fast, as always). Consequence: those things now step 18.2 times a second -- correct speed, visibly stepped next to a 130 fps camera; host-side interpolation between pose samples is the follow-up if wanted. NOT YET SEEN IN GAME at time of writing.

**23:15 correction -- the PLAYER is a move callback.** The first gated build made Josh crawl: the movement routine 0x1CF64 (contains 0x1D747) has NO direct caller; it runs as an RL move callback inside the gated pass, stepping by the host-sized per-frame distance, and applies the result at once with 0x3EC20 (set position, handle from [0x162DE4]). The gate now exempts the root child whose handle equals [0x162DE4] (`mov eax,[esp+28] / cmp eax,[esi+0x163DE4] / jz nogate`), so the player and keyboard turning stay per-frame and everything else is on the 18.2 Hz tick. Paid for by dropping the Part0/Part1 skip counters (only AztScenePart2_skips is read, by Start-HostRender.ps1). Overlay 53,239 bytes, 9 free. ASSUMES the movement frame is a direct child of the scene root (per the scene-graph note); if the player is still slow after this, that assumption is wrong. Keyboard turn remains frame-tied (fast when uncapped).

**23:40 -- move gate OFF by default; the player exemption is WRONG.** Live read: [0x162DE4] = handle 3; the scene root has two children (handles 0xA2C, 0xFAC); the movement frame (object 0x89E188, 1 move callback) is a child of 0x9BD1EC = root child 0xA2C. So `cmp eax,[0x162DE4]` never matches and the whole-pass gate always catches the player. Josh hit the crawl repeatedly (though one run reported fine -- unexplained). Watcher now writes parts = 4 unless `-MoveGate`; doors/characters are frame-rate fast again until the gate is rebuilt NARROW: hook 0x551FE (`cmp byte [ebx+0x45],0 / jz 0x5521A`, 6 bytes, no fixups, eax free) and skip to 0x5525F when gated, leaving callbacks -- and therefore the player -- per frame. ~50 bytes of overlay; free it by deleting the unused AztScenePart0/1 stubs and their hook-scenepart sites. The watcher also logs measured player speed per stats tick now.

**23:55 -- NARROW GATE BUILT: `AztVelGate` at 0x551FE.** `jmp` from 0x551FE (6 bytes `80 7B 45 00 74 16` -> `E9 rel32 90`; no fixups, no branch into its middle) to an overlay stub: get delta (call/pop/sub), `test byte [aztSceneParts],8` -> if clear run stock; `cmp word [aztAnimDue],0` -> if zero `jmp 0x5525F` (skip rotation AND velocity); else displaced `cmp byte [ebx+0x45],0 / jz 0x5521A / jmp 0x55204`. Callbacks -- and so the player -- stay per-frame. The whole-pass gate, its exemption, and the unused AztScenePart0/1 stubs + `hook-scenepart-3F1EA/3F202` sites are GONE (sites back to stock). 417 patches, overlay 53,178 bytes, **70 free**. Watcher writes parts = 12 by default again (`-NoMoveGate` = 4). Not yet seen in game. ALSO FIXED in the watcher: on every takeover the build's 24 fps step stayed in place for 250 ms while the loop already ran uncapped (16x walking speed, big enough steps to tunnel) -- with `-CaptureRef` retaking every 8 s that is how Josh fell through the floor. The step is now written from the last measured rate BEFORE the cap is lifted. Measured player speed in that run: peak 291 units/s = exactly the design run speed.


## DOORS: the event scripts and their queued rotations (found 2026-10-05)

Measured per step from the host (`SceneGraph.StepLog`, watcher 'MOTION' / 'steps:' lines): a door turns a FIXED angle every rendered frame -- sdoor02/03 6 deg x 15, doorcor2 10 deg x 8 -- so 58 ms at 261 fps against ~0.8 s at 18 fps, and the wait before it closes is frame-counted too. RL's built-in rotation/velocity are OFF on doors (so AztVelGate never touched them) and it is not keyframes.

Mechanism: frame loop `0x148ED cmp word [0x1525F2],0 / jnz ; 0x148F7 call 0x2D470`. **0x2D470 is `call 0x1CBD4` falling into 0x2D478** (the event-script interpreter, module ~0x2A000..0x2D500). 0x1CBD4 walks the node list at [0x162B98] (0x22-byte nodes: +0 object index into [0x1841D0], +2 type 0 rotate / 1 move, +9 per-step amount, +0xB axis, +0xE steps left, +0x1E next), rotating by word[+9] deg x [0x14681C]=pi x [0x1417D8]=1/180 through 0x29F70 (-> 0x49D30) and decrementing. Nodes come from the script opcode at 0x2B11E (multi-step when word[+0xA] > 1; single-step rotates at once), also 0x2B2FC and NPCOpenDoor 0x260B8, via 0x1CB80. 0x1CD8C is the 'finish everything now' variant (room change).

FIX: `AztEventGate` (patch `event-gate` at 0x148F7): when aztSceneParts bit 3 is set, the call runs only on frames where aztAnimDue is set; skipped otherwise, eax preserved. 418 patches, overlay 53,217 bytes, **31 free**. Not yet seen in game. Dead ends on the way, do not repeat: 0x3B260/0x3B3B0 are scene-graph DETACH/ATTACH (not velocity setters); 0x261C0 is the CHARACTER action interpreter; the room-anim callbacks 0x1E2A8/0x1E4B0 are one fixed room animation and the 15-frame walk bob.

## CORRECTION 2026-10-05: 0x2D478 is the STATUS LINE, not the event-script interpreter

0x2D470 = `call 0x1CBD4` (door-rotation queue stepper, its ONLY caller) falling into 0x2D478,
which formats the hovered object's name ([0x146870]) and "Holding : %s" and draws them; nine
other sites call 0x2D478. AztEventGate originally replaced the frame loop's call at 0x148F7,
so the hover text was drawn on ~1 frame in 7 under the host renderer -- Josh: "cursors aren't
lining up, I can't click on an entire door". Now the gate replaces the call AT 0x2D470 and
tail-jumps to 0x1CBD4; 0x148F7 is stock again. Installed, 418/418 verified, NOT yet confirmed
in game. If picking is still off after this, the gate was not the (whole) cause.

## 2026-10-05 01:25: the status-line fix did NOT cure the pick -- OPEN

Josh after the narrowed gate: door speed fine, but hit areas are "off to the side" and some
items never give the contextual cursor. So the gate was not the cause of that. What is known:
pick = 0x116E4 -> 0x3BBC4 -> 0x3C554 -> 0x3C1A4, which builds its view from the CAMERA frame's
cached world (camera+0x8C, at 0x3C32F) and does its own viewport setup (0x59404, 0x58FE4);
the host draws from the MOVEMENT frame (aztCamRec +172), the camera's cached world is at +28.
Modded cursor->viewport is (x-0, y-49), bounds 1600x927. Unproven suspect: the pick camera is
stale/different under host render. The watcher now logs `PICK` lines (game hovered object vs
host part under the cursor, camera disagreement, render level) -- read those before theorising.