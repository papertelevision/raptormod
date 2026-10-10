---
name: azrael-viewport-paint-not-suppress
description: "To draw in the viewport, paint over the 3D via AztViewInject at 0x1419D. Holding the engine's 3D-suppress flag 0x15257C corrupts the whole screen."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-09-29T20:38:18.688Z
---

**Never hold the 3D-suppress flag to get the viewport.** The engine's own switch

    00014158  cmp word [0x15257C], 0
    00014160  jnz 0x1418C          ; skips the whole 3D block

looks safe because the game sets it itself for full-screen 2D views. Holding it at 1 from the
frame path **corrupted the entire screen**: orange smear, HUD drawn out of place, garbage on the
first frame — not just a black viewport. Tried 2026-09-29, reverted immediately. It matches the
[[azrael-hud-overlay-res]] failure mode: the HUD composites into the framebuffer with
stride-sensitive writes and smears exactly like that when the surface state it depends on has not
been set up, which skipping the 3D block evidently leaves unset. The flag is fine to READ.

**Do this instead: let the 3D render and paint over it through `AztViewInject`.** It is already
hooked at `0x1419D` — the instruction immediately after that same 3D block — already measured at
22 calls/sec with pixels surviving into the surface at 100%, and `AztInjInit` already allocates a
1024x576 staging buffer from the game's allocator (0x32CE0). It runs BEFORE the HUD draws, so the
panel stays on top. Setting `aztInjEnable` is the whole interface; **zero control flow changes**.
This worked first try where suppression corrupted the screen.

Two disproved theories, so they are not re-chased: `edi` was NOT wrong (AztDeltas does establish
it on the frame path), and the `ebp` locals around the block are NOT outputs of the 3D code —
`call 0x3F2F0` at 0x1419D takes them by address and fills them, and it runs regardless of the gate.

**Diagnosis discipline that mattered:** two changes had gone in since the last good launch (the CD
soundtrack table and this one), and I wrongly assumed mine was the cause. Reverting only one and
relaunching is what isolated it. Always ask what else changed before believing the obvious culprit.

Related: [[azrael-view-injection]], [[azrael-hud-overlay-res]], [[azrael-cave-space]].
