---
name: azrael-early-overlay
description: "The BSS overlay now loads at 0x16146, BEFORE the intro - which buys back the boot effect's ~4s CD latency and unblocks intro-time code from the file caves."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-02T05:20:16.326Z
---

`$ENABLE_EARLY_OVERLAY`. Two 10-byte trampolines in the game's own start-up, either side of
the intro sequence:

```
0x16146  call 0x10220  -> AztEarlyOvl (clock blob)  call AztOverlayLoad / jmp 0x10220
0x1614B  call 0x1FF39     the intro sequence, UNTOUCHED
0x16150  call 0x11688  -> AztCdBoot   (stub cave)   call 0x13300E / jmp 0x11688
```

**Why:** the visor boot effect is a CD track with **~4 s of start latency** (measured, and
confirmed unchanged after the track was cut from 2.02 MB/44.1 kHz stereo to 617 KB/22 kHz mono
— so it is drive latency, not file size). It used to be requested on the boot animation's first
frame, so the animation had to be held back to meet it. Requested at `0x16150` instead, the
latency is spent on the room/texture load that follows.

**How to apply:**

- **`AztInjInit` MUST stay off `AztInitAll`.** Init now runs before the intro MOVIES, and
  `AztInjInit` asks the game's allocator for 576 KB — out of the heap the movie player needs
  ~2.4 MB of. That is the documented crash in [[azrael-extra-intro-movie]]. It is deferred to
  the first `AztFrameAll`, flag-guarded by `aztInjDone` (not by `aztInjBufPtr`, since 0 is also
  what a failed allocation leaves). It runs FIRST in `AztFrameAll`, before `AztBootTick`, which
  reads the buffer.
- What remains in early init is safe: `AztCdInit` takes 64 bytes of **DOS low memory** (DPMI
  0x0100), not the heap; `AztBootInit` zeroes two dwords.
- `AztBootTick` still requests slot 11 on its first frame. Deliberate: `AztCdPlay` returns early
  for a track already playing (`aztCdCur` is set to 1 on success, guard at the top), so the
  track is **not** restarted, and it stays as the fallback if the early request failed.
- The overlay's third fixed entry is **+14** (`AztOvlCdBoot`), asserted at build time like +4
  and +9. `AztCdBootStart` derives its own esi/edi — every other overlay routine is entered
  from the frame hook, which already holds the deltas, but this one comes from a bare
  trampoline.
- Trampolines reach the overlay by **rel32 to a literal** (`OVERLAY_BASE + 14`), never an
  absolute: both ends are in obj1 and shift by the same delta. An absolute obj1 address is the
  pointer-to-nowhere that crashed the opening movie — see [[azrael-cave-space]].
- Emit the `0x16146` patch **after** the clock blob is assembled; `AztEarlyOvl` lives in it, and
  referencing it earlier yields a null address.

Cost: clock blob 403 -> 413 of 419, stub cave 1651 -> 1661 of 1664.

## Still open

`$BOOT_TEXT_US` is **still 4000000** — the visual timeline has NOT been retuned, deliberately,
because moving the hook and the timeline together makes the result unreadable. One launch
settles it: if the sound starts during the black loading screen the latency is fully absorbed
and `$BOOT_TEXT_US` drops to ~250000; if it starts N seconds into the visor animation, set it
to N. Overshoot is the risk to watch — a long room load means the track is already playing when
the animation starts, and the opening of the sound is missed. See [[azrael-music]] for the
track's own recipe and [[azrael-boot-effects-phase]] for the animation beats.

## The ~2 s ambient at game start is NOT the MIDI cue -- dead end, reverted

A short ambient swell is heard at the very start of a new game, before the boot effect. It is
**not** the room's MIDI cue, despite looking exactly like one.

Ruled out by measurement, not reasoning: all four callers of `0x3B048` (`0x1154A`, `0x13B18`,
`0x13E59`, `0x14D94`) take their volume identically --
`mov edx,[0x14693E] / sar edx,0x10`, the player's 16.16 slider -- so zeroing that global before
the room loads must silence any cue started through it. **It changed nothing.** Whatever makes
the sound does not read that global.

It also had a COST, which is the useful half of the result: the in-game music took noticeably
longer to arrive after the sequence. Volume is an argument baked in when `0x3B048` plays a cue,
so a cue started at 0 stays silent until something re-plays it -- restoring the global does not
bring it back. **Do not zero `0x14693E` to silence anything.** Reverted; the overlay is back to
33,718 bytes, which is the check that a revert of this kind is complete.

Also ruled out: `AztCdPoll` is gated (`aztBootState < 2` bails) so the CD cannot switch tracks
during the boot, and `AztCdSwitch` has no direct hook.

**IDENTIFIED: it is `hud3.wav`**, a 2.13 s PCM sample -- which is why muting the sequencer did
nothing. Found by envelope-scanning all 264 playable WAVs for something 0.8-4.5 s that peaks
early and decays to near nothing, then matching the name against the HUD art (`HUD3.PCX`).

The string sits at obj2 **0x143160** in the HUD resource block, next to `nbut0off.pcx`, and
reaches the sound player `0x100BC` from two sites: **0x2C2E8** (inside the HUD routine
`0x2C2D4`, which the startup path reaches via `0x16D92`) and **0x2C85E**.

**`0x100BC` TAKES ONLY EAX.** It sets ebx/ecx/edx itself and reads its volume from the SFX
global `0x14693C` (note: `0x14693E` is MUSIC, one word apart -- easy to confuse). So the call
can be replayed later with nothing but the string pointer: no register capture, no guessed
argument list. Site B's `ebx=1 / edi=0xFF / edx=0x164DAA` are for something else and are
irrelevant to the sound.

Both sites now redirect to `AztWhooshGate` in the overlay, which swallows the call while
`aztBootState < 2` and records a one-bit debt, then `AztWhooshPlay` at `ABT_finish` pays it
back with `lea eax,[edi+0x143160] / call 0x100BC`. After the boot the gate tail-jumps to
`0x100BC` unchanged, so a HUD raised later in the game still whooshes normally.