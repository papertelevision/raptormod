---
name: azrael-render-scale
description: "FOUND: the engine has a stock render-scale divisor (SetRenderLevel 0x10FEC) that divides OUR PATCHED viewport on both axes - level 2 is a quarter of the fill. Also why the 1-2-1 key trick improves frame rate."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-03T15:22:19.446Z
---

Found 2026-10-03, chasing Josh's observation that *"switching from 1,2,1 does seem to
improve frame rate"* while the 1/2/3/4 resolution keys otherwise "haven't worked".
Both halves of that turned out to be true and they have different causes.

## `SetRenderLevel(eax = level)` at **0x10FEC** — a real render-scale, latent

```
0x10FF7  cmp word [0x15257C], 0      ; the 3D-suppress flag -> bail
0x11005  cmp ax, word [0x14686C]     ; CURRENT level; equal -> bail (unless [0x152AE8])
0x1102A  call 0x3AC10  x2            ; destroy surfaces [0x152138] and [0x152134]
0x1103E  call 0x37FC8                ; clear 0x152150
0x11043  mov eax, 0x11A   (282)      ; <- AztMod patches this to $VIEW_H
0x1104C  mov bx, si                  ; the DIVISOR
0x11052  idiv ebx                    ; height / level
0x11067  mov eax, 0x228   (552)      ; <- AztMod patches this to $VIEW_W
0x11071  idiv ebx                    ; width / level
0x1108C  call 0x28157                ; create the surface at the divided size
```

**It divides the PATCHED numbers**, so at 1600x928 level 2 creates an 800x464 surface —
**a quarter of the rasteriser fill** — with the HUD, text and panel still native. That is
exactly the "render scale" dial every modern game has, sitting unused in a 1996 engine,
and it is the single biggest frame-rate lever found so far.

`word [0x14686C]` is the current level. Nine callers of 0x10FEC: 0x14132, 0x15424,
0x17593, 0x111A1, 0x13158, 0x1312F, 0x136F8, 0x13380, 0x16B11.

### THE ENGINE ALREADY IMPLEMENTS THE WHOLE PIPELINE (traced 2026-10-03)

Nothing needs writing. Render small -> expand -> blit full is all there:

| piece | where |
|---|---|
| divided render target | surface header **0x152164** (+0 w, +2 h), sized to (W/level)x(H/level) by `0x37B04` at 0x1111F |
| full-size screen surface | **0x152150** — only `Clear()`ed by the rebuild (0x1103E), never resized |
| the EXPAND loop | 0x142DB..0x14330: reads the divided width, `imul` by `word [0x14686C]` (the level) for the destination row step, steps the source by the scanline stride at **0x14304** |
| three row scalers, by level | **0x1E61C / 0x1E62C / 0x1E63C** — thin Watcom wrappers (push 4 args) onto **0x1E674 / 0x1E6EA / 0x1E814**. They take width and height as ARGUMENTS, so no baked-in resolution |
| the screen blit | `0x33F80` is **1:1** — at 0x33FDF it builds the destination rect from the SOURCE surface's own w/h (`add ax,[esi]` / `dec`). No stretch, and none needed, because it is handed the already-expanded full-size surface |

`0x14304`'s stock `sub esi, 0x228` IS already covered, as `view-stride-14304`. (Careful:
`tools\load.ps1` disassembles the PRISTINE Steam R.EXE, so stock immediates there are not
evidence that AztMod missed them — check the manifest before concluding a site is unpatched.)

### `$RENDER_SCALE` — built, awaiting a play test

0 = follow the player's own level (rebuild only). 1..4 = force that level on every room
change. **Forcing still needs the round trip**: `SetRenderLevel` early-outs when the
request matches `word [0x14686C]`, so going straight to the target would do nothing from
the second room onwards and lose the restorative rebuild. So it bounces off the other
level first: `mov eax,1 / call 0x10FEC / mov eax,2 / call 0x10FEC`.

At 1600x1200 level 2 draws the 3D at **800x464** and the engine expands it to 1600x928 —
**25% of the rasteriser fill with the HUD and panel still native**, since only the 3D
target is divided.

Why a flag instead of more reading: every piece above looks correct on paper, yet the
1/2/3/4 keys reportedly never worked under the mod. One look at the screen prices it.

### TESTED AT LEVEL 2: THE EXPANDER IS BROKEN AT 1600x1200. `$RENDER_SCALE` back to 0.

Two symptoms, ONE fault:

* the 3D viewport came up **blank**; pressing 1 (back to level 1) showed the game
  correctly AND with the good frame rate
* the **boot animation lost its readouts** and kept only the background

**They are the same bug, and the startup allocation at 0x10E2C is why:**

```
mov eax, 0x26010      ; = $VIEW_W*$VIEW_H, patched
call 0x32CE0          ; ONE pixel buffer, allocated once
mov [0x152154], eax   ; the live viewport
mov [0x1521BC], eax   ; where levels >= 2 expand TO
mov [0x162E2C], eax
mov [0x163A34], eax   ; ...and what AztViewInject writes INTO
```

**`[0x163A34]` is that same buffer.** So the destination of the expansion and the
destination of our boot injection are one and the same, and at level 2 the expander
overwrites the boot art. The missing readouts were a CONSEQUENCE of the broken
expansion, not an independent bug — worth remembering, because it looked like two.

So the destination is correct and full-size, and the fault is further in: the dispatch
around **0x14230..0x1428D** that selects a scaler, or the workers **0x1E674 / 0x1E6EA /
0x1E814**. That is where to resume.

### ALSO FIXED: the room tick must not run while the boot owns the viewport

The first room's frames exist long before the 16.9 s boot animation ends, so the room
signature changes DURING the boot and `AztRoomTick` was tearing the 3D surfaces down and
rebuilding them underneath the animation. `AztRoomTick` now early-outs on
`aztInjEnable != 0` — two instructions, and it removes the whole interaction. Keep this
even if render scaling is abandoned.

### DONE: the small interface text was the STOCK log font — see [[azrael-font-format]]

Not a missing `Hi()` on a coordinate, as guessed: `$LOG_FONT_STOCK` was `$true`, so the
mod shipped no font replacement at all and the log ran on Mindscape's 1380x12 sheet while
the panel scaled 2.5x. Now generated at 24 rows.

## THE 1-2-1 GAIN IS DEVICE STATE, **NOT** THE TEXTURE CACHE (settled 2026-10-03)

Tested, not reasoned: the room-change defragment below was built on the cache theory,
Josh played it, **the frame rate did not change and the 1-2-1 keystrokes still improved
it.** So the cache was never the mechanism. Do not re-run that experiment.

Diffing the two device-configuration paths call for call finds the difference:

| | calls, in order |
|---|---|
| startup `0x10EF0..0x10FBE` | `0x3A460(0)` `0x3A5B0(1)` `0x3A5F0(0)` CreateViewport `SetBack(30000.0)` `SetFront(0.8)` `0x3A930(0, ecx=0x163610)` **`0x3AB70(0)`** `0x3ABA0(1)` |
| rebuild `0x11043..0x1117B` | `0x3A460(0)` `0x3A5F0(0)` `0x3A5B0(1, ecx=0x163610)` `0x3ABA0(1)` `0x3A930(0)` CreateViewport `SetBack` `SetFront` `0x37B04` viewport swap |

* **`0x3AB70` is `mov dword [device+0x54], ecx` and ONLY the startup path calls it.**
  A rebuilt device therefore keeps its constructor default for `[device+0x54]`, while
  the startup device has it forced to 0 — and the rebuilt state is the faster one.
  **NOPing the `call 0x3AB70` at 0x10FA5 is the likely one-dword equivalent** and is the
  obvious follow-up to test.
* `ecx = 0x163610` (a ramp/palette table) is handed to a DIFFERENT setter in each path.
* `0x3A840` = SetBack (30000.0), `0x3A8A0` = SetFront (0.8) — identical in both, so the
  clip planes are NOT the difference.
* `0x3ABA0` validates its argument is a power of two in 0..0x100, so it is a
  SetShades-style call; both paths pass 1, so it is not the difference either (the
  differing `ebx` at each site is dead — the function overwrites ebx immediately).

### THE GAIN IS RESTORATIVE, NOT CONFIGURATIONAL — the second lesson

`AztRelevelKick` was first fired ONCE from `ABT_finish`, at boot hand-over. Josh tested
it: **pressing 1-2-1 by hand still gave a further improvement on top.** And the level
global `[0x14686C]` **ships as 1**, so the kick was not bailing out on a zero — it ran
and simply did not help.

So the device state *degrades as you play* and the rebuild restores it. Firing at boot is
too early: nothing has degraded, so there is nothing to restore. That also retro-explains
the defragment doing nothing — **both were aimed at a configuration problem that does not
exist.** `[device+0x54]` may still be a real difference, but it is not the mechanism.

**Do not test any "fix this once at startup" idea against this symptom again.** The
trigger has to repeat.

### BUILT: `AztRelevelKick`, fired on ROOM CHANGE

`$ENABLE_RELEVEL_KICK`. Overlay **0x133102**, called from `AztRoomTick` at 0x1330E9 —
the same room-change hook as the defragment (which runs first, because compaction moves
texture pixels and rewrites owner pointers). `AztDefragTick` was renamed `AztRoomTick`
and is now emitted when EITHER flag is on.

Reads the CURRENT level from `word [0x14686C]` and toggles to the other of {1,2} and
back, so it ends on whatever level is in force and cannot strand the player at a
resolution they did not pick. `SetRenderLevel` preserves ebx (and esi/edi), so ebx
carries the level to return to across the first call.

**Checked leak-safe BEFORE enabling it per room**, which matters at 87 rooms: the device
creator `0x28157` guards the big allocation — `cmp dword [0x147466], 0 / jnz` skips the
z-buffer malloc when it already exists, so the 2,969,600-byte buffer is allocated ONCE
however many rebuilds happen, and the 60-byte descriptor at `[0x14745C]` is freed via
`0x32DF9` before reallocation.

If the frame rate still sags during a LONG stay in one big room, a periodic kick is the
next step — but it would hitch mid-play, so room change is the default.

## Why 1 -> 2 -> 1 helps and 1 -> 1 does nothing

`0x11005` early-outs when the requested level EQUALS the current one. So pressing 1 at
level 1 is a no-op, while 1->2->1 forces **two full destroy-and-recreate cycles** of the
3D surfaces. The frame-rate gain is therefore NOT from resolution — it is from resetting
allocator / device state. Which is evidence for the decay below.

## The texture cache is a FIRST-FIT LINKED LIST, and it fragments

`GetTextureMemory` is **0x1BF9C** (the name string is at obj2 0x141563; the diagnostic
strings live at 0x1414FF / 0x14151A / 0x141527 / 0x141532 and are referenced from
0x1C168 / 0x1C1B1 / 0x1C1B6). Node layout, walked from `[mgr+0x1C0]`:

| off | meaning |
|---|---|
| +0x00 | block address (the pixels) |
| +0x04 | block size |
| +0x08 | owner, **0 = free** |
| +0x0C | next |

The requesting object gets the block written to `[obj+0x1C]`. Allocation is a plain
first-fit walk that splits the remainder (`call 0x1BF52`).

On failure it does **not** just give up: `0x1C223` **coalesces the free list** (walks it,
sums free blocks, merges adjacent ones, freeing the spare nodes via `0x32DF9`), then
`0x1C383` picks a victim and `0x1C4B5` evicts it, then retries. `[mgr+0x1BC]` is the other
list head. A conditional `call 0x1CABF` runs at entry when `[0x162B88]` is set.

**So the crash was FRAGMENTATION, not simple capacity** — it failed a 262,144 request with
248,832 free *after* coalescing and evicting. 512x512 textures are the worst possible input
for a first-fit arena of 4.46 MB, which is a second independent reason the upscale in
[[azrael-texture-remaster-verdict]] cannot work here.

## BUILT 2026-10-03: `AztDefragTick`, defrag on room change

`$ENABLE_TEX_DEFRAG` in Build-AztMod. `AztDefragTick` lives in the overlay at
**0x13306C** (vars: `aztDefragSig` 0x1330F1, `aztDefragSeen` 0x1330F5,
`aztDefragCount` 0x1330F9 — the count is readable over the bridge to prove it fired).
Called from `AztFrameAll`, +152 bytes of overlay.

It reuses `AztSceneLog`'s room signature VERBATIM rather than inventing one — root
frame's **LAST** child (`[root+0x40]`, because room frames are appended and the FIRST
child is the never-changing movement frame) XORed with the music cue `[0x152AD0]`,
since the allocator can hand back a reused pointer for a different room. Then
`mov eax,[edi+0x162B74]` (IDataManager) and `call 0x1C223`.

The first room is deliberately skipped — nothing has been loaded and freed yet.

Verified in the emitted bytes before installing: all three rel32 calls resolve to
0x42410 / 0x39E50 / 0x1C223, exactly ONE call to the defragmenter, and all three obj2
reads are the intended globals. Worth repeating that check for any new overlay routine
that calls into the engine.

**Residual risk:** the defragmenter memmoves texture pixels and rewrites owner pointers,
so if it ever ran while the renderer held a raw texture pointer it would corrupt. It is
called from the frame limiter (a frame boundary) and only on a room change, which is when
the engine itself is loading textures. **If texture corruption appears right after a room
transition, this is the first thing to switch off.**

## Two things worth building out of this

1. **A render-scale option** (big): fix/verify the upscale path and expose level 2, or a
   fractional scale. 3D soft, UI sharp, up to 4x less fill.
2. **A periodic defragment** (cheap and surgical): call `0x1C223` on room change — it is
   far cheaper than the device rebuild Josh is doing by hand with 1-2-1, and it attacks
   BOTH the frame-rate decay and the fragmentation crash. It takes the manager in `eax`
   (the allocator receives it in `edi` from its caller).

See [[azrael-texture-cache-reserve]], [[azrael-perf-measured]], [[azrael-1600x1200]].
