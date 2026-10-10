---
name: azrael-render-audit
description: "How to check the host renderer against the engine without eyeballing: live -Audit mode (engine vs host block compare, flagged pairs saved) and the offline Test-RoomHoles scan. Built 2026-10-05, audit not yet run live."
metadata:
  type: project
---

Josh asked (2026-10-05) for a way to verify every room without eyeballing each one, after
seeing "through the ceiling" in MINEMAZE near the Raptor.

**Live audit (ground truth)** -- `Watch-HostRender.ps1 -Audit`, desktop shortcut "Azrael's Tear
(Host Renderer - audit)" / `Play-HostRender-Audit.cmd`. Whenever the camera is still (>=0.6 s,
at most every `-AuditSeconds` 4) it hands the viewport back ~0.5 s, takes the engine's settled
picture (Save-EngineReference path) and runs `Raster.CompareFrames` (16x16 blocks of mean
luminance, tol 28). Logs `AUDIT room at (x,y,z): N% differs; engine-only, host-only`, appends
`C:\Games\azrael-render\audit\audit.csv` (with the camera matrix), saves a side-by-side PNG
(engine LEFT, host RIGHT) when engine-only or host-only > 1.5% or differs > 10%.
Calibration on the old ref2 pairs: good views 1.7-5% differ, 0% engine-only; a host frame with
its top third blanked reads 11.6% engine-only; a pair taken with a door swinging reads 31%.

**Offline scan** -- `tools\Test-RoomHoles.ps1` (all 77 game rooms from ROOMS.DAT, ~1 min) ->
`room-holes.csv`. Six 90-degree views from each `zy` marker and floor samples at floor+45;
counts EMPTY pixels and LEAK pixels (a culled back face is nearer than what is shown).
It is a TRIAGE list only: floor samples can land outside the play area (100% leak), and many
rooms are open to black above by design. CORICORI/TUNNMAZE/THEOTRAP/GSTUDIO read ~0.

**MINEMAZE "see-through ceiling": NOT confirmed from the files.** Rest pose has roof01..11 at
y~31 plus two huge lids `black`/`black01` at y 41-43 (x 168..970), all drawn, all facing down;
straight up from Josh's last position is 0% empty / 0% leak. What shows above the trench walls
is `minehead`, a 4-vertex PICTURE backdrop at x~1260, y 80..454 beyond the chasm, which the
lid stops short of (x 970) -- so from x > ~540 it is visible by design. The live run had
"4 hidden" parts, identity unknown. Needs an audit capture there before changing anything.
Only skip rules in that room: TRANSPARANT x26, ACTIVATION x2. Corpus-wide BLACKCOVER (101 tris,
12 rooms, textured n_black) is still skipped by name -- the first suspect if an audit shows
engine-only black.

Related: [[azrael-tier-a-host-render]], [[azrael-room-unit-cache]].