---
name: azrael-frame-cost
description: "Measured per-effect cost of the true-colour host renderer (2026-10-05), and that frame interpolation was removed at Josh's request"
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-06T03:18:39.721Z
---

**Frame interpolation (re-projection between frames) was REMOVED on 2026-10-05 at Josh's request**
("the characters are barely animated so i say remove it"). `Overlay.SubmitRgb` is back to
(rgb, pw, ph, minShare); no `Reproject`, `WarpHz`, `-NoWarp`, `SpareDepth`, `Raster.SetDepthBuffer`.
Do not re-propose it.

**What a frame costs** (offline bench `cost-bench.ps1` pattern: the watcher's own Get-Room /
Set-RoomAtmosphere pulled from the AST, 2562x1238, 29 draw threads; confirmed against Josh's
in-game log of the same evening):
- Helmet-lamp shadows are the heaviest effect: 2 shadow maps 1656x800 = 5.6-6.6 ms "lamp views" +
  ~4-5 ms of per-pixel lookups (soft edge ~2-4 of that). Flashlight ON = ~25 fps in room 1,
  OFF = 42-52 fps, in Josh's own log. 512-tall maps save ~4 ms.
- Picture size: room draw 18 -> 10 ms going 2562x1238 -> 1920x928 (everything is per pixel).
- Water reflection: ~6 ms, only in water rooms (SPAROOM).
- Cheap: fog ~1 ms, dust 0.1-0.2, torch + its 512 shadow view ~2-3, smooth models/shading <=1.
- Off the loop but on the same CPU: sharpen 11-16 ms on N/10 threads + compose 4-9 ms; it drops
  pictures when the loop goes faster than ~50 fps.
- Script overhead outside draw: ~5-7 ms a frame (wait 2, pose 1, loop start 2, other 1).

**Shipped after the report (Josh's choice, 2026-10-05):** ONE lamp shadow map (`-LampPair` brings
the pair back) and `-ShadowSize 512` (was 800). Bench: SPAROOM 25.0 -> 18.7 ms, CORICORI 17.9 ->
13.4 ms a frame. Smoother models removed the same evening ([[azrael-smooth-models]]).

**Why:** Josh asked "what is the heaviest" at ~30 fps; these are the numbers to answer from.
**How to apply:** fps work starts with the lamp shadows (single map, smaller map) or the draw
size (-TcMaxPixels), not fog/dust/smoothing. See [[azrael-true-colour]], [[azrael-helmet-lamp]].
