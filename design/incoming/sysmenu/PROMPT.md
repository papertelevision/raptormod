# ChatGPT prompt — Azrael's Tear system menu reskin

Attach **`zoom-SAVE06.png`** (and optionally `sysmenu-frames.png`) as the
reference, then paste the prompt below.

Ask for the **master panel first**. Do not ask for all 14 frames — the eight
state frames differ only by which button is lit, and AI image tools redraw rather
than edit, so asking for variants produces fourteen subtly different panels that
flicker when the animation plays. I composite the lit states from the master, the
same way the stock art does it.

---

## The prompt

> I'm remastering the UI artwork for *Azrael's Tear* (1996), a first-person
> gothic sci-fi adventure. The attached image is the original in-game system
> menu panel, shown at 3x so you can read it — the real asset is only 206x170
> pixels. I need a modern, high-resolution repaint of the same object that keeps
> its exact identity and layout.
>
> **What it is.** A fold-out control panel built into the player's wrist-mounted
> device: a black lacquered ovoid shell with bevelled gold inlay, fused on its
> right-hand side to an articulated mechanical-organic assembly of claws,
> segmented armature and small glowing indicator jewels. Think Giger-adjacent
> biomechanical, but restrained and elegant — polished obsidian and aged brass,
> not wet and fleshy. It should read as a precision instrument that happens to be
> grown rather than machined.
>
> **Layout — keep these exactly where they are.** Five engraved control labels,
> all lowercase, all set into recessed gold-bevelled slots:
> - `load` — upper left, on the ovoid shell
> - `save` — lower left, on the ovoid shell
> - `quit` — centre, on the vertical spine that divides the panel
> - `music` — upper right
> - `sfx` — lower right
>
> The articulated claw assembly occupies the right third and must not overlap the
> labels. The lettering should look engraved into metal and lit from the upper
> left, not printed on top.
>
> **Style constraints, and these matter more than they usually would:**
> - Palette is severely limited: near-black body, warm gold/brass highlights,
>   and a few tiny green and amber indicator lights. **No other hues at all** —
>   no blues, no purples, no coloured rim light.
> - Avoid large smooth gradients and avoid film grain, noise or texture overlays.
>   The final asset is 8-bit indexed colour and both of those turn into visible
>   dithering speckle.
> - Contrast should be strong and local — crisp bevel edges, bright specular
>   glints on the gold — rather than soft global shading.
> - The panel must stay legible when reduced to roughly 412x340 pixels.
>
> **Technical:**
> - Aspect ratio **206:170** (1.212:1, landscape). The panel should fill the
>   frame edge to edge with no margin.
> - **Pure black or fully transparent background**, with a clean hard edge around
>   the silhouette. No drop shadow, no glow spilling onto the background, no
>   vignette — anything outside the silhouette becomes transparent in game, so a
>   soft edge turns into a fringe of stray pixels.
> - Highest resolution you can produce.
>
> Produce one image: the panel at rest, with all five labels visible and none of
> them highlighted.

---

## After the master

Once the master looks right, ask for **one** extra image as a treatment
reference — the same panel with only `save` lit — so I can match how a
highlighted control should look (the stock art draws a bright outline around the
slot and brightens the lettering). I generate the other seven states from the
master using that treatment.

The six opening frames (`SAVE00`–`SAVE05`) are the panel unfolding and are mostly
silhouette; I derive those from the master rather than generating them, so the
animation stays consistent.

---

## What happens to it here

| | |
|---|---|
| final size | **412x340** — exactly 2x stock, so the existing hot-spot polygons scale cleanly |
| position | latched to the **right edge of the viewport**, instead of floating mid-screen |
| palette | quantised into the LIVE shared palette, not its own |
| transparency | palette index 0 |

**The palette point is the real constraint.** Unlike the book pages, these frames
do not carry their own palette — they index the shared 256-colour DAC that the
3D renderer is also using. AztMod's reskin owns indices 1..53; the rest are the
status gauge ramp, Reality Lab's shading ramps and character flesh tones. So the
repaint gets fitted into colours that already exist, which is exactly why the
brief above insists on a narrow black-and-gold gamut: a narrow gamut quantises
almost losslessly, and anything wider will band.
