# HUD text (story log, conversation list, inventory list): reverse-engineering reference

Static analysis of the stock `GAME\AZRAEL\R.EXE` with the `tools\load.ps1` toolchain. A few
checks were made against the installed modded `C:\Games\RaptorMod\game\GAME\AZRAEL\R.EXE`
and against `AztMod.manifest.json` / `src\Build-AztMod.ps1`; those are labelled **[MOD]**.
Addresses are image-LINEAR (no 0x200000 load base). At runtime the game adds
`0x1F0000` to obj1 addresses and `0x1F1000` to obj2 addresses (`tools\GuestBase.ps1`).
Every POINTER read out of guest memory is already a runtime linear address: host address =
`MemBase + value`.

Confidence tags:
- **[SEEN]**: read directly in the disassembly.
- **[INFERRED]**: deduced from usage, naming or arithmetic. Not proven.
- **[MOD]**: about what AztMod changes, from the manifest, build script or installed EXE.

Nothing was run. No game file, manifest or tool was modified.

---

## 0. The short version

| What | Where | Meaning |
|---|---|---|
| story-log text object | dword `[0x1521AC]` | 0x14-byte object (s1.1). Created once at `0x10D16`. |
| log surface | `[[0x1521AC]+0]` | **This is the scrollback. History exists only as its pixels.** |
| pending text | `[[0x1521AC]+8]`, len word `+0xC` | **Only the text not yet rendered.** Consumed and freed as it renders. |
| paced flag | word `[[0x1521AC]+0x12]` | 1 = one line per frame (normal). 0 = render at once (conversation). |
| gold font (narration, options) | dword `[0x152178]` | RUSGLD2 font object |
| cyan font (highlight, descriptions) | dword `[0x15217C]` | GENBLU2 font object |
| inventory font | dword `[0x163A38]` | INVFONT font object |
| log reset | `0x3948C` | Clears the surface, x=y=0, frees pending. Runs at conversation start/end, option redraw and game load. |
| conversation up | word `0x152B1C` | |
| option list | head `[0x152B1E]`, top/current `[0x152B22]` | 10-byte nodes: +0 `char*` ("^ %s\n"), +4 word id, +6 next |
| option scroll animation | word `0x152B30` dir (-1/0/+1), word `0x152B32` px offset | 7 px per frame |
| option hit table | words `0x162B36[]`, count word `0x162B34` | bottom of each option, + 0x59 (stock) / + 0 (mod) |
| inventory list widget | `0x163A40` (a surface + list) | +0x12 top, +0x14 count, +0x16 ids[50], +0x7A `char*`[50] |
| inventory row pitch | word `0x14747A` | INVFONT sheet height + 1 |

**The big consequence for the host.** The log buffer is NOT a history. `0x39120` renders a
line, then memmoves the rest of the buffer down and reallocs it. When it reaches the end it
frees the buffer. Once text is drawn, its bytes are gone; only its pixels stay in the surface.
During a conversation the text is drawn inside `HudPrint` itself, so it is never visible in the
buffer at all. A host that only polls memory cannot be exact. See s7 for the fix.
(The comment in `Build-AztMod.ps1` saying "The log text really is an ever-growing buffer" is
wrong for the same reason. **[SEEN]**, `0x3942B..0x39458`.)

---

## 1. The log buffer (Q1)

### 1.1 The text object

Created by `0x38FE4(eax=surface or 0, edx=width, ebx=height)`. Its only caller is `0x10D16` in
the start-up routine `0x10B98`. The width and height immediates are at `0x10D05`/`0x10CF1`.
Stock size is 170x206; **[MOD]** it is 438x678 (`textbox-w`/`textbox-h`). **[SEEN]**

| off | size | field | notes |
|---|---|---|---|
| +0x00 | dword | surface ptr | surface = word w, word h, dword pixels, then the clip rect at +8 (18 bytes) |
| +0x04 | word | x cursor | where the next word goes |
| +0x06 | word | y cursor | top row of the current line. **Can equal the surface height** (s2.4) |
| +0x08 | dword | pending buffer | `NULL` when nothing is pending |
| +0x0C | word | buffer length incl. the final NUL | **stale when +8 is NULL**. The free path does not clear it (`0x3941A`) |
| +0x0E | dword | current font | font of the last `\x01` the renderer consumed. Was missing from the old notes. |
| +0x12 | word | paced flag | set to 1 by the creator (`0x3903E`) |

Creation sets y=0 (`0x3902A`) and then x = y (`0x39044`). **[MOD]** y starts at 585
(`log-cursor-start`) and x is forced to 0 (`log-cursor-x0`).

### 1.2 Record format (HudPrint `0x39080`, eax=obj, edx=font, ebx=string) **[SEEN]**

```
first call (buf NULL):  buf = malloc(strlen+6); len = strlen+6; write at buf
later calls:            buf = realloc(buf, len + strlen + 5); write at buf+len-1 (over the old NUL); len += strlen+5
record written:         0x01, <font ptr: 4 bytes LE, runtime address>, <string bytes>, 0x00
then:                   if (obj+0x12 == 0) Render(obj)      // 0x3910D
```

So the buffer is one NUL-terminated stream: `\x01 F1 text1 \x01 F2 text2 ... \0`.

**The only control byte is `\x01` + font pointer.** There are no colour codes. Colour is the
font: compare the record's pointer with the values in `[0x152178]` (gold) and `[0x15217C]`
(cyan). The renderer also acts on these bytes in the text (s2):

| byte | effect |
|---|---|
| `0x00` | end of stream |
| `0x01` | font change; the next 4 bytes are the font ptr |
| `0x0A` `\n`, `0x0D` `\r` | both are "new line". `\r\n` therefore gives TWO line breaks. |
| `0x20` | word separator, fixed advance |
| `0x21..0x7F` | glyph `c - 0x21` |
| `0x80..0xFF` | translated through the pair table at `0x14764C` first (s3.3) |
| `0x02..0x09`, `0x0B`, `0x0C`, `0x0E..0x1F` | treated as glyphs with a negative index, so garbage widths. The game never sends them. **[INFERRED]** |

The colour markers `0xFA`/`0xFB`/`0xFC` in `hudmes.dat` messages never reach the buffer.
`0x2A594` splits on them and makes one HudPrint per segment (s6.2).

### 1.3 Lifetime: consumed, not kept **[SEEN]**

- `0x39120` trims the buffer after every finished line. It memmoves the unread tail to the
  front, reallocs, and sets +0xC (`0x3942B..0x39458`). At end of stream it frees the buffer
  and sets +8 = 0 (`0x3941A..0x39422`).
- **Paced mode** (+0x12 = 1, the normal state). HudPrint only appends. The frame routine
  `0x16043` calls `Render` once per frame at `0x148B3`, gated by
  `[0x152904]==0 && [0x15257C]==0` (not dead, not in a close-up). Each call renders
  **one line**, then returns (`0x3945C`). While dead (`0x148BA..0x148E6`) it renders a line
  every second frame, through counter word `0x152906`, and only with the fold-out closed.
  In a close-up/book view nothing renders, so text queues.
  So a message of N lines comes out one line per frame. The trailing NUL needs one more
  call, which frees the buffer.
- **Immediate mode** (+0x12 = 0). Set by StartConversation `0x17E52` (`0x17F11`) and
  restored to 1 by EndConversation `0x17F2F` (`0x17F71`). HudPrint renders everything at once,
  then frees the buffer before it returns.

### 1.4 Resets: `0x3948C` **[SEEN]**

It sets y=0 and x=0, clears the surface to index 0 (`0x37FC8`), and frees any pending text.
**[MOD]** These bytes are unpatched in the installed EXE, so after a reset y = 0, not 585.

| caller | when |
|---|---|
| `0x17F07` (`0x17E52`) | conversation starts |
| `0x17F67` (`0x17F2F`) | conversation ends. It then prints "Model 7 Head Up Display\n\n\n" in gold and "Online.......\n\n" in cyan. |
| `0x1801B` (`0x17FF6`) | every redraw of the option list |
| `0x1813D` (`0x180C0`) | an option is clicked |
| `0x2CD1B`, `0x2CEB0` (`0x2CCA1`) | the load path of the save/load OK handler (`[0x152B04]=1`) |

There is no reset on room change and no size cap. The pending buffer's length is a word, so it
is limited to 64 KB, but it never comes close. **[INFERRED]** The surface is the only memory. Its
history is lost at every conversation and every load. **[MOD]** `AztBoxConv` (Build-AztMod
~l.11808) ALSO zeroes x/y, clears the surface and sets `aztLogScroll` to the open-box maximum,
on the rising edge of `[0x152B1C]`.

---

## 2. The layout algorithm, `0x39120` (Q2)

### 2.1 Exact pseudocode **[SEEN]**

Locals: word buffer `[esp+0..0x3B]` (60 bytes, so a word over ~59 chars smashes the frame),
x `[esp+0x5C]`, y `[esp+0x58]`, word width `[esp+0x54]`, flags 0x4C/0x50/0x64/0x68/0x6C.

```
Render(o):
  x = o.x; y = o.y
  if o.buf == NULL: return
  p = o.buf
LINE:
  endOfBuf = false; lineDone = false
WORD:                                         // 0x39159
  wordStart = p; word = ""; wordW = 0; nl = false; midFont = false
  wf = o.font                                 // the font this word is measured and drawn in
  loop:
    c = *p++; word += c
    if c == 0x01:
        f = *(u32*)p; p += 4; o.font = f
        if wf == NULL or word.len == 1: wf = f   // \x01 at the start of a word applies to it
        word.removeLast()
        if word.len == 0: continue               // keep scanning the same word
        midFont = true; break                    // \x01 inside a word ENDS the word (no space advance)
    if c == '\n' or c == '\r': nl = true; break
    if c == 0: lineDone = endOfBuf = true; break
    if c == ' ': break                           // space stays in `word`; it has no width
    g = (c >= 0x80) ? Translate(c) : c
    e = wf.glyphs[g - 0x21]; wordW += e.end - e.start
  if nl or lineDone: word.removeLast()           // drop \n, \r, NUL (never the space)
  lh = wf.sheet.height                           // 0x39255
  W = o.surf.w; H = o.surf.h                     // 0x3924A / 0x39279

  if x + wordW >= W:                             // 0x3924D: must be STRICTLY less to fit
      p = wordStart                              // re-read this word on the next line
      x = 0; y += lh; lineDone = true; nl = false
      // endOfBuf is NOT cleared here -> see 2.3, the last word is lost
  else:
      if y + lh > H: Scroll(o, y + lh - H); y = H - lh      // even for an EMPTY word
      DrawString(o.surf, wf, x, y, word)                    // 0x38EC8
      if terminator == ' ': x = trunc(x + lh * 2/7)         // 0x39315..0x39350
      x += wordW
      if nl and not lineDone: x = 0; y += lh; lineDone = true   // 0x3938A..0x393BC

  if not lineDone: goto WORD
  // a line ended (newline, wrap or end of stream)
  if endOfBuf: free(o.buf); o.buf = NULL                    // +0xC left stale
  else:        memmove(o.buf, p, o.len - (p - o.buf)); o.buf = realloc(...); o.len -= (p - o.buf)
  if o.paced == 0 and not endOfBuf: goto LINE
  o.x = x; o.y = y
```

`Scroll(o, d)` (`0x39281..0x392F5`):
```
memcpy(pix, pix + W*d, W*(H - d - 1))   // shift up d rows. One row short (stock bug): row H-d-1 keeps stale pixels
memset(pix + W*(H - lh), 0, W*lh)       // clear the bottom lh rows
```

### 2.2 The rules, in words

- **Break opportunities:** space, `\n`, `\r`, end of stream, and a font change in the middle of a
  word. There is **no hyphen rule.** `-` is a normal glyph, so "Auto-Map" is one word.
- **Fit test:** `x + wordWidth < surfaceWidth`. The width does not include the trailing space,
  and the space advance is added after the word even if it pushes x past W.
- **Over-long words** (wider than the surface at x=0) never fit. The renderer wraps, nothing is
  consumed, and it repeats. In immediate mode that is an endless loop. In paced mode it adds a
  blank line every frame. **[SEEN]** for the logic; no shipped string is that long **[INFERRED]**.
- **Newline:** x = 0 and y += lh. Blank lines (`\n\n`) advance a full lh each. `\r` behaves the
  same as `\n`.
- **Consecutive spaces:** each extra space is an empty "word" that still advances. Leading spaces
  and spaces inside a word ("S y s t e m  I n t e g r i t y") all count, so the start-up
  banner's indentation depends on this.
- **A line can start with a space** only when that space itself was the word that did not fit.
- **Scrolling is lazy:** after a newline at the bottom, y = H. The shift happens when the next
  word is drawn, and that includes the empty word made by the stream's trailing NUL. So in
  practice the surface scrolls as the message ends. If the start y is not a multiple of lh
  (the mod's 585), the first scroll is by less than lh.
- **The end of the stream does NOT reset x.** A message without a trailing `\n` leaves the
  cursor mid-line, and the next HudPrint continues on that line.

### 2.3 Stock quirk: the last word can vanish **[SEEN]**

The end of the stream is reached with the last word in hand. If that word does not fit on the
current line, the wrap branch rewinds `p` but leaves `endOfBuf` set, and `0x39412` frees the
buffer. The word is never drawn, but y has already advanced a line. It only happens when the
pending stream does not end in `\n`, because then the last "word" is the empty one after the
newline. Every literal HudPrint string checked ends in `\n`. `hudmes.dat` segments (s6.2) are
the case to watch. A re-implementation must copy this, and it depends on
**where the NULs were at render time**:
- Paced mode: everything appended before the frame's call is one stream.
- Immediate mode: every HudPrint is its own stream.

### 2.4 Metrics (all read live; nothing is hard-coded) **[SEEN]**

| quantity | source |
|---|---|
| wrap width W | `word [[o+0]+0]` (`0x3924A`). Stock 170, mod 438. |
| surface height H | `word [[o+0]+2]` (`0x39279`). Stock 206, mod 678. |
| line height lh | `word [[font+2]+2]`, the font sheet's height (`0x39255`). Stock 12, **mod 21** (all three sheets). |
| glyph advance | `table[g].end - table[g].start` (`0x393E0..0x393F2`). No extra letter spacing at render time; the spacing is inside `end` (s3). |
| space advance | `trunc(x + lh * C)` - x, with `C = 2/7` as a double at `0x143F4B` |
| start x/y | `o.x`, `o.y`: 0/0 stock; 0/585 mod at creation; 0/0 after any reset |

**The space advance is `floor(2*lh/7)`:** 3 px for lh=12 and **6 px for lh=21**. A caveat
**[INFERRED]**: `C` is slightly below 2/7, and lh=21 is an exact multiple of 7. The result
therefore depends on FPU rounding:
- The Reality Lab rasteriser sets RC=chop and never restores it. It does `fnstcw`, then
  `or 0xC00`, then `fldcw` at `0x114ADB` and 9 sister sites. The startup CW is `0x127F`
  (`0x5C085`).
- On a real x87, `21*C` would chop to 5.999... and the advance would be **5**.
- DOSBox's C FPU does FMUL/FADD in host doubles with round-to-nearest, and honours RC only in
  FRNDINT/FIST. That gives exactly 6.0, then `trunc` gives **6**. Checked: in double
  arithmetic, `trunc(x + lh*C) == x + floor(2*lh/7)` for every lh 1..64 and x 0..2000.

**Validate once in game:** after a line that contains spaces, compare the host's x with
`word [o+4]`.

### 2.5 Is text queued while paced still in the buffer?

Yes. While +0x12 = 1, HudPrint only appends (`0x3910D` skips the render), so all
not-yet-shown text sits in `[o+8]`. It drains one line per frame (s1.3). In immediate mode it
never stays in the buffer.

### 2.6 How it reaches the screen

| state | stock blit | [MOD] |
|---|---|---|
| no conversation scroll (`[0x152B32]==0`) | `0x14FA6`: `0x37D98(eax=0, edx=log surf, ebx=view 0x152150, ecx=381, push 35)` | Dest retargeted to the box surface `0x152AD4`. The call goes through `AztLogClearBx`, which clears the box and subtracts the scroll offset from the pushed Y (a negative Y is a source-row offset, `0x37E2F`). |
| conversation scrolling (`[0x152B32]!=0`) | `0x14FE3`: `0x37E74(eax=0, edx=log surf, ebx=rect (0,[0x152B32])-(170,206), ecx=view, push x=381, push y=35)` | Rect 438x678 (`convlist-w/h`), Y=2. Goes through `AztLogClearCx`, which does NOT add the offset (`$CONV_USES_BOX=$false`). |

Stock shows the box only while `word [0x152910]` is set (`0x14F5B`). It is set while text is
pending or a conversation/close-up is up. It is cleared 300 BIOS ticks (about 16.5 s, from
`0x1BC5F`, which reads `0x46C`) after the buffer empties (`0x14F35..0x14F55`). **[MOD]** The
box frame is blitted every frame (`log-box-always`). The text compose is still gated by
`0x152910`; the build script never touches it. **[INFERRED]**

**[MOD] Which surface rows are visible** (`AztBoxWindow`, Build-AztMod ~l.12190). Here
`s = min(word aztLogScroll @0x132998 obj1, MAXOFF)`:
- collapsed: rows `[MAXOFF_SMALL - s, MAXOFF_SMALL - s + RECESS_H_SMALL)`, with `MAXOFF_SMALL = TEXTBOX_H - RECESS_H_SMALL` (=585)
- expanded, or a conversation is up: rows `[MAXOFF_BIG - s, ...)`, with `MAXOFF_BIG = TEXTBOX_H - RECESS_H_BIG` (=120 with `$LOG_HISTORY`=120)

---

## 3. Fonts and glyph widths (Q3)

### 3.1 Font object (StLoadFont `0x38AB8`, eax=filename; 10 bytes) **[SEEN]**

| off | field |
|---|---|
| +0 | byte first char, always `0x21` (`0x38C05`) |
| +1 | byte count, always `0x8B` = 139 (`0x38C12`) |
| +2 | dword surface ptr: the PCX, w x h, 8-bit, index 0 = transparent |
| +6 | dword glyph table ptr: 139 entries of `{ word start, word end }` |

Fonts loaded: `0x10CE2` rusgld2 into `0x152178`, `0x10CF6` genblu2 into `0x15217C`,
`0x10D0A` rus14 into `0x152180` (compass labels), `0x288AE` invfont into `0x163A38`,
`0x1FD01` (map screen).

**For the host: read the advances live.** Follow `font+6`, take 139 x 4 bytes, and
`advance[g] = end - start`. The line height is `word [[font+2]+2]`. That is exact for whatever
sheet is installed.

### 3.2 Building the table from the PCX (to recompute offline) **[SEEN]** `0x38BBB..0x38D86`

```
single = (every non-zero pixel in the whole sheet has the same index) ? 1 : 0
col = 0
for g in 0..138:
    while col < W and column(col) is all zero: col++        // skip blank columns
    start = col
    while column(col) not blank and col < W - single: col++
    end = col + single                                        // first blank column (+1 if single-ink)
    table[g] = (start, end); col = end
```
So the advance is the ink width, plus 1 for single-ink sheets. Stock INVFONT is single-ink
(index 54 only), so it gets +1. Stock RUSGLD2/GENBLU2 use 54+56 and 54+55, and every mod sheet
is multi-level, so they get +0. Their 1-px gap is the shadow column inside the ink.

| sheet | stock | mod (installed) |
|---|---|---|
| RUSGLD2 | 1380x12, inks 54 shadow + 56 gold | 1532x21, 54,14,22,26,56 |
| GENBLU2 | 1380x12, inks 54 + 55 cyan | 1532x21, 54,3,9,19,55 |
| INVFONT | 1380x12, ink 54 only | 1532x21, 54,18,23,27,41 |

### 3.3 Characters 0x80..0xFF (`0x38DD8`) **[SEEN]**

The table at `0x14764C` is (from, to) byte pairs, ending at 0:
`8E>80 80>82 99>85 9A>86 85>88 83>89 84>8A 87>8D 82>8E 8A>8F 88>90 8C>94 A4>96 93>99 94>9A
97>9D 96>9E 81>9F E1>A7 90>83 8F>81 89>91 8B>95`.
The glyph index is `to - 0x21`. A byte >= 0x80 that is not in the table calls
`ErrorFunc(..., "DrawString")`. The same mapping is used by the measure (`0x393C3`), the draw
(`0x38F54`) and StringWidth (`0x38E7C`).

### 3.4 Related routines

| addr | name | notes |
|---|---|---|
| `0x38EC8` | DrawString(eax=surf, edx=font, ebx=x, ecx=y, [push str]), callee-pops 4 | Per glyph: blit `(start,0)-(end,h-1)` via `0x37E74`, then x += end-start. Space: x = trunc(x + h*2/7) (`0x143F43`). `\n`: x = start x, y += **h+1**. `\r`: y += h+1. The log never sends it `\n`; the inventory list does not either. |
| `0x38E1C` | StringWidth(eax=font, edx=str) | Same advances; stops at `\n`/`\r`/NUL. Used for centring. |
| `0x38A80` | column-blank test | |
| `0x37A9E` | `__CHP` | frndint with RC=chop |

---

## 4. Conversation options (Q4)

### 4.1 Same surface, same renderer **[SEEN]**

Options are printed with HudPrint into the story-log object `[0x1521AC]`, so into the same
surface. The log is reset first and the object is in immediate mode, so the options replace
the narration on screen. `0x37E74` is only the blit used while the list is mid-scroll (s2.6),
not a separate text renderer.

### 4.2 Data

- **AddOption** `0x17CD5(eax=text, edx=id)`: mallocs a 10-byte node,
  `node+0 = malloc'd sprintf("^ %s\n", text)` (format at `0x140A2C`), `+4 = id`,
  `+6 = old head`. It sets head `[0x152B1E]` = top `[0x152B22]` = node, so nodes come out in
  REVERSE order of adding. `^` is a glyph in the font.
- **ClearOptions** `0x17CA5`: frees the list.
- Strings are runtime pointers; follow `[node+0]`.

### 4.3 Drawing the list, `0x17FF6` **[SEEN]**

```
if [0x152B28] (speaking): [0x152B26]=1; return          // redraw when the line ends (0x17C08)
Reset(log); [0x162B34] = 0
for (n = [0x152B22]; n && log.y < H - 80; n = n->next):
    font = (n == [0x152B22] && [0x152B30] == 0) ? GENBLU2 : RUSGLD2
    HudPrint(log, font, n->text)                         // renders at once (immediate mode)
    if n == [0x152B22]: [0x152B2E] = log.y               // height of the top option
    [0x162B36 + 2*[0x162B34]++] = log.y + 0x59           // bottom of this option (+0x59 stock; [MOD] +0)
```
- **Highlight = the font only.** The top node `[0x152B22]` is cyan (GENBLU2) and the rest are
  gold. During a scroll animation (`[0x152B30] != 0`) every option is gold. There is no
  rectangle.
- Options start at y=0 (after the reset) and x=0. Each one ends in `\n`, so the next starts on
  a new line. A long option wraps over several lines like any log text.
- The list stops once y >= H-80 (stock H-80 = 126; mod 598). Options past that are neither
  drawn nor clickable.

### 4.4 Keyboard scrolling (`0x1818F` down, `0x18246` up; per frame via `0x182F6` from `0x14F81`)

- Down: `[0x152B30]=1`, redraw (all gold), then `[0x152B32] += 7` per frame until it is >=
  `[0x152B2E]`. Then `[0x152B22]` = next, dir = 0, offset = 0, redraw.
- Up: `[0x152B22]` = predecessor, dir = -1, redraw, offset = `[0x152B2E]`. It then drops by 7
  per frame to 0 and redraws.
- While the offset is non-zero the list is blitted from source row `[0x152B32]` (s2.6). Enter
  (`0x12F0C`) speaks `[0x152B22]` via `0x17D2B`.

### 4.5 Clicking (`0x180C0`, eax = cursor Y) **[SEEN]**

- Ignored while `[0x152B26]` is set or Y is outside `[0x59, 0x126]`. **[MOD]** That range
  becomes `[0, 677]`, and `AztConvHit` converts screen to surface rows first.
- Option i = the first i with `Y < table[i]`. So option i covers
  `[table[i-1] or list top, table[i])`. It is `y_after_option + 0x59`, the bottom edge
  (exclusive).
- On a hit it resets the log and **reprints from the OLD top `[0x152B22]`**, with the CLICKED
  node in cyan and the others gold. Then `[0x152B22]` = clicked and `0x17D2B` plays it.
- So for that moment the cyan line is not the list's top. A host that rebuilds the list from
  state must remember the previous top.
- When speech ends, `0x17C08` redraws via `0x17FF6` if `[0x152B26]` is set. The script's
  response (`0x1B3C6`) rebuilds the options and calls `0x17FF6`.
- NPC lines are voice only. Nothing prints them: no HudPrint caller is in `0x1B1xx`.
  **[INFERRED]**

---

## 5. Inventory text, left panel (Q5)

### 5.1 The widget at `0x163A40` (it is a surface with a list appended) **[SEEN]**

Built by `0x287DA` from `0x138D3`. Stock 103x69, mod 236x88 (`inv-w/h-138C9/C4`). Blitted
at stock (70,345); **[MOD]** (76,1014) (`hud-map-x/y`, 4 sites).

| off | field |
|---|---|
| +0..+0x11 | surface (w, h, pixels, clip) |
| +0x12 | word top index (first visible row) |
| +0x14 | word count (max 50) |
| +0x16 | word ids[50] (object ids, newest first) |
| +0x7A | dword `char*` names[50] (runtime pointers) |
| +0x142 | word last id picked by click (`0x28ADF`) |
| +0x144 | word scroll velocity: 0, -4 (`0x28A27`, up a row) or +4 (`0x289E7`, down a row) |
| +0x146 | word scroll pixel position 0..pitch |
| +0x148 | word marked id (eye icon) or -1 |

- `word 0x14747A` = row pitch = INVFONT height + 1 (`0x288C5`). That is 13 stock and 22 mod.
- `word 0x147478` = dirty flag. It is set by add/remove; `0x28BC9` redraws when it is dirty
  or scrolling.

### 5.2 Names **[SEEN]**

- **AddInventoryItem** `0x288E2(eax=0x163A40, edx=name, ebx=id)` puts the new item at index 0.
  Its callers are the pickup at `0x2AFE5` and save-game restore at `0x3B986`.
- Both pass `name = [[0x1841D0] + id*4] + 0x3F`: the object record's name, NUL-terminated
  (OBJECTS.DAT **[INFERRED]**).
- RemoveInventoryItem `0x28944`; clear `0x289D7`.

### 5.3 Draw, `0x28A4A` **[SEEN]**

```
memcpy(list.pixels, [0x163A3C].pixels, w*h)          // invback2.pcx backdrop
y0 = 0
if vel < 0: { if pos==0: top--;  pos += 4; if pos > pitch: vel=0, pos=pitch;  y0 = pos - pitch }
if vel > 0: { pos += 4; if pos > pitch: vel=0, top++, pos=pitch;  y0 = -pos }   // drawn from the pre-++ top
for (i = top, y = y0; i < count && y < h; i++, y += pitch):
    DrawString(list, INVFONT, 0, y, names[i])        // one line, NO wrapping; clipped at w
    if ids[i] == marked: blit eye.pcx (0x163B8A) at (w-16, y+1)
```
- One line per item at x=0. Names that are too long are clipped by the blitter's clip rect,
  not wrapped. There is no hover highlight.
- `marked` is set by `0x28C02` when an item is taken in hand (`0x2C52A`; only if
  `record+6 != 0`) and cleared by `0x28BF4`. **[INFERRED]** This is the "held for use" item.
- **Host, at rest:** `vel == 0` gives y0 = 0. While scrolling, use the post-update formula
  above.
- Click (`0x2C43D`, `0x28ADF`): `index = (cursorY - 0x154) / pitch + top`. That is stock;
  **[MOD]** `hit-map-*` move it. It ignores the scroll offset.

### 5.4 Descriptions are not on the left panel **[SEEN]**

Clicking an item in scan mode (`[[0x1841C8]+0xC]`) calls `0x2BE30`.
- That reads the description from `objhud.dat`: record `[obj+0xE]`, 0x19F bytes, text at +0xF,
  via `0x3D244`.
- It prints `"%s\n\n\n"` in **cyan** into the story log (`0x2BB08`).

Taking an item in hand instead sets `[[0x1841C8]+8]` = id and `+0xA` = 1. `0x2D478` then
draws `"Holding : %s"` and `"Using with : %s\n"` in the 3D view (s6.3).

`[0x146872]` = object id under the 3D cursor, or -1. `[0x1521B4]` = scene-frame name under
the cursor. Both are written by the pick routine `0x116E4`. They are not inventory text.

---

## 6. Everything else drawn as text (Q6)

### 6.1 Into the story-log surface (HudPrint call sites; all target `[0x1521AC]`) **[SEEN]**

| site(s) | font | text | trigger |
|---|---|---|---|
| `0x10D37..0x10E09` (`0x10B98`) | gold, then cyan, then gold | ASCII "7" logo, "H U D  S t a r t u p . . .", "Env Systems.... OK"..., "Internals:...", "S y s t e m  I n t e g r i t y :\n1 0 0 %" | game start |
| `0x13DA5`, `0x13DBC` | cyan | "W A R N I N G", "The HUD has suffered corrosion damage. ..." | `word [0x152AF8]` (cleared after) |
| `0x17027..0x171AD` (`0x16FB4`) | mixed | vital signs / CE / "### Offline ###" | death sequence |
| `0x17F90`, `0x17FA5` | gold, cyan | "Model 7 Head Up Display", "Online......." | conversation end |
| `0x1806F`, `0x1808D`, `0x1810A` | s4 | options | conversation |
| `0x2A5DA..0x2A6C7` (`0x2A594`) | per marker | `hudmes.dat` message (s6.2) | 9 callers: scripted events (`0x1508D`, `0x1514E`, `0x15328`, `0x16E56`, `0x171BC`, `0x172BB`, `0x17499`), `0x2B0EF`, `0x2BFB4` |
| `0x2BB37` (`0x2BB08`) | cyan | object description `"%s\n\n\n"` | scan an object/inventory item |
| `0x2BF3D` | cyan | `DESCRIPT.ZAP` `"<name>.DES"` text | scan a character (`ZZ` rig) |
| `0x2BF9A` | cyan | "ADDITIONAL - Organism Dead - PENSCAN - Faint Life Signs Detected." | character scan, condition at `0x2700C` |

### 6.2 `hudmes.dat` and colour markers (`0x2A1C4`, `0x2A594`) **[SEEN]**

- `0x2A1C4(n)` seeks `0x1E + 6n` and reads `dword offset, word length`. It returns a malloc'd
  NUL-terminated copy, which is never freed **[INFERRED]**.
- `0x2A594` scans it. `0xFA` and `0xFC` switch to gold; `0xFB` switches to cyan. Each switch
  prints the segment before it (marker bytes dropped) with the font that was in effect, then
  the tail is printed.
- **Text before the first marker is dropped** when the string starts without one, because a
  segment that starts at 0 is skipped (`test dx,dx`). A string with no markers prints whole in
  gold.
- Segments are not joined with spaces. A marker in the middle of a word gives a mid-word font
  change (s2.1).

### 6.3 Not in the two areas (for completeness)

| what | where | detect |
|---|---|---|
| debug readout: coordinates + nearby names, "Unknown Object.." | `0x11E68` draws into **`0x152AD4`**, which **[MOD]** IS the log box surface. It first clears it (`0x11ED1`). | `word [0x1523E2]` (debug toggle, key handler `0x1350F`). Off in normal play. |
| loading caption "Updating Environment Scan....", "Saving Game....", "Loading Game....", plus 5 random scan lines at `0x146874 + 33k` | `0x108D8` sets the pointer `[0x1523B0]`; `0x10300` centres it with StringWidth in cyan at y=12 in the 180x40 surface `0x152390` and blits it at screen (230,120) (**[MOD]** `hud-cap-x`) | `word [0x152B02]` saving, `word [0x152B04]` loading |
| "Holding : %s" (30,20), "Using with : %s\n" (30,33), gold | `0x2D478` into the view `0x152150` | `word [[0x1841C8]+0xA]` != 0, `[0x14721C]`==0, `[0x15257C]`==0 |
| "RUN" (4,93) cyan, "REPLAY" centred, "RESTART", save-slot names | `0x16043` sites `0x143B4`, `0x15819`, `0x14BAC`, `0x14BE9`, `0x14C9D` into the view | see `docs\save-load-screen-RE.md` |
| "AWAITING BOOK PAGE...." | `0x1645D` into the book surface `0x152580` | |
| compass degree labels (rus14), "-%d-" counter | `0x13ECC`, `0x10B79` | |
| debug pick text "%s (%.3f ...)", "ROOM: %d" | `0x116E4` into the view | `[0x1523E2]` |

---

## 7. Host recipe

### 7.1 What can be read at any time

- The log object, the surface size, the x/y cursors, the current font, the paced flag, the
  pending bytes, and the font tables (advances and height).
- The conversation state: `0x152B1C/1E/22/26/28/2E/30/32`, `0x162B34/36`.
- The inventory widget, the names (via the `char*` array) and the scroll state.
- The **mod** window: `aztLogScroll`, the box state and the build constants.

### 7.2 What memory alone cannot give

- **Story-log history** before the host attached, or text that was queued and drawn between
  two polls. A short message lives one frame in the buffer.
- **Anything printed in immediate mode** (the whole conversation list).
- **NUL boundaries** at render time (s2.3).

### 7.3 Recommended: a tiny guest tap (no fixups at either site, checked with `Test-FixupsIn`)

1. **Hook HudPrint entry `0x39080`** (6 bytes `51 56 57 55 89 C1`). Copy
   `(seq, paced flag, font ptr, strlen, bytes)` into a ring in the BSS cave. Copy the bytes,
   because many callers pass stack buffers (`0x2A594`, `0x2BB08`, `0x2BE30`).
2. **Hook Reset `0x3948C`** (`53 52 89 C2 66 C7`). Bump a reset-generation counter. Also note
   `AztBoxConv`'s own reset (s1.4).
3. **Host side:** keep the stream since the last reset and re-run s2.1 on a virtual surface
   (W, H, start y from the guest).
   - In paced mode, render up to `consumed = total - (([o+8] != 0) ? [o+0xC] - 1 : 0)`
     characters of the stream (bytes counted the same way as s1.2). That reproduces the
     one-line-per-frame reveal.
   - Self-check after each frame: the emulated `(x, y)` must equal `word [o+4]`,
     `word [o+6]`. On a mismatch, re-sync from the next reset.
4. Map virtual rows to the screen with the same window maths the mod uses (s2.6). Colour per
   word = its font pointer (gold/cyan).

Without a tap, the next-best option:
- Poll `[o+8]` every host frame and diff the tail. This works in paced mode only.
- Rebuild the conversation list from the node list (s4.3), remembering the old top after a
  click (s4.5).
- Accept that history before attach is missing.

The inventory list needs no tap. Read the widget each frame (s5.3).
