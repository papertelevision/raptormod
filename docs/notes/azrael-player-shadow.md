---
name: azrael-player-shadow
description: "Player shadow = RAPTOR.XAF body drawn ONLY into placed room lights' shadow views (GPU). Rig faces +Z, not +X. Built 2026-10-07, not yet seen in game."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-08T03:53:54.821Z
---

Josh asked (2026-10-07) for player shadows from placed room lights using the raptor mesh as an invisible body. Built, not yet seen in game.

- **ScanWire.cs**: AddBody / BodyTris / BodyMetrics / StepBody. StepBody sizes the rig so its eye sits at the camera's eye height above the floor (RayDistance straight down) and stands it 6% of its height behind the eye. It faces the camera's flat forward, plays WALK (KURT.ANI 124-136) when the eye moves more than 25 u/s and plays REST otherwise. **Pace = the characters' clock**: 1e6/aztAnimPeriod (read live, 18.2 Hz), whole keyframes (BodyStepped). Pacing it by player speed was "too fast" (Josh, 2026-10-07): never scale it by speed again. A move over 400 u/s is treated as a warp, not a walk.
- **The rig faces +Z** (visor, toes and arms), checked in profile. The earlier "+X forward" assumption was WRONG. Rig X is across.
- **GpuRaster.SetCasters**: the body is drawn into shadow slots i>=2 (placed lights) with uNoMask=1. It is never drawn into the lamp pair or the main view. The casters are used up each Draw.
- **Watcher**: on by default, `-NoPlayerShadow` turns it off. GPU only (no CPU-path shadow).
- **Test-GpuLook**: `-PlayerShadow x,z -PlayerYaw deg -Steady` (Steady = no torch flicker, so an A/B diff is clean). It probes the floor from the light's height, because from y=200 the ray hits CORICORI's ceiling.
- CORICORI's torch is about 76 units above the floor (floor -83.9), only just above the body, so the shadows run long (about 3x the distance). That is physically right; if Josh finds it too long, lights need placing higher.

Related: [[azrael-atmosphere]], [[azrael-gpu-renderer]], [[azrael-scan-wire]], [[azrael-judge-in-game]].

**Darker shadows (2026-10-07, Josh: 'a touch darker')**: ShadowDark default 0.30 -> 0.38 (lamp), plus GPU `LightShadowDeep` 0.35 (watcher `-LightShadowDeep`). A placed light's shadow also removes that share of the room level, weighted by the light's share there. Measured: the player shadow went from 73% to 66% of lit brightness.

**2026-10-08 round 2 (Josh: 'still very jiggly and fast', plus shadows cut off along straight lines):**
- JIGGLE ROOT CAUSE: the body was rescaled every frame so its eye matched the LIVE eye height, and the game's walk bob moves that eye. A wall torch only about 25 units above the head magnifies any height change about 3x in the shadow's length. Fix: FIXED size (BodyEyeHeight 48), feet on the floor (followed at 14/s), yaw eased (10/s), and a walk/idle dead band (on above 40 u/s, off below 15). Poses are BLENDED at the characters' 18.2/s; stepped whole frames (BodyStepped) jitter when magnified. Verified: a +/-3 eye bob changes the body by 0.000 units. Not yet seen in game.
- CUT-OFF ROOT CAUSE: a placed light's GPU shadow was ONE 110-degree view along its dir, so shadows stopped dead in a straight line outside it. Now ALL ROUND: GpuRaster.SetLightCube, six 90-degree faces in one 3x2 map (uLightMapOn 2, uCubeAx[6], softTile). The watcher's -LightShadowFace is 768 per face (about 2x sharper, ~14 MB a light). The CPU path still uses the single view. Test-GpuLook -OldLightView renders the old way for A/B.
- IDLE (Josh, 2026-10-08: breathing 'in fast forward'): REST 143-147 is only 4 keys, about 5 loops a second at the tick. It is a CLOSED loop (147 = 143's pose, measured), so it is played forward once per BodyIdleCycle = 3.5 s, blended between keys (max 0.006 units per 120 fps frame). Don't ping-pong it: that made two breaths per cycle.
- SOFT CONTACT SHADOWS (2026-10-08, Josh asked): PCSS on the placed lights' cube maps (pcssTile). A blocker search of 16 rotated Poisson taps, then a penumbra = size*(lz-zb)/zb*lf/lz/2 texels clamped [0.75, SoftMaxTexels 20], then a 16-tap filter. Watcher -LightSoft 4 (Josh set it 2026-10-08, was 6; world units; 0 = the old hard softTile). The cube faces keep a SoftMax+3 texel margin (FocalPx) so taps never leave a face. No visible grain. The FLASHLIGHT pair uses PCSS too (pcssMap, -LampSoft 3; the muzzle flash shares its maps). One routine, pcss(), with a forward declaration: GLSL needs declare-before-use. Verified: no self-shadowing (mean brightness identical, 0.2% of pixels changed).
