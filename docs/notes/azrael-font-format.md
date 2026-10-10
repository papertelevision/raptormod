---
name: azrael-font-format
description: "Azrael's bitmap fonts are 139 variable-width glyphs in one PCX strip, so a better font is a pure art swap with no layout risk."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-10-03T15:22:34.276Z
---

## THE LOG FONT IS GENERATED AGAIN AT 1600x1200 (2026-10-03)

`$LOG_FONT_STOCK` had been `$true` since the 1024x768 era, so **AztMod shipped no font
replacement at all** — the story log ran on Mindscape's 1380x12 sheet. That was the right
call then and became wrong silently: `$HS` went 1.6 -> 2.5, the panel and the log recess
grew 56%, the text did not, and Josh reported "the interface text is far too small now".

**The old verdict was about SIZE, not about generated fonts.** Every failure recorded
against the generated sheet — speckle, muddy mid-tones, black stems at two levels — was
measured on a 12-row render. Anti-aliased glyphs get BETTER as they grow, so at 24 rows
six levels is comfortable where four was not.

### Choosing the size: it costs characters per line

The renderer takes **wrap width from the surface** and **line height from the sheet**
(0x39255), and `$TEXTBOX_W = $RECESS_W` = 287 px at 1600x1200. Measured by generating
each size and dividing sheet width by the 139 glyphs:

| rows | avg advance | chars per line in 287 px |
|---|---|---|
| 12 (stock) | 9.9 | ~29 |
| 19 | 10.5 | ~27 |
| **24 (chosen)** | **12.4** | **~23** |
| 30 = Hi(12) | 14.9 | ~19 |

So the principled `Hi()` scale reads as cramped prose. 24 is double the stock height —
an unmistakable fix — and still holds a sensible line.

### Only two sheets exist to generate, and the handshake is asserted

`Build-Font` writes **RUSGLD2** (gold narration, 24 of HudPrint's 43 call sites) and
**GENBLU2** (cyan, the conversation line) and nothing else — it never touches FONT.PCX
(stock 1932x15), INVFONT or the other coloured variants. The ramp stays restricted to
indices **1..56**; gold comes out 54,26,22,14,56,56 and cyan 54,19,9,3,55,55.

`$LOG_FONT_ROWS`/`$LOG_FONT_EM` in Build-AztMod must match `$logRows`/`$logEm` in
`src\Build-Art.ps1`, and **Build-AztMod asserts the generated sheet's height** — because
the engine reads line height off the sheet, so a stale sheet does not look broken, it
silently re-wraps the whole log at the wrong leading. Read that height straight from the
PCX header (`ymax-ymin+1` at offsets 10/6): the check runs before Build-AztMod Add-Types
PcxTool, and `[LeTool.Pcx]` there fails with "Unable to find type".

`StLoadFont` at **`0x38AB8`** — `fopen(name,"rb")`, reads a 0x80-byte PCX header,
derives w/h from xmin/xmax/ymin/ymax. The font object it builds:

| off | meaning |
|---|---|
| +0 | first char, hard-coded `0x21` (`'!'`) at `0x38C05` |
| +1 | count, hard-coded `0x8B` = **139** at `0x38C12` |
| +2 | surface pointer |
| +6 | glyph table, 4 bytes per glyph |

So a sheet covers **0x21..0xAB** — ASCII plus the CP437 accented set. **SPACE is
not in the sheet**; the renderer gives it a fixed advance.

Glyphs are **variable width, delimited by fully-blank columns**. `0x38C42..0x38D16`
walks the strip testing each column against every row and records 139 runs.
`0x38A80` is that column test on its own. Verified: RUSGLD2, GENBLU2 and INVFONT
each scan to exactly 139 runs. (FONT.PCX and SMALLFON.PCX scan to 137, so the
game would mis-index them — they are not used for body text.)

**Line height = the PCX height**, read off the font surface by the renderer at
`0x39255`. **Wrap width = the target surface's width**, read at `0x3924A`.

Which is the whole point: **a better font is a pure art swap.** Keep 139 glyphs
and the game re-measures every advance itself, so nothing using that font can go
out of layout. `Build-Font.ps1` generates sheets this way.

## Palette — the trap

Index 0 is the transparency key. Every other index is looked up in the **current**
palette (PALETTE.PCX), *not* in the font PCX's own palette. So a sheet is only
usable if its indices mean the right thing there:

| sheet | cell | inks | verdict |
|---|---|---|---|
| RUSGLD2 | 15x12 | 54 (#000000 shadow) + 56 (#F8B018 gold) | what the story log uses |
| GENBLU2 | 15x12 | 54 + 55 (#BCF8FC cyan) | ditto |
| RUSBLU2 / RUSYEL / RUSBLU | 18x14 | one ink: 53 = **#080000**, or 1 = #CCBCA4 | **unusable** — 53 is all but invisible |
| FONT / RUS14 | 21x15 | 55, 202, 251, 252, 255 | 202+ read as #000000 in PALETTE.PCX |

Indices **200+ are scene-driven and read as black in PALETTE.PCX**, so only the
low region (1..199) is safe to author against. I recommended the 18x14 family to
the user on cell size alone before checking this, and had to walk it back.

PALETTE.PCX *is* the live palette — HUDOFF.PCX's own palette matches it entry for
entry. PAL.PCX is something else and is not it.

## Generating a sheet — the three things that bit me

1. **Only bridge INTERIOR blank columns.** Walking every column and marking the
   bottom row left 22 detached specks on the baseline (stock sheets have zero),
   which showed in game as dots behind the text. Bridge strictly between a
   glyph's first and last inked column, and put the mark on the same row as the
   ink to its left so it attaches to a stroke.
2. **`AntiAliasGridFit` goes binary at small sizes** — at 10px it produced only
   two indices, i.e. an aliased font. Use plain `AntiAlias` to keep tonal
   coverage; that is where the "high-res" look comes from.
3. **Do not let a ramp pick an arbitrary nearest palette entry for the faintest
   level.** There is no dark cyan here, so the blue font's 25% level snapped to
   index 23 = #384838, a muddy teal-green sprayed round every glyph. Pin the
   faintest level to the shadow index (54) — it reads as an outline and can only
   use an index the stock sheets prove is safe.

Sizing: an 11px face needs ~13 rows to fit ascender, descender and the +1 shadow;
in a 12-row sheet the descenders and `_` clip. **10px in a 12-row sheet** fits
cleanly — verified `g`/`y`/`p` reach row 11 while `x` stops at 10.

## The story / message log

Object at **`0x1521AC`**, created by `0x38FE4(eax=0, edx=width, ebx=height)` at
`0x10D16`. Watcom hoists both immediates far above the call and lets them survive
two intervening StLoadFont calls (which push/pop ebx and edx), so the `mov`s are
**not** adjacent: `0x10CF1 mov ebx,0xCE` = height 206, `0x10D05 mov edx,0xAA` =
width 170. Same trick as the nbut creates.

`HudPrint` = **`0x39080`** `(eax=box, edx=font, ebx=string)` — it appends
`\x01<font ptr><string>` to the object's buffer, so the font is *per line, in the
text stream*, and `0x39120` re-renders. Every call site targets `[0x1521AC]` with
either `[0x152178]` (rusgld2) or `[0x15217C]` (genblu2).

Drawn into the view surface `0x152150` at view-relative (381, 35) — patch
`view-text-x-14F92`. **Not** to be confused with `0x152120`, which is 206x170 and
holds the `SAVE%02d.pcx` thumbnail; I chased that for a while because its create
sits right next to the log's.

See [[azrael-hud-widgets]] and [[aztmod-patch-framework]].
