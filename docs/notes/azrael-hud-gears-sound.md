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
- **Double slide sound on a LOAD (Josh, 2026-10-15: heard behind the loading screen, then again at the hand-off):** the watcher holds the HUD during a load (`HudWait` + `panel.HoldOff` every frame), but BootHd's own `ReleaseHud()` -- at the reload boot's shutter beat and its hold timeout -- ignored `HudWait`, released it with the sound, and the watcher took it back until `HudIn()`. Now `ReleaseHud(fromWatcher)` returns while `HudWait` unless called from `HudIn`. Only the hand-off plays it.
- **REAL CAUSE (Josh, same day: "I still hear the sound under the loading screen"):** the sound fired on the HoldOff RELEASE, but the panel's visual slide starts only when its window shows (Panel loop: `want` needs `_ov.Shown`; slide when shown after >= HideToSlide 3 s hidden). After a title load the release came at "the view is steady" (watch.log 14:12:43) while the loading panel was still fading; the overlay -- and so the slide -- came out ~4 s later. NOW: a release only ARMS the sound (`HudSlideSound` stamps `_slideArmedAt`); `Panel.SlideStarted` (fired on the panel's thread at `Slide = 0`) calls `BootHd.OnHudSlide`, which plays it if armed within `SlideArmSeconds` 20. `BootHd.Hud` is a property whose setter wires the callback. Sound and slide are now the same moment by construction.
- **STILL heard after the slide-sync fix (Josh, same day) -> the whole loading sequence is SILENT (his idea, "and see if that helps"):** Watch-HostRender `Set-LoadSilence` / `Step-LoadSilence` (called first in Step-LoadGuard): from a load's start (title pick / memory-core read) until `panel.Slides` goes up (10 s after the loading panel goes with no slide, 90 s cap): `BootSound.Silence` (static: Play/PlayStereo drop and NOTE each clip -- `SilencedN`, `SilencedWhat` = length + mono/stereo; the mixer writes zeros, hum too), `LoadingAudio.Silence` (the title's voice + track run on silent), and DOSBox via `AztTool.AppMute.Set(pid, mute)` (Core Audio: default output's sessions for that pid, ISimpleAudioVolume.SetMute -- Windows' per-app mute, NOT a suspend; verified on a real session). `OnHudSlide` lifts `BootSound.Silence` first so the slide's own sound plays. DOSBox is unmuted on attach, at game end and on stop. Log: "load audio: SILENT ..." / "load audio: back on after X s (...) -- N host sound(s) asked to play while silent: <lengths>" -- the ratchet clip's length identifies it. If the sound is still heard with all of this off, it is not ours or DOSBox's. -NoLoadSilence.
- **THE RATCHET UNDER THE LOADING SCREEN WAS THE GAME'S OWN `hud3.wav` (2026-10-15).** With every host sound, the loading audio and DOSBox silenced, the log showed 0 host sounds asked to play -- yet Josh still heard "a ratchet". R.EXE names `hud3.wav` (2.13 s, 8-bit mono, its interface sound) beside hud3.pcx and the HUD button art, and plays it as its HUD comes up: after a title LOAD that is the first frame of play, 0.1 s after the gate's release (gate clock 21.8 -> 21.9 s; the watcher prints gate notes LATE, so its wall-clock stamps hid this), a second before the watcher's frame loop muted DOSBox. FIX: the title gate mutes DOSBox AT THE PICK, before `ReleaseTitle` (`LoadingScreen.cs GateMute` -- its own copy of AppMute, the gate is compiled separately; `MuteGameOnLoad`, set from -not -NoLoadSilence); the watcher's load silence keeps it and unmutes at the slide. The loading voice/track are NOT silenced (Josh wants them; `LoadingAudio.Silence` kept only for tests). Lesson: when a sound survives every fix of ours, look for the GAME playing its own sample (GAME\AZRAEL\*.WAV, names in R.EXE), and judge timing by the gate's own clock.
- **hud3.wav was WRONG (same day):** waveform match of hud-ratchet vs HUD3.WAV = 0.04 (a different sound); the ratchet is in no loading clip either (exact-waveform match <= 0.46; a band-energy "fingerprint" scored every game WAV ~0.8 -- useless, not discriminative). Josh still heard it with the gate mute at the pick (log 15:01:53) and 0 host sounds requested; he closed the game himself right after (no crash). NEXT STEP = MEASURE: `BootHd.cs AudioMeter` (Core Audio IAudioMeterInformation per session, every 40 ms, runs above 2% peak written as "+a..+b s  process (pid) peak", our steps marked with `AudioMeter.Mark`: load began, view steady, HudIn, OUR slide sound, game exited). Watcher `Step-AudioMeter` starts it (60 s) when the title menu is up or a load begins, drains it into watch.log. -NoAudioMeter. Read the next load's lines before guessing again. The gate's GateMute at the pick and the load silence stay in.
- **MEASURED (AudioMeter, title load 15:33:41, Josh: "heard it as the loading screen faded"):** ONE ratchet in the whole load -- ours, +8.02 s, the same frame as HudIn (the title window fully gone, TitleShowing false), Panel.SlideStarted and the materialize start; powershell peak 0.48 for +8.17..+11.74 (the 3.6 s clip). Before it: only the loading voice/track (powershell, <= 0.35) and DOSBox muted (Windows confirmed). So the "under the loading screen" double is GONE; what remains is the slide's own sound at the end of the fade. TRAP FIXED: GateMute (gate assembly) and AppMute/AudioMeter (renderer) each declared a [ComImport] class for the MMDeviceEnumerator CLSID -- in one process the second cast failed ("Unable to cast MMDeviceEnumeratorCo to MMDeviceEnumeratorCo"); now `Activator.CreateInstance(Type.GetTypeFromCLSID(...))` everywhere (tested together in one process).
- **Josh, after the measured run: "The problem is a ratchet sound that is played the instant I click to load a game and the loading interface appears ... attached to the animation of the loading interface expanding. The ratchet sound associated with the slide out animation of the UI is fine as-is."** So it is AT THE TITLE'S LOAD CLICK, not the HUD. The title's own sounds are synthesized (Tone: _tick 2600 Hz 18 ms, _confirm 520/780 Hz 0.16 s; LoadingScreen.cs:967) -- no ratchet clip anywhere in LoadingScreen.cs. The meter had started only after the pick, so it missed the click: now `AudioMeter.Start(300)` right after the renderer compiles (covers the title and the click) and `TitleScreen.LoadClickTicks` (stamped at LOAD/CONTINUE) is marked on the meter's clock (`AudioMeter.MarkAt`).
- **ROOT CAUSE, MEASURED (2026-10-15, AudioMeter from launch + TitleScreen.LoadClickTicks):** LOAD clicked +34.03 s -> "OUR HUD slide sound played: the panel's halves started in" +34.35 s. BootHd's boot thread, in M_DONE with the game at its TITLE (boot state 2), runs the "attached late" safety release (`if (state == 2 && Hud.HoldOff && !HudWait) ReleaseHud()`), which ARMED the slide sound; the panel then slid in behind the title the moment the click brought the view up, and the armed ratchet played. FIX: `ReleaseHud(fromWatcher, silent)` -- that release is silent now. Only HudBeats (a new game's HUD line) and HudIn (a load's hand-off) arm the sound.
- **Diagnostics now OPT-IN** (they were not the fix): `-LoadSilence` (host silence + DOSBox mute during a load; also sets the gate's `MuteGameOnLoad`, default false) and `-AudioMeter` (the per-program meter from launch). Normal play: the game's sounds and the loading voice/track play during a load as before. Lesson: four rounds of fixes went to the wrong cause by reasoning from code; ONE measured run with the click stamped found it. Measure first.
- **Slide sound lost at the hand-off (Josh, after the click fix):** after a title load (15:47) the game was "not in front" for ~17 s (true colour window "on screen no", "game not in front"), so the panel could not show until Josh pressed ESC; the old 20 s arm lapse had run out by then. NOW: `HudSlideSound` arms only when a slide is coming (`Hud.Shown` false), no time lapse; `ReleaseHud(silent)` and `Panel.ShownWithoutSlide` (back on screen hidden < HideToSlide, so no slide) clear the arm. Open item: the game not being in front after a title load (focus) -- watch for it.
- **Round after (Josh: "No changes, it still doesn't work and I still hear the system menu sound effect. That's an old one from the CPU game"):** (1) the menu sound is the ORIGINAL GAME's (DOSBox): a title LOAD is carried out through the game's own load menu (the gate writes the slot + OK; log: "the fold-out's slide was stuck ... put back at rest", "memory core: the host draws the save/load screen") and the game plays its menu sound. The DOSBox mute is now DEFAULT for a load: the gate mutes at the pick (`MuteGameOnLoad` = -not -NoLoadGameMute), Set-LoadSilence keeps it until the panel slides in; our sounds (BootSound.Silence) only with -LoadSilence; the loading voice/track always play. (2) slide sound: `ShownWithoutSlide` no longer clears the arming (suspected of cancelling it when the panel flickers on during a load); every arm / play / skip is now logged ("HUD slide sound: armed / PLAYED / NOT armed / not armed -- silent") -- read those lines first next time.
- **The race (Josh: "the ratchet sound is back in the loading sequence", log 15:59:37 "armed" + "PLAYED", then again at the hand-off 15:59:42):** a load's RE-BOOT starts the instant LOAD is picked (the gate releases the game); BootHd's HudBeats (`_reboot` -> release at once) ran before the watcher's Step-LoadGuard had set `HudWait` (the boot's notes are printed by the watcher LATE -- they showed :37, it happened at the pick). FIX: HudBeats arms the sound only when `!_reboot` (a new game); a re-boot's release is silent and clears any arming. After a load ONLY HudIn arms it. TRAP: BootHd note timestamps are when the watcher printed them, not when they happened.
- **SOLVED (Josh, 2026-10-15: "it works now, the ratchet only plays at the slide-in").** Final state: the sound plays on `Panel.SlideStarted`; armed only by HudBeats for a NEW game (`!_reboot`) and by HudIn after a load; quiet releases (attached-late at the title, a re-boot) never arm it; the game's own audio is muted from the title's LOAD pick to the slide (gate `GateMute`, watcher `Set-LoadSilence`; DOSBox unmuted on attach, game end and stop -- Josh force-quits after loads, that is fine); the system menu's own open sound is off (`SysOpenSound`) until Josh's new one.
