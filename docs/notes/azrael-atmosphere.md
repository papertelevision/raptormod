---
name: azrael-atmosphere
description: "Fog, floating dust and PLACED lights in the host renderer (built 2026-10-05 21:45, not yet seen in game): per-room JSON in C:\Games\RaptorMod\cache\rooms, cave class defaults, torch on room 1's inscription wall. How it works and the numbers."
metadata:
  type: project
---

Josh (2026-10-05): fog "deep dark brown, almost black, filling the outer edges" in the first room
and all caves; floating dust; one warm flickering torch in room 1 "towards the middle on a wall,
perhaps the one with the Latin wording". He wants to PLACE further lights himself later (the
game has no light data: every torch is paint; see [[azrael-true-colour]]).

**Files (he edits these):** `C:\Games\RaptorMod\cache\rooms\_defaults.json` = classes with room
lists + fog/dust defaults (class "cave": 32 rooms, fog #120C08 near 120 far 820 max 0.88, dust 500
r 360). `rooms\<ROOM>.json` = that room's own `lights` (x y z in the room's coordinates, color,
power, range, flicker) and fog/dust overrides. Re-read on every room entry.
**Room 1 torch:** the inscription wall is part `textwall2` (tex 17-ecrlwl01; the Latin "Morte Est
Locus Iste" is on 12-ecrdor02 beside it); centre (104,-31,-44), normal (-0.42,0,0.91) into the
room; light at (91,-8,-17), #FFB266, power 1.4, range 260, flicker 0.35.

**Renderer:** `Raster.Lights` (world xyz, rgb strength, range; <= 8), transformed to view space
per draw; per pixel: view position from screen + depth, |n.l| with the triangle's view-space
normal (`PTri.nvx..`), 1/(d (1 + d^2/range^2)); coloured gain added to the lamp's.
`Fog32`/`FogColor32`/`Fog32Near/Far/Max` (names: FogNear/FogFar already existed for the 8-bit
shade fog!) smoothstep on depth, applied AFTER lighting. `Raster.LampAt(fx,fy,z)` exposes the
beam. `tools\Motes.cs`: dust cloud in a sphere round the player clipped to the room box,
soft 1-4 px discs depth-tested against the scene, lit by room level + lamp beam; 0.2 ms.
Watcher: `Get-RoomAtmosphere` / `Set-RoomAtmosphere` / `Update-RoomLights` (flicker = two sines
+ smoothed noise, floor 0.45); `-RoomsDir`, `-NoFog`, `-NoDust`, `-NoLights`.
Cost: room 1 draw 7 -> 14 ms offline at 2560x1238 with fog + one light (a sqrt per light per
pixel; optimise if the frame rate complains). Frame interpolation still NOT built.
Offline frame: C:\Games\RaptorMod\cache\tc-test\atmos-cori.png.

## Josh's verdict (21:30): fog "perfect", dust "perfect", torch "perfect" -- three tweaks, built 21:42

- Fog starts at 100 (was 120) -- `_defaults.json` cave class.
- Dust sizes vary: `Motes.SizeMin` (JSON "sizeMin" 0.3): each mote gets SizeMin..1 of Size, more
  small than large (square of a uniform draw); small ones a little fainter.
- **Placed lights cast shadows like the flashlight**: a light with `"dir"` (which way it faces;
  a wall torch = the wall's normal) gets its own 512x512, 110-degree depth view drawn every frame
  from the light (`$script:lightRs`, culling off, 0.8 ms), passed in with `Raster.SetLightShadow(i,
  map, size, focalPx, LookAt's LastBasis)`; per pixel the light-to-pixel vector is projected into
  that view and 4 taps decide the occlusion. Outside the view's cone = lit. `"shadow": false`
  turns it off for one light. Room 1 torch: dir (-0.42, 0, 0.91).
- Draw with fog + one shadowed light: 15.7 ms offline at 2560x1238 (was 14.4 unshadowed, 7 bare).
- PowerShell trap hit again: `@($a/$l, $b/$l, $c/$l)` is parsed as `$a / ($l, $b/$l, ...)`.

Josh: "It's beautiful" -> fog + dust on in ALL rooms (21:50): _defaults.json class everywhere with rooms ["*"] (wildcard support added to Get-RoomAtmosphere; classes apply in file order, later override). The cave class stays as a place to make caves denser later.

## Visor bottom reverted + SOFT SHADOWS (built 2026-10-05 22:31)

- Josh: the top remap of the visor frame is "perfect", the bottom was corrupted -> `Overlay.VisorBottomRows = 0`
  (bottom rows compose as before; only the top band is remapped to the far corners).
- Soft shadows, from the ideas list: shadow maps 800 tall (`-ShadowSize`, was 560; width by the
  picture's aspect, ~1654x800); `Raster.ShadowSoft` (`-ShadowSoft`, default 1.0): each lookup is a
  2x2 bilinear-weighted compare (`ShadowTap`) and, when the 2x2 round the point is not all-lit or
  all-shadow, two such taps on a diagonal +-r texels (`ShadowSoftAt`), so a penumbra ~2 texels
  wide and no staircase. Same for the placed lights' maps. 0 = one smooth tap (cheapest).
- MEASURED in room 1 at 2560x1238 (noisy box, medians): no flashlight shadows 11 ms, one smooth
  tap 15 ms, 2-tap soft 20 ms. The first 4-tap/16-read version cost ~9 ms more than hard and was
  dropped. ESM/VSM prefiltered maps are the next step if soft shadows must get cheaper.
**Dust follows the flashlight (Josh's idea, 2026-10-05):** lamp off = grey-brown specks MIXED over the picture (Motes.ColorDark #6E5E4C, DarkAlpha 0.45, JSON colorDark/darkAlpha); lamp on = the original additive lit dust. Motes.LampLevel is fed the lamp's own fade each frame, so the switch eases. Specks also fade into the fog with distance.
