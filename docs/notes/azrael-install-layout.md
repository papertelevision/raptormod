---
name: azrael-install-layout
description: "ONE install folder C:\\Games\\RaptorMod (game/cache/textures/sources/scratch + Play RaptorMod.cmd), ONE desktop shortcut; Setup-Machine migrates the old C:\\Games\\azrael-* layout; the second PC's 61 s first room and the boot's busy hold. 2026-10-15."
metadata:
  type: project
---

**Why (2026-10-15).** Josh installed on a second PC (RTX 4090 Laptop, 2560x1600 at 125%) and saw the 8-bit game.

That PC's watch.log (kept on the NAS assets folder) showed the GPU was fine (OpenGL 4.6). The first room's textures took **61 s** ("true colour textures ... 61426 ms"; ~1.2 s on this PC). The visor boot's hold gave up after HoldMaxMs 10 s ("no host 3D after 10000 ms of hold"), so the 8-bit game showed.

He also clicked `Play-Azrael-Modded.bat`, which never started the renderer. And he wanted ONE folder instead of `C:\Games\azrael-*` plus two Desktop folders, with one desktop shortcut.

**The layout: everything in `C:\Games\RaptorMod`.** The repo stays in the Steam game folder.
- **`game\`** (was AzraelsTear-Modded).
  - `Play-Azrael-Modded.bat` now starts the GPU version through the repo's `Play-HostRender-TrueColour.cmd`; `Play-Azrael-8bit.bat` is the plain game. Both are written by Apply-AztMod.
  - `raptormod-settings.json` holds fov, textureQuality and tcMaxPixels.
- **`cache\`** (was azrael-render): watch.log, gpu-check.json, `azrael-palette.pal` (was azrael-inject), the twins index, and the rooms/room-notes junctions.
- **`textures\`** (was azrael-textures): `hires`, `hires-2048`, backups.
- **`sources\`**: `books`, `gfx`, `video`, `realesrgan`, `soundtrack` (was Desktop\AzraelTearSoundtrack), `files` (was Desktop\RaptorModFiles).
- **`scratch\`**: old RE/test folders and files.
- **`Play RaptorMod.cmd`, `Room Review.cmd`**: written by Setup-Machine with the repo's absolute path. ONE desktop shortcut, `RaptorMod.lnk`, points at `Play RaptorMod.cmd`. Setup removes any other desktop .lnk whose target is in the repo or the game folder.

**The path change.** One mechanical replacement across 153 tracked files: code, cmd, conf, room-notes JSON, docs.
- **First-try trap:** a regex replacement STRING treats `\` literally, so feeding `\\` doubled every separator. Collapse with `-replace '\\+', $sep`.
- **Manifest:** only `bookSource` changed (Build-AztMod `$BOOK_SOURCE_DIR`).
- **Setup-Machine's migration list** is the only place the old paths remain, on purpose.

**Setup-Machine now:**
- **Moves the old layout in.** It moves, never copies, and only where the new place is empty. It runs before the pack, and also rewrites the game's .conf paths (capture_dir).
- **Restores pack tars** only when their restore root is under `C:\Games\RaptorMod`; an older pack is skipped with a warning.
- **Builds the shared-art index** ("textures prepared"). This is the first-touch cost on a fresh PC.
- **Runs `tools\Test-GpuCaps.ps1`.** It compiles the renderer's full C# set and creates the GpuRaster context. It prints vendor, renderer and GL version and writes `cache\gpu-check.json`.
- **Makes the launchers and the single shortcut.**

**The renderer:**
- **Busy hold:** `BootHd.HoldWhileBusy`/`BusyText` (cap `HoldBusyMaxMs` 180 s). The watcher's `Get-RoomBusy` sets it around every `Get-Room`, so the boot holds with "PREPARING TEXTURES..." typed under the briefing instead of dropping to 8-bit. When cleared it gives `HoldExtendUntil` +15 s for the upload and the first frame. Tested with a fake-guest harness: it holds 4 s past a 0.8 s limit, then lets go when cleared.
- **Timing log:** "shared-art index: N ms" is logged when >300 ms (`Add-AztRgb` returns TwinMs/TwinNote).
- **Start-up failures** (before Say exists) are written to watch.log by a script `trap`, plus a message box under -Launch.
- **Graphics card refused:** shown on the visor once (`Show-GpuRefused`).
- **`-TcMaxPixels`:** 0 by default. The order is the switch, then settings `tcMaxPixels`, then 5.5 M. It came out of `Play-HostRender-TrueColour.cmd`.

**Not proven yet:** WHY the second PC's first room took 61 s.
- **Measured here:** a cold index rebuild takes 1.6 s, and 11 ms with the index.
- **Suspected:** first-touch on freshly restored files (Defender's on-access scan, a cold disk cache) while TexTwins opens 2,426 hi-res PNGs.
- **Next:** the new timing line will say on the next run there.
- **hires-2048 WENT MISSING (found 2026-10-15, a 2K install failed: "Could not find a part of the path ...\textures\hires-2048"):** Josh's hand-made 2K set (273 files, MINEMAZE + the opening rooms) stayed in the old `C:\Games\azrael-textures` after the move and the 10-14 cleanup swept it into `C:\Games\_cleanup-2026-10-14`. RESTORED to `C:\Games\RaptorMod\textures\hires-2048` (+ its hires-2048-backup-* folders); all 273 still newer than their 4K masters, so Normal uses them. The asset pack never carried it either: Export-AssetPack's `hires` component now packs `textures/hires` AND `textures/hires-2048` -- re-export for the second PC. Lesson: before sweeping leftovers of an old layout, check each against the new layout's expected folders.
