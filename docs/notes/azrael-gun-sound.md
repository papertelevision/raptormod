---
name: azrael-gun-sound
description: SOLVED 2026-10-07 - the loading gate froze DOSBox (NtSuspendProcess, ~8 s) and that killed the Sound Blaster for the session (voices, gunfire, effects). Now the game is held in its own frame limiter. Never suspend DOSBox. Also - muzzle flash.
metadata:
  type: project
---

Josh (2026-10-07): "the gunfire sound no longer plays when shooting". **Not yet solved; a probe is in.**

**The fire path:**
- 0x15B02: needs [0x14721C] (weapon) and ammo [0x14694C] != 0, and the target type at [0x1841C8]+8 != 0xDD.
- Then 0x15B31 plays "shot.wav" via 0x100BC, and 0x15B42 does sub word [0x14694C], 1 (ammo).
- [0x1521B4] is the target ('ZZ' = a character, then hit at 0x24B78).

**0x100BC, the effect sound player** (SCAN.WAV, hud sounds and shot.wav all go through it):
- It is silent if [0x1525A0] (pause/menu) or [0x152B1C] (conversation list) is set.
- It plays via the Miles driver handle [0x1824E8] (0x317EC). This is a driver, not a single channel.
- Its volume comes from the HIGH word of [0x14693C], i.e. [0x14693E], 0..0x7F.
- [0x14693C] low word is an on/off toggle, flipped at 0x2C6FA.

**What writes [0x14693E]:**
- The options slider (0x14DC0: (0x210 - cursorX) clamped and scaled), only while dragging ([0x14693A] and [0x1523DA]).
- Conversation START (0x17E52) ducks it (fild * k); conversation END (0x17F2F) restores it from [0x146940].
- An unmatched start, or a slider dragged with the widescreen HUD's moved coordinates, could leave it at 0. That's suspected, NOT proven.
- No settings file, so it resets every launch.

**Ruled out:**
- No patch in the manifest touches 0x100BC, the fire code or these words, and nothing on the host writes them.
- 0x163E8 is the BOOK page loader, not a flash.
- 0x32722 (stop all samples) only runs on [0x1528F4], a book palette refresh.

**The probe:** the watcher logs 'shot N: ammo a -> b; effects volume v/127, on-word, pause, conversation, weapon' on the first 6 shots and then every 25th. Read that line before theorising.

**The muzzle flash** (built the same day) uses the same ammo-drop detection:
- GpuRaster uFlash/uFlashC/uFlashRange: a warm all-round term after the lamp, by depth, facing and relief, masked by the lamp pair's shadow occlusion (occF). The lamp views are drawn during a flash even with the flashlight off.
- Watcher: -NoMuzzleFlash, -FlashPower 1.6, -FlashRange 420. Envelope: 12 ms rise, then exp tau 0.05, gone at 0.25 s.
- Test-GpuLook -Flash 1.6 renders it.
- Related: [[azrael-helmet-lamp]], [[azrael-gpu-effects]], [[azrael-scan-wire]].

## SOLVED (2026-10-07, 2nd report: voiceovers too)

**The probe cleared the game:** at every shot, effects volume 100/127, on-word 1, pause 0, conversation 0. So the game asked for the sound and the emulated Sound Blaster didn't produce it.

**The cause was the loading gate (LoadingScreen.cs GameGate).**
- When the game reached play before the renderer was ready (every FIRST launch after the watcher starts, i.e. while it compiles), it held the game with NtSuspendProcess on DOSBox, freezing every thread, ~8 s.
- Every session with a hold (15:56, 16:45, 16:54, 17:10, 17:27, all 7.6-10.8 s) lost its digital audio; sessions without a hold were fine.
- 15:56 was the session right before 'gunfire no longer plays'.

**The fix: the game holds ITSELF.**
- AztFrameLimit spins until aztFramePeriod (obj1 0x510A2, from the manifest settings) and re-reads it every pass. The gate writes 0x7FFFFFFF to park the frame loop, while DOSBox, its timers, IRQs and the SB keep running.
- Release: if aztBootState != 0, move the boot's T0 (+12) on by the held microseconds FIRST, then restore the period.
- Tested offline via reflection on a fake memory block.
- Suspend/Resume still exist but are UNUSED.

**NEVER freeze DOSBox for more than a moment.** Note that music (FluidSynth, in DOSBox's mixer) and SB digital are separate paths.

## The park LEAKS: pin the boot's clock instead (2026-10-07, 'will not play the full bootup if I skip the movies too fast')

**What happened:** the 17:46 and 17:51 sessions had the guest boot reach state 2 within 0.15 s of release.
- Some game states skip AztFrameLimit (AztActorTime's comment says so), so the boot ran on behind the loading screen.
- The release then added the whole hold to T0. el went negative, wrapped unsigned past BOOT_CAP, and the boot ended at once.

**The fix:** the gate pins the boot's clock all through the hold.
- Every 1 ms while held (and once more at release): if aztBootState == 1, T0 (+12) = GuestNow - el_held.
  - el_held is El (+16) when first caught: 0 for a fresh start.
  - GuestNow = AztNow's own formula: [0x46C] x [0x1485E0+d2] + [0x1485A0+d2], 32-bit; reread if the tick changed between reads.
- The boot cannot advance whether or not frames leak. The period park stays as well.
- Tested offline: el is held at 0.5 s across an 11 s hold while the fake guest tried to move it on.
- aztBootState 0x1351BE, aztBootT0 0x1351CA, aztBootEl 0x1351CE (overlay.sym).
