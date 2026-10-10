# ChatGPT brief — Azrael's Tear HUD reskin (AztMod)

Paste the section below into ChatGPT. Attach these three images:

  design\panel-spec-overlay.png       the reserved-region map (annotated, 2x)
  design\hud-stock-panel-2x.png       the original 1996 panel, for tone
  design\hud-shipped-panel-800x111.png what the mod ships today

---

## THE BRIEF

I need you to design a replacement instrument panel for a 1996 first-person
adventure game. This is a **pixel-accurate UI asset**, not an illustration. Exact
dimensions and placement matter more than flourish.

### Subject and tone

The game is a gothic sci-fi archaeological thriller: a cyber-enhanced treasure
hunter explores a sealed Templar monastery. The player sees the world through a
head-up display built into a visor, and this panel is the bottom of that visor —
an instrument housing the 3D view sits inside.

The original is a brass-and-olive metal console with a domed central lens. I want
that same character, **modernised, not replaced**: cleaner metal, crisper bevels,
confident edges, legible iconography, no 1996 dithering or noise. Think precision
instrument, machined and slightly worn — not glossy consumer UI, not neon
cyberpunk, not glass-and-blur. It should look like hardware that was built to
last and has been in the field a while.

Restraint wins. This sits under a dark 3D scene for the entire game; anything
loud or high-contrast will fight it.

### Canvas — exact

**1600 x 254 pixels** (this is 2x; the final asset is 800 x 127). PNG, sRGB,
with a real alpha channel.

The canvas has two zones. All coordinates below are in **final 800 x 127 space** —
double them for your 1600 x 254 canvas.

**Rows 0-15 — the bleed strip.**
Fully transparent EXCEPT for the panel's raised silhouette breaking upward into
it. This is the single most important part of the design. In the original, the
panel's top edge is not a straight line: raised shoulders at the far left and far
right corners climb about 14 px up, and a shallow dome rises in the middle, with
transparent gaps between them. That scalloped bite is what makes the 3D image sit
*inside* the housing instead of on top of a bar. Reproduce that idea in your own
design language. Rows 0-15 must be mostly transparent.

**Rows 16-126 — the panel body.**
The panel proper, 800 x 111. Row 16 is the panel's top edge. Fully opaque.

### Reserved regions — hard constraints

These rectangles are where the game engine draws live content at runtime. Their
positions are compiled into the executable and cannot move. Your artwork must
provide the **housing, bezel, recess or socket around each one** and must leave
the rectangle itself empty.

**Fill every reserved rectangle with flat, pure magenta #FF00FF**, with no
shading, no texture, no antialiasing at the edges, and use that colour nowhere
else in the image. This is a registration marker so the placement can be verified
automatically.

| region | x | y | size | what the engine draws there |
|---|---|---|---|---|
| AUTOMAP | 165 | 22 | 128 x 86 | live top-down map, needs a sunken bezel |
| CONTROL A | 301 | 22 | 19 x 30 | small vertical toggle / switch |
| CONTROL B | 300 | 55 | 17 x 30 | small vertical toggle / switch |
| ACTION 0 | 342 | 33 | 46 x 20 | contextual button sprite, drop-in socket |
| ACTION 1 | 326 | 59 | 46 x 21 | contextual button sprite, drop-in socket |
| ACTION 2 | 430 | 63 | 50 x 24 | contextual button sprite, drop-in socket |
| STATUS GAUGE | 400 | 43 | 100 x 14 | horizontal bar that fills left to right |
| SCAN READOUT | 620 | 16 | 180 x 111 | scrolling text, needs a dark recessed well |

Everything else is yours: x 0-164 and x 486-619 are pure housing, plus whatever
frames the regions above.

### Style rules that are not negotiable

The final image is reduced to an indexed palette, so:

- **Flat or stepped shading only.** No soft gradients, no glows, no bloom, no
  translucency, no blurred drop shadows. Gradients band badly and will look
  broken.
- **Strong value separation.** Each form must read by lightness alone, not by
  hue. Convert your design to greyscale mentally — if two adjacent parts merge,
  the contrast is too low.
- **Chunky detail.** The panel is 111 px tall in play. Anything finer than about
  2 px disappears. No hairlines, no fine text, no micro-texture.
- **Muted, narrow gamut.** Desaturated metals, olive, bone, gunmetal, with at
  most one restrained accent colour. No saturated primaries.
- **Hard edges.** Minimal antialiasing. Crisp 1-2 px bevels read far better than
  soft ones at this size.

### Output

1. The 1600 x 254 PNG described above, with alpha.
2. A second version of the **same** image in a **powered-down state**: identical
   geometry, pixel for pixel, but inert — unlit, drained, no active accent. This
   is the HUD-off variant and it must register exactly with the first.

Do not add a border, watermark, caption, margin, or drop shadow around the canvas.
Do not letterbox or pad. The image must be exactly 1600 x 254.

---

## FOLLOW-UP REQUEST — the six action-button sprites

Once the panel is agreed, ask for these separately, on transparent backgrounds,
at 4x for downsampling. They are contextual verb buttons (TAKE / USE / PUSH and
similar) that drop into the ACTION sockets.

  ACTION 0  46 x 20   ->  deliver at 184 x 80
  ACTION 1  46 x 21   ->  deliver at 184 x 84
  ACTION 2  50 x 24   ->  deliver at 200 x 96

Each needs an **unlit** and a **lit/highlighted** version — six images, three
matched pairs. The lit state should differ by brightness and a rim, not by a
glow. They must sit convincingly in the sockets designed above and share the
panel's material language.

---

## OPTIONAL — the compass strip

Runs across the top of the screen, above the 3D view.
**348 x 24** final; deliver at 1392 x 96. A horizontal graduated bearing scale.
Same material language, same flat-shading rules.
