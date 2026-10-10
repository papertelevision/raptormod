---
name: azrael-inject-esi-clobber
description: "Inside AztInjBody, esi stops being the obj1 delta at `mov esi,ebx` — read every [esi+var] BEFORE that line or you address the staging buffer instead."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-09-30T18:30:00.986Z
---

Everywhere else in the overlay `esi` is the obj1 delta, so `[esi+label]` reaches a
variable. **`AztInjBody` is the exception**: it repurposes `esi` as the copy source with
`mov esi,ebx` (A-MovEsiEbx), and from that line on `[esi+label]` addresses the **staging
buffer**, not the variables.

The labels resolve to roughly `0x136xxx`, so a read after the clobber lands more than a
megabyte past a 576 KB allocation — unmapped, arbitrary, or both.

**It froze the game on the first frame that used it.** The vertical-hold-slip roll offset
was read after the clobber, got garbage, and `rep movsd` walked off into unmapped memory.
Nothing about the symptom pointed at register lifetime.

**How to apply:** in `AztInjBody`, read every variable at the top, before `A-MovEsiEbx`.
The split path already did this and says so in its comment ("read BEFORE esi becomes the
copy source") — that comment was the clue, and worth reading before touching this routine.
The roll now also refuses an offset `>= INJ_W*INJ_H`, so a bad value degrades to a plain
copy instead of running wild.

The blit routines (`AztBootText`, `AztBootTyped`, `AztBootGlitch`) never touch `esi`, so
post-passes there can read variables freely — verified by grepping the span for esi writes.

Related: [[azrael-view-injection]], [[azrael-boot-effects-phase]],
[[azrael-viewport-paint-not-suppress]].
