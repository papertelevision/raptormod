---
name: azrael-book-view-black
description: Book/inventory close-up view = word [0x15257C] (StartBookViewMode); in GPU true colour the world behind it is forced black via GpuRaster.BlackView. Built 2026-10-08, not yet seen in game.
metadata:
  type: project
---

Josh (2026-10-08): reading books or viewing inventory items used to sit on black; in true colour the live room showed behind them. He wants fully black backgrounds again.

- **The flag:** word [0x15257C] (obj2; host = MemBase + addr + delta2). Only StartBookViewMode writes it (0x15C75 and 0x162F8 set it, alongside [0x152578]), and 0x164D4 clears it. Item close-ups are book views too: BOOKS\BOOKS.ZAP holds parchments (P), keys (K), shields (S), tapestries.
- **Why the world showed:** the game stops its 3D, but its viewport keeps the key colour, and the host paints its live 3D wherever it sees key.
- **Fix:** GpuRaster.BlackView, the compose uniform uBlack, sets pic = 0 before every use. So black shows wherever the host's 3D would (key pixels, beyond the game's picture, under the panel); the game's own drawings are untouched. The watcher reads [0x15257C] every frame in Step-TrueColour and logs 'book/item view opened/closed'.
- GPU only; the CPU/F9 and retro paths are unchanged (Josh: retro is done).
- **PAGE IN FRONT OF THE PANEL (2026-10-08, Josh: pages were "hidden behind the ui"):** the overlay only composes the game's VIEW rows (49..976); rows 977+ belong to the Panel window, which drew its art over the page's bottom.
  - Panel.BookView (set from the same flag by the watcher) makes the Panel compose ComposeBook instead of its art: clear above game row PanelTop (977), black below it, plus the page pixels.
  - Which pixels are page comes from the PAGE SURFACE, the struct at obj2 0x152580: {u16 w, u16 h, u32 pixels}, host = GuestPtr(pixels). The game clears it to 0 (0x37FC8 = memset) before loading a page, and page pixels are palette 128..255 (0x1648C loads the page's DAC 0x80..0xFF), so nonzero = page. Its rows 977+ are re-read every 250 ms (pages turn).
  - Panel keys are not clickable in book view. Verified offline with a synthetic screen (no HUD pixels, page aligned); not yet seen in game.
- Verified: Test-GpuLook -BlackView gives 0 non-black pixels against a key-only screen (52,500 without it).
- This is NOT the 'never hold 0x15257C' rule in [[azrael-viewport-paint-not-suppress]]: that was the HOST writing the flag. Here it is only read.

**BAND ACROSS THE PAGE (2026-10-11, Josh: "still being cut off by some portions of the bottom UI's shape toward the bottom").**
- The view's compose leaves out the game's drawings from the panel's bleed row (`OwnFromRow` = wide.json bleedTop = 948, HideFromRow), while Panel.ComposeBook drew the page only from PanelTop (977). Game rows 948..976 of the page showed black: a ~29-row band (~39 px at 2562 wide).
- **FIX (Panel.cs):** ComposeBook / ReadBook start at `BookFrom` = min(OwnFromRow, PanelTop) (not above the window's Top): black plus the page surface's own pixels from the bleed row down. The view's compose still leaves those rows out, so the game's 8-bit copy of the HUD's top edge never shows beside a page.
- Watcher: the opened log box's HideRect is dropped while a page is up (the panel doesn't draw the box over a page, so no part of it may be hidden).
- Offline: scratchpad book-band-test.ps1 (32-bit). Rows 950/960/975 were clear (the compose hid them, so black on screen) and are now PAGE. Test helpers: Panel.TestBookSurface / TestBookFrom.