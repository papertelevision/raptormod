---
name: azrael-geometry-export
description: WORKING OBJ export of a live room - AZTGEO.BIN + tools\Export-Obj.ps1 produced 1173 triangles with ZERO faces dropped. Plus the PowerShell comma-precedence traps that cost two rounds.
metadata:
  type: project
---

**Stage 6 achieved 2026-09-26: a real OBJ of room 1, exported from the running game.**
124 named meshes, 1,377 vertices with UVs, 1,749 normals, **1,173 triangles, ZERO
faces dropped**, no NaNs.

Pipeline: `$ENABLE_GEO_LOG` -> `AztGeoEmit`/`AztGeoWrite` in the overlay write
`AZTGEO.BIN`; `tools\Export-Obj.ps1` turns it into `azrael-room.obj`.

**The trick that made the dump trivial: `INT 21h AH=40h` writes from ANY address**, so
the payloads stream straight out of the engine's own arrays. Only a fixed 144-byte
header per mesh is assembled, and mesh size is unbounded. Four writes per mesh.

**Zero dropped faces is the validation.** Faces reference vertices by POINTER; the
exporter recovers `(ptr - base) / stride` and REJECTS any pointer not landing exactly
on a stride boundary. All 1,173 resolved exactly. A wrong pointer interpretation would
show up as drops, so this is proof rather than plausibility. See
[[azrael-rl-object-model]] for the strides (vertex 48, face 120, normal 12).

**Sanity check on the result.** Level-only bounds (excluding the `ZZ*` rigs) are
X −524..726, Y −208..107, Z −437..504 — a coherent room, with the camera's observed
range (X −385..23, Z −363..129) sitting inside it. Only **2 of 124** objects are
outliers, both `EUEYE`, at X~2500 / Y~−1340. Those match an odd world transform
already visible in the scene log, i.e. **stale transforms in the ENGINE** for bones
that are not currently dirty-propagated — not an export bug. Exclude `ZZ*` for a
level-only export.

**VISUALLY CONFIRMED in Blender (2026-09-26): the room renders correctly and the
polygons match the game.** Winding order turned out fine; textures absent as expected.

**CORRECTED 2026-09-26 — it is NOT stale world matrices.** Once the LOCAL matrices
were captured (`frame+0x4C`), composing `local x parent.world` reproduced the stored
world matrices EXACTLY for every creature bone tested. The transforms are internally
consistent. What is actually true: `EUTAIL`'s LOCAL genuinely places it ~648 units from
the pelvis, so the skeleton really is laid out that way in the data as sampled. Since
all these bones carry an `Animation` attachment (`frame+0x1C/+0x20`), the likely reading
is REST-POSE locals not yet overwritten by animation — unconfirmed, needs the
`AnimationSet` decoded. The stale-world hypothesis below was WRONG; kept only so the
reasoning is not repeated.

**Superseded hypothesis (wrong):** Character bones below
the first joint carry rest-pose world matrices, so a creature appears displaced as a
rigid unit (~650 units) while its shape is correct. Measured on XAFQ1: the chain is
exact until `EUBUM -> EUTAIL`, which jumps (37, 192, 648); every offset below that is
small and consistent. Cause: the engine only re-propagates DIRTY frames and
`AztSceneLog` deliberately does not call the lazy refresh `0x554F0` (calling it would
mutate engine state to observe it). **Fix: capture each frame's LOCAL matrix at
`obj+0x4C` and compose the hierarchy host-side.** That is also the right approach for
animation, since local matrices are what animation drives. NOTE the scene log does not
currently capture `obj+0x4C..0x8B` — the header dump stops at `0x4B` and the world
block starts at `0x90`, so that range is an unsampled gap.

## PowerShell traps that cost two rounds here

1. **The comma binds TIGHTER than `+`.** Writing
   `@( $a*$M[0] + $M[12], $b*$M[1] + $M[13] )` makes `$M[12], $b*$M[1]` an array, so
   the preceding `+` attempts `double + Object[]` and dies with *"[System.Object[]]
   does not contain a method named 'op_Addition'"*. **Parenthesise every element of a
   multi-element `@(...)` whose members are arithmetic.**
2. **Inside a METHOD CALL, commas are argument separators.**
   `$list.Add("{0} {1}" -f $a, $b)` passes THREE arguments, so the format string only
   ever sees `$a` — *"Index (zero based) must be ... less than the size of the argument
   list"*. **Wrap the whole `-f` expression: `.Add(("{0} {1}" -f $a, $b))`.**
3. Short helper names silently resolve to builtin aliases: `gu`=Get-Unique,
   `rd`=Remove-Item, `fl`=Format-List. Use verbose names (`ReadUint32`). And `$r`/`$R`
   are the same variable. See [[azrael-scene-graph]].
