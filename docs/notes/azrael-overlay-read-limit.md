---
name: azrael-overlay-read-limit
description: "The overlay window is 256 KB since 2026-10-11 (obj1 vsize 0x163000, $OVERLAY_READ 0x40000) -- obj1 grew PAST obj2's linked base and obj2 moved up (delta 0x1F1000 -> 0x224000). The loader lives in the actor-time (clock) blob, NOT the stub."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-11T23:55:00.000Z
---

`$OVERLAY_READ` caps how much of `AZTCODE.BIN` the loader pulls into the BSS window at 0x133000.

**History:** 0x4000 → 0x8000 → 0xC000 → 0xD000 (2026-09-30, then the "ceiling": the window ended at obj2's LINKED base 0x140000) → **0x40000 = 256 KB (2026-10-11)**.

**Josh, 2026-10-11:** "If there is a ceiling, lets raise it a logical amount for tasks I request. This is an old game and we have room to make it more beefy." The overlay was 53,246 of 53,248 bytes when he said it; it is now 53,238 of 262,144 (208,906 free).

**How the ceiling was lifted (Build-AztMod `$OBJ1_VSIZE` = 0x163000):**
- DOS/4GW does NOT load the objects at their linked bases, and does not keep their linked layout:
  - obj1 runs at 0x200000 (delta 0x1F0000);
  - obj2 runs ONE PAGE PAST obj1's END (0x331000 = 0x200000 + 0x130000 + 0x1000).
  - Equal deltas would have meant one block in the linked layout; they differ by a page.
- So the linked ranges overlapping (obj1 now 0x10000..0x173000, obj2 still linked at 0x140000) is nothing the loader looks at. Every absolute reference is a fixup against (object, offset).
- **obj2's delta = obj1 vsize (page-rounded) + 0xC1000:** 0x1F1000 with vsize 0x130000, **0x224000 with 0x163000**. The game's stack (obj2 BSS, ESP 0x386340 in old crash dumps) moves with it.
- The build throws if the vsize is not whole pages or exceeds 0x200000 (2 MB out of the heap needs a deliberate decision).

**What had to change with it -- check these again if the vsize moves:**
- **Guest:** AztScenePart2's refresh read the scene root as `[esi + 0x147ED8 + 0x1000]` ("obj2 is one page past obj1"). It now calls AztDeltas and reads `[edi + 0x147ED8]`. An audit of every esi-relative operand found no other obj2 address. AztRaptorTrap's "inside obj1" test is now `< OBJ1_BASE + OBJ1_VSIZE`.
- **Host -- obj2's delta is FOUND, never assumed:**
  - **GuestBase.ps1:** Get-AztObj2Deltas reads obj1's vsize from the installed R.EXE header and tries that delta, then 0x1F1000. The needles must agree under one of them. `.Delta2` is returned and Read-AztGuest -Obj2 uses it. A plain file copy (objects 0xD000 closer, implied delta 0x1E3000) is still refused.
  - **LoadingScreen.cs GameGate:** obj1 needles first, so FastBase's anchor has no obj2 delta in it. Verify/FindBase try each candidate, and `D2` is the one that matched; the title-menu addresses and ClearGameInput use D2.
  - **Watch-HostRender:** `Get-GuestD2` takes the guest's aztCamDelta2, else $g.Delta2, else 0x1F1000. `Get-StackLo` gives the stack region for the stall dump and exit-stack ring. BootHd's SetGameCopy has a settable `D2`. The attach line logs the delta.
  - **Dev scripts** (Capture-Reference, Start-HostView, Start-HostRender, Test-Suppress3D*, Map-GuestMemory) use $g.Delta2 or the header.
- **tools\LeTool.cs ObjOfLinear prefers the LATER object where ranges overlap**, so Test-Patch on a patched R.EXE still reads obj2 data at 0x140000+.

**The read itself:** one DOS `INT 21h AH=3Fh` of up to 0x40000 bytes. DOS/4GW takes a 32-bit count: the game's own fread (0x397B3) hands the whole remainder to 0x54044 → `int 21h` with no 64 KB chunking. AH=3Fh reads *up to* ECX and returns what it got, so the file can be any size up to the window.

**Where the loader actually is:** `AztOverlayLoad` is emitted into the **`actor-time` patch**, the clock blob at linear 0x50F2D, not the `stub` patch. To verify the read count, look for `B9 00 00 04 00` (mov ecx, 0x40000) in that patch.

**Offline proof (2026-10-11):**
- scratchpad `layout-test.ps1` + `layout-holder.ps1`: a second process holds a fake guest RAM with the needles at their runtime addresses.
  - New layout: GuestBase and the gate's fast and full scans all find it, delta 0x224000.
  - Old layout: all three find it, delta 0x1F1000.
  - File-copy spacing: all three refuse it.
- Test-Patch on the new manifest: every hook a whole instruction, no relocation clobbered.
- Manifest diff: obj1-vsize, actor-time's read count, and 12 rel32s into the overlay shifted -8 (the shorter AztScenePart2). Installed: 442/442 verified.
- Backup: `AztMod\backup-pre-overlay-256k-20261011`.
- **RUN IN GAME 2026-10-11: Josh "the game is running fine otherwise so the added ceiling seems good to go".** (watch.log's "attached ... obj2 delta 0x..." line says which layout DOS/4GW used.)

**Still budget before writing:** the window is big now, but the CAVES (stub 0 free, clock blob 12, box blobs 1 and 5) are not. Hooks into game code still need their few bytes there or an in-place rel32.

Related: [[azrael-cave-space]], [[azrael-boot-effects-phase]], [[azrael-le-image-layout]], [[azrael-rl-error-callback]], [[azrael-host-guest-bridge]].
