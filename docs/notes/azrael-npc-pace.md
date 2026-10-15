---
name: azrael-npc-pace
description: "NPC pace (2026-10-13): every character at 90% (AztActorGate on the actor stepper + AztNpcStride on the stride, one rate so pose and travel agree; doors/room anims/walk bob untouched); per room 'npcs' block (speed share + pauses) via the host-written aztNpcTab; pauses at 0x2694E: RUN -> the room's pauseAnim, and RUN again from the overlay (EUGENE has NO WANDER: the first version froze them). CORICORI: EUGENE/EUGENB at 0.8, pausing into SNIFF 11-52 (unused EUGBLD frames, the .ANI line added at install)."
metadata:
  type: project
---

Josh (2026-10-13): "slow down the animation of all npcs by a small amount, say 10% ... the 2 creatures in the cori cori room are especially fast, so I need them only to be slowed a total of 20%. Additionally, I'd like them to pause every once in a while, rather than constantly running around. This would give the player an easier chance to scan them." **Built and installed 2026-10-13; the installed code disassembled and checked; NOT yet seen in game.**

## How a character moves (static analysis, R.EXE)
- **TRAVEL, scripts and AI: the actor stepper `0x261C0`.** It is called once a frame from `0x13DF0` (gated by `[0x1525F2]`), through the clock blob's AztActorTime at 18.2 Hz.
  - It walks the character table at `0x1521C4`: 0x6F bucket heads at +2; nodes `{+0 next, +4 name, +8 character}`.
  - `[char+0x3C]` is a script program counter over 0x23-byte opcodes (table `0x26198`: 0 set-anim, 1 move-to, 2 wait (`+0x24D`) ... 9 AttackPlayer).
  - **With no script** (`[char+0x3A]` = 0), the AI at `0x2662E` applies to WALK 2, RUN 5, ATTACK 0xD and FACE_YOU 0x14:
    - `[char+8] < 0` -> AttackPlayer `0x26AE0`;
    - else RandomMovement `0x26C38` -> the mover `0x258A8`, a SPEED `[char+0x10]` step.
  - **Why the wanderers never stop:** `0x26951`. WANDER `[char+0xA]` set and state REST 1 -> `0x23DC8(char, 5 = RUN)` on every step.
- **STRIDE: the move callback `0x229A4`** (`+1` at `0x22C05` -> `[char+0x284]`), on the shared `aztAnimDue`. The same flag also drives the doors, room animations, the walk bob, AztVelGate and AztEventGate, so it must not be slowed itself.
- **Fields** (words unless noted):
  - `+0` instance N (= the host's ZZ%04d);
  - `+8` target (-1 = hunting the player);
  - `+0xA` WANDER, `+0xC` HEALTH, `+0x10` SPEED;
  - `+0x3A` script running;
  - `+0x260` state (byte);
  - `+0x262` AI frozen (conversation);
  - `+0x284` frame.
- **The trap in AztActorTime:** it adds 100 per BIOS tick and ZEROES the accumulator on a step. Any `aztPeriod` from 101 to 200 is therefore every 2nd tick: 50%, not the 90% it says. So the pace is NOT done through aztPeriod (still 100).

## How (guest, `src\Build-AztMod.ps1` `$ENABLE_NPC_PACE`, `$NPC_RATE_PCT` = 90)
- **AztActorGate** (overlay; the clock blob reaches it by the fixed entry **`AztOvlActor` at overlay +21**: `lea ecx,[esi+0x133015] / call ecx`, asserted; blob 410/419 bytes):
  - accumulates `aztNpcPct` and tail-jumps to `0x261C0` 90 times in 100;
  - all travel, scripts and AI pace together.
- **Stride:** AztFrameAll derives `aztCharDue` (the animation tick thinned by the same `aztNpcPct`) once a frame. AztAnimStep holds a character's frame unless AztNpcStride says go.
- **Per character:** `aztNpcTab`, 4 x `{dd character, db pct, db strideAcc, db aiAcc, db hold}`, written by the host.
  - AztNpcStride: that character's own stride share.
  - **AztNpcAi** (`0x2662E` `mov dh,[eax+0x260]` -> `call; nop`): dh = 0 when its AI step is not due (0 is not an AI state).
  - **AztNpcHold** (`0x2694E..0x26966` -> `call; jmp 0x26966`):
    - hold set on a calm wanderer -> RUN -> REST (`0x23DC8(char, 1)`), and no restart;
    - not if hunting (`+8 < 0`), dead (`+0xC` = 0), scripted (`+0x3A`) or talking (`+0x262`);
    - otherwise the game's own restart, byte for byte.
  - When the host clears hold, the game's own restart sets RUN again.

## How (host, `tools\Watch-HostRender.ps1` Step-NpcPace)
- **A room's `"npcs"` block** (rooms\<ROOM>.json): `"NAME": { "speed": 0.8, "pauseEvery": [6, 12], "pauseFor": [2.5, 4.5] }`.
  - **speed** = share of the ORIGINAL pace. The per-character pct is `speed / (aztNpcPct / 100)`, so 0.8 gives 89.
  - Names are the game's actor names (the character table's node+4).
- **The table:** every 0.5 s the host finds the named characters and writes their entries; empty slots are zeroed. A room change clears it.
- **Pauses:** each character has its own timer flipping the hold byte.
- **Logged** once a room per character: "npcs: EUGENE in CORICORI at 80% of the original pace, pausing now and then".
- **CORICORI:** EUGENE and EUGENB (both EUGBLD.XAF, SPEED 12) at 0.8, pausing 2.5-4.5 s every 6-12 s.

## Notes for later
- **A pause is the REST pose** (EUGBLD's REST is frame 0, a still stand), switched to instantly like any stock animation change.
- **EUGBLD.XAF has unused keys at frames 11-52** that no .ANI references; frame 0 matches frame 11 on the root. They are a possible idle clip ("SNIFF 11-52" in EUGENE.ANI), not yet rendered to check.
- **Never clear WANDER from the host.** Saves keep `+0xA`, so a save taken mid-pause would leave a statue. A save mid-pause stores REST, and the restart heals it on load.
- **Script waits count `0x261C0` steps**, so timed scripted events are 10% longer too (by design: "all NPCs").

## Round 2 -- they froze; the sniff (Josh, 2026-10-13)
"the creatures in that room are now frozen in place. The idea is that they would still run around, but pause every once in a while. Explore that sniffing animation too as that would be perfect to include in the pause, and maybe its already built in." **Fixed and installed 2026-10-13; NOT yet seen in game.**
- **Why they froze:** the first pause switched them RUN -> REST and left the restart to the game's own WANDER rule (`0x26951`). **EUGENE.ANI has no WANDER line**, so that never fires: their running is kept up by the AI alone, and REST is not an AI state. The first pause began 6-12 s in -- during the new game's reveal -- and they stood for good.
- **Fix -- the overlay restarts what it paused.**
  - Hold byte `[entry+7]`: bit 0 = pause, set and cleared by the host; bit 7 = paused, set by AztNpcHold when it switches RUN -> the pause state.
  - With bit 0 clear and bit 7 set, it clears the byte and, if the character is still in the pause state, sets RUN (`0x23DC8(char, 5)`). If something else changed the state (shot, scripted), the game decides.
  - The host releases by clearing bit 0 only (read, `and 0x80`, write).
  - Entries are 12 bytes now: `+8` = the pause state.
- **The sniff -- already in the model.** EUGBLD.XAF frames 11-52 (drawn and checked offline: Test-style rig render via ScanWire.AddBody/BodyTris):
  - 11 standing;
  - 14-29 head down sniffing the ground, tail up;
  - 33-44 head up, jaw open, looking round;
  - 48-52 back to the stand (52 matches 11).
  - Unused by any .ANI. The game has a SNIFF state: keyword 10 in the 13-byte table at `0x147300`, `REST WALK SLEEP START_RUN RUN END_RUN PICKUP DROP ROAR SNIFF AWAKE SHOT ATTACK DEATH_TWITCH DEAD NOLOOP1-3 FLOAT FACE_YOU SHOT_RECOVER`, state = index + 1.
- **The `.ANI` line is added at install** (Apply-AztMod, after the stock-restore sweep): `SNIFF 11-52` under `REST 0-0` in the installed EUGENE.ANI and EUGENB.ANI, with an `.aztbak`. No game data in the repo.
- **Room rule:** `"pauseAnim": "SNIFF", "pauseFrames": 41`. The host times one pass of the clip at the character's own stride (18.2 Hz x 0.9 x 0.89, ~2.8 s), so the pause ends on the stand pose and runs on. pauseEvery stays [6, 12] s.

## Round 3 -- slower run, same sniff (Josh, 2026-10-13)
"slow down the 2 creatures by another 20%. the sniff and pause animation is perfect however."
- CORICORI: `speed` 0.64 (0.8 x 0.8).
- New rule key **`pauseSpeed`** (0.8): the pace while paused. The host writes it into the entry's pct byte when a pause starts, and the run pct back when it ends. So the sniff plays at its approved pace while the run is slower.
- `pauseFrames` is timed at the pause's pace (still ~2.8 s).

## Round 4 -- 95%, and the opening's fast creatures (Josh, 2026-10-13)
"those intro creatures animate at a higher speed until I leave the room and come back. Everything is too slow now ... increase ... by 50% whatever it was we recently reduced them" -- asked: **95%** (half the cut back); the creatures "identical to all other creatures while I test" -- asked: **same pace, keep the pauses**.
- `$NPC_RATE_PCT` 90 -> **95** (one overlay byte: `aztNpcPct`). CORICORI's EUGENE/EUGENB: no `speed` / `pauseSpeed` (the common 95%), still `pauseAnim` SNIFF x 41 frames.
- **Why the opening's creatures differed (inferred from the logs, not traced live):**
  - The host found them 4 s into the room (13:28:34) and the guest loop ran at the same ~140-150 fps on both visits, so it was not a missed table nor the frame rate.
  - On a new game they run a SCRIPT first (`[char+0x3A]` != 0), and the script's moves go through `0x261C0` WITHOUT the AI hook. So the per-character travel share (AztNpcAi) never touched them -- only the common pace did -- while their stride WAS slowed (AztNpcStride): faster travel on first entry, the full 0.64 only once they wander after a room reload.
  - With the creatures at the common pace this no longer shows. If a per-character pace comes back, give scripted moves the share too (e.g. gate the whole character in 0x261C0, not just the AI step).
- **Also corrected:** `[0x1525F2]` is NOT an "opening-room hold" (azrael-frame-tied-timing.md's old reading). It is a toggle (`0x12954`, from a key and command `0x2C615`) that also skips the render (`0x1414A` -> past `0x14182` / `0x14187`): a frozen mode, normally 0.

## Round 5 -- 70% and silky poses (Josh, 2026-10-13)
- **The 10% test** showed the opening's fast creatures were "just their wonky animation", not a bug.
- **CORICORI EUGENE/EUGENB:** `speed` 0.7 (running), `pauseSpeed` 0.8 (the sniff he approved).
- **"their animation is very jarring as if at a slow frame rate. Regardless of speed, I want their animation to be silky smooth."** NOT the removed whole-picture frame interpolation ([[azrael-frame-cost]]): this smooths the characters' POSES between the game's steps.
- **Why it stuttered:** a character's pace thins the 18.2 Hz ticks, so its poses arrive on an uneven beat (70% = gaps of 55/55/110 ms). The host's Smoother eased each pose over one fixed tick, so it arrived early and STOOD STILL until the next one.
- **Fix: steady playback** (`SceneGraph.Smoother`, `Adaptive`, rig joints only: InChar, the XAFQ container and its ZZ bones, so travel too):
  - each joint queues the poses as they come and plays them back at its own measured beat (a running average of its gaps, 0.8 / 0.2), interpolated (slerp of the joint's LOCAL rotation, as before);
  - kept `PlayBehind` 1.5 steps behind the newest, the speed easing toward that over `PlayEaseMs` 400 (following the sawtooth closely made it surge);
  - catch-up x3 after a stall; at most 6 queued.
  - Every pose is still shown, in order: only the spacing changes. Room objects keep the old one-tick rule. A character is drawn ~1.5 of its own steps behind the game (~85 ms at 95%, ~120 ms at 70%; the old smoother was 55 ms).
- **Measured** (an offline sim, a joint stepping +1 a pose, drawn at 60 fps; unevenness = the frame-to-frame speed's spread / its mean):

  | beat | old | new (PlayBehind 1.5) |
  |---|---|---|
  | 70% | 54%, 58 of 299 frames standing still | 5%, none |
  | 95% | 23%, 14 still | 10%, none |
  | 100% | 0% | 1% |
  | 50% | 89%, 114 still | 4%, none |

  PlayBehind 1.0 left a stop at every long gap.
- **Switch:** `-NoSteadyPlay` = the old easing (`-NoSmooth` = none at all).

**Round 6 (Josh, 2026-10-13: "It looks great, make the 2 intro creatures at 60%"):** CORICORI EUGENE/EUGENB `speed` 0.6 (overlay share 63%), sniff still 0.8. The playback needed no change: it measures each joint's own beat. The 60% beat as the overlay makes it is 110/55/110/55/110/110/55... with an occasional 165 (mean 92 ms). In the sim, old = 74% unevenness, 87 of 299 frames standing still; new = 9%, none.

## 100% (Josh, 2026-10-13): "all characters move at their 100% animation speed except for the 2 creatures in the coricori room, which should remain as is"
`$NPC_RATE_PCT = 100`: both accumulators (AztActorGate, AztFrameAll's aztCharDue) pass every step = the stock pace; the gate stays in place for the rooms' "npcs" blocks. CORICORI's `speed` 0.6 / `pauseSpeed` 0.8 are shares of the ORIGINAL pace, so the host now writes pct 60 (was 63 against 95): the creatures move exactly as before. Only the overlay word aztNpcPct changed (95 -> 100).
