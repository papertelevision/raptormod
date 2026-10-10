---
name: azrael-lfb-plan
description: "Verified plan to move Azrael's blit to a VESA 2.0 linear framebuffer — LFB exists at PhysBasePtr 0xC0000000 and the change set is ~11 sites, not a rewrite."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-24T04:28:55.998Z
---

Investigated 2026-09-20. This supersedes the pessimism in
[[azrael-hires-blocker]]. Each point below was measured, not assumed.

## The LFB exists

Queried empirically: a DEBUG.COM script (`a 100 / mov ax,4F01 / mov cx,101 /
push cs / pop es / mov di,300 / int 10 / int 3`) run under a DOSBox Staging conf
matching the game's (`machine=svga_s3`, `vesa_modes=compatible`). DEBUG.COM ships
at `DOSBOX-STAGING\resources\drives\y\dos\debug.com`. **Its script file must have
CRLF line endings** — with LF only every line errors.

Returned `AX=004F` and ModeInfoBlock: ModeAttributes `0x009B` (**bit 7 set = LFB
available**), WinSize 64 KB, WinASegment 0xA000, BytesPerScanLine 640,
**PhysBasePtr = 0xC0000000**.

## The change set is small

- The inner copy is `rep movsw` and its per-scanline advance is already **32-bit**
  (`add edi,ebx` / `add esi,[ebp-0x4]` at 0x50F8E/0x50F90), so the loop is
  linear-safe untouched.
- Only the **initial** offset is 16-bit: 3 × `mul dx` + `add ax,cx` at
  0x50F17/0x50F1A, 0x5118E/0x51191, 0x5142C/0x5142F. `mul edx` and `add eax,ecx`
  are SHORTER encodings, and edx/ecx are already zero-extended by preceding
  `movzx`. Pad with NOP.
- 8 × `movzx edi,[ebp+0x2C]; shl edi,4` (8 bytes) -> `mov edi,[lfbBase]` (6 + 2 NOP)
  at 0x50EDD, 0x50FC3, 0x51038, 0x51078, 0x51154, 0x51235, 0x512BF, 0x5131C.
- The 13 `shl dx,cl` and 9 `int 10h` AX=4F05h bank switches go dead.

## IMPLEMENTED 2026-09-20 as v0.16.0 — with NO injected code

The plan below (init routine over 0x33EB8) was **abandoned**, for a reason worth
remembering: **the LE fixup table still holds 21 records pointing INTO those 198
bytes.** The loader writes obj2 addresses over whatever sits there, and the gaps
between fixup windows are at most 17 bytes. `$IMG.Fixups` uses field **`Site`**,
not `Addr` — a scan with the wrong field reports zero and looks clean.
Relocating was no better: the big unreferenced runs in obj1 are DOS/4GW
`int N; ret` thunk tables and functions reached only through pointers.

None of it was needed. The boundaries are derived at 0x33EBB by dividing the
WINDOW SIZE by the stride, and the window size is computed once at 0x33D21 as
`WinSize_KB << 10`. **Shift by 14 instead of 10** and the window reports as 1 MB,
so the four boundaries land at rows 1638/3276/4915/6553 — past row 479, still
inside a word — every rect resolves to bank 0, and the `int 10h` switches never
fire. One byte. `[0x182510]` has exactly two references in the image.

Shipped patch set (13, all data, no cave, no fixup surgery):
`lfb-no-bank-crossing` (0x33D23: 0x0A->0x0E), `lfb-mode-bit` (0x101->0x4101),
8 × `lfb-base-*` (7-byte sequence -> `mov edi,0xC0000000` + 2 NOPs),
3 × `lfb-offset-*` (`mul dx`/`add ax,cx` -> `mul edx`/`add eax,ecx` + 2 NOPs).
Verified through the loader after install — all 13 survive fixup application.

**RESULT: the framebuffer works. 0xC0000000 IS directly addressable** from
DOS/4GW's flat space — no DPMI mapping, no injected code, no fixup surgery. The
game ran, rendered, and the frame rate went UP markedly.

**But the shortcut was unsound and v0.16.0 was reverted to `$ENABLE_LFB=$false`.**

Two separate faults, one root:

1. *Splits are window-relative.* After crossing a boundary the blitter resets
   `edi = windowBase + rectX - boundaryX` (0x50FBF..0x50FC8) — offset 0 of the
   NEW bank, with the row component gone because the bank starts there. Pointed
   at an LFB that is nonsense: the continuation writes near the top of the
   framebuffer. This is the misplaced-rectangle artefact.
2. *Huge boundaries break the search.* Making the window 1 MB does not simply
   stop splitting: at 0x50F5B, `rowsLeft - rowsUntilBoundary <= 0` falls through
   to 0x50F60, which restores the count, does `dec word [ebp-0x6]` (bank index
   to -1) and walks `esi` BACKWARDS out of the boundary table. Stock never hits
   that path because a 64 KB window always splits a 480-row screen.

Visible symptoms, all from this: hard rectangular blocks, a coarse/posterised
picture (misplaced scanlines become noise, which xBR then smears), and a stray
image inside the mouse cursor (its save/restore uses the same offsets).
Confirmed by A/B screen capture — LFB-off is smooth and detailed.

### Attempt 2 (also failed) — suppress the split at source

Each of the three blitters has an identical split decision. Replacing it with
"copy every remaining row in one pass" is 14 bytes and fits:

| func | region | rows var | copy loop |
|---|---|---|---|
| 0x50EA5 | 0x50F51, 15 B | [ebp+0x14] | 0x50F81 |
| 0x5111C | 0x511C6, 15 B | [ebp+0x18] | 0x511F6 |
| 0x513BF | 0x51466, 14 B | [ebp+0x14] | 0x51495 |

`pop ax` / `mov eax,[rows]` / `mov dword [rows],0` / `jmp copy`. Keep exactly one
`pop ax`: each function pushes 8 bytes before the loop (`push r32` + two
`push word [r]`) and its exit pops 6 (3 × `pop ax` at 0x510C8 / 0x5136A /
0x515DB), so one 2-byte pop in between balances it.

Verified through the loader — all ten patches land correctly. **Still wrong:** two
reticles drawn at different places and large black areas where geometry belongs.
Reverted again.

### Attempt 3 — USE THE GAME'S OWN LINEAR PATH (this one works)

Both earlier attempts fought the bank logic for nothing. **Each blitter already
contains a linear fast path** for rects that do not straddle a boundary: rows
from `[ebp+rows]`, no boundary table, no stack juggling, no `int 10h`, per-row
advances already 32-bit. It is selected by
`cmp word [ebp+flag],0 / jz short / jmp <crossing>` — so make that jump
unconditional and every blit takes Mindscape's own tested code.

| func | test | len | linear path |
|---|---|---|---|
| 0x50EA5 | 0x50F1F (`[ebp+0x38]`) | 9 | 0x510D0 |
| 0x5111C | 0x51196 (`[ebp+0x3C]`) | 9 | 0x51372 |
| 0x513BF | 0x51434 (`[ebp+0x40]`) | 9 | 0x515E3 |

Replace the 9 bytes with `E9 <rel32 to linear>` + 4 NOPs.

**PROVEN, not assumed:** a sweep of every decoded branch shows each crossing
region (0x50F2D..0x510CF, 0x511A4..0x51371, 0x51442..0x515E2) has exactly ONE
entry from outside, and it is the `jmp` being replaced. So the other 13
`shl <r>,4` sites, all 9 `int 10h` bank switches and the whole boundary walk are
unreachable — no need to patch any of them.

**The dispatcher needs forcing too.** Making the blitter ignore banks is not
enough: the C-level dispatcher (0x34109 onward) still decides which bank a rect
starts in and passes BANK-RELATIVE coordinates. Under a linear framebuffer those
land short by the bank origin, and since the origin changes at rows 102/204/307/
409 the cursor appears to JUMP around rather than being displaced by a constant —
which is why the pointer could not be put on the lower panel at all (y 391..479
spans two banks).

So `lfb-one-bank` (0x33D23, `shl edx,0x0A` -> `0x0E`) is back, reporting the
window as 1 MB so the dispatcher puts everything in bank 0. **This is the same
one-byte patch that failed alone in attempt 1, and it is safe only in company:**
its failure mode was the blitter's boundary search walking backwards off the
table, and `lfb-linear-*` jumps straight past that search. Neither patch is
correct without the other.

Shipping set (11): 1 × `lfb-one-bank`, 3 × `lfb-linear-*`, 3 × `lfb-base-*`
(0x50ED9 edi, 0x51150 edi, 0x513F3 esi), 3 × `lfb-offset-*`, 1 × `lfb-mode-bit`.

#### `lfb-one-bank`'s SHIFT IS RESOLUTION-DEPENDENT (found 2026-09-24)

The shift must not be hard-coded at `0x0E`. The dispatcher's boundary is
`windowSize / stride` and the stride is the screen width, so a fixed 1 MB window
slides up the screen as it widens:

| width | first bank boundary | screen rows | verdict |
|---|---|---|---|
| 640 | 1638 | 480 | fine |
| 1024 | 1024 | 768 | fine (barely) |
| **1280** | **819** | **1024** | **BROKEN** |

At 1280x1024 every rect whose START row was >= 819 got bank-relative coordinates
against a linear framebuffer and drew near the top of the screen: the log box, the
automap, the scan readout, the gauge and all the panel buttons. **The full-screen
HUD repaint still looked right because it starts at row 0**, so the symptom read
as "the panel's colours are off" (its wells were showing the flat fills
Build-HudButtons puts in them) plus "the text box is floating in the upper left".
One cause, two unrelated-looking symptoms.

Build-AztMod now derives the shift: the smallest one whose window covers the whole
framebuffer, asserting the boundary clears the last row. 1280x1024 picks `shl 15`
(2 MB, boundary row 1638). The `-Expect` byte stays `0x0A`.

See [[azrael-resolution-asserts]] for the other constants of this shape.

Also checked and NOT the problem: 0x51646 (a bare `out dx,al` port write) and
0x50E40 (a dead VESA 4F02h mode-set helper, zero references).

**CONFIRMED WORKING** by the user at 11 patches. Everything renders correctly,
the pointer reaches the lower panel again, no ghost reticle.

### Bonus: ~1300 bytes of new code space

The bank-crossing machinery is now provably unreachable, **fixup-free and
contiguous** — unlike 0x33EB8, which had 21 fixups in 198 bytes:

| region | bytes | fixups |
|---|---|---|
| 0x50F2D..0x510CF | 419 | 0 |
| 0x511A4..0x51371 | 462 | 0 |
| 0x51442..0x515E2 | 417 | 0 |

1298 bytes, against a cave of 1664 with 24 free. This unblocks everything that
was previously refused for want of room — a real delta-time animation gate, the
in-game console ([[azrael-key-addresses]], HudPrint at 0x39080). Only usable
while `$ENABLE_LFB` is on, so anything put there must be inside that flag.

Result: geometry, detail and smoothing all correct, frame rate up. **One defect
left: a ghost reticle** drawn ~320 px left and ~128 px up from the real one (the
same "image inside the cursor" reported earlier). Not func 0x50E40 — that is a
dead VESA mode-set helper (`4F02h`) with zero references.

### What is still unaccounted for

**There are SIXTEEN window-base computations, not eight.** A scan for `shl edi,4`
misses them; scan for `shl <any r32>, 0x4`:
- `shl edi,4`: 0x50EDD 0x50FC3 0x51038 0x51078 0x51154 0x51235 0x512BF 0x5131C
- `shl ecx,4`: 0x51008 0x5127C 0x5151C
- `shl esi,4`: 0x513F7 0x514D6 0x5154C 0x5158D
- `shl eax,4`: 0x50E61 (func 0x50E40, reads the segment from `[edi+0x10]`, no callers found)

**Func 0x513BF uses ESI and is the read-back path** — that is why the mouse
cursor grew a stray image when only the EDI sites were patched.

The three INITIAL bases are 0x50ED9 (edi), 0x51150 (edi), 0x513F3 (esi). The
other thirteen are continuation paths. Attempt 2 patched only the initial three
on the theory that continuations become unreachable; the black areas suggest some
continuation DOES still run and writes into the unused 0xA0000 window. **Next
diagnostic: patch all sixteen to the LFB.** If the black areas turn into visible
garbage, a continuation is live and needs tracing; if they stay black, the fault
is elsewhere.

**Also corrected:** the frame-rate jump proves the `int 10h` AX=4F05h bank
switches, not the `rep movsw`, were the real per-frame cost — see
[[azrael-blit-vs-rasteriser]].

Also: PowerShell reads a bare `0xC0000000` as a NEGATIVE Int32; write
`0xC0000000L` before casting to uint32.

## The code-space problem (superseded — kept for the next resolution step)

`0x33EB8` (the boundary precompute) is **198 bytes with a single caller,
0x33A73**, in the mode-set path — and becomes entirely dead in LFB mode.
Overwrite it in place with the LFB init: read PhysBasePtr from
`[[0x182528]+0x28]`, map via INT 31h AX=0800h (fall back to the raw physical
address if CF is set, in case DOS/4GW is unpaged), store the base, and write the
four boundary pairs (0x182514/16/18/1A/1C/1E/20/22) past the end of the screen so
no crossing ever fires. No cave needed, no LE page surgery.

Also set the mode with bit 14: `0x33ABB` `mov ecx,0x101` -> `0x4101`.

Note `0x33EC1` hard-codes `mov ebx,0x280` (stride 640) — another resolution
constant.

## Still unverified

Whether DOS/4GW's INT 31h AX=0800h maps 0xC0000000, and whether anything reads
back from video memory. Those only fall out of running it.

**Do the spike at 640x480 first** — no resolution, coordinate or art changes — so
a black screen means the plumbing, not the 346 constants.
