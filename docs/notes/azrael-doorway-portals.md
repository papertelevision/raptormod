---
name: azrael-doorway-portals
description: "Live doorways + motion smoothing in the host renderer (2026-10-05): rooms are in separate coords; zx trigger / zy arrival marker / picture quad give the join. Built and offline-verified, NOT yet seen in game."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-05T04:57:44.282Z
---

**Doorways show a PICTURE, not the next room**: a 4-vertex upright quad standing ~58 units
beyond the exit trigger, textured with a 1996 still (`r12r5` = room 1 looking into room 5).
The host now draws the real neighbour there. Built 2026-10-05, offline-verified only.

**The data (all on disk, no RE):**
- Every room .XAF is in its OWN coordinates (origin mid-room) -- nothing lines up as stored.
- `zx*` = exit trigger (AZONES.DAT zone "AToB", or bare "WashRoomMineMaze" in the first rooms).
  `zy<code>` = ARRIVAL marker for arrivals from that room (`zyR05`, `zyC5`, `zyR22b`), ~30
  units further into the room. Named-zy == nearest-zy in nearly every room.
- ROOMS.DAT: 60-byte room name + 60-byte file name + uint16 zone count + 60-byte zone names
  -> which file the game really loads (MINEHEAD, not MINEHED2/HINEAZF). 83 rooms found.
- Old named rooms' codes: EntryCoord=R1 WashRoom=R2 MineMaze=R3 TheoChamber=R4 SpaRoom=R5
  MineHead=R6 WellRoom=R7 Baptistery=R8 Orrery=R9 Tunnel=R10 Cloister=R16 Vestry=R17
  ChapterHouse=R18.
- Use vertex CENTROIDS, never parts.json rest translations (off by hundreds of units).

**The join:** each room models its own door + a tunnel stub ending at its picture plane, so
the far room is placed PICTURE PLANE ON PICTURE PLANE, exits facing each other (turn about Y
from the quad normals). ~75% of doorways come out at 0 degrees turn. Rejected first attempt:
mapping A's trigger onto B's arrival marker -- folds the tunnels together, a stairwell wall
filled the doorway, 7 doorways showed nothing.

**Two pictures per doorway:** one standing by default, one PARKED far below the floor that
the game lifts when the FAR door changes state (usually "opened"; `all2cori` is a generic
shut door). Rule: default standing = neighbour as its file has it; parked lifted = hide the
neighbour's entrance door (found offline as a door-named slab across its tunnel); parked
lifted and no far door known = keep the game's picture. "...CLOSE"/`sa_door`/black quads are
never replaced.

**Code:** `tools\Build-PortalMap.ps1` -> `C:\Games\RaptorMod\cache\portals.json` (169 doorways,
121 with a picture). `Get-AztPortals` (LoadRoom.ps1). `Raster.BeginPortals/AddPortal/
EndPortals/DrawTexturedMasked` + `AztTool.Portals.Prepare/Draw` (aperture mask tested against
the room's depth, so a shut near door hides it). `tools\Test-Portals.ps1` renders
picture-vs-live PNGs to `C:\Games\RaptorMod\cache\portal-test` (-All: 121/121 pass, none empty).
Watcher: `-NoPortals`; logs `doorways:` and a `PORTAL CHECK` line per room change (actual
heading change vs the map's turn -- the map's turn is UNVERIFIED against the game until read).
Cost ~1.6 ms/frame with a doorway filling 16% of 1600x928. Neighbour is static: rest pose,
no creatures.

**Motion smoothing** (`AztTool.Smoother`, SceneGraph.cs): `WalkTree` returns locals + parents;
each joint's LOCAL matrix is eased (quaternion/scale/position) from where it is DRAWN to the
new pose over one 18.2 Hz tick, worlds composed after -- blending world matrices opens joints.
One tick (55 ms) behind, no prediction. Rigs always; room objects only when they turn in
place (a travelling one may be a lift carrying the unsmoothed camera); steps <30 ms apart,
>150 units or >120 degrees pass straight through. `-NoSmooth`, `-SmoothAll`. The MOTION step
report only exists with `-NoSmooth`.

**Trap hit again:** a script param `[string]$Room` and a local `$room` are the SAME variable
-- the room object was silently stringified. See [[azrael-powershell-silent-traps]].

Related: [[azrael-zones-room-graph]], [[azrael-tier-a-host-render]],
[[azrael-characters-host-render]], [[azrael-room-unit-cache]].

## First live run (2026-10-05 01:00) and the fix

Josh: smoothing "fantastic"; doorways "broke many things" -- broken/missing polygons, joins
never right. Two causes, both fixed offline (NOT yet re-seen in game):

1. **HEADING IS PRESERVED THROUGH A DOORWAY -- MEASURED.** Eight PORTAL CHECK lines (rooms
   1/2/5): heading turned 0 degrees every time where the quad normals said 6 and 11; landing
   is 1-7 units from the zy marker. Rooms share one orientation; the tunnels just are not
   square to each other. Turns within 30 degrees are now forced to 0 (pure translation,
   picture centre on picture centre). Larger turns (stairwells, -99 etc.) are still from
   geometry and UNMEASURED.
2. **The aperture was this room's whole picture quad**, often far bigger than the tunnel it
   depicts (spa: 123 square over a 65 tunnel), so the far tunnel was seen from outside.
   Now `Raster.RestrictPortal` cuts the aperture to the overlap with the FAR room's picture
   quad (`farQuad` in portals.json, pre-transformed; a parked one is stood on the floor);
   the rest is dark wall (mask 255). Doorways whose two mouths overlap < 40% keep their
   picture (2 of 121: KITCHEN's "picture" is mill machinery). 119 live, 0 empty offline.

Use the picture's Standing flag, never a y-threshold, to decide "parked": KITCHEN's standing
quad hangs 100 units below its floor.

## DECISION 2026-10-05: live doorways are OFF by default

Josh: "the maps dont actually line up perfectly and its causing too many issues to iron out" --
revert to the game's pictures. The watcher now needs `-Portals` to draw neighbours; all the code,
portals.json and Test-Portals stay. Motion smoothing stays ON (Josh: "fantastic"). Do not
re-propose live doorways unless asked. Josh also reported doors and clicking "work well now"
(after the narrowed event gate); the PICK probe lines are still logged.
