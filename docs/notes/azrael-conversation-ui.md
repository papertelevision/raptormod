---
name: azrael-conversation-ui
description: "How dialogue options are drawn, clicked and skipped; the red lock brackets removed (0x155DC); the log box opens once the options print (aztConvBox latch); the visor's amber recording cue (ConvTag)."
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

**Space guard (2026-10-11):** RaptorMod's Space skip shares the key with the game's weapon toggle (0x136D8 -> 0x131E1), so a Space just after a line drew the weapon. The watcher's SpaceGuard (tools\Keys.cs) holds Space back for 1 s after any line ends; see [[azrael-vector-cursors]]. The overlay had no room for a game-side guard.

## The conversation's look (Josh, 2026-10-13)
"there is a red glow that appears in the 4:3 aspect from the original game. I want that removed. Instead ... a subtle amber glow that is on the outside edge of the visor anytime the character is engaged with a npc dialogue. Then a small soundwave icon at the bottom left of the visor, with small text beneath: Conversation recording engaged..." Plus: the log box stood open and blank through the NPC's first line. **Installed 2026-10-13, not yet seen in game.**

**The red glow = the game's "input locked" corner brackets.**
- The main loop (0x16043) at 0x155BC: while `[0x14721A]` (a modal: the conversation opener 0x17E52 sets it at 0x17EE7, 0x17FAA clears it) or `[0x1471F0]` (a script lock) is set, it draws 4 corner brackets (8 lines, 0x3847C, palette **127** = 247,20,0) on every other frame (phase word 0x152108, toggled at 0x156B2).
- Stock they were 20 px. The view patches (view-w1/h1-*) widened their ENDS but not their starts (531, 261), so in the mod they were long red lines along the view's edges, blinking at frame rate.
- **Removed:** manifest patch `no-lock-brackets-155DC` (`$ENABLE_NO_LOCK_BRACKETS`): `jz 0x156B2` -> `nop; jmp 0x156B2`. No fixups there. The toggle still runs; nothing else reads 0x152108. This removes them in every locked state (cutscene locks too), on purpose.
- Not the cause (checked): the conversation opener / StartConversation draw nothing; no palette write is tied to conversations; nothing red in the host follows a conversation (VisorDamage is health-only).
- 0x1554A draws two GOLD brackets (0x38) while `[0x14722C]` is set: a key toggles that flag. Left alone.

**The log box waits for the options** (`$ENABLE_CONV_BOX_LATCH`, overlay `AztConvBoxZ`, data `aztConvBox`).
- Why it opened early: the box opened on `[0x152B1C]`, but the list builder **0x17FF6 defers while a line is spoken** (sets the pending flag 0x152B26 and returns); 0x17C08 (end of speech) builds it.
- The latch: 0 = no conversation; 2 = one is up, box collapsed; 1 = open until it ends. The FIRST frame only arms (2): the option count 0x162B34 is only zeroed by the next build (0x18020), so it is stale then, and AztBoxPrep's BOX_CONV rewinds the log's text cursor that frame. It opens when nobody speaks, the count > 0, and `[0x1521AC]+6` (the text cursor) > 0: the list has printed.
- AztBoxWindow and the box-icon click test call it (`call; jz/jnz`, 5 bytes in place of an 8-byte cmp: the box blob went 461 -> 455 of 466). It keeps every register (the click test holds the mouse Y in eax).
- Host: `Panel.ConvBoxAddr` (the watcher sets it from the sym); `BoxOpen = aztBoxBig || aztConvBox == 1` (an older install falls back to the conversation flag).
- AztConvHit still measures against the OPEN recess: no list shows before the latch opens, so nothing can be clicked meanwhile.

**The visor's recording cue** (`tools\ScanWire.cs` ConvTag; `-NoConvCue`):
- The watcher steps it every presented frame with `[0x152B1C]` (up) and `[0x152B28]` (speaking); off while the boot covers the view.
- The edge glow: `GpuRaster.ConvGlow/ConvTime/ConvRows` -> FS_PRESENT `convGlow` (amber 1.0/0.60/0.18, ~5% of the view's height deep, corners stronger, the panel seam weaker, breathing + a slow shimmer; never on the panel). Fades in 0.7 s, out 0.9 s.
- The badge: ScanTag's plate mirrored to the lower left (x = W*0.055 - em*0.8, bottom at vr*0.86: the damage badge's spot, which a conversation never shares), in the visor amber 0xFFB040: a recording dot, a soundwave that moves with the voice (calm ripple between lines), and "Conversation recording engaged" beneath with ticking dots. Its own texture slot (`SetTag2`, unit 8), so it never fights the Scanning label.

## "Sometimes I cannot select the first option" (Josh, 2026-10-13) -- FIXED: the click region
An option click only exists if the pointer is inside **hot-spot screen 5's quad** (the old story-log quad, r0, event 0x18; the conversation opener switches to screen 5 at 0x17F21). AztConvHit/0x180C0 never see a click outside it.
- The build remapped the stock quad (414..583 x 89..294) by SCALING it through the box. That carried the stock 5-row top inset along x2.7: the quad began at y **555** while the options' row 0 (AztConvHit measures from `$RECESS_Y_BIG`) is at **541**. A click on the first option's top line -- most of a one-line option -- raised no event; just below the text it worked. Hence "sometimes". It was also 28 px past the recess's left side and 31 px short of its right.
- The stock inset was never an inset of the TEXT: the stock table's row 0 was screen y 89 (text Y + 0x59), so the quad's top WAS the text's row 0.
- **Fix:** with the log in the panel and the box toggle on, the quad is exactly the open recess: x `$RECESS_X`..+`$RECESS_W`-1, y `$RECESS_Y_BIG`..+`$RECESS_H_BIG`-1 (1064..1501 x 541..1098). Only `hotspots-screen5` changed.
- Ruled out: the pending-redraw flag 0x152B26 (0x180D9 ignores clicks while it is set) is set only while a line is spoken (0x17D72) and always cleared at its end (0x17C4D).

## Start-up static + the right margin (Josh, 2026-10-13; host only, tools\Panel.cs)
- **"//Initializing Dialogue Interface..."**: while `aztConvBox == 2` (a conversation is up, its options not printed yet: the NPC's opening line) and the box is collapsed, `Panel.InitStatic` fills the art's closed recess (LogBoxClosed) with see-through AMBER snow (StaticInk 0xFFB040 at StaticAlpha 0.4; blocks of the display's scale, interlaced, a rolling bright band, torn rows) and the words pulsing in the recording badge's AMBER (InitInk 0xFFB040, a thin dark edge, no plate behind them; dark amber and dark brown were tried first -- Josh, 2026-10-13; PulseSeconds 1.4) in the middle, now and then slipping sideways. 30 fps (StaticDue drives the compose loop), fades in 0.25 s, gone when the box opens. Watcher: `$pn.InitStaticOn` (off with -NoConvCue or -Retro).
- **The right margin**: conversation lines start at the game's place (recess + dx, ~28 px inside the ART's recess) but were fitted to the GAME's recess, which ends ~6 px short of the art's right edge. LogHost now fits them to the art's right edge minus the same left margin, and condenses every conversation line by the same factor (LineImage `condense`), so the type stays even. Narration (LogOwn) already had equal LogPadX margins.