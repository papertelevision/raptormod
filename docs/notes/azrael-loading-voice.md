---
name: azrael-loading-voice
description: 'Loading ... Raptor Mod.' (Josh: 'absolute perfection') plays on the loading screen over his raptormod_loading track; the game is released only after the voice finishes, then the track fades. Files in art\loading, built by design\boot-sounds\Make-LoadingAudio.ps1.
metadata:
  type: project
---

Josh asked (2026-10-07) for a digitized, synth-like voice saying "Loading RaptorMod." with heavy reverb and echo, to preview before further instructions. Placement is not decided yet; the loading screen is the obvious candidate.

**Generator:** AztMod\design\boot-sounds\Make-LoadingVoice.ps1, output 11-loading-raptormod.wav, 44.1 kHz stereo, 7.35 s.
- **Source:** SAPI, Microsoft David, SSML prosody rate -12% pitch -8%. Only David and Zira are installed on this machine. A distributed build would need the clip shipped as a file, not regenerated: other machines may not have the same voices.
- **Vocoder:** 24 RBJ band-passes (Q 5.5) from 90 Hz to 9 kHz, envelopes with 4 ms attack and 25 ms release.
- **Carrier:** two saws at 82 Hz and x1.006, plus a sub sine an octave down; noise above 4.2 kHz, a blend from 2.6 kHz.
- **Mix:** dry 0.18; crush 0.45 (sample-and-hold to 16 kHz, 10 bits).
- **Echo:** ping-pong 380 ms, feedback 0.45, LP 3.2 kHz.
- **Reverb:** Freeverb, room 0.9, damp 0.35, wet 0.5, right side spread 23.
- **Measured:** speech about -16 dB RMS for 1.5 s, tail down to -60 dB by about 4.7 s, peak 0.87.
- **Switches:** -Pitch, -Dry, -Crush, -EchoMs, -EchoFb, -Room, -Wet, -Tail, -Voice, -Text.

Related: [[azrael-gpu-boot]], [[azrael-gun-sound]].

## v2 (2026-10-07): Josh couldn't understand v1 ('too much distortion; I need to hear some semblance of raptor mod')

**Measured with Windows speech recognition**, not by ear. recognize.ps1 in the scratchpad runs free dictation plus a forced choice of the phrase against decoys.
- Plain TTS 0.99; v1 no match.
- Per stage: vocoder blend and crush keep it (0.90). The ECHO lost it: the first repeat of 'loading' landed on 'raptor mod'.

**The v2 fixes:**
- The plain voice runs in PARALLEL, loudness-matched (Dry 0.55 vs the vocoder).
- 32 bands at Q 7.5; crush 0.22; echo 520 ms, feedback 0.35; reverb wet 0.38 with a 70 ms pre-delay; rate -20%.
- SIDECHAIN DUCKING (Duck 0.85): the echo and reverb returns are pulled down while the voice is active (5 ms attack, 350 ms release) and bloom after it.
- Result: the full chain is recognized as 'loading raptor mod' at 0.83. Free dictation fails on any vocoded voice, so it's no use as a measure.
- -Stage mix|crush|echo|full writes the intermediate stages for testing.

## v3 (2026-10-07): 'deeper in tone' and 'Loading ... Raptor Mod'

- Carrier 82 -> 62 Hz; SAPI pitch -25%; the voice is shifted down 3 semitones by resampling before the vocoder (formants drop too).
- Text 'Loading ... Raptor Mod.': '...' becomes an SSML break (-PauseMs 450). Measured, the voice stops about 0.7 s between the words, with the echo ringing about 10 dB down in the gap.
- Recognizer forced choice 0.89. 8.25 s long.

## SHIPPED on the loading screen (2026-10-07)

- **Josh:** play it on the 'Loading RaptorMod' screen layered over his track (C:\Users\josh\Desktop\AzraelTearSoundtrack\NewSounds\raptormod_loading.mp3, 12.04 s). If loading finishes first, load into the game, but ALWAYS finish the voice.
- **Files:** design\boot-sounds\Make-LoadingAudio.ps1 builds AztMod\art\loading\.
  - loading-track.wav: the MP3 decoded via AudioFx.DecodePcm (Media Foundation). winmm MCI MP3 ('mpegvideo') fails on this machine with error 277, and WAV always works.
  - loading-voice.wav: v3 with the tail below -55 dB trimmed, 6.09 s.
- **Player:** LoadingAudio in LoadingScreen.cs, its own stereo waveOut mixer (that file compiles standalone). Voice 1.0 over track 0.35 (measured: the track is ~5.6 dB louder than the voice), soft limiter at 0.75, FadeTrack 1.2 s.
- **Gate:**
  - The sound starts with Screen.Show() at the hold.
  - Ready() is now a REQUEST (_releaseReq). The gate thread releases when the voice is done; VoiceDone waits out the ~0.19 s of queued buffers. Then the track fades.
  - Ready(true) forces release (ProcessExit, Dispose).
  - No loading screen means no hold means no sound: it only plays when the screen actually shows.
- **Watcher:** -NoLoadingSound (also -NoBootSound), -LoadingTrackGain 0.35. Late gate notes are written from Write-BootNotes (Write-GateNotesLate).
- **Tested offline:** voice done at 6.22 s; track faded and the player stopped 1.4 s later; Ready() during the voice kept the game parked, Ready(true) released it.
- **Softer, 'as if in the distance' (2026-10-07):** VoiceGain 1.0 -> 0.5, plus a 2-stage one-pole low-pass at 2.8 kHz on the voice at playback (VoiceLowHz). TrackGain 0.35 -> 0.3. Watcher: -LoadingVoiceGain, -LoadingTrackGain.

## The loading screen's LOGO (2026-10-07)

Josh: 'an animated logo above the loading text ... wireframe feel (similar to the grail), pure white, 1-2px vector linework of an animated pair of fangs, logo like, animated in the smooth style of the reticle animation'.

**Where:** LoadingScreen.DrawFangs. The panel grew upward by LogoBand 168 px at 96 dpi; the drawing lives in DrawPanel, and Preview(sc, t, shown) renders it offline (scratchpad logo-test.ps1).

**The mark:** an arched jaw line, and two curved fangs (outline Beziers plus a thinner centre line plus four cross-section rings) inside reticle-style corner brackets. Pure white, ~1.5 px, antialiased, no glow.

**Timeline (s after shown):**
- Brackets in from 1.6x, turning 45 -> 0 deg, the arms shortening (0-0.45).
- Jaw line drawn out from the middle (0.2-0.75).
- Fangs drawn gum to tip via Partial(), left at 0.45 and right at 0.55, 0.6 s each; the rings pop in with EaseBack.
- Lock rings off the tips (1.15-1.6).
- Idle: breathing 0.88-1.0 over 2.4 s, a scan line every 2.8 s, a glint down each fang every 3.2 s.
- It fades with the window's own 350 ms fade.

**Logo v2 (Josh: 'lose the brackets, make it more 3d, 40% smaller'):**
- No brackets. LogoScale 0.6, LogoBand 96, cy = band x 0.52.
- Fangs are 3D tusks: round sections of radius 0.155 x (1-u)^0.8 swept along a spine curving in (x) and forward (z). 8 meridians drawn gum to tip, 5 rings in near/far halves, depth-dimmed.
- The jaw is a horseshoe band (z = -0.42(1-x^2)), upper and lower edges plus ticks.
- Perspective k = 1/(1+0.35z); tilt -0.22. It swings in from 0.55 rad during the build, then sways +/-0.38 rad over 7 s.
- Lock rings off the tips at 1.1 s; the idle breathing, scan line and glint are kept.
- **Loading bar counts up from empty when the screen shows:** display = _shown x EaseOut(t / BarIntro 1.4 s).
- **Credit line under the bar** (Josh asked for it): 'Developed by Josh Sears. Papertelevision.com', Segoe UI 10.5 px at 96 dpi, grey 140. Drawn with plain AntiAlias: GridFit spaced the small type unevenly. CreditBand 22.
- **Credit v2:** 11.5 px, the same 235 grey as the main type, two centred lines ('Developed by Josh Sears.' / 'Papertelevision.com'), split on a newline in Credit. CreditBand 48.

## The loading screen EVERY launch (2026-10-07)

Josh: 'I do want to see it every time so at the minimum we hear it say Loading Raptor Mod'.

- GameGate.AlwaysShow = true.
- A Ready() that arrives while not held just sets _releaseReq and keeps the screen (no Dispose).
- The game is held at the first gameplay frame whatever the renderer's state. If it is already ready, it's released when the voice is done (~6.2 s); otherwise when the renderer is ready AND the voice is done.
- The 'renderer ready before the game was found / reached play' early returns are skipped when AlwaysShow is set.
## One size every launch (2026-10-14)
Josh: "The raptor mod loading screen is sometimes full screen and sometimes smaller. It needs to be consistently the correct size." The cause could not be seen in the logs. The panel used to be scaled by GetDpiForWindow/96, read once, with the window sized once from the monitor rect.
- Now (LoadingScreen.Loop), every 250 ms:
  - the window is fitted to the primary monitor again (GetWindowRect vs rcMonitor -> SetWindowPos);
  - the panel is scaled by the window's OWN client height: sc = max(1, height / 1067), which is 1.5 at 1600 rows, the size it was designed at on Josh's 150% screen. So it is the same share of the screen whether or not the thread's DPI awareness took, or the display changed under it (DOSBox going full screen).
- It re-centres (black cleared) when the size changes. Compiles with the gate's own options (/define:TITLE_GATE + RaptorDocs.cs + CursorShapes.cs).
- **Movies:** Josh asked for full-screen movies, then chose to leave them for his own re-render (2026-10-14). Don't re-propose a host player or a re-encode.
- **Still too small (Josh, 2026-10-14, the next launch):** "it's about sometimes not being full screen, regardless of resolution", same machine and same window size every time. The cause is still unknown: every host window uses the same DPI call, and the log had nothing on this screen. So it now REPORTS ITSELF:
  - `LoadingScreen.Log` (GameGate.Start -> its notes -> watch.log "loading gate: ... loading screen: ...") gives, each time its size changes: window rect, client size, monitor size, DPI and whether the per-monitor DPI context was accepted, panel size and scale.
  - `ShotPath` (watcher: <CacheDir>\loading-screen.png) saves a third-size picture of the whole screen ~1.5 s after it shows.
  - Next time it is wrong: read those two before changing anything.
- **FOUND (2026-10-14, the next launch -- the log + picture did their job):**
  - The window was right (2560x1600, dpi 144, per-monitor) and the panel's numbers were right (479x311 at 1040,644, scale 1.5). The PICTURE showed it drawn at 2/3 from its top-left corner: the bar 220 wide instead of 330, the centre ~80 px left.
  - **Cause:** `DrawImageUnscaled` scales by the bitmap's STORED DPI over the target's. A new Bitmap takes its DPI from the display context of the moment: 96 one launch, 144 the next.
  - **Fix:** `Blit()` = DrawImage at the image's own pixel size (destination rect + GraphicsUnit.Pixel), in LoadingScreen (the panel; the title's preview background) and Panel.cs (the HUD log lines and inventory, 3 sites).
  - The logging and the 1.5 s picture are kept.
