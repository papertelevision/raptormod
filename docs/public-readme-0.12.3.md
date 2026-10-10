# AztMod 0.12.3

Quality-of-life patches for **Azrael's Tear** (Intelligent Games / Mindscape, 1996),
targeting the Steam release. Mouselook, WASD, a full-width 640x480 viewport,
wall sliding, and a rebuilt story log.

It patches the game's `R.EXE` at install time. It does **not** ship a patched
executable and it does not ship any of the game's data.

---

## Install

You need Windows PowerShell (already on every Windows machine) and the game
installed from Steam.

1. Unzip this folder anywhere.
2. Open PowerShell in it and run:

```powershell
.\Apply-AztMod.ps1 -Install -Dest "C:\Games\AzraelsTear-Modded"
```

3. Play with `C:\Games\AzraelsTear-Modded\Play-Azrael-Modded.bat`.

The installer locates your Steam copy automatically; pass
`-GameDir "<path to Azrael's Tear>"` if it lives somewhere unusual.

It **copies your whole game** to `-Dest` and patches the copy. Your Steam install
is never written to, so Steam updates and "Verify integrity of game files" cannot
break the mod, and the mod cannot break your original. Launching from Steam still
runs the unpatched game.

If PowerShell refuses to run the script, either unblock it
(`Unblock-File .\Apply-AztMod.ps1`) or run it once as
`powershell -ExecutionPolicy Bypass -File .\Apply-AztMod.ps1 ...`.

### Other commands

```powershell
.\Apply-AztMod.ps1 -Status -Dest "C:\Games\AzraelsTear-Modded"
.\Apply-AztMod.ps1 -Revert -Dest "C:\Games\AzraelsTear-Modded"
```

`-Revert` restores `R.EXE` and every replaced art file from the backups the
installer made (`*.aztbak`), so the copy goes back to stock without reinstalling.

`-InPlace` patches your Steam folder directly instead of copying. Not
recommended, but it is there if you want it; `-Revert` still works.

---

## What it changes

**Controls**

| key | action |
|---|---|
| Mouse | look around - the default now, nothing to hold |
| `W` / `S` | forward / back |
| `A` / `D` | strafe left / right (true lateral movement, not turning) |
| hold right mouse | restore the game's normal pointer with its TAKE / USE / PUSH icons |
| left mouse | fires in combat mode (`Space`). It no longer walks you forward. |
| `F3` | sticky cursor mode, if you would rather not hold a button |
| `F2` | disable / re-enable the mod live |
| `F10` | invert mouse Y (a stock game feature) |

**Display**

- The 3D viewport goes from 552x282 to the full 640x342. The instrument panel is
  rescaled to 55% and re-centred to make room, and every button, hover highlight
  and click region is moved to match.
- The HUD widgets that used to sit under the panel (notes window, status gauge,
  object scanner) are relocated into the HUD strip rather than left floating in
  the middle of the scene.
- The camera-pitch indicator on the edge of the view is removed.

**Movement**

- Walking into a wall no longer swings your view. Stock behaviour nudges your
  facing by +/-10 degrees and abandons the step; that is gone.
- Instead you **slide along the wall**: the movement vector is projected onto the
  wall plane, so you keep the component that is not blocked and lose speed
  smoothly as you turn into it.

**Story log**

- Narrower and repositioned so it takes up less of the scene.
- New anti-aliased fonts, generated at install time (see below).

---

## Why the installer builds art instead of shipping it

This package deliberately contains **no game assets**.

The rescaled instrument panel (`HUD3.PCX`, `HUDOFF.PCX`) and the contextual
button sprites (`NBUT*.PCX`) are derived from Mindscape's original artwork, so
redistributing them would mean redistributing their art. Instead the manifest
records *how* they were made, and `Apply-AztMod.ps1` rebuilds them at install
time from the copy of the game you already own. The replacement fonts are
generated the same way, from a typeface already on your system.

The patch data itself carries about 2.7 KB of original bytes, spread over 245
short excerpts used to verify each patch site before writing to it. That is how
any binary patcher works, and it is what makes the installer refuse to run
against the wrong build instead of corrupting it.

---

## Compatibility

Built against the Steam release:

```
R.EXE   1,665,875 bytes
SHA-256 8EE00BE079FCB99F008C1F51ECBDBD04FFDF3BEA5FDEFC56775210FDDA549EFF
```

The installer checks this before touching anything and stops if it does not
match. If you have a different release (GOG, floppy, CD) it refuses rather than
guess. That is intentional.

It also verifies every one of the 245 patch sites individually, so a partial or
failed install is reported rather than silently shipped.

---

## Known limitations

- **640x480 is a hard ceiling.** The game's screen writer is hand-unrolled for
  exactly four 64 KB VESA bank boundaries across five blitters and has no linear
  framebuffer path. Higher modes can be *set*, but nothing renders correctly.
  This is not a tuning problem; it needs a new renderer.
- **The intro movies cannot be patched out** of `R.EXE` - that code owns the
  video mode and event pump during startup. `-SkipIntro` skips the separate
  `TM.EXE` stage only.
- The story-log scrollbar drag covers roughly 55% of its range (the gain is one
  unit per screen pixel, unchanged from stock).
- Sliding is implemented for the two forward movement paths. Backing into a wall
  still stops dead.

---

## Credits and licence

AztMod is an unofficial fan modification. It is not affiliated with, endorsed by
or supported by Intelligent Games, Mindscape or any current rights holder.
*Azrael's Tear* and all its assets remain the property of their owners. You need
your own legally obtained copy of the game; this package does not include any
part of it.

The mod's own code is free to use, modify and redistribute.
