---
name: azrael-host-pointer
description: The pointer across the whole widescreen display (tools\Pointer.cs, 2026-10-07) - done with NO game code by holding the game's "pointer hidden" flag; the seam layout + MapPointer; why game-side hooks were impossible.
metadata:
  type: project
---
TRIED IN GAME 2026-10-07 AND TURNED OFF (now opt-in, watcher -HostPointer): Josh could not highlight buttons and had trouble picking up items -- holding the "pointer hidden" flag evidently gates hover and world picking. Not diagnosed further; the plan instead is new art (design\hud-v3-prompt.md) with every control inside the game's reachable 1600 columns (central 15%..85% of a 16:9 strip) and plain repeatable rail sections outside them. Josh: GPU/true-colour version only; the CPU renderer is the future "retro" mode and is not being enhanced.

**Why the mouse stopped at 1600:** the game's screen is 1600x1200; its driver range is clipped to it (0x35939), it draws the cursor itself (0x3544D) and every hit test reads word 0x182D6C/E. Everything wider is host-painted.

**No code space anywhere** (2026-10-07): stub 0 bytes spare, overlay 8 bytes of BSS, clock blob 12, box blob 5. So no game hook. The DATA route instead:
- word **0x147586 "pointer hidden"** (set by EnterMouselook): the mouse callback 0x3584F then neither writes the cursor words nor calls the cursor draw. Its other readers are the blitters' cursor save-under checks. Held at 1 by the host while mouselook (word 0x147218) is off.
- **Clicks are stamped with the cursor words INSIDE the callback** (0x36CD5 -> 0x36D49), BEFORE the position store at 0x358F7 -- so a click lands where the host last wrote.
- The callback thunk saves the driver's position every event: **dword 0x182D68 = x, 0x182D64 = y** (0x182D60 = event mask).
- Cursor image: dword **0x147588 -> game surface** (CORRECTED 2026-10-09 from the blitter 0x37D98: +0 WORD width, +2 WORD height, +4 DWORD pixels, rows packed at the width -- the old "+0 w, +4 h, +0x18 bpl, +0x1C pixels" was wrong and read 30x30 as one dword), hotspot words **0x14758E / 0x147590**; index 0 see-through.

**Pointer.cs** (own thread ~1 kHz, own layered cursor window): moves with the driver's deltas; where the driver is pinned (or the pointer is already past the game's columns) Raw Input (RIDEV_INPUTSINK) carries it, scaled by a running driver/raw ratio. Writes the game position = Panel.MapPointer(display). Dispose clears the flag. If the watcher dies with it set, RMB in/out of mouselook clears it.

**Seam layout** (Panel.SeamLayout, only with the pointer): halves shifted to the window edges (_dL/_dR), gap = slivers of the two inner edges (each half trimmed 3 game px off the dark seam joint). Everything live shifts with its half (XS); a rect spanning the seam (health bar) is stretched across the gap. MapPointer: over art (or below the backing top) -> the half's inverse shift (gap -> SeamX); over the 3D -> itself clamped to 0..1599 and to row 976. Offline: all 11 controls round-trip exactly at 16:9. The edgeSlice beam is unused under the seam layout. -NoHostPointer turns all of it off.