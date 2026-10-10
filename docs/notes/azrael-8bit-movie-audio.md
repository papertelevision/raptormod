---
name: azrael-8bit-movie-audio
description: "Movie audio crackle is 8-bit quantisation distortion, not a decode fault. Silence is 0x80 not 0x00 (a zero-filled tail is a BANG), and normalise+dither before quantising."
metadata:
  node_type: memory
  type: reference
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-02T04:04:03.201Z
---

`.MOV` chunk types 6 (mono) and 7 (stereo) are **unsigned** 8-bit PCM at 22050 Hz. That is
~48 dB of range in total, so the conversion from the 16-bit master is where all the quality is
won or lost.

## Silence is 0x80

`New-Object byte[] $len` zero-fills, and in unsigned 8-bit `0x00` is **full-scale negative**,
not quiet. The last frame is almost always short (181 frames want 399,105 samples, the render
gave 398,664), so every movie built this way ended with a full-amplitude DC step — an audible
bang, and a spurious `0.00 dBFS` peak in any level check. Fill with **128**.

## Why it crackled

The opening render: peak −5.24 dBFS, **RMS −23.75 dBFS**, no clipping. At 8 bits that is
ordinary content swinging over about ±9 of 128 steps — roughly four effective bits — and it
touched only **139 of 256 codes**. Quantisation error that large is *correlated* with the
signal, which is what crackle is. Three fixes, all in `Convert-ToAnim.ps1`:

1. **Remove DC** before quantising (was 58.6).
2. **Round, don't shift.** `(v + 32768) -shr 8` truncates: a half-LSB downward bias on every
   sample.
3. **TPDF dither**, two summed uniforms spanning ±1 LSB (1 LSB = 256 counts), added before
   rounding. Seeded so rebuilds stay byte-identical.
4. **Normalise** — `-AudioNormalize` / `-AudioPeakDb` (default −1.0). Opt-in, because it is a
   mix decision: every 6 dB recovered is a whole extra bit of the eight.

Result: 139 → **223 of 256 codes**, RMS −23.75 → −19.52 dBFS.

## Level reference (measure before judging, as with the soundfonts)

| | peak | RMS | codes |
|---|---|---|---|
| stock INTRO | 0.00 dBFS | −14.40 | 256 |
| stock TOB | 0.00 dBFS | −21.08 | 208 |
| our OPENING (fixed) | −1.01 dBFS | −19.52 | 223 |

Read them with `AztTool.Anim` — `NextFrame()` then `LastAudio` / `LastAudioLen` (the type is
`Anim`, **not** `AnimDecoder`).

## FRAME 0 IS A PRIMING CHUNK — this is the actual crackle

Every shipped movie makes its **first** audio chunk oversized, and nothing built here did:

| | frame 0 | steady | lead |
|---|---|---|---|
| stock INTRO (t7) | **10,000** | 4,410 | 1.27 frames |
| stock TOB (t6) | **16,384** | 2,205 | 6.40 frames |

It is extra **real** audio, not padding: INTRO's 10,000 + 681×4,410 = 68.3 s against 68.2 s of
picture, so the sound finishes a fraction early. Without it the player's buffer holds exactly
one frame and any frame decoding slower than its 100 ms starves it — heard as steady crackle,
not a dropout. Our movies are least able to afford it: 1024x768 is **4.7× the pixels** of stock
INTRO's 600x280. `-AudioPrime` defaults to the shipped value for the chunk type; don't invent a
number, the player's buffer has only ever been asked to hold those.

**The crackle was NOT in the file.** Extracting the chunks back out of a finished movie found
zero sample-to-sample discontinuities and zero at the chunk seams, and the same audio as a WAV
sounded clean — as did a WAV of the pre-quantisation PCM. When both A/B WAVs sound fine but the
game still crackles, stop working on the conversion: it is playback timing. Build the WAV from
the **.MOV's own chunks**, not from the decoded PCM, or the test proves nothing.

DOSBox is already `core=dynamic`, `cpu_cycles_protected=max`, and the Staging config has no
`[mixer]` section (so defaults). Remaining levers if priming is not enough: a `[mixer]`
`prebuffer`/`blocksize` bump (host side), or cutting literal blocks per frame (guest side).

Some hiss is inherent at 8 bits and the shipped movies have it too. The last quality lever is
dynamic-range compression to lift RMS toward stock INTRO's −14.4 dBFS, which changes the mix
and should be asked about, not assumed. See [[azrael-mov-format]], [[azrael-mf-stride-trap]].
