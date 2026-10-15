---
name: aztmod-manifest-not-buildscript
description: "Apply-AztMod installs from AztMod.manifest.json, NOT from Build-AztMod.ps1 - editing the build script alone changes nothing."
metadata:
  node_type: memory
  type: feedback
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-09-28T19:51:29.715Z
---

**`Apply-AztMod.ps1` reads a pre-generated `AztMod.manifest.json`. It does NOT run
`Build-AztMod.ps1`.** Editing the build script and re-running the installer applies the
OLD manifest and silently ignores every change.

This wasted a long debugging session on 2026-09-28: a patch was added, `-Install` reported
success, and the bytes in R.EXE were untouched.

**The tell was there and I missed it:** the installer prints `all NNN patch sites verified`
and the count never moved. Read that number across runs — if a patch was added and the
count is unchanged, the manifest is stale.

## The correct sequence

```powershell
.\src\Build-AztMod.ps1 -OutFile <temp>.json     # regenerate
# diff against the live manifest BEFORE installing
Copy-Item <temp>.json .\AztMod.manifest.json
.\Apply-AztMod.ps1 -Install -Dest C:\Games\RaptorMod\game
```

**Always diff first.** The live manifest may predate uncommitted edits to the build script,
so regenerating can change more than intended. Compare patch NAMES and the
`fileOffset|replace` of every shared patch; a clean change shows only the patches just
added or deliberately altered, with everything else byte-identical. That check is what made
the 20 MB reserve bump safe to install.

**Assert-NoOverlap runs during generation, not installation** — so a conflicting patch is
caught only when the manifest is rebuilt. It rejected a redundant movie-centring patch that
duplicated the existing `scr-w-20D14` / `scr-h-20CF5` pair.

**The installer restores stock movies and rewrites `AZRAEL.BAT`** on every `-Install`, so
re-copy any replacement `.MOV` and re-apply the OOM redirect afterwards.

Related: [[aztmod-patch-framework]], [[azrael-vesa-mode-conflict]], [[azrael-mov-format]],
[[azrael-texture-cache-reserve]]
