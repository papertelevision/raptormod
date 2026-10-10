# Prompt for ChatGPT: the expanding text area (right-hand section of the panel)

Attach these three images first (all in `AztMod\design\incoming\hud\textarea\` except the first):

1. `AztMod\design\incoming\hud\two_panels_reference.png`: the whole panel, for style
2. `current-right-section.png` (1536x496): the section being replaced, at exactly the size of the
   closed state
3. `layout-template.png` (1536x1024): where everything goes in the open state

Ask for the images one at a time. Image 1 is the important one.

---

I am remastering a 1996 adventure game, Azrael's Tear. Attached is its new bottom instrument panel
(two_panels_reference.png). I need a REPLACEMENT for its right-hand section: the story-text
screen and its controls (current-right-section.png shows the section as it is now). The new
section is laid directly over the panel and covers that part completely. The text screen can
EXPAND upward over the game view, with a smooth mechanical unfolding animation: the frame
slides up, cables stretch, and a small gear on the right turns while it moves.

I will animate it myself from ONE image of the fully opened state, so how that image is built
matters more than anything else. Please follow the layout template (layout-template.png)
closely.

## The look (match the attached panel exactly)

- Biomechanical steampunk: heavy cast and sculpted bronze/brass housing with organic, flowing
  curves, ribbed black rubber hoses and cables, brass rivets and slotted screws, vents with
  horizontal slats, small amber lamps.
- Materials: dark olive / gunmetal bronze (#3A3826 to #2C2A18), worn polished brass on raised
  edges (#B8A060), deep near-black shadows, grime, fine scratches. Lit things glow warm amber
  (#FFB030 to #FF8A1A).
- Painted, pre-rendered 1990s CGI look, like the attached. NOT flat modern UI, NOT glossy plastic,
  NOT neon, NOT holograms.
- Soft key light from the UPPER LEFT. Straight-on orthographic view: no perspective, no tilt.

## Image 1: the section FULLY OPEN, 1536 x 1024 pixels (landscape)

The canvas is exactly the template. Its three horizontal zones:

| Rows | Zone | Rule |
|---|---|---|
| 0 to 300 | TOP ZONE (blue on the template) | The top of the machine: top bezel of the screen, a sculpted crest, the upper controls |
| 300 to 828 | STRETCH BAND (green) | **Everything here runs perfectly straight up and down.** The screen's left and right frame rails, the screen itself, straight vertical cables and pipes, vertical ribbed plating. **No rivets, no screws, no buttons, no curves, no gear, nothing that starts or ends inside this band.** Every row of the band must look the same as every other row. |
| 828 to 1024 | BOTTOM ZONE (blue) | The bottom of the machine: bottom bezel, the lower controls, the gear. Row 1023 is the bottom of the screen: the bottom edge is straight. |

**Why:** the closed state is this image with rows 300 to 828 cut out (the top zone sits straight
on the bottom zone). The in-between frames are this image with part of the band cut out. So:

- **If rows 300 to 828 are deleted, the result must be a complete, correct-looking section:** a
  shorter screen in a closed frame, the same shape and size as current-right-section.png
  (1536 x 496). Row 299 and row 828 must join seamlessly.
- The cables and rails crossing the band are what "stretch" as it opens.

**The text screen:** one recessed screen with a thick bevelled brass bezel, filled with **FLAT
MAGENTA #FF00FF** at exactly **x 70 to 1190, y 130 to 950** (the magenta rectangle on the
template). It is perfectly flat: no texture, no gradient, crisp edges, slightly rounded corners
are fine. Magenta is used nowhere else. The game draws its text there.

**The right column (x 1210 to 1536):** the controls and the gear, built INTO the housing like the
attached panel's oval buttons. Each control is cast from the same metal and sits flush in a
socket shaped exactly to it. Not a square button stuck in a round hole, and not the current
plain square keys. Small engraved or inlaid icons, unlit (pale brass), readable at about 50 px:

| Template circle | Control | Icon |
|---|---|---|
| top zone, upper (y 150 to 210) | **Expand / collapse** | a double chevron pointing up |
| top zone, lower (y 225 to 285) | **Scroll the text up** | a single chevron / triangle pointing up |
| bottom zone, upper (y 845 to 905) | **Scroll the text down** | a single chevron / triangle pointing down |
| bottom zone, lower (y 920 to 980) | **Replay the last line** | a curved arrow looping back |

**The gear** (orange circle on the template, centre about x 1440, y 900, about 130 px across):
a small brass gear, seen face-on, sitting in a round recessed socket in the right end of the
housing, partly visible through an opening, as if part of the opening mechanism. It turns while
the section opens.

**Cables** (grey lines on the template): two or three ribbed black cables run straight up the
right side from the bottom zone to the top zone, through the band, passing behind or beside the
gear. They are anchored in sculpted brass collars in the top zone and the bottom zone (never in
the band).

**The left edge (x 0 to 40, yellow strip on the template)** joins the rest of the panel, which
continues to the left. In the top zone and bottom zone it must match the LEFT EDGE of
current-right-section.png: the curved brass hump and the black ribbed hoses there continue
across the join. In the band it is plain vertical structure.

**The top of the image** (rows 0 to about 105) rises above the panel and is seen over the game
view: keep it a low sculpted crest with the background showing around it, rising gently from the
left (where it meets the existing hump) to the right end (where it meets the end cap's crest),
like the attached panel's silhouette.

**The right end (x 1500 to 1536)** is the end of the whole panel: the end cap with its vents,
like the right end of current-right-section.png.

**Background:** pure black #000000 wherever there is no machine (or transparent, if you can).
**No text, letters or numbers anywhere.**

## Image 2: the gear on its own, 1024 x 1024

Exactly the same gear as in Image 1 (same teeth, same hub, same metal, same light from the upper
left), alone, face-on, centred, about 800 px across, on pure black. Nothing else in the image.
The gear must look right at ANY rotation, so: evenly spaced identical teeth, a round hub, no
shadow that only makes sense at one angle. I will rotate it myself.

## Image 3 (optional): Image 1 with the controls lit

Identical to Image 1 pixel for pixel, except the four controls glow warm amber through their
engraved icons, as if pressed or active.
