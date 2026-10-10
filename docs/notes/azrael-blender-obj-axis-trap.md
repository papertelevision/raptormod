---
name: azrael-blender-obj-axis-trap
description: "Blender's OBJ importer leaves the Y-up to Z-up conversion in matrix_world, NOT baked into vertices - imported mesh data is still in GAME coordinates."
metadata:
  node_type: memory
  type: reference
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-27T00:43:48.876Z
---

**Blender's OBJ importer does not bake its Y-up → Z-up conversion into the vertices.** It
leaves that conversion in the object's `matrix_world`, which comes out as exactly

```python
G2B = Matrix(((1,0,0,0), (0,0,-1,0), (0,1,0,0), (0,0,0,1)))
```

so **the mesh data is still in GAME coordinates**.

## Why it matters

Placing anything using an engine matrix from the running game (see
[[azrael-host-guest-bridge]]) means deciding which space the vertices are in. Converting
a mesh to local space must subtract the **game-space** translation, not the Blender-space
one.

Getting it wrong put a replacement object **140.2 units** from where it belonged — which
is precisely the distance between the two forms of that translation vector, and is how
the bug was identified:

```
T(game)    = (22.0143, -99.2400,   1.7052)
T(blender) = (22.0143,  -1.7052, -99.2400)
|difference| = 140.2
```

With the right space the placement error was **0.000006 units**.

## Two checks that look reasonable and are worthless

* **Comparing object ORIGINS.** Every imported object sits at the scene origin, so the
  difference is just the length of the translation vector (101.67 here) no matter how
  correct the placement is. Compare **world-space bounding-box centres** instead.
* **Measuring after modifiers.** Bevel and Subdivision Surface both shrink a mesh, moving
  its centre (~0.15 units here). Measure placement **before** adding modifiers, or the
  shrinkage gets mistaken for a transform error.

Related: [[azrael-geometry-export]], [[azrael-camera-transform]]
