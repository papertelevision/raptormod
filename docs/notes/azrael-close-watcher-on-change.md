---
name: azrael-close-watcher-on-change
description: "Whenever Watch-HostRender.ps1 (or the overlay it reads symbols from) changes, stop every running watcher before handing back to Josh."
metadata:
  node_type: memory
  type: feedback
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-04T20:41:27.157Z
---

Any time I change `tools\Watch-HostRender.ps1` or rebuild the overlay, stop all running
watcher processes before telling Josh to test, and confirm zero remain. Josh then starts
the new one themselves.

**Why:** Josh asked for this explicitly (2026-10-04). A watcher left running holds old code
and old symbol addresses, so a test against it is not a test of the change.

**How to apply:** find them by command line (`Get-CimInstance Win32_Process` where
CommandLine matches `*Watch-HostRender*`, both powershell.exe and pwsh.exe), `Stop-Process`,
re-check the count, and say in the reply that none are running. Still never launch the game
or the watcher myself — see [[azrael-never-autolaunch]].

**Exception: if DOSBox is running, do NOT kill the watcher.** A force-killed watcher leaves the viewport frozen and the frame cap off in the live game. Check `Get-Process dosbox*` first; if the game is live, leave the watcher, say so, and ask Josh to Ctrl-C and restart it.
