---
name: azrael-loh-retention-trap
description: "Convert-ToAnim's per-frame verify list fragmented the Large Object Heap and cost a 7-hour dead run; hash frames instead of keeping them."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-09-29T10:43:41.962Z
---

On 2026-09-29 OUTRO2 (2000 frames, 1024x768, from a 2560x1920 source at 18.8 MB/frame) ran
**7 hours without writing a byte**, at 54.3 GB committed on a 47.6 GB machine, 2.49 billion page
faults, CPU pinned at ~99% of a core in the GC rather than in the encoder.

**Cause, measured by bisection, not guessed:** `Convert-ToAnim.ps1` kept every fed frame in
`$fed` for the `-Verify` pass. Every buffer in that loop is over 85 KB so all of it is Large
Object Heap, which is never compacted and only collected on a gen-2 pass. The long-lived frames
sat interleaved with the transient decode/resize garbage and the heap could not be compacted
around them. On OUTRO1: retaining frames grew LIVE memory (after a forced collect) 14.75 MB per
frame to 3.2 GB by frame 200; the identical run without `-Verify` held **flat at 226 MB**. That
one-variable comparison is what identified it — `[GC]::Collect()` on a cadence alone did NOT fix
it, and `ArrayList.Add(byte[])` was measured innocent at the expected 490 KB per call.

**Fix:** store `MD5(frame)` instead of the frame — 16 bytes each. Verify compares hashes. Also
dropped the old pixel-by-pixel verify loop, which ran one PowerShell iteration per pixel (1.57
BILLION on OUTRO2). Result on OUTRO1: live memory flat at 226 MB, output **byte-identical** to
the known-good file, still "round-trip is EXACT", and 20% faster (248.6s -> 197.9s).

**How to apply:** never retain per-frame buffers across a long encode in PowerShell. If a check
needs to compare frames, hash them. Use the `-Progress N` switch (added at the same time) on any
run over a few hundred frames so a stalled job is visible in minutes instead of hours — print
`[GC]::GetTotalMemory($true)` (live, forced) beside private bytes, because the cheap
`GetTotalMemory($false)` reading hides the difference between garbage and genuine retention.

Related: [[azrael-mov-format]], [[azrael-powershell-silent-traps]].
