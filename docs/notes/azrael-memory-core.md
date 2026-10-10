---
name: azrael-memory-core
description: "The save/load screen (\"memory core\"): host-drawn VisorMenu (ScanWire.cs) from the game's state + the game's slot-list hot spots and row maths MOVED by Build-AztMod to match. Installed 2026-10-09, not yet seen in game. RE reference in AztMod\\docs\\save-load-screen-RE.md."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-09T23:14:56.581Z
---

Josh (2026-10-09): the save/load list's text was "far too small". He wanted "an all new loading screen ... amber interlaced monitor ... transparency ... degauss sound ... similar style as the bootup sequence".

- **The reverse engineering:** `AztMod\docs\save-load-screen-RE.md`, from a subagent's static analysis. Key state:
  - EA 0x1523EA = panel visible; DC 0x1523DC = list showing; DE / E0 = load / save mode.
  - Selected row is int16 0x146948 (-1, 0..4, or 6 = RESTART).
  - Live names at 0x152434 + 30*i. Typing writes straight into them, and Enter means OK.
  - Hover is not stored anywhere; the host computes it from the cursor 0x182D6C/E (screen px).
- **Clicks stay the GAME's.** Build-AztMod's `$SLOTLIST_HOT` remaps the close box, 5 rows and RESTART on UI screens 2 and 3. They are matched on their stock boxes and asserted x2 each.
  - Patch `memcore-rowmath-2CC37` (10 bytes, no fixups): `lea eax,[edx-TOP] / push PITCH / pop ebx / nop`.
  - Layout in screen px:
    - rows: x 130-970, from y 280, pitch 76, 68 tall;
    - close box: 950,160 40x40;
    - RESTART: 130,676 430x60.
  - **VisorMenu's numbers must change WITH the build's.**
- **Host:** `AztTool.VisorMenu` lives in ScanWire.cs and hangs on the new Overlay.Decorate4.
  - The watcher's `Step-MemCore` reads the state block (0xF8 bytes from 0x1523D6), the selection and the cursor each frame.
  - While it plays it sets HideRect2 (shared with the scanner; they never coexist) to hide the game's tiny list (still drawn at the stock place) and anything under the glass.
  - Effects: degauss sound + RGB swing on open, a ticking sound on hover, the selection and typing.
  - Switch: `-NoMemCore`.
- **KNOWN GAPS:**
  - The game's own tiny list was NOT moved, so in 8-bit / -Retro or after a true-colour fallback its clicks no longer line up with its drawing. The draw constants are listed in the RE doc s3.3 (row pitch imm8; stipple x and h share one immediate).
  - **Stock bugs FIXED (Josh, 2026-10-09, manifest 426 patches):**
    - **"Slot 6" corruption:** six `memcore-restore-guard-*` patches. Every name-restore site (0x2C30E, 0x2C92B, 0x2CA46, 0x2CB26, 0x2CBA2, 0x2CBFC) goes from `cmp reg,-1 / jz` to `cmp reg,5 / jae`. Two bytes each, no fixups.
    - **Invisible RESTART in save/quit mode:** NOT fixable in the game's handler (0x2C789).
      - It has 21 free bytes across three fragments around five fixed-relocation instructions; a mode check needs 27 or more.
      - No register holds an obj2 address at entry, and new absolute references can't be added without fixups.
      - So the watcher's `Guard-SaveList` (every frame, both modes) does it instead: if sel==6 while DE==0, it writes back the previous frame's sel, 0x1524CC and the click screen `[[0x182DB8]+0x52]`.- Install: manifest 419 -> 420 patches. Diff was clean (only hotspots-screen2/3 + the new patch). Backup in `AztMod\backup-pre-memcore-20261009`. AZRAEL.BAT and the movies were untouched by the install.
**WRITING LOG screen (2026-10-09, Josh: "when I click confirm I see the old load/save interface briefly"):**
- Cause: OK clears DC at once (so the panel closed), then the game saves for ~3 s with 0x152B02 = 1. The game's old list showed through.
- Fix: Step-MemCore reads 0x152B02 (memAt.Sav) into `VisorMenu.Writing`. The panel stays up as "WRITING LOG..." (archive name, a fill bar timed to 3 s, a hex stream, "DO NOT POWER DOWN THE VISOR").
  - Then "LOG WRITTEN." for WrittenHold 0.7 s, then it closes.
  - A 0.15 s grace bridges the poll between DC going down and the flag going up.
  - Offline test: scratchpad memcore-write-test.ps1.
- On LOAD, the re-boot's line under the reticle reads "ALL SYSTEMS OPERATIONAL." (BootHd.ReloadText). A new game keeps "WEAPON SYSTEMS ONLINE."
- Not yet seen in game. If the old screen still flashes, check whether the guest renders frames during the save at all.

**Vector effects (2026-10-09, Josh; not yet seen in game):**
- **Hover "memory cell"** (`VisorMenu.MemCell`): on the hovered row (or the selected one when nothing is hovered), just left of the STORED/VACANT tag.
  - A wireframe cube turning, with three pulsing data bars and a chevron streaming in (save) or out (load). Corner ticks; it flickers on and bobs.
  - Vacant = a dashed cube, struck through. Amber at 0.78; dark on a selected row.
  - Josh's wording ("to the right ... to the left of the slot") was ambiguous; this placement was the reading. Easy to move.
- **Back to the world after a save** (`DrawReturn`, `ReturnSeconds` 1.45): triggered when the memory core folds within 3 s of the write ending.
  - Static dashes; lids close to a hot line (0.12-0.42 s) and reopen (to 0.70); the whole view in interlaced amber monochrome fading to colour.
  - Plays Line + a soft degauss. The cursor is not redrawn during it.
- **`AnyPlaying`** (Playing || SysPlaying || ReturnPlaying) now drives the watcher's decorated-picture path and Repaint-HeldPicture.

**2026-10-09 follow-ups (Josh):**
- **Heading:** now "RAPTOR H.U.D. // MEMORY CORE // ..." (it was "AZRAEL VISOR").
- **The cursor was lost behind the panel.** The game draws it into its own picture, which is under the panel, and HideRect2 hides the game's drawings there anyway. Fix: VisorMenu redraws the game's CURRENT cursor image last, over the panel.
  - It reads the cursor-surface ptr 0x147588, the hot spot 0x14758E and the pointer-hidden flag 0x147586, as Pointer.cs does.
  - It has its own ReadProcessMemory: ProcMem is compiled apart from ScanWire.cs.
  - Tested with fake guest memory in 32-bit PowerShell; guest pointers are 32-bit.- **The cursor STILL did not show in game** (Josh, after the 11:28 session), so the cause is unknown.
  - Fallback: if the game's cursor image can't be read, VisorMenu draws its OWN amber arrow at the cursor, never nothing.
  - The pointer-hidden flag no longer suppresses it.
  - The read records why it failed (`CursorNote`), and the watcher logs "memory core cursor: ..." to watch.log when the reason changes. READ THAT LINE after Josh's next session to find the real cause.- **CURSOR CAUSE FOUND (watch.log 12:07):** "cursor surface looks wrong: 1966110x521522" -- the game's surface is word w, word h, dword pixels (blitter 0x37D98), not the int32 layout Pointer.cs assumed. Both are fixed now. The amber fallback arrow stays for any other failure.