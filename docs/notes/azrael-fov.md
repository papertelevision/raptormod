---
name: azrael-fov
description: "Field of view 60 (2026-10-13): the GAME's Reality Lab field is set every frame from a host-written tan (overlay AztFovTick, aztFovTan), so the game's pick/clicks stay lined up with the host's wider picture; F12 cycles 50/60/65/70 (Josh plays at 65: raptormod-settings.json "fov"); -Retro = the original 50. RL field = half-extent of the viewport's LONGER side; 4 SetField(0.8) sites, never changed at run time."
metadata:
  type: project
---

Josh (2026-10-13): the 50 degrees "is a major reason why this game still doesn't feel modern ... Increasing it to 70 would be a great first step". The plan's question: 70 vertical is ~111 degrees across his widescreen picture. **He chose 60 vertical as the default** (~90 across the game's band, ~100 across the widescreen), with **F12 cycling 50 / 60 / 70** to judge, and **-Retro staying at the original 50**. **Built and installed 2026-10-13; checked offline; NOT yet seen in game.**

## Why it was not done before, and why it works now
2026-10-05 ([[azrael-true-colour]]): Josh asked for 70; it was declined because only the HOST's picture would widen -- objects would be drawn away from where the game hit-tests, so clicks, hover cursors and shots would miss. Now the **game's own field changes with it**:
- The game's cursor pick (`0x116E4` -> `0x3BBC4` -> `0x3C1A4` -> `0x59404` / `0x58FE4`) reads the viewport's field LIVE. There is no FOV constant in the game's own code. So pick, render and host agree at any angle.

## The engine's field (static analysis of R.EXE)
- **The setter:** Reality Lab `SetField` = `0x3A8A0`.
  - Watcom: `EAX` = the viewport HANDLE (`[0x152138]`), the float is pushed, `ret 4`.
  - A field <= 0 goes to RL's error path (`0x32FB0`).
  - It stores +/-f at `obj+0xF8 / 0xFC / 0x100 / 0x104` and recomputes nothing.
- **Four callers**, all `push 0x3F4CCCCD` (0.8; no fixups):
  - `0x10F83`: startup;
  - `0x11145`: `0x10FEC`, the 1/2/3 render level;
  - `0x11398` and `0x11403`: `0x111A8`, the viewport re-created on a room load or a close-up.
- **Nothing else changes it.** The MS7 sniper sight (Z since the jump, [[azrael-jump]]; the game's key is SPACE) is a HUD sprite, not a zoom.
- **Each frame** `Viewport::Render` `0x5BD0C` -> `0x59404`:
  - `+0x240 = 1/field_x`, `+0x244 = 1/field_y`;
  - when `+0xD8` is set (Create sets it), `a = (w x [dev+0x160]) / (h x [dev+0x164])` (`w,h` = `obj+0x3C/+0x40` ints, `dev` = `obj+0x2C`);
  - `a > 1` -> y scale x a (the field is the HORIZONTAL half-extent); else x scale / a (the field is the vertical one).
- **The numbers:** 0.8 over the 1600x928 view = tan 38.7 across, tan 24.9 up = 77.3 x 49.8 degrees: the measured 50 ([[azrael-host-fov-calibration]]).
- **Corrections to `docs\AZRAEL_REMASTER_FEASIBILITY.md`'s table:**
  - `+0xF4` = FRONT clip 1.0;
  - `+0xC4` = BACK clip (100 by default, 30000 after SetBack);
  - `+0xF8..+0x104` = +/-field (+/-0.5 only until SetField).
- **Reading it from the host:** `[0x152138]` is a handle. Resolve it through the RL hash table (`Resolve-RlHandle`, Watch-HostRender), then read `obj+0xFC`.

## How (game)
- **`src\Build-AztMod.ps1` `$ENABLE_HOST_FOV`:** `AztFovTick`, called from `AztFrameAll` (the per-frame hook `0x13DC8`, before that frame's render `0x14182` and pick `0x14895`).
  1. `aztFovTan` <= 0 -> nothing (the game's own 0.8).
  2. Resolve the viewport (`0x39E50`).
  3. `field = aztFovTan x max(1, w*sx / h*sy)`, the same rule as `0x59404` -- right for close-ups' other-shaped viewports too.
  4. If it differs from `obj+0xFC`, `SetField(handle, field)`, and count `aztFovSets`.
  - **It compares against the OBJECT** every frame. A new viewport (room load, the 1/2/3 keys) comes back at 0.8 and is set again before it is drawn.
- **Placement:** the routine and its data (`aztFovTan`, `aztFovWant`, `aztFovSets`) are LAST in the overlay. Only the 7-byte call in AztFrameAll moved the labels after it, and the 29 manifest patches that jump into the overlay followed.
- **Verified** by disassembling the installed AZTCODE.BIN. Load the installed R.EXE with `tools\load.ps1 -Exe`. Its loader maps 0x140000+ to obj2's LINK address, so copy the overlay bytes into that object's data to decode them.

## How (host, `tools\Watch-HostRender.ps1`)
- **`-Fov`** (vertical degrees of the game's view): 0 = `raptormod-settings.json` "fov", else 60; -Retro = 50.
- **`Step-Fov`** (every loop, beside Step-LoadGuard):
  - writes `aztFovTan = tan(Fov/2)` (0 in -Retro: a data write);
  - F12 (`-FovKey`, 0x7B; F10 stays unbound) cycles 50/60/70 with a visor readout;
  - every 2 s reads the viewport back (`Get-GameFov`, the same rule) and logs "the game draws and picks at N degrees". In -Retro the host follows the live value.
- **`Set-HostFov`** sets `$r` / `$gpu` (`SetVerticalFov` = `_focal`; all else derives) and the lamp's shadow views at Fov + 8 (was a fixed 58 against 50).
- **An older install** without `aztFovTan`: the host stays at 50 and says why at startup.

## Tools
- **Room Review:** `tools\room-review\viewer.js` `GAME_FOV = 60` (camera, saved pose, and the Game look request `fov`); `RoomLookWorker.ps1` draws each frame at the request's fov.
- **`Test-GpuLook -Fov`** (default 60; Render view uses it).
- **Still 50, comparing against stock captures:** Compare-Reference, Tune-Lighting, Render-Offline, Render-Demo, Test-Raster*. Test-GpuRaster also keeps 50.
- **Re-measuring:** `Tune-Geometry` can re-measure against a fresh `-CaptureRef` in game.

## Measured offline
`Test-GpuLook -Fov 50/60/70`, CORICORI and MINEHEAD:
- the wider views draw correctly (MINEHEAD shows its doors and the ledge in front of the player);
- the lamp still lights to the edges;
- frame time 2.8 / 2.9 / 3.0 ms.

## To check in game
- Clicks, hover, pick-ups and shots at the band's left and right EDGES.
- No flash of 50 on a room change.
- Keys 1/2/3 keep it.
- Book and close-up views.
- Characters just outside the old view still animate.
- -Retro stays 50.
- FPS at 50 vs 70.
- Lamp shadows softer: texels ~1.22x at 60, 1.46x at 70.
- Rooms showing edges never meant to be seen: Josh's call which to patch.

## 65 (Josh, 2026-10-13, after playing it: "Wow it works perfectly")
"I'd like to add a 65 fov option between 60/70 as I think personally that would be my perfect setting." F12 now cycles **50 / 60 / 65 / 70**. His own `C:\Games\RaptorMod\game\raptormod-settings.json` was created with `{ "fov": 65 }`, so his sessions open at 65; the shipped default stays 60 (the file is per machine, not in git).
