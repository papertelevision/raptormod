---
name: azrael-hud-viewport-locked
description: The 640x342 viewport and the 55% HUD panel are settled and must not be traded away for performance.
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-19T19:54:17.470Z
---

**Do not propose shrinking the 3D viewport or enlarging the instrument panel**,
for performance or any other reason. The 640x342 view with the panel at
`$PANEL_SCALE = 0.55` is a finished, deliberate result and one of the mod's main
goals.

**Why:** it took many iterations to get there — the panel rescale, relocating the
HUD widgets, the hot-spot polygon tables, the nbut anchors and the regenerated
art all exist to support it. I suggested reverting some of it to claw back ~21%
of the per-frame pixel cost (640x342 = 218,880 px vs 640x269 = 172,160) and the
user ruled it out outright.

**How to apply:** treat `$PANEL_SCALE`, `$VIEW_W`, `$VIEW_H` and `$VIEW_Y` as
fixed. Find frame rate elsewhere — emulated CPU cycles, presentation mode, or
decoupling game logic from frame rate. See [[azrael-dosbox-staging]].
