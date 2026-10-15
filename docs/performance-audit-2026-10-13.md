# Performance audit — 2026-10-13

This audit covers the whole running mod:
- the watcher's frame loop;
- pose and hand-over;
- the side threads;
- the GPU renderer;
- the title screen.

The method:
- measured costs from `C:\Games\azrael-render\watch.log`;
- micro-benchmarks of the PowerShell and GDI+ calls involved;
- a read of every hot path.

**The rule throughout:** keep every feature and keep the look identical.

## Where a frame goes today

A typical CORICORI frame takes 17 ms, about 58 fps. The guest runs at about 115–128 fps.

| Bucket | ms | What it really is |
|---|---|---|
| Loop start | 4.8 | PowerShell: ~25 function calls a frame, ~15 one-word guest reads (each one opened and closed the process), and a twice-a-second scene fingerprint walk of ~660 script calls (10–30 ms hitches). |
| Waiting for the game | 2–3 | **Not DOSBox pacing.** The guest is twice as fast as the host. This is the host lining up with the guest's next copy, plus `Sleep(1)` overshoot. |
| Hand-over | 2.6–3.4 | Mostly script work: the memory-core and menu reads every frame, and the conversation cue's reads. Plus the present, ~0.7–1.1 ms with two GL context switches. There is **no** read-back on the steady path. "Collecting the picture 0.9" in the log is a stale value from the last boot frame. |
| Before the room | 2.0 | Script: the torch flicker (a `Get-Random` cmdlet per light per frame), the placed-light setup, the save-list guard, damage and health reads. |
| Pose | 1.6 | ~300–360 small reads a frame walking the scene graph twice, plus a once-a-second character match of ~10k script iterations (10–20 ms hitch). |
| Other | 1.2 | F-key polls, a per-frame diagnostic read through an advanced function (~0.25 ms), counters. |
| **The graphics card's work** | **~1 (CPU side)** | The logged "its draw" is CPU time spent issuing commands. **The card's own time has never been measured.** |

**Off the frame loop,** the side threads take ~35–45% of one CPU core steadily, with 30–70% bursts:

| Thread | Share of a core | Work |
|---|---|---|
| Overlay screen reader | ~14% | 6 MB read 128 times a second, while the card shows ~55 frames |
| Panel polling | 12–17% | reads 4.5 MB and compares 708 rows each pass, 3D-view rows included |
| Vector cursor | 5–8% | 1,000 passes a second, even while hidden |
| Panel full-window composes | 30–70% in bursts | 19.6 MB copied per picture, during static, health fills and log scrolls |

On this APU the CPU and iGPU share power and memory bandwidth, so this load costs frame rate too.

Josh's 18:17 session ran on a **3842-wide display**, so the Panel and the Overlay work scale up accordingly.

## Changed today

All of these keep the look and the features identical. To try them, restart the watcher (nothing to install).

| # | Change | Where | Est. saving |
|---|---|---|---|
| 1 | **One process handle, kept.** `ProcMem.Read`/`Write` opened and closed the game's process on every call (15–20 a frame). A failed call on a dead process drops the handle and reopens. | `ProcMem.cs` | 0.4–0.8 ms/frame |
| 2 | **Room-change fingerprint in C#**: `SceneGraph.Fingerprint`, the identical walk; the script version stays as a fallback. | `SceneGraph.cs`, `Get-SceneFingerprint` | 0.4–1.0 ms avg; **removes a 10–30 ms hitch twice a second** |
| 3 | **Character match memoised**: same prefixes, bones and room files return the same answer. | `Get-LiveCharacters` | 0.2–0.3 ms avg; **removes a 10–20 ms hitch once a second** |
| 4 | **Shot diagnostics at 10 Hz.** The full per-frame input history for the SHOT RECORD moves behind a new **`-ShotLog`** switch; the weapon and ammo logs stay. | `Step-ShotWatch` | ~0.4 ms |
| 5 | **Injection-destination check every 30th frame.** It is a diagnostic read through an advanced function. | main loop | ~0.25 ms |
| 6 | **FOV written when it changes**, plus twice a second in case the overlay reloads. | `Step-Fov` | ~0.1 ms |
| 7 | **NPC pace and pauses at 10 Hz.** Pauses last seconds. | `Step-NpcPace` | ~0.3 ms in rooms with `npcs` |
| 8 | **Torch flicker uses a kept `Random`**, not the `Get-Random` cmdlet per light per frame. | `Update-RoomLights` | 0.1–0.2 ms |
| 9 | **GL uniform locations asked once per program.** About 200 string-marshalled lookups a frame went to the driver. | `GpuRaster.cs` (`glGetUniformLocation` wrapper) | 0.2–0.5 ms |
| 10 | **AO skipped where it is exactly 1.0** (view depth ≥ 800). | `FS_COMP` | card time, far pixels |
| 11 | **A placed light's shadow map is not read where that light contributes nothing** (facing away, outside its cone). `att ≥ 0` and `sAmb` only rises, so the result is identical. | `FS_MAIN` | card time, roughly half the shadow work per torch |
| 12 | **Vector cursor**: own PID cached (it made a finalizable `Process` object every pass); redraw 60/s instead of 125/s, with the position still followed every pass; sleeps 6 ms while hidden instead of spinning at 1 kHz. | `CursorIcons.cs` | ~3–5% of a core |
| 13 | **Panel**: no 4.5 MB reference copy per pass while the vector cursor is up (nothing reads it); polls every 16 ms at rest instead of 10, still 4 ms while animating. | `Panel.cs` | ~5–8% of a core |
| 14 | **Vitals monitor near death: 30 redraws a second** instead of every presented frame, with two fonts made each time. | `ScanWire.cs` `VisorDamage` | 1–2 ms/frame below 25% health |
| 15 | **Overlay reader reuses its histogram and sample buffers.** It allocated about 128 times a second. | `Overlay.cs` | GC churn |
| 16 | **Title: the foreground dust is composited into a layer** when due (22 ms per pass → 1.6 ms at 40 Hz + 0.5 per pass); grail motes 10% slower as asked. | `LoadingScreen.cs` | title only |

**Expected, frame loop:** about 2–3.5 ms off the 17 ms frame, and the twice-a-second and once-a-second hitches gone. **Side threads:** roughly a quarter to a third less steady load.

**To confirm in game:** compare the `frame … ms = …` lines in `watch.log` before and after. Loop start should drop most.

## Second pass, same day: items 1–4 below are done

Host-side only. Nothing to install: restart the watcher. Every feature and the look stay as they were.

| # | Change | Where | Measured / expected |
|---|---|---|---|
| 1 | **Early frame handshake.** In steady true colour (`aztInjSync 0`, the key frame), `ready = 1` is written right after the camera re-read, not at the end of the frame. The end-of-frame wait and write are skipped for that frame. A frame that turns out to need sync 1 (calibration patch, 8-bit) first waits for the early `ready` to be consumed, then hands over the old way. **`-NoEarlyReady`** restores the old order. | main loop | expected 2–2.5 ms (the "waiting for the game" bucket) |
| 1b | **The wait is in C#**: `HostView.WaitClear` polls with a high-resolution waitable timer every 0.4 ms (`Sleep(1)` where Windows has none). It is a sleep, never a spin. | `HostView.cs` | release 0.3–0.8 ms after the clear (measured), against ~2 ms per `Sleep(1)` poll |
| 2 | **One guest snapshot per frame.** obj2 `0x146900..0x147220`, `0x152138..0x152B2A`, `0x182D6C..0x182DBC` and the player pointer `0x1841C8` are read at the top of the loop and again beside the camera after the wait. `GuestWord`, `Step-MemCore`, `Guard-SaveList`, the conversation cue, ammo, health pointer and book view all read from it. Writes go to the game at once *and* into the copy (`Write-GuestSnap`). Guest pointers are still read through every time. The hot overlay host addresses (ready, camera record, sync, frame counter, boot state, RL trap, reboot) are worked out once per attach. | `HostView.cs` (`Snap*`), watcher | a word: 109 µs → 4.6 µs (measured); one block read 4 µs; ~1–2 ms a frame |
| 3 | **Placed lights in C#**: `AztTool.RoomLightSet` (in `GpuRaster.cs`, so the offline tools that extract `Update-RoomLights` still compile). It runs the flicker, the dance, the colour cycle and GI flicker, plus the card's light views (`CardViews`). It is built when the room's light list changes and still runs every frame. Checked against the script over 500 frames with three lights and the same `Random` seed: **bit-identical**. | `GpuRaster.cs`, `Update-RoomLights`, main loop | 6 lights: 0.12 → 0.06 ms for the update (measured), plus the view loop's script |
| 4 | **Card hand-over in one C# call**: `FrameStep.ComposePresent` does `TakeSurface` → `ComposeMap` → `SetComposeMap` → `PostCompose` → read-back, or shade + `PresentGpu`. Same calls, same order, and none of the script's twelve `[ref]`s. Also: the present-window check compares the handle and the card instead of formatting a key string every frame; the HUD text note's regex runs only when the note changes. | `FrameStep.cs` (new; the watcher's Add-Type list), `Step-TrueColour` | ~0.3–0.8 ms expected |
| 4b | **`Step-MemCore` while no menu is up.** No list, no system menu, no save or load, no visor panel playing: the five slot names are not decoded (a script loop of up to 150 steps). The visor is still told everything else, so its state is exactly as before. Its reads come from the snapshot, shared with `Guard-SaveList`. | `Step-MemCore` | ~0.2–0.4 ms |

**What to look for in `watch.log`.** Compare the `frame … ms = waiting for the game … + … + hand-over … + loop start …` lines with a run from before:
- "waiting for the game" should fall from 2–3 ms to well under 1;
- "loop start" and "hand-over" should each drop by roughly 0.5–1.5 ms;
- the frame should come in around 4–6 ms shorter.

Also check the session start. It should log "frame hand-shake: the waits poll every 0.4 ms…", and on the first wait "waits use the high-resolution waitable timer". If the guest's own rate (`guest loop … fps`) falls, or the black flicker returns, try `-NoEarlyReady` first.

## Recommended next, ranked

*(Items 1–4 are done: see the second pass above.)*

Each of these keeps every feature. Estimates are per frame unless marked otherwise.

### Frame loop (largest wins)

1. **Arm the frame handshake early in true colour: 2–2.5 ms. Risk low–moderate; test in game.**
   - With `aztInjSync 0` (steady true colour) the guest copies every frame regardless and clears `ready` after each copy. So `ready` is only a pacing baton.
   - Writing `ready = 1` right after the camera read (instead of at the end of the frame) lets the guest clear it during the host's ~14 ms of work, so the next wait is a single read.
   - Pacing still holds; 8-bit and calibration modes keep today's order.
   - If a wait is still needed, move it into C# with a high-resolution waitable timer at 250–500 µs. That is not a spin, so it does not starve DOSBox.
2. **One guest snapshot per frame, plus host addresses cached per session: 1–1.5 ms. Low risk.**
   - Read three contiguous blocks once at the top of the loop:
     - obj2 `0x152138..0x152B2A`;
     - `0x146900..0x147220`;
     - `0x182D6C..0x182DBC`.
   - Serve every `GuestWord` from them: the shot, ESC and quit watches, `Guard-SaveList`, `Step-MemCore`, the conversation cue, ammo and health.
   - Compute `HostLin(Sym …)` for the ~10 overlay symbols once per session (they are ASLR'd per attach). That removes ~12 `HostLin` and ~4 `Sym` calls a frame.
   - Optionally read the overlay's own variables in one go: camera record, frame counter, ready, boot state, reboot, raptor flag, FOV. The frame counter is already inside the camera record at +4.
3. **Torch flicker and placed-light setup into C#: 0.6–0.9 ms.**
   - Pass the lights as a struct array.
   - Do not throttle them: the flicker and dancing shadows would visibly step.
4. **Hand-over script work into C#: 1–1.8 ms.**
   - Port the card branch of `Step-TrueColour` (the conversation cue, scan tag, damage and menu stepping) to one C# call.
   - Gate `Step-MemCore` to its one 0xF8-block read with an early out while no menu is up. Its own reads duplicate `Guard-SaveList`'s.
5. **Pose.**
   - (a) After a walk, merge the frame addresses into ~5–20 memory spans and read those spans per frame instead of ~300 small reads. Fall back to a full walk if a pointer leaves the spans. Saves 0.5–0.9 ms.
   - (b) Run root + walk + sample on a background thread, leaving the loop only `Evaluate`. Saves 1–1.2 ms, at moderate risk: shared static caches, root-change signalling, lift objects.
6. **F-key polls as one C# call** (`Keys.Edges`). Saves ~0.15 ms.
7. **The long-term floor.** About 3–5 ms of every frame is PowerShell itself: function-call overhead, `$script:` access, boxing. Moving the main loop body into a compiled C# class, with the script keeping setup, logging and room loading, would remove most of it. This is the biggest single lever left, but a large refactor; best done step by step via items 2–5.

### GPU (measure first)

8. **Add `GL_TIME_ELAPSED` timer queries.** Double-buffer them and read them a frame late. Put them around:
   - the shadow views;
   - the room pass;
   - the water;
   - both compose passes;
   - the present.

   Card-side savings cannot be confirmed without them, and they will matter once the CPU side is cut and the card starts to bound the frame (heavy rooms at 5.5 M pixels).
9. **Keep the GL context current on the present window: 0.2–0.6 ms.**
   - `PresentTex` calls `wglMakeCurrent` twice a frame, and each call flushes.
   - All other drawing binds its own framebuffer, so the context can stay on the present window's DC.
   - Fall back only on detach, on the CPU path or on F9. Low–medium risk.
10. **Shadow views as one multi-draw: ~0.25 ms per torch, ~1.3 ms in MINEMAZE.**
    - Each texture group is a separate draw with a uniform lookup and a texture bind, for every face of every torch: ~1,000 calls a frame in torch-heavy rooms.
    - Draw the opaque, casting groups in one `glMultiDrawArrays`. It stays depth-only in the same order, so the result is bit-identical.
11. **Water: ~0.6 ms CPU per pool plus ~1 ms card at 5.5 M.**
    - Skip pools whose box is out of view.
    - Limit the two full-size depth+stencil copies and the reflection clear to the pool's on-screen rectangle.
    - Use the depth-only program for the mirror's depth pass.
    - Share one mirror build between pools at the same height.
12. **Soft shadows: `textureGather` in `pcss` taps (~80 → ~32 reads per map).** Also skip the lamp's soft shadow where its distance fade is 0. Identical result.
13. **Depth pre-pass for `FS_MAIN`** (overdraw, possibly 30–50% of its time in heavy rooms). This changes which coplanar face wins unless the vertex order is reversed. Measure with an overdraw count first, and Josh checks rooms with decals. Medium risk.
14. **CPU-decorated frames** (boot reveal, scanner, visor notes, menus): `PresentPicture` re-uploads the 22 MB picture synchronously each frame. Use a mapped pixel-unpack buffer as `PostCompose` already does, or upload only the decorated region.

### Side threads

15. **Overlay reader paced to its consumer: ~6–8% of a core, ~350 MB/s.** Read once per frame the card takes (signal from `TakeSurface`), or simply use `ReadPauseMs` 12. The game's own drawings would lag ~8 ms more, so judge in game.
16. **Panel reads and compares only the rows in use: ~6–8% of a core.**
    - Box closed: about 260 rows instead of 708, keeping the cursor's bleed rows.
    - This also stops the 3D view's changes (hover text, the key colour during fades) from causing full recomposes.
17. **Panel dirty-rectangle presents.**
    - Compose straight into the DIB.
    - Push only the changed band with `UpdateLayeredWindowIndirect`: the log box during the start-up static, the gauge during a health fill, the recess during a log scroll.
    - This removes the 30–70% bursts. Medium risk.
18. **Visor notes and the scanner box to the card as tags**, like ScanTag and ConvTag already are (needs a third tag slot). That ends the CPU-decorated frames after each room entry, hit or scan: several ms per frame for 4–9 s. Quick part: build the scan box's Ink/Glow as premultiplied ARGB and reuse one `ImageAttributes`.
19. **Small allocations:**
    - `Raster.ViewPoint` returns a new `float[3]` per particle and mote.
    - The ScanTag and ConvTag fonts are made per render.
    - The ConvTag bar brushes.
    - The degauss clones the whole picture per frame (22 MB).
    - RoomCover fills the whole picture black every frame.
    - The Panel's `Word`/`Bytes` allocate per call.
    - The vector cursor reads the cursor and hotspot as four words; two dwords would do.

### Title screen (before play only)

20. **The face light: draw it by hand like the dust layer.** The `ImageAttributes` alpha path is ~2.6 ms per pass; a premultiplied scale-and-over into the buffer over its area is ~0.3 ms. Also stop redrawing the static menu area every pass.

## Not worth changing

- **Fog:** already marched at half size.
- **The ghost:** already half size.
- **Particle and mote uploads.**
- **Shadow maps:** redrawn every frame by necessity. Torches move their light point and the player's body casts.
- **The steady card path:** has no read-back or `glFinish`.
- **Small loops:** the SpaceGuard poll, the BootHd loop after the boot, and the boot sound mixer.
- **`glGetError` checks:** they drive the CPU fallback.

**Never do these:**
- Never spin on guest memory (DOSBox emulates on one thread).
- Never cache guest *pointers* across loads; only overlay host addresses per session.
- Never throttle the camera-record reads, the jump detection, the muzzle flash, the lamp lag or the torch flicker.
