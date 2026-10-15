---
name: azrael-room-unit-cache
description: "Room loading is cached per .XAF as a binary 'unit' and composed in C#: 1-2 s per room change became 4-24 ms. Plus in-process room detection and the live palette check."
metadata:
  type: project
---

**Room-change hitch, fixed 2026-10-04.** `Import-AztRoom` (tools\LoadRoom.ps1) used to parse
OBJ text, quantise textures and walk every triangle in script on every room change, and again
when a character arrived: 0.8-2.4 s each.

Now: `Get-AztUnit` builds ONE file's finished geometry via the old path (renamed
`Import-AztRoomSlow`, unchanged) and saves it as `C:\Games\RaptorMod\cache\<NAME>.unit`
(`AztRoom.RoomUnit`, tools\RoomUnit.cs). `AztRoom.Composed.Build` lays units end to end with
indices rebased; two instances of one rig share textures but get their own geometry.
Measured: slow 772-2,355 ms -> **4-24 ms from disk, ~3 ms from memory**, and every array
(V, UV, T, TriPart, PartOf, parts, per-triangle texture content, counts, span) is IDENTICAL
to the slow path on four test compositions.

A unit's stamp = `$script:AZT_UNIT_RULES` | the OBJ's version line | the OBJ's timestamp |
palette SHA1. **Bump `AZT_UNIT_RULES` whenever a rule in Import-AztRoomSlow changes what a
unit contains**, or stale units will be trusted. `tools\Build-RoomCache.ps1` pre-builds all
178; re-run it after a palette re-capture or exporter change.

**Room detection is in-process too**: `Find-LiveRoomFast` in the watcher does Find-LiveRoom's
greedy cover from an inverted index (name -> files), <1 ms, same answers on 8 rooms. Must be
fed RAW names (`WalkBlocks`), not `WalkLive`'s, because WalkLive adds bare aliases for
ZZ-prefixed bones and a rig would then be chosen as a "room". Index hashtables are ORDINAL.

**Palette.** The capture at `C:\Games\RaptorMod\cache\azrael-palette.pal` (2026-10-04 01:33)
post-dates the HUD rebuild and is current (Josh confirmed colours). The old staleness warning
compared timestamps with the overlay and false-alarmed after every install; it is replaced by
`Test-LivePalette`, which reads the game's own palette (3-byte master at obj2 0x163310, 4-byte
table at 0x163610) at session start and compares CONTENT, trying 6-bit/8-bit and both byte
orders. Which reading is right is unknown until the first live run prints it.

**Lighting / draw distance: not done, being measured.** `-CaptureRef` on the watcher saves, every
8 s while the camera is still, the host's unlit frame + depth and the ENGINE's picture from
the same pose (read from the surface at [0x163A34] after handing the viewport back) into
`C:\Games\RaptorMod\cache\ref2\*.{host,eng,depth}.bin + .json`. Fit brightness-vs-depth from
those, then turn `-Light` on with fitted FogNear/FogFar/FogCurve. The existing -Light numbers
were tuned against a reference with the OLD palette baked in -- do not trust them.

Related: [[azrael-characters-host-render]], [[azrael-tier-a-host-render]], [[azrael-palette-budget]].
## First lighting measurement (2026-10-04 23:58): the engine does NOT darken with distance in CORICORI

One clean pair (232539-CORICORI): engine and host pictures are visually the same brightness; engine/host luminance ratio by depth is 0.93-1.00 from 75 to 800 units, median 1.000 in most bins. So the 'rooms fade to black with distance' premise is NOT supported here -- the darkness is in the textures. Do not switch `-Light` on from this. Still needed: pairs from large/open rooms and wherever Josh sees the host drawing further than the engine. Capture notes: two-identical-reads never happens (engine is mid-draw most of each frame) -> `SceneGraph.SettledFrame` takes the per-pixel most common non-zero value over 7 reads; 12-54% 'unsettled' was reported with creatures in view. Four of the five saved pairs are useless duplicates taken from outside the room after the fall-through.

## LIGHTING AND DRAW DISTANCE: MEASURED, NOTHING TO ADD (2026-10-04 23:59)

Four clean engine/host pairs (MINEHEAD, WELLROOM, ORRERY, CORICORI): engine/host luminance ratio is 0.94-1.07 in every depth bin from 50 to 1,300 units, and MINEHEAD's two pictures are visually near-identical side by side, far wall included. **The engine applies no distance fade and no extra lighting; the look is baked into the textures. Leave `-Light` OFF. The 'host draws further / unlit' items were a wrong premise from the old-palette reference.** 'Engine drew nothing' runs 10-40% at ALL depths (engine writes index 0 for black texels; the host never emits 0), so it is not a far clip. Real differences seen instead: in MINEHEAD the engine shows a hanging lift cage and grating between the pillars that the host does not draw (a missing/misposed object or a keyed texture) -- that is the next picture-correctness item. Pair 233730-SPAROOM is invalid (a door was swinging: striped engine frame). Also: Find-LiveRoomFast now skips *.ANI rig files (it briefly chose MINEHEAD+LURKA). Narrow velocity gate + takeover fix ran this session without complaint: player peak 291-312 units/s, 132 fps median.

## Corpus sweep + launcher (2026-10-05, renderer phase wrap-up)

**Sweep of all 178 .XAF (135,043 triangles), results in `C:\Games\RaptorMod\cache\room-sweep.csv`:** 0 load failures, 130,604 textured, 1,424 solid colour, 3,015 hidden by rule, **0 on the grey fallback**, no blank textures, no NaN/extreme coordinates. The only 63 fallback triangles were faces with NO material at all, every one an authoring helper (`dummy` in CAM/CAMERA01/CAMWALK1, `tdummy` in TOBIAS, `fight` in FIGHT, `sailorbox` = the whole of SAILOR_A, `rat`'s 2-face root in RATTY); Import-AztRoomSlow now skips material-less faces (`AZT_UNIT_RULES = 'rules-2'`, cache rebuilt, 83 s). Offline only -- it proves every file loads and is fully textured, not that every room looks right in play.

**One-click launcher:** `AztMod\Play-HostRender.cmd` + desktop shortcut *Azrael's Tear (Host Renderer)*. Relaunches itself minimised, refuses if a DOSBox is already up, starts the game (same command line as Play-Azrael-Modded.bat), then runs `Watch-HostRender.ps1 -Once` and closes with the game. `-Once` now also exits if the game goes away before a session starts or never appears within 90 s. `AZT_DRYRUN=1` walks the file without starting anything (used to test it; the real path has NOT been run -- never auto-launch). Batch trap hit while writing it: the file's own path contains `(x86)`, so expanding `%~f0` inside an `if ( ... )` block closes the block; use goto.

Dropped by Josh: the save-load freeze (no longer an issue) and the MINEHEAD machinery difference ('nothing's missing from that room').
