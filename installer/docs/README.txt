RaptorMod {VERSION} -- a remaster patch for Azrael's Tear (1996)
=================================================================

RaptorMod rebuilds Azrael's Tear for modern PCs: a true-colour picture at your
monitor's resolution, hi-res and remastered textures, lighting, water, fog and
shadows, a widescreen visor HUD, remastered movies, a recorded soundtrack, and
new movement (jump, crouch, smoother walking).

It is a free fan patch. It needs the Steam version of Azrael's Tear, and it
does not change your Steam installation: the game is copied into RaptorMod's
own folder and patched there.


REQUIREMENTS
  - Azrael's Tear, installed with Steam
  - Windows 10 or 11 (64-bit)
  - A graphics card with OpenGL 4.5 (most cards from 2014 on; Intel UHD 620 or
    newer, any recent NVIDIA or AMD card). Without one, use the
    "Play RaptorMod (Classic 8-bit)" shortcut.
  - About 12 GB of free disk space; 8 GB of memory or more recommended


INSTALL
  1. Install Azrael's Tear with Steam (and run it once if you like).
  2. Run RaptorMod-{VERSION}-Setup.exe. Keep the .bin files next to it.
     Windows SmartScreen may say it "protected your PC" because the setup is
     not signed: click "More info", then "Run anyway".
  3. Pick a folder (default C:\Games\RaptorMod). Setup finds the game in your
     Steam libraries, copies it, patches the copy and prepares everything.
     The last step takes a few minutes; a window shows its progress.
  4. Start the game from the "Play RaptorMod" shortcut.

Uninstall from Windows Settings > Apps (or the Start menu). That removes the
RaptorMod folder, including the saved games inside it. Steam is not touched.


CONTROLS
  Mouse            look around
  W A S D          move and strafe
  Space            jump (also skips a spoken line)
  C                crouch / stand
  Z                weapon / MS7 sight (combat mode); left mouse fires
  Hold right mouse the game's pointer, to take, use and push things
  F                helmet lamp
  V                echo scan: outlines doors, items and creatures nearby
  E                open / close the story log box
  Up / Down        scroll the story log
  ESC              visor menu: save, load, options, quit
  F12              field of view (50 / 60 / 65 / 70)
  F3               sticky pointer       F10  invert mouse Y
  F5 F6 F7 F11     wet surfaces / shine / relief / texture repair on-off
  F9               draw with the graphics card or the processor


SETTINGS
  game\raptormod-settings.json in the RaptorMod folder (create it if missing):
    { "fov": 60, "textureQuality": "Ultra" }
  textureQuality "Normal" uses 2K textures (less video memory) instead of 4K.


TROUBLESHOOTING
  - Antivirus: RaptorMod's renderer reads and writes the game's memory inside
    DOSBox and watches the keyboard (for Space, C and Z) while the game is in
    front. That is how it draws the game; some antivirus tools ask about it.
  - Black screen or no picture: try "Play RaptorMod (Classic 8-bit)".
  - Something wrong? Run "Collect Logs" (Start menu > RaptorMod). It saves a
    zip of the logs to your Desktop to attach to your report.
  - Steam updated the game, or the setup says R.EXE does not check out:
    in Steam, right-click Azrael's Tear > Properties > Installed Files >
    Verify integrity of game files, then run the setup again.


Azrael's Tear (c) 1996 Mindscape. RaptorMod is an unofficial fan project, not
affiliated with or endorsed by the game's publishers. See CREDITS.txt and
THIRD-PARTY-NOTICES.txt.