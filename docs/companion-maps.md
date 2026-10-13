# Companion maps: shine, height and glow for your textures

From 2026-10-12, the GPU renderer reads up to three extra greyscale pictures for any texture. They are optional: without them,
the renderer works out shine from the colour art and its material (rooms\_materials.json), and relief from the art's brightness.

| File (beside the colour) | What it says | Black | White |
|---|---|---|---|
| `NN-name_rough.png` | how rough the surface is | polished: sharp, strong highlights | matte: no highlight |
| `NN-name_height.png` | what is raised and what is sunk | deepest | highest |
| `NN-name_glow.png` | what glows by itself (lamps, embers, runes) | does not glow | shows at full painted colour, whatever the light |

- **Mid-grey (128) rough** means "as the material is", so a flat grey map changes nothing. Darker areas shine more and lighter
  areas less, relative to the texture's material (gold, stone, wood ...).
- **Height** replaces the brightness-guessed relief with your own, and the parallax depth (phase 4a) uses it instead of guessing from the art's cracks and joints.
- **Glow** has no bloom yet. It keeps those texels lit in the dark.

## Making them (ChatGPT)

Ask for them in the same conversation as the colour render, so they match it pixel for pixel. Something like:

> Now make three greyscale maps for this exact image, same size and framing, nothing moved:
> 1. a ROUGHNESS map: black where the surface is polished, wet or metal, white where it is dull (rough stone, wood, cloth);
> 2. a HEIGHT map: white for raised parts (stones, rivets, carved lines' edges), black for sunken parts (mortar, cracks, carving);
> 3. a GLOW map: pure black everywhere except things that give off light, which are white.

They must keep the colour picture's exact framing. If ChatGPT re-draws or shifts anything, the maps won't line up.

## Installing

Put them in the same folder as the colour (e.g. `decals\SPAROOM\4k-2k\09-spacop01_rough.png` beside `09-spacop01.png`), with
the colour's name plus the suffix, and run Fit-RoomTextures as for the colour.

- It fits each colour and gives its companion maps exactly the same correction (zoom, shift, shape).
- It writes them beside the installed colour (`hires\09-spacop01_rough.png`) and backs up any they replace.
- The report's Companions column lists which went in.

The renderer reads them on the next entry to the room. The watcher log says "companion maps (shine / height / glow) for N of
them". At 2K (Normal) they are scaled down like the colour, and they are kept to 2048 at most either way.

## Checking

- In game, F6 switches all shine off and on.
- `tools\Show-Materials.ps1 -Room SPAROOM` lists every texture's material (what its shine is based on).
