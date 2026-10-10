---
name: azrael-hud-reskin
description: "The HUD reskin pipeline — Build-HudSkin.ps1 and Build-HudButtons.ps1 convert a modern render into the game's art, and the ARTWORK drives the engine's coordinates."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-21T19:36:26.230Z
---

Started 2026-09-21. A 24-bit render (ChatGPT) becomes the game's 8-bit HUD:

```
design\incoming\panel-pair.png       lit + unlit panels, real alpha
design\incoming\verbs.png            TAKE/USE/PUSH, 3 rows x off/on, has alpha
design\incoming\arrows-on-white.png  up/down, 2 rows x off/on, NO alpha
      |
src\Build-HudSkin.ps1     -> HUD3.PCX, HUDOFF.PCX, HUDBOT.RES, MAPBKGRD.PCX,
                             art\hud-layout.json
src\Build-HudButtons.ps1  -> NBUT{0,1,2}{ON,OFF}.PCX, arrows baked into HUD3/HUDOFF
tools\Quantize.cs         -> Resample / MedianCut / Map / MatteBorder / Blobs
```

**THE ARTWORK WINS.** The old code derived widget positions by scaling the stock
layout. With a reskin that is backwards: `Build-HudSkin` measures the eight
`#FF00FF` registration blocks out of the render, writes them to
`art\hud-layout.json`, and `Build-AztMod.ps1` overrides `$MAP_*`, `$BAR_*`,
`$SCAN_*` and the nbut anchors/sizes from it. Regions are identified by **shape**
(scan = biggest on the right, gauge = wide and short, controls = narrowest),
never by discovery order, so a re-render cannot silently swap two of them.

**Ask the renderer for registration blocks.** Flat `#FF00FF` where the engine
draws, used nowhere else. Then mask them in TWO passes: tight -> forced to index
0; tight dilated 3px -> excluded from the palette vote only. A single tight mask
let six half-magenta entries win palette slots (`#3C0141`, `#6B046F`, `#8D0494`),
because a 2.5:1 downscale smears the blocks' antialiased edges into a purple
ring. That is ~10 of 53 colours.

**Fitting.** Source body rows -> exactly `$PanelH`; the bleed scales with it and
the width is set by the screen, so the art ends ~10% vertically stretched. Far
less than the 0.685-vs-1.25 squash the old scaled art suffered.

**WHAT THE PANEL CONTROLS ACTUALLY ARE** (established 2026-09-21, after two wrong
guesses):

* the two NARROW stacked regions (15x29) are the **inventory sort arrows**
* `NBUT0` / `NBUT1` / `NBUT2` are **mode toggles, not contextual verbs** —
  TAKE/USE/PUSH was a guess and it was wrong. Confirmed by the user, who plays
  it: **NBUT0 = SCAN** (level with the top arrow), **NBUT1 = MAP** (level with
  the bottom one), **NBUT2 = the system menu**, i.e. the same thing the Q key
  opens. Icons beat words at 41x23 — a text version was rendered first and was
  barely legible in play.
* the **REPLAY button** (play the last line of dialogue again) is NONE of those.
  It is the "inline panel control" at `0x15770` / `0x15A6D`, drawn from seven
  frames of its own art — `0x15745` formats `"REPLAY%d.PCX"` with
  `[0x152AEE]>>16`.

**A SCALED POSITION WITH AN UNSCALED SPRITE OVERFLOWS.** `To-PanelY` squashes a
stock y by the panel's 0.685 factor, but `REPLAY*.PCX` stays 86x43. Stock fitted
exactly (437 + 43 = 480, the bottom of a 480-line screen); scaled it became
571 + 43 = 614 on a 600-line one — fourteen rows off the end of the framebuffer.
The replay button is now placed from the readout rect minus the sprite size, with
the fit asserted. **Check every unscaled sprite whose position is scaled.**

**Gotchas that each cost a round:**

* `NBUT*.PCX` carry **no embedded palette** — `Pcx.Palette` is null. Render them
  through HUD3's. And they are not labelled buttons in stock: they are blank oval
  lamps with an unlit/lit pair.
* The two narrow CTRL regions are **artwork, not sprites** — the game only draws
  a hover highlight over them. Arrows get baked into HUD3/HUDOFF; there is no lit
  state to use.
* `hud-layout.json` stores **y panel-local but x absolute**. Compositing with the
  raw y put both arrows at screen row 13, up in the backdrop.
* **Never let a PowerShell helper return a collection.** `return $hashtable` came
  back as `Object[]` (poisoning every index expression with "op_Subtraction on
  Object[]"), and `return ,$array` survived only until the caller's `@()`
  re-wrapped it — six sprites reported as one. Keep it linear; put real loops in
  `Quantize.cs`.
* `$g`/`$G` collided **again** (Graphics vs game dir). PowerShell variable
  collisions have now cost four rounds here. The worst was `foreach ($h in ...)`
  inside `for ($h = 0; $h -lt $count; $h++)` — binding a hashtable to the
  enclosing loop's counter, which failed far away with "the '++' operator works
  only on numbers". **Before adding a loop variable, grep the enclosing block
  for that name.**

**THE CLICK REGIONS ARE A SEPARATE JOB FROM THE DRAWING.** Moving the draw
coordinates leaves every control clicking in its old place. The hot-spot polygon
transform has rules keyed to the STOCK layout (`To-PanelX/Y`, the housing shift),
so a reskin needs `$script:SKIN_HOT`: stock bounding box -> artwork rect, matched
exactly and mapped bbox-to-bbox so the 4/6/7/9-point outlines keep their shape.
Count matches **per region, not in total** — the menu button's polygon appears on
four screens (screen 0 plus all three fold-outs, since the panel stays visible
while the menu is open and the same button closes it), and every copy must move.
* Background mattes: flood inward from the border, and test **neutrality** as
  well as brightness (channels within ~14). The render's white is a vignette from
  203 to 255, and bone lettering is nearly as bright as the background.

See [[azrael-palette-budget]] for the 53-colour ceiling and [[azrael-hud-overlay-res]]
for HUDBOT/HUDTOP's differing trailers.

## On THIS box, Apply-AztMod does NOT regenerate art

`Apply-AztMod` line ~279: `if (-not (Test-Path $artDir) ...)` -- the whole art-generation block
is skipped when `AztMod\art\` already exists, which it does here. A redistributable build has
no `art\` and rebuilds everything from the player's own files; a developer box uses the
prebuilt folder as the source of truth.

**So editing a generator (Build-HudTop, Build-HudOverlay, Build-HudArt...) changes NOTHING on
its own.** Run it by hand with `-OutDir .\art` and the geometry from the manifest
(`art.viewW/viewH/screenW/cornerRadius`), THEN install. Same shape as the
manifest-not-buildscript trap: the thing that ships is not the thing you edited.

`Copy-Item` preserves LastWriteTime, so a stale timestamp on the installed file is the giveaway
-- the install log still says `art HUDTOP.RES` because it copied, it just copied the old one.