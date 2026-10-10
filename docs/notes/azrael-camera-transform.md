---
name: azrael-camera-transform
description: "The live camera pose is READABLE and verified - globals hold HANDLES not pointers, matrices are at +0x4C/+0x90, and 0x39E50 is the side-effect-free resolver."
metadata:
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-26T05:18:48.004Z
---

The §14 experiment of [[azrael-remaster-feasibility]] is **done and CONFIRMED**
(2026-09-26). The live camera transform can be read every frame from inside the
game. Overlay routines `AztCamLog`/`AztCamSnap`, decoder `tools\Read-CamLog.ps1`,
binary log `AZTCAM.LOG` (320-byte records). Flag `$ENABLE_CAM_LOG`.

**Three things static analysis got WRONG — do not re-derive them:**

1. `[0x152144]` and `[0x162DE4]` hold **handles, not object pointers**. Resolve with
   **`0x39E50`** (eax = handle -> object): a chained-hash lookup, `div 0x3FD` into
   the bucket table at `0x1831CC` matching `[obj+0x14]`, with **zero side effects**,
   which is why it is safe to call from the frame loop. `[global]+0x7C` reads garbage.
2. The 4×4 matrices are at **`+0x4C` (local)** and **`+0x90` (world)**, NOT
   `+0x48`/`+0x8C`. Those two addresses are the start of a 0x11-dword block whose
   first dword is a tag. Translation is the matrix's fourth row, landing on
   `+0x7C/0x80/0x84` (local) and `+0xC0/0xC4/0xC8` (world).
3. **`0x42410` is not an unwrap helper.** It resolves the handle then returns
   `[root+0x14]` — the SCENE ROOT's handle. That is why the movement code uses it as
   the reference frame for Get/SetPosition.

**Frame layout, all CONFIRMED by measurement:** `+0x14` handle, `+0x18` class tag,
`+0x30` parent, `+0x44` dirty byte, `+0x4C` local 4×4, `+0x90` world 4×4.
`0x554F0` is the lazy refresh (walks parents testing `+0x44`) — **do not call it**;
the renderer has already made the world matrices clean by the time the frame hook
runs, and calling it means mutating engine state to observe it.

**Use `[0x152144]`'s WORLD matrix as the camera pose.** It is the frame passed to
`Viewport::Create` at `0x10F65`. Its *local* matrix is exactly identity every frame
(pure attachment point; the pose lives in its parent chain). The world matrix carries
yaw AND pitch, pitch clamped at ±40.89°. `[0x162DE4]` is a different frame with a
different parent, co-posed to within 0.05 units when stationary but diverging ~1.3
(max 2.65) while moving, sagittal plane only — an update-ordering artifact, not an eye
offset. The parent chain has never been walked.

**Verification that makes this fact, not plausibility:** all matrices stay orthonormal
to ~2.4e-7 across 1,362 frames; an on-the-spot turn gave exactly 90.0° yaw with 0.01
units of translation; 22.2 records/s matches the known fps in [[azrael-perf-measured]].

**Type tags are RELOCATED.** Runtime tag `0x338EDC` = linear `0x147EDC` + obj2 delta
`0x1F1000`; obj1 delta is `0x1F0000`, so the load base is `0x200000` (agrees with
[[azrael-stride-derived-offsets]]). The stub logs both deltas for exactly this reason —
without them no logged pointer can be checked against a linear address from the notes.

Gotchas paid for once: `ACL_` label prefix is already taken by the CD log; `$r` and
`$R` are the SAME PowerShell variable (case-insensitive); AztNow's 32-bit microsecond
clock **wraps every 4,294.97 s** and its epoch is not process start, so unwrap before
using durations.
