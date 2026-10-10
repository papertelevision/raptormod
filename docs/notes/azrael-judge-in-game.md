---
name: azrael-judge-in-game
description: For look/taste decisions (textures, grain, upscales) produce the result and let Josh judge in game; do not build offline comparison images unless asked.
metadata:
  type: feedback
---

On 2026-10-05, while I was generating an offline 4x-vs-8x comparison crop during the texture
upscaling work, Josh rejected the tool call and wrote: "You dont need to create comparisons lets
just run the 8x upscale on these rooms ... so I can see in game."

**Why:** he judges the look in the running game; side-by-side crops cost him waiting time and he
does not use them. (Earlier the same day he did use one labelled ladder to pick settings, when
I asked him to choose between named variants.)

**How to apply:** for a look change he has already specified, just apply it to the requested
rooms and report. Offer a comparison picture only when he has to CHOOSE between options, or asks.
My own interpretation: quick self-checks that take seconds and produce no deliverable are still
fine; long re-renders purely to make a comparison are not.

Related: [[azrael-true-colour]].