---
name: azrael-host-fov-calibration
description: "The host renderer's vertical FOV is 50, MEASURED against the engine's own frame - not the 60 that was assumed in five tools. Plus the mask recall/precision method that found it, and why profile correlation could not."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-04T04:15:09.505Z
---

Measured 2026-10-04 against the `opening3` capture (CORICORI, 1600x928).

## The number

**Vertical FOV = 50.** Every tool defaulted to **60**, which was an assumption that had
never been checked and was carried into `Compare-Reference`, `Render-Demo`,
`Render-Offline`, `Start-HostRender` and `Tune-Lighting`.

Sharp, unimodal peak — this is not a fitted curve:

| fov | 47 | 48 | 49 | 49.5 | **50** | 50.5 | 51 | 52 | 53 | 60 |
|---|---|---|---|---|---|---|---|---|---|---|
| recall | 61.8% | 70.3% | 81.6% | 90.1% | **91.5%** | 83.0% | 77.6% | 70.0% | 64.6% | 55.8% |

The horizontal profile shift also lands on **exactly 0** at 50, which is an independent
confirmation from a different statistic.

## Why it mattered more than it sounds

At 60 the host painted a lit vaulted **ceiling the engine does not show**, which read as
"the lighting is wrong" — and every lighting comparison before this was therefore fitting
tone to misaimed geometry. Check alignment BEFORE tuning anything tonal.

## HOW to measure it: mask overlap, not profile correlation

Reduce both frames to "is this pixel drawn" (palette index != 0 in both the engine's own
capture and the host's output — no luminance threshold needed) and compare per pixel:

* **recall** = share of the ENGINE's drawn pixels the host also draws
* **precision** = share of the HOST's drawn pixels the engine also draws

recall near 1 with low precision = host is a SUPERSET: aimed right, drawing things the
engine culls. Low recall = genuinely misaimed.

**Cross-correlating row/column profiles does NOT work here** and wasted a pass. A
corridor's row profile is smooth, so correlation sits near 0.6 at *many* shifts and the
"best" one jumps around (-395, -245, -305, -271, +460 across neighbouring FOVs) — it
cannot distinguish misaimed from merely drawing-more. Also: a best shift exactly equal to
the search limit means the search was clamped, not that a shift was found.

Tool: `tools\Tune-Geometry.ps1`, with the loops in `tools\Align.cs` — a per-pixel `-ne 0`
over 1.48M elements in PowerShell throws "Could not compare 0 to 0 0 0 ...", which is the
same family of trap as [[azrael-powershell-silent-traps]].

## Where it now stands

With the aim corrected, recall 91.5% / precision 43.7%: **the host draws ~2.3x as many
lit pixels as the engine** (40.9% coverage vs 19.5%). Fog cannot close that — the best
sweep settings overshoot to 99.2% dark against the engine's 94.2%, and reach 0.00% bright
against its 0.3%, i.e. they kill the highlights to lose the coverage. That gap points at
**draw distance / culling**, not attenuation, and is the open question.

Lighting does now measurably matter, where the old metric said it did not: no-lighting
scores 0.4447 vs 0.2581 for the best lit setting. The old sweep's 0.0001 margin came from
(a) excluding the background, which made it blind to coverage — the actual difference —
and (b) cropping the top strip, which hid the ceiling symptom. Both corrected in
`Tune-Lighting.ps1`.

Related: [[azrael-tier-a-host-render]], [[azrael-camera-transform]], [[azrael-xaf-scene-format]]
