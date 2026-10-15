---
name: azrael-room-cover
description: "Room entry (2026-10-12): the visor's loading cover (tools\\RoomCover.cs, 'RAPTOR H.U.D. // ANALYZING ENVIRONMENT' + % + bar, top centre) hides the 8-bit view while a room's 4K textures decode and go to the card. Session texture cache: CPU colours capped (-TextureCacheGB, LRU) + card LRU eviction (GpuRaster.UploadSome/Evict). -NoRoomCover. Game loads: the texture work runs under the loading panel, whose bar follows it (Set-LoadProgress, Send-RoomTextures)."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-12T12:45:00.000Z
---

Josh (2026-10-12, after the opening rooms' 4K textures went in): on entering a room he saw "the 256 color version of the game (non gpu engine) for a good while as the textures load". He asked for two things:
- cache the textures per game session;
- a simple in-world loading display, top centre of the viewport: "Raptor H.U.D - Analyzing Environment..." with a number counting up to 100%.
- "The key is we shouldnt see the 256 version."

**WHY THE 8-BIT VIEW SHOWED (three causes, all measured in watch.log):**
1. **The engine-draw pulse:** every teleport hands the viewport back until the guest draws 6 frames of its own (300-500 ms). It is needed for the floor, see [[azrael-floor-needs-engine-draw]]. It stays, now under the cover.
2. **Sequential PNG decode inside Get-Room:** ORRERY's 32 4K textures took 6.6 s, WASHCORI 4.9 s. The loop is blocked, so the overlay goes stale (StaleMs 400) and the game's own picture shows.
3. **The card budget:** over MaxTextureBytes, Draw called ForgetTextures and re-uploaded everything every frame.

**WHAT WAS BUILT**
- **Parallel decode:**
  - `Raster.LoadRgbAsync(texes, paths, pal, workers)` runs a Parallel.For over min(8, cores/2) threads. It returns an RgbJob: Total, Done, Same[], Error[], Task.
  - `Add-AztRgb` (LoadRoom.ps1) works in four steps: a work list, the originals in parallel (texture-order proof), the overrides in parallel (an override that fails falls back to the original), then palette colours for the rest.
  - `-Progress { param($done, $total) }` is called every 15 ms. The originals count 1/10 each, the 4K overrides 1 each.
  - WASHCORI: 4.9 s -> 1.35 s. GDI+ serialises part of the decode, so it is not 8x.
- **CPU session cache:**
  - Decoded colours stay in `$script:AztUnitMem` per unit, which records RgbDone, RgbDir, RgbUsed and RgbBytes. Re-entering a room costs about 1 ms.
  - `Limit-AztRgbCache -Keep <this room's units> -CapBytes` drops the least recently used other units to 85% of the cap. A dropped unit is decoded again on its next entry, under the cover.
  - It is called after a new load and after a cache-hit re-decode.
  - Watcher `-TextureCacheGB` (0 = auto: RAM/4, clamped 2..16 GB).
  - A 4K texture is ~85 MB on the CPU (int[] plus its half-size copies).
- **Card cache:**
  - `GpuRaster.UploadSome(texes, max)`, `MissingCount(texes)`, `Evict(keep, target)`; Draw calls `Upload(texes)` = UploadSome(all).
  - Over MaxTextureBytes, it evicts the least recently used (GTex.Used stamp) down to 85%, never the textures of the frame being drawn.
  - SharpB is tracked, so the relief maps' bytes come back too. `Evicted` counts them.
  - Measured: a 3 GB budget keeps the current 4K room whole; 10 GB (Josh's 8060S) keeps two. Upload is 13-37 ms per 4K texture with its relief map.
- **The cover (`tools\RoomCover.cs`):**
  - `Render(w, h, viewRows, t, target)`: black, a faint amber scan sweep every 1.6 s, and the readout at 6.5% of the view's rows, centred:
    - title with animated dots;
    - Consolas percentage;
    - a 30-segment bar;
    - corner brackets.
  - The counter only rises: +max(0.006, 22% of the gap) per picture; once the target is 1, +max(0.03, 35%), so it finishes in about 0.17 s.
  - It costs 2.1 ms at 2562x1536.
  - The watcher presents it through the card's window: `GpuRaster.PresentPicture` + `Overlay.NoteGlFrame`, ~35 a second, with `Overlay.HoldFreshUntil` a second ahead so it never hides between pictures.
  - The game keeps drawing underneath, hidden.

**THE FLOW (Watch-HostRender.ps1: Start/Set/Show/Stop-RoomCover, beside Step-NothingToDraw)**
- **Start:** at the teleport (dj > 60), only while the host has the viewport (`$suppressed`), BEFORE the pulse.
- **Percentages:** the pulse 2-12, recognised 14, decoding 15-70 (rgbProgress), the upload loop 72-98, then 'ready' runs on to 100 (at most 250 ms).
- **After the pulse:** Stage 'waiting'.
  - Room detection runs on EVERY pass while a cover is up.
  - A guard after Step-ShotWatch keeps showing it and `continue`s, so no frame of the OLD room is drawn from the new place.
- **A new room recognised:** Get-Room (decode under the cover), then its textures go up one at a time (`UploadSome($room.Texes, 1)`, 20 s cap, logged "textures to the card under the cover"), then `Stop-RoomCover 'ready'`.
  - On 'ready' the 100% picture stays held until the room's first real frame replaces it.
- **Other stops:**
  - 'the same room' (detection says nothing changed);
  - 'no new room came' (1 s of waiting);
  - 'gave up after 12 s';
  - 'nothing to draw for 1.5 s' (a movie or menu: Step-NothingToDraw keeps it up through shorter blinks);
  - 'could not load';
  - 'the card no longer presents'.
  - Every non-ready stop lets go of the hold, if it is still the cover's own (the visor menu sets HoldFreshUntil too).
- **Late start:** a new room recognised with no cover up and the host holding the viewport (the cover gave up, or the scene changed before the jump) puts one up for the load. Never for the first room after a title load: there `$suppressed` is false and the boot owns that moment.
- Log line per cover: "room cover: N ms on screen, N pictures (how; why)".
- **Off switch:** `-NoRoomCover`. It also needs the GPU mode with the card presenting (ov.GlPresent) and tcRaster; -Retro never shows it.

**KNOWN, NOT YET SEEN IN GAME (2026-10-12):**
- A jump WITHIN a room shows the cover for the pulse plus 1 s. The window is there because detection can lag behind a real room change. Shorten it only if Josh finds it long.
- Characters joining mid-room (Get-Room with chars) decode outside the cover: Theo is 248 ms, a stall, not 8-bit.
- The Normal tier's first entry of a room still makes its 2048 copies if hires-2048 lacks them (Get-AztSizedOverride). The cover keeps refreshing then, but pre-make them before shipping.

Traps hit:
- `Volatile.Read` + `Interlocked.Increment` on the same field gives warning CS0420, and a warning fails Add-Type. Read an internal field through Volatile.Read in a property.
- A Parallel.For body has to be C#: a scriptblock cannot run on worker threads.

See [[azrael-josh-hires-textures]] (the textures that made this necessary), [[azrael-true-colour]] (the card's window, StaleMs), [[azrael-frame-cost]].

**GAME LOADS CARRY THE ROOM TOO (2026-10-12, same day).** Josh: room to room "works perfectly", but loading a game still showed the 256 version; the textures should be "lumped into the core loading UI/animation as part of the loading process".
- **MEASURED (watch.log 13:05:16, an in-game load into MINEHEAD):**
  - The reading panel and the re-boot's cover held while the room was recognised and decoded (1.9 s).
  - The 48 4K textures then went to the card in the room's FIRST frame, after BootHd's Reveal had let the cover go.
  - The card took 3.3 s over them ("collecting the picture 3,320 ms"), with "stale 2": the window hid and the 8-bit picture showed.
- **Now:**
  - **Every room load sends its textures before the first frame:** `Send-RoomTextures` (watcher), one at a time, then `GpuRaster.Finish()` (glFinish), so nothing is left for the first frame. It runs whether or not anything covers, and also for the characters' composed room while a load is covering. The room cover's own upload loop is this function too; it holds the cover 3 s ahead over the Finish.
  - **During a load the loading panel's bar carries the room:** `Test-LoadUi` = a title load (gate.PickedSlot), the memory core reading (visorMenu.ReadWait) or the visor boot covering. Under it:
    - no room cover;
    - `Set-LoadProgress` sends decode 0-65% and the card 65-100% to `TitleScreen.LoadProgress` (via `GameGate.TitleLoadProgress`) and to `VisorMenu.LoadProgress`;
    - a load into the room already there reports 1 once the re-boot is covering.
  - **Both panels' `ReadBar`:**
    - The archive is the first 30% on the planned time, creeping to ~42% while the room has not started.
    - Then base -> 99% follows the room, eased and never backwards.
    - The line under the bar reads "ANALYZING ENVIRONMENT" while the room loads.
    - When the view is up, it runs to 100% as before.
    - `RoomLoadAhead` false (-Retro / -NoRgb): the old bar (99% on time, then wait).
    - Simulated (scratchpad readbar-sim.ps1): room from 1.2 s, 99% by 4.0 s; a room starting late at 4 s holds near 35% and then climbs.
  - **BootHd.HoldExtendUntil:** Set-LoadProgress keeps it 3 s ahead, so the re-boot's cover does not give up (HoldMaxMs 10 s) while a big room is still loading.
  - **The panel no longer freezes:**
    - In the GPU mode the card's window is the one shown (Overlay.GlPresent). BootHd's pictures go to the overlay's own window, unseen; they only keep the card's window fresh.
    - So the memory core's reading panel was drawn only by Repaint-HeldPicture between loop passes. During a re-boot's wait and a room's decode, it stood still.
    - `Step-LoadRepaint` now repaints it ~30 times a second, from Set-LoadProgress and from the re-boot wait.
- **Not yet seen in game.** Logs to look for: "textures to the card before the room's first frame: N in N ms, finished on the card N ms later", and "visor boot: a load -- the host's view is up after N ms of cover".
**ONE COVER THROUGH THE WHOLE SWITCH (Josh, 2026-10-14, entering MINEMAZE: "I still see the 256 version ... then it will flicker to loading, then back, then finally the GPU version").**
- MEASURED (watch.log 18:06:14, CHAMBNEW -> MINEMAZE): the room was recognised by its SCENE changing ("scene rebuilt") BEFORE the camera's jump. The cover started late and ended 'ready'. A moment later the jump came; its engine-draw pulse called Set-Engine3D false, which HID the card's window, so the 8-bit picture was up. The second cover managed 3 pictures in 1.27 s.
- **Fixes:**
  - `Set-Engine3D $false` no longer hides the card's window while a room cover is up, so the cover shows through the pulse.
  - A cover that started late (no jump seen yet) and whose room is loaded goes to stage **'settle'** (`Loaded` = true) instead of 'ready'. It waits up to 1.5 s for the jump; the jump's pulse runs under it; then it ends 'ready', so the room's first GPU frame materializes it with the teal scan.
  - The 'same room' stop of a loaded cover is 'ready' too.
- Not yet seen in game.
