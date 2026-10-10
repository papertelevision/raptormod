# ChatGPT prompt — expanding log box (2 images)

Attach these three files, then paste everything below the line:

  design\incoming\panel-pair.png          your original full-res render (style)
  design\logbox-ref-context-2x.png        where the box sits, both states marked
  design\logbox-ref-4x.png                what is there now, 4x

---

I'm attaching three references:

1. **panel-pair.png** — the full-resolution bottom HUD panel you designed for me
   earlier. This is the style to match.
2. **logbox-ref-context-2x.png** — that panel as it actually appears in the game
   now, at 2x, with the area I need redrawn marked: the **magenta rectangle is
   the box closed**, the **cyan rectangle is the box open**.
3. **logbox-ref-4x.png** — the closed box's current contents at 4x, so you can
   see the existing bevel and interior at the pixel level.

I need two new images that replace **only that box** — the large one on the
right-hand side with the dark recessed interior. Everything else in the panel
stays exactly as it is; do not redraw, restyle or re-render the rest of it.

That box is now an expanding text panel. It has two states, and I need one image
for each.

## What I need

**Image 1 — "LOG BOX, CLOSED"**
- Exactly **174 × 94 pixels**. Not a multiple, not scaled — 174 × 94.
- This is the box at its normal size, sitting in the panel exactly where the
  existing large right-hand box sits, but **10 pixels taller at the top** than
  the current one (it now runs right up to the bottom edge of the game's 3D
  viewport).
- A metal frame around the outside, with a dark recessed interior for text.

**Image 2 — "LOG BOX, OPEN"**
- Exactly **174 × 214 pixels**.
- The same box, extended **upward by 120 pixels**. The bottom edge and both
  side edges must be identical to Image 1; only the top moves up.
- Its **bottom 94 pixels must read as a continuation of Image 1** — same side
  rails, same interior treatment, same bevels, so that when the box grows the
  frame looks like one object stretching rather than two different panels. The
  left and right rails should run the full height uninterrupted.

## Style

- Match the attached panel exactly: same metal, same wear, same lighting
  direction, same palette. This has to look like it was always part of it.
- The interior is a dark recess for glowing text — flat and low-contrast, around
  `#2C2A18`. No noise, gradients or texture in the text area; anything busy there
  makes the text unreadable.
- The frame reads as a machined metal bezel, in keeping with the rest of the
  panel.

## Hard technical constraints

These come from the 1996 engine this is going into. Please treat them as fixed.

1. **Text is drawn flush into the top-left corner of the interior.** I cannot
   inset it from the left. So:
   - The **left rail must be 3 pixels or less**, and dark. Text will occasionally
     touch it. Do not put a thick or bright border on the left edge.
   - The **top rail may be up to 10 pixels** — I reserve those rows in code.
2. **The right 18 columns (x = 156..173) are reserved** and will never have text
   over them. Put the right rail and the toggle control here.
3. **The bottom 8 rows are reserved** — safe for the bottom rail.
4. So the usable text area is `x 0..155`, and `y 10..85` (closed) /
   `y 10..205` (open). Nothing decorative inside that rectangle.

## The toggle control

Draw a small control into the reserved right strip of **both** images, in the
**top-right corner, roughly 12 × 12 pixels at x 158..169, y 4..15**. It is the
button that opens and closes the box, so it must differ between the two:

- In **Image 1 (closed)** it shows an **upward chevron / expand** marking.
- In **Image 2 (open)** it shows a **downward chevron / collapse** marking.

Keep it simple and readable at actual size — at 12 pixels, a single clean chevron
in a bright accent colour beats anything detailed.

## Output

- Two PNGs at **exactly 174 × 94** and **exactly 174 × 214**.
- No transparency, no alpha channel, no drop shadow falling outside the canvas.
- No upscaling, no smoothing, no "enhanced" resolution — these are blitted
  1:1 into an 800 × 600 screen, so a larger render would have to be shrunk and
  would lose the crisp edges.
- Keep the total number of distinct colours low (ideally under 40 across both
  images) and reuse the panel's existing colours wherever possible. The images
  get quantised into a shared 8-bit palette, so a restrained render survives it
  intact and a photographic one does not.
- Please show them at 1:1 as well as enlarged, so I can check the actual pixels.
