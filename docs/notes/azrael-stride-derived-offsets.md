---
name: azrael-stride-derived-offsets
description: "Azrael's load base is 0x200000; the viewport stride family includes `row*552` framebuffer offsets that look nothing like a stride."
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-19T16:08:37.911Z
---

**Load base is 0x200000.** A runtime EIP maps to an image-linear address as
`linear = eip - 0x1F0000` (obj1's stated base is 0x10000). Verified by matching a
reported fault EIP to a loop top.

Caveat: with `core=dynamic` DOSBox reports the start of the translated **block**,
not the faulting instruction — so the reported address is always a branch target.
Finding it means looking for *loop tops* (targets of a backward branch), not for
a particular opcode. The pair of reported EIPs 0xF apart resolved instantly once
that was understood.

**The stride family has a fourth member.** Beyond W, W-1, W/2, W*H and the
`imul/add/sub 552` stride sites, the image contains constants of the form
`row * 552` used as byte offsets into the framebuffer. They are invisible to a
search for 552.

Find them all with: scan every immediate in obj1 for an **exact multiple of 552**
(2..282 rows). That turns up exactly these, and nothing else:

| site | k | what |
|---|---|---|
| `0x10947` | 71 | start offset of a 180x40 thumbnail grab out of the view |
| `0x10959` | 111 | its terminator — `cmp esi, 0xEF58` |
| `0x16B91` | 27 | pointer to row 27, stored at `0x1525D0` |
| `0x16C23` | 27 | same, feeds `0x3F010` |
| `0x16C12` | 208 | byte count = 208 rows, feeds `0x3F010` |
| `0x20335` | 356 | **coincidence** — movie code (func `0x201E0`), 640x480 domain. Leave it. |

**Why:** the pair at `0x10947`/`0x10959` is a `for (esi = 71*552; esi != 111*552;
esi += stride)`. Patch the stride to 640 and leave the terminator at `111*552` and
the equality never holds — the loop runs forever, copying off the end of the
framebuffer and then off the end of RAM. Symptom: a flood of
`Illegal write to <top of RAM>` and a hard crash minutes into play. It survived
two wrong diagnoses (memsize, then the HUD overlay) because the overlay bug had
the identical signature.

**How to apply:** re-run the multiple-of-552 scan whenever the viewport width
changes. A loop that steps by the stride but terminates on `!=` rather than `<`
is unforgiving.

See [[azrael-hud-overlay-res]] and [[azrael-dosbox-runtime]].
