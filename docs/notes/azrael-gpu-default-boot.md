---
name: azrael-gpu-default-boot
description: GPU/true colour is the DEFAULT from 2026-10-07 (-Retro = the old 8-bit/CPU look); the visor boot is shown through the overlay from the staging buffer and calibration hides behind its held last frame.
metadata:
  type: project
---
Josh, 2026-10-07: "The GPU version is now the default version moving forward"; the CPU renderer becomes the "retro style" version and is not enhanced further.
- Watch-HostRender: `if (-not $Retro) { $TrueColour = $true }` right after the param block. -Retro = the old picture.
- THE BOOT: the visor boot is the game's own 8-bit animation drawn into the STAGING BUFFER (host addr = MemBase + bufGuest, W x H). While aztBootState == 1 the watcher calls Overlay.ShowGuestFrame (staging buffer -> palette tcPal32 -> laid with the compose's own maps, black at the sides and under the panel) every ~25 ms. During 'find'/'confirm' (the calibration patch frames) Overlay.HoldGuestFrame keeps the last boot frame up, so the white patch is never seen. The panel only shows once the overlay is Located, so it slides in after the boot.
- The boot's colours are HUD indices 1..53, so tcPal32 (the captured palette file) is right as long as the HUD palette is left alone (every HUD generator keeps it). NOT YET SEEN IN GAME.