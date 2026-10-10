---
name: azrael-opengl-verdict
description: "Hardware 3D for Azrael is out of scope for AztMod — the blocker is the DOSBox emulator boundary plus static linking, not the renderer's design."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-20T15:48:58.933Z
---

Assessed 2026-09-20. Adding OpenGL / hardware 3D to Azrael's Tear is possible in
principle but is a different project from AztMod, and not worth starting as a
patch. The blockers, in order of severity:

1. **The emulator boundary.** The game is emulated x86 inside DOSBox; there is no
   host GPU on the other side. Any GL path needs a forked DOSBox exposing a
   bridge (fake port/interrupt), which turns the mod from a PowerShell patcher
   into "ship your own emulator" and needs a C++ toolchain this box lacks
   ([[azrael-re-tooling]]).
2. **Static linking.** Reality Lab is compiled into R.EXE
   ([[azrael-reality-lab-engine]]), not an overlay. Glide games can be
   accelerated (DOSBox-X does it) only because GLIDE2X.OVL is a loadable module
   with a stable ABI to trap. Here you would hook hard-coded addresses, valid for
   one build.
3. **Code budget.** The cave is 1664 bytes with ~24 free
   ([[azrael-wall-slide]]); marshalling vertices and state is far more.
4. **Ramp mode is palettised** — textures are 8-bit indices lit through ramp
   tables, so a GL path must mirror the texture cache and its invalidation.
5. **Frame-tied logic** ([[azrael-frame-tied-timing]]) — faster rendering just
   makes the game run faster.

The one real prize would be escaping 640x480 ([[azrael-hires-blocker]]), since a
GL path bypasses the VESA bank writer entirely. That does not change the verdict.

**Don't re-derive this.** The realistic GPU win is already in place: DOSBox
Staging's post-process shaders ([[azrael-dosbox-staging]]).
