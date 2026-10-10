---
name: azrael-intro-sequence
description: "The intro sequence 0x1FF39 mapped - four reads of the skip flag 0x182DB0, and patching only some of them DELETES a movie. All four or none."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-10T05:17:38.056Z
---

The intro sequence is one function at `0x1FF39`. `0x182DB0` is the "a key was pressed" word:
the sequence reads it after each stage to decide whether to abandon the rest. The movie player
0x20BD4 does NOT read it (corrected 2026-10-10): it stops on a KEY event in the input queue
(type 2) or at its frame count, and mouse events count as frames. See [[azrael-title-menu]].

```
0x1FF67  call 0x20BD4      ; 1. AZRAEL\MINDLOGO.MOV   (edx=15)
0x1FF71  call 0x1FACC      ;    fade
0x1FFA6  cmp word [0x182DB0],0 / 0x1FFAE jnz 0x20099      <- near jnz, 6 bytes
0x1FFC0  call 0x20BD4      ; 2. AZRAEL\INTRO.MOV      (edx=10)  the logo sting
0x1FFCA  call 0x1FACC      ;    fade
0x1FFCF  cmp word [0x182DB0],0 / 0x1FFD7 jnz 0x20099      <- near jnz, 6 bytes
0x1FFDD  ...               ; 3. TITLE.PCX (string 0x141B21, loader 0x38A20)
0x20019  call 0x35448      ;    timed wait: up to 130 iterations...
0x2002C  cmp word [0x182DB0],0 / 0x20034 jz 0x20019       <- ...OR until the flag is set
0x20049  cmp word [0x182DB0],0 / 0x20051 jnz 0x20099      <- SHORT jnz, 2 bytes
0x2008A  call 0x20BD4      ; 4. MOV\INTRO.MOV         (edx=10)  the story intro, 18 MB
0x20094  call 0x1FACC      ;    fade
0x20099  xor ebx,ebx / xor edx,edx / lea eax,[ebp-0x14]  ; EPILOGUE
0x200A0  call 0x33F80      ;    screen clear  <- AztOpenMovie hooks here
```

**Why:** every `jnz` goes to the epilogue `0x20099`, so stock behaviour is that one keypress
anywhere abandons the *whole* sequence and drops you into the game.

**How to apply:** `$ENABLE_SKIP_ONE_CUTSCENE` turns each `cmp`+`jnz` into
`mov word [0x182DB0],0` + NOPs — skip ends only the movie being watched. **Patch all three
`jnz` sites or none.** Patching just `0x1FFA6`/`0x1FFCF` and leaving `0x20049` alone silently
*deleted* `MOV\INTRO.MOV`: the title screen's only quick exit is to set the flag (`0x2002C`
loops while it is clear), and `0x20049` then threw the story intro away. Symptom reported as
"one of the videos is gone" — mindlogo → title → opening, with the title screen visible behind
a letterboxed movie.

Encoding note: `cmp word [disp32],imm8` is 8 bytes, `mov word [disp32],imm16` is **9** — one
more — so a near-jnz site is 8+6=14 → 9+5 NOPs and a short-jnz site is 8+2=10 → 9+1 NOP. The
disp32 sits at instruction+3 in both, so the LE fixup still lands on its own four bytes;
the file holds `B0 2D 04 00` (0x42DB0) and the loader adds the 0x140000 obj2 base.

`AztOpenMovie` must clear the flag too, or skipping the story intro takes out the extra
opening movie with it. In a cave with one byte to spare: zero `ebx` (the call wants it zero
anyway) and store `bx` — 7 bytes, not the 9 of `mov word [...],0` — and `push imm8 / pop edx`
for the fps, 3 instead of 5. See [[azrael-extra-intro-movie]], [[azrael-cutscene-triggers]].


## 2026-10-04: skip-ALL is back on (Josh, 'for now')

` = $false` -- the three sites are stock again, so one key abandons the whole sequence. It also takes out the extra opening movie, because **AztOpenMovie's flag clear has never worked**: it is cave code with no fixup and no delta, so `66 89 1D <0x182DB0>` writes the BUILT address while the flag lives at runtime 0x182DB0+0x1F1000. The earlier line above saying it 'must clear the flag too' describes intent, not behaviour. If skip-one comes back and the opening movie must survive a skip of the story intro, that store needs a real delta (overlay, not the cave).
