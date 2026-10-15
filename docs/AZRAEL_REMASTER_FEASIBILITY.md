# Azrael's Tear — Enhanced Runtime Feasibility Report

---

## BOOKMARK — state of play, 2026-09-27

**Option 1 (host pixels inside the original game) is COMPLETE and verified end to end.**
Read §14g, §14j-b, §14l and §14m for the detail; this is the short version.

| stage | state |
|---|---|
| Assets — geometry, textures, rooms, triggers, animation | done, all offline from disk |
| Live state — camera, scene graph, per-object transforms | done, read from host, no emulator fork |
| Host→guest write path, frame sync | done, 0 frames missed |
| Suppressing the engine's 3D output | done, one-byte branch patch |
| Injecting host pixels, full 1024×576 frame | done, **1.5% frame-rate cost** |
| The game's live 256-colour palette | captured, 255 distinct colours |
| **The whole loop** — live camera → Blender → quantise → inject | **done, lines up on screen** |

**Where the work goes next: a Unity layer.** The intent is to keep improving the game
*in its current engine* for now, then move presentation to Unity later. Nothing done here
is wasted by that move — the same camera matrices, per-object transforms, `.XAF` geometry,
textures and room graph feed Unity directly, and the reading half of the bridge is the
part Unity needs.

**The one constraint that does not go away in option 1:** the viewport is 8-bit, so host
frames can never exceed 256 colours. That ceiling is the reason option 2 (host renders in
its own window, the game runs as simulation) is the eventual destination.

**To resume the in-engine work:** the build is `src\Build-AztMod.ps1` → `Apply-AztMod.ps1
-Install -Dest C:\Games\AzraelsTear-Modded`. Injection ships **disabled**
(`aztInjEnable = 0`); nothing in the current build changes normal play.

---

Investigation only. No invasive changes were made in producing this.

Evidence is drawn from three sources, all reproducible:

* **Static analysis** — Ghidra 12.1.4 project at `C:\Tools\azt\proj` (name `Azrael`),
  plus AztMod's own C# LE loader/disassembler in `AztMod\tools`.
* **Runtime measurement** — the frame-rate logger and CD-audio event logger already
  built into AztMod's overlay, which write to files the host can read.
* **Two years of accumulated patch work** — 390 verified patch sites whose
  expect-checks pass against the shipped binary, which is itself strong evidence
  that the addresses below are right.

Confidence is marked on every conclusion: **CONFIRMED**, **STRONG**, **LIKELY**,
**SPECULATIVE**, **UNKNOWN**.

---

## 0. Executive summary — read this first

Three findings dominate everything else, and two of them cut against the premise
of the proposed architecture.

**1. The internal 3D renderer is already resolution-independent, and we already
exploit that.** The 3D view is not a fixed 320×200 or 640×480 buffer that gets
upscaled. Reality Lab creates a viewport at runtime from computed width/height,
and AztMod already patches those to **1024×576**. The game genuinely rasterises
at that resolution. *(CONFIRMED — §3)*

**2. Rasterisation is not the bottleneck, so a host renderer will not make the
game faster.** Measured: going from 1024×768 to 1280×1024 — **1.73× the pixels** —
cost **7.5% of the frame rate**. Per-pixel work can therefore only be ~10–15% of
frame time. The game runs at ~22–24 fps because of *emulated CPU work that does
not scale with screen area*, with DOSBox already at `cpu_cycles_protected = max`
on a single core. Moving rasterisation to the GPU would buy at most ~15%.
*(CONFIRMED by measurement — §11)*

**3. The cleanest seam is the Reality Lab scene graph, not the framebuffer.**
This is a **retained-mode** engine. The game does not stream triangles at a
rasteriser; it builds a persistent graph of frames (transforms) and meshes, then
asks the viewport to render it. That graph is the world, already marshalled into
a traversable structure, in a format that is semi-documented because Reality Lab
became Direct3D Retained Mode. *(STRONG — §10)*

**What this means for the goal.** "Original brain, modern body" is technically
viable, but its payoff is *visual*, not performance, and the single biggest visual
win — arbitrary resolution — is already banked without any of it. The remaining
prizes are modern assets, lighting and materials. Those are real, but they should
be pursued with clear eyes about cost.

---

## 1. Game executable architecture — CONFIRMED

| Property | Value | Evidence |
|---|---|---|
| Format | LE (Linear Executable), DOS/4GW extended | LE signature; DOS/4GW stub |
| Compiler | Watcom C/C++ | register calling convention throughout; `..\rl\*.c` assert paths |
| Objects | 2 | LE object table |
| obj1 | base `0x10000`, virtual size **1,190,259** bytes — code + const data | `LeImage.ObjData[1]` |
| obj2 | base `0x140000`, virtual size **359,888** bytes — data + BSS | `LeImage.ObjData[2]` |
| Relocations | **28,880 fixups** | fixup table walk |
| Entry | main loop reached via `AztFrameHook`; frame limiter at `0x50F2D` | AztMod patch |

**A trap worth recording.** The LE header's data-pages offset field is **wrong** in
this binary; the real value (`0x61A54`) must be derived from the file tail. Any
tool that trusts the header will silently mis-load everything.

**A second trap, found while setting up Ghidra.** Loading the raw file gives
*un-relocated* operands. At `0x3B05B` the bytes are `83 3D EC 24 04 00 00` —
`cmp dword [0x000424EC], 0` — but the game sees `0x1824EC`, because the LE loader
adds obj2's base via a fixup. **Every data address in a naive Ghidra import is
wrong by an object base.** The project at `C:\Tools\azt\proj` imports images
dumped from the loader's relocated `ObjData`, so its addresses match the running
game, AztMod's notes and the patch table exactly.

---

## 2. Graphics architecture — CONFIRMED

The 3D pipeline is **RenderMorphics Reality Lab**, the engine Microsoft acquired
in 1995 and shipped as Direct3D Retained Mode.

Evidence: the string `Rendermorphics ERROR:` at `0x140013`, and compiled-in
assertions carrying their original source paths — `..\rl\device.c`,
`..\rl\object.c`, `..\rl\math.c`, `..\rl\tilemap.c`, `..\rl\api\object\objdes.c`,
`..\gen\rampmap.c`, `..\ramp\ramplt.c`. Also the symbols `MeshRenderer`,
`MatCache`, `GetTextureMemory`, `DefragTextureCache`, `TextureItemInUse`.

**Only the `ramp` modules are linked** — the 8-bit palettised software rasteriser
that lights through ramp tables. There is no HAL or hardware device module.

Two consequences that constrain everything downstream:

* The pipeline is **palette-bound end to end**. Textures are 8-bit indices lit
  through ramp tables, not RGB.
* It is **statically linked**. Unlike Glide titles (which DOSBox-X can accelerate
  because `GLIDE2X.OVL` is a loadable module with a stable ABI), there is no
  module boundary to trap. Any interception hooks hard-coded addresses valid for
  exactly this build.

---

## 3. Internal render resolution — CONFIRMED

**This directly answers the A/B/C/D question in the brief. The answer is B + C.**

`FUN_00010fec` (`0x10FEC`) is the render-resolution setter, driven by the in-game
`1`/`2`/`3` keys. Decompiled:

```c
DAT_00152138 = FUN_0003a630((0x228 / divider) - DAT_00152aec,    // 0x228 = 552
                            (0x11a / divider) - DAT_00152aec);   // 0x11a = 282
FUN_00037b04();
FUN_0003a840(0x46ea6000);   // float 30000.0 — far clip   (SetBack)
FUN_0003a8a0(0x3f4ccccd);   // float 0.8     — field of view (SetField)
```

So the 3D viewport is **created at runtime from computed dimensions**, stored at
`[0x152138]`. Stock is 552×282 divided by a quality level. It is not a compile-time
constant baked into the rasteriser.

**AztMod already changes this**, not merely the output resolution:

* VESA mode patched `0x101` → `0x105` (`lfb-mode-bit`, and the mode literal at `0x33ABB`)
* the view surface and its stride patched to **1024×576**
* ~50 sites keyed to `VIEW_W`/`VIEW_H` — render buffer, stride, row offsets, clip
  limits, projection centre, z-buffer

A previous attempt to add supersampling established the decisive point: at
divider 1, **the render target *is* the view surface** (per `0x281ED`). There is no
separate internal buffer being scaled up. The game is genuinely rasterising
1024×576 polygons.

**Therefore the renderer already supports arbitrary resolution with dimensional
assumptions removed — because we removed them.** The practical ceiling now is
memory and the texture-cache reserve, not the rasteriser.

---

## 4. Framebuffer architecture — CONFIRMED

| Property | Value |
|---|---|
| Output | VESA linear framebuffer at **`0xC0000000`** (`PhysBasePtr`) |
| Addressing | flat, 32-bit offsets; directly addressable from DOS/4GW without DPMI mapping |
| Colour depth | 8-bit palettised |
| Stride | screen width (1024 currently) |
| Blit primitive | `0x33F80` — `Blit(eax = surface, edx = x, ebx = y)` |
| Blitters | three, at `0x50EA5`, `0x5111C`, `0x513BF` |

A **surface** is a 16-byte header: `+0` width (word), `+2` height (word), `+4`
pixel pointer (dword), `+8..+0xE` clip rect. The 3D view surface is `0x152150`.

**Bank switching is disabled**, not worked around: all three blitters are forced
down their own existing linear fast paths, and the dispatcher is told the VESA
window is large enough to hold the whole framebuffer so it never splits a rect.
That window size is **resolution-dependent** and derived at build time — a fixed
value silently corrupts the panel above 1024 wide.

---

## 5. Camera representation — CONFIRMED (measured in the running game)

There are **two distinct camera notions**, and conflating them would waste weeks.

**(a) Game-level orientation** — `0x1CF3C` is the entire turn routine:

```c
DAT_00162dfa            += pitch_delta;   // pitch, 16-bit
DAT_00162df6._2_2_      += yaw_delta;     // yaw at 0x162DF8, 16-bit
```

Six callers: combat edge-turn `0x13F71`, PgUp `0x12F9D`, PgDn `0x12FB5`, auto-aim
`0x24432`/`0x24458`/`0x244E0`. Eye height is a float at `0x1388B` (AztMod sets −85).

**(b) Reality Lab frame transforms** — the actual 3D camera. `FUN_0003ec20`
(`0x3EC20`) is `Frame::SetPosition`:

```c
*(frame + 0x7c) = x;  *(frame + 0x80) = y;  *(frame + 0x84) = z;
*(frame + 0x48) = 1;  *(frame + 0x44) = 1;    // dirty flags
```

`FUN_0003c690` (`0x3C690`) is `Frame::GetPosition`; it copies **17 dwords** from
either `frame+0x48` or `frame+0x8C` depending on the reference frame — a 4×4
matrix plus a tag.

**Frame structure — now settled by measurement, not inference.** The §14 experiment
(below) read these fields out of the running game for 1,362 consecutive frames.

| Offset | Meaning | Confidence |
|---|---|---|
| `+0x14` | the frame's **handle** — what the globals actually store | CONFIRMED |
| `+0x18` | class/type tag; equals `0x147EDC + obj2 delta` for a frame | CONFIRMED |
| `+0x30` | parent frame | CONFIRMED |
| `+0x44` | dirty byte, tested by the lazy refresh `0x554F0` | CONFIRMED |
| `+0x4C` | 4×4 transform, **local** (relative to parent) | CONFIRMED |
| `+0x7C/+0x80/+0x84` | position x, y, z — local; row 3 of the local matrix | CONFIRMED |
| `+0x90` | 4×4 transform, **world** | CONFIRMED |
| `+0xC0/+0xC4/+0xC8` | position x, y, z — world; row 3 of the world matrix | CONFIRMED |

The matrices sit at `+0x4C`/`+0x90`, not `+0x48`/`+0x8C` as first supposed. Both
encodings in `GetPosition` agree on this and that agreement is the proof: it copies
`0x11` dwords starting at `+0x48`/`+0x8C`, then returns copy offsets
`0x34/0x38/0x3C` as x/y/z. So each block is one leading dword followed by the 4×4,
the translation is the matrix's fourth row, and that lands exactly on the
independently-known `+0x7C/0x80/0x84`. A wrong offset could not satisfy both.

**The globals hold handles, not object pointers.** `GetPosition`/`SetPosition` pass
them through `0x33048` first, so `[0x152144]+0x7C` reads garbage. The resolver is
**`0x39E50`**, a chained-hash lookup (`div 0x3FD` into the bucket table at
`0x1831CC`, matching `[obj+0x14]`) that is **completely free of side effects** —
which is what makes it safe to call from inside the frame loop. `0x42410` is *not*
the unwrap: it resolves the handle and then returns `[root+0x14]`, the **scene
root's** handle, which is why the movement code uses it as its reference frame.

**Two distinct frames, and they are not parent and child:**

| Global | Role | Handle (observed) |
|---|---|---|
| `[0x152144]` | the frame passed to `Viewport::Create` at `0x10F65` — **the camera** | `0x14` |
| `[0x162DE4]` | the frame the movement code drives (all 13 refs in `0x1CF64..0x1E0A0`) | `0x03` |

Both are confirmed frames (identical type tag). Their parents differ, neither is the
other's parent, and their world poses are **the same to within 0.05 units while
stationary**, diverging to ~1.3 units average (max 2.65) only while moving — purely
in the sagittal plane, lateral component zero to ±0.03. That divergence correlates
with neither pitch (−0.21) nor speed (0.13), so it is an update-ordering artifact
within the frame rather than a designed eye offset. **A host-side renderer should use
`[0x152144]`'s world matrix**, because that is the frame the viewport renders with.

`[0x152144]`'s **local** matrix is exactly identity at every frame — the camera frame
is a pure attachment point and its entire pose comes from its parent chain. Its
**world** matrix carries the complete pose including pitch, which is clamped
symmetrically at ±40.89°.

**Viewport object** (created by `0x3A630`, pointer at `[0x152138]`):

| Offset | Meaning | Confidence |
|---|---|---|
| `+0x2C` | owning device | STRONG |
| `+0x34/+0x38` | x, y on device | STRONG |
| `+0x3C/+0x40` | **width, height** | CONFIRMED |
| `+0xC4` | `100.0` — BACK clip (30000.0 after SetBack) | CONFIRMED 2026-10-13 |
| `+0xF4` | `1.0` — FRONT clip | CONFIRMED 2026-10-13 |
| `+0xF8/+0xFC/+0x100/+0x104` | ±field (±0.5 until SetField; 0.8 after) — see docs/notes/azrael-fov.md | CONFIRMED 2026-10-13 |

**Projection constants are single floats set by ordinary calls** — FOV `0.8` via
`0x3A8A0`, far clip `30000.0` via `0x3A840`. Widescreen FOV is therefore a
*one-float change*, not a pipeline rewrite. **(STRONG)**

---

## 6. Model / resource architecture — MIXED

**Textures — CONFIRMED and fully decoded.** `.RES`/`.azf` containers hold a
`D3DRMIMAGE` header, a per-texture palette, and static-Huffman-compressed pixels
(decoder at `0x2D558`). Measured across 172 files: **2,805 textures**, of which

| longest edge | count | share |
|---|---|---|
| 64 | 38 | 1.4% |
| 128 | 505 | 18.0% |
| **256** | **1,908** | **68.0%** |
| 512 | 354 | 12.6% |

`RESOURCE.CFG` redirects texture loading to the hard disk with no patch needed —
an existing, working override hook.

**Models and level geometry — UNKNOWN, and not where you would expect.** The
shipped loose files are almost all *text manifests*:

* `.ANI` (35 files) — `NUM_FILES 1 / OFF...`, plain text
* `.ZAP` — text lists naming `.SND`, `.DES`, `.BOK` resources
* `.DAT` — mostly text (`AZONES.DAT` begins `EntryCoordWash`; `CHARLIST.DAT` is a
  name list). `CHARS.DAT` is a binary struct table with embedded names and `0xCC`
  padding.
* `.LST`/`.CAT` — Miles sound driver configuration, `;`-commented text

Total loose data is ~3 MB against **`AZT.BIN` at 487 MB**. Geometry therefore lives
inside that ISO image, which is a MODE1/2352 track we already parse for texture
extraction. ~~Finding model and room geometry means walking `AZT.BIN`'s filesystem,
and that work has not been done.~~

> **CORRECTION — the geometry was never hidden. It is the `.XAF` files, and they are
> plain text.** Found incidentally while mapping textures to their `.RES` packs.
> `C:\AZTEX` holds 178 non-empty `.XAF` files, **26 MB, 100% printable ASCII**, in a
> brace-delimited format carrying the whole scene:
>
> ```
> material "FLOOR1" { texture "ecrflr01.gif" colour {...} specular {...} }
> object "wall2" {
>   matrix { 4x4, row-major, translation in the last row }
>   mesh { vertices {...} normals {...} texture_coordinates {...}
>          faces { 3, v,t v,t v,t ... 0 }
>          material "CORWALL1" } }
> ```
>
> Census: **8,395 objects / 8,395 meshes across 178 files**, with 64 objects in
> `CORICORI` (room 1) and up to 156 in `POIS_GR5`. Object names match the live scene
> graph names recovered in §14b, and a `.XAF`'s texture references match its `.RES`
> records in first-appearance order (verified: all 21 `CORICORI` names appear in the
> live room-1 capture, and record 12 `ecrdor02` is 512×512 in both).
>
> **Consequence for §14d/§14e:** the live-memory capture is no longer the only route to
> geometry, and the play-through-every-room problem disappears for *static* geometry.
> Live capture remains necessary for what the `.XAF` cannot contain — runtime state,
> posed animation and object instancing.
>
> One wrinkle worth recording: some `.XAF` files reference textures as `name.azf` and
> others as `name.gif`. `Export-RoomTextures.ps1` matched only `.azf` and so silently
> found **zero** names in `CORICORI.XAF`. Match both.

---

## 7. Animation architecture — LIKELY, partly known

Animation is driven by **Reality Lab move callbacks**, not by a bespoke animator:
`0x44DD0` is `AddMoveCallback` and `0x44D7C` is `SetTime`. The engine invokes every
registered callback once per frame.

AztMod already intervenes here: animation advance happens at **six `+1` sites in
three move callbacks** (`0x229A4`, the direct entry at `0x24090`, and a room-init
path at `0x1E4B0`), all now gated on a microsecond clock rather than frame count.

Separately, `0x261C0` is a **script interpreter**, not the animator — it walks a
program counter at `actor+0x3C` over 0x23-byte opcodes. This was mislabelled once
and cost a full debugging cycle.

Whether the underlying representation is skeletal, vertex-morph or hierarchical
frame transforms is **UNKNOWN**. Given Reality Lab, hierarchical frame transforms
are the most likely (**LIKELY**), which would be good news — it means animation
state is readable as transforms on the same frame objects described in §5.

---

## 8. Level architecture — UNKNOWN

Not investigated. What is known:

* Rooms load via a path that sets the music cue (`0x1150B` writes the cue index
  from `[edi+0x1529D0]`), so room transitions are observable.
* A texture-cache reserve is computed at room load: `0x1BE79` gives the cache
  *(largest free block − 4.5 MB)*, which is the cause of the big-room out-of-memory
  crash and cannot be fixed by raising `memsize`.
* `AZONES.DAT` is text containing entry coordinates — a lead for room adjacency.

---

## 9. DOSBox Staging integration points — LIKELY

Not yet examined in source, so this section is the least evidenced.

What is already established from the runtime side:

* The game is a **protected-mode DOS/4GW** binary; its memory is inside DOSBox's
  emulated address space. Guest linear addresses are stable because AztMod
  computes them and 390 patches verify against them.
* **DPMI works from inside the game.** AztMod already allocates a real-mode buffer
  (`INT 31h AX=0100h`) and performs real-mode calls (`AX=0300h` with a 50-byte
  RMCS) to reach MSCDEX. That proves a guest→host service path exists and is
  usable, which is the same mechanism a bridge would need.
* The low 1 MB is identity-mapped and directly addressable from the flat model —
  `segment * 16` is a valid pointer.

The realistic hook points, in increasing invasiveness:

| Hook | What it gives | Cost |
|---|---|---|
| A guest-side "mailbox" in BSS, polled by a forked DOSBox | any state we choose to publish | small guest patch + small emulator patch |
| Fake I/O port or unused interrupt as a bridge | synchronous guest→host calls | emulator fork |
| VGA/VESA presentation hook | finished frames only | emulator fork, no world data |
| Memory-write watchpoints | change notification | expensive if global |

**The mailbox approach is strongly preferable**, and we can prototype the guest
half *today* with no emulator work at all — see §14.

---

## 10. Candidate seams — the central question

| Seam | Leverage | Rewriting required | Verdict |
|---|---|---|---|
| framebuffer → DOSBox | pixels only | none | Already exploited via Staging shaders. No world data — dead end for a remaster. |
| renderer → framebuffer | finished 2D | low | Same limitation. |
| transformed geometry → rasteriser | screen-space triangles | medium | Post-transform, post-clip: you inherit the original projection and gain little. |
| **scene graph → renderer** | **world geometry, transforms, materials** | **medium** | **Best leverage.** See below. |
| game objects → renderer | object ids + transforms | medium | Good for *model replacement*, weaker for environments. |
| emulated memory → host | everything, unstructured | high | Needs the structures anyway; this is the transport, not the seam. |

**The scene graph is the seam.** Reality Lab is retained mode: the world is a
persistent hierarchy of frames (transforms) and meshes that the application builds
once and mutates, then renders with a single call. That means:

* Geometry, transforms, materials and hierarchy are **already assembled in memory**
  in a traversable structure — we do not have to reverse the on-disk model format
  to get at them.
* The structures are **semi-documented**, because this engine became Direct3D
  Retained Mode. `IDirect3DRMFrame`, `IDirect3DRMMesh` and friends are described
  in public documentation, and the field offsets we have recovered (§5) are
  consistent with that lineage.
* Object identity, position and animation state all hang off the same frames, which
  is exactly what a host-side model-replacement system needs (§ Strategy B).

**This is the highest-value finding in the report**, and it reframes the project:
the work is not "reverse the model format" but "walk a known-shaped scene graph in
emulated memory".

---

## 11. Performance reality — CONFIRMED, and it constrains the goal

Measured with an in-overlay frame counter writing one sample per second, during
real play, with the frame cap raised so it recorded the machine's ceiling:

| Build | samples | min | max | mean | reached the 48 fps cap |
|---|---|---|---|---|---|
| 1280×1024 (view 1280×797) | 66 | 10 | 40 | **22.3** | **0 of 91** |
| 1024×768 (view 1024×576) | 86 | 13 | 40 | **24.1** | **0 of 115** |

**1.73× the pixels cost 7.5% of the frame rate.** For those two numbers to sit that
close, per-pixel work can only be ~10–15% of frame time. The rest is emulated CPU
work that does not scale with screen area: per-polygon transform, clipping, setup,
game logic and the script interpreter.

Three consequences:

1. **A host GPU renderer cannot deliver a large speed-up.** Its ceiling is the
   ~10–15% currently spent on fill. *(CONFIRMED)*
2. **There is no cycles headroom to reclaim.** `cpu_cycles_protected = max` already
   lets Staging use everything one core sustains, and DOSBox emulates the CPU
   single-threaded. *(CONFIRMED)*
3. **Resolution is nearly free, so raising it further is cheap** — 1280×1024 costs
   about 2 fps and is available now. It was abandoned only because 87% of textures
   are ≤256 px, so it bought no visible sharpness.

This also supersedes an earlier note in the project that called the rasteriser
"the bottleneck" — that was inferred from static analysis and is contradicted by
measurement.

---

## 12. Unknowns, ranked by how much they block the goal

| # | Unknown | Blocks | Cost to resolve |
|---|---|---|---|
| ~~1~~ | ~~Can we read live camera/world state out of the guest at all?~~ **RESOLVED — yes. §14a** | — | done |
| ~~2~~ | ~~Scene graph root and traversal order~~ **RESOLVED — first-child/next-sibling, fully enumerated. §14b** | — | done |
| ~~3~~ | ~~Mesh structure: vertex/face layout, UV format, winding~~ **RESOLVED — vertices 48B with UVs, faces = inline 120B Face objects, per-corner normals, winding CONFIRMED. §14d** | — | done |
| ~~4~~ | ~~Where geometry lives inside `AZT.BIN`~~ **RESOLVED — it is not in `AZT.BIN` at all. The `.XAF` files are plain-text scene descriptions: 178 files, 26 MB, 8,395 objects carrying vertices, normals, UVs, faces and materials. See the correction in §6** | — | done |
| ~~5~~ | ~~Animation representation~~ **RESOLVED — three head/tail key lists (rotation quaternion / position / scale), sorted by time. §14e** | — | done |
| ~~6~~ | ~~Room/portal/visibility structures~~ **ROOM GRAPH + TRIGGERS RESOLVED — `AZONES.DAT` is a flat 319-record table on disk: 87 rooms, 166 portals, 127 scripted events, plus the room→file mapping. §14i.** *Visibility/culling is still unexamined — no evidence yet of a PVS or portal culling* | visibility only | graph: done |
| ~~7~~ | ~~DOSBox Staging bridge mechanics~~ **READ PATH RESOLVED — no fork needed.** `ReadProcessMemory` reaches live guest state; verified by reading the player's walked route out of the running game. §14g. *Write path and frame synchronisation remain open.* | host rendering sync | read: done |
| ~~8~~ | ~~Suppress original renderer while keeping UI~~ **RESOLVED — YES. A one-byte branch patch at `0x14160` freezes the 3D output (1.62% → 0.00%) while the HUD still repaints (70.44%). §14j-b.** *Host-drawn pixels into the engine's 3D buffer remain unresolved* | host-composited viewport | suppression: done |

---

## 13. Architectural options, assessed against the evidence

| Option | Feasibility | RE effort | Perf gain | Modern assets | Risk |
|---|---|---|---|---|---|
| **A. Patch original renderer for higher res** | **Done already** | — | +0 | no | none |
| B. Higher-poly assets in original engine | Unproven; palette- and cache-bound | high | negative | partial | high |
| **C. DOSBox fork + host renderer** | Viable via §10 seam | **very high** | ≤15% | **yes** | high |
| D. External process reading state | Viable for *observation*; can't render in-place | medium | n/a | n/a | low |
| E. Renderer command interception | Weak — static linking, no module ABI | high | ≤15% | partial | high |
| F. Full engine recreation | Possible (RL is documented) but abandons the "original brain" goal | extreme | large | yes | extreme |
| **G. Hybrid: original sim + host overlay** | Best balance | high | ≤15% | yes | medium |

**Recommendation: G, approached incrementally, and only after §14 succeeds.**

Take the parts of C that pay off soonest — camera extraction, then object
transforms, then host-rendered replacement models composited over the original
view — while leaving the original renderer responsible for the world until a host
renderer demonstrably matches it. Do **not** begin by suppressing the original
viewport.

And be honest about the payoff: this is a **visual** project. The evidence says it
will not make the game run faster.

---

## 14. The highest-value next experiment

**Publish the live camera transform from inside the game to a file the host can
read, and verify it tracks movement.**

This is Milestone 3 and most of Milestone 4, and it can be done **with no emulator
work and no new infrastructure**, because AztMod already has every piece:

* an overlay with **51,311 bytes free** at `0x133000`
* a per-frame hook that runs after the overlay is resident (`AztOvlFrame` at `+9`)
* a **proven file-writing mechanism** — the frame logger and CD event logger both
  open a file via `INT 21h AH=3Ch`, append with `AH=40h` and commit with `AH=68h`,
  and I have read both back from Windows this session

The experiment: each frame, walk to the camera frame object, read position
(`+0x7C/+0x80/+0x84`) and the 4×4 at `+0x8C`, and append them with a timestamp.
Then walk a known route in-game and check the numbers move correctly and
consistently — forward should change one axis, turning should rotate the matrix.

**Why this first:**

* It answers unknown #1, which blocks everything else.
* It proves or kills the whole "expose internal state to host code" premise for a
  few hundred bytes of overlay code.
* It produces the data needed for Milestone 5 (native camera following) without
  committing to a DOSBox fork.
* If the camera frame is not where §5 predicts, we learn that cheaply.

**Explicitly not yet:** no DOSBox fork, no GPU renderer, no model extraction, no
touching the original viewport.

---

## 14a. RESULT — the experiment was run, and it CONFIRMS the premise

Implemented as `AztCamLog`/`AztCamSnap` in the overlay (+12 bytes of record fields
over two builds; 50,685 bytes of BSS still free), decoded by
`tools\Read-CamLog.ps1`. **Two runs, 1,268 and 1,362 consecutive frames.** Nothing
in the engine is modified — the log is purely observational, and the lazy transform
refresh `0x554F0` is deliberately *not* called, because the renderer has already
consumed the world matrices by the time the frame hook runs; calling it would mean
mutating engine state in order to observe it.

**What is now proven:**

1. **The live camera transform is readable every frame.** 22.2 records/s over a
   61.45 s route, which independently matches the known ~22–24 fps.
2. **It is genuinely a rotation matrix.** All four logged matrices are orthonormal
   to ~2.4e-7 — worst `|len−1|` 2.41E-007, worst row dot 1.42E-007. This is the
   check that makes the offsets fact rather than plausibility: a wrong offset does
   not stay orthonormal for 1,362 frames.
3. **It tracks movement correctly.** Walking moved the camera 231.7 units in 1.71 s
   with zero rotation; a deliberate on-the-spot turn produced **exactly 90.0° of
   yaw while translating 0.01 units**. Full yaw range covered (359°).
4. **Pitch is present in the camera's world matrix**, clamped at ±40.89°. So this
   single 4×4 is the complete camera pose — nothing further is needed for a
   host-side renderer to follow the DOS camera.
5. **Frame identity is proven, not assumed.** The stub also logs the obj1/obj2 load
   deltas (`0x1F0000`/`0x1F1000`, putting obj1 at `0x200000` — matching earlier
   notes), which closes the arithmetic on the type tag: observed `0x338EDC` is
   exactly `0x147EDC + obj2 delta`, so both frames are confirmed Reality Lab
   frames. Without the deltas this could only ever have been an inference, since
   every pointer the engine returns is relocated.

**Corrections this produced** — both were wrong in the static analysis and would
have cost real time downstream:

* the globals hold **handles**, not object pointers (resolver `0x39E50`);
* the matrices are at **`+0x4C`/`+0x90`**, not `+0x48`/`+0x8C`;
* `0x42410` returns the **scene root's handle**, it is not the unwrap helper.

**Still open:** the relationship between `[0x152144]` and `[0x162DE4]`. They are
distinct frames with different parents, co-posed when stationary and diverging
~1.3 units while moving. This does not block anything — the camera's own world
matrix is authoritative — but the parent chain has not been walked.

Method note, consistent with the rest of this project: **instrumenting the running
game settled in one pass three things that static reading had gotten wrong.**

---

## 14b. STAGE 2 RESULT — the scene graph is fully enumerable

Implemented as `AztSceneLog`/`AztScnEmit` in the overlay, decoded by
`tools\Read-SceneLog.ps1`. One shot per run, fired on the first frame the camera's
world translation is non-zero. **132 nodes, 3 roots, max depth 7**, and the walk
verified coherent: every node visited exactly once, every non-root node's parent
visited, every depth equal to parent depth + 1.

The tree shape was **not** guessed. The recursive transform propagator at `0x55378`
must walk the hierarchy to push world matrices down, so it names the links outright
(`mov edx,[ebp+0x3C]` / recurse / `mov edx,[edx+0x34]`). It also gave up `0x4272C`
as the 4×4 multiply and confirmed the tag-then-matrix block layout independently.

**Frame fields — CONFIRMED, each by a reciprocity check rather than by inspection:**

| Offset | Meaning | How it was confirmed |
|---|---|---|
| `+0x00` | hash-bucket chain | the link `0x39E50` follows |
| `+0x14` | handle | 132 distinct, one per node |
| `+0x18` | class tag | identical on all 132 |
| `+0x1C` | move-callback count | 0 or 1 only; non-zero on exactly the `+0x20` nodes |
| `+0x20` | move-callback list `{fn, arg}` | `fn` is always `0x459B4` |
| `+0x24` | **the frame's NAME** (C string) | reads as ASCII |
| `+0x30` | parent | 129 resolve to nodes; the 3 that don't are the 3 roots |
| `+0x34` | next sibling | 98 resolve to nodes |
| `+0x38` | **previous sibling** | `next.prev == self` for 98 of 98, 0 bad |
| `+0x3C` | first child | 33 resolve to nodes |
| `+0x40` | **last child** | end of the child chain == `+0x40` for 33 of 33, 0 bad |
| `+0x44` | dirty byte | cleared by `0x55378` |
| `+0x4C` / `+0x90` | local / world 4×4 | §5 |
| `+0xD0` / `+0xD4` | a **third** block, tag + 4×4 | identity on all 132 here |

**The camera hierarchy, which §5 left open.** `[0x152144]` and `[0x162DE4]` are not
unrelated after all — they are grandchild and grandparent:

```
0  depth 0  0x0129964C  (root)
1  depth 1  0x01299934  the MOVEMENT frame        [0x162DE4]
2  depth 2  0x01299C1C  "dummy"  + attached obj   the camera's parent
3  depth 3  0x0129D708  the CAMERA                [0x152144]
```

`"dummy"` is the player's body. The earlier "DISTINCT and not directly related"
verdict came from a decoder that compared only immediate parents; the intermediate
local transforms are also what produce the small cam/mov divergence while moving.

**The scene is semantically named**, which is far more than hoped for. Level nodes:
`wall01`..`wall24`, `floorbit`..`floorbit15` (the `+127.7` set is the ceiling, the
`-138.7` set the floor), `dorwall`, `textwall`, `tunnel02`..`07`, `doorcor`,
`entcori`, `zxcoriR2/R5`, `zyR02/R05`, `Object01`..`03`, `spaview`, `r1p1`, `save`.

**Two complete articulated character rigs**, `XAFQ1`/`XAFQ2`, each ~30 named bones
in a real skeleton: `EUBUM` → `EUTAIL`, `EUBODY` → `EURSTUMP`/`EULSTUMP`/`EUNECK02`
→ `EUNECK01` → `EUHEAD` → `EUJAW`/`EUEYE`, plus `EURTHIGH` → `EURLEG01` →
`EURLEG02` → `EURFOOT` and the left mirror, plus `BLOOD01`..`03`. Every bone has a
live world 4×4. For animated characters that is exactly what a host renderer needs.

**Only 61 of 132 frames carry an attached object**, and they are precisely `dummy`
plus the two rigs. `0x459BC` shows what the attachment is: it stores a frame into
`[obj+0x48]` of an object whose class tag is **`0x147B78`**, and registers/unregisters
callback `0x459B4` (which invalidates a frame's local-transform tag) via `0x45180` /
`0x5E7B0`. So `+0x20` is a move-callback registration and its `arg` is the
`0x147B78` object.

**STRONG, not confirmed:** `0x147B78` is the visual/mesh class. The population fits
(only the animated, visibly-rendered things have one) but the class has not been
identified by name and its contents have not been decoded.

**CORRECTION — the "no geometry on walls" worry was my own sampling artifact, and
class `0x147B78` is `Animation`, not Mesh.** Both are settled in §14c below. The
frames carrying that attachment are the *animated* ones, which is why the population
was `dummy` plus the two rigs; and the visuals were simply 300 bytes past where the
first dump stopped looking.

---

## 14c. The object model names itself — and the geometry is all there

**Reality Lab classes self-identify.** A class tag is not opaque: it points at a
descriptor holding a **name string at `+0x04`** and the **object size at `+0x08`**.
`0x147EDC` → `"Frame"` proved the scheme, and walking the table gives the whole
object model:

| tag | class | size | | tag | class | size |
|---|---|---|---|---|---|---|
| `0x1476A4` | Object200b20001 | 44 | | `0x148324` | Device | 828 |
| `0x147700` | Texture | 424 | | `0x148370` | Viewport | 592 |
| `0x147B44` | AnimationSet | 48 | | `0x1483A4` | Tilemap | 64 |
| `0x147B78` | **Animation** | 76 | | `0x148468` | Visual | 48 |
| `0x147BAC` | **Mesh** | 272 | | `0x1484A4` | Light | 124 |
| `0x147BEC` | Face | 120 | | `0x149240` | Tree | 68 |
| `0x147C20` | Material | 316 | | `0x149280` | MeshRenderer | 220 |
| `0x147EDC` | **Frame** | **736** | | `0x1492B4` | MatCache | 1072 |

Descriptor `+0x00` is the **base class**: Frame's is `Tree`, which is why frames
carry the parent/child/sibling links at all.

**`Frame` is 736 bytes and the first scene dump stopped at `+0x13F`** — less than
half of it. `Frame::AddVisual` (`0x49940`) validates its two arguments as Frame and
Visual, bumps `[visual+0x0C]` (refcount), then does `add eax,0x268` before the
list-append at `0x54C38`. So:

| Offset | Meaning | Confidence |
|---|---|---|
| `+0x268` | **visual count** | CONFIRMED |
| `+0x26C` | capacity | CONFIRMED |
| `+0x270` | → `Visual*[]` | CONFIRMED |

`0x54C38` is the engine's generic dynamic-array append (`items[count] = item` via
`[list+0x08]`, bumping `[list+0x00]`), so `{count, capacity, pointer}` is the shape
to expect throughout. `AddVisual` also sets `mesh+0x30` to the owning frame when the
visual is a Mesh, giving a back-link.

**Measured, not inferred: 124 of the 132 frames carry exactly one visual, and all
124 are of class `Mesh`.** The walls, floors, tunnels and markers all have geometry.
The 8 without are the root, the movement frame, the camera and a few pure transforms.

**Inside `Mesh` (272 bytes) there are three `{count, capacity, pointer}` arrays**, at
`+0x48/+0x4C/+0x50`, `+0x54/+0x58/+0x5C` and `+0x60/+0x64/+0x68`, plus `+0x14`
handle, `+0x18` class tag, `+0x0C` refcount and `+0x30` owning frame. The counts are
geometrically sensible:

| frame | arr1 | arr2 | arr3 |
|---|---|---|---|
| `wall2` (a quad) | 4 | 2 | 4 |
| `floorbit` (a slab) | 8 | 6 | 12 |
| `dorwall` | 15 | 24 | 40 |
| `ZZ0001EUHEAD` | 47 | 46 | 47 |
| **totals, 124 meshes** | **1377** | **1173** | **1749** |

**LIKELY, not confirmed:** arr1 is vertices and arr2 is faces — 4 vertices with 2
faces for a wall quad and 8 with 6 for a box both fit, and `Face` is its own 120-byte
class. But this is read off counts, not off code. `0x54C38` has exactly one caller
(`AddVisual`), so these three arrays are filled by another path that has not been
found, and arr3 is unidentified: it equals arr1 on the character meshes (47/47,
33/33) but not on the level meshes (8 vs 12, 15 vs 40), so "per-vertex normals" does
**not** hold generally.

---

## 14d. GEOMETRY — the mesh format is decoded. CONFIRMED.

The three arrays were followed one level and their payloads dumped. The earlier
"arr1 = vertices, arr2 = faces" guess was right, and arr3 is now identified too.

**`arr1` — VERTICES, 48-byte stride.** Confirmed on three meshes of very different
size (`wall2` 4, `floorbit` 8, `ZZ0001EUHEAD` 47):

| offset | field |
|---|---|
| `+0x00`,`+0x04`,`+0x08` | x, y, z (frame-local) |
| `+0x0C` | vertex colour, `0xFFFFFFFF` on every vertex seen |
| `+0x10`,`+0x14` | **u, v** — all within [0,1] |
| `+0x18`..`+0x2F` | zero on every mesh sampled |

`wall2`'s four vertices are unmistakably a textured quad: v0/v1 share y (−102.21, the
bottom edge), v1/v2 share x and z (a vertical edge), u runs along the bottom and v up
the side.

**`arr3` — NORMALS, 12-byte stride**, unit length (`wall2`: 0.2484, ~0, −0.9686;
0.2484² + 0.9686² = 0.9995). Count equals the vertex count on character meshes but
not on level meshes (`floorbit` is 8 verts / 12 normals), so it is a separate indexed
array, not strictly one-per-vertex.

**`arr2` — an INLINE ARRAY OF `Face` OBJECTS**, 120-byte stride — not an array of
pointers. Proven by the object header appearing at the array base: `+0x14` handle
(74), `+0x18` class tag `0x00338BEC` = `0x147BEC` = **Face**. (The `f0` dump came back
all zeros exactly as it should: `arr2[0]`'s first dword is 0, so the range guard
refused to dereference it as a pointer.)

**`Face` layout:**

| offset | field |
|---|---|
| `+0x0C` | refcount | 
| `+0x14` / `+0x18` | handle / class tag |
| `+0x2C`,`+0x30`,`+0x34` | **face normal** — matches the `arr3` entry |
| `+0x38` | face colour (`0xFF000000`) |
| `+0x44` | **vertex count = 3** — the faces are triangles |
| `+0x58` | → the mesh's vertex array (`= mesh+0x50`'s value) |
| `+0x64` | → the mesh's normal array (`= mesh+0x68`'s value) |
| `+0x4C`,`+0x50`,… | per-corner pointers, 12 apart (into the normal array) |

`wall2` = 4 vertices + 2 triangular faces + 4 normals: a quad, exactly right.

**Faces reference geometry by POINTER, not by index.** Extraction therefore recovers
an index as `(pointer − array_base) / stride`, which is trivial but must not be
overlooked.

**Room 1 totals: 1377 vertices and 1173 faces across 124 meshes** — a whole room's
geometry, with UVs, normals and per-frame world transforms, all readable live.

**What this means.** Every ingredient a host-side renderer needs for a complete room
is now confirmed reachable from inside the running game: the camera pose (§14a), the
named scene graph with world transforms per node (§14b), the visual list per frame
(§14c), and now vertices, UVs, normals and triangle faces (§14d). Nothing here
required an emulator fork.

**The remaining limit is sampling, not understanding.** Only the first 128 bytes of
each array were captured, so this proves the *format* but does not yet contain whole
meshes — 128 bytes is 2 vertices of a 47-vertex head. A variable-length dump of the
full arrays (1377 × 48 = 66 KB of vertices, 1173 × 120 = 140 KB of faces for room 1)
would produce an exportable OBJ of a real room. That is the next step and it is
bookkeeping, not discovery.

---

## 14e. ANIMATION and MULTI-ROOM — both decoded. CONFIRMED.

**Animation.** An `Animation` (obj2 class, 76 bytes) holds **three independent key
lists**, found not by guessing at accessors but by hooking the three functions that
*must* touch them — the key adders. Each list is a linked chain with **head and tail
pointers**; it terminates at the tail, **not at a null `next`**. Walking to null runs
straight into the next list's keys, which is how a first pass produced 968 "corrupt
rotations": they were position keys being read as quaternions.

| list | key payload | record |
|---|---|---|
| rotation | quaternion (4 floats) | 40 bytes: time + 4 floats + links |
| position | vec3 | same record, 3 floats used |
| scale | vec3 | same record, 3 floats used |

Keys are sorted by time. A capture of room 1 yielded **2,678 keys**. Two bugs are worth
recording because both were silent: `ANI_KEY_LEN` at 36 truncated the 4th quaternion
component, and `aztAniList` was never copied to `aztAniKeyList`, so every key claimed
list 0. Neither produced an error — only implausible data.

**Note on the creature rest-pose displacement (~650 units): animation does NOT explain
it.** Position keys exist but are of order 0.01–2.1. This remains open.

**Multi-room.** The room-change trigger fires on the scene root's **last** child XOR the
music cue at `0x152AD0`. The first child is the movement frame, created at init and
identical in every room — using it fired the capture exactly once across five rooms, a
mistake that cost a play-through and was visible in the scene dump already on disk.

Revisits are captured deliberately (the engine genuinely rebuilds the scene with new
handles), so `Export-Rooms.ps1` groups captures by a fingerprint of **static geometry
names only**, excluding `ZZnnnn*` creature bones, `XAFQn` creature roots and `dummy`.
Fingerprinting on everything gave 11 groups for 7 real rooms; the static-only
fingerprint gives exactly 7.

Two texture-completeness bugs were found by the user playing, not by inspection: a
32-entry per-room dedup cap (room 4 needed 53; room 7 got *exactly* 32, the tell) and
`AztTexEmit` reading only `face[0]`. Fixed with 256 slots and a per-face loop; re-capture
resolved every material. A session-wide FNV-1a hash of the filename now suppresses
repeat pixel payloads across rooms, so a long session stays affordable.

**Winding order** was confirmed analytically rather than visually: the cross product of
the captured corner order agrees with the captured face normal for **1165 of 1165**
faces, mean dot **1.000**. No flip is needed on export.

## 14f. VISUAL PROOF — the extracted scene reproduces the original view

Pose **f2169** (position `(-75.0, -68.6, 23.1)`, yaw 82°, pitch 0°), taken from the
engine's own camera matrix, was rendered in Blender and laid beside the DOSBox capture of
that same frame. Same corridor, same door at the far end, same steps, same boulder in the
foreground right, same pillar spacing.

Three things are confirmed jointly by that match, none of which could be checked in
isolation:
* the reading of `field = 0.8` as a **horizontal half-angle** (22.5 mm on a 36 mm sensor),
* the coordinate conversion — Reality Lab is row-vector/row-major, and a Blender camera's
  columns are `(right, up, -forward)` under `(x,y,z) -> (x,-z,y)`,
* that geometry, UVs, textures and winding together reproduce the original image.

The render is deliberately **unlit**: the game does no lighting at all (every vertex
colour is white, its Materials are empty), so shading is emission-only. Adding lights
would make the comparison worse.

Measured mean luminance over the 1024×576 viewport: game **18.69**, extracted **21.02**
— the extraction is **12.5% brighter**, not darker as it appears by eye. The residual is
consistent with ramp-mode dithering plus the capture's 2× rescale and is not currently
explained further.

**Texture upscaling.** The 28 room-1 textures were taken 256→1024 with **Scale2x/EPX**
(`tools\Upscale.cs`), applied twice. Scale2x was chosen over any smooth filter because
every output pixel is a *copy of an input pixel* — nothing is invented, and the tiling
these textures depend on survives. Mean luminance across the whole frame changed by
**0.2%** (21.02 → 20.98), which is the useful number: the upscale altered local detail
without shifting the art's tone. The visual gain comes from being able to then sample
with bilinear filtering instead of nearest-neighbour.

An AI upscale would likely look better still on stone and cloth, and `src\Texture-Tool.ps1
-Import` already exists to put new art back into the *original game* (power-of-two, ≤512,
`-Keyed` for `#` textures). That is an art-sourcing decision, not a technical blocker.

**Tooling note:** Blender 5.2 is installed on this machine and runs headless
(`blender -b -P script.py`), so these renders are produced directly rather than handed
over as a script.

---

## 14g. THE BRIDGE — host reads live guest state with NO emulator fork. CONFIRMED.

§9 assumed the host half of the mailbox needed a DOSBox fork. **It does not.** DOSBox
keeps emulated RAM as an ordinary committed allocation in an ordinary Windows process,
and guest linear addresses are identity-mapped onto it, so `ReadProcessMemory` reaches
the game's state directly.

**Method — why string needles.** A guest linear address is not a fixed offset into the
emulated RAM array in general, because DOS/4GW runs with its own page tables. Long
strings from `R.EXE` sidestep that: the LE loader **never relocates text**, so a string's
file offset converts to the address the game runs it at, and `host − runtime` is the
emulated-RAM base. Several needles are used deliberately — one needle always looks
self-consistent because nothing checks it.

**The conversion is per object, and the two differ by one page:**

| object | image linear | file | runtime delta |
|---|---|---|---|
| obj1 | `0x10000` | `0x61A54`+ | `+0x1F0000` |
| obj2 | `0x140000` | `0x61A54 + 291*4096` = `0x184A54`+ | `+0x1F1000` |

Using obj1's delta for an obj2 address shifts everything by 0x1000 and still *looks*
plausible. The confirming run used **four needles spanning both objects** — obj1 runtime
`0x22ED49` and obj2 runtime `0x3353E9`, about 1 MB apart — and all four produced the same
base, which is what establishes contiguity across the image rather than locally.

```
host = runtimeLinear + MemBase        MemBase = guestRamBase + 0x60
```

The 32 MB RAM region is subject to **ASLR** — it was `0x1C271850000` in one run and
`0x20F6EC78000` in the next — so the base is derived every time and never stored.

**Result 1 — the overlay, live.** Reading guest image-linear `0x133000` returned
AztMod's own overlay: `'AZTO'`, then `E9 05 00 00 00` / `E9 10 00 00 00`, the init and
per-frame vectors at +4 and +9, followed by real code. 200 of the first 256 bytes
non-zero.

**Result 2 — the player's pose, live.** `aztCamRec` is located by its own magic `'CAM1'`
in the shipped `AZTCODE.BIN` rather than by rebuilding, because a rebuild could produce
an overlay that differs from the one the **running** game loaded and would silently move
every offset. 50 samples at 500 ms while walking gave **39 distinct positions and 24
distinct yaw values over a −180°..+74° range**, with Y rising and falling across the
room's steps and two clean yaw reversals where the player turned. The frame counter
advances ~23 fps, matching §11's measured 22–24.

The raw record also confirms the structure: `camWorld` and `movWorld` are both proper
orthonormal matrices co-posed to ~0.01 units, `camLocal` is identity and `movLocal`
equals `movWorld` — so the camera is parented to the movement frame with no local
offset. (An earlier session saw `camWorld` stuck at identity; it is **not** in this
build, and that symptom should not be carried forward.)

**What this does and does not establish.**

* **Established:** out-of-band, read-only access to arbitrary guest memory from host
  code, with no emulator changes, no per-frame disk I/O, and no waiting for the game to
  exit. This supersedes the file-logging transport for every observation task.
* **Not established:** writing to guest memory; frame synchronisation (the reader polls,
  it is not driven by the game's frame); and any latency guarantee. A host renderer that
  must not tear would still need a sync mechanism, which is where an emulator change may
  yet be justified — but for *observation*, option D in §13 is now strictly better than
  its "can't render in-place" verdict implies.

**Tools:** `tools\ProcMem.cs` (VirtualQueryEx/ReadProcessMemory, chunked scan with
overlap), `tools\GuestBase.ps1` (`Get-AztGuestBase`, `Read-AztGuest`,
`ConvertTo-AztRuntime`), `tools\Map-GuestMemory.ps1` (diagnostic), and
`tools\Read-LiveCamera.ps1`.

One practical trap: **DOSBox holds `R.EXE` open exclusively** while the game runs, so
`File.ReadAllBytes` on it fails with a sharing violation at exactly the moment the tool
is useful. Open it with `FileShare.ReadWrite`.

---

## 14h. THE SEAM ITSELF — the scene graph read live from the host. CONFIRMED.

§10 names "scene graph → renderer" the best-leverage seam and §13 puts object transforms
as the step after camera extraction. Both are now done, and **with no guest code running
at all** — the frame tree is ordinary linked structures in emulated RAM, so the host
chases the pointers itself.

Starting point is `aztCamObj` (camera record +16), a genuine runtime pointer rather than
an engine handle — handles would need `0x39E50` to resolve, which means calling into the
guest. Climbing `+0x30` to the root sidesteps that entirely; the camera sits **4 levels**
below the root.

One walk of room 1 returned **133 frames, 126 named, 124 carrying visuals**, in tree
order with world transforms:

```
(unnamed)  root 0x11FEF58
  (unnamed)
    (unnamed)              173.76  -70.92  100.83
      dummy                173.75  -70.91  100.83   vis 1     <- the player's own body
    zxcoriR2              -365.75  -84.67 -375.84   vis 1
    wall2                  584.02    9.74  116.90   vis 1
    ...
    XAFQ1                  315.45  -99.27  143.27   vis 0     <- creature root
      ZZ0001EUBUM          307.39  -96.78  138.12   vis 1
```

**Cross-validation against the on-disk `.XAF`.** The live names are the same names the
text file uses, so the two can be compared directly: **63 of 64 `CORICORI.XAF` objects
matched by name, all 63 within 0.01 units, worst distance 0.0000**. Two entirely
independent pipelines — an offline text parse and a live pointer-walk of emulated RAM —
agree to floating-point exactness. Each validates the other, and neither could have been
trusted alone.

That exactness carries a design consequence: for this room the engine loads the `.XAF`
matrices **verbatim and does not modify them at runtime**. Static world transforms can
therefore be taken offline; only dynamic objects need live reading.

The 63 live frames with no `.XAF` counterpart are exactly the ones that should have none
— `dummy` (the player's body) and the two creature rigs (`XAFQ1`/`XAFQ2` with their
`ZZ0001*`/`ZZ0002*` bones), which come from their own files.

**Why this beats the in-guest scene logger it parallels:** no overlay code, no file
writing, no dependence on the room-change trigger, and it can be sampled at any instant
rather than only when the engine happens to rebuild a room.

**Caveats, stated rather than buried.**
* The root frame's `+0x268` read as 2,121,891,201 — not a visual count. The root is
  probably not a plain `Frame`; it is range-checked out of the totals rather than
  trusted.
* The graph is read **while the game mutates it**, so a torn read is possible. That is
  an inherent limit of polling, not something the reader can fix, and it is the same
  gap as the frame-sync item left open in §14g.

**Tool:** `tools\Read-LiveScene.ps1` (`-WaitForRoom`, `-WithVisualsOnly`, `-Json`).
Every pointer is range-checked before dereference and the node count is capped, so a
corrupt or mid-update pointer ends the walk instead of hanging it.

---

## 14i. UNKNOWN 6 — the room graph was never hidden either. CONFIRMED.

Rated **High cost** on the assumption it needed reverse engineering. It did not:
`AZONES.DAT` is a flat array on disk.

**Format.** `uint16 count`, then `count` records of 75 bytes: zone name at +0 (60 bytes,
NUL-terminated), object name at +60 (12 bytes), 3 trailing bytes. 23,927 bytes =
2 + 319×75 exactly, and the header word is `0x013F` = 319 — two independent counts
agreeing, rather than a hex dump eyeballed into shape.

**The file is full of garbage and that is normal.** It was written from an uncleared
buffer, so bytes after each NUL are `0xCC` debug fill or stale heap — at points it
contains fragments of unrelated strings and even code. Read to the NUL; ignore the rest.

**What the records mean.** The object name is a `zx*`/`zy*` object that also appears in
the room's `.XAF` **and in the live scene graph** — these are trigger volumes, placed in
the world like any other object. The zone name says what entering one does:

| kind | count | example |
|---|---|---|
| portal `<A>To<B>` | **166** | `MineHeadToWellRoom` → `zxmineh2R7` |
| scripted event | 127 | `R5WaterDeathAZ`, `R6CarAZ`, `R29GibbetAZ`, `R2FalseFloor` |
| lift / ladder | 21 | `R22aLift1` → `zxladdlifa` |
| entry coordinate | 5 | `EntryCoordWashRoom` → `zxcoriR2` |

**The room graph: 87 rooms, 166 directed connections**, 28 with no return edge. Two of
those 28 are not one-way at all but a **typo in the shipped data** — `Baptistery→Orrey`
against `Orrery→Baptistery`.

**Room → file mapping.** Cross-referencing the 264 distinct trigger objects against the
`.XAF` corpus locates **248** of them. This also explains the 178-files-for-87-rooms
discrepancy: many trigger objects appear in several files, so **the corpus ships
duplicate and dev versions of rooms** (`WELLDEMO`/`WELLROOM`/`R7`,
`MINEHEAD`/`MINEHED2`/`HINEAZF`, `SPAROOM`/`SPAROOM3`/`SPAROOMX`/`OLDSPA`). Anyone
extracting assets wholesale needs this or they will extract the same room repeatedly and
sometimes the wrong revision. `zxentry`/`zxcoriR2` → `CORICORI, R1`, independently
confirming room 1.

**Still open:** this gives the room graph and the trigger system. It does **not** give
*visibility* — there is no evidence yet of portal culling or a PVS, and the engine may
simply draw the whole room. That half of unknown 6 is untouched.

**Tool:** `tools\Read-Zones.ps1` (`-Graph`, `-MapFiles`, `-Csv`).

## 14j. UNKNOWN 8 — the composited frame is host-readable AND host-writable. PARTIAL.

The question was whether the original renderer can be suppressed while keeping the UI.
The transport half is now answered; the suppression half is not.

**The framebuffer is not in guest RAM.** Diffing all 8,193 pages of the 32 MB guest RAM
between frames found no framebuffer-sized contiguous run (1024×576 would be 144 pages;
the largest was 30). That is consistent with the LFB change — the game writes to the
linear framebuffer, which is DOSBox's *video* allocation.

**Found by observation, not by reverse engineering the video code.** Diffing every
committed region >512 KB located a 64 MB allocation with a 162-page contiguous changed
run. Dumping it as an image shows the live screen: the 3D viewport, the cursor and scan
readout, and the HUD panel with fully legible text — *including AztMod's own story log*.
So **the 3D and the HUD are composited into one surface that host code can read.**

Stride is **2048**, and the surface is 32-bit, not the guest's 8bpp: readback shows
repeating 4-byte groups (`24 39 31 00 24 39 31 00`), i.e. BGRA with 2× horizontal
scaling. This is DOSBox's scaled output surface, which matters — writing to it is not
the same as writing to the guest's own framebuffer.

**Writable: yes.** `WriteProcessMemory` returns true and the bytes read back immediately.
An earlier attempt appeared to fail only because DOSBox regenerates the surface every
frame and a 140-row write loop took ~20 ms — far longer than one frame. So host
compositing is possible but must **win a race against the game's own redraw**, which is
the frame-sync problem again.

## 14j-b. SUPPRESSING THE 3D PASS — YES, and the HUD survives. CONFIRMED.

Tested live through the bridge with no file modified and no rebuild.

**Locating the 3D block.** Several plausible-looking candidates were wrong first:
`0x33F80` is the *generic* 2D surface blit (65 callers, used by everything), `0x3544D` is
the cursor redraw, and `0x28157` allocates the Z-buffer but runs at room init rather than
per frame. What pinned it was AztMod's own `view-zbuf-28168` patch → the device/viewport
creation at `0x10FEC` → the viewport global **`0x152138`** → its three consecutive uses in
the frame path:

```
00014158  cmp word [0x15257C], 0
00014160  75 2A        jnz 0x1418C      <-- guards the 3D block
00014162  mov eax,[0x152138]            ; viewport
00014182  call 0x3F0D0                  ; render
00014187  call 0x3F1B0
0001418C  ... HUD work continues
```

**Attempt 1 — set the engine's own flag. NEGATIVE, and instructively so.** Writing
`0x1525F2 = 1` stops the **entire** screen redraw, HUD included. The flag has 13
references across the codebase, so setting it globally disables far more than one block.

This is where a *watching* test misleads. Under the flag the HUD still looked perfectly
legible in a framebuffer dump, which reads as "the HUD is still being drawn" — it was not.
It was **stale**, left from the last frame because nothing overwrote it. Frame-to-frame
change cannot tell those apart, because the panel is nearly static anyway (0.32% at
baseline, 0.00% suppressed).

**The test that can tell them apart: don't watch, intervene.** Blank a rectangle in the
viewport *and* one in the HUD, then see which the game paints back. The two rectangles
act as each other's control in the same frame, and a repaint is positive evidence rather
than an absence of change.

| | viewport | HUD panel | game loop |
|---|---|---|---|
| baseline | blanked → **44.5% repainted** | blanked → **69.8% repainted** | 36 frames |
| flag `0x1525F2 = 1` | blanked → **0.00%, stays blank** | blanked → **0.00%, stays blank** | 35 frames |

The frame counter kept advancing in both, so the engine was alive and simply not drawing.

**Attempt 2 — patch the one branch. CONFIRMED.** Forcing only the guard taken
(`0x14160`, `75` → `EB`, one byte, restored afterwards) skips `0x14162..0x14187` and
leaves every other path that consults those flags alone:

| | measurement |
|---|---|
| viewport frame-to-frame change, baseline | 1.62%, 1.61% |
| viewport frame-to-frame change, patched | 0.33%, **0.00%** — frozen |
| viewport after restore | 0.39% — moving again |
| HUD rectangle while patched | blanked → **70.44% repainted** |

**So the 3D pass can be suppressed while the HUD keeps drawing.** That is unknown 8's
central question, answered.

**A correction to §14j above:** the claim that the framebuffer is "not in guest RAM" was
based on too weak a test — page-diffing an *idle* scene, where little changes. The
engine's offscreen 3D colour surface **is** in guest RAM: descriptor at `[0x14745C]`,
**1024×576, 8bpp, bytesPerLine 1024, pixels at `0x012AC288`**, with the Z surface at
`[0x147460]`. For widths above 0x114 the colour pixels come from `[0x163A34]` rather than
the shared block at `[0x147466]`.

**What did NOT work: host-drawn pixels into that buffer.** Writing into the colour surface
does not reach the screen, because the buffer is reverted within ~107 ms. Chasing that
produced a **correction to the claim above** and a set of eliminations.

### CORRECTION: the branch patch suppresses the 3D *output*, not the renderer

The patch's measured effects — viewport frame-to-frame change 1.62% → 0.00%, HUD still
repainting at 70.44% — are reproducible and stand. But "the 3D render is suppressed" does
**not** follow from them, and the evidence now says it is false: the scene is still being
rendered into the colour buffer by a path outside the patched block. What the patch stops
is the result reaching the screen.

### What rewrites the buffer — eliminations, and what it is not

| test | result |
|---|---|
| Host writes to overlay BSS / scene-graph memory / far heap `0x1500000` | **persist 1.5 s** |
| Host write to the colour buffer `0x12AC288` | **reverted by ~107 ms** |
| Write size 16 B → 589,824 B | **identical behaviour**, so not a size or paging artifact |
| Descriptor pixel pointer over 20 samples | **single value** — not double-buffered |
| Buffer left untouched, 3D patched out | **0 bytes change** over 300 ms |

So the write path is sound and the effect is specific to this one buffer.

Eliminated as the writer, each by NOPing it and re-measuring: `0x2D100` (it is inventory
logic, "Holding : %s", not a clear), **both** `0x3F010` fills at `0x1434B`/`0x14381`
(`0x3F010` *is* a memset-with-colour — it broadcasts a byte to a dword then calls
`0x5AB80` — but removing both changed nothing), `0x1F222`, and `0x1E61C`/`0x1E62C`/
`0x1E63C`. It is also **not gated by either flag** that stops all screen drawing: with
`0x1525F2` or `0x15257C` set, the sentinel is still wiped.

**And it is not a clear or a copy-back.** After a wipe the content is **91.4% identical**
to what preceded it, not 100%, with non-zero coverage moving 10.0% → 18.6%. An exact
restore would mean a copy from another buffer; near-identical-but-drifting means the scene
is being **re-rendered**, the small differences being animation.

### The RL object model, recovered while hunting it

`AddMoveCallback` (`0x44DD0`) resolves a Frame handle and grows a list at **frame+0x280
(count) / +0x284 (array of 8-byte {callback, context})**, registered from `0x1E067`,
`0x1E0F2`, `0x1E49F`, `0x22CE0`. Move callbacks move frames; they do not render, so this
was a dead end for the buffer — but the class descriptor it uses identified the rest:

| descriptor | class | size |
|---|---|---|
| `0x147EDC` | **Frame** | 736 |
| `0x148370` | **Viewport** | 592 |

Thirteen functions resolve handles against the Viewport descriptor, i.e. the Viewport
method set: `0x3A630` (create), `0x3A840` (SetBack), `0x3A8A0` (SetField), `0x3ACB0`,
`0x3ACE0`, `0x3C1A4`, `0x3F0D0`, `0x3F6D0`, `0x58D00`, `0x58D9C`, `0x59C40`, `0x5B950`,
`0x5BD0C`.

**`0x3F1B0` is the render-all**, and `FuncOf` hides that: its body continues past an
*early-exit* `ret` at `0x3F220` to `0x3F2DE`, where it loops devices → viewports doing
`call 0x42410` (scene root) then `call 0x5BD0C(viewport, root)` — Viewport::Render. It has
**eleven call sites**, of which `0x14187` is the one the branch patch removes. That is why
suppressing the branch freezes the screen but not the rendering.

### Still NOT the writer — four more eliminations

Each stubbed live (entry byte → `0xC3`) and re-measured; the sentinel stayed 0/16 in every
case:

* `0x3F1B0` — the render-all itself, killing all eleven call sites at once
* `0x5BD0C` — Viewport::Render
* `0x5B950`, `0x3F6D0` — the other two per-viewport calls

So the buffer is rewritten **even with the entire Reality Lab render path stubbed out**,
and (from earlier) even with both flags that stop all screen drawing. Whatever writes it
is not the renderer and not in the draw path.

### RESOLVED — it is a shared surface pool, not a framebuffer

The call-graph hunt failed four times because the premise was wrong. `0x163A34` is not a
dedicated 3D framebuffer pointer. **One allocation is stored into four global aliases:**

```
00010E2C  mov eax, 0x26010      ; size in bytes (AztMod patches this -- see below)
00010E3B  call 0x32CE0          ; add eax,0x11 / shr eax,4 -> paragraphs, then allocate
00010E40  mov [0x152154], eax
00010E45  mov [0x1521BC], eax
00010E4A  mov [0x162E2C], eax
00010E4F  mov [0x163A34], eax
```

`0x28157` points the 3D colour surface at `[0x163A34]` **only when width > 0x114**; below
that it uses `[0x147466] + w*h*2`. So at hi-res the 3D renders into the shared pool.

**How shared:** `0x152154` alone has **54 references across 19 functions** — the UI, the
map, the book viewer, the scan readout — including eight sites inside the per-frame draw
path at `0x1428D`, `0x142B4`, `0x14252`, `0x1437C`. The `.XAF` parser takes it too
(`0x29B60`: `mov eax,[0x163A34]` → `mov [0x163BAC], eax`).

**AztMod already treats it as the viewport buffer**, which independently confirms the
reading: six `view-bytes-*` patches rewrite the byte count from the stock **155,664** to
**589,824 = 1024×576** — at the allocation (`0x10E2D`) and at five consumers
(`0x1425A`, `0x167CB`, `0x16866`, `0x169FD`, `0x17845`).

**So nothing was "rewriting the framebuffer".** A host write lands in a buffer that the 2D
and UI paths rewrite every frame, entirely independently of the 3D renderer — which is
exactly why stubbing `0x3F1B0`, `0x5BD0C`, `0x5B950`, `0x3F6D0` and both flags all changed
nothing.

**Consequence for a host-composited viewport.** Writing the surface from outside cannot
work, because the guest rewrites it every frame from several code paths. Host pixels have
to be injected **from inside the guest** — see §14l, where that was built and confirmed.

---

## 14l. HOST PIXELS IN THE RUNNING GAME — option 1 works. CONFIRMED, ON SCREEN.

`AztViewInject`, an overlay routine hooked into the frame, copies a rectangle from a
staging buffer in the overlay's BSS into the shared viewport surface. The host fills the
staging buffer through the bridge; the guest does the copy.

```
host writes staging buffer (overlay BSS)  ->  AztViewInject copies it mid-frame  ->  engine blits it
```

**Verified visually in the game window**, not merely in memory.

### The probe build, and why it was worth one

Picking a hook site from the disassembly failed: the first build hooked `0x1434B`, which
**never executes** — `[0x152AE6]` is 0 in normal play, so `0x141FB` jumps to `0x14386` and
that whole block is a different view mode. After five earlier wrong guesses about this
frame path, the second build stopped guessing and measured: four candidate sites, each
with its own counter *and* its own band, so one run answers both questions.

| probe | site | calls/sec | band survives? |
|---|---|---|---|
| 0 | `0x1419D` just after the 3D block | **22** | **100% — YES** |
| 1 | `0x141D2` after the 3D block | **22** | **100% — YES** |
| 2 | `0x143B4` HUD text | 0 — never runs | — |
| 3 | `0x143ED` HUD text, later | 0 — never runs | — |

22 calls/sec is exactly the frame rate. The two HUD-text sites never fire at all (they run
only when there is text), which is precisely the failure mode the counters exist to catch:
without them, a dead site and a broken copy loop look identical.

Survival was checked by reading the engine's **own descriptor pixel pointer**
(`[0x14745C]+0x1C`), not an address chosen by hand.

### The bug that broke the game, recorded because it will recur

The first stub did `call <displaced target>` and then `ret`. That puts **our return address
on top of the caller's stack arguments** — `0x38EC8` reads its argument at `[esp+0x38]`, so
every stack argument shifted by four bytes and the game hung on the intro movie.

It shipped latent in the first build *because* `0x1434B` never fired, and only appeared
once sites that actually execute were hooked.

**A displaced call must be re-issued as a TAIL CALL:**

```
AztInjProbeN:
    pushfd / pushad        ; pushad does NOT save EFLAGS
    ... work ...
    popad / popfd
    jmp <displaced target> ; its own ret returns to the game, stack untouched
```

Also learned the hard way: **do not hook the generic LFB blitters** (`0x34328` → `0x50EA5`,
`0x3534C` → `0x513BF`). They serve the intro movie as well as the frame loop, so a probe
there runs on paths unrelated to rendering the world.

Isolating this took one step: rebuilding with `$ENABLE_VIEW_INJECT = $false` confirmed the
baseline was clean, which separated "my hooks" from "something else" immediately.

### FULL FRAME — done, and it costs 1.5%

Scaled from the 256×16 strip to the whole 1024×576 viewport:

| | |
|---|---|
| staging buffer | **589,824 bytes**, allocated from the game's own heap at overlay init (`0x32CE0`) — landed at guest `0x165A038` |
| frame rate, injection OFF | **22.3 fps** |
| frame rate, injection ON | **22.0 fps** |
| **cost of a full-frame copy** | **1.5%** |
| viewport surface, row 300 | **1008/1024 bytes match the host frame (98.4%)** |

The copy is a single flat `rep movsd` of 147,456 dwords — no row loop, because the surface
stride (1024) equals the frame width.

**1.5% was the number that decided this.** A full-frame memcpy inside an emulated 486 was
the one cost that could have made option 1 impractical; it is nearly free, which is
consistent with §11's finding that the rasteriser dominates and memory traffic does not.

**The 98.4% is not a defect and should not be "fixed".** The missing 16 bytes are the
game's own UI drawing *after* the injection point — which is exactly the property the
hybrid depends on: the host owns the world, the engine still draws its HUD and cursor on
top.

**The 576 KB comes out of the texture cache**, which is the known cause of the big-room
out-of-memory crash. If large rooms start failing to load, this allocation is the first
suspect.

### THE PALETTE — captured, 255 distinct colours

The viewport is 8-bit indexed, so host frames must be expressed in the game's own palette,
which is merged at runtime from several PCX files and is not a file we can read. So it was
**measured**: paint known indices through the injection path and read the resulting colours
out of DOSBox's display surface.

Self-checked before being written: index 100 = `#147149` and index 200 = `#41552D`, with the
band chart agreeing exactly with a direct single-colour fill. **255 distinct colours across
256 indices.** The result contains the magenta chroma key and a yellow→red ramp, which is
independent corroboration that it is the real live palette.

**Display geometry, derived rather than assumed:** a 256-band chart gave a band spacing of
8192 bytes for 2 game rows, so DOSBox's surface is **1024 px wide, 32-bit, 4096 bytes per
row, 1:1 with the game** — *not* the 2×-scaled 2048-stride surface an earlier section
assumed.

**The mistake worth recording:** the first three attempts used index 0 and index 255 as
probes and markers. Both are black in this palette, so "fill 0 then fill 255" changed
nothing (longest changing run: 3 bytes) and a 255 marker was invisible to a non-zero
search — which sent the marker hunt onto unrelated game content and produced a confident
but wrong 17-colour result. `Capture-Palette.ps1` now **verifies its probe pair differs**
(trying 100/200, 64/192, 40/160, 20/220 and requiring >200,000 changed bytes) and refuses
to write a palette unless the chart agrees with the direct measurement.

### 14m. THE WHOLE LOOP, JOINED UP. CONFIRMED.

`tools\Show-LiveRender.ps1` runs the complete hybrid in one command:

```
read the player's live camera matrix out of the running game
  -> Blender renders room 1 from that exact matrix, headless
  -> quantise to the game's own captured palette
  -> inject into the viewport
```

Measured at camera `(-69.3, -68.6, 18.9)`, 9.2 s end to end, **and the result lines up with
where the player is actually standing** — verified on screen. The camera comes from the
engine rather than being hand-placed, which is what makes this "the host is drawing this
game" rather than "a picture in the viewport".

**Option 1 is complete.** Every stage — assets, world state, live camera, per-object
transforms, suppression, injection, full frame, palette — is working and verified.

**The 8-bit ceiling still applies** (§ the assessment above): the surface is 256-colour, so
host frames must be quantised to the game's live palette. That is what pushes a
visually-ambitious remaster toward option 2, and it is unchanged by this result.

**Tools:** `tools\Test-InjectProbes.ps1` (discovers the counter and flag addresses from
`AZTCODE.BIN` rather than hard-coding them, so a rebuild cannot leave it reading stale
symbols).

**Method note:** "the buffer looked stable when untouched" was misleading in the same way
the stale HUD was. A static scene is re-rendered to *identical* bytes every frame, so
watching it shows nothing. Only writing to it and seeing the write reverted revealed a
writer was there at all.

**Tools:** `tools\Test-Suppress3D.ps1`, `tools\Test-Suppress3D-Redraw.ps1`
(`-Mode Flag|Jump`).

## 14k. STAGE 7 — a host-rendered replacement model at an engine transform. DONE.

The first picture of the hybrid working: the original game remains the authority on where
things are, the host supplies the presentation.

**Subject:** the object the engine calls `save` — which turns out to be **the boulder** in
room 1. 72 triangles, 104 units from the camera at pose f2169, the closest object with
real geometry in that view.

**The transform is the point, so it was used honestly.** The OBJ export bakes world
coordinates, so subdividing in place would prove nothing. Instead the mesh was taken back
to local space by subtracting the engine's own translation — read live out of the running
game — and the enhanced mesh was then placed using that same engine matrix. If the matrix
were wrong the replacement would land in the wrong place.

> **Placement error: 0.000006 units.**

Getting there required correcting a real mistake, worth recording because it will recur:
**Blender's OBJ importer does not bake its Y-up → Z-up conversion into the vertices.** It
leaves that conversion in the object's `matrix_world` (which is exactly `G2B`), so the
mesh data is still in **game** coordinates. Subtracting the Blender-space translation
from game-space vertices put the replacement **140.2 units** away — precisely the
distance between the two forms of that vector, which is what identified the bug.

**The replacement invents no art**: the engine's own silhouette with Bevel + Subdivision
Surface + smooth shading, 72 → ~4,600 triangles. A hand-modelled asset would look better
but would prove nothing about the pipeline. The close-up is its own control — the left
boulder is the replacement, the right boulder is untouched engine geometry in the same
frame: same position, same texture, same camera, hard facet ridges against a smooth
surface.

**Tool:** `azrael-stage7-replacement.py`, output in `C:\Games\azrael-stage7`.

---

## 15. Staged roadmap

| Stage | Goal | Gate |
|---|---|---|
| ~~1~~ | ~~Camera transform logged live and verified against movement~~ — **DONE, see §14a** | §14 ✔ |
| ~~2~~ | ~~Locate the scene graph root; enumerate frames~~ — **DONE, see §14b** (meshes still open) | §14b ✔ |
| 3 | Publish object ids + transforms per frame to the mailbox | stage 1 working |
| 4 | Read the mailbox from a forked DOSBox Staging; print live | first emulator work |
| 5 | Native GPU test scene following the Azrael camera | Milestone 5 |
| 6 | Decode one mesh from the live scene graph; export OBJ | Milestone 6 |
| 7 | Host-render one replacement model at an original transform | Strategy B |
| 8 | Room geometry; host-rendered room compared against the DOS view | Milestone 8 |
| 9 | Suppress original viewport, keep HUD | only if 8 matches |

Stages 1–3 need no emulator changes. Stage 4 is the first genuine fork.

---

## Appendix — reproducing the analysis

**Ghidra project** (addresses match the running game; fixups applied):

```
C:\Tools\azt\proj              project "Azrael"
C:\Tools\azt\obj1.bin          1,190,259 bytes @ 0x10000   (code)
C:\Tools\azt\obj2.bin            359,888 bytes @ 0x140000  (data + BSS)
C:\Tools\azt\scripts\          DecompileOne.java, DecompileMany.java, AddObj2.java
```

Decompile any function by linear address:

```
set JAVA_HOME=C:\Tools\jdk-21.0.12.1+1
C:\Tools\ghidra_12.1.4_PUBLIC\support\analyzeHeadless.bat C:\Tools\azt\proj Azrael ^
  -process obj1.bin -noanalysis -scriptPath C:\Tools\azt\scripts ^
  -postScript DecompileMany.java 10FEC 3EC20 3C690
```

**Regenerating the images** (must be dumped from the loader, never the raw file):

```powershell
Add-Type -Path AztMod\tools\LeTool.cs
$img = New-Object LeTool.LeImage "<path>\GAME\AZRAEL\R.EXE"
[IO.File]::WriteAllBytes('C:\Tools\azt\obj1.bin', $img.ObjData[1])
[IO.File]::WriteAllBytes('C:\Tools\azt\obj2.bin', $img.ObjData[2])
```

**File inventory:** 593 files, 518.7 MB, dominated by `AZT.BIN` (487.4 MB),
270 `.WAV` (15.7 MB), 52 `.DAT` (3.0 MB), 125 `.PCX` (1.2 MB), 24 `.XMI` (0.3 MB).

