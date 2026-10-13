---
name: azrael-system-menu
description: "Visor system menu (host-drawn over the game's fold-out; the game's hot spots MOVED IN GUEST MEMORY at run time so retro keeps the old one), ESC = menu / E = log box (in-place key-handler patch, 0 cave bytes), mouse wheel over the log. Installed 2026-10-09, not yet seen in game."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-10T02:29:20.698Z
---

Josh (2026-10-09): ESC opens and closes the system menu; E expands and collapses the log; mouse-wheel scrolling over the log; and "do away with the rendered system menu for this GPU mode (leave it for retro) ... rebuild it in the same style as the new save/load menu".

- **RE:** `AztMod\docs\system-menu-RE.md`, from a subagent.
  - The fold-out is drawn at screen 1085..1599 x 89..513. Commands: 7 SFX toggle, 8 music toggle, 9/10 slider drags, 11 SAVE, 12 LOAD, 13 QUIT, 16 OK (screen 3 only; the SAME OK confirms memory-core picks).
  - Levels are words at 0x14693E (SFX) / 0x146940 (music), 0..127. Toggles at 0x14693A / 0x14693C.
  - Slider drag maths is game code: track x 1100..1352, level 127 at the LEFT end.
- **Keys (Build-AztMod, after "log box repainted"):** six in-place rewrites in the KeyDown handler, using its duplicate epilogues.
  - ESC at 0x13713 issues cmd 5 only where ESC did nothing before.
  - 'e'/'E' (unbound) call the box blob's `ABC_toggle`, a new zero-byte label before AztBoxClick's xor. Both rel32s come from `$t.Labels`.
  - Manifest 426 -> 432 patches; diff = only the six. Disassembly checked from a hand-patched copy (Test-Patch deletes its own).
  - Backup in `AztMod\backup-pre-keys-sysmenu-20261009`. AZRAEL.BAT and the movies were unchanged by the install.
  - Caveat: holding E repeats the toggle.
- **Host menu (`VisorMenu` in ScanWire.cs, shared with the memory core):**
  - `DrawPanel` (glass, degauss, open line) now draws both panels; the cursor is drawn once, last.
  - `SetSys(...)` is fed by Step-MemCore (block 0x1523D6 + 8 bytes at 0x14693A).
  - Layout (static `Sys*` rects):
    - QUIT at top right; WRITE LOG / READ LOG;
    - MUSIC and EFFECTS sliders on the game's track x, MAX on the left, segments lit from the right as the game's bar, plus ON/OFF toggles;
    - a CONFIRM row whenever the game's OK is live.
  - `HideAll` is the union hide rect. Switch `-NoSysMenu`.
- **Clicks: `Set-SysMenuHot` (watcher)** rewrites 22 polygon records (screens 1-3) in GUEST MEMORY to the Sys* rects.
  - Each record's vertex count and cmd are checked first; vertex counts are kept (rect + repeats). QUIT has 3 vertices: a right triangle whose spare half is off-panel.
  - `Restore-SysMenuHot` runs in Close-TrueColour. **Not the build:** a build remap would break retro's clicks (the memory core's remap did).
  - Code constants were NOT touched at run time: DOSBox's dynamic core may cache translated code.
- **FIRST IN-GAME TRY: hover worked, NO CLICK did** (the log said all 22 records were moved).
  - **CAUSE:** the game hit-tests RUNTIME region objects, not the static records. Screen objects 0x164DAA / DB8 / DC6 hold {word count, dword -> region pointers}; each region is {word n, dword -> points, word x0 y0 x1 y1 (exclusive)}.
  - The BOX is tested first (0x336F8) and was computed at start-up, so it still sat at the old place.
  - Fixed: Set-SysMenuHot also finds each region whose points are a moved record (same memory, or a copy matched by content). It writes the points if copied, and a new box keeping the old exclusive edge. All of it is restored on the way out.
  - Proven with a fake-guest test (scratchpad `syshot-test.ps1`, 32-bit): 22/22 boxes right, restore byte-exact.
  - **LESSON: moving a hot spot at RUN TIME = move its region box too.** The build-time remaps never hit this because the boxes are computed from the patched records at start.
- **Look round 2:**
  - The panel's right edge = PX(content right) + the left padding in PICTURE px. The wide mapping stretches the last game columns, so x 1599 sat far right of the buttons.
  - The top right bends down by SysBend 64 game px, easing to none 55% of the way down (`BendAt`). Glass, clip and bracket all follow it.
  - QUIT moved to x 1416..1525.
- **Look round 3:** the bend is REMOVED (SysBend 0; Josh). The panel is bigger round the same controls (SysX0 1063, SysY0 67, SysY1 533), with the header at screen y 107, so the content has room inside the brackets.
- **Round 4 (Josh: top level with the memory core):**
  - Panel SysY0 140 (= the memory core's PanelY0) .. 606, header at SysY0 + 40. Every Sys* rect moved +73; the slider tracks keep the game's x.
  - `HideAll` now always covers the game's whole fold-out (1085..1599 x 89..513) as well as the panel: the game's art would otherwise show above the moved panel.
- **Round 5: both menus 56 px left (Josh: equal space left and right when both are open).**
  - Build `$MENU_SHIFT = 56` (defined above the SYSMENU block) drives `$SYSMENU_VX` (the fold-out moves to x 1029 -- art, plates, slider R 1352 -> 1296, overlay AztSlider0/1 bar X 1100 -> 1044) and the memory core's `$SLOTLIST_*` hot spots.
  - VisorMenu x numbers moved by the same 56: memory core 34..954; Sys* rects; tracks 1044..1296; fold-out hide 1029..1543.
  - Manifest diff: only fold-out x, slider R, hotspot screens 1-3, plus 2 overlay bytes.
  - The picture mapping is a plain scale (Overlay.EnsureSize), so game-px balance = display balance: about 34 / 35 px each side.
  - Code constants CANNOT be patched at run time: DOSBox core=dynamic caches translated code.
  - Backup: `AztMod\backup-pre-menu-shift-20261009`.
- **THE SAVE SHOWED THE OLD 8-BIT SCREEN (Josh):**
  - The OK handler saves with no frames (file I/O + a 3 s wait). The overlay's StaleMs (400) hid the window ("window hidden: stale 1" in watch.log), uncovering DOSBox.
  - Fixed:
    - `Overlay.HoldFreshUntil`, renewed while VisorMenu.Writing;
    - the watcher keeps the undecorated GPU picture (gpuClean) while a visor panel shows;
    - the sync-timeout branch (`if (-not $released)`) calls **Repaint-HeldPicture**: Step-MemCore + DecorateOnly + PresentPicture of that clean picture. The writing screen therefore animates through the stall (sync limit 30 ms while writing).
  - Title is now "COMMITTING LOG TO MEMORY..." / "LOG COMMITTED.".
  - Not verifiable offline (needs GL + the real stall).
- **DEFAULT VOLUMES (Josh, 2026-10-10: music 50%, sound 100%):** Build-AztMod `volume-defaults-14693E` writes the obj2 data words 0x14693E = 127 (SFX) and 0x146940 = 64 (music). Stock was 100/100, and nothing saves them with a game. Manifest 432 -> 433. Backup: `AztMod\backup-pre-volume-defaults-20261010`.
- **Wheel:** `WheelHook` (WH_MOUSE_LL on its own thread, in Panel.cs) feeds Panel.Wheel. Over the recess +30 px (game cursor), it moves aztLogScroll 42 px a notch.
- **Log margins:** right = left (the game's own inset, dx).

Related: [[azrael-memory-core]], [[azrael-hud-vector-text]], [[azrael-panel-button-rects]].

- **QUIT = straight to the desktop in the GPU mode (Josh, 2026-10-10: new credits will be built; retro keeps the old ones).**
  - QUIT -> OK sets word 0x152176 = 1 (0x2D09A; the 'q' path 0x135A7). The main loop returns at 0x16086, then the game rolls CREDITS.TXT (0x1FC6C from 0x162A7) under the GPU picture.
  - Watcher `Step-QuitWatch`: on 0x152176 == 1 it closes DOSBox (CloseMainWindow, else Kill).
  - Skipped for the game's ENDING (exit code 0x152908 == 0x66: outro movies, then credits) and under -Retro.
  - Other writers of 0x152176 (0x15313, 0x17488) are in-game events.
- **ESC dead after loads (2026-10-10):** the fold-out's direction 0x1523E8 was stuck at -1 with nothing moving. Guard-SaveList resets it after 1 s unmoved (see [[azrael-title-menu]] round 7).

## The confirm key's sheen (Josh, 2026-10-13)
"When a user clicks the quit button in the system menu, the 'confirm' button should become active but also have a revolving effect on its outline clarifying that the user needs to click it ... an in-universe style revolving 'sheen' that slowly revolves on the button's outline ... anytime the player needs to confirm something after an initial action in the menu systems." Built in teal (with the SAVE / LOAD small print teal), then thinner and slower, then: "switched back to the amber/orange color rather than the teal" -- the sheen is amber and the small print is its original dim amber again. **Checked offline (scratch harness), NOT yet seen in game.**
- The one confirm in the menus is the fold-out's OK key (`SysConfirm`: quit asking, or a slot / RESTART picked in the memory core's lists -- CONFIRM / COMMIT / RESTORE / RESTART). The title menu acts on a pick at once (no confirm step).
- `VisorMenu.Button(..., active)`: lit faintly (amber 0.14, 0.32 hovered) with no frame of its own -- its outline is the sheen's track.
- `VisorMenu.Sheen`: an amber rim (0.5, 1.2 px) and a head running round the outline once every `SheenSeconds` (3.0 s) -- a 38%-of-perimeter tail fading (power 1.8), a soft glow (5.5 px, 0.2) under a fine line (1.7 px), the head's first pieces in `AmberHi`; pieces split at the corners so it hugs the outline.