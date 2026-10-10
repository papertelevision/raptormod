---
name: azrael-renderer-phase-complete
description: "The Tier A host-renderer phase is DONE and signed off by Josh (2026-10-05). What shipped, how to run it, and what was deliberately left."
metadata:
  type: project
---

**Signed off 2026-10-05: "this wraps up the renderer phase and I am EXTREMELY happy with it."**

What it is: the game runs in DOSBox with its own rasteriser switched off, and
`tools\Watch-HostRender.ps1` on the host draws the 3D view (software rasteriser, C#) and
injects 8-bit frames into the game's viewport. ~22 fps became 130-150.

**Run it:** desktop shortcut *Azrael's Tear (Host Renderer)* -> `AztMod\Play-HostRender.cmd`
(game + watcher for one session). Without the watcher the game simply draws for itself.

**State at sign-off**
- Game build: 418 patches, overlay 53,217 of 53,248 bytes (**31 free**).
- Draws rooms, doors/moving parts, items (hidden when the engine removes them) and characters
  (27 rig files via *.ANI), all posed from the live scene graph with world matrices COMPOSED
  from locals. Corpus sweep: 178 files, 0 untextured triangles.
- Frame cap removed while the host renders; movement step follows the measured loop rate.
  Clock-gated to 18.2 Hz when the host asks (aztSceneParts bit 3): keyframe animation (six
  sites), RL built-in velocity/rotation (`AztVelGate`), event scripts + door rotations
  (`AztEventGate`). The crash was the AztScenePart2 skip not writing its outputs.
- `dos_rate = host` in azrael-staging.conf so DOSBox presents at the monitor's 180 Hz.
- Lighting/draw distance: measured against the engine, nothing to add; `-Light` stays off.

**Deliberately left / known**
- Intro: one key skips everything, "until I say so" (`$ENABLE_SKIP_ONE_CUTSCENE = $false`).
- Keyboard (arrow-key) turning is still frame-tied; mouse look is fine. Not requested.
- Doors/creatures step at 18 Hz by design; host-side smoothing was offered, not asked for.
- Diagnostics still in: RL error trap, pick guard, `-CharProbe`, `-CaptureRef`, `-Diag`,
  MOTION/step logging (always on, cheap), `2> AZERR.TXT` in AZRAEL.BAT.
- Dropped by Josh: save-load freeze ("no longer an issue"), MINEHEAD machinery difference.
- A watcher force-killed mid-game leaves the viewport frozen and the cap off.

Detail lives in [[azrael-tier-a-host-render]], [[azrael-rl-error-callback]],
[[azrael-characters-host-render]], [[azrael-room-unit-cache]], [[azrael-frame-tied-timing]].
Next phase not yet chosen; see [[azrael-project-direction]].