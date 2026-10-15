# RaptorMod (AztMod) -- notes for Claude

A mod for *Azrael's Tear* (1996, DOS/4GW, run in DOSBox Staging), built as:
- a **binary patcher** for the game's `R.EXE`: `src\Build-AztMod.ps1` assembles the patches into `AztMod.manifest.json`, and `Apply-AztMod.ps1` installs it into a COPY of the game at `C:\Games\AzraelsTear-Modded`;
- a **host GPU renderer**: `tools\Watch-HostRender.ps1` plus the C# in `tools\*.cs`. It reads the running game's memory and draws the 3D view, HUD, visor effects and menus in true colour over DOSBox.

Josh (the owner) plays and judges everything in game. This repo is the private working repo; a public patcher comes later.

## The knowledge base -- read it

`docs\notes\MEMORY.md` is the index of the project's notes (RE findings, decisions, traps, per-feature history), one file per topic.
- **Read the notes for the area you are about to touch before changing it.** Most "obvious" ideas there were already tried, measured or rejected.
- When you learn something durable, update or add a note in `docs\notes` (and its line in `MEMORY.md`) and commit it with the work.
- Code comments cite notes as `[[azrael-...]]`.

Other docs:
- RE write-ups in `docs\*.md`.
- Machine setup: `SETUP.md`.

## Standing rules (Josh's)

**Running things**
- **Never launch the game or the renderer/watcher yourself.** Install, verify, report, stop. Josh launches.
- **Stop any running watcher** before changing its code, and confirm none is left running.
- **Never suspend or freeze DOSBox.** It kills Sound Blaster audio for the session.

**What to build**
- **Josh judges looks in game.** Offline renders are for your own checking; produce comparison images only when asked.
- **Nothing may be tuned to one machine.** No resolution, GPU or path assumptions beyond `SETUP.md`'s layout.
- **F10 must stay unbound.**
- **Room lights are placed by Josh.**
- **GPU (true colour) mode is the product.** `-Retro` (8-bit) must keep working but gets no new features.
- **Do not re-propose:**
  - AI/ESRGAN model changes, 8x upscales or "Detail/Clarity" passes (FOV is now Josh's: 60 by default, F12 50/60/70 -- `docs\notes\azrael-fov.md`);
  - frame interpolation, smoother models or subdivision;
  - a pale ground mist in MINEMAZE;
  - the LURKA push-pull black fill.

**Patching**
- **DOSBox runs core=dynamic:** never patch game CODE at run time. Data writes from the host are fine; code changes go through the manifest.
- **The manifest, not the build script, is what installs.** After editing `src\Build-AztMod.ps1`:
  1. build: `& .\src\Build-AztMod.ps1 -OutFile $env:TEMP\x.json`;
  2. diff it against `AztMod.manifest.json`;
  3. copy BOTH `$env:TEMP\x.json` and `$env:TEMP\AztMod.overlay.sym` over the repo copies;
  4. install with `.\Apply-AztMod.ps1 -Install -Dest C:\Games\AzraelsTear-Modded` (DOSBox closed).
  Commit the manifest and `AztMod.overlay.sym` together.
- **Never overwrite a fixed-up operand.** Check `Test-FixupsIn` (`tools\load.ps1`, `tools\helpers.ps1`). `Assert-NoOverlap` fails the build on overlapping patches.

**PowerShell traps** (see `docs\notes\azrael-powershell-*.md`)
- Read and write files with `[IO.File]::ReadAllText` / `WriteAllText`, never `Get-Content` + `Set-Content`. Keep each file's BOM state as it is.
- Comma binds tighter than arithmetic: `@($a, ($b + 1))`.
- `$PSScriptRoot` is empty in a top-level `param()` default under `powershell -File`: default to `''` and fill it in the body from `$PSCommandPath`.
- The path contains `Azrael's Tear`: an apostrophe and spaces. Quote it.

## Layout (identical on every machine -- see SETUP.md)

| Path | What it is |
|---|---|
| `<Steam>\steamapps\common\Azrael's Tear\AztMod` | **This repo.** The build reads the stock game from `..\GAME\AZRAEL`. |
| `C:\Games\AzraelsTear-Modded` | The built, patched game: DOSBox Staging, extracted AZTEX, movies, soundtrack. Not in git. |
| `C:\Games\azrael-render` | The renderer's caches and `watch.log`. Its `rooms\` and `room-notes\` are junctions to this repo's `rooms\` and `room-notes\`: room settings and Room Review notes are versioned, and their screenshots are ignored. |
| `C:\Games\azrael-textures\hires` | Hi-res texture overrides (~3 GB). Not in git; comes with the asset pack. |
| `C:\Games\azrael-inject\azrael-palette.pal` | Copied from `runtime\` by `tools\Setup-Machine.ps1`. |

## Git

- **Branches:** work happens on `dev-next` (cut from `main` after PR #1 was squash-merged, 2026-10-13; the old `dev` is deleted). `main` is the last state Josh has played and approved: merge into it only when he says so. No mention of Claude / Claude Code in commit messages or PRs, and no attribution lines (Josh, 2026-10-13).
- **Do not commit or push, and do not ask to (Josh, 2026-10-10: "please dont commit or ask me to push as we make changes. I'll tell you when I want to commit").** Leave changes in the working tree; when he says commit, commit what is there with a message saying what changed and why.

- Byte-exact (`.gitattributes`: `* -text`).
- **Never commit game files:**
  - `R.EXE`, `AZT.BIN`, movies and the install folder are not ours to commit;
  - `.gitignore` blocks `*.EXE` / `*.BIN` / `*.MOV` / `*.DAT`.
- Big binary assets go in the asset pack (`tools\Export-AssetPack.ps1`), not git.
- `AztMod.manifest.installed.json` is per machine. It is ignored.
- **Room Review rounds:** after replying to notes (`tools\Reply-RoomNote.ps1`) and editing `rooms\*.json`, commit both, so the other PCs see the replies and the changes together.
