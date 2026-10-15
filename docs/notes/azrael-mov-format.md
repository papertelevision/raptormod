---
name: azrael-mov-format
description: The .MOV (IAnimation) format is FULLY SOLVED - decoder AND encoder. All 10 CD movies round-trip with zero differing pixels; AVI export works too.
metadata:
  node_type: memory
  type: reference
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-09-29T00:41:27.767Z
---

Azrael's cutscenes are `MOV\*.MOV` on the CD (`AZT.BIN`), plus `MINDLOGO.MOV` and a short
`INTRO.MOV` on the hard disk. **Not QuickTime** — a custom container the engine calls
`IAnimation`. Layout read out of R.EXE, not guessed, and every shipped file parses to the
exact byte with zero bytes left over.

## Container

```
FILE HEADER, 30 bytes                  (constructor 0x2026C reads exactly 0x1E)
  +00 u32  magic 0xAB12EF90            ; else "Invalid animation header if file %s"
  +04 u16  frame count
  +06 u16  fps  (always 12)
  +08 u16  width
  +0A u16  height
  +0C..1D  not touched by the constructor

FRAME HEADER, 16 bytes                 (DecodeAnimationFrame 0x20A2C)
  +00 u32  magic 0xEE9901CF
  +04 u16  chunk count
  +06 u32  decompressed size
  +0A u32  compressed size              ; ZERO = payload stored raw

CHUNK, 16-byte header + data
  +00 u32  magic 0x0123FEDC
  +04 u16  type                         ; dispatched via table at 0x20A10
  +06 u32  data size
```

**The payload compression is already solved**: DecodeAnimationFrame hands it to **0x2D558**,
the same static-Huffman inflate the `.RES` textures use, so `AztTool.Azf.Inflate` decodes it
unchanged. In practice only frame 0 is compressed; every later frame is stored raw.

## Chunk types (jump table at 0x20A10)

| type | handler | meaning | status |
|---|---|---|---|
| 1 | 0x20470 | **keyframe** — plain `movsd` memcpy of w*h bytes | DONE |
| 5 | 0x20770 | **palette** — 256 RGB triples, **VGA 6-bit (0..63)**, scale by 255/63 | DONE |
| 4 | 0x204B4 | **inter-frame delta** | DONE |
| 6 | 0x207F0 | **audio, 8-bit unsigned MONO**, 2205 samples/frame | DONE |
| 7 | 0x207F0 | **audio, 8-bit unsigned STEREO** interleaved, 2205 sample-frames/frame | DONE |
| 2,3 | — | error path; never appears in shipped files | n/a |

Each file has exactly ONE keyframe (frame 0) and one palette; everything after is type 4.
Audio is 4,410 bytes per frame, dead constant, in INTRO and OUTRO1 only.

## The delta codec (type 4) — SOLVED, implemented in `tools\AnimTool.cs`

`0x204B4` walks the image in **bands of 4 scanlines**, and within a band in **blocks of 4
pixels**, left to right — so a block is **4x4**. Each block takes a **2-bit opcode** from a
control byte, and a fresh control byte is fetched after 4 blocks (0x20701). Opcode table at
**0x204A4**:

| op | addr | meaning |
|---|---|---|
| 0 | 0x205A4 | **motion vector, long.** Two bytes A,B. `dx = A-0x7F`. `B>=0x80` -> `dy = B-0xBF` from the **current** frame; `B<0x80` -> `dy = B-0x3F` from the **previous** frame |
| 1 | 0x20639 | **skip run.** One byte, 0 means 256. Skips that many blocks *including this one*; consumes no opcode bits (0x20735 bypasses 0x20701) and may cross band boundaries |
| 2 | 0x20653 | **motion vector, packed.** One byte, always the previous frame. `dy = (c & 0x0F) - 7`, `dx = (c >> 4) - 7` — the **LOW** nibble is the one scaled by width |
| 3 | 0x206E3 | **literal.** 16 bytes, the 4x4 block verbatim |

**0x37B38 COPIES current -> previous at end of frame; it does not swap them.** That is why
"skip" means "leave the current buffer alone" and still yields the previous frame's pixels.

Motion vectors reach outside the picture near edges, so `AnimTool` pads both buffers
(`_origin = 70*W + 256`) rather than bounds-checking per pixel.

## Verified

All **12** movies decode end to end: frame counts match their headers exactly, **0**
out-of-range reads, and 99.49–100% of blocks accounted for per frame (four files hit exactly
100.00%; the shortfall elsewhere is the delta stream ending early, leaving the tail of the
frame unchanged, which is benign). OUTRO2 — 2,000 frames of 640x480 — decodes in **52 ms**.

## Tools

* `tools\Read-CdImage.ps1` — AZT.BIN is **raw 2352-byte MODE1 sectors**, not a cooked ISO;
  "CD001" is at sector 16 offset **17**. Lists/extracts; `-Filter` is a regex.
* `tools\Read-Anim.ps1` — parses the container, reports chunk types, `-DumpDir` writes payloads.
* `tools\AnimTool.cs` — the decoder (`AztTool.Anim`). Compile alongside `AzfTool.cs`.
* `tools\Export-AnimFrames.ps1` — driver: PNG sequence, `-Every N`, `-Verify` decodes and
  writes nothing. **Read its verify numbers**: a block codec desynchronises silently, so
  "blocks accounted" and "out of range" are how a good decode is distinguished from a
  plausible-looking mess.

## Audio, and THE FRAME RATE IS 10 NOT 12

Mono/stereo was established from the samples, not a header field: type 7's bytes resolve
into two independently smooth waveforms on the even and odd indices, type 6's into one.
**Both carry 2205 sample-frames per video frame, which at 22050 Hz is exactly 0.1 s — so
these run at 10 fps, and the `12` in the file header is wrong (or means something else).**
Confirmed on every movie with audio: INTRO 68.2s video vs 68.3s audio, OUTRO2 200.0 vs
200.1, OUTRO1 38.5 vs 38.6. At 12 fps the picture runs 20% fast and desyncs from its own
soundtrack. The small excess is the first frame's priming chunk (16,384 bytes for type 6,
10,000 for type 7) versus 2205 thereafter.

Four movies carry NO audio chunks (COBANI, LEOCATH, LEOEXE, LIBEMPTY); their dialogue is in
`SOUNDS\` on the CD and the game plays it separately.

## ENCODER — DONE, and proven exact

`tools\AnimEncoder.cs` + `tools\Convert-ToAnim.ps1` write playable `.MOV` files.
**All 10 CD movies round-trip decode -> encode -> decode with ZERO differing pixels.**
Output is 101–180% of the original's size (the originals use motion vectors and compress
frame 0; this uses literal blocks + skip runs and stores frames raw).

Four things the encoder must get right:

1. **The control and data streams are ONE interleaved stream**: control byte, then the data
   for the next FOUR opcodes, then the next control byte. Opcodes fill bits 0-1, 2-3, 4-5,
   6-7 in that order.
2. **EMIT THE TRAILING SKIP RUN.** Dropping it is the trap — those blocks would keep the
   previous frame's pixels anyway, but the decoder does not know the frame ended. It keeps
   taking opcodes and reading operands past the chunk, and in a `[delta][audio]` frame
   (TOB, TALFNL, TANDL1) it **decodes the soundtrack as picture**. This broke the first
   round-trip: frame 0 exact, every later frame wrong.
3. **NEVER DITHER** when mapping to the palette. Dither noise makes every block differ from
   the previous frame even in static areas, destroying the skip runs.
4. **Audio is copied through verbatim** with its original chunk type, so re-encoding the
   picture cannot disturb the sound.

Only op3 (literal) and op1 (skip run) are needed; the motion-vector opcodes are a size
optimisation and a subtly wrong motion search is the easiest way to ship a file that looks
fine for fifty frames and then drifts.

**Decoder note:** `Delta()` must be bounded by the CHUNK size, not the payload length, or an
early-ending delta stream spills into the next chunk.

## Playable output — DONE

`tools\AviWriter.cs` + `tools\Convert-AnimToAvi.ps1` mux MJPEG video and PCM audio into AVI.
There is no ffmpeg on this machine, so the container is written by hand; MJPEG because a raw
640x480 OUTRO2 would be 614 MB. **All 12 movies converted, 173.7 MB total**, into
`C:\Games\RaptorMod\sources\video`. AVI gotcha: idx1 offsets are relative to the `movi` FOURCC, not
absolute — absolute offsets parse fine and seek wrongly.

## THE SIZE CEILING, AND THE PATCH THAT LIFTS IT

The IAnimation constructor mallocs a **FIXED 400,000-byte** block for the decoded frame
payload and DecodeAnimationFrame reads into it **with no bounds check**:

```
0x20360  mov ebx, 0x61A80     ; 400,000
0x2036A  mov eax, 0x61A80     ; 400,000 -> malloc -> [0x162FEC]
```

400,000 is just over the largest shipped movie (640x480 = 307,200) and nothing more. A
1024x768 frame is **787,232 bytes** — nearly double — so it corrupts the heap. The game
keeps RUNNING; every allocation afterwards fails, so the 3D viewport and the HUD both go
blank together. That signature means "a movie is too big", not "the renderer broke".

AztMod patches both immediates to **`SCREEN_W*SCREEN_H + 32768`** (`movie-buf-size`,
`movie-buf-size2`) = 819,200 at 1024x768.

**+32768, NOT +8192. FRAME 0 CARRIES MORE THAN THE PICTURE**, and getting this wrong bit
twice:

```
786,432   keyframe (w*h)
    784   palette chunk
 16,400   AUDIO PRIMING chunk -- on every movie that has sound
     16   keyframe chunk header
-------
803,632   a full-screen movie WITH audio
```

The +8192 version fitted silent MINDLOGO with 7,392 bytes spare and overflowed the 50-frame
INTRO sting -- **the only movie that is both full-screen AND has audio** -- by 9,008 bytes.
A near-miss only one input exposes. Later frames are far smaller (audio drops to 2,205), so
only frame 0 matters.

Other payloads: 1024x384 = 394,016 silent / 410,416 with audio (both fitted even the stock
400,000 buffer, which is why letterboxed movies worked while 4:3 ones never could);
1024x476 = 498,240.

**The movie CENTRING box at 0x20CF5/0x20D14 needs nothing** — the `scr-w-`/`scr-h-` family
already repoints it at the screen size. Adding a second patch is what Assert-NoOverlap
caught.

## PLAYBACK IS 10 FPS, HARD-CODED AT THE CALL SITE

The header's fps field is **ignored**. Each caller of the playback loop (0x20BD4) passes the
rate in edx and the loop does `1,000,000 / rate` microseconds per frame:

| call site | movie | rate |
|---|---|---|
| 0x1FF67 | `mindlogo.mov` | **15** |
| 0x1FFC0 | `intro.mov` | 10 |
| 0x2008A, 0x20133, 0x2019B | the CD cutscenes | 10 |

So **the frame COUNT must match the original**: surplus frames do not play faster, they play
longer and drift from the soundtrack. This confirms independently what the audio arithmetic
said (2,205 samples/frame at 22,050 Hz = 0.1 s), and explains why the header's `12` never
mattered.

**Tell the upscaler to keep the source frame rate.** TensorPix once returned 2,880 frames for
TALFNL's 1,199 (2.4x = 10 fps retimed to 24). `Convert-ToAnim` resamples by position to the
reference count, so any ratio is handled -- but interpolated frames are slightly softer than
the real ones, and the extra frames are wasted work.

## Upscaling: 4x, and NEVER compress the intermediate

**4x beats 2x**, measured on COBANI: the two differed in 78.4% of pixels after quantisation,
and 4x resolved spines and stone edges that 2x smeared. The gain is the DOWNSCALE acting as
supersampling (2208 -> 1024 is 2.16x), not the raw resolution. Cost is negligible: 8.3 vs
7.7 MB. An earlier recommendation of 2x was wrong -- it reasoned about wasted pixels rather
than what survives 256 colours.

**Never compress the MP4 intermediate.** It is decoded to raw frames, so its size is
irrelevant to the output -- but any lossy pass adds frame-to-frame wobble in static areas,
which collapses the skip runs and makes the GAME file bigger. Cleanest source = best picture
AND smallest output.

**The encoder STREAMS frames; never buffer them.** At 4x the twelve movies would need 73 GB
if decoded up front (OUTRO2 alone is 2,000 frames of 2560x1920 = 36.6 GB). The source is
opened twice -- once to sample for the palette, once to encode -- holding one frame at a
time. Encoding is ~1 s/frame at 2208x832 and ~3 s at 2560x1920, so OUTRO2 is a ~2.5 hour job.

## Dither: NO (settled 2026-09-28)

`Convert-ToAnim -Dither` exists (Floyd-Steinberg, 15-bit LUT) and Josh rejected it:
**40.2 MB vs 16.7 MB and skip runs 47.1% vs 78.7%** on MINDLOGO, for banding nobody will
see in a logo most players skip. Default is OFF and should stay off. The nuance if it ever
comes up again: the 1996 originals ARE dithered, so removing it trades their grain for
visible banding on smooth gradients — it is a real trade, just not one worth 2.4x the file
and decode cost.

## Dimensions (why they look tiny)

OUTRO2 640x480 - INTRO 600x280 - OUTRO1 320x148 - everything else **552x208**.
At 1024x768 a 552x208 movie is a postage stamp. Same problem the book pages had, and
[[azrael-xaf-model-pipeline]]'s lesson applies: rescaling the ASSET beat patching a runtime
scaler for the books, and would here too — but that needs an ENCODER, which needs the delta
codec finished first.

## PowerShell trap that cost time here

`0xAB12EF90` is parsed as a **negative Int32**, so it never equals the UInt32 from
`BitConverter`, and the error prints both identically under `{0:X8}`. Use
`[Convert]::ToUInt32('AB12EF90',16)`. See [[azrael-powershell-silent-traps]].

Related: [[azrael-texture-format]], [[azrael-dosbox-runtime]], [[azrael-re-tooling]]
