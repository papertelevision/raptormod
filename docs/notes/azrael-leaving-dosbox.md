---
name: azrael-leaving-dosbox
description: "What leaving DOSBox would take (assessed 2026-10-11): Tier 1 = an emulator core inside our own app (CHOSEN for RaptorMod 2.0), Tier 2 = run R.EXE natively (not recommended), Tier 3 = Unity/native reimplementation (blocked on the unreversed story layer). Not started."
metadata:
  type: project
---

Josh (2026-10-11): "What would it take to fully leave dosbox behind for this game in its current state?" He then chose **option 1 (Tier 1)** for **RaptorMod 2.0**, after 1.0 ships on DOSBox ([[raptormod-roadmap]]). Not started.

**Where things stood when assessed.** Only PRESENTATION is on the host:
- the 3D view, boot, title and loading screens;
- the HUD art and its decoded text, the menus, the scanner and the cursors.

These are drawn into click-through topmost windows over DOSBox ([[azrael-true-colour]]). Everything else runs inside DOSBox:
- the simulation and collision;
- event and NPC scripts, conversations, inventory, AI;
- every game sound:
  - Miles AIL: the library is in R.EXE, the `.DIG`/`.MDI` drivers are separate 16-bit files;
  - SB16, and MPU-401 → FluidSynth;
  - the CD soundtrack via MSCDEX ([[azrael-music]], [[azrael-gun-sound]]);
- movies and saves;
- timing: frame-tied, the BIOS tick 0x46C, the PIT reprogrammed by the game's INT 8 ([[azrael-frame-tied-timing]]).

The host reaches it through ReadProcessMemory / WriteProcessMemory, string needles and handshakes ([[azrael-host-guest-bridge]]). Memory is capped at memsize 32, and the heap fragments ([[azrael-texture-cache-reserve]]).

## Tier 1 -- an emulator core inside OUR app (CHOSEN for 2.0)
- **What:** the patched R.EXE runs in an emulation core loaded into our process, which renders into one window of ours.
  - (a) a libretro DOSBox core (e.g. DOSBox Pure, a prebuilt 64-bit DLL) driven from C# through the libretro C API (`retro_run`, video/audio/input callbacks, memory access); or
  - (b) DOSBox Staging built from source with an embedding API. This needs a C++ toolchain, which the dev machine lacks.
- **Effort:** weeks; low-to-medium risk. 100% compatible, because the same code runs on the same emulated hardware.
- **Gains:**
  - One window: the overlay windows go, along with the z-order fights (cursor window, title cover, panel window), click-through and focus hacks.
  - Guest RAM by pointer.
  - SYNCHRONOUS frames: step the guest to its frame boundary, then draw. That ends torn reads, `aztInjSync`, the flicker guards, the `Panel.Steady` hold logic and the key-colour reading.
  - Our own input: full-width mouse mapping, controllers, rebinding; the Space guard becomes a plain filter.
  - Our own audio mixer. Pausing = not stepping, so "never suspend DOSBox" stops mattering.
  - Save states and in-process debugging.
- **Costs:**
  - Still an emulated CPU (the guest loop ~70-150 fps is the ceiling for logic; fine, the host renders).
  - GPL cores, which matter for the public patcher.
  - Downloading a core or installing a toolchain needs Josh's OK.
  - The host becomes a compiled C# app (out of PowerShell + Add-Type).
  - The core must match Staging's VESA 0x120, MPU-401 + soundfont, CD-image soundtrack and dynamic core.
- **GPU mode:** the same look, clean plumbing. **Retro:** still the authentic 8-bit rasteriser, shown in our window with our scaler/shader.
- **Start with a spike:**
  - boot the patched game in the core inside our window;
  - show its 8-bit frames;
  - read guest RAM by pointer;
  - route keyboard and mouse.

## Tier 2 -- run R.EXE's x86 code natively (NOT recommended)
- **What:** a 32-bit process loads the LE image (tools\LeTool.cs already loads it and applies fixups) and runs the code on the CPU. The DOS/4GW and hardware services are reimplemented (INT 21h, 31h, 33h + the 0x3584F callback, VESA/LFB, the DAC, PIT/IRQ0, the keyboard ISR 0x362BB, MSCDEX) and trapped with a vectored exception handler. Hot sites (the palette upload 0x353A0, etc.) are patched into direct host calls.
- **The Miles drivers** are 16-bit real-mode code, so AIL would need replacing at its API.
- **Effort:** months; high risk:
  - interrupt delivery;
  - DPMI selector loads that WoW64 cannot honour;
  - the hardware long tail.
  - Windows/x86 only, and it would need the game run repeatedly while developing.
- **Its unique win:** a fast authentic Retro (the native rasteriser, instead of ~22-24 fps), and no 32 MB cap.

## Tier 3 -- reimplement (Unity / native), the long-term destination
- **Ready today:** every room loads, renders and can be walked, with characters, movies, music and texts. The data formats are decoded.
- **NOT reverse engineered at all -- the story layer:**
  - the event-script interpreter (~0x2A000..0x2D500, no opcode table);
  - NPC action programs (0x261C0);
  - conversation trees and flags (`WORLD.DAT` 348 KB; COLIN/EDGAR/GEFFRYE/JACK/KURT/LURKA/NIAMH/PHILIP/SAILOR/TALLUM/TOBIAS/VINCENT `.DAT`);
  - puzzles (`PUZZLES.DAT` 1.1 MB) and use-with rules;
  - enemy AI (Lurka, scorpion, raptor);
  - cutscene conditions and the automap (`MAPS.DAT`);
  - save contents (`SAVE%d.dat`, `CON%d`/`NPC%d`/`RANIM%d`);
  - `FLAGLIST.DAT`, `NAMES.DAT`, `OBJLIST.DAT`, `CHARS.DAT`.
- **Retro can't stay authentic** (the original rasteriser is gone). Keep a Tier 1 build as "Classic".
- **The Tier 1 core can be Unity's simulation backend,** so systems are swapped one at a time instead of a big-bang rewrite ([[azrael-project-direction]]).

Related: [[raptormod-roadmap]], [[azrael-overlay-read-limit]], [[azrael-opengl-verdict]] (pre-host-renderer; its "fork DOSBox" blocker is what Tier 1 accepts).

## 2026-10-15 UPDATE -- the plan is now a STAGED NATIVE REBUILD (Josh), DEFERRED
**Josh's decisions:**
- **End state:** no emulator at all. RaptorMod becomes its own C# program running the game's logic natively, reached in stages.
- **Retro mode stays, but on the GPU:** original textures, palette and dither, low internal resolution, nearest filtering, an optional CRT pass. It no longer needs the game's own 8-bit rasteriser. So Tier 3's "Retro can't stay authentic" objection no longer blocks anything.
- **Licensing:** GPL/emulator code is not a concern for him (a free mod for the Steam game).

**WHEN: deferred.** It starts only after Josh's final tweaks to the current version are done and dev-next is pushed and merged.

**WHERE: CRITICAL.**
- The rebuild lives in an **ALL-NEW folder**: its own repo/worktree and its own install folder.
- **Never** the AztMod repo's working tree or `C:\Games\RaptorMod`.
- The current DOSBox version stays intact as the working backup.

**The stages** (full report: the session plan file of 2026-10-15; summary here):
- **Stage 0 (2-4 wk):** a compiled host, RaptorMod.exe (.NET SDK, with Josh's OK), with the PowerShell watcher ported. Still drives DOSBox.
- **Stage 1 (4-8 wk):** a libretro core (DOSBox Pure x64; download with Josh's OK) inside RaptorMod.exe.
  - One window, synchronous frames, RAM by pointer.
  - Our input; no memory cap.
  - Music and movies native (the cue byte 0x152AD0 -> MP3 / our FluidSynth; AnimTool movies).
  - Retro = the GPU retro look; the game's rasteriser off (aztSup3D).
  - Starts with a 1-week spike (boot, frames, RAM, input; VESA 0x120 + LFB is the go/no-go).
- **Stage 2 (~5-9 months, the bulk):** hollow out R.EXE one system at a time. Each native C# system runs in LOCKSTEP with the core (the core is the oracle: a per-tick state comparison) before it takes over. The game's own data files are INTERPRETED, never rewritten by hand. Order:
  1. sound effects;
  2. movement, collision, falling, lifts;
  3. doors and the event-script VM (0x2AC9C);
  4. conversations;
  5. NPC programs and AI;
  6. inventory, use-with, puzzles;
  7. saves, with an importer for the old saves.
- **Stage 3 (1-2 wk):** remove the core. RaptorMod still reads the Steam copy's data files and never ships them.

**INVENTORY CORRECTIONS (2026-10-15):**
- **The script VM is found:** the jump table at 0x2AC9C, opcodes 0..0x28; op 08 add inventory, 09 remove, door moves, collision re-bake, HUD messages ([[azrael-map-3d]]). "No opcode table" above is stale.
- **MAPS.DAT is decoded** ([[azrael-map-3d]]).
- **Plain text** (a much smaller job than "348 KB binary" suggested):
  - the 12 character dialogue `.DAT` files (~160 KB: node ids, 5-integer condition/effect tuples, lines, voice ids);
  - `CON%d`/`NPC%d.DAT`, `FLAGLIST.DAT`, `OBJLIST.DAT`.
- **Genuinely binary:** only `WORLD.DAT` (348 KB), `PUZZLES.DAT` (1.1 MB) and `NAMES.DAT` (113 KB).
- **"Every room can be walked, with characters" overstated it.** Room Review's walk uses its own approximate collision, and characters are drawn at rest pose or as scan wireframes only.
