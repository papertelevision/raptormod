---
name: azrael-mf-stride-trap
description: MF_MT_DEFAULT_STRIDE LIES when the MP4 width is not 16-aligned - Media Foundation pads BOTH axes. This sheared the opening movie and survived three wrong diagnoses.
metadata:
  node_type: memory
  type: reference
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-02T02:15:55.779Z
---

`MF_MT_DEFAULT_STRIDE` is the media type's **nominal** pitch, not the buffer's. Media
Foundation hands back frames padded to 16 on **both** axes, and only the width padding
matters: believe the declared stride and every row lands N pixels off the one above, so the
picture comes out progressively **sheared** — "slanted to the right and smeared".

`opening.mp4` is 1470x630. The buffer was 3,768,320 bytes = **1472 x 640 x 4**:

| | declared | actual |
|---|---|---|
| pitch | 5880 (1470*4) | **5888** (1472*4) |
| rows | 630 | **640** |

Two pixels lost per source row; scaled to the 1024-wide output that is ~1.4 px/row, ~613 px
across the frame.

## Detecting it

`bufLen / Height` **does not work** — the height is padded too, so 3768320/630 = 5981.46 and a
divisibility test just fails (my first guard did exactly this and silently did nothing). Walk
candidate pitches instead, from `Width*4` upward in steps of 4, and take the narrowest that
divides the buffer into a whole number of rows between `Height` and `Height+64`. An aligned
width matches `Width*4` first, so nothing changes for the normal case.

Confirm from the picture, not the arithmetic: mean `|row[y] - row[y+1]|` over a few hundred
rows is minimised at the true pitch. For opening.mp4 — 5880: 4.411, 5884: 3.215, **5888:
2.256**, 5892: 2.998. Also the only exact divisor.

Fixed in `tools\Mp4Reader.cs` (`CheckStride`, called on the first frame; `ReadRawFrame()`
exists for re-running the correlation).

## Who is at risk

**Only non-16-aligned widths.** Every TensorPix upscale is aligned (2208, 2400, 2560, 1280),
which is why only this one movie was ever skewed and why none of the others needed
re-encoding. Probe with `Probe-Mp4.ps1` and check `W % 16`.

## Three wrong diagnoses first

Recorded so they are not revisited: (1) the output geometry had to be 1024x384 — false,
1024x768/x576/x440 all play; (2) the hook calling the player twice back-to-back skipped a
teardown — plausible, and the hook move to 0x200A0 was kept, but it was not the cause;
(3) the alternating 1837/1838-sample audio chunks sheared the picture — they corrupt the
*sound* and the constant-chunk rule stands, but the image was already sheared before the
container was written.

**The test that settled it:** decode your own output back to PNG. The block codec reported
**100% of blocks accounted, 0 out of range** on a visibly sheared frame — self-consistent
garbage in, self-consistent garbage out. A clean codec report says nothing about whether the
pixels fed to it were right. See [[azrael-mov-format]], [[azrael-extra-intro-movie]].
