---
name: azrael-hud-gears-sound
description: HUD slide-in sound - WIRED IN 2026-10-07 as Josh's own ratchet.mp3 (art\boot\hud-ratchet.wav, stereo); BootSound's mixer is STEREO now (PlayStereo/LoadStereoWav). My synthesized v1-v3 (Make-GearsSound.ps1) were drafts he replaced.
metadata:
  type: project
---

Josh (2026-10-07): 'a machine-like sound of gears turning ... played when the UI comes in from the left and right during the boot ... don't put it in yet, let's refine it here first.'

**The slide it follows:** Panel.cs, SlideSeconds 0.9, ease-out cubic (fastest at the start). The boot fires the HUD at its 'INITIATING MS-2 HELMET H.U.D.' line, about 4.0 s.

**Generator:** Make-GearsSound.ps1, all synthesized, 44.1 kHz stereo, 1.8 s.
- Speed = (1-u)^2 with a 35 ms engage.
- Two gear trains: tooth ticks into 3 metallic resonators each (2650/3920/5480 and 1880/3150/4710 Hz), 52 teeth/s at full speed, the second gear 1.62x. Panned left and right.
- Motor: a saw at 120-350 Hz, LP 1.4 kHz, plus a mesh whine at 3x.
- Rumble: LP noise around 150 Hz.
- The latch at 0.9 s: 55 Hz thud, five inharmonic clank partials, a click, and a settle tick at +75 ms.
- A small room; normalized to -3 dBFS.

**Balance:** v1 had the latch 17 dB over the gears. Now gears about -21 dB, latch about -16 dB (latch 0.42, gear gain x16).

**Switches:** -Slide, -Teeth, -Motor, -Rumble, -Latch, -Room, -Seed.

When wiring it in: play from BootHd at the HUD cue (where it calls Hud slide-in), through its BootSound (mono mixer: would need a stereo path or a mono fold-down), level-matched to the other boot sounds.

## v2 (2026-10-07): Josh, 'heavier, like a gear/ratchet, more like servos, deep rumble underneath. v1 sounds like a cartoon'

**What made v1 a cartoon:** pure 2-5 kHz resonator 'tinks', evenly spaced ticks, a buzzy saw motor.

**v2 (Gears2 class):**
- SERVOS: per half, noise through a moving SVF band (380-900 / 430-1010 Hz, plus a 2x band) amplitude-modulated by a 9-tooth mesh, over a 62/71 Hz fundamental. The motor lags the slide a touch.
- RATCHET: 1.5 ms noise snaps into 4 low damped modes (215-940 Hz), 20 clicks/s at full speed, ±35% jitter.
- SUB RUMBLE: 3-pole LP noise around 70 Hz plus a wavering 42 Hz.
- LATCH: modes at 40/118/187/296/455/640 Hz with a pitch-drop start, a click, then a hydraulic hiss (SVF 3.2 kHz) from +60 ms.
- tanh saturation, then a darker 6-comb room.

**Measured:** 70% of energy below 150 Hz, 22% at 150-1000 Hz, 8% above 1 kHz. Machinery about -10 to -26 dB, latch -7.6 dB. 2.0 s. New switches: -Clicks, -Servo, -Ratchet, -Hiss.

## v3 (2026-10-07): Josh, 'I like the tink but want it deep, like a roller coaster pulled up a hill, or gears grinding; deep bass ratchet; a metallic click into place at the end, metal on metal, deep'

**Gears3:**
- RATCHET: chain-lift clacks. A 2.5 ms burst excites free-free BAR modes (1 : 2.756 : 5.404 : 8.933) at BarHz 190 (x1.09 on the second dog), decays 0.16-0.035 s, plus a ~60 Hz thump. 11 clacks/s at full speed, 30% minimum, ±22% jitter.
- GRINDING: SVF noise 230-390 Hz plus 480 Hz with a gritty level jumping every 64 samples, plus a 70-110 Hz harmonic whine.
- Servos down to 0.35; rumble kept.
- CLANG: the bar modes at ClangHz 95 (5 partials, decays 0.65-0.09 s), a 41 Hz body thud, a 4 ms contact. Hiss 0 by default.

**Measured:** 81% of energy below 150 Hz, 2% above 1 kHz. Clack peaks every 20-60 ms, slowing, clang at 0.92 s.

**If it reads as too dull:** raise the upper bar modes' amplitudes (ba[]) or BarHz.

## WIRED IN: Josh's own ratchet.mp3 (2026-10-07)

- He made his own track: C:\Users\josh\Desktop\AzraelTearSoundtrack\NewSounds\ratchet.mp3, 3.64 s, real stereo (side 4.8 dB under the mid), mastered hot (peak 1.0, about -11 dB RMS).
- Make-LoadingAudio.ps1 decodes it (AudioFx.DecodePcm) to AztMod\art\boot\hud-ratchet.wav.
- **BootSound's Mixer is STEREO now.**
  - waveOut has 2 channels; the hum bed and mono cues are mixed into a mono buffer and spread to both sides.
  - Voice.St marks stereo clips; _pending is List<Clip>.
  - New: PlayStereo(interleaved), LoadStereoWav(path, gain), which scales by gain x Volume/0.36.
- **BootHd:** HudSoundPath/HudSoundLevel 0.5, loaded at Start. HudSlideSound() plays it where the HUD is let go (HudBeats, ReleaseHud), ONLY if hud.HoldOff was set, so a reload with the HUD already out gets no sound.
- **Watcher:** -NoHudSound, -HudSoundLevel.
- **Measured:** the ratchet at about -20 dB RMS vs a typing cue's -25 dB.
- **Tested live** at tiny volume: the mixer opened, mixed stereo plus mono, and drained.
