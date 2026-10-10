---
name: azrael-reality-lab-engine
description: "Azrael's 3D engine is RenderMorphics Reality Lab in ramp (8-bit palettised) mode, statically linked into R.EXE — not a bespoke rasteriser."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-20T15:48:54.656Z
---

The 3D pipeline in R.EXE is **RenderMorphics Reality Lab**, the engine Microsoft
bought in 1995 and shipped as Direct3D Retained Mode. Proof: the string
`Rendermorphics ERROR:` at 0x140013, and assertions compiled in with their source
paths — `..\rl\device.c`, `..\rl\object.c`, `..\rl\math.c`, `..\rl\tilemap.c`,
`..\rl\api\object\objdes.c`, `..\gen\rampmap.c` (`!ramp->free`),
`..\ramp\ramplt.c` (`best != NULL`, `rm->ramp != NULL`). Also `MeshRenderer`,
`MatCache`, `GetTextureMemory`, `DefragTextureCache`, `TextureItemInUse`.

Only the **ramp** modules are linked: the 8-bit palettised software rasteriser
that lights through ramp tables. No HAL/hardware device module is present.

**Why this matters:** it explains why the renderer is structured rather than
ad-hoc, and it is the answer to "can we add OpenGL?" — see
[[azrael-opengl-verdict]]. It is also why the whole pipeline is palette-bound,
which constrains any art work ([[azrael-font-format]]).

Reality Lab being Direct3D RM's ancestor means its structures are semi-documented,
which makes a source port more tractable than for a typical bespoke 1996 engine —
but that is a reimplementation, not a patch.
