---
name: azrael-intro-poem
description: "The story intro (MOV\\INTRO.MOV, the poem) rebuilt as VECTOR text (2026-10-16): measured from TensorPix's upscale (text, layout, per-phrase fade curves), set in Centaur (cards 1-4) + Garamond (card 5), rendered + encoded 1600x1200 with the original narration. art\\intro-poem\\scene.json; tools\\Build-IntroPoem.ps1 + IntroPoem.cs."
metadata:
  type: project
---

Josh, 2026-10-16: the TensorPix upscale of the poem was "troublesome" (soft, artefacts: card 4's "thief" broken up);
"extract the design and text ... a vector based version ... so it is crisp on all screens". The text exists NOWHERE as
text (searched the whole disc + game folder): only as pictures in the movie.

**The poem** -- five cards (12 fps, frames from the dark gaps): 25-190, 196-329, 339-443, 451-554, 564-661. Text in
`art\intro-poem\scene.json` (`**bold**`, `_italic_`). Typefaces: cards 1-4 a Venetian serif (slanted e-bar -- the video
reads "thc", "scc"): **Centaur** (installed with Office) matches; card 5 **Garamond Bold**.

**Pipeline** (`tools\Build-IntroPoem.ps1`, `tools\IntroPoem.cs`):
- `-Measure`: one pass over the MP4 (2400x1120, 685 frames): per phrase, inside its scene rect, the ink box + BASELINE on
  its card's fullest frame (last row with >= 45% of the busiest row's ink: descenders don't move it), and its brightness on
  every frame -> fade curve (base = quietest tenth, / peak, 3-frame average, < 4% = dark), ONLY within its card's window
  (a later card's text in the same spot is not this phrase). Size = typeset ink width == measured (fit "height" for a lone
  `"` or `?`, placed by ink TOP). -> `scene.measured.json`.
- `-Preview N`: video / vector / OVERLAY (video red, vector green: yellow = agree) -- %TEMP%\intro-poem-preview.
- `-Render -Encode`: 682 frames (685 -> 682 by position) at 1600x1200, the strip centred (oy 226.7), white 240; encode
  `Convert-ToAnim -InDir -Ref <1024 original> -Width 1600 -Height 1200` = the original narration + count. 24 s render,
  6.8 min encode, EXACT round-trip, 11.8 MB (vs 34 MB for the upscale).
- Phrases, not words: splitting the soft upscale into words failed (letters touch the next word); phrase rects + the
  font's own spacing match within a few px (overlay checked on cards 1, 4, 5).
- Installed: `game\GAME\MOV\INTRO.MOV`. The full-width upscale is `sources\video\fullscreen\MOV\INTRO.MOV`, the 1024
  original `sources\video\movies-1024-backup\MOV\INTRO.MOV`. A native build can draw scene.measured.json live.
- Traps: `LoadAnim.ps1` is the ONE loader of Mp4Reader/Anim/encoder (Add-Type it separately = "type already exists");
  `$out` vs `-Out` (case-insensitive); `New-Object T(a, b * c)` comma trap -> use `[T]::new(...)`.

## The movies, full width (same day)
All 13 movies re-encoded from their own .MOV (`Convert-ToAnim -FromMov -Width 1600 -Height <h*1600/1024, multiple of 4>`
-- the codec writes 4x4 blocks: OUTRO1 736, not 738), palette kept, EXACT round trips; 4 encodes at once, 21.5 min.
0.62 -> 1.32 GB. Wide ones letterboxed by the player's centring. 1024 versions: `sources\video\movies-1024-backup`.