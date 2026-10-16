---
name: raptormod-release
description: "RaptorMod 1.0 public package (2026-10-16): Inno Setup wizard, everything in one download for ModDB; game built on the player's PC from their Steam copy (Install-Game.ps1, disc-map.tsv); Build-Release.ps1 hash guard; RAPTORMOD_ROOT."
metadata:
  type: project
---

Josh, 2026-10-16: "package everything for a distributable file for this patch to be played by any player ... steam-friendly
and compliant". It REPLACES his NAS + git dev install for play-testing on other PCs (dev work still uses the repo).

**Josh's decisions:** everything in ONE download (4K textures incl. his redraws, upscaled movies, books, HIS OWN soundtrack
recordings -- "Mine, ship them"); an **Inno Setup wizard** (Inno Setup 6 installed per-user on the dev PC via winget:
`%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe`); prepared for **ModDB** (also NAS / own site); the **classified print-out
scans ARE included** in Raptor Docs ("They should def be included"). Version **1.0.0** (banner "RaptorMod 1.0.0").

**Never shipped:** R.EXE, AZT.BIN, any file identical to a Steam file or a file on AZT.BIN, backups (.aztbak/.orig/.src),
Josh's saves (SAVE*, RANIM*, DEDCHA*, NPC0, SGDNAME), logs, old room exports. Fonts DO ship as the prebuilt PCX bitmaps
(regenerating with the manifest's settings was NOT byte-identical: RUSGLD2 differed, INVFONT not rebuilt).

**Install layout (one folder, default C:\Games\RaptorMod, player-chosen):** `app\` (repo tracked files minus dev-only),
`game\` (built on the player's PC), `textures\hires\`, `cache\`, `payload\` (removed after the build),
`raptormod-root.txt` (marker), launchers `Play RaptorMod.cmd`, `Play RaptorMod (Classic 8-bit).cmd` (-Retro),
`Collect Logs.cmd`. **RAPTORMOD_ROOT** (set by the launchers; Play-HostRender.cmd also finds it from the marker) replaces
every `C:\Games\RaptorMod` default in Watch-HostRender / LoadRoom / GuestBase / Build-RoomCache / Test-GpuCaps (fallback =
the dev layout). Play-HostRender.cmd: no IF blocks around paths (a root may contain "(x86)").

**tools\Install-Game.ps1 (player side, also "Repair RaptorMod"):** find Steam (registry + libraryfolders.vdf), check R.EXE
SHA -> robocopy the Steam folder -> extract AZT.BIN (Read-CdImage, 22 s) and place files per `app\runtime\disc-map.tsv`
-> payload\pre (DOSBox Staging, soundfont, AZT.CUE + AZTRACK*, raptordocs) + runtime confs (capture_dir rewritten) ->
Apply-AztMod (child process) -> payload\post (movies, TITLE.PCX, BOOKS -- AFTER the patcher, which regenerates book pages
from the stock ones) -> title music decode -> palette, cache\rooms junction, Build-RoomCache, twin index -> Test-GpuCaps ->
marker, dry-run. The room textures in GAME\AZTEX are the DISC's, unmodified (no resample step).

**tools\Build-Release.ps1 (dev side):** classifies every file of the working install (C:\Games\RaptorMod\game) by MD5
against Steam + disc -> disc-map, payload rules (pre/post regexes), `not-shipped.txt`; app = `git ls-files` minus dev-only;
root = installer\root + installer\docs ({VERSION}); **GUARD** fails the build on any staged/texture file matching a Steam
or disc file; ISCC (`installer\RaptorMod.iss`: DiskSpanning 1.9 GB slices, PrivilegesRequired=lowest, refuses Program
Files and a folder with a dev setup) -> `C:\Games\RaptorMod-Release\RaptorMod-<ver>\` + one stored zip + SHA256SUMS.

**TRAP HIT AGAIN (2026-10-16):** `Apply-AztMod ... | Select-Object -First N` halted it after it restored the stock R.EXE --
the dev game was left UNPATCHED until re-run ([[installer-select-first-trap]]). Never truncate Apply's pipeline.

Related: [[raptormod-repo]], [[azrael-install-layout]], [[aztmod-patch-framework]]

## First play-test of the release (2026-10-16): three gaps, all fixed
- **V scan dead (dev too):** the jump commit's block replace (between two markers) deleted the echo scan's header --
  `$EchoCreatures`, `$EchoLockedDoors` -- "echo scan failed: Cannot index into a null array. -- off". Restored from 01918ea.
  **After any marker-to-marker replace, diff the file against the last commit and read every removed line.**
- **Characters invisible:** `cache\xaf-objects.json` (Initialize-CharacterIndex returns early without it) was only ever made
  by Find-LiveRoom with a game running. Install-Game now builds it offline (same scan of GAME\AZTEX\*.XAF; 178/179 identical
  to the dev PC's, EXTFIGHT is an empty file). Also `cache\portals.json` (map + echo doorways): Build-PortalMap, AFTER the
  room cache (it reads the room .obj exports) -- identical to the dev PC's.
- **Install took 19 min:** Apply-AztMod re-made all 94 book pages from the stock ones (10 min) only for the shipped pages to
  replace them: `-SkipBooks` (Install-Game passes it); the stock books are no longer placed.
- Cache files the renderer reads, checked against a fresh install: only portals.json and xaf-objects.json were build-time;
  room-numbers.json is learned in play (seed table), pickups.json optional.