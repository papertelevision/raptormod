---
name: raptormod-roadmap
description: "Josh's release plan (2026-10-11): RaptorMod 1.0 = a patch for the Steam DOSBox version (bug fixes + the 2K/4K texture tiers); 2.0 = DOSBox removed via an in-app emulator core (Tier 1) + more 3D effects, room polish, better geometry; Unity later."
metadata:
  type: project
---

**Josh, 2026-10-11, in order:**
1. **RaptorMod 1.0** -- "a patch for the dosbox steam version":
   - finish some bug fixes;
   - "implement 4k and 3k textures on current version of dosbox dependent version".
2. **RaptorMod 2.0** -- "remove dosbox as you outlined in option 1" ([[azrael-leaving-dosbox]], Tier 1). "That giant step", most likely with:
   - more 3D effects;
   - deep polishing of all rooms;
   - better 3D geometry.
3. **Unity** -- "down the road, not important at this time".

**Why:** ship a real product on what works now. Everything made for 1.0 (room JSONs, renderer effects, textures) carries into 2.0 unchanged, because the host renderer does not care what runs the game.

**How to apply:**
- **1.0, in this order:**
  1. Confirm the untested work in game first: vector cursors, the Space guard, and the 256 KB overlay window / obj2 delta move ([[azrael-vector-cursors]], [[azrael-overlay-read-limit]]). (The overlay window: confirmed fine in game 2026-10-11.)
  2. Bug fixes, players' view first.
     - **Do NOT deep-fix DOSBox-only fragility** (overlay z-order, torn reads, focus, the host pointer). 2.0 deletes those mechanisms, so patch them just enough.
  3. Textures. The plumbing exists ([[azrael-josh-hires-textures]]):
     - `-TextureQuality`, raptormod-settings.json, `Get-AztSizedOverride`;
     - the title OPTIONS panel, "COMING SOON".
     - The work is Josh's art room by room, wiring OPTIONS for real (applies on the next launch or room load), and a VRAM/disk check per tier.
     - **SETTLED:** the tiers are Normal 2K / Ultra 4K. Josh's "4k and 3k" was a typo (2026-10-11); there is no 3K tier.
  4. Release engineering, in its own slot:
     - a patcher that copies the Steam install and never touches it;
     - the multi-GB asset pack and its download/install;
     - a one-icon launcher;
     - the banner "AztMod 0.16.0 lfbspike" -> RaptorMod 1.0;
     - prerequisites;
     - precompile the tools' C# to a DLL (faster start, and a head start on 2.0's compiled host);
     - a clean-machine test, Josh's playthrough, then dev -> main;
     - licences (the DOSBox Staging bundle, soundfonts).
- **2.0:**
  - A Tier 1 spike first. Then move the host into a compiled C# app and retire the overlay / key-colour / sync / torn-read machinery one piece at a time. The core choice (libretro vs a Staging fork) and the GPL question are decided then.
  - Effects and room polish can run alongside, after the spike proves out.
  - **GEOMETRY CAUTION:** the game still collides against its ORIGINAL geometry. New meshes must keep walkable floors, walls and doorways where they were (float/clip otherwise). Detail off the walk path is safe.
- **Unity:** can host the Tier 1 core as its simulation backend and replace systems gradually. It is blocked on story-layer reverse engineering ([[azrael-leaving-dosbox]]).

Related: [[azrael-project-direction]], [[raptormod-repo]].
