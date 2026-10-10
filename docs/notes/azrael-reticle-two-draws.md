---
name: azrael-reticle-two-draws
description: "The aiming reticle is drawn by TWO calls and the visible one (0x145FD) runs AFTER the view-inject hook, so draw order cannot hide it."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-09-30T13:47:37.123Z
---

The aiming reticle is **two separate draws**, not one:

| linear | call | what |
|---|---|---|
| `0x141B0` | `0x3C690` | crosshair lines — **before** the inject hook |
| `0x145FD` | `0x38558` | **the visible circle** — 0x42B bytes **after** the hook |

`AztViewInject` is hooked at `0x141D2`, which sits between them. So the overlay covers
the first draw by draw order and the second one paints straight over the overlay.

**This cost two wrong diagnoses.** The note in `$INJ_SITES` claimed 0x141D2 was "after the
reticle draw, so the overlay covers it", `$BOOT_HIDE_RETICLE` was turned off as
"unnecessary" on the strength of it, and the reticle kept showing through the boot
sequence. Covering by draw order only works for what is drawn *before* the injection —
anything after it needs a gate.

Both are now gated by `$BOOT_RET_SITES` → `AztRetGate0`/`AztRetGate1`: each replaces one
call with a stub that returns early while `aztInjEnable` is set and otherwise tail-jumps to
the real primitive, so ordinary play is byte-identical. Neither primitive can be suppressed
wholesale — `0x3C690` has 29 callers and `0x38558` is likewise generic.

**How to check this kind of thing quickly:** scan for `E8` rel32 in the function's linear
range and print each target. That listing is what exposed the second draw — a claim about
draw order is only as good as the call list it was derived from.

Related: [[azrael-viewport-paint-not-suppress]], [[azrael-view-injection]],
[[azrael-key-addresses]].
