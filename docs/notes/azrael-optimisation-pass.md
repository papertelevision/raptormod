---
name: azrael-optimisation-pass
description: "2026-10-08 optimisation pass (Josh: 65-70 fps after the 4K textures): card presents straight into its own window, fog marched at half size, texture budget from RAM, 5.5 M picture. Measured costs and what is left. Not yet seen in game."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-08T21:03:09.371Z
---

Josh chose -TcMaxPixels 5500000 (set in Play-HostRender-TrueColour.cmd) and asked for an in-depth optimisation pass.

**Where a frame went** (his 16:44 log, 3.2 M picture, 13.7 ms loop):

| Part | ms |
|---|---|
| Waiting for the game (aztInjReady handshake, Sleep(1) polls) | 2.9 |
| Pose | 1.1 |
| Draw | 1.4 |
| Hand-over, of which 3.0 was FinishRead's readback | 4.8 |
| To the game | 0.7 |
| Loop start | 1.8 |
| Other | 0.9 |

The overlay thread ALSO stretched the picture on the CPU (3.9-6 ms, Parallel.For) and GDI-blitted it. The card's own work at 5.5 M was ~25 ms in CORICORI: the volumetric fog's march was ~10 of it.

**Done:**
1. **The card presents straight into a window.**
   - Overlay now has a second layered window, `GlWindow`, placed and shown in step with the GDI one. Only one shows (`GlPresent`); a window OpenGL draws into must never be GDI-drawn.
   - Tested: GL into a WS_EX_LAYERED|TRANSPARENT window from another thread shows exact colours.
   - `GpuRaster.AttachPresent(hwnd)` sets the pixel format and wglSwapIntervalEXT(0). `PresentGpu()` draws _compTex with a Catmull-Rom upscale plus the visor shading: VisorShade.CoverageFor -> R8 texture, the same k+(k>>7)/256 blend toward Color.
   - `PresentPicture(pic)` serves CPU-decorated frames: in the watcher, `$dyn` = boot Covering, scanWire.Playing or KeepCopy. Those still FinishRead, then `Overlay.DecorateOnly`, then PresentPicture.
   - The F9 CPU path, ShowGuestFrame and the 8-bit Present set `GlPresent = $false`. `-CpuPresent` = the old way throughout.
   - Offline (`Test-GpuLook -PresentTest`): 0.6 ms vs readback 2.6 + stretch 1.7 + GDI. Mean diff vs a bicubic reference 0.9/255; the visor band is exact.
2. **Fog at half size.**
   - FS_COMP gained `uPass`: 1 marches into a (W+1)/2 x (H+1)/2 RGBA16F target `{ins, L}`; 2 reads it back with a depth-aware 4-tap filter (volUp, exp(-(dd*20)^2)). The march is now the function volMarch, and volDens gives the flashlight cut.
   - CORICORI at 5.5 M: 24.7 -> 16.3 ms frame; diff vs full 0.07/255. `GpuRaster.VolHalf`, `-VolFull` to revert (watcher and Test-GpuLook).
3. **Texture budget:** `MaxTextureBytes = DefaultTextureBudget()` = RAM/8, clamped 1.5..4 GB. Josh's log showed 1,679 MB against the old fixed 1.5 GB.

**Left, measured:**
- Remaining card effects are ~1-1.5 ms each at 5.5 M: AO, relief, beam, PCSS.
- Loop start ~1.8 ms plus "other" is PowerShell overhead; only a C# loop would remove it.
- The handshake wait (~3 ms) is the DOSBox pacing rule. Left alone deliberately: tight RPM loops starve DOSBox's single thread.
- Overlay screen reads are ~124/s (ReadPauseMs 6), which is fine.

PowerShell traps hit again: `$a`/`$A` and `$x`/`$X` in throwaway scripts (case-insensitive, overwrote params/bitmaps); array-splatting a script binds positionally (use a hashtable). Related: [[azrael-frame-cost]], [[azrael-gpu-renderer]], [[azrael-josh-hires-textures]].

**Texture budget, revised (Josh 2026-10-08: 'my card has 16gigs ... dedicated'):** GpuRaster.Init now asks the driver: ATI_meminfo TEXTURE_FREE_MEMORY_ATI (0x87FC), else NVX DEDICATED_VIDMEM_NVX (0x9047). Budget = 65% of that, clamped 1.5..10 GB, else the RAM/8 rule. On the 8060S the driver reports 46.7 GB (it counts shared system memory; the registry's HardwareInformation.qwMemorySize says the carve-out is 16 GB), so the 10 GB cap decides. The watcher logs the budget on its 'THE GRAPHICS CARD DRAWS THE PICTURE' line. Josh then wanted 4K 'across the board': memory is no longer the blocker. The blocker is that the 2,426 hires files are ESRGAN upscales of 64-512 px originals (8x was already rejected), so 4096 versions would add size, not detail. Asked him what the 4K versions should come from.
