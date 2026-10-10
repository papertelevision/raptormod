---
name: azrael-visor-note
description: "Visor readouts on room entry (VisorNote in ScanWire.cs, Overlay.Decorate3, a room's \"visor\" block); MINEMAZE \"Dark environment detected / Press F for Headlamp\" when the flashlight is off. Built 2026-10-09, not yet seen in game."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-10T01:16:46.796Z
---

Josh (Room Review MINEMAZE/5, 2026-10-09): entering the mines with the flashlight off, the visor should read "Dark environment detected. Press F for Headlamp". F (0x46) IS the watcher's -LampKey.

- **Drawing:** `AztTool.VisorNote` is in tools\ScanWire.cs (so it compiles wherever ScanWire does; no new Add-Type entry).
  - Lines type on in the scanner's inks: the first in AmberHi, the rest in Ink, breathing once typed. Below them sits a soft dark backing, at the top left of the view rows (x = 5.5% of the width, y = 10%, em = view rows / 42).
  - It is hung on the new **Overlay.Decorate3** (called after Decorate2), so it draws on the true-colour picture only.
- **Room key:** `"visor": { "text": [...], "lampOff": true, "delay": 1.5, "hold": 6 }`.
  - It is armed when the room is recognised (`$script:visorPending`) and fires by the flashlight switch code if the flashlight is still off.
  - `Dismiss()` runs when the flashlight comes on.
  - While Playing, the card's present path decorates every frame (the `$dyn` condition, like the scanner).
  - `-NoVisorNotes` turns them off.
- **DAMAGE BADGE (Josh, 2026-10-10):** "Damage taken!" in the view's lower left (x 5.5%, bottom at 86% of the view rows, em vr/50).
  - Look: a red-glass interlaced plate, corner brackets, a pulsing warning triangle, and a red split on each hit. It flickers on, holds 2.4 s and fades 0.55 s; a new hit re-flashes it and restarts the hold.
  - It lives in VisorNote too (`Damage()`), because Decorate3 has one slot. `Playing` covers both, and the watcher's `Get-VisorNote` makes it.
  - **Trigger:** the player's HEALTH is dword `[[0x1841C8]+0x16]`, 16.16 (the gauge code at 0x11DF6 reads it). Any fall counts as a hit.
  - It is quiet while the boot covers the view or the memory core is up, and for 3 s after either or after the object pointer changes, because a load sets health. Switch `-NoDamageBadge`. The watcher logs "damage taken (n)".
- **Tests:** PowerShell `New-Object T($null)` drops the null and finds no constructor; use `[T]::new([AztTool.Overlay]$null)`.