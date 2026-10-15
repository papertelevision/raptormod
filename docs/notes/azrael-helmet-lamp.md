---
name: azrael-helmet-lamp
description: "Helmet lamp lighting in the host renderer (2026-10-05): light table through gain 1 up to 1.7, cone by screen radius, falloff by depth, per-triangle facing, Bayer dither. Built and offline-rendered; not yet seen in game. Cast shadows are the agreed next step."
metadata:
  type: project
---

Josh (2026-10-05): renderer stable again; wants a basic lighting system, "not too intense as far
as making the rooms too dark", with a helm-mounted flashlight, and EVENTUALLY real-time cast
shadows.

**Built:** `Raster.Lamp` (Raster.cs, in DrawFastCore; off => code path byte-identical, Test-RasterFast
still passes). `BuildLightTable(pal, levels, maxGain)` = shade table that runs THROUGH gain 1 up
to maxGain (56 levels, 1.7), never index 0. Per pixel: level = LampRoom + LampPower * facing(tri)
* cone[tan^2 off axis] * dist[w], + 4x4 Bayer, one table lookup. The light is AT THE EYE, so
cone = f(screen radius), falloff = f(depth), no visible shadows. Cost +0.3-0.5 ms at 1600x928.
Watcher: on by default; `-NoLamp`, `-LampRoom` 0.70, `-LampPower` 0.90, `-LampRange` 600,
`-LampInner` 10, `-LampOuter` 24. Mutually exclusive with the old `-Light` fog path.
Test renders in `C:\Games\RaptorMod\cache\lamp-test`. Offline it reads as a soft pool on a near wall
and is subtle across a big room -- tuning is Josh's call once seen.

**Known consequence:** `-Audit` compares against the unlit engine picture, so with the lamp on it
will flag brightness differences; run audits with `-NoLamp`.

**Next (agreed direction):** cast shadows. A lamp at the eye cannot show them; they need a light
somewhere else (room lights, or the lamp offset from the eye) and a shadow-map pass per light.
Textures have baked lighting, so added lights must stay gains on top.

Related: [[azrael-tier-a-host-render]], [[azrael-render-audit]].

## v2 after the first live run (2026-10-05 10:25)

Josh on v1 (room 0.70, +0.90, 10-24 deg, range 600): "a vignette effect but not much else". A 24-degree
cone fills a view that is 25 degrees tall. v2: TWO LOBES -- hot spot 4-11 deg + corona (`LampHalo` 0.22
out to 30 deg) + spill 0.04; room 0.62, power 1.25, range 380, table 64 levels to gain 2.0; and the
beam TRAILS the view (`-LampLag` 0.12 s: a world-space direction eased toward the camera forward,
projected to `Raster.LampCx/LampCy`; snaps if >20 deg behind). Offline: a clear hot spot on a near
wall, faint across a big room. Not yet seen in game.

## v3 (2026-10-05 10:30) -- Josh's call on v2

"Pretty cool but makes the game very dark. Expand the lit area to the previous view, which will
enhance that vignette feel, but keep every other effect." v3 = v1's wide beam (10-24 deg, now the
`LampHalo` lobe at 0.60 of the lamp, `-LampHaloInner/-LampHaloOuter`) at room 0.70 and range 550,
with v2's hot spot (4-11 deg) and 0.12 s lag kept. He LIKES the vignette feel; do not remove it.
He also asked about real-time shadows on characters and geometry -- answered: feasible on the
host with a shadow map from a light that is not at the eye; not started.

## LAMP SHADOWS built (2026-10-05 10:53), not yet seen in game

Josh chose the offset-lamp route. `Raster.SetShadow(depth, size, focalPx, ox, oy)`: a second Raster
(640x640, fov 64) draws the POSED geometry from eye + right*ox + up*oy with the CAMERA'S orientation,
so lamp space = view space minus a constant and the lookup is `(x/z)_lamp = (x/z)_eye - ox*(1/z)` --
no per-pixel matrix. 4-tap compare (bias 2% in 1/z), averaged, through the lighting dither; shadowed
pixels lose the lamp term only. Offline (MINEHEAD): slivers on the LEFT of pillars and the cart, clean
edges, no acne; shadow map ~1.3 ms + ~0.5 ms in the picture. As predicted the shadows are slivers:
offset (16,10) changed 0.9% of a frame, (40,20) 1.3%; default set to (30,14). Switches `-NoShadows`,
`-LampOffsetX/Y`, `-ShadowSize`. Trap hit: the session-state init line nulled `\` AFTER it was
created (caught by grep before shipping).

## Shadows v2 (2026-10-05 11:05) -- after Josh saw v1 in game ("This is fantastic")

His three notes and what was done (built + offline-rendered, NOT yet seen in game):
1. "Assume the lamp is mounted in the centre of the visor, the left offset of shadows feels off."
   A centred lamp casts nothing; straight-up offset (0,22) was tried and vertical things cast
   NOTHING (shadows hide behind their casters: 0.2% of a frame). So: a symmetric PAIR, +/-24
   sideways and 8 up, half the light each -> half-shadow fringe on both sides.
   `Raster.SetShadow2`, `-LampSingle` for one lamp, `-LampOffsetX 24 -LampOffsetY 8`.
2. "Slivers overlay geometry without the geometry affecting the shadow" and
3. "doors cast a shadow, the walls near them do not (floating door shadow)". Two real causes:
   the shadow map was a SQUARE 64 deg against a 78 deg wide view (outer seventh of the screen each
   side unshadowed) -> map now has the picture's aspect, 58 deg tall (964x560 each); and the lamp
   view culled back faces, so one-sided walls cast nothing -> lamp views draw with culling OFF.
   Because every face now casts, each lamp is kept inside the room: `Raster.RayDistance` from the
   eye toward the lamp, stop 4 units short (a 60-unit tunnel has 15 of headroom).
Offline: symmetric fringes on pillars/cart/rails in MINEHEAD; shadows touch 0.8-5.9% of a frame;
two lamp views ~2.5-3 ms + ~0.5 ms in the picture (render ~7 ms total).

## Tuning round (2026-10-05 11:15): Josh on the lamp pair -- "Such an improvement!"

Asked: room level 70% "rather than 62%" (it ALREADY was 0.70 since v3 -- told him, left as is); hot spot
80% wider (4-11 -> 7.2-19.8 deg); shadows "a touch darker" and tapering with distance. Added
`ShadowDark` 0.30 (full shadow drops the ROOM level by that fraction, not just the lamp) and a
distance fade (`ShadowNear` 140 full, `ShadowFar` 900 gone; `_sfadeTab` by depth). Not yet seen.

Correction same round: Josh WANTS the room at 0.62 (darker, deliberately, to strengthen the vignette) together with the wider hot spot. Default `-LampRoom` is now 0.62. Do not "fix" it back to 0.70.

2026-10-05 11:30: Josh "looks great"; asked brighter centre + inner hot spot 20% wider. Power 1.25 -> 1.60 with halo 0.60 -> 0.47 (wide beam unchanged at ~0.75, hot spot 0.45 -> 0.78), inner 7.2 -> 8.64, outer 19.8 -> 21, light table 76 levels to gain 2.4. Not yet seen.

2026-10-05 11:40: FLASHLIGHT KEY. F toggles the lamp, HOST-side: `tools\Keys.cs` (GetAsyncKeyState + foreground window pid == DOSBox pid), edge-detected in the watcher, 0.14 s fade of LampPower, shadow passes skipped when off. `-LampKey` (VK code, 0 = none), `-LampStartsOff`. No game patch (8 overlay bytes free; the game's key handler 0x12B88 has no compare for F/f/scan 0x21). Not yet seen. Trap: a `'@` inside a here-string ends it -- nested Add-Type here-strings cannot be pasted through one; use a .cs file.

2026-10-05 11:45: TWO ROOM LEVELS (Josh's idea, "Perfect" on the F key). Lamp OFF -> `-LampRoomOff` 0.78 (not too dark to play); lamp ON -> `-LampRoom` 0.54 (darker surround), blended by the same 0.14 s fade. Power 1.60 -> 1.68 and halo 0.47 -> 0.495 so lit areas are unchanged (centre 2.22, wide beam ~1.44 either way). Not yet seen.

2026-10-05: Josh: flashlight-ON view "is perfect" (room 0.54, power 1.68, halo 0.495, spot 8.64-21, pair +/-24/8, ShadowDark 0.30, fade 140-900) -- DO NOT retune it. Flashlight-OFF room level set to 0.82.

**2026-10-13 (Josh): the flashlight STARTS OFF** -- "start the game with the flashlight off. Later I will add more 'visibility low' flashlight suggestions." Off when the watcher starts, and switched off again when a NEW game boots (BootHd.Mode -> live, not `IsReboot`: a load keeps the player's choice). F turns it on. `-LampStartsOn` = the old way. The room 'visor' readouts (MINEMAZE: Press F for Headlamp) are how the player learns the key.
- **Flashlight switch sound (Josh, 2026-10-15):** "the tile footstep is actually perfect for the sound of the flashlight turning on/off" -- he listened to exported tile steps (Desktop\RaptorMod tile steps) and chose "run 3" for ON and "run 4" for OFF = `Footsteps.Step(Tile, run: true, leftFoot: on, seed 1011 / 1012)` (`LampOnSeed`/`LampOffSeed`). `Footsteps.LampClick(on)`, called by Watch-HostRender `Invoke-LampClick` on the F key's toggle only (not the automatic off at a new game); through `$script:steps` (the game's effects level) or, before/without footsteps, its own Footsteps instance. Verified sample-exact against the files he heard.
