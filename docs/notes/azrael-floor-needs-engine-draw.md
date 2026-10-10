---
name: azrael-floor-needs-engine-draw
description: "Rooms entered while the host is drawing lose their floors: the game's ground test only finds the undrawn catch plane. Fix (unconfirmed in game): hand the viewport back for ~6 engine frames on every teleport."
metadata:
  type: project
---

**Symptom (measured 2026-10-05 09:01, capture run):** corridor -> spa -> corridor with the host
renderer drawing throughout. On re-entry the player stands at the right height until they move,
then eye height drops from -38.8 to **-95.5** and stays there everywhere: that is 45 above
`Object03`, an UNDRAWN catch plane at y -140.5 under the whole of CORICORI. The real floors
(tunnel03 -83.8, floorbit* -92..-118) no longer stop the ground test. Consequences seen: the
exit trigger (a quad lying on the floor) never fires, the player walks out through walls, the
spa walkway gives way (three `room -> DROWN` in the logs), "stuck in geometry".

**Eye height = floor + 45**, checked against six positions on the first visit.

**Why (inferred, not disassembled):** the first room never does it, and the engine drew that
room itself for seconds before takeover. A reload sometimes got an engine draw by luck (the
watcher noticing the load and handing back: "viewport handed back (nothing to draw yet)"),
which is why it was intermittent. So the ground test needs something per frame-object that
only the engine's own draw of a fresh room produces; the world-cache refresh thunk in
AztScenePart2 is NOT enough. Candidates if it needs chasing: the third matrix block
(+0xD0/+0xD4), bounding data built at render.

**Fix in the watcher:** on any camera jump > 60 units while suppressed, hand the viewport back
until aztCamFrameNo has advanced 6 (cap 1.5 s), log `new room: the engine drew N frames...`,
then retake. `-NoLoadPulse` disables. NOT yet confirmed by Josh.

**Do not blame the picture first when collision is off**: the host only draws. Check the
camera's y against floor + 45 (Under-style ray on the unit geometry) -- it settles it in one step.

Related: [[azrael-tier-a-host-render]], [[azrael-frame-tied-timing]], [[azrael-doorway-portals]].

## WRONG (09:07 run): the engine-draw pulse did NOT fix it

The pulse ran (6 engine frames, logged) and Josh still fell in the same spot. Corrections: he does
NOT fall in the spa; only on re-entering CORICORI from the spa. The fall happens at
(567,256) = exactly where door `doorcor01` stands (x 557..570, z 241..266), walking from the
tunnel into the room; floors there are continuous (tunnel03 -83.8 then dorwall06 ramp), so it is
not a gap. First pass through the same open door the other way is fine. Cause UNKNOWN. Not yet
bisected against the plain game (Play-Azrael-Modded.bat). The watcher now logs a `FALL:` block
(engine cache vs composed truth for every frame, door/floor matrices and flags) the moment the
eye drops >25 units. The pulse stays in (harmless) until the cause is known.

## HOW THE GAME'S COLLISION ACTUALLY WORKS (disassembled 2026-10-05) -- read before theorising

Josh confirms: never happened before the host renderer. Not bisected further at his request.

- Ground test = `0x11E68(x,y,z)` (called from the movement callback 0x1CF64). It calls
  `0x2F758`, which walks a BAKED FACE TABLE, not the scene: count `[0x165290]` (max 2000),
  normals 0x165294 (+12), plane d (double) 0x16B054 (+8), 2D polys 0x170E14 (+16), projection
  axis 0x178B14, owner-name POINTERS 0x16EED4 (+4). Point-in-polygon is in 16-bit INTEGER coords.
  Hits go to count `[0x164FBC]`, names 0x164ECC, points 0x164FC0.
- Floor chosen = highest hit with `hit.y < eye.y - 22 + v`; then `eye = floor + 45`. Names
  starting `ZX` are zone triggers handled in the same loop (so no floor hit = no trigger).
- **Falling is frame-tied**: `v = word [0x152592]`, `eye -= v; v += 6` PER FRAME, damage if
  v > 0x3C on landing. At 300 fps a fall is effectively instant.
- Table built by 0x2D6B4 / 0x2E2C0 at load (vertices through Frame::Transform 0x4B810, which
  refreshes the world matrix first via 0x554F0 -- so NOT a stale-cache problem).
- **Doors re-bake IN PLACE**: `0x2D630(table, name)` finds the object's first face by name
  pointer, sets the count there, re-runs the baker, restores the count. Called from the door
  stepper 0x1CBD4 (0x1CC5B, 0x1CCAC, 0x1CE15, 0x1CE8F) and script opcodes (0x2B2F2, 0x2B456).
  Only safe if the object emits the same number of faces every time. SUSPECT for the fall at
  the door, unproven.
- 0x1CBD4 also has a "do all remaining steps now" path (loop of 0x29F70 then one re-bake,
  sets object+0x12 = 2).

The watcher now logs `COLLISION TABLE` (run-length list of owner names) on room entry and
whenever it changes, and the last ground test's hits inside the `FALL:` block.

## 09:34 run + the gravity gate (BUILT, NOT INSTALLED at time of writing -- game was running)

FALL probe: one step after re-entering CORICORI the eye went -38.8 -> -74.8 (= 0+6+12+18, four
falling frames) -> -95.5, with `tunnel03@-83.8` STILL in the ground test's hit list. Once the
eye is below floor+23 the test never accepts that floor again (`hit.y < eye - 22 + v`).
World caches were fine (only smoothed character bones differ). Collision-table lines did not
print (unexplained; the name cache did fill).

**Mechanism adopted:** gravity is per FRAME (`eye -= v; v += 6` at 0x122F4). At 18 fps a floor
missing for one frame costs nothing (first step is v = 0); at ~300 fps the same 55 ms is ~16
frames and the player is gone. What makes the floor miss for that moment is NOT identified
(candidates: the post-re-bake push-out loop at 0x1D527 that calls 0x11E68 for trial positions
when `[0x162E02]` is set by 0x2D630; the arrival script restoring door state).

**Fix built:** `AztFallGate` -- `call` replacing the 7-byte `fild dword [esp+0x8C]` at 0x12283;
replays the original compare, standing -> 0x12291, falling -> 0x122F4 only on the 18.2 Hz tick
(else 0x12320, nothing moves). Paid for by factoring the gate test into `AztGateHold` (ZF=1 =
hold), now shared by AztVelGate / AztEventGate / AztFallGate. Overlay 53,240 bytes, 8 free,
419 patches. Emitted bytes and all jump targets checked.

**Install path now:** `tools\Apply-Delta.ps1` (desktop shortcut "AztMod - install update"):
diffs `AztMod.manifest.installed.json` against `AztMod.manifest.json`, undoes then applies,
verifies all, refuses while DOSBox runs. Simulated in memory: 0 errors.

## RESOLVED 2026-10-05 09:47: the gravity gate fixed the fall (Josh confirmed)

Installed 419 patches / overlay 53,240. Josh: "That fixed the fall issue."

## NEXT BUG, same day: rooms "fall apart" after going back and forth -- STALE SCENE ROOT in the watcher

Symptom: missing walls/floors, holes, parts in wrong places after several corridor<->spa trips;
log shows e.g. `SPAROOM ... (13 moved, 14 hidden)` for minutes. PROVEN live (read-only probe
while it was happening): the game's scene was complete (45/45 spa objects, 51 nodes) while the
watcher still reported 13 moved / 14 hidden. Cause: `$sceneRoot = RootOf(camObj)` was taken
ONCE at room detection; my teleport pulse moved detection to mid-load ("scene rebuilt"), when
the camera still hangs off the old, unhooked scene. The watcher then walked the previous room's
freed frames (bit-identical reads, so WalkTreeStable accepted them); parts sharing a name
across rooms (tunnel02..05, Object01..03, entcori, view) got the other room's matrices.
Fix: re-climb RootOf every sample, reset the smoother when it changes (logs `scene top moved`).
NOT yet confirmed by Josh. General rule: never cache a guest pointer across a room load.

## THE REAL "rooms fall apart on return" BUG: the NAME CACHE in SceneGraph.cs (2026-10-05 10:13)

After the stale-root fix Josh still got missing geometry "specifically on returning to a room".
Log: `CHAMBNEW (36 moved, 53 hidden)` on the second visit, scene top unchanged, plus a phantom
`character ZZ0005 -> THEO (4 of 4 frames)` from the previous visit. Cause: `_nameCache` in
WalkLive/WalkTree maps a name's ADDRESS to its string and was cleared only on a new pid. Room
changes free and re-allocate name strings at the same addresses, so new frames got OLD names.
Present since WalkLive was written (2026-10-04); WalkBlocks (room detection) never used it,
which is why the right room always loaded. Fix: cache dropped every 250 ms (`AgeNames`), and
`ForgetNames()` + smoother reset on room change / teleport / scene-top change. Also a safety
net at each 4 s report: if >5 parts are hidden, re-count with cache-free WalkBlocks and log
`POSE OUT OF STEP WITH THE SCENE` (and restart the fast path) when they disagree.
NOT yet confirmed by Josh. Rule: any host-side cache keyed by a guest address must expire.
The earlier "stale scene root" diagnosis may have been this bug too (same symptoms).