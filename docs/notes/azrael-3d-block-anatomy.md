---
name: azrael-3d-block-anatomy
description: "The engine's 3D block at 0x14162..0x1418A dissected: 0x3F0D0 is the CLEAR (callee-pops, ret 4), 0x3F1B0 is the scene pass. Plus the A/B harness that measures the host-offload ceiling."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-04T00:40:45.602Z
---

## The block, and what the two calls really are

`Test-Suppress3D.ps1`'s header comment labels `call 0x3F0D0` as "render". **It is not.**
Disassembled 2026-10-03:

```
00014158  cmp word [0x15257C], 0        <- $g_book; FIXUPS at +3 and +11, do not patch
00014160  jnz 0x1418C                   <- the engine's own 3D skip
00014162  mov eax,[0x152138] / call 0x3ACB0   -> ecx     ; viewport getters
0001416E  mov eax,[0x152138] / xor ebx,ebx / call 0x3ACE0 -> push eax
00014182  call 0x3F0D0                  <- viewport CLEAR
00014187  call 0x3F1B0                  <- the scene pass
0001418C  ... HUD work
```

| | |
|---|---|
| `0x3F0D0` | validates a rect against the viewport (`call 0x33048`, four corner compares, `mov eax,0xA / call 0x32FB0` on failure). **CALLEE-POPS: all exits are `ret 4`**, matching the `push eax` at `0x1417A`. Only **2 callers** |
| `0x3F1B0` | takes no arguments, enumerates into stack locals (`0x45270`), loops `0x5B7F0` per element, then `0x39C14` / `0x5B820`. Plain `ret`. **11 callers**, so gate it per SITE, never wholesale |

**Both call sites are fixup-free** (`Test-FixupsIn 0x14182 5` and `0x14187 5`), which is what
makes them patchable at all — the `cmp` two instructions above carries fixups at +3 and +11.

## Gate the CALLS, never the flag

Holding `0x15257C` (or `0x1525F2`) corrupts the whole screen — orange smear, misplaced HUD —
because the flag has other readers and skipping the block leaves surface state unset. That is
recorded in Build-AztMod's own boot-sequence comment and in
[[azrael-viewport-paint-not-suppress]]. Redirecting the two `E8` rel32 calls to gate stubs
touches nothing else: **rel32 is delta-free**, so the patch is five bytes with no fixup risk.

**`AztClrGate`'s skip path must `ret 4`, not `ret`.** A plain `ret` standing in for a
callee-pops routine leaves esp 4 low and the game dies on the first frame — the `0x34C40`
lesson from [[azrael-status-gauge]]. The build now asserts there is **exactly one** `C2 04 00`
in the whole overlay.

## The A/B harness ($ENABLE_SUP3D_AB)

Measures the ceiling of the host-offload plan ([[azrael-view-injection]]): what the game runs
at with its 3D pass gone. Three phases, 10 s each, cycling: **0** both run, **1** scene pass
off (viewport goes BLACK — the clear still runs), **2** clear off too (viewport FREEZES).

* `AztSupTick` in `AztFrameAll` advances the phase on **elapsed**, never `now+duration`
  ([[azrael-aztnow-wraps]]). Called **after** `AztFpsTick`, or every transition stamps the new
  phase onto a second rendered under the old one.
* Guarded on `aztInjEnable` so it never runs under the visor boot.
* **F2 pins the phase to 0** — a diagnostic that blanks the viewport needs an off switch that
  is not "quit". `aztEnabled` is reached from the overlay via
  `$asm.Labels['aztEnabled']`: the two assemblers do not share labels, but they share obj1,
  so `[esi+aztEnabled]` is the stub's own addressing.

### Tagged FPS samples

`AztFpsTag` packs the conditions into the one word the log writes, so a second can never be
attributed to the wrong cell: **bits 0..11 count, 12..13 render level - 1 (`word [0x14686C]`,
0 means unset and counts as 1), 14..15 phase.** `Read-Perf.ps1` auto-detects it (a count
≥ 0x1000 is impossible) and prints the phase x level table.

**This makes the fill-vs-per-polygon experiment free too**: the render divider (keys 1/2/3/4)
is still live, so one sitting yields frame rate as a function of both variables, in the same
room with the same cache state.

**Two samples must be discarded and both matter:** the second that straddles a phase flip,
and *everything up to the first flip* — the intro and the 16.9 s boot all log as phase 0 /
level 1, the baseline cell the headline divides by, and they render almost free.

**Inlining the tag cost pushed `AFT_out` 161 bytes away and the assembler refused the build.**
Out of line as a `call` it is five bytes in the hot path. The rel8 guard works; trust it.

## THE ANSWER: the 3D pass is 96% of the frame. The offload ceiling is x24. (2026-10-03)

Measured, uncapped, 114 samples, one sitting, level 1:

| phase | mean fps | ms/frame | share of frame |
|---|---|---|---|
| capped, 3D on | 22.2 | — | (cap reference) |
| **uncapped, 3D on** | **21.4** | 46.7 | baseline |
| uncapped, scene pass off | 489.3 | 2.04 | |
| **uncapped, scene + clear off** | **522.2** | 1.91 | |

* **scene pass `0x3F1B0` = 44.7 ms = 95.6%** of the frame
* **viewport clear `0x3F0D0` = 0.13 ms = 0.3%** — negligible
* **everything else = 1.91 ms = 4.1%** (input, script, HUD, audio, movement, collision)

**`x24.4` is the host-offload ceiling**, and in the heavy spot it is better: phase 1 read
13-16 fps there (71 ms/frame, 97.3% rasteriser) against the same ~512 suppressed, so **~36x**.
The win GROWS with scene complexity, which is the right shape — heavy rooms are the
complaint. So the renderer is the whole problem and a host renderer removes essentially all
of it; see [[azrael-view-injection]] (full-frame injection already measured at 1.5%).

**This also settles "resolution is nearly free" by direct measurement** rather than by
inference from two resolution points: the clear is a pure fill of 1.48 Mpx and costs 0.3%.
Fill is not the cost; per-polygon / per-visual work inside the scene pass is.

Caveat stated honestly: `0x3F1B0` is the WHOLE scene pass — transform, clip, setup,
rasterise, texture management, per-visual enumeration. A host renderer removes all of it, and
the camera and transforms it would need are read from the host over the bridge at no guest
cost, so 522 fps is a fair estimate of what the guest alone would sustain.

**Why capped readings sit at 22-23 and never 24:** the limiter spins and exits one clock read
late, so the achieved period is `period + overshoot` (~3-4 ms). A capped sample of 22 does
NOT mean the cap is slack — in the first run it was clamping a 512 fps frame down to 22.

## THE x24 CEILING WAS WRONG: 0x3F1B0 ALSO ADVANCES THE SIMULATION (2026-10-03)

Suppressing the whole scene pass froze the player **solid**: camera moved 0 units and
turned 0 degrees across a 25 s run, against **789 units and 175 degrees** with it left
alone. So the 522 fps measured by suppressing it was *the game with no simulation*, not
the game with no renderer, and **x24 was never achievable**. Correct any note that still
quotes it.

### The scene pass splits three ways, and the split is clean

Gated each internal call separately (`$ENABLE_SCENE_SPLIT`, host-written bitmask
`aztSceneParts`), cap lifted, standing still:

| mask | skips | fps | vs base |
|---|---|---|---|
| 0 | nothing | 22.2 | x1.00 |
| 1 | `0x3F1EA -> 0x5B7F0` once per scene element | 23.9 | **x1.08** |
| 2 | `0x3F202 -> 0x39C14` | 76.9 | x3.47 |
| 4 | `0x3F209 -> 0x5B820` | **383.0** | **x17.27** |
| 7 | all three | 510.3 | x23.02 |

**`0x5B820` carries essentially all the rendering cost on its own.** The per-scene-element
call — the `Frame::Move` shape, the prime suspect for driving simulation — costs 8%.

All three sites are fixup-free and all three targets end in a plain `ret`. **`0x5B820`'s
result is TESTED** (`test al,al` then a branch into `0x32E60`), so its skip path must
return `al = 0`, and because `popad` restores eax the zeroing has to happen *after* the
restore.

**The baseline is 22.2 fps with the cap LIFTED** — the game is not cap-bound at all in
normal play; 22 fps is simply what it manages.

### UNRESOLVED, and do not assume either way

* **Mask 4 alone**: the tool measured 266 units of camera path over 20 s and declared the
  simulation alive, but Josh reported he could only TURN, not walk. The metric sums the
  camera frame's path, and if that frame sits off the pivot then **rotation alone
  translates it** — so the number may be measuring looking around. Needs a metric that
  separates translation from rotation before it can be trusted.
* **Mask 4 + injection**: the host hit its 500 ms handshake timeout every frame (exactly
  2.0 fps) and `aztInjShown` stayed at **0** — AztInjBody never completed a single copy.
  `aztSupDraws` was **also 0**, and that counter increments every frame the gate is NOT
  suppressing, which means **`0x3F1B0` was never called at all**. Neither it nor the
  injection hook at `0x141D2` ran, so the game was not in its normal per-frame path --
  a menu, a movie, or genuinely stuck. Cause unknown.
  `scratchpad\isolate.ps1` steps the flags one at a time to find it; it needs the game up.

## A CAPPED A/B MEASURES THE CAP. The first run was null and it was my design error.

114 clean samples, phases cycling perfectly, and **22 fps in every phase** — 21-23 flat,
whether the scene pass ran or not. That is not "the 3D costs nothing". `AztFrameLimit`
**SPINS** until `aztFramePeriod` elapses (`0x50F38..0x50F4B`), so work removed from the frame
is handed straight back as spin and the loop still delivers its 24 fps ceiling.
`Read-Perf.ps1`'s own header said this all along — *"it measures the CAP, not the machine,
wherever the machine could go faster"* — and I built the experiment without acting on it.

**Any future headroom experiment must lift the cap or it cannot answer anything.**

### The fix: the phase cycle owns the cap

Four phases now, and `AztSupTick` writes `aztFramePeriod` (`0x510A8`, from
`$tAsm.Labels['aztFramePeriod']`, range-checked) on **every** path through the routine —
not at transitions — so the F2 pin and the boot guard cannot leave the game uncapped:

| phase | cap | 3D |
|---|---|---|
| 0 | 24 fps | on — **not a measurement**, exists so the game is navigable |
| 1 | **off** | on — the real baseline |
| 2 | **off** | scene pass off (viewport BLACK) |
| 3 | **off** | scene + clear off (viewport FROZEN) |

Headline = phase 3 ÷ phase 1, both uncapped. Period 0 never spins (`cmp eax,[period] / jb`
can't go below zero). Animation has its own 54,925 µs gate and is unaffected.

**Movement is frame-tied**, so phases 1-3 move the player far too fast — `$MOVE_SCALE` is
calibrated for 24 fps. F2 pins to phase 0 to navigate. **And the count had to be CLAMPED at
4095, not masked**: uncapped logic-only frames can run into the thousands, and
`and ax,0x0FFF` on 4100 yields 4 — a wrap that reads as a catastrophic slowdown.

### Verified before shipping

A synthetic log with planted means decoded back exactly (18/30/34 and 22/34/38, ceilings
x1.89 / x1.73). **Prove a decoder against known answers before the real data exists**, not
after.

Related: [[azrael-perf-measured]], [[azrael-host-guest-bridge]], [[azrael-render-scale]]
