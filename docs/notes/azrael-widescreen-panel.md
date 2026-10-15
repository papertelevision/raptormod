---
name: azrael-widescreen-panel
description: "The full-width lower interface (Josh's ChatGPT art, 2026-10-06) - game copy + host true-colour copy from one fixed game-pixel mapping; how it is built, installed, and what is untested."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-06T19:03:39.902Z
---

BUILT AND INSTALLED 2026-10-06 ~15:00, NOT YET SEEN IN GAME (watcher 14:54:47, AztMod 419 patches).

**Source art:** `AztMod\design\incoming\hud\two_panels_reference.png` (top = unlit, bottom = all lit, 321 rows lower). Josh's other files there (magenta version, button sheet, expanded-log full panel, filler strip) are NOT used: separate renders that do not register with it. Prompt: `AztMod\design\widescreen-panel-prompt.md`.

**One mapping, fixed in GAME pixels (machine-independent):** game x = -160 + (artcol-17)*K, y = 1200 + (artrow-347)*K, K = 1920/2038. Art spans 1920 game px (exactly 16:10); every control inside 0..1599 (the game's mouse reach). Josh chose TRUE SHAPE (no stretch): body 194 rows of the 223 panel; hoses/humps above over black; bleed 28 rows over the view.

**Generator `src\Build-HudWide.ps1`** (replaces HudSkin/HudButtons/HudBox for this design): HUD3/HUDOFF rows 977+, HUDBOT.RES, hud-layout.json (+gaugeWellW, replay), NBUT*, BOXOFF/BOXON + hud-box.json (+extend 160), runs HudInv + HudBar, writes host art `art\wide\` (panel-off/lit.png at 2x via Real-ESRGAN, box-open.png, wide.json, modes.bin = NBUT sprites as DOSBox shows them, 6-bit DAC). KEEPS THE EXISTING PALETTE 1..53 on purpose: changing it (HudSkin) recolours 72 other PCX files (sysmenu, fonts...). Matte = only true black (sum<6) + slit closing; looser ate the hoses' shadows.

**Build-AztMod edits:** BOX_EXTEND from hud-box.json `extend`; GAUGE_W_MAX from layout `gaugeWellW`; replay BTN_X/Y from layout `replay` (clamped x<=1514 so the 86-wide sprite stays on screen; click test is x>=,y>= only); aztLogScroll appended to AztMod.overlay.sym (0x132998).

**Host `tools\Panel.cs`:** layered per-pixel-alpha window, game rows 800..1199 full width, own thread. Copies live rects (inventory, gauge, log recess) from DOSBox surface; mode lit = nearer of modes.bin OFF/ON; open box when word aztBoxBig (lin 0x511AF = CAVE2_BASE+15) or g_convList (obj2 0x152B1C) != 0; cursor by DIFFERENCE vs a reference taken while cursor (obj2 0x182D6C/E) is elsewhere; log scroll keys = host clicks writing aztLogScroll +-8. Overlay/GpuRaster got `HideRect` (game's drawings ignored there) = the open box rect. Watcher: Start-WidePanel at tc 'run', Stop in Close-TrueColour, `-NoWidePanel`, log line "widescreen panel: ...". Offline test: scratchpad panel-test.ps1 (Panel.TestCompose).

Results: text area 442 px wide (was 287; Josh wanted >=2x - limited by the art's screen), 144 rows closed / 304 open.

**Undo:** `AztMod\backup-pre-widepanel-20261006-1440` (art, manifest, sym, Build-AztMod.ps1), then Apply-AztMod -Install.

Open questions for in-game: cursor coords really game px? INVBACK2 (stock parchment, stretched) looks light in the dark screen; the open box shows the hose band above its bezel; 8-bit fallback = 4:3 crop.

## TEXT AREA = THE PANEL'S OWN MODULE, STRETCHED (installed 2026-10-06 ~17:00, watcher 16:54:23; not yet seen in game)
REJECTED first: Josh's separate ChatGPT text-area overlays (sheet in `design\incoming\hud\textarea\`) -- "huge compared to the rest of the interface"; separate renders never share scale. Don't go back to overlay images.
- `src\Build-HudKeys.ps1` lifts ONLY the round key column from textarea-collapsed.png, scales 0.51, pastes at art (1818,140) in both panels -> `two_panels_reference-keys.png` (now Build-HudWide's -Reference). Keys (art): expand 133..191, up 221..261, down 261..295, replay 295..335.
- Opening = insert copies of art row 205 (cable slot between expand and up keys; stretches like a cable). Game: BOXON = BOXOFF + 160 rows inserted (cut from the quantised panel copy, so closed is identical to HUD3); lift 0; expand toggle is the GAME's (frame-local icon rect, same both states). Host: Panel.Stretch moves the module's columns (art 1276..1817 top 140, 1817..1870 top 133) up by e*160 rows and fills with row 205, all from the base art -- no extra image. Scroll keys = host; replay = game (1514,1154).
- HideRect only while open/animating = frame x 1036 w 553 rows 817..976. Text = game recess 1:1, clipped to the uncovered height.
- Cursor: reference now refreshed every reading outside an 84 px box round the cursor; if too much differs in the box (screen changed under a resting cursor), the last learned cursor shape is used and the rest of the box heals (CursorHeals counter). Old version would paint an 8-bit square there.
- RUN TRAPS: both Build-HudWide and Build-AztMod need explicit paths or `-Command "& 'script'"` ($PSScriptRoot empty under -File); Apply-AztMod needs `-Install -Dest C:\Games\RaptorMod\game`.
- TEST TRAP: `& panel-test.ps1 | Select-Object -First 1` STOPS THE SCRIPT after its first output line; check LastWriteTime.
## SEE-THROUGH PANEL + 3D UNDER IT (2026-10-06 ~17:20, not yet seen in game)
Josh (4K 3840x2160 display now, s=1.8): panel top was cut, black behind the hoses and a dotted band beside the opened box -> "transparent wherever these black backgrounds are".
- Cut tops: host crop now art rows 62..351 (end caps/crests start at 68; 76 cut them). wide.json artY0 62.
- Dotted band = HUDTOP.RES's mirrored bottom sweep+haze (view rows 776..927, checkerboard index 54) -- NOT the panel. Build-HudTop `-NoBottom` drops the bottom half; top half verified byte-identical; Build-Art passes it.
- 3D UNDER THE PANEL: Overlay.ExtendRows (=223, set by the watcher before Start when the wide panel is on; -NoUnderPanel stops it) makes the window run to the screen bottom; Overlay.ViewRowsOf(ph) = picture rows that are the view; rows below map riy=-1 -> picture alone (GPU FS_COMP and CPU compose). Raster.ViewRows / GpuRaster.ViewRows = off-centre projection (centre at ViewRows/2, focal from ViewRows; VS gets uOffY = VH/H-1; lamp shadow depth views force uOffY 0). Verified: CPU view rows pixel-identical with/without (8 cameras), GPU coverage matches CPU. ~24% more pixels.
- Panel.SeeThrough: no black backing; cursor drawn on panel rows regardless of alpha. Host art edge: HudWide.SoftEdge (3 art px band, alpha from brightness 12..110) -- the true-black matte left a jagged black rim.
## BLACK BACKING BELOW THE VIEW (Josh, 2026-10-06 ~17:50) -- supersedes the see-through-below part
Josh: black rectangle behind the art from the viewport's bottom edge (game row 977) down, full width; NOT above it (the art rising over the view stays see-through). So the 3D-under-panel extension is now OPT-IN (`-UnderPanel`), default off; Panel.SeeThrough false -> opaque pass from 977 again.
- The "artifact above the opened box" was a BILINEAR LEAK: the hide test used only (ix,iy), so the row above / column left of the hidden box blended half of the box's edge pixels (a light outline). Fixed in GPU FS_COMP and CPU compose by testing (ix+1, iy+1) too; offline hide test: 0 px differ over the whole picture (was 858).
- New HideFromRow (Overlay + GpuRaster, uniform uHideFrom): game drawings from the panel's bleedTop (949) down are left out of the 3D compose -- the game's 8-bit HUDBOT copy showed through the art's soft edges. Panel.OwnFromRow = bleedTop: the cursor is drawn there by the panel regardless of alpha.
- Offline harness: scratchpad hide-test.ps1 (GPU compose with a fake screen + HideRect).- (17:58) Backing top moved DOWN to wide.json `backingTop` = GY(art 144) = 1009, just under both screen modules' top bezels (row 141) -- Josh: the black must not show above them; hose gaps above it are see-through. Panel.BackingTop.
- Risen module's top-left corner cut ROUND (textArea.corner: R 22 art px, tangent to the bezel's left edge col 1284 and top 140; MODULE_TOP now starts at col 1284 -- the crest/shadow left of it no longer rises). Panel.Stretch applies per-pixel coverage.- (22:36) "Black bar still too high" was NOT the backing: with the 3D stopping at row 977, the art's gaps between 977 and backingTop showed DOSBox's own 8-bit panel (black index 54). Default now: Overlay.ExtendRows = backingTop - 977 + 2 (34 rows, ~3% more pixels) so the 3D reaches the backing; Panel.SeeThrough only with -UnderPanel (full extension, no backing). LESSON: anything see-through in the panel window below row 977 needs 3D beneath it, or the 8-bit panel shows.