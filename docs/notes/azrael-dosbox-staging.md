---
name: azrael-dosbox-staging
description: "AztMod's DOSBox Staging 0.83 setup: which 0.74 keys were renamed or dropped, and that the sharp-bilinear shader is called 'sharp'."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-19T19:38:05.990Z
---

The modded copy bundles **DOSBox Staging 0.83.0** (portable zip) in
`DOSBOX-STAGING\` alongside the stock `DOSBOX\`, so both launchers work and you
can A/B them:

- `Play-Azrael-Modded.bat`  -> DOSBox 0.74-3, `azrael-base.conf` + `azrael-graphics.conf` + `azrael-game.conf`
- `Play-Azrael-Staging.bat` -> Staging, `azrael-staging.conf` + `azrael-game.conf`

`azrael-game.conf` (the `[autoexec]` with `mount c .\GAME`, `imgmount d .\AZT.CUE`,
`config -securemode`) is **shared unchanged** â€” Staging still has all of it.

Launch with `--noprimaryconf --nolocalconf` or Staging's own global config at
`%LOCALAPPDATA%\DOSBox\dosbox-staging.conf` overrides ours (its default
`shader = crt-auto` would win). Note Staging uses `--conf`, not `-conf`, and has
no `-noconsole`.

## The shader

**`shader = sharp`** (full path `interpolation/sharp`). That IS sharp-bilinear:
upscale treating each source pixel as a small rectangle, so it integer-scales as
far as it fits and only filters the remainder. Confirmed live in the log:
`RENDER: Using shader 'interpolation/sharp'`.

Comparison values: `bilinear` = what 0.74's `output=opengl` did (plain blur),
`nearest` = 0.74's `openglnb`, `crt-auto` = Staging's own default.
`--list-shaders` prints everything shipped.

## 0.74 keys that do NOT carry over

| 0.74 | Staging 0.83 |
|---|---|
| `[render] scaler` | **gone** â€” superseded by `shader` |
| `[sdl] fullresolution` / `windowresolution` | `fullscreen_mode` / `window_size` |
| `[sdl] autolock` | `[mouse] mouse_capture` |
| `[sdl] usescancodes`, `priority` | **gone** |
| `[cpu] cycles = max limit 280000` | `cpu_cycles_protected` |
| `[render] aspect = true` | `aspect = auto` |
| `[dos] xms = true` | `xms = on` |

**`cpu_cycles` only covers real mode.** This game is DOS/4GW protected mode, so
`cpu_cycles_protected` is the one that applies â€” setting `cpu_cycles` does
nothing for it. Using a fixed `280000` to mirror 0.74's "max but capped".

`[mouse] mouse_capture = onstart` is required: the mod makes mouselook the
default, and Staging's `onclick` default would leave you unable to look until you
clicked â€” and left-click fires the weapon.

`[dosbox] vesa_modes = compatible` is enough; the game asks for 0x101
(640x480x8), a standard mode. Staging reports
`Initialised S3 Trio64 VESA 2.0 compatible with 4 MB`.

## Smoothing: 'sharp' is a near no-op here

Staging's log gives the reason:
`DISPLAY: VESA 640x480 ... scaled to 2133x1600` â€” that is **3.333x**. `sharp`
integer-scales as far as it fits (3x) and bilinear-filters only the leftover
1.11x, so almost no filtering happens. sharp-bilinear exists to stop pixels
coming out *uneven* at non-integer scales, **not** to smooth artwork.

For visible smoothing use an edge-aware scaler. Staging ships them as GLSL, so
unlike 0.74's CPU scalers they are free: `scaler/xbr-lv2-3d` (the variant tuned
for 3D-rendered rather than sprite art), `scaler/xbr-lv3` (strongest),
`scaler/advinterp3x` (gentler). Plus `[render] dedithering = 0..100`, which both
cleans 8-bit checkerboard dither and stops the scaler smearing it.

`Play-Azrael-Staging.bat [shader] [dedither]` passes `--set` overrides so these
can be A/B'd without editing the config.

## Colour: image_adjustments = off

Staging auto-applies a **P22 CRT phosphor profile and a 7800K white point** even
with a non-CRT shader. `[render] image_adjustments = off` makes every adjustment
in the section inert and passes raw RGB through.

Measured on bright pixels: on = R174 G182 B200 (**+26 blue**), off = R194 G195
B194 (neutral). Staging still logs "Auto-switched to P22 CRT color profile" when
off â€” that is the auto-*selection* logging, not proof it is applied. Measure,
don't read the log.

## Music: the game ships General MIDI and was using FM

`GAME\AZRAEL\MDI.INI` selected **SBPRO2.MDI = OPL3 FM**. The game also ships
`MPU401.MDI` (General MIDI) and `MT32MPU.MDI`, and every track exists twice:
`INGAME.XMI` / `GAME1_FM.XMI`, `CATHEDRL.XMI` / `CATH_FM.XMI`, and so on.

**The non-FM set is General MIDI, proven from the Miles TIMB chunk** (patch list
inside each XMI): CATHEDRL = 19 Church Organ, 52 Choir Aahs, 48/49 Strings;
INGAME = 24 Nylon Guitar, 73 Flute, 40 Violin, 68 Oboe. Those are GM program
numbers used semantically, so it is GM, not MT-32.

Switch by rewriting MDI.INI to `DRIVER MPU401.MDI` / `IO_ADDR 330h` (original
kept as `MDI.INI.aztbak`). Staging then reports
`MPU-401: Running in intelligent mode on ports 330h and 331h`.

Synth: **`mididevice = fluidsynth`** with **GeneralUser GS v2.0.3**
(`GeneralUser-GS.sf2`, 32,319,396 bytes) in
`C:\Games\RaptorMod\game\soundfonts\`, via
`[fluidsynth] soundfont = GeneralUser-GS.sf2` + `soundfont_dir = soundfonts`.
Staging recognises the bank by name and auto-applies tuned chorus/reverb, and
runs at 48 kHz without resampling.

Source: `github.com/mrbumpy409/GeneralUser-GS` (the author's own packaging repo;
the `documentation/LICENSE.txt` permits use and redistribution in software
projects and asks that you ship a local copy rather than hotlink â€” so bundling
is fine and is what the author prefers).

Rejected alternatives: `mididevice = port` reaches Windows' Microsoft GS
Wavetable Synth with zero downloads but has ~100 ms latency and weaker samples;
`mt32` is the wrong target for GM music and needs Roland ROMs the user must own.
`libfluidsynth-3.dll` and `mt32emu-2.dll` both ship inside the Staging zip â€” only
the SoundFont has to be fetched.

## Gotchas found while setting this up

- `--writeconf` does not exist; `--printconf` prints the primary config path and
  creates the file, which is the way to get the real 0.83 key schema.
- Extracting the zip into the deep scratchpad path blows MAX_PATH on Staging's
  bundled manual. Extract to a short path, and skip `resources/docs/` â€” that
  drops the bundle from ~95 MB to 64 MB.
- `[render] image_adjustments = on` with `brightness = 45`, `contrast = 65` are
  the documented neutral defaults, not CRT compensation. Left alone.

See [[azrael-dosbox-runtime]] and [[aztmod-patch-framework]].

## The modded launcher ran DOSBox 0.74, not Staging (found 2026-09-20)

**`Apply-AztMod.ps1` hard-coded the 0.74 launcher and was never updated when the
project moved to Staging.** So every `Play-Azrael-Modded.bat` launch silently ran
the OLD emulator on the OLD conf, while all the tuning went into a conf nobody
executed:

| | Play-Azrael-Modded (was) | Play-Azrael-Staging |
|---|---|---|
| exe | `DOSBOX\DOSBox.exe` | `DOSBOX-STAGING\dosbox.exe` |
| conf | `azrael-base.conf` | `azrael-staging.conf` |
| cycles | `cycles = max limit 280000` | `cpu_cycles_protected = 400000` |
| memsize | 16 | 32 |

Symptom that exposed it: at 800x600 the opening room ran fine but every later
room crawled. The rasteriser is the bottleneck and 800x600 is 1.56x the pixels,
so heavy rooms never got near the 40 fps cap.

**Two compounding effects, not one.** Below the cap the limiter never waits, so
(a) the frame rate itself drops, AND (b) `move-scale` is baked for the cap
(x18.2065/40 = 0.4552 per frame), so at ~18 fps the player moves at 45% of the
intended speed. "Painfully slow" was both.

Apply-AztMod now emits a Staging launcher when `DOSBOX-STAGING\dosbox.exe` and
`azrael-staging.conf` both exist, falling back to 0.74 otherwise, and forwards
`%*` so the passthrough overrides work:

    start "" /W /B DOSBOX-STAGING\dosbox.exe --noprimaryconf --nolocalconf ^
        --conf azrael-staging.conf --conf azrael-game.conf %*

**Raising cycles is SAFE now, and it was not before.** `AztFrameLimit` spins on
the PIT until a whole period has passed, so surplus cycles are burned in the spin
rather than turning into speed ([[azrael-frame-tied-timing]]). Before the limiter,
cycles were frame rate AND game speed together. Raised to 700000 for 800x600.

**The cap must stay ACHIEVABLE in the WORST room, not the opening one.** And note
`Set-FrameCap.ps1` only writes `aztFramePeriod` -- it does NOT rescale the
`move-scale` constants, which are static. Changing the cap at runtime therefore
desyncs movement speed; a cap change needs a rebuild.

## A FIXED cpu_cycles_protected made the AUDIO run in slow motion

Symptom: music and speech consistently slow, NOT varying by room or frame rate,
while animation and movement looked correct and consistent.

**That combination is the signature of the emulator running below real time.**
DOSBox executes N cycles per EMULATED millisecond. With a fixed `N` the host may
not deliver N per REAL millisecond, and emulated time then falls behind the wall
clock. Everything on the emulated clock still agrees with itself -- the frame
limiter, the actor stepper, movement -- but the sound hardware plays samples in
real time, so audio stretches. Consistent visuals + slow audio = too many cycles.

700000 was too many for this host on FPU-heavy 3D code plus the limiter's spin.

**Use `cpu_cycles_protected = max`.** It auto-adjusts to keep emulated time equal
to real time, so audio stays correct and the game just drops frames when the host
cannot keep up. Leaving it uncapped is safe ONLY because `AztFrameLimit` caps the
game on the PIT ([[azrael-frame-tied-timing]]) -- surplus cycles are burned in its
spin and cannot become speed. Without the limiter, `max` would make the game race.

**Do not "fix" slow audio by raising cycles.** It is the opposite lever.
