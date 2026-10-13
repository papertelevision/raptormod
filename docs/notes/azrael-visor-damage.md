---
name: azrael-visor-damage
description: "Damaged visor (2026-10-10): health-driven scratches/dirt/cracks/broken corner + hit static + vitals ECG monitor, all in GpuRaster's PRESENT pass (FS_PRESENT) from ScanWire.cs VisorDamage. Offline-tested, not yet seen in game."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-10T02:41:05.357Z
---

Josh (2026-10-10): static on each hit; more damage as health falls (scratches and dirt, then cracks, then a broken corner near death); a small heart-rate signal near death "just like in the intro"; "really sell the idea that you're wearing an operating system visor".

- **Where:** the card's FINAL present pass (`FS_PRESENT`, `PresentPass`), which serves both PresentGpu and PresentPicture.
  - A CPU decoration would force the readback path every frame at low health. Never move the persistent damage there.
- **Layer:** `VisorDamage.Build(level, w, h, seed, viewFrac)` runs on a Task, 25-60 ms at 1080p. It produces:
  - a premultiplied paint layer;
  - a half-size fx layer: R crack field (refraction via its gradient), G grime, B dead display, A glitch mask.
  - Elements are seeded (Seed 7331). Each has a threshold in damage space (damage = 1 - health), and crack systems GROW along their own lines, so the glass is never re-dealt:
    - dust 0.03+, scratches 0.05+;
    - claw rake 0.42;
    - impacts 0.30 / 0.45 / 0.58 / 0.68 / 0.80;
    - partial web rings at threshold + 0.1;
    - dead pixels 0.55+;
    - broken top-right corner 0.82 (dead LCD: stuck columns, corrupt blocks, ink bleed with a rainbow front).
  - The layer is rebuilt at 1/40 steps. Lighter = a teal repair sweep (two texture slots, `VisorSweep`).
- **Hit:** `Hit(strength)`, ~0.42 s: torn bands, RGB split, static, interlace dropout and a 50 ms red flash. Below 50% health, small random tears also occur on their own.
- **Near death (damage >= 0.75):**
  - a VITALS // CARDIAC monitor above the damage badge: the boot's ECG shape, 108->178 BPM, irregular, dropped beats, plus SUIT INTEGRITY with a bar;
  - a red edge pulse on each beat; colour drains from damage 0.55.
- **Watcher:**
  - `$script:hpFrac` = health / max(1000<<16, the most seen). It is -1 while the boot covers the view, since a new game's health isn't set yet.
  - Step runs before each present when `$glp` is true. A hit calls Hit(0.45 + 4 x the fraction lost).
  - Switch `-NoVisorDamage`.
- **Offline test:** scratchpad `visor-damage-test.ps1` (GpuRaster.PresentOffscreen) at 1080p. TRAP again: a `$Pic` param IS `$pic`.
- **Round 2 (Josh, 2026-10-10):**
  - Fine cracks "a bit too visible", so they are at about 60%: core alpha 125, dark 70, glow 12. Scratches are at 40-90 alpha.
  - He LOVED the red, dead top-right corner, so it now breaks at HALF health (`CornerFrom` 0.5). It starts at 45% size and grows to full by damage 0.92, scaled about the corner by a Graphics transform, so it is the same break.
  - The red edge pulse and the colour drain run from damage 0.5. The heart runs from there too (88 -> 178 BPM).
  - Quiet beeps: VisorDamage.Sound is its own BootSound at 0.33 x the boot's Volume (about -28 dBFS) and beeps on each beat while the monitor shows. `-NoBootSound` silences it.
- **Round 3 (Josh, 2026-10-10):**
  - **Death flatline:** health exactly 0 starts it. Over DeathSeconds 6 the heart slows from its rate to nothing, the beats weaken and get dropped, then comes the flat line plus `BootSound.Flatline(4 s)` (quiet, its own sound).
  - The monitor reads CARDIAC FAILURE -> NO PULSE with "--" BPM. `VisorDeath` greys and dims the display and raises the scanlines and grain.
  - A load ends it. A health of -1 (the boot) also counts as alive. The watcher logs "the player died".
  - **The corner breaks like real glass:** a K6 x J7 polar web of pieces from the corner whose jagged edges are shared (`Jag`, seeded per edge key).
    - Each piece has a break threshold that is monotonic outward from CornerFrom, so the hole grows a piece at a time.
    - A piece cracks round its edges 0.07 before it goes. Boundary edges get the glass edge, chips, bleed and outward cracks, seeded per edge.
    - The old scaled single break is gone.
  - **The teal sweep line is REMOVED** (with health regenerating it ran constantly). Mending is now a 1.3 s crossfade between the two layers.
  - In its place there are always-on faint scanlines (a 360-line pitch), a slow brightness roll and grain, all scaling with damage. At 85% health they are barely visible.
  - GDI+ DrawLines throws "Parameter is not valid" on some corner point lists, so DrawCrack now guards against fewer than 2 points, NaN or huge coordinates. The exact cause was not found.
- **Not done (could offer):** damage on the HUD panel itself.

Related: [[azrael-visor-note]] (badge + health address), [[azrael-gpu-renderer]], [[azrael-optimisation-pass]], [[azrael-gpu-boot]].

**The break moved to the TOP LEFT (Josh, 2026-10-10):** the system menu folds out on the right and the break hid it after a death. `VisorDamage.BreakLeft = true` mirrors the glass: the corner web anchors at (-2,-2), its pieces go out across the glass, and the claw rake (placed away from the break) goes to the right. The same seed, so every effect is kept. Nothing in FS_PRESENT is corner-specific: the red/inky dead display is the bDead field, which the corner block draws. The vitals monitor (lower left, top edge at about 0.68 vr) stays clear of the fully broken corner (about 0.64 vr deep at the edge). Not addressed: the memory core (left panel, READ LOG after a death) can sit under the break near death.

**Damage fades behind open menus (Josh, 2026-10-10).**
- `VisorMenu.ClearRects`: the open panels (memory core / reading / writing, system menu) as 0..1 picture rects, set in DrawOver; null when none is up.
- `VisorDamage.Menus` (the watcher sets it each frame) eases `_clrK` in over 0.2 s and out over 0.3 s, keeping the last rects while it fades.
- `GpuRaster.VisorClear` / `VisorClearK` -> uniforms uClr0/uClr1/uClrK. FS_PRESENT mixes back to catmull(s0), the untouched picture, inside the rects with a 14 px soft edge.
- Offline: scratchpad `visor-clear-test.ps1`.