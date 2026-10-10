---
name: azrael-cutscene-triggers
description: "Movie player is 0x20BD4 with a per-call-site fps immediate; in-game cutscenes are conversation responses in WORLD.DAT, not room triggers. Test-Movie.ps1 is the bench."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-09-29T17:44:32.697Z
---

**The player.** `0x20BD4`, Watcom convention: `eax` = full path, `edx` = fps, `ebx` = flag.
Only five callers, all startup/ending: mindlogo `0x1FF67`, intro `0x1FFC0`, `%sintro.mov`
`0x2008A`, `%soutro1.mov` `0x20133`, `%soutro2.mov` `0x2019B`. The path prefix comes from
`[0x162B70]` (RESOURCE.CFG line 3).

**Frame rate is a per-call-site immediate**, not read from the header:
`mov edx, 15` at lin `0x1FF5D` (file `0x0719B1`) for mindlogo, `mov edx, 10` at lin `0x1FFB6`
(file `0x071A0A`) for intro. Opcode `BA`, imm32 follows. These are PLAIN immediates, not
relocated operands, so they are safe to write — unlike the `mov eax, <string>` right after them.

**In-game cutscenes do NOT go through those five sites.** `0x16AD6` builds the path with
`sprintf(dest, "%s%s", [0x162B70], ecx)` where `ecx` is a name supplied at runtime by the world
engine, then goes via `0x201E0`.

**They are CONVERSATION responses, not room triggers.** Measured: `WORLD.DAT` holds
`tandl1.mov` and `talfnl.mov` beside "Edgar", `libempty.mov` beside "Geffrye", `leocath.mov`
beside "Tobias"/"Tallum", `cobani.mov` beside "Tobias". So reaching a cutscene needs the right
dialogue node with the right flags — **a room warp would not get you there**. Don't build a warp
tool expecting it to test cutscenes.

**The shipped developer saves are a dead end.** `SAVE2/3/4/6.DAT` differ from each other in only
TWO bytes of 16,756 (`0x2EEC`, `0x416C`) and all load at the very beginning; confirmed in game.
`SAVE65535` is genuinely different (5,420 bytes) but is 768 bytes larger than a normal slot and
**crashes the game** when promoted into slot 4. Slots 0 and 1 are Josh's own saves — never touch
them. `SGDNAME.DAT` is 5 x 32-byte records, first NUL-terminated string is the displayed name;
there is no "EMPTY" literal in R.EXE, so the name is not what marks a slot unused.

**The tool:** `tools\Test-Movie.ps1` stages any movie into the mindlogo or intro startup slot and
patches that site's fps to the movie's own, reverting both on `-Restore` (verified byte-exact).
It covers picture, palette, fullscreen, keyframe-vs-buffer fit, clean decode, speed and audio
pitch. It cannot show the music bed or script side effects.

Related: [[azrael-mov-format]], [[azrael-zones-room-graph]], [[azrael-le-image-layout]].
