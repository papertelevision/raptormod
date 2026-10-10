---
name: azrael-never-autolaunch
description: "Never launch Azrael's Tear automatically after installing assets or patches — install, verify, report, stop."
metadata:
  node_type: memory
  type: feedback
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-09-29T04:19:53.346Z
---

Do not auto-run the game after installing movies, patches or artwork. Install, verify, report
what landed, and stop. Josh launches it themselves.

**Why:** they want to choose when to test, and an unexpected DOSBox window grabbing focus
interrupts whatever they are doing. Earlier in the movie work they explicitly asked for
"install them when done and launch" — that was a one-off request for that batch, not a
standing instruction, and they later corrected the assumption.

**How to apply:** treat "launch" as something to be asked for each time. If a change really
needs an in-game check before it can be called verified, say so and offer to launch, rather
than doing it. Verification that can be done without running the game (round-trip compares,
payload-vs-buffer arithmetic, [[azrael-vesa-mode-conflict]]'s Assert-NoOverlap) should be done
and reported anyway.
