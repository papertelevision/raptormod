# System menu (fold-out): reverse-engineering reference

Static analysis of the stock `GAME\AZRAEL\R.EXE` with the `tools\load.ps1` toolchain, checked
against the installed modded `C:\Games\AzraelsTear-Modded\GAME\AZRAEL\R.EXE`, `src\Build-AztMod.ps1`
and `AztMod.manifest.json` (426 patches). Read `docs\save-load-screen-RE.md` first. It already
covers the fold-out state words, commands 5/11..16/25, the `SAVE%02d.pcx` picture choice and the
slot list. This document adds the rest of the fold-out: the toggles, the sliders, QUIT, the
keyboard, and the drawing rectangle.

Addresses are LINEAR. File offsets:
- obj1: `0x61A54 + (lin - 0x10000)`.
- obj2: `0x184A54 + (lin - 0x140000)`.

Tags:
- **[SEEN]**: read in the disassembly.
- **[INFERRED]**: deduced, not proven.
- **[MOD]**: checked in the installed modded EXE or in Build-AztMod.

Nothing was run, and no game, mod, manifest or tool file was changed.

---

## 0. The short version

| what | where | values |
|---|---|---|
| SFX on | word `0x14693A` | 1 on / 0 off. Initial 1 (EXE data). Toggled by cmd 7. |
| music on | word `0x14693C` | 1 on / 0 off. Initial 1. Toggled by cmd 8. |
| **SFX level** | word `0x14693E` | **0..127**. Initial 100. |
| **music level** | word `0x146940` | **0..127**. Initial 100. |
| music button pressed (flash) | word `0x146942` | 1 from the cmd-8 click until LEFT button up. Shows picture 9. |
| SFX button pressed (flash) | word `0x146944` | 1 from the cmd-7 click until LEFT button up. Shows picture 10. |
| **dragging the SFX slider** | word `0x1523DA` | 1 from the cmd-9 click until LEFT button up |
| **dragging the music slider** | word `0x1523D8` | 1 from the cmd-10 click until LEFT button up |
| fold-out up / visible / step / dir | `0x1523D6` / `0x1523EA` / `0x1523E6` / `0x1523E8` | see the save/load doc §1 |
| quit confirm / OK meaning | `0x1524CA` / `0x1524CC` (2 = quit) | see the save/load doc |
| auto-quit-confirm request (`q` key) | word `0x15259A` | turns into cmd 13 on the first idle frame |

Every fold-out click goes through a hot-spot polygon whose `flagB` is a command id. The polygon
starts the action; the game does all the work. **Commands fire on LEFT BUTTON DOWN only**
[SEEN `0x3698F..0x36A47`]:
- The event pump hit-tests only mouse events whose sub-type is 0, i.e. left down.
- The first region in table order that contains the cursor wins, and its pre-built command event
  replaces the mouse event.
- Every other mouse event is passed on raw.

Mouse sub-types are written by `0x3584F`:

| sub-type | event | handled at |
|---|---|---|
| 0 | left down | |
| 1 | right down | `0x15C75`: closes the book/close-up view |
| 2 | left up | `0x15C50` |
| 3 | right up | |

---

## 1. Hot-spot polygons (question 1)

Table format, from the panel-button memory: `word count; count x { word n; int16 x,y[n]; word flagA;
word flagB(cmd); word icon }`. The points start at record + 2.

Screen tables: `[0x14712E + N*4]`.
- s0 `0x146A7C`
- s1 `0x146B4E`
- s2 `0x146C3C`
- s3 `0x146DD2`

`flagA` is 7 for every fold-out control (the viewport rect on s0 is 5). Icon 1 is the "active"
pointer; **icon 0** is the plain pointer and is used by the two sliders.

### 1.1 Records, all screen px [SEEN stock, MOD installed]

| control | cmd | icon | s1 rec | s2 rec | s3 rec | stock points (n) | stock bbox | [MOD] bbox |
|---|---|---|---|---|---|---|---|---|
| SFX toggle | 7 | 1 | `0x146B50` | `0x146C3E` | `0x146DD4` | (530,154)(560,154)(553,183)(530,189) (4) | 530..560 x 154..189 | 1381..1429 x 319..352 |
| music toggle | 8 | 1 | `0x146B68` | `0x146C56` | `0x146DEC` | (530,152)(530,116)(557,123)(576,138)(558,152) (5) | 530..576 x 116..152 | 1382..1464 x 217..250 |
| **SFX slider** | 9 | 0 | `0x146B84` | `0x146C72` | `0x146E08` | (463,181)(479,173)(527,173)(527,169)(505,155)(441,155)(445,167) (7) | 441..527 x 155..181 | **1100..1352 x 283..355** |
| **music slider** | 10 | 0 | `0x146BA8` | `0x146C96` | `0x146E2C` | (463,126)(479,134)(527,134)(527,138)(505,152)(441,152)(445,140) (7) | 441..527 x 126..152 | **1100..1352 x 201..273** |
| SAVE | 11 | 1 | `0x146BCC` | `0x146CBA` | `0x146E50` | (466,184)(498,192)(528,192)(528,177)(478,177) (5) | 466..528 x 177..192 | 1252..1334 x 351..383 |
| LOAD | 12 | 1 | `0x146BE8` | `0x146CD6` | `0x146E6C` | (466,122)(494,114)(528,114)(528,129)(480,129) (5) | 466..528 x 114..129 | 1249..1331 x 174..206 |
| QUIT | 13 | 1 | `0x146C04` | `0x146CF2` | `0x146E88` | (508,153)(528,140)(525,167) (3) | 508..528 x 140..167 | 1302..1358 x 265..302 |
| **menu button = open/close** | 5 | 1 | `0x146C18` | `0x146D06` | `0x146E9C` | 7-pt panel polygon, also s0 `0x146B2A` | 360..444 x 387..426 | 949..1014 x 1013..1100 |
| **OK / confirm** (s3 only) | 16 | 1 | - | - | `0x146EC0` | (479,209)(495,213)(495,221)(459,221)(459,213) (5) | 459..495 x 209..221 | 1193..1351 x 417..457 |

On s2 and s3 these records come after the slot-list records, as listed in the save/load doc §4.1:
- close box (cmd 14): s2 `0x146D2A`, s3 `0x146EDC`;
- 5 rows (cmd 15);
- RESTART (cmd 25): s2 `0x146DBA`, s3 `0x146F6C`.

**[MOD] layout.** The installed full [MOD] point lists are in the EXE. Decode them with the
snippet in §7.
- The mod keeps every record's vertex count `n` and moves the points; a table cannot grow,
  because the records are packed.
- The fold-out moved from stock screen (421,83) 206x170 to **(1085,89) 515x425**.
- The plates come from `$SYSMENU_PLATES` (412x340 reference space, scale `$SYSMENU_K` = 515/412).
- The sliders come from `$SYSMENU_SLIDER_*`; the OK box comes from `$SYSMENU_CONFIRM`.
- They are matched by `Fold-Old` on the exact stock bbox (Build-AztMod ~13280..13315).

### 1.2 Which screens carry what [SEEN]

| screen | used when | panel buttons present |
|---|---|---|
| 0 | fold-out closed | **all**: cmd 2 (`0x146A7E`), cmd 1 inventory window (`0x146AAA`), cmd 3/4 (`0x146AC2`/`0x146ADA`), viewport (`0x146AF2`, flagA 5), cmd 6 (`0x146B0A`), cmd 5 menu (`0x146B2A`) |
| 1 | fold-out open, idle | fold-out controls + **only** the cmd-5 menu button |
| 2 | slot list, nothing picked | + close box, rows, RESTART |
| 3 | slot picked **or quit confirm** | + OK (cmd 16) |

Consequences:
- **While the fold-out is up, the other panel buttons and the viewport are dead.** They are not
  in tables 1..3.
- A fold-out remap touches only tables 1..3 and cannot break screen 0.
- The **menu button polygon exists four times** (s0 r6, s1 r7, s2 r7, s3 r7). Moving the menu
  button means moving all four.
- **Nothing on the fold-out itself closes it.** Closing is the panel's menu button (cmd 5), or
  `0x2C2D4` on load/save/death/conversation (see the save/load doc §6).

**Overlap rule.** The first matching region in table order wins [SEEN `0x369CD` loop]. On s3 the
fold-out controls (r0..r8) come before the slot-list records (r9..r15). So where a new layout
overlaps them, the fold-out control wins.

### 1.3 Quit-confirm variant [SEEN]

Quit confirm = screen 3 with `24CA = 1`, `24CC = 2` and `DC = DE = E0 = 0`.

**The slot-list polygons stay live and invisible.** On screen 3 they are still in the table, so
in [MOD] the memory-core rows, close box and RESTART are clickable where nothing is drawn:
- **Row (cmd 15).** Sets `sel` and goes to screen 3. `24CA` and `24CC` are untouched, so OK
  still quits.
- **Close box (cmd 14).** Goes to screen 1, so OK becomes unclickable. `24CA` stays 1, so
  picture 11 stays up and Enter still quits.
- **RESTART (cmd 25).** Sets `sel = 6` and **`24CC = 0`**, so OK would LOAD SAVE6 under a
  "Quit Game" picture.
  - The watcher's `Guard-SaveList` (`sel == 6 && DE == 0` → revert) already catches this
    [MOD, memory note].
  - Keep that guard while quit mode is host-drawn.

---

## 2. Volume sliders (question 2)

### 2.1 Storage [SEEN]

| word | meaning | range | initial |
|---|---|---|---|
| `0x14693E` | SFX level | 0..127 | 100 |
| `0x146940` | music level | 0..127 | 100 |

Both are int16 in obj2 file-backed data. The code usually reads them as `mov reg,[addr-2] / sar reg,16`
(Watcom sign-extend idiom). So a reference to `0x14693C` / `0x14693E` as a DWORD is really the
next word. Keep that in mind when you search for refs.

No other code references them by address, so they are **not saved** with a game [INFERRED].

**Ducking.** The conversation opener `0x17E52` saves the SFX level to `0x162B60` and writes
`0x14693E = level * 0.3` (double at `0x140A32`) [SEEN `0x17E73..0x17E96`]. The closer `0x17F2F`
restores it (`0x17FED`). The fold-out is force-closed when a conversation opens, so this only
matters to a host that reads the level outside the menu.

### 2.2 Drag start / end [SEEN]

**Start.**
- Cmd 9 (`0x2C9AE`) sets `0x1523DA = 1` (SFX); cmd 10 (`0x2C9C0`) sets `0x1523D8 = 1` (music).
- That is all they do. They do not check the toggle.
- The cmd fires on LEFT DOWN inside the slider polygon.

**End.** LEFT UP (mouse sub-type 2) → `0x15C50` zeroes:
- `0x1523DA`, `0x1523D8` (the drag flags);
- `0x146942`, `0x146944` (the toggle flashes);
- `0x152B00` (unrelated; cmd handlers near `0x2C65F`).

Nothing else clears the drag flags. They are not cleared on fold-out close; left-up always
arrives and clears them.

**Between start and end.** The level follows the cursor X **every frame, wherever the cursor
is**: the polygon only starts the drag.

### 2.3 The per-frame drag maths, `0x14D04..0x14E0F`

This runs inside the fold-out draw block, so only when `[0x1525A0] == 0` (`0x1484F`) and
`[0x1523EA] != 0` (`0x148FC`).

```
14D04  if music_on(14693C) && dragM(1523D8):          ; music branch; else-if SFX branch
14D20    ax = cursorX [0x182D6C]                       ; 66 A1 <fixup>
14D26    sub eax, 0x210      ; 81 E8 imm32  R = 528   (fixup-free)  file 0x6677A
14D2C    neg eax             ; F7 D8                  (fixup-free)  file 0x66780
14D2E    [0x146940] = ax     ; pixel position = R - X
14D3C    if <0 -> 0
14D50    cmp eax,0x57 / jle  ; 83 F8 57 imm8 (5 bytes w/ jle)  W = 87
14D55    -> [0x146940] = 0x57 (imm16 at 0x14D5C)
14D5E    level = pos*0x7F / W   ; imul imm8 0x7F; mov ebx,W imm32 at 0x14D6A
14D76    [0x146940] = level
14D7E    0x3B048(eax = 0x152A34 + 12*[byte 0x152AD0], edx = level)   ; music volume NOW
14D9E  else if sfx_on(14693A) && dragS(1523DA):
14DB2..14E09  same with R at 0x14DB8 (file 0x6680C), neg at 0x14DBE (0x66812),
              clamp cmp at 0x14DE3, clamp store imm16 0x14DEF, W imm32 0x14DFD,
              result in 0x14693E. No sound call (see 2.4).
```

**Formula.**
- `level = clamp(R - X, 0, W) * 127 / W`.
- The level **grows to the LEFT**: level 0 at `X = R`, 127 at `X = R - W`.
- The music branch has priority (if / else-if), so only one slider moves per frame.

**Stock vs [MOD] values.**

| constant | stock | [MOD] installed |
|---|---|---|
| R (`0x14D26`, `0x14DB8`) | 0x210 = 528 | **0x548 = 1352** (`sysmenu-slider-right-*`, imm32 in place) |
| W (divisor `0x14D6A`, `0x14DFD`) | 0x57 = 87 | **0xFC = 252** (imm32 in place) |
| W (clamp store `0x14D5C`, `0x14DEF`) | 87 | 252 (imm16 in place) |
| W (clamp compare `0x14D50`, `0x14DE3`) | 87, imm8 | **5-byte `jmp` to overlay `AztSliderClamp0/1`** (`cmp eax,imm32 / jle 0x14D5E` or `0x14DF1` / else `jmp 0x14D55` or `0x14DE8`) |

So the [MOD] track is screen X 1100..1352: 1352 = level 0, 1100 = level 127.

**Fixups [SEEN with Test-FixupsIn].**
- `0x14D26` (6), `0x14D2C` (2), `0x14D50` (5), `0x14D6A` (5), `0x14DB8` (6), `0x14DBE` (2),
  `0x14DE3` (5) and `0x14DFD` (5) are **fixup-free**.
- The cursor loads (`0x14D20`/`0x14DB2` +2) and the clamp-store instructions (`0x14D55`/`0x14DE8`
  +3, i.e. their address operands) carry fixups. The imm16 at +7 is free.

### 2.4 How the level reaches the sound system [SEEN]

**Music.** `0x3B048(track, vol)` → `0x4F08D(seq, vol, 0)`, a Miles sequence-volume call
[INFERRED name]. It is applied immediately during the drag, and also:
- on cue loop/restart (`0x13E59`);
- on room music changes (`0x11545`, `0x13B03`, `0x16CA4`);
- as a 1000 ms fade at conversation end (`0x3B088` at `0x17FE2`).

[MOD] The overlay watches `0x146940` to drive the CD-audio volume and its mute logic (Build-AztMod
~7660..7770, ~9930, ~10138). It reads the word; it does not change the maths.

**SFX.** Applied **per sample at start**: `0x100BC` (UI/one-shot play) does
`0x317EC(...)` then `0x31EAF([0x1824E8], 0, level, 0)` [INFERRED: set the sample volume].
Positional sounds `0x1F222` scale `level * dist / 99` (`0x1F3B0`). A level change therefore
affects only sounds started afterwards [INFERRED].

**Toggles.**

| toggle | off | on |
|---|---|---|
| music, cmd 8 `0x2C6FA` | `0x3B088(track, 0, 4000 ms)` fade, then `0x3AF1B(track)` (stop) | `0x3AE63(track)` (start). The level is re-applied by the loop poll `0x13E22`. |
| SFX, cmd 7 `0x2C6AF` | `0x31B92([0x1824E8])` | `0x31BD0([0x1824E8], 1)`, then stores edx to `0x162FD4` |

[INFERRED: the SFX calls suspend and resume the digital driver.] The ambient routines
`0x1F222` / `0x1F5AC` / `0x1F693` / `0x1F784` also test `0x14693A`.

While a toggle is off, its slider is inert: the drag branch needs it on, and the bar is not drawn.
The level is kept.

### 2.5 How the sliders are drawn, `0x14E0F..0x14EEE` [SEEN]

Drawn only when the fold-out is not animating (`E8 == 0`) and is visible (`EA`). Per slider:

```
px  = level * W / 127                          ; 0x14E34 / 0x14E91 (imul imm8 87)
esi = W - px
0x335EC(rect = [ebp+0x22], x0 = esi, y0 = 0, x1 = W-1 (0x56), y1 = H-1 (push 0x1A))
if on: 0x37E74(0, src, rect, dst = 0x152150, push X = esi + 0x18D, push Y)   ; partial blit
```

| slider | source bar | Y in view |
|---|---|---|
| music | `0x1523EC` (temp.pcx, 87x27) | 77 |
| SFX | `0x152400` (bemp.pcx, 87x27) | 106 |

The visible fill is the RIGHT `px` columns of the bar, anchored at the bar's right end, and grows
leftward. Stock screen = view + (44,49): track 441..528, music y 126, SFX y 155.

**[MOD] changes.**
- The bar surfaces are 252x72: `0x10C1D` / `0x10C22` / `0x10C33` and `0x10C53` / `0x10C58` /
  `0x10C67`.
- The source rect uses W 0xFC (`0x14E43`, `0x14EA0`), right 0xFA (`0x14E4A`, `0x14EA7`) and bottom
  0x46 (`0x14E48`, `0x14EA5`).
- The px maths runs in the overlay (`AztSliderPx0/1`, jumped to from `0x14E34` / `0x14E91`).
- The draw sites `0x14E68` / `0x14EC9` jump to `AztSlider0/1`, which push Y and add X.
- The bars land at in-view (1100,152) and (1100,234), i.e. screen **(1100,201)** and
  **(1100,283)**, 252x72 each.

### 2.6 Moving the sliders to a new layout

The host draws, so in true colour only the CLICK side matters. The changes:

1. **Polygons.** Rewrite the points of the cmd 9 / 10 records on s1, s2 and s3 (six records, data
   only). Any shape works; keep each `n`.
2. **R.** Set the imm32 at `0x14D26` and `0x14DB8` to the new track's right end (screen X).
3. **W.** Set the imm32 at `0x14D6A` and `0x14DFD`, the imm16 at `0x14D5C` and `0x14DEF`, and the
   overlay `AztSliderClamp0/1` imm32.
   - All three come from one variable today, `$SYSMENU_SLIDER_W`, which ALSO drives the bar art,
     bar surfaces and draw maths.
   - If the host's track width differs from the bar art, split that variable into a click W and a
     draw W.
   - Changing it adds no overlay bytes: they are imm32 already.
4. **Optional: make the slider grow to the RIGHT.**
   - NOP the `neg eax` at `0x14D2C` / `0x14DBE` (`F7 D8` → `90 90`; files `0x66780` / `0x66812`).
   - Set the imm32 at `0x14D26` / `0x14DB8` to the track's LEFT end L. Then `level = (X - L)`
     clamped to 0..W, scaled by 127/W.
   - Fixup-free, 4 bytes.
   - Only the low 16 bits are stored and re-read sign-extended, so the garbage upper bits of eax
     (from `mov ax,[cursor]`) do not matter.
   - In 8-bit mode the game's own bar would still fill from the right.
5. **Vertical sliders are not cheap.** The cursor read `mov ax,[0x182D6C]` has its address in a
   fixup slot. Using Y means retargeting that fixup record, which is per-site. Possible, but it
   is not a byte patch.

**Host read rule.** Each frame the game writes the PIXEL position into the level word and then
overwrites it with the level, in consecutive instructions. An asynchronous ReadProcessMemory can
very rarely catch the intermediate value (0..W, up to 252 in [MOD]). Treat a value > 127 as
"re-read next frame".

---

## 3. Toggles and what the fold-out shows (question 3)

| word | written by | meaning |
|---|---|---|
| `0x14693A` | cmd 7 `setz` toggle | SFX on (1) / off (0) |
| `0x14693C` | cmd 8 `setz` toggle | music on (1) / off (0) |
| `0x146944` | cmd 7 sets 1; cleared by cmd 5 open and left-up `0x15C50` | "SFX button held": picture 10 |
| `0x146942` | cmd 8 sets 1; cleared likewise | "music button held": picture 9 |

The EXE's initial data has both flashes = 1, but cmd 5 clears them on every open.

**On/off is never drawn as a lamp** [SEEN]. The only on/off cue is whether that slider's bar is
blitted. Pictures 9/10 are press flashes, which [MOD] `Build-SysMenu.ps1` renders as the lit plate:
- `$LIT` = save (7), load (8), music (9), sfx (10), save (12), load (13);
- captions `'Quit Game'` (11) and `'confirm'` (12, 13).

**Nothing else is drawn by code** [SEEN, `0x148FC..0x14EEE`]. The fold-out block draws:
- the picture (`0x14CFF`);
- the slot list (only when `DC`);
- the two bars.

There is no text, version number or counter. Every caption is baked into `SAVE%02d.pcx`. Picture
selection is in the save/load doc §1.4.

**Sounds.**
- `hud3.wav` on open/close: [MOD] gated by `AztWhooshGate` at `0x2C85E` / `0x2C2E8`.
- `hudlockr.wav` when step 6 is reached (`0x14960`).
- Opening also blits the lit panel menu-button sprite `0x164E92` (nbut2on) at anchor
  `X[2]` / `Y[2]` (`0x14748A` / `0x147490`). That is panel art, not the fold-out.

---

## 4. QUIT (question 4) [SEEN]

**Flow.**

| step | effect |
|---|---|
| QUIT plate (cmd 13 `0x2C8E6`), off → on | `E0 = DC = DE = 0`, restore the name backup, `sel = -1`, **`24CA = 1`, `24CC = 2`**, screen 3 (OK live). Picture 11. |
| QUIT again | `24CA = 0`, screen 1 |
| OK (cmd 16 `0x2CCA1`) or **Enter** (`0x12CAD`: `24CA && ascii == 0x0D` → cmd 16) | sets `0x152176 = 1`. The main loop tests it at `0x16086` after the event batch and returns: the game quits at once. |

**Other exits from quit mode.**
- SAVE / LOAD (cmd 11 / 12) set `24CA = 0` and open their list.
- Cmd 5 closes everything (`0x2C2D4` clears `24CA`).

**Drawing.** Picture 11 is chosen when no list mode is set (`0x149AA..`). The [MOD] art says
"Quit Game" in the confirm box; the OK hot spot covers that caption.

**There is no "No" button.** The only clickable things are the OK polygon, the fold-out controls,
the menu button, and the invisible slot-list polygons (§1.3).

**`q` / `Q` key** (`0x13599`).
- Debug flag `0x152AFC` set: quit at once.
- Otherwise: cmd 5 plus `0x15259A = 1`, which issues cmd 13 on the first idle frame (`0x1496C`).
- **Stock quirk:** pressing `q` while the fold-out is OPEN closes it but leaves `0x15259A = 1`.
  The flag is cleared only on idle frames, so the next open, by any means, lands in quit confirm.

---

## 5. Keyboard (question 5)

The KeyDown handler is `0x12B88(eax = event)`: ascii at +6, scancode at +7, sub-type at +5.
Event type 2 sub 1 reaches it from `0x15E7E`.

[MOD] `0x15E7E` calls `AztKeyHook` (stub cave `0x132E71`):
- WASD → arrow scancodes with ascii zeroed (skipped while `0x1525A0` is set);
- the real arrows scroll the log;
- F2 / F3 / F4;
- everything else (ESC, letters) passes through unchanged.

### 5.1 The order of tests in `0x12B88` [SEEN]

| # | site | condition | effect on keys |
|---|---|---|---|
| 1 | `0x12B95` | book / close-up view `[0x15257C]` | **every key ignored** (return). The view closes on right-button-down (`0x15C75` → `0x15D66`). |
| 2 | `0x12BA3` | `[0x1525F2]` (opening-room hold) | only m/M/h/H/p/P/`/`/`?`/F1 pass; **ESC and `e` ignored** |
| 3 | `0x12BF0` | `[0x1525A0]` (the picture modal `0x16A80`; the mod calls it `g_saveBox`, which is a misnomer) | **ESC → `0x16BE0` closes it**; `s` passes; the rest are ignored |
| 4 | `0x12C16` | `[0x1528F6]` debug room-number entry | a non-digit cancels it and falls through |
| 5 | `0x12CAD` | quit confirm and Enter | cmd 16 (then continues) |
| 6 | `0x12CCB` | `(E0 \|\| DE) && sel != -1`: **slot picked / typing** | `0x12DCF` editor: Backspace / Enter / printable go to the name (save mode). **ESC and everything else are swallowed.** |
| 7 | `0x12CF4` | dead `[0x152904]` | ignored |
| 8 | `0x12D02` | conversation `[0x152B1C]` or speaking `[0x152B28]` | `s`, `1`, `2`, `3` → normal dispatch. Then: **speaking + ESC → `0x12D67` call `0x17C08` (skip the line)** [MOD: `0x12D5E` → `AztSkipKey`, which also accepts Space]. In a conversation and not speaking: arrows/Enter pick options, **ESC swallowed**. Speaking outside a conversation: any other key goes to normal dispatch. |
| 9 | `0x12E75` | **normal dispatch** (ascii binary search) | ESC: `0x13648` → `0x136A8` → `0x136D4` → **`0x13713`**: `test al,al / jz 0x13049` (scancode keys), else **return: ESC does nothing** |

So ESC reaches `0x13713` **only** when none of the following applies:
- book view;
- opening hold;
- picture modal;
- slot picked;
- dead;
- conversation;
- speaking.

In other words, exactly "nothing else uses ESC". That covers normal play, the fold-out open
(idle, quit confirm, or a list with nothing picked), help/map, and the orrery.

**`e` (0x65) and `E` (0x45) are unbound** [SEEN].
- `e` falls out of the search at the epilogue **`0x135F6`**, the shared "no match" for 0x5A..0x67
  after `cmp al,0x59 / jz`.
- `E` falls out at **`0x13628`**, after `cmp al,0x48 / jz`.
- AztKeyHook does not touch them (scancode 0x12). No host tool binds E or Escape (grepped
  `tools\*.cs`, `*.ps1`).
- Save-name typing (`0x12DCF..0x12E4F`) returns before `0x12E75`, so a binding placed in the
  normal dispatch can **never** steal a letter from a save name or from load-list selection.

**Already modded in this handler [MOD, manifest]:**
- `0x12D5E` skip-space;
- `0x12FEF` f1-help-in-combat;
- the confine/screen-size immediates at `0x13253..0x13439`.

None of them touches the sites below.

### 5.2 Proposed patch: ESC = cmd 5, E/e = log-box expand, with NO new cave bytes

**Cave status [MOD].** There is effectively no room for new code:
- overlay `AZTCODE.BIN` 53,240 / 53,248 bytes;
- stub 1664 / 1664;
- box blob 461 / 466;
- box-art 418 / 419;
- clock blob about 16 bytes free.

So this patch fits **inside the handler**. The handler has Watcom's duplicated 12-byte epilogues
(`81 C4 3C 03 00 00 5F 5E 5A 59 5B C3`). Three of them are fall-through "no match" exits:
- `0x1367A`, for '6'..';';
- `0x1369C`, for '0';
- `0x136C8`, for '&'..'+'.

Each becomes a 2-byte short `jmp` to a surviving epilogue, which frees 10 bytes.

**Safety checks [SEEN].**
- None of the 6 sites carries a fixup (`Test-FixupsIn`).
- No branch in the image targets any byte inside them other than their first byte.
- Every displaced key still just returns.

**The log toggle reuses the mod's own code.** It runs the tail of `AztBoxClick` (box blob), from
its `xor word [esi+aztBoxBig],1` onward. That tail:
- flips `aztBoxBig` (`0x511AF`);
- on collapse, zeroes `aztLogScroll` (`0x132998`);
- plays `hudlockr.wav` via `0x100BC`;
- `popad / ret`.

Its entry needs a `pushad` and `call AztBoxDeltas` (esi = obj1 delta, edi = obj2 delta), which is
what T1 below does.
- **Flipping the word alone would also redraw correctly.** `AztBoxWindow` / `AztBoxPrep` re-read
  `aztBoxBig` every frame.
- What it would miss is the scroll reset and the sound. Reusing the tail keeps keyboard and
  click identical.
- It needs one zero-byte label in Build-AztMod: `Add-Label $t 'ABC_toggle'` immediately before the
  `xor` at line ~12341.
- In the installed build `ABC_toggle` = `0x51323` and `AztBoxDeltas` = `0x511B3` (`CAVE2_BASE + 0x13`).
- **Compute both rel32s from `$tBox.Labels` at build time; never hard-code them.**

**Layout.**
- `T1` = `0x1367C`, `T2` = `0x136CF`. T1 + T2 is the toggle trampoline.
- `E` = `0x1369E`, the ESC body.
- `Z` = `0x136CA`, the old `jz 0x13049` moved out of `0x13713`.

| # | lin / file | stock bytes | new bytes | meaning |
|---|---|---|---|---|
| 1 | `0x13713` / `0x65167` | `84 C0 0F 84 2E F9 FF FF` | `84 C0 74 B3 3C 1B 74 83` | `test al,al; jz Z(0x136CA); cmp al,0x1B; jz E(0x1369E)`; else falls into the `0x1371B` epilogue |
| 2 | `0x1369C` / `0x650F0` | epilogue (12) | `EB 7D 6A 05 58 E8 62 8D 01 00 EB 73` | ('0' → `jmp 0x1371B`) **E:** `push 5; pop eax; call 0x2C408; jmp 0x1371B` |
| 3 | `0x136C8` / `0x6511C` | epilogue (12) | `EB 51 E9 7A F9 FF FF E9 xx xx xx xx` | (`&`..`+` → `jmp 0x1371B`) **Z:** `jmp 0x13049`; **T2:** `jmp ABC_toggle` (installed: `4F DC 03 00`) |
| 4 | `0x1367A` / `0x650CE` | epilogue (12) | `EB 20 60 E8 xx xx xx xx EB 4B 90 90` | ('6'..';' → `jmp 0x1369C` → `0x1371B`) **T1:** `pushad; call AztBoxDeltas` (installed: `31 DB 03 00`); `jmp T2` |
| 5 | `0x135F6` / `0x6504A` | epilogue (12) | `3C 65 75 10 E8 7D 00 00 00 EB 09 90` | `cmp al,'e'; jnz 0x1360A; call T1; jmp 0x1360A` (`0x1360A` is an intact epilogue) |
| 6 | `0x13628` / `0x6507C` | epilogue (12) | `3C 45 75 10 E8 4B 00 00 00 EB 09 90` | `cmp al,'E'; jnz 0x1363C; call T1; jmp 0x1363C` (`0x1363C` is intact) |

The total is 66 bytes rewritten in place, with **0 bytes of new cave**. Every branch distance was
checked by hand:
- rel8 targets: `0x136CA`, `0x1369E`, `0x1371B` from both holes, `0x1369C`, `0x136CF`,
  `0x1360A`, `0x1363C`;
- `call 0x2C408` = `0x2C408 - 0x136A6 = 0x18D62`;
- `jmp 0x13049` = `-0x686`.

**Register contract.**
- `0x2C408` preserves ebx/ecx/edx/esi/edi/ebp and dispatches on `al` (`dec al / cmp 0x19 / and
  eax,0xFF`). `push 5 / pop eax` sets it cleanly.
- T1/T2 preserve everything (pushad … popad).
- Every exit goes through an untouched epilogue, so the handler's frame (`sub esp,0x33C`) is
  unwound normally.

**Behaviour after the patch.**

| state | ESC | `e` / `E` |
|---|---|---|
| normal play | cmd 5 opens the fold-out. Refused (silently) if dead, animating (`E8 != 0`), `0x1471F0` or `0x14721A` (help/map, conversation, script lock). In combat it first calls `0x179EC`, as the menu button does. | toggles the log box (+ sound, + scroll reset on collapse) |
| fold-out open, idle / quit confirm / list with nothing picked | cmd 5 closes it (`0x2C2D4` clears `24CA`, `DC`, …) | toggles |
| slot picked or typing a save name | swallowed (unchanged) | typed into the name / swallowed in load mode (unchanged) |
| speaking | skips the line (unchanged, Space too [MOD]) | toggles only outside a conversation |
| conversation (not speaking) | swallowed (unchanged) | swallowed (the box is forced big anyway) |
| book view / opening hold / dead | ignored (unchanged) | ignored |
| picture modal `0x1525A0` | closes the modal (unchanged) | ignored |

**Caveats.**
- **Key repeat.** Holding the key re-sends KeyDown [INFERRED]. ESC is damped by cmd 5's
  `E8 != 0` refusal during the swing-in; `e` is not damped, so it flips at the repeat rate.
  Making it edge-only needs a state word, i.e. cave bytes.
- **Orrery.** It is not tested by the handler or by cmd 5. ESC (like stock `q`) can open the
  fold-out over the orrery puzzle [INFERRED; same exposure as stock].
- **No two-stage ESC.** A "close the list first, then the fold-out" ESC needs to read `0x1523DC`.
  That is an absolute obj2 address, which in-place code cannot carry without a fixup record. So
  ESC closes the whole fold-out.
- **Manifest.** Apply installs from the manifest, so all of this must be emitted by Build-AztMod
  (e.g. `key-esc-13713`, `key-esc-body-1369C`, `key-z-136C8`, `key-t1-1367A`, `key-e-135F6`,
  `key-E-13628`) and checked by `Assert-NoOverlap`.

---

## 6. Drawing and the rectangle to hide (question 6) [SEEN + MOD]

**The panel blit.** `0x14CFF`: `0x37D98(eax = 0, edx = 0x152120 src, ebx = 0x152150 view surface,
ecx = X, push Y)`.
- Stock: X = `0x179 + 7*(6 - step)` (imul at `0x14CE6`), Y `0x22`, 206x170.
- **[MOD]: X `0x43D` = 1085** (`0x14CF0`), **slide 0** (`0x14CE6` imul 0), **Y `0x28` = 40**
  (`0x14CE9`).
- [MOD] surface `0x152120` = **515 x 425** (`0x10CBF` w = `0x203`, `0x10CBA` h = `0x1A9`).
- View origin [MOD] = (0,49).

**Screen rectangle to hide: x 1085..1599, y 89..513 (515x425).** It is flush with the view's right
edge. Every one of the 14 frames uses the same rectangle: the swing-in is inside the art.
- The two bars are inside it: screen (1100,201) and (1100,283), 252x72 each.
- Index 0 is transparent in the art [INFERRED from Build-SysMenu's alpha→0].

**The slot list is outside this rectangle.** It is drawn into the same view surface at its own
place (the save/load doc §3), still at the stock spot, in-view x 150..341 / y 40..223 [MOD
unchanged]. The memory core already hides it via HideRect2.

**When it is drawn.** Every frame while `[0x1523EA] != 0` (including the close animation) and
`[0x1525A0] == 0`. There is no dirty flag. It is drawn after the inject hook `0x1419D`, so in
8-bit mode it lands on top of host pixels.

The bars are drawn only when idle (`E8 == 0`) and only if their sound is on.

**Host poll.** Read two blocks:
- `0x1523D6`, 0xF8 bytes, which the memory core already reads. It covers D6..EA, 24CA and 24CC.
- `0x14693A`, 0x10 bytes: toggles, levels, flashes, picture cache, selection.

To pick the host's picture state, reuse the save/load doc §1.4 order:
1. DE
2. E0
3. 24CA
4. 146942
5. 146944
6. idle

---

## 7. Snippet: decode any hot-spot table (stock or modded)

```powershell
. .\tools\load.ps1 -Exe C:\Games\AzraelsTear-Modded\GAME\AZRAEL\R.EXE; Initialize-Azt
function W16($a){ [BitConverter]::ToInt16($IMG.Slice([uint32]$a,2),0) }
foreach ($scr in 0..3) { $p = [BitConverter]::ToUInt32($IMG.Slice([uint32](0x14712E+$scr*4),4),0); $c = W16 $p; $p += 2
  for ($r=0; $r -lt $c; $r++) { $n = W16 $p; $pts = @(0..($n-1) | % { "({0},{1})" -f (W16 ($p+2+4*$_)), (W16 ($p+4+4*$_)) })
    $q = $p+2+4*$n; "s$scr r$r 0x{0:X} cmd={1} icon={2} {3}" -f $p, (W16 ($q+2)), (W16 ($q+4)), ($pts -join ''); $p = $q+6 } }
```
