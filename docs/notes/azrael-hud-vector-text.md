---
name: azrael-hud-vector-text
description: "HUD log + inventory text redrawn in Verdana at display res by the Panel: the log is DECODED back out of the game's text surface (no text history exists in memory), inventory names read from its list. Built 2026-10-09, offline-tested, not yet seen in game."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-10T01:16:41.893Z
---

Josh (2026-10-09): the log (right) and inventory (left) text are "too hard to read". He wants "crisp, legible fonts with consistent linespacing", the visor's vector approach. Chosen in chat: Verdana (the face the game's sheets come from), gold + cyan kept, same size, so the game's own line layout stays and conversation clicks keep working.

- **RE:** `AztMod\docs\text-render-RE.md`, from a subagent's static analysis.
  - **The log buffer is NOT a history.** Each line's bytes are freed once drawn; in conversations the text is drawn inside HudPrint and never sits in memory. The scrollback exists only as pixels in the log surface `[[0x1521AC]+0]` (438x678 in the mod).
  - A comment in Build-AztMod saying "ever-growing buffer" is wrong.
- **Approach B (chosen over hooking HudPrint): decode the surface.**
  - Every glyph is an exact copy of its sheet columns (index 0 transparent).
  - `HudDecoder.Line` reads one line as a fewest-glyphs left-to-right path. Blank columns are passed over; inked columns must match a glyph exactly in rows 0..H-2.
  - The LAST ROW is ignored: the stock scroll (0x39281) moves one row short, so every line's last row is stale. That also means `_` cannot be decoded (it only has ink in that row).
  - Gold and cyan sheets use different indices, so the font comes out of the match.
  - Lines sit at the cursor's y (`word [obj+6]`) ± k x 21.
  - Offline: 7/7 lines and 278/278 glyphs, with stale rows simulated (scratchpad `hudtext-decode-test.ps1`).
- **Panel (Panel.cs, end of file: HudFont / HudRun / HudDecoder; Panel.LogHost / InvHost):**
  - **Fonts:** read live (font +2 sheet surface, +6 table of 139 {start, end}).
  - **Which surface row is at the recess top:** the mod's window maths, `first = (H - recessH) - min(aztLogScroll, H - recessH)`; mid-scroll conversation lists use `[0x152B32] - 2`.
  - That row is VERIFIED against the screen (surface main ink vs bright non-background screen pixels, >= 80%). Otherwise it searches every offset, else falls back to the game's pixels (`TextFallbacks`).
  - **Drawing:** each line becomes a cached image (`LineImage`: Verdana em 17.5 x scale, baseline from the sheet's 'x', squeezed to the game's width, soft dark outline). Compose 3.4 ms vs 5.3 ms for the game's pixels. Runs that don't decode are drawn as the game's pixels.
  - **Inventory:** widget 0x163A40 (top +0x12, count +0x14, ids +0x16, char* names +0x7A, vel +0x144, marked +0x148), pitch word 0x14747A. Ink is dark sepia `InvInk 0x2A1C0E`; the font's full ink is its darkest. While scrolling it shows the game's pixels, and the eye icon is always the game's pixels.
- **Watcher:** wires the addresses (obj2 + d2) and logs `hud text: ...` with a decoded sample when the state changes. `-NoHostText` turns it off.
  - Offline end-to-end: scratchpad `hudtext-panel-test.ps1`, which runs a fake guest in **32-bit** PowerShell.
- **First in-game session (17:23): it NEVER showed.** watch.log had "does not line up (best 6% at row 580)": the game's text sits ~24 px IN from the recess's left edge (box padding), and the check assumed 0.
  - Fixed: `Search()` finds rows by the ink-per-row profile, then dx by the ink-per-column profile (±64 px), then verifies with Agree. `_lastFirst`/`_lastDx` are reused.
  - Offline test now shifts the screen text +24 and finds it at 100%. **LESSON: test the mapping against a deliberately offset screen.**
- **Josh round 2 (same day):**
  - "the SAME font as in the visor": **Consolas Bold**, em 17.5.
  - "line breaks too wide": `BlankLine` 0.4. Empty lines between paragraphs take 40% of a line. The layout is anchored at the box's bottom line and closes up upward. Not in conversations (option clicks); not when a run fell back to pixels.
  - LINES FLOW in Consolas's own spacing from the game's first word, with each game gap as round(gap / floor(2h/7)) spaces. Squeezing each word into its Verdana width made narrow words look pinched.
  - A line that would overrun the box (from the text's dx to TextRight 6 px short of the edge) is narrowed evenly.
- **Round 3 (2026-10-10), the host's OWN LAYOUT (`Panel.LogOwn`):**
  - Josh: the top line showed cut off under the frame; he wanted top padding, the same padding open, the log "tightened up" and better wheel scrolling.
  - CAUSE: the game's box (wide.json recessClosed/Open) is NOT the recess the art shows. The art's dark area is 8 px higher, 16 px lower and 25 px further left. It was measured off panel-off / panel-exp: closed (1039.2, 998.1, 472.4x117.2), open (1038.2, 531.0, 468.1x582.8). These are `LogBoxClosed/Open`, set by the watcher; a wide.json `textArea.box` overrides them.
  - Outside conversations the host now lays out the whole surface history itself. It ignores the game's scroll word and drops the Agree check, which was failing hundreds of times a session.
    - LogPadX is 22 game px each side. Top and bottom padding is (117 - 4x21)/2 = 16.5, so the closed box shows exactly 4 lines.
    - The top line always sits whole at the padding; the slack goes below the newest line.
    - Wheel, arrows and Step all go through `_logWant`: whole text lines, blank lines skipped, eased (LogScrollSeconds 0.07). The wheel moves a fifth of the visible lines per notch.
    - A view scrolled back stays on its lines as new text arrives (`Remap` matches runs of up to 3 line strings).
    - At rest only whole lines draw, so no slivers show at the padding.
  - Conversations keep the old game-placed path, because option clicks depend on it. The watcher switch `-NoLogLayout` brings back the old placement.
  - Offline test: scratchpad `hudlog-test.ps1 -Case 0|1`, a fake guest in 32-bit PowerShell. TRAP: `$st` IS `$ST` (it clobbered the stride).
- **To check after Josh's first session:** the `hud text:` lines in watch.log (state, sample, fallbacks); whether conversation lists line up mid-scroll; whether the space advance and baseline look right.

Related: [[azrael-story-log-scrollback]], [[azrael-font-format]], [[azrael-hud-new]], [[azrael-conversation-ui]].
