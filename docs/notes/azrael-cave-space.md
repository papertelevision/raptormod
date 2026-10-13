---
name: azrael-cave-space
description: "Where AztMod can put new code: the file-backed caves are full, the LE tables cannot be grown safely, and the answer is 53 KB of zero-filled BSS at 0x133000."
metadata:
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-23T20:50:13.463Z
---

Settled 2026-09-23, after the animation gate and the book rescale left every
file-backed cave within a few bytes of full.

## The two kinds of space, and only one is patchable

obj1 is base `0x10000`, stock vsize `0x122973`, **291 file-backed pages** which
actually cover to `0x133000`. obj2 starts at `0x140000`.

| range | what it is |
|---|---|
| `0x132973..0x133000` | file-backed slack in obj1's LAST page -- the stub cave. Real bytes on disk, so the patcher can write it. 1664 usable. |
| `0x133000..0x140000` | past the last page: **53,248 bytes the loader zero-fills** purely because the object claims to be that big. No file offset, so NOT patchable -- but writable and executable at runtime. |

`$OBJ1_VSIZE = 0x130000` claims all of it. **Verified by running the game**, not
assumed: DOS/4GW honours a vsize well beyond the mapped pages (obj2 already does
the same -- vsize `0x57DD0`, only `0x13000` file-backed). Hard ceiling: obj1 base
+ vsize must not exceed `0x140000` or the objects overlap; the build asserts it.

## The file-backed caves are full

| cave | linear | used / cap |
|---|---|---|
| stub | `0x132980` | 1642 / 1664 |
| clock blob | `0x50F2D` | 397 / 419 |
| box blob | `0x511A0` | 461 / 466 |
| box art blob | `0x51440` | 374 / 419 |

72 spare bytes, non-contiguous. obj1 has **zero** unreferenced filler runs of
96 bytes or more -- checked by decoding the whole image, collecting every branch
target and fixup site, and scanning for padding. The image is dense.

## Two dead ends -- do not re-derive these

**`0x33EB8` IS NOT DEAD.** An older note called it 198 dead bytes with one
caller. It builds the bank boundary table at `0x182514..0x18251A`, and five LIVE
screen blitters read it (`0x34121`, `0x34550`, `0x349B5`, `0x34DF9`, `0x3516A`).
The `lfb-one-bank` trick works precisely BECAUSE that table is computed with a
faked 1 MB window. Overwriting it breaks normal drawing. Its 21 fixups are also
scattered every 1-17 bytes, so there is no usable run even if it were dead.

**The LE tables cannot be grown.** Header at `0x290FC`; every table butts
straight against the next with zero slack:

```
+0x0F4  page map        310*4 = 0x4D8  -> ends +0x5CC
+0x5CC  resident_name   10 bytes
+0x5D6  entry_table      1 byte
+0x5D7  fixup_page_tab  311*4 = 0x4DC  -> ends +0xAB3
+0xAB3  fixup_rec_tab
```

Adding a page needs +4 bytes in BOTH the page map and the fixup page table, which
means shifting everything after them. **And the data-pages offset cannot be
recomputed with confidence**: the header field at +0x80 holds `0x3B400`, which is
not the answer under any base (`+LeBase` = `0x644FC`; the real start is
`0x61A54`, derived from the tail and confirmed against 2,909 textures and 362
patch sites). Since the rule the DOS/4GW loader actually uses is unknown, nothing
already in the file may move. Only appending is safe, and an appended physical
page still needs a page-map entry, which is the thing that cannot grow.

## So: new code goes in the BSS, via an overlay

The BSS cannot be patched, so the bytes have to arrive at runtime -- ship them as
a file and read them into `delta + 0x133000` at startup. The game's own stdio is
right there: `0x396E0` fopen(eax=name, edx=mode) -> eax, `0x397B3`
fread(eax=dest, edx=elemSize, ebx=count, ecx=FILE*), `0x3997D` fclose(eax).
(Signatures read off the RANIM save/load code around `0x1E1CF`.)

## BUILT AND PROVEN (2026-09-23)

`AztOverlayLoad` lives in the clock blob; it uses **DOS INT 21h AH=3Dh/3Fh/3Eh**,
not the game's stdio, because those are 2 bytes a call against a 5-byte rel32
each, and DOS/4GW translates the flat `DS:EDX` itself. It reads a fixed
`0x4000` rather than the exact size -- AH=3Fh returns what it actually read, so
there is no build-order dependency on how big the overlay came out.

Triggered from `AztFrameLimit` (already unconditional, already has esi) by
testing the overlay's own magic dword `'AZTO'` at `0x133000`: BSS starts zeroed,
so zero means not loaded and nothing else can put that value there. No separate
flag, 9 bytes a frame. Failure is silent -- `pushad` restores everything, the
magic stays zero, and the next frame retries.

The bootstrap paid for itself by moving `AztSkipKey`, `AztAnimStep`,
`AztAnimAddEdx` and `AztAnimAddEdxSt` (78 bytes) out of the clock blob into the
overlay. Nothing can press a key or run a room animation before the first frame,
so the ordering is safe. The two movies that play BEFORE the main loop (MINDLOGO,
INTRO) are the 640x480 ones, so nothing needing the overlay runs ahead of it.

**The overlay travels inside the manifest**, not as a second shipped file: its
routines are called from patched sites by absolute address, so a manifest and an
AZTCODE.BIN from different builds would crash with nothing to trace. The
installer writes it out with an `.aztnew` marker so `-Revert` deletes it.
**AZTCODE.BIN is mandatory** -- a missing file is a crash, not a lost feature.

Verified by backdating the file's LastAccessTime six hours (NTFS updates it on an
HOUR granularity, so a smaller offset proves nothing -- see
[[azrael-texture-cache-reserve]]) and watching it jump forward on launch.

Overlay code follows the same esi-delta convention as everything else
([[aztmod-patch-framework]]), because the destination is `delta + 0x133000`, not
a fixed address.

Related: [[azrael-le-image-layout]], [[azrael-lfb-plan]]

## UPDATE 2026-10-02 -- the string pool, and a landmine in the flags

**$ENABLE_FPS_LOG DID NOT GATE THE FPS LOG.** It gated the clock blob's
`lea eax,[esi+0x133009] / call eax` -- the ONLY entry into `AztFrameAll`, which drives
`AztBootTick` (the visor boot animation) and `AztCdPoll`. Turning the fps log off would have
silently deleted the boot sequence with nothing in the build to say so. Now gated on a derived
`$NEED_OVL_FRAME` (FPS_LOG -or CAM_LOG -or SCENE_LOG -or BOOT_SEQ -or CD_AUDIO), computed at
the use site because every flag it reads is defined by line 800 and the site is line ~3450 --
see [[azrael-powershell-null-ordering]]. **Verify after any flag change** by checking the
installed `actor-time` patch still contains `8D 86 09 30 13 00 FF D0`.

There are **nine** logging flags, not the five that are obvious: OOM_TRAP, FPS_LOG, CAM_LOG,
ANI_LOG, TEX_LOG, GEO_LOG, SCENE_LOG, CD_DIAG. They are entangled -- TEX_LOG reads the scene
log's `aztScnMeshP` -- so turning one off can throw `undefined label`. Turn them off together.
`$ENABLE_LOG_IN_PANEL` and `$ENABLE_LOG_BOX_TOGGLE` are the in-game STORY LOG UI, not
diagnostics; leave them on.

### What the sweep actually bought

Diagnostics live in the OVERLAY, not the file caves, so turning them off frees **BSS, not cave
bytes**: overlay 44,938 -> 33,670, free BSS 8,310 -> **19,578**. Only one file patch went away
(`oom-trap-28770`). Do not expect cave relief from this.

### STRING POOL -- BUILT, THEN REVERTED. IT CRASHED THE GAME.

Pooling "opening.mov" at the top of the stub cave and loading it with `mov eax,imm32` cut
cave 3 from 418 to 403 of 419 -- and **crashed the game at that movie**.

**AN ABSOLUTE obj1 ADDRESS IS A POINTER TO NOWHERE.** obj1 is not loaded where it was built;
that is the whole reason `AztDeltas` exists ("esi = obj1 delta ... the difference between where
we actually are and where we were built to be"). The movie player received the pointer as a
filename. The game's own code pushes paths onto the stack for exactly this reason, and so must
AztOpenMovie -- 20 bytes to carry 12 bytes of text, but delta-free.

What misled me: the skip-flag store `mov word [0x182DB0],bx` in the same stub uses an absolute
obj2 address and the build "worked". That is NOT evidence absolute addressing is safe -- obj2
has its own delta (edi) and that store is suspect too; it just writes somewhere harmless
instead of being read as a pointer. **Do not cite one absolute reference as proof for another.**

Rel32 `call`/`jmp` ARE delta-free -- both ends shift together -- which is why every call in the
caves works and only DATA references need the delta.

Budget that killed the correct version: cave 3 allows 45 bytes for AztOpenMovie. Stack pushes
+ absolute flag store = 44 (shipped, works). Pooled string + delta-correct flag store = 55.
Deriving the delta inline is call/pop/sub = 12 bytes, and obj2's is another 13.

`Add-PooledString` is kept and is correct FOR CALLERS THAT HAVE THE DELTA -- address it as
`lea eax,[esi+addr]`, never absolute. Nothing is pooled today. The real fix is to move
AztOpenMovie into the BSS overlay (~19 KB free, AztDeltas already there), which needs the
overlay loaded BEFORE the intro: hook 0x16146, the `call 0x10220` immediately preceding the
only call to the intro sequence at 0x1614B.

## UPDATE 2026-10-11: THE WINDOW IS 256 KB NOW

The 'hard ceiling: obj1 base + vsize must not exceed 0x140000' was a precaution, not a measured limit. DOS/4GW places obj2 one page past obj1's END, so obj1's vsize is now 0x163000 (BSS window 0x133000..0x173000) and obj2 simply loads 0x33000 higher (delta 0x224000). See [[azrael-overlay-read-limit]] for everything that had to follow it. The file-backed CAVES are unchanged: still full.
