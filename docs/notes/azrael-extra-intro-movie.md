---
name: azrael-extra-intro-movie
description: "An extra movie must play from the INTRO SEQUENCE, not the overlay — playing one on the first gameplay frame crashes, because the room's texture cache already holds the memory."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-09-30T22:43:08.373Z
---

**Playing a movie on the first gameplay frame CRASHES.** Tried it from the overlay in
`AztBootTick` state 0; the game reached the first frame (AZTCAM.LOG had exactly one record)
and died in the call. The movie player wants ~2.4 MB — two screen-sized surfaces plus its
frame buffer — and by the first frame the room and its texture cache have already taken
the heap. See [[azrael-texture-cache-reserve]].

So an extra movie plays from the **intro sequence**, where the three shipped ones do and
memory is free. That means file-backed cave code, because the intro runs before the first
frame hook and the BSS overlay is not resident yet.

**The sequence** (function 0x1FF39, all calling the player 0x20BD4 with eax=path, edx=fps,
ebx=flag):
| site | movie | fps |
|---|---|---|
| 0x1FF67 | `mindlogo.mov` (GAME\AZRAEL) | 15 |
| 0x1FFC0 | `intro.mov` (GAME\AZRAEL — the short logo sting) | 10 |
| 0x2008A | `%sintro.mov` (GAME\MOV — the real intro) | 10 |

`AztOpenMovie` replaces the call at **0x2008A**: it calls the player for the original, then
again for the new movie, then returns. 40 bytes at the end of the box-art blob (CAVE3).

**The path goes on the STACK**, pushed as three dwords, then `mov eax,esp`. That is exactly
what the game's own third call does (`lea eax,[ebp-0x78]`), and it avoids needing the obj1
delta to address a string — which would not have fitted.

**Audio rate: 22,050 Hz.** Derived, not guessed: steady-state chunks are 2205 bytes mono /
4410 stereo, and the call sites play at 10 fps. Chunk type 6 is 8-bit unsigned mono, type 7
stereo — raw PCM, so audio can be SYNTHESISED, which is what lets a movie exist with no
reference to copy chunks from (`Convert-ToAnim -AudioFrom`, added for this).

Related: [[azrael-mov-format]], [[azrael-cutscene-triggers]], [[azrael-cave-space]],
[[azrael-powershell-silent-traps]].

## SHIPPED AND WORKING (2026-10-02)

The exact command that produces a correct movie — every element of it was a bug at some point:

```
.\tools\Convert-ToAnim.ps1 -Mp4 <src.mp4> -Out <OPENING.MOV> `
  -Width 1024 -Height 768 -Fps 10 -Frames <audioSecs*fps> -Letterbox `
  -AudioFrom <src.mp4> -AudioRate 22050 -AudioStereo -AudioNormalize
```

- **1024x768, not the content's own aspect.** Black bars baked in, or the title screen shows
  around a letterboxed movie — the epilogue's screen clear runs *after* our hook.
- **-Frames is mandatory.** Without it the count silently follows the SOURCE (361 frames at
  10 fps = 36 s of picture over 15 s of sound). Guarded now, but pass it.
- **10 fps**, so 22050/10 = 2205 samples is whole. 12 fps gives 1837.5 and alternating chunks.
- Verified end to end: 181 frames, 18.08 s, frame 0 primed to 10,000 then 4,410 steady,
  223/256 codes used, no skew, no crackle.

Hooked at **0x200A0** (see [[azrael-intro-sequence]]); the stub clears the skip flag so it is
independently skippable. Cave 3 is at **418 of 419 bytes** — anything further added to the stub
needs `opening.mov` moved out of the push sequence into a data cave first.

Traps that cost the most time, each recorded in full elsewhere: the MF stride shear
([[azrael-mf-stride-trap]]), the missing frame-0 audio priming and the 0x00-vs-0x80 silence
fill ([[azrael-8bit-movie-audio]]).