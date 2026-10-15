# Setting up a PC to work on RaptorMod

The repo holds everything that is code or hand-made and small: the patch source and manifest, the renderer, the Room Review app, the art, the design sources, the room settings, Room Review's notes and the project notes.

The big data travels separately, as an **asset pack**:
- the built game install;
- the hi-res textures;
- the book pages;
- Josh's 4K source art.

You make the asset pack once on a PC that has it all, and restore it on each new PC. After that, git does the day-to-day syncing.

**The pack lives on the NAS:** `\\DXP2800GT-7649\personal_folder\Projects\AzraelsTear\assets`. On a new PC, the whole setup is: install Steam and the game, then double-click **`Install-RaptorMod.cmd`** in that folder (section 2).

## What a PC needs

| Requirement | Notes |
|---|---|
| Windows 10/11, 64-bit | Windows PowerShell 5.1 and .NET Framework 4.x are built in; nothing else to install for the scripts. |
| A GPU with OpenGL 4.5 | The renderer draws on the graphics card. Any recent AMD, NVIDIA or Intel GPU is fine. `Play-HostRender-TrueColour.cmd` draws the 3D at up to 5.5 M pixels (`-TcMaxPixels 5500000`, tuned for a 4K screen); on a weaker GPU lower that number in the .cmd (3200000 was the old default). |
| Steam + *Azrael's Tear* | Installed in any Steam library. The repo is cloned **inside** the game's folder. |
| Git for Windows | `winget install --id Git.Git -e`. It includes Git Credential Manager, which signs you in to GitHub in the browser on the first fetch or push. |
| ~16 GB free on C: | About 8 GB for the restored default assets (10.9 GB with every optional part), plus the renderer's caches (room cache ~0.3 GB, lighting bakes, the 2K texture tier ~0.9 GB if used). The pack itself stays on the NAS. |

**Everything lives in ONE folder, `C:\Games\RaptorMod`, the same on every machine** (the tools assume it, so keep it):
- `game\`: the patched game (`Play-Azrael-Modded.bat` there starts the GPU version, `Play-Azrael-8bit.bat` the plain game)
- `cache\`: the renderer's caches, `watch.log`, the palette; `rooms\` and `room-notes\` link to the repo
- `textures\`: the hi-res textures
- `sources\`: books, art, video, the upscaler, the soundtrack, Josh's working files
- `Play RaptorMod.cmd` and `Room Review.cmd`, and ONE desktop shortcut, **RaptorMod**

Nothing else goes on the desktop. An older layout (`C:\Games\azrael-*`, `C:\Games\AzraelsTear-Modded`, the Desktop source folders) is moved into this folder by `Setup-Machine.ps1`.

The Steam library can live on any drive.

## 1. On the PC that has everything: make the asset pack (once, and again when big assets change)

```powershell
cd "<Steam library>\steamapps\common\Azrael's Tear\AztMod"
powershell -ExecutionPolicy Bypass -File tools\Export-AssetPack.ps1 -OutDir "\\DXP2800GT-7649\personal_folder\Projects\AzraelsTear\assets" -Include all
```

Close the game first. This writes one `.tar` per component plus `pack.json` (about 8 GB by default, 10.9 GB with `-Include all`) into the folder you name, and copies `Install-RaptorMod.ps1` / `.cmd` next to them. To a network folder (the NAS) each tar is built on this PC and copied over with `robocopy /J`: tar's own 10 KB writes over SMB ran at 2 MB/s, robocopy at ~60 MB/s, so the whole pack takes ~3 minutes. Setup copies each tar down the same way before unpacking it. Before packing, make sure the install is current: run `Apply-AztMod.ps1 -Install -Dest C:\Games\RaptorMod\game` (or `Setup-Machine.ps1` with no pack).

**It contains a copy of the game, so keep it private.**

| Component | What | Size |
|---|---|---|
| `install` | `C:\Games\RaptorMod\game`: the built game (DOSBox Staging, its conf and soundfont, extracted and upscaled textures, re-encoded movies, CD soundtrack, saves) | ~1.7 GB |
| `hires` | `C:\Games\RaptorMod\textures\hires`: the renderer's hi-res textures | ~5.9 GB |
| `books` | `C:\Games\RaptorMod\sources\books`: the upscaled book pages | ~0.2 GB |
| `gfx` | Josh's sources in `C:\Games\RaptorMod\sources\gfx`: `decals\<ROOM>\updated`, `screens`, `credits` | ~0.2 GB |
| *(optional)* `audio`, `video`, `realesrgan` | Soundtrack and boot-sound sources, the MP4 movie sources, the upscaler. Only needed to rebuild the soundtrack or movies, or to run new upscales: `-Include all` | ~0.4 GB |
| *(optional)* `rmfiles` | `C:\Games\RaptorMod\sources\files`: Josh's working files (3D, audio, updated art, the opening MP4s) | ~0.5 GB |
| *(optional)* `gfxextra` | `azrael-gfx\decals\<ROOM>\4k-2k` (the 4K decal masters the hi-res textures are fitted from; their `_2k` halves are not kept) and `wire` | ~2.4 GB |

To refresh just one component later, for example after new textures:

```powershell
powershell -ExecutionPolicy Bypass -File tools\Export-AssetPack.ps1 -OutDir E:\raptormod-assets -Include hires -Force
```

## 2. On a new PC

1. Install Steam and *Azrael's Tear* (any library).
2. Double-click `\\DXP2800GT-7649\personal_folder\Projects\AzraelsTear\assets\Install-RaptorMod.cmd`. It:
   - finds the Steam game folder;
   - installs Git with winget if it is missing (answer winget's prompts);
   - clones the repo on `dev-next` into `<game folder>\AztMod` (GitHub asks you to sign in once: the repo is private);
   - runs `Setup-Machine.ps1` with the pack from the NAS (10.9 GB to restore).

   `Install-RaptorMod.cmd -DryRun` (from a command prompt) shows what it would do and changes nothing.

By hand, the same thing is:

```powershell
cd "<Steam library>\steamapps\common\Azrael's Tear"
git clone -b dev-next https://github.com/papertelevision/raptormod.git AztMod
powershell -ExecutionPolicy Bypass -File AztMod\tools\Setup-Machine.ps1 -AssetPack "\\DXP2800GT-7649\personal_folder\Projects\AzraelsTear\assets"
```

`Setup-Machine.ps1` reports each step it takes. It:
- sets the repo's local git settings (`core.autocrlf false`, `core.longpaths true`, the author) where they are unset;
- checks that the repo sits in the game folder;
- restores the pack (anything already present is left alone unless `-Force`);
- makes the `C:\Games\RaptorMod\cache\rooms` and `\room-notes` junctions to the repo's `rooms\` and `room-notes\`;
- copies the palette;
- decodes the title music;
- installs the repo's patches into `C:\Games\RaptorMod\game`;
- builds every room's cached 3D export, which Room Review's viewer shows (a few minutes the first time);
- prepares the textures (the shared-art index, every hi-res texture read once: a fresh PC's first room otherwise took a minute) and checks the graphics card (`tools\Test-GpuCaps.ps1`);
- writes `Play RaptorMod.cmd` and `Room Review.cmd` into `C:\Games\RaptorMod` and puts ONE shortcut, **RaptorMod**, on the desktop (older RaptorMod shortcuts are removed);
- dry-runs the launcher (every step checked, nothing started).

If the title music cannot be decoded (Windows N editions lack Media Foundation: install the Media Feature Pack), setup warns and carries on; the title is then silent.

Play from that shortcut. The renderer compiles itself on its first start, and builds its room caches (`C:\Games\RaptorMod\cache`) the first time it sees each room, so the first visit to a room is a little slower.

For Claude Code, open the session in the `AztMod` folder. It reads `CLAUDE.md`, which points it at the notes in `docs\notes`.

## 3. Day to day

- **The renderer** (`tools\`) runs straight from the repo. Pull, then play.
- **Room settings** (`rooms\*.json`) are read through the junction. Pull, then play.
- **Room Review** (`Review-Rooms.cmd`) works on any PC once it's set up. Its notes (`room-notes\*.json`) are in git: commit and push after submitting a round on one PC, and pull before reviewing on another. Each PC keeps its own screenshots.
- **Patches or art changed** (the pull touched `AztMod.manifest.json` or `art\`): close the game and run `tools\Setup-Machine.ps1` again with no `-AssetPack`. It reinstalls the patches and art and records the installed manifest. `Install-Update.cmd` also works for patch-only changes.
- **Big assets changed on another PC:** re-export that component there, then on this PC run `Setup-Machine.ps1 -AssetPack <folder> -Force`.
- **Not synced:**
  - saves (`GAME\AZRAEL\SAVE*.DAT` inside the install) belong to the PC, unless you re-pack `install`;
  - `watch.log` and the renderer's caches stay on each PC.

## Building the install from scratch (no pack)

`Apply-AztMod.ps1 -Install` alone produces a playable patched game, but not the full current setup. These steps were done by hand or by separate scripts, and the `install` component carries their results:
- **DOSBox Staging:** put DOSBox Staging 0.83 in `DOSBOX-STAGING\`, with `runtime\azrael-staging.conf` and the GeneralUser-GS soundfont in `soundfonts\`.
- **Configs:** `runtime\azrael-game.conf`, `runtime\MDI.INI` (General MIDI) and `runtime\RESOURCE.CFG` copied into the install.
- **Extracted textures:** `GAME\AZTEX` extracted from `AZT.BIN` with `tools\Read-CdImage.ps1`, then upscaled with `tools\Upscale-Budgeted.ps1`.
- **Movies:** re-encoded from `C:\Games\RaptorMod\sources\video\update\*.mp4` with `tools\Convert-ToAnim.ps1`.
- **Soundtrack:** `AZT.CUE` plus `AZTRACK*` from `src\Build-Soundtrack.ps1`.
- **Title:** the black `TITLE.PCX`, from `src\Build-Title.ps1 -Import -InDir design\title-black`.

Turning this into one script is part of the future public patcher.
