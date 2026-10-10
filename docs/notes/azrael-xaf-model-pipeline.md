---
name: azrael-xaf-model-pipeline
description: Round-trip model pipeline built 2026-09-27 - .XAF to OBJ to Blender and BACK into the game. Keep it; the writer works and is verified.
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-09-27T23:57:04.416Z
---

**Josh asked to keep this tooling for updating other models.** A complete, verified
round trip now exists: `.XAF` -> OBJ -> Blender -> `.XAF`, with the game loading the result.

## The tools

| script | does |
|---|---|
| `tools\Export-XafObj.ps1` | `.XAF` -> textured OBJ, any of the 179 scene files. `-Report` inspects only |
| `tools\Import-XafMesh.ps1` | OBJ -> back into the `.XAF` **in place**. `-Revert` restores. `-Report` dry-runs |
| `Desktop\lurka\subdivide_lurka.py` | Catmull-Clark with angle-weighted creasing. **Preserves UVs** |
| `Desktop\lurka\unify_lurka.py` | solidify+join+voxel remesh into ONE body. **Destroys UVs** |
| `Desktop\lurka\gamify_lurka.py` | unify, then cut back into the original named parts |

`Import-XafMesh` replaces ONLY the vertices/normals/texture_coordinates/faces blocks and
leaves matrices, materials and the animation_set byte-identical. It always reads from
`.XAF.orig`, so nothing compounds. Blender is at
`C:\Program Files\Blender Foundation\Blender 5.2\blender.exe`.

## The thing that decides whether a model change is worth anything

**The engine does NO lighting** — see [[azrael-rl-object-model]]. So GEOMETRY IS NEARLY
INVISIBLE and the TEXTURE IS THE ENTIRE LOOK. Josh's verdict on a 5x-triangle Lurka was
"it didn't look like it had more polygons", and he was right: extra polygons only change
the silhouette, and without lighting a smoother silhouette barely registers.

**Therefore: never use a voxel remesh for something going back into the game.** It rebuilds
the surface from scratch, so UVs have no correspondence and must be resampled by proximity
— which stretches across every bit of invented surface. Catmull-Clark subdivision
interpolates UVs exactly and is the only safe operation. This was learned by shipping the
remesh and getting "stretched or missing" back.

## Facts measured, so they are not re-derived

* **No mesh size limit to worry about.** The shipped corpus goes up to **1,876 vertices**
  (R35_2.XAF) and **1,399 faces** (PULPIT3.XAF) in a single block.
* **Triangle budget:** room 1 (CORICORI.XAF) is **589** triangles; Lurka is **440**.
  The rasteriser is triangle-setup bound, not fill bound, so triangles are the expensive
  axis (see [[azrael-perf-measured]]).
* **Winding:** corner order agrees with the stored normals on 440/440 original faces.
  Blender round-trips it correctly; no flip needed.
* **`mount c .\GAME`**, and RESOURCE.CFG's first line is `C:\AZTEX\`, so the live geometry
  is `GAME\AZTEX\*.XAF`. `LURKA.DAT` in GAME\AZRAEL is **dialogue**, not geometry.
* **Vertex sharing:** key on (vertex, UV) and average the normals. Keying on the normal too
  — which is what Blender's per-corner normals imply — triples the vertex count for zero
  visual difference, because normals cannot affect an unlit renderer.

## Two file-format traps in the writer

* **Face punctuation is `3,<TAB>0,0, 2,2, 1,1, `** — comma after every pair AND a trailing
  one. Do not emit `0,0 1,1 2,2`.
* **Never write exponent notation.** .NET's `G7` gives `-4.276302E-05`; every number the
  1996 tool wrote is lowercase with three digits (`-8.16568e-008`). `Num()` writes plain
  fixed point and pins InvariantCulture.

**State as of 2026-09-27: LURKA.XAF is reverted and byte-identical to stock**, along with
every `.RES` in AZTEX. Nothing in the game is modified.

Related: [[azrael-xaf-scene-format]], [[azrael-geometry-export]], [[azrael-texture-remaster-verdict]],
[[azrael-blender-obj-axis-trap]], [[azrael-project-direction]]
