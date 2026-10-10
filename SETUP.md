# Setting up a PC to work on RaptorMod

The repo holds everything that is code or hand-made and small: the patch source and manifest, the renderer, the art, the design sources, the room settings and the notes.

The big data travels separately, as an **asset pack**:
- the built game install;
- the hi-res textures;
- the book pages;
- Josh's 4K source art.

You make the asset pack once on a PC that has it all, and restore it on each new PC. After that, git does the day-to-day syncing.

## What a PC needs

| Requirement | Notes |
|---|---|
| Windows 10/11, 64-bit | Windows PowerShell 5.1 and .NET Framework 4.x are built in; nothing else to install for the scripts. |
| A GPU with OpenGL 4.5 | The renderer draws on the graphics card. Any recent AMD, NVIDIA or Intel GPU is fine. |
| Steam + *Azrael's Tear* | Installed in any Steam library. The repo is cloned **inside** the game's folder. |
| Git for Windows | `winget install --id Git.Git -e`. It includes Git Credential Manager, which signs you in to GitHub in the browser on the first fetch or push. |
| ~12 GB free on C: | About 6.5 GB for the restored assets plus room for the renderer's caches. The pack itself can stay on the external or cloud drive. |

**Paths are the same on every machine.** The tools assume these locations, so keep them:
- `C:\Games\AzraelsTear-Modded`
- `C:\Games\azrael-render`
- `C:\Games\azrael-textures`
- `C:\Games\azrael-inject`

The Steam library can live on any drive.

## 1. On the PC that has everything: make the asset pack (once, and again when big assets change)

```powershell
cd "<Steam library>\steamapps\common\Azrael's Tear\AztMod"
powershell -ExecutionPolicy Bypass -File tools\Export-AssetPack.ps1 -OutDir E:\raptormod-assets
```

This writes one `.tar` per component plus `pack.json`, about 6.5 GB, into the folder you name: an external drive, or a private cloud folder (OneDrive, Google Drive and so on).

**It contains a copy of the game, so keep it private.**

| Component | What | Size |
|---|---|---|
| `install` | `C:\Games\AzraelsTear-Modded`: the built game (DOSBox Staging, its conf and soundfont, extracted and upscaled textures, re-encoded movies, CD soundtrack, saves) | ~2.3 GB |
| `hires` | `C:\Games\azrael-textures\hires`: the renderer's hi-res textures | ~3.1 GB |
| `books` | `C:\Games\azrael-books`: the upscaled book pages | ~0.2 GB |
| `gfx` | Josh's sources in `C:\Games\azrael-gfx`: `decals\<ROOM>\updated`, `screens`, `credits` | ~0.2 GB |
| `notes` | Room Review's notes (JSON; screenshots left behind) | small |
| *(optional)* `audio`, `video`, `realesrgan` | Soundtrack and boot-sound sources, the MP4 movie sources, the upscaler. Only needed to rebuild the soundtrack or movies, or to run new upscales: `-Include all` | ~0.8 GB |

To refresh just one component later, for example after new textures:

```powershell
powershell -ExecutionPolicy Bypass -File tools\Export-AssetPack.ps1 -OutDir E:\raptormod-assets -Include hires -Force
```

## 2. On a new PC

```powershell
# 1. Steam + Azrael's Tear installed, Git installed (see above)
cd "<Steam library>\steamapps\common\Azrael's Tear"
git clone https://github.com/papertelevision/raptormod.git AztMod

# 2. restore the asset pack and set the PC up
powershell -ExecutionPolicy Bypass -File AztMod\tools\Setup-Machine.ps1 -AssetPack E:\raptormod-assets
```

`Setup-Machine.ps1` reports each step it takes. It:
- checks that the repo sits in the game folder;
- restores the pack (anything already present is left alone unless `-Force`);
- makes the `C:\Games\azrael-render\rooms` junction to the repo's `rooms\`;
- copies the palette;
- decodes the title music;
- installs the repo's patches into `C:\Games\AzraelsTear-Modded`;
- puts **"Azrael's Tear (Host Renderer - true colour)"** on the desktop.

Play from that shortcut. The renderer compiles itself on its first start, and builds its room caches (`C:\Games\azrael-render`) the first time it sees each room, so the first visit to a room is a little slower.

For Claude Code, open the session in the `AztMod` folder. It reads `CLAUDE.md`, which points it at the notes in `docs\notes`.

## 3. Day to day

- **The renderer** (`tools\`) runs straight from the repo. Pull, then play.
- **Room settings** (`rooms\*.json`) are read through the junction. Pull, then play.
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
- **Movies:** re-encoded from `C:\Games\azrael-video\update\*.mp4` with `tools\Convert-ToAnim.ps1`.
- **Soundtrack:** `AZT.CUE` plus `AZTRACK*` from `src\Build-Soundtrack.ps1`.
- **Title:** the black `TITLE.PCX`, from `src\Build-Title.ps1 -Import -InDir design\title-black`.

Turning this into one script is part of the future public patcher.
