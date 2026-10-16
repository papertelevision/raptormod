---
name: raptormod-repo
description: "AztMod is a git repo (github.com/papertelevision/raptormod, private; work on dev-next, main = approved) since 2026-10-10. Layout, what is out of git, the asset pack, the rooms junction, and docs/notes as the shared knowledge base."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-10T15:15:16.842Z
---

Josh (2026-10-10) wants to work from several PCs with a normal GitHub workflow. **AztMod is the repo root** (`<Steam>\steamapps\common\Azrael's Tear\AztMod`). Remote `origin` = https://github.com/papertelevision/raptormod.git (private), branch `main`.

**Local config:** repo-local user Josh Sears / josh@papertelevision.com; `core.autocrlf false`; `core.longpaths true`. Git for Windows 2.55 was installed via winget with Josh's OK; it lives at `C:\Program Files\Git\cmd\git.exe` (NOT on the PATH of already-open shells).

**In git (about 81 MB):** src, tools, art (as-is: its generators need realesrgan, Desktop audio and C:\Games sources), design (minus flat-art), rooms, runtime, docs, the manifest + overlay.sym, CLAUDE.md, SETUP.md, README.md.
- `.gitattributes` `* -text`: byte-exact, no EOL conversion.

**Out of git (`.gitignore`):**
- backups and snapshots: backup-*, checkpoints (they hold R.EXE copies), release, art-*-backup, *.pre-*, *.bak-*;
- tc-test;
- per-machine and obsolete manifests;
- art/title/title-music.wav: the MP3 is committed; tools\Setup-Machine.ps1 decodes it;
- game files: *.EXE, *.BIN, *.MOV, *.DAT.

**Moved into the repo:**
- `rooms\`: `C:\Games\RaptorMod\cache\rooms` is now a JUNCTION to it. The old folder is kept as `rooms.pre-repo-20261010`.
- `room-notes\` (2026-10-10, Josh: the Room Review app belongs in this repo): `C:\Games\RaptorMod\cache\room-notes` is now a junction to it. The JSON is versioned; `room-notes/*.png` screenshots are ignored and per PC (optional pack component `screenshots`). The old folder is kept as `room-notes.pre-repo-20261010`.
- The app itself (`tools\room-review\`, `Start-RoomReview.ps1`, the round/reply/restore tools, `Review-Rooms.cmd`, `.claude\launch.json`) was already in the initial import.
- Setup-Machine builds every room's export (tools\Build-RoomCache.ps1) so the viewer lists all 178 rooms on a fresh PC: the server only knows rooms whose OBJ exists.
- The palette: `runtime\azrael-palette.pal`. Setup copies it to C:\Games\RaptorMod\cache.

**Big data = the ASSET PACK** (`tools\Export-AssetPack.ps1 -OutDir <folder>`): one tar per component, restored by `tools\Setup-Machine.ps1 -AssetPack <folder>`.
- install: the built game, ~2.3 GB.
- hires: 3.1 GB.
- books, gfx sources.
- Optional: screenshots (Room Review's), audio, video and realesrgan.
- It contains the game, so it stays PRIVATE.

**Setup-Machine** (idempotent; also the post-pull refresh):
- checks the repo location;
- restores the pack;
- makes the rooms junction;
- copies the palette;
- decodes the title music;
- runs Apply-AztMod -Install and records manifest.installed;
- makes the desktop shortcut.

**Paths are fixed on every PC** (C:\Games\...); only the Steam library may differ.

**Knowledge base:** `docs\notes\` is a snapshot of this memory folder, and CLAUDE.md tells sessions on other PCs to read it. **When a note changes here, copy it to docs\notes and commit**, or the PCs drift.

**Old README** (v0.1.0): rewritten. What was left of it is in docs\readme-v0.1-recovered.md; the 0.12.3 public README is in docs\public-readme-0.12.3.md.

Fixes made along the way:
- Build-HudV3/New/Wide/Overlay/Repalette default the stock game path in the body from $PSCommandPath ([[azrael-powershell-silent-traps]]).
- Apply-AztMod's fresh copy skips AztMod and .claude.

**Branches (2026-10-10, Josh: "adhere to the new github workflow"):** work happened on `dev` (tracking origin/dev) until 2026-10-13; since then on `dev-next` (below). `main` is the approved state: merge only when Josh says so. NO commits or pushes, and no asking to push, until Josh says so (2026-10-10). CLAUDE.md says the same.

**Private for good (Josh, 2026-10-13):** "This repo will never go public, I'm going to have a separate distributable git for that later." RaptorMod is a free community patch/mod (never sold). So publisher material Josh approves may live here -- the in-game manual's text (`raptordocs\`) does; the classified scans still do not. Game files (R.EXE, AZT.BIN, movies) never do. A public distribution repo is a separate, later job: decide there what it may carry.

**Branches since 2026-10-13:** PR #1 (dev -> main) was SQUASH-merged by Josh's say (main = 24e96e2). Work now continues on **`dev-next`**, cut from that main (same tree as the old dev). The old `dev` was deleted (GitHub and local) the same day at Josh's request; branches now: `main` + `dev-next`. Commit / push / PR only when Josh says; no mention of Claude / Claude Code in commit messages, PR titles or descriptions (Josh, 2026-10-13), and no attribution lines.

**Second PC, one step (2026-10-14, Josh: "plan what's needed so I can easily patch the steam version of the game on another machine with this entire mod"; play + develop).**
- **The pack lives on the NAS:** `\\DXP2800GT-7649\personal_folder\Projects\AzraelsTear\assets`.
  - It is the full pack (`-Include all`, ~12.8 GB). `hires` alone is now 5.9 GB.
  - New optional components: `rmfiles` (Desktop\RaptorModFiles) and `gfxextra` (decals\<ROOM>\4k-2k + wire, ~3 GB).
  - Export-AssetPack copies `tools\Install-RaptorMod.ps1` and `.cmd` next to the tars.
- **New PC:** install Steam and the game, then double-click `Install-RaptorMod.cmd` on the NAS. It:
  - finds the Steam game (registry + libraryfolders.vdf);
  - installs Git with winget if it is missing;
  - clones `-b dev-next` into `<game>\AztMod` (pulls if it is already there);
  - runs Setup-Machine with the NAS pack. `-DryRun` only prints.
- **Setup-Machine additions:**
  - the repo-local git settings, where unset;
  - a screenshots restore that works on a fresh clone (present = its PNGs);
  - the title-music decode in try/catch (Windows N without Media Foundation);
  - a Room Review shortcut;
  - a final launcher dry run (`AZT_DRYRUN`).
- **TRAP (fixed):** Setup-Machine ran Build-RoomCache IN-PROCESS after Apply-AztMod. The install had already Add-Type'd `LeTool.Quant`, so the cache step failed ("type name already exists") on every fresh setup. It now runs in its own `powershell.exe`.
- **Authoring paths no longer hard-code `C:\Users\josh`:** Build-Soundtrack and Make-LoadingAudio use the Desktop folder.
- **Cleanup before the first NAS pack (2026-10-14, Josh: "clean everything up before pushing to the repo and NAS").** Nothing was hard-deleted: every removed file went to `C:\Games\_cleanup-2026-10-14` with its path kept. `moved.txt` lists them; Josh empties it once satisfied.
  - **Install:** `GAME\MOV\_new` (666 MB, exact copies); `R.EXE.pre-*`; CD-audio tests; conf backups; capture/logs.
  - **Decal sources:** the `_2k` halves (706 MB).
  - **RaptorModFiles copies:** Real-ESRGAN, `title_4k.png`, `opening.mp4`, `.blend1`.
  - **Repo working folder:** ALL Room Review screenshots; `backup-pre-*`, `tc-test`, `checkpoints`, old manifests.
  - **Local caches and test output:** `upscale-work`, `hires-2048` (rebuilds), azrael-render test folders and the `pre-repo` copies, `opening-check`/AVIs.
  - **design\:** the 93 files no script reads (by name or folder).
- **KEPT, contrary to the first survey:**
  - **ChatGPT*.png in design\incoming:** `Build-HudBox` picks the newest by glob.
  - **design\incoming\lurka\*.png:** `Texture-Tool -InDir`.
  - **The 76 duplicate hi-res character-art files.** They are at exactly 4x their originals, so TexTwins counts them as OLD UPSCALE and never aliases them. Dropping one would show that leaf's low-res original. Check IsNewArt before removing any "duplicate" hires leaf.
- **Screenshots** are no longer a pack component.
- **`art\wide\bg8.bin` / `modes.bin`** (read by the renderer) were caught by `*.BIN` in .gitignore and never reached git. They are now un-ignored (`!art/wide/*.bin`).
- **Build-Soundtrack's `-Src`** now defaults to Desktop\AzraelTearSoundtrack (the same 11 MP3s as `music-export`, and packed as `audio`).
- **PowerShell trap:** a helper named `H` is `h` = Get-History (like `R`); inside `Group-Object { H ... }` it failed with "Cannot bind parameter 'Id'".
- **NAS TRAP (measured 2026-10-15):** `tar.exe` writing straight to the NAS ran at 2.2 MB/s, because its 10 KB records each wait on SMB over Wi-Fi. `robocopy /J` to the same share ran at 58 MB/s.
  - **The fix:** Export-AssetPack builds each tar in `%TEMP%\raptormod-pack-stage` and robocopies it over (size-checked), so the whole pack takes ~3 minutes. Setup-Machine copies each tar down the same way before unpacking.
  - **The first full pack:** 9 components, 10.9 GB, from repo f377038. Every tar lists cleanly, and a test restore of `books` from the NAS matched 83/83 files.
- **2026-10-15: ONE install folder.** Everything that is not the repo is under `C:\Games\RaptorMod` (see [[azrael-install-layout]]). The pack restores into it; Setup-Machine moves an older layout in and leaves ONE desktop shortcut.
- **2026-10-15: dev-next squash-merged into main (4019f83 = the DOSBox version 1.0 backup; dev-next d86379e has the same content). The NEXT PHASE (staged native rebuild) is branch `native`, from main, checked out as a git WORKTREE in the all-new folder `C:\Games\RaptorMod-Native\AztMod` (Josh: "an all new file folder ... I want to maintain a dosbox version"). The Steam-folder checkout stays on dev-next and `C:\Games\RaptorMod` stays as it is -- never build or install the native work into them.**
