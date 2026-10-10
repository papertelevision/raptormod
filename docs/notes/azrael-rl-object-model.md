---
name: azrael-rl-object-model
description: Reality Lab classes SELF-IDENTIFY - the class tag points at a descriptor with a name string at +0x04 and object size at +0x08. Frame is 736 bytes and the visual list is at frame+0x268.
metadata:
  node_type: memory
  type: reference
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-26T14:53:52.131Z
---

**A class tag is not opaque.** It points at a descriptor:

| descriptor offset | meaning |
|---|---|
| `+0x00` | **base class** descriptor (Frame's is `Tree`) |
| `+0x04` | **name string** |
| `+0x08` | **object size in bytes** |
| `+0x18`, `+0x1C` | methods |

`0x147EDC` → `"Frame"` proves the scheme. The full table (obj2 linear addresses):

| tag | class | size | | tag | class | size |
|---|---|---|---|---|---|---|
| `0x1476A4` | Object200b20001 | 44 | | `0x148324` | Device | 828 |
| `0x147700` | Texture | 424 | | `0x148370` | Viewport | 592 |
| `0x147B44` | AnimationSet | 48 | | `0x1483A4` | Tilemap | 64 |
| `0x147B78` | Animation | 76 | | `0x148468` | Visual | 48 |
| `0x147BAC` | Mesh | 272 | | `0x1484A4` | Light | 124 |
| `0x147BEC` | Face | 120 | | `0x149240` | Tree | 68 |
| `0x147C20` | Material | 316 | | `0x149280` | MeshRenderer | 220 |
| `0x147EDC` | **Frame** | **736** | | `0x1492B4` | MatCache | 1072 |

Tags observed at runtime are RELOCATED: add the obj2 delta (`0x1F1000` in the
sessions so far). See [[azrael-camera-transform]].

**`0x54C38` is the generic dynamic-array append** — `items[count] = item` through
`[list+0x08]`, bumping `[list+0x00]`. So **`{count, capacity, pointer}`** is the list
shape to expect everywhere in this engine.

**Frame is 736 bytes (0x2E0).** `Frame::AddVisual` = **`0x49940`**: validates (Frame,
Visual), bumps `[visual+0x0C]` refcount, `add eax,0x268`, append. Therefore:

* **`frame+0x268` visual count, `+0x26C` capacity, `+0x270` -> `Visual*[]`**
* if the visual is a Mesh, `mesh+0x30` is set to the owning frame (back-link)

**Mesh (272 bytes):** `+0x0C` refcount, `+0x14` handle, `+0x18` class tag,
`+0x30` owning frame, and **three `{count,cap,ptr}` arrays at `+0x48`, `+0x54`,
`+0x60`** (pointers at `+0x50`, `+0x5C`, `+0x68`). **All three are now CONFIRMED by
dumping their payloads:**

* **`+0x50` -> VERTICES, 48-byte stride:** `x,y,z` at +0x00/04/08 (frame-local),
  vertex colour at +0x0C (always `0xFFFFFFFF`), **`u,v` at +0x10/+0x14** (in [0,1]),
  +0x18..+0x2F zero on every mesh sampled.
* **`+0x5C` -> an INLINE ARRAY OF `Face` OBJECTS, 120-byte stride** — NOT pointers.
  The object header sits at the array base (`+0x14` handle, `+0x18` = the Face tag).
  Face: **normal at +0x2C/30/34**, colour at +0x38, **vertex count at +0x44 = 3, so
  faces are TRIANGLES**, `+0x58` -> the mesh's vertex array, `+0x64` -> its normal
  array, and per-corner pointers from +0x4C spaced 12 apart.
* **`+0x68` -> NORMALS, 12-byte stride**, unit length. Count equals the vertex count
  on character meshes but NOT on level meshes (floorbit is 8 verts / 12 normals), so
  it is a separate indexed array, not one-per-vertex.

**Faces reference geometry by POINTER, not index** — recover an index as
`(ptr - array_base) / stride`.

Sanity check that validated all of it: `wall2` = 4 vertices + 2 triangles + 4 normals,
and its vertices form a proper textured quad (two share the bottom y, two share a
vertical edge, u along the bottom, v up the side). Room 1 totals **1377 vertices and
1173 faces across 124 meshes**.

**Method for finding any attachment: find the function that MUST touch it.** The tree
links came from the recursive propagator `0x55378`; the visual list came from
`AddVisual`. Both beat searching for accessors. See [[azrael-scene-graph]].

**Do not confuse `Animation` with `Mesh`.** `0x147B78` is Animation, and the
`frame+0x1C/+0x20` move-callback attachment marks ANIMATED frames only (61 of 132 in
room 1). Geometry is at `+0x268` and is on **124 of 132** frames — including all the
walls and floors. An earlier note that walls had no geometry was wrong; it came from
dumping only to `frame+0x13F`. **Always check the class's declared size before
concluding a field is absent.**

## Confirmed descriptors and the render path (2026-09-27)

| descriptor (obj2) | class | size |
|---|---|---|
| `0x147EDC` | Frame | 736 |
| `0x148370` | Viewport | 592 |

`AddMoveCallback` (`0x44DD0`) grows a list at **frame+0x280 (count) / +0x284 (8-byte
{callback, context})**; registered from `0x1E067`, `0x1E0F2`, `0x1E49F`, `0x22CE0`.
Move callbacks move frames; they do NOT render.

Thirteen functions resolve against the Viewport descriptor (the method set): `0x3A630`
create, `0x3A840` SetBack, `0x3A8A0` SetField, `0x3ACB0`, `0x3ACE0`, `0x3C1A4`, `0x3F0D0`,
`0x3F6D0`, `0x58D00`, `0x58D9C`, `0x59C40`, `0x5B950`, **`0x5BD0C` = Viewport::Render**.

**`0x3F1B0` is the render-all** — and `FuncOf` MISLEADS here: its body continues past an
*early-exit* `ret` at `0x3F220` through to `0x3F2DE`, looping devices -> viewports with
`call 0x42410` (scene root) then `call 0x5BD0C`. It has **eleven call sites**; `0x14187`
is only one of them, which is why patching that branch freezes the screen without
stopping the rendering.

Related: [[azrael-host-guest-bridge]]
