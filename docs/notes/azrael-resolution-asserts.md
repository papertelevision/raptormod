---
name: azrael-resolution-asserts
description: "AztMod's generators are full of asserts written as ABSOLUTE PIXEL SIZES that silently encode one resolution; changing the screen size trips them on unchanged, correct artwork. Identify regions by aspect, not by size."
metadata:
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-10-02T19:27:30.181Z
---

Moving AztMod from 1024x768 to 1280x1024 tripped four asserts in a row, and **not
one of them was a real defect** — each was a correct value measured against a
threshold that had quietly baked in the old resolution.

| where | assert | why it fired |
|---|---|---|
| `Build-AztMod.ps1` ~2917 | `$_.h -le 14`, `$_.w -lt 20` | the gauge measures 163x18 and the arrows 23 wide at 1280; both were under the limit at 1024 |
| `Build-HudButtons.ps1` ~52 | **the same two tests, duplicated** | ditto — fix them together or the build and the buttons disagree |
| `Build-HudBox.ps1` ~197 | rails differ `-gt 2` px | the two box renders are scaled to a common width but different heights, so the gap grows with the frame: ~1.5px at 1024, 4px at 1280 |
| `Build-HudArt.ps1` ~109 | `throw` unless exactly 4:3 | the script is already panel-relative and didn't need it |

## The rule

**Classify regions by ASPECT RATIO, never by pixel size.** The artwork's shapes are
scale-free; its sizes are not. The gauge is the only region wider than 4:1, and the
two sort arrows the only ones taller than 1.5:1, at *any* resolution:

```powershell
$gaugeR = $rg | Where-Object { ($_.w / $_.h) -ge 4.0 } | Select-Object -First 1
$ctrl   = @($rg | Where-Object { ($_.h / $_.w) -ge 1.5 } | Sort-Object y)
```

The comment above that block already claimed regions were identified "by SHAPE, not
by the order they were found" — aspect is shape, absolute pixels never were.

## Do not just loosen a tolerance — find what it was protecting

`Build-HudBox`'s 2px rail check looked like pure slack. It wasn't: `recessY` is
**shared** between the collapsed and expanded frames while the heights were measured
**per-state**, so a 4px rail disagreement made the open recess overhang its own
bottom bevel by 4px. The fix is structural, not a bigger number: pin the origin to
`max(y0)` of the two and measure *both* heights from it, so the recess is contained
in both frames by construction.

## `Build-HudArt` must run BEFORE `Build-HudSkin`

HudArt rescales Mindscape's art and writes HUD3/HUDOFF/MAPBKGRD/NBUT*; HudSkin then
paints the reskin over it. Running only HudSkin leaves the widget sprites at the old
scale; running HudArt second wipes the reskin. Full order for a resolution change:

    HudArt -> Font -> HudSkin -> HudRepalette -> HudButtons -> HudInv
           -> HudBox -> HudTop -> SysMenu -> (installer does Books)

Two wiring traps in that chain: **`Build-SysMenu` defaults `-OutDir` to
`design\incoming\sysmenu\out`, not `art\`** (pass it explicitly or the frames never
ship), and **`Build-Font` defaults `-GameDir` to the MODIFIED copy** at
`C:\Games\RaptorMod\game` — point it at the pristine Steam install.

`Apply-AztMod.ps1` line ~317 still hard-codes `-BoxW 207 -BoxHOff 111 -BoxHOn 231`
for the redistributable path while `sysMenuW/H` come from the manifest. That is a
latent bug for anyone installing without a prebuilt `art\`.

## Two more of them, found going to 1600x1200 (2026-10-02)

The pattern held exactly: both were correct values measured once at 1024 and then
used as absolute limits.

| where | assert | why it fired |
|---|---|---|
| `Build-AztMod` `$GAUGE_W_MAX = 136` | gauge width vs the painted well | the recess is 203 px at 1600, so a 136 px "ceiling" rejected correct artwork |
| `Build-AztMod` `$GAUGE_W_EXTRA = 2` | columns past the recess | 2 px of overhang is invisible at 1600 |

Both are now `floor(x * $HS / 1.6)`, which reproduces 136 and 2 to the pixel at 1024.
**Both also had to MOVE into the DERIVED block** — they sat above `$HS`, so deriving
them in place would have read `$null` and produced 0 silently
([[azrael-powershell-null-ordering]]). `$SYSMENU_W/H` and `cornerRadius` were the same
kind of literal and got the same treatment.

The chain in this file is now executable: **`src\Build-Art.ps1`** runs all ten
generators in this order with every size derived from (screenW, screenH, panelScale),
and it was validated by reproducing the shipped 1024 manifest before being allowed to
overwrite the art. See [[azrael-1600x1200]] for its three structural gotchas
(per-generator processes, the log box's unavoidable second pass, H1's overhang).

See [[azrael-hud-overlay-res]], [[azrael-hud-reskin]], [[azrael-stride-derived-offsets]].
