---
name: azrael-phase2-echo-complex
description: "Phase 2 (2026-10-14, Josh): the visor echo scan (V) and the whole-complex map (zoom out from a room's 3D map) -- how each works, the keys, data, traps."
metadata:
  type: project
---

Josh asked for both on 2026-10-14 (phase 2, with the painted-light finder in Room Review). They are built and checked offline; neither has been seen in game yet.

**Echo scan (V)**
- **Key:** `-EchoKey 0x56` (V).
  - The game's ascii dispatch (0x12E75..0x13713) compares only `0D 20 " $ % , . / 1 3 4 5 < > ? H M P Q X Y h m p r s x y 9C`, so V/v and most letters are free. The list was found by linear-decoding `cmp al,imm` with tools\load.ps1.
  - Host keys are not taken from the game.
- **Watcher `Step-Echo`** (called in the card block beside the shot impacts) collects three groups of targets:
  - doors: parts matching `door|gate` (not `wall`), plus each doorway's opening (portals.json `farQuad`, 4 corners);
  - items: parts OBJECTS.DAT names (`ScanWire.IsObjectPart`, new), not `zx/zy` triggers, at most 160 units across;
  - creatures: IsCharacter parts. These are re-sent every frame, because they move.
- **Rules:**
  - triangles not drawn (`dt < 0`: taken, or invisible) are left out;
  - it is blocked under the map, the boot cover and the room cover.
- **Sound:** `BootSound.SonarPing()` (new): a ping with two echoes.
- **GpuRaster:**
  - `EchoT` (seconds; -1 = none), EchoSpeed 950, EchoMax 1900, EchoFade 1.4;
  - `SetEchoTargets(cat, tris, segs)`, `EchoEdges` (feature edges), `DrawEcho` (VS_XRAY + new FS_ECHO, no depth test, additive);
  - each outline lights when the shell's radius passes it, flares white for about 0.1 s, and decays;
  - the shell itself is in FS_MAIN `uEcho`: a band at `length(vView)` == R, with 9-unit contour rings trailing it, added to lightG so it shows through the fog;
  - colours: doors 0xFFB040, items 0xFFE8A8, creatures 0xFF6A38.
- **Badge (Josh, 2026-10-14):** ScanTag shows "Gathering Environmental Data..." in amber (EchoInk 0xFFB040 / EchoFlare 0xFFE3A6 / EchoGlass 0x140C02), centred above the panel. It shows while the shell runs out plus EchoTagHold 0.6 s, then fades over 0.3 s; its bar = the shell's reach (GpuRaster.EchoTagK/EchoTagProgress). The strongest of the three messages (room, map, echo) shows.
- `-NoEcho`. Offline: `Test-GpuLook -EchoAt s`.
- BAPTIST shows a lot as "items": the fonts, mirrors, tapestries, bath and plaque are all OBJECTS.DAT objects (interactables, not only pickups). Live record +6 ("can be held") could narrow it later.

**Whole-complex map**
- **Data:** portals.json `m` per entry carries the far room into this room's coordinates (row vectors). Every room file has its own origin; headings mostly carry over (MINEHEAD-BAPTIST ±38, TRACK01 ±91, ZIGURRAT ±173 are rotations inside `m`).
- **`LoadRoom.ps1 Get-AztComplex -Root -Visited`:**
  - breadth-first from the current room through VISITED rooms; placement = m x parent;
  - a visited room's unvisited neighbours are placed as group 2 (faint) and not walked through;
  - `Get-AztComplexGeo` caches each room's map geometry: Import-AztRoom from the .unit, Get-AztMapSkip, invisible triangles and triangles with an edge over 1500 dropped (MINEHEAD's backdrops, TRACK01's 15,000-unit planes).
  - Cost: 6 visited rooms, 11 placed, ~140 ms the first time.
- **GpuRaster:**
  - `SetMapComplex(vx, idx, grp)`: `BuildComplex` makes 2 VBO pairs (faces + edges). It reuses BuildXray with a dummy Tex and a masked triTex.
  - `MapComplexK` fades them in. COLOURS (Josh, 2026-10-14): visited rooms in the map's teal (no white core; 0.75 of the current room); never-reached rooms a faint GREY outline (`MapUnseenInk` 0x6C7278 / flare 0x8C9298, `MapComplexDim` 0.14, faces 0.2), "rather hidden" until reached. They are drawn after the room's own pass with uWave off, faces at 0.8 / 0.4 and lines x `MapComplexDim` 0.3 for unvisited rooms.
  - The camera stays centred on the current room; MapZoom now goes down to 0.03, and near/far use the complex's radius.
- **Watcher:**
  - `Get-MapVisited` / `Add-MapVisited` (on every `room ->`) / `Clear-MapVisited` (a NEW game boot), stored in `C:\Games\azrael-render\visited-rooms.json`;
  - Step-Map lays the complex out on open when the room or the visited list changed;
  - the wheel goes down to 0.06, and the complex fades in from zoom 0.62 to 0.37.
- **Per SAVE (Josh, 2026-10-14: a new game still showed other rooms; "tied to the individual save file"):**
  - The visited rooms are now THE GAME'S OWN: 100 words at 0x162E4C, one per MAPS.DAT room number. They are set on entering (0x11591), cleared for a new game (0x1148E), and WRITTEN TO / READ FROM the save file (fwrite 0x2270B / fread 0x22891, 0xC8 bytes).
  - `Get-GameVisited` reads them when the map opens. The number becomes a file through `$script:roomNumSeed` (MAPS.DAT ROOM n vs files, the confident ones) plus numbers LEARNED live: word `[[0x1841C8]]`, the map toggle's own room, read 2 s after each `room ->` and on map open, kept in <CacheDir>\room-numbers.json.
  - A visited room whose number is not known yet is left off.
  - visited-rooms.json (the host list) is only a fallback for when the words cannot be read.
- **Interlace (Josh, 2026-10-14: "very faint interlacing ... 5-10%"):** FS_COMP darkens every max(2, rows/500)-th row of the whole map view by `MapLines` 0.08 x MapK.
- **Only DISCOVERED rooms (Josh, 2026-10-14):** the grey unvisited outlines were too bright where they overlapped, and "the helmet scans rooms as the player enters". So Get-AztComplex leaves unvisited rooms out entirely (`-ShowUnvisited` brings the grey back), and the visited ones are drawn in teal.
- **Round 2 (Josh, 2026-10-14, a screenshot):**
  - **Too bright, thicker lines zoomed out.** The lines keep their pixel width while the rooms shrink, so they piled up. Width and strength now fall to `MapFarWidth` / `MapFarK` (0.45) at the furthest zoom, eased from zoom 0.6.
  - **"Cut off at the bottom".** It did not reproduce offline. The likely cause: seen from above, rooms under another room's floor were thinned by the hidden-line pass. The other rooms' faces now write no depth and their lines draw whole (depth ALWAYS, 0.8 of `MapLineK`).
  - **The game's old map peeking at the top.** MAPS.DAT neighbour thumbnails sit above the view (ORRERY's T_CHAM_C at y 17). While the 3D map is up, the compose's hide rect now covers everything (+/-100000).
- **Round 3 (Josh, 2026-10-14):**
  - The map opens at `-MapZoomStart` 1.5 (was 1.0).
  - The other rooms fade in from just under that zoom down to 0.4 under it (was 0.62 -> 0.37: he had to zoom out "way too far").
  - The up/down tilt had stopped working: a comment inserted mid-line ate the pitch statement. Restored, and the watcher scanned for any other line where a comment hides code: none.
- **Map update notes:** Room Review has a note kind `map` ("Map update"). Answer one by adding the clicked part to rooms\<ROOM>.json `"map": { "hide": [part names, exact spelling] }`. Get-AztMapSkip reads it. The complex cache is keyed by the room file's time, and the watcher re-reads it when the file changes, so it shows the next time the map opens.
- Not done: room-name labels, links drawn between paired doors (the doorways already meet), and the game's own visited words (`0x162E4C+2n`, MAPS.DAT numbering) instead of the host list. A load keeps the host list.
- Offline: `Test-GpuLook -Map -MapZoom 0.12 -MapVisited A,B,...`.

**Traps hit**
- **It stopped the GPU renderer (2026-10-14, Josh: "The game isn't loading the gpu renderer anymore"):** `Get-MapVisited` returned its List bare, and PowerShell unrolls an EMPTY list to nothing. So `Add-MapVisited` on the first `room ->` called `.Contains` on `$null`, and the session ended ("You cannot call a method on a null-valued expression"). Fixed with `return ,$list`. The echo, the eye shine and Add-MapVisited are now each wrapped: an error switches that one feature off with a log line.
- PowerShell variable names ignore case: `$T` (the list) was overwritten by the loop's `$t`. Use distinct names (`$cxT`).
- `Get-AztMapSkip` returns `,$list`, so `@(...)` wrapped it as ONE int[] and `[int]` threw. The catch swallowed it, so every room came back empty.
- LoadRoom.ps1 is CRLF: multi-line `.Replace` anchors written with LF silently did not match. Normalise to LF, replace, then restore.

Related: [[azrael-map-3d]], [[azrael-zones-room-graph]], [[azrael-doorway-portals]], [[azrael-scan-wire]], [[azrael-phase1-life]].
