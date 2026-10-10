---
name: azrael-xaf-scene-format
description: "The .XAF files are plain-text scene descriptions - all the game's geometry is on disk, readable, no play-through needed."
metadata:
  node_type: memory
  type: reference
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-10-04T03:59:08.293Z
---

**The geometry was never hidden in `AZT.BIN`.** `C:\AZTEX` holds **178 non-empty `.XAF`
files, 26 MB, 100% printable ASCII**, and they are complete scene descriptions.

```
material "FLOOR1" {
 texture "ecrflr01.gif"
 colour { 0, 0, 0, 1 }
 specular { 0, 15 }
}
object "wall2" {
 matrix {  4x4, row-major, translation in the LAST row  }
 mesh {
  vertices { x,y,z ... }
  normals { x,y,z ... }
  texture_coordinates { u,v ... }
  faces { 3,  v,t  v,t  v,t      <- count, then (vertexIdx, texcoordIdx) pairs
          3,  v,t  v,t  v,t
          0 }                    <- terminated by a zero count
  material "CORWALL1" }
}
```

Census: **8,395 objects / 8,395 meshes across 178 files**. `CORICORI` (room 1) has 64;
the largest is `POIS_GR5` at 156. Object names match the live scene-graph names from
[[azrael-scene-graph]].

## A MESH CAN BE MULTI-MATERIAL — `face_materials` (found 2026-10-03)

The sketch above shows `material "CORWALL1"` inside the mesh, and that is the *single*
material case. The other case has **no mesh-level material at all** and instead:

```
  faces { ... 0 }
  face_materials { "1CHIM_WALL02", "1CHIM_WALL02", ... "1GRAILDOOR" }
```

one quoted name **per face, in face order**, exactly parallel to the face list (449
tokens for 449 faces). Reading only `material` drops every such mesh to the untextured
fallback: **31,980 faces, 24.1% of all visible geometry corpus-wide.** They are heavily
concentrated in a few huge meshes — each room's props are one mesh literally named
`stuff` (1,369 faces in PULPIT2, 449 in CHIMNEY, 290 in MINEHEAD) — plus doors
(`chi_xitdor`), chests (`decchest02`), `car2`, `lecttop`, `picture2`. Worst rooms:
CHIMNEY 97% lost, PULPIT2 92%, R35_2 92%, PULPIT3 90%, ENTRY_D 82%.

OBJ needs no new format for this — re-emit `usemtl` between face groups. **Advance the
face counter for dropped faces too**, or every later face takes the wrong material.

Two regex traps when auditing this:
* `material "NAME"` is BOTH the file-scope definition and the in-mesh reference. The
  definition is followed by `{`. `"([^"]+)"\s*(?!\{)` does **not** separate them — `\s*`
  just backtracks until the lookahead passes, so it always matches. Use `(?!\s*\{)`.
* Counting faces as "lines starting with a digit" reports **1** for any mesh that puts
  its faces on one line. Walk the records: `N`, then `N` pairs, lone `0` ends the list.

## Characters and items are SEPARATE .XAF files

Of 179 `.XAF`, many are not rooms: `CL-STAND` / `CL-WALK` / `CL-ATAK` / `CL-TURN` /
`CL-LOOK` are one creature's per-animation files, and `EDGAR`, `EUGENE`, `DEATH`,
`BOAT01` are named rigs — each a full mesh set with its own `.RES` (EDGAR 23 meshes,
EUGENE 18, CL-STAND 20). **A room-only loader therefore renders an empty room**: no
characters, no pickups. They load through the same pipeline; what is missing is knowing
*which* are present and *where*, which is what the live scene graph
([[azrael-scene-graph]]) answers.

## Pairing a .XAF with its .RES

A `.RES` has no names and no index; records match the `.XAF`'s texture references by
**first-appearance order**. Verified on `CORICORI`: all 21 names appear in the live
room-1 capture, and record 12 `ecrdor02` is 512x512 in both.

**Some `.XAF` files say `name.azf` and others say `name.gif`.** `Export-RoomTextures.ps1`
matched only `.azf` and therefore silently found ZERO names in `CORICORI.XAF`. Match
both, or parse `texture "..."` and take the leaf.

## Why this matters

Static geometry no longer requires playing through every room — see
[[azrael-geometry-export]], which captured it from live memory. Live capture is still
needed for what the `.XAF` cannot hold: runtime state, posed animation, instancing.

Not yet done: a `.XAF` -> OBJ converter, and a check of the offline conversion against
the known-good live capture of room 1.
