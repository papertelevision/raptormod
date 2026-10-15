# Save/Load slot screen: reverse-engineering reference

Static analysis of the stock `GAME\AZRAEL\R.EXE`, using the `tools\load.ps1` toolchain. A few
checks were made against the installed modded `C:\Games\RaptorMod\game\GAME\AZRAEL\R.EXE`
and are labelled as such. Addresses are LINEAR (no 0x200000 load base). File offsets come from
`$IMG.FileOffsetOfLinear` (obj1: `file = 0x61A54 + (lin - 0x10000)`; obj2 data:
`file = 0x184A54 + (lin - 0x140000)`).

Confidence tags:
- **[SEEN]**: read directly in the disassembly.
- **[INFERRED]**: deduced from usage or naming, not proven.
- **[MOD]**: checked in the installed modded EXE.

Nothing was run. No game file, manifest or tool was modified.

---

## 0. The short version

| What | Where | Meaning |
|---|---|---|
| fold-out logically open | word `0x1523D6` | 0/1. Toggled by command 5. |
| fold-out visible / animating | word `0x1523EA` | 1 from open until the slide-out reaches step 0 |
| anim step / direction | word `0x1523E6` / word `0x1523E8` | step 0..6, dir +1 open, -1 close, 0 idle |
| **slot list showing** | word `0x1523DC` | 1 while the LOAD or SAVE list is up |
| **LOAD mode** | word `0x1523DE` | 1 = load list |
| **SAVE mode** | word `0x1523E0` | 1 = save list |
| quit confirm up | word `0x1524CA` | 1 = "quit?" confirm |
| what OK does | word `0x1524CC` | 0 load, 1 save, 2 quit |
| **selected row** | int16 `0x146948` | -1 none, 0..4 slot, **6 = RESTART** |
| fold-out picture cache | word `0x146946` | index N of `SAVE%02d.pcx` currently loaded; 0xFF forces a reload |
| slot names (live) | `0x152434 + 30*i`, i = 0..4 | NUL-terminated, 30-byte stride, edited in place |
| name backup | `0x152434 - 32` = `0x152414` (32 bytes) | original name of the selected slot |
| names on disk (mirror) | `0x184230 + 32*i` | SGDNAME.DAT records |
| active hot-spot screen | dword `[[0x182DB8] + 0x52]` | `0x164DAA` = screen 1, `0x164DB8` = 2, `0x164DC6` = 3 |
| save / load in progress | word `0x152B02` / word `0x152B04` | set around the file I/O |
| player dead | word `0x152904` | blocks SAVE, open/close and several commands [INFERRED name] |

**"Typing a save name"** is not a separate flag. It is `[0x1523E0] != 0 && 0 <= [0x146948] <= 4`.

---

## 1. State

### 1.1 The command dispatcher

Every fold-out control is a hot-spot polygon whose `flagB` word is a **command id**. The mouse
path at `0x16071..0x16077` takes the command byte from the event record and calls
`0x2C408(al = cmd)` [SEEN]. The keyboard dispatcher also calls it. `0x2C408` bounds-checks
1..26 and jumps through `cs:[0x2C3A0 + (cmd-1)*4]` (`0x2D0E7..0x2D0F6`). While a conversation
is up (`[0x152B1C]`), only commands 0x18 and 0x1A pass [SEEN].

| cmd | handler | what it does |
|---|---|---|
| 5 | `0x2C7BB` | toggle the fold-out (panel button / `q` key / scripted "savenow") |
| 7 | `0x2C6AF` | toggle SFX (`0x14693A`), flash picture 10 |
| 8 | `0x2C6FA` | toggle music (`0x14693C`), flash picture 9 |
| 9 / 10 | `0x2C9AE` / `0x2C9C0` | start dragging the SFX / music slider (`0x1523DA` / `0x1523D8`) |
| **11** | `0x2CAA3` | **SAVE button**: toggle the save list |
| **12** | `0x2C9D2` | **LOAD button**: toggle the load list |
| 13 | `0x2C8E6` | QUIT button: toggle the quit confirm |
| **14** | `0x2CB83` | **close box** (the 9x9 X at the list's top-left) |
| **15** | `0x2CBF3` | **click a slot row** |
| **16** | `0x2CCA1` | **OK / confirm** (screen 3 only; Enter also sends it) |
| **25** | `0x2C789` | **RESTART** button |
| 6, 24, 26 | ... | unrelated (catch-all, story log, conversation) |

### 1.2 Who writes what [SEEN]

**cmd 5 open, `0x2C7BB`.**
- Refuses if dead (`0x152904`), still animating (`0x1523E8 != 0`), `0x1471F0` or `0x14721A`.
- Toggles `0x1523D6`.
- On open, plays `hud3.wav` and sets `E8 = 1`, `EA = 1`, `DC = 0`, `146946 = 0xFF`, and
  `E0 = DE = 24CA = 146944 = 146942 = 0`.
- Selects hot-spot screen 1 and blits the lit button sprite `0x164E92`.
- On close it calls `0x2C2D4`.

**Close, `0x2C2D4`.**
- Plays `hud3.wav` unless dead. Sets `E8 = -1`, so the panel slides out.
- If `DC && sel != -1`, copies the backup `0x152414` back into slot `sel`.
- Clears `DC`, `D6`, `E0`, `DE` and `24CA`. Selects screen 0 and blits the unlit sprite `0x164E80`.
- Does **not** reset `0x146948`.
- Callers:
  - `0x2C8D8` (cmd 5);
  - `0x2CF3C` and `0x2D07E` (after a load or a save);
  - `0x16D92` (the death handler `0x16CCC`);
  - `0x17EA6` (the conversation opener `0x17E52`, which then also zeroes `D6` at `0x17EAB`).

**SAVE button, cmd 11, `0x2CAA3`.**
- Refuses if dead. Sets `24CA = 0`.
- **On:** `E0 = 1`, `DE = 0`, `DC = 1`, `146948 = -1`, screen 2, `24CC = 1`.
- **Off:** `DC = 0`, restore the backup into slot `sel`, `146948 = -1`, screen 1.

**LOAD button, cmd 12, `0x2C9D2`.**
- Sets `24CA = 0`.
- **On:** `DE = 1`, `E0 = 0`, `DC = 1`, `146948 = -1`, screen 2, `24CC = 0`.
- **Off:** as for SAVE.
- The On paths do NOT restore a name edited under the other mode, so a half-typed save name
  stays visible in the load list [SEEN, quirk].

**QUIT, cmd 13, `0x2C8E6`.**
- **Off → on:** `E0 = DC = DE = 0`, restore the backup, `146948 = -1`, `24CA = 1`, `24CC = 2`,
  screen 3 (so OK is live).
- **On → off:** `24CA = 0`, screen 1.

**Close box, cmd 14, `0x2CB83`.**
- `E0 = DE = DC = 0`, restore the backup, screen 1.
- Leaves `0x146948` stale. It is harmless because the next list open resets it.

**Row click, cmd 15, `0x2CBF3`.** See §4.

**RESTART, cmd 25, `0x2C789`.**
- `146948 = 6`, `24CC = 0`, screen 3. It does not back up or restore anything.

**Other writers of the whole set.**
- `0x15406..0x15521` [SEEN] force the fold-out OPEN (`D6 = E8 = EA = 1`, everything else
  cleared, screen 1).
- `0x17575..0x17680` [SEEN] are a duplicate of that block.
- Both are default cases of state machines in the death/event path. My reading [INFERRED] is
  that after the player dies the fold-out is opened for you; SAVE is then refused by the
  `0x152904` check while LOAD still works.
- `0x16E95` [SEEN] is a case in the game-event switch at `0x16CCC` (fixup at `0x16CF0`). It
  issues cmd 5 and plays `savenow.wav`, i.e. a scripted "save now" prompt.

**Keyboard.**
- `q` / `Q` (`0x13599` via `0x135A1`): if `[0x152AFC] == 0` it issues cmd 5 and sets
  `0x15259A = 1`.
- On the first idle frame (step 6, not animating), `0x1496C..0x1497B` sees `0x15259A`, issues
  **cmd 13** (the quit confirm) and clears it.
- If `[0x152AFC]` is set, `q` quits outright (`0x152176 = 1`).
- **ESC does nothing to the fold-out in stock.** 0x1B falls through `0x13713` to the exit
  [SEEN].

### 1.3 Values for each situation

| situation | D6 | EA | DC | DE | E0 | 24CA | 24CC | 146948 | hot-spot screen |
|---|---|---|---|---|---|---|---|---|---|
| fold-out open, idle | 1 | 1 | 0 | 0 | 0 | 0 | - | stale | 1 |
| load list, nothing picked | 1 | 1 | 1 | 1 | 0 | 0 | 0 | -1 | 2 |
| load list, slot picked | 1 | 1 | 1 | 1 | 0 | 0 | 0 | 0..4 | 3 |
| load list, RESTART picked | 1 | 1 | 1 | 1 | 0 | 0 | 0 | 6 | 3 |
| save list, nothing picked | 1 | 1 | 1 | 0 | 1 | 0 | 1 | -1 | 2 |
| **typing a save name** | 1 | 1 | 1 | 0 | 1 | 0 | 1 | 0..4 | 3 |
| quit confirm | 1 | 1 | 0 | 0 | 0 | 1 | 2 | -1 | 3 |
| closing (sliding out) | 0 | 1 | 0 | 0 | 0 | 0 | - | stale | 0 |

`0x1523D6` is therefore only "the fold-out is up". It never takes values other than 0/1 from
these writers.

### 1.4 The fold-out picture index (`SAVE%02d.pcx`)

The picture choice is in `0x149AA..0x14A69`, loaded at `0x14A70..0x14AA7` into surface
`0x152120` only when it differs from word `0x146946` [SEEN].

| condition (first match) | picture |
|---|---|
| DE and sel == -1 | 8 |
| DE | 13 |
| E0 and sel == -1 | 7 |
| E0 | 12 |
| 24CA | 11 |
| 146942 (music toggle flash) | 9 |
| 146944 (sfx toggle flash) | 10 |
| step > 5 and dir == 0 | 6 |
| otherwise (sliding) | animation step 0..5 |

Pictures 12 and 13 are the variants with the OK prompt drawn. The fold-out is blitted at
`0x14CFF` by `0x37D98`. In stock that is X `0x179 + 7*(6-step)`, Y 0x22. **[MOD]** It is X
0x43D, Y 0x28, with no slide.

---

## 2. Slot data

### 2.1 In memory [SEEN]

- **`0x152434 + 30*i`, i = 0..4.**
  - The live names that are drawn and edited: a NUL-terminated char[30], 150 bytes in all.
  - Draw loop: `imul edx,eax,0x1E` / `add edx,0x152434` (`0x14C4E` / `0x14C5A`).
  - Editors: `0x12DCF..0x12E4F`.
- **`0x152414`** is a 32-byte backup of the selected slot's original name, so it ends exactly
  where the array starts.
  - Written by cmd 15 (`0x2CC5A..0x2CC8D`, `strcpy(0x152414, slot[sel])`).
  - Restored by commands 11/12 off, 13, 14 and 15, and by `0x2C2D4`.
  - On a successful SAVE it is re-written from the slot (`0x2CF79..0x2CFB0`) before the file
    write.
- **`0x184230 + 32*i`** is the SGDNAME.DAT image: `char name[30]` plus `uint16 empty` at
  +0x1E. `0x18424E + 32*i` is that flag.
- **Init.** `0x2D330` (called from `0x16155`) first calls `0x4AB6C`, which fopens
  `SGDNAME.DAT` "rb" and freads 5 records of 32 bytes into `0x184230`. It then copies each
  name to `0x152434 + 30*i`.
- **No SGDNAME.DAT.** If the file is missing, every name becomes `""` (the string at
  `0x14433B` is empty) with `empty = 1`.
- **Slot 6 (RESTART)** has no name record. `slot[6]` would be `0x152434 + 180 = 0x1524E8`,
  which is **inside another object at `0x1524D0`** (+0x18). See §8, risk 1.

### 2.2 Where "EMPTY" and "RESTART" come from

- **"EMPTY" is literal data** in the shipped `SGDNAME.DAT`. Every stock record starts
  `"EMPTY\0"` with `empty = 0`, followed by leftover dev text such as `"SAVE"`,
  `"SDHFKASDJFHASKDFJH"` and `"OOM 17"`. The game has no "EMPTY" string of its own.
  - Matching `SAVE0..4.DAT` files ship too (16756 bytes each), so loading an "EMPTY" slot
    loads a real starting state.
  - The modded install's file holds `NEFFFG`, `FRTHER 3 VE`, `EMPTY`, `EMPTY`, `ECON VE`, which
    matches the screenshot.
- **"RESTART"** is a separate button, drawn from the two string copies at `0x140654` and
  `0x14065C`. It is not a slot row. Picking it loads **slot 6**, i.e. `SAVE6.DAT` (shipped)
  [SEEN, file name by construction].

### 2.3 On disk [SEEN]

- **`SGDNAME.DAT`**: 160 bytes = 5 x {char name[30]; uint16 emptyFlag}. It is written whole
  ("wb") by `0x4A740` after every save.
- **`SAVE%d.dat`**: the format at `0x14430C`, built by `0x4AC20(eax = buf, edx = slot)`.
  - Written by `0x4A740(eax = name*, edx = slot)` ("wb"). That routine first does
    `strcpy(0x184230 + 32*slot, name)` and sets `empty = 0`.
  - Read by `0x4A994(eax = slot)` ("rb").
- **`DEDCHA%d.SAV`** holds the dead characters for each slot.
  - Save: `0x1B46E(0x152548, slot)` and `0x22744(slot)`; the string is at `0x1421A5`.
  - Load: `0x1B60D(0x152548, slot)` and `0x224E0(slot)`; the string is at `0x14202D`.
- **Missing checks.** The load path reads the `empty` flag (`0x4A9AE`) and the fopen result,
  but never branches on either; Watcom's checks are compiled out [SEEN]. Loading a slot whose
  `SAVEn.DAT` is missing probably crashes [INFERRED].
- **Name limits.** At most **20 characters** (`cmp esi,0x14` at `0x12E27`). They are
  uppercased by `0x3E314` (a..z only) and limited to 0x20..0x7F.

---

## 3. Drawing

### 3.1 Where and when [SEEN]

The list is drawn inside the per-frame body (the analyzer labels it `fn 16043`, a fixup seed;
the code lives at `0x148FC..0x14EEE`). The order within one frame is:

```
0x14182  call 0x3F0D0          ; clear the view
0x14187  call 0x3F1B0          ; Reality Lab scene pass
0x1419D  call 0x3F2F0          ; <-- AztViewInject hook site (host pixels enter here)
...
0x1484F  cmp word [0x1525A0],0 ; another modal up? -> skip ALL of this (jnz 0x15040)
0x148FC  cmp word [0x1523EA],0 ; fold-out visible?  no -> 0x14EEE
0x1490A..0x149A3               ; advance step/dir; plays hudlockr.wav on reaching 6
0x149AA..0x14AA7               ; choose and (re)load SAVE%02d.pcx
0x14AAD  cmp word [0x1523DC],0 ; slot list showing? no -> 0x14CDA
0x14ABB..0x14CD5               ; THE LIST (background, close box, RESTART, 5 rows)
0x14CDA..0x14D04               ; fold-out panel blit (0x37D98)
0x14D04..0x14EEE               ; volume sliders
```

- **Target.** Everything is drawn into the 3D view surface **`0x152150`** (buffer `[0x152154]`)
  in view-relative pixels. The surface is presented to the screen later, at the view origin.
  - Stock origin: (44, 49).
  - **[MOD]** origin: (0, 49), which is why the list sits at the top-left.
- **Redraw.** The list is redrawn **every frame** from the current state; there is no dirty
  flag. It is drawn after the inject hook, so in 8-bit mode the game's list lands on top of
  injected host pixels.

### 3.2 Primitives [SEEN]

| routine | signature |
|---|---|
| `0x128BC` | `Stipple(eax=x, edx=y, ebx=w, ecx=h, push color)`. Every other pixel, straight into `[0x152154]` with stride imm32 at `0x1291F` (stock 0x228 = 552; **[MOD]** 0x640 = 1600). `ret 4`. |
| `0x12820` | `RectOutline(eax=x, edx=y, ebx=w, ecx=h, push color)` on 0x152150, built from 4 lines. `ret 4`. |
| `0x3847C` | `Line(eax=surf, edx=x0, ebx=y0, ecx=x1, push color, push y1)`, i.e. y1 is the last push |
| `0x38EC8` | `DrawString(eax=surf, edx=font, ebx=x, ecx=y, push char*)`. `ret 4`. |
| `0x39AD2` | `sprintf` (cdecl) |

Fonts:
- `[0x152178]` = **rusgld2.pcx** (gold): unselected rows and unselected RESTART. The mod
  regenerates this file as `art\RUSGLD2.PCX` for the log, and the list inherits it.
- `[0x15217C]` = **genblu2.pcx** (blue): the selected row and RESTART when selected.
- Both are loaded at `0x10CDD..0x10CFB`.

### 3.3 Geometry: all constants in code, no table [SEEN]

View-relative coordinates. Stock screen = view + (44, 49). **[MOD]** screen = view + (0, 49).

| element | values | sites (lin / file) |
|---|---|---|
| darkening stipple | x 150, y 40, w 200, h 150, color 0 | `0x14ABD` ecx=0x96 (h, also copied to eax as **x**) / 0x66511; `0x14AC2` ebx=0xC8 w / 0x66516; `0x14AC7` edx=0x28 y / 0x6651B; `0x14ABB` push 0 color |
| close box | rect (154, 44) 9x9, colour 0x38; X lines (154,44)-(162,52) and (162,44)-(154,52) | `0x14AD3..0x14B20`: imm32 0x9A, 0x2C, 9, 0xA2; imm8 0x34 (y1) and 0x38 (colour) |
| RESTART box (load mode only) | rect (220, 41) 60x17, colour 0x37 | `0x14B40..0x14B51` and the duplicate `0x14B77..0x14B88` (eax 0xDC, edx 0x29, ebx 0x3C, ecx 0x11) |
| RESTART text | (223, 44) | `0x14B65` / `0x14B9C` ebx=0xDF; `0x14B60` / `0x14B97` ecx=0x2C |
| row text X | 158 | `0x14BD2` (unselected) and `0x14C77` (selected): `mov ebx,0x9E`, files 0x66626 / 0x666CB |
| row text Y | 66 + 24*i | `0x14BB1` `mov eax,0x42` (file 0x66605) |
| left tick | x 154, y 65+24i .. 79+24i | `0x14BB8` `mov edx,0x41` (0x6660C); x `0x14BF3` / `0x14CA7` `mov ecx,0x9A` |
| underline | y 79+24i, x 154..341 | `0x14BC8` `mov edi,0x4F` (0x6661C); x1 `0x14C0A` / `0x14CBE` `mov ecx,0x155` |
| row pitch | 24 | **imm8** `add edi,0x18` `0x14C2A`, `add ecx,0x18` `0x14C2D`, `add ebx,0x18` `0x14C31` (files 0x6667E / 0x66681 / 0x66685) |
| row count | 5 | imm8 `cmp eax,5` `0x14C45` (0x66699) |
| line colour | 0x39 unselected, 0x37 selected | imm8 pushes `0x14BEE`, `0x14C08` / `0x14CA2`, `0x14CBC` |

All of the above are **free of fixups**. These bytes in the same range DO carry fixups (never
patch them):
- `0x14AFF`, `0x14B1C`, `0x14B6B`, `0x14BA2`, `0x14BD8`, `0x14BF9`, `0x14C16`, `0x14C96`,
  `0x14CAD`, `0x14CCA` → 0x152150;
- `0x14B71`, `0x14C90` → 0x15217C;
- `0x14BA8`, `0x14BDF` → 0x152178;
- `0x14C5C` → 0x152434;
- `0x14B34`, `0x14C53` → 0x146946;
- `0x14C70` → "%s_";
- `0x14B5C`, `0x14B93` → the RESTART strings;
- `0x14AB0` → 0x1523DC; `0x14B28` → 0x1523DE.

The pitch immediates are imm8 and cannot exceed 127.

### 3.4 Row loop excerpt [SEEN]

```
14BB1 mov eax,0x42 / mov edx,0x41 / [ebp+6E]=66 textY, [ebp+72]=65 tickTop, edi=0x4F underlineY, [ebp+6A]=i=0
14C3F i = word[ebp+6A]; if i >= 5 -> 0x14CDA
14C4E edx = 0x152434 + i*30
14C51 if i != word[0x146948] -> 14BCF (normal) else selected:
14C68   sprintf(buf, "%s_", name)            ; selected row gets a trailing '_' cursor
14C88   DrawString(0x152150, [0x15217C] genblu, 158, textY, buf)
14CA2   Line(154,tickTop)-(154,underY) c=0x37 ; Line(154,underY)-(341,underY) c=0x37
14BCF normal: DrawString(0x152150, [0x152178] rusgld, 158, textY, name)
14BEE   Line(...) c=0x39 ; Line(...) c=0x39
14C21 textY+=24, tickTop+=24, underY+=24, i++
```

### 3.5 Highlight and hover

- **Highlight.** The only one is the **selected** row (`0x146948`): blue font, colour 0x37
  rules, plus a trailing `_` in BOTH modes.
- **Hover.** There is no per-row hover state anywhere. Hovering only changes the cursor icon
  through the hot-spot region's `icon` word (=1 for every row). The hovered row is not stored,
  so a host has to derive it from the cursor (§4.2).

---

## 4. Hit testing

### 4.1 Hot-spot polygons

The tables live in obj2 data; the format is in `azrael-panel-button-rects` memory. The slot
list exists on **screen 2** (no selection) and **screen 3** (selection present: adds OK).

Stock screen coords:

| table entry | lin | stock polygon | cmd |
|---|---|---|---|
| s2 r8 / s3 r9 | `0x146D2A` / `0x146EDC` | close box (198,93)-(206,101) | 14 |
| s2 r9..r13 / s3 r10..r14 | `0x146D42`, `0x146D5A`, `0x146D72`, `0x146D8A`, `0x146DA2` / `0x146EF4`, `0x146F0C`, `0x146F24`, `0x146F3C`, `0x146F54` | rows: x 198..389, y **114+24i .. 127+24i** (13 tall; the 11-px gaps are dead) | 15 |
| s2 r14 / s3 r15 | `0x146DBA` / `0x146F6C` | RESTART (264,90)-(323,103) | 25 |
| s3 r8 | `0x146EC0` | OK prompt (459..495, 209..221) | 16 |

Each record is `word n; int16 x,y[n]; word flagA; word flagB(cmd); word icon`. The points
start at record + 2; patch the int16 pairs (file = `0x184A54 + lin - 0x140000`).

**[MOD] installed values.**
- Close box (154,93)-(162,101).
- Rows x **154..345**, y unchanged (114..223); the `inView` rule only shifts X by -44.
- RESTART (220,90)-(279,103).
- OK (1193..1351, 417..457) on the rebuilt fold-out.
- The cursor (`0x182D6C` / `0x182D6E`) is in 1600x1200 screen pixels, so the list is still
  native-size at the top-left.

### 4.2 The row math, `0x2CBF3` [SEEN]

The polygon only decides THAT a row was hit. WHICH row comes from the cursor Y alone:

```
2CBF3  if word[0x146948] != -1: strcpy(slot[sel], 0x152414)   ; undo edits on the old row
2CC30  movsx edx, word [0x182D6E]     ; cursor Y (screen px)
2CC37  sub   edx, 0x72                ; 83 EA 72   imm8!  file 0x7E68B
2CC3A  mov   ebx, 0x18                ; BB 18 00 00 00     file 0x7E68E
2CC3F  mov   eax, edx / sar edx,0x1F / idiv ebx
2CC46  mov   [0x146948], ax           ; row = (Y - 114) / 24   -- NO range check
2CC4C  strcpy(0x152414, slot[row])    ; back up the new row's name
2CC8E  hot-spot screen 3 (0x164DC6)   ; OK becomes clickable
```

### 4.3 Making rows taller or moving them

To move or enlarge the rows, three things must agree:
1. the 10 row polygons (data; free to rewrite);
2. `0x2CC37` TOP and `0x2CC3A` PITCH (code);
3. the draw constants in §3.3, which only matter in 8-bit (retro) mode.

Limits and options:
- `sub edx,imm8` caps TOP at 127. In place, `0x2CC37..0x2CC40` (10 bytes, **no fixups**,
  verified) can become `lea eax,[edx-TOP32]` (6) + `push PITCH8; pop ebx` (3) + `nop`.
  - That removes the `mov eax,edx` at `0x2CC3F`.
  - The following `sar edx,0x1F` then works on the raw cursor Y (always >= 0), which is
    correct for every Y on or below the first row.
  - That allows TOP up to 2^31 and PITCH up to 127.
  - A larger PITCH needs a trampoline.
- The draw pitch at `0x14C2A` / `0x14C2D` / `0x14C31` is imm8 too (max 127).

### 4.4 What a click does in each mode [SEEN]

**Row click (cmd 15).** Selects the row in either mode. It never loads or saves.

**OK (cmd 16, `0x2CCA1`; Enter also sends it).** It first does screen 1 and
`E0 = DE = DC = 0`, then branches on `[0x1524CC]`:

- **0 = LOAD:**
  1. `0x152B04 = 1`, then `0x177A8`. Clears the HUD text, `0x152904 = 0` (revive) and
     `0x147214 = 0`.
  2. Drains mouse events (`0x36599` loop).
  3. **`0x4A994(slot)`**. This is the site the mod hooks: **[MOD]** `0x2CD63` → `0x134F71`,
     "re-boot the visor on load".
  4. `0x1B60D(0x152548, slot)`, `0x224E0(slot)`, `0x111A8`, `0x1E1B0(slot)`, camera and
     scene rebuild, `0x27B38(0x1521C4, slot)`.
  5. `0x2C2D4` (close), `0x152B04 = 0`, `146948 = -1`.
- **1 = SAVE:**
  1. `0x177A8`, `0x152B02 = 1`.
  2. `0x108D8` posts "Saving Game...." (`0x146950`).
  3. Commits the backup = name, then `0x1E224`, `0x1CD8C`, ...
  4. **`0x4A740(name = 0x152434 + 30*slot, slot)`** writes `SAVEn.DAT` and `SGDNAME.DAT`.
  5. `0x1B46E`, `0x27754`, `0x22744(slot)` (DEDCHA).
  6. `0x35448(0xBB8)`, a 3000 ms wait [INFERRED: delay]. `0x109AC` removes the message.
  7. `0x152B02 = 0`, close, `146948 = -1`.
  - An empty name is saved as-is; there is no check.
- **2 = QUIT:** `0x152176 = 1` (exit), `146948 = -1`.

---

## 5. Save-name entry (keyboard) [SEEN]

Everything sits in the KeyDown dispatcher `0x12B88` (event in ebx, ASCII at +6). It runs
**before** the normal game keys, so while it applies, every key is consumed.

```
12CAD  if [0x1524CA] && ascii == 0x0D -> cmd 16                  ; Enter confirms Quit
12CCB  if ([0x1523E0] || [0x1523DE]) && word[0x146948] != -1 -> 12DCF
12DCF  len = strlen(0x152434 + 30*sel)
12DEB  ascii <  8           -> 12DFC
       ascii == 8 (BkSp)    -> 12D78: if save mode && len: name[len-1] = 0
       ascii == 0x0D (Enter)-> 12DB9: cmd 16 (OK)  -- both load and save
12DFC  if !save mode          -> consume, return              ; load: every other key swallowed
       if ascii < 0x20 or > 0x7F -> consume, return           ; ESC/arrows swallowed too
       if len >= 20 (0x14)       -> consume, return
       name[len] = toupper(ascii) (0x3E314); name[len+1] = 0   ; 0x12E46 / 0x12E4F
```

- **Buffer:** the slot's own entry `0x152434 + 30*sel`, edited in place. There is no separate
  edit buffer and no cursor-position variable; the cursor is always at the end (`len`).
  The original is in `0x152414`.
- **Confirm:** Enter or the OK hot spot (cmd 16).
- **Cancel:** there is no key.
  - Cancel by clicking another row, the close box (cmd 14), SAVE again (cmd 11), LOAD, QUIT
    or the panel button (cmd 5).
  - Each of these restores `0x152414` into the slot. Exception: LOAD-on (§1.2) does not.
- **No selection:** with a list up and `sel == -1`, keys fall through to normal gameplay
  handling.

---

## 6. Closing

| how | effect |
|---|---|
| load completes | `0x2C2D4` (slide-out) + `146948 = -1` + `152B04 = 0` |
| save completes | same, after the 3 s "Saving Game...." |
| close box (cmd 14) | list off (`DC/DE/E0 = 0`), fold-out stays open at picture 6 |
| SAVE / LOAD button again | that list off; picture 6 |
| panel button (cmd 5) / `0x2C2D4` | fold-out closes: `D6 = DC = DE = E0 = 24CA = 0`, `E8 = -1`; `EA` stays 1 until step reaches 0 (`0x14990..0x149A3` then clears `E8` and `EA`) |
| conversation starts | `0x17E52` → `0x2C2D4`, and `D6 = 0` at `0x17EAB` |
| player dies | `0x16CCC` → `0x2C2D4` (then the fold-out is re-opened by the death sequence [INFERRED]) |
| ESC | **nothing** in stock |
| clicking elsewhere | nothing; outside the polygons there is no command |

**Restoring the hot-spot screen.** The code that restores it after other modals (`0x132EE`,
`0x16C4B`) picks screen 0, 1 or 2 from `D6` / `DC` only. It never picks 3, so after such a
restore the OK hot spot is gone until a row is clicked again; Enter still works [SEEN, quirk].

---

## 7. Notes for a host overlay that draws the list large

1. **Poll once per frame.**
   - **List visible:** `[0x1523EA] && [0x1523DC]`.
   - **Mode:** `[0x1523DE]` = load, `[0x1523E0]` = save.
   - **Quit prompt:** `[0x1524CA]`.
   - **Selection:** int16 `[0x146948]` (-1, 0..4, or 6).
   - **Names:** 5 x 30 bytes at `0x152434`.
   - **Typing:** `E0 && sel in 0..4`, cursor = strlen.
   - **Gadget gone:** `0x1525A0 != 0` hides the whole block; so does `D6 == 0` after the slide.
2. **No dirty flag.** The state can change on any keypress or click, and the game redraws the
   list every frame. Re-read every frame; do not cache.
3. **True-colour mode.** The game's own list is painted into the 8-bit view surface, which the
   host's window covers. The host must draw the list itself whenever DC is set, exactly as for
   the book view (`0x15257C`).
4. **Clicks still go through the game's polygons and the Y math.** Either:
   - (a) relocate the 10 row polygons + `0x2CC37` / `0x2CC3A` (§4.3), plus the close box and
     RESTART polygons, to the host's large layout; or
   - (b) leave them alone and have the host translate its pointer.

   (a) is a pure-data change for everything except the two row-math constants, and it keeps
   Enter / typing / OK untouched.
5. **Highlight.** The game itself highlights only the selected row, with `_` appended. Hover
   must be computed by the host as `row = (Y - TOP) / PITCH`, valid only inside a polygon's Y
   band.
6. **Fold-out picture.** `0x146946` is a picture cache, not the state. Derive the state from
   the table in §1.4.
7. **Sounds come for free.** `hud3.wav` (open/close, hooked by the mod as `AztWhooshGate`) and
   `hudlockr.wav` (on reaching step 6).

## 8. Risks and quirks found [SEEN unless noted]

1. **RESTART corrupts memory.**
   - Cmd 25 sets `sel = 6` without a backup. Any later restore (close box, list toggle,
     another row, close) then does `strcpy(0x152434 + 180 = 0x1524E8, backup)`.
   - That writes up to 21 bytes into the object at **`0x1524D0`** (+0x18), which has about
     30 users.
   - Reachable by clicking RESTART and then the close box.
2. **RESTART is clickable in save mode.** Its hot spot is present on screens 2 and 3 in SAVE
   mode even though it is only drawn in LOAD mode. Clicking that invisible spot and then OK
   *loads* SAVE6 (`24CC` is forced to 0).
3. **Row click has no range check.** It relies entirely on the polygons.
4. **Load does not check for a missing save** (§2.3). A missing `SAVEn.DAT` is unhandled
   [INFERRED crash].
5. **Missing SGDNAME.DAT gives blank names.** A fresh install without it shows five blank rows
   (names ""), not "EMPTY".

## 9. Addresses touched by the mod in this area [MOD]

- `0x2C2E8`, `0x2C85E`: `call 0x100BC` → `0x133CD0` (AztWhooshGate).
- `0x2CD63`: `call 0x4A994` → `0x134F71` (re-boot the visor on load).
- `0x14CE6` / `0x14CE9` / `0x14CF0`: fold-out slide 0, Y 0x28, X 0x43D.
- `0x14D26` ... `0x14EC9`: sliders.
- `0x1291F`: stipple stride 0x640.
- Screen 2/3 polygons: rows / close / RESTART shifted to x - 44; fold-out controls remapped.
- **No mod patch touches** the row-draw constants, `0x2CBF3`'s math, or the typing code.
