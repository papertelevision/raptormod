---
name: azrael-vector-cursors
description: "The game's 30 interaction cursors redrawn as animated vectors (tools\\CursorIcons.cs IconCursor, 2026-10-11): slot table 0x164B80 + i*18, names at 0x14714A, current 0x147588; bitmaps BLANKED in guest memory (not the hidden flag); own top window. Round 2: 'pointer hidden' is raised by EVERY blit (debounce it); the panel must be told the game draws no cursor (Overlay.GameCursorBlank). Round 3: every icon loops (play, 1.5 s rest, play); arrows start at once, bigger. Space = weapon out = no contextual cursors."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-11T23:30:00.000Z
---

Josh (2026-10-11): recreate the game's environment cursors "in animated vectors, similar in style to the chalice vector and the icons ... in the game menu". Examples he gave:
- the door arrows step forward or back;
- the "pick up" claw (wrench head) bobs up and down;
- the pinwheel spins one revolution on hover;
- "exact same representation" as the bitmaps.

**RE (R.EXE):**
- `0x2A2EA` loads 30 cursors: slot i = `mice\<name>.pcx` from the name table `0x14714A[i]`, into a 30x30 surface at `0x164B80 + i*18` (word w, word h, dword pixels; malloc 900).
- Order: pointer, active, look, blook, up, bup, pull, bpull, use, buse, rot, brot, use, buse, take, btake, push, bpush, pull, bpull, use, buse, down, bdown, scan, left, right, downarrw, default, bdefault.
- MICE files NOT loaded: BLEFT, BRIGHT, PHOTO, ROTLEFT, ROTRIGHT, UPLADR, DOWNLADR.
- Current cursor: dword `0x147588` = guest pointer to the slot's surface (slot = (p - (0x164B80 + d2)) / 18). Hot spot: words `0x14758E/90`. Position: `0x182D6C/E`.
  - SetCursor `0x3561D` (eax = surface) stores it; the draw `0x3544D` blits the bitmap at (cursor - hot spot) via 0x34818, so the window formula below matches the game exactly.
  - A conversation starts on slot 0 (pointer; 0x17A1F).
- The "B" set is teal and the same shapes, except: bdown -1 px x, btake +1 px y, bpull -1 px y, bpush -2 px y. ACTIVE = POINTER in red. DOWN is NOT an exact flip of UP; RIGHT IS LEFT mirrored (x' = 30 - x).
- **NOT one of the 30:**
  - a held item's picture ([0x182DB4], via 0x36BEB / 0x36CBD);
  - **0x15210C**, the game's own 30x30 surface built at start-up (0x10BD0). It is set for combat (word 0x14721C, 0x1324D), close-ups (0x16ACB) and 0x12A2F.
  - These stay the game's own (not blanked) and the vector window hides. They are the watcher's "readings of a cursor not one of the 30".
- **"Pointer hidden" word 0x147586 is raised by EVERY blit**, not just mouselook. 0x33F80, 0x3439C, 0x34818, 0x34C40 and 0x350CC each save it, set 1 while they draw, and put it back (0x350CC also runs inside the cursor draw). It is therefore up for a few ms of nearly every frame.

**How it works (CursorIcons.cs, class IconCursor; watcher starts it after the panel; `-NoIconCursor` turns it off; not with -HostPointer):**
- Shapes are traced as lines in each bitmap's own 30x30 grid (pixel centres n + 0.5). They are drawn in four passes: dark rim (the bitmap's outline), glow, core, hot centre line.
  - Inks: amber 0xFFB040 / 0xFFE3A6; teal 0x71DFD7 / 0xBEFBFF (the chalice's); red 0xFF6A3C for ACTIVE.
  - Fills: the eye's pupil, PULL's culet facet, USE's knob, the teal eye's dome.
  - Widths in grid units (round 2, bolder):
    - rim (2.6 + 1.7w) at 0.85;
    - glow (2.4 + 1.8w) at 0.27 x Glow (max 0.6);
    - core 1.7w at full;
    - hot line 0.65w at 0.8+.
  - At 2560 wide (u = 1.334 px) they read as clearly as the bitmaps (scratchpad cursor-true-scale.ps1).
- Animations, by the time since that cursor appeared (round 3: every one now LOOPS, see below):
  - pointer: the arms lock in; ACTIVE also throbs.
  - look: opens from its base, the iris drifts, blinks every 4.6 s.
  - blook: a gloss sweep.
  - up/down: chevrons light in turn, then a forward wave.
  - pull/push: comes toward you / goes away, then leans that way again.
  - use: the lever is thrown from an 18 deg tilt, the arrows spread and nudge.
  - rot: ONE revolution (0.95 s).
  - take: drops in, then bobs.
  - scan: the rings open out, then a pulse runs outward.
  - left/right/downarrw: slide in, then nudge.
  - default: a slow breath only, since it is up most of the time.
- **Fading:** a 0.08 s fade-in ONLY when the cursor comes up from nothing (hidden > `AppearAfterMs` 400). One shape changing to another shows at full strength, with the new shape's own animation. The first cut's "flicker-on" is gone.
- Placement comes from Panel.GetPlacement via `IconCursor.PlaceBy(pn, 'GetPlacement')`. PowerShell 5.1 cannot cast a PSMethod to a Func; that is PS 6+.
  - The window sits at `origin + cursor*s - hot*u - margin`. (Panel and Overlay share s and the origin; the overlay's compose maps put the view at the same scale. Only the visor's top band rows, the top 9% of the view, stretch the game's columns.)
  - It is shown when slot >= 0, mouselook (0x147218) is off, 'pointer hidden' has stayed up for less than `HiddenHoldMs` (150 ms), and the game is in front.
- **The game's bitmaps are blanked in guest memory** (zeros = see-through). This is a data write and leaves hover and picking alone; holding the hidden flag broke both ([[azrael-host-pointer]]).
  - Re-checked every 400 ms: a reloaded bitmap is blanked again with its new picture kept.
  - Restored on Dispose, and after 1 s without placement.
- **`Overlay.GameCursorBlank`** is true while the cursor in use is one of ours AND blanked, i.e. the game draws nothing at the pointer.
  - Panel.UpdateRef then takes the screen as it is: the reference is the whole screen, nothing is learnt as "the cursor", and Panel.Cursor() draws nothing. PxNoCursor skips the box.
  - Counter: `Panel.BlankCursorReadings`.
- **Z-order:** `Overlay.TopSlot()` returns `Overlay.CursorWindow` when set, so every host window goes below the cursor. The cursor itself uses `Overlay.CoverSlot()` (just below the title cover).
- VisorMenu's "redraw the game's cursor over the panel" now draws a blank image; the vector window is above it anyway.
- Watcher log: "game cursors: drawn as animated vectors" at start.
  - "vector cursors: ..." prints at the first show, then every 25 shows, and when blank/restore counts change.
  - It includes the 'pointer hidden' rises / holds and the panel's no-cursor readings. Healthy play = shows ~ times you leave mouselook, NOT dozens a second.

**ROUND 2 (Josh's first session, 2026-10-11 16:10): "off center, and flickering, and very faint ... in dialogue I could no longer select any dialogue options".**
- **ONE CAUSE for all three looks.** watch.log showed "shown 135 times" within 4 s, with only 247 renders in all.
  - The window hid on every blit's momentary 'pointer hidden' (~30 Hz).
  - Every return restarted the appear animation: fade from 0 plus flicker-on, with the arms 3.5 units out, the claw 4 up and the arrows 4 back.
  - So Josh only ever saw the first frames: faint, flickering, and mid-slide (= "off centre").
  - Fix: the 150 ms debounce, plus no restart for hides < 400 ms.
- **DIALOGUE:**
  - The panel keeps a reference of the screen in an 84x84 box round the pointer (Panel.UpdateRef). It used that box to tell the game's cursor from the text under it, and decoded the text from it (PxNoCursor, ScreenInk / Agree).
  - With the game's cursor blank, nothing was ever "learnt". When the text under a RESTING pointer changed (a new options list), it took the `!_haveLearned` return, so the box was never refreshed and showed the OLD list there. (Small changes were instead learnt as the "cursor" and held.)
  - Offline (scratchpad panel-stale-box-test.ps1): 2032 of 2880 changed pixels read OLD before the fix, 0 after.
  - Together with the near-invisible pointer, that made a clicked choice look like nothing happened.
  - The game's own click path (event 0x18 -> 0x2D0B5 -> AztConvHit) does not depend on the host.
- Offline tests:
  - scratchpad `cursor-flicker-test.ps1` (fake guest, 64-bit):
    - 96 blit blips -> shown stays 1;
    - a 300 ms hold -> hides once, back without restarting;
    - 600 ms mouselook -> appears afresh;
    - held item -> panel flag false;
    - Dispose -> flag false, 30 restored.
  - hudconv tests 1-4 unchanged (0 fallbacks).
- Josh after round 2: "those look great".

**ROUND 3 (2026-10-11): THE LOOP + livelier arrows.**
- Josh: "for the arrows, let's have them animate a bit earlier, and a bit more obvious so a touch more movement". He also asked that all the icons animate more than once: "animate, 1.5 second pause, animate, in a loop".
- `Play(ta, start, act, out round)` gives the time into the current play. Plays are `act + LoopPause` (1.5 s) apart, and `round` alternates variants. Everything runs on the time since the cursor appeared, not the global clock.
- **Arrows** (up/down chevrons, left/right/downarrw):
  - The first play starts AT ONCE (0.1 / 0.22 s), with the appear.
  - The chevron wave is 2.6 units (was 1.6, waiting on a 1.3 s clock).
  - The single arrows give a push of 3.0 plus a second push of 1.2 (was 1.8).
- **Every other icon:** the appear is the first play, then its action every 1.5 s:
  - pointer: re-locks (arms spring out 2.4, snap in);
  - look: glances one way and back / blinks / the other way...;
  - blook: gloss sweep;
  - pull/push: leans (10% / 1.2 units);
  - use: lever pulled back 14 deg and thrown again, arrows nudge 1.4;
  - rot: one revolution;
  - take: two bobs (2.0 + 1.0);
  - scan: the pulse runs out.
  - `default` keeps its slow continuous breath (it is up most of the time); ACTIVE keeps its throb.
- Redrawn every 8 ms while up (`RedrawMs`). `Still()` is gone.
- Offline: scratchpad `cursor-loop-sheet.ps1` (12 icons x 17 times, two plays); flicker test unchanged.

**"Could not pick up the key in the well" (same session) = THE WEAPON WAS OUT, not the cursor.**
- Both clicks there were SHOT RECORDs with C1 (weapon word 0x14721C) and L1.
- The game's SPACE key toggles the weapon. It is 0x136D8 `cmp al,0x20 -> 0x131E1`, the toggle itself at 0x13235. It is skipped while the fold-out, mouselook (0x147218), a close-up, 0x181F88, 0x14721A or 0x1471F0 is up. In the in-game help it is "Toggle MS7 Sniper sight - SPACE".
- While the weapon is out, the per-frame cursor pick 0x116E4 jumps past all contextual cursors at 0x119D6 (also while 0x147218 is set). The cursor is the game's own 0x15210C and the left button fires.
- Other writers of 0x14721C: conversation start clears it (0x17EC3) and the end restores it (0x17A6B); 0x16E20 / 0x17011 are state restores.
- RaptorMod's Space also SKIPS a spoken line (AztSkipKey). A Space pressed as a line ends therefore draws the weapon.
- The watcher now logs "weapon DRAWN ... / put away" with "(a spoken line ended N s before)" (Step-ShotWatch). Offline test: scratchpad weapon-log-test.ps1.
- **THE SPACE GUARD (Josh: "yes, add the Space guard after spoken lines") -- built HOST-SIDE, not in the game.**
  - The game patch had no room: the overlay is 53,246 of 53,248 bytes, the clock blob has 12 free, the box blobs 1 and 5, the stub 0. The guard needed ~120 bytes (stamp the line end at 0x13B46's call 0x17C08 and at ASK_hit, then guard 0x136D8's `jbe 0x131E1`, refusing via 0x1371B).
  - `AztTool.SpaceGuard` (tools\Keys.cs) is a WH_KEYBOARD_LL hook on its own thread, plus a 4 ms poll of the speaking word 0x152B28.
  - While a line plays, Space passes and skips it.
  - For `QuietMs` 1000 after a line ends, a Space down AND its key-up are dropped. Each dropped press restarts the quiet.
  - A Space the game holds down when the line ends gets a SendInput key-up at once, marked by dwExtraInfo 0x41A75A0E so the hook lets it through. DOSBox repeats held keys itself, so dropping Windows' repeats alone would not stop them.
  - It only acts while DOSBox's window is in front.
  - The watcher starts it with each session (Start-SpaceGuard, right after `$script:memAt`) and stops it after each session and in the finally block. It logs "space guard: on" and "Space held back N time(s) ..." (at most every 3 s). `-NoSpaceGuard` turns it off.
  - Offline: scratchpad space-guard-test.ps1 (TestKey on a fake speaking word; the real hook starts and unhooks). NOT yet seen in game.
  - The early key-up path cannot be tested offline without injecting into the foreground app; it was reasoned only.

**ROUND 4 (2026-10-11): the interactive cursor lands ON the reticle; the claw glows.**
- Josh: on right-click (look -> interactive) the icons appeared 'centered' but LOWER than the sniper reticle -- they must be centred in the viewable viewport like the reticle, in all cases.
- CAUSE (game code, not the icon): the look-mode crosshair is pinned at the 3D VIEW centre (aztCentreX/Y = 800, 513; AztFrameHook / AztCursorRedraw), but the game re-parks the pointer with SetMousePos 0x35A45 at three sites -- 0x132AF (Space turning combat OFF, which the mod's switch goes through via AztSendSpace), 0x16DA5 (0x16CCC, a mode exit), 0x179F2 (0x179EC, conversation start) -- and the build had patched those to the SCREEN centre (800, 600): 87 game px low. Now all three park on (CENTRE_X, CENTRE_Y). Manifest diff: only scr-hc-132AF/16DA5/179F2, 0x258 -> 0x201. Installed 442/442.
- The hot spot is (15,15) for EVERY cursor: set once at 0x10E79 via 0x3556F -- the middle of the 30x30 bitmap, so an icon centres on the pointer.
- 'take' (and 'btake'): its glow swells with each lift (1 + 0.9 x the lift, like the door chevrons' 1 + 0.8 x the step), its jaws close toward the middle as it lifts (points below y 14 move in by up to 1.3 units -- a grab), and it lights as it lands on appearing. Sheet: scratchpad cursor-take-sheet.ps1.
- Josh confirmed in game (same day): the game runs fine with the 256 KB overlay window ([[azrael-overlay-read-limit]]).

**Offline tests (scratchpad):**
- cursor-trace-sheet.ps1: bitmap | vector over the faded bitmap | vector. All 24 kinds line up.
- cursor-true-scale.ps1: bitmap vs vector at the real on-screen size (u 1.334), x4 nearest.
- cursor-anim-sheet.ps1: appear frames.
- cursor-guest-test.ps1 (fake guest): slot 14 found; 30 blanked; held item = -1; reload re-blanked; 30 restored exactly; the window starts and unregisters without showing.
- cursor-flicker-test.ps1 and panel-stale-box-test.ps1 (round 2, above).
- cursor-loop-sheet.ps1 and weapon-log-test.ps1 (round 3); space-guard-test.ps1 (the Space guard).

Related: [[azrael-host-pointer]], [[azrael-hud-hit-regions]], [[azrael-panel-button-rects]], [[azrael-title-menu]], [[azrael-hud-vector-text]], [[azrael-conversation-ui]].

**The shapes are shared (2026-10-11, RAPTOR DOCS).** Build / Draw / Preview and the inks moved to `tools\CursorShapes.cs` (a static class; IconCursor keeps forwarders), so the title's manual draws the very same animated icons in its cursor legend. Verified: all 24 icons x 10 moments hashed byte-identical before and after. The watcher compiles CursorShapes.cs before CursorIcons.cs; the title's copy is named TitleShapes under `#if TITLE_GATE` (Add-Type refuses a name twice -- [[azrael-raptor-docs]]). New shape `shoot` (a combat sight, three flashes = a burst) -- only the manual draws it; no game slot is named that.
