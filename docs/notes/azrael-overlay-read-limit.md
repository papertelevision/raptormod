---
name: azrael-overlay-read-limit
description: "$OVERLAY_READ is now 0xD000, the whole BSS window; the loader that uses it lives in the actor-time (clock) blob, NOT the stub."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-04T19:35:41.407Z
---

`$OVERLAY_READ` caps how much of `AZTCODE.BIN` the loader pulls into the BSS. Raised
**0x4000 → 0x8000 → 0xC000 → 0xD000** (2026-09-30), and **0xD000 is the ceiling**: the BSS
window is `OBJ1_BASE 0x10000 + OBJ1_VSIZE 0x130000 - OVERLAY_BASE 0x133000` = 0xD000 =
53,248 bytes, and obj2 begins at 0x140000.

Raising it is safe because the read is DOS `INT 21h AH=3Fh`, which reads *up to* ECX and
returns what it got — a smaller file simply reads short. The only real constraint is that
`OVERLAY_BASE + OVERLAY_READ` must not leave the window, which the build now asserts
(the check sits next to `$OBJ1_VSIZE`, because that is where the window's top is first
known — `$OVERLAY_READ` itself has to be declared hundreds of lines earlier).

**Nothing else lives in that window.** The 576 KB staging buffer comes from the game's own
allocator at `0x32CE0`. An early version parked it at `OVERLAY_BASE+0x5000` and left behind
a guard (`$INJ_BUF_AT`) implying the overlay only had 0x5000 to grow into; that guard is
now removed.

**Where the loader actually is:** `AztOverlayLoad` is emitted into the **`actor-time`
patch** — the 403-byte "clock blob" at linear 0x50F2D / file 0xA2981 — not the `stub`
patch, despite the stub being where overlay plumbing otherwise lives. To verify a change
to the read count, look for `B9 <imm32>` in that patch, or in the installed R.EXE at
`actor-time offset + 158`.

**NEARLY FULL: 53,239 of 53,248 bytes, 9 free (2026-10-04 23:15; it was down to ONE byte at 23:05).** The next overlay change MUST remove something first (candidates: the six per-site AztAnimGate checks, now redundant under the move gate; $ENABLE_RAPTOR_TRAP; dead probes). Before that it was 53,211 — 37 bytes free (was 53,163 — 85
bytes free**, and the build throws rather than overflowing (`overlay is N bytes, more than
AztOverlayLoad reads`). Adding anything now means removing something, or spending it the way
AztRaptorTrap did: it wanted a 256-byte stack buffer, the window had 333 bytes left, so it
sifts the stack for plausible return addresses instead and stores 20 slots in 80 bytes —
deeper coverage for less space. Budget BEFORE writing the routine, not after.

Related: [[azrael-cave-space]], [[azrael-boot-effects-phase]], [[azrael-le-image-layout]],
[[azrael-rl-error-callback]].
