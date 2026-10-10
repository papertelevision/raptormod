---
name: azrael-rl-error-callback
description: "0x10204 is Reality Lab's REGISTERED error callback -- that is why the host-render crash has no static caller; AztRaptorTrap captures the live stack instead."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-04T20:01:50.031Z
---

The host renderer's crash is **`RAPTOR ERROR in Rendermorphics / Error: object expected in
argument`** = RL error code **1**.

**The reporter is 0x10204** (file 0x61C58), and it is 8 bytes of `movsx eax, al` +
`call 0x32FF4` (code → message text, table at 0x14352B), then `push eax` / `push 0x140008`
("Error: %s") / `push 0x140013` ("Rendermorphics ERROR:") / `call 0x334A0` / `ret`.
`0x334A0` shuts video and sound down first, so the message lands on a clean text screen.

**IT HAS ZERO STATIC CALLERS AND THAT IS NOT A TOOLING FAILURE.** `mov eax, 0x10204` at
**0x10E92** is the game *registering* it with RL; the call comes from inside RL through a
pointer. **Stop looking for the caller in the disassembly** — nine passes of static
analysis could never have found it. Only the live stack knows.

Hence `$ENABLE_RAPTOR_TRAP` in `src\Build-AztMod.ps1`: `AztRaptorTrap` replaces those 8
bytes with `jmp` + 3 nops (verified: no LE fixup in range, nothing branches into it), sifts
192 dwords of stack for values inside obj1 (**0x10000..0x140000** — obj1 starts at 0x10000
and its BSS window ends where obj2 begins, so any return address is in that range while the
heap at 0xA86038/0x1138038 and obj2's data are above it), keeps 20, and holds the game for
up to 91 BIOS ticks so the watcher can read it. A **jmp, not a call** — it pushes nothing,
so `[esp]` on entry is already RL's own return address, and the site's `ret` still works.
`Read-Raptor.ps1` then keeps only entries with a **call immediately before them** (an
instruction that ends exactly at that address), which separates real frames from lookalike
data.

**Watcher gotcha:** poll it at the TOP of the session loop. A game frozen in the trap never
clears `aztInjReady`, so both sync waits time out and `continue` — a poll after either one
is never reached.

## WHAT IT CAUGHT (2026-10-04): the cursor pick

All 9 captured entries were genuine frames. Live chain: **0x14895 → 0x116E4** (per-frame
cursor pick; reads cursor 0x182D6C/6E, calls RL pick 0x3BBC4, `al==5` = nothing picked →
0x11D3A) **→ 0x11830 `call 0x3A420`** (handle → owner) **→ 0x33048 → 0x39E50 returns null →
error 1**. The pick hands back a handle RL can no longer resolve and 0x116E4 never checks it.
Fix: `AztPickGuard` (patch `pick-guard` at 0x11830) resolves via 0x39E50 first; dead handle
→ drop return address, `jmp 0x11D3A`. WHY the handle is stale under host render is NOT
established (guess: pick data depends on the suppressed scene pass) — if picking/interaction
misbehaves under host render, start there. Overlay now 53,193 bytes, **55 free**.
Trap capture ignores 4 stale frames between live ones (0x4DA11..0x1F3F2 were residue).

**The pick guard did NOT cure it — the crash moved (15:57 run).** Second chain: **0x14187 →
0x3F1B0** (scene pass) **→ 0x3F1EA `call 0x5B7F0`** (per-child move/tick) **→ 0x33048 →
error 1**. 0x45270 snapshots the root's children (`[0x147ED8]`, first child +0x3C, sibling
+0x34, handle +0x14) into an array; one handle in that array fails the lookup. So the real
fault is general: **a handle from a live list stops resolving** (hash at 0x1831CC, 0x3FD
buckets, chain via [rec+0], key [rec+0x14]). Either an object destroyed mid-pass / still
referenced, or its header corrupted. UNDECIDED. The trap now records `aztRaptorEsp` and the
watcher's `Write-RaptorForensics` dumps registers, raw stack, the snapshot array with
ok/DEAD per handle, and any linked-but-unresolvable child, naming dead handles from walks
made while healthy. Overlay 53,205 bytes, **43 free**.

## Causes ELIMINATED (do not re-derive)

- **Texture-cache purge use-after-free** at 0x2876C. `$ENABLE_OOM_TRAP` skips the purge and
  reports the first failed allocation, so this cannot happen without
  `FreeMemory: No memory available` reaching AZERR.TXT first. It never does. See
  [[azrael-texture-cache-reserve]].
- **Buffer overrun.** Both blocks measure 1,484,805 bytes for a 1,484,800-byte copy, and the
  destination `[0x163A34]` was logged as stable across a whole session.
- **The actor-loop burst** — real, and FIXED (`AztActorTime` now runs one step per frame
  instead of draining its accumulator up to 8x), but **not the whole story**: it took the
  crash from ~180 copies / 8 s to **597 copies / 27 s at the same push rate**, which rules
  it in as a contributor and out as the cause. See [[azrael-frame-tied-timing]].

**`OpenProcess failed: 87` one second after a crash is a WATCHER bug, not a clue.** A
process stays listed for a moment after it exits, so the re-attach loop found the corpse of
the game that had just died. It now waits for the old pid to disappear first. This was
reported as the error that killed a run more than once.

Related: [[azrael-view-injection]], [[azrael-reality-lab-engine]],
[[azrael-overlay-read-limit]], [[azrael-tier-a-host-render]].


## Third failure mode (2026-10-04 16:05): NOT an RL error

After ~100 s and 4 rooms (CORICORI, SPAROOM, MINEHEAD, BAPTIST) the game died on **DOS/4GW exception 06h (invalid opcode) at 0x111008** -- a jump into data, during a scene rebuild 8 s after entering BAPTIST. Registers: EAX=EBX=0x6400000, ECX=EDI=0xA86038 (the viewport surface), ESI=0xC5AB78, EBP=0x35A, ESP=0x386340. The trap cannot see this. The watcher now sifts the stack region 0x37E000..0x38A000 into `stallstack.txt` when the guest takes no frame for 3 s, and the installed AZRAEL.BAT ends in a `pause` so guest RAM survives the crash (**-Install rewrites the BAT; re-add both the `2> AZERR.TXT` and the pause**). AZERR.TXT timestamps run ~20 s ahead of host time (guest clock), so they do not mean DOSBox outlived the crash. Survival between identical builds varied 8 s vs 100 s, so run length alone proves nothing.

**The exception-06 crash is REPRODUCIBLE (16:28 run):** identical registers and EIP 0x111008 both times, both on walking BAPTIST -> ORRERY (camera about -298 -39 396), the second after 11 minutes / 14,510 clean frames. So after the pick guard the host renderer is otherwise stable in play; this is one specific trigger, not random corruption. Not yet known whether ORRERY crashes without the watcher. The stall dump is now keyed on aztCamFrameNo (not on $suppressed -- the viewport had been handed back 1 s before the crash, so the first version missed it), and the BAT hold is a pause LOOP because a held movement key satisfied a single pause instantly. The 'IN BLENDER' console text is just Export-XafObj.ps1's note, printed when the watcher exports a room it has not cached -- harmless. Separate open issue: loading a save hard-hangs 0.35 s into the reboot-on-load boot replay with the BIOS tick frozen (Josh deferred it).

**ORRERY crash located (16:43 stack image).** The DOS/4GW exception frame sits just under ESP 0x386340 and [ESP] = return 0x4713F: `call [edx+0x18]` at 0x4713C in **0x46F34** (add faces to a mesh), called from the XAF mesh loader **0x29068** at 0x297BC (chain 0x29B50 -> 0x2992C -> 0x29068; object strings 'ORRERYTEXTURE01' on the stack). The face slot ebx = [mesh+0x5C] + [mesh+0x54]*120 was 0x6400000 -- beyond guest RAM (memsize 32) -- so the vtable read FFFFFFFF and the call landed in low memory (EIP 0x111008). Mesh had 387 verts / 424 faces. WHY the slot is wrong is still open. Note the loader uses the SHARED VIEWPORT SURFACE [0x163A34] as its face-list scratch buffer (0x29B60 copies it to 0x163BAC; edi=0xA86038 at the crash). The watcher now keeps a 4-deep ring of stack images (exitstack-N.bin) plus the mesh header (exitmesh-N.bin) because DOSBox itself dies ~1 s after this crash. Still untested: ORRERY with no watcher.

**16:51 mesh header: the bad pointer came from malloc.** mesh+0x54 faces 0, +0x58 cap 424, +0x5C = 0x6400000 -- freshly set by 0x46634 from 0x39B10 -> Watcom malloc (0x32C40 -> 0x401A7 -> 0x50A3E; heap list head [0x1476EC], next [+8], rover [+0xC], largest [+0x14]). The heap being searched is the mini-heap at **0xA86008, whose first block is the viewport surface at 0xA86038**. Unmapped guest memory reads FFFFFFFF = a huge free block, so once a rover leaves real RAM (top 0x2000000 at memsize 32) every malloc 'succeeds' in memory that does not exist and writes are lost silently; the crash is a late symptom. Leading hypothesis: genuine exhaustion or a bad free-block size in ORRERY, NOT the host renderer -- unproven until ORRERY is entered with no watcher. Watcher now logs every mini-heap per room and flags the first moment a heap pointer passes RAM top.

## 2026-10-04 17:00 -- the ORRERY crash is a USE-AFTER-FREE WRITE; relevel kick switched off to test

Heap log (watcher `Get-HeapReport`): the last mini-heap 0x131B008 had rover 0x131C738 until the ORRERY load, then **0x640C6C0 = 0x63FFFF8 + 0xC6C8** (the 50,884-byte request for a 424-face mesh, rounded). So malloc followed a free-list link of **0x063FFFF8** out of RAM. That value is **1599.9999 in 16.16** -- a viewport right clip edge at 1600 wide -- written into an already-freed block. Prime suspect: `` (destroys/recreates device + viewport every room change). **Now `False` as a diagnostic** (overlay 53,151 bytes, 97 free; 28 patches re-pointed). If ORRERY then loads: confirmed, and the earlier dead-handle RL errors are probably the same bug. If it still crashes: turn the kick back on and look for another writer of viewport extents. Josh's view: not the watcher (agreed -- watcher never writes there) and ORRERY is not the biggest room (agreed -- trigger is the first >38 KB malloc when every real heap is fragmented, not room size). NOTE: 'largest 0xFFFFFFFF' and negative alloc counts in the heap report are NOT proof of corruption -- seen on the last heap in the very first room; only a pointer past 0x2000000 is.

## ROOT CAUSE FOUND (2026-10-04 17:15) -- the AztScenePart2 skip never wrote its outputs

0x5B820 is called from the scene pass 0x3F1B0 as (eax = &count, edx = &array). The host-render skip stub (aztSceneParts bit 4) returned al = 0 WITHOUT writing either, so every suppressed frame 0x3F221.. looped over a garbage list and then `mov eax,[esp+4] / call 0x39C14` FREED a garbage pointer: a double free per frame. That explains every symptom in this file: dead handles (pick, scene pass, mesh pick), negative heap alloc counts, free-list links leaving RAM (0x6400000 phantom objects -- seen on the pick's own stack in the 17:08 capture), the DOS/4GW exception in ORRERY, and delay shrinking with frame rate (8-100 s at 22 fps, 4 s at 50). FIX: the stub now does `and dword [eax],0 / and dword [edx],0 / xor eax,eax` -- 0x5B820's own nothing-to-draw exit at 0x5B835. **Awaiting Josh's confirmation run.** The relevel kick is STILL OFF from the earlier wrong guess (the 16.16-clip-edge reading of 0x063FFFF8 was a coincidence) -- turn `` back on once the fix is confirmed. Lesson: a skip stub must reproduce the callee's OUTPUTS, not just its return value; read the caller past the test.

**CONFIRMED 2026-10-04 17:17:** with the AztScenePart2 output fix, Josh entered ORRERY and played 3+ min at ~50 fps guest loop with no trap, no exception, no heap line past RAM. 'Best run yet.' Still to do: turn `` back on (needs a build+install with the game closed).

**17:25: `` is back ON** (cleared; comment in the build script says why). Overlay 53,211 bytes, **37 free**. Installed, 418 patches verified. Not yet run with the kick + scene-part fix together.

**Cursor pick + stale cache (2026-10-04 23:05):** the pick walks frame+0x90, which goes stale under host render (see [[azrael-characters-host-render]]). `AztScenePart2`'s skip path now calls the engine's own refresh-dirty-subtree routine: `mov eax,[0x147ED8]` then a thunk `push edx / jmp 0x552D2` (0x552C4 entered past its test of the node's own dirty byte, because the tree top is not a real frame). Untested live.
