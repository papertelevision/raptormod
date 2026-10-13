---
name: azrael-title-menu
description: "4K title screen + Continue/Load/Options/Quit/Story (2026-10-10): host TitleScreen in LoadingScreen.cs run by the GameGate; the game holds TITLE.PCX via a 33-byte loop rewrite + keyboard ISR or-patch; a Load runs cmd 16 on the first frame. Load-from-title hang fixed 2026-10-10 (black TITLE.PCX, not jumps)."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-11T14:17:07.299Z
---

Josh (2026-10-10): the intro's title image becomes his 4K art (`art\title\title_4k.png`, 4096x2304, also on his desktop as title_4k.png) as a real title screen.
- Continue loads the newest save.
- Load shows a slot list over the title, without the visor background.
- Options and Story come later.
- Quit quits.

**Game side (Build-AztMod `$ENABLE_TITLE_MENU`)**
- **Title wait 0x20015..0x20035:** stock waited 130 x 20 ms or for the skip flag 0x182DB0. The rewrite keeps the flag's one relocated operand (at 0x2002F) as the imm32 of `mov ecx,&flag` at 0x2002E.
  - Each pass it ORs in 0x0100 (the marker) and tests the flag against a mask: 0x02FF with no host, or 0x0200 once the host has set 0x8000.
  - The mask is computed with `cwd/not dx/xor dh,dh/or dh,2`. No delay: it spins.
  - With no host it holds until a key ("press any key"); the stock 2.6 s timeout is gone.
- **Keyboard ISR 0x362BB:** `mov word [flag],1` becomes `or word [flag],1`, so the host's bits survive a key.
- **Load on the first frame (overlay AztBootTick state 0, 16 bytes):** `test byte [edi+0x146949],0x80 / jnz / mov al,16 / jmp 0x2C408`.
  - The host has already written 0x146948 = slot (it is -1 in file data) and 0x1524CC = 0.
  - 0x2C408 is the command DISPATCHER: al = cmd, table `[cmd-1]` at 0x2C3A0, cmd 16 = OK at 0x2CCA1.
  - Handlers are jumped to inside the dispatcher's frame and it preserves esi/edi. A tail jump works because its ret returns to AztFrameAll.
- **THE OVERLAY IS AT ITS 0xD000 CEILING.** Room was made by:
  - making the dead AztSceneLog call conditional (7 bytes);
  - turning AztBootTick's `jz ABT_out` into `jnz +1 / ret` (3 bytes).
  - 2 bytes are left.

**Host side (tools\LoadingScreen.cs)**
- `TitleScreen`: a full-monitor, layered, click-through, no-activate window. The art is cover-fit once and only the menu area and pointer are redrawn.
  - Visor amber Consolas with letter-spacing, a lock-on glass bar, brackets, chevrons and a scan sweep.
  - Rows flicker on in turn. CONTINUE shows its sub-line "NAME // MMM dd HH:mm".
  - A divider, then a dim STORY. OFFLINE // COMING SOON for Options and Story.
  - LOAD opens the MEMORY CORE // RESTORE list (5 slots and BACK, the newest dotted).
- **Input is the GAME's:** DOSBox has `mouse_capture = onstart` and keeps focus.
  - The cursor is 0x182D6C/E and the left button 0x182DA6, fed in by the gate. The range decides 640 or 1600 wide.
  - Keys come from GetAsyncKeyState while DOSBox is in front.
  - The mouse handler 0x3584F only updates the cursor when [0x182DA4] != 0 and [0x147586] == 0. Whether that holds at the title stage is UNVERIFIED; the keys always work.
- **Saves:** SGDNAME.DAT (5 x {name[30], u16 empty}) and SAVEn.DAT mtimes. "EMPTY" or no file = unusable. Continue with no saves = a new game.
- **`GameGate.TitleTick`** (every ~6 ms in the gate's play-watch loop):
  - It sees the 0x100 marker, shows the title and sets 0x8000.
  - On a choice it writes the slot and OK mode, then 0x8300, sleeps 80 ms, then sets the flag to 1 (skip the intro) or 0 (story intro).
  - Quit closes DOSBox.
  - If the window dies with no choice, it releases into the story intro.
- Watcher: `-NoTitleMenu`; off with -Retro too.
- Tests: scratchpad `title-preview.ps1` (offline renders) and `title-live.ps1` (the real loop in a 480x270 corner window: cursor feed, LOAD, pick slot).
- **NEW GAME (Josh, 2026-10-10):** rows are CONTINUE, NEW GAME, LOAD, OPTIONS, QUIT, then STORY.
  - NEW GAME is always shown. Josh said "if previous saves exist", but read literally a first boot would have no way in.
  - With no usable save, CONTINUE is greyed with "NO SAVED LOG" and skipped by keys and hover, and the start selection is NEW GAME.

**Round 2 (Josh, 2026-10-10): the intro order.** It is now logo -> logo sting -> story intro (MOV\INTRO.MOV) -> TITLE -> epilogue (AztOpenMovie at 0x200A0 = the custom opening movie, new game only), done with jumps only.
- **Skip checks:** each skip check `cmp word [flag],0` becomes `btr dword [flag],0`: the same 8 bytes, the operand at +3, and a key both decides the jump and is cleared.
  - 0x1FFA6: jc the title.
  - 0x1FFCF: jnc story 0x20053.
  - 0x20049: btr / jmp short title (story -> title).
  - 0x20094 (story fade call): jmp 0x20049.
  - 0x20044 (title fade call): jmp the epilogue 0x20099.
  - A key in ANY video goes to the title.
- **Opening movie -- THE PLAYER NEVER READS THE SKIP FLAG.** 0x20BD4 drains the input queue, then plays until a KEY event (type 2, posted by the keyboard ISR) or its frame count -- and every other event (mouse) counts as a frame, so moving the mouse ends a movie early. "A load leaves the flag at 1 so it stops at once" was FALSE: a title load sat through all of OPENING.MOV (58 MB) behind a black screen unless the mouse moved (Josh: Continue "went to a black screen"; it looked like a hang).
  - Fix: the host's LOAD BIT 0x0002 (the ISR only sets bit 0). The gate releases a load with 0x8302, then 2. Patch `title-loadskip-2003E`: `test byte [ecx],2 / jnz 0x200A5` (ecx = &flag from the wait loop; 0x37FC8 keeps it) skips just the movie call; the wait and free still run.
- **Story intro jump retargeted to 0x20069** (the intro.mov setup): 0x20053 blitted the title surface [ebp-0x14] before the title was ever loaded (garbage descriptor).
- **Loading from the title:** the reading panel fires on the first loop pass (aztReboot already 1, gate PickedSlot/PickedName) and holds at 99% (`VisorMenu.ReadWait`) until BootHd leaves live/hold. The flat line needs the player seen ALIVE since the last boot / player object (a title load read health 0 as the view came back).
- **Loading RaptorMod is at the TITLE now:**
  - TitleTick sees the marker and holds (0x8000).
  - Screen.Show() plays the voice until the renderer is ready, the voice is done and at least 1.5 s has passed (60 s cap).
  - Then Screen.Finish() and the menu.
  - At play, with `_titleLoad` set and the renderer ready, there is no second loading screen.
- Manifest 440 patches. Backup: `backup-pre-title-order-20261010`.

**First in-game look (2026-10-10) was CORRUPT.** Josh saw a partial background, a black area, and the menu's art out of line with the rest. The log showed the title up and QUIT working.
- **Cause:** Josh's display is 144 DPI (150%). `DrawImageUnscaled` onto the window's Graphics scales by screen DPI / bitmap DPI, so the first full frame drew 1.5x while the dirty-rect copies were 1:1.
- **Fix:**
  - Rectangle + GraphicsUnit.Pixel DrawImage everywhere.
  - WM_ERASEBKGND returns 1; WM_PAINT validates and sets `_needFull`.
  - Full frames for the first second and on any WM_PAINT.
- Verified with scratchpad `title-live-capture.ps1`: a DPI-aware CopyFromScreen of the live window.
- **NEVER use DrawImageUnscaled onto a window on this machine.** LoadingScreen's panel still does, but its look was approved.

**Round 3 (Josh, 2026-10-10):**
- **Title music:** KREEPY3 (Josh corrected KREEPY2 -> KREEPY3) from `Desktop\AzraelTearSoundtrack\KREEPY3.mp3`, decoded to `art\title\title-music.wav` (314 s, 44.1 kHz stereo; same RMS as KREEPY2, so the gain stayed).
  - The gate plays it with LoadingAudio (new: `LoopTrack` and `FadeInTrack`) from the menu's arrival.
  - Gain 0.55, fade in 2 s, fade out 1.6 s on a choice (0.8 s on Quit). Watcher `$gt.TitleMusic`.
- **Old TITLE.PCX removed -- WITH ART, NOT CODE.** TITLE.PCX in the install is an all-black 1600x1200 (`src\Build-Title.ps1 -Import -InDir design\title-black -Files TITLE.PCX`; the mod's old title is in `backup-pre-title-black-20261010\TITLE.PCX.mod`).
  - Jumping over the load (0x1FFDD) and the free (0x20036) HUNG EVERY LOAD from the title: the epilogue's 0x200A0 blit (AztOpenMovie) and 0x200B2 free use the surface at [ebp-0x14], which only the 0x1FFE9 TITLE.PCX load fills. Never skip that load. Manifest back to 440 patches.
- **System menu dead after a TITLE load (FIXED, host-side):**
  - The load's close 0x2C2D4 sets the slide direction 0x1523E8 = -1. The fold-out was never open, so the position 0x1523E6 runs below 0 forever (0x14947 stops only at exactly 0), and cmd 5 refuses while E8 != 0.
  - `Guard-SaveList`: if int16 [0x1523E6] < 0, zero E6/E8/EA.
- **Reading panel on loads:** VisorMenu `BeginReading(slot, name)` uses the same panel as WRITING (DrawArchive, read=true): "INITIATING LOG FILE "NAME"", READ ACCESS, ReadSeconds 2.2 + ReadHold 0.7.
  - The watcher's `Step-LoadPanel` (top of the main loop, before any `continue`) fires on aztReboot 0->1.
  - The slot comes from the gate's `PickedSlot` (title) or `$script:lastLoadSel` (the load list's last row); the name from the game's list.
  - It draws over BootHd's re-boot frames, because those go through Overlay.ShowComposed -> Decorated -> Decorate4.

**INSTALL TRAP FOUND:** Build-AztMod writes `AztMod.overlay.sym` NEXT TO `-OutFile` (the temp folder). The watcher reads AztMod\AztMod.overlay.sym (the gate's aztInjBufPtr/aztBootState, aztLogScroll). Copy the temp sym in with the manifest whenever the overlay layout changes. Until this build it hadn't changed since 10/7.

Related: [[azrael-intro-sequence]], [[azrael-gpu-boot]], [[azrael-memory-core]], [[aztmod-manifest-not-buildscript]].

**Round 4 (2026-10-10): loads still black + silent, no first frame (24 s).**
- **Probable cause: a lost release.** The title loop's `or word [flag],0x100` is a read-modify-write that DOSBox doesn't make atomic against host writes. A host write between its read and write is reverted. The gate's two blind writes (0x8302, then 2 after 80 ms) could both be lost, leaving the game spinning on the black title. The same race explains the earlier "nothing happens".
  - `GameGate.ReleaseTitle` writes 0x8200|bits (no 0x0100) and rewrites until it reads 0x0300 set: the loop OR'd onto OUR value, so it has seen it. Then the final value. It notes when it needed more than one write.
- **LOGO.WAV** (0x1FF56, channel 0, under the silent MINDLOGO) only stopped at the epilogue, so a key at the logo carried it into the title. Patch `title-logostop-1FFEE`: the title stage calls 0x31C11(handle, 0) first, in the bytes of the black title's palette read and fade-in. The handle comes from the fixed-up `mov eax,0x141B2B` at 0x1FFF4, + 0x409BD = [0x1824E8]: an obj2 address with no new fixup.
- Verify a patched image by applying x.json to a stock R.EXE copy and loading it with LeTool.LeImage (scratchpad verify-title.ps1); Test-Patch's temp exe isn't kept.

**Round 5 (2026-10-10): "I don't see the loading screen" + "randomly starts a new game on the menu".**
- **The race was confirmed.** The first verified release needed 9 writes (logged), and that load reached WELLROOM.
- **The title reads the log in itself.** A LOAD no longer closes the TitleScreen. The art dims, and `DrawRead` (the visor's DrawArchive look) opens where the menu was: the title typed, the bar, the hex stream.
  - The bar holds at 99% until `LoadShown`. The watcher calls `gate.TitleLoadShown()` at BootHd.Reveal (the shutter), or from Step-LoadPanel if there's no host boot.
  - Then "LOG FILE INITIATED." for 0.85 s, then the window fades into the visor's shutter. ReadMax is 45 s.
  - The in-visor BeginReading is now for fold-out loads only; it could never catch a title load (the short re-boot is over before the main loop's first pass).
  - Tests: scratchpad `title-read-preview.ps1` (offline `PreviewRead`) and `title-live-read.ps1` (real loop).
- **Random new game:** without the host's 0x8000 bit, the title loop exits on bit 0, which the keyboard ISR sets on every key down, up or repeat. A skip key released after the intro's last btr ended the title on its first pass. The opening movie then ran unseen behind the loading screen and menu until the mouse used it up.
  - Fix: `GameGate.ClaimTitle` writes 0x8000 as soon as the game is found, re-writing it only if missing. The btr checks read bit 0 only, the movie player never reads the flag, and nothing in the game clears 0x8000.
- **Flatline over a live player:** a load passes through health 0. A death now needs health ≤ 0 for 0.5 s and hpQuiet ≥ 3 s; until then the watcher passes 0.001.

**Round 6 (2026-10-10): flicker over the title's reading, in-game loads, ESC dead after a title load.**
- **THE COVER:** the TitleScreen window is named `AztTitleCover` (= `Overlay.CoverName`). `Overlay.TopSlot()` returns it while it is visible (FindWindow, cached 100 ms), else HWND_TOPMOST.
  - Overlay, Panel and Pointer all place themselves via TopSlot, i.e. JUST BELOW the title.
  - The flicker was the panel (re-topmost every 250 ms) and the title (every 150 ms) swapping. The title's fade now reveals the visor beneath.
  - ReadDim is 0.55: the reading plays OVER the home screen (Josh wants the home art visible).
- **In-game load = like a save.** 0x152B04 is the load's busy word: set at 0x2CCDC, cleared at 0x2CF41, the twin of the save's 0x152B02; it is memAt.Lod.
  - Step-MemCore starts BeginReading (ReadWait) at OK and holds the window fresh. Repaint-HeldPicture and the 30 ms sync limit now cover reading too.
  - The re-boot trigger skips if a reading is already playing.
  - Previously the panel started only after the load's stall, so the picture went stale and hid, and the bottom panel (shown only with it) blinked and re-slid.
- **ESC after a TITLE load (probable):** 0x1471F0 is the script's interface lock (opcode 0x26477). cmd 5 refuses while it, or 0x14721A, is set; walking doesn't care.
  - The new game's opening locks it, and the frame-1 load removes the script that unlocks it. For 5 s after a title load the watcher clears both and logs it once.
  - `Step-EscWatch` logs every ESC blocker whenever ESC opens nothing ("ESC opened nothing -- ..."). Read that line if ESC is still dead.
- **Flatline over a live player was hpMax:** a garbage read during the load raised "full" far past 1,000, so 1,000 then read as about 0. Readings above 1,500 or below -1,000 (16.16) are now ignored.
- Tests: scratchpad cover-test.ps1 (TopSlot finds the title, then lets go).

**Round 7 (2026-10-10): ESC still dead; "the boot animation is playing in the background during the loading".**
- **ESC, from the diagnostic:** "sliding -1": the fold-out's direction 0x1523E8 was stuck at -1 with the position unmoved; cmd 5 refuses while E8 != 0. The 0x1471F0 lock was 0 (that theory was wrong; its clearing code stays, but it is harmless).
  - Guard-SaveList now resets E6/E8/EA whenever E8 != 0 and the position hasn't moved for 1 s, outside a load or save stall.
  - The slide routine 0x14920 only reaches rest when the position counts down to exactly 0.
- **Loads are not boots (BootHd.LoadCover).** A re-boot shows `LoadHeld`: the watcher's gpuClean, handed over at the load's OK, or black for a title load.
  - The loading panel is drawn over it; there are no boot visuals, sounds or glare.
  - Reveal() on a load goes straight to M_DONE: no shutter or calibration ("straight to the game, no boot-in").
  - The readings finish when the view is back: `VisorMenu.FinishReading()` and TitleScreen `_shownAt`, with ReadMin 1 s and the bar running to full in 0.3 s. The footer now says "RESUMING".
- The false "player died" line every session came from `$script:vdDeaths` starting $null; it is now 0 at creation.
- Release ack: a value that stays ours for 6 ms means the loop has gone (it can take our value before its own OR); this cost 2 s once.

**Round 8 (2026-10-10): ESC and QUIT confirmed working by Josh. MOUSE ON THE TITLE:** the game's cursor 0x182D6C never moves before play, so the TitleScreen reads the mouse itself through RAW INPUT (RIDEV_INPUTSINK on its own window; it still arrives while DOSBox holds the mouse captured).
- Movement moves the title's own pointer, starting on the selected row. Speed: RawSpeed 1 px per count, x max(1, W/1920), with mild acceleration.
- The left button picks; the wheel steps through the rows. Absolute devices (tablet, RDP) are mapped from 0..65535.
- Input counts only while DOSBox or the title is in front.
- The process's earlier mouse registration (Pointer.cs, -HostPointer) is saved and restored when the title closes.
- Tested in scratchpad title-mouse-test.ps1: registered while up, removed after. No injected moves (they would move Josh's real cursor).
- **Title pointer = the game's reticle (Josh, 2026-10-10: "more like a small reticule").**
  - It is MICE\POINTER.PCX (the diamond crosshair, the game's UI pointer "mice\pointer.pcx"), with ACTIVE.PCX (its red variant) over a pickable row.
  - Read from SaveDir\MICE by TitleScreen.ReadPcx (8-bit RLE; index 0 = see-through).
  - Hot spot in the middle. Size is CursorScale x W/1600, the visor's mapping, so it matches the in-game size (about 48 px on 2560 wide). Bilinear, with a soft shadow.
  - The drawn arrow is the fallback. Preview: `PreviewPointer` / `PreviewHover`.
  - Other cursors in MICE: DEFAULT (bow-tie, 3D view), LOOK, SCAN, TAKE, USE...

**Round 10 (2026-10-11): THE OPTIONS PANEL.** Josh: "in the settings of the main menu we would have a texture quality setting: Normal/Ultra ... implement the menu item on the home menu, with that 'coming soon' in place on the actual new sub menu".
- OPTIONS now opens a panel like LOAD's slot list: `_optOpen`, rows `O_TEX` / `O_BACK`, `DrawOptions`, header "RAPTOR H.U.D. // SYSTEM // OPTIONS".
- TEXTURE QUALITY shows NORMAL / ULTRA, the current one underlined (`TitleScreen.TextureQuality`, from `GameGate.TitleTextureQuality` <- the watcher's quality), the line "NORMAL: 2K // ULTRA: 4K" and a COMING SOON tag.
  - Picking it flashes "OFFLINE // COMING SOON". BACK or ESC closes the panel. STORY keeps the old soon flash.
- Offline preview: `Preview` with `PreviewOptions` / `PreviewOsel` / `PreviewSoon` (scratchpad title-options-preview.ps1).
- To make it live later: cycle the value on Enter / click, write `<GameDir>\raptormod-settings.json` {"textureQuality": "Normal"|"Ultra"}. The watcher reads it at start (see [[azrael-josh-hires-textures]]), so a change applies from the next launch, unless the room cache is reloaded.

**Round 9 (2026-10-10): the title's clicks leaked into play.** The first right press after a load fired the gun: the click that picked Continue was still queued in the game. ReleaseTitle now empties the game's input rings first (`ClearGameInput`). See [[azrael-gun-sound]].

**Round 11 (2026-10-11): clicks fell through to the menu behind a panel (Josh: "if I click somewhere in the options menu, it will accidentally click the load button ... you can only click the buttons that you see on screen").**
- **CAUSE:** every click reaches the title TWICE: raw input at once, and the game's button word 0x182DA6 a frame or more later, once DOSBox passes it on. Both counted as a press.
  - The options panel's BACK sits exactly over the main menu's LOAD.
  - The first copy closed the panel; the second, 50-60 ms later, hit LOAD.
  - Activate also used the remembered selection, which the hover updates only when its index changes, so it could reopen the panel just shut.
- **FIX (TitleScreen.Press):**
  - a press within ClickMerge 0.3 s of the last is the same click;
  - no press counts for LayerSettle 0.3 s after a panel opens or closes (LayerChanged, which also resets the hover);
  - a press acts on HitTest at the pointer in the layer on top NOW: it sets that layer's selection, then Activate.
  - Keyboard activation is unchanged.
- **Offline:** scratchpad title-click-test.ps1 (Press + TestLayer/TestCentre/TestHit). BACK then the duplicate leaves the menu shut (LOAD not opened); settling is ignored; an empty spot in a panel does nothing.

**Round 12 (2026-10-11): STORY became RAPTOR DOCS.** The last row opens a panel like OPTIONS: MANUAL (the 1996 manual typeset in the visor's library) and CLASSIFIED DOCS (the box's print-outs between arrow pads, click to magnify); BACK / Esc in a reader go straight to the main menu. All of it is `tools\RaptorDocs.cs` (partial TitleScreen); the gate now compiles LoadingScreen.cs + RaptorDocs.cs + CursorShapes.cs with `/define:TITLE_GATE`. The click merge counts from the last press that ACTED (quick clicks on an arrow each turn a page). See [[azrael-raptor-docs]].
