---
name: azrael-jump
description: "Space = JUMP, C = CROUCH (toggle), Z = weapon / MS7 sight, F = lamp (2026-10-15, branch jump). Host-only: steers the fall speed 0x152592 tick by tick (eased plan), crouch = data writes to the eye height/knee/speeds; the view's height eased + landing bob."
metadata:
  type: project
---

Josh, 2026-10-15: "a basic jump button assigned to the SPACE BAR", then the same day "make C a crouch key ... the head is
getting caught on geometry ... crouched, they will move slightly slower", the jump "a little up and down harsh, like an
ease at the top would be ideal, and a very slight head bob on landing". Keys: **Space jump, C crouch (toggle since round 2), Z weapon /
MS7 sight** (Z: Josh's pick; F stays the helmet lamp). Branch **`jump`** (from dev-next), DOSBox version. **No game code**
for any of it (data writes only); `-Retro` keeps stock keys.

## The jump: the engine's gravity, steered
- `v = word [0x152592]` (obj2) is the fall speed. Each fall step (the 18.2 Hz tick, `AztFallGate`): `eye -= v; v += 6`
  while the eye is more than `v + 15` over standing (`floor + 45`), else it SNAPS to standing, `v = 0` (damage if `v > 60`).
  Floor test: highest hit with `hit.y < eye - 22 + v` ([[azrael-floor-needs-engine-draw]], [[azrael-wall-slide]]).
- **The first rise must be >= 16**: at take-off the eye is AT standing, so `0 > v + 15` needs `v <= -16` (the first
  version's low-ceiling fallbacks of 12 / 6 could never have left the ground).
- After each step `v` reads (written + 6): the host writes the plan's next value (`Get-JumpPlan`): rises **16 10 6 3 1**,
  `JumpHang` (1) ticks at 0, then **1 3 6 10** down; past the end the engine's own +6s until the floor takes it.
  Heights 16 26 32 35 36 36 35 32 26 16, landing (snap) from 16: **0.60 s**, landing v 16. Several steps between reads
  (a stall): advance by d/6. A low ceiling (`Footsteps.RayUp` - 12) clips the rises; under 16 = no jump.
- Landed = `v` 0 after a positive write, or held 0 at the top for > 0.15 s (a low arc that snapped).
- Sounds: `Footsteps.JumpSound` (take-off one run step, landing two feet x `LandLevel` 1.4) at `JumpPitch` 0.6
  (`Step(..., pitchScale)`: lower and as much longer).
- Params: `-NoJump`, `-JumpPower 36` (the top), `-JumpHang 1`.

## The view's height, eased (Step-EyeSmooth, before TiltCamera; this frame's copy of the camera only)
The game moves the eye in 18 Hz steps; `$m[13]` follows each over one tick (linear from where the view is), so jumps,
the landing snap, stairs and crouching glide. A jump's landing dips it `LandBob` 2.5 units (half sine over
`LandBobTime` 0.28 s). A jump of > 80 units (room change, teleport) is taken at once. `$script:eyeGameY` keeps the GAME's
eye for the headroom tests. `-NoEyeSmooth`; off in -Retro and under the 3D map.

## Crouch (Step-Crouch): data the ground test and the movement step read
- Standing eye height **double 45.0 at 0x140328** (read only at 0x121FF / 0x12262), knee test **float -22 at 0x140340**
  (0x1218F only) raised by the same drop (the player still steps up 23 units), walk / run step lengths **0x1417FC /
  0x141800** (already rescaled by the build's move-scale: scaled from what the game holds, read on attach).
- `-CrouchDrop 16`, `-CrouchSpeed 0.65`, `-CrouchTime 0.2` (smoothstep). Lowered a few units a frame, so the engine
  SNAPS the eye down (no fall). Lowering the eye lowers both wall tests (eye ray, point 8 below): beams and arches pass
  over a crouched head. Stays down while `RayUp` - 8 is less than what is left of the drop.
- `Reset-Crouch` (in Stop-SpaceGuard: game end, watcher stop) writes the stock values back; on attach, values left part
  way by a stopped watcher are recognised from the eye height and undone.

## Keys (tools\Keys.cs SpaceGuard, the WH_KEYBOARD_LL hook of the spoken-line guard)
- Space outside a spoken line: dropped, counted in `JumpPresses` (held = one). Passed to the game while a line is spoken
  (skip), swallowed within `QuietMs` after one, passed while a save name is typed (`TypingAddr` = `aztTypingKeys`).
- **Z** (`WeaponVk` 0x5A): dropped; a marked (`Marker` 0x41A75A0E) Space down + up sent so the game's own toggle runs.
- **C** (`CrouchVk` 0x43, `CrouchMode`): dropped while held, `CrouchHeld` for the watcher.
- The game's key handler has no Z / C (its 0x2C / 0x2E compares are ASCII `,` `.`).

## Verified offline (2026-10-15)
Compiled; TestKey (Space paths); RayUp; the plan simulated against the fall rule (full, ceiling 30, 20, 15). **Josh: the
first jump "works pretty well"; the eased arc, crouch and bob not yet judged in game.**

## Round 2 (2026-10-15, after Josh's test): C TOGGLES; the crouch sprint; the shadow
- **C toggles** the crouch (`SpaceGuard.Crouched`; Josh: "make C a toggle for crouch, not hold to crouch").
- **THE SPRINT BUG** (Josh: "holding forward while holding and releasing C ... I will zoom in quickspeed between lowering /
  raising"): the host ALREADY rewrites the walk / run step every 250 ms (`Update-HostFps`: distance per second / the
  guest's measured frame rate, several hundred fps with the cap off). Crouch had read the step ONCE on attach -- the build's
  24 fps value -- and wrote its scaled copy every frame of a 0.2 s transition: many times the right step until the next
  250 ms correction. Now `$script:crouchK` is a factor INSIDE every writer of the step (`Enable-HostFps`,
  `Update-HostFps`, `Set-MoveSteps`). **Any future speed change must go through crouchK / Set-MoveSteps, never a direct write.**
- **The player's shadow body** (`ScanWire.StepBody`): `BodyLift` raises it by the eye's height over where it stood while a
  jump is in the air (eased), `BodySquash` (= CrouchDrop x eased crouch / 48) shortens it from the head, feet on the floor.

## Round 3 (2026-10-15): reverb, a deeper jump, and the view-height freeze
- **Reverb** on every step and the jump (`Footsteps.Reverb`, in `Step(..., reverb = true)`): six damped combs + two
  all-passes a channel (Freeverb's tunings, right channel +23 samples), tail peak `ReverbWet` 0.30 of the dry step,
  `ReverbTail` 0.55 s (50 ms fade), `ReverbRoom` 0.78, `ReverbDamp` 0.35. NOT on the lamp click (`reverb: false`).
- **JumpPitch 0.42** (0.6 before; Josh: "deeper in tone even further").
- **THE VIEW-HEIGHT FREEZE** (Josh: "the character won't crouch/stand after pressing C until I stop walking"): the game
  crouched fine -- the VIEW did not. Step-EyeSmooth restarted its one-tick ease on every change of the game's height and
  measured progress from the restart; walking changes the height a hair nearly every frame, so progress stayed 0 and the
  view's height froze until the player stopped (stairs too). Now a closed-form SMOOTH-DAMP (critically damped,
  `$EyeSmoothTime` 0.06 s): always moves toward the game's height, stable at any frame time. Simulated: a crouch with
  per-frame jitter follows ~60 ms behind. **Never measure an ease from "the last change" when the target can change every frame.**

## Round 4 (2026-10-15)
- **JumpPitch 0.38** (Josh).
- **Crouched steps 20% quieter** (Josh): `Footsteps.Crouch` (the eased crouch, set by Step-Crouch) and `CrouchLevel` 0.8 scale a WALKING step through `Step(..., level)`; the jump's sounds are not scaled. Measured: peak 7049 -> 5639 (0.80).

## Round 5 (2026-10-15)
- **ReverbTail 0.65** (Josh).
- **Echo** on the steps and the jump (not the lamp): `EchoRepeats` 2 copies of the whole step + room mix, `EchoDelay` 0.17 s apart, `EchoLevel` 0.20 then x `EchoDecay` 0.45, each one darker (one-pole at `EchoDark` 2600 Hz, run k times) and leaning +-15% to alternate sides. Measured (peak per 50 ms): 7049 at the step, 1989 at ~170 ms, 862 at ~340 ms; a step is now ~1.3 s long.

## Round 6 (2026-10-15)
- **CrouchLevel 0.72** (was 0.8; Josh: 10% softer again).
- **No steps in the air** (Josh: running jumps kept stepping): `Footsteps.Airborne` (= the watcher's `jumpAir`, set before each Update) skips steps and restarts the stride, so walking resumes half a stride after the landing's own sound. The old `_vy < -120` check only caught fast falls, never the rise and the top. Simulated: steps 11 30 49 | jump 60-95: none | 105 124 ...
