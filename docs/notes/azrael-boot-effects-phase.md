---
name: azrael-boot-effects-phase
description: "Agreed backlog of visor-boot effects (2026-09-30), ordered easy to risky; three approved and being built first."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-01T02:52:43.516Z
---

Agreed **2026-09-30**: a phase of extra effects for the visor boot sequence, after the
sequence itself was signed off. Josh approved **all** of these; build order is easy first.

**Batch 1 — in progress**
1. **Blinking caret** on the typed lines, at the reveal column, ~2 Hz, gone when the line
   completes. The typed routine already tracks `aztBootCols`, so it is one `rep stosb` per
   caret row.
2. **Phosphor flare** — each newly revealed line draws one palette step brighter for
   ~120 ms then settles. Cheapest as a post-pass that rewrites ink bytes over the new
   line's rows; a second pair of expansion tables would cost 4 KB and the flare window is
   tiny, so cost is irrelevant.
3. **Vertical hold slip** during the disruption — roll the whole frame, wrapping. Free if
   done as a two-run copy inside the injection rather than as a memmove of the 576 KB
   staging buffer.
   **The first tuning was invisible** and the numbers are why: 1-8 rows on a flat amber
   field, one frame (42 ms), 1-in-16 over 2.4 s — about three imperceptible shifts, and
   the window closed before any readout text existed to displace. Shipped at 10-41 rows,
   held 3 frames, 1-in-8, over 0-5.0 s so it reaches the text. Lesson: on a near-uniform
   field an effect needs *structure* to displace and time to register.

**Tried and REJECTED**
- **Brightness flash on the slip** (fill 5→7, scan 4→6 for the slip's frames). It worked
  and made the roll easier to spot, but Josh cut it: it read as the picture blinking
  rather than as the hold slipping. Do not re-propose it.
  The variable fill/scan colours it needed (`aztFillDw`/`aztScanDw`, reset each frame in
  AztBootPaint) were KEPT — they cost nothing and the CRT warm-up wants that same hook.
  Anything that tints the screen must be set BEFORE `AztBootGlitch` repaints, or it misses
  its own frame; that is why `AztBootSlip` is called above the disruption branch.

**Batch 2**
4. **CRT warm-up** — DONE. Fill climbs the amber ramp 1→5 (luma 15→108) over 1.2 s in 5
   stages, scan trailing one step so the scanlines resolve as it brightens. The corruption
   is deliberately NOT dimmed: bright artifacts over a dark screen is the striking-tube look.
   **The trap:** the readout's background is BAKED into the expansion tables
   (`aztBootTab`/`aztBootTab2`) at build time, so dimming only the clear leaves the banner
   on a normal-brightness rectangle — a bright box on a dark screen. `AztBootWarm` also
   repaints those tables' background bytes, gated on the stage changing (5 rebuilds, not
   per frame) and testing against the INK colour so it is idempotent.
5. **Horizontal tear bands** — DONE. An 8-39 row band displaced 16-143 px sideways with
   wrap, ONE frame, chance driven by a 5th `Tear` column in the disruption stage table
   (chance out of 256, not an odds mask — a mask cannot express "never", since
   `random AND 0` is always 0). Runs LAST in the phase so it tears the text too.
   A right shift is done as a left ROTATE by (W - M): one code path for both directions,
   and no backward `std; rep movsb` whose direction flag could leak.
   Needs a full 1024-byte row scratch, and `esi` (the obj1 delta) as a string source —
   the scratch address goes into ebp and the delta is parked on the stack first.
6. **Boot progress bar** — DONE. Framed track under the readout, spanning the readout's own
   ink width (derived, so it follows the text), full exactly as the closing line finishes
   typing. Redrawn whole every frame, and each interior row writes exactly BAR_W bytes
   (1 frame + filled + remainder + 1 frame) so it cannot escape its rectangle at any fill.
   Flagged to Josh as possibly too modern a cue for a 1996 helmet; he wanted it anyway.

**Also done, on request:** a single scripted tear across the OBJECTIVE line at 13.6 s. It
is confined to the mission block's exact rectangle because nothing repaints the background
after the mission wipe — a tear reaching the bare screen would stay torn for good. The
block's own per-frame blit heals it. Build asserts the band stays inside.

**Batch 3**
7. **Reticle calibration** — DONE, and the feared risk turned out not to apply. A square box
   closes from r=140 to r=22 over 16.4-16.9 s, drawn STRAIGHT INTO THE SURFACE rather than
   the staging buffer.
   **Why that is safe:** it only runs once the shutter is fully open, and at full open the
   split copy moves ZERO bytes (top = 0 rows, bottom panel starts past the end), so the
   surface holds the engine's own frame and nothing overwrites the box. The engine redraws
   the viewport each frame, so it needs no erase either.
   It is called from the inject hook stub BEFORE `AztInjBody`, not after: with nothing being
   copied the order is irrelevant, and calling first leaves the injection's esi lifetime
   completely alone — see [[azrael-inject-esi-clobber]].
   `BOOT_HOLD_US` went 16.8 -> 16.9 s to fit it.

**Batch 4 — a second round, agreed after the first seven shipped**
8. **Glyph corruption** — DONE. Whole 8px character cells replaced by a cell from elsewhere
   on the SAME row, 5 cells, 1 frame in 8, confined to the readout block. Reads as dropped
   characters rather than static because what lands is a wrong glyph on the right baseline.
   Written into the staging buffer after the text, never into the source bitmap, so it
   heals itself. Copies with two dword moves, NOT `rep movsb` — a string copy needs esi,
   which is the obj1 delta the loop reads its variables through.
9. **Phosphor ghost on the shutter** — DONE. g rows of dim fill trailing each retracting
   panel, where g = min(10, h, 288-h). Capped at h so the panels cannot cross while the
   slit is thin (negative copy lengths); capped at 288-h so it reaches zero exactly as the
   shutter completes instead of leaving a permanent dim border round the 3D. The ghost is
   part of the COPIED panel, not of the revealed band.
10. **Calibration crosshair** — DONE. Arms grow as (R0 - r), clamped to r, so they touch the
   box edges exactly as it settles. Arm peaks at 70 px.

11. **Short re-boot on loading a save** — DONE. It does NOT duplicate the timeline: the hook
   winds the clock back so `el` already reads `BOOT_REBOOT_FROM` (14.8 s), which drops the
   run into the mission phase and carries it through the shutter and calibration — 2.1 s.
   Every beat is a build-time immediate, so a genuinely "faster" version would have meant
   duplicating all of them.
   A reload gets the mission phase's WIPE but not the briefing (`aztReboot` gates the text),
   and `ABT_finish` skips the CD re-switch, which would otherwise restart the room's music
   from the top on every load.

   **The hook site, and how it was found:** `0x2CD63`, the single caller of `0x4A994`.
   Chain: the format string `SAVE%d.dat` is at file 0x188D60; strings are referenced by
   `file offset - 0x184A54`, so its operand is 0x430C; one instruction loads that (0x4AC3A)
   in a small `sprintf(buf,"SAVE%d.dat",n)` helper at 0x4AC20; that helper has two callers,
   0x4A786 (fopen mode `"wb"` = save) and 0x4A9C5 (`"rb"` = load); the load one sits in the
   function starting 0x4A994, which has exactly one caller. The caller overwrites eax right
   after, so the loader's return value is free to ignore.
   Safe in the OVERLAY (unlike the opening movie) because a load can only be asked for from
   the in-game fold-out, by which point the overlay has been resident since the first frame.

**The agreed list is now complete.**

**Ruled out:** lighting up the automap/status/scan widgets. They are outside the viewport
at hard-coded screen coords and need a different injection site — too much exposure for
the payoff. See [[azrael-hud-widgets]].

Space: the overlay was 44,535 of the 49,152 read limit when this was agreed, with 8,713
bytes of BSS free behind it. Raising `$OVERLAY_READ` is routine and has been done twice.

Related: [[azrael-view-injection]], [[azrael-viewport-paint-not-suppress]],
[[azrael-palette-budget]], [[azrael-boot-text-rasteriser]].

## Boot effect timing (settled 2026-10-02)

`$BOOT_FX_DELAY_US = 1000000`. The effect is requested **one second into** the boot sequence,
not on its first frame: the track is 14.0 s against a 16.9 s animation, so it cannot cover the
whole thing and a second of lead-in moves the leftover to the END, where it settles rather than
stops. Build prints and asserts it:

```
boot effect: 1.00 - 15.00 s of a 16.90 s sequence  (track 14.00s, 1.90s of animation after it)
```

Implemented in `AztBootTick`'s running block, flag-guarded by `aztBootFxDone` (reset on the
sequence's first frame so a reload re-boot uses the same timer). **Save eax AND ebx across the
call**: eax is the elapsed time the cap tests below depend on and ebx is `now`, and `AztCdPlay`
destroys both (`mov ebx,[eax]` fetching the start LBA). Losing ebx once made elapsed compute as
LBA-minus-now, wrap huge, trip the hard cap and kill the whole sequence on its first frame.

**The assertion lives next to the `$CD_TRACKS` load, not with the other timeline checks**,
because those run ~300 lines earlier and `$CD_TRACKS` is still `$null` there — placed up with
them the block silently never ran and asserted nothing. Same silent-`$null` shape as
[[azrael-powershell-null-ordering]], expressed as a test that never fired rather than a wrong
number. The two values it compares live in different files (track length from
art\music-tracks.json, delay from Build-AztMod), so they can drift apart unnoticed.

This is only tunable because the LBA drift was fixed first — before that the drive spent 5.57 s
in PEACEFUL's fade-out and where the request went made no predictable difference.