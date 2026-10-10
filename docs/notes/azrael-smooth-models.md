---
name: azrael-smooth-models
description: "REMOVED 2026-10-05 -- smoother models (curved subdivision at load + F9) were tried in game and taken out at Josh's request; do not re-propose. Where the code went and why."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-06T03:18:29.577Z
---

**Verdict (Josh, 2026-10-05 evening): "the increased polygon count (tied to F9) ... doesn't add
anything and makes characters look worse" -> REMOVED.** Do not re-propose subdividing models in
the host renderer, in Blender, or in the .XAF files (the September verdict in the game's engine
said the same: [[azrael-xaf-model-pipeline]]).

What was removed: `Import-AztRoom -Smooth` (+ `-SmoothLevels/-CreaseDeg/-CharSmoothLevels/
-CharCreaseDeg`), the watcher's `-NoSmoothModels/-NoSmoothShade/-SmoothKey` and the F9 room swap,
the `|smooth` room-cache key. `tools\MeshSmooth.cs` and `tools\Test-MeshSmooth.ps1` are parked in
`tools\retired\` (not loaded by anything). Left dormant, off by default: `Raster.SmoothShade` /
`CornerGroup` (per-corner lamp facing) and the `CornerGroup` fields in `RoomUnit.cs` /
`Composed.Build` -- nothing sets them now.

What it was, for the record: crease-aware welding (40 deg rooms, 80 deg characters), fans with
shared normals, Phong-tessellation midpoints (exact circular alpha = 1/((1+c)c)), split along
curved edges only, 1 round rooms / 2 rounds characters, corner normals carried across rounds.
It worked technically (no cracks, parts intact, +1.5 ms a frame) and Josh could see "a small
difference but not much"; at 100 deg "some of the models just look fat". The look, not the cost,
killed it.

Related: [[azrael-true-colour]], [[azrael-characters-host-render]], [[azrael-judge-in-game]],
[[azrael-frame-cost]].
