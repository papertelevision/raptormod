---
name: azrael-raptor-docs
description: "RAPTOR DOCS on the title (2026-10-11): STORY became RAPTOR DOCS -> a panel like OPTIONS -> MANUAL (the 1996 manual typeset in the visor, <game>\\raptordocs\\manual.txt) and CLASSIFIED DOCS (the box's print-outs, arrow pads, click to magnify); BACK/Esc = main menu. tools\\RaptorDocs.cs (partial TitleScreen) + CursorShapes.cs under TITLE_GATE; Build-RaptorDocs.ps1 from C:\\Games\\azrael-gfx\\raptordocs."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-11T23:59:00.000Z
---

Josh (2026-10-11): rename the title's STORY to "Raptor Docs". It opens "just like the options menu", with "Manual" and "Classified Docs":
- the manual "in-universe for the game, but simple and sleek";
- the print-outs from the box, with "in-universe left/right arrows" and a "back" button "that will lead back to the main menu".

**Where things are**
- `tools\RaptorDocs.cs`: a `partial class TitleScreen` holding the panel, both readers, their layout, drawing and input.
  - LoadingScreen.cs only routes into it: Press / HitTest / Key / Activate, the hover, the loop's redraw, Prepare and Preview.
  - The row is `R_DOCS` (was R_STORY); the "OFFLINE // COMING SOON" row flash is gone.
- The docs live in `<game>\raptordocs` (`GameGate.TitleDocs`, set by the watcher):
  - `manual.txt`;
  - `classified.txt` (file | title | line);
  - `classified\NN.jpg`.
- **Build:** `tools\Build-RaptorDocs.ps1` writes that folder from Josh's sources:
  - `raptordocs\manual.txt` and `classified.txt` in this repo (since 2026-10-13; before that in the asset pack's gfx component);
  - the scans in `credits\*.png`.
  - Re-run it after editing either. Nothing about it is in the manifest.
- **The manual's TEXT is in this repo; the print-outs' SCANS are not** (Josh, 2026-10-13: "This repo will never go public, I'm going to have a separate distributable git for that later, so please include it ... a community patch/mod that is provided free of charge ... please omit the scans but include the text"). `raptordocs\manual.txt` and `raptordocs\classified.txt` (repo root) are what Build-RaptorDocs reads (`-TextDir`, default the repo's `raptordocs\`); the scans stay in `C:\Games\azrael-gfx\credits\` (asset pack), as does the PDF (`<game>\manual`, not redistributable). The old copies in `C:\Games\azrael-gfx\raptordocs\` are no longer read (nor packed). What goes into the later public distribution repo is decided there.

**The manual**
- **Source:** the archive.org PDF (14 spreads = 28 booklet pages, MRC images + a GlyphLessFont text layer, CID = Unicode).
  - That text layer is garbled on the noisy-paper pages ("w tight click yi your n mouse").
  - Windows' own OCR read it far better. In PS 5.1 that is `Windows.Data.Pdf` to render each half-spread at 2x (`SourceRect` and `DestinationWidth` are in DIPs: the page is 1027 x 794), then `Windows.Media.Ocr`.
  - The result was proofread against the scans, with figure callouts kept as cursor captions.
- **Dropped:** the ads, the cover, TECHNICAL SUPPORT (1996 phone numbers) and the screenshots (the old 640x480 HUD).
- **Chapters (9):** AZRAEL (a title page, centred), KNIGHTS TEMPLAR, THE RAPTORS, JOURNAL #676, PLAYER'S GUIDE, MS-2 HELMET, APPENDICES, ADDITIONAL HELP, CREDITS.
- **Markup** (in manual.txt's header): `@chapter NAME | HEADING`, `@h`, `@epigraph`, `@bullet`, `@quote`, `@mono`, `@caption`, `@warn`, `@term L | R` (`;` in R = a new line), `@icon NAME | TITLE | TEXT`, `@figicon NAME | CAPTION`, `@gap`, `@break`. Plain lines join into paragraphs.
- **Layout** scales by `_vs = min(W/1920, H/1080)`, so it is 30 pages at every screen size.
  - It is laid out on first open (tens of ms): word-wrapped with GDI+ GenericTypographic, with headings kept with their next lines and rows kept whole.
  - Pages are lists of placed items, drawn straight from them.
- **Look:** body Bahnschrift SemiLight 19.5 px (SemiBold headings; Segoe UI fallback) in pale amber `DocInk` 0xF2DDB8; Consolas for the HUD chrome.
  - Contents down the left (click to jump), the vector arrow pads and "07 / 30" below. "STOLLAND LIBRARY // ONLINE" (the journal's HUD maker).
  - A bright line runs down the column as a page comes up.
- **The cursor legend draws the in-game vector icons** (animated, as in play). The manual's names are not the files' names:
  - **Use** = the bow-tie `default`;
  - **Lever** = `use`;
  - **Shoot** = a new `shoot` shape: a sight that flashes three times. Only the docs draw it; in combat the game draws its own cursor.

**The classified files**
- **Files:** JPEG q92 at full size (4096 wide, 2.6 / 3.1 MB). Decoded and scaled on the ThreadPool at open (both files) into a Fit bitmap and a Zoom bitmap.
  - Zoom is `DocZoom` 2x the fit, capped at the scan's own size.
  - Both are drawn 1:1 (nearest, integer place), never resampled per frame.
  - "DECRYPTING FILE 01..." shows while it loads; then the page is revealed top-down behind a bright line.
- **Labels:** "RAPTOR EYES ONLY" tag (Josh renamed it from EYES ONLY; on the panel row and the reader); title and line under it from classified.txt; FILE 01 / 02.
- **Magnifying:** a click on the page magnifies it, and the pointer's height (and width, if wider) pans it. Up/Down or the wheel also pan.

**Input**
- **BACK, Esc or Backspace** in a reader go straight to the MAIN MENU, with RAPTOR DOCS selected (Josh's words).
- **Turning pages:** Left / Right / PgUp / PgDn turn pages or files. In the manual, Up / Down and the wheel do too. Home / End go to the first / last.
- **The click merge now counts from the last press that ACTED.** Counted from any press, each swallowed click renewed the 0.3 s merge, so quick clicks on an arrow turned only one page. The double-delivery guard is unchanged (scratchpad title-click-test.ps1 still passes).
- **Keys:** the polled list gained 0x25 / 0x27 / 0x21 / 0x22 / 0x24 / 0x23 / 0x08. The menu and the old panels ignore them.

**Redrawing: a reader is static unless something changes**
- The whole window is repainted only:
  - on `_vNeed` (page or file turn, hover change, loaded);
  - for 0.45 s around opening and closing.
- Otherwise only the moving rects are repainted: the arrow pads, the page's icons, and a loading / revealing / panning page.
- Measured live (960x540): 1.5-1.7 ms a pass on a still page or file.
- One 263 ms pass happened while the first scan decoded (GDI+ contention), during the DECRYPTING screen.

**Fault fence:** any exception in the docs goes to `DocsFault`, which notes it and closes the docs. The loop's own catch would close the title, which releases the game into its intro.

**THE COMPILE TRAP (TITLE_GATE).** The title (loading gate) and the renderer are separate Add-Types in one PowerShell session. Both need the cursor shapes, and PowerShell refuses a type name it has added before ("Cannot add type ... already exists"), public or internal.
- `tools\CursorShapes.cs` (split out of CursorIcons.cs; 240 frames byte-identical before and after) declares `TitleShapes` under `#if TITLE_GATE`, else `CursorShapes`.
- The watcher compiles the gate with `-CompilerParameters` (`/define:TITLE_GATE`; System.dll and System.Drawing.dll added by hand), and the main list with CursorShapes.cs before CursorIcons.cs.
- **Anything compiling LoadingScreen.cs now needs RaptorDocs.cs + CursorShapes.cs + the define.** See [[azrael-powershell-silent-traps]].

**Tests (scratchpad):**
- `docs-preview.ps1`: offline renders (`PreviewDocs` / `PreviewView` / `PreviewPage` / `PreviewZoom`), and page counts at five sizes.
- `docs-click-test.ps1`: every click and key path, duplicates and settling.
- `docs-live.ps1`: the real loop in a 960x540 corner window. Keys are queued with `TestQueueKey` and the GamePid is dead, so real input is not read. It captures the window and reads the `Passes` / `FullPasses` / `DrawMs` counters.

Not yet seen by Josh in game (2026-10-11).

Related: [[azrael-title-menu]], [[azrael-vector-cursors]], [[azrael-memory-core]].
