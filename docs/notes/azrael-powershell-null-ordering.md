---
name: azrael-powershell-null-ordering
description: "In Build-AztMod, a derived value placed above the constant it reads gets $null → 0 and builds silently. Keep derived values in the block below all constants."
metadata:
  node_type: memory
  type: feedback
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-09-30T16:43:41.951Z
---

Build-AztMod.ps1 is one long top-to-bottom script, so **a derived value placed above the
constant it reads silently becomes 0**. PowerShell resolves an undefined variable to
`$null` and `$null` arithmetic to `0` without a warning, and `Set-StrictMode` is not on.

This has bitten twice in the boot sequence alone:

- `$BOOT_MIS_Y = ($BOOT_MIS_CY - [int]($BOOT_MIS_H / 2)) -band -2` was written above
  `$BOOT_MIS_H`, so it evaluated to `270 - 0` and the mission block sat **36px lower**
  than intended. It built, it passed its own bounds check, and it looked plausible.
- The timeline print/assert read `$BOOT_MIS_TYPE_US` from above its definition, printed
  the mission beat as **zero-length**, and its ordering assertion passed on the strength
  of that zero.

**Why it's nasty:** nothing fails. There is no error, the output looks reasonable, and the
assertion you wrote to catch timing bugs passes *because* of the bug.

**How to apply:** put every derived boot value in the block marked
`=== everything below is DERIVED ===`, after `$BOOT_TXT_PITCH`. That block opens with an
explicit `Get-Variable`/`$null` check over the constants it depends on, which turns this
class of mistake into a build failure. Add new names to that list when adding derived
values. The same care applies anywhere else in this script that computes from constants.

Related: [[azrael-powershell-silent-traps]], [[azrael-powershell-utf8-trap]],
[[aztmod-manifest-not-buildscript]].
