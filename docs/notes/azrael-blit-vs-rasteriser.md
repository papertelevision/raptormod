---
name: azrael-blit-vs-rasteriser
description: "Profiled 2026-09-20 — Azrael's VESA blit is ~1-3% of frame time; the Reality Lab rasteriser is the bottleneck. Don't optimise the blit."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-24T21:03:22.485Z
---

> **PARTLY SUPERSEDED 2026-09-24 by [[azrael-perf-measured]].** The conclusion
> "don't optimise the blit" still holds. But "the rasteriser is the bottleneck" was
> inferred, not measured, and RUNTIME measurement contradicts it: 1.73x the screen
> pixels (1024x768 -> 1280x1024) costs only 7.5% of the frame rate, so PER-PIXEL
> work of any kind is only ~10-15% of frame time. The real cost is emulated CPU
> work that does not scale with screen area — per-polygon transform/clip/setup and
> game logic. Do not plan optimisation work around fill rate.

**The blit is not worth attacking.** Measured by static analysis of the four asm
blit primitives (see [[azrael-hires-blocker]] for their addresses):

- The copy is `rep movsw`, not a per-pixel loop. A full 640x480 update is
  307,200 bytes = **153,600 word iterations**, plus only 4 `int 10h` AX=4F05h
  bank switches.
- The blitters take a **rect**, so it is dirty-rectangle — often much less than
  full screen.
- Against that, the Reality Lab ramp rasteriser ([[azrael-reality-lab-engine]])
  must touch at least the 640x342 = **218,880** viewport pixels, each costing a
  texture fetch, ramp lookup, z test and write — a dozen-plus emulated
  instructions — times overdraw.

Ratio is at minimum ~15:1 in the rasteriser's favour, realistically far more.

**CORRECTION (2026-09-20).** The *copy* is negligible, but the **`int 10h`
AX=4F05h bank switches are not**. Removing them in the LFB spike
([[azrael-lfb-plan]]) raised the frame rate markedly — enough that the actor
divider needed retuning again. A BIOS callback is expensive under `core=dynamic`,
and the blitters are called per RECT, so the count per frame is far higher than
the four-per-full-screen the static analysis assumed. Count BIOS calls, not just
instructions.

**Independent corroboration:** the game's own launch advice, printed by
`azrael-game.conf`, is *"If a room feels slow, you can speed it up by pressing
1,2,1"* — that is the 3D render-resolution divider at `0x10FEC`
([[azrael-key-addresses]]). It only helps if the rasteriser dominates. The
developers knew where the time went.

**How to apply:** the only levers on smoothness are emulated CPU throughput
(`cpu_cycles_protected`, currently 400000 — see [[azrael-dosbox-staging]]) and
the render-resolution divider. Do not spend effort on the blit, and do not
propose GPU rendering ([[azrael-opengl-verdict]]).
