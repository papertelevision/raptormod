---
name: azrael-texture-format
description: The .RES texture bundles fully decoded — D3DRMIMAGE records with per-texture palettes and a static-Huffman pixel codec at 0x2D558. Textures are redirectable via RESOURCE.CFG with no patch at all.
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-10-04T03:58:49.673Z
---

Solved 2026-09-22. The whole texture pipeline, verified against **all 179 rooms
and 2,909 textures with zero parse failures** (two independently written parsers
agreed exactly).

## Where the art lives

`AZT.BIN` is a 511 MB MODE1/2352 ISO (user data at `lba*2352+16`). Root holds
`AZRAEL.EXE`, `MOV\`, `SOUNDS\`, `TEXTURES\`. `TEXTURES\` has 179 `.RES` + 179
`.XAF` pairs (one per room) plus `BOOKS\` (PCX), `MAPS\`, `WIRE\`.

**`.XAF` IS PLAIN TEXT** — a scene description with `material`, `mesh`,
`vertices`, `faces`, `texture_coordinates`, `normals`, `animation` blocks. Each
material names its texture: `texture "toarms.gif"`. The source art really was
GIF; the `.RES` is the preprocessed bundle.

**THE BUNDLE HAS NO NAMES OR INDEX.** Entries are matched to the `.XAF`'s
textures by **first-appearance order**, not alphabetically — getting that wrong
mislabels everything (it did once: the file "toface" turned out to be a torso).

## `.RES` = concatenated `.azf` records

```
dword payloadLength        (bytes after this dword)
D3DRMIMAGE, 60 bytes:      width, height, aspectx, aspecty, depth, rgb,
                           bytes_per_line, buffer1, buffer2,
                           red/green/blue/alpha masks, palette_size, palette*
palette   palette_size*4   (r, g, b, flags)
pixels    Huffman stream   (see below)
```

File offsets are struct offsets **+4** (the length dword). Loader `0x1E944`:
`fread(4)` the length, `fread(0x3C)` the image struct, `fread(palette_size*4)`
into a stack buffer, `fread(rest)` into a scratch buffer, then decompress.
Palettes are then shifted right by 2 (`sar eax,2`) — 8-bit art, 6-bit VGA DAC.

Reached from the XAF parser: `texture "x.gif"` -> `0x29C52` -> `GetTexture2`
(`0x285E0`) -> cache miss -> the extension is rewritten **in place** to `.azf`
(bytes `61 7A 66` at `0x28704`) -> `0x1E944`.

Sizes in use: 128x128 x507, 256x256 x1534, 512x512 x141, 512x256 x66,
256x512 x109 ... all powers of two, **512 already used in both axes**, so
doubling the common 128/256 sizes is not new ground for the engine.

## The pixel codec: static Huffman, `0x2D558`

Thirty instructions, cdecl `(src, dst)` via the thunk `0x2D54D`.

```
dword uncompressedSize
dword rootNode                 (256..511)
uint16 tree[1024]              (2048 bytes)
bitstream                      little-endian dwords, LSB first, 32 bits per word
```

```
node = rootNode
while node >= 0x100:                 # >=256 is an internal node
    bit  = next bit                  # sar eax,1 -> CF
    node = tree[node*2 + bit]        # adc/lea/mov bx,[ebx+edi]
emit (byte)node                      # <256 is the literal
```

Leaves are 0..255, internal nodes 256..511, so only table entries 512..1023 are
ever read. Compresses to 31-64%. **Encodable as well as decodable** — building a
Huffman tree and emitting this table is straightforward, which is what makes
re-importing modified art possible at all.

Working decoder + PNG exporter written this session (see the transcript's `Azf`
class): decodes all five AMTOB textures to exactly `bytes_per_line * height`.

### THE LAST RECORD IN EVERY FILE NEEDS 4 BYTES OF SLACK (fixed 2026-10-03)

The decoder does `dec cx` and refills **before** testing whether the next step
exits to a leaf, so the stream must always have one more dword readable past the
last bit actually used. Intermediate records get that for free from the record
that follows them. **The last record in the file has nothing after it**, so a
host decoder reading with `BitConverter.ToUInt32` runs off the end and throws.

That cost 7 textures — and the "2,909 textures, zero parse failures" claim above
is about *parsing*, which hid it. The failures were **CORICORI (spadoor, the
door texture used by both doors in the opening room), CHAPEL, R1, SPACORI, THEO,
THEONEW, IKTEST** — and in all 7 it was the **last** record, which is the tell.
If a decode ever fails, check the index against `count-1` before suspecting the
art.

Fix in `tools\AzfTool.cs`: a `Dword(b,p)` helper that zero-fills past the end.
The bits are never consumed (the loop is driven by `outLen` and the final leaf
is already reachable), so this is **bit-exact, not an approximation** — verified
by all 7 filling their exact `BytesPerLine * Height`, and spadoor rendering as a
recognisable wooden door. Now **2,909 of 2,909 decode**.

The game is unbothered by this because under DOS the four bytes past the read
buffer are just slack heap.

## TEXTURES ARE REDIRECTABLE WITH NO PATCH

`0x1BD04` reads **`GAME\AZRAEL\RESOURCE.CFG`**, three plain-text lines, into
`[0x162B68]` (textures), and two more for sounds and movies:

```
D:\TEXTURES\
D:\SOUNDS\
D:\MOV\
```

Point line 1 at a folder on C: and the game loads textures from the hard disk.
**No code patch and no ISO rebuild** — which is the whole reason an art
replacement project is tractable here. (Missing the file is fatal:
`IDataManager / "Could not find RESOURCE.CFG file..."`.)

## For an uprez attempt

Each texture carries its **own private 256-entry palette**, so unlike the HUD
([[azrael-palette-budget]]) there is no shared-index budget to respect — an
upscale only needs requantising to 256 colours per texture, and
`tools\Quantize.cs` already exists.

Watch: the 24 MB texture cache (`GetTextureMemory`, and the real fatal
`"Not enough space in texture cache for %d bytes"`) at 4x the data per texture;
and style drift between neighbouring tiles, which reads worse than honest
chunkiness.

## The FLAT 2D art is a much easier target than the 3D textures

`TEXTURES\` also holds three folders of ordinary PCX, no .azf container involved:

* **`BOOKS\`** — 91 readable pages at **640x480, 8bpp**: journal entries, scrolls,
  documents. Named `<room>_<n>_<page>.pcx`. The "Press right mouse button to
  exit book view mode" prompt is BAKED INTO THE ARTWORK, so a replacement must
  redraw it.
* **`MAPS\`** — 79 usable images: ten 640x480 (MAPBKGRD, CLOISTER, BOAT, HELP,
  ORRERY, GIBBIT5...) plus ~15 per-room top-down maps at ~320x300 named after
  the room (KITCHEN, PERILOUS, ENTRY_D, THEOTRAP...). The remaining 121 are 5xN
  corridor strips for the automap, not worth touching.
* **`WIRE\`** — 70 inventory items x ~10 frames each at 140x120. These are
  ROTATION ANIMATIONS (1FLASK00..09), so AI upscaling breaks frame-to-frame
  consistency; treat as a poor target.

**BOOK PAGES CARRY THEIR OWN PALETTE.** `0x1648C` calls `0x3E7B4` = `LoadPCXPal`
(named by its own error string) on the same file right after `0x38A20` loads the
pixels, so a replacement page is free to use any 256 colours — no shared-palette
budget, unlike the HUD.

**Book pages are now rescaled to the screen (2026-09-23).** They load into
surface `0x152580`, which `scr-w/h-116C2` already grew to the full screen. A 1:1
blit means raising the resolution makes a page physically SMALLER -- 86% of the
width at 640x480, 69% at 800x600, 54% at 1024x768 -- and centring never touched
that. `src\Build-Books.ps1` rescales all 91 pages to the screen size at install
time (better than a runtime scaler: once, with a real resampler, no code cave),
keeping each original beside it as `.PCX.src` so a re-run never rescales its own
output. The page then lands at (0,0), which is stock, so `book-centre` /
`AztBookPos` drop out of the build entirely -- 20 bytes back in a full blob.
`$BOOK_FULLSCREEN` and the manifest's `art.bookFullscreen` keep the build and the
installer in step; if the art is not rescaled and the patch is gone, every page
sits in the TOP-LEFT corner.

The bounds test accepts an exactly-fitting image: `0x3E443` is `jg` on
xOff+width vs surface width, `0x3E47A` is `jl` on surface height vs
yOff+height -- so 1024 into 1024 passes.

**The quantiser must use 128 colours at base index 128.** Measured on every stock
page: zero pixels below 128. Entries 0..127 are copied from the stock page
untouched. Using all 256 is what turned an earlier replacement into a screenful
of dithering dots.

Export/import both directions with `tools\PcxTool.cs`; these are plain PCX, so
no Huffman and no D3DRMIMAGE wrapper.

Related: [[azrael-texture-cache-reserve]], [[azrael-reality-lab-engine]]
