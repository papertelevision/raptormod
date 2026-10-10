# Prompt for ChatGPT: widescreen lower interface for Azrael's Tear

Attach these three images to the chat first (they are the current interface, for style):

- `AztMod\design\incoming\panel-pair.png`: the current panel, lit and unlit
- `AztMod\design\incoming\modes-icons-v1.png`: the current Scan / Map / Menu buttons, off and lit
- `AztMod\design\box-pair-sheet.png`: the current text log, collapsed and expanded

Then paste everything below the line. Ask for the images ONE AT A TIME (Image 1, then 2, ...),
and check each before asking for the next.

---

You are designing the new lower instrument panel for a 1996 first-person adventure game,
Azrael's Tear, which is being remastered for widescreen. I have attached three images of the
CURRENT interface. Keep its look exactly; change its layout and its buttons as described.

## The look to keep (match the attached images)

- Biomechanical steampunk machinery: heavy cast and sculpted metal housing with organic, flowing,
  almost bone-like curves, ribbed black rubber hoses and cables running between parts, brass
  rivets and slotted screws, vents with horizontal slats, small amber indicator lamps.
- Materials: dark olive / gunmetal bronze (around #3A3826 to #2C2A18) with worn, polished brass
  highlights on the raised edges (around #B8A060), deep near-black shadows, grime in the crevices,
  fine scratches. Lamps and lit states glow warm amber / gold (around #FFB030 to #FF8A1A).
- Recessed display screens: deep wells with thick bevelled brass bezels, a rivet in each corner,
  and a dark olive-black glass floor (#2C2A18).
- Rendering style: a painted, pre-rendered 1990s CGI look (like the attached), gritty and detailed.
  NOT modern flat UI, NOT glossy plastic, NOT neon, NOT sci-fi holograms.
- Lighting: soft key light from the upper left, the same on every image so separately made
  pieces match. Straight-on orthographic view: no perspective, no tilt, no camera angle.

## What changes

1. **The panel spans the full width of a widescreen display** (16:10 and 16:9 screens, and wider).
   It is a long, low strip along the bottom of the screen; the 3D game view sits directly above it.
2. **The text log screen on the right becomes much bigger: at least TWICE as wide as now**, and it
   can EXPAND upward over the game view to read more text (see Image 4).
3. **The buttons are re-designed so they are part of the machine.** The current ones are square,
   flat button plates pressed into round sockets; they look stuck on. The new buttons must be cast
   from the same metal as the housing and belong to it. Each button's socket is shaped exactly to
   its button, with a thin dark gap around it. Examples of what works: an oval brass push-plunger
   sitting flush in a sculpted oval socket; a rocker key moulded into a ridge of the housing; a
   lever or toggle growing out of the casting; a rounded key with its icon engraved or inlaid in
   the face. No rectangle-inside-a-circle, no floating plates.

## Every element the panel must contain (left to right)

| Element | What it is | Notes |
|---|---|---|
| Left end cap | Sculpted end of the machine | Vents, hoses curling round the end. |
| **Inventory window** | Recessed screen where the game lists items and notes | Landscape, roughly 4:3. FLAT MAGENTA (see rules). |
| **Inventory scroll up / down** | Two keys that scroll that list | Integrated beside the window, e.g. one vertical brass rocker with an up and a down end, or two stacked keys sharing one sculpted socket. Small engraved chevrons. |
| **SCAN button** | Toggles object scanning | Icon: a beacon (a dot on a small triangle with two arcs radiating above it), as in the attached. |
| **MAP button** | Opens the map | Icon: a folded map (three panels, one folding open). |
| **MENU button** | Opens the system menu | Icon: a cog / gear. |
| **Status gauge** | The player's health bar | A long, narrow horizontal well near the three buttons. FLAT MAGENTA inside. The game draws the bar itself. |
| **Text log screen** | Story narration, dialogue, and scan results scroll here | Wide landscape well, at least twice as wide as the current one (roughly a third of the whole panel's width) and as tall as the panel allows. FLAT MAGENTA inside. |
| **Log controls** | Belong to the text log, built into its right-hand side as one integrated column or cluster | **Expand / collapse** (double chevron pointing up when collapsed, down when expanded), **scroll up**, **scroll down**, and **replay last line** (a curved arrow looping back). |
| Right end cap | Matching the left | Vents, lamps, hoses. |
| Joining sections | Machinery between the modules | Ribbed hoses, brass rails, pipes. **Designed to repeat horizontally without a visible seam**, so the panel can be made wider or narrower for different screens. |

Decorative lamps, vents, gauges and rivets are welcome wherever they fit, but keep every
interactive element clearly readable as interactive and every decoration clearly not.

## Rules every image must follow (they are needed to put the art into the game)

- **FLAT MAGENTA #FF00FF** fills every area the game draws into live: the inventory window, the
  status gauge well, the text log screen. Perfectly flat colour, no texture, no gradient, no glow,
  no anti-aliased soft edges, crisp rectangles (rounded corners are fine). Use #FF00FF NOWHERE else.
- **Background: pure black #000000** around the artwork (or a transparent PNG if you can).
- **No text, letters, numbers or logos** anywhere. Icons only.
- Same lighting, scale and materials in every image, so the pieces fit together.
- The panel's TOP edge may rise in a few sculpted humps (like the current one) but stays mostly low
  and level, because the game view is directly above it. The bottom edge is straight: it is the
  bottom of the screen.
- Buttons must stay readable when small: on screen each will be roughly 70-100 pixels wide.

## The images I need, one at a time

**Image 1: the whole panel, unlit (all buttons off).** One long horizontal strip spanning the full
width of a landscape canvas, about 8.5 times wider than it is tall, centred vertically on black.
The module widths should be in roughly these proportions of the full width:
left end cap 5%, inventory window and its scroll keys 20%, centre console with the three buttons
and the status gauge 22%, text log screen with its controls 40%, right end cap 5%, and joining
sections filling the rest.

**Image 2: the same panel, lit.** Identical in every way, except every button and lamp glows
warm amber / gold as if powered on (like the lower row of the attached button image). Same framing,
same position, pixel for pixel, so the two can be swapped.

**Image 3: a button sheet.** Each interactive control on its own, larger, on black, laid out in a
grid with even spacing: the inventory scroll up/down keys, SCAN, MAP, MENU, expand/collapse
(both arrow directions), log scroll up, log scroll down, replay. Show each one THREE times in a
row: off, lit (amber glow through the engraved icon), and pressed (pushed in slightly, darker
rim, shadow tighter). Each control must look exactly as it does on the panel, in its socket, with
a little of the surrounding housing around it.

**Image 4: the text log, collapsed and expanded, side by side.** On the left, the text log module
exactly as on the panel (collapsed). On the right, the SAME module expanded: the screen and its
brass frame extend straight upward to about 2.5 times the panel's height, as a tall window rising
over the game view, same width, the controls column following it up, the bottom edge unchanged so
it is clearly the same object grown taller. Both screens FLAT MAGENTA inside.

**Image 5: the joining section on its own**, a short length that repeats seamlessly left-to-right
(the left edge continues exactly into the right edge), on black, at the panel's height.
