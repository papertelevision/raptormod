---
name: gdi-drawimageunscaled-dpi-trap
description: "Never DrawImageUnscaled in the host's windows: it scales by the bitmap's stored DPI, which varies launch to launch (96/144) -- the loading screen drew at 2/3 off-centre. Use DrawImage with a pixel rect (Blit)."
metadata:
  type: feedback
---

`Graphics.DrawImageUnscaled(img, x, y)` draws the image at its PHYSICAL size: its stored DPI over the target Graphics' DPI. A `new Bitmap(w, h)` takes its DPI from the display context at the moment it is made. On Josh's 150% screen that is 96 one launch and 144 the next, so the same code drew the launch screen's panel at 2/3 size from its corner on some launches ("too small and a little off center to the left", 2026-10-14).

**Why:** it looked like a window-size or DPI-awareness bug and cost two wrong fixes. Only a screenshot taken by the screen itself (LoadingScreen.ShotPath) and its own size log showed the window was right and the drawing was not.

**How to apply:**
- Draw host bitmaps with `g.DrawImage(im, new Rectangle(x, y, im.Width, im.Height), 0, 0, im.Width, im.Height, GraphicsUnit.Pixel)`: the `Blit()` helpers in LoadingScreen.cs and Panel.cs.
- For an intermittent visual bug, make the thing report itself (sizes plus a screenshot) before guessing.

Related: [[azrael-loading-voice]], [[azrael-boot-text-rasteriser]].