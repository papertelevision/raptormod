---
name: installer-select-first-trap
description: Piping Apply-AztMod into Select-Object -First N STOPS the installer mid-way (R.EXE patched, overlay/books/bat not written). Use -Last or no filter.
metadata:
  type: feedback
---

2026-10-13: `.\Apply-AztMod.ps1 -Install ... | Select-String ... | Select-Object -First 6` ended the pipeline once 6 lines matched, which halts the upstream script: R.EXE was patched but AZTCODE.BIN (the overlay) was never rewritten, so the installed game ran the OLD overlay (aztNpcPct still 95).

**Why:** PowerShell's `Select-Object -First` stops upstream commands as soon as it has enough objects.
**How to apply:** never cap the installer's output with -First; use `Select-Object -Last N`, or capture all output to a variable first. After an install, read back a changed overlay word from the installed AZTCODE.BIN (and its LastWriteTime), not just R.EXE. See [[aztmod-manifest-not-buildscript]].