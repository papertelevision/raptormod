---
name: azrael-animation-format
description: Animation keyframes fully decoded - three doubly-linked key lists on the Animation object (rotation/position/scale), identified from the data not the API order.
metadata:
  type: reference
---

**Decoded 2026-09-26. 61 Animations, 2,678 keys, 100% partitioned, none left over.**
Dumped by `AztAniEmit`/`AztAniKeys` in the overlay (`$ENABLE_ANI_LOG`) to `AZTANI.BIN`.

**Animation object (76 bytes)** — three key lists, each a **head/tail PAIR**:

| offset | contents |
|---|---|
| `+0x14` / `+0x18` | handle / class tag (`0x147B78`, "Animation") |
| `+0x2C` / `+0x30` | **ROTATION** keys: head, tail — 28-byte records, **quaternion** |
| `+0x34` / `+0x38` | **POSITION** keys: head, tail — 24-byte records, vec3 |
| `+0x3C` / `+0x40` | **SCALE** keys: head, tail — 24-byte records, vec3 |
| `+0x48` | the Frame this Animation drives |

**Key record:** `+0x00` next, `+0x04` **prev** (doubly linked), `+0x08` time,
`+0x0C..` payload (4 floats quaternion, or vec3 + pad). Times are integer frame
numbers, 0..163 in room 1. Keys are **stored sorted by time** — each adder does
`fld [node+0x08] / fcomp <newTime>` while walking.

**Which list is which was decided by the DATA, not the API order** (the code cannot
say): rotation = all 1710 keys unit-length-4; scale = every value exactly (1,1,1);
position = small varying vec3s. Counts 1710 / 563 / 405.

**The three adders:** `0x456B0` rotation (allocates 0x1C = 28, four floats to key+0x0C),
`0x457AC` position (0x18 = 24, vec3), `0x458B0` scale (0x18 = 24, vec3). Found via
functions referencing the Animation tag `0x147B78`. See [[azrael-rl-object-model]].

**A list terminates at its TAIL pointer, not at a null `next`.** Walking `next` until
null runs straight out of one list into the next one's keys — which is what made 968
vec3 keys look like corrupt quaternions. Use the head/tail pair.

**CORRECTION, recorded because it was asserted twice and was wrong both times:** the
creature rest-pose displacement (~650 units, see [[azrael-geometry-export]]) is NOT
explained or fixed by animation. Position keys DO exist (563 of them) but their values
are small (order 0.01-2.1), nowhere near 650. The displacement comes from the bone
LOCAL matrix translations and remains unexplained.
