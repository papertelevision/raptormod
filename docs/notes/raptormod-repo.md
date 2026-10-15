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
- `rooms\`: `C:\Games\azrael-render\rooms` is now a JUNCTION to it. The old folder is kept as `rooms.pre-repo-20261010`.
- `room-notes\` (2026-10-10, Josh: the Room Review app belongs in this repo): `C:\Games\azrael-render\room-notes` is now a junction to it. The JSON is versioned; `room-notes/*.png` screenshots are ignored and per PC (optional pack component `screenshots`). The old folder is kept as `room-notes.pre-repo-20261010`.
- The app itself (`tools\room-review\`, `Start-RoomReview.ps1`, the round/reply/restore tools, `Review-Rooms.cmd`, `.claude\launch.json`) was already in the initial import.
- Setup-Machine builds every room's export (tools\Build-RoomCache.ps1) so the viewer lists all 178 rooms on a fresh PC: the server only knows rooms whose OBJ exists.
- The palette: `runtime\azrael-palette.pal`. Setup copies it to C:\Games\azrael-inject.

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
