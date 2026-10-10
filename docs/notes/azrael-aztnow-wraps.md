---
name: azrael-aztnow-wraps
description: "AztNow wraps every ~71.6 minutes of WALL-CLOCK time (BIOS midnight tick x 54925, truncated to 32 bits) — never compare against now+duration, always compare elapsed."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-01T02:44:31.513Z
---

`AztNow` returns `[0x46C] * TIMER_PERIOD15 (54,925 us) + the intra-tick accumulator`, kept
as the low 32 bits of the product. **0x46C is the BIOS tick counter since MIDNIGHT**, so:

- `now` does NOT start at zero when the game launches — it starts wherever the wall clock is
- it wraps every `2^32 / 54,925` ticks ≈ **71.6 minutes of wall-clock time**, whatever the
  game is doing

**Therefore: never store an absolute deadline.** `end = now + duration` overflows whenever
the game is launched inside the last `duration` of a wrap window, and `now >= end` is then
true on the very next frame and every frame after.

This is exactly what silently killed the CD soundtrack: `aztCdEnd = now + us` with a
359-second track meant **8.3% of launches** (measured) had the loop timer fire continuously
— the track restarted every frame, so no music was ever audible. It presented as "the music
stopped working" long after the code was written, because it depends on the time of day you
start, not on anything in the build.

**Always compare ELAPSED:** store the start and the duration, then
`eax = now; sub eax,[start]; cmp eax,[duration]; jb still-running`. The subtraction is
correct modulo 2^32 for any interval shorter than the wrap, so it does not care where in
the window `now` happens to be.

The visor boot was always immune for this reason — it uses `now - aztBootT0` throughout.

**How it was found:** `AZTCD.LOG` (the `$CD_DIAG` event log, 8 bytes per event) showed
1,000 alternating "loop timer fired" / "PLAY issued" events on one slot. Codes: 1 switch,
2 play, 3 stop, 4 loop restart, 5 restore skipped, 6 slider moved, 7 F4, 8 mute skipped.

Related: [[azrael-music]], [[azrael-frame-tied-timing]], [[azrael-key-addresses]].
