---
name: azrael-room-review
description: "Room Review = local 3D viewer (desktop shortcut \"Room Review\") where Josh clicks rooms and leaves notes; notes are in C:\\Games\\azrael-render\\room-notes\\<ROOM>.json. How to read and answer them, and the traps found building it."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-08T14:22:11.296Z
---

Built 2026-10-08 at Josh's request: review rooms without playing through the game. He clicks a point and leaves a note; I read the notes and make the changes, mostly in C:\Games\azrael-render\rooms\<ROOM>.json.

**Pieces**
- `AztMod\Review-Rooms.cmd`, plus the Desktop shortcut "Room Review".
- `tools\Start-RoomReview.ps1`: a PS 5.1 HttpListener on localhost:8642, falling back to `tools\RoomReviewHttp.cs` (AztTool.MiniHttp, TcpListener on BOTH loopbacks -- with IPv4 only, "localhost" clients stall on ::1).
- `tools\room-review\` (index.html, viewer.js, viewer.css, rooms.json). three.js 0.160.1 comes from the jsdelivr importmap.
- Batch 1: rooms.json "batch" (CORICORI, WASHCORI, SPAROOM, MINEHEAD, MINEMAZE, BAPTIST, WELLROOM, CHAMBNEW, ORRERY, TUNNMAZE). Add rooms there for later batches.
- `Root .claude\launch.json` "room-review" (for MY browser-pane checks; the pane wants it at the session root `Azrael's Tear\.claude`, not AztMod).

**Data:** it serves the existing Export-XafObj output in C:\Games\azrael-render (.obj/.mtl/.png), hi-res from azrael-textures\hires, and the merged atmosphere via Get-RoomAtmosphere (AST-extracted). The server never writes room settings.

**Notes file:** `{schema, room, rev, nextId, notes[], deleted[]}`. Each note has:
- `id`, `status` (open/done/question/wontfix), `kind`, `text`;
- `point` and `normal` in ROOM coordinates (the same space as lights x,y,z), `part`, `material`, `texture`, `uv`;
- `target` (a light clicked), `camera.gpuLook {X,Y,Z,Yaw,Pitch}` (feed it to Test-GpuLook to render the same view);
- `suggest.light` (point + normal*30, dir = flat normal);
- `screenshot` (`<ROOM>-<id>.png` in room-notes);
- `reply`, `changes[]`.

**ANSWERING:** edit rooms\<ROOM>.json, then write reply + status done + changes[]. While the server runs, use `PATCH /api/rooms/<R>/notes/<id>` with header X-Review: 1 and JSON {reply,status,changes}; otherwise edit the file directly (UTF-8 without BOM, keep notes an array). The viewer polls every 5 s and shows the reply.

**Verified (2026-10-08):**
- normal (-0.425,0,0.905) on textwall2 = the torch's dir;
- the inscription reads correctly with mirrorZ;
- all 10 rooms load (geometry 60-160 ms, hi-res textures);
- traversal, foreign Origin, missing X-Review and foreign Host are refused;
- the notes round trip works.

**Traps**
- Walls are ONE-SIDED in the game: CORICORI's start pose sits behind dorwall05. The viewer uses FrontSide (it matches the renderer under the Z mirror) with a "Back faces" toggle.
- `[IO.File]::Replace($tmp,$p,$null)` -- PowerShell turns $null into "" for a string parameter, so it threw; use `[NullString]::Value`.
- Arrival view: a door's 'door' coordinate (trigger zone) does not say which way is into the room. It now picks the most open of 16 directions.
- The browser pane's screenshots LAG; check state with javascript_tool before trusting a screenshot.

Related: [[azrael-volumetric-fog]], [[azrael-atmosphere]], [[azrael-zones-room-graph]], [[azrael-geometry-export]].

**Controls (Josh, 2026-10-08):** two modes.
- FLY is the DEFAULT: the orbit view (drag turn, right-drag pan, wheel zoom), and WASD/arrows FLOAT camera and orbit target together with NO collision. Q/E or Space/C go down/up. Speed 217 u/s, Shift 582. Left/right arrows turn on the spot.
- WALK: eye 48 over the floor, walls stop you at a 14-unit body (sliding), game speeds 145 / Shift 291, drag to look, wheel = pace.
- F switches modes, Esc goes back to Fly. (A third free-look 'fly' mode existed briefly and was replaced by this at Josh's request.)
- TESTING TRAP: a hidden browser pane gets NO requestAnimationFrame. Drive window.__rr.tick(now) by hand with keys dispatched (window.__rr.keys shows what's held).

## THE WORKFLOW (Josh, 2026-10-08) -- notes are worked in ROUNDS; this is how I answer them
Lifecycle: **new** (Josh wrote; my turn) -> **review** (I replied; his turn) -> he follows up (back to new) or marks **complete** (it leaves the list and is kept in the file's 'completed'). Each note's 'log' = [{who josh|claude, text, at, shot?, render?, changes?, round?}]. Schema 2; schema 1 is converted on read. Shared I/O: tools\RoomNotes.ps1.

When Josh says "notes are ready":
1. `.\tools\Start-RoomRound.ps1` -- snapshots rooms\*.json to C:\Games\azrael-render\rooms-history\round-NNN (the state BEFORE the round), numbers the round in room-notes\rounds.json, and lists every 'new' note with its place, view (-X -Y -Z -Yaw -Pitch), suggested light and full log. (`-ListOnly` just lists.)
2. Make the changes in rooms\<ROOM>.json.
3. `.\tools\Reply-RoomNote.ps1 -Room R -Id n -Text '...' -Changes 'rooms\R.json lights[1] added', ...` -- renders the note's view through Test-GpuLook (flashlight off | on, side by side, ~8 s), attaches it, and sets review. `-NoRender` for questions.
4. Undo: `.\tools\Restore-RoomRound.ps1 -Round N [-Room R]` (current files saved to rooms-history\restore-<time> first).

The server only lets the viewer set status 'complete' (anything else -> 400); 'edit' changes Josh's latest message only before I answer it (409 after). Message screenshots are R-<id>-<k>.png, renders R-<id>-<k>-render.png.
Traps: the dialog is saved on the form SUBMIT (a hidden tab held back the 'close' event, so nothing saved); the 5 s poll only runs while the tab is visible; the safety hook blocks PowerShell commands containing JS like `marks.remove(` -- write JS blocks with the Write tool and splice them in.

**RENDER VIEW + SELF-REFRESHING EXPORTS (2026-10-08):**
- The viewer's 'Render view' button (key R) POSTs the camera's gpuLook to /api/rooms/R/render. The server runs tools\Render-RoomView.ps1 (Test-GpuLook x2: flashlight off | on, side by side) as a hidden process, one at a time (409 while busy). The viewer polls /render/<id> and serves /renders/R/<id>.png from C:\Games\azrael-render\room-renders (the newest 40 are kept). About 10 s. Reply-RoomNote.ps1 uses the same Render-RoomView.ps1.
- Opening a room (GET /api/rooms/R) re-exports it with Export-XafObj (no -IfStale) when GAME\AZTEX\R.XAF or R.RES is newer than the cached OBJ. -IfStale only checks the format version, NOT dates. The manifest's 'refreshed' says why. The export is deterministic (only the header date comment differs).
- What the viewer does NOT show: lighting (it is unlit; Render view shows it), live game state (doors, picked-up items, characters).

**SUBMIT UPDATE (2026-10-08):** a button at the viewer's lower right. POST /api/submit writes room-notes\submit.json {id, at, total, rooms, state waiting}. Start-RoomRound sets it to 'working' with the round; GET /api/submit turns it 'done' once no 'new' notes remain. The viewer shows 'Sent .. waiting for Claude' / 'Claude is working (round N)' / 'Claude replied · your turn'.
**I KEEP A WAITER RUNNING:** `.\tools\Wait-RoomSubmit.ps1` with run_in_background -- it exits when submit.json says 'waiting', which wakes me. THEN: Start-RoomRound.ps1 -> work the notes -> Reply-RoomNote.ps1 each -> START THE WAITER AGAIN. (It only works while this conversation is open; otherwise the submission waits for Josh's next message.)
**Also round 2 (CORICORI/2):** light fields colorFar/tintFrom/tintTo (colour shift with distance: main shader uLightTintM/D, compose uVLM/uVLT, SetLightTint) and 'dust' {count,size} = SHAFT particles in Particles.cs (15 floats a shaft; spans from the first surface to the next along the axis; pre-filled; additive, coloured along the blend).

**Notes panel = LIST + DETAIL (Josh 2026-10-08: 'cluttered, lumps all notes into one entry'):** compact rows (#, kind, first words, your turn / with Claude); a row OR its PIN in the 3D view opens that note alone (S.sel; the pin turns white and ringed); '← All notes' goes back. Filter: All open / Your turn / With Claude / Completed (doc.completed, read-only). Sort: Your turn first / Latest activity / Note number / Kind. A new note opens on save. Viewer-only changes need just F5 (static files are served no-store).

**EXTRA LINKS (2026-10-09, WASHCORI/1):** portals.json only holds DOORWAYS. A drop (WASHCORI door01 -> false floor zxfalse -> MINEMAZE, zone WashRoomMineMaze, trigger zxwshrR3) was missing, so Josh thought the cave room was missing. It was MINEMAZE, already in batch 1. 	ools\room-review\links.json {ROOM: [{to, zone, door[x,y,z]}]} is merged into the door markers, read fresh per request. The game watcher never reads it, so portals.json stays untouched. To find a room's other exits, use 	ools\Read-Zones.ps1 -Csv file (zone names <A><B>, trigger zx objects in the room's OBJ). Lincoln = KURTB.DES ('identified - Lincoln'), trigger zxkurt in MINEMAZE.

**In git since 2026-10-10** ([[raptormod-repo]]): the notes live in the repo's oom-notes\ (C:\Games\azrael-render\room-notes is a junction to it; screenshots ignored) and the rooms in ooms\. After a round's replies, commit oom-notes + ooms together.
