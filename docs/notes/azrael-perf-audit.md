---
name: azrael-perf-audit
description: "2026-10-13 full performance audit (docs\performance-audit-2026-10-13.md): the frame is CPU/PowerShell-bound (loop start 4.8 ms, the card ~1 ms CPU-side and never timed); 16 look-identical fixes, then a second pass doing items 1-4 (early handshake + C# wait, guest snapshot, C# lights, C# card hand-over); next: pose spans, GL timer queries."
metadata:
  type: project
---

Josh (2026-10-13): "do a full performance audit on the game and see if there are ways to optimize all aspects. You can make changes where obvious, but also provide a report". Full report: `docs\performance-audit-2026-10-13.md`.

**Where a 17 ms CORICORI frame goes (~58 fps; guest ~120 fps):**
| Bucket | ms |
|---|---|
| Loop start (PowerShell) | 4.8 |
| Waiting for the game: host lining up with the guest's copies, NOT DOSBox pacing | 2-3 |
| Hand-over: mostly script; present 0.7-1.1 with two wglMakeCurrent | ~3 |
| Before the room (script) | 2 |
| Pose: ~300 small reads | 1.6 |
| Other | 1.2 |

- **The card:** ~1 ms of CPU-side submission. The GPU's own time has NEVER been measured: add GL_TIME_ELAPSED queries before any card-side work.
- **"Collecting the picture 0.9"** in the log is stale (LastFinishMs from the last boot frame).
- **Side threads:** ~35-45% of a core steady (Overlay reader 128 x 6 MB/s, Panel polling, vector cursor 1 kHz), and the Panel's full-window composes take 30-70% of a core in bursts. Josh's 18:17 session ran on a 3842-wide display.

**Shipped (all look-identical; host-only, restart the watcher):**
- `ProcMem` keeps one process handle.
- `SceneGraph.Fingerprint` (C#) replaces the ~660-call script walk: a 10-30 ms hitch twice a second.
- `Get-LiveCharacters` memoised: a 10-20 ms hitch once a second.
- ShotWatch at 10 Hz; the full input history needs **-ShotLog**.
- The 0x163A34 diagnostic runs every 30th frame.
- Step-Fov writes on change only.
- Step-NpcPace at 10 Hz.
- Torch jitter uses a kept `Random`, not `Get-Random`.
- GL uniform locations cached per program (the `glGetUniformLocation` wrapper; `_uloc` is cleared in Link).
- AO skipped at view depth >= 800, where it is exactly 1.
- A light's shadow map is skipped where att == 0.
- CursorIcons: PID cached, redraw 16 ms, Sleep(6) while hidden.
- Panel: no `_ref` copy while the vector cursor is up; Sleep 16 at rest.
- VisorDamage widget at 30 fps.
- Overlay reader reuses its histogram and sample buffers.
- Title dust composited by hand.

**Second pass, same day (items 1-4 of the ranked list; restart the watcher, nothing to install):**
- **Early handshake:** with aztInjSync 0 + tcState run, `ready=1` is written right after the camera re-read (`$earlyArmed`); the end-of-frame wait and write are skipped. A frame that turns out to be sync 1 first waits for that ready to be consumed (the buffer still holds the whole key frame, so that copy is clean). `-NoEarlyReady` = the old order. Safe because AztInjBody copies every frame with sync 0 and clears ready after each copy (Build-AztMod ~6093-6186).
- **The wait is in C#:** `HostView.WaitClear` uses a high-resolution waitable timer at `PollUs` 400. It is a sleep, not a spin. MEASURED: release 0.3-0.8 ms after the clear.
- **Guest snapshot:** `HostView.SnapInit/SnapTake/SnapWord/SnapU32/SnapBytes/WriteSnap`.
  - The blocks: obj2 0x146900+0x920, 0x152138+0x9F2, 0x182D6C+0x50, 0x1841C8+4, at MemBase + the session's D2.
  - Taken at the loop top and again after the wait, beside the camera; Repaint-HeldPicture takes its own.
  - Writes go through `Write-GuestSnap` (the game now, plus the copy).
  - The hot HostLin values are computed in Invoke-Session (per attach); `$script:snapOn`/`hl*` are cleared at detach.
  - MEASURED: a word costs 4.6 us, against 109 us for the script GuestWord.
- **Lights:** `AztTool.RoomLightSet` lives in GpuRaster.cs (RoomLookWorker / Test-GpuLook / Test-GpuRaster extract Update-RoomLights and compile GpuRaster.cs). It is rebuilt when `$script:roomLights` changes reference; `CardViews` / `AimView` do the shadow views. The watcher sets `$script:lightsNoWriteBack` (tools still get `$l.Jx` copied back). BIT-IDENTICAL to the script over 500 frames with the same Random seed.
- **Card hand-over:** `FrameStep.ComposePresent` (new FrameStep.cs, watcher Add-Type list only). The glPresent check compares handle + card, not a formatted key; the hud-text regex runs only when the note changes.
- **Step-MemCore:** skips the slot-name decode while no menu, save, load or visor panel is up; SetState still runs, with names $null.
- **To judge:** watch.log "frame ... ms = waiting for the game X" should drop from 2-3 to <1, and loop start and hand-over by ~0.5-1.5 each.

**Next, ranked (see the report):**
5. Pose span reads (0.5-0.9) or background sampling (1-1.2).
6. GPU:
   - timer queries;
   - keep the context on the present window;
   - shadow multi-draw;
   - water culling and scissored copies;
   - textureGather in pcss.
7. Overlay reader paced to its consumer.
8. Panel row-limited reads and dirty-rect presents.
9. Visor notes and the scan box as card tags.

**Long term:** ~3-5 ms a frame is PowerShell itself. A C# main loop is the biggest lever left.

**Never:**
- spin on guest memory;
- cache guest POINTERS across loads;
- throttle the camera reads, jump detection, flash, lamp lag or torch flicker.

Related: [[azrael-frame-cost]], [[azrael-optimisation-pass]], [[azrael-title-menu]].