---
name: azrael-texture-cache-reserve
description: "The big-room crash is the texture cache eating the heap — it takes (largest block - 4.5 MB) at startup, which is why raising memsize never helped. Also: the game prints its own OOM diagnostics."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-10-03T05:30:47.815Z
---

**THE BIG-ROOM FREEZE WAS OUT OF MEMORY, AND memsize CANNOT FIX IT.** Solved
2026-09-21 after several wrong theories; do not re-derive.

At start-up `0x1BE79` finds the largest free block and gives nearly all of it to
the texture cache, keeping a FIXED reserve back for everything else:

```
0x1BE87  cmp esi, 0x400000    ; under 4 MB -> fatal "IDataManager"
0x1BEA6  cmp esi, 0x800000    ; 8 MB or less -> small mode, 1 MB cache
0x1BEC0  sub esi, 0x480000    ; else the cache is (block - 4.5 MB)
```

With memsize=32 that reads `block 29,891,584 - 4,718,592 = cache 25,172,992`, so
the WHOLE REST OF THE GAME lives in 4.5 MB. Ample at 640x480; not at 800x600,
where the z-buffer went 311,328 -> 704,000, the view framebuffer 155,664 ->
352,000 and every full-screen surface 307,200 -> 480,000.

**Why memsize is the wrong dial:** a larger pool means a larger largest-block,
the cache grows to swallow it, and the leftover stays 4.5 MB. That is exactly why
the fault address tracked memsize (0x1000000 at 16 MB, 0x2000000 at 32 MB) and
looked like a buffer overrun at the pool end. It was not.

AztMod patches BOTH immediates (`tex-reserve-1BEC0`, `tex-minbig-1BEA6`). They must
move together: the threshold test GATES the `sub`, so a reserve above it underflows
to a ~4 GB request. A smaller cache only costs texture re-uploads; it cannot fail.

**RAISED 2026-09-28 to 20 MB reserve / 24 MB threshold at 1024x768** (was 14/18), to
make room for full-screen movies and up-rezzed art. Split at a 29.9 MB largest block:
**reserve 20 MB, cache 8.5 MB**. A full-screen movie alone costs 2.37 MB (two
786,432-byte surfaces plus the 794,624-byte frame buffer — see [[azrael-mov-format]]),
the z-buffer is 1.57 MB and every full-screen surface 786,432.

**THIS IS THE ONLY DIAL THAT GIVES HEADROOM**, and memsize is pinned at 32 anyway:
the config records that 64 MB exits after ~17 s because DOS/4GW misbehaves with very
large pools. If big rooms start thrashing, the reserve is the number to walk back.

## The freeze-with-digital-noise was a use-after-free, downstream of this

`0x32C40` (98 callers) is the allocator. On malloc failure it falls back to
`0x2876C`, which **purges and retries** — `0x1BBA8` frees `[0x162B7C]` and
`[0x162B84]`, and those are the texture cache's own companion buffers, allocated
right beside it at `0x1BF02`/`0x1BF15`. The renderer keeps using them: garbage
blits (diagonal lines where the compass was), then a wild pointer, then the
freeze. Only if the RETRY also fails does `0x287A3` report.

## The game prints its own diagnostics — use them

`0x334A0` is the fatal reporter. It calls `0x102B0` FIRST, which shuts video and
sound down, so the message lands on a clean text screen:

```
MAXIMIUM MEMORY BLOCK FOUND: 29891584
TEXTURE CACHE ALLOCATION: 25172992
RAPTOR ERROR in FreeMemory
No memory available.
Failed to allocate 16 bytes
```

**Capture it by redirecting the game, not DOSBox**: edit `GAME\AZRAEL\AZRAEL.BAT`
to `r %1 %2 %3 > AZTOUT.TXT 2> AZERR.TXT` and read the files afterwards. DOSBox
Staging's own log is not the place to look (`stderr verbosity: 0`, and the
debugger build takes the console), and the installer REWRITES AZRAEL.BAT on every
`-Install`, so re-apply it after.

`$ENABLE_OOM_TRAP` in Build-AztMod makes the FIRST failure report instead of
purging — 7 bytes at 0x28770, jumping to 0x287A3. Stack-safe because 0x2876C's
four pushes are popped by the tail at 0x287B6. It turns a corrupting freeze into
a clean message; decide before release whether to ship it.

## THE CACHE ACCUMULATES ACROSS ROOMS AND HARD-FAILS. It does not evict. (2026-10-03)

**This corrects two wrong beliefs that were acted on, so read it before sizing anything.**

Measured from the game's own report at 1600x1200, captured via the AZRAEL.BAT redirect:

```
MAXIMIUM MEMORY BLOCK FOUND: 29838336      <- 28.46 MB, not the 29,891,584 assumed
TEXTURE CACHE ALLOCATION: 4672512          <- 4.46 MB  (= block - 24 MB reserve)
CURRENTLY IN CACHE...   [52 textures listed]
TOTAL: 4423680
RAPTOR ERROR in GetTextureMemory
Not enough space in texture cache for 262144 bytes.      <- over by 13,312 bytes
```

1. **"A smaller cache only costs texture re-uploads; it cannot fail" is WRONG.** It is a
   fixed arena that fills and then raises a FATAL error. There is no eviction of textures
   (the `0x2876C` purge frees the companion buffers, not the cache contents).
2. **It is NOT per-room.** The 52-entry dump held `mine*`, `pinc*`, `all2cori`,
   `or_tunn3`, `wel_pip2`, `r62r5/r62r7` AND 1 MB of LURKA (`l_bod`, `l_head`, `l_legs`,
   `mhed2mmz` at 262,144 each) — several rooms plus a character, simultaneously. So a
   per-room budget is the wrong model; the real limit is everything visited in a region.

**Consequence for up-rezzing: it is fatal, not merely slow.** The budgeted 256->512
upscale in [[azrael-texture-remaster-verdict]] crashed the game in a mine room by 13 KB,
because every 512x512 record costs 262,144 bytes and the arena fills ~4x faster. Reverted.

**Consequence for resolution: going to 1600x1200 HALVED the cache** (reserve 20 -> 24 MB
took it 8.9 -> 4.46 MB), so it is tighter than it has ever been while the heaviest single
room is 2.84 MB. Stock art fits, but the margin for a texture-heavy region is thin — if a
crash ever recurs with stock art, walking the reserve back (22 MB gives 6.6 MB of cache)
is the dial, and `$ENABLE_OOM_TRAP` should go on first so a reserve shortfall reports
cleanly instead of becoming the use-after-free freeze.

**Always capture it.** `tools\Read-Perf.ps1` parses the block/cache/TOTAL and the failing
request size automatically. **The report comes out on STDERR** — AZERR.TXT — not stdout;
AZTOUT.TXT was never even created.

Related: [[azrael-dosbox-runtime]], [[azrael-key-addresses]], [[azrael-1600x1200]],
[[azrael-perf-measured]]
