---
name: azrael-music
description: "The game ships TWO scores and picks between them from MDI.INI's DRIVER line; all music is MIDI, there is no recorded audio. Plus the XMI/render tooling and the soundfont level trap."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-24T23:15:45.470Z
---

**ALL MUSIC IS MIDI. There is no recorded audio anywhere in this game** — 24
`.XMI` (Miles XMIDI) sequences, and AZT.CUE has a single MODE1 data track, so no
redbook either. Anything that "sounds like MIDI" is MIDI and always will be; the
only variable is the synthesiser. Do not promise otherwise (2026-09-21: calling
the change "General MIDI rather than FM" was accurate but read as "real
instruments", and cost a round of confusion).

## Two scores, selected by MDI.INI

`0x1EF9B` opens `MDI.INI`, parses its `DRIVER` line and matches it against
**ULTRA.MDI / SBAWE32.MDI / SNDSCAPE.MDI / MPU401.MDI**; 1 = wavetable, 0 = FM.
`0x138DD` then picks the track table:

```
jz 0x13986   -> FM set    awe_fm cath_fm egypt_fm fite2_fm ghost_fm grail_fm
                          game1_fm game2_fm krep2_fm krep3_fm peace_fm
else 0x138E6 -> GM set    awemyst cathedrl egyptian fight2 ghosts grail
                          ingame ingame2 kreepy2 kreepy3 peaceful
```

AztMod writes `MPU401.MDI` into MDI.INI (stock is `SBPRO2.MDI`), so it loads the
**GM set** — genuinely different arrangements, not just a different synth.
`MDI.INI.aztbak` holds the original; the installer excludes MDI.INI from the art
sweep, so only `-Revert` restores it.

Runtime chain, all verified: MDI.INI -> MPU401.MDI present in GAME\AZRAEL ->
matches the wavetable list -> Staging `mpu401=intelligent` + `mididevice=fluidsynth`
-> `FSYNTH: Using SoundFont ...`. Check the last one by running Staging headless:
`dosbox.exe --conf azrael-staging.conf --noautoexec -c "exit" --exit > log 2>&1`.

## SOUNDFONTS ARE NOT LEVEL-MATCHED — match before judging

SGM-V2.01 (236 MB) rendered about **4 dB quieter** than GeneralUser-GS (peak
3563 / RMS 541 vs 6513 / 874 on cathedrl). Under this game's ambience a quieter
bank reads as *"no difference at all"*, not as a quieter one — which is exactly
what happened. Level-match with `soundfont_volume` (percentage, 1..800, music
only; the master mixer would drag speech and effects too) BEFORE forming an
opinion. Settled on GeneralUser-GS: the difference did not justify 236 MB, and
it is the only one whose licence permits redistribution, so a release needs it.

## Tooling (both written 2026-09-21)

### The tempo trap — exports ran 39% FAST until 2026-09-24

**XMIDI's clock is FIXED at 120 ticks/second.** A delay of N is N/120 of a second
whatever any tempo meta event in the file says: Miles stores tempo events but does
not pace playback with them. `XmiTool.cs` used to pass them through, and a standard
player then obeys a tempo the game ignores. `INGAME.XMI` carries **359,280 us/qn**,
which against the 60 PPQN timebase is 167 ticks/sec instead of 120 — every export
ran 1.392x fast (INGAME came out 6:01 instead of 8:21).

Fix: **drop every `FF 51` from the XMI and always emit 500,000 us/qn at 60 PPQN**
(= exactly 120 Hz). Do not "preserve" the file's own tempo; it is not playback data.

Note `Add-Type` here treats C# warnings as ERRORS, so leaving the now-unused
`sawTempo` flag behind failed the build with CS0219.

* `tools\XmiTool.cs` + `src\Export-Music.ps1` — XMI -> playable .MID, sorted into
  `general-midi\` / `opl-fm\`. Two things XMI does differently and both must be
  undone: **delta times are summed bytes, not VLQs** (a standard VLQ is still
  used for meta/sysex lengths and note durations — the two readers are NOT
  interchangeable), and **there are no note-offs** — a note-on carries a
  duration, so note-offs are synthesised and scheduled, which means events come
  out of order and the whole track has to be collected and sorted by absolute
  tick. Output is 60 PPQN at 500,000 us/qn, which reproduces XMI's fixed 120 Hz.
* `tools\FluidRender.cs` — renders a .mid to .wav through **the same
  libfluidsynth-3.dll Staging uses**, so a render is what the game would play.
  Needs `SetDllDirectory` to the Staging folder first or the load fails with a
  bare "module not found". Renders via `fluid_synth_write_s16` and writes its own
  RIFF header, because the built-in file renderer wants libsndfile.

**This is how to judge any audio change here** — auditioning in-game means being
in the right room for the right cue with no way to hear two options back to back.

## CD-quality audio: possible, but a real build

Staging ships ogg.dll + opus.dll, so it can decode audio tracks from a CUE — the
emulator side is ready. The game side is **empty**: no MSCDEX/redbook strings and
the only INT 2Fh sites are DOS/4GW runtime. Worse, R.EXE is protected-mode, so
MSCDEX needs DPMI real-mode plumbing (`INT 31h AX=0100h` for a <1 MB request
buffer, `AX=0300h` to invoke), plus a per-frame poll to loop. ~300-400 bytes,
against ~200 bytes of free cave. Not attempted.

Related: [[azrael-dosbox-staging]], [[azrael-dosbox-runtime]]

## The visor boot effect (slot 11 / track 13) -- EXACT recipe

The boot audio is a CD track, not MIDI. Processed with `tools\Add-Reverb.ps1`:

```
.\tools\Add-Reverb.ps1 -In <track>.mp3 -Out <track>-verb.wav `
    -Rate 22050 -Channels 1 -Tail <pad> -Rt60 1.0 -Wet 0.15 -PeakDb -1
```

**These were RECOVERED, not remembered.** Nothing recorded them, so I swept Rt60 x Wet in
memory against the shipped `booting2-verb.wav` until the residual was 0.28 counts, then
confirmed the full command reproduced it **byte-identical** (0 of 264,710 samples differing).
Do this again rather than guessing if the settings are ever in doubt -- `-Rate`/`-Channels`
fall straight out of the WAV header, `-Tail` from (output length - source length), and
`-PeakDb` from the output's peak, which read exactly -1.00 dBFS.

Defaults are NOT what was used: the script defaults to Rt60 1.2 / Wet 0.25 / 44100 / stereo
and peak-matching, all of which are wrong for this track.

### Pad to a WHOLE SECOND

`Build-Soundtrack` computes `sectors = Secs * 75` and `us = Secs * 1e6` from an INTEGER second
count, so a 13.76 s file would be described to the game as 13 s. Choose `-Tail` so the result
lands exactly on a second: pad = (targetSecs*22050 - sourceSamples) / 22050.

Slot 11 is placed LAST on the disc precisely so its length can change without shifting any
music LBA -- so swapping in a longer track is safe. Rebuild order is **Build-Soundtrack ->
Build-AztMod -> Apply-AztMod**: the first writes `art\music-tracks.json`, which the second
bakes into the EXE.

A `.wav` effect emits `WAVE` in the CUE, a `.mp3` emits `MP3`; the extension decides, and
getting it wrong mis-reads rather than fails. There is no MP3 encoder on this box, so anything
processed can only come back as PCM. See [[azrael-8bit-movie-audio]] for the movie-side audio.

## THE LBA TABLE MUST BE BUILT FROM DECODED SECTOR COUNTS

`Build-Soundtrack` used to take each track's length from the Windows shell's `hh:mm:ss`
property -- **whole seconds** -- and compute `sectors = secs * 75`. The truncation is tiny per
track and **accumulates**, because every track's start is the previous one's end:

| trk | real sect | ours | drift |
|---|---|---|---|
| 2 AWEMYST | 14,612 | 14,550 | 0 |
| 8 INGAME | 26,965 | 26,925 | 2.49 s |
| 12 PEACEFUL | 15,570 | 15,525 | 4.97 s |
| **13 BOOTFX** | 1,050 | 1,050 | **418 sectors = 5.57 s** |

DOSBox lays the disc out from the FILES; our table only tells the game where to seek. So the
game asked the drive to start 5.57 s before the boot effect — **inside the fade-out at the end
of PEACEFUL**, whose last 7 s decays smoothly from −20.5 to −46.6 dBFS. That fade is the
"2-second orchestral swell before the boot sound" that survived every other theory.

**It was also the entire "~4 s of CD start latency."** There is no drive latency. Two rounds of
work went into compensating for it — holding the visual timeline at `$BOOT_TEXT_US = 4000000`
and moving the play request earlier — before the table was ever checked.

Fix: decode each track and use `ceil(frames / 588)` (a CD-DA sector is 588 frames at 44.1 kHz).
Slower than a shell property and the only way to land on the sector DOSBox does.

**Lesson worth more than the fix: when audio starts in the wrong place, verify the ADDRESS
before theorising about timing.** Three wrong causes were chased — MIDI cue, PCM sample,
drive latency — all downstream of an LBA that was simply wrong. The check is cheap: decode the
tracks, accumulate, compare against the table. See [[azrael-early-overlay]].

**THE MIDI STAYS DOWN UNDER THE RECORDED SOUNDTRACK (Josh, 2026-10-13: "If I adjust volume, it still switches to the old midi. It should never switch unless I click F4"):**
- **Cause:** the soundtrack plays as CD audio with the MIDI sequence held at volume 0 (AztCdSwitch). The game sets the MIDI's volume back up in SIX places, and the overlay only re-muted on a slider change (0x146940), a frame late:
  - 0x3B048 (set now): 0x14D94 the slider, 0x13E59, 0x13B18, 0x1154A;
  - 0x3B088 (fade, ebx ms): 0x16CC0, and 0x17FE2 -- the end of EVERY conversation (0x17E6E faded it out at the start).
- **Fix:** patches `midi-quiet-*` route those six `call`s (no fixups, no other patch on them) through overlay `AztMidiVol48` / `AztMidiVol88` -> `AztMidiQuiet`. While aztCdOn (stub cave) and aztCdMuted (overlay) are both set, it forces edx (the level) to 0; otherwise nothing changes. F4 unmutes as before. Every register but edx kept.
- **Music default:** 30% = level 38 (`$VOL_MUSIC_DEFAULT`; the menu shows level x 100 / 127). Sound stays at 127.
- Manifest 445 -> 451. Installed 2026-10-13, not yet heard in game.