---
name: azrael-perf-measured
description: "MEASURED frame rates via the AZTFPS.LOG counter -- resolution is nearly FREE (1.73x the pixels costs only 8% fps), so fill is NOT the bottleneck. Sustained play is ~22-24 fps and the 48 fps cap was never once reached."
metadata:
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-10-03T18:31:18.913Z
---

Measured 2026-09-24 with the FPS counter in the overlay (see below), one sample
per second, during real play sessions rather than idling at a menu.

| build | gameplay samples | min | max | mean | median | hit the 48 cap |
|---|---|---|---|---|---|---|
| 1280x1024 (view 1280x797) | 66 | 10 | 40 | **22.3** | 22 | **0 of 91** |
| 1024x768 (view 1024x576) | 86 | 13 | 40 | **24.1** | 22 | **0 of 115** |

## THE HEADLINE: fill rate is not the bottleneck

**1.73x the pixels costs only 7.5% of the frame rate.** That reverses the framing in
[[azrael-blit-vs-rasteriser]]: the blit is indeed negligible, but so is per-pixel
fill generally — it can only be ~10-15% of frame time for these two numbers to sit
this close. The dominant cost is emulated CPU work that does NOT scale with screen
area: per-polygon transform / clip / setup, game logic, texture management.

Consequences, all of which cut against the intuitive plan:

* **Resolution is cheap.** 1280x1024 was abandoned for ~2 fps. If the sharpness is
  ever wanted it can come back; it was never the performance problem. What it did
  NOT buy was crispness — 87% of textures are <=256 px, see below.
* **Dropping resolution does not buy headroom for anything else.** There was only
  8% to recover.
* `cpu_cycles_protected = max` already lets Staging use as much as one core
  sustains, and DOSBox emulates the CPU single-threaded, so this is a hard ceiling
  on a 16-core host. There is no cycles dial left to turn.
* Frame rate tracks scene complexity (13 fps in a big room, 40 in a corridor),
  which is the signature of per-polygon cost, not fill.

## The 48 fps cap was fiction, and it made the game WALK SLOWLY

Movement is frame-tied and `$MOVE_SCALE = DESIGN_FPS / $FRAME_CAP_FPS`, so the cap
is a SPEED CALIBRATION, not just a smoothness dial. At a 48 cap and an actual
22 fps the player moved at **46% of the intended speed**. Recalibrated to
`$FRAME_CAP_FPS = 24` (the measured mean; median 22), move-scale x0.3793 -> x0.7586.

**`Set-FrameCap.ps1` changes the PERIOD ONLY** — it cannot fix `$MOVE_SCALE`, which
is baked at build time. A taste change there leaves the speed wrong; change
`$FRAME_CAP_FPS` in Build-AztMod and rebuild so both move together.

Animation is unaffected either way: it is clock-gated at six sites and carries its
remainder, so it holds its rate at any cap ([[azrael-frame-tied-timing]]).

## Texture sizes -- why 1280 did not look sharper

All 2,805 textures across 172 .RES files:

| longest edge | count | share |
|---|---|---|
| 64 | 38 | 1.4% |
| 128 | 505 | 18.0% |
| **256** | **1,908** | **68.0%** |
| 512 | 354 | 12.6% |

87% are <=256 px, so more screen pixels only magnify the same source detail.
**The engine already ships 354 textures at 512**, so a 256->512 uprez stays inside
proven territory. It spends texture cache and memory bandwidth, NOT fill — a
different budget from resolution, and the one behind the big-room crash
([[azrael-texture-cache-reserve]]).

## The counter

`$ENABLE_FPS_LOG` in Build-AztMod. ~100 bytes in the overlay plus 8 in the clock
blob. Writes one 16-bit frame count per second to `GAME\AZRAEL\AZTFPS.LOG` via
INT 21h AH=40h, committed with AH=68h each time (the handle is never closed, so
without the commit a quit loses the whole run).

    $b = [IO.File]::ReadAllBytes('...\GAME\AZRAEL\AZTFPS.LOG')
    0..($b.Count/2 - 1) | ForEach-Object { [BitConverter]::ToUInt16($b, $_*2) }

A file beats drawing on the HUD: far less code than digit conversion plus
DrawString, it cannot corrupt the display, and it yields a time series.

**Hooked via a fixed entry vector.** The overlay is assembled after the clock blob,
so the clock blob cannot name its labels; `+4` is AztOvlInit and **`+9` is now
AztOvlFrame**, both 5-byte jumps, reached by `lea eax,[esi+0x13300N] / call eax`.
The frame hook sits below `AFL_haveOvl`, where the overlay is guaranteed resident
and `ebx` still holds `now`.

**Idling tells you nothing.** Unattended runs gave 95-98 fps stretches — intro
movies and menus render almost free, and the movie path pins to exactly 40. Only
logged real play is worth reading, and the first ~25-30 samples are always the
intro and must be discarded.

## CORRECTION: resolution is NOT "nearly free" at 1600x1200 (2026-10-03)

The 7.5% figure below is real but it was measured on the 1.73x step and **does not
extrapolate**. Clean 109-second run, 1600x1200, STOCK textures, no crash:

| min | max | mean | median | at 24 cap | <15 fps |
|---|---|---|---|---|---|
| 5 | 23 | **17.5** | 18 | 0 of 79 | 18 of 79 (23%) |

Against 24.1 at 1024x768 that is a **27% fall for 2.52x the viewport fill** (1024x576 =
0.59 Mpx -> 1600x928 = 1.48 Mpx) — worse than linear, so do not quote "~8%" for a
resolution change again without measuring the actual step.

**CONFOUND, unresolved:** the 24.1 was measured 2026-09-24, on a build without the boot
sequence, early overlay, view injection or the six clock gates. Some of 24.1 -> 17.5 may
be the mod's own per-frame additions rather than pixels. The two are only separable by
measuring a LOWER resolution on TODAY's build.

**Eliminated as a suspect:** per-frame view injection. `AztInjBody` early-outs on
`aztInjEnable == 0` in three instructions, and the flag is cleared when the boot hands the
viewport back, so the 1.48 MB staging copy does not run during play.

**The free experiment to run FIRST:** the game's own render-resolution divider (keys
1/2/3/4, the surface-creation sites 0x11043/0x11067, still live in the mod and listed in
README). Holding each level ~15 s in a heavy room, with `$ENABLE_FPS_LOG` on, separates
fill cost from per-polygon cost inside a SINGLE run — no rebuild, no art regeneration, no
confound. If the frame rate jumps on 2/3, fill dominates and dropping resolution pays; if
it barely moves, the emulated per-polygon cost dominates and only moving the renderer off
the emulated CPU helps.

If a lower resolution is wanted, **1280x960 is mode 0x17D and 1152x864 is 0x207**, both
4:3 and both confirmed present in DOSBox's table ([[azrael-1600x1200]]); `src\Build-Art.ps1`
regenerates the whole art chain for either in one command. 1280x960 gives view 1280x733
(0.94 Mpx, 0.63x the current fill) and, as a bonus, smaller surfaces mean the reserve can
fall and the 4.46 MB texture cache can grow.

## AZTFPS.LOG TRUNCATES per run, it does not append

Despite the "appends" note elsewhere: the crashed run left 46 samples and the next run
left 109 TOTAL, with a different distribution in the first 46. The DOS create (AH=3Ch)
truncates. So each run is self-contained — but check the byte count against the expected
sample count before assuming which run you are reading.

## 1600x1200 MEASURED (2026-10-03) — and the cap is now proven not to bind

46 samples, 1600x1200 (view 1600x928), with the upscaled textures that then crashed:

| min | max | mean | median | at the 24 cap | under 15 fps |
|---|---|---|---|---|---|
| 7 | 23 | **17.6** | 21 | **0 of 46** | 14 of 46 (30%) |

**0 of 46 reached the cap**, so raising it would have bought exactly nothing — the cap
question is closed by measurement, not argument. Against 24.1 mean at 1024x768 with stock
art this is a real fall, but the run is confounded: it includes the intro and the
cache-thrash approaching the crash (ten samples in the 0-10 bucket). **Re-measure with
stock textures before treating 17.6 as the number for this resolution.**

## Multi-core is STRUCTURALLY impossible — answer it and move on (asked 2026-10-02)

Josh suggested it to raise frame rate. It is not a missing feature or a tuning gap:
DOSBox emulates ONE x86 instruction stream and a serial instruction stream cannot be
split across cores; the game is a single-threaded DOS/4GW binary with no threads to
distribute. No DOSBox fork does multi-threaded CPU emulation. The host is a 16-core
Ryzen AI MAX+ 395 (32 threads) and the conf is already at its stop — **`core = dynamic`
and `cpu_cycles_protected = max`**. 31 threads cannot help, by construction.

## DO NOT RAISE THE FRAME CAP, even with movement decoupled

This was designed in full and then dropped, so the design is recorded rather than the
work repeated.

**The attraction:** corridors measure 40 fps and are being spin-waited down to 24, so
the cap looks like free frame rate sitting on the table.

**Why it is not:** the cap is load-bearing for the WHOLE frame-tied class, not just
movement — Build-AztMod's own note says the game is "frame-tied in MANY places" and
capping the loop "fixes the whole class at once", and the first room ran at hyperspeed
before the cap existed. Fixing movement alone and raising the cap re-speeds every other
frame-tied system, which is a regression for an unknown gain.

**The movement half is easy, if it is ever wanted:** the per-frame step is only TWO
floats in obj2 — `[0x141800]` = 16.0 (run, 2 read sites) and `[0x1417FC]` = 8.0 (walk /
wall slide, 8 sites) — so no movement code needs touching at all. Rewrite both from
`AztFrameAll` (ebx = now, esi/edi already hold the deltas) each frame:

* `elapsed = now - last`, unsigned, so the 2^32-us wrap costs one frame
* **no runtime float math and no FPU** — index a build-time table of 256 precomputed
  floats by `elapsed >> 9` (512-us buckets, ~2% speed granularity). Avoids any risk of
  x87 stack overflow at the hook, which would write an indefinite into the step and
  teleport the player. `mov ecx,[esi+eax*4+d32]` is `8B 8C 86 <d32>`.
* **clamp `elapsed` to 2 design frames (109,850 us, idx 214)** or a hitch after a room
  load becomes one enormous step through a wall. Costs correct speed below ~9 fps,
  which is below any measured scene (min 13).
* Arithmetic check: step = `16.0 * elapsed / 54925` gives 12.1377 at 24 fps — EXACTLY
  today's static patched value — and a constant 291.3 units/s at 13, 24 and 40 fps.

## AN EMPTY AZTFPS.LOG PROVES NOTHING (2026-10-03)

A run came back with the file **present and 0 bytes**. Its existence does *not* mean the
measurement ran: `AztFpsInit` creates it, and `AztFpsInit` is reached from the **early
overlay hook at 0x16146** ([[azrael-early-overlay]]), not from the per-frame chain. So an
empty log is equally consistent with two faults that need opposite fixes — the frame chain
never running, or it running with every DOS write failing.

Verified structurally correct in the INSTALLED binary before changing anything, and this is
the chain to re-check if it happens again:

```
0x1329EB AztFrameHook -> 0x50F2D AztFrameLimit (clock blob, one caller)
0x50F97  cmp dword [esi+0x133000],0   ; 'AZTO' magic; load if absent
0x50FA5  lea eax,[esi+0x133009] / call eax   ; AztOvlFrame, EVERY frame, ebx = now
0x133009 -> 0x133029 AztFrameAll -> 0x13321C AztFpsTick
0x133004 AztOvlInit -> 0x133013 AztInitAll -> AztFpsInit, CamInit, CdInit, BootInit
```

**DIAGNOSED by asking what was on screen, which settled it in one message.** Josh confirmed
the boot animation played, movement speed was normal and the A/B viewport cycling happened —
all three require `AztFrameAll`, so `AztFpsTick` was certainly being entered 20+ times a
second. That leaves only the file I/O. **Do not debug an empty log by reading code; ask what
the screen did, because the visible features share the chain.**

### THE LONG-LIVED HANDLE WAS THE BUG. `AztFpsWrite` now opens/appends/writes/CLOSES per sample.

The old design created the file before the intro, held one handle for the entire session,
wrote 2 bytes a second and never closed it, relying on INT 21h **AH=68h (commit)** to get
the bytes to disk. A handle that old has several ways to die quietly — the game opens
hundreds of files of its own — and an unclosed buffered write depends on AH=68h doing
anything at all on this host. Neither was ever checked.

Four INT 21h calls **once a second** (AH=3Dh open, AH=42h seek-to-end, AH=40h write,
AH=3Eh close) removes the whole class: a close is the one operation guaranteed to flush, and
a handle that does not outlive the call cannot go stale. Against a ~40 ms frame budget the
cost is unmeasurable. **Open AH=3Dh and SEEK, never create** — a create truncates and the
log would hold only its last second; `AztFpsInit` does the one truncation at startup and
closes immediately. Counters `aztFpsWrites` / `aztFpsOpens` / `aztFpsFails`, and `pop` does
not touch the flags, which is what lets the handle be restored between the write and its CF
test.

**A first-call marker** also remains: `AztFpsTick` writes `0xFFFF` on first entry, so the log
should START `FF FF`. Phase 3 is impossible, so it cannot be mistaken for a sample and
Read-Perf names it. The three outcomes are now all distinguishable: 0 bytes = chain dead,
2 bytes = every open failing, `FF FF` + samples = working.

## The overlay symbol map now EXISTS: `AztMod.overlay.sym`

353 symbols, written beside the manifest on every build. The bridge notes' complaint that
"the manifest carries only 8 symbols, not the overlay label map" is fixed — stop hunting byte
signatures to find overlay code. Sorted by linear address; add the obj1 delta for runtime.

## Measuring: `tools\Read-Perf.ps1`, and re-apply the .BAT redirect AFTER installing

`$ENABLE_FPS_LOG = $true` writes AZTFPS.LOG (one uint16 per second). `Read-Perf.ps1`
decodes it with a histogram, discards the first 30 samples as intro, and counts how many
samples sit AT the cap — which is the number that says whether the cap binds at all.

It also parses the game's OWN startup report out of AZTOUT.TXT
(`MAXIMIUM MEMORY BLOCK FOUND` / `TEXTURE CACHE ALLOCATION`) for the real split rather
than our arithmetic. That needs `r %1 %2 %3 > AZTOUT.TXT 2> AZERR.TXT` in
`GAME\AZRAEL\AZRAEL.BAT`, and **Apply-AztMod REWRITES that file on every install**, so
the redirect has to go back afterwards every time.

**A build with the FPS counter on takes noticeably longer to build and install** (~10 min
each here) — not a hang; let it finish.

## Open suspect: the texture upscale may COST frames

[[azrael-texture-remaster-verdict]]'s budgeted upscale pushed rooms from 2.84 MB to
3.41 MB against a 4.51 MB cache. Texture management is named above as part of the
dominant cost, and a cache that evicts makes the game re-run its Huffman decoder. So the
upscale spends the same budget the bottleneck is made of. It is one command to revert
(`Upscale-Budgeted.ps1 -Revert`), so A/B it rather than reasoning about it. Also worth
testing: the 24 MB reserve was set by "err high" guesswork, and walking it back would
give the cache room and might buy frames.

Related: [[azrael-resolution-asserts]], [[azrael-dosbox-staging]], [[azrael-lfb-plan]],
[[azrael-1600x1200]], [[azrael-frame-tied-timing]]
