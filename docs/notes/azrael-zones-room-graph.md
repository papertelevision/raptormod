---
name: azrael-zones-room-graph
description: "AZONES.DAT decodes to the whole room graph and trigger system - 319 records, 87 rooms, 166 portals. No reverse engineering needed."
metadata:
  node_type: memory
  type: reference
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-27T00:43:37.014Z
---

Unknown 6 was rated *High cost* on the assumption it needed reverse engineering. It did
not. `GAME\AZRAEL\AZONES.DAT` is a flat array.

**Format:** `uint16 count`, then `count` records of **75 bytes**:

| offset | field |
|---|---|
| +0 | zone name, NUL-terminated (60 bytes) |
| +60 | object name, NUL-terminated (12 bytes) |
| +72 | 3 trailing bytes |

23,927 bytes = 2 + 319*75 exactly, and the header word is 0x013F = 319 — two independent
counts agreeing.

**The file is full of garbage and that is normal.** Written from an uncleared buffer, so
bytes after each NUL are 0xCC fill or stale heap, including fragments of unrelated
strings and code. Read to the NUL; ignore the rest.

The object name is a `zx*`/`zy*` object that also appears in the room's `.XAF` and in the
live scene graph — **trigger volumes placed in the world like any other object**. The
zone name says what entering it does:

* `<A>To<B>` — a portal (**166** of them; 87 rooms, 166 directed edges)
* `EntryCoord<Room>` — spawn points (5)
* `<Room><Thing>AZ` — scripted events (127): deaths, characters, vehicles, false floors
* `R22aLift1` etc. — lifts and ladders (21)

**`Baptistery→Orrey` vs `Orrery→Baptistery` is a TYPO in the shipped data**, not a
one-way portal. It accounts for 2 of the 28 apparently-one-way edges.

## The room -> file mapping, and a trap

Cross-referencing the 264 trigger objects against the `.XAF` corpus locates 248. This
explains why there are 178 `.XAF` files for 87 rooms: **the corpus ships duplicate and
dev versions of rooms** — `WELLDEMO`/`WELLROOM`/`R7`, `MINEHEAD`/`MINEHED2`/`HINEAZF`,
`SPAROOM`/`SPAROOM3`/`SPAROOMX`/`OLDSPA`, `CORICORI`/`R1`. Extract wholesale without this
and you get the same room repeatedly, sometimes the wrong revision.

## Still open

This is the room graph and the trigger system. It is **not** visibility — no evidence yet
of portal culling or a PVS; the engine may simply draw the whole room.

Tool: `tools\Read-Zones.ps1` (`-Graph`, `-MapFiles`, `-Csv`).

Related: [[azrael-xaf-scene-format]], [[azrael-host-guest-bridge]]
