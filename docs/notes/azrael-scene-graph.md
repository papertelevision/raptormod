---
name: azrael-scene-graph
description: "The Reality Lab scene graph is fully enumerable and SEMANTICALLY NAMED - first-child/next-sibling tree, name string at frame+0x24, and only animated things carry an attachment."
metadata:
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-26T14:25:10.765Z
---

Stage 2 of [[azrael-remaster-feasibility]] is **done** (2026-09-26). `AztSceneLog` /
`AztScnEmit` in the overlay walk the whole graph once per run into `AZTSCN.LOG`;
decode with `tools\Read-SceneLog.ps1`. Flag `$ENABLE_SCENE_LOG`. First room:
**132 nodes, 3 roots, max depth 7**, walk verified coherent.

**The tree shape came free from `0x55378`**, the recursive transform propagator — it
has to walk the hierarchy to push world matrices down, so it names the links:
`mov edx,[ebp+0x3C]` (first child) / recurse / `mov edx,[edx+0x34]` (next sibling).
Same function gives `0x4272C` = 4×4 multiply (`world = local × parentWorld`) and
`0x552EC` = build local matrix. **Pick the function that MUST traverse.**

Frame fields, beyond those in [[azrael-camera-transform]]:

| Offset | Meaning |
|---|---|
| `+0x1C` / `+0x20` | move-callback count (0/1) + list node `{fn=0x459B4, arg}` |
| `+0x24` | **the frame's NAME**, a plain C string |
| `+0x34` / `+0x38` | next / **previous** sibling (reciprocal check: 98 of 98) |
| `+0x3C` / `+0x40` | first / **last** child (child-chain end matches: 33 of 33) |
| `+0xD0` / `+0xD4` | a **third** tag+4×4 block, identity in the sample |

**Camera hierarchy — settles the open question in [[azrael-camera-transform]].**
`[0x152144]` and `[0x162DE4]` are grandchild and grandparent, not unrelated:
`root -> movement frame [0x162DE4] -> "dummy" (player body) -> camera [0x152144]`.
The earlier "distinct" verdict came from comparing only immediate parents.

**The scene is semantically named.** Level: `wall01..wall24`, `floorbit..floorbit15`
(Y +127.7 = ceiling, -138.7 = floor), `dorwall`, `textwall`, `tunnel02..07`,
`doorcor`, `entcori`, `zxcoriR2/R5`, `zyR02/R05`, `Object01..03`, `spaview`, `r1p1`,
`save`. Two full articulated rigs `XAFQ1`/`XAFQ2`, ~30 named bones each:
`EUBUM -> EUTAIL, EUBODY -> EURSTUMP/EULSTUMP/EUNECK02 -> EUNECK01 -> EUHEAD ->
EUJAW/EUEYE`, `EUxTHIGH -> EUxLEG01 -> EUxLEG02 -> EUxFOOT`, plus `BLOOD01..03`.
Every bone has a live world 4×4.

**Only 61 of 132 frames have an attachment** — exactly `dummy` plus the two rigs.
`0x459BC` stores a frame into `[obj+0x48]` of an object of class tag **`0x147B78`**
and registers callback `0x459B4` on it (add `0x45180`, remove `0x5E7B0`). So `+0x20`
is a move-callback registration whose `arg` is the `0x147B78` object.
**RESOLVED: `0x147B78` is `Animation`, NOT the mesh class.** See [[azrael-rl-object-model]].

**RESOLVED — the geometry was always there.** `Frame` is 736 bytes and that dump stopped at `+0x13F`. The visual list is at **`frame+0x268`**, and **124 of 132 frames carry exactly one Mesh**, walls and floors included. See [[azrael-rl-object-model]].

**Traps paid for here.** `INT 21h AH=3Ch` **returns the handle in AX**, so creating a
log file DESTROYS eax — the first walk climbed from the wreckage and emitted one node
at `0x001300F0`. Stash pointers in memory across any INT 21h. Better still, get the
root from the engine: `0x42410(handle)` returns the ROOT frame's handle via `0x55540`.
Also: **PowerShell resolved my short helper names to builtin aliases** — `gu` is
Get-Unique and `rd` is Remove-Item, producing pages of nonsense errors. Use verbose
helper names, and remember `$r`/`$R` are the same variable (hit twice in one session).
