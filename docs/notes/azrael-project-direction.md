---
name: azrael-project-direction
description: "Three stages since 2026-10-11: RaptorMod 1.0 on DOSBox, 2.0 without DOSBox (an emulator core in our app), Unity later. (2026-09-27: improve in-engine now, Unity later.)"
metadata:
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-27T18:01:39.136Z
---

**Josh's stated plan, 2026-09-27:** keep making the game as good as possible **in its
current engine first**, then build a separate engine layer (**Unity**) on top of it later.
He is explicit that Unity is coming, just not yet — so treat in-engine work as the active
track and Unity as the known destination.

## Where things stand

**Option 1 of the hybrid — host pixels inside the original game — is COMPLETE**, verified
end to end on screen (see [[azrael-view-injection]] and [[azrael-host-guest-bridge]]):

* assets, live camera, per-object transforms, room graph — all readable
* host→guest read AND write, no emulator fork, 0 frames missed
* engine 3D output suppressible with a one-byte branch patch
* full 1024x576 frame injection at **1.5%** frame-rate cost
* the game's live 256-colour palette captured (255 distinct)
* the whole loop joined up: live camera -> Blender -> quantise -> inject, and it
  **lines up with where the player is standing**

## What this means for planning

**Nothing done so far is wasted by the Unity move.** The same camera matrices, per-object
transforms, `.XAF` geometry, textures and room graph feed Unity directly, and the *reading*
half of the bridge is exactly the half Unity needs. Do not treat the bridge work as
throwaway.

**The 8-bit ceiling is the reason Unity is the destination.** Option 1 can deliver
geometry, resolution and model quality inside the original game but never more than 256
colours. Do not propose fixing that inside option 1 — it would mean changing the video mode
and every drawing path that assumes 8bpp.

**Injection ships DISABLED** (`aztInjEnable = 0`). The current build does not change normal
play; the hook is inert until a host sets the flag.

Related: [[aztmod-patch-framework]], [[azrael-xaf-scene-format]], [[azrael-zones-room-graph]]

## UPDATE 2026-10-11 -- three stages, Unity is the third

Josh's sequence ([[raptormod-roadmap]]): **1.0** = a patch for the Steam DOSBox version (bug fixes + the 2K/4K texture tiers); **2.0** = DOSBox removed by running an emulator core inside our own app ([[azrael-leaving-dosbox]] Tier 1) plus more 3D effects, room polish and better geometry; **Unity** = later, not important now -- it can host the Tier 1 core as its simulation backend. The '8-bit ceiling' reason above is history: the host renderer has drawn the view in true colour since 2026-10 ([[azrael-gpu-renderer]]).
