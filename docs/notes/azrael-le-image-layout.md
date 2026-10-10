---
name: azrael-le-image-layout
description: "R.EXE's LE header lies about its data-pages offset; the real value is 0x61A54, derived from the file tail."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-20T17:33:05.220Z
---

`GAME\AZRAEL\R.EXE` (Azrael's Tear, Watcom C++ / DOS-4GW LE, LE header at file `0x290FC`) has a
**"Data Pages Offset" field at LE+0x80 that does not match the file**. It claims `0x3B400`
(→ `0x644FC` absolute), but the real offset of module page 1 is **`0x61A54`**.

Derive it instead of trusting the header:
`DataPagesOff = fileLength - ((NumPages-1) * PageSize + LastPageSize)`
= `0x196B53 - (309*4096 + 255)` = `0x196B53 - 0x1350FF` = **`0x61A54`**.

Verified: with this base, all 217 page-1 fixup records land on 4-byte slots whose pre-fixup file
contents equal the record's target offset exactly (0/217 match at `0x644FC`).

Resulting layout:
- obj1 (code+rodata): base `0x10000`, vsize `0x122973`, module pages 1–291
- obj2 (data+strings): base `0x140000`, vsize `0x57DD0`, module pages 292–310
- `file = DataPagesOff + (modulePage-1)*4096 + offsetInPage`

Fixup convention: all records are src type `0x07` (32-bit offset), target flags `0x00`/`0x10`,
target type 0 (internal) only. The **file already stores the target offset**; the loader writes
`objectBase + targetOffset` over it. So raw byte-scanning for absolute addresses finds nothing —
fixups must be applied before any address-based analysis.

## Fixups vs. patching: never overwrite a fixed-up operand

This has now cost two full attempts (`0x33EB8`, then the mouse divide sites). The
failure is silent and the symptom is *nonsense*, because **the file on disk is
correct and the loaded image is not**:

> NOPing all six bytes of `fdiv qword [0x182D50]` at `0x358E6` gave six `90`s in
> the file. There is a fixup at `0x358E8`, so the loader wrote `50 2D 18 00` back
> — and the image ran two NOPs followed by `push eax` / `sub eax,...` live in the
> mouse handler.

**Diagnostic:** compare the raw file bytes at `Lin2File addr` against
`$IMG.Slice(addr, n)`. They disagree exactly where a fixup landed. The field on a
fixup record is **`Site`**, NOT `Addr` — a scan with the wrong field returns zero
records and the site looks clean. That mistake is what produced the wrong "there
are no fixups here" conclusion at `0x33EB8`, which has 21 of them.

**The idiom that works:** overwrite only the opcode bytes you actually own and
jump *over* the loader's operand. For any 6-byte `op r/m, disp32`:

    EB 04        jmp +4     ; at +0, resumes at +6

The fixup still fires; it just lands in bytes nothing executes. Assert that +6 is
a real instruction boundary (at both mouse sites it is `E8` = `call 0x37A9E`).
Cheaper and safer than relocating the instruction to a cave.

Related: [[azrael-re-tooling]], [[azrael-key-addresses]], [[azrael-hires-blocker]]
