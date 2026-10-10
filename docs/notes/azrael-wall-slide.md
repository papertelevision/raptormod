---
name: azrael-wall-slide
description: "How Azrael's movement integrator blocks, and how AztMod turns a dead stop into a wall slide by retrying the step."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-19T18:25:48.716Z
---

Stock behaviour on a blocked move: nudge the player's facing by +/-10 and abandon
the step. Six sites, all the same shape — an 8-byte
`sub|add word [0x162DF8], 0xA` (fixup at +3, do not overwrite) followed by a
5-byte `jmp 0x1DE08` (`E9 rel32`, no fixup, safe to redirect). `no-wall-turn`
zeroes the rotation immediate; on its own that just leaves a dead stop.

**The movement path** (function `0x1CF64`, math at `0x1D747`):

```
local[esp+0x0C] += dirX * speed      ; dirX = [0x147200]
local[esp+0x14] += dirZ * speed      ; dirZ = [0x147208]
                                      ; speed at [0x141800]
```
then collision-tests via `0x11E68` / `0x10180` / `0x10160`.

Three facts make a retry possible:
1. **esp is constant** through the function — prologue is `mov ebp,esp` /
   `sub esp,0x104` / `and esp,-8`, and every callee in the path is stdcall
   (`0x11E68` ret 0xC, `0x10180` ret 0x18, `0x10160` ret 0xC, `0x3EC20` ret 0xC).
   So stubs reach the locals at fixed `[esp+disp8]`.
2. The two position locals are updated **in place**, so a retry must restore
   them first. `0x1D75B` (`fadd dword [esp+0x14]` + `fxch`, 6 bytes, fixup-free)
   is the last point where BOTH still hold the pre-move value.
3. The **wall normal** is sitting in `0x162DD4` as three floats (X,Y,Z) — it is
   what the stock code feeds the cross product that picks the rotation sign
   (`dirZ*n.X - dirX*n.Z`, at `0x1D85A`).

**AztMod's implementation** (`slide-save-1D75B`, `slide-exit-1D881`,
`slide-exit-1DC39`): save the pre-move position, and on a block restore it, zero
whichever movement component the wall most opposes, and jump back to `0x1D747`
to redo the step. One retry per frame, guarded by `aztSlideDone` which
`AztFrameHook` clears — deliberately *before* its F2 check, since the slide
patches are unconditional and a stuck flag would kill sliding permanently.

## The slide vector must be a projection, not an axis drop

v0.11.3 zeroed whichever of `dirX`/`dirZ` the wall most opposed. That only works
on walls that run along a world axis; on an angled wall it shoves you along X or
Z, still into the wall, and you stick. Azrael has plenty of angled walls.

v0.11.4 projects instead: `d = v·n`, `v' = v - n*d` (2D, Y flattened — a floor
slide). Do **not** renormalise `v'`; losing speed as you turn into the wall is
the behaviour you want.

`n` must be unit length, and `0x162DD4` is **not** normalised — the stock code
always copies it and calls `0x441A8` first. Do the same: copy X and Z into a
3-contiguous-float cave buffer, force Y to 0, pass the pointer in `eax`.
`0x441A8` normalises in place, returns the pointer in `eax`, clobbers only
`eax` (it and `0x441E4` save edx/ebx and never touch esi/edi), and guards the
zero vector by yielding `(1,0,0)` instead of a NaN.

Still **two attempts**, because normal-vs-tangent is still unproven — but the
two readings are complements sharing one dot product, so it costs almost
nothing: attempt 1 is `v - n*d` (n as normal), attempt 2 is `n*d` (n as
tangent). Two tries then stop, which also handles inside corners.

The x87 stack is **empty** at all four exits: each ends
`fsubp / fldz / fcompp / fnstsw / sahf`, which nets to zero. `D9 EE` is FLDZ,
not FCHS — misreading that makes the depth look impossible.

Clobbering `dirX`/`dirZ` needs no cleanup: `0x1D429..0x1D43B` rebuilds all three
direction components from the camera angles at the top of every frame.

## The map of exits — get this wrong and nothing slides

There are **two forward paths**, chosen at `0x1D733`/`0x1D741`, differing only in
speed constant. **Each runs two collision tests**, and each test has its own
wall-normal block and its own private exit:

| path | head | speed | save | `0x10160` fails | `0x10180` fails |
|---|---|---|---|---|---|
| A | `0x1D747` | `[0x141800]` | `0x1D75B` | `jae 0x1D873` → `0x1D881` | `jae 0x1D8E8` → `0x1D8F6` |
| B | `0x1D8FB` | `[0x1417FC]` | `0x1D90F` | `jae 0x1DA07` → `0x1DA15` | `jae 0x1DA8E` → `0x1DA9C` |

v0.11.1 and v0.11.2 paired `0x1D881` with path A and `0x1D8F6` with path B.
**Both are path A.** Path B — the one ordinary movement falls into — had no hooks
at all, which is why no version before v0.11.3 produced any sliding. All four
private exits must be hooked.

Save offset is `head + 0x14` for **both** paths, so one stub serves both: it
derives its retry target from its own return address (`ret - 0x19`) and returns
through `jmp eax`. Both use the same locals, `[esp+0x0C]` X and `[esp+0x14]` Z
(Y at `+0x10`); a *second* copy of the pre-move position lives at `[esp+0x6C]`
and is the ray origin the segment test uses — the retry must not disturb it.

**`0x11E68` is NOT a wall test.** It touches `0x152AD4` and `0x1523E2`, the
object-scan readout — it rejects a step that runs into an interactive *object*,
and computes no wall normal. v0.11.2 hooked its `jnz 0x1DE08` at `0x1D78C` and
`0x1D940` as if it were a wall; that only made the slide retry against a stale
`0x162DD4`. Leave both stock.

Test polarity across the whole function: `0x11E68` nonzero = reject,
`0x10180` **zero** = blocked, `0x10160` nonzero = blocked.

The four movement blocks (forward `0x1D747`/`0x1D8FB`, backward `0x1DAA1`,
strafe `0x1DC3E` and `0x1DD10`) are **priority-ordered, not additive** — every one
ends `jmp 0x1DE08`, so only the first eligible one runs per frame.

## Which exits are safe to redirect — this bit bit me

Each collision test has two exits: a **private** `-10` site reached by
fall-through, and a **shared** `+10` site at `0x1DC31` that FOUR tests jump to
(`0x1D873`, `0x1D8E8`, `0x1DA07`, `0x1DA8E`) plus a fifth falling in from
`0x1DC2B`.

v0.11.0 redirected the shared site and it was a bad bug: three unrelated movement
paths ended up restoring path A's stack slots and resuming path A's code — the
player could walk through walls and get teleported down hallways. **Only the
private exits are safe.**

To still catch both sides of a wall, each hooked path's `jae 0x1DC31` is
retargeted to the very next instruction so both branches fall into that path's
own private exit. Nothing is lost — `no-wall-turn` has already zeroed both
rotation immediates, so the branches are behaviourally identical.

Left completely stock: the backward and strafe blocks' own exits (`0x1DBD3`,
`0x1DB02`, `0x1DC9F`, `0x1DD71` …) and the shared `0x1DC39`.

**Cave budget.** The hole is `0x132980..0x132FFF`, 1664 bytes, and the limit is
not arbitrary: `0x133000` is where obj1's file-backed pages end
(`file = 0x61A54 + (lin - 0x10000)`, 291 pages), and injected code must live in
file-backed bytes. Growing obj1's vsize alone does NOT help.

v0.11.0 filled it to 1 byte spare. Reclaimed ~250 bytes by gating out
`AztHudPoint` / `AztHudEvent` (`$ENABLE_CURSOR_REMAP = $false`) — dead since the
hot-spot polygons were patched in data. Now 1416 bytes used, 248 spare. When
adding stubs, check whether an old one is still reachable before assuming there
is no room.

See [[azrael-key-addresses]] and [[aztmod-patch-framework]].
