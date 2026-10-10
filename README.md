# RaptorMod -- *Azrael's Tear* (1996), remastered in place

A private working repo for **RaptorMod**, a modernisation of *Azrael's Tear* (Intelligent Games / Mindscape) running on DOSBox Staging, for the Steam release.

## What it is

**A patcher for the game's `R.EXE`.**
- `src\Build-AztMod.ps1` assembles x86 patches and an overlay of new code into `AztMod.manifest.json`.
- `Apply-AztMod.ps1` installs that into a **copy** of the game at `C:\Games\AzraelsTear-Modded`. The Steam install is never modified.
- The patches add, among other things:
  - mouselook;
  - widescreen and high resolution;
  - a new HUD;
  - the visor boot sequence;
  - the title menu;
  - save and load screens;
  - the system menu;
  - CD soundtrack support.

**A host renderer.** `tools\Watch-HostRender.ps1` and `tools\*.cs`:
- read the running game's memory and draw the 3D view on the GPU in true colour, with hi-res textures, lighting, shadows, GI, fog and water;
- draw the visor's interface over DOSBox.

Per-room look settings live in `rooms\*.json`.

## Start here

| | |
|---|---|
| Setting up a PC | [`SETUP.md`](SETUP.md) |
| Play | `Play-HostRender-TrueColour.cmd` (the desktop shortcut that `tools\Setup-Machine.ps1` makes) |
| Install or refresh the patches | `.\Apply-AztMod.ps1 -Install -Dest C:\Games\AzraelsTear-Modded` (game closed), or re-run `tools\Setup-Machine.ps1` |
| Room look review | `Review-Rooms.cmd` (a local 3D viewer with click-to-note) |
| How things work | `docs\notes\MEMORY.md` (the project's notes, by topic) and `docs\*.md` (reverse-engineering write-ups) |
| Working with Claude | [`CLAUDE.md`](CLAUDE.md) |

## Layout

| Path | Contents |
|---|---|
| `src\` | The patch build (`Build-AztMod.ps1`, `Asm.ps1`) and the art and asset builders (`Build-Hud*`, `Build-Title`, `Build-Soundtrack`, ...) |
| `tools\` | The renderer (`Watch-HostRender.ps1` + C#), RE tools (`load.ps1`, `Disasm.cs`, `LeTool.cs`), Room Review, machine setup and the asset pack |
| `art\` | Built art the installer copies into the game, plus the renderer's title, loading, boot and panel art |
| `design\` | Hand-made art sources the art builders read |
| `rooms\` | Per-room renderer settings (`C:\Games\azrael-render\rooms` is a junction to here) |
| `runtime\` | The install's hand-made configs (DOSBox Staging conf, MDI.INI, RESOURCE.CFG) and the palette |
| `docs\` | Write-ups and the notes |
| `AztMod.manifest.json`, `AztMod.overlay.sym` | **Generated** by `Build-AztMod.ps1`, committed, because the installer and renderer need them. Rebuild and commit them together. |

Game files (`R.EXE`, `AZT.BIN`, movies, the install) are never committed.
