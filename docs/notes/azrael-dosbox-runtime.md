---
name: azrael-dosbox-runtime
description: "Azrael's intro movies cannot be patched out of R.EXE, and DOSBox memsize is NOT the fix for the enlarged-viewport crash."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-19T16:05:35.884Z
---

**Memory is a red herring.** With the enlarged viewport, DOSBox logged a long run
of `Illegal write to 1000000, CS:IP 180:200970` — exactly 16 MB, the top of the
stock `memsize=16` pool. Raising it to 32 moved the identical fault to
`0x2000000`. A fault that tracks the pool end is a buffer being walked off, not a
pool that is slightly too small. The real cause was the HUD overlay writing
552-wide rows into a 640-wide framebuffer — see [[azrael-hud-overlay-res]].
memsize stays at the stock 16.

Note `core=dynamic` makes DOSBox report the CS:IP of the translated *block*, not
the faulting instruction, so the EIP cannot be mapped back to an instruction.
Group the log by address range instead — writes and reads have separate 1000-line
caps, so raw counts are truncated and meaningless.

**Intro movies cannot be removed.** Three approaches all fail:

| approach | result |
|---|---|
| NOP `call 0x1FF39` at `0x1614B` (the whole sequence, one caller, unused return) | `Exit to error: INT:Gate Selector points to illegal descriptor with type f` |
| NOP its three calls to the player `0x20BD4` (`0x1FF67`, `0x1FFC0`, `0x2008A`) | same crash |
| rename `INTRO.MOV` / `MINDLOGO.MOV` | game exits silently before the menu |

So `0x20BD4` owns something structural during startup (video mode / event pump),
not just playback. Only the TM.EXE half can be skipped: `GAME\AZRAEL\AZRAEL.BAT`
is `tm %1 %2 %3` + `if NOT ERRORLEVEL 1 r %1 %2 %3`; replacing it with just
`r %1 %2 %3` works. `Apply-AztMod.ps1 -SkipIntro` does that. The two OTHER
`0x20BD4` call sites, `0x20133` and `0x2019B`, are the outro movies — leave them.

**How to apply:** don't re-try the movie patches, and don't reach for memsize when
a fault lands on a round power of two.

See [[aztmod-patch-framework]].
