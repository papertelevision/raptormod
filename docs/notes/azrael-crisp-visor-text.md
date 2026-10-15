---
name: azrael-crisp-visor-text
description: "Visor text (scan readout, echo tooltips, badges, visor note, vitals, system menu, memory core) goes through ScanWire.cs Crisp: whole-pixel font sizes and positions; the card's labels are copied texel-for-pixel."
metadata:
  type: project
---

Josh, 2026-10-15: "Any reason why fonts are blurry in these visor scans and other visor text?"

**Two causes, both half-pixel smears:**
1. **GDI+ text at fractional sizes and places.** Sizes were shares of the view (`vr / 58` = 26.48 px) and text sat at centred/scaled fractional positions. GDI+ only hints at a WHOLE pixel size and only puts stems on pixels when a glyph starts on one. The boot hit the same thing: [[azrael-boot-text-rasteriser]].
2. **The card blended the label images between pixels.** FS_PRESENT `labelOver` (ScanTag / ConvTag) and `labelsOver` (echo tooltips) sampled with `texture()` at fractional origins (centred badges, panel-relative y, 3D-projected tooltips).

**Fix (2026-10-15):**
- `ScanWire.cs` `static class Crisp` (top of the namespace): `Crisp.Font(em, style)` rounds the size; `Crisp.Text(g, s, font, brush, x, y[, fmt])` rounds the position. EVERY font (24) and DrawString (44) in ScanWire.cs was switched to them. **New visor text: use Crisp, never `new Font(...)` / `g.DrawString` directly.**
- FS_PRESENT: `labelOver` / `labelsOver` use `texelFetch` at `floor(wp) - floor(origin + 0.5)` (one texel per window pixel). The atlas row is `int(L.w + 0.5) * cellH`.
- Checked: before/after crop at 4x shows one-pixel stems instead of two-pixel smears.

**Not changed:** Panel.cs (HUD log text) and BootHd.cs. The game picture itself is 1:1 with the window (2562x1536 on Josh's 2560x1600, 144 dpi), so the 3D view is not resampled.