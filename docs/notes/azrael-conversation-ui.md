---
name: azrael-conversation-ui
description: "How dialogue options are drawn, clicked and skipped — the 0x59 screen-space origin that broke clicking, and the ESC skip the game already had."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-22T02:03:41.565Z
---

Conversation state (2026-09-21). `[0x152B1C]` = a conversation is up,
`[0x152B28]` = a line is being spoken, `[0x152B22]` = the current option node,
`[0x152B32]` = the highlight rect's y0 (0 means draw as plain text, not a list).

## Clicking an option

`0x2D0B5` passes the RAW CURSOR Y to `0x180C0`, which walks `0x162B36[]`, a table
of per-option bottoms, and takes the first entry the cursor is above. Reached by
event 0x18 through the table at `0x2C3A0` (index = code-1, dispatched at
`0x2D0F1`); while a conversation is up `0x2C424` lets only 0x18 and 0x1A past the
early-out, so **there is no hot-region gate** — the only filter is the Y range.

**That range is why clicking was dead.** The table is built at `0x1809E` as
`textYcursor + 0x59` — SCREEN coordinates for a box whose row 0 sat at y=89 —
and `0x180EA`/`0x180F3` bound it to 89..294. AztMod's recess is at 387..582, so
every click fell outside and nothing was selectable.

AztMod keeps the table in the TEXT SURFACE's own rows (the `+0x59` becomes `+0`,
bounds become 0..315) and converts at CLICK time in `AztConvHit`, because the
table is built when the options print and read when the player clicks — the
scroll offset can change in between, and rebasing the constants would silently
pick the wrong line. A conversation always forces the box open, so it measures
against `$RECESS_Y_BIG` / `$RECESS_H_BIG` and repeats AztBoxWindow's clamp.

## Skipping a line — THE GAME ALREADY HAD THIS, ON ESC

In the key handler (`0x12B88`, ebx = event record, ascii at +6):

```
0x12D41  cmp word [0x152B28], 0   ; not speaking -> normal keys at 0x12F24
0x12D4F  cmp byte [ebx+5], 1      ; key-down
0x12D5E  cmp eax, 0x1B            ; ESC, and only ESC
0x12D67  call 0x17C08             ; end the line early
```

`0x17C08` is the NATURAL end-of-speech routine — `0x13B35` polls the channel with
`0x321B4` each frame and calls it when the sample stops. It clears the speaking
flag, releases the channel via `0x31C11`/`0x3231F` and redraws the option list,
so an early call cannot leave the conversation half-advanced. Every other key
while speaking already falls to `0x12F2F` and is swallowed, which is why Space
was free. `skip-space-12D5E` jumps to `AztSkipKey` in the clock blob (two values
will not fit in the 9 bytes in place) and keeps ESC.

Also here: `0x17C79` is the REPLAY button (event 0x1A), not a skip.

## The log fonts may only use palette indices 1..56

`Build-Font`'s `Nearest-Index` searched 1..199, and the anti-aliasing mid-tones
landed on 65/104/114/119 (gold) and 19/76/78/80 (blue) — scene-palette slots that
change per room, so a third of every glyph drew in whatever colour that room held.
Against the box's flat index-2 recess that reads as **dots peppered through the
text, in columns beside the stems**. 54/55/56 are safe because the stock sheets
use exactly those.

**Do NOT fix it by dropping to two levels.** That pins every partial-coverage
pixel to the shadow; at this size most of a Verdana stem IS partial coverage, so
the glyphs go black and the text becomes illegible. Stock gets away with two
colours because its strokes are solid 3px bitmap, not an anti-aliased outline.
The fix is `-Hi 56` on the ramp search, level count unchanged.

Related: [[azrael-story-log-scrollback]], [[azrael-palette-budget]],
[[azrael-texture-cache-reserve]]
