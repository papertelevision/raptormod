---
name: azrael-characters-host-render
description: "How the host renderer loads characters: live frames named ZZ%04d+bone identify an instance, *.ANI `FILE x.xaf` names the rig file, Import-AztRoom -Characters appends one copy per instance."
metadata:
  type: project
---

Characters in the host renderer (built 2026-10-04, **not yet seen in game** at time of writing).

**Identification.** The engine instances a rig under a container frame `XAFQ%d` and names
every bone frame `ZZ%04d` + the object's own name (both format strings are in R.EXE at file
0x1867D0 / 0x1871C3). So live names `ZZ0001EUBUM`, `ZZ0001EUHEAD`… are one instance; strip
the prefix and match the set against `C:\Games\RaptorMod\cache\xaf-objects.json`.

**Which file.** Several .XAF share a skeleton (EUGBLD, EUGBLD1, EUGBLD2, EUGTEST: same 30
names; BLD1==BLD2 geometry, BLD differs in 9 meshes). The tie-break is the character
definitions: `GAME\AZRAEL\*.ANI` are 250-byte text files with `FILE eugbld.xaf` plus
`SPEED`, `HEALTH`, frame ranges (`REST 0-0`, `RUN 2-7`, `ATTACK 53-70`, `DEAD 163-163`) and
sound triggers. 35 .ANI → 27 distinct rig files (KURT→RAPTOR, SCORP→TRILET01, CLAUDE→CLAWALK,
EDGAR→REEDGAR, PHILIP→PHILIP2, SAILOR→SAILOR_A…).

**Rig .XAF structure.** Objects are NESTED (EUBUM root, depth to 5) with local matrices, and
the file carries an `animation_set` with per-object `position_keys`/`rotate_keys`/`scale_keys`.
`Export-XafObj.ps1` already composes the hierarchy and writes parts.json with rest matrices.
The host does not use the keys: it poses each part by `inv(rest) * live world`, the same
mechanism as doors, so whatever the engine animates is followed for free.

**Code.** `Import-AztRoom -Characters @(@{Xaf;Prefix})` (LoadRoom.ps1) loads one geometry
copy per instance with parts named Prefix+name and `IsCharacter`. In the watcher,
`Get-LiveCharacters` runs once a second off the pose walk; a changed signature rebuilds the
room (`Get-Room $rooms $chars`, cache key includes the signature). ZZ-prefixed groups mostly
explained by the room's own files are instanced room objects and are skipped.
`-NoCharacters` turns it off.

**Unverified until seen:** that a bone frame's live world matrix maps the mesh's local
vertices the same way a door's does (scale 0.1 on the EUBUM root is the thing to watch), and
that the watcher's stripped-name alias in `$live` does not let a room part pick up a bone's
matrix. Related: [[azrael-scene-graph]], [[azrael-xaf-scene-format]],
[[azrael-tier-a-host-render]], [[azrael-animation-format]].
## SEEN WORKING 2026-10-04 18:16

Both Eugenes drew in CORICORI at the right place and scale (frame 181618-CORICORI), 30 of 30 frames matched each, 126-136 fps. So a bone's live world matrix does apply to its mesh like a door's. Josh: 'a bit less crisp than typical'. Cause found in the log, not the art: `-PoseHz` was 10, so creatures stepped 10x/s inside a 130 fps picture. Fix: `SceneGraph.WalkLive` (one 0x26C-byte read per node, name strings cached by pointer) + `SceneGraph.PoseAll` in C#; Update-Pose measured 0.15 ms for 124 moving parts (was ~2.8 ms incl. walk); PoseHz default now 240. WalkLive itself is untested until the next live run. Also: stop a watcher ONLY when DOSBox is not running -- killing it mid-game freezes the viewport (done by mistake once this session).

## Torn poses (2026-10-04 22:15) -- and a test that never ran the new code

Josh reported stretched polygons, jumping textures and a floating creature on ALL characters. The log showed the watcher from 18:15 (pid 38000, build 18:14:18) had stayed up across four game sessions, so that test ran the OLD script walk: 5-8 ms per walk at 10 Hz against a guest frame under 4 ms. **Always check the last 'Watch-HostRender built' line against the build just shipped before reading a result.** Cause of the tearing: the guest re-derives every world matrix top-down each frame (propagator 0x55378 via 0x3F2F0) and the host reads with no lock, so a walk overlapping that pass mixes parent-new with child-old. Fix: `SceneGraph.WalkLiveStable` -- walk twice, accept only if bit-identical, up to 4 retries, else keep the previous pose; the stats line now prints walks / retried / abandoned. Untested live at time of writing. Also confirmed in that log: LURKA (23/23, MINEHEAD), RAPTOR (25/25, MINEMAZE) match and load; instance numbers keep counting up across rooms (ZZ0003, ZZ0004...).

## 22:26 run: tearing fixed; 'missing textures' = textureless materials

WalkLiveStable live numbers: 25,376 walks, 9.7% needed a retry, 3.2% abandoned; pose 1.07 ms avg; 123 fps. Josh: tearing 'pretty much fixed'. NIAMH (19/19, WELLROOM) also loads. Missing textures traced to materials with `texture \"\"`: the XAF colour is {r,g,b,ALPHA}. Alpha 0 = not drawn (106 in the corpus: TRANSPARANT, CLEAR_OBJECT, ATRANNIE...), alpha 1 = solid colour (BLACKMATTE 0,0,0,1 is 181 of the Raptor's 504 triangles). They were absent from the .mtl and fell to a grey fallback. Now Export-XafObj (OBJ version 4) writes them as `Kd r g b` + `d alpha` with no map_Kd, and Import-AztRoom draws alpha-1 ones as a 1x1 solid texture (nearest non-zero palette index) and skips alpha-0 ones. After the change no room or rig tested has any triangle on the grey fallback. BLACKCOVER (textured n_black.gif, alpha 1) is STILL skipped by name -- unexamined, a candidate if a room shows a hole where black should be.

## OPEN: a character floats under the host renderer, grounded when the engine draws (2026-10-04 22:47)

MINEMAZE, lying body (ZZ0007 LURKA and ZZ0008 RAPTOR present; not certain which is the floater). Josh: on Ctrl-C of the watcher it 'repositioned' onto the ground. `-CharProbe` (records WalkBlocks, hands back for 1.5 s, records again) showed the frames are the SAME in both states: only the Lurka's idle animation moved (~1 unit, alternating), the Raptor's 25 frames not at all, third block d=0, flags 000. Ruled out: .ANI OFFSET (0,0,0 for both; only SASCHA/SASCHB have 0,-7,0), exporter inconsistency (RAPTOR OBJ verts == XAF local * parts.json rest to 5e-7, 25 unique names). So the frames do not explain it; next suspect is the MESH -- `Invoke-MeshProbe` now compares the engine's live vertices (frame+0x270 -> Visual*[] -> Mesh +0x48 count / +0x50 ptr, 48-byte stride) with ours taken back to local via inv(rest). Other untested ideas: HEIGHT (33 for both) applied somewhere outside the frames; a room part wrongly posed via the bare-name alias so the FLOOR is what is wrong. Probing needs the game running -- twice it had been closed by the time I read, so the probes live in the watcher.

## SOLVED 2026-10-04 23:00 -- frame+0x90 is a LAZY CACHE; compose world from locals

Mesh probe: 0 of 48 character parts differ from the engine's live vertices, so meshes were never the problem. The second CharProbe caught it: the Raptor's 25 parts all shift by exactly (-4.3,-18.7,-8.0) when the engine draws, LOCALS UNCHANGED. Live read: root bone ZZ0004SBUM has local t (7.1,-18.7,-5.6) but cached world t == its container XAFQ4's, dirty flag 1; children consistent with that stale parent. **The engine refreshes frame+0x90 only when it draws (or something queries a frame); under host render it stops drawing, animation keeps writing locals (+0x4C), and the cache goes stale.** (The earlier 'frames identical in both states' reading was the Lurka's probe -- the first run happened not to list the Raptor.) FIX: `SceneGraph.WalkLive` now composes `world = local * parentWorld` top-down, starting from IDENTITY (the top of the parent chain is not a real frame: zero rows, NaN world). **Validated read-only against the running game: composed == cached on all 81 room frames, and differs only on the 48 character frames, where it reproduces the engine-drawing positions from the probe to the decimal.** This is what the 2026-09-26 geometry-export note already recommended. Awaiting Josh's visual confirmation. `-CharProbe` and the mesh/transform probes remain in the watcher for future use.
