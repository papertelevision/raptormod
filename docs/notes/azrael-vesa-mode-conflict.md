---
name: azrael-vesa-mode-conflict
description: FIXED - lfb-mode-bit and vesa-mode-33ABB both owned file 0x85510 so the LFB bit was never requested; now one patch writes mode 0x4105 and Assert-NoOverlap prevents recurrence.
metadata:
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-26T05:36:45.331Z
---

**RESOLVED 2026-09-26.** Kept because the failure mode is subtle and the prevention
matters more than the fix.

`lfb-mode-bit` and `vesa-mode-33ABB` both wrote **the same four bytes** at file
`0x85510` (linear `0x33ABB`, the imm32 of `mov ecx,0x101` feeding INT 10h AX=4F02h).
Both expected `01 01 00 00`; one wrote `01 41 00 00` (mode 0x101 + LFB bit 0x4000),
the other `05 01 00 00` (mode 0x105). The applier walks the list in order, so the
hires one won and **the LFB bit was never requested in any hires build** — the
shipped R.EXE read `05 01 00 00`, plain banked mode 0x105.

Nothing caught it: patch count was right, every site verified against pristine bytes,
and the game ran — because `lfb-one-bank` widens the reported VESA window until the
whole framebuffer fits bank 0, so the blitter's linear writes to 0xC0000000 land
correctly with or without bit 14. The only symptom was a patch that silently did
nothing.

**The fix.** `lfb-mode-bit` is deleted. The LFB bit now travels as a value,
`$LFB_MODE_BIT` (0x4000, zero when `$ENABLE_LFB` is off), and the single patch that
owns that site ORs it in: `vesa-mode-33ABB` writes `$VESA_MODE -bor $LFB_MODE_BIT`.
Verified installed as `05 41 00 00` = **mode 0x4105**, and boot-tested: 590 frames
logged, so the mode set succeeds and rendering works. Only the 4F02h SET site may
carry the bit — the 4F01h get-info and mode-list sites (`0x33C03`, `0x33C17`,
`0x33C4C`) must keep the plain mode number or they will not match the BIOS tables.
There is also a branch for `-not $ENABLE_HIRES`, so turning hires off cannot silently
drop the LFB bit again.

**The prevention, which is the real point: `Assert-NoOverlap`** runs in
Build-AztMod.ps1 just before the manifest is written and **fails the build if any two
patches touch the same file byte**, naming both. Overlap is always a bug — either two
patches disagree or one is dead. It reports e.g. `no-overlap check: 389 patches cover
6,292 distinct file bytes, none shared`.

**Side effect now gone:** `tools\Test-Patch.ps1` used to throw `vesa-mode-33ABB:
mismatch at +1` and abort before its other checks, because it verifies each patch's
expected bytes AFTER applying earlier ones — an overlap looks to it like a corrupt
manifest. It had been silently not validating builds. It now runs to completion.

Useful technique learned here: to verify overlay code without Test-Patch, pull
`manifest.overlay.bytes`, splat it into `LeImage.ObjData[1]` at
`0x133000 - ObjBase[1]`, and disassemble — `ObjData` is a writable `byte[][]` sized to
each object's full virtual size. See [[azrael-re-tooling]], [[azrael-lfb-plan]],
[[azrael-hires-blocker]].
