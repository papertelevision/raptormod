---
name: azrael-host-guest-bridge
description: "Host code reads the running game's memory with ReadProcessMemory and NO DOSBox fork; how to find the base, and the traps."
metadata:
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-27T14:17:42.589Z
---

**Unknown 7's read path is SOLVED, and it needed no emulator fork.** Do not re-derive
this, and do not plan a DOSBox fork for *observation* tasks.

DOSBox keeps emulated RAM as an ordinary committed allocation in an ordinary Windows
process (32 MB here), and guest linear is identity-mapped onto it. `ReadProcessMemory`
reaches the game's live state directly.

```
host = runtimeLinear + MemBase        MemBase = guestRamBase + 0x60
```

## Finding the base: string needles

A guest linear address is not generally a fixed offset into the RAM array (DOS/4GW has
its own page tables). Long strings from `R.EXE` sidestep that because **the LE loader
never relocates text**. Convert a string's file offset to its runtime address, subtract
from where it was found, and that is MemBase. Use SEVERAL needles: one always looks
self-consistent.

**The file->runtime conversion is PER OBJECT and they differ by one page:**

| object | image linear | file base | runtime delta |
|---|---|---|---|
| obj1 | 0x10000 | 0x61A54 | +0x1F0000 |
| obj2 | 0x140000 | 0x61A54 + 291*4096 = **0x184A54** | +0x1F1000 |

Using obj1's delta on an obj2 address shifts everything by 0x1000 and still looks
plausible. Confirm with needles in **both** objects.

**The RAM region is subject to ASLR** — observed at 0x1C271850000 and 0x20F6EC78000 in
consecutive runs. Derive it every time; never store it.

## Traps that cost time

- **DOSBox holds `R.EXE` open exclusively** while the game runs, so `File.ReadAllBytes`
  on it throws a sharing violation at exactly the moment the tool is useful. Open with
  `FileShare.ReadWrite`.
- **Do not rebuild to get overlay label addresses.** The manifest carries only 8 symbols,
  not the overlay label map, and a rebuild can produce an `AZTCODE.BIN` that differs from
  the one the RUNNING game loaded — every offset then silently moves. Instead locate
  records by their own magic in the shipped blob: `aztCamRec` is the dword `'CAM1'`, and
  the overlay starts with `'AZTO'` then `E9 05 00 00 00` / `E9 10 00 00 00` (init at +4,
  per-frame at +9).
- **A low-entropy signature is worthless.** An early probe "found" the overlay 8 times
  using a 256-byte run of zeros. Reject signatures with few distinct byte values.
- The game only lives as long as the window is open; scans fail with `OpenProcess`
  error 87 when it exits mid-scan. Poll for the process rather than sleeping a fixed time.

## Tools

`tools\ProcMem.cs`, `tools\GuestBase.ps1` (`Get-AztGuestBase`, `Read-AztGuest`,
`ConvertTo-AztRuntime`), `tools\Map-GuestMemory.ps1` (diagnostic),
`tools\Read-LiveCamera.ps1`.

## The scene graph walks from the host too

`tools\Read-LiveScene.ps1` walks the whole frame tree with **no guest code**. Start from
`aztCamObj` (camera record +16) — a real runtime pointer, not a handle, so no call to
`0x39E50` is needed — and climb `+0x30` to the root (the camera is 4 levels down).

Frame fields: `+0x24` char* name, `+0x30` parent, `+0x34` sibling, `+0x3C` first child,
`+0x4C` local 4x4, `+0x90` world 4x4, `+0x268` visual count, `+0x270` Visual*[]; Frame is
736 (0x2E0) bytes. Room 1 gives **133 frames, 126 named, 124 with visuals**.

**The root is NOT a plain Frame** — its `+0x268` reads as garbage. Range-check it.

**Cross-validated against the on-disk `.XAF`: 63 of 64 objects matched by name, all
within 0.01, worst distance 0.0000.** So the engine loads `.XAF` matrices verbatim and
does not modify static transforms at runtime — static geometry can be taken offline, and
only dynamic objects need live reads. See [[azrael-xaf-scene-format]].

## Suppressing the 3D pass (unknown 8) — YES

The 3D block is guarded by one branch:

```
00014158  cmp word [0x15257C], 0
00014160  75 2A     jnz 0x1418C     <-- patch 75 -> EB to skip ONLY the 3D
00014162  mov eax,[0x152138]        ; viewport global
00014182  call 0x3F0D0              ; render
0001418C  ... HUD work continues
```

One byte at `0x14160` (obj1, so runtime +0x1F0000) freezes the viewport (frame-to-frame
change 1.62% → **0.00%**) while the HUD still repaints (**70.44%**).

**Do NOT use the engine's flag `0x1525F2` instead** — it has 13 references and setting it
stops the ENTIRE screen redraw, HUD included.

**The trap that nearly produced a false positive:** under the flag the HUD still *looked*
perfectly drawn in a framebuffer dump. It was **stale**, not redrawn. Frame-to-frame
change cannot detect this because the panel is near-static anyway (0.32% baseline).
**Blank a rectangle and see if the game paints it back** — a repaint is positive
evidence; an absence of change proves nothing.

## The engine's offscreen 3D surface

Descriptor `[0x14745C]` (obj2): **1024x576, 8bpp, bytesPerLine 1024, pixels at
`0x012AC288`**. Z surface at `[0x147460]`. For widths > 0x114 the colour pixels come from
`[0x163A34]`, not the shared block at `[0x147466]`.

**Writing a host image into it does NOT reach the screen** — the buffer is reverted within
~107 ms. The write path is fine: host writes persist 1.5 s in overlay BSS, in scene-graph
memory and in far heap, and only this buffer reverts. Size is irrelevant (16 B behaves
like 589 KB) and the pixel pointer is stable, so it is not double-buffered.

**CORRECTION to the line above:** the branch patch suppresses the 3D *output*, not the
renderer. The measured effects (viewport 1.62% → 0.00%, HUD still repainting) stand, but
the scene is still being rendered into the buffer by a path outside the patched block.

**It is not a clear and not a copy-back.** After a wipe the content is 91.4% identical to
what preceded it — not 100% — with non-zero coverage moving 10.0% → 18.6%. Exact restore
would mean a copy; near-identical-but-drifting means re-rendering, the differences being
animation.

**RESOLVED: it is a SHARED SURFACE POOL, not a framebuffer.** One allocation at `0x10E3B`
is stored into FOUR global aliases — `0x152154`, `0x1521BC`, `0x162E2C`, `0x163A34` — and
`0x28157` points the 3D colour surface at `[0x163A34]` only when width > 0x114. `0x152154`
alone has **54 references across 19 functions** (UI, map, book viewer, scan readout),
including eight in the per-frame draw path; the `.XAF` parser uses it too (`0x29B60`).

AztMod already treats it as the viewport buffer: six `view-bytes-*` patches change the byte
count from the stock 155,664 to **589,824 = 1024x576** (at the allocation `0x10E2D` and five
consumers `0x1425A`, `0x167CB`, `0x16866`, `0x169FD`, `0x17845`).

So nothing was "rewriting the framebuffer" — a host write lands in a buffer the 2D/UI paths
rewrite every frame independently of the renderer. That is why stubbing `0x3F1B0`,
`0x5BD0C`, `0x5B950`, `0x3F6D0` and both flags all changed nothing. Earlier dead ends, for
the record: `0x2D100` (inventory logic), both `0x3F010` fills, `0x1F222`,
`0x1E61C`/`0x1E62C`/`0x1E63C`.

**Consequence:** a host-composited viewport cannot be done by writing the surface from
outside. Host pixels must be injected FROM INSIDE the guest, after the last writer and
before the blit — a small overlay hook copying from a staging buffer the host fills. The
bridge already provides the staging half.

**Method:** a static scene re-renders to IDENTICAL bytes, so watching a buffer proves
nothing. Write a sentinel and see whether it is reverted — that is what revealed a writer
existed at all.

## What is NOT established

Writing to guest memory, frame synchronisation (the reader polls; it is not driven by
the game's frame), and latency bounds. A host renderer that must not tear still needs a
sync mechanism — that is where emulator work may yet be justified.

Related: [[azrael-camera-transform]], [[azrael-scene-graph]], [[aztmod-patch-framework]],
[[azrael-le-image-layout]], [[azrael-xaf-scene-format]]

## 2026-10-11: THE WINDOW IS 256 KB -- obj2's delta moved

obj2's runtime delta is NOT a constant: obj2 runs one page past obj1's end, and obj1 grew (vsize 0x130000 -> 0x163000), so +0x1F1000 became **+0x224000**. obj1's +0x1F0000 is unchanged. Never hard-code it: GuestBase.ps1 returns .Delta2 (found from the needles, the installed header's candidate first), the gate has .D2, the watcher has Get-GuestD2. See [[azrael-overlay-read-limit]].
