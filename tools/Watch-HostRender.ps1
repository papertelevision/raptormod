# Watch-HostRender.ps1 -- leave this running; it renders whatever room the player is in.
#
#   .\tools\Watch-HostRender.ps1
#   .\tools\Watch-HostRender.ps1 -Light          # lit instead of flat-textured
#   .\tools\Watch-HostRender.ps1 -Once           # one game session, then exit
#
#   .\tools\Watch-HostRender.ps1 -NoSmooth       # creatures step at 18 Hz, exactly as the game poses them
#   .\tools\Watch-HostRender.ps1 -Portals        # experimental: draw the next room through doorways (off by default)
#
# IT NEVER LAUNCHES THE GAME. It waits for one to appear, takes over the viewport, follows
# the player from room to room, and goes back to waiting when the game exits. Start it once
# and forget it; start the game whenever you like, as many times as you like.
#
# WHY THIS EXISTS. Start-HostRender takes the room as a parameter (or detects it once), runs
# for -Seconds, and stops. That made every observation a staged test run: pick a room, start
# the game, get there, run the command, watch a 30 second window. Walking through a door
# invalidated the whole thing silently -- the camera kept tracking while the geometry stayed
# behind, which reads as a frozen, jumbled renderer rather than as the wrong file.
#
# THE THREE COSTS, and why the loop is shaped the way it is:
#
#   ATTACHING scans the address space for needles. Seconds. Done ONCE per game session.
#   DETECTING the room walks ~2000 scene-graph frames reading a string from each. Hundreds
#     of milliseconds. Done only when the room actually changes.
#   FINGERPRINTING walks the same graph but reads only POINTERS, capped. ~10 ms. Done twice
#     a second, and it is what decides whether the detect is needed.
#
# A room change is caught two independent ways, because missing one leaves the wrong room on
# screen and that is the failure that wastes a session:
#   * the scene fingerprint changes  -- the engine rebuilt the graph
#   * the camera jumps               -- a transition always teleports the player, and a
#                                       walk never covers $JumpUnits in a single frame
[CmdletBinding()]
param(
    # FIELD OF VIEW (Josh, 2026-10-13: the 50 degrees "is a major reason why this game still doesn't feel modern"): the
    # vertical angle of the game's view, in degrees. 0 = the player's choice in <GameDir>\raptormod-settings.json ("fov"),
    # else 60. The GAME's field is set to match every frame (the overlay's AztFovTick reads aztFovTan, a data word written
    # here), so its clicks, hover and shots stay lined up with the picture. -Retro is always the game's own 50 (measured,
    # tools\Tune-Geometry.ps1). -FovKey (F12) cycles 50 / 60 / 70 in play. [[azrael-fov]]
    [double]$Fov = 0,
    [int]$FovKey = 0x7B,
    [switch]$Light,
    [int]$ShadeLevels = 32,
    [double]$FogScale = 1.6,
    [double]$FogNearFrac = 0.04,
    [double]$Ambient = 0.45,
    [double]$NormalLight = 0.25,
    [switch]$Uncap,
    # The guest's frame cap WHILE THE HOST OWNS THE VIEWPORT. The build pins the loop to
    # 24 fps because the engine's own rasteriser never reached it; with the rasteriser off
    # the guest has time to spare and the cap is the only thing holding the picture at 22.
    # Applied on takeover and put back on hand-back, so the engine's own drawing is untouched.
    # 0 = leave the build's cap alone.
    #
    # THE GUEST CANNOT HIT AN ARBITRARY RATE. Its limiter reads a clock that only advances
    # when the timer interrupt fires, and the game runs that interrupt at whatever period its
    # sound driver asked for -- 5 ms in play. So a frame lasts a whole number of 5 ms ticks
    # and the reachable rates are 200, 100, 66.7, 50, 40...: asking for 60 (16.7 ms) rounded
    # UP to 20 ms and delivered 50, which is what the 17:14 run measured. The request is
    # therefore snapped to the nearest reachable rate AT OR ABOVE it, and the log says which.
    #
    # 0 = NO CAP AT ALL while the host renders, and that is now the default (Josh, 2026-10-04:
    # see what it tops out at). The limiter's period is written as 0, so its spin exits at
    # once. Movement still follows the measured rate; everything else frame-tied runs fast.
    # -KeepCap leaves the build's own 24 fps cap in place instead.
    [ValidateRange(0, 250)][int]$Fps = 0,
    [switch]$KeepCap,
    # The delivered frame rate, drawn into the top right of the host's own frame.
    [switch]$NoFpsCounter,
    # Draw with the reference rasteriser (DrawTextured) instead of the fast path.
    [switch]$SlowRaster,
    # Draw the room only, without the character rigs the live scene graph reports.
    [switch]$NoCharacters,
    # MOTION SMOOTHING. The game moves creatures (and doors) on its 18.2 Hz clock tick; the
    # host eases each joint from one pose to the next over that tick, so they move at the
    # picture's frame rate, one tick behind. See AztTool.Smoother. -NoSmooth draws every pose
    # exactly as read (and brings back the per-step MOTION report); -SmoothAll also eases room
    # objects that travel, which is left off because a lift you are riding would shudder.
    [switch]$NoSmooth,
    [switch]$SmoothAll,
    # LIVE DOORWAYS -- OFF. Where the game hangs a still picture of the next room in a doorway,
    # -Portals draws the next room itself (needs C:\Games\RaptorMod\cache\portals.json, from
    # tools\Build-PortalMap.ps1). Switched off by default on 2026-10-05 at Josh's call: the
    # rooms were never modelled to meet, so the joins do not line up perfectly and each
    # doorway would need ironing out by hand. The game's own pictures are shown instead.
    # -NoPortals is still accepted and means the same as leaving -Portals off.
    [switch]$Portals,
    [switch]$NoPortals,
    # Log what the game says is under the cursor against what the host drew there (PICK lines).
    [switch]$NoPickProbe,
    # THE HELMET LAMP (see Raster.Lamp). The room is held a little under the level the textures
    # were painted at, and a spotlight fixed to the player's view lifts whatever it points at
    # back up and past it, fading with distance. On by default; -NoLamp draws the room flat,
    # exactly as before.
    #   -LampRoom    the room's general level; 1 = as painted, lower = darker away from the beam
    #   -LampPower   how much the beam adds at its centre, close up
    #   -LampRange   the distance (world units) at which the beam is down to half
    #   -LampInner / -LampOuter   the beam's full-strength and cut-off half-angles, degrees
    # TEXTURE FILTERING (see Raster.Filter): close up, each pixel takes one of the four nearest
    # texels by a fixed screen pattern, so big texels blend instead of standing as squares; far
    # away, pre-shrunk copies of each texture are read so distant surfaces stop shimmering.
    # On by default; -NoTexFilter starts with it off. -FilterKey (a Windows virtual-key code,
    # 0x76 = F7, 0 = none) switches it in play, for comparing the two looks on the same wall.
    # -MipBias below 0 keeps distant textures sharper (and shimmerier), above 0 softer.
    # TEXTURE RESOLUTION EXPERIMENT (see Raster.Tex.Upscaled). Every texture is enlarged by
    # this factor when its room loads -- bicubic, sharpened, back into the palette -- and the
    # room is drawn from the enlarged set. 1 = off. It cannot add detail the originals do not
    # have; what it changes is how they stretch. -HiTexKey (0x77 = F8) switches between the
    # enlarged and the original textures in play. Costs a pause on entering a room for the
    # first time (about 0.2 s at 2, 0.5 s at 4) and memory (8 / 34 MB for a 49-texture room).
    [ValidateSet(1, 2, 4, 8)][int]$TexScale = 1,          # OFF. Tried at 2, 4 and 8 (Josh, 2026-10-05): "isn't helping much ... leave them as-is for now".
    [ValidateRange(0.0, 3.0)][double]$TexSharpen = 0.6,
    [int]$HiTexKey = 0,                                    # no in-play switch for now (0x77 = F8 brings it back)
    # REFLECTIVE WATER (see Raster.MaskBeyond). Any flat, level object whose material is named
    # as water or liquid mirrors the room: the room is drawn a second time, flipped through
    # the water's height, into the pixels where the water shows. -WaterKeep is the share of
    # those pixels left as the water's own texture; -WaterDim how bright the reflection is
    # against the real thing. -NoReflections turns it off.
    [switch]$NoReflections,
    [ValidateRange(0.0, 0.95)][double]$WaterKeep = 0.65,
    [ValidateRange(0.05, 1.0)][double]$WaterDim = 0.72,
    [switch]$NoTexFilter,
    [int]$FilterKey = 0x76,
    [ValidateRange(-3.0, 3.0)][double]$MipBias = -0.35,
    [switch]$NoLamp,
    # The key that switches the lamp on and off in play (a Windows virtual-key code; 0x46 = F),
    # and whether it starts on. Off, the room stays at -LampRoom with no beam and no shadows.
    # Read by the host from Windows, only while the game window is in front: see tools\Keys.cs.
    [int]$LampKey = 0x46,
    [switch]$LampStartsOff,
    # THE FLASHLIGHT STARTS OFF (Josh, 2026-10-13: "start the game with the flashlight off. Later I will add more
    # 'visibility low' flashlight suggestions"): off when the watcher starts and again when a NEW game boots (not a load's
    # re-boot -- the player's own choice stays); F turns it on. -LampStartsOn = the old way. (-LampStartsOff still works.)
    [switch]$LampStartsOn,
    [switch]$NoSteadyPlay,          # characters eased one tick per pose as before, not played back steadily (SceneGraph.Smoother.Adaptive)
    #   -LampHalo    how much of the lamp goes into the wide, dim corona round the hot spot
    #   -LampLag     seconds the beam takes to catch up with the view when you turn (0 = rigid)
    # (First defaults were 0.70 / 0.90 / 600 / 10-24: Josh, 2026-10-05 -- "a vignette effect but
    # not much else". A cone that wide fills the view. Now a small hot spot in a dim corona,
    # stronger, shorter-ranged, and trailing the view slightly.)
    # (v2 -- room 0.62, range 380, corona 0.22 -- Josh: "pretty cool but makes the game very
    # dark. Expand the lit area to the previous view ... keep every other effect". So v3 is v1's
    # wide 10-24 degree beam at v1's room level and reach, with v2's hot spot and lag on top.)
    #   -LampHaloInner / -LampHaloOuter   the wide beam's full-strength and cut-off half-angles
    # TWO ROOM LEVELS, like eyes adjusting (Josh, 2026-10-05). With the lamp OFF the room sits
    # at -LampRoomOff, only a little under how it was painted, so the game is comfortable to
    # play without the light. Switching the lamp ON drops the surroundings to -LampRoom, so
    # the beam stands out against a darker room -- and the lamp's own strength was raised by
    # the same amount, so what it lights is exactly as bright as it was before the split.
    [ValidateRange(0.2, 1.2)][double]$LampRoom = 0.54,
    [ValidateRange(0.2, 1.2)][double]$LampRoomOff = 0.82,
    [ValidateRange(0.0, 3.0)][double]$LampPower = 1.68,      # +0.08 into the wide beam, to pay back the 0.08 taken off the room level while the lamp is on
    [ValidateRange(50, 5000)][double]$LampRange = 550,
    # (hot spot widened 80% from 4-11 at Josh's request, 2026-10-05)
    [ValidateRange(1, 40)][double]$LampInner = 8.64,
    [ValidateRange(2, 60)][double]$LampOuter = 21,
    [ValidateRange(0.0, 1.0)][double]$LampHalo = 0.495,
    [ValidateRange(1, 60)][double]$LampHaloInner = 10,
    [ValidateRange(2, 80)][double]$LampHaloOuter = 24,
    [ValidateRange(0.0, 1.0)][double]$LampLag = 0.12,
    # SHADOWS CAST BY THE LAMP (see Raster.SetShadow). The lamp is placed this far to the
    # RIGHT of and ABOVE the eye, in world units, and whatever it cannot see gets the room's
    # level without the beam. The further from the eye, the wider the shadows: a lamp a real
    # helmet's width away (8 or so) gives hairlines, so the default is nearer a lamp held out
    # at arm's length. -NoShadows keeps the lamp and drops the shadow pass (about 1.5 ms).
    [switch]$NoShadows,
    # (First defaults were 30 right / 14 up. Josh, 2026-10-05: "fantastic", but the sideways
    # throw "feels off" -- assume the lamp is in the centre of the visor -- and a door cast a
    # shadow while the wall it hangs in did not. So: no sideways offset, the lamp sits ABOVE
    # the eye and shadows fall down and behind things; the lamp is kept under the ceiling;
    # the lamp's view covers the whole picture; and every face blocks light, whichever way it
    # faces, so one-sided walls cast like the doors do.)
    #
    # A LAMP PAIR. A lamp exactly in the middle casts nothing the eye can see, and one moved
    # straight up hides most of its shadows behind the very things that cast them (tried:
    # pillars cast none at all). So the "centre" lamp is two, LampOffsetX to the LEFT and to
    # the RIGHT of the eye and LampOffsetY above it, each with half the light: everything in
    # the beam gets a fringe of half-shadow on both sides, evenly. SINCE 2026-10-05 ONE LAMP at
    # (+X, Y) is the default: the pair cost a second shadow map and a second lookup per pixel
    # (~5 ms of a frame; Josh: "single pass for the flashlight shadows"). -LampPair brings it back.
    [ValidateRange(-200, 200)][double]$LampOffsetX = 24,
    [ValidateRange(-200, 200)][double]$LampOffsetY = 8,
    [switch]$LampPair,
    #   -ShadowDark   how far below the room's level a full shadow goes (0 = only the lamp is lost)
    #   -ShadowNear / -ShadowFar   shadows are full strength up to Near and have faded out by Far
    [ValidateRange(0.0, 0.9)][double]$ShadowDark = 0.38,      # (0.30 until 2026-10-07: Josh, shadows "a touch darker")
    [ValidateRange(0, 5000)][double]$ShadowNear = 140,
    [ValidateRange(50, 10000)][double]$ShadowFar = 900,
    # SHADOW MAPS: 512 tall (800 cost ~4 ms more a frame; Josh chose 512 on 2026-10-05), width
    # following the picture's shape; -ShadowSoft is the penumbra's reach in map texels (0 = hard).
    [ValidateRange(128, 2048)][int]$ShadowSize = 512,       # shadow map HEIGHT; its width follows the picture's shape
    [ValidateRange(0.0, 3.0)][double]$ShadowSoft = 1.0,
    # AUDIT MODE: check the host's picture against the ENGINE's, automatically, as you play.
    # Whenever the camera has been still for a moment (at most every $AuditSeconds), the
    # viewport is handed back for about half a second, the engine's own picture of the same
    # view is copied, and the two are compared block by block. Every check is a line in the
    # log and a row in $AuditDir\audit.csv; a pair that disagrees is saved as one PNG, engine
    # on the left and host on the right. Walk through the rooms, pause in each, and the list
    # of what the host draws wrongly writes itself. The picture flicks to the engine's (and
    # its frame rate) for that half second each time.
    [switch]$Audit,
    # TRUE COLOUR, PHASE 0 (see tools\Overlay.cs). The picture is shown in the renderer's own
    # click-through window laid over the game's viewport, and the game is handed a flat key
    # colour instead; whatever the game draws over the view is read back and laid on top.
    # This phase shows the SAME 8-bit picture as before -- it proves the route, not the colours.
    [switch]$TrueColour,
    # THE GPU, TRUE-COLOUR PICTURE IS THE DEFAULT (Josh, 2026-10-07), boot sequence included. -Retro gives the
    # old 256-colour picture drawn by the processor instead (the "retro style" version).
    [switch]$Retro,
    # THE VISOR BOOT, DRAWN BY THE HOST (tools\BootHd.cs, script art\boot-hd.json): the GPU version's own
    # copy of the boot at display resolution, timed by the game's boot clock. -NoBootHd shows the game's
    # 8-bit boot through the overlay instead (as the retro version always does).
    [switch]$NoBootHd,
    # START THE GAME FROM HERE, once everything that can be ready before it is (Josh, 2026-10-07: "the GPU
    # can load before the game starts"). Play-HostRender.cmd passes it; without it the watcher waits for
    # a game started some other way, as before.
    [switch]$Launch,
    [string]$GameDir = 'C:\Games\RaptorMod\game',
    # -Launch shows "Loading RaptorMod..." and holds the game until the renderer has hold of it; this
    # skips both (the game then runs as soon as it starts, as before).
    [switch]$NoLoadingScreen,
    # The visor's top shading drawn smooth by the host across the full width (and over the boot);
    # -NoVisorShade leaves the game's own dithered copy.
    [switch]$NoVisorShade,
    # The lower HUD slides in WITH the boot (art only until the game's screen is found); -HudAfterBoot
    # brings it in after the boot instead, as before.
    [switch]$HudAfterBoot,
    # The boot's own sound: low, soft digital blips as its lines land and type out (tools\BootHd.cs BootSound).
    # -NoBootSound silences it; -BootSoundVolume sets its peak level (0..1, default 0.36).
    [switch]$NoBootSound,
    [switch]$NoStandUp,             # a new game's reveal without the raptor getting up (BootHd.StandUp: the view's tilt, the visor's dust)
    # THE LOADING SCREEN'S SOUND (Josh, 2026-10-07): 'Loading ... Raptor Mod.' over his raptormod_loading track (art\loading,
    # built by design\boot-sounds\Make-LoadingAudio.ps1). The game is let go only once the voice has finished; the track fades.
    [switch]$NoLoadingSound,
    # THE HUD'S SLIDE-IN SOUND (Josh, 2026-10-07): his ratchet (art\boot\hud-ratchet.wav, from Make-LoadingAudio.ps1), played
    # as the held HUD is let go to slide in during the boot. Stereo, at this level against the boot's own sounds.
    [switch]$NoHudSound,
    [double]$HudSoundLevel = 0.5,
    [double]$LoadingTrackGain = 0.3,
    [double]$LoadingVoiceGain = 0.5,
    [double]$BootSoundVolume = -1,
    # PHASE 1: with -TrueColour the picture itself is drawn in true colour (painted textures,
    # bilinear + mip blending, lighting as a real multiply). -NoRgb keeps the 8-bit picture in
    # the overlay window; -RgbKey (F8) switches between the two while playing.
    [switch]$NoRgb,
    [int]$RgbKey = 0x77,
    # THE GRAPHICS CARD (tools\GpuRaster.cs) DRAWS THE TRUE-COLOUR PICTURE. Set up at the start of
    # a session; if it cannot be (no driver, no OpenGL 4.5) the processor draws, as before. It
    # draws everything the processor does, term for term: lighting, the flashlight's beam and
    # shadows, fog, torches and their shadows, water reflections, dust (tools\Test-GpuRaster.ps1
    # -Full compares the two). F9 (-GpuKey) switches between card and processor while playing;
    # -NoGpu keeps the processor. Not on the card: live doorways (-Portals, off by default).
    [switch]$NoGpu,
    [int]$GpuKey = 0x78,
    # ON THE CARD ONLY (Josh, 2026-10-06): RELIEF (bump maps made from every texture, lit per pixel
    # by the flashlight and torches), CORNERS (-AO: contact darkening), the flashlight's BEAM in
    # the air (-Beam), GROUND MIST and PARTICLES (embers, drips, steam, footstep dust) from the room
    # files. 0 / the -No switches turn each off; the processor's picture (F9) has none of them.
    # The beam is a faint FAN rising from under the visor toward the centre (Josh, 2026-10-06), never
    # more than 15% of white over what is there, so it lightens rather than veils. -Beam 0 turns it off.
    [ValidateRange(0.0, 3.0)][double]$Relief = 1.0,
    # THE RELIEF, as Josh chose it on 2026-10-07 in the first room and then had applied GAME-WIDE:
    #  * SHARP maps -- at the texture's full size, from its FINEST detail (bumps 1-2 texels across, plus -ReliefMid of the
    #    2-8 texel layer), the lamp brightening a bump at most -ReliefGain times (it was ~3.5x on floors seen at an angle).
    #    -ReliefSharpRooms: '*' = every room (the default), or a list; rooms left out get the first, half-size maps.
    #    -ReliefTile lays them smaller (2 = half size) but MEASURED: it borrows relief from other pieces sharing the
    #    texture file, so it stays 1. -ReliefSharpK: their steepness.
    #  * MICRO RELIEF -- stone-like bumps generated in the world, finer than any texel, over the texture's own relief
    #    ("I really want a high resolution feel"): -Detail strength (0 = off), -DetailScale the coarsest bumps in world
    #    units (each finer layer half that; Josh went 1.2 -> 1.02 -> 0.8), -DetailRough, -DetailAO (hollows darker).
    #    Not on characters and creatures: laid in the world, it would slide across them.
    #  * SHADOWS IN THE TEXTURE'S OWN COLOUR, as a Photoshop multiply layer makes them, not a greyish darkening ("dark
    #    gray shadows ... feel muddy"): -ReliefTint, 0 = plain.
    #  * OPACITY 50%, as a layer's (texture relief and micro relief together; tried 80% first): -ReliefOpacity.
    [string[]]$ReliefSharpRooms = @('*'),
    [ValidateRange(0.0, 200.0)][double]$ReliefSharpK = -1,
    [ValidateRange(0.25, 8.0)][double]$ReliefTile = 1.0,
    [ValidateRange(0.0, 2.0)][double]$ReliefMid = 0.35,
    [ValidateRange(1.0, 99.0)][double]$ReliefGain = 1.6,
    [ValidateRange(0.0, 2.0)][double]$Detail = 0.4,
    [ValidateRange(0.1, 20.0)][double]$DetailScale = 0.8,
    [ValidateRange(0.0, 10.0)][double]$ReliefTint = 3.0,
    [ValidateRange(0.0, 1.0)][double]$ReliefOpacity = 0.5,
    [ValidateRange(0.0, 1.5)][double]$DetailRough = 0.85,
    [ValidateRange(0.0, 1.0)][double]$DetailAO = 0.10,
    # MIPMAPS ON THE CARD, per pixel and anisotropic (Josh: detail should soften in the distance, not shimmer).
    # -NoPixelMip goes back to one level per triangle as the processor does; -GpuMipBias below 0 sharper, above 0
    # softer; -Anisotropy 1 turns the anisotropic filtering off (8 = floors stay sharp as they recede).
    [switch]$NoPixelMip,
    [ValidateRange(-2.0, 2.0)][double]$GpuMipBias = 0.0,
    [ValidateRange(1.0, 16.0)][double]$Anisotropy = 8.0,
    [ValidateRange(0.0, 1.0)][double]$AO = 0.6,
    [ValidateRange(0.0, 3.0)][double]$Beam = 0.7,
    [switch]$NoMist, [switch]$NoParticles,      # F9 (F10 is the game's own invert-mouse key)
    # REPLACEMENT TEXTURES (true colour only). A PNG in this folder named like a texture's own
    # exported file (08-ecrflra2.png) replaces its colours, at any size. The game's files are
    # not touched and the game's own texture memory is not involved.
    [string]$TexOverrideDir = 'C:\Games\RaptorMod\textures\hires',
    # TEXTURE QUALITY (Josh, 2026-10-11): Normal = replacement textures at most 2048 on their long side (a scaled copy, made
    # once beside the folder), Ultra = as large as they are (4096). Empty: the player's choice in <GameDir>\raptormod-settings.json
    # ("textureQuality"; the title's Options will offer it -- "coming soon" for now), else Ultra.
    [string]$TextureQuality = '',
    # THE ROOM'S LOADING COVER (tools\RoomCover.cs, Josh 2026-10-12: "we shouldnt see the 256 version"): from a room change
    # until the new room's first frame, the visor goes dark with "RAPTOR H.U.D. // ANALYZING ENVIRONMENT" and a percentage at
    # the top of the view, while its textures decode (several at once) and go up to the card. -NoRoomCover: the old way.
    [switch]$NoRoomCover,
    # THE SESSION'S TEXTURE CACHE: decoded room textures kept for the session up to this many GB (the least recently visited
    # rooms give theirs up first). 0 = a quarter of the computer's memory, between 2 and 16 GB.
    [double]$TextureCacheGB = 0,
    # MATERIALS (Josh, 2026-10-12: "Shine where it belongs"): every texture's highlight under the lamp and the placed lights,
    # from rooms\_materials.json (graphics card only). -NoShine: none; -Shine: all of it x this; -ShineKey (0x75 = F6, 0 = none)
    # switches it in play, to compare on the same wall.
    [switch]$NoShine, [double]$Shine = 1.0, [int]$ShineKey = 0x75,
    # WET SURFACES (Josh, 2026-10-12, phase 2): the damp caves' and the spa rooms' "wet" block (rooms\_defaults.json classes,
    # a room's own file). -NoWet: none; -WetKey (0x74 = F5, 0 = none) switches it in play.
    [switch]$NoWet, [int]$WetKey = 0x74,
    # THE RELIEF (normal mapping) off and on in play, in the true-colour picture (Josh, 2026-10-12: "a toggle for the normal
    # mapping as well so I can compare all three effects"): -ReliefKey (0x76 = F7, which there did nothing; 0 = none). Each of
    # the three switches (F5 wet, F6 shine, F7 relief) says what it did on the visor.
    [int]$ReliefKey = 0x76,
    # TEXTURE REPAIR (Josh, 2026-10-12, phase 3: "Fix badly stretched textures ... Hide the repeats"): faces whose 1996 texture
    # coordinates smear or stretch the art re-laid, repeating surfaces mixed (GpuRaster.SetRelay; a room's "repair" block:
    # {"skip": [texture names], "mix": false, "stretch", "flat"}, or "repair": null for none). -NoRepair: none; -RepairKey
    # (0x7A = F11, 0 = none) switches it in play, with a note on the visor like F5-F7.
    [switch]$NoRepair, [int]$RepairKey = 0x7A,
    # PARALLAX DEPTH (Josh, 2026-10-12, phase 4a: "Mortar lines, planks and stone blocks appear sunken as you move past"): the
    # card steps into each texture's height map (GpuRaster.Parallax*), close up, with the relief (F7 switches both).
    # -NoParallax: none; -ParallaxDepth: how deep its deepest texel lies (world units); a room's "parallax": x that (null: none).
    [switch]$NoParallax, [double]$ParallaxDepth = 1.0,
    # THE VISOR MATERIALIZES THE ROOM (Josh, 2026-10-13): once ANALYZING ENVIRONMENT reaches 100% (the room cover lifts), once a
    # loaded game is handed over, and once a new game's boot animation is done, the room sweeps in from the scan's teal wireframe
    # to full texture in a fast wave (GpuRaster.StartMaterialize). -NoMaterialize: none.
    [switch]$NoMaterialize,
    # THE CONVERSATION CUE (Josh, 2026-10-13: in place of the original's red glow, which the manifest now removes): while
    # a conversation is up, the visor's edges glow amber and a soundwave badge reads "Conversation recording engaged..."
    # at the lower left (ScanWire.cs ConvTag, in the card's present pass); until the options print, the collapsed log box
    # shows static and '//Initializing Dialogue Interface...' (Panel.InitStatic). -NoConvCue: none of it.
    # FOOTSTEPS (BootHd.cs Footsteps; Josh, 2026-10-14): subtle steps as the player walks, by what is underfoot (stone, tile, wood,
    # metal, water), at the game's effects level. -NoFootsteps: none; -FootstepVolume: a walking step's peak (0..1, default 0.2).
    [switch]$NoFootsteps, [double]$FootstepVolume = -1,
    # THE JUMP (Josh, 2026-10-15: "a basic jump button assigned to the SPACE BAR"): Space jumps -- the game's own gravity does
    # the arc, the host steering its fall speed word 0x152592 tick by tick for an EASED top (rises 16 10 6 3 1, JumpHang ticks
    # held, then 1 3 6 10 down). Space still skips a spoken line. The weapon / MS7 sight toggle is on Z, and C TOGGLES a
    # crouch (F stays the lamp). -NoJump: Space and Z/C as stock. -JumpPower: the top in units (36; 16 is the least that leaves
    # the ground). -NoCrouch: C to the game. -CrouchDrop: how far the eye comes down (units; standing it is 45 over the
    # floor). -CrouchSpeed: walking / running speed while down. -CrouchTime: seconds to go down or come up.
    # -NoEyeSmooth: the view's height follows the game's 18 Hz steps as they come (else eased between them, for jumps,
    # stairs and crouching). -LandBob: how far the view dips on a jump's landing (units; 0 = none), over -LandBobTime s.
    [switch]$NoJump, [int]$JumpPower = 36, [int]$JumpHang = 1,
    [switch]$NoCrouch, [double]$CrouchDrop = 16, [double]$CrouchSpeed = 0.65, [double]$CrouchTime = 0.2,
    [switch]$NoEyeSmooth, [double]$LandBob = 2.5, [double]$LandBobTime = 0.28,
    [switch]$NoConvCue, [switch]$NoVisorFog, [switch]$NoEyeShine, [switch]$NoImpacts, [switch]$NoEcho, [switch]$NoEchoLabels, [switch]$LoadSilence, [switch]$AudioMeter, [switch]$NoLoadGameMute, [double]$MapPanelLight = 0.6, [switch]$NoMapLights, [double]$MapZoomStart = 1.5, [int]$EchoKey = 0x56,
    # THE SHOT RECORD's input history (Step-ShotWatch): every frame's buttons kept, to explain a shot nobody meant (Josh,
    # 2026-10-11). Off by default since the 2026-10-13 performance audit (7 guest reads a frame); the weapon log stays.
    [switch]$ShotLog,
    # THE EARLY HAND-SHAKE (2026-10-13 performance audit): in steady true colour (aztInjSync 0) 'ready' is armed right after
    # the camera read instead of at the end of the frame, so the guest clears it while the host draws and the next wait is
    # one read. -NoEarlyReady = the end-of-frame order everywhere, as before.
    [switch]$NoEarlyReady,

    # THE PICTURE IS DRAWN AT THE SIZE IT IS SHOWN, WHATEVER THE DISPLAY. Nothing here names a
    # resolution: the size is measured from where the game's viewport actually sits on this
    # screen (1440x835 on 1920x1080, 2134x1238 on 2560x1600, 2880x1670 on 4K). -TcScale draws
    # at a fraction of that for a slower machine; -TcMaxPixels caps it, scaled down evenly, so
    # a 4K display does not ask for three times the work of a 1440p one by default.
    [ValidateRange(0.25, 2.0)][double]$TcScale = 1.0,
    [int]$TcMaxPixels = 0,      # (0: the player's settings file "tcMaxPixels", else 5,500,000 -- see below)
    # AFTER THE PICTURE IS DRAWN (true colour only): edge smoothing and sharpening, BOTH OFF.
    # EDGE SMOOTHING OFF (Josh, 2026-10-05: "I no longer need the anti-aliasing/smoothing
    # feature"): with grainy upscaled textures it took the grain for edges. -AA turns it back on.
    # SHARPEN OFF (Josh, 2026-10-06: "not much benefit"); -Sharpen 0.5 is how it was. On the
    # graphics card it is part of the compose pass, on the processor PostJob's. (-PostKey <vk>
    # binds a key to switch both while playing; F9 is the card/processor switch now.)
    [switch]$AA,
    [switch]$NoAA,                # accepted and ignored: it is the default now
    [ValidateRange(0.0, 2.0)][double]$Sharpen = 0.0,
    [int]$PostKey = 0,
    # DIAGNOSTIC PROBES, OFF BY DEFAULT. The pick probe (what is under the cursor, every 200 ms)
    # and the collision-table watch were written to chase the hover/click and fall-through-the-
    # floor faults, both fixed and confirmed. They cost about a millisecond of every frame and
    # most of the log. -Probes turns them back on.
    [switch]$Probes,
    # (Smoother models -- curved subdivision at load, F9 -- were tried on 2026-10-05 and removed
    # at Josh's request: "doesn't add anything and makes characters look worse".)
    # WIDESCREEN. The game's picture is 4:3; on a wider display the 3D view now runs the full
    # width of the screen, past the pillars either side, keeping the same vertical framing (so
    # the middle is exactly the game's own view and clicking still lines up; the game's cursor
    # cannot reach the extra width). The panel at the bottom stays 4:3 for now. -NoWide = 4:3.
    [switch]$NoWide,
    # THE WIDESCREEN PANEL (Josh, 2026-10-06): the new lower interface drawn by the host across
    # the full width (tools\Panel.cs, art from src\Build-HudWide.ps1). -NoWidePanel leaves the
    # game's own 4:3 copy of it.
    [switch]$NoWidePanel,
    # THE SCANNER'S WIREFRAME (Josh, 2026-10-07): scanning a creature shows its REAL model walking and turning, as a
    # vector wireframe like the boot's chalice, in place of the game's ten-frame bitmap (tools\ScanWire.cs). The sets
    # replaced: the rig <NAME>.XAF walking its .ANI WALK range, identified by the game's own GAME\AZTEX\WIRE\<NAME>00.PCX.
    # The host also holds EVERY scan to the stock length (~4.2 s): the game counts it in frames, and with the frame
    # cap lifted it was over in 0.3-1 s. The raptor (Kurt, Lincoln), Lurka and the small dinosaurs (Eugene).
    [switch]$NoScanWire,
    # THE MUZZLE FLASH (Josh, 2026-10-07): each shot lights the surroundings for a moment, casting shadows (the lamp
    # pair's shadow views, drawn during the flash even with the flashlight off). A shot is the ammo count going down.
    [switch]$NoMuzzleFlash,
    [double]$FlashPower = 1.6,
    [double]$FlashRange = 420,
    # THE PLAYER'S SHADOW (Josh, 2026-10-07): the raptor's own body (RAPTOR.XAF, walking or idling as the player moves)
    # stands under the camera, unseen, and is drawn only into the PLACED room lights' shadow views -- so the player casts
    # a raptor silhouette from those lights. Graphics card only; not in the flashlight's views (it would shade the beam).
    [switch]$NoPlayerShadow,
    # How much of the room's own level a placed light's shadow also takes away, where that light dominates (0 = the
    # light's own share only, as before 2026-10-07; Josh: 'a touch darker')
    [ValidateRange(0.0, 0.9)][double]$LightShadowDeep = 0.35,
    # A placed light's shadows on the graphics card are ALL ROUND (2026-10-08): six 90-degree views, each this many
    # texels square (768: about twice as sharp as the old single 110-degree 512 view, ~14 MB a light)
    [ValidateRange(128, 2048)][int]$LightShadowFace = 768,
    # SOFT CONTACT SHADOWS (2026-10-08): a placed light's size in world units -- its shadows are sharp where the caster
    # touches and soften the farther they fall (the player's feet crisp, the head's end of the shadow soft). 0 = hard.
    [ValidateRange(0.0, 40.0)][double]$LightSoft = 4,      # (6 until 2026-10-08: Josh, "set the torch from 6 to 4")
    # ...and the flashlight's (its pair of shadow views; the muzzle flash shares them). 0 = the old even softening.
    [ValidateRange(0.0, 40.0)][double]$LampSoft = 3,
    # VOLUMETRIC FOG: per room, a "volume" block in its atmosphere file (rooms\<ROOM>.json); -NoVolume turns it off.
    [switch]$NoVolume,
    # MODERN WATER: per room, a "water" block (rippled, shiny, lit from below, caustics on the walls); -NoWaterFx turns it off.
    [switch]$NoWaterFx,
    # BOUNCED LIGHT: per room, a "gi" block -- worked out in the background the first time a room is entered with those
    # lights and that geometry, cached in <CacheDir>\gi (GiBake). -NoGi turns it off.
    [switch]$NoGi,
    # no light from the artwork (a room's "artLight": the room's level shaded by the original art's painted light and shade)
    [switch]$NoArtLight,
    # the HUD's log and inventory text as the game's own pixels, not redrawn in vector type (Panel.HostText)
    [switch]$NoHostText,
    # the log laid out where the GAME puts it (its box, its scroll word), not in the art's recess with the host's own
    # padding and eased line scrolling (Panel.LogOwn, 2026-10-10)
    [switch]$NoLogLayout,
    # THE DAMAGE BADGE: "Damage taken!" in the visor's lower left when the player's health falls. -NoDamageBadge: none.
    [switch]$NoDamageBadge,
    # THE DAMAGED VISOR: the glass scratched, dirtied, cracked and finally broken as the health falls, a hit's static, the
    # vitals monitor near death (ScanWire.cs VisorDamage, in the card's present pass). -NoVisorDamage: clean glass.
    [switch]$NoVisorDamage,
    # GHOSTS: the characters a room's "ghost" block names (WELLROOM: Niamh) drawn by the card as glowing smoke, shedding
    # wisps, with a faint light of their own (GpuRaster.DrawGhost). -NoGhost: drawn as solid models, as before.
    [switch]$NoGhost,
    # THE TITLE MENU: the 4K title with Continue / Load / Options / Quit / Story, shown by the loading gate while the game
    # holds its title stage (Build-AztMod $ENABLE_TITLE_MENU). -NoTitleMenu (or -Retro): the game's own title, waiting for a key.
    [switch]$NoTitleMenu,
    # THE GRAIL'S GOLD on the title (Josh, 2026-10-13): fine gold flakes rising from the chalice, a few close ones as bokeh
    # (LoadingScreen.cs TitleScreen.GrailFx). -NoGrailDust: the art alone.
    [switch]$NoGrailDust,
    # ...and the grail's light flickering on the man's face (TitleScreen.GrailGlow). -NoGrailGlow: none.
    [switch]$NoGrailGlow,
    # THE 3D MAP (Josh, 2026-10-14): the map button shows the room as the scan's wireframe over the dimmed visor view, turned
    # by dragging with the left button (wheel: closer / further), the doors as amber arrows (GpuRaster.DrawMap, Step-Map).
    # Every room (Josh, 2026-10-14, after the CORICORI proof: "I want this map solution added to all rooms in the game");
    # -Map3DRooms A,B: only those (and -Map3DAll is the default anyway); -NoMap3D: the game's own maps.
    [switch]$NoMap3D, [string[]]$Map3DRooms = @('*'), [switch]$Map3DAll,
    # the game's own system menu (fold-out) in true colour, not the host's visor one (VisorMenu.SetSys / Set-SysMenuHot)
    [switch]$NoSysMenu,
    # VISOR READOUTS: a room's "visor" block types a message onto the visor on entering (e.g. MINEMAZE with the flashlight off). -NoVisorNotes: none.
    [switch]$NoVisorNotes,
    # THE MEMORY CORE: the host's large save/load screen (on by default; the build moved the list's click targets to it).
    [switch]$NoMemCore,
    # THE PICTURE INTO ITS WINDOW (2026-10-08): the card draws it straight into the overlay's own card window. -CpuPresent:
    # the old way (read back, stretched on the processor, copied by GDI).
    [switch]$CpuPresent,
    # the volumetric fog's march at half size each way, brought back depth-aware (2026-10-08: ~8 ms less at 5.5 M); -VolFull = every pixel
    [switch]$VolFull,
    [string]$ScanWireSets = 'ALL',
    # Items too (batch 2): -NoScanItems leaves every item scan to the game's own bitmaps
    [switch]$NoScanItems,      # every character with wireframe frames; or a list of definitions (KURTB,LURKA)
    # The 3D carries on under the widescreen panel to the screen's bottom, so the panel's halves slide in
    # over the world (Josh's new HUD, 2026-10-06); at rest the panel's black backing covers it from
    # backingTop down. -NoUnderPanel: only down to backingTop (a quarter fewer pixels; the slide then
    # crosses the game's own 8-bit panel). -UnderPanelSeeThrough: no black backing at all.
    [switch]$NoUnderPanel,
    # THE POINTER ACROSS THE WHOLE DISPLAY (tools\Pointer.cs, 2026-10-07): the host takes the pointer over
    # while the game shows it, draws the game's cursor itself, and the panel's halves sit at the display's
    # edges with the seam filled. OFF BY DEFAULT since 2026-10-07: in game it broke button highlighting and
    # picking up items (holding the game's "pointer hidden" flag evidently gates both). -HostPointer to try it.
    [switch]$HostPointer,
    # THE GAME'S CURSORS AS ANIMATED VECTORS (tools\CursorIcons.cs, Josh 2026-10-11): its 30 interaction cursors traced into
    # the visor's glowing lines, each with its own small animation, drawn at the game's own cursor (hover and picking stay
    # the game's); its bitmaps are blanked in its memory meanwhile and put back after. -NoIconCursor: the game's bitmaps.
    [switch]$NoIconCursor,
    # SPACE AFTER A SPOKEN LINE (tools\Keys.cs SpaceGuard, Josh 2026-10-11): Space skips a line, and the game's Space also
    # draws the weapon -- so for a second after a line ends Space is not passed to the game. -NoSpaceGuard: always passed.
    [switch]$NoSpaceGuard,
    [switch]$UnderPanelSeeThrough,
    # ATMOSPHERE (true colour only): fog, floating dust and placed lights, per room, from
    # -RoomsDir\_defaults.json (classes of rooms, e.g. every cave) and -RoomsDir\<ROOM>.json
    # (that room's own lights and overrides). Edit the files; a room re-reads its file when
    # it is entered. -NoFog / -NoDust / -NoLights switch each off for the session.
    [string]$RoomsDir = 'C:\Games\RaptorMod\cache\rooms',
    [switch]$NoFog, [switch]$NoDust, [switch]$NoLights,
    [switch]$TcGameSize,       # draw at the game's own 1600x928 and let the window stretch it (the first true-colour build)
    [int]$KeyIndex = 0,           # palette index handed to the game as the key; 0 = choose one
    [int]$TcMinShare = 400,       # below this share (per 1000) of key colour in the view, the game is showing something else: hide
    [string]$TcRect = '',         # 'x,y,w,h' in screen pixels: put the window exactly here instead of working it out
    [string]$TcNudge = '',        # 'dx,dy,dw,dh' added to the worked-out rectangle
    [int]$AuditSeconds = 4,
    [string]$AuditDir = 'C:\Games\RaptorMod\cache\audit',
    # Do not hand the viewport back for a few engine-drawn frames after each teleport (diagnostic;
    # without it floors stop holding in rooms entered while the host is drawing).
    [switch]$NoLoadPulse,
    [switch]$NoMoveGate,
    [switch]$MoveGate,
    # MEASURE THE ENGINE'S LIGHTING INSTEAD OF GUESSING IT. Every $CaptureRefSeconds, if the
    # camera is standing still: keep the host's own unlit frame and its depth buffer, hand the
    # viewport back for a moment, copy the picture the ENGINE draws from the same spot straight
    # out of its viewport surface, and save all three. Pixel for pixel that gives "what colour
    # the engine made this texel at this distance", which is the lighting and the draw
    # distance as data. The picture flicks to the engine's for about half a second each time.
    [switch]$CaptureRef,
    [int]$CaptureRefSeconds = 8,
    [string]$CaptureRefDir = 'C:\Games\RaptorMod\cache\ref2',
    # THE FLOATING-RAPTOR EXPERIMENT. Every $CharProbeSeconds while a character is in the
    # room: record every frame's matrices, hand the viewport back so the ENGINE draws for a
    # moment, record them again, take the viewport back, and log what moved. A dead Raptor
    # floated under the host renderer and dropped to the ground the instant the watcher was
    # stopped -- so something the engine's own drawing does also places characters, and this
    # shows which frames and which matrix. The picture flicks to the engine's for ~1.5 s.
    [switch]$CharProbe,
    [int]$CharProbeSeconds = 12,
    # The crash-hunt instrumentation: a stack image every 40 ms, heap reports, a stall dump.
    # Off by default now the host-render crash is fixed -- it was all on the frame path.
    # The Reality Lab trap readout is NOT part of this and always runs.
    [switch]$Diag,
    # SUPPRESSION IS NOW OPT-IN, because it crashes the game.
    #
    # aztSceneParts = 4 skips 0x5B820 and forces its caller's `test al,al` down the zero path
    # every frame, so 0x32E60 never runs. With it on, the game died with
    # "RAPTOR ERROR in Rendermorphics / object expected in argument" after 4, 8, 9 and 19
    # seconds of host rendering across four sessions. With it off -- one guest write different,
    # everything else identical -- the same play session was stable.
    #
    # It also buys nothing right now: the host renders in 5-10 ms while the frame limiter pins
    # the whole loop to 22.2 fps, so the engine's 3D work happens inside time we already spend
    # waiting. The saving only becomes real once the cap comes off, which needs the frame-tied
    # movement work. Revisit then, narrowing to parts 1 or 2 and measuring each.
    [switch]$Suppress,
    # Draw the .XAF rest pose instead of re-posing from the live graph (diagnostic).
    # How often to re-read the live scene graph, in Hz. Doors and creatures do not need a
    # 22 Hz sample to look right, and the walk is host CPU -- which this game is unusually
    # sensitive to, because DOSBox emulates on ONE thread and the game's animation is
    # clock-gated off the BIOS tick, so host load turns into bigger animation steps inside
    # the guest. 10 Hz is visually indistinguishable and costs less than half as much.
    # Every frame, in effect. It was 10 when a walk cost 2.8 ms; it is now cheap enough that
    # doors and characters should move as often as the camera does.
    [double]$PoseHz = 240,
    # Do EVERYTHING except hand frames to the game: attach, read the camera, walk the scene,
    # rasterise -- then throw the frame away. The engine draws itself and the player sees the
    # normal game.
    #
    # This is the bisect every previous run failed to make. Each experiment so far changed
    # both the host's CPU load AND whether we were injecting, so "no watcher = stable" could
    # not distinguish the two. With this, the load is identical to a real run and the only
    # thing missing is the injection:
    #   stable  -> the injection path is at fault, not load
    #   crashes -> our CPU load (or our reads) destabilise the guest, and injection is innocent
    # Arm injection and push frames as normal, but NEVER set aztInjReady -- so with the sync
    # handshake on, AztInjBody starves every frame and the 1.48 MB copy never executes.
    #
    # This splits "injection" in two, which no previous test has done. Everything else is
    # identical to a real run: the hook fires, the probe wrapper runs, AztBootCalib runs, we
    # write the staging buffer every frame. The ONLY thing missing is the guest-side copy.
    #   stable  -> the copy is what kills it, despite being exactly sized to its destination
    #   crashes -> the copy is innocent and the fault is in the hook path or our buffer writes
    #
    # The viewport will hold the last boot frame and never update. That is expected: this
    # measures where the crash comes from, not what it looks like.
    # Set the injection flags exactly as a real run does, but never write the staging buffer.
    # With -NoReady the guest-side copy already never runs, so this leaves ONLY the flags --
    # and splits the last two suspects apart:
    #   stable  -> our 1.48 MB host write into the guest is what corrupts it
    #   crashes -> merely setting aztInjEnable/aztInjSync does, which would mean the fault is
    #              in the hook path the flags unlock, not in any data we move
    # Hand the guest a frame only every Nth time round the loop. 1 = every frame (normal).
    #
    # The bisect says the guest-side COPY is the cause, and both buffers measure correctly
    # sized (1,484,805 bytes each, for a 1,484,800-byte copy). So the next question is whether
    # the damage accumulates per copy or simply happens after so many seconds:
    #   crashes after the same NUMBER OF COPIES  -> cumulative, something the copy does each time
    #   crashes after the same WALL TIME         -> not the copies themselves; they only have to
    #                                               be happening for some other process to bite
    # At -PushEvery 4 a crash at ~8 s means time; a crash at ~32 s means copies.
    [int]$PushEvery = 1,
    [switch]$NoPush,
    [switch]$NoReady,
    [switch]$NoInject,
    [switch]$NoPose,
    [switch]$NoFlipV,
    [switch]$NoCull,
    [switch]$Once,                # exit after one game session instead of waiting again
    # How long to wait for the guest to release the staging buffer before dropping the
    # frame. 120 ms is five guest frames at the capped 45 ms, so it should never fire in
    # normal operation -- when it fires a lot, the guest is the bottleneck, not the host.
    [int]$SyncTimeoutMs = 120,
    # A frame with nothing to draw (camera record caught mid-update, room detection blinking)
    # keeps the last picture up; the viewport is handed back to the engine only once there has
    # been nothing to draw for this long (a load, a movie). Each hand-back flashed the engine's
    # own picture (Josh, 2026-10-06: flicker).
    [int]$HandBackAfterMs = 250,
    # How long aztBootState may sit at 0 before we conclude this build has no boot sequence
    # and stop waiting for one. Generous: the boot only starts once the room is up.
    [int]$BootWaitSeconds = 30,
    [int]$JumpUnits = 400,        # camera movement in one frame that means "new room"
    [double]$CheckSeconds = 0.5,  # how often the cheap fingerprint runs
    # Save the host's OWN output as a PNG every N seconds (0 = off).
    #
    # Added because three rounds of diagnosing "bright dots that shouldn't be there" from a
    # description got nowhere: offline renders of the same room, lit and unlit, measured
    # FEWER bright pixels than the engine's own frame and essentially no isolated dots. The
    # live frame is the only thing that settles it, so write it down rather than infer it.
    [int]$SaveFrames = 0,
    [string]$SaveDir = 'C:\Games\RaptorMod\cache\frames',
    [int]$CacheRooms = 8,         # loaded rooms kept in memory for instant re-entry
    [int]$Threads = 0,
    [string]$TexDir  = 'C:\Games\RaptorMod\game\GAME\AZTEX',
    [string]$CacheDir = 'C:\Games\RaptorMod\cache',
    [string]$Palette = 'C:\Games\RaptorMod\cache\azrael-palette.pal',
    # RESOLVED IN THE BODY, not here. $PSScriptRoot is empty while parameter defaults are
    # bound under `powershell -File`, so "$PSScriptRoot\..\x" became "C:\x" and the script
    # died on startup -- and -File is exactly how a double-clicked launcher runs it.
    [string]$Sym      = '',
    [string]$Manifest = '',
    [string]$LogFile  = 'C:\Games\RaptorMod\cache\watch.log'
)
if (-not $Retro) { $TrueColour = [switch]$true }      # (see -Retro)
$ErrorActionPreference = 'Stop'
$NoAA = -not $AA                 # edge smoothing is opt-in; everything below still reads $NoAA
$toolDir = Split-Path -Parent $PSCommandPath
if (-not $Sym)     { $Sym      = Join-Path $toolDir '..\AztMod.overlay.sym' }
if (-not $Manifest) { $Manifest = Join-Path $toolDir '..\AztMod.manifest.json' }
New-Item -ItemType Directory -Force (Split-Path $LogFile -Parent) | Out-Null
# A START-UP ERROR IS SEEN (2026-10-15): before the session's own log writer is up (Say), an error that stopped this script showed
# only in the launcher's minimised window -- and with -Launch the game was already running, so the player saw the plain game and
# no reason. Now it goes into watch.log, and (a game launched from here) into a message box; later failures are logged too.
$script:startupDone = $false
trap {
    $msg = $_.Exception.Message + ' (' + ($_.InvocationInfo.PositionMessage -replace '\s+', ' ').Trim() + ')'
    try { [IO.File]::AppendAllText($LogFile, ("[{0}] {1}: {2}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $(if ($script:startupDone) { 'STOPPED' } else { 'STARTUP FAILED' }), $msg)) } catch { }
    if (-not $script:startupDone -and $Launch) {
        try { [void](New-Object -ComObject WScript.Shell).Popup("RaptorMod's renderer could not start:`r`n`r`n$msg`r`n`r`nThe game runs on without it. Details: $LogFile", 0, 'RaptorMod', 16) } catch { }
    }
    break
}
# TEXTURE QUALITY (see -TextureQuality): the switch, else the player's settings file, else Ultra; Normal caps replacement
# textures at 2048 ($script:texMax, read by Get-Room's Add-AztRgb)
$script:texQuality = [string]$TextureQuality
if (-not $script:texQuality) { try { $sp = Join-Path $GameDir 'raptormod-settings.json'; if (Test-Path $sp) { $script:texQuality = [string](Get-Content $sp -Raw | ConvertFrom-Json).textureQuality } } catch { } }
$script:texQuality = $(if ($script:texQuality -match '^\s*normal\s*$') { 'Normal' } else { 'Ultra' })
$script:texMax = $(if ($script:texQuality -eq 'Normal') { 2048 } else { 0 })
# the session's texture cache (see -TextureCacheGB; Limit-AztRgbCache in LoadRoom.ps1)
$script:texCacheBytes = [long]$(if ($TextureCacheGB -gt 0) { $TextureCacheGB * 1GB } else {
    $ram = 16GB; try { $ram = [long](Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory } catch { }
    [Math]::Max(2GB, [Math]::Min(16GB, $ram / 4)) })
$script:rgbProgress = $null; $script:roomCover = $null; $script:roomCoverPainter = $null

# ONE WATCHER AT A TIME, ENFORCED.
#
# Two instances attach to the same game, write the same 1.48 MB staging buffer, and both set
# aztInjReady -- which defeats the very handshake that stops a frame being written while the
# guest is reading it. It is not subtle once you know to look (every log line doubled, host
# fps halved while the guest's displayed count stayed the same, and room loads failing with
# "A generic error occurred in GDI+" as both processes opened the same PNGs), but it looks
# exactly like a renderer bug from the outside, and it silently invalidates any run it
# happens during.
$script:AztMutex = New-Object System.Threading.Mutex($false, 'Global\AztModWatchHostRender')
# A watcher that was force-killed leaves the mutex ABANDONED. WaitOne then throws, but it has
# still acquired it -- so that case must be caught and treated as success, or every stop by
# Ctrl-C or Stop-Process would lock the tool out for good.
$script:AztHeld = $false
try { $script:AztHeld = $script:AztMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $script:AztHeld = $true }
if (-not $script:AztHeld) {
    Write-Host 'ANOTHER WATCHER IS ALREADY RUNNING.' -ForegroundColor Red
    Write-Host 'Close it (Ctrl-C in its window) before starting another, or the two will fight' -ForegroundColor Red
    Write-Host 'over the same staging buffer and whatever you observe will be meaningless.' -ForegroundColor Red
    exit 1
}
# ---- -Launch: THE GAME FIRST, the renderer loads behind it (Josh, 2026-10-07) ---------------------
# The intro movies must play, so the game starts before anything slow happens here. A small gate
# (tools\LoadingScreen.cs, compiled on its own in about a second) finds the game at once and watches
# for the first gameplay frame. If the renderer is ready by then -- the usual case, the intro takes
# a while -- nothing is seen. If the player skipped the movies and got there first, the game is
# held (parked in its own frame limiter -- NOT suspended: that killed the Sound Blaster) right at the start of play behind "Loading RaptorMod..." until the renderer has
# hold of it, so the GPU boot is never beaten to the screen.
$script:gate = $null
if ($Launch) {
    $running = @(Get-Process -Name 'dosbox*' -ErrorAction SilentlyContinue)
    if ($running.Count) { Write-Host 'a DOSBox is already running -- attaching to it instead of starting another' -ForegroundColor Yellow; $gamePid0 = $running[0].Id }
    else {
        $exe = Join-Path $GameDir 'DOSBOX-STAGING\dosbox.exe'
        if (-not (Test-Path $exe)) { Write-Host ("the modded game was not found at {0} -- run Apply-AztMod.ps1 first" -f $GameDir) -ForegroundColor Red; exit 1 }
        $gamePid0 = (Start-Process -FilePath $exe -WorkingDirectory $GameDir -ArgumentList '--noprimaryconf', '--nolocalconf', '--conf', 'azrael-staging.conf', '--conf', 'azrael-game.conf' -PassThru).Id
    }
    if (-not $NoLoadingScreen) {
        try {
            # (with the title's RAPTOR DOCS and its own copy of the cursor icons: TITLE_GATE names that copy TitleShapes, so the
            # renderer's CursorShapes, compiled below, is not refused as a type "that already exists")
            $gateCp = New-Object System.CodeDom.Compiler.CompilerParameters
            [void]$gateCp.ReferencedAssemblies.Add('System.dll'); [void]$gateCp.ReferencedAssemblies.Add('System.Drawing.dll')
            $gateCp.CompilerOptions = '/define:TITLE_GATE'; $gateCp.GenerateInMemory = $true
            Add-Type -Path @((Join-Path $toolDir 'LoadingScreen.cs'), (Join-Path $toolDir 'RaptorDocs.cs'), (Join-Path $toolDir 'CursorShapes.cs')) -CompilerParameters $gateCp -ErrorAction Stop
            $symText = [IO.File]::ReadAllText((Resolve-Path $Sym).Path)
            $sb = [regex]::Match($symText, '(?m)^0x([0-9A-Fa-f]+)\s+aztInjBufPtr\s*$'); $ss = [regex]::Match($symText, '(?m)^0x([0-9A-Fa-f]+)\s+aztBootState\s*$')
            if (-not $sb.Success -or -not $ss.Success) { throw 'aztInjBufPtr / aztBootState are not in the overlay symbol map' }
            $gt = New-Object AztTool.GameGate
            # the hold is the game's own frame limiter (aztFramePeriod, from the manifest's settings): never a frozen DOSBox
            try { foreach ($st in (Get-Content (Resolve-Path $Manifest).Path -Raw | ConvertFrom-Json).settings) { if ($st.name -eq 'aztFramePeriod') { $gt.FramePeriodLin = [Convert]::ToInt32((([string]$st.linear) -replace '^0x', ''), 16) } } } catch { }
            if (-not $gt.FramePeriodLin) { Write-Host 'loading gate: aztFramePeriod is not in the manifest -- the game will not be held' -ForegroundColor Yellow }
            $ld = Join-Path $toolDir '..\art\loading'
            $gt.VoicePath = Join-Path $ld 'loading-voice.wav'; $gt.TrackPath = Join-Path $ld 'loading-track.wav'; $gt.TrackGain = $LoadingTrackGain; $gt.VoiceGain = $LoadingVoiceGain
            $gt.Sound = -not ($NoBootSound -or $NoLoadingSound)
            # the title menu (LoadingScreen.cs TitleScreen): the art, and where the saves are for Continue / Load
            $gt.TitleOn = -not ($NoTitleMenu -or $Retro); $gt.TitleImage = (Join-Path $toolDir '..\art\title\title_4k.png'); $gt.SaveDir = (Join-Path $GameDir 'GAME\AZRAEL'); $gt.TitleTextureQuality = $script:texQuality.ToUpperInvariant()
            $gt.TitleGrailFx = -not $NoGrailDust                                    # (the grail's gold flakes on the title)
            $gt.TitleGrailGlow = -not $NoGrailGlow                                  # (and its light on his face)
            $gt.MuteGameOnLoad = (-not $NoLoadGameMute)      # (the game's own menu sound plays as it loads the save: muted at the pick)      # (the game's own HUD sound, hud3.wav, plays 0.1 s after a LOAD is picked: muted at the pick)
            $gt.TitleMusic = (Join-Path $toolDir '..\art\title\title-music.wav')      # (KREEPY3, Josh's soundtrack, looped under the menu)
            $gt.TitleDocs = (Join-Path $GameDir 'raptordocs')                         # (RAPTOR DOCS: the manual and the print-outs -- tools\Build-RaptorDocs.ps1)
            $gt.TitleRoomLoad = [bool]($TrueColour -and -not $NoRgb)                  # (a title load's bar carries the room's textures: Set-LoadProgress)
            try { $gt.Screen.ShotPath = (Join-Path $CacheDir 'loading-screen.png') } catch { }      # (the launch screen as it really looked, 1.5 s in -- Josh, 2026-10-14: 'sometimes not full screen')
            $gt.Stage(0.6, 6)
            $gt.Start($gamePid0, (Join-Path $GameDir 'GAME\AZRAEL\R.EXE'), [Convert]::ToInt32($sb.Groups[1].Value, 16), [Convert]::ToInt32($ss.Groups[1].Value, 16))
            $script:gate = $gt
        } catch { Write-Host ("loading gate: {0} -- the game is not held" -f $_.Exception.Message) -ForegroundColor Yellow; $script:gate = $null }
    }
}
. (Join-Path $toolDir 'GuestBase.ps1')
. (Join-Path $toolDir 'LoadRoom.ps1')
Add-Type -Path @((Join-Path $toolDir 'Raster.cs'), (Join-Path $toolDir 'Quantize.cs'), (Join-Path $toolDir 'HostView.cs'),
                 (Join-Path $toolDir 'SceneGraph.cs'), (Join-Path $toolDir 'Keys.cs'), (Join-Path $toolDir 'Overlay.cs'), (Join-Path $toolDir 'Motes.cs'),
                 (Join-Path $toolDir 'GpuRaster.cs'), (Join-Path $toolDir 'GiBake.cs'), (Join-Path $toolDir 'Particles.cs'), (Join-Path $toolDir 'Panel.cs'), (Join-Path $toolDir 'Pointer.cs'), (Join-Path $toolDir 'CursorShapes.cs'), (Join-Path $toolDir 'CursorIcons.cs'),
                 (Join-Path $toolDir 'BootHd.cs'), (Join-Path $toolDir 'ScanWire.cs'), (Join-Path $toolDir 'RoomCover.cs'), (Join-Path $toolDir 'TexTwins.cs'), (Join-Path $toolDir 'FrameStep.cs')) `
         -ReferencedAssemblies 'System.Drawing', 'System.Web.Extensions' -ErrorAction Stop
# ProcMem (RdU32 and every other guest read here) was only compiled inside Get-AztGuestBase, so when the loading
# gate had already found the game -- and that search was skipped -- the first read threw and ended the watcher
# (2026-10-07 16:32). Compiled up front now, whichever way the game is found.
if (-not ('AztTool.ProcMem' -as [type])) { Add-Type -Path (Join-Path $toolDir 'ProcMem.cs') -ErrorAction Stop }
if ($AudioMeter) { try { [AztTool.AudioMeter]::Start(300, 'from the renderer''s start: the title, the click, the load'); $script:meterStarted = $true } catch { } }      # (the ratchet hunt: every program's sound from launch)
Add-Type -AssemblyName System.Drawing
if ($script:gate) { $script:gate.Stage(0.8, 2) }

# ---- 1 ms SLEEPS, BECAUSE THE DEFAULT IS 15.6 ------------------------------------------
# The sync wait polls aztInjReady with `Start-Sleep -Milliseconds 2`, and on Windows' default
# timer that sleeps until the next 15.6 ms tick. Once per frame, that alone caps the host
# near 1000 / (render + 15.6): the 17:14 run MEASURED it -- the guest loop ran at 50 fps and
# starved 50-80 times every 4 s while the host delivered 31-36 with a 7-12 ms render. The
# guest was waiting on us, and we were asleep. timeBeginPeriod(1) makes the same sleep take
# about 2 ms. Still a sleep, not a spin: DOSBox emulates on one thread and must not be
# starved (see the note at the wait itself).
if (-not ('AztTool.WinTimer' -as [type])) {
    Add-Type -Namespace AztTool -Name WinTimer -MemberDefinition @'
[DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint ms);
[DllImport("winmm.dll")] public static extern uint timeEndPeriod(uint ms);
'@
}
[void][AztTool.WinTimer]::timeBeginPeriod(1)

$symMap = @{}
foreach ($l in [IO.File]::ReadAllLines((Resolve-Path $Sym).Path)) {
    if ($l -match '^0x([0-9A-Fa-f]+)\s+(\S+)$') { $symMap[$Matches[2]] = [uint32]('0x' + $Matches[1]) }
}
function Sym([string]$n) {
    if (-not $symMap.ContainsKey($n)) { throw "$n is not in the overlay symbol map -- rebuild with the right flags on" }
    return [uint32]$symMap[$n]
}
# $S_enable is the HOST's own flag. NOT aztInjEnable -- that one is the visor boot's, and
# AztRoomTick reads it as `the boot is painting` and skips the texture defrag while it is set.
$S_sup3D = Sym 'aztSup3D'; $S_enable = Sym 'aztHostInject'; $S_bufPtr = Sym 'aztInjBufPtr'
$S_parts = Sym 'aztSceneParts'; $S_sync = Sym 'aztInjSync'; $S_ready = Sym 'aztInjReady'
$S_camRec = Sym 'aztCamRec'
# The GUEST's own counters: how many injected frames it displayed, and how many times it
# reached the injection point with nothing ready. Without these, "9.2 fps with 50 sync
# timeouts" cannot distinguish a host that is too slow from a guest that has stopped
# running its per-frame path -- and those need opposite fixes.
$S_shown  = Sym 'aztInjShown'; $S_starve = Sym 'aztInjStarve'
# THE VISOR BOOT OWNS THE SAME STAGING BUFFER. The build is explicit about it -- "the visor
# boot fills this same buffer from guest" -- so taking the viewport while the boot animation
# is still playing means two writers on one 1.48 MB buffer. That corrupted the end of the
# boot animation, put lines on screen at what would be the normal start of play, and showed
# up in the numbers as the guest displaying MORE frames than the host pushed (222 vs 201):
# the extra ones were the boot's.
#
# 0 = not started, 1 = running, 2 = finished for good ("aztBootState reaches 2 only when the
# sequence ends"). Soft lookup: a build without the boot sequence has no such symbol.
$S_split = Sym 'aztInjSplit'; $S_roll = Sym 'aztInjRoll'
$S_topDw = Sym 'aztInjTopDw'; $S_botOff = Sym 'aztInjBotOff'
$S_bootState = $(if ($symMap.ContainsKey('aztBootState')) { [uint32]$symMap['aztBootState'] } else { [uint32]0 })
# ---- the Reality Lab error trap ---------------------------------------------
# AztRaptorTrap replaces RL's registered error callback at 0x10204, sifts the stack for
# anything that could be a return address, and holds the game for up to 5 s so this can
# read it before the process dies. Soft lookup: an older overlay has no such symbols.
$S_rapHit  = $(if ($symMap.ContainsKey('aztRaptorHit'))   { [uint32]$symMap['aztRaptorHit'] }   else { [uint32]0 })
$S_rapSeen = $(if ($symMap.ContainsKey('aztRaptorSeen'))  { [uint32]$symMap['aztRaptorSeen'] }  else { [uint32]0 })
$S_rapCode = $(if ($symMap.ContainsKey('aztRaptorCode'))  { [uint32]$symMap['aztRaptorCode'] }  else { [uint32]0 })
$S_rapStk  = $(if ($symMap.ContainsKey('aztRaptorStack')) { [uint32]$symMap['aztRaptorStack'] } else { [uint32]0 })
# The obj1 load delta, as the guest itself recorded it. Reported with every capture because
# the first version of the trap filtered RUNTIME stack values against BUILT addresses and so
# found nothing on a crash it had correctly caught -- the delta is the number that decides
# whether a capture can work at all, and it should never again be an assumption.
$S_delta1  = $(if ($symMap.ContainsKey('aztCamDelta1')) { [uint32]$symMap['aztCamDelta1'] } else { [uint32]0 })
$S_delta2  = $(if ($symMap.ContainsKey('aztCamDelta2')) { [uint32]$symMap['aztCamDelta2'] } else { [uint32]0 })
# THE FIELD OF VIEW (see -Fov): the angle, and whether the game is to follow the host (not in -Retro, not with an overlay
# that has no AztFovTick -- an older install keeps the game's own 50 and the host follows it).
$S_fovTan = $(if ($symMap.ContainsKey('aztFovTan')) { [uint32]$symMap['aztFovTan'] } else { [uint32]0 })
# (the game's own map: not drawn while the host draws its 3D map -- AztMapBlit, Josh 2026-10-14)
$S_oldMapOff = $(if ($symMap.ContainsKey('aztOldMapOff')) { [uint32]$symMap['aztOldMapOff'] } else { [uint32]0 })
# THE PICTURE'S PIXEL CAP (2026-10-15: was -TcMaxPixels 5500000 in Play-HostRender-TrueColour.cmd, Josh's 4K screen): the switch,
# else this PC's settings file ("tcMaxPixels" in raptormod-settings.json), else 5.5 M -- a smaller screen's view is under it anyway
if ($TcMaxPixels -le 0) { try { $sp = Join-Path $GameDir 'raptormod-settings.json'; if (Test-Path $sp) { $tp = (Get-Content $sp -Raw | ConvertFrom-Json).tcMaxPixels; if ($tp) { $TcMaxPixels = [int]$tp } } } catch { } }
if ($TcMaxPixels -le 0) { $TcMaxPixels = 5500000 }
$script:fovGame = -not $Retro
if ($script:fovGame -and $Fov -le 0) { try { $sp = Join-Path $GameDir 'raptormod-settings.json'; if (Test-Path $sp) { $fs = (Get-Content $sp -Raw | ConvertFrom-Json).fov; if ($fs) { $Fov = [double]$fs } } } catch { } }
if ($Retro -or $Fov -le 0) { $Fov = $(if ($Retro) { 50 } else { 60 }) }
$Fov = [Math]::Max(30.0, [Math]::Min(100.0, $Fov))
$script:fovNote = $null      # (said with the start line: Say is defined further down)
if ($script:fovGame -and -not $S_fovTan) { if ($Fov -ne 50) { $script:fovNote = "this install's overlay cannot set the game's field (no aztFovTan) -- the view stays at the game's 50; reinstall for $Fov" }; $Fov = 50; $script:fovGame = $false }
$S_frameNo = $(if ($symMap.ContainsKey('aztCamFrameNo')) { [uint32]$symMap['aztCamFrameNo'] } else { [uint32]0 })
$S_rapEsp  =$(if ($symMap.ContainsKey('aztRaptorEsp')) { [uint32]$symMap['aztRaptorEsp'] } else { [uint32]0 })

$man = Get-Content (Resolve-Path $Manifest).Path -Raw | ConvertFrom-Json
$W = [int]$man.view.injW; $H = [int]$man.view.injH
$capLin = 0
foreach ($s in $man.settings) { if ($s.name -eq 'aztFramePeriod') { $capLin = [Convert]::ToUInt32((([string]$s.linear) -replace '^0x',''), 16) } }
if ($Uncap -and -not $capLin) { throw 'aztFramePeriod is not in the manifest settings -- cannot lift the cap' }

$REC_MOVWORLD = 172
$pal = [IO.File]::ReadAllBytes((Resolve-Path $Palette).Path)

# IS THE PALETTE OLDER THAN THE BUILD IT HAS TO MATCH?
#
# Textures are quantised to palette INDICES once, at load; the game then displays those
# indices through its own live palette, which is merged at runtime from several PCX files.
# When the HUD art is rebuilt those entries move, and a stale capture silently paints the
# wrong colours -- not uniformly, only on the entries that moved, which reads as scattered
# wrong-coloured dots rather than as an obviously broken image.
#
# That is exactly what happened: a palette captured 2026-09-27 against a build whose index
# 33 was dark olive (73,73,49), used against a build where it is bright orange (243,166,12).
# 41 of the 53 HUD entries had moved, and 7.6-40.6% of every frame lands in that range.
# Re-capture with tools\Capture-Palette.ps1 (game running, watcher stopped).
# THE CHECK IS NOW BY CONTENT, AGAINST THE RUNNING GAME -- see Test-LivePalette. It used to
# compare this file's timestamp with the overlay's, and the overlay is rewritten by every
# install, so it cried wolf after each one while saying nothing about the colours.
function Test-LivePalette {
    # The game keeps its merged palette in its own memory: 0x28110 stores each entry as a
    # 3-byte master at obj2 0x163310 (what fades re-upload) and as a 4-byte table at
    # 0x163610 (the rasteriser's lookup). Which of 6-bit / 8-bit and which byte order they
    # use has not been pinned down, so every reading is tried and the best is reported --
    # an exact match under ANY of them means the capture is the palette the game is using.
    try {
        $m3 = [byte[]](Read-AztGuest $g 0x163310 768 -Obj2); $m4 = [byte[]](Read-AztGuest $g 0x163610 1024 -Obj2)
        if (-not $m3 -or -not $m4 -or $m3.Length -lt 768 -or $m4.Length -lt 1024) { Say 'palette check: could not read the game''s palette' Yellow; return }
        $best = $null
        $forms = [ordered]@{
            'master, 8-bit'          = { param($i, $c) [int]$m3[$i*3 + $c] }
            'master, 6-bit x4'       = { param($i, $c) [int]$m3[$i*3 + $c] * 4 }
            'master, 6-bit expanded' = { param($i, $c) (([int]$m3[$i*3 + $c] -shl 2) -bor ([int]$m3[$i*3 + $c] -shr 4)) }
            'table, r g b'           = { param($i, $c) [int]$m4[$i*4 + $c] }
            'table, b g r'           = { param($i, $c) [int]$m4[$i*4 + 2 - $c] }
            'table, 6-bit x4'        = { param($i, $c) [int]$m4[$i*4 + $c] * 4 }
        }
        foreach ($name in $forms.Keys) {
            $exact = 0; $near = 0; $worst = 0
            for ($i = 1; $i -lt 256; $i++) {
                $d = 0; for ($c = 0; $c -lt 3; $c++) { $d = [Math]::Max($d, [Math]::Abs((& $forms[$name] $i $c) - [int]$pal[$i*3 + $c])) }
                if ($d -eq 0) { $exact++ }; if ($d -le 4) { $near++ }; if ($d -gt $worst) { $worst = $d }
            }
            if (-not $best -or $near -gt $best.Near) { $best = @{ Name = $name; Exact = $exact; Near = $near; Worst = $worst } }
        }
        if ($best.Near -ge 250) {
            Say ("palette check: the capture matches the running game ({0}: {1} of 255 entries exact, {2} within rounding)" -f $best.Name, $best.Exact, $best.Near) Green
        } else {
            Say ("palette check: the capture does NOT match the running game -- best reading '{0}' agrees on only {1} of 255 entries (worst channel off by {2})." -f $best.Name, $best.Near, $best.Worst) Red
            Say '               Colours will be wrong where they differ. Re-run tools\Capture-Palette.ps1 with the watcher stopped.' Red
        }
    } catch { Say ("palette check failed: {0}" -f $_.Exception.Message) Yellow }
}

# ---- shared state across sessions -------------------------------------------
# Rooms stay loaded between visits AND between game sessions: re-entering a room already
# seen costs nothing, which is what makes following the player through doors viable.
$roomCache = New-Object System.Collections.Specialized.OrderedDictionary
$g = $null; $hv = $null
# The pid of the session that just ended, so the next attach cannot land on its corpse.
$lastGamePid = 0
$script:rapRoom = '(none)'

function Say([string]$m, [string]$c = 'Gray') {
    $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $m
    Write-Host $line -ForegroundColor $c
    # ALSO TO A FILE. This runs unattended behind a full-screen game, so whatever it printed
    # is gone by the time anything is worth asking about -- the first live run came back as
    # "everything was black" with no way to tell a failed attach from a failed detect from a
    # failed push.
    try { [IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine) } catch { }
}

function Get-GamePid {
    $p = Get-Process -Name 'dosbox*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { return $p.Id } else { return 0 }
}
function HostLin([uint32]$l) { [long]($g.MemBase + $l + 0x1F0000) }
# OBJ2'S RUNTIME DELTA -- it is NOT fixed: obj2 runs one page past obj1's end, and obj1 grew for a 256 KB overlay window
# (2026-10-11: 0x1F1000 became 0x224000). The guest's own value (aztCamDelta2, once the overlay has written it), else what
# the attach found from the needles ($g.Delta2: GuestBase.ps1 / the gate's D2), else the old layout's.
function Get-GuestD2 {
    $d = [uint32]0
    if ($S_delta2 -and $g) { try { $d = RdU32 (HostLin $S_delta2) } catch { $d = [uint32]0 } }
    if (-not $d -and $g -and $g.PSObject.Properties['Delta2'] -and $g.Delta2) { $d = [uint32]$g.Delta2 }
    if (-not $d) { $d = [uint32]0x1F1000 }
    return $d
}
# The game's STACK lives in obj2 (ESP 0x386340 in the 2026-10-04 crashes, delta 0x1F1000): it moves with obj2's delta.
function Get-StackLo { [uint32](0x37E000 + ([long](Get-GuestD2) - 0x1F1000)) }
function RdU32([long]$h) {
    # the session's own open handle when there is one: ProcMem.Read opens and closes the
    # process for every call, and this runs several times a frame
    if ($hv) { return $hv.ReadU32($h) }
    $b = [AztTool.ProcMem]::Read($g.ProcessId, $h, 4)
    if (-not $b) { return [uint32]0 }
    return [BitConverter]::ToUInt32($b, 0)
}

# ---- the Reality Lab error trap's readout -----------------------------------
# The crash reports "object expected in argument" -- RL error code 1 -- and nine passes of
# static analysis could not name the caller, because 0x10204 is a callback the game
# REGISTERS with RL (`mov eax, 0x10204` at 0x10E92) and the call therefore comes from
# inside RL through a pointer. There is no static caller to find.
#
# So the guest captures the stack instead. Clearing the flag also releases the game from
# the bounded wait the trap is sitting in, so this must run promptly -- it is polled on the
# push path rather than on the 2 Hz room-detect tick.
$RL_ERRORS = @('no error', 'object expected in argument', 'bad argument type passed', 'out of memory')

# ---- the handle table, read from outside ------------------------------------
# Both trapped crashes (the cursor pick, then the scene pass at 0x3F1EA) are the same event
# seen from two callers: a handle taken from a live list fails the lookup at 0x39E50. That
# lookup is a 0x3FD-bucket hash at 0x1831CC, chained through [rec+0], keyed on [rec+0x14].
# So the question a caller chain cannot answer -- WHICH object, and is it still linked into
# the scene -- can be answered here, while the trap holds the game still.
#
# These are obj2 addresses, so they take the obj2 delta, which differs from obj1's by a page.
$script:rapNames = @{}                       # handle -> frame name, from the last healthy walk
# Initialised HERE. Left unset, the first read of $script:rapWalkNoted threw under strict
# mode inside a bare catch, so the 16:02 run printed no handle-table check and said nothing.
$script:rapWalkNoted = $false; $script:rapD2 = [uint32]0; $script:rapWalkErr = ''

# ---- a crash that is NOT a Reality Lab error --------------------------------
# The 16:05 run died on a DOS/4GW exception 06h (invalid opcode) at 0x111008 -- a jump into
# data -- so RL never reported anything and the trap never ran. DOS/4GW prints registers but
# no stack, and the stack is the only thing that says who made the jump.
#
# The guest's RAM outlives the game for as long as DOSBox stays open (AZRAEL.BAT now ends in
# a PAUSE for exactly this), and the stack sits where it always does: the crash had
# ESP = 0x386340. So when the guest stops taking frames for 3 s, sift that region for
# anything that is a runtime obj1 address and keep it with its stack address. Entries ABOVE
# the ESP that AZERR.TXT reports are the live chain; below it is stale. A room load can stall
# this long too, which is harmless: the file is overwritten and the last one wins.
function Write-StallStack {
    try {
        $d1 = $(if ($S_delta1) { RdU32 (HostLin $S_delta1) } else { [uint32]0x1F0000 })
        $lo = Get-StackLo; $len = 0xC000
        $sb = [AztTool.ProcMem]::Read($g.ProcessId, (GuestPtr $lo), $len)
        if (-not $sb) { Say 'stall: the stack region was not readable' Yellow; return }
        $dir = Split-Path $LogFile -Parent
        [IO.File]::WriteAllBytes((Join-Path $dir 'stallstack.bin'), $sb)
        $out = New-Object System.Collections.Generic.List[string]
        $out.Add(("# guest stalled {0:yyyy-MM-dd HH:mm:ss}, room {1}, obj1 delta 0x{2:X}" -f (Get-Date), $script:rapRoom, $d1))
        $out.Add(('# stackaddr  built-linear   (raw region 0x{0:X}..0x{1:X} saved as stallstack.bin)' -f $lo, ($lo + $len)))
        for ($i = 0; $i -lt $len; $i += 4) {
            $v = [BitConverter]::ToUInt32($sb, $i)
            if ($v -lt $d1) { continue }
            $b = [uint32]($v - $d1)
            if ($b -ge 0x10000 -and $b -lt 0x173000) { $out.Add(('0x{0:X8}  0x{1:X8}' -f ($lo + $i), $b)) }     # (obj1 runs to 0x173000 with the 256 KB overlay window)
        }
        [IO.File]::WriteAllLines((Join-Path $dir 'stallstack.txt'), $out)
        Say ("guest has taken no frame for 3 s -- {0} stack candidates written to stallstack.txt" -f ($out.Count - 2)) Yellow
    } catch { Say ("stall dump failed: {0}" -f $_.Exception.Message) Yellow }
}
function GuestObj2([uint32]$built) { [long]($g.MemBase + $built + $script:rapD2) }
function GuestPtr([uint32]$ptr)   { [long]($g.MemBase + $ptr) }
function Resolve-RlHandle([uint32]$h) {
    $rec = RdU32 (GuestObj2 ([uint32](0x1831CC + 4 * ($h % 0x3FD))))
    for ($i = 0; $i -lt 4096 -and $rec -ge 0x1000; $i++) {
        if ((RdU32 (GuestPtr ($rec + 0x14))) -eq $h) { return $rec }
        $rec = RdU32 (GuestPtr $rec)
    }
    return [uint32]0
}
function Get-RlName([uint32]$frame) {
    $np = RdU32 (GuestPtr ($frame + 0x24))
    if ($np -lt 0x1000) { return '' }
    $b = [AztTool.ProcMem]::Read($g.ProcessId, (GuestPtr $np), 48)
    if (-not $b) { return '' }
    $z = [Array]::IndexOf($b, [byte]0); if ($z -le 0) { return '' }
    for ($i = 0; $i -lt $z; $i++) { if ($b[$i] -lt 0x20 -or $b[$i] -gt 0x7E) { return '' } }
    return [Text.Encoding]::ASCII.GetString($b, 0, $z)
}
# The root's children exactly as 0x45270 snapshots them: [root+0x3C], then [child+0x34].
function Get-RlRootChildren {
    $res = @()
    if (-not $S_delta2) { return $res }
    $script:rapD2 = RdU32 (HostLin $S_delta2)
    $root = RdU32 (GuestObj2 0x147ED8)
    if ($root -lt 0x1000) { return $res }
    $c = RdU32 (GuestPtr ($root + 0x3C))
    for ($i = 0; $i -lt 600 -and $c -ge 0x1000; $i++) {
        $res += [pscustomobject]@{ Ptr = $c; Handle = (RdU32 (GuestPtr ($c + 0x14))); Name = (Get-RlName $c) }
        $c = RdU32 (GuestPtr ($c + 0x34))
    }
    return $res
}
# ---- the C heap, read from outside -------------------------------------------
# The ORRERY crash is a face array at 0x6400000 in a 32 MB guest. The mesh header proves
# RL was GIVEN that address by malloc (0x39B10 -> 0x32C40 -> 0x401A7 -> 0x50A3E), so the
# Watcom heap itself is handing out memory that does not exist. Unmapped guest memory reads
# as FFFFFFFF, which the allocator takes for an enormous free block: every request then
# "succeeds" and the rover just walks further out. So the fault is wherever a heap's free
# list first left real RAM, which is before the crash, not at it.
#
# The heap list head is [0x1476EC]; each mini-heap links through [+8] and keeps its rover
# at [+0xC] and largest-free at [+0x14] (all read straight off 0x401A7 / 0x50A3E).
$GUEST_RAM_TOP = [uint32]0x2000000          # memsize = 32 in azrael-staging.conf
function Get-HeapReport {
    $out = @()
    if (-not $S_delta2) { return $out }
    $script:rapD2 = RdU32 (HostLin $S_delta2)
    $h = RdU32 (GuestObj2 0x1476EC)
    for ($i = 0; $i -lt 64 -and $h -ge 0x1000 -and $h -lt $GUEST_RAM_TOP; $i++) {
        $b = [AztTool.ProcMem]::Read($g.ProcessId, (GuestPtr $h), 0x30)
        if (-not $b) { break }
        $w = @(0..11 | ForEach-Object { [BitConverter]::ToUInt32($b, $_ * 4) })
        $flag = $(if ($w[3] -ge $GUEST_RAM_TOP -or $w[10] -ge $GUEST_RAM_TOP -or $w[8] -ge $GUEST_RAM_TOP) { '  <-- POINTS PAST THE END OF RAM' } else { '' })
        $out += ("heap 0x{0:X}: len 0x{1:X} rover 0x{2:X} b4rover 0x{3:X} largest 0x{4:X} allocs {5} frees {6} list 0x{7:X}/0x{8:X}{9}" -f `
            $h, $w[0], $w[3], $w[4], $w[5], $w[6], $w[7], $w[8], $w[10], $flag)
        $h = $w[2]
    }
    return $out
}

function Update-RlNames {
    try {
        $kids = @(Get-RlRootChildren)
        foreach ($k in $kids) { $script:rapNames[[uint32]$k.Handle] = ("{0} @0x{1:X}" -f $k.Name, $k.Ptr) }
        # Said once: proof the obj2 delta and the list layout are right BEFORE a crash
        # depends on them. Zero children here means the forensics will be empty too.
        if (-not $script:rapWalkNoted) {
            $script:rapWalkNoted = $true
            $bad = @($kids | Where-Object { (Resolve-RlHandle $_.Handle) -ne $_.Ptr }).Count
            Say ("handle table check: scene root has {0} children, {1} fail to resolve (obj2 delta 0x{2:X})" -f $kids.Count, $bad, $script:rapD2)
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -ne $script:rapWalkErr) { $script:rapWalkErr = $msg; Say ("handle table walk failed: {0}" -f $msg) Yellow }
    }
}
function Write-RaptorForensics([string]$dump, [uint32]$d1) {
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add(''); $out.Add('# ---- forensics ----')
    $kids = @(Get-RlRootChildren)
    $out.Add(("# obj2 delta 0x{0:X}; root has {1} children now; {2} handles known from earlier walks" -f $script:rapD2, $kids.Count, $script:rapNames.Count))
    $live = @{}
    foreach ($k in $kids) {
        $live[[uint32]$k.Handle] = $k
        $ok = ((Resolve-RlHandle $k.Handle) -eq $k.Ptr)
        if (-not $ok) {
            $out.Add(("# LINKED BUT UNRESOLVABLE: child 0x{0:X} handle 0x{1:X} name '{2}'" -f $k.Ptr, $k.Handle, $k.Name))
            $hx = [AztTool.ProcMem]::Read($g.ProcessId, (GuestPtr $k.Ptr), 64)
            if ($hx) { $out.Add('#   first 64 bytes: ' + (($hx | ForEach-Object { $_.ToString('X2') }) -join ' ')) }
        }
    }
    $esp = $(if ($S_rapEsp) { RdU32 (HostLin $S_rapEsp) } else { [uint32]0 })
    if ($esp -ge 0x1000) {
        $base = [uint32]($esp + 36)                     # past the trap's pushfd + pushad
        $sb = [AztTool.ProcMem]::Read($g.ProcessId, (GuestPtr $base), 1024)
        $regs = [AztTool.ProcMem]::Read($g.ProcessId, (GuestPtr $esp), 36)
        if ($regs) {
            $n = @('edi','esi','ebp','esp','ebx','edx','ecx','eax','efl')
            $out.Add('# registers at the callback: ' + ((0..8 | ForEach-Object { '{0}={1:X8}' -f $n[$_], [BitConverter]::ToUInt32($regs, $_ * 4) }) -join ' '))
        }
        if ($sb) {
            # The scene pass keeps its snapshot at [esp+8]=count, [esp+0xC]=array, and
            # 0x5B7F0 saved the loop counter (already incremented) two slots under its
            # return address.
            $want = [uint32](0x3F1EF + $d1)
            for ($i = 0; $i -lt 250; $i++) {
                if ([BitConverter]::ToUInt32($sb, $i * 4) -ne $want) { continue }
                $cnt = [BitConverter]::ToUInt32($sb, ($i + 1) * 4 + 8)
                $arr = [BitConverter]::ToUInt32($sb, ($i + 1) * 4 + 12)
                $idx = $(if ($i -ge 2) { [BitConverter]::ToUInt32($sb, ($i - 2) * 4) } else { 0 })
                $out.Add(("# scene pass snapshot: {0} handles at 0x{1:X}, failing on entry {2} (1-based)" -f $cnt, $arr, $idx))
                if ($cnt -gt 0 -and $cnt -lt 600 -and $arr -ge 0x1000) {
                    $ab = [AztTool.ProcMem]::Read($g.ProcessId, (GuestPtr $arr), [int]($cnt * 4))
                    for ($j = 0; $ab -and $j -lt $cnt; $j++) {
                        $h = [BitConverter]::ToUInt32($ab, $j * 4)
                        $rec = Resolve-RlHandle $h
                        $was = $(if ($script:rapNames.ContainsKey($h)) { $script:rapNames[$h] } else { '(never seen)' })
                        $state = $(if ($rec) { 'ok  ' } else { 'DEAD' })
                        $linked = $(if ($live.ContainsKey($h)) { 'still linked' } else { 'NOT in child list now' })
                        if (-not $rec -or ($j + 1) -eq $idx -or -not $live.ContainsKey($h)) {
                            $out.Add(("#   [{0,3}] handle 0x{1:X8} {2} {3}; was: {4}" -f ($j + 1), $h, $state, $linked, $was))
                        }
                    }
                }
                break
            }
            $out.Add('# raw stack from the callback entry (runtime values), 8 per line:')
            for ($i = 0; $i -lt 256; $i += 8) {
                $out.Add(('#   +{0:X3}: ' -f ($i * 4)) + ((0..7 | ForEach-Object { '{0:X8}' -f [BitConverter]::ToUInt32($sb, ($i + $_) * 4) }) -join ' '))
            }
        }
    } else { $out.Add('# no esp recorded -- overlay predates aztRaptorEsp') }
    [IO.File]::AppendAllLines($dump, $out)
    foreach ($l in $out) { if ($l -match 'LINKED BUT|scene pass snapshot|DEAD|NOT in child') { Say ('  ' + $l.TrimStart('#',' ')) Red } }
}

function Test-RaptorTrap {
    if (-not $S_rapHit) { return $false }
    if ((RdU32 $(if ($script:hlRapHit) { $script:hlRapHit } else { HostLin $S_rapHit })) -eq 0) { return $false }      # (the address worked out once per attach: Invoke-Session)

    $code = RdU32 (HostLin $S_rapCode)
    $low  = [int]($code -band 0xFF)
    $name = $(if ($low -lt $RL_ERRORS.Count) { $RL_ERRORS[$low] } else { 'unknown' })
    $seen = RdU32 (HostLin $S_rapSeen)
    $d1 = $(if ($S_delta1) { RdU32 (HostLin $S_delta1) } else { [uint32]0 })
    Say ("REALITY LAB ERROR TRAPPED: code {0} ({1}), report {2} of this session" -f $low, $name, $seen) Red
    Say ("  obj1 load delta 0x{0:X} -- captured addresses are already converted to BUILT linear" -f $d1) Red

    $chain = @()
    $sb = [AztTool.ProcMem]::Read($g.ProcessId, (HostLin $S_rapStk), 80)
    if ($sb) {
        for ($i = 0; $i -lt 20; $i++) {
            $v = [BitConverter]::ToUInt32($sb, $i * 4)
            if ($v -eq 0) { break }
            $chain += $v
        }
    }
    if ($chain.Count) {
        Say ("  caller chain ({0} candidates, innermost first):" -f $chain.Count) Red
        # Four per line: the whole point is to paste this into the disassembler, and a
        # 20-line block in a log that already scrolls fast is harder to read than five.
        for ($i = 0; $i -lt $chain.Count; $i += 4) {
            $row = @()
            for ($j = $i; $j -lt [Math]::Min($i + 4, $chain.Count); $j++) { $row += ('0x{0:X8}' -f $chain[$j]) }
            Say ('    ' + ($row -join '  ')) Red
        }
    } else {
        Say '  the stack held nothing that looked like a return address' Red
    }
    # THE FILE IS WRITTEN EITHER WAY. It used to be written only when the chain had
    # entries, so the one run that caught the error and captured nothing left no record of
    # having fired at all -- the empty result is itself the measurement that found the
    # delta bug. The next thing that happens is the game dying and the watcher reporting
    # that, so whatever is worth keeping has to leave the log.
    try {
        $dump = Join-Path (Split-Path $LogFile -Parent) 'raptor.txt'
        $out = @(("# Reality Lab error trapped {0:yyyy-MM-dd HH:mm:ss}" -f (Get-Date)),
                 ("# code {0} ({1}), report {2}, room {3}" -f $low, $name, $seen, $script:rapRoom),
                 ("# obj1 load delta 0x{0:X}; addresses below are BUILT linear, ready for the disassembler" -f $d1),
                 ("# {0} candidate(s)" -f $chain.Count))
        $out += $chain | ForEach-Object { '0x{0:X8}' -f $_ }
        [IO.File]::WriteAllLines($dump, $out)
        Say ("  written to {0} -- symbolise with tools\Read-Raptor.ps1" -f $dump) Red
        # After the chain is safely on disk: this part reads far more and may throw.
        try { Write-RaptorForensics $dump $d1 } catch { Say ("  forensics failed: {0}" -f $_.Exception.Message) Yellow }
    } catch { }

    # Release the game. It will now print the error exactly as it always did.
    [void]$hv.WriteU32((HostLin $S_rapHit), 0)
    return $true
}

# The cheap room-change test. Walks the graph like Find-LiveRoom but reads only the name
# POINTER from each frame, never the string behind it, and stops at $cap frames -- which is
# the whole difference between ~10 ms and several hundred. The pointers themselves are the
# fingerprint: a rebuilt scene allocates new ones.
function Get-SceneFingerprint([uint32]$camObj, [int]$cap = 220) {
    # (2026-10-13 performance audit: the same walk in C#, SceneGraph.Fingerprint -- ~660 PowerShell calls here were a
    # 10-30 ms hitch twice a second; the script version below stays only as the fallback)
    try { return [AztTool.SceneGraph]::Fingerprint([int]$g.ProcessId, [long]$g.MemBase, [uint32]$camObj, $cap) } catch { }
    $p = $camObj
    for ($i = 0; $i -lt 16; $i++) {
        $par = RdU32 ([long]($g.MemBase + $p + 0x30))
        if ($par -lt 0x1000) { break }
        $p = $par
    }
    $acc = [uint64]$p; $n = 0
    $stack = New-Object System.Collections.Stack
    $stack.Push($p)
    $seen = @{}
    while ($stack.Count -gt 0 -and $n -lt $cap) {
        $f = [uint32]$stack.Pop()
        if ($f -lt 0x1000 -or $seen.ContainsKey($f)) { continue }
        $seen[$f] = 1; $n++
        $acc = ($acc * 31 + [uint64](RdU32 ([long]($g.MemBase + $f + 0x24)))) -band 0xFFFFFFFFFFFF
        $c = RdU32 ([long]($g.MemBase + $f + 0x3C)); if ($c -ge 0x1000) { $stack.Push($c) }
        $s = RdU32 ([long]($g.MemBase + $f + 0x34)); if ($s -ge 0x1000) { $stack.Push($s) }
    }
    return ("{0}:{1}" -f $n, $acc)
}

# The host's own 8bpp output, written through the game's palette so the PNG is exactly what
# the guest was handed -- not a re-render, not a re-quantisation.
function Save-HostFrame([byte[]]$color, [byte[]]$pal, [string]$room) {
    New-Item -ItemType Directory -Force $SaveDir | Out-Null
    # the picture's own size, and in true colour the true-colour picture
    $tr = $script:tcRaster
    $fw = $(if ($tr) { [int]$tr.W } else { $W }); $fh = $(if ($tr) { [int]$tr.H } else { $H })
    $rc = New-Object System.Drawing.Rectangle -ArgumentList ([int]0),([int]0),([int]$fw),([int]$fh)
    if ($tr -and $tr.Rgb -and $tr.Color32) {
        $bmp = New-Object System.Drawing.Bitmap -ArgumentList ([int]$fw), ([int]$fh), ([System.Drawing.Imaging.PixelFormat]::Format32bppRgb)
        $bd = $bmp.LockBits($rc, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppRgb)
        for ($y = 0; $y -lt $fh; $y++) { [System.Runtime.InteropServices.Marshal]::Copy([int[]]$tr.Color32, $y*$fw, [IntPtr]($bd.Scan0.ToInt64() + $y*$bd.Stride), $fw) }
    } else {
        $bmp = New-Object System.Drawing.Bitmap -ArgumentList ([int]$fw), ([int]$fh), ([System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
        $cp = $bmp.Palette
        for ($i = 0; $i -lt 256; $i++) { $cp.Entries[$i] = [System.Drawing.Color]::FromArgb(255, $pal[$i*3], $pal[$i*3+1], $pal[$i*3+2]) }
        $bmp.Palette = $cp
        $bd = $bmp.LockBits($rc, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
        for ($y = 0; $y -lt $fh; $y++) {
            [System.Runtime.InteropServices.Marshal]::Copy($color, $y*$fw, [IntPtr]($bd.Scan0.ToInt64() + $y*$bd.Stride), $fw)
        }
    }
    $bmp.UnlockBits($bd)
    $f = Join-Path $SaveDir ("{0:HHmmss}-{1}-{2}.png" -f (Get-Date), $room, $PID)
    $bmp.Save($f, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    return $f
}

# ---- live posing ------------------------------------------------------------
# The .XAF gives every object in its REST pose, which is why doors never opened, picked-up
# items kept being drawn and anything the engine moves stayed put. This holds the per-room
# state needed to re-pose from the live scene graph each frame:
#
#   PoseV    the vertex buffer actually drawn (starts as a copy of the rest pose)
#   InvRest  inverse of each part's rest matrix, computed ONCE -- D = inv(rest) * live
#   BaseTex  the texture index each triangle should have when its object is visible
#   Posed    whether a part's vertices currently differ from rest, so a part that stops
#            moving gets restored exactly once instead of every frame
function New-PoseState($room) {
    $n = $room.Parts.Count
    $st = [pscustomobject]@{
        PoseV   = [single[]]$room.V.Clone()
        InvRest = New-Object 'single[][]' $n
        BaseTex = [int[]]$room.TexIdx.Clone()
        CurTex  = [int[]]$room.TexIdx.Clone()
        Vis     = New-Object bool[] $n
        Posed   = New-Object bool[] $n
        Missing = 0
        Moved   = 0
        # the same part table as flat arrays, which is what SceneGraph.PoseAll takes
        Names   = [string[]]@($room.Parts | ForEach-Object { [string]$_.Name })
        VFirst  = [int[]]@($room.Parts | ForEach-Object { [int]$_.VFirst })
        VCount  = [int[]]@($room.Parts | ForEach-Object { [int]$_.VCount })
        Rest    = New-Object 'single[][]' $n
        Changed = New-Object 'System.Collections.Generic.List[int]'
        # how many times each part's live matrix changed between walks, for the motion report
        Last    = New-Object 'single[][]' $n
        Steps   = New-Object int[] $n
        # when each part first and last changed, and its matrix at that first change -- a
        # motion is reported once it has been still for a second, timed start to finish
        T0      = New-Object double[] $n
        T1      = New-Object double[] $n
    }
    for ($i = 0; $i -lt $n; $i++) {
        $st.Rest[$i] = [single[]]$room.Parts[$i].Rest
        $st.InvRest[$i] = [AztTool.SceneGraph]::InvertAffine($st.Rest[$i])
        $st.Vis[$i] = $true
    }
    return $st
}

# Apply the live graph to one room's geometry. Returns nothing; mutates $st.
function Update-Pose($room, $st, $live, [bool]$stats = $true) {
    $st.Changed.Clear()
    # THE STEP STATISTICS ARE FOR RAW POSES ONLY. They count how often a part's matrix changes,
    # which is the game's stepping when the matrices are as read, and merely "every frame"
    # once they are eased -- so with smoothing on they are not collected at all.
    if ($stats) {
        $res = [AztTool.SceneGraph]::PoseAll($live, $st.Names, $st.VFirst, $st.VCount, $st.Rest, $st.InvRest,
                                             [single[]]$room.V, $st.PoseV, $st.Posed, $st.Vis, $st.Changed, $st.Last, $st.Steps, $st.T0, $st.T1)
    } else {
        $res = [AztTool.SceneGraph]::PoseAll($live, $st.Names, $st.VFirst, $st.VCount, $st.Rest, $st.InvRest,
                                             [single[]]$room.V, $st.PoseV, $st.Posed, $st.Vis, $st.Changed)
    }
    $st.Moved = $res[0]; $st.Missing = $res[1]
    # Visibility changed: -1 is the rasteriser's "do not draw". This is what makes a picked-up
    # item disappear -- the engine removes its frame from the scene, so it stops appearing in
    # the walk. Rare, so the per-triangle pass stays in script.
    foreach ($i in $st.Changed) {
        $vis = $st.Vis[$i]
        for ($t = 0; $t -lt $st.CurTex.Length; $t++) {
            if ($room.TriPart[$t] -eq $i) { $st.CurTex[$t] = $(if ($vis) { $st.BaseTex[$t] } else { -1 }) }
        }
    }
}

# ---- CHARACTERS: which rigs are in the room, and which file each one is -------------------
# A room's .XAF holds the room. Characters live in their own .XAF and the engine instances
# them into the scene at run time, so a room-only loader draws an empty room. The live scene
# graph says exactly what is present: the engine names an instance's frames "ZZ%04d" + the
# object's own name (its format strings are in R.EXE beside "XAFQ%d"), so every frame called
# ZZ0001EUBUM, ZZ0001EUHEAD... is one rig, and the names with the prefix removed identify the
# file -- the same object index Find-LiveRoom uses for rooms.
#
# Several files can share one skeleton (EUGBLD, EUGBLD1, EUGBLD2, EUGTEST all name the same
# bones). The tie goes to the file a character definition actually loads: every *.ANI in the
# game directory has a `FILE name.xaf` line, and EUGENE.ANI says eugbld.xaf.
$script:xafIndex = $null; $script:aniXafs = @{}; $script:nameToFiles = $null
function Initialize-CharacterIndex {
    $script:xafIndex = @{}
    $ix = 'C:\Games\RaptorMod\cache\xaf-objects.json'
    if (-not (Test-Path $ix)) { return }
    $j = Get-Content $ix -Raw | ConvertFrom-Json
    $script:nameToFiles = New-Object 'System.Collections.Hashtable' ([StringComparer]::Ordinal)
    foreach ($p in $j.PSObject.Properties) {
        # ORDINAL, case-sensitive: object names are matched exactly as the engine spells them,
        # and a default hashtable would fold "Head" and "head" together.
        $h = New-Object 'System.Collections.Hashtable' ([StringComparer]::Ordinal); $fn = $p.Name.ToUpper()
        foreach ($o in @($p.Value)) {
            $h[[string]$o] = 1
            if (-not $script:nameToFiles.ContainsKey([string]$o)) { $script:nameToFiles[[string]$o] = New-Object System.Collections.Generic.List[string] }
            $script:nameToFiles[[string]$o].Add($fn)
        }
        $script:xafIndex[$fn] = $h
    }
    $aniDir = Join-Path (Split-Path $TexDir -Parent) 'AZRAEL'
    foreach ($a in (Get-ChildItem $aniDir -Filter '*.ANI' -ErrorAction SilentlyContinue)) {
        foreach ($m in [regex]::Matches([IO.File]::ReadAllText($a.FullName), '(?im)^\s*FILE\s+([A-Za-z0-9_\-]+)\.xaf')) { $script:aniXafs[$m.Groups[1].Value.ToUpper()] = 1 }
    }
}
# The room, by greedy set cover over the object index -- the rule Find-LiveRoom.ps1 documents:
# take the file that explains the most still-unexplained live names, repeat while a file adds
# a worthwhile share, stop when what is left is creature rigs and engine-made frames.
# Driven from the inverted index (name -> files), so a pass costs one lookup per live name
# instead of one scan per file.
function Find-LiveRoomFast([string[]]$liveNames) {
    $remaining = @{}; foreach ($n in $liveNames) { if ($n) { $remaining[$n] = 1 } }
    $total = $remaining.Count; $chosen = @()
    if ($total -eq 0) { return $chosen }
    for ($pass = 0; $pass -lt 6 -and $remaining.Count -gt 0; $pass++) {
        $hits = @{}
        foreach ($n in $remaining.Keys) { $fs = $script:nameToFiles[$n]; if ($fs) { foreach ($f in $fs) { $hits[$f] = 1 + [int]$hits[$f] } } }
        $best = $null; $bestHit = 0
        # A CHARACTER RIG IS NEVER A ROOM. A dead Lurka's frames matched enough of LURKA.XAF
        # by bare name to be chosen as a second "room" for a moment (23:38:17, "MINEHEAD+LURKA"),
        # which loads the rig a second time at its rest pose. Rigs are the files the *.ANI
        # definitions name; they are left to the character loader.
        foreach ($f in $hits.Keys) { if ($script:aniXafs.ContainsKey($f)) { continue }; if (($chosen -notcontains $f) -and ($hits[$f] -gt $bestHit -or ($hits[$f] -eq $bestHit -and [string]::CompareOrdinal($f, $best) -lt 0))) { $best = $f; $bestHit = $hits[$f] } }
        if (-not $best -or $bestHit -lt [Math]::Max(3, $total * 0.05)) { break }
        $chosen += $best
        foreach ($o in @($script:xafIndex[$best].Keys)) { $remaining.Remove($o) }
    }
    return $chosen
}

function Get-LiveCharacters([string[]]$nodes, [string[]]$roomFiles) {
    if ($null -eq $script:xafIndex) { Initialize-CharacterIndex }
    $groups = @{}
    foreach ($nm in $nodes) {          # live frame NAMES (strings)
        if ($nm -and $nm -match '^(ZZ\d{4})(.+)$') {
            if (-not $groups.ContainsKey($Matches[1])) { $groups[$Matches[1]] = New-Object System.Collections.Generic.List[string] }
            $groups[$Matches[1]].Add($Matches[2])
        }
    }
    # THE SAME CHARACTERS AS LAST TIME: the same answer (2026-10-13 performance audit -- the match below is ~10k script
    # iterations, a 10-20 ms hitch once a second; it only depends on the prefixes, their bone names and the room's files)
    $memoKey = ($roomFiles -join '+') + '|' + ((@($groups.Keys) | Sort-Object | ForEach-Object { $_ + '=' + ($groups[$_] -join ',') }) -join ';')
    if ($null -ne $script:liveCharMemo -and $script:liveCharMemoKey -eq $memoKey) { return $script:liveCharMemo }
    $res = @()
    foreach ($pre in @($groups.Keys | Sort-Object)) {
        $bones = $groups[$pre]
        # An instanced ROOM object carries the prefix too. If the room's own files already
        # explain most of these names, this is not a character.
        $inRoom = 0
        foreach ($b in $bones) { foreach ($rf in $roomFiles) { $s = $script:xafIndex[$rf.ToUpper()]; if ($s -and $s.ContainsKey($b)) { $inRoom++; break } } }
        if ($inRoom * 2 -ge $bones.Count) { continue }
        $best = $null; $bestHit = 0
        foreach ($f in $script:xafIndex.Keys) {
            $s = $script:xafIndex[$f]; $hit = 0
            foreach ($b in $bones) { if ($s.ContainsKey($b)) { $hit++ } }
            if ($hit -gt $bestHit -or ($hit -eq $bestHit -and $hit -gt 0 -and $script:aniXafs.ContainsKey($f) -and -not $script:aniXafs.ContainsKey($best))) { $best = $f; $bestHit = $hit }
        }
        if ($best -and $bestHit -ge 3 -and $bestHit * 2 -ge $bones.Count) {
            $res += [pscustomobject]@{ Xaf = $best; Prefix = $pre; Hits = $bestHit; Of = $bones.Count }
        }
    }
    $script:liveCharMemoKey = $memoKey; $script:liveCharMemo = $res
    return $res
}
# THE ENGINE'S MESH AGAINST OURS. The transform probe above came back clean -- the frames of a
# floating character are the same whether we draw or the engine does -- so the frames are
# not what differs. What is left is the mesh: the vertices the engine actually holds for a
# part, in that part's local space, against the ones the host loaded from the .XAF. Ours are
# stored posed into the rest pose, so they are taken back to local with inv(rest) first.
function Invoke-MeshProbe([uint32]$root, $room, $st) {
    $eng = [AztTool.SceneGraph]::WalkMeshVerts($g.ProcessId, [long]$g.MemBase, $root, 900, 400)
    $byChar = @{}
    for ($i = 0; $i -lt $room.Parts.Count; $i++) {
        $p = $room.Parts[$i]; if (-not $p.IsCharacter) { continue }
        $pre = $p.Name.Substring(0, 6)
        if (-not $byChar.ContainsKey($pre)) { $byChar[$pre] = New-Object System.Collections.ArrayList }
        if (-not $eng.ContainsKey($p.Name)) { [void]$byChar[$pre].Add([pscustomobject]@{ N = $p.Name; Note = 'no engine mesh'; Max = -1; D = @(0,0,0); Ours = $p.VCount; Theirs = 0; Ratio = 0 }); continue }
        $e = $eng[$p.Name]; $ne = [int]$e[0]; $inv = $st.InvRest[$i]
        $n = [Math]::Min([Math]::Min($p.VCount, $ne), 400)
        $mx = 0.0; $sx = 0.0; $sy = 0.0; $sz = 0.0; $lo = 0.0; $le = 0.0
        for ($k = 0; $k -lt $n; $k++) {
            $o = ($p.VFirst + $k) * 3; $x = $room.V[$o]; $y = $room.V[$o+1]; $z = $room.V[$o+2]
            $lx = $x*$inv[0] + $y*$inv[4] + $z*$inv[8] + $inv[12]; $ly = $x*$inv[1] + $y*$inv[5] + $z*$inv[9] + $inv[13]; $lz = $x*$inv[2] + $y*$inv[6] + $z*$inv[10] + $inv[14]
            $ex = $e[1 + $k*3]; $ey = $e[2 + $k*3]; $ez = $e[3 + $k*3]
            $dx = $ex - $lx; $dy = $ey - $ly; $dz = $ez - $lz
            $mx = [Math]::Max($mx, [Math]::Max([Math]::Abs($dx), [Math]::Max([Math]::Abs($dy), [Math]::Abs($dz))))
            $sx += $dx; $sy += $dy; $sz += $dz
            $lo += [Math]::Sqrt($lx*$lx + $ly*$ly + $lz*$lz); $le += [Math]::Sqrt($ex*$ex + $ey*$ey + $ez*$ez)
        }
        [void]$byChar[$pre].Add([pscustomobject]@{ N = $p.Name; Note = ''; Max = $mx; D = @(($sx/$n), ($sy/$n), ($sz/$n)); Ours = $p.VCount; Theirs = $ne; Ratio = $(if ($lo -gt 0) { $le / $lo } else { 0 }) })
    }
    foreach ($pre in @($byChar.Keys | Sort-Object)) {
        $rows = $byChar[$pre]; $bad = @($rows | Where-Object { $_.Max -gt 0.05 -or $_.Max -lt 0 -or $_.Ours -ne $_.Theirs })
        Say ("MESH PROBE {0}: {1} parts, {2} differ from the engine's mesh" -f $pre, $rows.Count, $bad.Count) Magenta
        foreach ($r in ($bad | Sort-Object Max -Descending | Select-Object -First 10)) {
            Say ("  {0,-18} verts ours {1,3} engine {2,3}  max diff {3,9:N3}  mean offset ({4:N2} {5:N2} {6:N2})  engine/ours size {7:N3} {8}" -f $r.N, $r.Ours, $r.Theirs, $r.Max, $r.D[0], $r.D[1], $r.D[2], $r.Ratio, $r.Note) Magenta
        }
    }
}

function Save-EngineReference($ras, [single[]]$cam, [ref]$flag) {
    $hostColor = [byte[]]$ras.Color.Clone(); $hostDepth = [single[]]$ras.Depth.Clone()
    Set-Engine3D $flag $false
    # Wait for the engine to have drawn, then for two reads of its surface to agree: a single
    # read can land halfway through a frame.
    Start-Sleep -Milliseconds 350
    $ptrB = Read-AztGuest $g 0x163A34 4 -Obj2
    if (-not $ptrB) { return 'no surface pointer' }
    $ptr = [BitConverter]::ToUInt32([byte[]]$ptrB, 0)
    if ($ptr -lt 0x1000) { return 'surface pointer is null' }
    # SEVERAL COPIES, THEN THE SETTLED PICTURE. Two identical copies never happened: the
    # engine spends most of each frame part-way through drawing this surface, so every copy
    # is partial. See SceneGraph.SettledFrame.
    $reads = New-Object 'byte[][]' 7
    for ($k = 0; $k -lt 7; $k++) {
        $reads[$k] = [byte[]][AztTool.ProcMem]::Read($g.ProcessId, (GuestPtr $ptr), ($W * $H))
        if (-not $reads[$k] -or $reads[$k].Length -ne ($W * $H)) { return 'could not read the engine surface' }
        Start-Sleep -Milliseconds 37          # not a multiple of the engine's frame time
    }
    $unsettled = 0
    $eng = [AztTool.SceneGraph]::SettledFrame($reads, [ref]$unsettled)
    $unsPct = 100.0 * $unsettled / ($W * $H)
    if ($unsPct -gt $(if ($Audit) { 30 } else { 6 })) { return ("{0:N1}% of the engine picture never settled (something is moving in view)" -f $unsPct) }
    # the player must not have moved between our frame and the engine's
    $rec2 = [AztTool.ProcMem]::Read($g.ProcessId, (HostLin $S_camRec), 320)
    if (-not $rec2) { return 'camera unreadable' }
    for ($i = 0; $i -lt 16; $i++) { if ([Math]::Abs([BitConverter]::ToSingle($rec2, $REC_MOVWORLD + $i*4) - $cam[$i]) -gt 0.001) { return 'the camera moved during the capture' } }
    if ($Audit) {
        $bad = 0.0; $ho = 0.0; $eo = 0.0
        [AztTool.Raster]::CompareFrames($hostColor, $eng, $pal, $W, $H, 28, [ref]$bad, [ref]$ho, [ref]$eo)
        New-Item -ItemType Directory -Force $AuditDir | Out-Null
        $file = ''
        # worth a look: the engine has something where we have nothing (or the reverse) over
        # more than 1.5% of the view, or a tenth of it is a different brightness
        $flag = ($eo -gt 1.5 -or $ho -gt 1.5 -or $bad -gt 10)
        if ($flag) {
            $pair = New-Object byte[] ($W * 2 * $H)
            for ($y = 0; $y -lt $H; $y++) { [Buffer]::BlockCopy($eng, $y * $W, $pair, $y * $W * 2, $W); [Buffer]::BlockCopy($hostColor, $y * $W, $pair, $y * $W * 2 + $W, $W) }
            $bmp = New-Object System.Drawing.Bitmap -ArgumentList ([int]($W * 2)), ([int]$H), ([System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
            $cp = $bmp.Palette; for ($i = 0; $i -lt 256; $i++) { $cp.Entries[$i] = [System.Drawing.Color]::FromArgb(255, $pal[$i*3], $pal[$i*3+1], $pal[$i*3+2]) }; $bmp.Palette = $cp
            $rc = New-Object System.Drawing.Rectangle -ArgumentList ([int]0), ([int]0), ([int]($W * 2)), ([int]$H)
            $bd = $bmp.LockBits($rc, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format8bppIndexed)
            for ($y = 0; $y -lt $H; $y++) { [System.Runtime.InteropServices.Marshal]::Copy($pair, $y * $W * 2, [IntPtr]($bd.Scan0.ToInt64() + $y * $bd.Stride), $W * 2) }
            $bmp.UnlockBits($bd)
            $file = "{0:HHmmss}-{1}.png" -f (Get-Date), ($script:rapRoom -replace '[^A-Za-z0-9_+-]', '_')
            $bmp.Save((Join-Path $AuditDir $file), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        }
        $csv = Join-Path $AuditDir 'audit.csv'
        if (-not (Test-Path $csv)) { [IO.File]::WriteAllText($csv, "time,room,x,y,z,differentPct,hostOnlyPct,engineOnlyPct,unsettledPct,flagged,file,camera`r`n") }
        [IO.File]::AppendAllText($csv, ("{0:s},{1},{2:F0},{3:F0},{4:F0},{5:F1},{6:F1},{7:F1},{8:F1},{9},{10},{11}`r`n" -f (Get-Date), $script:rapRoom, $cam[12], $cam[13], $cam[14], $bad, $ho, $eo, $unsPct, [int]$flag, $file, ((@($cam) | ForEach-Object { '{0:R}' -f $_ }) -join ' ')))
        return ("AUDIT {0} at ({1:N0},{2:N0},{3:N0}): {4:N1}% of the view differs; engine-only {5:N1}%, host-only {6:N1}%{7}" -f `
            $script:rapRoom, $cam[12], $cam[13], $cam[14], $bad, $eo, $ho, $(if ($flag) { "  ** FLAGGED -> $file" } else { '  ok' }))
    }
    New-Item -ItemType Directory -Force $CaptureRefDir | Out-Null
    $stem = Join-Path $CaptureRefDir ("{0:HHmmss}-{1}" -f (Get-Date), ($script:rapRoom -replace '[^A-Za-z0-9_+-]', '_'))
    [IO.File]::WriteAllBytes("$stem.host.bin", $hostColor); [IO.File]::WriteAllBytes("$stem.eng.bin", $eng)
    $db = New-Object byte[] ($hostDepth.Length * 4); [Buffer]::BlockCopy($hostDepth, 0, $db, 0, $db.Length); [IO.File]::WriteAllBytes("$stem.depth.bin", $db)
    $meta = [ordered]@{ room = $script:rapRoom; width = $W; height = $H; fov = $Fov; near = 0.5; camera = @($cam | ForEach-Object { [double]$_ }); time = (Get-Date).ToString('s') }
    [IO.File]::WriteAllText("$stem.json", ($meta | ConvertTo-Json -Compress))
    return ("saved {0}  ({1:N2}% of pixels unconfirmed)" -f (Split-Path $stem -Leaf), $unsPct)
}

function Invoke-CharProbe([uint32]$root, [ref]$flag) {
    $a = [AztTool.SceneGraph]::WalkBlocks($g.ProcessId, [long]$g.MemBase, $root, 900)
    $fa = $(if ($S_frameNo) { RdU32 (HostLin $S_frameNo) } else { 0 })
    Set-Engine3D $flag $false
    Start-Sleep -Milliseconds 1500
    $b = [AztTool.SceneGraph]::WalkBlocks($g.ProcessId, [long]$g.MemBase, $root, 900)
    $fb = $(if ($S_frameNo) { RdU32 (HostLin $S_frameNo) } else { 0 })
    $rows = @()
    foreach ($k in $a.Keys) {
        if (-not $b.ContainsKey($k)) { continue }
        $x = $a[$k]; $y = $b[$k]
        $dl = 0.0; $dw = 0.0; $dt = 0.0
        for ($i = 0; $i -lt 16; $i++) {
            $dl = [Math]::Max($dl, [Math]::Abs($x[$i] - $y[$i])); $dw = [Math]::Max($dw, [Math]::Abs($x[16+$i] - $y[16+$i])); $dt = [Math]::Max($dt, [Math]::Abs($x[32+$i] - $y[32+$i]))
        }
        if ($dl -gt 0.01 -or $dw -gt 0.01 -or $dt -gt 0.01) { $rows += [pscustomobject]@{ N = $k; DL = $dl; DW = $dw; DT = $dt; A = $x; B = $y } }
    }
    $onlyA = @($a.Keys | Where-Object { -not $b.ContainsKey($_) }); $onlyB = @($b.Keys | Where-Object { -not $a.ContainsKey($_) })
    Say ("CHAR PROBE: {0} frames while host draws (guest frame {1}), {2} while engine draws (frame {3}); {4} differ; {5} vanished, {6} appeared" -f $a.Count, $fa, $b.Count, $fb, $rows.Count, $onlyA.Count, $onlyB.Count) Magenta
    foreach ($r in ($rows | Sort-Object DW -Descending | Select-Object -First 14)) {
        Say ("  {0,-18} local d{1,8:N2}  world d{2,8:N2}  third d{3,6:N2} | local t ({4:N1} {5:N1} {6:N1}) -> ({7:N1} {8:N1} {9:N1}) | world t ({10:N1} {11:N1} {12:N1}) -> ({13:N1} {14:N1} {15:N1}) | flags {16}{17}{18} -> {19}{20}{21}" -f `
            $r.N, $r.DL, $r.DW, $r.DT, $r.A[12], $r.A[13], $r.A[14], $r.B[12], $r.B[13], $r.B[14], $r.A[28], $r.A[29], $r.A[30], $r.B[28], $r.B[29], $r.B[30], `
            [int]$r.A[48], [int]$r.A[49], [int]$r.A[50], [int]$r.B[48], [int]$r.B[49], [int]$r.B[50]) Magenta
    }
    if ($onlyA.Count) { Say ("  vanished: {0}" -f (($onlyA | Select-Object -First 12) -join ' ')) Magenta }
    if ($onlyB.Count) { Say ("  appeared: {0}" -f (($onlyB | Select-Object -First 12) -join ' ')) Magenta }
    # the camera chain moves when the player does, so say whether the player was still
    $cam = $rows | Where-Object { $_.N -eq 'dummy' }
    if ($cam) { Say '  (the player body "dummy" moved too -- stand still for a clean reading)' Magenta }
}

# ---- DOORWAYS -----------------------------------------------------------------------------
# The neighbouring rooms for this room's doorways, ready to draw. Built again whenever the room
# object is (a creature arriving rebuilds it, and the picture quads' indices move with it);
# the neighbours' own geometry comes from the unit cache, so this is a few milliseconds.
function Get-RoomPortals($room, [string[]]$files) {
    if (-not $Portals -or $NoPortals -or -not $room) { return $null }
    try {
        $ps = Get-AztPortals -Room $room -Files $files -CacheDir $CacheDir -TexDir $TexDir -Palette $Palette
        foreach ($note in @($script:AztPortalNotes)) { Say ("  {0}" -f $note) Yellow }
        if ($ps -and $ps.Count) {
            Say ("  doorways: {0}" -f ((@($ps) | ForEach-Object { '{0} ({1:N0} triangles)' -f $_.To, ($_.T.Length / 3) }) -join ', ')) Cyan
            return ,([AztTool.Portal[]]$ps)
        }
    } catch { Say ("  doorways unavailable: {0}" -f $_.Exception.Message) Yellow }
    return $null
}

# WHAT THE GAME ACTUALLY DID AT A DOORWAY, against what the portal map assumes. The map is
# built from the files alone: which way each room's exit faces, and so how far the far room is
# turned relative to this one. The game knows the truth, and shows it every time the player
# walks through a door -- the camera's heading just before the teleport and just after. One
# line per transition, so a map entry that is turned wrong can be seen in the log instead of
# on the screen. `$tele` is the last camera jump: @{ Before; After; At (stopwatch ms) }.
function Write-PortalCheck($tele, [string]$from, [string]$to) {
    if (-not $tele -or -not $script:AztPortalMap -or -not $from -or -not $to) { return }
    $toFiles = @($to -split '\+' | ForEach-Object { $_.ToUpper() })
    $best = $null; $bestD = [double]::MaxValue; $b = $tele.Before; $a = $tele.After
    foreach ($f in ($from -split '\+')) {
        $prop = $script:AztPortalMap.PSObject.Properties[$f.ToUpper()]
        if (-not $prop) { continue }
        foreach ($e in @($prop.Value)) {
            if ($toFiles -notcontains ([string]$e.to).ToUpper()) { continue }
            $d = [Math]::Sqrt([Math]::Pow($b[12] - [double]$e.door[0], 2) + [Math]::Pow($b[14] - [double]$e.door[2], 2))
            if ($d -lt $bestD) { $bestD = $d; $best = $e }
        }
    }
    if (-not $best) { Say ("  PORTAL CHECK {0} -> {1}: the portal map has no doorway between these" -f $from, $to) DarkYellow; return }
    $deg = 180.0 / [Math]::PI
    $hB = [Math]::Atan2($b[8], $b[10]) * $deg; $hA = [Math]::Atan2($a[8], $a[10]) * $deg
    $turnSeen = $hA - $hB; while ($turnSeen -gt 180) { $turnSeen -= 360 }; while ($turnSeen -le -180) { $turnSeen += 360 }
    # the map's turn is for the far room's geometry coming INTO this room; the player's
    # heading going the other way turns by the opposite amount
    $turnMap = -[Math]::Atan2(-[double]$best.m[2], [double]$best.m[0]) * $deg
    $off = $turnSeen - $turnMap; while ($off -gt 180) { $off -= 360 }; while ($off -le -180) { $off += 360 }
    $dl = [Math]::Sqrt([Math]::Pow($a[12] - [double]$best.land[0], 2) + [Math]::Pow($a[14] - [double]$best.land[2], 2))
    Say ("  PORTAL CHECK {0}: left {1:N0} units from the trigger heading {2:N0}; landed {3:N0} units from the arrival marker heading {4:N0}. Heading turned {5:N0} degrees, the map says {6:N0} ({7:N0} out)" -f `
        $best.zone, $bestD, $hB, $dl, $hA, $turnSeen, $turnMap, $off) DarkYellow
}

# ---- WHAT THE GAME THINKS IS UNDER THE CURSOR, AGAINST WHAT THE HOST DREW THERE ------------
# The game still does its own picking (0x116E4 -> Reality Lab's viewport pick) against its own
# scene, while the picture the player aims at is the host's. When the two disagree the player
# sees a door they cannot click. Five times a second, and logged only when either answer
# changes:
#   * the cursor (obj2 words 0x182D6C / 0x182D6E; the viewport starts 49 rows down the screen)
#   * the game's hovered object: word [0x146872] indexes the table at [0x1841D0], and the
#     status line prints the string at record + 0x3F
#   * the host part under that same pixel
#   * whether the CAMERA the game picks with is the camera the host drew with. The pick builds
#     its view from the camera frame's cached world matrix (camera + 0x8C, at 0x3C32F); the
#     host draws from the movement frame. The record carries both.
$script:pickLast = ''; $script:pickClock = [Diagnostics.Stopwatch]::StartNew(); $script:pickCamNote = ''
function Write-PickProbe($ras, $room, [single[]]$dv, [int[]]$dt, [byte[]]$rec, [single[]]$cam) {
    if ($script:pickClock.ElapsedMilliseconds -lt 200) { return }
    $script:pickClock.Restart()
    $cb = Read-AztGuest $g 0x182D6C 4 -Obj2
    $hb = Read-AztGuest $g 0x146870 4 -Obj2
    if (-not $cb -or -not $hb) { return }
    $cx = [int][BitConverter]::ToInt16([byte[]]$cb, 0); $cy = [int][BitConverter]::ToInt16([byte[]]$cb, 2)
    $px = $cx - [int]$man.view.injX; $py = $cy - [int]$man.view.injY
    if ($px -lt 0 -or $py -lt 0 -or $px -ge $W -or $py -ge $H) { return }
    $idx = [int][BitConverter]::ToInt16([byte[]]$hb, 2)
    $gameName = '-'
    if ($idx -ge 0) {
        $gameName = "#$idx"
        $tb = Read-AztGuest $g 0x1841D0 4 -Obj2
        if ($tb) {
            $tab = [BitConverter]::ToUInt32([byte[]]$tb, 0)
            if ($tab -ge 0x1000) {
                $pb = [AztTool.ProcMem]::Read($g.ProcessId, (GuestPtr ([uint32]($tab + $idx * 4))), 4)
                if ($pb) {
                    $recp = [BitConverter]::ToUInt32([byte[]]$pb, 0)
                    if ($recp -ge 0x1000) {
                        $rb = [byte[]][AztTool.ProcMem]::Read($g.ProcessId, (GuestPtr $recp), 0x60)
                        if ($rb) {
                            # every printable run in the record's first 0x60 bytes: the scene object's
                            # own name is in there as well as the display name at +0x3F
                            $strs = @([regex]::Matches([Text.Encoding]::ASCII.GetString($rb), '[\x21-\x7E][\x20-\x7E]{2,}') | ForEach-Object { $_.Value.Trim() })
                            $gameName = "#$idx " + ($strs -join ' | ')
                        }
                    }
                }
            }
        }
    }
    # the cursor is in the game's pixels; the picture may be drawn at another size
    # (in widescreen the game's 4:3 view sits in the middle of a wider picture)
    $gwP = $ras.H * $W / [double]$H; $gx0P = ($ras.W - $gwP) / 2
    $t = $ras.TriAt($dv, [int[]]$room.T, $dt, [int]($gx0P + $px * $gwP / $W), [int]($py * $ras.H / $H))
    $hostName = '-'
    if ($t -ge 0) { $pi4 = $room.TriPart[$t]; $hostName = $(if ($pi4 -ge 0) { [string]$room.Parts[$pi4].Name } else { '(no part)' }) }
    # the two cameras: translation apart, and the angle between their forward rows
    $cw = New-Object single[] 16; [Buffer]::BlockCopy($rec, 28, $cw, 0, 64)
    $dpos = [Math]::Sqrt([Math]::Pow($cw[12]-$cam[12],2) + [Math]::Pow($cw[13]-$cam[13],2) + [Math]::Pow($cw[14]-$cam[14],2))
    $dot = $cw[8]*$cam[8] + $cw[9]*$cam[9] + $cw[10]*$cam[10]; if ($dot -gt 1) { $dot = 1 } elseif ($dot -lt -1) { $dot = -1 }
    $dang = [Math]::Acos($dot) * 180 / [Math]::PI
    $camNote = $(if ($dpos -gt 1 -or $dang -gt 0.5) { 'PICK CAMERA IS {0:N0} units and {1:N1} degrees from the drawn one' -f $dpos, $dang } else { 'cameras agree' })
    $lvB = Read-AztGuest $g 0x14686C 2 -Obj2; $vpB = Read-AztGuest $g 0x152164 4 -Obj2
    $lv = $(if ($lvB) { [BitConverter]::ToUInt16([byte[]]$lvB, 0) } else { -1 })
    $vp = $(if ($vpB) { '{0}x{1}' -f [BitConverter]::ToUInt16([byte[]]$vpB, 0), [BitConverter]::ToUInt16([byte[]]$vpB, 2) } else { '?' })
    $key = "$gameName/$hostName/$($camNote.Substring(0, 8))"
    if ($key -eq $script:pickLast) { return }
    $script:pickLast = $key
    Say ("  PICK cursor {0},{1}: game says [{2}]  host drew [{3}]  | {4} | level {5}, engine viewport {6}" -f $px, $py, $gameName, $hostName, $camNote, $lv, $vp) DarkCyan
}

# ---- THE GAME'S OWN COLLISION TABLE ---------------------------------------------------------
# Floors and walls are not tested against the scene. At room load the game bakes every
# object's faces into flat arrays (0x2D6B4 / 0x2E2C0), and the ground test 0x2F758 walks them:
#     [0x165290]            face count
#     0x165294 + 12*i       plane normal            0x16B054 + 8*i   plane distance (double)
#     0x16EED4 + 4*i        pointer to the owning object's name
#     0x164FBC / 0x164ECC / 0x164FC0   the hits of the LAST ground test: count, names, points
# When a door turns, 0x2D630 re-bakes that one object IN PLACE: it finds the object's first
# face by name, lets the baker write from there, and puts the count back. That is only safe if
# the object produces exactly as many faces as it did before.
#
# This reads the table as the run of names it holds, in order. Logged on entering a room and
# again whenever the run changes, so if something overwrites a floor's faces the log says
# what, and when -- instead of the player finding out by falling through it.
$script:colNames = @{}; $script:colLast = ''; $script:colClock = [Diagnostics.Stopwatch]::StartNew()
function Get-CollisionRun {
    $cb = Read-AztGuest $g 0x165290 4 -Obj2
    if (-not $cb) { return $null }
    $n = [BitConverter]::ToInt32([byte[]]$cb, 0)
    if ($n -le 0 -or $n -gt 2000) { return "count $n" }
    $pb = [byte[]](Read-AztGuest $g 0x16EED4 ($n * 4) -Obj2)
    if (-not $pb) { return $null }
    $sb = New-Object Text.StringBuilder; $prev = [uint32]0; $run = 0; $prevName = ''
    for ($i = 0; $i -le $n; $i++) {
        $p = $(if ($i -lt $n) { [BitConverter]::ToUInt32($pb, $i * 4) } else { [uint32]0xFFFFFFFF })
        if ($p -eq $prev -and $i -lt $n) { $run++; continue }
        if ($run -gt 0) { [void]$sb.AppendFormat('{0}x{1} ', $prevName, $run) }
        if ($i -eq $n) { break }
        if (-not $script:colNames.ContainsKey($p)) {
            $nm = '?'
            if ($p -ge 0x1000) {
                $nb = [byte[]][AztTool.ProcMem]::Read($g.ProcessId, (GuestPtr $p), 24)
                if ($nb) { $z = [Array]::IndexOf($nb, [byte]0); if ($z -gt 0) { $nm = [Text.Encoding]::ASCII.GetString($nb, 0, $z) } }
            }
            $script:colNames[$p] = $nm
        }
        $prev = $p; $prevName = $script:colNames[$p]; $run = 1
    }
    return ("{0} faces: {1}" -f $n, $sb.ToString().TrimEnd())
}
function Write-CollisionWatch([string]$why) {
    try {
        $run = Get-CollisionRun
        if (-not $run -or $run -eq $script:colLast) { return }
        if ($why -or -not $script:colLast) { Say ("  COLLISION TABLE ({0}) {1}" -f $(if ($why) { $why } else { 'first read' }), $run) DarkMagenta }
        else {
            # say only what differs: the two runs split into items, shown where they part
            $a = $script:colLast -split ' '; $b = $run -split ' '; $k = 0
            while ($k -lt $a.Count -and $k -lt $b.Count -and $a[$k] -eq $b[$k]) { $k++ }
            $ea = $a.Count - 1; $eb = $b.Count - 1
            while ($ea -ge $k -and $eb -ge $k -and $a[$ea] -eq $b[$eb]) { $ea--; $eb-- }
            Say ("  COLLISION TABLE CHANGED after item {0} ({1}): was [{2}] now [{3}]  ({4} -> {5})" -f $k, $(if ($k -gt 0) { $a[$k-1] } else { 'start' }),
                ($a[$k..([Math]::Max($k, $ea))] -join ' '), ($b[$k..([Math]::Max($k, $eb))] -join ' '), $a[0], $b[0]) Magenta
        }
        $script:colLast = $run
    } catch { }
}
# The last ground test's hits, and every face of the named objects: for the FALL report.
function Write-GroundHits {
    $hc = Read-AztGuest $g 0x164FBC 2 -Obj2
    if ($hc) {
        $n = [BitConverter]::ToUInt16([byte[]]$hc, 0)
        if ($n -gt 0 -and $n -le 60) {
            $np = [byte[]](Read-AztGuest $g 0x164ECC ($n * 4) -Obj2); $pp = [byte[]](Read-AztGuest $g 0x164FC0 ($n * 12) -Obj2)
            $items = @()
            for ($i = 0; $i -lt $n; $i++) {
                $p = [BitConverter]::ToUInt32($np, $i * 4); $nm = $(if ($script:colNames.ContainsKey($p)) { $script:colNames[$p] } else { '0x{0:X}' -f $p })
                $items += ('{0}@{1:N1}' -f $nm, [BitConverter]::ToSingle($pp, $i * 12 + 4))
            }
            Say ("    last ground test hit {0}: {1}" -f $n, ($items -join '  ')) Red
        } else { Say ("    last ground test hit {0} faces" -f $n) Red }
    }
}

function Get-CharacterSig($chars) { (@($chars | ForEach-Object { '{0}={1}' -f $_.Prefix, $_.Xaf }) -join ',') }
# THE BOOT WAITS FOR THE ROOM (2026-10-15, the second PC: its first room took 61 s, the visor boot's hold gave up after 10 s and the
# 8-bit game showed): while a room is prepared the boot's hold does not time out (BootHd.HoldWhileBusy, its status line under the
# briefing), and when it is ready the hold is given 15 s more for the textures to reach the card and the first frame
function Get-RoomBusy([string[]]$rooms, $chars = @()) {
    $bh = $script:bootHd
    if ($bh) { $bh.BusyText = 'PREPARING TEXTURES...'; $bh.HoldWhileBusy = $true }
    try { Get-Room $rooms $chars }
    finally { if ($bh) { $bh.HoldExtendUntil = [Diagnostics.Stopwatch]::GetTimestamp() + 15 * [Diagnostics.Stopwatch]::Frequency; $bh.HoldWhileBusy = $false } }
}

function Get-Room([string[]]$rooms, $chars = @()) {
    $key = ($rooms -join '+') + '|' + (Get-CharacterSig $chars)
    if ($roomCache.Contains($key)) {
        # (met before: its painted colours are normally still decoded -- unless the session's texture cache gave them up to
        # stay under -TextureCacheGB, and then they are decoded again here, under the room's loading cover)
        $rm = $roomCache[$key]
        if ($TrueColour -and -not $NoRgb) {
            try {
                $rgbClock = [Diagnostics.Stopwatch]::StartNew()
                $rgbSt = Add-AztRgb -Names (@($rooms) + @($chars | Where-Object { $_ } | ForEach-Object { [string]$_.Xaf })) -CacheDir $CacheDir -Pal $pal -OverrideDir $rm.RgbDir -MaxSize ([int]$script:texMax) -Progress $script:rgbProgress
                [AztTool.Raster]::EnsureRgb($rm.Texes, $pal)
                if ($rgbSt.FromFile -or $rgbSt.FromPalette) {
                    Say ("  true colour textures decoded again (the session cache had let them go): {0} painted, {1} ms" -f $rgbSt.FromFile, $rgbClock.ElapsedMilliseconds) Cyan
                    $unitsHere = @(@($rooms) + @($chars | Where-Object { $_ } | ForEach-Object { [string]$_.Xaf }))
                    $lim = Limit-AztRgbCache -Keep $unitsHere -CapBytes $script:texCacheBytes
                    if ($lim.Dropped.Count) { Say ("  texture cache: {0} let go to stay under {1:N1} GB ({2}); {3:N1} GB held" -f $lim.Dropped.Count, ($script:texCacheBytes / 1GB), ($lim.Dropped -join ', '), ($lim.Bytes / 1GB)) DarkCyan }
                }
            } catch { Say ("  true colour textures failed: {0}" -f $_.Exception.Message) Yellow }
        }
        return $rm
    }
    $rm = Import-AztRoom -Rooms $rooms -Characters @($chars) -CacheDir $CacheDir -TexDir $TexDir -Palette $Palette -Width $W -Height $H
    # the shrunk copies the texture filter reads; built once per texture (they are shared
    # between rooms), a few milliseconds for a whole room
    if ($script:rgbLut) { [AztTool.Raster]::EnsureMips($rm.Texes, $pal, $script:rgbLut) }
    # true colour: the painted originals for every texture that has one (see Add-AztRgb)
    if ($TrueColour -and -not $NoRgb) {
        try {
            $rgbClock = [Diagnostics.Stopwatch]::StartNew()
            $dirNow = $TexOverrideDir
            $unitsHere = @(@($rooms) + @($chars | Where-Object { $_ } | ForEach-Object { [string]$_.Xaf }))
            $rgbSt = Add-AztRgb -Names $unitsHere -CacheDir $CacheDir -Pal $pal -OverrideDir $dirNow -MaxSize ([int]$script:texMax) -Progress $script:rgbProgress
            [AztTool.Raster]::EnsureRgb($rm.Texes, $pal)
            $rm | Add-Member -NotePropertyName RgbDir -NotePropertyValue $dirNow -Force
            if ($rgbSt.Replaced.Count) { Say ("  REPLACEMENT ART from {0}: {1}" -f $dirNow, ($rgbSt.Replaced -join ', ')) Green }
            if ($rgbSt.TwinError) { Say ("  shared art (twins' new art) not worked out, each texture keeps its own: {0}" -f $rgbSt.TwinError) Yellow }
            if ($rgbSt.Companions) { Say ("  companion maps (shine / height / glow) for {0} of them" -f $rgbSt.Companions) Green }
            if (@($rgbSt.CompanionErrors).Count) { Say ("  companion maps that would not load: {0}" -f (@($rgbSt.CompanionErrors) -join '; ')) Yellow }
            if ($rgbSt.FromFile -or $rgbSt.FromPalette) {
                # (2026-10-15: where the time went -- the second PC's first room took 61 s in all; the shared-art index is built once per PC)
                if ($rgbSt.TwinMs -gt 300) { Say ("  shared-art index: {0:N0} ms ({1})" -f $rgbSt.TwinMs, $rgbSt.TwinNote) DarkCyan }
                Say ("  true colour textures: {0} painted originals, {1} from the palette, {2} ms{3}" -f $rgbSt.FromFile, $rgbSt.FromPalette, $rgbClock.ElapsedMilliseconds, `
                    $(if ($rgbSt.Bad.Count) { '  ** texture order did not match for ' + ($rgbSt.Bad -join ', ') + ': palette colours used' } else { '' })) Cyan
            }
            # the session's texture cache stays under -TextureCacheGB: the rooms met longest ago give their colours up first
            $lim = Limit-AztRgbCache -Keep $unitsHere -CapBytes $script:texCacheBytes
            if ($lim.Dropped.Count) { Say ("  texture cache: {0} let go to stay under {1:N1} GB ({2}); {3:N1} GB held" -f $lim.Dropped.Count, ($script:texCacheBytes / 1GB), ($lim.Dropped -join ', '), ($lim.Bytes / 1GB)) DarkCyan }
        } catch { Say ("  true colour textures failed: {0}" -f $_.Exception.Message) Yellow }
    }
    # ...and the enlarged set, when the experiment is on. Kept beside the originals so the
    # two can be switched between on the same view.
    $hiTex = $null
    if ($TexScale -gt 1 -and $script:rgbLut6) {
        $hiTex = [AztTool.Raster]::UpscaleAll($rm.Texes, $TexScale, $pal, $script:rgbLut6, [single]$TexSharpen)
        [AztTool.Raster]::EnsureMips($hiTex, $pal, $script:rgbLut)
    }
    $rm | Add-Member -NotePropertyName TexesHi -NotePropertyValue $hiTex -Force
    # WATER: which parts are it. The composed room has no material names, so they are read
    # from each file's OBJ (object -> materials); a part counts when a material is named for
    # water or liquid AND the part is flat and level -- "1W_WATERWALL" is a waterfall, not a
    # pool. Each gets its triangles as vertex indices, the shape the mask pass takes.
    $water = @()
    if (-not $NoReflections) {
        try {
            foreach ($rf in $rooms) {
                $objPath = Join-Path $CacheDir ("{0}.obj" -f $rf); if (-not (Test-Path $objPath)) { continue }
                $wetNames = @{}; $curO = ''
                foreach ($ln in [IO.File]::ReadAllLines($objPath)) {
                    if ($ln.StartsWith('o ')) { $curO = $ln.Substring(2).Trim() }
                    elseif ($ln.StartsWith('usemtl ') -and $ln -match 'WATER|LIQUID') { $wetNames[$curO] = 1 }
                }
                # (2026-10-10, Room Review WELLROOM/1) water whose material is not named for it -- the well's surface is the
                # part 'death' (NIBODYBASE, the drowned body under it): the room file's "water": { "parts": [names] }
                try { foreach ($pn in @((Get-RoomAtmosphere @($rf)).Water.parts)) { if ($pn) { $wetNames[[string]$pn] = 1 } } } catch { }
                if (-not $wetNames.Count) { continue }
                for ($pi6 = 0; $pi6 -lt $rm.Parts.Count; $pi6++) {
                    $pp = $rm.Parts[$pi6]
                    if ($pp.IsCharacter -or ([string]$pp.Room).ToUpper() -ne $rf.ToUpper() -or -not $wetNames.ContainsKey([string]$pp.Name) -or $pp.VCount -lt 3) { continue }
                    $y0 = [single]::MaxValue; $y1 = [single]::MinValue
                    for ($k = 0; $k -lt $pp.VCount; $k++) { $yy = $rm.V[($pp.VFirst + $k) * 3 + 1]; if ($yy -lt $y0) { $y0 = $yy }; if ($yy -gt $y1) { $y1 = $yy } }
                    if (($y1 - $y0) -gt 2.0) { continue }
                    $tl = New-Object 'System.Collections.Generic.List[int]'
                    $t = [Array]::IndexOf($rm.TriPart, $pi6)
                    while ($t -ge 0) { if ($rm.TexIdx[$t] -ge 0) { $tl.Add($t) }; $t = [Array]::IndexOf($rm.TriPart, $pi6, $t + 1) }
                    if (-not $tl.Count) { continue }
                    $tv = New-Object int[] ($tl.Count * 3)
                    for ($k = 0; $k -lt $tl.Count; $k++) { [Array]::Copy($rm.T, $tl[$k] * 3, $tv, $k * 3, 3) }
                    $water += [pscustomobject]@{ Part = $pi6; Name = [string]$pp.Name; VFirst = [int]$pp.VFirst; TriVerts = $tv }
                }
            }
        } catch { }
    }
    # ONE PASS PER WATER LEVEL, NOT PER QUAD. The dock's sea is six quads within 45 units of
    # each other in height; a mirror pass each would cost six redraws of the room. Pieces
    # within 60 units of a group's first piece share one pass, mirrored at their mean height.
    $groups = @()
    foreach ($wt in ($water | Sort-Object { $rm.V[$_.VFirst * 3 + 1] })) {
        $wyRest = $rm.V[$wt.VFirst * 3 + 1]; $wGrp = $null
        foreach ($gr in $groups) { if ([Math]::Abs($wyRest - $gr.Y0) -le 60) { $wGrp = $gr; break } }
        if ($wGrp) { $wGrp.Parts += $wt } else { $groups += [pscustomobject]@{ Y0 = $wyRest; Parts = @($wt) } }
    }
    $rm | Add-Member -NotePropertyName WaterGroups -NotePropertyValue $groups -Force
    $rm | Add-Member -NotePropertyName Water -NotePropertyValue $water -Force
    $rm | Add-Member -NotePropertyName TSwap -NotePropertyValue $(if ($water.Count) { [AztTool.Raster]::SwapWinding([int[]]$rm.T) } else { $null }) -Force
    while ($roomCache.Count -ge $CacheRooms) { $roomCache.RemoveAt(0) }
    $roomCache.Add($key, $rm)
    return $rm
}

$script:capWas = 0

# ---- the host-render frame cap, and the movement speed that has to follow it -------------
# MOVEMENT IS A DISTANCE PER FRAME, so raising the cap alone makes the player sprint: the
# build bakes the step for 24 fps (16.0 and 8.0 units scaled by 18.2065/24) into two plain
# floats in obj2, [0x141800] (run) and [0x1417FC] (walk / wall slide). Neither has a fixup
# and nothing else writes them, so the correction needs no guest code at all: measure the
# rate the guest is ACTUALLY running at and write step = design distance per second / rate.
# Measured rather than assumed 60, because a heavy room will not reach the cap and a step
# sized for 60 would then crawl. Actors and animation are clock-gated and need nothing.
# Anything ELSE that is frame-tied will run faster at the higher rate -- that is the known
# cost of this, and why the build's own cap was never raised.
$MOVE_PER_SEC = @{ 0x141800 = (16.0 * 18.2065); 0x1417FC = (8.0 * 18.2065) }
$script:fpsOn = $false; $script:fpsCapWas = [uint32]0; $script:fpsMoveWas = @{}
$script:fpsRate = 24.0; $script:fpsFrame0 = [uint32]0; $script:fpsClock = $null; $script:fpsMax = 60.0; $script:fpsLastRate = 400.0
$script:crouchK = 1.0      # (CROUCH: the share of the step while down -- every writer of the step multiplies by it)
# ---- the on-screen frame counter ---------------------------------------------------------
# DELIVERED frames per second -- pictures the guest actually took from us -- not the guest
# loop rate, which is far higher and is not what the player sees. Drawn into the host's own
# frame after the render, so it costs the guest nothing.
#
# The strip is rebuilt only when the number changes (twice a second at most) and stamped
# with one BlockCopy per row: per-pixel work in PowerShell on the frame path would cost
# more frame rate than it reports. Index 0 is never used -- it is black AND transparent in
# the guest, so a zero here would punch a hole through to the engine's own picture.
$FPS_FONT = @{
    '0' = '01110','10001','10011','10101','11001','10001','01110'
    '1' = '00100','01100','00100','00100','00100','00100','01110'
    '2' = '01110','10001','00001','00010','00100','01000','11111'
    '3' = '11110','00001','00001','01110','00001','00001','11110'
    '4' = '00010','00110','01010','10010','11111','00010','00010'
    '5' = '11111','10000','11110','00001','00001','10001','01110'
    '6' = '00110','01000','10000','11110','10001','10001','01110'
    '7' = '11111','00001','00010','00100','01000','01000','01000'
    '8' = '01110','10001','10001','01110','10001','10001','01110'
    '9' = '01110','10001','10001','01111','00001','00010','01100'
}
$FPS_SCALE = 4; $FPS_PAD = 6
$script:fpsInk = [byte]0; $script:fpsPaper = [byte]0; $script:fpsStrip = $null; $script:fpsShown = -1
$script:fpsDelivered = 0; $script:fpsDispClock = $null; $script:fpsDispBase = 0; $script:fpsCache = @{}
function Initialize-FpsInk {
    $hi = -1; $lo = 99999
    for ($i = 1; $i -lt 256; $i++) {
        $v = [int]$pal[$i*3] + [int]$pal[$i*3 + 1] + [int]$pal[$i*3 + 2]
        if ($v -gt $hi) { $hi = $v; $script:fpsInk = [byte]$i }
        if ($v -lt $lo) { $lo = $v; $script:fpsPaper = [byte]$i }
    }
}
function New-FpsStrip([int]$value) {
    $txt = [string]([Math]::Max(0, [Math]::Min(999, $value)))
    $cw = 5 * $FPS_SCALE; $gap = $FPS_SCALE
    $sw = $FPS_PAD * 2 + $txt.Length * $cw + ($txt.Length - 1) * $gap
    $sh = $FPS_PAD * 2 + 7 * $FPS_SCALE
    $b = New-Object byte[] ($sw * $sh)
    for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = $script:fpsPaper }
    for ($c = 0; $c -lt $txt.Length; $c++) {
        $g = $FPS_FONT[[string]$txt[$c]]; $x0 = $FPS_PAD + $c * ($cw + $gap)
        for ($gy = 0; $gy -lt 7; $gy++) { for ($gx = 0; $gx -lt 5; $gx++) {
            if ($g[$gy][$gx] -ne '1') { continue }
            for ($sy = 0; $sy -lt $FPS_SCALE; $sy++) {
                $row = ($FPS_PAD + $gy * $FPS_SCALE + $sy) * $sw + $x0 + $gx * $FPS_SCALE
                for ($sx = 0; $sx -lt $FPS_SCALE; $sx++) { $b[$row + $sx] = $script:fpsInk }
            }
        } }
    }
    return [pscustomobject]@{ W = $sw; H = $sh; Bytes = $b }
}
function Add-FpsCounter([byte[]]$color, [int]$delivered) {
    if (-not $script:fpsDispClock) { $script:fpsDispClock = [Diagnostics.Stopwatch]::StartNew(); $script:fpsDispBase = $delivered; Initialize-FpsInk }
    if ($script:fpsDispClock.ElapsedMilliseconds -ge 500) {
        $rate = [int][Math]::Round(($delivered - $script:fpsDispBase) / $script:fpsDispClock.Elapsed.TotalSeconds)
        $script:fpsDispBase = $delivered; $script:fpsDispClock.Restart()
        if ($rate -ne $script:fpsShown) {
            # Cached per value: building a strip is tens of ms of PowerShell, a visible hitch
            # if paid on every change, and the rate only ever visits a few dozen values.
            if (-not $script:fpsCache.ContainsKey($rate)) { $script:fpsCache[$rate] = New-FpsStrip $rate }
            $script:fpsShown = $rate; $script:fpsStrip = $script:fpsCache[$rate]
        }
    }
    $s = $script:fpsStrip; if (-not $s) { return }
    $tr = $script:tcRaster
    $fw = $(if ($tr) { [int]$tr.W } else { $W })       # the picture's own width: not the game's, in true colour
    # (in true colour the picture wears a visor band along the top: the counter sits below it)
    $x0 = $fw - 16 - $s.W; $y0 = $(if ($tr -and $tr.Rgb) { [int]([int]$tr.H * 0.11) } else { 16 })
    for ($y = 0; $y -lt $s.H; $y++) { [Buffer]::BlockCopy($s.Bytes, $y * $s.W, $color, ($y0 + $y) * $fw + $x0, $s.W) }
    if ($script:gpuFrame -and $script:gpu -and $script:tcPal32) { $script:gpu.Stamp($s.Bytes, $s.W, $s.H, $x0, $y0, $script:tcPal32) }      # the picture is on the card
    elseif ($tr -and $tr.Rgb -and $tr.Color32 -and $script:tcPal32) { [AztTool.Overlay]::StampPal($tr.Color32, $fw, $s.Bytes, $s.W, $s.H, $x0, $y0, $script:tcPal32) }
}

function F32Bits([double]$v) { [BitConverter]::ToUInt32([BitConverter]::GetBytes([single]$v), 0) }
function Enable-HostFps {
    if ($KeepCap -or -not $capLin -or -not $S_delta2 -or $script:fpsOn) { return }
    $script:rapD2 = RdU32 (HostLin $S_delta2)
    $script:fpsCapWas = $hv.ReadU32((HostLin $capLin))
    foreach ($a in $MOVE_PER_SEC.Keys) { $script:fpsMoveWas[$a] = $hv.ReadU32((GuestObj2 ([uint32]$a))) }
    # Refuse rather than guess: these must be the build's 24 fps steps (12.14 and 6.07).
    $run = [BitConverter]::ToSingle([BitConverter]::GetBytes([uint32]$script:fpsMoveWas[0x141800]), 0)
    if ($run -lt 4 -or $run -gt 20 -or $script:fpsCapWas -lt 8000 -or $script:fpsCapWas -gt 200000) {
        Say ("frame cap left alone: run step reads {0:N3} and the cap {1} us, neither looks like this build" -f $run, $script:fpsCapWas) Yellow
        return
    }
    # Snap to the guest clock's own tick. The PIT divisor the game last programmed is the
    # word at obj2 0x14866E (0 means 65536); the timer service converts at 1.193182 ticks
    # per microsecond. Half a tick under the target, so the compare cannot land on the edge.
    $want = $(if ($Fps -gt 0) { 1000000.0 / $Fps } else { 0.0 })
    $div = ($hv.ReadU32((GuestObj2 0x14866E))) -band 0xFFFF; if ($div -eq 0) { $div = 65536 }
    $tick = $div / 1.193182
    $script:fpsMax = [double]$Fps
    if ($Fps -eq 0) {
        $period = 0; $script:fpsMax = 1000.0
        Say ("frame cap REMOVED while the host renders (guest clock tick {0:N2} ms); movement follows the measured rate" -f ($tick / 1000)) Green
    } elseif ($tick -ge 200 -and $tick -le 30000) {
        $steps = [Math]::Max(1, [Math]::Floor(($want + 1) / $tick))
        $period = $steps * $tick - $tick / 2
        $script:fpsMax = 1000000.0 / ($steps * $tick)
        Say ("guest clock ticks every {0:N2} ms: asked for {1} fps, the reachable rate at or above it is {2:N1} ({3} ticks a frame)" -f ($tick / 1000), $Fps, $script:fpsMax, $steps) Green
    } else {
        $period = $want
        Say ("guest clock tick reads {0:N0} us, which is not believable -- using the plain {1} fps period" -f $tick, $Fps) Yellow
    }
    # THE STEP GOES DOWN BEFORE THE CAP COMES OFF. The other order -- which this was -- leaves
    # the build's 24 fps step (12 units a frame) in place while the loop is already running
    # at several hundred frames a second, until the first measurement a quarter of a second
    # later: sixteen times walking speed, in steps big enough to pass through a wall or a
    # floor. It happened on every takeover, and -CaptureRef takes over every few seconds;
    # that is how the player fell out of the room. Start from the rate last measured (or a
    # deliberately high guess): starting too SLOW for a quarter second is harmless.
    $script:fpsRate = [Math]::Max(60.0, [Math]::Min($script:fpsMax, $script:fpsLastRate))
    foreach ($a in $MOVE_PER_SEC.Keys) { [void]$hv.WriteU32((GuestObj2 ([uint32]$a)), (F32Bits ($MOVE_PER_SEC[$a] / $script:fpsRate * $script:crouchK))) }
    [void]$hv.WriteU32((HostLin $capLin), [uint32][Math]::Round($period))
    $script:fpsOn = $true; $script:fpsClock = [Diagnostics.Stopwatch]::StartNew()
    $script:fpsFrame0 = $(if ($S_frameNo) { RdU32 (HostLin $S_frameNo) } else { [uint32]0 })
    if ($Fps -gt 0) { Say ("frame cap {0:N1} -> {1:N1} fps while the host renders; movement step follows the measured rate" -f (1000000.0 / $script:fpsCapWas), $script:fpsMax) Green }
}
function Update-HostFps {
    if (-not $script:fpsOn -or -not $S_frameNo -or $script:fpsClock.ElapsedMilliseconds -lt 250) { return }
    $now = RdU32 (HostLin $S_frameNo)
    $inst = ([long]$now - [long]$script:fpsFrame0) / $script:fpsClock.Elapsed.TotalSeconds
    $script:fpsFrame0 = $now; $script:fpsClock.Restart()
    if ($inst -lt 1) { return }                       # a load or a menu: keep the last good step
    $inst = [Math]::Max(10.0, [Math]::Min($script:fpsMax, $inst))
    $script:fpsRate = 0.5 * $script:fpsRate + 0.5 * $inst
    $script:fpsLastRate = $script:fpsRate
    foreach ($a in $MOVE_PER_SEC.Keys) { [void]$hv.WriteU32((GuestObj2 ([uint32]$a)), (F32Bits ($MOVE_PER_SEC[$a] / $script:fpsRate * $script:crouchK))) }
}
# THE STEP NOW, crouch included: the measured-rate step while the host has the cap off, else the game's own step (the build's,
# kept from before the cap came off -- or read on attach when it never did) x crouchK. (The first crouch wrote ITS copy of the
# step every frame of a transition -- the build's 24 fps step at several hundred fps: a sprint. Josh: "I will zoom in".)
function Set-MoveSteps {
    if (-not $hv) { return }
    foreach ($a in $MOVE_PER_SEC.Keys) {
        if ($script:fpsOn) { $s = $MOVE_PER_SEC[$a] / $script:fpsRate }
        elseif ($script:fpsMoveWas.ContainsKey($a)) { $s = [BitConverter]::ToSingle([BitConverter]::GetBytes([uint32]$script:fpsMoveWas[$a]), 0) }
        elseif ($script:crouchBase) { $s = $(if ($a -eq 0x141800) { $script:crouchBase.Run } else { $script:crouchBase.Walk }) }
        else { continue }
        [void]$hv.WriteU32((GuestObj2 ([uint32]$a)), (F32Bits ($s * $script:crouchK)))
    }
}
function Disable-HostFps {
    if (-not $script:fpsOn) { return }
    $script:fpsOn = $false
    try {
        [void]$hv.WriteU32((HostLin $capLin), $script:fpsCapWas)
        foreach ($a in $MOVE_PER_SEC.Keys) { [void]$hv.WriteU32((GuestObj2 ([uint32]$a)), [uint32]$script:fpsMoveWas[$a]) }
    } catch { }
}

function Restore-Viewport {
    if (-not $hv) { return }
    Disable-HostFps
    try { foreach ($s in @($S_ready, $S_enable, $S_sup3D, $S_parts, $S_sync)) { [void]$hv.WriteU32((HostLin $s), 0) } } catch { }
    if ($script:capWas) { try { [void]$hv.WriteU32((HostLin $capLin), $script:capWas); $script:capWas = 0 } catch { } }
}

# THE INVARIANT: the engine's rasteriser is off ONLY while the host is pushing frames.
# Called with $false on every path that skips a push, so a stall shows the game's own view
# rather than a black screen the player cannot navigate out of.
#
# ORDER MATTERS in both directions. Taking over, injection is armed BEFORE the engine stops,
# so no frame has neither. Releasing, the engine restarts BEFORE injection is disarmed, for
# the same reason.
# NOTHING TO DRAW THIS FRAME: ride out a blink (skip the frame, the window keeps the last
# picture and the game keeps getting the key), hand the viewport back only if it lasts.
# ---- THE ROOM'S LOADING COVER (tools\RoomCover.cs; Josh, 2026-10-12: "When entering a room, I will see the 256 color version
# of the game ... for a good while as the textures load ... a simple in world loading display on the viewport, top center ...
# 'Raptor H.U.D - Analyzing Environment...' with a loading number counting up to 100% as the room loads. The key is we
# shouldnt see the 256 version"). On a room change the viewport goes to the game for its own first frames of the new room (the
# engine-draw pulse below), then the room is recognised, its textures decoded and sent to the card -- seconds of 8-bit picture
# on a first entry of a 4K room. Now, from the moment the jump is seen, the card's window shows this cover instead (held fresh,
# so it never hides), presented ~35 times a second from wherever the watcher is: the pulse, the decoding (-Progress of
# Add-AztRgb), the upload. The game draws on underneath, hidden. Its percentage: the pulse to 12, recognised 14, the textures
# decoded to 70, on the card to 98, then 100 and the room's first frame.
function Start-RoomCover([string]$why) {
    if ($NoRoomCover -or $script:roomCover -or -not $script:gpu -or -not $script:ov -or -not $script:ov.GlPresent -or -not $script:tcRaster) { return }
    if (Test-LoadUi) { return }      # (a game being loaded or booted: its own panel / the visor boot covers the room -- Set-LoadProgress)
    if (-not $script:roomCoverPainter) { $script:roomCoverPainter = New-Object AztTool.RoomCover }
    $script:roomCoverPainter.Reset()
    $script:roomCover = [pscustomobject]@{ Clock = [Diagnostics.Stopwatch]::StartNew(); Target = 0.02; Stage = 'pulse'; Why = $why; LastShow = -1.0; Shows = 0; WaitFrom = 0.0; Hold = 0L; NothingSince = $null; Loaded = $false; SettleFrom = 0.0 }
    $script:rgbProgress = { param($d, $t) Set-RoomCoverTarget (0.15 + 0.55 * $d / [Math]::Max(1, $t)) 'textures' }
    Show-RoomCover -Force
}
function Set-RoomCoverTarget([double]$v, [string]$stage) {
    $c = $script:roomCover; if (-not $c) { return }
    if ($v -gt $c.Target) { $c.Target = [Math]::Min(1.0, $v) }
    if ($stage) { $c.Stage = $stage }
    Show-RoomCover
}
function Show-RoomCover([switch]$Force) {
    $c = $script:roomCover; if (-not $c) { return }
    $t = $c.Clock.Elapsed.TotalSeconds
    if (-not $Force -and ($t - $c.LastShow) -lt 0.028) { return }      # (~35 a second)
    $c.LastShow = $t
    $gq = $script:gpu; $o = $script:ov; $tr = $script:tcRaster
    if (-not $gq -or -not $o -or -not $tr -or -not $o.GlPresent) { Stop-RoomCover 'the card no longer presents'; return }
    try {
        $pw = [int]$tr.W; $ph = [int]$tr.H
        $pic = $script:roomCoverPainter.Render($pw, $ph, $o.ViewRowsOf($ph), $t, $c.Target)
        $c.Hold = [Diagnostics.Stopwatch]::GetTimestamp() + [Diagnostics.Stopwatch]::Frequency; $o.HoldFreshUntil = $c.Hold      # (a second ahead: it never hides)
        if ($gq.PresentPicture($pic, $pw, $ph)) { $o.NoteGlFrame(); $c.Shows++ }
    } catch { Say ("room cover failed: {0} -- off for this room" -f $_.Exception.Message) Yellow; $script:roomCover = $null; $script:rgbProgress = $null }
}
# AFTER A LOAD, THE LOADING PANEL GOES FIRST (Josh, 2026-10-13: "the game is still loading in the background of the load screen,
# so I dont see the wireframe effect after loading a game ... I never see the UI spanning in from the left/right because it's
# always happening in the background behind the loading screen"): from a load's start (a title load's pick, the memory core's
# reading) until the title's window and the memory core's panel are both gone (and the re-boot no longer covers), the HUD is
# held back and the room's materialize waits; then the HUD slides in (its sound) and the room materializes, in view.
# THE LOAD WAITS FOR A STEADY VIEW (Josh, 2026-10-13: "the game starts, hidden, behind the loading screen, and when it hands
# off to the viewport the visor animation is complete already, and the new wireframe animation is choppy. It should load the
# game and the textures all together, not displaying any of the game until all loading is complete"). MEASURED (watch.log
# 09:06:58): the title was told the view was back on the renderer's FIRST frame -- the same second as the true colour
# search, the 24 scanner wireframes and the panel's first build, frames at ~38 ms -- and the boot thread had let the HUD go
# the moment the game reached play, behind the title. Now, while a load's panel is up: the HUD is held (BootHd.HudWait), the
# room is dark glass (GpuRaster.MatHold: a panel fading out shows nothing of the game), and the panel is told the view is
# back (the title's TitleLoadShown, the memory core's FinishReading) only once the frames are steady: the last
# LoadSteadyFrames each within 1.5x their median + 4 ms, at least 0.6 s after the view came up (12 s at most).
$script:viewUpAt = $null; $script:loadFrameAt = $null; $script:loadFrames = $null; $script:titleShowDue = $false; $script:loadSteadySaid = $false
$LoadSteadyFrames = 12
function Set-LoadViewUp { if (-not $script:viewUpAt) { $script:viewUpAt = [Diagnostics.Stopwatch]::StartNew(); $script:loadFrameAt = $null; $script:loadFrames = New-Object 'System.Collections.Generic.List[double]' } }
function Test-LoadViewSteady {
    if (-not $script:viewUpAt) { return $false }
    $age = $script:viewUpAt.Elapsed.TotalSeconds; $f = $script:loadFrames; $nf = $LoadSteadyFrames
    $ok = $false; $med = 0.0
    if ($age -ge 0.6 -and $f.Count -ge $nf) {
        $last = $f.GetRange($f.Count - $nf, $nf).ToArray(); [Array]::Sort($last); $med = $last[[int]($nf / 2)]
        $ok = $last[$nf - 1] -le 1.5 * $med + 4
    }
    if (-not $ok -and $age -gt 12) { $ok = $true; if (-not $script:loadSteadySaid) { Say ("load: the frames never settled in 12 s ({0} drawn) -- the loading panel lets go anyway" -f $f.Count) DarkYellow } }
    elseif ($ok -and -not $script:loadSteadySaid) { Say ("load: the view is steady ({0} frames of ~{1:N0} ms, {2:N1} s after it came up) -- the loading panel lets go" -f $nf, $med, $age) DarkCyan }
    if ($ok -and -not $script:loadSteadySaid) { [AztTool.AudioMeter]::Mark("the view is steady: the title is told the view is back (its loading screen finishes, then fades)") }
    if ($ok) { $script:loadSteadySaid = $true }
    return $ok
}
function Complete-TitleLoad {
    if ($script:gate) { $script:gate.TitleLoadShown(); $script:gate.PickedSlot = -1 }
    $script:titleReadAt = $null; $script:titleReadSeen = $false; $script:titleShowDue = $false
}
function Request-TitleLoadShown { Set-LoadViewUp; $script:titleShowDue = $true }
# THE LOADING SEQUENCE IS SILENT (Josh, 2026-10-15: the HUD's slide sound kept playing under the loading screen -- "Lets try
# disabling all audio for the loading sequence"): from a load's start until the panel actually slides in (Panel.Slides
# goes up), every host sound (BootSound.Silence: the boot's mixer, footsteps, the echo...), the loading screen's voice and
# track (LoadingAudio.Silence) and DOSBox's own sound (AztTool.AppMute: Windows' per-app mute -- never a pause) are off.
# 10 s after the load's panel has gone with no slide, or 90 s in all, it ends anyway. The log says what tried to play.
$script:loadSilent = $false; $script:loadSilentAt = $null; $script:loadSilentSlides = 0; $script:loadSilentEndAt = $null
function Set-LoadSilence([bool]$on, [string]$why) {
    if ($on -eq $script:loadSilent) { return }
    $script:loadSilent = $on
    [AztTool.BootSound]::Silence = ($on -and $LoadSilence)      # (our own sounds: only with the -LoadSilence diagnostic)
    [AztTool.AudioMeter]::Mark($(if ($on) { "a LOAD began: host sounds + DOSBox silenced (the loading voice/track play on)" } else { "load silence lifted ($why)" }))
    # (the loading screen's own voice and track stay ON -- Josh wants them; the ratchet was the GAME's hud3.wav: LoadingAudio.Silence is left for a test)
    $dm = '(left on: -NoLoadGameMute)'; if (-not $NoLoadGameMute -or -not $on) { try { $dm = [AztTool.AppMute]::Set([int]$g.ProcessId, $on) } catch { $dm = $_.Exception.Message } }
    if ($on) {
        [AztTool.BootSound]::SilencedN = 0; [AztTool.BootSound]::SilencedWhat = ''
        $script:loadSilentAt = [Diagnostics.Stopwatch]::StartNew(); $script:loadSilentEndAt = $null
        $script:loadSilentSlides = $(if ($script:panel) { [long]$script:panel.Slides } else { 0 })
        Say ("load audio: the GAME's own sound (DOSBox: {0}) is muted until the HUD slides in -- its menu and HUD sounds play during a title load; the loading voice and track play on{1}" -f $dm, $(if ($LoadSilence) { '; our own sounds silent too (-LoadSilence)' } else { '' })) DarkCyan
    } else {
        Say ("load audio: back on after {0:N1} s ({1}; DOSBox {2}) -- {3} host sound(s) asked to play while silent{4}" -f $script:loadSilentAt.Elapsed.TotalSeconds, $why, $dm, [AztTool.BootSound]::SilencedN, $(if ([AztTool.BootSound]::SilencedN) { ': ' + [AztTool.BootSound]::SilencedWhat } else { '' })) DarkCyan
        $script:loadSilentAt = $null
    }
}
# THE AUDIO METER (BootHd.cs AudioMeter; 2026-10-15, the ratchet hunt): from the title menu / a load, 60 s of every program's
# sound level on the default output, with our own steps marked on its clock, into this log. Read-only. OFF unless -AudioMeter.
$script:meterStarted = $false
function Step-AudioMeter {
    if (-not $AudioMeter) { return }
    $titleUp = $script:gate -and $script:gate.TitleShowing
    if (-not [AztTool.AudioMeter]::Running -and -not $script:meterStarted -and ($titleUp -or $script:loadSilent)) {
        $script:meterStarted = $true; [AztTool.AudioMeter]::Start(60, $(if ($script:loadSilent) { 'a load' } else { 'the title menu is up' }))
    }
    try { $ct = [AztTool.TitleScreen]::LoadClickTicks; if ($ct -gt 0 -and $ct -ne $script:clickMarked) { $script:clickMarked = $ct; [AztTool.AudioMeter]::MarkAt($ct, "LOAD / CONTINUE CLICKED on the title (the loading box starts to expand)") } } catch { }
    for ($k = 0; $k -lt 60; $k++) { $ml = [AztTool.AudioMeter]::Take(); if (-not $ml) { break }; Say $ml DarkGray }
}
function Step-LoadSilence {
    Step-AudioMeter
    if (-not $script:loadSilent) { return }
    $slid = $script:panel -and [long]$script:panel.Slides -gt $script:loadSilentSlides
    if ($slid) { Set-LoadSilence $false 'the panel slid in'; return }
    if (-not $script:loadGuard) { if (-not $script:loadSilentEndAt) { $script:loadSilentEndAt = [Diagnostics.Stopwatch]::StartNew() } elseif ($script:loadSilentEndAt.Elapsed.TotalSeconds -gt 10) { Set-LoadSilence $false 'no slide 10 s after the loading panel went' ; return } }
    if ($script:loadSilentAt.Elapsed.TotalSeconds -gt 90) { Set-LoadSilence $false '90 s cap' }
}
function Step-LoadGuard {
    Step-LoadSilence
    $ldNow = ($script:gate -and $script:gate.PickedSlot -ge 0) -or ($script:visorMenu -and $script:visorMenu.ReadWait)
    if ($ldNow -and ($LoadSilence -or -not $NoLoadGameMute)) { Set-LoadSilence $true '' }      # (the GAME muted for a load: its own menu/HUD sounds play under the loading screen; -LoadSilence also silences ours)
    if ($ldNow -and -not $script:loadGuard) {
        $script:loadGuard = $true; $script:loadGuardAt = [Diagnostics.Stopwatch]::StartNew(); $script:viewUpAt = $null; $script:titleShowDue = $false; $script:loadSteadySaid = $false
        Say 'load: the HUD and the materialize wait until the loading panel is gone; the room stays dark until the view is steady' DarkCyan
    }
    if (-not $script:loadGuard) { return }
    if ($script:gpu -and -not $NoMaterialize) { $script:gpu.MatHold = $true }
    if ($script:bootHd) { $script:bootHd.HudWait = $true }
    # (the frames' pace since the view came up)
    if ($script:viewUpAt) { if ($script:loadFrameAt) { $script:loadFrames.Add($script:loadFrameAt.Elapsed.TotalMilliseconds); $script:loadFrameAt.Restart() } else { $script:loadFrameAt = [Diagnostics.Stopwatch]::StartNew() } }
    if ($script:titleShowDue -and (Test-LoadViewSteady)) { Complete-TitleLoad }
    $panelUp = $ldNow -or ($script:gate -and $script:gate.TitleShowing) -or ($script:visorMenu -and $script:visorMenu.AnyPlaying) -or ($script:bootHd -and $script:bootHd.Covering)
    # (a safety net: a panel that never says it has gone must not keep the HUD away for good)
    if ($panelUp -and $script:loadGuardAt -and $script:loadGuardAt.Elapsed.TotalSeconds -gt 45) { Say 'load: still a loading panel after 45 s -- the HUD comes in anyway' DarkYellow; $panelUp = $false }
    if ($panelUp) { if ($script:panel) { $script:panel.HoldOff = $true }; $script:matPending = $null; return }
    $script:loadGuard = $false; $script:loadGuardAt = $null; $script:viewUpAt = $null; $script:loadFrameAt = $null; $script:titleShowDue = $false
    [AztTool.AudioMeter]::Mark("the loading panel is gone: the HUD is let in (HudIn)")
    if ($script:bootHd) { $script:bootHd.HudIn() } elseif ($script:panel) { $script:panel.HoldOff = $false }
    # (the room's dark glass holds until the sweep starts, on the next frame: StartMaterialize lets it go)
    if ($NoMaterialize -and $script:gpu) { $script:gpu.MatHold = $false }
    $script:matPending = 'the loaded game is in view (its loading panel gone)'
}
# ---- THE FIELD OF VIEW (see -Fov): every loop the host writes tan(v/2) for the overlay's AztFovTick (a data word; 0 in
# -Retro = the game's own field), F12 cycles 50/60/70, and every 2 s the game's viewport is read back: its own field as
# the game will draw and pick with it (Reality Lab applies it to the viewport's longer side: x max(1, w*sx / h*sy), as
# 0x59404 does). In -Retro the host follows that live value.
$script:fovAt = $null; $script:fovSeen = $false; $script:fovMiss = 0; $script:fovKeyWas = $false
function Set-HostFov([double]$v) {
    $script:Fov = $v
    if ($r) { $r.SetVerticalFov($v) }
    if ($script:gpu) { $script:gpu.SetVerticalFov($v) }
    if ($rs) { $rs.SetVerticalFov($v + 8) }; if ($rs2) { $rs2.SetVerticalFov($v + 8) }      # (the lamp sees a little past the view)
}
function Get-GameFov {
    if (-not $S_delta2) { return $null }
    $script:rapD2 = RdU32 (HostLin $S_delta2)
    $h = RdU32 (GuestObj2 0x152138); if (-not $h) { return $null }
    $o = Resolve-RlHandle $h; if (-not $o) { return $null }
    $b = [AztTool.ProcMem]::Read($g.ProcessId, (GuestPtr $o), 0x100); if (-not $b) { return $null }
    $field = [BitConverter]::ToSingle($b, 0xFC); $w = [BitConverter]::ToInt32($b, 0x3C); $hh = [BitConverter]::ToInt32($b, 0x40); $dev = [BitConverter]::ToUInt32($b, 0x2C)
    if ($field -le 0 -or $w -le 0 -or $hh -le 0 -or $dev -lt 0x1000) { return $null }
    $d = [AztTool.ProcMem]::Read($g.ProcessId, (GuestPtr ($dev + 0x160)), 8); if (-not $d) { return $null }
    $sx = [BitConverter]::ToInt32($d, 0); $sy = [BitConverter]::ToInt32($d, 4); if ($sx -le 0 -or $sy -le 0) { return $null }
    $a = ($w * [double]$sx) / ($hh * [double]$sy)
    return 2 * [Math]::Atan($(if ($a -gt 1) { $field / $a } else { $field })) * 180 / [Math]::PI
}
function Step-Fov {
    if (-not $S_fovTan -or -not $hv) { return }
    if ($FovKey -gt 0 -and $script:fovGame) {
        $k = $false; try { $k = [AztTool.Keys]::DownInProcess($FovKey, $g.ProcessId) } catch { }
        if ($k -and -not $script:fovKeyWas) {
            $nv = $(if ($script:Fov -lt 55) { 60 } elseif ($script:Fov -lt 62.5) { 65 } elseif ($script:Fov -lt 67.5) { 70 } else { 50 })
            Set-HostFov $nv; $script:fovSeen = $false; $script:fovMiss = 0; $script:fovAt = $null
            Say ("field of view: {0} degrees (F12: 50 / 60 / 65 / 70)" -f $nv) Cyan; Show-ToggleNote ('FIELD OF VIEW: {0} DEG' -f $nv)
        }
        $script:fovKeyWas = $k
    }
    $tan = $(if ($script:fovGame) { [Math]::Tan($script:Fov * [Math]::PI / 360) } else { 0.0 })
    $fbits = [BitConverter]::ToUInt32([BitConverter]::GetBytes([single]$tan), 0)
    if ($fbits -ne $script:fovBits -or -not $script:fovWr -or $script:fovWr.ElapsedMilliseconds -ge 500) {      # (2026-10-13 audit: not every frame)
        try { [void]$hv.WriteU32((HostLin $S_fovTan), $fbits) } catch { }
        $script:fovBits = $fbits; if ($script:fovWr) { $script:fovWr.Restart() } else { $script:fovWr = [Diagnostics.Stopwatch]::StartNew() }
    }
    if ($script:fovAt -and $script:fovAt.Elapsed.TotalSeconds -lt 2) { return }
    if ($script:fovAt) { $script:fovAt.Restart() } else { $script:fovAt = [Diagnostics.Stopwatch]::StartNew() }
    $gv = $null; try { $gv = Get-GameFov } catch { }
    if ($null -eq $gv) { return }
    if (-not $script:fovGame) {
        if ([Math]::Abs($gv - $script:Fov) -gt 0.3) { Set-HostFov ([Math]::Round($gv, 2)); Say ("field of view: following the game's own {0:N1} degrees" -f $gv) DarkCyan }
        return
    }
    if ([Math]::Abs($gv - $script:Fov) -le 0.3) {
        if (-not $script:fovSeen) { $script:fovSeen = $true; $sets = 0; try { $sets = $hv.ReadU32((HostLin (Sym 'aztFovSets'))) } catch { }; Say ("field of view: the game draws and picks at {0:N1} degrees, as the host draws ({1} viewport(s) set so far)" -f $gv, $sets) DarkCyan }
        $script:fovMiss = 0
    } elseif (++$script:fovMiss -eq 2) { Say ("field of view: the game's viewport is still at {0:N1} degrees, the host at {1} -- the overlay has not applied it" -f $gv, $script:Fov) Yellow }
}
# ---- NPC PACE, PER ROOM (Josh, 2026-10-13: the two creatures in CORICORI "slowed a total of 20% ... pause every once in a
# while, rather than constantly running around ... an easier chance to scan them"). Every character already runs at the
# build's NPC_RATE_PCT (90%: the overlay's AztActorGate / AztNpcStride). A room's "npcs" block names characters (the
# game's actor names, e.g. "EUGENE") with:
#   "speed": a share of the ORIGINAL pace (0.8 = 20% slower in all); the overlay's per-character share is speed / 0.9;
#   "pauseEvery": [min, max] seconds between pauses (none = never pauses);
#   "pauseAnim": the state to pause in -- one the character's .ANI has a range for: "SNIFF" (EUGENE/EUGENB, added at
#   install by Apply-AztMod: frames 11-52 of EUGBLD.XAF, a sniff and look-round already in the model), "REST", "ROAR"...;
#   "pauseSpeed": the pace while paused (default = speed) -- the clip plays at it (Josh, 2026-10-13: the run another 20%
#   slower, "the sniff and pause animation is perfect" as it was);
#   "pauseFrames": how long, in that clip's frames at the pause's pace (41 = one sniff), else "pauseFor": [min,
#   max] seconds. The run starts again from the overlay (AztNpcHold) when the host lets go.
# The host finds them in the game's character table (0x1521C4: 0x6F buckets at +2, nodes {+0 next, +4 name, +8 character})
# and writes the overlay's aztNpcTab (4 x 12 bytes: {dd character, db pct, db strideAcc, db aiAcc, db hold, db pauseState}); a pause is the hold
# byte: bit 0 = pause, set and cleared by the host; bit 7 = paused, set by AztNpcHold (RUN -> the pause state), which also
# sets RUN again once bit 0 is clear. (The first version paused into REST and left the restart to the game's WANDER rule
# -- EUGENE.ANI has no WANDER, so they stood for good: "the creatures in that room are now frozen in place".)
$script:npcStates = @{ REST = 1; WALK = 2; SLEEP = 3; START_RUN = 4; RUN = 5; END_RUN = 6; PICKUP = 7; DROP = 8; ROAR = 9; SNIFF = 10; AWAKE = 11; FACE_YOU = 20 }
$script:npcRoom = $null; $script:npcRules = $null; $script:npcAt = $null; $script:npcState = @{}; $script:npcSaid = @{}
$script:npcRnd = New-Object Random
function Get-NpcChars {
    # name -> character pointer (the game's own values), from the character table
    $res = @{}
    $b = [AztTool.ProcMem]::Read($g.ProcessId, (GuestObj2 0x1521C4), 2 + 4 * 0x6F); if (-not $b) { return $res }
    for ($i = 0; $i -lt 0x6F; $i++) {
        $node = [BitConverter]::ToUInt32($b, 2 + 4 * $i)
        for ($k = 0; $k -lt 64 -and $node -ge 0x1000; $k++) {
            $nb = [AztTool.ProcMem]::Read($g.ProcessId, (GuestPtr $node), 12); if (-not $nb) { break }
            $np = [BitConverter]::ToUInt32($nb, 4); $ch = [BitConverter]::ToUInt32($nb, 8)
            if ($np -ge 0x1000 -and $ch -ge 0x1000) {
                $sb = [AztTool.ProcMem]::Read($g.ProcessId, (GuestPtr $np), 16)
                if ($sb) { $z = [Array]::IndexOf($sb, [byte]0); if ($z -gt 0) { $res[[Text.Encoding]::ASCII.GetString($sb, 0, $z).ToUpperInvariant()] = $ch } }
            }
            $node = [BitConverter]::ToUInt32($nb, 0)
        }
    }
    return $res
}
function Write-NpcEntry([int]$slot, [uint32]$ch, [int]$pct, [int]$state) {
    $at = (HostLin (Sym 'aztNpcTab')) + 12 * $slot
    $e = [byte[]]@(0, 0, 0, 0, [byte]$pct, 0, 0, 0, [byte]$state, 0, 0, 0); [BitConverter]::GetBytes($ch).CopyTo($e, 0)
    [void][AztTool.ProcMem]::Write($g.ProcessId, $at, $e)
}
function Step-NpcPace {
    if (-not $symMap.ContainsKey('aztNpcTab') -or -not $S_delta2) { return }
    if ($script:npcTick -and $script:npcTick.ElapsedMilliseconds -lt 100) { return }      # (10 Hz: 2026-10-13 performance audit)
    if ($script:npcTick) { $script:npcTick.Restart() } else { $script:npcTick = [Diagnostics.Stopwatch]::StartNew() }
    $room = [string]$script:rapRoom
    if ($room -ne $script:npcRoom) {
        $script:npcRoom = $room; $script:npcRules = $null; $script:npcState = @{}; $script:npcAt = $null
        try { [void][AztTool.ProcMem]::Write($g.ProcessId, (HostLin (Sym 'aztNpcTab')), (New-Object byte[] 48)) } catch { }
        try {
            $own = Join-Path $RoomsDir ("{0}.json" -f ($room -split '\+')[0])
            if ($room -and (Test-Path $own)) { $o = Get-Content $own -Raw | ConvertFrom-Json; if ($o.PSObject.Properties['npcs']) { $script:npcRules = $o.npcs } }
        } catch { Say ("npcs: {0}.json could not be read ({1})" -f $room, $_.Exception.Message) Yellow }
    }
    if (-not $script:npcRules) { return }
    $now = [Diagnostics.Stopwatch]::GetTimestamp() / [double][Diagnostics.Stopwatch]::Frequency
    # every half second: who is here (characters come and go with scripts), and their entries
    if (-not $script:npcAt -or $script:npcAt.Elapsed.TotalSeconds -ge 0.5) {
        if ($script:npcAt) { $script:npcAt.Restart() } else { $script:npcAt = [Diagnostics.Stopwatch]::StartNew() }
        $script:rapD2 = RdU32 (HostLin $S_delta2)
        $chars = $null; try { $chars = Get-NpcChars } catch { return }
        $rate = 90.0; try { $rate = [double]($hv.ReadU32((HostLin (Sym 'aztNpcPct'))) -band 0xFFFF) } catch { }
        if ($rate -le 0) { $rate = 90.0 }
        $slot = 0; $seen = @{}
        foreach ($p in $script:npcRules.PSObject.Properties) {
            if ($p.Name.StartsWith('_') -or -not $chars.ContainsKey($p.Name.ToUpperInvariant())) { continue }
            if ($slot -ge 4) { break }
            $ch = [uint32]$chars[$p.Name.ToUpperInvariant()]; $rule = $p.Value; $seen[$ch] = 1
            $speed = $(if ($null -ne $rule.speed) { [double]$rule.speed } else { $rate / 100.0 })
            $pct = [int][Math]::Max(10, [Math]::Min(100, [Math]::Round($speed * 10000.0 / $rate)))
            $ps = 1; if ($rule.pauseAnim -and $script:npcStates.ContainsKey(([string]$rule.pauseAnim).ToUpperInvariant())) { $ps = $script:npcStates[([string]$rule.pauseAnim).ToUpperInvariant()] }
            # one pause in the clip's own frames: the stride steps at 18.2 Hz x the build's rate x this character's share
            $pspd = $(if ($null -ne $rule.pauseSpeed) { [double]$rule.pauseSpeed } else { $speed })
            $ppct = [int][Math]::Max(10, [Math]::Min(100, [Math]::Round($pspd * 10000.0 / $rate)))
            $hz = 18.2065 * ($rate / 100.0) * ($ppct / 100.0)      # (the clip's frame rate while paused)
            $st = $script:npcState[$ch]
            if (-not $st) {
                $st = @{ Slot = $slot; Pct = $pct; PausePct = $ppct; Hold = 0; Next = $now + (Get-NpcSpan $rule.pauseEvery 6 12); Until = 0.0; Name = $p.Name; State = $ps; Hz = $hz }
                $script:npcState[$ch] = $st
                try { Write-NpcEntry $slot $ch $pct $ps } catch { }
                if (-not $script:npcSaid[$p.Name + $room]) { $script:npcSaid[$p.Name + $room] = $true; Say ("npcs: {0} in {1} at {2:P0} of the original pace{3}" -f $p.Name, $room, $speed, $(if ($rule.pauseEvery) { ', pausing now and then' } else { '' })) DarkCyan }
            } elseif ($st.Slot -ne $slot -or $st.Pct -ne $pct) { $st.Slot = $slot; $st.Pct = $pct; $st.PausePct = $ppct; $st.Hz = $hz; $st.Hold = 0; try { Write-NpcEntry $slot $ch $pct $ps } catch { } }
            $slot++
        }
        foreach ($k in @($script:npcState.Keys)) { if (-not $seen.ContainsKey($k)) { $script:npcState.Remove($k) } }
        for ($s = $slot; $s -lt 4; $s++) { try { Write-NpcEntry $s 0 0 0 } catch { } }
    }
    # the pauses: each character on its own timer
    foreach ($ch in @($script:npcState.Keys)) {
        $st = $script:npcState[$ch]; $rule = $script:npcRules.($st.Name)
        if (-not $rule -or -not $rule.pauseEvery) { continue }
        $hb = (HostLin (Sym 'aztNpcTab')) + 12 * $st.Slot + 7
        if ($st.Hold -eq 0 -and $now -ge $st.Next) {
            $st.Hold = 1
            $st.Until = $now + $(if ($rule.pauseFrames -and $st.Hz -gt 0) { [double]$rule.pauseFrames / $st.Hz } else { Get-NpcSpan $rule.pauseFor 2 4 })
            try { [void][AztTool.ProcMem]::Write($g.ProcessId, $hb - 3, [byte[]]@([byte]$st.PausePct)); [void][AztTool.ProcMem]::Write($g.ProcessId, $hb, [byte[]]@(1)) } catch { }      # (the pause's own pace, then the pause)
        } elseif ($st.Hold -eq 1 -and $now -ge $st.Until) {
            $st.Hold = 0; $st.Next = $now + (Get-NpcSpan $rule.pauseEvery 6 12)
            # let go: bit 0 off, the overlay's bit 7 kept -- AztNpcHold sets the run again and clears it
            try { $cur = [AztTool.ProcMem]::Read($g.ProcessId, $hb, 1); [void][AztTool.ProcMem]::Write($g.ProcessId, $hb, [byte[]]@([byte]($cur[0] -band 0x80))); [void][AztTool.ProcMem]::Write($g.ProcessId, $hb - 3, [byte[]]@([byte]$st.Pct)) } catch { }      # (and its running pace back)
        }
    }
}
function Get-NpcSpan($pair, [double]$lo, [double]$hi) {
    if ($pair -and @($pair).Count -ge 2) { $lo = [double]@($pair)[0]; $hi = [double]@($pair)[1] } elseif ($pair) { $lo = [double]$pair; $hi = $lo }
    return $lo + ($hi - $lo) * $script:npcRnd.NextDouble()
}
function Stop-RoomCover([string]$how) {
    $c = $script:roomCover; if (-not $c) { return }
    if ($how -eq 'ready') {
        $script:matPending = 'the room is in (ANALYZING ENVIRONMENT 100%)'      # (the room's first real frame materializes it)
        # 100% shown before the room comes up (a quarter of a second at most)
        $c.Target = 1.0; $fin = [Diagnostics.Stopwatch]::StartNew()
        while ($script:roomCover -and $script:roomCoverPainter.Shown -lt 0.999 -and $fin.ElapsedMilliseconds -lt 250) { Show-RoomCover -Force; [Threading.Thread]::Sleep(16) }
    }
    # Ready: the 100% picture stays held until the room's first frame replaces it. Anything else (a movie, a menu, the same
    # room): the hold is let go, so whatever comes next is not hidden behind it (the visor menu's own hold is left alone).
    elseif ($script:ov -and $c.Hold -and $script:ov.HoldFreshUntil -eq $c.Hold) { $script:ov.HoldFreshUntil = 0 }
    Say ("  room cover: {0:N0} ms on screen, {1} pictures ({2}; {3})" -f $c.Clock.ElapsedMilliseconds, $c.Shows, $how, $c.Why) DarkCyan
    $script:roomCover = $null; $script:rgbProgress = $null
}
# ---- A GAME LOAD CARRIES ITS ROOM (Josh, 2026-10-12: "we need those textures to be loaded when loading a game as well, but that
# needs to be lumped into the core loading UI/animation as part of the loading process. Currently the game still shows the 256
# version when loading"). MEASURED on a load into MINEHEAD (watch.log 13:05:16): the reading panel and the re-boot's cover held
# while the room was recognised and its textures decoded, but the 48 4K textures went to the card in the room's FIRST FRAME --
# after the cover had let go -- and the card took 3.3 s over them with nothing new to show: the 8-bit picture. Now a load (the
# title's reading, the memory core's, or the visor boot) gets the same as a room change: textures decoded AND sent to the card
# AND finished on it before the first frame, with the loading panel's bar following them (VisorMenu / TitleScreen
# .LoadProgress: the archive is its first 30%, the room the rest) and the re-boot's cover kept up past HoldMaxMs while it works.
function Test-LoadUi {
    [bool](($script:gate -and $script:gate.PickedSlot -ge 0) -or ($script:visorMenu -and $script:visorMenu.ReadWait) -or ($script:bootHd -and $script:bootHd.Covering))
}
function Set-LoadProgress([double]$p) {
    $p = [Math]::Max(0.0, [Math]::Min(1.0, $p))
    if ($script:gate -and $script:gate.PickedSlot -ge 0) { try { $script:gate.TitleLoadProgress($p) } catch { } }
    if ($script:visorMenu -and $script:visorMenu.ReadWait) { $script:visorMenu.LoadProgress = [single]$p }
    if ($script:bootHd -and $script:bootHd.Covering) { $script:bootHd.HoldExtendUntil = [Diagnostics.Stopwatch]::GetTimestamp() + 3 * [Diagnostics.Stopwatch]::Frequency }
    Step-LoadRepaint
}
# THE LOAD'S PANEL KEEPS MOVING while the renderer works under it. In the GPU mode the card's window is the one on screen
# (Overlay.GlPresent), and the re-boot's own pictures (BootHd, its thread) go to the overlay's other window -- unseen; they
# only keep the card's window from going stale. So the memory core's reading panel was redrawn only by Repaint-HeldPicture
# between passes of the loop, and stood still for as long as a room's textures took. Now ~30 times a second from wherever
# the work is (Set-LoadProgress) and from the re-boot's wait. (A title load: the title's own window is in front, no picture yet.)
$script:loadRepaintAt = $null
function Step-LoadRepaint {
    if (-not ($script:visorMenu -and $script:visorMenu.ReadPlaying -and $script:gpuClean -and $script:gpu -and $script:ov -and $script:ov.GlPresent)) { return }
    if ($script:loadRepaintAt -and $script:loadRepaintAt.ElapsedMilliseconds -lt 30) { return }
    if ($script:loadRepaintAt) { $script:loadRepaintAt.Restart() } else { $script:loadRepaintAt = [Diagnostics.Stopwatch]::StartNew() }
    try { Repaint-HeldPicture } catch { }
}
# A ROOM'S TEXTURES TO THE CARD BEFORE ITS FIRST FRAME: one at a time (so whatever covers the change keeps moving: $onFrac gets
# 0..1), then waited for -- Finish: the card's copies, mipmaps and relief maps done -- or the first frame waits on them instead.
function Send-RoomTextures($rm, [scriptblock]$onFrac) {
    $gq = $script:gpu; $upClock = [Diagnostics.Stopwatch]::StartNew()
    $miss0 = $gq.MissingCount($rm.Texes); $ev0 = $gq.Evicted; $upN = 0; $prev = [int]::MaxValue; $stuck = 0
    if ($miss0 -le 0) { if ($onFrac) { & $onFrac 1.0 }; return }
    while ($upClock.Elapsed.TotalSeconds -lt 20) {
        $left = $gq.MissingCount($rm.Texes); if ($left -le 0) { break }
        if ($left -ge $prev) { if (++$stuck -ge 3) { break } } else { $stuck = 0 }      # (one that never counts as sent: Draw has it)
        $prev = $left
        if ($onFrac) { & $onFrac (1 - $left / [Math]::Max(1, $miss0)) }
        $upN += $gq.UploadSome($rm.Texes, 1)
    }
    # (the room's cover cannot be redrawn while the card finishes: held up a while longer)
    if ($script:roomCover -and $script:ov) { $script:roomCover.Hold = [Diagnostics.Stopwatch]::GetTimestamp() + 3 * [Diagnostics.Stopwatch]::Frequency; $script:ov.HoldFreshUntil = $script:roomCover.Hold }
    $upMs = $upClock.ElapsedMilliseconds; $gq.Finish(); $finMs = $upClock.ElapsedMilliseconds - $upMs
    if ($onFrac) { & $onFrac 1.0 }
    Say ("  textures to the card before the room's first frame: {0} in {1:N0} ms, finished on the card {2:N0} ms later; {3:N1} GB held there ({4} let go, least recently used)" -f $upN, $upMs, $finMs, ($gq.TextureBytes / 1GB), ($gq.Evicted - $ev0)) Cyan
}
function Step-NothingToDraw([ref]$flag, [string]$why, [int]$sleepMs) {
    # (the loading cover stays up through a short gap -- a load can blink -- but not over a movie or a menu)
    if ($script:roomCover) {
        if (-not $script:roomCover.NothingSince) { $script:roomCover.NothingSince = [Diagnostics.Stopwatch]::StartNew() }
        if ($script:roomCover.NothingSince.Elapsed.TotalSeconds -gt 1.5) { Stop-RoomCover ("nothing to draw for 1.5 s: " + $why) } else { Show-RoomCover }
    }
    if (-not $script:nothingClock) { $script:nothingClock = [Diagnostics.Stopwatch]::StartNew() }
    if ($flag.Value -and $script:nothingClock.ElapsedMilliseconds -lt $HandBackAfterMs) { $script:nothingSkips++; [Threading.Thread]::Sleep(2); return }
    if ($flag.Value) { Say ("nothing to draw for {0:N0} ms ({1}) -- handing the viewport back" -f $script:nothingClock.ElapsedMilliseconds, $why) DarkGray }
    Set-Engine3D $flag $false; Start-Sleep -Milliseconds $sleepMs
}
function Set-Engine3D([ref]$flag, [bool]$suppress) {
    if ($suppress -eq $flag.Value) { return }
    if ($suppress) {
        # THE COPY MUST BE A FLAT FULL FRAME WHEN WE OWN THE VIEWPORT.
        #
        # AztInjBody has two other modes, used by the visor boot: SPLIT copies only an upper
        # and a lower panel using aztInjTopDw/aztInjBotOff, and ROLL offsets the source for
        # the vertical hold slip. Both change where the 1.48 MB lands. ABT_finish is supposed
        # to clear them, but if any survived -- a boot that ended early, a reload re-boot, a
        # path that misses the finish -- our frame would be written at stale offsets, which
        # is a heap write, not a cosmetic glitch.
        #
        # Logged before being forced, so the log says whether this was ever actually the
        # case rather than silently papering over it.
        $sp = $hv.ReadU32((HostLin $S_split)); $rl = $hv.ReadU32((HostLin $S_roll))
        if ($sp -ne 0 -or $rl -ne 0) {
            Say ("injection was left in split/roll mode (split={0} roll={1} topDw={2} botOff={3}) -- forcing flat" -f `
                $sp, $rl, $hv.ReadU32((HostLin $S_topDw)), $hv.ReadU32((HostLin $S_botOff))) Red
        }
        [void]$hv.WriteU32((HostLin $S_split), 0)
        [void]$hv.WriteU32((HostLin $S_roll), 0)

        # IS THE DESTINATION ACTUALLY BIG ENOUGH? Assumed since the first line of this work,
        # never measured. AztInjBody copies INJ_W*INJ_H = 1,484,800 bytes into [0x163A34] and
        # checks only that the pointer is non-null. If the surface behind it is smaller, every
        # single frame overruns the heap -- which is exactly the shape of this crash: only
        # while injecting, intermittent in when it bites, and surfacing as Reality Lab finding
        # one of its own objects corrupted.
        #
        # BOTH READS ARE -Obj2. 0x163A34 and 0x14745C are obj2 addresses and the per-object
        # deltas differ by a page, so the earlier probe that read 0x163A34 without it was
        # reading the wrong address -- consistently, which is why it reported a reassuring
        # "dst 1" that meant nothing.
        # THE SOURCE BUFFER, never measured until now. AztInjInit asks the game's allocator
        # (0x32CE0) for INJ_W*INJ_H bytes and we write exactly that many into it from the host
        # every frame. If the block is actually smaller, WE are corrupting the heap directly --
        # which would show up with -NoReady (writes, no copy) and not with -NoInject (neither),
        # and that is precisely the split the runs have shown.
        $hdr = [AztTool.ProcMem]::Read($g.ProcessId, ($g.MemBase + $bufGuest - 16), 16)
        if ($hdr) {
            $words = @(0..3 | ForEach-Object { [BitConverter]::ToUInt32($hdr, $_*4) })
            Say ("staging buffer 0x{0:X}, we write {1:N0} bytes; 16 bytes of heap header before it: {2}" -f `
                $bufGuest, ($W*$H), (($words | ForEach-Object { "0x{0:X}" -f $_ }) -join ' '))
            foreach ($wv in $words) {
                if ($wv -ge ($W*$H) -and $wv -lt ($W*$H + 4096)) { Say ("  header word {0:N0} looks like the block size and is BIG ENOUGH" -f $wv) Green }
                elseif ($wv -gt 1024 -and $wv -lt ($W*$H)) { Say ("  *** header word {0:N0} is SMALLER than the {1:N0} we write ***" -f $wv, ($W*$H)) Red }
            }
        }
        $dsB = Read-AztGuest $g 0x163A34 4 -Obj2
        $sdB = Read-AztGuest $g 0x14745C 4 -Obj2
        if ($dsB -and $sdB) {
            $dstPtr = [BitConverter]::ToUInt32($dsB, 0)
            $sdPtr  = [BitConverter]::ToUInt32($sdB, 0)
            Say ("destination [0x163A34] = 0x{0:X}, surface descriptor ptr = 0x{1:X}" -f $dstPtr, $sdPtr)
            if ($sdPtr -ge 0x1000) {
                $sd = [AztTool.ProcMem]::Read($g.ProcessId, ($g.MemBase + $sdPtr), 0x20)
                if ($sd) {
                    $sw = [BitConverter]::ToInt32($sd,0x00); $sh = [BitConverter]::ToInt32($sd,0x04)
                    $bpl = [BitConverter]::ToInt32($sd,0x18); $px = [BitConverter]::ToUInt32($sd,0x1C)
                    $have = [long]$bpl * $sh; $need = [long]$W * $H
                    Say ("surface {0}x{1}, bytesPerLine {2}, pixels 0x{3:X} -- holds {4:N0} bytes, the copy writes {5:N0}" -f `
                        $sw, $sh, $bpl, $px, $have, $need)
                    if ($have -gt 0 -and $have -lt $need) {
                        Say ("*** THE COPY OVERRUNS THE DESTINATION BY {0:N0} BYTES ***" -f ($need - $have)) Red
                    }
                    if ($px -ne 0 -and $px -ne $dstPtr) {
                        Say ("*** surface pixels 0x{0:X} is NOT the injection destination 0x{1:X} ***" -f $px, $dstPtr) Red
                    }
                }
            }
        }
        [void]$hv.WriteU32((HostLin $S_sync), 1); $script:injSync = 1
        [void]$hv.WriteU32((HostLin $S_enable), 1)
        # 4 = skip the engine's own draw. 8 = run Reality Lab's per-object move pass on the
        # 18.2 Hz animation clock instead of on every frame: that pass applies each object's
        # built-in velocity and rotation, which is how the game moves doors, scripted objects
        # and walking characters, and with the cap off it was running ten times too often.
        # -NoMoveGate leaves it per-frame, to tell this apart from anything else.
        # THE MOVE GATE IS OFF BY DEFAULT AGAIN (2026-10-04 23:40). It kept slowing the PLAYER
        # to a crawl. The gate holds the engine's whole per-object pass to 18 Hz, the player's
        # own movement runs inside that pass, and the exemption written for it cannot work:
        # it lets through the top-level object whose handle is [0x162DE4], but a live read
        # shows the movement frame is not top-level at all -- it sits INSIDE the main scene
        # object, so it is gated with everything else. Until the gate is moved to the
        # velocity/rotation step alone (which cannot catch the player), walking speed wins:
        # 4 = skip the engine's draw only. -MoveGate asks for 12 again, for testing.
        # ...AND ON AGAIN BY DEFAULT (23:55): the gate now lives at 0x551FE, after the move
        # callbacks, and holds only the built-in velocity and rotation steps to the tick. The
        # player's movement is a callback, so it is never touched. -NoMoveGate writes 4.
        if ($Suppress) { [void]$hv.WriteU32((HostLin $S_parts), $(if ($NoMoveGate) { 4 } else { 12 })) }
        Say 'viewport taken over by the host renderer' Green
        Enable-HostFps
    } else {
        # the game's own picture is the picture again -- unless the host's boot is covering it (a re-boot after a load)
        # (...nor while the room's loading cover is up: it shows through the card's window, and hiding it here put the 8-bit picture on
        # screen through the engine-draw pulse -- Josh, 2026-10-14, entering MINEMAZE: '256 version ... loading, then back')
        if ($script:ov -and -not ($script:bootHd -and $script:bootHd.Covering) -and -not $script:roomCover) { $script:ov.Hide() }
        Disable-HostFps          # the engine draws for itself again: its own cap, its own step
        [void]$hv.WriteU32((HostLin $S_parts), 0)
        [void]$hv.WriteU32((HostLin $S_enable), 0)
        [void]$hv.WriteU32((HostLin $S_sync), 0); $script:injSync = 0
        Say 'viewport handed back (nothing to draw yet)' Yellow
    }
    $flag.Value = $suppress
}

# ---- TRUE COLOUR, PHASE 0 ------------------------------------------------------
# States: 'find' (a calibration patch is on screen; look for it in DOSBox's memory),
# 'confirm' (the patch has been moved; whichever copy followed it is the live display),
# 'run'. Any failure ends in the 8-bit picture being injected exactly as without the switch.
$script:ov = $null; $script:tcOn = $false; $script:tcPush = $null
function Close-TrueColour {
    if ($S_oldMapOff -and $hv) { try { [void]$hv.WriteU32((HostLin $S_oldMapOff), [uint32]0) } catch { }; $script:oldMapWr = $null }      # (the game draws its own map again)
    Restore-SysMenuHot      # (the game's own fold-out clicks, before the host stops drawing its menu)
    Restore-MapHot          # (the map screen's own click, if the 3D map was up)
    Stop-BootHd
    Stop-VisorShade
    if ($script:ov) { $script:ov.Decorate = $null; $script:ov.Decorate3 = $null; $script:ov.Decorate4 = $null }
    $script:visorMenu = $null
    $script:visorNote = $null; $script:visorPending = $null
    Stop-ScanWire
    Stop-WidePanel
    $script:tcOn = $false; $script:tcPush = $null
    # the 8-bit picture is the picture again: it must be the lit, filtered one -- and it must be
    # the game's size to be injected, so a session drawing at another size has to start over
    if ($script:tcRaster) { $script:tcRaster.Rgb = $false; if ($script:tcRaster.W -ne $W -or $script:tcRaster.H -ne $H) { $script:tcRestart = $true } }
    if ($script:ov) { try { $script:ov.Dispose() } catch { }; $script:ov = $null }
}
# ---- THE WIDESCREEN PANEL ----------------------------------------------------------------------
# Started once true colour is running (it reads the same DOSBox surface the overlay found), and
# stopped with it. Everything about the design comes from AztMod\art\wide (Build-HudWide.ps1).
function Stop-WidePanel {
    # the pointer first: it gives the game its own pointer back (and the vector cursors put the game's bitmaps back)
    if ($script:iconCursor) { try { $script:iconCursor.Dispose() } catch { }; $script:iconCursor = $null }
    if ($script:pointer) { try { $script:pointer.Dispose() } catch { }; $script:pointer = $null }
    if ($script:panel) { try { $script:panel.Dispose() } catch { }; $script:panel = $null }
    if ($script:ov) { $script:ov.HideRect = $null; $script:ov.HideFromRow = [int]::MaxValue }; if ($script:gpu) { $script:gpu.HideRect = $null; $script:gpu.HideFromRow = [int]::MaxValue }
}
# A SWITCH SAYS WHAT IT DID (F5 wet, F6 shine, F7 relief: Josh compares them in play and cannot see the log) -- a short
# readout typed on the visor, not dismissed by the flashlight as a room's own readout is
$script:toggleNoteAt = $null
function Show-ToggleNote([string]$text) {
    if (-not $script:ov) { return }
    try { (Get-VisorNote).Show(@("RAPTOR H.U.D. // $text"), 1.2); $script:toggleNoteAt = [Diagnostics.Stopwatch]::StartNew() } catch { }
}
# the visor's readouts and damage badge (ScanWire.cs VisorNote, on Overlay.Decorate3), made on first use
function Get-VisorNote {
    if (-not $script:visorNote) {
        $script:visorNote = New-Object AztTool.VisorNote($script:ov); $script:ov.Decorate3 = $script:visorNote.Hook
        if ($script:tcPal32) { $script:visorNote.AmberHi = $script:tcPal32[49] -band 0xFFFFFF; $script:visorNote.Ink = $script:tcPal32[88] -band 0xFFFFFF; $script:visorNote.InkFlare = $script:tcPal32[55] -band 0xFFFFFF }      # (the scanner's inks)
    }
    return $script:visorNote
}
function Start-WidePanel($ovl) {
    Stop-WidePanel
    if ($NoWidePanel -or -not $ovl.Wide) { return }
    $wd = Join-Path $toolDir '..\art\wide'; $wj = Join-Path $wd 'wide.json'
    if (-not (Test-Path $wj)) { Say 'widescreen panel: no art\wide\wide.json -- the game''s own 4:3 panel stays' Yellow; return }
    try {
        $wi = Get-Content $wj -Raw | ConvertFrom-Json
        $lay = Get-Content (Join-Path $wd '..\hud-layout.json') -Raw | ConvertFrom-Json
        $pn = New-Object AztTool.Panel($g.ProcessId, $ovl, (Resolve-Path $wd).Path)
        $pn.K = [double]$wi.k; $pn.ArtX0 = [int]$wi.artX0; $pn.ArtY0 = [int]$wi.artY0; $pn.HiScale = [int]$wi.hiScale
        # (THE MAP'S LIGHTS sit on the art's two corner horns: their tips at art column 18, row 15 from the image's origin -- panel-off.png
        # at hiScale 2 -- the right one the mirror of the left about the screen's middle; GpuRaster.MapBeamView takes VIEW pixels, rows from 49)
        try { $bxL = [double]$wi.gameX0 + 18 * [double]$wi.k; $byL = [double]$wi.gameY0 + 15 * [double]$wi.k - 49; $script:mapBeamView = [single[]]@($bxL, $byL, (1600 - $bxL), $byL) } catch { $script:mapBeamView = $null }
        $pn.Inventory = [int[]]@($wi.inventory.x, $wi.inventory.y, $wi.inventory.w, $wi.inventory.h)
        $pn.Gauge = [int[]]@($wi.gauge.x, $wi.gauge.y, $wi.gauge.w, $wi.gauge.h)
        # THE TEXT AREA: the panel's own module, stretched as it opens (Build-HudWide's textArea)
        $ta = $wi.textArea
        $pn.TaTop = [double[][]]@($ta.top | ForEach-Object { ,([double[]]@($_[0], $_[1], $_[2])) })
        $pn.TaInsertY = [double]$ta.insertY; $pn.TaExtend = [int]$ta.extend
        $pn.RecessClosed = [int[]]@($ta.recessClosed.x, $ta.recessClosed.y, $ta.recessClosed.w, $ta.recessClosed.h)
        $pn.RecessOpen = [int[]]@($ta.recessOpen.x, $ta.recessOpen.y, $ta.recessOpen.w, $ta.recessOpen.h)
        # THE LOG'S OWN LAYOUT (Josh, 2026-10-10: the top line sat cut off under the frame): the recess the ART shows round
        # the log, closed and open -- the dark area out to the bevel, measured off panel-off.png / panel-exp.png (the game's
        # box above sits 8 px under its top, 16 short of its bottom and 25 in from its left). A "box" in wide.json's
        # textArea { closed {x,y,w,h}, open {..} } overrides it.
        if (-not $NoLogLayout) {
            if ($ta.PSObject.Properties['box']) { $pn.LogBoxClosed = [double[]]@($ta.box.closed.x, $ta.box.closed.y, $ta.box.closed.w, $ta.box.closed.h); $pn.LogBoxOpen = [double[]]@($ta.box.open.x, $ta.box.open.y, $ta.box.open.w, $ta.box.open.h) }
            else { $pn.LogBoxClosed = [double[]]@(1039.2, 998.1, 472.4, 117.2); $pn.LogBoxOpen = [double[]]@(1038.2, 531.0, 468.1, 582.8) }
        }
        $pn.LogUp = [double[]]@($ta.up.x, $ta.up.y, $ta.up.w, $ta.up.h); $pn.LogDown = [double[]]@($ta.down.x, $ta.down.y, $ta.down.w, $ta.down.h)
        $pn.FrameOpen = [int[]]@($ta.frame.x, $ta.frame.yOpen, $ta.frame.w)
        $pn.SeeThrough = [bool]$UnderPanelSeeThrough -and $ovl.ExtendRows -gt 0      # no black backing at all
        # the new HUD: its own placement, the seam the halves slide in to, and what its text sits on
        if ($wi.PSObject.Properties['gameX0']) { $pn.GameX0 = [double]$wi.gameX0; $pn.GameY0 = [double]$wi.gameY0 }
        if ($wi.PSObject.Properties['seamX']) { $pn.SeamX = [double]$wi.seamX }
        if ($wi.PSObject.Properties['backingX0']) { $pn.BackingX0 = [double]$wi.backingX0; $pn.BackingX1 = [double]$wi.backingX1 }
        if ($wi.PSObject.Properties['edgeSlice']) { $pn.EdgeSlice = [double[]]@($wi.edgeSlice) }
        if ($wi.PSObject.Properties['edgeCut']) { $pn.EdgeCut = [double[]]@($wi.edgeCut) }
        if ($wi.PSObject.Properties['gaugeSlot']) { $pn.GaugeSlot = [double[]]@($wi.gaugeSlot.x, $wi.gaugeSlot.y, $wi.gaugeSlot.w, $wi.gaugeSlot.h) }
        if ($wi.PSObject.Properties['windowTop']) { $pn.Top = [Math]::Min($pn.Top, [int]$wi.windowTop) }
        if ($ta.PSObject.Properties['exp']) { $ex = $ta.exp; $pn.TaExpFile = [string]$ex.file; $pn.TaExpRect = [double[]]@($ex.x, $ex.y, $ex.w, $ex.h)
            $pn.TaExpCutY = [double]$ex.cutY; $pn.TaExpClosedTop = [double]$ex.closedTop; $pn.TaExpShift = [double]$ex.shift }
        if ($ta.PSObject.Properties['upOpen']) { $pn.LogUpOpen = [double[]]@($ta.upOpen.x, $ta.upOpen.y, $ta.upOpen.w, $ta.upOpen.h); $pn.LogDownOpen = [double[]]@($ta.downOpen.x, $ta.downOpen.y, $ta.downOpen.w, $ta.downOpen.h) }
        if ($wi.PSObject.Properties['bg8']) { $pn.LoadBg8((Join-Path $wd $wi.bg8)) }
        # the panel's bleed over the view (game rows bleedTop..976) is the host's: the game's 8-bit copy
        # of it is left out of the 3D compose, or it shows through the art's soft edges
        $pn.OwnFromRow = [int]$wi.bleedTop
        if ($wi.PSObject.Properties['backingTop']) { $pn.BackingTop = [int]$wi.backingTop }
        if ($ta.PSObject.Properties['corner']) { $pn.TaCorner = [double[]]@($ta.corner.x, $ta.corner.y, $ta.corner.r) }
        $pn.ReplaySprite = [int[]]@($lay.replay.x, $lay.replay.y, 86, 43)
        # the keys that flicker on at the boot's HUD line, left to right (game px)
        $pk = New-Object System.Collections.Generic.List[int[]]
        foreach ($r in @($wi.invUp, $wi.invDown, $wi.modes[0], $wi.modes[1], $wi.modes[2], $ta.expand, $ta.up, $ta.down)) {
            if ($r -and $null -ne $r.x) { $pk.Add([int[]]@([int]$r.x, [int]$r.y, [int]$r.w, [int]$r.h)) }
        }
        $pn.PowerKeys = $pk.ToArray()
        # the mode buttons, and their two sprites as DOSBox shows them (Build-HudWide's modes.bin)
        $mbin = [IO.File]::ReadAllBytes((Join-Path $wd 'modes.bin')); $mo = 0
        for ($mi = 0; $mi -lt 3; $mi++) {
            $mw = [BitConverter]::ToInt32($mbin, $mo); $mh = [BitConverter]::ToInt32($mbin, $mo + 4); $mo += 8
            $md = $wi.modes[$mi]; if ($md.w -ne $mw -or $md.h -ne $mh) { throw "mode button $mi is ${mw}x$mh in modes.bin but $($md.w)x$($md.h) in wide.json" }
            $pn.Modes[$mi] = [int[]]@($md.x, $md.y, $md.w, $md.h)
            $off = New-Object int[] ($mw * $mh); [Buffer]::BlockCopy($mbin, $mo, $off, 0, $mw * $mh * 4); $mo += $mw * $mh * 4
            $on = New-Object int[] ($mw * $mh); [Buffer]::BlockCopy($mbin, $mo, $on, 0, $mw * $mh * 4); $mo += $mw * $mh * 4
            $pn.ModeOff[$mi] = $off; $pn.ModeOn[$mi] = $on
        }
        # the game's state it follows: obj1 addresses take HostLin, obj2 ones the obj2 delta
        $d2 = Get-GuestD2
        $pn.BoxBigAddr = HostLin 0x511AF                              # aztBoxBig: CAVE2_BASE + 15, fixed by design
        $pn.ConvListAddr = [long]($g.MemBase + 0x152B1C + $d2)        # g_convList: a conversation holds the box open
        $pn.CursorXAddr = [long]($g.MemBase + 0x182D6C + $d2); $pn.CursorYAddr = [long]($g.MemBase + 0x182D6E + $d2)
        if ($symMap.ContainsKey('aztLogScroll')) { $pn.LogScrollAddr = HostLin (Sym 'aztLogScroll') }
        if ($symMap.ContainsKey('aztConvBox')) { $pn.ConvBoxAddr = HostLin (Sym 'aztConvBox') }   # the box opens once the options print (overlay AztConvBoxZ)
        $pn.InitStaticOn = -not $NoConvCue -and -not $Retro                                  # until then the collapsed log shows static + '//Initializing Dialogue Interface...' (Panel.InitStatic)
        # THE HUD'S TEXT IN VECTOR TYPE (Josh, 2026-10-09; docs\text-render-RE.md): the log read back out of the game's text
        # surface and the inventory's names out of its list, drawn in Verdana at the display's resolution. -NoHostText:
        # the game's own pixels, as before.
        $pn.HostText = -not $NoHostText; $pn.MemBase = [long]$g.MemBase; $pn.Palette = $script:tcPal32
        $pn.LogObjAddr = [long]($g.MemBase + 0x1521AC + $d2); $pn.FontGoldAddr = [long]($g.MemBase + 0x152178 + $d2); $pn.FontCyanAddr = [long]($g.MemBase + 0x15217C + $d2)
        $pn.FontInvAddr = [long]($g.MemBase + 0x163A38 + $d2); $pn.InvWidgetAddr = [long]($g.MemBase + 0x163A40 + $d2); $pn.InvPitchAddr = [long]($g.MemBase + 0x14747A + $d2)
        $pn.ConvScrollAddr = [long]($g.MemBase + 0x152B32 + $d2); $pn.ConvOptAddr = [long]($g.MemBase + 0x162B34 + $d2); $pn.ConvSpeakAddr = [long]($g.MemBase + 0x152B28 + $d2)      # the options' ends (the hover highlight)
        # the host's pointer (before the panel starts: the seam layout is decided when it first places itself)
        $ptr = $null
        if ($HostPointer) {
            try {
                $ptr = New-Object AztTool.Pointer($g.ProcessId)
                $o2 = { param([uint32]$a) [long]($g.MemBase + $a + $d2) }
                $ptr.MemBase = [long]$g.MemBase
                $ptr.HiddenAddr = & $o2 0x147586; $ptr.MouselookAddr = & $o2 0x147218; $ptr.CursorAddr = & $o2 0x182D6C
                $ptr.DrvXAddr = & $o2 0x182D68; $ptr.DrvYAddr = & $o2 0x182D64; $ptr.CurSurfAddr = & $o2 0x147588; $ptr.HotAddr = & $o2 0x14758E
                $ptr.Palette = $script:tcPal32
                $pn.AttachPointer($ptr); $pn.SeamLayout = $true
                if (-not $ptr.Start()) { throw ("its window would not start: " + $ptr.StartError) }
            } catch { Say ("host pointer failed: {0} -- the game's own pointer, inside its 1600 columns" -f $_.Exception.Message) Yellow; try { $ptr.Dispose() } catch { }; $ptr = $null; $pn.Ptr = $null; $pn.SeamLayout = $false }
        }
        if (-not $pn.Start()) { throw ("its window would not start: " + $pn.StartError) }
        $script:pointer = $ptr
        $script:panel = $pn
        # THE GAME'S CURSORS AS ANIMATED VECTORS (see -NoIconCursor; not with the host pointer, which draws the cursor itself)
        if (-not $NoIconCursor -and -not $ptr) {
            try {
                $ic = New-Object AztTool.IconCursor($g.ProcessId)
                $o2c = { param([uint32]$a) [long]($g.MemBase + $a + $d2) }
                $ic.MemBase = [long]$g.MemBase; $ic.GamePid = $g.ProcessId
                $ic.CursorAddr = & $o2c 0x182D6C; $ic.CurSurfAddr = & $o2c 0x147588; $ic.HotAddr = & $o2c 0x14758E
                $ic.HiddenAddr = & $o2c 0x147586; $ic.MouselookAddr = & $o2c 0x147218
                $ic.TableAddr = & $o2c 0x164B80; $ic.TableGuest = [uint32](0x164B80 + $d2)          # (slot i's surface: 0x164B80 + i * 18)
                $ic.PlaceBy($pn, 'GetPlacement')
                if (-not $ic.Start()) { throw ("its window would not start: " + $ic.StartError) }
                $script:iconCursor = $ic
                Say 'game cursors: drawn as animated vectors (the game''s 30 cursor bitmaps blanked while they are; -NoIconCursor for the bitmaps)' Green
            } catch { Say ("vector cursors failed: {0} -- the game's own cursor bitmaps" -f $_.Exception.Message) Yellow; try { $ic.Dispose() } catch { }; $script:iconCursor = $null }
        }
        Say ("widescreen panel: on ({0}); log text {1} px wide; scroll keys {2}" -f $wd, $pn.RecessOpen[2], $(if ($pn.LogScrollAddr) { 'wired' } else { 'NOT wired (no aztLogScroll in the symbol map)' })) Green
    } catch { Say ("widescreen panel failed: {0} -- the game's own 4:3 panel stays" -f $_.Exception.Message) Yellow; Stop-WidePanel }
}
# ---- THE SCANNER'S WIREFRAME (tools\ScanWire.cs) ----------------------------------------------
# Scanning a creature plays a ten-frame bitmap in the view's top-left corner; for the sets listed in
# -ScanWireSets the host hides that box and draws the creature's own rig there, walking and turning, instead.
$script:scanWire = $null
function Stop-ScanWire {
    if ($script:ov) { $script:ov.Decorate2 = $null; $script:ov.HideRect2 = $null }
    if ($script:gpu) { $script:gpu.HideRect2 = $null }
    if ($script:scanWire) { try { $script:scanWire.Close() } catch { }; $script:scanWire = $null }
}
function Start-ScanWire($ovl) {
    Stop-ScanWire
    if ($NoScanWire -or -not $ovl) { return }
    try {
        $sw = New-Object AztTool.ScanWire
        $sw.PhaseCache = Join-Path $CacheDir 'scanwire-phases.txt'      # (each set's start angle: worked out once, ~2.5 s a set)
        $aniDir = Join-Path (Split-Path $TexDir) 'AZRAEL'; $wireDir = Join-Path $TexDir 'WIRE'
        # what the game prints when each is scanned: DESCRIPT.ZAP, NAME.DES ... $END$
        $des = @{}
        $zap = Join-Path $aniDir 'DESCRIPT.ZAP'
        if (Test-Path $zap) {
            $zt = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($zap))
            foreach ($mm in [regex]::Matches($zt, '([A-Za-z0-9_]+)\.DES[\x00-\x1F]*([\s\S]*?)\$END\$')) { $des[$mm.Groups[1].Value.ToUpperInvariant()] = (($mm.Groups[2].Value -replace '[\x00-\x1F]+', ' ') -replace '\s+', ' ').Trim() }
        }
        # EVERY CHARACTER the game scans with a wireframe (Josh, 2026-10-08: 'all creatures ... that contain that scanning
        # wireframe animation'): each definition (GAME\AZRAEL\<NAME>.ANI) that has the game's frames, WIRE\<NAME>00..09.PCX,
        # is a set of its own -- its rig (the .ANI's FILE), its own frames and its own text. Characters sharing a rig (KURT and
        # KURTB, the three scorpions) are separate sets on one rig. The game's frame files do not always carry the
        # definition's name: Geoffrye's are GEFFRYE0 + GEOFF01..09, Vincent's VINCE00..09. ZOMBIE has frames and text but no
        # rig anywhere in the game (cut), so it stays the game's own. -ScanWireSets narrows it to a list of definitions.
        $alias = @{ 'GEFFRYE' = @('GEFFRYE0', 'GEOFF01', 'GEOFF02', 'GEOFF03', 'GEOFF04', 'GEOFF05', 'GEOFF06', 'GEOFF07', 'GEOFF08', 'GEOFF09'); 'VINCENT' = 'VINCE' }
        $only = @($ScanWireSets -split '[,; ]+' | Where-Object { $_ -and $_ -ne '*' -and $_ -ne 'ALL' } | ForEach-Object { $_.ToUpperInvariant() })
        $got = @(); $skipped = @()
        foreach ($af in @(Get-ChildItem $aniDir -Filter '*.ANI' -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $an = $af.BaseName.ToUpperInvariant()
            if ($only.Count -and $only -notcontains $an) { continue }
            $at = [IO.File]::ReadAllText($af.FullName)
            $mx = [regex]::Match($at, '(?im)^\s*FILE\s+([^\s.]+)\.xaf'); if (-not $mx.Success) { continue }
            $xaf = Join-Path $TexDir ('{0}.XAF' -f $mx.Groups[1].Value.ToUpperInvariant())
            # its frames
            $fr = @()
            if ($alias.ContainsKey($an) -and $alias[$an] -is [array]) { $fr = @($alias[$an] | ForEach-Object { Join-Path $wireDir ('{0}.PCX' -f $_) } | Where-Object { Test-Path $_ }) }
            else { $pre = $(if ($alias.ContainsKey($an)) { $alias[$an] } else { $an }); $fr = @(0..9 | ForEach-Object { Join-Path $wireDir ('{0}{1:00}.PCX' -f $pre, $_) } | Where-Object { Test-Path $_ }) }
            if ($fr.Count -eq 0) { continue }                    # (not scanned with a wireframe: cut-scene stand-ins and the like)
            if (-not (Test-Path $xaf)) { $skipped += "$an (no $($mx.Groups[1].Value).xaf)"; continue }
            # what it does while turning: its WALK, else RUN (the small dinosaurs only run), else REST; a range of one frame
            # is a pose held (Leo seated, the sailor), turned but not animated
            $rg = $null
            foreach ($k in 'WALK', 'RUN', 'REST') { $m = [regex]::Match($at, '(?im)^\s*' + $k + '\s+(\d+)\s*-\s*(\d+)'); if ($m.Success) { $rg = @([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, $k); break } }
            if (-not $rg) { $rg = @(0, 0, 'none') }
            if ($sw.Add($an, $xaf, [string[]]$fr, $rg[0], $rg[1])) {
                $got += $an
                $sw.AddCharacter($an, $an, $(if ($des.ContainsKey($an)) { $des[$an] } else { $null }))
                # its SNIFF, when its .ANI has one (EUGENE / EUGENB: added at install), plays in the scan after the walk
                $ms = [regex]::Match($at, '(?im)^\s*SNIFF\s+(\d+)\s*-\s*(\d+)')
                if ($ms.Success -and $sw.SetExtra($an, [int]$ms.Groups[1].Value, [int]$ms.Groups[2].Value)) { Say ("scanner wireframe: {0} also sniffs (frames {1}-{2}) after its walk" -f $an, $ms.Groups[1].Value, $ms.Groups[2].Value) DarkCyan }
                Say ("scanner wireframe: {0} ({1} {2}-{3}, {4} frames{5})" -f $sw.RigInfo, $rg[2], $rg[0], $rg[1], $fr.Count, $(if ($des.ContainsKey($an)) { '' } else { ', no text' })) DarkCyan
            } else { $skipped += $sw.LastError }
        }
        if ($skipped.Count) { Say ("scanner wireframe: left to the game: {0}" -f ($skipped -join '; ')) Yellow }
        # THE ITEMS (batch 2, 2026-10-08): every set in the game's item table GAME\AZRAEL\WIRESCAN.RES (one line per scannable
        # object; one set can serve many objects -- BISC serves 24). Drawn from the game's own detailed frames (the rooms'
        # models of the items are flat cards and bare boxes); the text per scan from OBJECTS.DAT, by the picked part.
        if (-not $NoScanItems) {
            $objs = Join-Path $aniDir 'OBJECTS.DAT'
            if (Test-Path $objs) { try { $no = $sw.LoadObjects($objs); Say ("scanner wireframe: {0} objects' texts from OBJECTS.DAT" -f $no) DarkCyan } catch { Say ("scanner wireframe: OBJECTS.DAT unreadable: {0}" -f $_.Exception.Message) Yellow } }
            $ws = Join-Path $aniDir 'WIRESCAN.RES'; $items = @()
            if (Test-Path $ws) {
                foreach ($ln in @([IO.File]::ReadAllLines($ws) | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ -match '^[A-Z0-9_]+$' } | Select-Object -Unique)) {
                    if ($got -contains $ln) { continue }           # (CLAUDE: a character first)
                    $fr = @(0..9 | ForEach-Object { Join-Path $wireDir ('{0}{1:00}.PCX' -f $ln, $_) } | Where-Object { Test-Path $_ })
                    if ($fr.Count -and $sw.AddItem($ln, [string[]]$fr)) { $items += $ln } else { $skipped += $ln }
                }
            }
            if ($items.Count) { Say ("scanner wireframe: {0} item sets: {1}" -f $items.Count, ($items -join ', ')) DarkCyan; $got += $items }
        }
        if ($got.Count -eq 0) { return }
        $d2 = Get-GuestD2
        # its sounds: the boot's own engine, under the boot's switches (-NoBootSound, -BootSoundVolume)
        $sw.Sound = New-Object AztTool.BootSound
        $sw.Sound.On = (-not $NoBootSound); if ($BootSoundVolume -ge 0) { $sw.Sound.Volume = $BootSoundVolume }
        $sw.Attach($g.ProcessId, [long]$g.MemBase, [long]$d2)
        if ($sw.LastError) { throw $sw.LastError }
        $sw.Use($ovl)
        # the scan pulse and readout in the boot's own inks (art\boot-hd.json: scan 34, sweep 49, text 88, flare 55)
        if ($script:tcPal32) { $sw.Amber = $script:tcPal32[34] -band 0xFFFFFF; $sw.AmberHi = $script:tcPal32[49] -band 0xFFFFFF; $sw.Ink = $script:tcPal32[88] -band 0xFFFFFF; $sw.InkFlare = $script:tcPal32[55] -band 0xFFFFFF }
        $ovl.Decorate2 = $sw.Hook
        $script:scanWire = $sw; $script:scanSaid = 0
        Say ("scanner wireframe: the host draws {0} when scanned" -f ($got -join ', ')) Green
    } catch { Say ("scanner wireframe failed: {0} -- the game's own bitmaps" -f $_.Exception.Message) Yellow; Stop-ScanWire }
}
# NOT SILENT (2026-10-15): the graphics card refused means the processor draws -- slower, without the card's effects -- and the
# player could not tell why; the visor says so once (the reason is in watch.log)
function Show-GpuRefused([string]$why) {
    if ($script:gpuRefusedShown) { return }; $script:gpuRefusedShown = $true
    try { if ($script:ov) { (Get-VisorNote).Show(@('RAPTOR H.U.D. // GRAPHICS CARD NOT AVAILABLE', 'DRAWING ON THE PROCESSOR -- SEE WATCH.LOG'), 6) } } catch { }
}
function Stop-TrueColour([string]$why) {
    Say ("true colour: {0} -- back to the 8-bit picture for this session" -f $why) Red
    Close-TrueColour
}
function Initialize-TrueColour {
    Close-TrueColour
    try {
        # Indices whose colour no other index shares, outside the HUD's own 1..53: the game's
        # drawings over the view never use them, so the key cannot be mistaken for a drawing.
        $count = @{}
        for ($i = 0; $i -lt 256; $i++) { $k = ([int]$pal[$i*3] -shl 16) -bor ([int]$pal[$i*3+1] -shl 8) -bor [int]$pal[$i*3+2]; $count[$k] = 1 + [int]$count[$k] }
        $uniq = @(54..254 | ForEach-Object {
            $k = ([int]$pal[$_*3] -shl 16) -bor ([int]$pal[$_*3+1] -shl 8) -bor [int]$pal[$_*3+2]
            if ($count[$k] -eq 1) { [pscustomobject]@{ I = $_; L = (0.299*$pal[$_*3] + 0.587*$pal[$_*3+1] + 0.114*$pal[$_*3+2]) } }
        } | Sort-Object L)
        if ($uniq.Count -lt 2) { throw 'the palette has no two usable key colours' }
        # DARK, so the frame or two before the window appears is a dim flash and not a bright one
        $keyA = $(if ($KeyIndex -gt 0) { $KeyIndex } else { [int](@($uniq | Where-Object { $_.L -ge 12 })[0].I) })
        # THE CALIBRATION PATCH IS DARK TOO (Josh, 2026-10-15: "when we fade to game, I still see a blank white square briefly"):
        # the patch was the palette's BRIGHTEST unique colour, and for the few frames the first takeover calibrates (at a new
        # game's shutter) the DOSBox window showed it as a white 256x128 block. FindPatch only needs a run of a colour that is NOT
        # the key's flanked by key, so the next-darkest unique colour does: a dim block on near-black, unseen.
        $keyB = [int](@($uniq | Where-Object { $_.L -ge 12 -and $_.I -ne $keyA })[0].I)
        if (-not $keyB -or $keyB -eq $keyA) { $keyB = [int]$uniq[$uniq.Count - 1].I; if ($keyB -eq $keyA) { $keyB = [int]$uniq[$uniq.Count - 2].I } }
        $script:tcKeyA = $keyA; $script:tcKeyB = $keyB
        $script:tcPal32 = New-Object int[] 256
        for ($i = 0; $i -lt 256; $i++) { $script:tcPal32[$i] = ([int]$pal[$i*3] -shl 16) -bor ([int]$pal[$i*3+1] -shl 8) -bor [int]$pal[$i*3+2] }
        $script:tcKeyFrame = [AztTool.Overlay]::FlatFrame($W, $H, [byte]$keyA)
        # where the calibration patch goes: clear of the edges, the reticle and each other
        $script:tcSpots = @(@(400, 200), @(1000, 620), @(250, 560), @(1100, 180)); $script:tcSpot = 0
        $script:tcPatch = [AztTool.Overlay]::PatchFrame($W, $H, [byte]$keyA, [byte]$keyB, 400, 200, 256, 128)
        $scrW = [int]$man.view.screenW; $scrH = [int]$man.view.screenH
        $o = New-Object AztTool.Overlay($g.ProcessId, $W, $H, $scrW, $scrH, [int]$man.view.injX, [int]$man.view.injY)
        $script:ov = $o
        # (the key we hand the game is always see-through in the compose, whatever colour is commonest in the view: closing the map left
        # the view mostly black for a few frames, black was taken for the key, and the real key showed as a #101010 block -- Josh, 2026-10-14)
        $o.KeyAlso = $script:tcPal32[$keyA] -band 0xFFFFFF; $script:keyAlsoSaid = $false
        if ($TcRect)  { $q = @($TcRect -split '[,; ]+' | Where-Object { $_ } | ForEach-Object { [int]$_ });  if ($q.Count -eq 4) { $o.FixX = $q[0]; $o.FixY = $q[1]; $o.FixW = $q[2]; $o.FixH = $q[3] } else { Say '-TcRect needs x,y,w,h -- ignored' Yellow } }
        if ($TcNudge) { $q = @($TcNudge -split '[,; ]+' | Where-Object { $_ } | ForEach-Object { [int]$_ }); if ($q.Count -eq 4) { $o.NudgeX = $q[0]; $o.NudgeY = $q[1]; $o.NudgeW = $q[2]; $o.NudgeH = $q[3] } else { Say '-TcNudge needs dx,dy,dw,dh -- ignored' Yellow } }
        $o.Wide = (-not $NoWide -and -not $NoRgb -and -not $TcGameSize)
        # -UnderPanel: THE 3D CARRIES ON UNDER THE WIDESCREEN PANEL to the screen's bottom, with the
        # view's own projection (Raster.ViewRows), for the art's see-through parts there.
        # Without it the 3D still runs on to the panel's black backing (wide.json backingTop, just under
        # the screen modules' top bezels): between the view's bottom edge and there, the art's gaps
        # would otherwise show DOSBox's own 8-bit panel -- a black bar behind the hoses (Josh, 2026-10-06).
        $wjPath = Join-Path $toolDir '..\art\wide\wide.json'
        if ($o.Wide -and -not $NoWidePanel -and (Test-Path $wjPath)) {
            $viewBottom = [int]$man.view.injY + $H
            if (-not $NoUnderPanel) { $o.ExtendRows = $scrH - $viewBottom }
            else { $bt = (Get-Content $wjPath -Raw | ConvertFrom-Json).backingTop; if ($bt -and [int]$bt -gt $viewBottom) { $o.ExtendRows = [int]$bt - $viewBottom + 2 } }
        }
        if (-not $o.Start()) { throw ("the overlay window could not be created: {0}" -f $o.StartError) }
        # how big the viewport is on THIS screen: that is the size to draw at
        $script:tcRW = 0; $script:tcRH = 0
        if (-not $TcGameSize -and -not $NoRgb) {
            for ($i = 0; $i -lt 40 -and $o.RectW -le 0; $i++) { Start-Sleep -Milliseconds 50 }
            if ($o.RectW -gt 0) {
                $fit = [Math]::Min(1.0, [Math]::Sqrt($TcMaxPixels / ([double]$o.RectW * $o.RectH * $TcScale * $TcScale)))
                $script:tcRW = [int]([Math]::Round($o.RectW * $TcScale * $fit / 2) * 2); $script:tcRH = [int]([Math]::Round($o.RectH * $TcScale * $fit / 2) * 2)
                if ($script:tcRW -lt 320 -or $script:tcRH -lt 200) { $script:tcRW = 0; $script:tcRH = 0 }
                Say ("true colour: the view is {0}x{1} on this screen{5}; drawing at {2}x{3}{4}" -f $o.RectW, $o.RectH, $script:tcRW, $script:tcRH, `
                    $(if ($fit -lt 1) { " (held to $TcMaxPixels pixels; -TcMaxPixels raises it)" } elseif ($TcScale -ne 1) { " (-TcScale $TcScale)" } else { '' }), `
                    $(if ($o.Wide) { ' (WIDESCREEN: the full width of the game window)' } else { '' })) Cyan
            } else { Say 'true colour: the game window was not found in time -- drawing at the game''s own size' Yellow }
        }
        $script:tcState = 'find'; $script:tcCount = 0; $script:tcTries = 0; $script:tcCands = $null
        $script:tcShareSum = 0; $script:tcShareN = 0; $script:tcHidden = 0; $script:tcReadFails = 0
        $script:tcOn = $true
        Say ("TRUE COLOUR (phase 0): key index {0} #{1:X6}, calibration index {2} #{3:X6}; the display surface is located on the first frames" -f `
            $keyA, $script:tcPal32[$keyA], $keyB, $script:tcPal32[$keyB]) Cyan
    } catch { Stop-TrueColour $_.Exception.Message }
}
# ---- THE VISOR BOOT, THE HOST'S OWN (tools\BootHd.cs) ----------------------------------------
# Started as soon as the overlay exists -- before the staging buffer, the room or the 3D -- so it
# is on screen from the boot's first frame. It runs on its own thread at display rate, following
# the game's boot clock; the loop below only has to tell it when the 3D is up (Reveal).
$script:bootHd = $null; $script:visorShade = $null; $script:shadeClock = $null; $script:shadeSaid = ''
# ---- THE VISOR'S SHADING, host-drawn (BootHd.cs VisorShade) ------------------------------------
# Smooth and across the whole width, over the boot and the 3D; the game's dithered copy is hidden
# (its dots turned into the key colour) once the game has loaded it, and put back on the way out.
function Start-VisorShade {
    Stop-VisorShade
    if ($NoVisorShade -or $NoRgb -or -not $script:tcOn -or -not $script:ov) { return }
    $res = Join-Path $GameDir 'GAME\AZRAEL\HUDTOP.RES'
    if (-not (Test-Path $res)) { $res = Join-Path $toolDir '..\art\HUDTOP.RES' }
    if (-not (Test-Path $res)) { return }
    try {
        $vs = [AztTool.VisorShade]::Load((Resolve-Path $res).Path, $script:tcPal32, $W)
        $vs.Wedge = [double]$script:ov.VisorWedge
        # off for the 3D until the game's own copy is hidden; the boot (drawn by the host) turns it on itself
        $vs.Enabled = $false
        $script:visorShade = $vs; $script:shadeClock = [Diagnostics.Stopwatch]::StartNew(); $script:shadeSaid = ''
        Say ("visor shading: drawn by the host from {0} ({1:N0} dots of colour {2}, {3} rows deep), across the full width" -f (Split-Path $res -Leaf), $vs.Inked, $vs.Index, $vs.Rows) Cyan
    } catch { Say ("visor shading: {0} -- the game's dithered copy stays" -f $_.Exception.Message) Yellow; $script:visorShade = $null }
}
function Stop-VisorShade {
    if (-not $script:visorShade) { return }
    try { if ($g) { $script:visorShade.D2 = Get-GuestD2; $r = $script:visorShade.SetGameCopy($g.ProcessId, [long]$g.MemBase, -1); Say ("visor shading: the game's own copy {0}" -f $r) DarkGray } } catch { }
    $script:visorShade = $null
}
# Every couple of seconds while the host draws: keep the game's copy hidden, and draw ours only once it is.
function Step-VisorShade {
    $vs = $script:visorShade; if (-not $vs -or -not $g) { return }
    if ($script:shadeClock.ElapsedMilliseconds -lt 2000 -and $vs.Enabled) { return }
    $script:shadeClock.Restart()
    $vs.D2 = Get-GuestD2; $r = $vs.SetGameCopy($g.ProcessId, [long]$g.MemBase, [int]$script:tcKeyA)
    $vs.Enabled = ($r -like 'hidden*' -or $r -like 'already hidden*')
    if ($r -ne $script:shadeSaid -and $r -notlike 'already*') { Say ("visor shading: the game's own copy {0}" -f $r) $(if ($vs.Enabled) { 'Cyan' } else { 'Yellow' }); $script:shadeSaid = $r }
}
function Stop-BootHd {
    if ($script:bootHd) { Write-BootNotes; try { $script:bootHd.Dispose() } catch { }; $script:bootHd = $null }
}
function Write-GateNotesLate { if ($script:gate) { for ($k = 0; $k -lt 4; $k++) { $n = $script:gate.TakeNote(); if (-not $n) { break }; Say ('loading gate: ' + $n) Cyan } } }
function Write-BootNotes { Write-GateNotesLate;
    if (-not $script:bootHd) { return }
    for ($i = 0; $i -lt 8; $i++) { $n = $script:bootHd.TakeNote(); if (-not $n) { break }; Say $n Cyan }
}
function Start-BootHd {
    Stop-BootHd
    if ($NoBootHd -or $NoRgb -or -not $script:tcOn -or -not $script:ov -or -not $S_bootState) { return }
    $bj = Join-Path $toolDir '..\art\boot-hd.json'
    if (-not (Test-Path $bj)) { Say 'visor boot: no art\boot-hd.json (run src\Build-AztMod.ps1) -- the game''s 8-bit boot is shown instead' Yellow; return }
    try {
        $b = [AztTool.BootHd]::Load((Resolve-Path $bj).Path, $script:tcPal32)
        # AT THE WINDOW'S OWN SIZE when it is known: the raster's 1-pixel lines must reach the screen
        # 1:1, or the window's scaling smears them into a blur and a beat pattern
        $pw = $(if ($script:ov.RectW -gt 0) { $script:ov.RectW } elseif ($script:tcRW -gt 0) { $script:tcRW } else { $W })
        $ph = $(if ($script:ov.RectH -gt 0) { $script:ov.RectH } elseif ($script:tcRH -gt 0) { $script:tcRH } else { $H })
        if ($script:visorShade) { $b.Shade = $script:visorShade }
        $b.StaticShotPath = (Join-Path $CacheDir 'boot-shot.png')      # (one picture of the readout at 8 s: what the boot really drew)
        $b.StandUp = (-not $NoStandUp)
        # THE SELF SCAN (2026-10-14): the raptor's own rig turning in the right column while the readout loads; its idle from KURT.ANI
        try {
            $rg = @(124, 136, 143, 147); $ka = Join-Path (Split-Path $TexDir) 'AZRAEL\KURT.ANI'
            if (Test-Path $ka) {
                $kt = [IO.File]::ReadAllText($ka)
                $mw = [regex]::Match($kt, '(?im)^\s*WALK\s+(\d+)\s*-\s*(\d+)'); if ($mw.Success) { $rg[0] = [int]$mw.Groups[1].Value; $rg[1] = [int]$mw.Groups[2].Value }
                $mr = [regex]::Match($kt, '(?im)^\s*REST\s+(\d+)\s*-\s*(\d+)'); if ($mr.Success) { $rg[2] = [int]$mr.Groups[1].Value; $rg[3] = [int]$mr.Groups[2].Value }
            }
            $b.LoadRaptor((Join-Path $TexDir 'RAPTOR.XAF'), $rg[0], $rg[1], $rg[2], $rg[3])
        } catch { Say ("visor boot: no self scan ({0})" -f $_.Exception.Message) Yellow }
        $b.Sound.On = (-not $NoBootSound); if ($BootSoundVolume -ge 0) { $b.Sound.Volume = $BootSoundVolume }
        $hs = Join-Path $toolDir '..\art\boot\hud-ratchet.wav'
        if (-not $NoHudSound -and (Test-Path $hs)) { $b.HudSoundPath = (Resolve-Path $hs).Path; $b.HudSoundLevel = $HudSoundLevel }
        $rbA = $(if ($symMap.ContainsKey('aztReboot')) { HostLin (Sym 'aztReboot') } else { 0 })
        $b.Start($g.ProcessId, $script:ov, (HostLin $S_bootState), $rbA, $pw, $ph)
        $script:bootHd = $b
        Say ("visor boot: the host draws it ({0}x{1}, type at x{2:N2} of the 8-bit boot's size), waiting for it to start" -f $pw, $ph, $b.Zoom) Cyan
    } catch { Say ("visor boot: the host's copy could not start ({0}) -- the game's 8-bit boot is shown instead" -f $_.Exception.Message) Yellow; $script:bootHd = $null }
}
# ---- the loading gate (see -Launch) ----------------------------------------------------------
function Write-GateNotes {
    if (-not $script:gate) { return }
    for ($i = 0; $i -lt 8; $i++) { $n = $script:gate.TakeNote(); if (-not $n) { break }; Say ("loading gate: " + $n) Cyan }
}
# The renderer has hold of the game: a held game runs on, the loading screen (if it came up) fades.
# ALWAYS ends with the game running -- called on success, on failure and on the way out.
function Open-Gate {
    if (-not $script:gate) { return }
    $script:gate.Ready(); Write-GateNotes
}
# THE VISOR'S MEMORY CORE (Josh, 2026-10-09): the save/load list drawn large by the host (ScanWire.cs, VisorMenu) from the
# game's own state, read every frame -- the list is redrawn by the game every frame too, with no dirty flag. Its click
# targets were moved to this layout by Build-AztMod ($SLOTLIST_*). -NoMemCore: the host leaves it alone (but then the
# game's tiny list no longer lines up with where it clicks).
# THE SYSTEM MENU'S CLICKS (Josh, 2026-10-09; docs\system-menu-RE.md): the fold-out's controls stay the GAME's -- its hot-spot
# polygons (screens 1-3) are MOVED in guest memory to the host's visor layout (AztTool.VisorMenu.Sys*) while true colour runs,
# and put back on the way out (Restore-SysMenuHot), so retro (-Retro, or no watcher) keeps the old menu and its clicks. Each
# record is checked (vertex count and command) before it is written; the polygon keeps its vertex count (rect + repeats; QUIT
# has 3: a right triangle round its rect whose spare half lies off the panel, above and to the right).
$script:sysHotRecs = @(
    @(0x146B50, 7), @(0x146B68, 8), @(0x146B84, 9), @(0x146BA8, 10), @(0x146BCC, 11), @(0x146BE8, 12), @(0x146C04, 13),
    @(0x146C3E, 7), @(0x146C56, 8), @(0x146C72, 9), @(0x146C96, 10), @(0x146CBA, 11), @(0x146CD6, 12), @(0x146CF2, 13),
    @(0x146DD4, 7), @(0x146DEC, 8), @(0x146E08, 9), @(0x146E2C, 10), @(0x146E50, 11), @(0x146E6C, 12), @(0x146E88, 13), @(0x146EC0, 16))
$script:sysHotOrig = $null
function Set-SysMenuHot {
    if ($script:sysHotDone -or -not $script:memAt) { return }
    $script:sysHotDone = $true
    $rects = @{ 7 = [AztTool.VisorMenu]::SysSfxToggle; 8 = [AztTool.VisorMenu]::SysMusToggle; 9 = [AztTool.VisorMenu]::SysSfxTrack; 10 = [AztTool.VisorMenu]::SysMusTrack; 11 = [AztTool.VisorMenu]::SysSave; 12 = [AztTool.VisorMenu]::SysLoad; 13 = [AztTool.VisorMenu]::SysQuit; 16 = [AztTool.VisorMenu]::SysOk }
    $orig = New-Object System.Collections.Generic.List[object]; $moved = New-Object System.Collections.Generic.List[object]; $bad = 0
    foreach ($rec in $script:sysHotRecs) {
        $a = [long]($g.MemBase + $rec[0] + $script:memAt.D2)
        try { $hd = [AztTool.ProcMem]::Read($g.ProcessId, $a, 2); $n = [BitConverter]::ToInt16($hd, 0) } catch { $bad++; continue }
        if ($n -lt 3 -or $n -gt 12) { $bad++; continue }
        $body = [AztTool.ProcMem]::Read($g.ProcessId, $a + 2, 4 * $n + 6); $cmd = [BitConverter]::ToInt16($body, 4 * $n + 2)
        if ($cmd -ne $rec[1]) { $bad++; continue }
        $r = $rects[[int]$rec[1]]; $x0 = $r[0]; $y0 = $r[1]; $x1 = $r[2]; $y1 = $r[3]
        $pts = $(if ($n -eq 3) { @($x0, $y1, ($x0 + 2 * ($x1 - $x0)), $y1, $x0, ($y1 - 2 * ($y1 - $y0))) } else { $q = @($x0, $y0, $x1, $y0, $x1, $y1, $x0, $y1); for ($k = 4; $k -lt $n; $k++) { $q += @($x0, $y1) }; $q })
        $nb = New-Object byte[] (4 * $n); for ($k = 0; $k -lt 2 * $n; $k++) { [Array]::Copy([BitConverter]::GetBytes([int16]$pts[$k]), 0, $nb, 2 * $k, 2) }
        $orig.Add(@(($a + 2), ([byte[]]$body[0..(4 * $n - 1)])))      # (parenthesised: a bare sum in @() is split by its comma)
        $moved.Add(@(($a + 2), ([byte[]]$body[0..(4 * $n - 1)]), $nb, $n))
        [void][AztTool.ProcMem]::Write($g.ProcessId, $a + 2, $nb)
    }
    # THE REGIONS' OWN BOXES (Josh's first try: hover worked, no click did). The game hit-tests the RUNTIME region objects its UI
    # screens hold (0x164DAA / DB8 / DC6: word count, dword -> region pointers), each {word n, dword -> points, word x0 y0 x1 y1}
    # -- and the box, worked out at start-up, is tested FIRST (0x336F8). Moving the points alone left every box at the old
    # place. So each region whose points are one of the moved records (the same memory, or a copy of the old points) gets the
    # new points and a box round them, the old box's exclusive edge kept; both go on the list put back on the way out.
    $boxes = 0
    foreach ($scr in @(0x164DAA, 0x164DB8, 0x164DC6)) {
        try {
            $sb = [AztTool.ProcMem]::Read($g.ProcessId, [long]($g.MemBase + $scr + $script:memAt.D2), 6)
            $cnt = [BitConverter]::ToInt16($sb, 0); $arr = [BitConverter]::ToUInt32($sb, 2)
            if ($cnt -le 0 -or $cnt -gt 64 -or $arr -lt 0x1000) { continue }
            $ptrs = [AztTool.ProcMem]::Read($g.ProcessId, [long]($g.MemBase + $arr), 4 * $cnt)
            for ($i = 0; $i -lt $cnt; $i++) {
                $rp = [long]($g.MemBase + [BitConverter]::ToUInt32($ptrs, 4 * $i))
                $rb = [AztTool.ProcMem]::Read($g.ProcessId, $rp, 14); $rn = [BitConverter]::ToInt16($rb, 0); $pp = [long]($g.MemBase + [BitConverter]::ToUInt32($rb, 2))
                foreach ($mv in $moved) {
                    if ($rn -ne $mv[3]) { continue }
                    $same = ($pp -eq [long]$mv[0]); $pts = $null
                    if (-not $same) { $pts = [AztTool.ProcMem]::Read($g.ProcessId, $pp, 4 * $rn); if ([Convert]::ToBase64String($pts) -ne [Convert]::ToBase64String([byte[]]$mv[1])) { continue } }
                    if (-not $same) { $orig.Add(@($pp, $pts)); [void][AztTool.ProcMem]::Write($g.ProcessId, $pp, [byte[]]$mv[2]) }
                    $ox = @(); $oy = @(); $nx = @(); $ny = @()
                    for ($k = 0; $k -lt $rn; $k++) { $ox += [BitConverter]::ToInt16([byte[]]$mv[1], 4 * $k); $oy += [BitConverter]::ToInt16([byte[]]$mv[1], 4 * $k + 2); $nx += [BitConverter]::ToInt16([byte[]]$mv[2], 4 * $k); $ny += [BitConverter]::ToInt16([byte[]]$mv[2], 4 * $k + 2) }
                    $ex = [BitConverter]::ToInt16($rb, 10) - ($ox | Measure-Object -Maximum).Maximum; $ey = [BitConverter]::ToInt16($rb, 12) - ($oy | Measure-Object -Maximum).Maximum
                    $nbx = New-Object byte[] 8
                    $vals = @(($nx | Measure-Object -Minimum).Minimum, ($ny | Measure-Object -Minimum).Minimum, (($nx | Measure-Object -Maximum).Maximum + $ex), (($ny | Measure-Object -Maximum).Maximum + $ey))
                    for ($k = 0; $k -lt 4; $k++) { [Array]::Copy([BitConverter]::GetBytes([int16]$vals[$k]), 0, $nbx, 2 * $k, 2) }
                    $orig.Add(@(($rp + 6), ([byte[]]$rb[6..13]))); [void][AztTool.ProcMem]::Write($g.ProcessId, $rp + 6, $nbx); $boxes++
                    break
                }
            }
        } catch { $bad++ }
    }
    $script:sysHotOrig = $orig
    Say ("system menu: the fold-out's clicks moved to the visor layout ({0} records, {1} region boxes{2})" -f $moved.Count, $boxes, $(if ($bad) { "; $bad did not match and were left alone" } else { '' })) $(if ($bad -or $boxes -lt $moved.Count) { 'Yellow' } else { 'Cyan' })
}
# ---- THE 3D MAP (Josh, 2026-10-14: "when a player clicks the map button in the lower UI, they will be taken to a dimmed version
# of the visor view, the world behind faded back but still visible. We then see the 3d wireframe, with basic shading in place but
# no textures. The user can click to rotate the map, and the arrows that indicate doors etc are still in place as they are in the
# original game, but in modern vector graphics ... Lets start with the coricori room first as a proof of concept").
# THE GAME'S MAP SCREEN (docs\notes\azrael-map-3d.md): the toggle 0x12954 flips word 0x1525F2 (map OR help, the same flag),
# switches the hot spots to screen 6 -- one whole-screen region whose command closes it -- and blits its composed picture
# (MAPBKGRD + the room's top-down PCX pieces + arrow PCXs from MAPS.DAT) over the whole screen every frame; the main loop
# keeps running (and our frame hook) but skips the 3D, the actors and the scripts. The help screen is told apart by the
# palette the toggle loads (HELP.PCX's, at 0x1525F4). While the 3D map is up for this room:
#   * the game's picture is left out of the view (the compose's hide rect: the whole game screen) and the card draws the map
#     over the dimmed world (GpuRaster.MapK, DrawMap) -- the world held still: the camera as it was when the map opened;
#   * the doors from the portal map (Get-AztMapDoors), the player where they stand (the floor under the eye, from the main
#     loop's $room -- read through PowerShell's dynamic scope), facing where they look;
#   * a drag with the left button turns it, the wheel brings it closer (RawMouse: DOSBox holds the mouse captured);
#   * a click must not close it, so screen 6's one region is moved -- at run time, in guest memory, and put back -- onto the
#     MAP button's own box (screen 0's region for command 6): the map button closes it, as do right-click and M.
$script:mapOpen = $false; $script:map3d = $false; $script:mapHelp = $false; $script:mapKNow = 0.0; $script:mapClock = $null
$script:mapYaw = 0.0; $script:mapPitch = 52.0; $script:mapZoom = 1.0; $script:mapYawT = 0.0; $script:mapPitchT = 52.0; $script:mapZoomT = 1.0
$script:mapMouse = $null; $script:mapHotOrig = $null; $script:mapFreezeCam = $null; $script:mapDoors = $null; $script:mapDoorsFor = $null
$script:mapPals = $null
function Get-PcxPalette([string]$path) {
    try { $b = [IO.File]::ReadAllBytes($path); if ($b.Length -lt 769 -or $b[$b.Length - 769] -ne 12) { return $null }; return [byte[]]$b[($b.Length - 768)..($b.Length - 1)] } catch { return $null }
}
# the help screen and the map share 0x1525F2: the toggle loads HELP.PCX's palette for help, CORICORI.PCX's for every map
function Test-MapIsHelp {
    if (-not $script:mapPals) {
        $md = Join-Path $GameDir 'GAME\AZTEX\MAPS'
        $script:mapPals = @{ Help = Get-PcxPalette (Join-Path $md 'HELP.PCX'); Map = Get-PcxPalette (Join-Path $md 'CORICORI.PCX') }
    }
    $hp = $script:mapPals.Help; $mp = $script:mapPals.Map
    if (-not $hp -or -not $mp) { return $false }
    $live = $null; try { $live = [AztTool.ProcMem]::Read($g.ProcessId, [long]($g.MemBase + 0x1525F4 + $script:memAt.D2), 768) } catch { }
    if (-not $live -or $live.Length -ne 768) { return $false }
    # (the game may keep it as 8-bit or as the VGA's 6-bit: compare both ways, take the nearer)
    $dh = [long]0; $dm = [long]0; $dh6 = [long]0; $dm6 = [long]0
    for ($i = 0; $i -lt 768; $i += 3) { $dh += [Math]::Abs($live[$i] - $hp[$i]); $dm += [Math]::Abs($live[$i] - $mp[$i]); $dh6 += [Math]::Abs($live[$i] - ($hp[$i] -shr 2)); $dm6 += [Math]::Abs($live[$i] - ($mp[$i] -shr 2)) }
    return ([Math]::Min($dh, $dh6) -lt [Math]::Min($dm, $dm6))
}
# screen objects: 0x164D9C + N x 14 = {word count, dword -> region pointers}; a region = {word n, dword -> points, word x0 y0 x1 y1}
function Get-HotRegion([uint32]$screenObj, [int]$index) {
    $sb = [AztTool.ProcMem]::Read($g.ProcessId, [long]($g.MemBase + $screenObj + $script:memAt.D2), 6)
    $cnt = [BitConverter]::ToInt16($sb, 0); $arr = [BitConverter]::ToUInt32($sb, 2)
    if ($index -ge $cnt -or $arr -lt 0x1000) { return $null }
    $rp = [long]($g.MemBase + [BitConverter]::ToUInt32([AztTool.ProcMem]::Read($g.ProcessId, [long]($g.MemBase + $arr + 4 * $index), 4), 0))
    $rb = [AztTool.ProcMem]::Read($g.ProcessId, $rp, 14); $n = [BitConverter]::ToInt16($rb, 0); $pp = [long]($g.MemBase + [BitConverter]::ToUInt32($rb, 2))
    return @{ At = $rp; N = $n; Points = $pp; Box = @([BitConverter]::ToInt16($rb, 6), [BitConverter]::ToInt16($rb, 8), [BitConverter]::ToInt16($rb, 10), [BitConverter]::ToInt16($rb, 12)) }
}
function Set-MapHot {
    if ($script:mapHotOrig -or -not $script:memAt) { return }
    try {
        $btn = Get-HotRegion 0x164D9C 5          # screen 0, region 5: the MAP button (command 6)
        $map = Get-HotRegion 0x164DF0 0          # screen 6's one region: the whole screen
        if (-not $btn -or -not $map -or $map.N -lt 3 -or $map.N -gt 12) { Say 'map: the map screen''s click region was not found -- a click closes it as before' Yellow; return }
        if ($btn.Box[1] -lt 600) { Say ("map: screen 0's region 5 is not down in the panel ({0}) -- a click closes the map as before" -f ($btn.Box -join ',')) Yellow; return }
        $x0 = $btn.Box[0]; $y0 = $btn.Box[1]; $x1 = $btn.Box[2] - 1; $y1 = $btn.Box[3] - 1
        $pts = @($x0, $y0, $x1, $y0, $x1, $y1, $x0, $y1); for ($k = 4; $k -lt $map.N; $k++) { $pts += @($x0, $y1) }
        $nb = New-Object byte[] (4 * $map.N); for ($k = 0; $k -lt 2 * $map.N; $k++) { [Array]::Copy([BitConverter]::GetBytes([int16]$pts[$k]), 0, $nb, 2 * $k, 2) }
        $bx = New-Object byte[] 8; for ($k = 0; $k -lt 4; $k++) { [Array]::Copy([BitConverter]::GetBytes([int16]$btn.Box[$k]), 0, $bx, 2 * $k, 2) }
        $script:mapHotOrig = @(@($map.Points, [AztTool.ProcMem]::Read($g.ProcessId, $map.Points, 4 * $map.N)), @(($map.At + 6), [AztTool.ProcMem]::Read($g.ProcessId, $map.At + 6, 8)))
        [void][AztTool.ProcMem]::Write($g.ProcessId, $map.Points, $nb); [void][AztTool.ProcMem]::Write($g.ProcessId, $map.At + 6, $bx)
        if (-not $script:mapHotSaid) { $script:mapHotSaid = $true; Say ("map: a click no longer closes the 3D map -- only the MAP button does ({0}); and right-click, M" -f ($btn.Box -join ',')) DarkCyan }
    } catch { Say ("map: moving its click region failed: {0}" -f $_.Exception.Message) Yellow }
}
function Restore-MapHot {
    if (-not $script:mapHotOrig) { return }
    foreach ($o in $script:mapHotOrig) { try { [void][AztTool.ProcMem]::Write($g.ProcessId, [long]$o[0], [byte[]]$o[1]) } catch { } }
    $script:mapHotOrig = $null
}
# ---- FOOTSTEPS (BootHd.cs Footsteps; Josh, 2026-10-14: "footsteps ... subtle sound effects, which would change based on the
# different flooring being walked on (mainly stone, tile, wood)") ----------------------------------------------------------------
# A step every stride of ground the eye covers (none for a jump, a fall, or while the map, a boot or room cover, a conversation
# or a visor panel has the player); what is underfoot from the floor triangle's texture material (rooms\_materials.json), a
# room's "footsteps" block naming surfaces by hand: false = none in that room; { "default": "wood", "<texture leaf or
# material>": "tile", ... } (stone, tile, wood, metal, water). At the game's own effects setting (SFX off = none).
# -NoFootsteps: none; -FootstepVolume: a walking step's peak. [[azrael-footsteps]]
$script:steps = $null; $script:stepsOff = $false; $script:stepsSfxAt = $null
# THE FLASHLIGHT'S SWITCH SOUND (BootHd.cs Footsteps.LampClick; Josh, 2026-10-15): two of the tile steps -- run 3 on, run 4 off.
# Played through the footsteps' own sound (so at the game's effects level); with -NoFootsteps a quiet instance of its own.
$script:lampClick = $null
function Invoke-LampClick([bool]$on) {
    try {
        $f = $script:steps
        if (-not $f) {
            if (-not $script:lampClick) { $script:lampClick = New-Object AztTool.Footsteps; if ($BootSoundVolume -ge 0) { $script:lampClick.Sound.Volume = $BootSoundVolume }; $script:lampClick.Warm() }
            $f = $script:lampClick
        }
        $f.LampClick($on)
    } catch { }
}
function Set-RoomFootsteps($atm) {
    $f = $script:steps; if (-not $f) { return }
    $f.Reset(); $f.Named.Clear(); $f.RoomDefault = $null; $f.On = $true
    # the floors named for every room (rooms\_footsteps.json: the painted floors that are really tile or wood), then the room's own
    $sets = @()
    $tp = Join-Path $RoomsDir '_footsteps.json'
    try {
        if (Test-Path $tp) {
            $st = (Get-Item $tp).LastWriteTimeUtc
            if (-not $script:stepsTable -or $script:stepsTableAt -ne $st) { $script:stepsTable = ([IO.File]::ReadAllText($tp) | ConvertFrom-Json).surfaces; $script:stepsTableAt = $st }
            if ($script:stepsTable) { $sets += ,$script:stepsTable }
        }
    } catch { Say ("footsteps table problem: {0}" -f $_.Exception.Message) Yellow }
    $b = $(if ($atm) { $atm.Footsteps } else { $null })
    if ($b -is [bool]) { $f.On = $b; if (-not $b) { return } } elseif ($null -ne $b) { $sets += ,$b }
    foreach ($set in $sets) { foreach ($pr in $set.PSObject.Properties) {
        if ($pr.Name -like '_*') { continue }
        $sv = $null; try { $sv = [Enum]::Parse([AztTool.Footsteps+Surface], [string]$pr.Value, $true) } catch { Say ("  footsteps: '{0}' is not a surface (stone, tile, wood, metal, water)" -f $pr.Value) Yellow; continue }
        if ($pr.Name -eq 'default') { $f.RoomDefault = $sv } else { $f.Named[$pr.Name] = $sv }
    } }
}
function Step-Footsteps([single]$dtS, $m, [single[]]$dv, $room, [int[]]$dt, $texes) {
    if (-not $room -or -not $room.T) { return }
    if (-not $script:steps) {
        $script:steps = New-Object AztTool.Footsteps
        if ($BootSoundVolume -ge 0) { $script:steps.Sound.Volume = $BootSoundVolume }
        if ($FootstepVolume -ge 0) { $script:steps.Level = $FootstepVolume }
        $script:steps.Warm(); Set-RoomFootsteps $script:roomAtmNow
        Say ("footsteps: on (a walking step peaks at {0}; -NoFootsteps for none)" -f $script:steps.Level) DarkCyan
    }
    # the game's own effects setting (the system menu's SFX toggle and level, 0x14693A / 0x14693E), twice a second
    if (-not $script:stepsSfxAt -or $script:stepsSfxAt.ElapsedMilliseconds -gt 500) {
        $first = -not $script:stepsSfxAt; $script:stepsSfxAt = [Diagnostics.Stopwatch]::StartNew()
        $sb = $null
        try { if ($script:snapOn) { $sb = $hv.SnapBytes(0x14693A, 8) } elseif ($script:memAt -and $script:memAt.Snd) { $sb = [AztTool.ProcMem]::Read($g.ProcessId, $script:memAt.Snd, 8) } } catch { }
        if ($sb -and $sb.Length -ge 6) {
            $sOn = [BitConverter]::ToInt16($sb, 0) -ne 0; $sLv = [int][BitConverter]::ToInt16($sb, 4)
            $script:steps.SfxShare = $(if (-not $sOn) { 0.0 } elseif ($sLv -ge 0 -and $sLv -le 127) { $sLv / 127.0 } else { 1.0 })
            if ($first) { Say ("  footsteps: the game's effects {0}, level {1}/127" -f $(if ($sOn) { 'on' } else { 'OFF' }), $sLv) DarkGray }
        }
    }
    $quiet = $script:mapFreezeCam -or ($script:bootHd -and $script:bootHd.Covering) -or $script:roomCover -or $script:convWas -or ($script:visorMenu -and $script:visorMenu.AnyPlaying)
    $script:steps.Airborne = [bool]$script:jumpAir      # (no steps while a jump is in the air)
    $k = $script:steps.Update($dtS, $m[12], $m[13], $m[14], $dv, [int[]]$room.T, $dt, $texes, [bool]$quiet)
    if ($k -and ($script:steps.Steps -le 3 -or $k -ne $script:stepsLastKind)) { Say ("  footstep: {0}" -f $k) DarkGray }
    if ($k) { $script:stepsLastKind = $k }
}# THE JUMP (Josh, 2026-10-15). The game falls by itself: v = word [0x152592], each fall step (the 18.2 Hz tick under the host,
# AztFallGate) `eye -= v; v += 6` while the eye is more than v + 15 over its standing height, else it stands (v back to 0;
# damage only if v > 60). So a NEGATIVE v lifts the player -- and the host can steer every step: after each one v reads
# (written + 6), and the next value of the plan goes in. The plan (Get-JumpPlan) eases: rises 16 10 6 3 1 (the first must be
# >= 16 or the engine stands instead), JumpHang ticks held at the top, then 1 3 6 10 down, after which the engine's own +6s
# carry on until the floor takes it (a ledge, or a drop). The top is capped by the headroom (Footsteps.RayUp) so the eye
# never goes through a ceiling. Space presses come from the SpaceGuard's hook. No game code. [[azrael-jump]]
$script:fallAt = 0L; $script:jumpOn = $false; $script:jumpOff = $false; $script:jumpAir = $false; $script:jumpTaken = 0L; $script:jumpSaid = 0
$script:jumpPlan = $null; $script:jumpI = 0; $script:jumpW = 0; $script:jumpFree = $false; $script:jumpMaxV = 0; $script:jumpWrote = 0; $script:jumpRetry = $false
$script:jumpLand = [Diagnostics.Stopwatch]::StartNew(); $script:jumpUp = [Diagnostics.Stopwatch]::StartNew(); $script:jumpStep = [Diagnostics.Stopwatch]::StartNew()
function Write-Fall([int]$w) { $script:jumpW = $w; [void][AztTool.ProcMem]::Write($g.ProcessId, $script:fallAt, [BitConverter]::GetBytes([int16]$w)) }
function Get-JumpPlan([double]$fit) {
    $top = [Math]::Min([double]$JumpPower, $fit); if ($top -lt 16) { return $null }
    $k = ($top - 16) / 20.0; $plan = New-Object System.Collections.Generic.List[int]; $plan.Add(-16); $sum = 16
    foreach ($r in 10, 6, 3, 1) { $x = [int][Math]::Round($r * $k); if ($sum + $x -gt $top) { $x = [int][Math]::Floor($top - $sum) }; if ($x -gt 0) { $plan.Add(-$x); $sum += $x } }
    for ($i = 0; $i -lt [Math]::Max(0, $JumpHang); $i++) { $plan.Add(0) }
    foreach ($d in 1, 3, 6, 10) { $plan.Add($d) }
    @{ Steps = $plan.ToArray(); Top = $sum }
}
function Step-Jump($m, [single[]]$dv, $room, [int[]]$dt) {
    $sg = $script:spaceGuard; if (-not $sg -or -not $sg.JumpMode -or -not $script:fallAt) { return }
    $vb = [AztTool.ProcMem]::Read($g.ProcessId, $script:fallAt, 2); if (-not $vb -or $vb.Length -lt 2) { return }
    $v = [int][BitConverter]::ToInt16($vb, 0)
    if ($script:jumpAir) {
        $w = $script:jumpW
        if ($v -gt $script:jumpMaxV) { $script:jumpMaxV = $v }
        if ($script:jumpWrote -gt 0) {
            $script:jumpWrote--
            # (the standing snap can clear the take-off in the same instant -- once: write it again)
            if ($v -eq 0 -and $script:jumpI -eq 0 -and -not $script:jumpRetry) { $script:jumpRetry = $true; Write-Fall $script:jumpPlan.Steps[0]; return }
        }
        $d = $v - $w
        if ($d -gt 0 -and ($d % 6) -eq 0) {
            # the engine took d/6 steps since the last write: the plan's next value (past its end the engine's gravity alone)
            $script:jumpStep.Restart()
            if ($script:jumpFree) { $script:jumpW = $v }
            else {
                $script:jumpI += [int]($d / 6)
                if ($script:jumpI -lt $script:jumpPlan.Steps.Length) { Write-Fall $script:jumpPlan.Steps[$script:jumpI] } else { $script:jumpFree = $true; $script:jumpW = $v }
            }
            return
        }
        # landed: the floor took the eye (v back to 0 from a fall, or held at 0 through the top for over two ticks)
        $snapped = ($v -eq 0 -and $w -gt 0) -or ($v -eq 0 -and $w -eq 0 -and $script:jumpI -gt 0 -and $script:jumpStep.Elapsed.TotalSeconds -gt 0.15)
        if ($snapped) {
            $script:jumpAir = $false; $script:jumpLand.Restart()
            if ($script:steps) { $script:steps.JumpSound($true) }
            if ($LandBob -gt 0) { $script:eyeBob.Restart(); $script:eyeBobOn = $true }
            if ($script:jumpSaid -le 8) { Say ("  jump: landed after {0:N2} s (falling at {1} -- damage only past 60)" -f $script:jumpUp.Elapsed.TotalSeconds, $script:jumpMaxV) DarkGray }
        }
        elseif ($v -eq 0 -and $script:jumpI -eq 0 -and $script:jumpRetry -and $script:jumpWrote -le 0) { $script:jumpAir = $false }      # (it never left the ground)
        elseif ($script:jumpUp.Elapsed.TotalSeconds -gt 3 -and ($v -eq 0 -or $d % 6 -ne 0)) { $script:jumpAir = $false }      # (a room change / teleport reset it mid-jump)
    }
    $p = $sg.JumpPresses; if ($p -eq $script:jumpTaken) { return }
    $script:jumpTaken = $p
    $why = $(if ($script:mapFreezeCam) { 'the map is up' } elseif ($script:bootHd -and $script:bootHd.Covering) { 'a boot / load cover' } elseif ($script:roomCover) { 'the room is loading' }
             elseif ($script:convWas) { 'a conversation' } elseif ($script:visorMenu -and $script:visorMenu.AnyPlaying) { 'a visor menu' } elseif ($script:gpu -and $script:gpu.BlackView) { 'a close-up / book view' }
             elseif ($script:jumpAir -or $v -ne 0) { 'already in the air' } elseif ($script:jumpLand.Elapsed.TotalSeconds -lt 0.3) { 'just landed' } else { '' })
    if ($why) { if ($script:jumpSaid -le 8) { $script:jumpSaid++; Say ("  jump: not now ({0})" -f $why) DarkGray }; return }
    # the headroom: from the eye (the GAME's, not the eased view's) straight up to the lowest face over it, 12 units spare
    $gy = $(if ($null -ne $script:eyeGameY) { [single]$script:eyeGameY } else { [single]$m[13] })
    $room1 = [single]400
    try { $room1 = [AztTool.Footsteps]::RayUp($dv, [int[]]$room.T, $dt, [single]$m[12], $gy, [single]$m[14], [single]400) } catch { }
    $plan = Get-JumpPlan ($room1 - 12)
    if (-not $plan) { if ($script:jumpSaid -le 8) { $script:jumpSaid++; Say ("  jump: no headroom ({0:N0} units to the ceiling)" -f $room1) DarkGray }; return }
    $script:jumpPlan = $plan; $script:jumpI = 0; $script:jumpFree = $false; $script:jumpMaxV = 0; $script:jumpWrote = 2; $script:jumpRetry = $false
    Write-Fall $plan.Steps[0]
    $script:jumpUp.Restart(); $script:jumpStep.Restart(); $script:jumpAir = $true
    if ($script:steps) { $script:steps.JumpSound($false) }
    if ($script:jumpSaid -le 8) { $script:jumpSaid++; Say ("  jump: top {0} units ({1}; {2:N0} to the ceiling)" -f $plan.Top, ($plan.Steps -join ' '), $room1) DarkCyan }
}

# CROUCH (Josh, 2026-10-15: "make C a crouch key ... the player's head is getting caught on geometry ... crouched, they will
# move slightly slower to emulate sneaking"; then "make C a toggle for crouch, not hold to crouch"). All DATA, read only by the ground test and the movement step: the standing eye
# height (double 45.0 at 0x140328), the knee test (float -22 at 0x140340: raised as much as the eye comes down, so the
# player still steps up 23 units), and the walk / run step lengths (0x1417FC / 0x141800, scaled from what the game holds:
# the build has already rescaled them, and the host's frame-rate step rewrites them: crouchK is a factor inside that step,
# Set-MoveSteps). Lowering the eye lowers the wall tests with it (a ray at the eye, a point 8 below):
# beams, arches and overhangs pass over a crouched head. Down and up over CrouchTime, eased; lowered at most a few units a
# frame, so the engine snaps the eye down instead of falling. Stays down while the ceiling is too low to stand.
$script:crouchAt = $null; $script:crouchBase = $null; $script:crouchC = 0.0; $script:crouchWrote = 0.0; $script:crouchOff = $false
$script:bodyStand = 0.0; $script:bodyLift = 0.0
$script:crouchClock = [Diagnostics.Stopwatch]::StartNew(); $script:crouchSaid = 0; $script:crouchBlocked = $false; $script:crouchWas = $false
function Write-CrouchValues([double]$c) {
    $e = $c * $c * (3 - 2 * $c); $drop = $CrouchDrop * $e; $pid0 = $g.ProcessId
    [void][AztTool.ProcMem]::Write($pid0, $script:crouchAt.Eye, [BitConverter]::GetBytes([double](45 - $drop)))
    [void][AztTool.ProcMem]::Write($pid0, $script:crouchAt.Knee, [BitConverter]::GetBytes([single](-22 + $drop)))
    $script:crouchK = 1 - (1 - $CrouchSpeed) * $e; Set-MoveSteps
    $script:crouchWrote = $c
}
function Reset-Crouch {
    if ($script:crouchAt -and $script:crouchBase -and $g -and $script:crouchWrote -gt 0) { try { Write-CrouchValues 0 } catch { } }
    $script:crouchK = 1.0; $script:crouchC = 0.0; $script:crouchBase = $null; if ($script:steps) { $script:steps.Crouch = 0 }
}
function Step-Crouch($m, [single[]]$dv, $room, [int[]]$dt) {
    $sg = $script:spaceGuard; if (-not $sg -or -not $sg.CrouchMode -or -not $script:crouchAt) { return }
    $dtS = [Math]::Min(0.1, $script:crouchClock.Elapsed.TotalSeconds); $script:crouchClock.Restart()
    if (-not $script:crouchBase) {
        # the game's own values (a watcher that stopped while crouched left them part way: undo that share)
        $eye = [BitConverter]::ToDouble([AztTool.ProcMem]::Read($g.ProcessId, $script:crouchAt.Eye, 8), 0)
        $walk = [BitConverter]::ToSingle([AztTool.ProcMem]::Read($g.ProcessId, $script:crouchAt.Walk, 4), 0)
        $run = [BitConverter]::ToSingle([AztTool.ProcMem]::Read($g.ProcessId, $script:crouchAt.Run, 4), 0)
        $e = $(if ($eye -lt 44.99 -and $eye -gt 0 -and $CrouchDrop -gt 0) { [Math]::Min(1, (45 - $eye) / $CrouchDrop) } else { 0 })
        $k = 1 - (1 - $CrouchSpeed) * $e
        $script:crouchBase = @{ Walk = $walk / $k; Run = $run / $k }; $script:crouchWrote = $(if ($e -gt 0) { 1.0 } else { 0.0 }); $script:crouchC = $script:crouchWrote
    }
    $want = $(if ($sg.Crouched) { 1.0 } else { 0.0 }); $c = $script:crouchC
    if ($want -lt $c) {
        # coming up needs room over the head for what is left of the drop
        $gy = $(if ($null -ne $script:eyeGameY) { [single]$script:eyeGameY } else { [single]$m[13] })
        $up = [single]400; try { $up = [AztTool.Footsteps]::RayUp($dv, [int[]]$room.T, $dt, [single]$m[12], $gy, [single]$m[14], [single]400) } catch { }
        $left = $CrouchDrop * $c * $c * (3 - 2 * $c)
        if ($up - 8 -lt $left) { $want = $c; if (-not $script:crouchBlocked -and $script:crouchSaid -le 8) { $script:crouchSaid++; Say ("  crouch: staying down -- {0:N0} units over the head" -f $up) DarkGray }; $script:crouchBlocked = $true }
        else { $script:crouchBlocked = $false }
    }
    $rate = $dtS / [Math]::Max(0.01, $CrouchTime)
    if ($want -gt $c) { $c = [Math]::Min($want, $c + $rate) } elseif ($want -lt $c) { $c = [Math]::Max($want, $c - $rate) }
    $script:crouchC = $c
    if ($script:steps) { $script:steps.Crouch = $c * $c * (3 - 2 * $c) }      # (crouched steps play quieter: Footsteps.CrouchLevel)
    if ($sg.Crouched -ne $script:crouchWas) { $script:crouchWas = $sg.Crouched; if ($script:crouchSaid -le 8) { $script:crouchSaid++; Say ("  crouch: {0} (step x{1:N2})" -f $(if ($sg.Crouched) { 'down' } else { 'up' }), $(if ($sg.Crouched) { $CrouchSpeed } else { 1.0 })) DarkGray } }
    if ([Math]::Abs($c - $script:crouchWrote) -lt 1e-4) { return }
    Write-CrouchValues $c
}

# THE VIEW'S HEIGHT, EASED (Josh, 2026-10-15: the jump "feels a little up and down harsh, like an ease at the top would be
# ideal, and a very slight head bob on landing"). The game moves the eye in 18.2 Hz steps (a jump's rises and falls, its
# landing snap, a stair); the frame's copy of the camera follows each step over one tick instead of jumping, and a jump's
# landing dips it LandBob units and back (a half sine over LandBobTime). Only this frame's copy -- as the stand-up tilt.
$script:eyeDisp = $null; $script:eyeVel = 0.0; $script:eyeGameY = $null; $script:eyeBobOn = $false
$script:eyeClock = [Diagnostics.Stopwatch]::StartNew(); $script:eyeBob = [Diagnostics.Stopwatch]::StartNew()
# (The first version eased each game step over one tick, measured from the step -- and restarted on every change, so while
# walking, where the height changes a little nearly every frame, the view's height FROZE until the player stopped: Josh,
# "the character won't crouch/stand after pressing C until I stop walking". Now a smooth-damp follow, closed form so any
# frame time is stable: it always moves toward the game's height, ~EyeSmoothTime behind.)
$EyeSmoothTime = 0.06
function Step-EyeSmooth($m) {
    $gy = [double]$m[13]; $script:eyeGameY = $gy
    $dtE = [Math]::Max(0.0005, [Math]::Min(0.1, $script:eyeClock.Elapsed.TotalSeconds)); $script:eyeClock.Restart()
    if ($NoEyeSmooth -or $Retro -or $script:mapFreezeCam) { $script:eyeDisp = $null; return }
    if ($null -eq $script:eyeDisp -or [Math]::Abs($gy - $script:eyeDisp) -gt 80) { $script:eyeDisp = $gy; $script:eyeVel = 0.0; $script:eyeBobOn = $false; return }
    $om = 2.0 / $EyeSmoothTime; $x = $om * $dtE; $ex = 1.0 / (1.0 + $x + 0.48 * $x * $x + 0.235 * $x * $x * $x)
    $ch = $script:eyeDisp - $gy; $tmp = ($script:eyeVel + $om * $ch) * $dtE
    $script:eyeVel = ($script:eyeVel - $om * $tmp) * $ex
    $script:eyeDisp = $gy + ($ch + $tmp) * $ex
    $y = $script:eyeDisp
    if ($script:eyeBobOn) {
        $tb = $script:eyeBob.Elapsed.TotalSeconds
        if ($tb -ge $LandBobTime) { $script:eyeBobOn = $false } else { $y -= $LandBob * [Math]::Sin([Math]::PI * $tb / $LandBobTime) }
    }
    $m[13] = [single]$y
}$script:echoLabels = $null; $script:echoLabelsRoom = $null; $script:echoModelSaid = @{}
function Get-PartSpan($room, $pt) {
    $v = $room.V; $lo = @(1e9, 1e9, 1e9); $hi = @(-1e9, -1e9, -1e9)
    for ($i = [int]$pt.VFirst; $i -lt [int]$pt.VFirst + [int]$pt.VCount; $i++) { for ($k = 0; $k -lt 3; $k++) { $q = $v[$i * 3 + $k]; if ($q -lt $lo[$k]) { $lo[$k] = $q }; if ($q -gt $hi[$k]) { $hi[$k] = $q } } }
    return [Math]::Max($hi[0] - $lo[0], [Math]::Max($hi[1] - $lo[1], $hi[2] - $lo[2]))
}
# a part's middle in this frame's geometry
function Get-PartMid([single[]]$vx, $pt) {
    $lo = @(1e9, 1e9, 1e9); $hi = @(-1e9, -1e9, -1e9); $e = [Math]::Min([int]($vx.Length / 3), [int]$pt.VFirst + [int]$pt.VCount)
    for ($i = [int]$pt.VFirst; $i -lt $e; $i++) { for ($k = 0; $k -lt 3; $k++) { $q = $vx[$i * 3 + $k]; if ($q -lt $lo[$k]) { $lo[$k] = $q }; if ($q -gt $hi[$k]) { $hi[$k] = $q } } }
    return @((($lo[0] + $hi[0]) / 2), (($lo[1] + $hi[1]) / 2), (($lo[2] + $hi[2]) / 2))
}
function Step-Echo($gq, $room, [single[]]$dv, [int[]]$dt) {
    if ($NoEcho -or -not $gq) { return }
    $down = $false; try { $down = [AztTool.Keys]::DownInProcess($EchoKey, $g.ProcessId) } catch { }
    $press = $down -and -not $script:echoWas; $script:echoWas = $down
    $blocked = $script:mapFreezeCam -or ($script:bootHd -and $script:bootHd.Covering) -or $script:roomCover
    if ($press -and -not $blocked -and $room -and $room.TriPart) {
        if (-not $script:echoObjs) {
            $script:echoObjs = New-Object AztTool.ScanWire
            try { $op = Join-Path (Join-Path (Split-Path $TexDir -Parent) 'AZRAEL') 'OBJECTS.DAT'; if (Test-Path $op) { [void]$script:echoObjs.LoadObjects($op) } } catch { }
        }
        $doors = New-Object 'System.Collections.Generic.List[int]'; $items = New-Object 'System.Collections.Generic.List[int]'; $chars = New-Object 'System.Collections.Generic.List[int]'
        $kind = @{}; $lockPi = @{}
        for ($i = 0; $i -lt $room.Parts.Count; $i++) {
            $pt = $room.Parts[$i]; $nm = [string]$pt.Name
            $lockList = $EchoLockedDoors[[IO.Path]::GetFileNameWithoutExtension([string]$pt.Room).ToUpperInvariant()]
            if (-not $pt.IsCharacter -and $lockList -and ($lockList -contains $nm)) { $kind[$i] = 0; $lockPi[$i] = 1 }
            elseif ($pt.IsCharacter) { $kind[$i] = 2 }
            elseif ($nm -match '(?i)(door|gate)' -and $nm -notmatch '(?i)wall') { $kind[$i] = 0 }
            elseif ($script:echoObjs.IsObjectPart($nm) -and $nm -notmatch '^(?i)z[xy]' -and (Get-PartSpan $room $pt) -le 160) { $kind[$i] = 1 }      # (things to take or use: not trigger planes, not a rafter or a bath)
        }
        $tp = $room.TriPart; $firstTri = @{}
        for ($t = 0; $t -lt $tp.Length; $t++) {
            $pi = [int]$tp[$t]; if ($pi -lt 0 -or -not $kind.ContainsKey($pi)) { continue }
            if ($dt -and $t -lt $dt.Length -and $dt[$t] -lt 0) { continue }      # (taken away: no longer in the scene -- or never drawn)
            switch ($kind[$pi]) { 0 { $doors.Add($t) } 1 { $items.Add($t) } 2 { $chars.Add($t) } }
            if (-not $firstTri.ContainsKey($pi)) { $firstTri[$pi] = $t }
        }
        # each doorway's opening, as the portal map has it in this room's coordinates
        $segs = New-Object 'System.Collections.Generic.List[single]'
        try {
            foreach ($f in @([string]$script:rapRoom -split '\+')) {
                if (-not $script:AztPortalMap) { [void](Get-AztMapDoors -Files @($f)) }
                $prop = $script:AztPortalMap.PSObject.Properties[$f.ToUpper()]; if (-not $prop) { continue }
                foreach ($e in @($prop.Value)) {
                    $q = @($e.farQuad); if ($q.Count -lt 12) { continue }
                    for ($c = 0; $c -lt 4; $c++) { $n = ($c + 1) % 4; foreach ($k in 0..2) { $segs.Add([single]$q[$c * 3 + $k]) }; foreach ($k in 0..2) { $segs.Add([single]$q[$n * 3 + $k]) } }
                }
            }
        } catch { }
        $gq.SetEchoTargets(0, $doors.ToArray(), $segs.ToArray()); $gq.SetEchoTargets(1, $items.ToArray(), $null); $gq.SetEchoTargets(2, $chars.ToArray(), $null)
        # THE LABELS (ScanWire.cs EchoLabels; Josh, 2026-10-15): a tooltip over each thing that can be PICKED UP (OBJECTS.DAT's
        # action 6, IsTakePart), each INTERACTIVE object (IsInteractivePart), each HUMANOID and each CREATURE (by the character's model:
        # $EchoCreatures) -- pickups and interactive objects 20 s, characters 3 s (EchoLabels.HoldOf) -- renewed by
        # every scan. A character is all its bone parts (one ZZnnnn prefix).
        if (-not $NoEchoLabels) {
            if (-not $script:echoLabels) { $script:echoLabels = New-Object AztTool.EchoLabels }
            $script:echoLabels.Begin(); $script:echoLabelsRoom = $room; $script:echoLabels.Rest = [single[]]$room.V
            $nI = 0; $nX = 0; $nH = 0; $nC = 0; $nL = 0; $byChar = @{}
            # A BOLT IS A LOCK (Josh, 2026-10-15: a barred door's bolt read "Interactive item detected."): the game files its bolts
            # ('Bolt', action 8) as things to use, but a shot bolt is what keeps its door shut -- so the door nearest each bolt
            # (within 250 units) reads "Locked door." (pinned to the door; the bolt and the door together, so drawing the bolt back
            # or opening the door takes it away), and the bolt itself gets no tooltip.
            $boltDoor = @{}
            foreach ($bi in @($firstTri.Keys)) {
                if ($kind[$bi] -ne 1 -or [string]$room.Parts[$bi].Name -notmatch '(?i)bolt') { continue }
                $bm = Get-PartMid $dv $room.Parts[$bi]; $best = -1; $bd = 250.0
                foreach ($di in @($firstTri.Keys)) {
                    if ($kind[$di] -ne 0) { continue }
                    $dm = Get-PartMid $dv $room.Parts[$di]; $dd = [Math]::Sqrt(($dm[0] - $bm[0]) * ($dm[0] - $bm[0]) + ($dm[1] - $bm[1]) * ($dm[1] - $bm[1]) + ($dm[2] - $bm[2]) * ($dm[2] - $bm[2]))
                    if ($dd -lt $bd) { $bd = $dd; $best = $di }
                }
                $boltDoor[$bi] = $best
            }
            foreach ($bi in @($boltDoor.Keys)) {
                $di = $boltDoor[$bi]; $bp = $room.Parts[$bi]
                if ($di -lt 0) { continue }
                $dp = $room.Parts[$di]; $lockPi.Remove($di)
                $script:echoLabels.Add(4, [int[]]@([int]$dp.VFirst, [int]$bp.VFirst), [int[]]@([int]$dp.VCount, [int]$bp.VCount), [int]$firstTri[$di]); $nL++
            }
            foreach ($pi in @($firstTri.Keys)) {
                $pt = $room.Parts[$pi]; $nm = [string]$pt.Name
                if ($boltDoor.ContainsKey($pi)) { continue }      # (the bolt: its door carries the label)
                if ($lockPi.ContainsKey($pi)) { $script:echoLabels.Add(4, [int[]]@([int]$pt.VFirst), [int[]]@([int]$pt.VCount), [int]$firstTri[$pi]); $nL++; continue }
                if ($kind[$pi] -eq 1 -and $script:echoObjs.IsTakePart($nm)) { $script:echoLabels.Add(0, [int[]]@([int]$pt.VFirst), [int[]]@([int]$pt.VCount), [int]$firstTri[$pi]); $nI++ }
                elseif ($kind[$pi] -eq 1 -and $script:echoObjs.IsInteractivePart($nm)) { $script:echoLabels.Add(3, [int[]]@([int]$pt.VFirst), [int[]]@([int]$pt.VCount), [int]$firstTri[$pi]); $nX++ }      # (levers, wheels, handles...: "Interactive object.")
                elseif ($kind[$pi] -eq 2) {
                    $pre = $(if ($nm -match '^(?i)ZZ\d{4}') { $nm.Substring(0, 6).ToUpperInvariant() } else { [string]$pt.Room })
                    if (-not $byChar.ContainsKey($pre)) { $byChar[$pre] = New-Object 'System.Collections.Generic.List[int]' }
                    $byChar[$pre].Add($pi)
                }
            }
            foreach ($pre in $byChar.Keys) {
                $ps = $byChar[$pre]; $vf = New-Object int[] $ps.Count; $vc = New-Object int[] $ps.Count
                for ($q = 0; $q -lt $ps.Count; $q++) { $vf[$q] = [int]$room.Parts[$ps[$q]].VFirst; $vc[$q] = [int]$room.Parts[$ps[$q]].VCount }
                $model = [IO.Path]::GetFileNameWithoutExtension([string]$room.Parts[$ps[0]].Room).ToUpperInvariant()
                $isCreature = $model -match $EchoCreatures
                $script:echoLabels.Add($(if ($isCreature) { 2 } else { 1 }), $vf, $vc, -1)
                if ($isCreature) { $nC++ } else { $nH++ }
                if (-not $script:echoModelSaid.ContainsKey($model)) { $script:echoModelSaid[$model] = 1; Say ("  echo labels: {0} is {1}" -f $model, $(if ($isCreature) { 'a creature (Live fauna detected)' } else { 'a humanoid (Humanoid figure detected)' })) DarkGray }
            }
            Say ("  echo labels: {0} pickup(s), {1} interactive, {2} locked door(s), {3} humanoid(s), {4} creature(s)" -f $nI, $nX, $nL, $nH, $nC) DarkCyan
        }
        $script:echoChars = $chars.ToArray()
        $script:echoClock = [Diagnostics.Stopwatch]::StartNew()
        if (-not $NoBootSound) { if (-not $script:echoSound) { $script:echoSound = New-Object AztTool.BootSound; if ($BootSoundVolume -ge 0) { $script:echoSound.Volume = $BootSoundVolume } }; try { $script:echoSound.SonarPing() } catch { } }
        Say ("echo scan: {0} door triangle(s) + {1} doorway(s), {2} item triangle(s), {3} creature triangle(s)" -f $doors.Count, [int]($segs.Count / 24), $items.Count, $chars.Count) DarkCyan
    }
    if ($script:echoClock) {
        $t = $script:echoClock.Elapsed.TotalSeconds
        if ($t -gt ($gq.EchoMax / [Math]::Max(1, $gq.EchoSpeed)) + 4 * $gq.EchoFade -or $blocked) { $script:echoClock = $null; $gq.EchoT = -1 }
        else {
            $gq.EchoT = [single]$t
            if ($script:echoChars -and $script:echoChars.Length) { $gq.SetEchoTargets(2, $script:echoChars, $null) }      # (creatures move: their outlines again from this frame's pose)
        }
    }
    if ($script:echoLabels) {
        if (-not [object]::ReferenceEquals($script:echoLabelsRoom, $room)) { $script:echoLabels.Clear(); $script:echoLabelsRoom = $room }      # (another room: its vertex ranges mean nothing here)
        $hideL = $blocked -or $script:convWas -or ($script:visorMenu -and $script:visorMenu.AnyPlaying) -or $gq.BlackView
        $script:echoLabels.Step($gq, $dv, $dt, [single]$gq.EchoSpeed, [bool]$hideL)
    }
}
# ROOMS VISITED -- THE SAVE'S OWN (Josh, 2026-10-14: "If starting a new game, I should only see the first room on the map ... This
# needs to be tied to the individual save file"). The game keeps them itself: 100 words at 0x162E4C, one per MAPS.DAT room number,
# set to 1 on entering a room (0x11591), cleared for a new game (0x1148E), and WRITTEN TO / READ FROM the save file with it (the
# save routine's fwrite at 0x2270B and the load's fread at 0x22891, 0xC8 bytes each). Its old map screen drew a neighbour's
# thumbnail only if its word was set. Here: the words read when the map opens, each number turned into the room's file by
# MAPS.DAT's numbering -- a seed table below, and every number the watcher sees the player standing in (word [[0x1841C8]], the
# map toggle's own room) learned and kept in <CacheDir>\room-numbers.json. A room whose number is not known yet is left off.
$script:roomNumSeed = @{ 0 = 'CORICORI'; 1 = 'WASHCORI'; 2 = 'SPAROOM'; 3 = 'MINEMAZE'; 4 = 'CHAMBNEW'; 5 = 'ORRERY'; 6 = 'BAPTIST'; 7 = 'MINEHEAD'
    8 = 'TUNNMAZE'; 9 = 'WELLROOM'; 10 = 'CHAPEL'; 11 = 'VESTRY'; 12 = 'CLOISIM6'; 15 = 'EDCRTSIM'; 22 = 'INTRVIEW'; 23 = 'LAB'; 24 = 'ATUNNEL2'
    27 = 'DRAIN1'; 28 = 'D3-D9'; 29 = 'DRAIN5'; 30 = 'DRAIN7'; 35 = 'ENTRY_D'; 36 = 'EXEC_R'; 37 = 'TREEMAZE'; 38 = 'COB_LAIR'; 39 = 'CLOCK'
    40 = 'KITCHEN'; 41 = 'GSTUDIO'; 42 = 'MEATLOCK'; 43 = 'ZIGURRAT'; 49 = 'CRYPT'; 56 = 'R43'; 57 = 'LIGHT'; 58 = 'THEOTRAP'; 59 = 'DECISION'
    60 = 'MAL_LAB1'; 61 = 'POIS_GR'; 64 = 'AQUADUCT'; 65 = 'WWCA'; 66 = 'FIGHT_R'; 67 = 'TUNNJ' }
$script:roomNums = $null
function Get-RoomNumbers {
    if ($null -eq $script:roomNums) {
        $script:roomNums = @{}; foreach ($k in $script:roomNumSeed.Keys) { $script:roomNums[[int]$k] = $script:roomNumSeed[$k] }
        try { $rp = Join-Path $CacheDir 'room-numbers.json'; if (Test-Path $rp) { $j = [IO.File]::ReadAllText($rp) | ConvertFrom-Json; foreach ($pp in $j.PSObject.Properties) { $script:roomNums[[int]$pp.Name] = ([string]$pp.Value).ToUpperInvariant() } } } catch { }
    }
    return $script:roomNums
}
function Get-GameRoomNumber {
    try {
        $po = [uint32]$(if ($script:snapOn) { $hv.SnapU32(0x1841C8) } else { RdU32 ([long]($g.MemBase + 0x1841C8 + $script:memAt.D2)) })
        if ($po -lt 0x1000 -or $po -ge 0x10000000) { return -1 }
        $n = [int]((RdU32 ([long]$g.MemBase + $po)) -band 0xFFFF); if ($n -ge 0 -and $n -lt 100) { return $n }
    } catch { }
    return -1
}
# (the player is in $name: its number, learned -- a new pairing is kept)
function Note-RoomNumber([string]$name) {
    if (-not $name -or -not $script:memAt) { return }
    $n = Get-GameRoomNumber; if ($n -lt 0) { return }
    $rn = Get-RoomNumbers; $u = $name.ToUpperInvariant()
    if ($rn[$n] -ne $u) {
        $rn[$n] = $u
        try { $o = [ordered]@{}; foreach ($k in ($rn.Keys | Sort-Object)) { if ($script:roomNumSeed[$k] -ne $rn[$k]) { $o[[string]$k] = $rn[$k] } }; [IO.File]::WriteAllText((Join-Path $CacheDir 'room-numbers.json'), ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) } catch { }
        Say ("map: room number {0} is {1}" -f $n, $u) DarkCyan
    }
}
# the rooms this save has visited, as room files ($null when they cannot be read: the host's own list is used instead)
# THE ITEMS THE PLAYER CAN PICK UP (Josh, 2026-10-14, Room Review MINEMAZE/12: "Omit all items that are able to be picked up from the
# player from all maps"). Nothing in OBJECTS.DAT or OBJLIST.DAT marks them (checked); an item reaches the inventory only through the
# game's scripts: command 08 (AddInventoryItem 0x288E2, the script interpreter's case 0x2AFAC; 09 takes one away). The scripts, as the
# game decoded them from world.dat, are in its memory: [0x1841F0] = word count of lists, [0x1841F4] = 6-byte {word count, dword ->
# command pointers}; a command = byte op, word object id. Read once a session (the game has loaded its world), each id turned into its
# room part by OBJECTS.DAT's record of that number -- trusted only when the game's own object table ([0x1841D0], name at +0x3F) shows
# the same names -- and kept in <CacheDir>\pickups.json, which Get-AztMapSkip reads for every room's map (and Room Review's map look).
$script:pickupsDone = $false; $script:pickupsTry = $null
function Update-Pickups {
    if ($script:pickupsDone -or -not $script:memAt -or -not $g) { return }
    if ($script:pickupsTry -and $script:pickupsTry.Elapsed.TotalSeconds -lt 10) { return }
    $script:pickupsTry = [Diagnostics.Stopwatch]::StartNew()
    try {
        $d2 = [long]$script:memAt.D2; $mb = [long]$g.MemBase; $pid0 = $g.ProcessId
        $rd = { param([long]$a, [int]$n) [AztTool.ProcMem]::Read($pid0, $a, $n) }
        $nl = [BitConverter]::ToUInt16((& $rd ($mb + 0x1841F0 + $d2) 2), 0)
        $tbl = [BitConverter]::ToUInt32((& $rd ($mb + 0x1841F4 + $d2) 4), 0)
        if ($nl -le 0 -or $nl -gt 20000 -or $tbl -lt 0x1000 -or $tbl -ge 0x10000000) { return }      # (no world yet)
        $lists = & $rd ($mb + $tbl) ($nl * 6)
        $ids = @{}
        for ($i = 0; $i -lt $nl; $i++) {
            $cnt = [BitConverter]::ToUInt16($lists, $i * 6); $ptr = [BitConverter]::ToUInt32($lists, $i * 6 + 2)
            if ($cnt -le 0 -or $cnt -gt 5000 -or $ptr -lt 0x1000 -or $ptr -ge 0x10000000) { continue }
            $cp = & $rd ($mb + $ptr) ($cnt * 4)
            for ($j = 0; $j -lt $cnt; $j++) {
                $c = [BitConverter]::ToUInt32($cp, $j * 4); if ($c -lt 0x1000 -or $c -ge 0x10000000) { continue }
                $cb = & $rd ($mb + $c) 3
                if ($cb[0] -eq 8) { $ids[[int][BitConverter]::ToUInt16($cb, 1)] = 1 }
            }
        }
        if ($ids.Count -eq 0) { return }
        # OBJECTS.DAT: display name +0, object name +0x3C, room part +0x78 (603-byte records after a word count)
        $op = Join-Path (Join-Path (Split-Path $TexDir -Parent) 'AZRAEL') 'OBJECTS.DAT'; $ob = [IO.File]::ReadAllBytes($op); $on = [BitConverter]::ToUInt16($ob, 0)
        $str = { param([byte[]]$b, [int]$p, [int]$len) $e = $p; while ($e -lt $p + $len -and $e -lt $b.Length -and $b[$e] -ne 0) { $e++ }; [Text.Encoding]::ASCII.GetString($b, $p, $e - $p) }
        $otab = [BitConverter]::ToUInt32((& $rd ($mb + 0x1841D0 + $d2) 4), 0)
        $objs = New-Object 'System.Collections.Generic.List[object]'; $same = 0; $checked = 0
        foreach ($id in ($ids.Keys | Sort-Object)) {
            if ($id -ge $on) { continue }
            $rec = 2 + $id * 603; $disp = & $str $ob $rec 0x3C; $part = & $str $ob ($rec + 0x78) 0x53
            $live = ''
            try { $lo = [BitConverter]::ToUInt32((& $rd ($mb + $otab + $id * 4) 4), 0); if ($lo -ge 0x1000 -and $lo -lt 0x10000000) { $live = & $str (& $rd ($mb + $lo + 0x3F) 0x3C) 0 0x3C } } catch { }
            if ($live) { $checked++; if ($live -eq $disp) { $same++ } }
            $objs.Add([ordered]@{ id = $id; name = $disp; object = (& $str $ob ($rec + 0x3C) 0x3C); part = $part })
        }
        if ($checked -lt 3 -or $same -lt 0.8 * $checked) { Say ("pickups: the game's object names do not line up with OBJECTS.DAT ({0} of {1}) -- not used" -f $same, $checked) Yellow; $script:pickupsDone = $true; return }
        $parts = @($objs | ForEach-Object { $_.part } | Where-Object { $_ } | Sort-Object -Unique)
        $doc = [ordered]@{ about = 'Items the player can pick up: every object the game''s scripts add to the inventory (command 08), read from its memory by Watch-HostRender (Update-Pickups). Get-AztMapSkip leaves these parts off every map.'; made = [DateTime]::UtcNow.ToString('o'); parts = $parts; objects = $objs.ToArray() }
        $pf = Join-Path $CacheDir 'pickups.json'; $js = ConvertTo-Json $doc -Depth 5
        $old = $(if (Test-Path $pf) { try { ([IO.File]::ReadAllText($pf) | ConvertFrom-Json).parts -join '|' } catch { '' } } else { '' })
        if ($old -ne ($parts -join '|')) { [IO.File]::WriteAllText($pf, $js, (New-Object Text.UTF8Encoding $false)); Say ("pickups: {0} items the player can pick up ({1} room parts) -- left off every map; pickups.json written" -f $objs.Count, $parts.Count) Cyan }
        else { Say ("pickups: {0} items the player can pick up, as before" -f $objs.Count) DarkCyan }
        $script:pickupsDone = $true
    } catch { Say ("pickups: could not read the game's scripts ({0})" -f $_.Exception.Message) Yellow }
}
function Get-GameVisited {
    if (-not $script:memAt) { return $null }
    try { $vb = [AztTool.ProcMem]::Read($g.ProcessId, [long]($g.MemBase + 0x162E4C + $script:memAt.D2), 200) } catch { return $null }
    if (-not $vb -or $vb.Length -lt 200) { return $null }
    $rn = Get-RoomNumbers; $out = New-Object 'System.Collections.Generic.List[string]'
    for ($n = 0; $n -lt 100; $n++) { if ([BitConverter]::ToInt16($vb, $n * 2) -ne 0 -and $rn.ContainsKey($n) -and -not $out.Contains($rn[$n])) { $out.Add($rn[$n]) } }
    return ,$out
}
# ROOMS VISITED, for the whole-complex map (Josh, 2026-10-14): every room the watcher sees the player in, kept in
# <CacheDir>\visited-rooms.json across sessions, emptied when a NEW game boots (a load keeps it: the map shows what this
# machine's player has seen).
$script:mapVisited = $null
function Get-MapVisited {
    if ($null -eq $script:mapVisited) {
        $script:mapVisited = New-Object 'System.Collections.Generic.List[string]'
        try { $vp = Join-Path $CacheDir 'visited-rooms.json'; if (Test-Path $vp) { foreach ($v in @(([IO.File]::ReadAllText($vp) | ConvertFrom-Json).rooms)) { if ($v) { $script:mapVisited.Add(([string]$v).ToUpperInvariant()) } } } } catch { }
    }
    return ,$script:mapVisited      # (the list itself: returned bare, an empty one comes back as nothing -- 2026-10-14, it ended the session)
}
function Save-MapVisited { try { [IO.File]::WriteAllText((Join-Path $CacheDir 'visited-rooms.json'), (@{ rooms = @($script:mapVisited); at = (Get-Date).ToString('s') } | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) } catch { } }
function Add-MapVisited([string]$name) {
    if (-not $name) { return }; $v = Get-MapVisited; $u = $name.ToUpperInvariant()
    if (-not $v.Contains($u)) { $v.Add($u); Save-MapVisited }
}
function Clear-MapVisited { $v = Get-MapVisited; if ($v.Count) { $v.Clear(); Save-MapVisited; Say 'map: a new game -- rooms visited cleared' DarkCyan } }
function Step-Map {
    $gq = $script:gpu
    # THE GAME'S OWN MAP is not drawn at all while the host draws the 3D map (AztMapBlit reads aztOldMapOff; 0 again on close)
    if ($S_oldMapOff -and $hv -and (-not $script:oldMapWr -or $script:oldMapWr.ElapsedMilliseconds -ge 500)) {
        try { [void]$hv.WriteU32((HostLin $S_oldMapOff), [uint32]$(if ($NoMap3D -or -not $gq) { 0 } else { 1 })) } catch { }
        if ($script:oldMapWr) { $script:oldMapWr.Restart() } else { $script:oldMapWr = [Diagnostics.Stopwatch]::StartNew() }
    }
    if ($script:learnRoomAt -and $script:learnRoomAt.Elapsed.TotalSeconds -ge 2 -and $script:memAt) { try { if (([string]$script:rapRoom -split '\+')[0] -eq $script:learnRoom) { Note-RoomNumber $script:learnRoom } } catch { }; $script:learnRoomAt = $null }
    if ($NoMap3D -or -not $gq -or -not $script:memAt) { return $false }
    $open = $false; $w = GuestWord 0x1525F2; if ($null -ne $w) { $open = $w -ne 0 }
    $rname = ([string]$script:rapRoom -split '\+')[0]
    if ($open -and -not $script:mapOpen) {
        $script:mapHelp = Test-MapIsHelp
        try { Update-Pickups } catch { }      # (the items the player can pick up: off every map -- once a session)
        $script:map3d = (-not $script:mapHelp) -and ($Map3DAll -or (@($Map3DRooms) -contains '*') -or (@($Map3DRooms | ForEach-Object { $_.ToUpperInvariant() }) -contains $rname.ToUpperInvariant()))
        if ($script:map3d) {
            $mrj = Join-Path (Join-Path $CacheDir 'rooms') ($rname.ToUpper() + '.json'); $mst = $(if (Test-Path $mrj) { (Get-Item $mrj).LastWriteTimeUtc.Ticks } else { 0 }); $pkf = Join-Path $CacheDir 'pickups.json'; if (Test-Path $pkf) { $mst = [string]$mst + '|' + (Get-Item $pkf).LastWriteTimeUtc.Ticks }      # (its "map" settings: "hide")
            if ($script:mapDoorsFor -ne $script:rapRoom -or $script:mapSkipRoom -ne $room -or $script:mapSkipStamp -ne $mst) {
                $script:mapDoorsFor = $script:rapRoom; $script:mapSkipRoom = $room; $script:mapSkipStamp = $mst
                $mfiles = @([string]$script:rapRoom -split '\+')
                $script:mapDoors = Get-AztMapDoors -Files $mfiles
                # (the doorway pictures -- the parked alternates float outside the room -- and the characters: left out of the map)
                $mskip = @(); try { if ($room -and $room.Parts) { $mskip = Get-AztMapSkip -Room $room -Files $mfiles } } catch { Say ("map: its doorway pictures could not be found ({0})" -f $_.Exception.Message) Yellow }
                $gq.SetMapSkip([int[]]$mskip)
                # (its cut under the floor -- a room's map.hideBelow / keep, Room Review MINEHEAD/8: walls running on down under the floor end there)
                $mcut = $null; try { if ($room -and $room.Parts) { $mcut = Get-AztMapCut -Room $room -Files $mfiles } } catch { }
                if ($mcut) { $gq.SetMapCut([single]$mcut.Y, [bool[]]$mcut.Tris) } else { $gq.SetMapCut([single]::NaN, $null) }
            }
            # the world held still behind it, and the map turned to look the way the player does
            $cam = $null; try { $cam = [single[]]$script:lastCamM } catch { }
            if ($cam -and $cam.Length -ge 16) { $script:mapFreezeCam = [single[]]$cam.Clone(); $script:mapYawT = [Math]::Atan2(-$cam[8], -$cam[10]) * 180 / [Math]::PI } else { $script:mapFreezeCam = $null }
            $script:mapYaw = $script:mapYawT; $script:mapPitch = $script:mapPitchT = 52.0; $script:mapZoom = $script:mapZoomT = $MapZoomStart      # (Josh, 2026-10-14: "more zoomed in by default")
            $script:mapIntroClock = [Diagnostics.Stopwatch]::StartNew()      # (THE MAP PULSES IN: GpuRaster.MapIntro)
            # THE WHOLE COMPLEX round it: the visited rooms placed through the doorways, their unvisited neighbours faint
            # (LoadRoom.ps1 Get-AztComplex); shown as the map zooms out past the room
            # (THE SAVE'S OWN visited rooms -- the game's words, saved and loaded with it; the host's list only if they cannot be read)
            try { Note-RoomNumber $rname } catch { }
            $vl = $null; try { $vl = Get-GameVisited } catch { }
            if ($null -eq $vl) { $vl = New-Object 'System.Collections.Generic.List[string]'; foreach ($v in (Get-MapVisited)) { $vl.Add($v) } }
            if (-not $vl.Contains($rname.ToUpperInvariant())) { $vl.Add($rname.ToUpperInvariant()) }
            $csig = $rname + '|' + ($vl -join ',')
            if ($script:complexSig -ne $csig) {
                $script:complexSig = $csig; $sw = [Diagnostics.Stopwatch]::StartNew()
                try {
                    $cx = Get-AztComplex -Root $rname -Visited @($vl) -CacheDir $CacheDir
                    if ($cx -and $cx.T.Length) { $gq.SetMapComplex([single[]]$cx.V, [int[]]$cx.T, [int[]]$cx.G); Say ("map: the complex round it -- {0} ({1:N0} ms)" -f ($cx.Rooms -join ', '), $sw.Elapsed.TotalMilliseconds) Cyan }
                    else { $gq.SetMapComplex($null, $null, $null) }
                } catch { Say ("map: the complex could not be laid out ({0})" -f $_.Exception.Message) Yellow; $gq.SetMapComplex($null, $null, $null) }
            }
            Set-MapHot
            if (-not $script:mapMouse) { $script:mapMouse = New-Object AztTool.RawMouse; $script:mapMouse.GamePid = [int]$g.ProcessId; if (-not $script:mapMouse.Start()) { Say ("map: the mouse cannot turn it ({0})" -f $script:mapMouse.StartError) Yellow } }
            Say ("map: the 3D map of {0} -- {1} door(s): {2}; drag to turn, wheel to come closer" -f $rname, @($script:mapDoors.Doors).Count, ((@($script:mapDoors.Doors) | ForEach-Object { $_.To }) -join ', ')) Cyan
        } elseif ($script:mapHelp) { Say 'map: the help screen (the game''s own)' DarkGray }
        else { Say ("map: the game's own map ({0} has no 3D map yet: -Map3DRooms / -Map3DAll)" -f $rname) DarkGray }
    }
    if (-not $open -and $script:mapOpen) {
        Restore-MapHot
        if ($script:mapMouse) { try { $script:mapMouse.Dispose() } catch { }; $script:mapMouse = $null }
        $script:mapFreezeCam = $null
    }
    $script:mapOpen = $open
    $up = $open -and $script:map3d
    # the fade: in over 0.35 s, out over 0.2 s (it goes as the game puts its view back)
    if (-not $script:mapClock) { $script:mapClock = [Diagnostics.Stopwatch]::StartNew() }
    $dt = [Math]::Min(0.1, $script:mapClock.Elapsed.TotalSeconds); $script:mapClock.Restart()
    $script:mapKNow = $(if ($up) { [Math]::Min(1.0, $script:mapKNow + $dt / 0.35) } else { [Math]::Max(0.0, $script:mapKNow - $dt / 0.2) })
    if (-not $up) { $script:map3d = $script:map3d -and $open }
    if ($script:mapKNow -le 0) { $gq.MapK = 0; $gq.MapOn = $false; if ($script:panel -and $script:panel.Light -lt 1) { try { $script:panel.Light = 1 } catch { } }; return $false }
    # turning: the drag (counts of the mouse), eased; the wheel, closer or further
    $introT = $(if ($script:mapIntroClock) { $script:mapIntroClock.Elapsed.TotalSeconds } else { 99.0 })
    $introOn = $introT -lt [double]$gq.MapIntroSeconds
    $gq.MapIntro = [single]$(if ($introOn) { $introT } else { -1 })
    # THE VISOR'S LIGHTS (Josh, 2026-10-14): two faint teal cones from the panel's top corners -- brighter while the map draws, then a glow that stays
    $gq.MapBeamT = [single]$introT; if ($NoMapLights) { $gq.MapBeamK = 0 } elseif ($script:mapBeamView) { $gq.MapBeamView = $script:mapBeamView }
    if ($up -and $script:mapMouse) {
        $dx = 0; $dy = 0; $wh = 0; $left = $false; $script:mapMouse.Take([ref]$dx, [ref]$dy, [ref]$wh, [ref]$left)
        if ($introOn) { $dx = 0; $dy = 0; $wh = 0 }      # (interactive once it has pulsed in)
        $script:mapYawT += $dx * 0.22; $script:mapPitchT = [Math]::Max(12.0, [Math]::Min(88.0, $script:mapPitchT + $dy * 0.18))      # (yaw +: the map is no longer mirrored, so a drag turns it the same way it did)
        if ($wh -ne 0) { $script:mapZoomT = [Math]::Max(0.06, [Math]::Min(3.0, $script:mapZoomT * [Math]::Pow(1.12, $wh / 120.0))) }      # (below the room's own framing, 0.6: out to the whole complex)
    }
    $e = 1 - [Math]::Exp(-$dt / 0.08)
    $script:mapYaw += ($script:mapYawT - $script:mapYaw) * $e; $script:mapPitch += ($script:mapPitchT - $script:mapPitch) * $e; $script:mapZoom += ($script:mapZoomT - $script:mapZoom) * $e
    # the marks: the doors, and the player where they stand (on the floor under the eye), facing where they look
    $mk = New-Object 'System.Collections.Generic.List[single]'
    if ($script:mapDoors) { $mk.AddRange([single[]]$script:mapDoors.Marks) }
    $cam = $script:mapFreezeCam
    if ($cam) {
        $py = $cam[13] - 40; try { $rg = $room; if ($rg -and $rg.V) { $fd = [AztTool.Raster]::RayDistance($rg.V, $rg.T, $rg.TexIdx, $cam[12], $cam[13], $cam[14], 0, -1, 0, 600); if ($fd -lt 600) { $py = $cam[13] - $fd } } } catch { }
        foreach ($v in @([single]$cam[12], [single]$py, [single]$cam[14], [single]$cam[8], [single]$cam[10], [single]1, [single]0, [single]0)) { $mk.Add($v) }
    }
    $gq.SetMapMarks($mk.ToArray(), [int]($mk.Count / 8))
    # (the rest of the complex fades in as soon as the map is zoomed out a little from where it opens -- Josh, 2026-10-14: he had
    # to zoom out "way too far" -- from just under the opening zoom to 0.4 under it)
    $zc = [Math]::Max(0.0, [Math]::Min(1.0, ($MapZoomStart - 0.05 - $script:mapZoom) / 0.4)); $gq.MapComplexK = [single]($zc * $zc * (3 - 2 * $zc))
    # THE PANEL DIMS while the map is up (Josh, 2026-10-14) -- Panel.Light, following the map's own fade
    if ($script:panel) { try { $script:panel.Light = [single](1.0 - (1.0 - $MapPanelLight) * $script:mapKNow) } catch { } }
    $gq.MapOn = $up; $gq.MapK = [single]$script:mapKNow; $gq.MapYaw = [single]$script:mapYaw; $gq.MapPitch = [single]$script:mapPitch; $gq.MapZoom = [single]$script:mapZoom
    return $true
}
function Restore-SysMenuHot {
    if (-not $script:sysHotOrig) { return }
    foreach ($o in $script:sysHotOrig) { try { [void][AztTool.ProcMem]::Write($g.ProcessId, [long]$o[0], [byte[]]$o[1]) } catch { } }
    Say ("system menu: the fold-out's own clicks put back ({0} records)" -f $script:sysHotOrig.Count) Cyan
    $script:sysHotOrig = $null; $script:sysHotDone = $false
}
# THE GAME STALLS WHILE IT SAVES (Josh, 2026-10-09: "when I save a game, I see ... the old view"): OK does the whole save in
# one handler -- file writes and a 3 s wait -- with no frames, so the overlay went stale and hid, uncovering DOSBox's 8-bit
# screen. While the memory core is writing (or any visor panel is up and the game has stopped handing frames over), the last
# clean picture is presented again with the panels laid over it -- the "writing log" screen keeps animating -- and the window
# is held fresh.
function Repaint-HeldPicture {
    $o = $script:ov; $gq = $script:gpu; $vm = $script:visorMenu
    if (-not $o -or -not $gq -or -not $vm -or -not $script:gpuClean) { return }
    if ($script:snapOn -and $hv) { $hv.SnapTake() }      # (outside the frame -- a save's stall, a load's repaint: the words read now, as before)
    Step-MemCore $o
    if (-not $vm.AnyPlaying) { return }
    if ($vm.Writing -or $vm.ReadPlaying -or $script:loadBusy) { $o.HoldFreshUntil = [Diagnostics.Stopwatch]::GetTimestamp() + [Diagnostics.Stopwatch]::Frequency }      # (a second ahead, renewed while it writes / reads)
    if (-not $script:gpuHeld -or $script:gpuHeld.Length -ne $script:gpuClean.Length) { $script:gpuHeld = New-Object int[] $script:gpuClean.Length }
    [Array]::Copy($script:gpuClean, $script:gpuHeld, $script:gpuClean.Length)
    try { $o.DecorateOnly($script:gpuHeld, $script:gpuCleanW, $script:gpuCleanH); if ($gq.PresentPicture($script:gpuHeld, $script:gpuCleanW, $script:gpuCleanH)) { $o.NoteGlFrame() } } catch { }
}
function Get-VisorMenu($o) {
    if (-not $script:visorMenu) {
        $vm = New-Object AztTool.VisorMenu($o)
        $vm.Sound = New-Object AztTool.BootSound; $vm.Sound.On = (-not $NoBootSound); if ($BootSoundVolume -ge 0) { $vm.Sound.Volume = $BootSoundVolume }
        $vm.ViewY = [int]$man.view.injY
        $vm.RoomLoadAhead = [bool]($TrueColour -and -not $NoRgb)      # (a load's reading bar carries the room's textures: Set-LoadProgress)
        $vm.Pid = $g.ProcessId; $vm.MemBase = [long]$g.MemBase; $vm.CurSurfAddr = $script:memAt.CurSurf; $vm.HotAddr = $script:memAt.Hot; $vm.HiddenAddr = $script:memAt.Hidden      # (the game's cursor, drawn over the panel)
        $o.Decorate4 = $vm.Hook; $script:visorMenu = $vm
        Say 'memory core: the host draws the save/load screen' Cyan
    }
    return $script:visorMenu
}
# LOADING A LOG (Josh, 2026-10-10: "when loading a game lets have a screen on the visor very similar to the saving game screen,
# but instead it will read 'Initiating log file "[name]"'"): when a load's visor re-boot begins (aztReboot 0 -> 1: the fold-out's
# OK, or the title menu's Continue / Load on the first frame), the memory core's panel reads the archive in over the re-boot.
# The slot: the title menu's (the gate's PickedSlot), else the last row picked in the load list; its name from the game's list.
# A TITLE LOAD (2026-10-10: "it showed the visor but empty, no loading animation"): the load runs on the game's FIRST frame, so the
# re-boot is already under way (aztReboot 1) the first time this looks -- the gate's PickedSlot says it was ours. And the panel
# waits for the load (ReadWait: its bar holds short of full) until the re-boot has revealed the 3D -- from the title that is the
# renderer loading its first room, seconds of an otherwise empty visor; on an in-game load, the new room.
$script:loadRebootWas = $null; $script:lastLoadSel = -1; $script:readWaitAt = $null; $script:readWaitSeen = $false
function Step-LoadPanel {
    if ($script:readWaitAt) {
        # let the reading finish once the re-boot has shown the view (or never started covering it, or 30 s)
        $bm = if ($script:bootHd) { $script:bootHd.Mode } else { 'done' }
        if ($bm -eq 'live' -or $bm -eq 'hold') { $script:readWaitSeen = $true }
        $age = $script:readWaitAt.Elapsed.TotalSeconds
        $quiet = -not $script:loadBusy -and $script:loadBusyEnd -and $script:loadBusyEnd.Elapsed.TotalSeconds -gt 4      # (no re-boot came after the load)
        if (($script:readWaitSeen -and $bm -ne 'live' -and $bm -ne 'hold') -or (-not $script:readWaitSeen -and $quiet) -or $age -gt 45) {
            Set-LoadViewUp      # (and the reading finishes once the view is steady: Step-LoadGuard counts its frames)
            if ($age -gt 45 -or (Test-LoadViewSteady)) {
                try { (Get-VisorMenu $script:ov).FinishReading() } catch { }
                $script:readWaitAt = $null
            }
        }
    }
    # A TITLE LOAD (2026-10-10: "If i load a game I don't see the loading screen i hoped for") is read in by the TITLE: it is
    # already up and in front from the click, where this panel could only start once the renderer had its first room (the
    # short re-boot is often over by then). Here only its fallback: no host boot to reveal -> tell the title now.
    if ($script:gate -and $script:gate.PickedSlot -ge 0) {
        if (-not $script:titleReadAt) { $script:titleReadAt = [Diagnostics.Stopwatch]::StartNew(); if ($script:bootHd) { $script:bootHd.LoadHeld = $null }; Say ("loading a log from the title: slot {0} '{1}' -- the title reads it in until the view is back" -f ($script:gate.PickedSlot + 1), $script:gate.PickedName) Cyan }
        $bm = if ($script:bootHd) { $script:bootHd.Mode } else { 'none' }
        if ($bm -eq 'live' -or $bm -eq 'hold') { $script:titleReadSeen = $true }
        if (-not $script:titleShowDue -and ($bm -eq 'none' -or ($script:titleReadSeen -and $bm -ne 'live' -and $bm -ne 'hold') -or (-not $script:titleReadSeen -and $script:titleReadAt.Elapsed.TotalSeconds -gt 6))) {
            Request-TitleLoadShown      # (Step-LoadGuard tells the title once the view is steady)
            $script:titleUnlockAt = [Diagnostics.Stopwatch]::StartNew(); $script:titleUnlockSaid = $false
        }
        $script:loadRebootWas = $null
        return
    }
    if ($NoMemCore -or -not $script:ov -or -not $symMap.ContainsKey('aztReboot')) { return }
    try { $rb = $hv.ReadU32($(if ($script:hlReboot) { $script:hlReboot } else { HostLin (Sym 'aztReboot') })) } catch { return }
    $was = $script:loadRebootWas; $script:loadRebootWas = $rb
    if ($rb -ne 1 -or $null -eq $was -or $was -ne 0) { return }
    if ($script:visorMenu -and $script:visorMenu.ReadPlaying) { return }      # (already reading: started at OK)
    $slot = $script:lastLoadSel; $name = ''; $title = $false
    if ($slot -ge 0 -and $slot -lt 5 -and $script:memAt) { try { $nb = [AztTool.ProcMem]::Read($g.ProcessId, ($script:memAt.Blk + 0x5E + 30 * $slot), 30); $n = 0; while ($n -lt 30 -and $nb[$n] -ne 0) { $n++ }; if ($n -gt 0) { $name = [Text.Encoding]::ASCII.GetString($nb, 0, $n) } } catch { } }
    try {
        $vmR = Get-VisorMenu $script:ov; $vmR.ReadWait = $true; $vmR.BeginReading($slot, $name)
        $script:readWaitAt = [Diagnostics.Stopwatch]::StartNew(); $script:readWaitSeen = $false
        Say ("loading a log{0}: slot {1} '{2}' -- the visor reads it in over the re-boot, until the view is back" -f $(if ($title) { ' from the title' } else { '' }), ($slot + 1), $name) Cyan
    } catch { Say ("the reading panel failed: {0}" -f $_.Exception.Message) Yellow }
}
# ESC AFTER A TITLE LOAD (Josh, 2026-10-10: "when i load into a game, I can't hit the escape key to bring up the system menu or
# quit"). A title load runs on the NEW game's first frame: the opening's script has just locked the interface (word 0x1471F0, set
# by script opcode 0x26477 -- cmd 5, the menu, refuses while it is set; walking does not care), and the load swaps the room out
# from under the script that would have unlocked it. A saved game is never locked, so for the first seconds after a title load
# the lock (and 0x14721A, cmd 5's other refusal) is cleared. And whenever ESC opens nothing, every one of its blockers is logged.
# (from the frame's guest snapshot when there is one -- HostView.SnapWord, see THE GUEST SNAPSHOT in Invoke-Session; it reads
# live outside the snapshot's blocks. 2026-10-13 performance audit)
function GuestWord([uint32]$lin) { if ($script:snapOn) { return $hv.SnapWord($lin) }; try { [BitConverter]::ToInt16([AztTool.ProcMem]::Read($g.ProcessId, [long]($g.MemBase + $lin + $script:memAt.D2), 2), 0) } catch { $null } }
# a data write to an obj2 word the snapshot holds: to the game now, and into the snapshot so the rest of the frame sees it
function Write-GuestSnap([uint32]$lin, [byte[]]$data) { if ($script:snapOn) { [void]$hv.WriteSnap($lin, $data) } else { [void][AztTool.ProcMem]::Write($g.ProcessId, [long]($g.MemBase + $lin + $script:memAt.D2), $data) } }
# THE MUSIC, LOGGED (2026-10-15, Josh: KREEPY2 "plays in the Minemaze room, but I believe that room is still playing the original
# midi file"): the game's current cue [0x152AD0] (0 awemyst .. 8 kreepy2 .. 10 peaceful) and what the overlay's CD switch made
# of it (AztCdPoll: aztCdCur = a CD track playing, aztCdIdx = which slot, aztCdMuted = the MIDI held at 0, aztCdOnLast = F4's
# soundtrack mode), read twice a second and said whenever any of it changes -- so a room's music can be checked from watch.log
$script:musicWas = $null; $script:musicAt = $null
$script:cueNames = @('AWEMYST', 'CATHEDRL', 'EGYPTIAN', 'FIGHT2', 'GHOSTS', 'GRAIL', 'INGAME', 'INGAME2', 'KREEPY2', 'KREEPY3', 'PEACEFUL', 'BOOTFX')
function Step-MusicWatch {
    if ($script:musicOff -or -not $symMap.ContainsKey('aztCdCur')) { return }
    if ($script:musicAt -and $script:musicAt.ElapsedMilliseconds -lt 500) { return }
    if ($script:musicAt) { $script:musicAt.Restart() } else { $script:musicAt = [Diagnostics.Stopwatch]::StartNew() }
    try {
        $cw = GuestWord 0x152AD0; if ($null -eq $cw) { return }; $cue = [int]$cw -band 0xFF
        $ok = RdU32 (HostLin (Sym 'aztCdOk')); $cur = RdU32 (HostLin (Sym 'aztCdCur')); $idx = RdU32 (HostLin (Sym 'aztCdIdx'))
        $muted = RdU32 (HostLin (Sym 'aztCdMuted')); $on = (RdU32 (HostLin (Sym 'aztCdOnLast'))) -band 0xFFFF
        $now = "$cue|$ok|$cur|$idx|$muted|$on"
        if ($now -eq $script:musicWas) { return }; $script:musicWas = $now
        $nm = { param($i) if ($i -ge 0 -and $i -lt $script:cueNames.Count) { $script:cueNames[$i] } else { "?$i" } }
        $what = $(if (-not $ok) { 'CD audio not available -- the MIDI plays' }
                  elseif (-not $on) { 'soundtrack mode OFF (F4) -- the original MIDI plays' }
                  elseif ($cur) { "the recorded soundtrack plays {0} (slot {1}){2}" -f (& $nm ([int]$idx)), $idx, $(if ($muted) { ', MIDI held at 0' } else { ' -- but the MIDI is NOT muted' }) }
                  else { 'no CD track playing -- the MIDI plays' + $(if ($muted) { ' (held at 0)' } else { '' }) })
        Say ("music: the game's cue is {0} ({1}); {2}" -f (& $nm $cue), $cue, $what) DarkCyan
    } catch { $script:musicOff = $true; Say ("music watch off: {0}" -f $_.Exception.Message) Yellow }
}
function Step-EscWatch {
    if (-not $script:memAt -or -not $g) { return }
    if ($script:titleUnlockAt -and $script:titleUnlockAt.Elapsed.TotalSeconds -lt 5) {
        foreach ($lk in @(0x1471F0, 0x14721A)) {
            $v = GuestWord $lk
            if ($v) {
                try { Write-GuestSnap $lk ([byte[]]@(0, 0)) } catch { }
                if (-not $script:titleUnlockSaid) { $script:titleUnlockSaid = $true; Say ("system menu: the new game's interface lock (0x{0:X} = {1}) outlived the title load -- cleared" -f $lk, $v) Yellow }
            }
        }
    } elseif ($script:titleUnlockAt) { $script:titleUnlockAt = $null }
    # THE QUIT CONFIRMATION ONLY FROM 'q' (Josh, 2026-10-13: "If I hit escape key, it should not automatically initiate the
    # quit confirmation. That only occurs when I click 'q' for quit"). 'q' (0x13599) asks for it with word 0x15259A, which
    # the game turns into cmd 13 -- and clears -- only when the fold-out finishes sliding OPEN (0x1496C). A 'q' pressed
    # while the fold-out is already open (cmd 5 closes it) or while it cannot open (help, map, a conversation...) leaves
    # the word set, and the next open by ANY means -- ESC -- lands in the quit confirmation (a stock quirk,
    # docs\system-menu-RE.md s4). So the request lives 2 s after a 'q' (plenty for its own slide-in); after that it is
    # cleared (a data write).
    $qd = $false; try { $qd = [AztTool.Keys]::DownInProcess(0x51, $g.ProcessId) } catch { }
    if ($qd) { $script:quitKeyAt = [Diagnostics.Stopwatch]::StartNew() }
    if ((GuestWord 0x15259A) -and -not ($script:quitKeyAt -and $script:quitKeyAt.Elapsed.TotalSeconds -lt 2)) {
        try { Write-GuestSnap 0x15259A ([byte[]]@(0, 0)) } catch { }
        if ($script:quitReqSaid -lt 3) { $script:quitReqSaid++; Say 'system menu: a stale quit request (a q that opened nothing) cleared -- ESC opens the menu, not the quit confirmation' DarkCyan }
    }
    $down = $false; try { $down = [AztTool.Keys]::DownInProcess(0x1B, $g.ProcessId) } catch { }
    if ($down -and -not $script:escWas) { $script:escAt = [Diagnostics.Stopwatch]::StartNew(); $script:escFold = GuestWord 0x1523D6 }
    $script:escWas = $down
    if ($script:escAt -and $script:escAt.Elapsed.TotalSeconds -gt 0.6) {
        $script:escAt = $null
        if ((GuestWord 0x1523D6) -eq $script:escFold -and $script:escSaid -lt 12) {
            $script:escSaid++
            Say ("ESC opened nothing -- book {0}, help {1}, picture {2}, slot {3} (DE {4} E0 {5}), dead {6}, conversation {7}, speaking {8}, sliding {9}, lock {10}, lock2 {11}, combat {12}" -f `
                (GuestWord 0x15257C), (GuestWord 0x1525F2), (GuestWord 0x1525A0), (GuestWord 0x146948), (GuestWord 0x1523DE), (GuestWord 0x1523E0), (GuestWord 0x152904), (GuestWord 0x152B1C), (GuestWord 0x152B28), (GuestWord 0x1523E8), (GuestWord 0x1471F0), (GuestWord 0x14721A), (GuestWord 0x14721C)) Yellow
        }
    }
}
# QUIT GOES STRAIGHT TO THE DESKTOP (Josh, 2026-10-10: "when exiting the game I want them to exit immediately to desktop ... the
# credits stay for the retro mode on exit"). The fold-out's QUIT -> OK sets word 0x152176 = 1 (0x2D09A; the 'q' path 0x135A7);
# the main loop sees it at 0x16086 and returns, and the game rolls CREDITS.TXT (0x1FC6C, from 0x162A7) under the renderer's
# picture before going back to DOS. In the GPU mode the moment the word is set DOSBox is closed -- the game has nothing left
# to save. NOT for the game's ENDING (the exit code 0x152908 = 0x66: the outro movies, then the credits), and never in -Retro.
function Step-QuitWatch {
    if ($Retro -or $script:quitDone -or -not $script:memAt -or -not $g) { return }
    if ((GuestWord 0x152176) -ne 1) { return }
    $code = GuestWord 0x152908
    if ($code -eq 0x66) { if (-not $script:quitEndSaid) { $script:quitEndSaid = $true; Say 'the game is ending (exit code 0x66): the outro and credits are the game''s own -- not closed' Cyan }; return }
    $script:quitDone = $true
    Say ("QUIT: the player left the game (exit code {0}) -- closing DOSBox now, no credits (the GPU mode)" -f $code) Cyan
    try {
        $gp = [Diagnostics.Process]::GetProcessById([int]$g.ProcessId)
        if (-not $gp.CloseMainWindow() -or -not $gp.WaitForExit(2500)) { $gp.Kill(); [void]$gp.WaitForExit(2000) }
    } catch { Say ("QUIT: closing DOSBox failed: {0}" -f $_.Exception.Message) Yellow }
}
# THE SHOT RECORDER (Josh, 2026-10-10: "it is now automatically shooting the gun when I right-click"). The fire code (0x15A5C,
# the LEFT-down case of the button switch at 0x1382C) only fires in combat; the right button's own case (0x15C75) never gets
# there. So each shot logs the last ~0.6 s of the input that led to it -- left / right button (0x182DA6 / 0x182DAA),
# combat (0x14721C), mouselook (0x147218) -- one sample a frame, oldest first, until the cause is known.
$script:shotHist = New-Object System.Collections.Generic.List[string]; $script:shotAmmo = $null; $script:shotClock = [Diagnostics.Stopwatch]::StartNew(); $script:shotSaid = 0
$script:shotWeapon = $null; $script:weaponSaid = 0; $script:spokeAt = $null
# SPACE AFTER A SPOKEN LINE (see -NoSpaceGuard; tools\Keys.cs): a low-level keyboard hook of the host's own, nothing in the game
$script:spaceGuard = $null; $script:sgSaid = 0L; $script:sgClock = [Diagnostics.Stopwatch]::StartNew()
function Start-SpaceGuard([long]$speakAt) {
    Stop-SpaceGuard
    if ($NoSpaceGuard -or -not $g) { return }
    try {
        $sg = New-Object AztTool.SpaceGuard($g.ProcessId); $sg.SpeakAddr = $speakAt
        $sg.JumpMode = (-not $NoJump -and -not $Retro); $script:jumpOn = $sg.JumpMode; $sg.CrouchMode = (-not $NoCrouch -and -not $Retro); try { $sg.TypingAddr = HostLin (Sym 'aztTypingKeys') } catch { }      # (a save name being typed: Space, Z and C are letters)
        if (-not $sg.Start()) { throw ("its keyboard hook would not start: " + $sg.StartError) }
        $script:spaceGuard = $sg; $script:sgSaid = 0L
        Say ("space guard: on -- for {0:N1} s after a spoken line ends, Space is not passed to the game (it would draw the weapon); while a line plays it skips it as before (-NoSpaceGuard)" -f ($sg.QuietMs / 1000.0)) Green
        if ($sg.JumpMode) { Say ("jump: Space jumps (top {0} units, eased), Z is the weapon / MS7 sight toggle; Space still skips a spoken line (-NoJump)" -f $JumpPower) Green }
        if ($sg.CrouchMode) { Say ("crouch: C toggles -- the eye {0:N0} units lower, {1:P0} speed (-NoCrouch)" -f $CrouchDrop, $CrouchSpeed) Green }
    } catch { Say ("space guard failed: {0} -- Space goes to the game as it is" -f $_.Exception.Message) Yellow; try { $sg.Dispose() } catch { }; $script:spaceGuard = $null }
}
function Stop-SpaceGuard {
    Reset-Crouch      # (the game's eye height, knee test and speeds back as they were)
    if ($script:spaceGuard) { try { $script:spaceGuard.Dispose() } catch { }; $script:spaceGuard = $null }
}
function Step-ShotWatch {
    $sgd = $script:spaceGuard
    if ($sgd -and $sgd.Swallowed -ne $script:sgSaid -and $script:sgClock.Elapsed.TotalSeconds -ge 3) {
        $script:sgSaid = $sgd.Swallowed; $script:sgClock.Restart()
        Say ("space guard: Space held back {0} time(s) just after a spoken line; {1} passed; {2} line ends seen; {3} held Space released early" -f $sgd.Swallowed, $sgd.Passed, $sgd.LineEnds, $sgd.EarlyUps) DarkYellow
    }
    if (-not $script:memAt -or -not $g) { return }
    # (2026-10-13 performance audit: 7 guest reads every frame for a diagnostic -- 10 times a second is plenty for the
    # weapon and ammo logs; -ShotLog keeps the old every-frame input history for the SHOT RECORD)
    if (-not $ShotLog) {
        if ($script:shotThin -and $script:shotThin.ElapsedMilliseconds -lt 100) { return }
        if ($script:shotThin) { $script:shotThin.Restart() } else { $script:shotThin = [Diagnostics.Stopwatch]::StartNew() }
    }
    $am = GuestWord 0x14694C; if ($null -eq $am) { return }
    # THE WEAPON (word 0x14721C; the game's SPACE key toggles it -- "Toggle MS7 Sniper sight"). While it is out the cursor pick
    # 0x116E4 skips every contextual cursor (0x119D6) -- no pick-up / use / door cursors -- and the left button fires. Josh
    # 2026-10-11 "could not pick up the key in the well": both clicks there were shots with it out. Space also skips a spoken
    # line (AztSkipKey), so a press just after a line ends draws the weapon: logged with how long ago a line was spoken.
    $wp = GuestWord 0x14721C; $now = $script:shotClock.Elapsed.TotalSeconds
    if ((GuestWord 0x152B28) -gt 0) { $script:spokeAt = $now }
    if ($null -ne $wp -and $null -ne $script:shotWeapon -and $wp -ne $script:shotWeapon -and $script:weaponSaid -lt 40) {
        $script:weaponSaid++
        $ago = if ($null -ne $script:spokeAt -and $now - $script:spokeAt -lt 2) { ' (a spoken line ended {0:N1} s before)' -f ($now - $script:spokeAt) } else { '' }
        Say ("weapon {0}{1}; conversation {2}" -f $(if ($wp) { "DRAWN -- the game's crosshair: no pick-up / use cursors, the left button fires, until Space puts it away" } else { 'put away' }), $ago, (GuestWord 0x152B1C)) DarkYellow
    }
    if ($null -ne $wp) { $script:shotWeapon = $wp }
    if ($ShotLog) {
        $s = '{0:N2}:L{1}R{2}C{3}M{4}' -f $script:shotClock.Elapsed.TotalSeconds, (GuestWord 0x182DA6), (GuestWord 0x182DAA), (GuestWord 0x14721C), (GuestWord 0x147218)
        $script:shotHist.Add($s); while ($script:shotHist.Count -gt 24) { $script:shotHist.RemoveAt(0) }
    }
    if ($null -ne $script:shotAmmo -and $am -lt $script:shotAmmo -and $script:shotSaid -lt 20) {
        $script:shotSaid++; $now = $script:shotClock.Elapsed.TotalSeconds
        $recent = @($script:shotHist | Where-Object { $now - [double]($_.Split(':')[0]) -le 0.6 } | ForEach-Object { $x = $_.Split(':'); '{0:+0.00;-0.00}s {1}' -f ([double]$x[0] - $now), $x[1] })
        Say ("SHOT RECORD {0}: ammo {1} -> {2}; input before it (L/R = left/right button, C = combat, M = mouselook): {3}" -f $script:shotSaid, $script:shotAmmo, $am, ($recent -join ' | ')) DarkYellow
    }
    $script:shotAmmo = $am
}function Step-MemCore($o) {
    if ($NoMemCore -or -not $o -or -not $script:memAt) { return }
    # ONE BLOCK READ, AND OUT AT ONCE WHILE NO MENU IS UP (2026-10-13 performance audit). The block and the words below come
    # from the frame's guest snapshot (they are the same reads Guard-SaveList makes); with no list, no system menu, no save, no
    # load, no slider drag and nothing of the visor's panels playing -- and the visor already told so last frame -- there is
    # nothing to hand over, so the names, the state and the sound words are not worked out at all.
    try {
        if ($script:snapOn) {
            $blk = $hv.SnapBytes(0x1523D6, 0xF8)
            $sav = $hv.SnapBytes(0x152B02, 2)      # (the game is saving: 0x152B02, set by OK through its ~3 s save)
            $lod = $hv.SnapBytes(0x152B04, 2)      # (the game is loading: 0x152B04, set by OK through the load)
        } else {
            $blk = [AztTool.ProcMem]::Read($g.ProcessId, $script:memAt.Blk, 0xF8)
            $sav = [AztTool.ProcMem]::Read($g.ProcessId, $script:memAt.Sav, 2)
            $lod = [AztTool.ProcMem]::Read($g.ProcessId, $script:memAt.Lod, 2)
        }
    } catch { return }
    if (-not $blk -or $blk.Length -lt 0xF8) { return }
    # word offsets in the block from 0x1523D6: EA +0x14, DC +0x06, DE +0x08, E0 +0x0A; names 0x152434 = +0x5E, 5 x 30
    $vis = [BitConverter]::ToInt16($blk, 0x14) -ne 0; $list = [BitConverter]::ToInt16($blk, 0x06) -ne 0
    $save = [BitConverter]::ToInt16($blk, 0x0A) -ne 0
    $open = $vis -and $list
    $sysUp = ([BitConverter]::ToInt16($blk, 0x00) -ne 0) -and -not $NoSysMenu      # (the fold-out logically up: 0x1523D6)
    if (-not $NoSysMenu -and -not $script:sysHotDone) { Set-SysMenuHot }
    if (-not $script:visorMenu) {
        if (-not ($open -or $sysUp)) { return }
        [void](Get-VisorMenu $o)
    }
    # NO MENU UP (no list, no system menu, no save or load, no visor panel playing): the five slot names are not decoded -- a
    # script loop of up to 150 steps a frame for nothing; the visor is still told the rest, so its state is exactly as before
    # (SetState keeps the names it had: they are only drawn while a list or the "writing log" panel is up, and the first
    # frame of either decodes them again)
    $idle = -not ($open -or $sysUp -or ($sav -and [BitConverter]::ToInt16($sav, 0) -ne 0) -or ($lod -and [BitConverter]::ToInt16($lod, 0) -ne 0) -or $script:visorMenu.AnyPlaying)
    try {
        if ($script:snapOn) {
            $sel = [BitConverter]::ToInt16($hv.SnapBytes(0x146948, 2), 0)
            $cur = $hv.SnapBytes(0x182D6C, 4)
            $snd = $hv.SnapBytes(0x14693A, 8)      # (the system menu: SFX / music on, their levels -- 0x14693A..0x146941)
        } else {
            $sel = [BitConverter]::ToInt16([AztTool.ProcMem]::Read($g.ProcessId, $script:memAt.Sel, 2), 0)
            $cur = [AztTool.ProcMem]::Read($g.ProcessId, $script:memAt.Cur, 4)
            $snd = [AztTool.ProcMem]::Read($g.ProcessId, $script:memAt.Snd, 8)
        }
    } catch { return }
    if ($open -and -not $save -and $sel -ge 0 -and $sel -lt 5) { $script:lastLoadSel = [int]$sel }      # (the row a load will read: its name for the reading panel)
    $names = $null
    if (-not $idle) { $names = New-Object string[] 5; for ($i = 0; $i -lt 5; $i++) { $b0 = 0x5E + 30 * $i; $n = 0; while ($n -lt 30 -and $blk[$b0 + $n] -ne 0) { $n++ }; $names[$i] = [Text.Encoding]::ASCII.GetString($blk, $b0, $n) } }
    $script:visorMenu.Palette = $script:tcPal32
    $script:visorMenu.Writing = [bool]($sav -and [BitConverter]::ToInt16($sav, 0) -ne 0)      # (Josh, 2026-10-09: "Writing log..." instead of the old screen while it saves)
    $script:loadBusy = [bool]($lod -and [BitConverter]::ToInt16($lod, 0) -ne 0)
    if ($script:loadBusy) {
        $script:loadBusyEnd = $null
        if (-not $script:visorMenu.ReadPlaying -and -not ($script:gate -and $script:gate.PickedSlot -ge 0)) {
            $slot = $script:lastLoadSel; $name = $(if ($slot -ge 0 -and $slot -lt 5) { $names[$slot] } else { '' })
            $script:visorMenu.ReadWait = $true; $script:visorMenu.BeginReading($slot, $name)
            $script:readWaitAt = [Diagnostics.Stopwatch]::StartNew(); $script:readWaitSeen = $false
            if ($script:bootHd) {
                if ($script:gpuClean) { $script:bootHd.LoadHeldW = $script:gpuCleanW; $script:bootHd.LoadHeldH = $script:gpuCleanH; $script:bootHd.LoadHeld = [int[]]$script:gpuClean.Clone() }
                else { $script:bootHd.LoadHeld = $null }
            }
            Say ("loading a log: slot {0} '{1}' -- the visor reads it in from OK, through the load and the re-boot" -f ($slot + 1), $name) Cyan
        }
    } elseif (-not $script:loadBusyEnd) { $script:loadBusyEnd = [Diagnostics.Stopwatch]::StartNew() }
    if ($script:visorMenu.Writing -or $script:loadBusy -or $script:visorMenu.ReadPlaying) { $o.HoldFreshUntil = [Diagnostics.Stopwatch]::GetTimestamp() + [Diagnostics.Stopwatch]::Frequency }
    $script:visorMenu.SetState($open, $save, [int]$sel, $names, [int][BitConverter]::ToInt16($cur, 0), [int][BitConverter]::ToInt16($cur, 2))
    # THE SYSTEM MENU (Josh, 2026-10-09): drawn by the host over the game's fold-out; its state from the same block + the sound words.
    # Block offsets from 0x1523D6: D6 +0x00, D8 (dragging music) +0x02, DA (dragging SFX) +0x04, DE +0x08, E0 +0x0A, 24CA (quit asking) +0xF4
    if ($snd -and $snd.Length -ge 8) {
        $script:visorMenu.SetSys($sysUp, ([BitConverter]::ToInt16($blk, 0xF4) -ne 0), $save, ([BitConverter]::ToInt16($blk, 0x08) -ne 0), ([BitConverter]::ToInt16($snd, 0) -ne 0), ([BitConverter]::ToInt16($snd, 2) -ne 0), [int][BitConverter]::ToInt16($snd, 4), [int][BitConverter]::ToInt16($snd, 6), ([BitConverter]::ToInt16($blk, 0x04) -ne 0), ([BitConverter]::ToInt16($blk, 0x02) -ne 0))
    }
    # A SLIDER LETS GO ON RELEASE (Josh, 2026-10-13: "I click the volume slider and it sticks even if releasing the mouse
    # button, and only sets if I click outside. It should set on mouse release"). The game starts a drag (0x1523D8 music,
    # 0x1523DA effects; set at 0x2C99x by the slider's hot-spot command) and ends it ONLY in its left-release handler
    # (event kind 2, 0x15C50). The hot-spot command is a separate queued event, so a click can have its release handled
    # BEFORE the drag starts -- and the slider then follows the pointer until the next release. So: a drag still set while
    # the button has been up for 120 ms (the slider has taken the pointer's place by then) is ended here, as the release
    # handler would (a data write). Either physical button counts as held (left-handed mice swap them).
    $dragNow = ([BitConverter]::ToInt16($blk, 0x02) -ne 0) -or ([BitConverter]::ToInt16($blk, 0x04) -ne 0)
    if ($dragNow) {
        $held = $false; try { $held = [AztTool.Keys]::DownInProcess(0x01, $g.ProcessId) -or [AztTool.Keys]::DownInProcess(0x02, $g.ProcessId) } catch { }
        if ($held) { $script:dragUpAt = $null }
        elseif (-not $script:dragUpAt) { $script:dragUpAt = [Diagnostics.Stopwatch]::StartNew() }
        elseif ($script:dragUpAt.ElapsedMilliseconds -ge 120) {
            try { Write-GuestSnap 0x1523D8 ([byte[]]@(0, 0, 0, 0)) } catch { }      # (memAt.Blk + 2)
            if (-not $script:dragFixSaid) { $script:dragFixSaid = $true; Say 'system menu: a volume slider still dragging after the button was let go -- ended (it sets on release now)' DarkCyan }
            $script:dragUpAt = $null
        }
    } else { $script:dragUpAt = $null }
    # (the cursor over the panel: why the game's image could not be read, when it changes -- 2026-10-09, it did not show in game)
    $cn = $script:visorMenu.CursorNote; if ($open -and $cn -ne $script:memCurNote) { $script:memCurNote = $cn; Say ("memory core cursor: {0} (game's image drawn {1}x, own pointer {2}x; cursor {3},{4})" -f $(if ($cn) { $cn } else { 'the game''s image reads fine' }), $script:visorMenu.CursorDrawn, $script:visorMenu.CursorFallback, [BitConverter]::ToInt16($cur, 0), [BitConverter]::ToInt16($cur, 2)) Yellow }
}
# A STOCK BUG, GUARDED (Josh, 2026-10-09): RESTART's click spot is live on BOTH list screens and the quit prompt, though
# RESTART is only drawn (and only meant) in the LOAD list. Picking it elsewhere sets the selection to 6 and OK to "load",
# so OK / Enter then LOADS the restart save instead of saving or quitting. There is no room in the game's handler for a
# mode check (docs\save-load-screen-RE.md), so the host puts it back: the frame after RESTART is picked outside the load
# list, the selection, the OK action (0x1524CC) and the click screen ([[0x182DB8]+0x52]) are restored to what they were
# the frame before -- as if the click never happened. Every frame, 8-bit or true colour.
function Guard-SaveList {
    if (-not $script:memAt) { return }
    try {
        # (from the frame's guest snapshot -- the same block Step-MemCore reads; 2026-10-13 audit)
        if ($script:snapOn) { $blk = $hv.SnapBytes(0x1523D6, 0xF8); $selB = $hv.SnapBytes(0x146948, 2); $mgr = $hv.SnapU32(0x182DB8) }
        else {
            $blk = [AztTool.ProcMem]::Read($g.ProcessId, $script:memAt.Blk, 0xF8)
            $selB = [AztTool.ProcMem]::Read($g.ProcessId, $script:memAt.Sel, 2)
            $mgr = RdU32 $script:memAt.Mgr
        }
    } catch { return }
    if (-not $blk -or $blk.Length -lt 0xF8 -or -not $selB) { return }
    # THE FOLD-OUT STUCK SLIDING (Josh, 2026-10-10: "after loading a game I cannot open the system menu anymore"). A load closes
    # the fold-out (0x2C2D4: slide direction 0x1523E8 = -1). From the TITLE MENU it was never open, so its slide position
    # 0x1523E6 starts at 0 and runs below zero for good (0x14947 only stops at exactly 0) -- and cmd 5 (ESC, the menu key)
    # refuses while the direction is not 0. A position below zero never happens otherwise: put the slide at rest (position,
    # direction and the visible word 0x1523EA all 0, as 0x14990 leaves them).
    $e6 = [BitConverter]::ToInt16($blk, 0x10); $e8 = [BitConverter]::ToInt16($blk, 0x12)
    if ($e8 -ne 0 -and $e6 -ge 0 -and -not $script:loadBusy -and -not ($script:visorMenu -and $script:visorMenu.Writing)) {
        if ($script:slideSeen -and $script:slideSeen.Pos -eq $e6 -and $script:slideSeen.At.Elapsed.TotalSeconds -gt 1.0) {
            try { Write-GuestSnap 0x1523E6 ([byte[]]@(0, 0, 0, 0, 0, 0)); Say ("system menu: the fold-out's slide was stuck (direction {0}, position {1}, nothing moving) -- put back at rest, so ESC opens the menu" -f $e8, $e6) Yellow } catch { }
            $script:slideSeen = $null; return
        }
        if (-not $script:slideSeen -or $script:slideSeen.Pos -ne $e6) { $script:slideSeen = @{ Pos = $e6; At = [Diagnostics.Stopwatch]::StartNew() } }
    } else { $script:slideSeen = $null }
    if ($e6 -lt 0) {
        try { Write-GuestSnap 0x1523E6 ([byte[]]@(0, 0, 0, 0, 0, 0)); Say 'system menu: the fold-out''s slide had run below zero (a load from the title) -- put back at rest' Yellow } catch { }
        return
    }
    $sel = [BitConverter]::ToInt16($selB, 0); $de = [BitConverter]::ToInt16($blk, 0x08); $cc = [BitConverter]::ToInt16($blk, 0xF6)
    $scrAt = $(if ($mgr) { GuestPtr ([uint32]($mgr + 0x52)) } else { 0 })
    $scr = $(if ($scrAt) { try { RdU32 $scrAt } catch { 0 } } else { 0 })
    $prev = $script:slGuard
    if ($sel -eq 6 -and $de -eq 0 -and $prev -and $prev.Sel -ne 6) {
        try {
            Write-GuestSnap 0x146948 ([BitConverter]::GetBytes([int16]$prev.Sel))
            Write-GuestSnap 0x1524CC ([BitConverter]::GetBytes([int16]$prev.Cc))      # (memAt.Blk + 0xF6)
            if ($scrAt -and $prev.Scr) { [void][AztTool.ProcMem]::Write($g.ProcessId, $scrAt, [BitConverter]::GetBytes([uint32]$prev.Scr)) }
            Say ("save/load: RESTART's hidden click spot was picked outside the load list -- put back (selection {0}, OK action {1})" -f $prev.Sel, $prev.Cc) Yellow
        } catch { }
        return
    }
    $script:slGuard = @{ Sel = $sel; Cc = $cc; Scr = $scr }
}
# Called once per frame, in place of injecting the picture. Leaves the frame to inject in
# $script:tcPush (NOT returned: a byte[] returned from a function arrives as object[]).
function Step-TrueColour([byte[]]$color) {
    $o = $script:ov
    if ($script:tcState -eq 'run') {
        # the host's 3D is going up: the boot's shutter opens over it from this frame on
        if ($script:bootHd -and $script:bootHd.Holding) { if ($script:tcRaster) { $script:bootHd.Reveal([int]$script:tcRaster.W, [int]$script:tcRaster.H) } else { $script:bootHd.Reveal() }; Write-BootNotes; if ($script:loadGuard) { Set-LoadViewUp }; if ($script:gate -and $script:gate.PickedSlot -ge 0) { Request-TitleLoadShown; $script:titleUnlockAt = [Diagnostics.Stopwatch]::StartNew(); $script:titleUnlockSaid = $false } }
        Step-VisorShade
        # the widescreen panel's text area draws itself over the view: the game's copy there is left out
        # IN THE BOOK / ITEM VIEW (Josh, 2026-10-11: the page was "cut off by some portions of the bottom UI's shape") the
        # panel draws the page itself from the bleed row (OwnFromRow) down -- black plus the page's own pixels (Panel.
        # ComposeBook) -- so the bleed rows stay out of the view's compose as ever, and the opened log box's hide area is
        # dropped: the panel does not draw the box over a page, so nothing of the page may be left out there.
        $bvNow = $false; if ($script:bookViewAt) { try { $bvNow = ($(if ($script:snapOn) { $hv.SnapU32(0x15257C) } else { RdU32 $script:bookViewAt }) -band 0xFFFF) -ne 0 } catch { } }
        $hide = $(if ($script:panel -and -not $bvNow) { $script:panel.HideNow } else { $null })
        $hideFrom = $(if ($script:panel) { $script:panel.OwnFromRow - [int]$man.view.injY } else { [int]::MaxValue })
        # THE GAME'S RETICLE WAITS FOR THE LOCK: while the boot's vector initiation closes on the aim point,
        # the game's own reticle (and the ammo count beside it) is kept out of the picture -- the middle of the
        # view, in game px. The panel's own hide area is only ever the opened log, which is shut during the boot.
        if ($script:bootHd -and $script:bootHd.HideReticle -and -not $hide) { $hide = [int[]]@([int]($W / 2 - 90), [int]($H / 2 - 90), [int]($W / 2 + 90), [int]($H / 2 + 90)) }
        # (THE 3D MAP: the game's own map picture is left out -- ALL of it: its neighbour thumbnails sit where MAPS.DAT puts them,
        # ORRERY's T_CHAM_C at y 17 above the view's top, and showed at the top of the screen -- Josh, 2026-10-14)
        if (Step-Map) { $hide = [int[]]@(-100000, -100000, 100000, 100000) }
        $o.HideRect = $hide; $o.HideFromRow = $hideFrom; if ($script:gpu) { $script:gpu.HideRect = $hide; $script:gpu.HideFromRow = $hideFrom; $script:gpu.KeyAlso = $o.KeyAlso }
        if (-not $script:keyAlsoSaid -and $o.LastShare -ge 800) { $script:keyAlsoSaid = $true; if (($o.LastKey -band 0xFFFFFF) -ne $o.KeyAlso) { Say ("true colour: the key measured on screen #{0:X6} is not the palette's #{1:X6} -- the second key will not match (the map-close block can come back)" -f $o.LastKey, $o.KeyAlso) Yellow } }
        Step-MemCore $o
        # (the HUD's vector text: its state when it changes, with a line it read -- so a session's log shows it working)
        if ($script:panel -and $script:panel.HostText -and $script:panel.TextNote -ne $script:hudTextRaw) {      # (only when the note changes: a regex a frame otherwise)
            $script:hudTextRaw = $script:panel.TextNote
            $hs = ($script:panel.TextNote -replace '\s*\(.*\)', '')
            if ($hs -and $hs -ne $script:hudTextState) { $script:hudTextState = $hs; Say ("hud text: {0} -- '{1}' ({2} lines read, {3} runs left to the game's pixels, {4} times it did not line up, {5} torn readings held steady)" -f $script:panel.TextNote, $script:panel.TextSample, $script:panel.TextLinesDecoded, $script:panel.TextRunsMissed, $script:panel.TextFallbacks, $script:panel.TextHolds) Cyan }
        }
        $memHide = $(if ($script:visorMenu) { $script:visorMenu.HideAll } else { $null })      # (the memory core's panel and/or the system menu's)
        if (-not $script:scanWire) { $o.HideRect2 = $memHide; if ($script:gpu) { $script:gpu.HideRect2 = $memHide } }
        # the scanner's wireframe: while one of the host's sets plays, the game's bitmap box is left out
        if ($script:scanWire) {
            $pn = $null; while ($script:scanWire.PhaseNotes.TryDequeue([ref]$pn)) { Say ("scanner wireframe: " + $pn) DarkCyan }
            $hide2 = $(if ($script:scanWire.HideNow) { [AztTool.ScanWire]::GameRect } else { $memHide })      # (the memory core's when no scan plays)
            $o.HideRect2 = $hide2; if ($script:gpu) { $script:gpu.HideRect2 = $hide2 }
            if ($script:scanWire.Scans -ne $script:scanSaid) {
                $script:scanSaid = $script:scanWire.Scans
                Say ("scan: {0} (who: {1}, told by {2}; frames match {3:N2}); {4} host writes so far{5}" -f $(if ($script:scanWire.Playing) { $script:scanWire.Playing + ' -- the host draws it' } else { 'not one of the host''s sets' }), $(if ($script:scanWire.LastName) { $script:scanWire.LastName } else { '?' }), $script:scanWire.LastHow, $script:scanWire.LastScore, $script:scanWire.Held, $(if ($script:scanWire.LastError) { '; ' + $script:scanWire.LastError } else { '' })) DarkCyan
                if ($script:scanWire.LastItem) { Say ("  item: {0}" -f $script:scanWire.LastItem) DarkCyan }
            }
        }
        $tr = $script:tcRaster
        $pw = $(if ($tr) { [int]$tr.W } else { $W }); $ph = $(if ($tr) { [int]$tr.H } else { $H })
        if ($tr -and $tr.Rgb -and $tr.Color32) {
            if ($script:gpuFrame -and $script:gpu) {
                # PHASE 3, THE CARD: last frame's finished picture to the window (its read-back has
                # long finished), then this frame sharpened and composed there with the overlay's
                # latest reading of the screen, and its read-back started. Nothing waits.
                $gq = $script:gpu
                $bv = $bvNow                                      # (read at the top of this step, for the hide areas too)
                $gq.BlackView = $bv
                # ...and the page in FRONT of the panel (Josh, 2026-10-08): the panel's art steps aside in its own rows and
                # shows the page there, masked by the page surface -- the struct at obj2 0x152580 is {u16 w, u16 h, u32 pixels}
                if ($script:panel) {
                    if ($bv) {
                        try {
                            $wh = RdU32 (& $shotAt 0x152580); $pp = RdU32 (& $shotAt 0x152584)
                            $script:panel.SetBook($(if ($pp -ge 0x1000) { GuestPtr ([uint32]$pp) } else { 0 }), [int]($wh -band 0xFFFF), [int](($wh -shr 16) -band 0xFFFF))
                        } catch { $script:panel.SetBook(0, 0, 0) }
                    }
                    $script:panel.BookView = $bv
                }
                if ($bv -ne $script:bookViewWas) { $script:bookViewWas = $bv; Say ("book/item view {0}: the world behind it {1}{2}" -f $(if ($bv) { 'opened' } else { 'closed' }), $(if ($bv) { 'is black' } else { 'is back' }), $(if ($script:panel) { '; panel: {0} (page reads {1}, failed {2})' -f $(if ($bv) { 'steps aside, the page over its rows' } else { 'back' }), $script:panel.BookReads, $script:panel.BookFails } else { '' })) DarkCyan }
                if (-not $script:gpuShowBuf -or $script:gpuShowBuf.Length -ne $pw * $ph) { $script:gpuShowBuf = New-Object int[] ($pw * $ph) }
                # STRAIGHT INTO ITS WINDOW (optimisation pass, 2026-10-08): the card draws the finished picture into the
                # overlay's own card window, scaled and visor-shaded on the way -- no read-back, no stretching on the
                # processor, no GDI copy (5-15 ms a frame at 4K). Only frames the processor still decorates (the boot's
                # reveal, the scanner, a frame being kept for saving) come back first. -CpuPresent: the old way throughout.
                $glp = $false
                if (-not $CpuPresent) {
                    $gw = $o.GlWindow
                    # (a new window or a new card: attach again, once -- compared as they are, not formatted into a key every frame)
                    if ($gw -ne [IntPtr]::Zero -and ($script:glPresentWndH -ne $gw -or -not [object]::ReferenceEquals($script:glPresentGq, $gq))) {
                        $script:glPresentWndH = $gw; $script:glPresentGq = $gq
                        if ($gq.AttachPresent($gw)) { Say 'picture: straight from the graphics card into its window (no read-back or processor stretch; -CpuPresent = the old way)' Cyan }
                        else { Say ("picture: the card cannot draw into its window ({0}) -- it comes back through the processor as before" -f $gq.PresentError) Yellow }
                    }
                    $glp = $gq.Presenting
                }
                $o.GlPresent = $glp
                # THE DAMAGED VISOR (ScanWire.cs VisorDamage): the glass's layer, the hit, the vitals monitor -- set on the card
                # before this frame is presented (both ways: PresentGpu and PresentPicture share the present pass)
                if ($glp -and -not $NoVisorDamage -and -not $script:visorDmgOff) {
                    if (-not $script:visorDmg) {
                        $script:visorDmg = New-Object AztTool.VisorDamage($o); $script:vdDeaths = 0
                        # the monitor's beeps, its own sound at a third of the boot's level (Josh: "keep them pretty quiet")
                        if (-not $NoBootSound) { $vds = New-Object AztTool.BootSound; $vds.Volume = 0.33 * $(if ($BootSoundVolume -ge 0) { $BootSoundVolume } else { 0.36 }); $script:visorDmg.Sound = $vds }
                        Say 'damaged visor: on (scratches, cracks and the vitals monitor follow the health)' Cyan
                    }
                    try { $script:visorDmg.Menus = $script:visorMenu; $script:visorDmg.Step($gq, $script:hpFrac) } catch { Say ("damaged visor failed: {0} -- off" -f $_.Exception.Message) Yellow; $gq.VisorOn = $false; $script:visorDmg = $null; $script:visorDmgOff = $true }
                    if ($script:visorDmg -and $script:visorDmg.Deaths -ne $script:vdDeaths) { $script:vdDeaths = $script:visorDmg.Deaths; Say ("the player died (health {0}): the vitals monitor slows to a flat line" -f $(if ($null -ne $script:hpRaw) { '{0:N1}' -f ($script:hpRaw / 65536.0) } else { '?' })) DarkYellow }
                    if ($script:visorDmg -and $script:visorDmg.LastError) { Say ("damaged visor: the layer failed ({0})" -f $script:visorDmg.LastError) Yellow; $script:visorDmg.LastError = $null }
                }
                # THE VISOR'S "Scanning..." LABEL while the room materializes (ScanWire.cs ScanTag; the card lays it over)
                if ($glp -and -not $NoMaterialize) {
                    if (-not $script:scanTag) { $script:scanTag = New-Object AztTool.ScanTag($o) }
                    try { $script:scanTag.Step($gq) } catch { Say ("the scanning label failed: {0} -- off" -f $_.Exception.Message) Yellow; $script:scanTag.Enabled = $false; $gq.TagOn = $false }
                } elseif ($gq.TagOn) { $gq.TagOn = $false }
                # THE CONVERSATION CUE (ScanWire.cs ConvTag): the amber edge glow and the recording badge while a conversation
                # is up ([0x152B1C]); its soundwave moves while a line is spoken ([0x152B28])
                if ($glp -and -not $NoConvCue -and -not $script:convTagOff) {
                    if (-not $script:convTag) { $script:convTag = New-Object AztTool.ConvTag($o) }
                    $cvUp = $(if ($script:snapOn) { $hv.SnapWord(0x152B1C) } else { GuestWord 0x152B1C }) -gt 0; $cvSpk = $cvUp -and $(if ($script:snapOn) { $hv.SnapWord(0x152B28) } else { GuestWord 0x152B28 }) -gt 0      # (the frame's snapshot)
                    if ($cvUp -and $script:bootHd -and $script:bootHd.Covering) { $cvUp = $false; $cvSpk = $false }
                    try { $script:convTag.Step($gq, $cvUp, $cvSpk) } catch { Say ("the conversation cue failed: {0} -- off" -f $_.Exception.Message) Yellow; $script:convTagOff = $true; $gq.Tag2On = $false; $gq.ConvGlow = 0 }
                    if ($cvUp -ne [bool]$script:convWas) { $script:convWas = $cvUp; if ($cvUp) { Say 'conversation: the visor records (amber edge, recording badge)' DarkCyan } }
                } elseif ($gq.Tag2On -or $gq.ConvGlow -gt 0) { $gq.Tag2On = $false; $gq.ConvGlow = 0 }
                # VISOR CONDENSATION (ScanWire.cs VisorFog; Josh, 2026-10-14): a room with steam mists the visor's edges, then it
                # clears; a room's "visorFog": false = never, true = even without steam, a number = its strength (with steam)
                if ($glp -and -not $NoVisorFog -and -not $script:visorFogOff) {
                    if (-not $script:visorFog) { $script:visorFog = New-Object AztTool.VisorFog($o) }
                    $vfr = $script:roomVisorFog
                    $steamy = $(if ($vfr -is [bool]) { $vfr } else { [bool]($script:fx -and $script:fx.SteamRate -gt 0) })
                    $script:visorFog.Strength = $(if ($vfr -is [ValueType] -and $vfr -isnot [bool]) { [single]$vfr } else { [single]1 })
                    if (($script:bootHd -and $script:bootHd.Covering) -or $script:mapFreezeCam) { $steamy = $false }
                    try { $script:visorFog.Step($gq, $steamy) } catch { Say ("visor condensation failed: {0} -- off" -f $_.Exception.Message) Yellow; $script:visorFogOff = $true; $gq.VisorFog = 0 }
                } elseif ($gq.VisorFog -gt 0) { $gq.VisorFog = 0 }
                $dyn = (-not $glp) -or $o.KeepCopy -or ($script:bootHd -and $script:bootHd.Covering) -or ($script:scanWire -and $script:scanWire.Playing) -or ($script:visorNote -and $script:visorNote.Playing) -or ($script:visorMenu -and $script:visorMenu.AnyPlaying)
                if ($dyn) {
                    if ($gq.FinishRead($script:gpuShowBuf)) {
                        # (while a visor panel shows, the undecorated picture is kept: the save stalls the game for ~3 s and
                        # Repaint-HeldPicture re-lays the panel -- its "writing log" animation -- over it, frame after frame)
                        if ($glp -and $script:visorMenu -and $script:visorMenu.AnyPlaying) {
                            if (-not $script:gpuClean -or $script:gpuClean.Length -ne $script:gpuShowBuf.Length) { $script:gpuClean = New-Object int[] $script:gpuShowBuf.Length }
                            [Array]::Copy($script:gpuShowBuf, $script:gpuClean, $script:gpuShowBuf.Length); $script:gpuCleanW = $pw; $script:gpuCleanH = $ph
                        }
                        if ($glp) { $o.DecorateOnly($script:gpuShowBuf, $pw, $ph); if ($gq.PresentPicture($script:gpuShowBuf, $pw, $ph)) { $o.NoteGlFrame() } }
                        else { $script:gpuShowBuf = $o.ShowComposed($script:gpuShowBuf, $pw, $ph) }
                    }
                } elseif ($gq.ReadPending) { $gq.DropRead() }
                # ONE C# CALL (FrameStep.ComposePresent, 2026-10-13 performance audit): the screen reading taken, composed over
                # the picture on the card, then read back (dyn) or presented into the card's window with the visor's shading --
                # the same calls in the same order the script made, without its twelve [ref]s
                $share = [AztTool.FrameStep]::ComposePresent($o, $gq, $pw, $ph, $TcMinShare, [single]$(if ($postOn) { $Sharpen } else { 0 }), $W, $H, [bool]$dyn, $script:visorShade)
            } else {
                if ($script:gpu) { $script:gpu.DropRead() }     # (a picture started on the card is not the one to show now)
                $o.GlPresent = $false                            # (the processor's picture goes to the overlay's own window)
                # hand the picture over and take back another buffer to draw the next one into
                $tr.Color32 = $o.SubmitRgb($tr.Color32, $pw, $ph, $TcMinShare)
                $share = $o.LastShare
            }
        } else { $o.GlPresent = $false; $share = $o.Present($color, $script:tcPal32, $pw, $ph, $TcMinShare) }
        $script:tcPush = $script:tcKeyFrame
        if ($share -lt 0) {
            $script:tcReadFails++
            if ($script:tcReadFails -ge 60) { Stop-TrueColour 'the display surface can no longer be read' }
            return
        }
        $script:tcReadFails = 0; $script:tcShareSum += $share; $script:tcShareN++
        if ($share -lt $TcMinShare) { $script:tcHidden++ }
        return
    }
    $script:tcPush = $script:tcPatch; $script:tcCount++
    [void]$o.HoldGuestFrame()
    if ($script:tcCount -lt 8) { return }            # the patch has to have reached the screen
    Start-Sleep -Milliseconds 120
    $spot = $script:tcSpots[$script:tcSpot]
    if ($script:tcState -eq 'find') {
        $bases = New-Object System.Collections.Generic.List[long]; $sizes = New-Object System.Collections.Generic.List[long]; $mb = 0.0
        foreach ($rg in [AztTool.ProcMem]::Regions($g.ProcessId, 0x7FFFFFFFFFFF)) {
            if ($rg.Size -ge ([long]$W * $H * 4) -and $rg.Size -le 600MB) { $bases.Add($rg.Base); $sizes.Add($rg.Size); $mb += $rg.Size / 1MB }
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $found = $o.FindPatch($bases.ToArray(), $sizes.ToArray(), [int]$spot[0], [int]$spot[1], 256, 128)
        Say ("true colour: searched {0} regions ({1:N0} MB) of DOSBox in {2} ms -- the calibration patch is in {3} place(s); {4} slow-to-read region(s) left unsearched" -f $bases.Count, $mb, $clock.ElapsedMilliseconds, $found.Count, $o.SlowRegionsSkipped) Cyan
        foreach ($c in $found) { Say ("    viewport at host 0x{0:X}, {1} pixels a row" -f $c[0], $c[1]) DarkGray }
        if ($found.Count -eq 0) {
            $script:tcTries++; $script:tcCount = 0
            if ($script:tcTries -ge 3) { Stop-TrueColour 'the calibration patch was never found in DOSBox''s memory' }
            return
        }
        $script:tcCands = $found; $script:tcSpot = 1; $script:tcState = 'confirm'; $script:tcCount = 0
        $spot = $script:tcSpots[1]
        $script:tcPatch = [AztTool.Overlay]::PatchFrame($W, $H, [byte]$script:tcKeyA, [byte]$script:tcKeyB, [int]$spot[0], [int]$spot[1], 256, 128)
        return
    }
    # 'confirm': which of them followed the patch to its new place?
    # ...AND WHICH OF THOSE IS QUICKEST TO READ. The first run took the first live copy, and it
    # cost 277 ms a read -- the picture ran at 3-5 fps behind it. The screen is in several
    # places in DOSBox; some are ordinary memory and some evidently belong to the graphics driver.
    $live = $null; $liveMs = 0.0
    foreach ($c in $script:tcCands) {
        if (-not $o.CheckPatch([long]$c[0], [int]$c[1], [int]$spot[0], [int]$spot[1], 256, 128)) { Say ("    0x{0:X}: did not follow the patch (a stale copy)" -f $c[0]) DarkGray; continue }
        $ms = $o.TimeRead([long]$c[0], [int]$c[1])
        Say ("    0x{0:X}: live, {1:N1} ms to read" -f $c[0], $ms) DarkGray
        if ($ms -ge 0 -and (-not $live -or $ms -lt $liveMs)) { $live = $c; $liveMs = $ms }
    }
    if (-not $live) {
        if ($script:tcSpot -lt $script:tcSpots.Count - 1) {
            $script:tcSpot++; $script:tcCount = 0; $spot = $script:tcSpots[$script:tcSpot]
            $script:tcPatch = [AztTool.Overlay]::PatchFrame($W, $H, [byte]$script:tcKeyA, [byte]$script:tcKeyB, [int]$spot[0], [int]$spot[1], 256, 128)
            return
        }
        $live = $script:tcCands[0]
        Say 'true colour: no copy followed the moved patch (is something drawn over those spots?) -- using the first one found, UNCONFIRMED' Yellow
    }
    $o.SetSurface([long]$live[0], [int]$live[1])
    $script:tcState = 'run'; $script:tcPush = $script:tcKeyFrame
    # (already up if it came in with the boot: it picks the screen up from the overlay by itself)
    if (-not $script:panel) { Start-WidePanel $o }
    Say ("true colour: display surface at host 0x{0:X} ({1} px rows); DOSBox window {2}; overlay {3}" -f $live[0], $live[1], $o.GameWindowText, $o.RectText) Green
}

# ---- ATMOSPHERE: fog, dust and placed lights, per room ------------------------------------
# The game has no lights of its own -- every torch is paint on a texture -- so there is nothing
# to read: a room's lights are PLACED, by hand, in its file. Fog and dust come by room class
# (every cave gets the cave fog) unless the room's own file says otherwise.
function ConvertTo-Rgb24([string]$hex, [int]$fallback) {
    if (-not $hex) { return $fallback }
    $h = $hex.Trim().TrimStart('#'); if ($h.Length -ne 6) { return $fallback }
    try { return [Convert]::ToInt32($h, 16) } catch { return $fallback }
}
function Get-RoomAtmosphere([string[]]$names) {
    $res = [pscustomobject]@{ Fog = $null; Dust = $null; Lights = @(); Source = @(); Mist = $null; Drips = $null; Steam = $null; Kickup = $null; Embers = $null; Volume = $null; Water = $null; Holograms = $null; Gi = $null; Visor = $null; WaterMist = $null; Holes = $null; NoCast = $null; ArtLight = $null; Ghost = $null; Materials = $null; Shine = $null; Wet = $null; Repair = 'default'; Parallax = 1.0; VisorFog = $null; ReactDust = $null; EyeShine = $null; Impacts = $null; Footsteps = $null; Name = '' }
    $first = $(if ($names.Count) { ([string]$names[0]).ToUpper() } else { '' }); $res.Name = $first
    try {
        $defPath = Join-Path $RoomsDir '_defaults.json'
        if (Test-Path $defPath) {
            $def = Get-Content $defPath -Raw | ConvertFrom-Json
            foreach ($cls in $def.classes.PSObject.Properties) {
                $list = @($cls.Value.rooms | ForEach-Object { ([string]$_).ToUpper() })
                # "*" names every room; classes apply in file order, later ones overriding earlier
                if ($list -contains $first -or $list -contains '*') {
                    if ($cls.Value.fog)  { $res.Fog  = $cls.Value.fog }
                    if ($cls.Value.dust) { $res.Dust = $cls.Value.dust }
                    if ($cls.Value.lights) { $res.Lights = @($cls.Value.lights) }
                    foreach ($k in 'mist', 'drips', 'steam', 'kickup', 'embers', 'volume', 'water', 'holograms', 'gi', 'visor', 'waterMist', 'holes', 'noCast', 'artLight', 'ghost', 'materials', 'shine', 'wet', 'repair', 'parallax', 'visorFog', 'reactDust', 'eyeShine', 'impacts', 'footsteps') { if ($cls.Value.PSObject.Properties[$k]) { $res.$k = $cls.Value.$k } }
                    $res.Source += ('class ' + $cls.Name)
                }
            }
        }
        $own = Join-Path $RoomsDir ("{0}.json" -f $first)
        if (Test-Path $own) {
            $o = Get-Content $own -Raw | ConvertFrom-Json
            if ($o.PSObject.Properties['fog'])    { $res.Fog  = $o.fog }
            if ($o.PSObject.Properties['dust'])   { $res.Dust = $o.dust }
            if ($o.PSObject.Properties['lights']) { $res.Lights = @($o.lights) }
            foreach ($k in 'mist', 'drips', 'steam', 'kickup', 'embers', 'volume', 'water', 'holograms', 'gi', 'visor', 'waterMist', 'holes', 'noCast', 'artLight', 'ghost', 'materials', 'shine', 'wet', 'repair', 'parallax', 'visorFog', 'reactDust', 'eyeShine', 'impacts', 'footsteps') { if ($o.PSObject.Properties[$k]) { $res.$k = $o.$k } }
            $res.Source += ("{0}.json" -f $first)
        }
    } catch { Say ("atmosphere file problem: {0}" -f $_.Exception.Message) Yellow }
    return $res
}
function Set-RoomAtmosphere($ras, $atm, $roomObj) {
    # fog
    $ras.Fog32 = $false
    if ($atm.Fog -and -not $NoFog -and $ras.Rgb) {
        $ras.Fog32 = $true; $ras.FogColor32 = ConvertTo-Rgb24 ([string]$atm.Fog.color) 0x120C08
        $ras.Fog32Near = [single]$(if ($atm.Fog.near) { $atm.Fog.near } else { 120 }); $ras.Fog32Far = [single]$(if ($atm.Fog.far) { $atm.Fog.far } else { 820 })
        $ras.Fog32Max = [single]$(if ($null -ne $atm.Fog.max) { $atm.Fog.max } else { 0.88 })
    }
    # dust: a fresh cloud inside the room's own box
    $script:motes = $null
    if ($atm.Dust -and -not $NoDust -and $ras.Rgb -and [int]$atm.Dust.count -gt 0) {
        $m = New-Object AztTool.Motes([int]$atm.Dust.count)
        if ($atm.Dust.radius) { $m.Radius = [single]$atm.Dust.radius }; if ($atm.Dust.size) { $m.Size = [single]$atm.Dust.size }
        if ($atm.Dust.drift) { $m.Drift = [single]$atm.Dust.drift }; if ($null -ne $atm.Dust.brightness) { $m.Brightness = [single]$atm.Dust.brightness }
        if ($null -ne $atm.Dust.sizeMin) { $m.SizeMin = [single]$atm.Dust.sizeMin }
        $m.Color = ConvertTo-Rgb24 ([string]$atm.Dust.color) 0xD8C8B0
        # flashlight off: "colorDark" and "darkAlpha" (how solid the specks are)
        $m.ColorDark = ConvertTo-Rgb24 ([string]$atm.Dust.colorDark) 0x6E5E4C
        if ($null -ne $atm.Dust.darkAlpha) { $m.DarkAlpha = [single]$atm.Dust.darkAlpha }
        $v = $roomObj.V; $lo = @([single]::MaxValue) * 3; $hi = @([single]::MinValue) * 3
        for ($i = 0; $i -lt $v.Length; $i += 3) { for ($k = 0; $k -lt 3; $k++) { $c = $v[$i + $k]; if ($c -lt $lo[$k]) { $lo[$k] = $c }; if ($c -gt $hi[$k]) { $hi[$k] = $c } } }
        $m.SetBounds($lo[0], $hi[0], $lo[1], $hi[1], $lo[2], $hi[2]); $m.Reset()
        $script:motes = $m
    }
    # lights: kept as given; strength with flicker is worked out every frame
    $script:roomLights = @(); $script:roomWashes = @(); $script:roomVisorFog = $atm.VisorFog; $script:roomAtmNow = $atm
    if (-not $NoLights -and $ras.Rgb) {
        foreach ($l in @($atm.Lights)) {
            if ($null -eq $l.x) { continue }
            # WALL WASHES (2026-10-14, Josh, CHAMBNEW: an uplight under each spotlight painted on the walls): "wash": true = a
            # steady spotlight with no shadow, outside the eight placed lights (GpuRaster.SetWashes, up to 16): x y z, dir, cone,
            # color, power, range, bounce. Graphics card only.
            if ($l.wash) {
                $wd = @($(if ($l.dir -and @($l.dir).Count -eq 3) { [double]$l.dir[0]; [double]$l.dir[1]; [double]$l.dir[2] } else { 0.0; 1.0; 0.0 }))
                $wl = [Math]::Sqrt($wd[0] * $wd[0] + $wd[1] * $wd[1] + $wd[2] * $wd[2]); if ($wl -lt 1e-6) { $wd = @(0.0, 1.0, 0.0); $wl = 1.0 }
                $wcol = ConvertTo-Rgb24 ([string]$l.color) 0xFFE8C8
                $script:roomWashes += [pscustomobject]@{ X = [single]$l.x; Y = [single]$l.y; Z = [single]$l.z; R = (($wcol -shr 16) -band 255) / 255.0; G = (($wcol -shr 8) -band 255) / 255.0; B = ($wcol -band 255) / 255.0
                    Power = [double]$(if ($null -ne $l.power) { $l.power } else { 1.0 }); Range = [single]$(if ($l.range) { $l.range } else { 250 })
                    Dir = @(($wd[0] / $wl), ($wd[1] / $wl), ($wd[2] / $wl)); Cone = $(if ($l.cone -and @($l.cone).Count -eq 2) { @([double]$l.cone[0], [double]$l.cone[1]) } else { @(20.0, 35.0) })
                    Bounce = [double]$(if ($null -ne $l.bounce) { $l.bounce } else { 1.0 }) }
                continue
            }
            $col = ConvertTo-Rgb24 ([string]$l.color) 0xFFB266
            # "dir": which way the light faces (a wall torch: the wall's normal, into the room). With
            # it, and unless "shadow": false, the light casts shadows the way the flashlight does.
            $dir = $null
            if ($l.dir -and @($l.dir).Count -eq 3) {
                $dx0 = [double]$l.dir[0]; $dy0 = [double]$l.dir[1]; $dz0 = [double]$l.dir[2]
                $dl = [Math]::Sqrt($dx0*$dx0 + $dy0*$dy0 + $dz0*$dz0)
                # (each component on its own line: `@($a/$l, $b/$l)` is read as `$a / ($l, $b/$l)` by PowerShell)
                if ($dl -ge 1e-6) { $dx0 = $dx0 / $dl; $dy0 = $dy0 / $dl; $dz0 = $dz0 / $dl; $dir = @($dx0, $dy0, $dz0) }
            }
            $shadow = ($null -ne $dir) -and ($null -eq $l.shadow -or [bool]$l.shadow)
            $script:roomLights += [pscustomobject]@{ X = [single]$l.x; Y = [single]$l.y; Z = [single]$l.z; R = (($col -shr 16) -band 255) / 255.0; G = (($col -shr 8) -band 255) / 255.0; B = ($col -band 255) / 255.0
                Power = [double]$(if ($null -ne $l.power) { $l.power } else { 1.0 }); Range = [single]$(if ($l.range) { $l.range } else { 250 }); Flicker = [double]$(if ($null -ne $l.flicker) { $l.flicker } else { 0.3 })
                Phase = [double](Get-Random -Minimum 0.0 -Maximum 6.28); Noise = 0.0; Dir = $dir; Shadow = $shadow
                # (2026-10-08) "cone": [inner, outer] degrees round "dir" = a spotlight; "air" = its strength in the volumetric
                # fog (1 = as bright as on surfaces); "airReach" = its reach there; "rays" 0..1 = streaks across its cone
                Cone = $(if ($l.cone -and @($l.cone).Count -eq 2) { @([double]$l.cone[0], [double]$l.cone[1]) } else { $null })
                Air = [double]$(if ($null -ne $l.air) { $l.air } else { 1.0 }); AirReach = [double]$(if ($null -ne $l.airReach) { $l.airReach } else { 0 }); Rays = [double]$(if ($null -ne $l.rays) { $l.rays } else { 0 })
                # "colorFar" + "tintFrom"/"tintTo": its colour shifts to colorFar between those distances (surfaces and air);
                # "dust": {count, size} = specks floating in its cone, lit by it (a spotlight's shaft)
                ColorRgb = $col; ColorFar = $(if ($l.colorFar) { ConvertTo-Rgb24 ([string]$l.colorFar) $col } else { $null })
                TintFrom = [double]$(if ($null -ne $l.tintFrom) { $l.tintFrom } else { 0 }); TintTo = [double]$(if ($null -ne $l.tintTo) { $l.tintTo } else { 1 })
                Dust = $l.dust
                # (2026-10-09) "bounce": how much of this light goes into the room's bounced light (1 = as it shines; a narrow
                # shaft through a hole needs more to fill the room as the torches do). "dance": how far (units) a flickering
                # light's point wanders round its flame, so its shadows sway with the flicker (default 7 x flicker; 0 = still)
                Bounce = [double]$(if ($null -ne $l.bounce) { $l.bounce } else { 1.0 }); AirFirst = [bool]$l.airFirst      # ("airFirst": always one of the four lights the fog shows)
                OneSided = [bool]$l.oneSided      # ("oneSided": lights only the side of a face the eye is on -- sun outside a window, 2026-10-14)
                # ("gate": [x0, y0, z0, x1, y1, z1] = it reaches only what it sees through that box -- a window's opening, so a sun
                # outside a room with no ceiling does not come in over the walls: BAPTIST, 2026-10-14)
                Gate = $(if ($l.gate -and @($l.gate).Count -eq 6) { [single[]]@($l.gate) } else { $null })
                Dance = [double]$(if ($null -ne $l.dance) { $l.dance } elseif ($null -ne $l.flicker) { 7 * [double]$l.flicker } else { 7 * 0.3 })
                # (2026-10-09, Josh, ORRERY/3) "cycle": {colors: ["#RRGGBB", ...], seconds, offset 0..1} = its colour drifts
                # round those colours in a slow loop (eased between each), on surfaces and in the air alike
                Cycle = $(if ($l.cycle -and @($l.cycle.colors).Count -ge 2) { [int[]]@($l.cycle.colors | ForEach-Object { ConvertTo-Rgb24 ([string]$_) $col }) } else { $null })
                CycleSec = [double]$(if ($l.cycle -and $l.cycle.seconds) { $l.cycle.seconds } else { 16 }); CycleOff = [double]$(if ($l.cycle -and $null -ne $l.cycle.offset) { $l.cycle.offset } else { 0 })
                Jx = 0.0; Jy = 0.0; Jz = 0.0 }
        }
    }
    if ($script:roomLights.Count -gt [AztTool.Raster]::MaxLights) { $script:roomLights = @($script:roomLights | Select-Object -First ([AztTool.Raster]::MaxLights)) }
    if ($script:roomWashes.Count -gt 16) { $script:roomWashes = @($script:roomWashes | Select-Object -First 16) }
    # a small depth view per shadowing light: 512 square, 110 degrees, looking the way it faces
    $ras.ClearLightShadows(); $script:lightRs = @()
    foreach ($l in $script:roomLights) {
        if (-not $l.Shadow) { $script:lightRs += $null; continue }
        $lz = New-Object AztTool.Raster(512, 512); $lz.NearZ = [single]0.5; $lz.SetVerticalFov(110); $lz.Threads = [Math]::Max(2, [int]($ras.Threads / 2))
        $script:lightRs += $lz
    }
    Say ("  atmosphere: fog {0}; dust {1}; lights {2}{3}{4}" -f $(if ($ras.Fog32) { ('#{0:X6} {1:N0}-{2:N0}' -f $ras.FogColor32, $ras.Fog32Near, $ras.Fog32Far) } else { 'none' }), `
        $(if ($script:motes) { $script:motes.Count } else { 'none' }), $script:roomLights.Count, $(if ($script:roomWashes.Count) { ' + {0} wall washes' -f $script:roomWashes.Count } else { '' }), $(if ($atm.Source.Count) { ' (' + ($atm.Source -join ', ') + ')' } else { '' })) Cyan
}
# ---- THE CARD'S OWN ATMOSPHERE: ground mist and particles (graphics card only) ----------------
# From the same room files: "mist" (density at the floor, how fast it thins with height, colour,
# wisps), "embers" (from every flickering light), "drips" (from the ceilings), "steam" (from the
# floor) and "kickup" (dust at the feet while walking). Set when a room loads, like the fog.
# ---- BOUNCED LIGHT (2026-10-09, Josh: "Bounced light (global illumination), pre-calculated per room ... It would
# recalculate whenever a room file changes") ---------------------------------------------------------------------------
# A room with a "gi" block gets the light its placed lights throw off every surface onto every other (GiBake: a grid of
# probes, rays traced on the processor, bounced "bounces" times). Keyed by a signature of the geometry, the textures'
# colours, the lights and the settings: the first visit with any of those changed works it out in the background (a share
# of the processor's threads, below normal priority -- the game is never held up) and saves it in <CacheDir>\gi; every
# later visit loads it at once. The room is drawn as before until it is ready. Keys: strength (1), ambient (0.6: the
# room's flat level while it is on, as a share -- the bounce takes over part of what it stood in for), spacing (20 units
# between probes), rays (64 per probe), bounces (3), albedo (1: how much light the surfaces give back).
$script:giBake = $null; $script:giSync = $false
function Set-GpuGi($gq, $atm, $roomObj) {
    if ($script:giBake) { $script:giBake.Cancel(); $script:giBake = $null }
    $gq.ClearGi()
    if (-not $atm.Gi -or $NoGi -or -not $roomObj -or -not (@($script:roomLights).Count + $(if ($script:roomWashes) { @($script:roomWashes).Count } else { 0 }))) { return }
    $gi = $atm.Gi
    $gq.GiStrength = [single]$(if ($null -ne $gi.strength) { $gi.strength } else { 1 }); $gq.GiAmbient = [single]$(if ($null -ne $gi.ambient) { $gi.ambient } else { 0.6 })
    $b = New-Object AztTool.GiBake
    if ($gi.spacing) { $b.Spacing = [single]$gi.spacing }; if ($gi.rays) { $b.Rays = [int]$gi.rays }; if ($null -ne $gi.bounces) { $b.Bounces = [int]$gi.bounces }; if ($null -ne $gi.albedo) { $b.Albedo = [single]$gi.albedo }
    foreach ($l in $script:roomLights) {
        $bl = New-Object AztTool.GiBake+Light
        $bl.X = $l.X; $bl.Y = $l.Y; $bl.Z = $l.Z; $bl.R = [single]($l.R * $l.Power * $l.Bounce); $bl.G = [single]($l.G * $l.Power * $l.Bounce); $bl.B = [single]($l.B * $l.Power * $l.Bounce); $bl.Range = [single]$l.Range; $bl.Shadow = [bool]$l.Shadow
        if ($l.Dir) { $bl.DX = [single]$l.Dir[0]; $bl.DY = [single]$l.Dir[1]; $bl.DZ = [single]$l.Dir[2] }
        if ($l.Gate) { $bl.Gate = $true; $bl.GX0 = [Math]::Min($l.Gate[0], $l.Gate[3]); $bl.GY0 = [Math]::Min($l.Gate[1], $l.Gate[4]); $bl.GZ0 = [Math]::Min($l.Gate[2], $l.Gate[5]); $bl.GX1 = [Math]::Max($l.Gate[0], $l.Gate[3]); $bl.GY1 = [Math]::Max($l.Gate[1], $l.Gate[4]); $bl.GZ1 = [Math]::Max($l.Gate[2], $l.Gate[5]) }
        if ($l.Cone -and $l.Cone[1] -gt 0.01) { $bl.CosIn = [single][Math]::Cos([Math]::Min($l.Cone[0], $l.Cone[1] - 0.01) * [Math]::PI / 180); $bl.CosOut = [single][Math]::Cos($l.Cone[1] * [Math]::PI / 180) }
        $b.Lights.Add($bl)
    }
    foreach ($l in @($script:roomWashes | Where-Object { $_ })) {      # (the wall washes bounce like any light -- traced with shadows here)
        $bl = New-Object AztTool.GiBake+Light
        $bl.X = $l.X; $bl.Y = $l.Y; $bl.Z = $l.Z; $bl.R = [single]($l.R * $l.Power * $l.Bounce); $bl.G = [single]($l.G * $l.Power * $l.Bounce); $bl.B = [single]($l.B * $l.Power * $l.Bounce); $bl.Range = [single]$l.Range; $bl.Shadow = $true
        $bl.DX = [single]$l.Dir[0]; $bl.DY = [single]$l.Dir[1]; $bl.DZ = [single]$l.Dir[2]
        $bl.CosIn = [single][Math]::Cos([Math]::Min($l.Cone[0], $l.Cone[1] - 0.01) * [Math]::PI / 180); $bl.CosOut = [single][Math]::Cos($l.Cone[1] * [Math]::PI / 180)
        $b.Lights.Add($bl)
    }
    $b.SetRoom($roomObj.V, $roomObj.UV, $roomObj.T, $roomObj.TexIdx, $roomObj.Texes, $true)
    $sig = $b.MakeSignature()
    $file = Join-Path (Join-Path $CacheDir 'gi') ("{0}-{1}.gi" -f $(if ($atm.Name) { $atm.Name } else { 'ROOM' }), $sig)
    if (Test-Path $file) {
        try {
            $c = [AztTool.GiBake]::Load($file)
            if ($gq.SetGi($c)) { Say ("  bounced light: cached ({0})" -f $c.Note) Cyan } else { Say ("  bounced light: {0}" -f $gq.GiNote) Yellow }
            return
        } catch { Say ("  bounced light cache unreadable, working it out again: {0}" -f $_.Exception.Message) Yellow }
    }
    $b.SavePath = $file
    if ($script:giSync) { $b.Run(); $script:giBake = $b; Complete-GpuGi $gq; return }
    $b.Threads = [Math]::Max(1, [int]([Environment]::ProcessorCount / 2)); $b.Priority = [System.Threading.ThreadPriority]::BelowNormal
    [void]$b.Start(); $script:giBake = $b
    Say ("  bounced light: working it out in the background ({0} lights, {1} threads below normal priority)..." -f $b.Lights.Count, $b.Threads) Cyan
}
# (each frame, on the drawing thread) a finished bake goes up to the card
function Complete-GpuGi($gq) {
    $b = $script:giBake; if (-not $b -or -not $b.Done) { return }
    $script:giBake = $null
    if ($b.Error) { if ($b.Error -ne 'cancelled') { Say ("  bounced light failed: {0}" -f $b.Error) Yellow }; return }
    if ($gq.SetGi($b)) { Say ("  bounced light: ready ({0})" -f $b.Note) Green } else { Say ("  bounced light: {0}" -f $gq.GiNote) Yellow }
}
# TEXTURE RULES BY NAME (Josh, 2026-10-09, Room Review MINEHEAD/1): "holes": [{ "texture": "37-mineplab", "minLum": 120,
# "box": [x0, y0, x1, y1] }] cuts holes where that texture's original art is at least minLum bright (the painted light
# grid becomes real openings: picture, shadows and bounce alike); "noCast": ["38-mineplat"] = textures that cast no shadow
# (a slab over a grate, so light from above reaches it). Textures are shared between rooms, so every room entry puts back
# what its own file does not ask for.
function Set-RoomTextureRules($gq, $atm, $roomObj) {
    if (-not $roomObj -or -not $roomObj.Texes) { return }
    $holes = @{}; foreach ($hr in @($atm.Holes)) { if ($hr -and $hr.texture) { $holes[[string]$hr.texture] = $hr } }
    $nc = @{}; foreach ($nn in @($atm.NoCast)) { if ($nn) { $nc[[string]$nn] = 1 } }
    foreach ($tx in $roomObj.Texes) {
        if (-not $tx) { continue }
        $lf = [string]$tx.Leaf
        if ($lf -and $holes.ContainsKey($lf)) {
            # ("boxes": [[x0, y0, x1, y1], ...] = several areas, as "box" one)
            $hr = $holes[$lf]; $box = $(if ($hr.boxes) { $bl = [int[]]@(foreach ($bx in @($hr.boxes)) { if (@($bx).Count -eq 4) { @($bx) } }); if ($bl.Length -ge 4) { ,$bl } else { $null } } elseif ($hr.box -and @($hr.box).Count -eq 4) { [int[]]@($hr.box) } else { $null })
            $cut = $tx.CutHoles($pal, [int]$(if ($null -ne $hr.minLum) { $hr.minLum } else { 120 }), $box)
            if ($gq) { [void]$gq.RefreshMask($tx) }
            # ("glass": 0..1 = the holes drawn as panes at that share of their own colour, light passing; "glassTint": the light
            # behind them -- Josh, 2026-10-14, BAPTIST/1: the windows "transparent with 30% opacity")
            $tx.Glass = [single]$(if ($null -ne $hr.glass) { $hr.glass } else { 0 }); $tx.GlassTint = $(if ($hr.glassTint) { ConvertTo-Rgb24 ([string]$hr.glassTint) 0xFFFFFF } else { 0xFFFFFF })
            Say ("  holes: {0} texels of {1} cut where its art is bright{2}" -f $cut, $lf, $(if ($tx.Glass -gt 0) { " (glass at {0:P0})" -f $tx.Glass } else { "" })) Cyan
        } else { $tx.Glass = 0; if ($tx.IdxOrig) { [void]$tx.RestoreHoles(); if ($gq) { [void]$gq.RefreshMask($tx) } } }
        $tx.NoCast = [bool]($lf -and $nc.ContainsKey($lf))
    }
}
# A GHOST (Josh, 2026-10-11, WELLROOM: Niamh, the floating lady -- "more ethereal ... look like a ghost and not a bunch of
# polygons"): "ghost": { "characters": [rig names], "color", "rim", "texture", "textureColour" (her own painted colours inside
# the glow, 0..1), "opacity", "density", "rimGlow", "soft", "core",
# "glow", "fade": [low, high], "noise": { amount, size, rise }, "shimmer", "breath", "wisps": { rate, size, life, rise, alpha,
# spread, color, parts: [pieces of part names] } (false = none), "light": { power, color, range, air, height } (false = none) }
# -- sizes are shares of her height. The card draws those characters as glowing smoke (GpuRaster.DrawGhost); the processor's
# picture and -Retro draw them as before.
function Set-GpuGhost($gq, $gh) {
    $script:ghostAtm = $gh; $script:ghostSeen = $false; $gq.GhostOn = [bool]$gh; $gq.GhostError = $null
    if (-not $gh) { return }
    $d = { param($x, $def) if ($null -ne $x) { [single]$x } else { [single]$def } }
    $gq.GhostColor = ConvertTo-Rgb24 ([string]$gh.color) 0xBFF6F0; $gq.GhostRimColor = ConvertTo-Rgb24 ([string]$gh.rim) 0xE6FFFF
    $gq.GhostTexture = & $d $gh.texture 0.55; $gq.GhostOpacity = & $d $gh.opacity 0.6; $gq.GhostDensity = & $d $gh.density 8; $gq.GhostRim = & $d $gh.rimGlow 1.0; $gq.GhostBright = & $d $gh.bright 1.8; $gq.GhostTexColour = & $d $gh.textureColour 0
    $gq.GhostSoft = & $d $gh.soft 0.02; $gq.GhostCore = & $d $gh.core 0.6; $gq.GhostGlow = & $d $gh.glow 0.8
    $fd = @($gh.fade); $gq.GhostFadeLow = & $d $(if ($fd.Count -eq 2) { $fd[0] } else { $null }) 0.02; $gq.GhostFadeHigh = & $d $(if ($fd.Count -eq 2) { $fd[1] } else { $null }) 0.72
    $nz = $gh.noise; $gq.GhostNoise = & $d $nz.amount 0.7; $gq.GhostNoiseSize = & $d $nz.size 0.12; $gq.GhostNoiseRise = & $d $nz.rise 0.06
    $gq.GhostShimmer = & $d $gh.shimmer 3; $gq.GhostBreath = & $d $gh.breath 0.08
    $li = $gh.light
    if ($li -is [bool] -and -not $li) { $gq.GhostLight = [single]0 }
    else { $gq.GhostLight = & $d $li.power 0.25; $gq.GhostLightRange = & $d $li.range 1.0; $gq.GhostLightAir = & $d $li.air 1.5; $gq.GhostLightHeight = & $d $li.height 0.8; $gq.GhostLightColor = ConvertTo-Rgb24 ([string]$li.color) 0x8FE6DC }
    Say ("  ghost: {0} as glowing smoke -- #{1:X6}, opacity {2}, fading below {3:P0} of her; her light {4}" -f (@($gh.characters) -join ', '), $gq.GhostColor, $gq.GhostOpacity, $gq.GhostFadeHigh, $(if ($gq.GhostLight -gt 0) { '{0} #{1:X6}' -f $gq.GhostLight, $gq.GhostLightColor } else { 'off' })) Cyan
}
# Which textures are the ghost's (Tex.Ghost) and where her wisps come from ($script:ghostWispVerts), for the room as built --
# again whenever its characters change (they are added to the room after it loads). Textures are shared between rooms, so
# every room's own are cleared first.
function Set-RoomGhosts($gq, $roomObj) {
    $script:ghostWispVerts = [int[]]@()
    if (-not $roomObj -or -not $roomObj.Texes) { return }
    foreach ($tx in $roomObj.Texes) { if ($tx) { $tx.Ghost = $false } }
    $gh = $script:ghostAtm
    if (-not $gh -or -not $gq -or -not $gq.GhostOn) { return }
    $want = @($gh.characters | Where-Object { $_ } | ForEach-Object { ([string]$_).ToUpper() })
    $pieces = @($(if ($gh.wisps -and $gh.wisps -isnot [bool] -and $gh.wisps.parts) { $gh.wisps.parts } else { @('NSKIRT', 'NIHAND', 'NILEG') }) | ForEach-Object { ([string]$_).ToUpper() })
    $found = @{}; $wv = New-Object 'System.Collections.Generic.List[int]'
    foreach ($pt in @($roomObj.Parts)) {
        if (-not $pt.IsCharacter) { continue }
        $rig = ([string]$pt.Room).ToUpper(); if ($want -notcontains $rig) { continue }
        if (-not $found.ContainsKey($rig)) {
            $found[$rig] = 0; $mem = $script:AztUnitMem[[string]$pt.Room]
            if ($mem) { foreach ($tx in @($mem.Tex)) { if ($tx) { $tx.Ghost = $true; $found[$rig]++ } } }
        }
        $pn = ([string]$pt.Name).ToUpper()
        foreach ($pc in $pieces) { if ($pn.Contains($pc)) { for ($v = 0; $v -lt [int]$pt.VCount; $v++) { $wv.Add([int]$pt.VFirst + $v) }; break } }
    }
    $script:ghostWispVerts = $wv.ToArray()
    foreach ($k in $found.Keys) { Say ("  ghost: {0} is here -- {1} of its textures drawn as smoke, wisps from {2} of its points" -f $k, $found[$k], $wv.Count) Cyan }
}
# MATERIALS (Josh, 2026-10-12: "Material tags for every texture ... Shine where it belongs. Your helmet lamp would glint off
# brass and gold, give wet stone a sheen, and leave wood and cloth dull"): what every texture is -- rooms\_materials.json
# (the materials, exact names, ordered name rules; characters by their own rules) and a room's own "materials" / "shine" --
# set on each texture (Raster.Tex.Material, Shine, Gloss, Metal, ShineVary) for the graphics card's highlights. Textures are
# shared between rooms, so every room entry sets all of its own. The file is read again when it changes.
$script:matTable = $null; $script:matStamp = $null
function Get-MaterialTable {
    $p = Join-Path $RoomsDir '_materials.json'
    if (-not (Test-Path $p)) { return $null }
    $st = (Get-Item $p).LastWriteTimeUtc
    if ($script:matTable -and $script:matStamp -eq $st) { return $script:matTable }
    try {
        $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json
        $mats = @{}; foreach ($pp in $j.materials.PSObject.Properties) { $mats[$pp.Name] = $pp.Value }
        $names = @{}; if ($j.names) { foreach ($pp in $j.names.PSObject.Properties) { $names[$pp.Name.ToLowerInvariant()] = [string]$pp.Value } }
        $rules = New-Object System.Collections.Generic.List[object]; $crules = New-Object System.Collections.Generic.List[object]
        foreach ($set in @(@($j.rules, $rules), @($j.characterRules, $crules))) {
            foreach ($rr in @($set[0])) { if ($rr -and @($rr).Count -ge 2) { $set[1].Add([pscustomobject]@{ Rx = [regex]::new([string]$rr[0], [Text.RegularExpressions.RegexOptions]::IgnoreCase); Mat = [string]$rr[1] }) } }
        }
        # (parallax by hand: "parallax": { "on": [names], "off": [names] } -- a texture's name or file name)
        $pOn = @{}; $pOff = @{}; if ($j.parallax) { foreach ($x in @($j.parallax.on)) { if ($x) { $pOn[([string]$x).ToLowerInvariant()] = 1 } }; foreach ($x in @($j.parallax.off)) { if ($x) { $pOff[([string]$x).ToLowerInvariant()] = 1 } } }
        $script:matTable = [pscustomobject]@{ Mats = $mats; Names = $names; Rules = $rules; CharRules = $crules; ParallaxOn = $pOn; ParallaxOff = $pOff }
        $script:matStamp = $st
    } catch { Say ("materials file problem: {0}" -f $_.Exception.Message) Yellow; $script:matTable = $null }
    return $script:matTable
}
# One texture's material, and why: the room's own word (by file name, then name), the table's names, the rules (characters
# by theirs), else stone (characters: skin). $roomMats: the room's "materials", keys in lower case.
function Resolve-TexMaterial($tbl, $tx, $roomMats) {
    $leaf = [string]$tx.Leaf; $name = ($leaf -replace '^\d+-', '').ToLowerInvariant()
    $mat = $null; $over = $null; $how = ''
    if ($roomMats -and $leaf) {
        foreach ($k in @($leaf.ToLowerInvariant(), $name)) {
            if ($roomMats.ContainsKey($k)) { $v = $roomMats[$k]; if ($v -is [string]) { $mat = $v } else { $over = $v; if ($v.material) { $mat = [string]$v.material } }; $how = 'room'; break }
        }
    }
    if (-not $mat -and $name -and $tbl.Names.ContainsKey($name)) { $mat = $tbl.Names[$name]; $how = 'name' }
    if (-not $mat -and $name) { foreach ($rl in $(if ($tx.Moves) { $tbl.CharRules } else { $tbl.Rules })) { if ($rl.Rx.IsMatch($name)) { $mat = $rl.Mat; $how = 'rule /' + $rl.Rx.ToString() + '/'; break } } }
    if (-not $mat) { $mat = $(if (-not $leaf) { 'matte' } elseif ($tx.Moves) { 'skin' } else { 'stone' }); $how = 'default' }
    return [pscustomobject]@{ Leaf = $leaf; Name = $name; Material = $mat; How = $how; Over = $over }
}
function Set-RoomMaterials($gq, $atm, $roomObj) {
    if (-not $roomObj -or -not $roomObj.Texes) { return }
    $tbl = Get-MaterialTable
    $rm = @{}; if ($atm -and $atm.Materials) { foreach ($pp in $atm.Materials.PSObject.Properties) { $rm[$pp.Name.ToLowerInvariant()] = $pp.Value } }
    $gain = [double]$(if ($atm -and $null -ne $atm.Shine) { $atm.Shine } else { 1.0 })
    $count = @{}; $unknown = @{}
    foreach ($tx in $roomObj.Texes) {
        if (-not $tx) { continue }
        $tx.Material = $null; $tx.Shine = 0; $tx.Gloss = 16; $tx.Metal = 0; $tx.ShineVary = 0; $tx.Wet = 0; $tx.Relief = 1; $tx.Parallax = 0; $tx.ParallaxSet = $false
        if (-not $tbl) { continue }
        $r = Resolve-TexMaterial $tbl $tx $rm
        $m = $tbl.Mats[$r.Material]; if (-not $m) { $unknown[$r.Material] = 1 }
        $get = { param($key, $def) if ($r.Over -and $null -ne $r.Over.$key) { [double]$r.Over.$key } elseif ($m -and $null -ne $m.$key) { [double]$m.$key } else { [double]$def } }
        $tx.Material = $r.Material
        $tx.Shine = [single]((& $get 'shine' 0) * $gain); $tx.Gloss = [single](& $get 'gloss' 16); $tx.Metal = [single](& $get 'metal' 0); $tx.ShineVary = [single](& $get 'vary' 1)
        $tx.Wet = [single](& $get 'wet' 0); $tx.Relief = [single](& $get 'relief' 1)      # (Josh, 2026-10-12: no relief on shiny surfaces)
        # parallax depth: the material's share (stone, floor, rock walls and floors), or set by hand (the table's lists, a room's
        # "materials" { "13-spadoor": { "parallax": 1 } })
        $tx.Parallax = [single](& $get 'parallax' 0)
        $lk = ([string]$tx.Leaf).ToLowerInvariant()
        if ($r.Over -and $null -ne $r.Over.parallax) { $tx.ParallaxSet = $true }
        elseif ($tbl.ParallaxOn -and ($tbl.ParallaxOn.ContainsKey($lk) -or $tbl.ParallaxOn.ContainsKey($r.Name))) { $tx.Parallax = 1; $tx.ParallaxSet = $true }
        elseif ($tbl.ParallaxOff -and ($tbl.ParallaxOff.ContainsKey($lk) -or $tbl.ParallaxOff.ContainsKey($r.Name))) { $tx.Parallax = 0; $tx.ParallaxSet = $true }
        $count[$r.Material] = 1 + [int]$count[$r.Material]
    }
    if ($tbl) {
        Say ("  materials: {0}{1}{2}" -f (($count.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { '{0} {1}' -f $_.Value, $_.Key }) -join ', '), $(if ($gain -ne 1) { " (shine x$gain)" } else { '' }), $(if ($unknown.Count) { '; NOT IN THE TABLE (matte): ' + (@($unknown.Keys) -join ', ') } else { '' })) DarkCyan
    }
}
# WET SURFACES (Josh, 2026-10-12, phase 2: "in the rooms with dripping like damp caves, and of course the spa room and similar
# rooms ... the lower walls and floors get a darker wet look with a glossy sheen ... a slow drip-streak animation runs down the
# walls, and puddles reflect your lamp"): a room's "wet" block -- _defaults.json's classes "cave" and "spa", a room file's own,
# or "wet": null for none. Keys (GpuRaster.Wet*): strength 0..1, height (how far up the walls the damp reaches above the floor
# beneath, units), dark (the colour's level at full wet), floor (floors' dampness 0..1; a cave's 0: only puddles), shine and
# gloss (the water film's highlight), puddles (share of the LEVEL floor 0..1) and puddleSize (units), walls (their share 0..1;
# a cave's half), ceiling (0..1), cell (the floor-height grid, units). (Trickles down the walls were taken out, 2026-10-12.) Each texture's share: its material's
# "wet" (rooms\_materials.json). The room's floor heights are worked out here, once per room entry.
function Set-GpuWet($gq, $atm, $roomObj) {
    $gq.ClearGround()
    $w = $atm.Wet
    if (-not $w -or $NoWet -or -not $roomObj) { return }
    $d = { param($x, $def) if ($null -ne $x) { [single]$x } else { [single]$def } }
    $gq.WetStrength = & $d $w.strength 1; $gq.WetHeight = & $d $w.height 45; $gq.WetDark = & $d $w.dark 0.62; $gq.WetFloor = & $d $w.floor 0.45
    $gq.WetShine = & $d $w.shine 0.16; $gq.WetGloss = & $d $w.gloss 40; $gq.WetPuddles = & $d $w.puddles 0.3; $gq.WetPuddleSize = & $d $w.puddleSize 70
    $gq.WetWalls = & $d $w.walls 1; $gq.WetCeiling = & $d $w.ceiling 0.15
    # (Josh, 2026-10-12, CORICORI: the wet fades out into the art's own darkness) "darkFrom" / "darkTo": the art's brightness
    # (0..255, blurred) where the wet starts and where it is full
    $gq.WetDarkFrom = & $d $w.darkFrom 10; $gq.WetDarkTo = & $d $w.darkTo 45
    $ok = $gq.SetGround($roomObj.V, $roomObj.T, $roomObj.TexIdx, $roomObj.Texes, (& $d $w.cell 8))
    if (-not $gq.WetUnitOk) { Say '  wet surfaces: this card has no 18th texture unit -- left out' Yellow; return }
    Say ("  wet surfaces: {0:P0}, walls {1:P0} damp {2:N0} units up, floors {3:P0} damp with {4:P0} puddles (level floor only){5}; floor heights {6}" -f $gq.WetStrength, $gq.WetWalls, $gq.WetHeight, $gq.WetFloor, $gq.WetPuddles, $(if ($gq.WetOn) { '' } else { ' (switched off: F5)' }), $(if ($ok) { $gq.GroundNote } else { 'NOT MADE (' + $gq.GroundNote + ')' })) Cyan
}
# TEXTURE REPAIR (Josh, 2026-10-12, phase 3: "Fix badly stretched textures automatically ... give those faces the texture laid
# evenly from the world instead" and "Hide the repeats ... get it mixed ... across the surface"): GpuRaster.SetRelay, worked
# out per room entry (and again when the characters change the triangle list). A room's "repair" block: "skip" [texture
# names left as they are], "mix" (false: no mixing), "stretch" (how uneven before a face counts as stretched, default 4),
# "flat" (how even the art under a face must be to count as one flat colour and be left, default 6); "repair": null = none.
function Set-GpuRepair($gq, $atm, $roomObj) {
    $gq.ClearRelay()
    $rp = $atm.Repair
    if ($NoRepair -or $null -eq $rp -or -not $roomObj) { return }
    $skip = @(); $gq.MixOn = $true; $gq.RelayStretch = [single]4; $gq.RelayFlatStd = [single]6
    if ($rp -isnot [string]) {
        $skip = @($rp.skip | Where-Object { $_ } | ForEach-Object { [string]$_ })
        if ($null -ne $rp.mix) { $gq.MixOn = [bool]$rp.mix }
        if ($rp.stretch) { $gq.RelayStretch = [single]$rp.stretch }; if ($null -ne $rp.flat) { $gq.RelayFlatStd = [single]$rp.flat }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $note = $gq.SetRelay($roomObj.V, $roomObj.UV, $roomObj.T, $roomObj.TexIdx, $roomObj.Texes, $pal, (-not $NoFlipV), [string[]]$skip)
    Say ("  texture repair: {0} ({1:N0} ms){2}{3}" -f $note, $sw.Elapsed.TotalMilliseconds, $(if ($skip.Count) { '; skipped: ' + ($skip -join ', ') } else { '' }), $(if ($gq.RelayOn) { '' } else { ' (switched off: F11)' })) Cyan
}
function Set-GpuAtmosphere($gq, $atm, $roomObj) {
    Set-RoomTextureRules $gq $atm $roomObj
    Set-RoomMaterials $gq $atm $roomObj
    Set-GpuWet $gq $atm $roomObj
    Set-GpuRepair $gq $atm $roomObj
    # the parallax depth's room share ("parallax": a number x -ParallaxDepth, null = none)
    # ("parallax": a number = x the depth; {"depth": x, "shade": 0..1} = that, with the art's broad shading in its height --
    # bright bulges, dark sinks -- for rocks; null = none)
    $pr = $atm.Parallax; $prK = 1.0; $prShade = 0.0
    if ($null -ne $pr) { if ($pr -is [ValueType]) { $prK = [double]$pr } else { if ($null -ne $pr.depth) { $prK = [double]$pr.depth }; if ($null -ne $pr.shade) { $prShade = [double]$pr.shade } } }
    $gq.ParallaxDepth = [single]$(if ($NoParallax -or $null -eq $pr) { 0 } else { $ParallaxDepth * $prK })
    if ($roomObj) { foreach ($tx in $roomObj.Texes) { if ($tx) { $tx.ParallaxShade = [single]$prShade } } }

    if ($roomObj) { [void]$gq.SetParallaxShell($roomObj.V, $roomObj.T, $roomObj.TexIdx, $roomObj.Texes) }      # (its walls and floors: only they take it)
    Set-GpuGhost $gq $(if ($NoGhost) { $null } else { $atm.Ghost })
    Set-RoomGhosts $gq $roomObj
    # LIGHT FROM THE ARTWORK (Josh, 2026-10-09, Room Review MINEHEAD/2-4): "artLight": {floor, gamma, open, close, blur,
    # percentile, exclude: [texture names], tint: "#RRGGBB" | "art"} -- the room's level and the bounce shaded per texel by
    # the light and shade the ORIGINAL art paints (GpuRaster.BuildArtLight); tint = the room's level in that colour
    # ("art": the art's own well-lit colour). Textures are shared between rooms, so a room without it takes it off.
    $gq.ClearArtLight($(if ($roomObj) { $roomObj.Texes } else { $null })); $gq.RoomTint = 0xFFFFFF
    if ($atm.ArtLight -and $roomObj -and -not $NoArtLight) {
        $al = $atm.ArtLight
        $n = $gq.BuildArtLight($roomObj.Texes, $pal, [single]$(if ($null -ne $al.floor) { $al.floor } else { 0.15 }), [single]$(if ($null -ne $al.gamma) { $al.gamma } else { 0.7 }), [int]$(if ($null -ne $al.open) { $al.open } else { 4 }), [int]$(if ($null -ne $al.close) { $al.close } else { 2 }), [int]$(if ($null -ne $al.blur) { $al.blur } else { 1 }), [single]$(if ($al.percentile) { $al.percentile } else { 0.85 }), [string[]]@($al.exclude | Where-Object { $_ }))
        if ($al.tint) { $gq.RoomTint = $(if ([string]$al.tint -eq 'art') { $gq.ArtTint } else { ConvertTo-Rgb24 ([string]$al.tint) 0xFFFFFF }) }
        Say ("  light from the artwork: {0}; room tint #{1:X6}" -f $gq.ArtNote, $gq.RoomTint) Cyan
    }
    $gq.MistOn = $false
    $gq.ClearScorches()      # (a new room: the last one's scorch marks are not here)
    # EYE SHINE (Josh, 2026-10-14): creatures' eyes glint in the helmet lamp (Particles.cs EyeShine) -- a part holding both
    # eyes per rig, and its head (which way it faces). Built in: CORICORI's creatures (EUGBLD: EUEYE, EUHEAD). A room's
    # "eyeShine": false = none; { "strength", "size", "halo", "parts": { "<EYE PART>": { "head": "<HEAD PART>", "neck": "<NECK PART>", "color": "#RRGGBB" } } }
    # (the eye part may be missing or misplaced -- CORICORI's EUEYE carries a stale transform in the engine: then the eyes go on
    # the head, forward of its middle away from the neck; a rig with no eye part can name its head as the "eye part")
    $script:eyeShine = $null
    $es = $atm.EyeShine
    if (-not ($es -is [bool] -and -not $es) -and -not $NoEyeShine -and $roomObj -and $roomObj.Parts) {
        $eyeParts = @{ 'EUEYE' = @('EUHEAD', 0xB8F07A, 'EUNECK01') }
        if ($es -and $es.parts) { foreach ($pp in $es.parts.PSObject.Properties) { $eyeParts[$pp.Name.ToUpperInvariant()] = @([string]$pp.Value.head, (ConvertTo-Rgb24 ([string]$pp.Value.color) 0xB8F07A), [string]$pp.Value.neck) } }
        $byName = @{}; for ($i = 0; $i -lt $roomObj.Parts.Count; $i++) { $byName[([string]$roomObj.Parts[$i].Name).ToUpperInvariant()] = $roomObj.Parts[$i] }
        $eye = New-Object AztTool.EyeShine
        if ($es -and $null -ne $es.strength) { $eye.Strength = [single]$es.strength }; if ($es -and $es.size) { $eye.Size = [single]$es.size }; if ($es -and $es.halo) { $eye.Halo = [single]$es.halo }
        foreach ($pt in $roomObj.Parts) {
            if (-not $pt.IsCharacter) { continue }
            $nm = ([string]$pt.Name).ToUpperInvariant(); $pre = $(if ($nm -match '^ZZ\d{4}') { $nm.Substring(0, 6) } else { '' }); $bare = $nm.Substring($pre.Length)
            if (-not $eyeParts.ContainsKey($bare)) { continue }
            $hd = $byName[$pre + ([string]$eyeParts[$bare][0]).ToUpperInvariant()]
            $nk = $(if ($eyeParts[$bare][2]) { $byName[$pre + ([string]$eyeParts[$bare][2]).ToUpperInvariant()] } else { $null })
            $eye.Add([int]$pt.VFirst, [int]$pt.VCount, $(if ($hd) { [int]$hd.VFirst } else { 0 }), $(if ($hd) { [int]$hd.VCount } else { 0 }), $(if ($nk) { [int]$nk.VFirst } else { 0 }), $(if ($nk) { [int]$nk.VCount } else { 0 }), [int]$eyeParts[$bare][1])
        }
        if ($eye.Count) { $script:eyeShine = $eye; Say ("  eye shine: {0} creature(s)" -f $eye.Count) Cyan }
    }
    # the wall washes (Set-RoomAtmosphere: lights with "wash": true)
    $wn = $(if ($script:roomWashes) { @($script:roomWashes).Count } else { 0 }); $wa = New-Object 'single[]' ([Math]::Max(1, $wn) * 12)
    for ($i = 0; $i -lt $wn; $i++) {
        $l = $script:roomWashes[$i]; $o = $i * 12
        $wa[$o] = $l.X; $wa[$o + 1] = $l.Y; $wa[$o + 2] = $l.Z; $wa[$o + 3] = $l.Range
        $wa[$o + 4] = [single]($l.R * $l.Power); $wa[$o + 5] = [single]($l.G * $l.Power); $wa[$o + 6] = [single]($l.B * $l.Power)
        $wa[$o + 7] = [single]$l.Dir[0]; $wa[$o + 8] = [single]$l.Dir[1]; $wa[$o + 9] = [single]$l.Dir[2]; $wa[$o + 10] = [single]$l.Cone[0]; $wa[$o + 11] = [single]$l.Cone[1]
    }
    $gq.SetWashes($wa, $wn)
    # each placed light's cone and its part in the air (spotlights, shafts with rays)
    $gq.ClearLightSpots()
    for ($li = 0; $li -lt @($script:roomLights).Count; $li++) {
        $l = $script:roomLights[$li]; $d = $(if ($l.Dir) { $l.Dir } else { @(0, -1, 0) })
        $gq.SetLightSpot($li, [single]$d[0], [single]$d[1], [single]$d[2], [single]$(if ($l.Cone) { $l.Cone[0] } else { 0 }), [single]$(if ($l.Cone) { $l.Cone[1] } else { 0 }), [single]$l.Air, [single]$l.AirReach, [single]$l.Rays); $gq.SetAirFirst($li, [bool]$l.AirFirst); $gq.SetLightOneSided($li, [bool]$l.OneSided)
        if ($l.Gate) { $g = $l.Gate; $gq.SetLightGate($li, $true, $g[0], $g[1], $g[2], $g[3], $g[4], $g[5]) }
        if ($null -ne $l.ColorFar) {
            # as a multiplier on its colour, channel by channel (so its strength and flicker carry over)
            $nc = $l.ColorRgb; $fc = $l.ColorFar
            $m = @(0, 1, 2 | ForEach-Object { $sh = 16 - 8 * $_; ((($fc -shr $sh) -band 255) / 255.0) / [Math]::Max(0.05, ((($nc -shr $sh) -band 255) / 255.0)) })
            $gq.SetLightTint($li, [single]$m[0], [single]$m[1], [single]$m[2], [single]$l.TintFrom, [single]$l.TintTo)
        }
    }
    # VOLUMETRIC FOG (2026-10-08, the first room first): black air that absorbs with distance and that the lights and the
    # flashlight light up as they pass through it (shafts by the lights' all-round shadow maps). While it is on, the room's
    # level is HELD (volume.level, default the flashlight-off level): no darkening with the flashlight -- the fog alone
    # makes the gloom (Josh: 'pure for now so I can analyze').
    $gq.VolOn = $false; $script:volLevel = $null
    if ($atm.Volume -and -not $NoVolume) {
        $vo = $atm.Volume; $gq.VolOn = $true
        if ($null -ne $vo.density) { $gq.VolDensity = [single]$vo.density }; if ($null -ne $vo.max) { $gq.VolMax = [single]$vo.max }
        if ($null -ne $vo.scatter) { $gq.VolScatter = [single]$vo.scatter }; if ($null -ne $vo.lamp) { $gq.VolLamp = [single]$vo.lamp }
        if ($null -ne $vo.anisotropy) { $gq.VolAniso = [single]$vo.anisotropy }; if ($vo.reach) { $gq.VolReach = [single]$vo.reach }
        if ($vo.far) { $gq.VolFar = [single]$vo.far }; if ($vo.steps) { $gq.VolSteps = [int]$vo.steps }; if ($null -ne $vo.cut) { $gq.VolCut = [single]$vo.cut }; $gq.VolLit = [single]$(if ($null -ne $vo.lightThrough) { $vo.lightThrough } else { 0.85 }); $gq.VolLitAir = [single]$(if ($null -ne $vo.lightThroughAir) { $vo.lightThroughAir } else { 0.7 }); $gq.LitReach = [single]$(if ($vo.lightReach) { $vo.lightReach } else { 110 })      # (2026-10-09: the placed lights cut through it as the flashlight does)
        $gq.VolColor = ConvertTo-Rgb24 ([string]$vo.color) 0x000000
        # ("airInRoom": true = the lights light the air only inside the room's own bounds (its geometry's box) -- BAPTIST's sun outside its windows,
        # 2026-10-14, lit the open sky above the walls)
        $gq.AirBoxOn = $false
        if ($vo.airInRoom -and @($vo.airInRoom).Count -eq 6) {      # (or the box itself: [x0, y0, z0, x1, y1, z1])
            $ab = @($vo.airInRoom); for ($k = 0; $k -lt 3; $k++) { $gq.AirLo[$k] = [single]$ab[$k]; $gq.AirHi[$k] = [single]$ab[$k + 3] }; $gq.AirBoxOn = $true
        } elseif ($vo.airInRoom -and $roomObj -and $roomObj.V) {
            $v = $roomObj.V; $lo = @([single]::MaxValue) * 3; $hi = @([single]::MinValue) * 3
            for ($i = 0; $i -lt $v.Length; $i += 3) { for ($k = 0; $k -lt 3; $k++) { $c = $v[$i + $k]; if ($c -lt $lo[$k]) { $lo[$k] = $c }; if ($c -gt $hi[$k]) { $hi[$k] = $c } } }
            for ($k = 0; $k -lt 3; $k++) { $gq.AirLo[$k] = [single]$lo[$k]; $gq.AirHi[$k] = [single]$hi[$k] }
            $gq.AirBoxOn = $true
        }
        $script:volLevel = [double]$(if ($null -ne $vo.level) { $vo.level } else { $LampRoomOff })
        # THE PAINTED DARKNESS (Josh, 2026-10-08, CORICORI/5-6): "paint": {density, max, cell, smooth, gamma} -- the fog thicker
        # black where the room's texture art is painted dark (GpuRaster.BuildPaintField samples the room's own surfaces)
        $gq.PaintOn = $false; $gq.PaintColor = 0
        if ($vo.paint -and $roomObj) {
            $pa = $vo.paint; $gq.PaintColor = ConvertTo-Rgb24 ([string]$pa.color) 0x000000      # (its own colour: black, whatever the fog's)
            if ($null -ne $pa.density) { $gq.PaintDensity = [single]$pa.density }; if ($null -ne $pa.max) { $gq.PaintMax = [single]$pa.max }
            $gq.BuildPaintField($roomObj.V, $roomObj.UV, $roomObj.T, $roomObj.TexIdx, $roomObj.Texes, $true, [single]$(if ($pa.cell) { $pa.cell } else { 8 }), [single]$(if ($pa.smooth) { $pa.smooth } else { 30 }), [single]$(if ($pa.gamma) { $pa.gamma } else { 1.5 }), $(if ($pa.fromLoaded) { $null } else { $pal }))      # (the ORIGINAL art's pixels unless "fromLoaded": true)
            Say ("  painted darkness: {0}; up to {1}/unit, {2:P0} opaque at most" -f $gq.PaintNote, $gq.PaintDensity, $gq.PaintMax) Cyan
        }
        Say ("  volumetric fog: density {0}/unit up to {1:P0} opaque, #{2:X6}; lights scatter {3} (reach {4:N0}, forward {5}), flashlight {6}, cuts {10:P0}; {7} steps over {8:N0} units; room level held at {9:N2}" -f $gq.VolDensity, $gq.VolMax, $gq.VolColor, $gq.VolScatter, $gq.VolReach, $gq.VolAniso, $gq.VolLamp, $gq.VolSteps, $gq.VolFar, $script:volLevel, $gq.VolCut) Cyan
    }
    # MODERN WATER (Josh, 2026-10-08, SPAROOM): a "water" block makes the room's reflective water rippled, shiny (Fresnel)
    # and lit from below -- an even glow plus "lights" [{x, z, radius, power}] under it -- with caustics thrown on the walls
    # above. Keys: glow (colour), glowPower, glowBase, dots, shine, f0, spec, distort, ripple {slope, size, speed},
    # caustics {strength, size, speed, height, fill}. -NoWaterFx: the old flat mirror.
    # HOLOGRAMS (Josh, 2026-10-08, Room Review CORICORI/4): "holograms": [{ "shape": "chalice", "x", "y" (the floor), "z",
    # "height", "spin" (radians a second), "color", "flare", "glow", "hover", "bob", "scan" }] -- the intro's revolving
    # teal wireframe chalice standing in the room
    # PROPS (Josh, 2026-10-08, CORICORI/7): a light with "torch": { "scale", "wall" } gets a torch in a wall sconce built under
    # it -- solid geometry with the room's own lighting, shadows and fog (GpuRaster.AddTorch); "wall" = how far the light is
    # from the wall (default 30, the placed torches' rule), along its "dir"
    Set-GpuGi $gq $atm $roomObj
    $gq.ClearProps()
    foreach ($tl in @($atm.Lights)) {
        if ($null -eq $tl -or $null -eq $tl.x -or -not $tl.torch -or -not $tl.dir) { continue }
        $tc = $tl.torch
        $sc = [single]$(if ($tc -is [bool]) { 1 } elseif ($tc.scale) { $tc.scale } else { 1 }); $wd = [single]$(if ($tc -isnot [bool] -and $tc.wall) { $tc.wall } else { 30 })
        $gq.AddTorch([single]$tl.x, [single]$tl.y, [single]$tl.z, [single]$tl.dir[0], [single]$tl.dir[2], $sc, $wd)
        Say ("  prop: a torch in a sconce under '{0}' ({1} triangles so far)" -f $tl.name, $gq.PropTris) Cyan
    }
    $gq.ClearHolos()
    foreach ($ho in @($atm.Holograms)) {
        if ($null -eq $ho -or $null -eq $ho.x) { continue }
        $gq.AddHoloChalice([single]$ho.x, [single]$ho.y, [single]$ho.z, [single]$(if ($ho.height) { $ho.height } else { 26 }), [single]$(if ($null -ne $ho.spin) { $ho.spin } else { 0.75 }),
            (ConvertTo-Rgb24 ([string]$ho.color) 0x71DFD7), (ConvertTo-Rgb24 ([string]$ho.flare) 0xBEFBFF), [single]$(if ($null -ne $ho.glow) { $ho.glow } else { 1 }),
            [single]$(if ($null -ne $ho.hover) { $ho.hover } else { 6 }), [single]$(if ($null -ne $ho.bob) { $ho.bob } else { 1.5 }), [bool]$(if ($null -ne $ho.scan) { $ho.scan } else { $true }))
        Say ("  hologram: chalice at {0:N0} {1:N0} {2:N0}, {3:N0} units tall" -f $ho.x, $ho.y, $ho.z, $(if ($ho.height) { $ho.height } else { 26 })) Cyan
    }
    $gq.WaterFx = $false; $gq.ClearWaterLights()
    if ($atm.Water -and -not $NoWaterFx) {
        $wa = $atm.Water; $gq.WaterFx = $true
        $gq.WaterGlowColor = ConvertTo-Rgb24 ([string]$wa.glow) 0x30D8C8
        if ($null -ne $wa.glowPower) { $gq.WaterGlow = [single]$wa.glowPower }; if ($null -ne $wa.glowBase) { $gq.WaterGlowBase = [single]$wa.glowBase }
        if ($null -ne $wa.dots) { $gq.WaterDots = [single]$wa.dots }; if ($null -ne $wa.shine) { $gq.WaterShine = [single]$wa.shine }
        if ($null -ne $wa.f0) { $gq.WaterF0 = [single]$wa.f0 }; if ($null -ne $wa.spec) { $gq.WaterSpec = [single]$wa.spec }; if ($null -ne $wa.distort) { $gq.WaterDistort = [single]$wa.distort }; $gq.WaterLightSpec = [single]$(if ($null -ne $wa.lightSpec) { $wa.lightSpec } else { 1.0 })
        # (2026-10-12, Josh: "a glossy sheen ... applied to water surfaces to reflect the lights") "sheen", "sheenGloss": its broad soft highlight
        $gq.WaterSheen = [single]$(if ($null -ne $wa.sheen) { $wa.sheen } else { 0.35 }); $gq.WaterSheenGloss = [single]$(if ($null -ne $wa.sheenGloss) { $wa.sheenGloss } else { 30 })
        if ($wa.ripple) { $rp = $wa.ripple; if ($null -ne $rp.slope) { $gq.RippleSlope = [single]$rp.slope }; if ($rp.size) { $gq.RippleSize = [single]$rp.size }; if ($null -ne $rp.speed) { $gq.RippleSpeed = [single]$rp.speed } }
        if ($wa.caustics) {
            $ca = $wa.caustics
            if ($null -ne $ca.strength) { $gq.CausStrength = [single]$ca.strength }; if ($ca.size) { $gq.CausSize = [single]$ca.size }; if ($null -ne $ca.speed) { $gq.CausSpeed = [single]$ca.speed }
            if ($ca.height) { $gq.CausHeight = [single]$ca.height }; if ($null -ne $ca.fill) { $gq.CausFill = [single]$ca.fill }
        }
        # "noLight": [[x0, z0, x1, z1], ...] floor-plan boxes the light off the water must not reach (hallways off the room)
        foreach ($nb in @($wa.noLight)) { if ($null -ne $nb -and @($nb).Count -eq 4) { $gq.AddWaterCut([single]$nb[0], [single]$nb[1], [single]$nb[2], [single]$nb[3]) } }
        foreach ($wl in @($wa.lights)) { if ($null -ne $wl -and $null -ne $wl.x) { $gq.AddWaterLight([single]$wl.x, [single]$wl.z, [single]$(if ($wl.radius) { $wl.radius } else { 120 }), [single]$(if ($null -ne $wl.power) { $wl.power } else { 1.5 })) } }
        Say ("  modern water: glow #{0:X6} x{1} (+{2} lamps under it), shine {3}, ripples {4}/{5:N0}u, caustics {6} over {7:N0}u" -f $gq.WaterGlowColor, $gq.WaterGlow, $(if ($wa.lights) { @($wa.lights).Count } else { 0 }), $gq.WaterShine, $gq.RippleSlope, $gq.RippleSize, $gq.CausStrength, $gq.CausHeight) Cyan
    }
    if ($atm.Mist -and -not $NoMist) {
        $mi = $atm.Mist; $gq.MistOn = $true
        if ($null -ne $mi.density) { $gq.MistDensity = [single]$mi.density }; if ($mi.height) { $gq.MistHeight = [single]$mi.height }
        if ($null -ne $mi.max) { $gq.MistMax = [single]$mi.max }; $gq.MistColor = ConvertTo-Rgb24 ([string]$mi.color) 0x6A6258
        if ($null -ne $mi.wisps) { $gq.MistNoiseAmount = [single]$mi.wisps }; if ($mi.wispSize) { $gq.MistNoiseScale = [single](1.0 / [double]$mi.wispSize) }
        if ($null -ne $mi.drift) { $gq.MistNoiseSpeed = [single]$mi.drift }
    }
    Set-RoomFootsteps $atm
    $script:fx = $null
    if ($NoParticles) { return }
    $fx = New-Object AztTool.Particles
    # embers from every light that flickers (a torch), unless the room says otherwise
    $em = $atm.Embers; $emOn = (-not $em) -or ($null -eq $em.rate) -or ([double]$em.rate -gt 0)
    if ($em) { if ($null -ne $em.rate) { $fx.EmberRate = [single]$em.rate }; if ($em.rise) { $fx.EmberRise = [single]$em.rise }; if ($em.life) { $fx.EmberLife = [single]$em.life }; if ($em.size) { $fx.EmberSize = [single]$em.size }; $fx.EmberColor = ConvertTo-Rgb24 ([string]$em.color) 0xFF8A2A }
    $exyz = New-Object System.Collections.Generic.List[single]
    if ($emOn) { foreach ($l in $script:roomLights) { if ($l.Flicker -gt 0) { $exyz.Add($l.X); $exyz.Add($l.Y); $exyz.Add($l.Z) } } }
    $fx.SetEmitters($exyz.ToArray())
    # dust floating in the shafts of spotlights that have "dust"
    $sh = New-Object System.Collections.Generic.List[single]
    foreach ($l in $script:roomLights) {
        if (-not $l.Dust -or -not $l.Cone -or -not $l.Dir) { continue }
        $nc = $l.ColorRgb; $fc = $(if ($null -ne $l.ColorFar) { $l.ColorFar } else { $nc })
        $vals = @($l.X, $l.Y, $l.Z, $l.Dir[0], $l.Dir[1], $l.Dir[2], [Math]::Tan([double]$l.Cone[1] * [Math]::PI / 180), [double]$(if ($l.Dust.count) { $l.Dust.count } else { 80 }), [double]$(if ($l.Dust.size) { $l.Dust.size } else { 0.8 }),
            (($nc -shr 16) -band 255), (($nc -shr 8) -band 255), ($nc -band 255), (($fc -shr 16) -band 255), (($fc -shr 8) -band 255), ($fc -band 255), [double]$(if ($l.Dust.vary) { $l.Dust.vary } else { 0 }), [double]$(if ($l.Dust.swirl) { $l.Dust.swirl } else { 0 }), [double]$(if ($l.Dust.fromLight) { 1 } else { 0 }))      # ("vary": the specks' size spread, 0 = as before)
        foreach ($v in $vals) { $sh.Add([single]$v) }
    }
    $fx.SetShafts($sh.ToArray())
    # DUST THAT REACTS (Josh, 2026-10-14): the shafts' specks and the room's motes pushed aside as the player walks through;
    # a room's "reactDust": a number = how strongly (1 = as made), false = not at all
    $rd = $atm.ReactDust; $rk = $(if ($rd -is [bool]) { [single]$(if ($rd) { 1 } else { 0 }) } elseif ($null -ne $rd) { [single]$rd } else { [single]1 })
    $fx.ReactStrength = $rk; if ($script:motes) { $script:motes.ReactStrength = $rk }
    if ($atm.Drips) { $dr = $atm.Drips; $fx.DripRate = [single]$(if ($null -ne $dr.rate) { $dr.rate } else { 2 }); if ($dr.radius) { $fx.DripRadius = [single]$dr.radius }; if ($dr.size) { $fx.DripSize = [single]$dr.size }; $fx.DripColor = ConvertTo-Rgb24 ([string]$dr.color) 0xA8B4B8; if ($null -ne $dr.fromDark) { $fx.DripFromDark = [single]$dr.fromDark } }
    # (2026-10-09, SPAROOM/2) drips that land on water ring it: "drips.ripples" = how strongly (0 = none); "drips.fromDark" = units above the eye a drip starts where there is no ceiling
    $gq.DropRipple = [single]$(if ($atm.Drips -and $null -ne $atm.Drips.ripples) { $atm.Drips.ripples } else { 1 })
    if ($atm.Steam) { $st = $atm.Steam; $fx.SteamRate = [single]$(if ($null -ne $st.rate) { $st.rate } else { 6 }); if ($st.radius) { $fx.SteamRadius = [single]$st.radius }; if ($st.rise) { $fx.SteamRise = [single]$st.rise }; if ($st.life) { $fx.SteamLife = [single]$st.life }; if ($st.size) { $fx.SteamSize = [single]$st.size }; if ($null -ne $st.alpha) { $fx.SteamAlpha = [single]$st.alpha }; $fx.SteamColor = ConvertTo-Rgb24 ([string]$st.color) 0xC4C2BA; $fx.SteamFine = [bool]$st.fine }
    if ($atm.Kickup) { $kk = $atm.Kickup; $fx.KickRate = [single]$(if ($null -ne $kk.puffs) { $kk.puffs } else { 3 }); if ($kk.step) { $fx.KickStep = [single]$kk.step }; if ($kk.size) { $fx.KickSize = [single]$kk.size }; if ($kk.life) { $fx.KickLife = [single]$kk.life }; if ($null -ne $kk.alpha) { $fx.KickAlpha = [single]$kk.alpha }; if ($kk.ahead) { $fx.KickAhead = [single]$kk.ahead }; $fx.KickColor = ConvertTo-Rgb24 ([string]$kk.color) 0x8A7A64 }
    # WATER-EDGE MIST (Josh, 2026-10-09, SPAROOM/8): "waterMist": { rate (puffs/s), size, life, rise, alpha, color, inset (how far in
    # over the water), drift } -- soft puffs along the outline of the room's water surface, a lighter shade of its teal
    if ($atm.WaterMist -and $roomObj -and @($roomObj.WaterGroups).Count) {
        $wm = $atm.WaterMist; $wtl = New-Object 'System.Collections.Generic.List[int]'
        foreach ($grp in @($roomObj.WaterGroups)) { if ($grp) { foreach ($wt in $grp.Parts) { $wtl.AddRange([int[]]$wt.TriVerts) } } }
        if ($null -ne $wm.band) { $fx.WaterMistBand = [single]$wm.band }
        $nEdge = $fx.SetWaterEdges($roomObj.V, $wtl.ToArray(), $roomObj.T, $roomObj.TexIdx, $fx.WaterMistBand)      # (band: how near a wall, pillar or step)
        $fx.WaterMistRate = [single]$(if ($null -ne $wm.rate) { $wm.rate } else { 6 }); if ($wm.size) { $fx.WaterMistSize = [single]$wm.size }; if ($wm.life) { $fx.WaterMistLife = [single]$wm.life }
        if ($null -ne $wm.rise) { $fx.WaterMistRise = [single]$wm.rise }; if ($null -ne $wm.alpha) { $fx.WaterMistAlpha = [single]$wm.alpha }; if ($null -ne $wm.inset) { $fx.WaterMistInset = [single]$wm.inset }; if ($null -ne $wm.drift) { $fx.WaterMistDrift = [single]$wm.drift }
        $fx.WaterMistColor = ConvertTo-Rgb24 ([string]$wm.color) 0x7FE6DA
        Say ("  water-edge mist: {0} places where the water meets the room, {1}/s, #{2:X6}, alpha {3}" -f $nEdge, $fx.WaterMistRate, $fx.WaterMistColor, $fx.WaterMistAlpha) Cyan
    }
    # A GHOST'S WISPS (Set-GpuGhost): "wisps": { rate (a second), size, life (s), rise, spread (shares of the height her wisp
    # parts span), alpha, color } -- false = none
    $wi = $null; $wOn = $false
    if ($script:ghostAtm -and $gq.GhostOn) { $wi = $script:ghostAtm.wisps; $wOn = -not ($wi -is [bool] -and -not $wi) }      # (no "wisps" key: the defaults)
    if ($wOn) {
        $fx.GhostRate = [single]$(if ($null -ne $wi.rate) { $wi.rate } else { 14 }); if ($wi.size) { $fx.GhostSize = [single]$wi.size }; if ($wi.life) { $fx.GhostLife = [single]$wi.life }
        if ($null -ne $wi.rise) { $fx.GhostRise = [single]$wi.rise }; if ($null -ne $wi.spread) { $fx.GhostSpread = [single]$wi.spread }; if ($null -ne $wi.alpha) { $fx.GhostAlpha = [single]$wi.alpha }
        $fx.GhostColor = ConvertTo-Rgb24 ([string]$wi.color) 0x9FEDE4
        $fx.SetGhostSources($script:ghostWispVerts)
    }
    $script:fx = $fx
    Say ("  the card's atmosphere: mist {0}; embers from {1} light(s); drips {2}; steam {3}; footstep dust {4}" -f $(if ($gq.MistOn) { ('{0} near the floor, thinning over {1:N0} units' -f $gq.MistDensity, $gq.MistHeight) } else { 'none' }), `
        ($exyz.Count / 3), $(if ($fx.DripRate -gt 0) { '{0}/s' -f $fx.DripRate } else { 'none' }), $(if ($fx.SteamRate -gt 0) { '{0}/s' -f $fx.SteamRate } else { 'none' }), $(if ($fx.KickRate -gt 0) { 'on' } else { 'none' })) Cyan
}$script:motes = $null; $script:roomLights = @(); $script:atmClock = [Diagnostics.Stopwatch]::StartNew()
$script:lightSet = $null; $script:lightSetFor = $null; $script:lightsNoWriteBack = $true      # (the watcher's own loop reads the dance from the C# set)
function Update-RoomLights($ras) {
    $n = $script:roomLights.Count; $ras.LightCount = 0
    if (-not $n) { return }
    $t = $script:atmClock.Elapsed.TotalSeconds
    # IN C# (AztTool.RoomLightSet, GpuRaster.cs): the identical maths, every frame, from a copy of the room's lights made
    # when the room's list changes (2026-10-13 performance audit: 0.6-0.9 ms of script a frame). The script below stays as
    # the fallback for a build without the type. The watcher reads the dance from the set (Jitter*); the offline tools that
    # extract this function read $l.Jx, so it is copied back for them unless $script:lightsNoWriteBack.
    if ('AztTool.RoomLightSet' -as [type]) {
        if (-not $script:lightSet -or -not [object]::ReferenceEquals($script:lightSetFor, $script:roomLights)) {
            $ls = New-Object AztTool.RoomLightSet
            foreach ($l in $script:roomLights) {
                $ls.Add([single]$l.X, [single]$l.Y, [single]$l.Z, [double]$l.R, [double]$l.G, [double]$l.B, [double]$l.Power, [single]$l.Range, [double]$l.Flicker, [double]$l.Phase, [double]$l.Dance, $(if ($l.Cycle) { [int[]]$l.Cycle } else { $null }), [double]$l.CycleSec, [double]$l.CycleOff, $(if ($l.Dir) { [double[]]$l.Dir } else { $null }))
            }
            $ls.Views = [AztTool.Raster[]]@($(if ($script:lightRs) { $script:lightRs } else { @() }))
            $script:lightSet = $ls; $script:lightSetFor = $script:roomLights
        }
        $script:lightSet.Update($ras, $t, $script:gpu)
        if (-not $script:lightsNoWriteBack) { for ($i = 0; $i -lt $n; $i++) { $l = $script:roomLights[$i]; $l.Jx = $script:lightSet.JitterX($i); $l.Jy = $script:lightSet.JitterY($i); $l.Jz = $script:lightSet.JitterZ($i) } }
        return
    }
    for ($i = 0; $i -lt $n; $i++) {
        $l = $script:roomLights[$i]
        # a torch: two slow sways and a little jitter, never below about half strength
        if (-not $script:lightRnd) { $script:lightRnd = New-Object Random }
        $l.Noise = 0.7 * $l.Noise + 0.3 * ($script:lightRnd.NextDouble() - 0.5)          # (not Get-Random: a cmdlet per light per frame -- 2026-10-13 audit)
        $f = 1.0 + $l.Flicker * (0.55 * [Math]::Sin($t * 7.9 + $l.Phase) + 0.3 * [Math]::Sin($t * 19.3 + $l.Phase * 2.1) + 1.2 * $l.Noise)
        if ($f -lt 0.45) { $f = 0.45 }
        $p = $l.Power * $f; $b = $i * 8
        # DANCING SHADOWS (Josh, 2026-10-09): the light's point wanders round the flame -- two slow sways each way across,
        # a little of the flicker's own noise, and up when it flares -- and the shadow views follow it (see THE PLACED
        # LIGHTS' VIEWS), so shadow edges sway with the torch
        $amp = $(if ($l.Flicker -gt 0) { $l.Dance } else { 0 })
        if ($amp -gt 0) {
            $l.Jx = $amp * (0.5 * [Math]::Sin($t * 5.3 + $l.Phase) + 0.3 * [Math]::Sin($t * 12.7 + $l.Phase * 1.9) + 0.4 * $l.Noise)
            $l.Jz = $amp * (0.5 * [Math]::Sin($t * 4.6 + $l.Phase * 2.7) + 0.3 * [Math]::Sin($t * 11.3 + $l.Phase * 0.7) - 0.4 * $l.Noise)
            $l.Jy = $amp * 0.6 * [Math]::Max(-1.0, [Math]::Min(1.5, ($f - 1.0) / $l.Flicker))
        } else { $l.Jx = 0.0; $l.Jy = 0.0; $l.Jz = 0.0 }
        $ras.Lights[$b] = [single]($l.X + $l.Jx); $ras.Lights[$b + 1] = [single]($l.Y + $l.Jy); $ras.Lights[$b + 2] = [single]($l.Z + $l.Jz)
        $cr = $l.R; $cg = $l.G; $cb = $l.B
        if ($l.Cycle) {
            # its colour round the loop: which two colours it is between, eased (smoothstep) from one to the next
            $nc = $l.Cycle.Count; $u = (($t / [Math]::Max(1.0, $l.CycleSec) + $l.CycleOff) % 1.0) * $nc; $k0 = [int][Math]::Floor($u) % $nc; $k1 = ($k0 + 1) % $nc
            $mixK = $u - [Math]::Floor($u); $mixK = $mixK * $mixK * (3 - 2 * $mixK); $c0 = $l.Cycle[$k0]; $c1 = $l.Cycle[$k1]
            $cr = ((1 - $mixK) * (($c0 -shr 16) -band 255) + $mixK * (($c1 -shr 16) -band 255)) / 255.0
            $cg = ((1 - $mixK) * (($c0 -shr 8) -band 255) + $mixK * (($c1 -shr 8) -band 255)) / 255.0
            $cb = ((1 - $mixK) * ($c0 -band 255) + $mixK * ($c1 -band 255)) / 255.0
        }
        $ras.Lights[$b + 3] = [single]($cr * $p); $ras.Lights[$b + 4] = [single]($cg * $p); $ras.Lights[$b + 5] = [single]($cb * $p); $ras.Lights[$b + 6] = $l.Range
    }
    $ras.LightCount = $n
    if ($script:gpu -and $script:gpu.GiOn) { $sw = 0.0; $sf = 0.0; for ($i = 0; $i -lt $n; $i++) { $l = $script:roomLights[$i]; $pw = $l.Power * ($l.R + $l.G + $l.B); $sw += $pw; $sf += $pw * ($ras.Lights[$i * 8 + 3] + $ras.Lights[$i * 8 + 4] + $ras.Lights[$i * 8 + 5]) / [Math]::Max(1e-6, $l.Power * ($l.R + $l.G + $l.B)) }; $script:gpu.GiFlicker = [single]$(if ($sw -gt 0) { $sf / $sw } else { 1 }) }
}

# ---- the session ------------------------------------------------------------
# Returns when the game exits. Everything inside assumes $g and $hv are live.
function Invoke-Session {
    # In true colour the picture never goes through the game, so it need not be the game's size.
    $rw = $W; $rh = $H
    if ($script:tcOn -and -not $NoRgb -and $script:tcRW -gt 0) { $rw = $script:tcRW; $rh = $script:tcRH }
    $r = New-Object AztTool.Raster($rw, $rh)
    $r.NearZ = [single]0.5
    $r.SetVerticalFov($Fov)
    # the picture's rows below the view (the 3D under the widescreen panel): same projection, centred in the view
    if ($script:tcOn -and $script:ov -and $script:ov.ExtendRows -gt 0) {
        $r.ViewRows = $script:ov.ViewRowsOf($rh)
        Say ("3D under the panel: the picture is {0} rows, the view the top {1}; the other {2} carry on beneath the panel" -f $rh, $r.ViewRows, ($rh - $r.ViewRows)) Cyan
    }
    $rs = $null; $rs2 = $null      # the lamps' shadow-map rasters; null when shadows are off / one lamp
    if (-not $script:rgbLut) { $script:rgbLut = [AztTool.Raster]::BuildRgbLut($pal) }
    if ($TexScale -gt 1 -and -not $script:rgbLut6) { $script:rgbLut6 = [AztTool.Raster]::BuildRgbLut6($pal) }
    $hiTexOn = ($TexScale -gt 1); $hiKeyWas = $false
    if ($TexScale -gt 1) { Say ("textures enlarged x{0} on load (sharpen {1:N1})" -f $TexScale, $TexSharpen) Cyan }
    $r.MipBias = [single]$MipBias; $r.Filter = (-not $NoTexFilter); $filterKeyWas = $false
    $script:tcRaster = $r; $rgbKeyWas = $false; $postOn = $true; $postKeyWas = $false; $postMs = 0.0; $postN = 0
    $curChars = @(); $motesClock = [Diagnostics.Stopwatch]::StartNew()
    $script:motes = $null; $script:roomLights = @(); $r.LightCount = 0; $r.Fog32 = $false
    if ($script:tcOn -and -not $NoRgb) { $r.EnableRgb(); Say 'true colour picture ON (F8 switches to the 8-bit picture and back)' Cyan }
    # the graphics card: drawing from the first frame. Any failure here only
    # means the card is not offered: the session carries on on the processor.
    $script:gpu = $null; $script:gpuOn = $false; $gpuKeyWas = $false
    if ($script:tcOn -and -not $NoRgb -and -not $NoGpu) {
        try {
            $gErr = $null; $gq = [AztTool.GpuRaster]::Create($r.W, $r.H, [ref]$gErr)
            if ($gq) {
                $gq.NearZ = [single]0.5; $gq.SetVerticalFov($Fov); $gq.MipBias = [single]$MipBias; $gq.ViewRows = $r.ViewRows
                $gq.Relief = [single]$Relief; $gq.AO = [single]$AO; $gq.Beam = [single]$Beam
                if ($ReliefSharpK -ge 0) { $gq.ReliefSharpK = [single]$ReliefSharpK }
                $gq.ReliefTile = [single]$ReliefTile; $gq.ReliefMid = [single]$ReliefMid; $gq.ReliefGain = [single]$ReliefGain
                $gq.PixelMip = (-not $NoPixelMip); $gq.PixelMipBias = [single]$GpuMipBias; $gq.Anisotropy = [single]$Anisotropy
                $gq.DetailScale = [single]$DetailScale; $gq.DetailRough = [single]$DetailRough; $gq.DetailAO = [single]$DetailAO; $gq.Detail = 0     # (per room, at room load)
                $gq.VolHalf = (-not $VolFull); $gq.ReliefTint = [single]$ReliefTint; $gq.ReliefOpacity = [single]$ReliefOpacity; $gq.LightShadowDeep = [single]$LightShadowDeep; $gq.LightSoft = [single]$LightSoft; $gq.LampSoft = [single]$LampSoft
                Say ("mipmaps: {0}, anisotropic x{1:0}, bias {2:N2}; relief: sharp maps ({3}), micro relief {4:N2} at {5:N2} units, shadows tinted {6:N1}, {7:P0} opacity" -f $(if ($gq.PixelMip) { 'per pixel' } else { 'per triangle' }), $Anisotropy, $GpuMipBias, $(if ($ReliefSharpRooms -contains '*') { 'every room' } else { $ReliefSharpRooms -join ', ' }), $Detail, $DetailScale, $ReliefTint, $ReliefOpacity) Cyan
                $script:fxClock = [Diagnostics.Stopwatch]::StartNew(); $script:fxStep = [Diagnostics.Stopwatch]::StartNew()
                $gq.ShineOn = (-not $NoShine); $gq.ShineGain = [single]$Shine
                $gq.ParallaxOn = (-not $NoParallax); $gq.ParallaxDepth = [single]$ParallaxDepth; $gq.MaterializeOn = (-not $NoMaterialize)
                Say ("parallax depth: {0} (F7 switches it with the relief)" -f $(if ($NoParallax) { 'off (-NoParallax)' } elseif (-not $gq.DepthUnitOk) { 'off -- this card has no 19th texture unit' } else { '{0} units at most, gone by {1:N0} units away' -f $ParallaxDepth, $gq.ParallaxFar })) Cyan
                Say ("materials: {0} (rooms\_materials.json; F6 switches it){1}" -f $(if ($NoShine) { 'no shine (-NoShine)' } else { 'surfaces shine by what they are, x{0}' -f $Shine }), $(if ($gq.MatUnitOk) { '' } else { '; this card has no 17th texture unit: companion maps left out' })) Cyan
                $script:gpu = $gq; $script:gpuOn = $true
                Say ("THE GRAPHICS CARD DRAWS THE PICTURE: {0} (OpenGL {1}); textures up to {2:N1} GB on it{3}; F9 switches to the processor and back" -f $gq.Renderer, $gq.Version, ($gq.MaxTextureBytes / 1GB), $(if ($gq.CardMemoryBytes -gt 0) { " (the driver reports {0:N1} GB)" -f ($gq.CardMemoryBytes / 1GB) } else { '' })) Cyan
                Say ("texture quality: {0} -- replacement textures {1}" -f $script:texQuality.ToUpperInvariant(), $(if ($script:texMax -gt 0) { "at most $($script:texMax) px (scaled copies in $($TexOverrideDir)-$($script:texMax))" } else { 'as large as they are' })) Cyan
            } else { Say ("graphics card not available: {0} -- drawing stays on the processor" -f $gErr) Yellow; Show-GpuRefused $gErr }
        } catch { Say ("graphics card not available: {0} -- drawing stays on the processor" -f $_.Exception.Message) Yellow; $script:gpu = $null; Show-GpuRefused $_.Exception.Message }
    }
    # the player's body for the placed lights' shadows: the raptor rig, its walk and idle ranges from the .ANI naming it
    $script:body = $null; $script:bodyBuf = $null
    if ($script:gpu -and -not $NoPlayerShadow) {
        try {
            $bx = Join-Path $TexDir 'RAPTOR.XAF'; $rg = @(124, 136, 143, 147)
            $ka = Join-Path (Split-Path $TexDir) 'AZRAEL\KURT.ANI'
            if (Test-Path $ka) {
                $kt = [IO.File]::ReadAllText($ka)
                $mw = [regex]::Match($kt, '(?im)^\s*WALK\s+(\d+)\s*-\s*(\d+)'); if ($mw.Success) { $rg[0] = [int]$mw.Groups[1].Value; $rg[1] = [int]$mw.Groups[2].Value }
                $mr = [regex]::Match($kt, '(?im)^\s*REST\s+(\d+)\s*-\s*(\d+)'); if ($mr.Success) { $rg[2] = [int]$mr.Groups[1].Value; $rg[3] = [int]$mr.Groups[2].Value }
            }
            $bw = New-Object AztTool.ScanWire
            if ((Test-Path $bx) -and $bw.AddBody('PLAYER', $bx, $rg[0], $rg[1], $rg[2], $rg[3])) {
                # its keyframes on the CHARACTERS' clock: the game's animation tick (aztAnimPeriod, microseconds a frame;
                # Set-AnimRate.ps1 changes it), whole frames at a time as they step -- never paced by the player's speed
                $ap = 0; foreach ($st in $man.settings) { if ($st.name -eq 'aztAnimPeriod') { try { $ap = RdU32 (HostLin ([Convert]::ToUInt32((([string]$st.linear) -replace '^0x', ''), 16))) } catch { } } }
                if ($ap -lt 5000 -or $ap -gt 1000000) { $ap = 54925 }
                $bw.BodyAnimHz = 1e6 / $ap
                $script:body = $bw; $script:bodyBuf = New-Object single[] ($bw.BodyTriCount('PLAYER') * 9); $script:bodyClock = [Diagnostics.Stopwatch]::StartNew()
                Say ("player shadow: the raptor's body ({0} triangles, walk {1}-{2}, idle {3}-{4}, {5:N1} frames/s like the characters) casts from the room's placed lights (-NoPlayerShadow)" -f $bw.BodyTriCount('PLAYER'), $rg[0], $rg[1], $rg[2], $rg[3], $bw.BodyAnimHz) Cyan
            } else { Say ("player shadow: no body ({0})" -f $(if (Test-Path $bx) { $bw.LastError } else { "no $bx" })) Yellow }
        } catch { Say ("player shadow: {0}" -f $_.Exception.Message) Yellow; $script:body = $null }
    }
    Say ("texture filtering {0} (F7 switches it; mip bias {1:N2})" -f $(if ($r.Filter) { 'ON' } else { 'off' }), $MipBias) Cyan
    if (-not $NoLamp -and -not $Light) {
        $r.SetLightTable([AztTool.Raster]::BuildLightTable($pal, 76, [single]2.4), 76, [single]2.4)
        $r.LampHalo = [single]$LampHalo; $r.LampHaloInnerDeg = [single]$LampHaloInner; $r.LampHaloDeg = [single][Math]::Max($LampHaloOuter, $LampHaloInner + 1)
        $r.LampRoom = [single]$(if (-not $LampStartsOn) { $LampRoomOff } else { $LampRoom }); $r.LampPower = [single]$LampPower; $r.LampRange = [single]$LampRange
        $r.LampInnerDeg = [single]$LampInner; $r.LampOuterDeg = [single][Math]::Max($LampOuter, $LampInner + 1)
        $r.ShadowDark = [single]$ShadowDark; $r.ShadowNear = [single]$ShadowNear; $r.ShadowFar = [single][Math]::Max($ShadowFar, $ShadowNear + 10)
        $r.ShadowSoft = [single]$ShadowSoft
        $r.Lamp = $true
        if (-not $NoShadows) {
            # the lamp's own view of the room: depth only matters, 64 degrees so it sees a
            # little more than the widest part of the beam
            # The picture's own shape, and 8 degrees taller than the picture (58 against the original 50): the same
            # margin sideways, so the lamp sees everything the eye does and a little more.
            # the PICTURE's shape, which in widescreen is wider than the game's 4:3
            $shadowW = [int]([Math]::Round($ShadowSize * $r.W / [double]$r.H / 4) * 4)
            $rs = New-Object AztTool.Raster($shadowW, $ShadowSize)
            $rs.NearZ = [single]0.5; $rs.SetVerticalFov($Fov + 8); $rs.Threads = [Math]::Max(2, [int]([Environment]::ProcessorCount / 2))
            if ($LampPair) { $rs2 = New-Object AztTool.Raster($shadowW, $ShadowSize); $rs2.NearZ = [single]0.5; $rs2.SetVerticalFov($Fov + 8); $rs2.Threads = $rs.Threads }
            Say ("lamp shadows on: {4} {0:N0} to the side of and {1:N0} above the eye (kept inside the walls), {2}x{3} shadow map each, every face casts" -f $LampOffsetX, $LampOffsetY, $shadowW, $ShadowSize, $(if ($LampPair) { 'a pair of lamps' } else { 'one lamp' })) Cyan
        }
        Say ("helmet lamp on: room level {0:N2} with the lamp on, {9:N2} with it off; lamp +{1:N2}, {5:P0} of it in a wide beam of {6:N0}-{7:N0} degrees, the rest in a hot spot of {2:N0}-{3:N0}; half strength at {4:N0} units; trails the view by {8:N2} s" -f $LampRoom, $LampPower, $LampInner, $LampOuter, $LampRange, $LampHalo, $LampHaloInner, $LampHaloOuter, $LampLag, $LampRoomOff) Cyan
    }
    if ($Threads -gt 0) { $r.Threads = $Threads }
    # TRUE COLOUR USES NEARLY EVERY LOGICAL PROCESSOR. Measured on the 2134x1238 picture: the
    # draw takes 8.8 ms on half of them and 6.2 ms on all but two -- the per-pixel work is
    # mostly waiting on memory, which is exactly what the second thread of a core is good for.
    # Two are left for DOSBox and the overlay. The 8-bit path keeps its half, as measured before.
    # ...AND THE AFTER-EFFECTS GET A FEW OF THEIR OWN, NOT A SHARE OF THE SAME ONES. The first
    # split was 30 for the draw and 16 for the effects, which run at the same time: 46 threads
    # on 32 processors, and the draw measured 12-13 ms in game against 9.9 ms alone. Measured
    # with both running: 26 + 6 gives the draw 9.6 ms -- as if the effects were not there --
    # and the effects still finish well inside a frame. So: an eighth and two for everything
    # else, a fifth for the effects, the rest for the draw.
    elseif ($r.Rgb) {
        $nCpu = [Environment]::ProcessorCount
        # (a tenth is plenty for the sharpen alone; the fifth was for edge smoothing)
        $fxThreads = [Math]::Max(2, [int][Math]::Floor($nCpu / $(if ($NoAA) { 10 } else { 5 })))
        $r.Threads = [Math]::Max(2, $nCpu - $fxThreads)
        # the pair's two views are drawn at once, half the threads each; one lamp gets them all
        if ($rs)  { $rs.Threads  = $(if ($rs2) { [Math]::Max(2, [int]($r.Threads / 2)) } else { $r.Threads }) }
        if ($rs2) { $rs2.Threads = [Math]::Max(2, [int]($r.Threads / 2)) }
        # THE GAME COMES FIRST. DOSBox emulates on one thread, and with every processor busy
        # drawing its loop fell from ~400 to ~230 turns a second -- which is time this loop
        # then spends waiting for it. Running the renderer a step below normal priority means
        # that one thread always gets a processor the moment it wants one.
        try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }
    }
    else { $r.Threads = [Math]::Max(2, [int]([Environment]::ProcessorCount / 2)) }
    # the after-effects run on the overlay's thread, not in this loop (see Overlay.SubmitRgb)
    $script:tcPostJob = $null
    if ($r.Rgb -and $script:ov) {
        $script:tcPostJob = New-Object AztTool.PostJob
        $script:tcPostJob.SmoothEdges = (-not $NoAA); $script:tcPostJob.Sharpen = [single]$Sharpen
        $script:tcPostJob.Threads = $(if ($fxThreads) { $fxThreads } else { [Math]::Max(2, [int]([Environment]::ProcessorCount / 5)) })
        $script:ov.ComposeThreads = $script:tcPostJob.Threads
        $script:ov.PostHook = $script:tcPostJob.AsHook()
    }
    $tmWait = 0.0; $tmHand = 0.0; $tmPush = 0.0; $tmFrames = 0; $tmClock = [Diagnostics.Stopwatch]::StartNew(); $tmShadow = 0.0
    $tmPre = 0.0; $tmRoom = 0.0; $tmWater = 0.0; $tmDust = 0.0; $tmCard = 0.0     # the draw, split: everything before the room (lamp + torch views, script), the room itself, water, dust

    if ($false) {
        # RETIRED: -Uncap lifted the cap for the whole session with no movement correction.
        # Enable-HostFps now does it per takeover, with the correction, and is the default.
        # SAVED SO IT CAN BE PUT BACK. Movement is frame-tied, so a cap left at 0 after the
        # watcher stops leaves the player sprinting -- and the game would look broken in a
        # way that has nothing to do with the renderer.
        $script:capWas = $hv.ReadU32((HostLin $capLin))
        [void]$hv.WriteU32((HostLin $capLin), 0)
        Say ("frame cap lifted (aztFramePeriod {0} -> 0) -- movement is frame-tied, so stand still" -f $script:capWas) Yellow
    }

    # START FROM A KNOWN STATE. $suppressed below tracks what we believe the guest's flags
    # are, and Set-Engine3D short-circuits when they already match -- so if a previous run
    # died with aztSceneParts still 4, believing "not suppressed" would never clear it and
    # the player would stare at a black viewport we think we are not responsible for.
    foreach ($s in @($S_ready, $S_enable, $S_sup3D, $S_parts, $S_sync)) { [void]$hv.WriteU32((HostLin $s), 0) }
    Test-LivePalette

    # NEVER SUPPRESS THE ENGINE UNLESS WE ARE ACTUALLY PUSHING FRAMES.
    #
    # The first live run came back as "everything was black, I could not see to walk to a
    # door". These three writes used to happen HERE, at session start -- which switches off
    # the engine's own rasteriser immediately, while the loop then spends the intro, the
    # movies and the room load with no geometry yet, skipping the push every time. Engine
    # off, host drawing nothing: a black screen, and no way to walk out of it.
    #
    # Suppression is now tied to having something to draw, and is lifted again the moment we
    # stop drawing it. The game is always either rendering itself or being rendered by us.
    $suppressed = $false
    $room = $null; $loadedFp = ''; $loadedNames = ''; $lastDetectErr = ''; $pushFails = 0
    $syncTimeouts = 0; $detects = 0; $renderMs = 0.0
    $bootNoted = $false; $bootDoneNoted = $false; $bootSkipNoted = $false; $bootZero = $null
    $totalFrames = 0; $loopSeq = 0; $dstSeen = @{}; $sincePose = [Diagnostics.Stopwatch]::StartNew(); $pose = $null; $sceneRoot = 0; $poseMs = 0.0; $poseWalks = 0
    $sinceSave = [Diagnostics.Stopwatch]::StartNew()
    $shown0 = $hv.ReadU32((HostLin $S_shown)); $starve0 = $hv.ReadU32((HostLin $S_starve))
    $lastCheck = [Diagnostics.Stopwatch]::StartNew()
    $camPrev = $null
    $frames = 0; $sinceReport = [Diagnostics.Stopwatch]::StartNew()
    $m = New-Object single[] 16
    [AztTool.SceneGraph]::StepLogOn = $true; [AztTool.SceneGraph]::StepLog.Clear()
    $charClock = [Diagnostics.Stopwatch]::StartNew(); $loadedCharSig = ''; $lastCharErr = ''; $probeClock = [Diagnostics.Stopwatch]::StartNew()
    $spdPos = $null; $spdClock = [Diagnostics.Stopwatch]::StartNew(); $spdMax = 0.0; $spdSum = 0.0; $spdN = 0
    $refClock = [Diagnostics.Stopwatch]::StartNew(); $refStill = [Diagnostics.Stopwatch]::StartNew(); $refPrevCam = $null
    $walkTorn = 0; $walkRetried = 0
    $smooth = New-Object AztTool.Smoother; $smooth.All = [bool]$SmoothAll; $smooth.Adaptive = (-not $NoSteadyPlay)
    $portals = $null; $portalPx = 0L; $portalFrames = 0
    $mirV = $null
    $lampDir = $null; $lampClock = [Diagnostics.Stopwatch]::StartNew()
    $lampOnNow = [bool]$LampStartsOn; $lampLevel = $(if ($lampOnNow) { 1.0 } else { 0.0 }); $lampKeyWas = $false; $lampFade = [Diagnostics.Stopwatch]::StartNew(); $lampM = New-Object single[] 16
    # the shots: the ammo count (obj2 0x14694C: 0x15B42 `sub word [0x14694C], 1` right after the game plays shot.wav),
    # and the game's sound state beside it, logged on the first shots (the gun's sound went missing, 2026-10-07)
    $shotD2 = Get-GuestD2
    $shotAt = { param([uint32]$a) [long]($g.MemBase + $a + $shotD2) }
    # the game's book / item close-up view: word [0x15257C], set by StartBookViewMode (0x15C75, 0x162F8), cleared at
    # 0x164D4. While it is set the true-colour picture is black behind the page, not the live room (Josh, 2026-10-08).
    $script:bookViewAt = & $shotAt 0x15257C; $script:bookViewWas = $false
    # the save/load list's state (docs\save-load-screen-RE.md): the fold-out block 0x1523D6..0x1524CD, the picked row 0x146948, the cursor
    $script:memAt = @{ Blk = (& $shotAt 0x1523D6); Sel = (& $shotAt 0x146948); Cur = (& $shotAt 0x182D6C); Mgr = (& $shotAt 0x182DB8); CurSurf = (& $shotAt 0x147588); Hot = (& $shotAt 0x14758E); Hidden = (& $shotAt 0x147586); Sav = (& $shotAt 0x152B02); Lod = (& $shotAt 0x152B04); Snd = (& $shotAt 0x14693A); D2 = [long]$shotD2 }; $script:sysHotDone = $false; $script:slGuard = $null; $script:quitDone = $false; $script:quitEndSaid = $false
    Start-SpaceGuard (& $shotAt 0x152B28)                # (the "a line is being spoken" word)
    $script:fallAt = & $shotAt 0x152592; $script:jumpAir = $false      # (the game's fall speed: the jump writes it)
    $script:crouchAt = @{ Eye = (& $shotAt 0x140328); Knee = (& $shotAt 0x140340); Walk = (& $shotAt 0x1417FC); Run = (& $shotAt 0x141800) }; $script:crouchBase = $null; $script:crouchC = 0.0; $script:crouchWrote = 0.0
    # ---- THE GUEST SNAPSHOT (2026-10-13 performance audit) -------------------------------------------------------------
    # The obj2 blocks the frame's watchers read (the menus' and fold-out's words 0x152138.., the ammo / weapon / sound words
    # 0x146900.., the cursor and the event record 0x182D6C.., the player pointer 0x1841C8) are read ONCE at the top of each
    # frame and again beside the camera after the hand-shake wait (HostView.SnapTake); GuestWord and the menu steps read from
    # that copy, writes go to the game at once and into the copy (Write-GuestSnap). Built obj2 addresses + this session's
    # obj2 delta -- never a guest POINTER kept (the player object, the click screen are still read through, every time).
    $script:snapOn = $false
    try {
        $hv.SnapInit([long]($g.MemBase + $shotD2), [uint32[]]@(0x146900, 0x152138, 0x182D6C, 0x1841C8), [int[]]@(0x920, 0x9F2, 0x50, 4))
        $hv.SnapTake(); $script:snapOn = $true
    } catch { Say ("guest snapshot: {0} -- the frame's watchers read the game word by word" -f $_.Exception.Message) Yellow }
    # THE HOT OVERLAY ADDRESSES, ONCE PER ATTACH: HostLin is MemBase-relative, and MemBase is ASLR'd per attach -- this is
    # Invoke-Session, which runs per attach, so they are worked out here and never outlive it.
    $hlReady = HostLin $S_ready; $hlCamRec = HostLin $S_camRec; $hlSync = HostLin $S_sync
    $hlFrameNo = $(if ($S_frameNo) { HostLin $S_frameNo } else { 0L }); $hlBoot = $(if ($S_bootState) { HostLin $S_bootState } else { 0L })
    $script:hlRapHit = $(if ($S_rapHit) { HostLin $S_rapHit } else { 0L })
    $script:hlReboot = $(if ($symMap.ContainsKey('aztReboot')) { HostLin (Sym 'aztReboot') } else { 0L })
    $hv.PollUs = 400
    $script:earlyReady = $false; $script:waitTimerSaid = $false
    Say ("frame hand-shake: the waits poll every 0.4 ms; in true colour 'ready' is armed right after the camera read (the guest copies every frame with sync 0), 8-bit and calibration keep the end-of-frame order{0}" -f $(if ($NoEarlyReady) { ' -- early arming OFF (-NoEarlyReady)' } else { '' })) DarkGray
    $ammoAddr = & $shotAt 0x14694C; $ammoWas = -1; $shots = 0; $flashClock = New-Object Diagnostics.Stopwatch; $flashLive = $false
    # the player's health for the damage badge: dword [[0x1841C8] + 0x16], 16.16 (what the gauge code at 0x11DF6 reads)
    $hpPtrAt = & $shotAt 0x1841C8; $hpWas = $null; $hpObjWas = [uint32]0; $hpQuiet = [Diagnostics.Stopwatch]::StartNew(); $hits = 0; $hpMax = 1000 * 65536; $script:hpFrac = -1.0
    $camPrevM = $null; $tele = $null; $lastPickErr = ''; $fallRef = $null; $fallSaid = $false; $fallClock = [Diagnostics.Stopwatch]::StartNew(); $dj = 0.0
    $sinceAlive = [Diagnostics.Stopwatch]::StartNew(); $stallDumped = $false; $fnLast = [uint32]0
    $stkRing = New-Object object[] 4; $stkNext = 0; $stkClock = [Diagnostics.Stopwatch]::StartNew(); $heapBadNoted = $false; $heapClock = $null; $heapLast = @()

    while ($true) {
        # THE RAPTOR POLL BELONGS AT THE TOP OF THE LOOP. A game sitting in AztRaptorTrap
        # has stopped running its frame loop, so it never clears aztInjReady -- BOTH sync
        # waits below then time out and `continue`, and a poll placed after either of them
        # would never be reached. The one moment the capture exists is the one moment this
        # loop stops getting to the end of itself, which is exactly the wrong place to
        # depend on. Cheap: one dword read per iteration.
        $topClock = [Diagnostics.Stopwatch]::StartNew()
        [void](Test-RaptorTrap)
        Update-HostFps
        # Same placement, same reason: a dead guest never reaches the end of this loop.
        # LIVENESS IS THE GUEST'S OWN FRAME COUNTER, not "we are pushing". The 16:28 crash
        # came one second after the viewport was handed back for a room load, so a test
        # that required $suppressed saw nothing and the stack was lost a second time.
        # KEEP THE LAST FEW STACK IMAGES IN HOST MEMORY. Waiting 3 s to notice a dead guest
        # is too slow: on the ORRERY crash DOSBox itself closes about a second after the
        # game dies (16:34 run -- the hold loop in AZRAEL.BAT printed its message and the
        # window went anyway). A 48 KB read per iteration costs nothing, and whichever
        # image was taken last before the process vanished is written out on exit.
        if ($Diag -and $stkClock.ElapsedMilliseconds -ge 40) {
            $stkClock.Restart()
            $img = [AztTool.ProcMem]::Read($g.ProcessId, (GuestPtr (Get-StackLo)), 0xC000)
            if ($img) {
                # THE ORRERY CRASH, NAMED BY THE 16:43 IMAGE: the mesh loader 0x29068 calls
                # 0x46F34 (add faces to a mesh), which does `call [edx+0x18]` at 0x4713C on a
                # face slot at [mesh+0x5C] + [mesh+0x54]*120 -- and that slot was 0x6400000,
                # past the end of guest RAM, so the vtable read back as FFFFFFFF and the call
                # went to low memory. The stack cannot say WHY the slot address is wrong; the
                # mesh object can, and it is gone by the time the process exits. So whenever
                # that call's return address is on the stack with 0x29068's behind it, copy
                # the mesh header too.
                $mesh = $null; $meshAt = [uint32]0
                for ($o = 0x8000; $o -lt 0x8800; $o += 4) {
                    if ([BitConverter]::ToUInt32($img, $o) -ne 0x23713F) { continue }
                    if ([BitConverter]::ToUInt32($img, $o + 0x34) -ne 0x2197C1) { continue }
                    $meshAt = [BitConverter]::ToUInt32($img, $o + 8)
                    if ($meshAt -ge 0x1000) { $mesh = [AztTool.ProcMem]::Read($g.ProcessId, (GuestPtr $meshAt), 0x90) }
                    break
                }
                # ONCE A SECOND, not every image. Thirty mini-heaps is thirty process reads
                # plus the formatting, 25 times a second, on the path that paces the frame.
                if (-not $heapClock -or $heapClock.ElapsedMilliseconds -ge 1000) {
                    $heapClock = [Diagnostics.Stopwatch]::StartNew()
                    $heapLast = @(); try { $heapLast = @(Get-HeapReport) } catch { }
                }
                $heapNow = $heapLast
                # Said the moment it first happens, with the room and frame, because that
                # moment -- not the crash -- is the fault.
                if (-not $heapBadNoted -and ($heapNow -match 'PAST THE END')) {
                    $heapBadNoted = $true
                    Say ("HEAP LEFT REAL MEMORY in {0}:" -f $script:rapRoom) Red
                    foreach ($hl in $heapNow) { Say ('  ' + $hl) Red }
                }
                $stkRing[$stkNext % 4] = [pscustomobject]@{ At = (Get-Date); Bytes = $img; Mesh = $mesh; MeshAt = $meshAt; Heap = $heapNow; Frame = $(if ($S_frameNo) { RdU32 (HostLin $S_frameNo) } else { 0 }) }
                $stkNext++
            }
        }
        if ($S_frameNo) {
            $fnNow = $hv.ReadU32($hlFrameNo)
            if ($fnNow -ne $fnLast) { $fnLast = $fnNow; $sinceAlive.Restart(); $stallDumped = $false }
        }
        if ($Diag -and -not $stallDumped -and $sinceAlive.Elapsed.TotalSeconds -ge 3) {
            $stallDumped = $true; Write-StallStack
        }
        $rec = $hv.ReadBytes($hlCamRec, 320)
        if (-not $rec) {
            # The process is gone; the ring is all that is left of its stack. Newest first.
            try {
                $dir = Split-Path $LogFile -Parent; $k = 0
                for ($j = $stkNext - 1; $j -ge [Math]::Max(0, $stkNext - 4); $j--) {
                    $e = $stkRing[$j % 4]; if (-not $e) { continue }
                    [IO.File]::WriteAllBytes((Join-Path $dir ("exitstack-{0}.bin" -f $k)), $e.Bytes)
                    Say ("  stack image {0}: taken {1:HH:mm:ss.fff}, guest frame {2}" -f $k, $e.At, $e.Frame) Yellow
                    if ($k -eq 0 -or $k -eq 3) { foreach ($hl in $e.Heap) { Say ('    ' + $hl) Yellow } }
                    if ($e.Mesh) {
                        [IO.File]::WriteAllBytes((Join-Path $dir ("exitmesh-{0}.bin" -f $k)), $e.Mesh)
                        Say ("    mesh 0x{0:X}: faces {1} of cap {2}, face array 0x{3:X}; groups {4} of {5} at 0x{6:X}" -f $e.MeshAt, `
                            [BitConverter]::ToInt32($e.Mesh, 0x54), [BitConverter]::ToInt32($e.Mesh, 0x58), [BitConverter]::ToUInt32($e.Mesh, 0x5C), `
                            [BitConverter]::ToInt32($e.Mesh, 0x48), [BitConverter]::ToInt32($e.Mesh, 0x4C), [BitConverter]::ToUInt32($e.Mesh, 0x50)) Yellow
                    }
                    $k++
                }
            } catch { Say ("exit stack dump failed: {0}" -f $_.Exception.Message) Yellow }
            # SAY WHERE AND WHEN. "the game exited" alone cannot distinguish a crash five
            # seconds into rendering from one the player caused, and the last camera position
            # says whether it died standing still or while moving into somewhere new.
            if ($camPrev) {
                Say ("the game exited -- {0} frames handed to the guest since takeover, last camera {1:N1} {2:N1} {3:N1}" -f `
                    $totalFrames, $camPrev[0], $camPrev[1], $camPrev[2]) Yellow
            } else { Say 'the game exited (before any frame was pushed).' Yellow }
            return
        }
        if ($script:snapOn) { $hv.SnapTake() }      # (the frame's guest snapshot: the watchers below read from it)
        Step-LoadGuard      # (after a load: the HUD and the materialize wait for the loading panel to go)
        Step-Fov            # (the game's field follows the host's; F12 cycles it)
        Step-NpcPace        # (a room's "npcs": a character's own pace and its pauses)
        if ([Text.Encoding]::ASCII.GetString($rec,0,4) -ne 'CAM1') {
            Step-NothingToDraw ([ref]$suppressed) 'no camera record' 200; continue
        }
        $camObj = [BitConverter]::ToUInt32($rec, 16)
        # No scene yet: the intro, a movie, a load. Not an error -- just nothing to draw,
        # and the engine must be drawing for itself while that is true.
        if ($camObj -lt 0x1000) {
            Step-NothingToDraw ([ref]$suppressed) 'no scene' 200; continue
        }

        for ($i = 0; $i -lt 16; $i++) { $m[$i] = [BitConverter]::ToSingle($rec, $REC_MOVWORLD + $i*4) }
        # Identity means the engine has not populated the frame yet. Rendering from it puts
        # the camera at the origin looking down +Z: plausible-looking and completely wrong.
        if ($m[12] -eq 0 -and $m[13] -eq 0 -and $m[14] -eq 0 -and $m[0] -eq 1) {
            Step-NothingToDraw ([ref]$suppressed) 'camera not set yet' 20; continue
        }

        $jumped = $false
        if ($camPrev) {
            $d = [Math]::Sqrt([Math]::Pow($m[12]-$camPrev[0],2) + [Math]::Pow($m[13]-$camPrev[1],2) + [Math]::Pow($m[14]-$camPrev[2],2))
            if ($d -gt $JumpUnits) { $jumped = $true }
        }
        $camPrev = @($m[12], $m[13], $m[14])
        # The last time the camera moved further in one step than walking can take it: the two
        # ends of a teleport, kept for Write-PortalCheck when the room turns out to have changed.
        if ($camPrevM) {
            $dj = [Math]::Sqrt([Math]::Pow($m[12]-$camPrevM[12],2) + [Math]::Pow($m[13]-$camPrevM[13],2) + [Math]::Pow($m[14]-$camPrevM[14],2))
            if ($dj -gt 60) {
                $tele = @{ Before = $camPrevM; After = [single[]]$m.Clone(); At = [Diagnostics.Stopwatch]::GetTimestamp() * 1000.0 / [Diagnostics.Stopwatch]::Frequency }
                [AztTool.SceneGraph]::ForgetNames(); $smooth.Reset()      # a teleport is a new scene: nothing remembered about the old one is true
                # ---- LET THE ENGINE DRAW A NEW ROOM ONCE BEFORE WE TAKE IT OVER ------------------
                # MEASURED 2026-10-05 09:01: walk corridor -> spa -> corridor with the host drawing
                # throughout, and on the way back in the player stands at the right height until
                # they move, then drops 57 units and walks about UNDER the room -- eye height
                # -95.5, which is 45 above `Object03`, an undrawn catch plane at -140.5 beneath
                # everything. The real floors (tunnel03 at -83.8, the floorbits) no longer stop the
                # game's ground test, so the exit trigger lying on them is never touched either and
                # the player can walk out through the walls. Same thing as the spa walkway giving
                # way (three drownings in the logs) and "stuck in the geometry".
                #
                # The first room never does this, and the difference is that the engine drew it for
                # itself for a few seconds before the host took over. Whatever the ground test needs
                # from a frame object, the engine's own draw of a freshly loaded room provides it and
                # nothing the host does replaces it. Some reloads happened to get it anyway, when
                # this loop noticed the load in time to hand the viewport back -- which is why the
                # fault came and went.
                #
                # So: every teleport (a room change always is one) hands the viewport back until
                # the guest has drawn a few frames of its own, then the normal path takes it again.
                # Done HERE, on the frame the jump is seen, because the player can start walking at
                # once and room detection can be half a second behind.
                # (the visor's loading cover goes up NOW, before the engine's own frames could be seen -- RoomCover.cs)
                if ($suppressed) { Start-RoomCover 'room change' }
                if ($suppressed -and -not $NoLoadPulse -and $S_frameNo) {
                    $f0 = RdU32 (HostLin $S_frameNo)
                    Set-Engine3D ([ref]$suppressed) $false
                    $pw = [Diagnostics.Stopwatch]::StartNew(); $fNow = $f0
                    while ($pw.ElapsedMilliseconds -lt 1500) {
                        [Threading.Thread]::Sleep(5)
                        $fNow = RdU32 (HostLin $S_frameNo)
                        Set-RoomCoverTarget (0.02 + 0.10 * [Math]::Min(1.0, ([uint32]($fNow - $f0)) / 6.0)) 'pulse'
                        if (([uint32]($fNow - $f0)) -ge 6) { break }
                    }
                    Say ("  new room: the engine drew {0} frames of it itself in {1:N0} ms before the host took over" -f ([uint32]($fNow - $f0)), $pw.ElapsedMilliseconds) Cyan
                    if ($script:roomCover -and $script:roomCover.Loaded) { Stop-RoomCover 'ready' }      # (the room was in before the jump: it shows now)
                    elseif ($script:roomCover -and $script:roomCover.Stage -eq 'pulse') { $script:roomCover.Stage = 'waiting'; $script:roomCover.WaitFrom = $script:roomCover.Clock.Elapsed.TotalSeconds }
                    $camPrevM = $null
                    continue
                }
                if ($script:roomCover -and $script:roomCover.Loaded) { Stop-RoomCover 'ready' }
                elseif ($script:roomCover -and $script:roomCover.Stage -eq 'pulse') { $script:roomCover.Stage = 'waiting'; $script:roomCover.WaitFrom = $script:roomCover.Clock.Elapsed.TotalSeconds }
            }
        }
        # ---- THE MOMENT THE FLOOR GIVES WAY --------------------------------------------------
        # A drop of more than 25 units from one loop to the next that is not a teleport: the
        # player has just fallen through something. Written down at once, while the game's own
        # idea of the scene is still what made it happen: where, and for every named frame
        # whether the engine's cached world matrix (what its ray tests use) matches the one
        # composed from the locals (what is true), with the motion flags of the ones that differ
        # and of whatever is nearest.
        # (Measured against where the player stood up to a second ago, not just the last loop:
        # a fall spread over several frames must still count. One report per fall.)
        if ($null -eq $fallRef -or $m[13] -ge $fallRef[13] -or $fallClock.ElapsedMilliseconds -gt 1000 -or ($camPrevM -and $dj -gt 60)) {
            $fallRef = [single[]]$m.Clone(); $fallClock.Restart(); $fallSaid = $false
        }
        if ($camPrevM -and $pose -and -not $fallSaid -and ($fallRef[13] - $m[13]) -gt 25 -and $dj -le 60) {
            $fallSaid = $true; $camPrevM = $fallRef
            try {
                Say ("FALL: eye dropped {0:N1} units at ({1:N0},{2:N1},{3:N0}) from ({4:N0},{5:N1},{6:N0}); host drawing: {7}; scene parts flag {8}" -f `
                    ($camPrevM[13] - $m[13]), $m[12], $m[13], $m[14], $camPrevM[12], $camPrevM[13], $camPrevM[14], $suppressed, $hv.ReadU32((HostLin $S_parts))) Red
                Write-GroundHits; $script:colLast = ''; Write-CollisionWatch 'at the fall'
                $blk = [AztTool.SceneGraph]::WalkBlocks($g.ProcessId, [long]$g.MemBase, $sceneRoot, 900)
                $tr = [AztTool.SceneGraph]::WalkTree($g.ProcessId, [long]$g.MemBase, $sceneRoot, 900)
                $sm2 = New-Object AztTool.Smoother; $sm2.Sample($tr, 0); $truth = $sm2.Evaluate(1)
                $rowsF = @()
                foreach ($k in $blk.Keys) {
                    if (-not $truth.ContainsKey($k)) { continue }
                    $bv = $blk[$k]; $tv = $truth[$k]; $dmax = 0.0
                    for ($q = 0; $q -lt 16; $q++) { $dq = [Math]::Abs($bv[16 + $q] - $tv[$q]); if ($dq -gt $dmax -or [double]::IsNaN($dq)) { $dmax = $(if ([double]::IsNaN($dq)) { 1e9 } else { $dq }) } }
                    $near = [Math]::Sqrt([Math]::Pow($tv[12] - $m[12], 2) + [Math]::Pow($tv[14] - $m[14], 2))
                    $rowsF += [pscustomobject]@{ N = $k; D = $dmax; Near = $near; B = $bv; T = $tv }
                }
                $badF = @($rowsF | Where-Object { $_.D -gt 0.05 } | Sort-Object D -Descending)
                Say ("  {0} named frames; engine cache differs from the truth on {1}" -f $rowsF.Count, $badF.Count) Red
                foreach ($rw in ($badF | Select-Object -First 14)) {
                    Say ("    STALE {0,-14} by {1,9:N2}: cache t ({2:N1} {3:N1} {4:N1}) truth t ({5:N1} {6:N1} {7:N1}) flags dirty {8} rot {9} vel {10}" -f $rw.N, $rw.D, $rw.B[28], $rw.B[29], $rw.B[30], $rw.T[12], $rw.T[13], $rw.T[14], [int]$rw.B[48], [int]$rw.B[49], [int]$rw.B[50]) Red
                }
                foreach ($nm in @('doorcor01','doorcor2','tunnel03','dorwall06','Object03','floorbit02')) {
                    if (-not $blk.ContainsKey($nm)) { continue }
                    $bv = $blk[$nm]
                    Say ("    {0,-10} local t ({1:N1} {2:N1} {3:N1}) x-row ({4:N2} {5:N2} {6:N2}) | cache t ({7:N1} {8:N1} {9:N1}) x-row ({10:N2} {11:N2} {12:N2}) | third t ({13:N1} {14:N1} {15:N1}) x-row ({16:N2} {17:N2} {18:N2}) | dirty {19} rot {20} vel {21}" -f `
                        $nm, $bv[12], $bv[13], $bv[14], $bv[0], $bv[1], $bv[2], $bv[28], $bv[29], $bv[30], $bv[16], $bv[17], $bv[18], $bv[44], $bv[45], $bv[46], $bv[32], $bv[33], $bv[34], [int]$bv[48], [int]$bv[49], [int]$bv[50]) DarkRed
                }
            } catch { Say ("  fall probe failed: {0}" -f $_.Exception.Message) Yellow }
        }
        $camPrevM = [single[]]$m.Clone()
        # HOW FAST THE PLAYER IS ACTUALLY MOVING, in world units a second, over quarter-second
        # windows -- horizontal only, so a ramp does not read as speed. The design figures are
        # 146 walking and 291 running (8.0 and 16.0 a tick at 18.2 ticks a second).
        if (-not $spdPos) { $spdPos = @($m[12], $m[14]); $spdClock.Restart() }
        elseif ($spdClock.ElapsedMilliseconds -ge 250) {
            $dd = [Math]::Sqrt([Math]::Pow($m[12] - $spdPos[0], 2) + [Math]::Pow($m[14] - $spdPos[1], 2)) / $spdClock.Elapsed.TotalSeconds
            if ($dd -lt 3000) { if ($dd -gt $spdMax) { $spdMax = $dd }; if ($dd -gt 5) { $spdSum += $dd; $spdN++ } }
            $spdPos = @($m[12], $m[14]); $spdClock.Restart()
        }

        if (-not $room -or $jumped -or $script:roomCover -or $lastCheck.Elapsed.TotalSeconds -ge $CheckSeconds) {      # (every pass while the loading cover waits for the new room)
            $lastCheck.Restart()
            $fp = Get-SceneFingerprint $camObj
            if ($fp -ne $loadedFp -or $jumped -or -not $room) {
                $why = $(if (-not $room) { 'first room' } elseif ($jumped) { 'camera jumped' } else { 'scene rebuilt' })
                $names = $null
                $detects++
                # IN PROCESS NOW. This used to run Find-LiveRoom.ps1 as a script on every room
                # change: parse it, re-read the symbol map, walk the graph with a process read
                # per field, load and score the whole object index in script loops. The walk
                # and the index are both already in memory here, so the same greedy cover
                # takes a few milliseconds. The script remains as the fallback (it is what
                # BUILDS the index the first time) and as the standalone tool.
                try {
                    if ($null -eq $script:xafIndex) { Initialize-CharacterIndex }
                    if ($script:xafIndex.Count) {
                        $rootNow = [AztTool.SceneGraph]::RootOf($g.ProcessId, [long]$g.MemBase, $camObj)
                        $names = @(Find-LiveRoomFast @([AztTool.SceneGraph]::WalkBlocks($g.ProcessId, [long]$g.MemBase, $rootNow, 2000).Keys))
                    } else {
                        $names = @(& (Join-Path $toolDir 'Find-LiveRoom.ps1') -TexDir $TexDir -Sym $Sym -Quiet -GuestBase $g)
                        $script:xafIndex = $null          # the script has just built the index: load it next time
                    }
                }
                catch {
                    # NOT SWALLOWED. An empty catch here is what turned the first live run
                    # into "everything was black" with nothing to diagnose from. Throttled to
                    # one line per distinct message so a persistent failure does not fill the
                    # log at 2 Hz.
                    $msg = $_.Exception.Message
                    if ($msg -ne $lastDetectErr) { Say ("room detection failed: {0}" -f $msg) Yellow; $lastDetectErr = $msg }
                }
                if (-not ($names -and $names.Count)) {
                    if ($lastDetectErr -ne 'empty') { Say 'room detection returned no match against the .XAF corpus' Yellow; $lastDetectErr = 'empty' }
                }
                if ($names -and $names.Count) {
                    $lastDetectErr = ''
                    $joined = ($names -join '+')
                    if ($joined -eq $loadedNames -and $script:roomCover) { Stop-RoomCover $(if ($script:roomCover.Loaded) { 'ready' } else { 'the same room' }) }      # (a jump within the room: nothing to load)
                    # (a load into the room already here: nothing to load -- once its re-boot has begun, i.e. the save is in, not
                    # the old scene being taken down)
                    if ($joined -eq $loadedNames -and $script:bootHd -and $script:bootHd.Covering -and (Test-LoadUi)) { Set-LoadProgress 1.0 }
                    if ($joined -ne $loadedNames) {
                        Say ("room -> {0}  ({1})" -f $joined, $why) Cyan
                        $script:learnRoom = [string]$names[0]; $script:learnRoomAt = [Diagnostics.Stopwatch]::StartNew()      # (its MAPS.DAT number, learned a moment later: Step-Map)
                        try { Add-MapVisited ([string]$names[0]) } catch { Say ("map: the rooms visited could not be noted ({0})" -f $_.Exception.Message) Yellow }      # (the whole-complex map: rooms visited)
                        # (no cover up -- it gave up waiting, or the scene changed before the jump: up now for the load, while the
                        # host still has the viewport; not the first room, not with the engine drawing for itself)
                        if (-not $script:roomCover -and $loadedNames -and $suppressed) { Start-RoomCover ('late: ' + $why) }
                        Set-RoomCoverTarget 0.14 'recognised'
                        # A GAME LOAD (or the visor boot) covers this room instead: its loading panel's bar follows the textures --
                        # decoded to 65%, on the card to 100 (Set-LoadProgress)
                        $loadUi = (-not $script:roomCover) -and (Test-LoadUi)
                        if ($loadUi) { Set-LoadProgress 0.0; $script:rgbProgress = { param($d, $t) Set-LoadProgress (0.65 * $d / [Math]::Max(1, $t)) } }
                        try {
                            $room = Get-RoomBusy $names
                            $curChars = @()
                            $cameFrom = $loadedNames
                            $loadedNames = $joined
                            # A new room starts with no characters loaded; the pose walk
                            # below adds whoever the live graph says is here.
                            $loadedCharSig = ''
                            # Script-scoped so the raptor dump FILE names the room too; the
                            # log line above is lost once the game dies, the dump is not.
                            $script:rapRoom = $joined
                            $atmNow = Get-RoomAtmosphere $names
                            Set-RoomAtmosphere $r $atmNow $room
                            if ($script:gpu) { Set-GpuAtmosphere $script:gpu $atmNow $room }
                            # A VISOR READOUT on entering (Josh, 2026-10-09, MINEMAZE/5): the room's "visor" block -- "text" (lines),
                            # "lampOff" (only if the flashlight is off then; default true), "delay" (s after the room is recognised,
                            # default 1.5), "hold" (s it stays once typed, default 6). Pressing the flashlight on clears it.
                            $script:visorPending = $null
                            if ($atmNow.Visor -and @($atmNow.Visor.text).Count -and $script:ov -and -not $NoVisorNotes) {
                                $vz = $atmNow.Visor
                                $script:visorPending = [pscustomobject]@{ Lines = [string[]]@($vz.text); LampOff = ($null -eq $vz.lampOff -or [bool]$vz.lampOff)
                                    At = [Diagnostics.Stopwatch]::StartNew(); Delay = [double]$(if ($null -ne $vz.delay) { $vz.delay } else { 1.5 }); Hold = [double]$(if ($vz.hold) { $vz.hold } else { 6 }) }
                            }
                            # sharp relief maps for this room's textures? (-ReliefSharpRooms; made on the card as they go up)
                            if ($script:gpu) {
                                $sharpHere = [bool]($ReliefSharpRooms -contains '*' -or @($names | Where-Object { $ReliefSharpRooms -contains $_ }).Count)
                                $script:gpu.ReliefSharpBuild = $sharpHere
                                $script:gpu.Detail = [single]$(if ($sharpHere) { $Detail } else { 0 })
                            }
                            # ...and its textures up to the card NOW, one at a time under the loading cover or the load's panel, and
                            # finished there, so the room's first frame does not stall on them (a 4K texture with its relief map is
                            # ~0.1 s; the card keeps the rooms visited last -- GpuRaster.UploadSome / Evict; Send-RoomTextures)
                            if ($script:gpu -and $script:gpuOn -and -not $SlowRaster) {
                                $onFrac = $(if ($script:roomCover) { { param($f) Set-RoomCoverTarget (0.72 + 0.26 * $f) 'card' } } elseif ($loadUi) { { param($f) Set-LoadProgress (0.65 + 0.35 * $f) } } else { $null })
                                try { Send-RoomTextures $room $onFrac } catch { Say ("  textures to the card failed: {0} -- the first frame takes them" -f $_.Exception.Message) Yellow }
                            }
                            if ($loadUi) { Set-LoadProgress 1.0; $script:rgbProgress = $null }
                            # (recognised by its SCENE changing, before the camera's jump: the jump and its engine-draw pulse are still to come.
                            # MEASURED, CHAMBNEW -> MINEMAZE 18:06:14: the cover ended 'ready', the jump came a moment later and the pulse put
                            # the 8-bit picture up -- '256 version ... loading, then back'. The cover now waits for that jump, up to 1.5 s.)
                            if ($script:roomCover -and $why -eq 'scene rebuilt' -and ([string]$script:roomCover.Why) -like 'late*') {      # (a cover the jump started has had its pulse)
                                $script:roomCover.Loaded = $true; $script:roomCover.Stage = 'settle'; $script:roomCover.SettleFrom = $script:roomCover.Clock.Elapsed.TotalSeconds
                            } else { Stop-RoomCover 'ready' }
                            # Pose state is per LOAD, not per room object: the room itself is
                            # cached and shared between visits, but the posed copy is not.
                            $pose = $(if ($room.Parts -and $room.Parts.Count) { New-PoseState $room } else { $null })
                            $sceneRoot = [AztTool.SceneGraph]::RootOf($g.ProcessId, [long]$g.MemBase, $camObj)
                            # a new room is a new set of frames: nothing to ease from
                            $smooth.Reset()
                            [AztTool.SceneGraph]::ForgetNames()
                            $script:colLast = ''; $script:colNames = @{}; Write-CollisionWatch ("entering {0}" -f $joined)
                            $portals = $(if ($pose) { Get-RoomPortals $room $names } else { $null })
                            try {
                                $nowT = [Diagnostics.Stopwatch]::GetTimestamp() * 1000.0 / [Diagnostics.Stopwatch]::Frequency
                                if ($tele -and $cameFrom -and ($nowT - $tele.At) -lt 8000) { Write-PortalCheck $tele $cameFrom $joined }
                            } catch { Say ("  portal check failed: {0}" -f $_.Exception.Message) Yellow }
                            $tele = $null
                            if (-not $pose) { Say '  no parts sidecar -- drawing the rest pose (doors will not move)' Yellow }
                            if ($Light) {
                                $r.SetShadeTable([AztTool.Raster]::BuildShadeTable($pal, $ShadeLevels), $ShadeLevels)
                                $r.FogFar = [single]($room.Span * $FogScale)
                                $r.FogNear = [single]($room.Span * $FogScale * $FogNearFrac)
                                $r.Ambient = [single]$Ambient; $r.NormalLight = [single]$NormalLight
                            }
                            if ($room.Water -and $room.Water.Count) { Say ("  reflective water: {0}" -f (($room.Water | ForEach-Object { $_.Name }) -join ', ')) Cyan }
                            Say ("  {0:N0} triangles, {1} textured, {2} flat, {3} invisible" -f `
                                ($room.T.Count/3), $room.Textured, $room.Flat, $room.Skipped)
                            # The heap on arrival in every room: the baseline the bad one is read against.
                            if ($Diag) { try { foreach ($hl in (Get-HeapReport)) { Say ('  ' + $hl) DarkGray } } catch { Say ("  heap report failed: {0}" -f $_.Exception.Message) Yellow } }
                        } catch {
                            # A detect during a load can name a room whose files are mid-swap.
                            # Keep drawing the old one rather than dropping to a black viewport.
                            Say ("could not load {0}: {1}" -f $joined, $_.Exception.Message) Yellow
                            Stop-RoomCover 'could not load'
                            if ($loadUi) { $script:rgbProgress = $null }
                        }
                    }
                    $loadedFp = $fp
                }
            }
        }
        Step-LoadPanel      # (a load's re-boot beginning: the visor's "initiating log file" panel -- before anything here can `continue`)
        Step-MusicWatch     # (the room's music and what the CD switch made of it, in watch.log when it changes)
        Step-EscWatch       # (after a title load: the new game's interface lock; ESC's blockers logged when it opens nothing)
        Step-QuitWatch      # (QUIT in the GPU mode: straight to the desktop, no credits)
        Step-ShotWatch      # (each shot: the input that led to it -- the right-click shooting)
        # THE LOADING COVER HOLDS until the new room is in (Stop-RoomCover 'ready', above): no frame of the old room drawn from
        # the new place, no 8-bit picture. Given up if the room never changes (a jump inside it: 1 s of waiting) or at 12 s.
        if ($script:roomCover) {
            $rc = $script:roomCover; $ct = $rc.Clock.Elapsed.TotalSeconds; $rc.NothingSince = $null      # (a scene again: the next gap gets its own 1.5 s)
            if ($ct -gt 12) { Stop-RoomCover 'gave up after 12 s' }
            elseif ($rc.Stage -eq 'waiting' -and ($ct - $rc.WaitFrom) -gt 1.0) { Stop-RoomCover 'no new room came' }
            elseif ($rc.Stage -eq 'settle' -and ($ct - $rc.SettleFrom) -gt 1.5) { Stop-RoomCover 'ready' }      # (no jump came: the room is in -- show it)
            else {
                if ($rc.Stage -eq 'waiting') { Set-RoomCoverTarget ([Math]::Min(0.135, 0.12 + 0.015 * ($ct - $rc.WaitFrom))) $null } else { Show-RoomCover }
                [Threading.Thread]::Sleep(4); continue
            }
        }
        # Detection can fail -- a room mid-load, a scene the corpus does not match. Hand the
        # viewport back and keep trying rather than sitting on a black screen.
        if (-not $room) { Step-NothingToDraw ([ref]$suppressed) 'no room detected' 100; continue }
        $script:nothingClock = $null      # something to draw: the next blink starts its own clock

        # WAIT OUT THE VISOR BOOT. Geometry is already loaded by this point, so the moment
        # the boot finishes the first host frame is ready -- but the buffer is not ours to
        # write until then.
        if ($S_bootState) {
            $bs = $hv.ReadU32($hlBoot)
            if ($bs -eq 1) {
                if (-not $bootNoted) { Say 'visor boot animation running -- it owns the staging buffer, waiting' Cyan; $bootNoted = $true }
                Set-Engine3D ([ref]$suppressed) $false
                # THE HOST DRAWS IT (BootHd, on its own thread): nothing to do here but wait for the game's
                # boot to end -- BootHd winds it on at the shutter beat, so that is about 15.5 s in.
                if ($script:bootHd) {
                    if (-not $bootShownNoted) { Say '  the boot is the host''s own (BootHd), in true colour' Cyan; $bootShownNoted = $true }
                    Step-LoadRepaint      # (a load's re-boot: the reading panel on the card's window keeps moving)
                    Write-BootNotes; Start-Sleep -Milliseconds 25; continue
                }
                # ...and shown through the true-colour window from its first frame, read straight out of
                # the staging buffer it is drawn into
                if ($script:tcOn -and $script:ov -and $script:tcRaster) {
                    $script:ov.GlPresent = $false          # (shown by the processor, in the overlay's own window)
                    if ($script:ov.ShowGuestFrame([long]($g.MemBase + $bufGuest), $W, $H, $script:tcPal32, [int]$script:tcRaster.W, [int]$script:tcRaster.H)) {
                        if (-not $bootShownNoted) { Say '  the boot is shown in true colour (the overlay window, from the staging buffer)' Cyan; $bootShownNoted = $true }
                        Start-Sleep -Milliseconds 25; continue
                    }
                }
                Start-Sleep -Milliseconds 100
                continue
            }
            if ($bs -eq 0) {
                # Not started YET, or this build has no boot sequence. Waiting forever would
                # be worse than the collision, so give it a bounded chance to start.
                if (-not $bootZero) { $bootZero = [Diagnostics.Stopwatch]::StartNew() }
                if ($bootZero.Elapsed.TotalSeconds -lt $BootWaitSeconds) {
                    Set-Engine3D ([ref]$suppressed) $false
                    Start-Sleep -Milliseconds 100
                    continue
                }
                if (-not $bootSkipNoted) {
                    Say ("aztBootState still 0 after {0}s -- treating the boot sequence as absent" -f $BootWaitSeconds) Yellow
                    $bootSkipNoted = $true
                }
            } elseif ($bootNoted -and -not $bootDoneNoted) {
                Say 'visor boot finished -- the staging buffer is ours' Green; $bootDoneNoted = $true
            }
            if ($bs -eq 2 -and $bootNoted) { $bootNoted = $false; $bootDoneNoted = $false; $bootShownNoted = $false }   # (a re-boot after a load is noted again)
            Write-BootNotes
        }

        # WAIT FIRST, THEN READ THE CAMERA. Ordering is latency.
        #
        # This used to read the camera, render, and only then wait for the guest to release
        # the buffer -- so the pose on screen was already stale by the render time plus the
        # whole wait, and the result felt like mouse lag that the frame rate did not explain.
        # Waiting first means the camera is sampled as late as possible before the one frame
        # the guest is about to take, which is the freshest it can be.
        $tmTop += $topClock.Elapsed.TotalMilliseconds
        $earlyArmed = $false
        if ($suppressed) {
            $wait = [Diagnostics.Stopwatch]::StartNew()
            $syncLimit = $(if ($script:visorMenu -and ($script:visorMenu.Writing -or $script:visorMenu.ReadPlaying)) { 30 } else { $SyncTimeoutMs })     # (a save's / load's stall: repaint the panel often)
            # (in C#: HostView.WaitClear polls with a 0.4 ms high-resolution timer -- a sleep, NEVER a spin: DOSBox emulates on
            # one thread. The script loop slept 1 ms a poll, ~2 ms in practice: 2026-10-13 performance audit)
            $released = $hv.WaitClear($hlReady, $syncLimit)
            if (-not $released) { $syncTimeouts++ }
            if (-not $script:waitTimerSaid -and $wait.ElapsedMilliseconds -gt 0) { $script:waitTimerSaid = $true; Say ("frame hand-shake: waits use {0}" -f $(if ($hv.FineTimer) { 'the high-resolution waitable timer (0.4 ms polls)' } else { '1 ms sleeps (no high-resolution timer on this Windows)' })) DarkGray }
            # NEVER write the buffer the guest is still reading -- see the handshake note below.
            $tmWait += $wait.Elapsed.TotalMilliseconds
            if (-not $released) { Repaint-HeldPicture; continue }
            $fresh = $hv.ReadBytes($hlCamRec, 320)
            if ($fresh) {
                for ($i = 0; $i -lt 16; $i++) { $m[$i] = [BitConverter]::ToSingle($fresh, $REC_MOVWORLD + $i*4) }
                if ($m[12] -eq 0 -and $m[13] -eq 0 -and $m[14] -eq 0 -and $m[0] -eq 1) { continue }
            }
            if ($script:snapOn) { $hv.SnapTake() }      # (the guest's words as fresh as the camera: ammo, health, menus, the cue)
            # ---- THE EARLY HAND-SHAKE (2026-10-13 performance audit) ---------------------------------------------------------
            # In steady true colour (aztInjSync 0: the game is handed the unchanging key frame) the guest copies the staging buffer
            # EVERY frame whatever `ready` says, and clears it after each copy (AztInjBody, src\Build-AztMod.ps1) -- so `ready`
            # is only the pacing baton there. Armed HERE, beside the camera read, instead of at the end of the frame, the guest
            # clears it during the host's ~14 ms of work and the next wait is a single read. The pacing still holds: a host
            # faster than the guest still waits for it. 8-bit pictures and the calibration patch (sync 1: a gated copy that
            # must never see a half-written buffer) keep the end-of-frame order below, and a frame that turns out to need
            # sync 1 waits for this early `ready` to be consumed before it writes anything.
            if ($fresh -and $script:injSync -eq 0 -and $script:tcOn -and $script:tcState -eq 'run' -and -not $NoReady -and -not $NoEarlyReady -and -not $NoPush -and $PushEvery -le 1) {
                [void]$hv.WriteU32($hlReady, 1); $earlyArmed = $true
            }
        }

        # ---- re-pose from the LIVE scene graph ----------------------------------
        # Without this the room is drawn exactly as the .XAF stored it: doors shut, items
        # that have been picked up still present, nothing the engine animates ever moving.
        if ($pose -and -not $NoPose -and ((-not $NoSmooth) -or $sincePose.Elapsed.TotalSeconds -ge (1.0 / $PoseHz))) {
            $pt = [Diagnostics.Stopwatch]::StartNew()
            $live = $null
            # ONE CALL: walk, name table and (below) the posing itself are all in C# now.
            # See SceneGraph.WalkLive for why -- the script version cost 2.8 ms a walk, which
            # is what held characters to 10 poses a second in a 130 fps picture.
            #
            # AND IT MUST BE ONE MOMENT OF THE SCENE, not a blend of two guest frames -- see
            # WalkLiveStable. A walk that cannot be confirmed is skipped: the parts keep the
            # pose they have, which is a frame stale and never torn.
            $walkTries = 0
            # WALK FROM THE TOP OF THE SCENE AS IT IS NOW, not as it was when the room was
            # detected. The top is found by climbing from the camera, and it used to be found
            # ONCE, at the moment a new room was noticed -- which can be part-way through the
            # load, while the camera hangs off the OLD scene, already unhooked and about to be
            # freed. Every walk after that read the previous room's dead frames out of memory
            # nobody had reused yet: bit-identical each time, so the two-walk check passed.
            # MEASURED 2026-10-05 09:50, corridor <-> spa several times: the game's own scene
            # was complete (45 of 45 spa objects) while this loop reported "13 moved, 14
            # hidden" for a minute -- the 13 being spa parts that share a NAME with something
            # in the corridor (tunnel02..05, Object01..03, entcori, view) and were posed with
            # the corridor's matrices, the 14 simply not found. Rooms "falling apart".
            # Climbing is five reads; do it every time, and start the smoother afresh if the
            # top has changed.
            if ($sincePose.Elapsed.TotalSeconds -ge (1.0 / $PoseHz)) {
                $rootSeen = [AztTool.SceneGraph]::RootOf($g.ProcessId, [long]$g.MemBase, $camObj)
                if ($rootSeen -ge 0x1000 -and $rootSeen -ne $sceneRoot) {
                    Say ("  scene top moved 0x{0:X} -> 0x{1:X}: walking the new one" -f $sceneRoot, $rootSeen) Cyan
                    $sceneRoot = $rootSeen; $smooth.Reset(); [AztTool.SceneGraph]::ForgetNames()
                }
            }
            if ($NoSmooth) {
                $sincePose.Restart()
                $live = [AztTool.SceneGraph]::WalkLiveStable($g.ProcessId, [long]$g.MemBase, $sceneRoot, 800, 4, [ref]$walkTries)
                if ($walkTries -eq 0) { $walkTorn++ } elseif ($walkTries -gt 2) { $walkRetried++ }
                $poseWalks++
            } else {
                # SAMPLE WHEN DUE, DRAW EVERY FRAME. The walk feeds the smoother whenever a
                # confirmed one is available; what is drawn is the smoother's answer for THIS
                # instant, so a creature keeps gliding through the frames in between the game's
                # 18 Hz steps -- and through a walk that had to be abandoned as torn.
                $nowMs = [Diagnostics.Stopwatch]::GetTimestamp() * 1000.0 / [Diagnostics.Stopwatch]::Frequency
                if ($sincePose.Elapsed.TotalSeconds -ge (1.0 / $PoseHz)) {
                    $sincePose.Restart()
                    $tree = [AztTool.SceneGraph]::WalkTreeStable($g.ProcessId, [long]$g.MemBase, $sceneRoot, 800, 4, [ref]$walkTries)
                    if ($walkTries -eq 0) { $walkTorn++ } elseif ($walkTries -gt 2) { $walkRetried++ }
                    if ($tree) { $smooth.Sample($tree, $nowMs) }
                    $poseWalks++
                }
                if ($smooth.HasTree) { $live = $smooth.Evaluate($nowMs) }
            }
            if ($live -and $live.Count) {
                # WHO IS IN THE ROOM. Checked once a second from the walk already in hand: a
                # character can arrive or be removed while the player stands still, and the
                # room has to be rebuilt with (or without) its geometry when that happens.
                if (-not $NoCharacters -and $charClock.ElapsedMilliseconds -ge 1000) {
                    $charClock.Restart()
                    try {
                        $chars = @(Get-LiveCharacters @($live.Keys) ($loadedNames -split '\+'))
                        $sig = Get-CharacterSig $chars
                        if ($sig -ne $loadedCharSig) {
                            $loadedCharSig = $sig
                            foreach ($c in $chars) { Say ("  character {0} -> {1}.XAF ({2} of {3} frames matched)" -f $c.Prefix, $c.Xaf, $c.Hits, $c.Of) Cyan }
                            if (-not $chars.Count) { Say '  no characters in the scene now' Cyan }
                            $room = Get-RoomBusy ($loadedNames -split '\+') $chars
                            # (during a load the characters' textures too go to the card before the first frame, under its cover)
                            if ($script:gpu -and $script:gpuOn -and -not $SlowRaster -and (Test-LoadUi)) { try { Send-RoomTextures $room $null } catch { Say ("  character textures to the card failed: {0}" -f $_.Exception.Message) Yellow } }
                            $curChars = $chars
                            $pose = New-PoseState $room
                            # a ghost among them (the room's "ghost" block): her textures, and where her wisps come from
                            if ($script:gpu) { Set-RoomGhosts $script:gpu $room; if ($script:fx -and $script:fx.GhostRate -gt 0) { $script:fx.SetGhostSources($script:ghostWispVerts) } }
                            if ($script:gpu) { Set-RoomMaterials $script:gpu $atmNow $room; Set-GpuRepair $script:gpu $atmNow $room }      # (what the characters wear: their materials too; the repair for the new triangle list)
                            Say ("  {0:N0} triangles with characters, {1} parts" -f ($room.T.Count/3), $room.Parts.Count)
                            # the picture quads moved with the rebuild; find them again
                            $portals = Get-RoomPortals $room ($loadedNames -split '\+')
                        }
                    } catch {
                        $msg = $_.Exception.Message
                        if ($msg -ne $lastCharErr) { $lastCharErr = $msg; Say ("character load failed: {0}" -f $msg) Yellow }
                    }
                }
                Update-Pose $room $pose $live ([bool]$NoSmooth)
                if ($CharProbe -and $suppressed -and $loadedCharSig -and $probeClock.Elapsed.TotalSeconds -ge $CharProbeSeconds) {
                    $probeClock.Restart()
                    try { Invoke-MeshProbe $sceneRoot $room $pose } catch { Say ("mesh probe failed: {0}" -f $_.Exception.Message) Yellow }
                    try { Invoke-CharProbe $sceneRoot ([ref]$suppressed) } catch { Say ("char probe failed: {0}" -f $_.Exception.Message) Yellow }
                }
            }
            $poseMs += $pt.Elapsed.TotalMilliseconds
        }
        if ($HiTexKey -gt 0 -and $TexScale -gt 1) {
            $hk = [AztTool.Keys]::DownInProcess($HiTexKey, $g.ProcessId)
            if ($hk -and -not $hiKeyWas) { $hiTexOn = -not $hiTexOn; Say ("textures: {0}" -f $(if ($hiTexOn) { "ENLARGED x$TexScale" } else { 'ORIGINAL' })) Cyan }
            $hiKeyWas = $hk
        }
        $texNow = $(if ($hiTexOn -and $room.TexesHi) { $room.TexesHi } else { $room.Texes })
        if ($RgbKey -gt 0 -and $script:tcOn -and -not $NoRgb) {
            $rk = [AztTool.Keys]::DownInProcess($RgbKey, $g.ProcessId)
            # F8 IS "ORIGINAL TEXTURES": the game's own 256-colour art, unfiltered and unsmoothed,
            # for a player who wants it as it was -- the picture's size, the lamp and the shadows
            # stay. (Like F4 for the music.) Back again, the true-colour picture returns.
            if ($rk -and -not $rgbKeyWas) {
                if ($r.Rgb) { $r.Rgb = $false; $r.Filter = $false } else { $r.EnableRgb() }
                Say ("picture: {0}" -f $(if ($r.Rgb) { 'TRUE COLOUR' } else { 'ORIGINAL TEXTURES (256 colours, unfiltered)' })) Cyan
            }
            $rgbKeyWas = $rk
        }
        # F9: the room drawn by the graphics card or the processor
        if ($script:gpu -and $GpuKey -gt 0) {
            $gk = [AztTool.Keys]::DownInProcess($GpuKey, $g.ProcessId)
            if ($gk -and -not $gpuKeyWas) {
                $script:gpuOn = -not $script:gpuOn
                Say ("room drawn by: {0}" -f $(if ($script:gpuOn) { 'the GRAPHICS CARD' } else { 'the PROCESSOR' })) Cyan
            }
            $gpuKeyWas = $gk
        }
        # F6: the materials' shine off and on (Set-RoomMaterials), for comparing on the same wall
        if ($script:gpu -and $ShineKey -gt 0) {
            $sk = [AztTool.Keys]::DownInProcess($ShineKey, $g.ProcessId)
            if ($sk -and -not $shineKeyWas) { $script:gpu.ShineOn = -not $script:gpu.ShineOn; Say ("materials' shine {0}" -f $(if ($script:gpu.ShineOn) { 'ON' } else { 'OFF' })) Cyan; Show-ToggleNote ('SURFACE SHINE: {0}' -f $(if ($script:gpu.ShineOn) { 'ON' } else { 'OFF' })) }
            $shineKeyWas = $sk
        }
        # F5: the wet surfaces off and on (Set-GpuWet)
        if ($script:gpu -and $WetKey -gt 0) {
            $wk = [AztTool.Keys]::DownInProcess($WetKey, $g.ProcessId)
            if ($wk -and -not $wetKeyWas) { $script:gpu.WetOn = -not $script:gpu.WetOn; Say ("wet surfaces {0}" -f $(if ($script:gpu.WetOn) { 'ON' } else { 'OFF' })) Cyan; Show-ToggleNote ('WET SURFACES: {0}' -f $(if ($script:gpu.WetOn) { 'ON' } else { 'OFF' })) }
            $wetKeyWas = $wk
        }
        # F7 in the true-colour picture: the relief (normal mapping) and micro relief off and on (in the 8-bit one F7 is the
        # texture filtering, below)
        if ($script:gpu -and $ReliefKey -gt 0 -and $script:tcOn) {
            $rlk = [AztTool.Keys]::DownInProcess($ReliefKey, $g.ProcessId)
            if ($rlk -and -not $reliefKeyWas) { $script:gpu.ReliefOn = -not $script:gpu.ReliefOn; Say ("relief (normal mapping) and parallax depth {0}" -f $(if ($script:gpu.ReliefOn) { 'ON' } else { 'OFF' })) Cyan; Show-ToggleNote ('RELIEF + DEPTH: {0}' -f $(if ($script:gpu.ReliefOn) { 'ON' } else { 'OFF' })) }
            $reliefKeyWas = $rlk
        }
        # F11: the texture repair (re-laid faces, mixed repeats) off and on (Set-GpuRepair)
        if ($script:gpu -and $RepairKey -gt 0) {
            $rpk = [AztTool.Keys]::DownInProcess($RepairKey, $g.ProcessId)
            if ($rpk -and -not $repairKeyWas) { $script:gpu.RelayOn = -not $script:gpu.RelayOn; Say ("texture repair {0}" -f $(if ($script:gpu.RelayOn) { 'ON' } else { 'OFF' })) Cyan; Show-ToggleNote ('TEXTURE REPAIR: {0}' -f $(if ($script:gpu.RelayOn) { 'ON' } else { 'OFF' })) }
            $repairKeyWas = $rpk
        }
        # F7 (texture filtering) belongs to the 8-bit renderer; in a true-colour session F8 decides
        if ($FilterKey -gt 0 -and -not $script:tcOn) {
            $fk = [AztTool.Keys]::DownInProcess($FilterKey, $g.ProcessId)
            if ($fk -and -not $filterKeyWas) { $r.Filter = -not $r.Filter; Say ("texture filtering {0}" -f $(if ($r.Filter) { 'ON' } else { 'OFF' })) Cyan }
            $filterKeyWas = $fk
        }
        # (in true colour F7 compared relief looks while they were being chosen, 2026-10-07; Josh picked one and it is
        # now the only one, so F7 does nothing there)
        $t0 = [Diagnostics.Stopwatch]::StartNew()
        # THE RAPTOR GETS UP (a new game's reveal, BootHd.TiltCamera): the view, the helmet lamp and its shadows turn as he
        # stands -- this frame's copy of the game's camera, read fresh every loop; the game's own camera is untouched, and
        # the position checks above have already used the untilted one
        try { Step-EyeSmooth $m } catch { }      # (the view's height eased between the game's 18 Hz steps; a landing's dip)
        if ($script:bootHd) { try { if ($script:bootHd.TiltCamera($m) -and -not $script:standSaid) { $script:standSaid = $true; Say 'visor boot: the raptor gets up (the view tilts, dust falls off the visor), then the weapon systems come online' DarkCyan } } catch { } }
        $script:lastCamM = $m
        if ($script:mapFreezeCam) { [Array]::Copy([single[]]$script:mapFreezeCam, $m, 16) }      # (THE 3D MAP: the world behind it held still)
        $r.SetCameraWorld($m)
        # THE BEAM TRAILS THE VIEW. It is kept as a direction in the WORLD and eased toward
        # where the player is looking, so on a turn it lags behind for a moment and then
        # settles -- the lamp is on a head, not painted on the glass. Where that direction
        # falls on the screen is the beam's centre (its x, y, z in the camera's own axes:
        # rows 0, 1, 2 of the camera matrix are right, up and forward).
        # THE MUZZLE FLASH: up in ~12 ms, gone in ~0.2 s
        $flashLive = $false
        if (-not $NoMuzzleFlash -and $script:gpu) {
            $am = $(if ($script:snapOn) { $hv.SnapU32(0x14694C) } else { RdU32 $ammoAddr }) -band 0xFFFF      # (the frame's snapshot, taken beside the camera)
            if ($ammoWas -ge 0 -and $am -lt $ammoWas -and ($ammoWas - $am) -le 3) {
                $flashClock.Restart(); $shots++; $script:shotPending = $true      # (its impact: found once the room is posed this frame -- below)
                if ($shots -le 6 -or ($shots % 25) -eq 0) {
                    # what the game's sound player (0x100BC) looks at: it is silent while [0x1525A0] or [0x152B1C] is set,
                    # and plays at the volume word [0x14693E] (0..127); [0x14693C] is the effects on/off word beside it
                    $vw = RdU32 (& $shotAt 0x14693C)
                    Say ("shot {0}: ammo {1} -> {2}; effects volume {3}/127, on-word {4}, pause {5}, conversation {6}, weapon {7}" -f $shots, $ammoWas, $am, (($vw -shr 16) -band 0xFFFF), ($vw -band 0xFFFF), ((RdU32 (& $shotAt 0x1525A0)) -band 0xFFFF), ((RdU32 (& $shotAt 0x152B1C)) -band 0xFFFF), ((RdU32 (& $shotAt 0x14721C)) -band 0xFFFF)) DarkYellow
                }
            }
            $ammoWas = $am
            if ($flashClock.IsRunning) {
                $fs = $flashClock.Elapsed.TotalSeconds
                if ($fs -gt 0.25) { $flashClock.Reset(); $script:gpu.Flash = 0 }
                else { $script:gpu.Flash = [single]($FlashPower * [Math]::Min(1.0, $fs / 0.012) * [Math]::Exp(-[Math]::Max(0.0, $fs - 0.012) / 0.05)); $flashLive = $true }
            } else { $script:gpu.Flash = 0 }
            $script:gpu.FlashRange = [single]$FlashRange
        }
        # THE DAMAGE BADGE (Josh, 2026-10-10): health falling = a hit -> "Damage taken!" in the visor's lower left. Not while
        # a boot covers the view or the memory core is up, nor for 3 s after either or after the player object changes:
        # a load sets the health, it is not a hit.
        if ((-not $NoDamageBadge -or -not $NoVisorDamage) -and $script:ov) {
            $hpObj = [uint32]$(if ($script:snapOn) { $hv.SnapU32(0x1841C8) } else { RdU32 $hpPtrAt }); $hp = $null      # (the pointer from the snapshot; the health behind it read through, every time)
            if ($hpObj -ge 0x1000 -and $hpObj -lt 0x10000000) { $hp = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32](RdU32 ([long]$g.MemBase + $hpObj + 0x16))), 0) }
            # (a sane reading only: full is 1,000 in 16.16 -- a read of a half-built player during a load once set the "full" mark
            # far above it, and a living player at 1,000 then read as nothing: the flat line, the glass at its worst)
            if ($null -ne $hp -and ($hp -gt 1500 * 65536 -or $hp -lt -1000 * 65536)) { $hp = $null }
            $booting = ($script:bootHd -and $script:bootHd.Covering)
            if ($booting -or ($script:visorMenu -and $script:visorMenu.AnyPlaying) -or $hpObj -ne $hpObjWas) { $hpQuiet.Restart() }
            # ALIVE FIRST: health 0 counts as a death only after the player has been seen with some since the last boot or
            # player object -- a load from the title read 0 as the view came back, and the monitor flat-lined a live player
            if ($booting -or $hpObj -ne $hpObjWas) { $script:hpAlive = $false }
            if ($null -ne $hp -and $hp -gt 0) { $script:hpAlive = $true }
            $script:hpRaw = $hp
            # the health as a share (full = 1000 in the game's 16.16, or the most it has been seen at), for the damaged visor;
            # not known (-1: clear glass) while a boot covers the view -- a new game's health is not set yet
            if ($null -ne $hp -and $hp -gt $hpMax) { $hpMax = $hp }
            $script:hpFrac = $(if ($null -eq $hp -or $booting -or -not $script:hpAlive) { -1.0 } else { [Math]::Max(0.0, [Math]::Min(1.0, $hp / [double]$hpMax)) })
            # DEAD ONLY WHEN IT STAYS DEAD: at nothing for 0.5 s, and not within 3 s of a load / boot / the memory core (until
            # then a hair above the monitor's line: the glass at its worst, no flat line). A load passes through 0 on its way.
            if ($null -ne $hp -and $hp -le 0) { if (-not $script:hpZeroAt) { $script:hpZeroAt = [Diagnostics.Stopwatch]::StartNew() } } else { $script:hpZeroAt = $null }
            if ($script:hpFrac -ge 0 -and $script:hpFrac -le 0.0005 -and (-not $script:hpZeroAt -or $script:hpZeroAt.Elapsed.TotalSeconds -lt 0.5 -or $hpQuiet.Elapsed.TotalSeconds -lt 3)) { $script:hpFrac = 0.001 }
            if ($null -ne $hp -and $null -ne $hpWas -and $hp -lt $hpWas -and $hpQuiet.Elapsed.TotalSeconds -ge 3) {
                if (-not $NoDamageBadge) { (Get-VisorNote).Damage() }
                if ($script:visorDmg) { $script:visorDmg.Hit([Math]::Min(1.0, 0.45 + 4.0 * ($hpWas - $hp) / [double]$hpMax)) }
                $hits++
                if ($hits -le 5 -or ($hits % 25) -eq 0) { Say ("damage taken ({0}): health {1:N1} -> {2:N1}" -f $hits, ($hpWas / 65536.0), ($hp / 65536.0)) DarkYellow }
            }
            $hpWas = $hp; $hpObjWas = $hpObj
        }
        if ($r.Lamp) {
            # THE SWITCH: one press, one change (the key has to come up before it counts
            # again), and the beam fades over about a seventh of a second rather than cutting.
            if ($LampKey -gt 0) {
                $kd = [AztTool.Keys]::DownInProcess($LampKey, $g.ProcessId)
                if ($kd -and -not $lampKeyWas) { $lampOnNow = -not $lampOnNow; Say ("flashlight {0}" -f $(if ($lampOnNow) { 'ON' } else { 'OFF' })) Cyan; Invoke-LampClick $lampOnNow }
                $lampKeyWas = $kd
            }
            $vp = $script:visorPending
            if ($vp -and $vp.At.Elapsed.TotalSeconds -ge $vp.Delay) {
                $script:visorPending = $null
                if ($script:ov -and -not ($vp.LampOff -and $lampOnNow)) {
                    (Get-VisorNote).Show($vp.Lines, $vp.Hold); Say ("visor readout: {0}" -f ($vp.Lines -join ' / ')) Cyan
                }
            }
            if ($script:visorNote -and $lampOnNow -and $script:visorNote.Playing -and -not ($script:toggleNoteAt -and $script:toggleNoteAt.Elapsed.TotalSeconds -lt 3)) { $script:visorNote.Dismiss() }      # (a switch's own readout stays)
            $fdt = $lampFade.Elapsed.TotalSeconds; $lampFade.Restart()
            $want = $(if ($lampOnNow) { 1.0 } else { 0.0 })
            if ($lampLevel -ne $want) { $stepF = $fdt / 0.14; if ($lampLevel -lt $want) { $lampLevel = [Math]::Min($want, $lampLevel + $stepF) } else { $lampLevel = [Math]::Max($want, $lampLevel - $stepF) } }
            $r.LampPower = [single]($LampPower * $lampLevel)
            $r.LampRoom = [single]$(if ($null -ne $script:volLevel -and $script:gpuOn -and $script:gpu) { $script:volLevel } else { $LampRoomOff + ($LampRoom - $LampRoomOff) * $lampLevel })      # (held in a volumetric-fog room)
            $ldt = $lampClock.Elapsed.TotalSeconds; $lampClock.Restart()
            if ($null -eq $lampDir -or $LampLag -le 0 -or $ldt -gt 0.25) { $lampDir = @([double]$m[8], [double]$m[9], [double]$m[10]) }
            else {
                $lk = 1.0 - [Math]::Exp(-$ldt / $LampLag)
                $lx = $lampDir[0] + ($m[8] - $lampDir[0]) * $lk; $ly = $lampDir[1] + ($m[9] - $lampDir[1]) * $lk; $lz = $lampDir[2] + ($m[10] - $lampDir[2]) * $lk
                $ll = [Math]::Sqrt($lx*$lx + $ly*$ly + $lz*$lz); if ($ll -lt 1e-6) { $lx = $m[8]; $ly = $m[9]; $lz = $m[10]; $ll = 1.0 }
                $lampDir = @(($lx / $ll), ($ly / $ll), ($lz / $ll))
            }
            $bz = $lampDir[0]*$m[8] + $lampDir[1]*$m[9] + $lampDir[2]*$m[10]
            if ($bz -lt 0.94) { $lampDir = @([double]$m[8], [double]$m[9], [double]$m[10]); $bz = 1.0 }     # more than ~20 degrees behind: a snap turn or a teleport
            $bx = $lampDir[0]*$m[0] + $lampDir[1]*$m[1] + $lampDir[2]*$m[2]; $by = $lampDir[0]*$m[4] + $lampDir[1]*$m[5] + $lampDir[2]*$m[6]
            $r.LampCx = [single]($bx / $bz * $r.FocalPixels); $r.LampCy = [single](-$by / $bz * $r.FocalPixels)
        }
        Update-RoomLights $r
        if ($script:giBake -and $script:gpu) { Complete-GpuGi $script:gpu }
        Guard-SaveList
        # THE FAST PATH IS THE DEFAULT. tools\Test-RasterFast.ps1 measured it at 3.4-4.2x
        # the reference with an identical picture AND depth buffer on 160 cameras over four
        # rooms. -SlowRaster draws with the reference instead, for when a picture looks wrong
        # and the first question is whether the optimisation did it.
        if ($pose -and -not $NoPose) { $dv = $pose.PoseV; $dt = $pose.CurTex } else { $dv = $room.V; $dt = $room.TexIdx }
        # DOORWAYS, in two halves round the room's own draw: first take the picture quads that
        # are standing in a doorway out of the room, then (once the room is down, so its depth
        # buffer can say what hides a doorway) draw the neighbouring room through each one.
        $doPortals = ($portals -and $pose -and -not $NoPose -and -not $SlowRaster)
        if ($doPortals) { [void][AztTool.Portals]::Prepare($portals, $dv, $dt, $pose.BaseTex, $pose.Vis) }
        # THE LAMP'S VIEW FIRST: the same geometry, as posed this frame (so creatures and
        # doors cast moving shadows), drawn for depth from a camera with the player's
        # orientation shifted to where the lamp is. Rows 0 and 1 of the camera matrix are its
        # right and up.
        # the graphics card this frame (true colour only; F8's original-textures view stays on the processor)
        $gpuNow = ($script:gpuOn -and $script:gpu -and $r.Rgb -and -not $SlowRaster)
        if ($rs -and $lampLevel -le 0 -and -not $flashLive) { $r.SetShadow($null, 0, 0, 0, 0, 0); $r.SetShadow2($null, 0, 0) }     # lamp off: nothing to cast, and the two lamp views are not drawn
        if ($rs -and ($lampLevel -gt 0 -or $flashLive)) {      # (a muzzle flash needs them too: it is shadowed by them)
            # EACH LAMP STAYS ON THE PLAYER'S SIDE OF THE WALLS. Every face casts, so a lamp
            # that ends up beyond a wall or above a ceiling has the whole room in its shadow.
            # A ray from the eye toward where the lamp wants to be says how far it can go; it
            # stops 4 units short of whatever is there.
            $sides = $(if ($rs2) { @(1.0, -1.0) } else { @(1.0) })
            for ($li = 0; $li -lt $sides.Count; $li++) {
                $ox = $LampOffsetX * $sides[$li]; $oy = $LampOffsetY
                $vx3 = $m[0]*$ox + $m[4]*$oy; $vy3 = $m[1]*$ox + $m[5]*$oy; $vz3 = $m[2]*$ox + $m[6]*$oy
                $vl = [Math]::Sqrt($vx3*$vx3 + $vy3*$vy3 + $vz3*$vz3)
                if ($vl -gt 1) {
                    $reach = [AztTool.Raster]::RayDistance($dv, $room.T, $dt, $m[12], $m[13], $m[14], [single]($vx3/$vl), [single]($vy3/$vl), [single]($vz3/$vl), [single]($vl + 6))
                    $k2 = [Math]::Max(0.1, [Math]::Min(1.0, ($reach - 4.0) / $vl)); $ox *= $k2; $oy *= $k2
                }
                $rz = $(if ($li -eq 0) { $rs } else { $rs2 })
                [Array]::Copy($m, $lampM, 16)
                for ($k = 0; $k -lt 3; $k++) { $lampM[12 + $k] = [single]($m[12 + $k] + $m[$k] * $ox + $m[4 + $k] * $oy) }
                # on the graphics card: its own depth view, from the same camera, drawn in its Draw below
                if ($gpuNow) { $script:gpu.SetLampShadow($li, $lampM, $rz.W, $rz.H, $rz.FocalPixels, [single]$ox, [single]$oy); continue }
                $rz.SetCameraWorld($lampM)
                if ($li -eq 0) { $r.SetShadow($rz.Depth, $rz.W, $rz.H, $rz.FocalPixels, [single]$ox, [single]$oy); $r.SetShadow2($null, 0, 0) }
                else { $r.SetShadow2($rz.Depth, [single]$ox, [single]$oy) }
            }
            # BOTH LAMP VIEWS AT ONCE (they were drawn one after the other).
            # CULLING OFF for a lamp's view: a wall modelled with one side still stops light.
            # The lamps' views need only depth: always the small originals.
            if (-not $gpuNow) { [AztTool.Raster]::DrawDepthPair($rs, $rs2, $dv, $room.UV, $room.T, $dt, $room.Texes, (-not $NoFlipV)) }
            $tmShadow += $t0.Elapsed.TotalMilliseconds
        }
        # THE PLACED LIGHTS' VIEWS, for their shadows: depth from each light, looking the way it faces
        if ($script:roomLights.Count -and $r.Rgb -and $script:lightRs -and $script:lightSet) {
            # (C#: AztTool.RoomLightSet, from where Update-RoomLights left each light this frame -- 2026-10-13 audit)
            if ($gpuNow) { $script:lightSet.CardViews($script:gpu, $LightShadowFace) }      # (all round on the card: no edge where shadows stop)
            else {
                for ($li = 0; $li -lt $script:lightSet.Count; $li++) {
                    $lx0 = [single]0; $ly0 = [single]0; $lz0 = [single]0
                    $lz = $script:lightSet.AimView($li, [ref]$lx0, [ref]$ly0, [ref]$lz0); if (-not $lz) { continue }
                    $lz.FastClear([byte]0)
                    $lz.DrawTexturedFast($dv, $room.UV, $room.T, $dt, $room.Texes, $false, (-not $NoFlipV))
                    $r.SetLightShadow($li, $lz.Depth, $lz.W, $lz.FocalPixels, $lz.LastBasis)
                }
            }
        } elseif ($script:roomLights.Count -and $r.Rgb -and $script:lightRs) {
            for ($li = 0; $li -lt $script:roomLights.Count; $li++) {
                $lz = $script:lightRs[$li]; if (-not $lz) { continue }
                $l = $script:roomLights[$li]; $d = $l.Dir
                $upAx = $(if ([Math]::Abs($d[1]) -gt 0.9) { 0 } else { 1 })     # a light facing straight up or down: lean on x instead
                $dlx = [single]($l.X + $l.Jx); $dly = [single]($l.Y + $l.Jy); $dlz = [single]($l.Z + $l.Jz)      # (where it is this frame: it dances)
                $lz.LookAt($dlx, $dly, $dlz, [single]($dlx + $d[0] * 100), [single]($dly + $d[1] * 100), [single]($dlz + $d[2] * 100), $upAx)
                if ($gpuNow) { $script:gpu.SetLightCube($li, $dlx, $dly, $dlz, $LightShadowFace); continue }      # (all round on the card: no edge where shadows stop)
                $lz.FastClear([byte]0)
                $lz.DrawTexturedFast($dv, $room.UV, $room.T, $dt, $room.Texes, $false, (-not $NoFlipV))
                $r.SetLightShadow($li, $lz.Depth, $lz.W, $lz.FocalPixels, $lz.LastBasis)
            }
        }
        # THE PLAYER'S BODY, for those lights only: stood on the floor under the eye, walking when the eye moves
        if ($gpuNow -and $script:body -and $script:roomLights.Count -and $script:lightRs) {
            $bdt = $script:bodyClock.Elapsed.TotalSeconds; $script:bodyClock.Restart()
            $bfd = [AztTool.Raster]::RayDistance($dv, $room.T, $dt, $m[12], $m[13], $m[14], 0, -1, 0, 400)
            if ($bfd -gt 4 -and $bfd -lt 400) {
                # (a JUMP lifts it by the eye's height over where it stood; a CROUCH shortens it by the crouch's share of its height)
                if ($script:jumpAir) { $blift = [Math]::Max(0.0, $bfd - $script:bodyStand) } else { $script:bodyStand = $bfd; $blift = 0.0 }
                $script:bodyLift += ($blift - $script:bodyLift) * [Math]::Min(1.0, $bdt * 30)
                $bce = $script:crouchC * $script:crouchC * (3 - 2 * $script:crouchC)
                $script:body.BodyLift = $script:bodyLift; $script:body.BodySquash = $CrouchDrop * $bce / 48.0
                $bn = $script:body.StepBody('PLAYER', $m, $bfd, $bdt, $script:bodyBuf)
                if ($bn -gt 0) { $script:gpu.SetCasters($script:bodyBuf, $bn) }
            }
        }
        $mkA = $t0.Elapsed.TotalMilliseconds      # everything before the room: lamp + torch views, script
        if ($gpuNow) { }        # drawn by the card below, once the water and the dust are handed to it
        elseif ($SlowRaster) {
            $r.Clear([byte]0)
            $r.DrawTextured($dv, $room.UV, $room.T, $dt, $texNow, (-not $NoCull), (-not $NoFlipV))
        } else {
            $r.FastClear([byte]0)
            $r.DrawTexturedFast($dv, $room.UV, $room.T, $dt, $texNow, (-not $NoCull), (-not $NoFlipV))
        }
        if ($doPortals -and -not $gpuNow) { $portalPx += [AztTool.Portals]::Draw($r, $portals, $dv, (-not $NoCull), (-not $NoFlipV)); $portalFrames++ }
        $mkB = $t0.Elapsed.TotalMilliseconds      # the room is down
        # WATER LAST: mark where each pool shows, then the room again upside down through it.
        # Skipped when the eye is at or below the surface, and for a pool the scene has removed.
        if ($room.WaterGroups -and $room.WaterGroups.Count -and -not $SlowRaster) {
            foreach ($gr in $room.WaterGroups) {
                $wpx = 0; $wySum = 0.0; $wyN = 0
                if ($gpuNow) { $wTris = New-Object 'System.Collections.Generic.List[int]' } else { $r.BeginPortals() }
                foreach ($wt in $gr.Parts) {
                    if ($pose -and -not $NoPose -and -not $pose.Vis[$wt.Part]) { continue }
                    $wyP = $dv[$wt.VFirst * 3 + 1]
                    if ($m[13] -le $wyP + 1) { continue }
                    if ($gpuNow) { $wTris.AddRange([int[]]$wt.TriVerts) } else { $wpx += $r.AddPortal($dv, $wt.TriVerts, [byte]250, $true) }
                    $wySum += $wyP; $wyN++
                }
                if ($wyN -eq 0) { continue }
                # on the graphics card: the pool's triangles and its height, for its Draw below
                if ($gpuNow) { $script:gpu.WaterKeep = [single]$WaterKeep; $script:gpu.WaterDim = [single]$WaterDim; $script:gpu.AddWater($wTris.ToArray(), [single]($wySum / $wyN)); continue }
                if ($wpx -le 0) { continue }
                $r.EndPortals($true)
                if (-not $mirV -or $mirV.Length -ne $dv.Length) { $mirV = New-Object single[] $dv.Length }
                [AztTool.Raster]::Mirror($dv, $mirV, [single]($wySum / $wyN))
                $r.MaskBeyond = $true; $r.MaskKeep = [single]$WaterKeep; $r.MaskDim = [single]$WaterDim
                $r.DrawTexturedMasked($mirV, $room.UV, $room.TSwap, $dt, $texNow, (-not $NoCull), (-not $NoFlipV), [byte]250)
                $r.MaskBeyond = $false; $r.MaskKeep = [single]0; $r.MaskDim = [single]1
            }
        }
        $mkC = $t0.Elapsed.TotalMilliseconds      # water done
        # DUST, after everything solid: drifts in the space round the player, drawn in front of
        # the depth buffer and lit by the lamp's beam
        if ($script:motes -and $r.Rgb) {
            $mdt = [single]$motesClock.Elapsed.TotalSeconds; $motesClock.Restart(); if ($mdt -gt 0.25) { $mdt = [single]0.25 }
            $script:motes.Update($mdt, $m[12], $m[13], $m[14])
            # grey-brown specks with the flashlight off, lit dust in its beam; follows the lamp's fade
            $script:motes.LampLevel = [single]$(if ($r.Lamp) { $lampLevel } else { 0.0 })
            if ($gpuNow) {
                # on the graphics card: each mote worked out here, drawn there
                if (-not $script:moteBuf -or $script:moteBuf.Length -lt $script:motes.Count * 6) { $script:moteBuf = New-Object single[] ($script:motes.Count * 6) }
                $nMotes = $script:motes.Gather($r, $script:moteBuf)
                $script:gpu.SetMotes($script:moteBuf, $nMotes, $script:motes.Color, $script:motes.ColorDark)
            } else { [void]$script:motes.Draw($r) }
        }
        # THE GRAPHICS CARD draws the whole picture here, now that it has been handed the lamp's and
        # the lights' views, the water and the dust (all used up by its Draw)
        $cardMs = 0.0; $script:gpuFrame = $false
        # Space: the jump (card or processor drawing alike; not -Retro, where Space is the stock weapon key)
        if ($script:jumpOn -and -not $script:jumpOff) { try { Step-Jump $m $dv $room $dt } catch { Say ("jump failed: {0} -- off" -f $_.Exception.Message) Yellow; $script:jumpOff = $true } }
        if (-not $script:crouchOff) { try { Step-Crouch $m $dv $room $dt } catch { Say ("crouch failed: {0} -- off" -f $_.Exception.Message) Yellow; $script:crouchOff = $true; Reset-Crouch } }
        if ($gpuNow) {
            $mkG = $t0.Elapsed.TotalMilliseconds
            try {
                # the card's own atmosphere: particles moved on, the mist laid on the floor under the player
                if (-not $script:fxStep) { $script:fxStep = [Diagnostics.Stopwatch]::StartNew(); $script:fxClock = [Diagnostics.Stopwatch]::StartNew() }
                $fxDt = [single]$script:fxStep.Elapsed.TotalSeconds; $script:fxStep.Restart(); if ($fxDt -gt 0.1) { $fxDt = [single]0.1 }
                $script:gpu.Time = [single]$script:fxClock.Elapsed.TotalSeconds
                if (-not $NoFootsteps -and -not $script:stepsOff) { try { Step-Footsteps $fxDt $m $dv $room $dt $room.Texes } catch { Say ("footsteps failed: {0} -- off" -f $_.Exception.Message) Yellow; $script:stepsOff = $true } }      # (the player's footsteps: BootHd.cs Footsteps)
                if ($script:fx) {
                    $script:fx.Update($fxDt, $m[12], $m[13], $m[14], $dv, $room.T, $dt)
            if (-not $script:dropBuf) { $script:dropBuf = New-Object single[] 64 }; $script:gpu.SetDrops($script:dropBuf, $script:fx.GatherDrops($script:dropBuf))      # (rings where drips land on water)
                    if (-not $script:fxBuf -or $script:fxBuf.Length -lt $script:fx.MaxParticles * [AztTool.Particles]::Stride) { $script:fxBuf = New-Object single[] ($script:fx.MaxParticles * [AztTool.Particles]::Stride) }
                    # SHOT IMPACTS (Josh, 2026-10-14): where this frame's shot landed -- the ray through the cursor (in combat the
                    # pointer is the crosshair) against the room as drawn: sparks and a puff of dust off the surface, a brief warm
                    # glow on it and a scorch mark that fades (GpuRaster.AddScorch); none on a creature (it moves; the game bleeds
                    # it); a room's "impacts": false = none
                    if ($script:shotPending) {
                        $script:shotPending = $false
                        if (-not $NoImpacts -and -not ($script:roomAtmNow -and $script:roomAtmNow.Impacts -is [bool] -and -not $script:roomAtmNow.Impacts)) {
                            try {
                                $cb = $(if ($script:snapOn) { $hv.SnapBytes(0x182D6C, 4) } else { Read-AztGuest $g 0x182D6C 4 -Obj2 })
                                if ($cb) {
                                    $ipx = [int][BitConverter]::ToInt16([byte[]]$cb, 0) - [int]$man.view.injX; $ipy = [int][BitConverter]::ToInt16([byte[]]$cb, 2) - [int]$man.view.injY
                                    if ($ipx -ge 0 -and $ipy -ge 0 -and $ipx -lt $W -and $ipy -lt $H) {
                                        # (the VIEW's rows, not the picture's: under the widescreen panel the picture runs on below the view -- Raster.ViewRows --
                                        # so scaling by the whole height put the shot below the reticle; Josh, 2026-10-14: 'centered in the viewport but does not
                                        # accommodate the UI ... needs to be perfectly in line with the reticule')
                                        $vrI = [double]$(if ($r.ViewRows -gt 0) { $r.ViewRows } else { $r.H })
                                        $gwI = $vrI * $W / [double]$H; $gxI = ($r.W - $gwI) / 2
                                        $hx = 0.0; $hy = 0.0; $hz = 0.0; $nx = 0.0; $ny = 0.0; $nz = 0.0
                                        $ht = $r.PickHit($dv, [int[]]$room.T, $dt, [single]($gxI + ($ipx + 0.5) * $gwI / $W), [single](($ipy + 0.5) * $vrI / $H), [single]3000, [ref]$hx, [ref]$hy, [ref]$hz, [ref]$nx, [ref]$ny, [ref]$nz)
                                        $onChar = $false; if ($ht -ge 0 -and $room.TriPart) { $hpI = $room.TriPart[$ht]; if ($hpI -ge 0 -and $room.Parts[$hpI].IsCharacter) { $onChar = $true } }
                                        if ($ht -ge 0 -and -not $onChar) {
                                            $script:fx.Impact([single]$hx, [single]$hy, [single]$hz, [single]$nx, [single]$ny, [single]$nz, [single]1)
                                            $script:gpu.AddScorch([single]$hx, [single]$hy, [single]$hz, [single]$nx, [single]$ny, [single]$nz, [single]4.5)
                                            $script:impactClock = [Diagnostics.Stopwatch]::StartNew()
                                            if ($shots -le 3) { Say ("  impact: {0:N0} {1:N0} {2:N0} on {3}" -f $hx, $hy, $hz, $(if ($room.TriPart -and $room.TriPart[$ht] -ge 0) { $room.Parts[$room.TriPart[$ht]].Name } else { '?' })) DarkYellow }
                                        }
                                    }
                                }
                            } catch { Say ("shot impact failed: {0}" -f $_.Exception.Message) Yellow }
                        }
                    }
                    if (-not $script:echoOff) { try { Step-Echo $script:gpu $room $dv $dt } catch { Say ("echo scan failed: {0} -- off" -f $_.Exception.Message) Yellow; $script:echoOff = $true; $script:gpu.EchoT = -1 } }      # (the visor's echo scan: V)
                    if ($script:impactClock) { $it = $script:impactClock.Elapsed.TotalSeconds; if ($it -gt 0.35) { $script:impactClock = $null; $script:gpu.ImpactK = 0 } else { $script:gpu.ImpactK = [single]([Math]::Min(1.0, $it / 0.01) * [Math]::Exp(-[Math]::Max(0.0, $it - 0.01) / 0.07)) } }
                    $nPart = $script:fx.Gather($r, $script:fxBuf)
                    if ($script:eyeShine) { try { $nPart = $script:eyeShine.Append($dv, $r, [single]$(if ($r.Lamp) { [Math]::Min(1.0, $r.LampPower / [Math]::Max(0.01, $LampPower)) } else { 0 }), $script:fxBuf, $nPart) } catch { Say ("eye shine failed: {0} -- off" -f $_.Exception.Message) Yellow; $script:eyeShine = $null } }      # (eye shine: glints after the particles)
                    $script:gpu.SetParticles($script:fxBuf, $nPart)
                    $script:gpu.MistFloorY = [single]$script:fx.FloorY
                } elseif ($script:gpu.MistOn) {
                    $fdn = [AztTool.Raster]::RayDistance($dv, $room.T, $dt, $m[12], $m[13], $m[14], 0, -1, 0, 400)
                    $script:gpu.MistFloorY = [single]$(if ($fdn -lt 400) { $m[13] - $fdn } else { $m[13] - 45 })
                }
                $script:gpu.SetCameraWorld($m)
                $script:gpu.CopyLighting($r)          # the lamp's fade and aim, the torch's flicker, the room's fog: as set on the processor's renderer
                # THE VISOR MATERIALIZES THE ROOM: the boot handing the view over (a new game's boot animation done, or a loaded
                # game straight to play) asks for it too; the room cover's 'ready' already did
                if ($script:bootHd) {
                    $bm = $script:bootHd.Mode
                    if ($bm -eq 'done' -and $script:bootModeWas -eq 'reveal' -and -not $script:loadGuard) { $script:matPending = 'the new game''s boot animation is done' }
                    # a NEW game boots with the flashlight off (-LampStartsOn: as it was)
                    if ($bm -eq 'live' -and $script:bootModeWas -ne 'live' -and -not $script:bootHd.IsReboot -and -not $LampStartsOn -and $lampOnNow) { $lampOnNow = $false; Say 'flashlight off for the new game (F turns it on)' Cyan }
                    if ($bm -eq 'live' -and $script:bootModeWas -ne 'live' -and -not $script:bootHd.IsReboot) { Clear-MapVisited }      # (a new game: nothing visited yet)
                    $script:bootModeWas = $bm
                }
                if ($script:matPending -and -not $script:loadGuard) { if (-not $NoMaterialize) { $script:gpu.StartMaterialize(); Say ("visor: materializing the room ({0})" -f $script:matPending) DarkCyan }; $script:matPending = $null }
                $script:gpu.Draw($dv, $room.UV, $room.T, $dt, $texNow, (-not $NoCull), (-not $NoFlipV))
                if ($script:gpu.GhostError -and $script:gpu.GhostError -ne $script:ghostErrSaid) { $script:ghostErrSaid = $script:gpu.GhostError; Say ("ghost: the card could not draw her as smoke ({0}) -- solid again" -f $script:gpu.GhostError) Yellow }
                if ($script:gpu.LastGhostDrawn -and -not $script:ghostSeen) { $script:ghostSeen = $true; $gb = $script:gpu.GhostBox; Say ("ghost: first seen -- {0} triangles, {1:N0} units tall, at {2:N0} {3:N0} {4:N0}" -f $script:gpu.LastGhostTris, ($gb[4] - $gb[1]), (($gb[0] + $gb[3]) / 2), $gb[1], (($gb[2] + $gb[5]) / 2)) Cyan }
                # PHASE 3: with true colour running (and no edge smoothing, which stays on the
                # processor) the picture stays on the card -- it is sharpened and the game's
                # drawings laid over it there, in Step-TrueColour. Otherwise it comes back here.
                $script:gpuFrame = ($script:tcOn -and $script:tcState -eq 'run' -and $script:ov -and $NoAA)
                if (-not $script:gpuFrame) { $script:gpu.ReadBack($r.Color32) }
            } catch {
                Say ("graphics card failed ({0}) -- back to the processor for this session" -f $_.Exception.Message) Yellow
                $script:gpuOn = $false; $gpuNow = $false; $script:gpuFrame = $false
                $r.FastClear([byte]0); $r.DrawTexturedFast($dv, $room.UV, $room.T, $dt, $texNow, (-not $NoCull), (-not $NoFlipV))
            }
            $cardMs = $t0.Elapsed.TotalMilliseconds - $mkG
        }
        $mkD = $t0.Elapsed.TotalMilliseconds
        $renderMs += $mkD
        $tmPre += $mkA; $tmRoom += ($mkB - $mkA); $tmWater += ($mkC - $mkB); $tmDust += ($mkD - $mkC - $cardMs); $tmCard += $cardMs
        # BEFORE the counter is stamped in, so the saved frame is pure render. Only when the
        # camera has not moved since the last frame -- a moving capture cannot be compared.
        # (not in true colour: the comparison is against the engine's own 8-bit picture at its own size)
        if (($CaptureRef -or $Audit) -and $suppressed -and -not $r.Rgb -and $r.W -eq $W) {
            $still = $true
            if ($refPrevCam) { for ($i = 0; $i -lt 16; $i++) { if ([Math]::Abs($m[$i] - $refPrevCam[$i]) -gt 0.001) { $still = $false; break } } } else { $still = $false }
            $refPrevCam = [single[]]$m.Clone()
            if (-not $still) { $refStill.Restart() }
            if ($refStill.ElapsedMilliseconds -ge 600 -and $refClock.Elapsed.TotalSeconds -ge $(if ($Audit) { $AuditSeconds } else { $CaptureRefSeconds })) {
                $refClock.Restart(); $refStill.Restart()
                try { Say ("ENGINE REFERENCE: {0}" -f (Save-EngineReference $r ([single[]]$m.Clone()) ([ref]$suppressed))) Magenta } catch { Say ("engine reference failed: {0}" -f $_.Exception.Message) Yellow }
            }
        }
        $probeClock2 = [Diagnostics.Stopwatch]::StartNew()
        if ($Probes -and $script:colClock.ElapsedMilliseconds -ge 250) { $script:colClock.Restart(); Write-CollisionWatch '' }
        if ($Probes -and $suppressed -and -not $NoPickProbe) {
            try { Write-PickProbe $r $room $dv $dt $(if ($fresh) { $fresh } else { $rec }) $m } catch { if ($lastPickErr -ne $_.Exception.Message) { $lastPickErr = $_.Exception.Message; Say ("pick probe failed: {0}" -f $lastPickErr) Yellow } }
        }
        $tmProbe += $probeClock2.Elapsed.TotalMilliseconds
        # TRUE COLOUR: smooth the staircase edges, then a light sharpen (see Raster.PostRgb).
        if ($r.Rgb) {
            if ($PostKey -gt 0) {
                $pk = [AztTool.Keys]::DownInProcess($PostKey, $g.ProcessId)
                if ($pk -and -not $postKeyWas) { $postOn = -not $postOn; if ($script:tcPostJob) { $script:tcPostJob.On = $postOn }; Say ("edge smoothing and sharpening {0}" -f $(if ($postOn) { 'ON' } else { 'OFF' })) Cyan }
                $postKeyWas = $pk
            }
            # normally done on the overlay's thread; here only if there is no overlay to do it
            if (-not $script:tcPostJob -and $postOn -and ((-not $NoAA) -or $Sharpen -gt 0)) { $r.PostRgb((-not $NoAA), [single]$Sharpen); $postMs += $r.PostMs; $postN++ }
        }
        if (-not $NoFpsCounter) { Add-FpsCounter $r.Color $totalFrames }
        if ($SaveFrames -gt 0 -and $sinceSave.Elapsed.TotalSeconds -ge $SaveFrames) {
            try {
                $f = Save-HostFrame $r.Color $room.Pal $loadedNames; Say ("saved {0}" -f (Split-Path $f -Leaf)) DarkGray
                # ENOUGH TO DRAW THIS FRAME AGAIN OFFLINE: the camera, and every room object that
                # is not where its file put it (by how far its first vertex has moved).
                Say ("    camera {0}" -f ((@($m) | ForEach-Object { '{0:R}' -f $_ }) -join ' ')) DarkGray
                if ($pose -and -not $NoPose) {
                    $mv = New-Object System.Collections.Generic.List[string]
                    for ($pi5 = 0; $pi5 -lt $room.Parts.Count; $pi5++) {
                        $pp = $room.Parts[$pi5]; if ($pp.IsCharacter -or $pp.VCount -lt 1) { continue }
                        if (-not $pose.Vis[$pi5]) { $mv.Add(('{0} GONE' -f $pp.Name)); continue }
                        $vo = $pp.VFirst * 3
                        $ddx = $pose.PoseV[$vo] - $room.V[$vo]; $ddy = $pose.PoseV[$vo+1] - $room.V[$vo+1]; $ddz = $pose.PoseV[$vo+2] - $room.V[$vo+2]
                        if (([Math]::Abs($ddx) + [Math]::Abs($ddy) + [Math]::Abs($ddz)) -gt 0.5) { $mv.Add(('{0}({1:N0},{2:N0},{3:N0})' -f $pp.Name, $ddx, $ddy, $ddz)) }
                    }
                    Say ("    room objects away from rest: {0}" -f $(if ($mv.Count) { $mv -join ' ' } else { 'none' })) DarkGray
                }
            }
            catch { Say ("could not save a frame: {0}" -f $_.Exception.Message) Yellow }
            $sinceSave.Restart()
        }

        # -NoInject: the frame is rendered and discarded. Never take the viewport, never
        # push, so the guest is untouched while the host load is identical to a real run.
        if ($NoInject) {
            $frames++; $totalFrames++
            if ($sinceReport.Elapsed.TotalSeconds -ge 4) {
                Say ("{0}: rendering {1:N1} fps, NOT injecting, render {2:N1} ms" -f `
                    $loadedNames, ($frames / $sinceReport.Elapsed.TotalSeconds), $(if ($frames) { $renderMs / $frames } else { 0 }))
                $frames = 0; $renderMs = 0.0; $poseMs = 0.0; $poseWalks = 0; $sinceReport.Restart()
            }
            Start-Sleep -Milliseconds 20   # pace it to roughly the guest frame rate
            continue
        }

        # Only now, with a frame in hand, is it safe to switch the engine off.
        # COUNTERS RESET ON TAKEOVER. The report timer had been running through the 10 s boot
        # wait, so the first line fired the instant we took over and read "1 pushed, render
        # 23.0 ms" -- the JIT warm-up frame and nothing else. The window has to start when the
        # rendering does, or a short session produces no usable measurement at all.
        if (-not $suppressed) {
            Set-Engine3D ([ref]$suppressed) $true
            $keyAge = 0                  # a takeover: the key frame is sent in full again
            $frames = 0; $syncTimeouts = 0; $renderMs = 0.0; $detects = 0
            $shown0 = $hv.ReadU32((HostLin $S_shown)); $starve0 = $hv.ReadU32((HostLin $S_starve))
            $sinceReport.Restart()
        }

        # The steady-state wait happens BEFORE the render, above, so the camera is fresh.
        # This one only covers the very first frame of a takeover, where there was nothing
        # pending to wait for yet.
        #
        # SLEEP, DO NOT SPIN. DOSBox emulates on ONE thread; a tight ReadProcessMemory loop
        # starves it and the game stops responding to input.
        #
        # ON TIMEOUT, SKIP THE FRAME -- DO NOT PUSH ANYWAY. The guest clears aztInjReady when
        # it has finished copying out of the staging buffer; writing while it is still set is
        # the tear the build's own handshake comment exists to prevent ("the host can never be
        # writing the buffer we are reading"). At a 1600-wide stride that reads as thick
        # horizontal bands -- one live run produced 50 of them in 93 frames.
        # (armed early this frame -- THE EARLY HAND-SHAKE above -- there is nothing to wait for here: with sync 0 the guest
        # copies the key frame whether or not it has taken this `ready` yet)
        $wait = [Diagnostics.Stopwatch]::StartNew()
        $released = $(if ($earlyArmed) { $true } else { $hv.WaitClear($hlReady, $SyncTimeoutMs) })
        if (-not $released) { $syncTimeouts++; continue }
        if ($NoPush) { $frames++; $totalFrames++; Start-Sleep -Milliseconds 20; continue }
        # Skip this frame's hand-over entirely: no push, no ready, so the guest copies nothing
        # and simply redraws its own 3D. Counting in $loopSeq rather than $frames so the skipped
        # ones are not reported as delivered.
        $loopSeq++
        if ($PushEvery -gt 1 -and ($loopSeq % $PushEvery) -ne 0) { Start-Sleep -Milliseconds 10; continue }
        # TRUE COLOUR: the picture goes to our own window and the game gets the key (or, for the
        # first frames, the calibration patch).
        $pushBuf = $r.Color
        $tmWait += $wait.Elapsed.TotalMilliseconds
        $handClock = [Diagnostics.Stopwatch]::StartNew()
        if ($script:tcOn) { Step-TrueColour $r.Color; if ($script:tcOn -and $script:tcPush) { $pushBuf = $script:tcPush } }
        $tmHand += $handClock.Elapsed.TotalMilliseconds; $handClock.Restart()
        # true colour gave up while drawing at the screen's size: this raster cannot be injected
        if ($script:tcRestart) { Set-Engine3D ([ref]$suppressed) $false; return }
        if ($pushBuf.Length -ne ($W * $H)) { continue }
        # THE BLACK FLICKER (Josh, 2026-10-06). The engine CLEARS the viewport to black every frame
        # (aztSup3D stays 0) and the guest copies our frame in only when aztInjReady is set; on a
        # frame with nothing fresh ("starved", hundreds every 4 s in true colour) the view stayed
        # BLACK -- not "the last frame" as the guest code assumes. DOSBox showed those, the
        # overlay read the black as the game's own drawing and laid it over the picture: parts of
        # the screen flashing black. While the game is handed only the unchanging key frame the
        # gate is OFF (aztInjSync 0): the guest copies the key every frame, and still clears
        # aztInjReady after each copy, so the hand-shake keeps pacing. Gated again for the
        # calibration patch and for 8-bit pictures, which must never be copied half-written.
        $syncWant = $(if ($script:tcOn -and $script:tcState -eq 'run' -and [object]::ReferenceEquals($pushBuf, $script:tcKeyFrame)) { 0 } else { 1 })
        if ($syncWant -ne $script:injSync) { [void]$hv.WriteU32($hlSync, $syncWant); $script:injSync = $syncWant; Say ("game copies the key frame {0}" -f $(if ($syncWant) { 'only when handed a new one (gated)' } else { 'on every frame of its own (no black frames)' })) DarkGray }
        # ARMED EARLY, BUT THIS FRAME IS GATED AFTER ALL (the calibration patch or an 8-bit picture from here on): the guest may
        # copy now on the early `ready` -- the buffer still holds the whole key frame, so that copy is clean -- and nothing is
        # written into the buffer until it has cleared it. Then this frame is handed over the old way.
        if ($earlyArmed -and $syncWant -ne 0) {
            $released = $hv.WaitClear($hlReady, $SyncTimeoutMs)
            if (-not $released) { $syncTimeouts++; continue }
            $earlyArmed = $false
        }
        # THE KEY FRAME IS ALREADY THERE. In true colour the game is handed the same flat frame
        # every time, and nothing else writes the staging buffer once the visor boot is over --
        # so writing 1.48 MB into DOSBox per frame only to say "the same again" is skipped. The
        # hand-shake below still happens every frame (it is what paces the game); the frame
        # itself is re-sent once in 30 and on every takeover, in case anything did touch it.
        $keyResend = (-not ($script:tcOn -and $script:tcState -eq 'run' -and [object]::ReferenceEquals($pushBuf, $script:tcKeyFrame))) -or ($keyAge -le 0)
        if ($keyResend) { $keyAge = 30 } else { $keyAge-- }
        if ($keyResend -and -not $hv.PushFrame($pushBuf)) {
            if ($hv.GameExited) { Say 'the game exited.' Yellow; return }
            # An occasional failed write is normal (the guest is mid-frame). A RUN of them is
            # not, and continuing while suppressed would leave the player staring at a frozen
            # viewport -- the same black-screen failure, just arrived at differently.
            $pushFails++
            if ($pushFails -ge 30) {
                Say ("{0} pushes in a row failed -- handing the viewport back" -f $pushFails) Yellow
                Set-Engine3D ([ref]$suppressed) $false
                $pushFails = 0
                Start-Sleep -Milliseconds 500
            }
            continue
        }
        # ARM THE HANDSHAKE. PushFrame only writes the staging buffer; this is what tells the
        # guest a frame is waiting for it. Omitting it cost a whole live run: the guest never
        # displayed anything, so the viewport held one stale image while the compass kept
        # turning -- and because aztInjReady then stayed 0 forever, the wait loop above
        # ("while ready != 0") fell through instantly every iteration and the host hammered
        # 1.48 MB writes into a single-threaded emulator as fast as it could issue them,
        # until the game died. The handshake is the throttle as much as it is the signal.
        if (-not $NoReady -and -not $earlyArmed) { [void]$hv.WriteU32($hlReady, 1) }      # (already armed beside the camera read: THE EARLY HAND-SHAKE)
        $tmPush += $handClock.Elapsed.TotalMilliseconds; $tmFrames++
        # ---- IS THE INJECTION DESTINATION STABLE? -------------------------------
        # AztInjBody copies 1.48 MB into [0x163A34]. That is a SHARED surface pool -- four
        # aliases, 54 references across 19 functions -- and the copy checks only that the
        # pointer is non-null, never that the surface behind it is big enough. If the pool
        # ever holds a smaller surface, the copy runs off its end into the heap, and the
        # first thing to notice would be Reality Lab finding one of its objects no longer
        # valid: "object expected in argument", which is RL error code 1.
        #
        # Read-only. If this value never changes while we inject, the theory is dead and I
        # stop suspecting it; if it moves, that is the fault.
        $dstB = $null; if (($totalFrames % 30) -eq 0) { $dstB = Read-AztGuest $g 0x163A34 4 -Obj2 }     # (every 30th frame: a diagnostic, and an advanced function's binding costs ~0.25 ms -- 2026-10-13 audit)
        if ($dstB) {
            $dst = [BitConverter]::ToUInt32($dstB, 0)
            if (-not $dstSeen.ContainsKey($dst)) {
                $dstSeen[$dst] = 1
                if ($dstSeen.Count -gt 1) { Say ("INJECTION DESTINATION CHANGED -> 0x{0:X} (now {1} distinct)" -f $dst, $dstSeen.Count) Red }
            }
        }

        $pushFails = 0
        $frames++; $totalFrames++
        # EVERY 10 SECONDS, not 30. The run that exposed the missing handshake lasted seven
        # seconds and produced no throughput line at all, so the one number that would have
        # identified the fault immediately -- frames actually delivered -- was never printed.
        # EVERY 4 SECONDS. The sessions being diagnosed last five seconds after takeover, so a
        # 10 s window produces nothing at all before the crash. Noisy is better than silent.
        if ($sinceReport.Elapsed.TotalSeconds -ge 4) {
            $shown = $hv.ReadU32((HostLin $S_shown)); $starve = $hv.ReadU32((HostLin $S_starve))
            if ($script:tcOn -and $script:ov) {
                $tcO = $script:ov
                Say ("  true colour [{0}]: window {1}, on screen {2}; key held {3}/1000 of the view on average (#{4:X6}), {5} frames hidden; screen read {6:N1} ms ({10} readings, off the frame), compose {7:N1} + scale {8:N1} ms; {9} drawn{11}" -f `
                    $script:tcState, $tcO.RectText, $(if ($tcO.Shown) { 'YES' } else { 'no' }), $(if ($script:tcShareN) { [int]($script:tcShareSum / $script:tcShareN) } else { 0 }), `
                    $tcO.LastKey, $script:tcHidden, $tcO.ReadMs, $tcO.ComposeMs, $tcO.ScaleMs, $tcO.Blits, $tcO.Reads, $(if ($script:gpu -and $script:gpu.Presenting) { "; card into its window: {0:N0} pictures, last {1:N2} ms" -f $script:gpu.PresentedFrames, $script:gpu.LastPresentMs } else { '' })) Cyan
                $script:tcShareSum = 0; $script:tcShareN = 0; $script:tcHidden = 0
                # FLICKER WATCH (Josh, 2026-10-06: parts of the screen flash black now and then)
                $hb = $(if ($script:gpu) { $script:gpu.HeldBlackFrames } else { 0 })
                Say ("  flicker watch: torn screen readings kept back {0}; card pictures with a sudden black band held back {1}; window hidden: no picture {2}, not placed {3}, stale {4}, game not in front {5}; blinks with nothing to draw ridden out {6}" -f `
                    $tcO.TornReads, $hb, $tcO.HideWant, $tcO.HidePlace, $tcO.HideStale, $tcO.HideFront, [int]$script:nothingSkips) Cyan
                $script:nothingSkips = 0
                if ($script:panel) {
                    $pnl = $script:panel
                    Say ("  widescreen panel: window {0}, on screen {1}; {2} pictures ({3:N1} ms to compose); log box {4}; lit buttons {5}; scroll clicks {6}; cursor {7},{8}{9}" -f `
                        $pnl.RectText, $(if ($pnl.Shown) { 'YES' } else { 'no' }), $pnl.Updates, $pnl.ComposeMs, $(if ($pnl.BoxOpen) { 'open' } else { 'closed' }), $pnl.ModesLit, ("{0}; box toggles {1}; cursor heals {2}" -f $pnl.ScrollClicks, $pnl.Toggles, $pnl.CursorHeals), $pnl.CursorX, $pnl.CursorY, $(if ($pnl.StartError) { '; ERROR ' + $pnl.StartError } else { '' })) Cyan
                    $pnl.Updates = 0
                    if ($script:pointer) { $pt = $script:pointer
                        Say ("  host pointer: {0}; display {1:N0},{2:N0} -> game {3},{4}; counts/px {5:N2}; moves {6} by the driver, {7} past its edge; {8} writes; {9} cursor images{10}" -f $(if ($pt.Active) { 'ACTIVE' } else { 'standing by (mouselook)' }), $pt.DispX, $pt.DispY, $pt.GameX, $pt.GameY, $pt.Ratio, $pt.DriverMoves, $pt.RawMoves, $pt.Writes, $pt.Images, $(if ($pt.StartError) { '; ' + $pt.StartError } else { '' })) Cyan }
                }
                if ($script:iconCursor) { $ic = $script:iconCursor; $icS = ('{0}|{1}|{2}|{3}' -f $ic.Blanked, $ic.Restored, [Math]::Floor(($ic.Shown + 24) / 25), $ic.StartError); if ($icS -ne $script:icReport) { $script:icReport = $icS; Say ("  vector cursors: now '{0}'; {1} renders, shown {2} times; game bitmaps blanked {3}, put back {4}; {5} readings of a cursor not one of the 30; 'pointer hidden' up {6} times, held {7}; panel readings with no game cursor {8}{9}" -f $ic.Shape, $ic.Renders, $ic.Shown, $ic.Blanked, $ic.Restored, $ic.NotOurs, $ic.HideFlagBlips, $ic.HideFlagHolds, $(if ($script:panel) { $script:panel.BlankCursorReadings } else { '-' }), $(if ($ic.StartError) { '; ' + $ic.StartError } else { '' })) Cyan } }
                $tcO.TornReads = 0; $tcO.HideWant = 0; $tcO.HidePlace = 0; $tcO.HideStale = 0; $tcO.HideFront = 0; if ($script:gpu) { $script:gpu.HeldBlackFrames = 0 }
                if ($postN) { Say ("  picture {0}x{1}; edge smoothing {2}, sharpen {3:N2}: {4:N1} ms a frame" -f $r.W, $r.H, $(if ($NoAA) { 'off' } else { 'on' }), $Sharpen, ($postMs / $postN)) Cyan; $postMs = 0.0; $postN = 0 }
                $pj = $script:tcPostJob
                if ($pj -and $pj.Runs -gt 0) {
                    Say ("  picture {0}x{1}; off the frame loop: edge smoothing {2} + sharpen {3:N2} {4:N1} ms, then compose; {5} of {6} pictures dropped (the loop outran it)" -f `
                        $r.W, $r.H, $(if ($NoAA) { 'off' } else { 'on' }), $Sharpen, ($pj.Ms / $pj.Runs), $tcO.Dropped, $tcO.Submitted) Cyan
                    $pj.Ms = 0; $pj.Runs = 0
                }
            }
            # WHERE A FRAME'S TIME GOES. "other" is everything in the loop that is not one of the
            # named parts: PowerShell itself, the probes, the key polls.
            if ($tmFrames -gt 0) {
                $per = $tmClock.Elapsed.TotalMilliseconds / $tmFrames
                $tw = $tmWait / $tmFrames; $tp = $poseMs / $tmFrames; $trn = $renderMs / $tmFrames; $th2 = $tmHand / $tmFrames; $tpu = $tmPush / $tmFrames
                $ttop = $tmTop / $tmFrames; $tpr = $tmProbe / $tmFrames
                Say ("  frame {0:N1} ms = waiting for the game {1:N1} + pose {2:N1} + draw {3:N1} (of which lamp views {4:N1}) + hand-over {5:N1} + to the game {6:N1} + loop start {9:N1} + probes {10:N1} + other {7:N1}; {8} draw threads" -f `
                    $per, $tw, $tp, $trn, ($tmShadow / $tmFrames), $th2, $tpu, ($per - $tw - $tp - $trn - $th2 - $tpu - $ttop - $tpr), $r.Threads, $ttop, $tpr) DarkGray
                Say ("  the draw, split: before the room (lamp + torch views, script) {0:N1} + the room {1:N1} + water {2:N1} + dust {3:N1}{4} ms" -f `
                    ($tmPre / $tmFrames), ($tmRoom / $tmFrames), ($tmWater / $tmFrames), ($tmDust / $tmFrames), `
                    $(if ($script:gpuOn -and $script:gpu) { (' + THE GRAPHICS CARD {0:N1} (its draw {1:N1}; {3} shadow views, {4} pools, {5} motes, {9} particles; {6:N0} MB of textures on it); sharpen + compose on the card {7:N1} + collecting the picture {8:N1} (in the hand-over)' -f ($tmCard / $tmFrames), $script:gpu.LastDrawMs, $script:gpu.LastReadMs, $script:gpu.LastShadowViews, $script:gpu.LastWaterGroups, $script:gpu.LastMotes, ($script:gpu.TextureBytes / 1MB), $script:gpu.LastPostMs, $script:gpu.LastFinishMs, $script:gpu.LastParticles) } else { '' })) DarkGray
            }
            $tmWait = 0.0; $tmHand = 0.0; $tmPush = 0.0; $tmFrames = 0; $tmShadow = 0.0; $tmTop = 0.0; $tmProbe = 0.0; $tmClock.Restart()
            $tmPre = 0.0; $tmRoom = 0.0; $tmWater = 0.0; $tmDust = 0.0; $tmCard = 0.0
            $secs = $sinceReport.Elapsed.TotalSeconds
            Update-RlNames        # handle -> name while healthy, so a dead handle can be named later
            if ($script:fpsOn) { Say ("  guest loop {0:N1} fps against a {1:N1} cap" -f $script:fpsRate, $script:fpsMax) DarkGray }
            if ($spdN) { Say ("  player speed while moving: average {0:N0}, peak {1:N0} units/s  (design: 146 walk, 291 run)" -f ($spdSum / $spdN), $spdMax) DarkGray }
            $spdMax = 0.0; $spdSum = 0.0; $spdN = 0
            # ---- A CHECK THAT DOES NOT TRUST THE FAST PATH -----------------------------------
            # "Hidden" means a part's name was not in the scene walk. A few is normal (an item
            # picked up, a trigger the script removed). Many means the WALK is wrong, not the
            # scene -- twice now (a stale scene top, then a stale name cache) the game's scene
            # was complete while this loop drew half a room. So when more than a handful are
            # hidden, read every name again the slow, cache-free way and count what is really
            # missing. If the slow walk finds parts the fast one did not, say so and start the
            # fast path from scratch. Runs with the report, every 4 s, only when needed.
            if ($pose -and $pose.Missing -gt 5) {
                try {
                    $rootChk = [AztTool.SceneGraph]::RootOf($g.ProcessId, [long]$g.MemBase, $camObj)
                    $raw = [AztTool.SceneGraph]::WalkBlocks($g.ProcessId, [long]$g.MemBase, $rootChk, 2000)
                    $really = 0; foreach ($pn in $pose.Names) { if (-not $raw.ContainsKey($pn)) { $really++ } }
                    if ($really -lt $pose.Missing) {
                        Say ("  POSE OUT OF STEP WITH THE SCENE: {0} parts hidden, but only {1} are really absent from the game's scene ({2} frames). Starting the scene walk afresh." -f $pose.Missing, $really, $raw.Count) Red
                        [AztTool.SceneGraph]::ForgetNames(); $smooth.Reset(); $sceneRoot = $rootChk
                    } else {
                        Say ("  {0} parts hidden, and the game's own scene really has none of them ({1} frames): {2}" -f $pose.Missing, $raw.Count, ((@($pose.Names | Where-Object { -not $raw.ContainsKey($_) } | Select-Object -First 12)) -join ' ')) DarkGray
                    }
                } catch { }
            }
            if ($poseWalks) { Say ("  scene walks: {0}, of which {1} needed a retry and {2} were abandoned as torn" -f $poseWalks, $walkRetried, $walkTorn) DarkGray }
            if (-not $NoSmooth -and ($smooth.Blended + $smooth.Snapped) -gt 0) {
                Say ("  motion smoothing: {0:N0} joint steps eased over a tick, {1:N0} passed straight through" -f $smooth.Blended, $smooth.Snapped) DarkGray
                $smooth.Blended = 0; $smooth.Snapped = 0
            }
            if ($portals -and $portalFrames) {
                $liveNow = @($portals | Where-Object { $_.Pixels -gt 0 } | ForEach-Object { '{0}{1}' -f $_.To, $(if ($_.DoorsHidden) { ' (far door open)' } else { '' }) })
                Say ("  doorways: {0} of {1} in view{2}, {3:N0} px a frame through them" -f $liveNow.Count, $portals.Count, $(if ($liveNow.Count) { ' -- ' + ($liveNow -join ', ') } else { '' }), ($portalPx / $portalFrames)) DarkGray
            }
            $portalPx = 0L; $portalFrames = 0
            # WHAT MOVED, HOW OFTEN, AND BY WHAT MECHANISM. Doors still open too fast with the
            # velocity gate in, so they are not driven the way that gate assumes. For each room
            # part that moved in this window: how many of the walks saw its matrix change (every
            # walk = it steps every frame; about 18 a second = it is on the tick), and the
            # object's own state -- dirty, built-in rotation and velocity enables (+0x45/+0x46)
            # and their per-step amounts. That names the mechanism instead of guessing it again.
            if ($pose -and $poseWalks) {
                try {
                    # ONE LINE PER FINISHED MOTION: a part that changed and has now been still for
                    # a second. Steps seen, the time from first to last, and so the rate -- which
                    # is the number that says "on the 18 Hz tick" or "every frame".
                    $nowMs = [Diagnostics.Stopwatch]::GetTimestamp() * 1000.0 / [Diagnostics.Stopwatch]::Frequency
                    $walkHz = $poseWalks / $secs
                    for ($pi3 = 0; $pi3 -lt $pose.Steps.Length; $pi3++) {
                        if ($pose.Steps[$pi3] -le 0 -or $room.Parts[$pi3].IsCharacter) { continue }
                        if (($nowMs - $pose.T1[$pi3]) -lt 1000) { continue }          # still going
                        $dur = $pose.T1[$pi3] - $pose.T0[$pi3]; $st3 = $pose.Steps[$pi3]
                        $nm = $pose.Names[$pi3]; $fp = [uint32]0; $flags = ''
                        if ([AztTool.SceneGraph]::FramePtr.TryGetValue($nm, [ref]$fp) -and $fp -ge 0x1000) {
                            $fb = [byte[]][AztTool.ProcMem]::Read($g.ProcessId, (GuestPtr $fp), 0x140)
                            if ($fb) { $flags = ("rot-on {0} vel-on {1} type {2}" -f $fb[0x45], $fb[0x46], $fb[0x48]) }
                        }
                        Say ("  MOTION {0,-14} {1,3} steps seen over {2,6:N0} ms = {3,5:N1} steps/s  (host was sampling {4:N0}/s; the tick is 18.2/s) | {5}" -f `
                            $nm, $st3, $dur, $(if ($dur -gt 0) { ($st3 - 1) * 1000.0 / $dur } else { 0 }), $walkHz, $flags) DarkYellow
                        # and every step of it: time since the first, and the yaw / position reached
                        $sl = $null
                        if ([AztTool.SceneGraph]::StepLog.TryGetValue($nm, [ref]$sl) -and $sl.Count) {
                            $t00 = $sl[0][0]; $line = New-Object System.Text.StringBuilder
                            foreach ($e in $sl) { [void]$line.AppendFormat('{0:N0}ms:{1:N0}deg({2:N0},{3:N0},{4:N0})  ', ($e[0] - $t00), $e[1], $e[2], $e[3], $e[4]) }
                            Say ("    steps: {0}" -f $line.ToString().TrimEnd()) DarkYellow
                            $sl.Clear()
                        }
                        $pose.Steps[$pi3] = 0; $pose.T0[$pi3] = 0; $pose.T1[$pi3] = 0
                    }
                } catch { Say ("  motion report failed: {0}" -f $_.Exception.Message) Yellow }
            }
            $walkTorn = 0; $walkRetried = 0
            Say ("{0}: host {1:N1} fps ({2} pushed, {3} dropped on sync), guest displayed {4} / starved {5}, render {6:N1} ms, pose {8:N1} ms ({9} moved, {10} hidden), {7} detects, dst {11}" -f `
                $loadedNames, ($frames / $secs), $frames, $syncTimeouts, `
                ($shown - $shown0), ($starve - $starve0), $(if ($frames) { $renderMs / $frames } else { 0 }), $detects, $(if ($poseWalks) { $poseMs / $poseWalks } else { 0 }), $(if ($pose) { $pose.Moved } else { 0 }), $(if ($pose) { $pose.Missing } else { 0 }), $dstSeen.Count)
            # SAFETY VALVE. If we pushed frames and the guest displayed NONE of them, the
            # injection path is not working and carrying on just leaves the player looking at
            # a frozen viewport -- which is how the last two sessions ended. Hand the engine
            # back and keep reporting; the game stays playable and the log says why.
            if ($frames -gt 0 -and ($shown - $shown0) -eq 0) {
                Say 'guest displayed NONE of the pushed frames -- handing the viewport back' Red
                Set-Engine3D ([ref]$suppressed) $false
                $room = $null; $loadedNames = ''   # force a clean re-detect before trying again
            }
            $shown0 = $shown; $starve0 = $starve
            $frames = 0; $syncTimeouts = 0; $detects = 0; $renderMs = 0.0; $poseMs = 0.0; $poseWalks = 0; $sinceReport.Restart()
        }
    }
}

# ---- supervisor -------------------------------------------------------------
# THE SCRIPT'S OWN MTIME, in the banner. PowerShell reads a script once at launch, so a
# watcher left running from before an edit keeps the old code indefinitely -- which is
# exactly what happened: a session started at 00:25 kept suppressing the viewport at
# session start long after that was fixed at 00:28, and the log looked empty because the
# running process had no logging in it. Comparing this line against the file on disk
# settles "is the thing I am debugging the thing I just changed" in one glance.
Say ("Watch-HostRender built {0:yyyy-MM-dd HH:mm:ss}" -f (Get-Item $PSCommandPath).LastWriteTime) DarkGray
$script:startupDone = $true
Say ("watching for the game. Field of view {0} degrees{2}, lighting {1}. Ctrl-C to stop." -f $Fov, $(if ($Light) { 'on' } else { 'off' }), $(if ($script:fovGame) { " (the game's own field set to match; F12 cycles 50/60/65/70)" } else { " (the game's own)" })) Green
if ($script:fovNote) { Say ("field of view: {0}" -f $script:fovNote) Yellow }
$sawGame = $false; $attachClock = $null; $attachSaid = $false; $attachErr = ''
# ---- -Launch: the game was started at the top of this script; finish what can be done before it plays
if ($Launch) {
    Say ("game started by the renderer (pid {0}); the renderer compiled behind its intro{1}" -f $gamePid0, $(if ($script:gate) { ', the loading gate is watching' } else { '' })) Green
    Write-GateNotes
    if ($null -eq $script:xafIndex) { try { Initialize-CharacterIndex } catch { Say ("room index: {0}" -f $_.Exception.Message) Yellow } }
    if ($TrueColour -and -not $NoBootHd -and -not (Test-Path (Join-Path $toolDir '..\art\boot-hd.json'))) { Say 'visor boot: art\boot-hd.json is missing -- the game''s own 8-bit boot will show' Yellow }
    if ($script:gate) { $script:gate.Stage(0.9, 2) }
}
try {
    while ($true) {
        # WAIT FOR THE DEAD ONE TO GO FIRST. A process stays listed for a moment after it
        # exits, so looping straight back here found the corpse of the game that had just
        # crashed and tried to attach to it -- "OpenProcess failed: 87", i.e. the PID is no
        # longer valid. That line then appeared one second after every crash, read like a
        # cause, and was reported as one. It is a consequence.
        if ($lastGamePid) {
            while ((Get-GamePid) -eq $lastGamePid) { Start-Sleep -Milliseconds 500 }
            $lastGamePid = 0
        }
        # -Once IS THE LAUNCHER'S MODE: one game, then leave. That has to cover the game going
        # away BEFORE a session ever starts (closed during the intro, or it never came up),
        # or the launcher's minimised window would sit waiting for a game that is not coming.
        $quit = $false; $waitGame = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Get-GamePid)) {
            if ($Once -and ($sawGame -or $waitGame.Elapsed.TotalSeconds -gt 90)) { $quit = $true; break }
            Start-Sleep -Seconds 2
        }
        if ($quit) { Say $(if ($sawGame) { 'the game has closed' } else { 'no game appeared within 90 s' }) Yellow; break }
        $sawGame = $true
        if (-not $attachClock) { $attachClock = [Diagnostics.Stopwatch]::StartNew(); Say 'game found -- attaching' Green }
        $g = $null
        # The game's own code has to be loaded before it can be found, so the first tries (DOSBox still
        # starting) fail; retried quickly and quietly rather than every 3 s with a line each.
        # (big regions first: the guest RAM is one 32 MB block; the whole process after 20 s, and the old
        # one-object rule with it, in case this build or DOSBox does not fit those assumptions)
        $late = $attachClock.Elapsed.TotalSeconds -gt 20
        Write-GateNotes
        # the gate has usually found the game already, behind the intro: no second scan
        if ($script:gate -and $script:gate.MemBase -and $script:gate.Pid -eq (Get-GamePid)) {
            $g = [pscustomobject]@{ ProcessId = $script:gate.Pid; MemBase = [long]$script:gate.MemBase; RamBase = 0; RamSize = 0; Needles = @(); Delta1 = [long]0x1F0000; Delta2 = [long]$script:gate.D2 }
        } else {
            try { $g = $(if ($late) { Get-AztGuestBase -AllowOneObject } else { Get-AztGuestBase -MinRegion 8MB }) } catch { $attachErr = $_.Exception.Message }
        }
        if (-not $g) {
            if ($attachClock.Elapsed.TotalSeconds -gt 30 -and -not $attachSaid) { Say ("attach failed: {0} (still trying)" -f $attachErr) Yellow; $attachSaid = $true }
            Start-Sleep -Milliseconds 200; continue
        }
        if ($script:gate) { $script:gate.Stage(0.97, 1.5) }
        Say ("attached to the game {0:N1} s after it appeared (guest RAM at host 0x{1:X}; obj2 delta 0x{2:X} -- 0x224000 = the 256 KB overlay window's layout, 0x1F1000 = the old)" -f $attachClock.Elapsed.TotalSeconds, $g.MemBase, $(if ($g.PSObject.Properties['Delta2']) { $g.Delta2 } else { 0 })) Green
        try { [void][AztTool.AppMute]::Set([int]$g.ProcessId, $false) } catch { }      # (a mute left over from a renderer that stopped mid-load: off)
        $attachClock = $null; $attachSaid = $false
        $lastGamePid = $g.ProcessId

        # THE PICTURE WINDOW AND THE HOST'S BOOT FIRST, before anything waits on the game: the boot can
        # start any moment after the intro, and it is drawn from its first frame only if this is ready.
        # (True colour needs nothing from the staging buffer -- only the window and the palette.)
        # ...and only then does a game held at the start of play go on (Open-Gate always lets it go).
        try {
            if ($TrueColour) {
                Initialize-TrueColour; Start-VisorShade; Start-BootHd; Start-ScanWire $script:ov
                if ($script:visorShade -and -not $script:bootHd -and $script:ov) { $script:visorShade.AttachTo($script:ov) }
                # THE HUD COMES IN WITH THE BOOT: the panel shows with the view's window, so it slides in on
                # the boot's first frame -- art only until the game's screen is found after the boot
                if ($script:bootHd -and -not $HudAfterBoot -and $script:ov) {
                    Start-WidePanel $script:ov
                    # held off until the readout's first line ("DEPLOYING MS-2 HELMET INTERFACE..."), then it slides in, its keys
                    # flicker on, and the health bar fills on "HEALTH SYSTEM INITIATED" (BootHd drives it)
                    if ($script:panel) { $script:panel.Blind = $true; $script:panel.HoldOff = $true; $script:bootHd.Hud = $script:panel }
                }
            }
        }
        finally { Open-Gate }

        # AztInjInit is DEFERRED, so the staging buffer does not exist the moment the
        # process does. Wait for it rather than failing the session -- for as long as the game is up:
        # attached this early (the intro is still playing) it can be a while.
        $bufGuest = 0; $bufWait = [Diagnostics.Stopwatch]::StartNew(); $bufSaid = $false
        while ($true) {
            $bufGuest = RdU32 (HostLin $S_bufPtr)
            if ($bufGuest -ge 0x1000) { break }
            if (-not (Get-GamePid)) { break }
            if (-not $bufSaid -and $bufWait.Elapsed.TotalSeconds -gt 60) { Say 'the staging buffer has not appeared after 60 s -- still waiting (is the overlay installed?)' Yellow; $bufSaid = $true }
            Write-BootNotes
            Start-Sleep -Milliseconds 100
        }
        if ($bufGuest -lt 0x1000) { Say 'the game closed before the staging buffer appeared' Yellow; Close-TrueColour; continue }

        $_srt = @(1..254 | ForEach-Object { [pscustomobject]@{ I=$_; L=(0.299*$pal[$_*3] + 0.587*$pal[$_*3+1] + 0.114*$pal[$_*3+2]) } } | Sort-Object L)
        $hv = New-Object AztTool.HostView($g.ProcessId, [long]($g.MemBase + $bufGuest), $W, $H, `
                  [byte]$_srt[$_srt.Count-2].I, [byte]$_srt[[int]($_srt.Count*0.20)].I, [byte]$_srt[[int]($_srt.Count*0.55)].I)
        Say ("attached: {0}x{1} viewport, staging buffer at 0x{2:X} ({3:N1} s after attaching)" -f $W, $H, $bufGuest, $bufWait.Elapsed.TotalSeconds) Green

        $script:tcRaster = $null
        do {
            $script:tcRestart = $false
            try { Invoke-Session } catch { Say ("session ended: {0}" -f $_.Exception.Message) Yellow }
            Stop-SpaceGuard
            if ($script:gpu) { try { $script:gpu.Dispose() } catch { }; $script:gpu = $null; $script:gpuOn = $false }
            if ($script:tcRestart) { Say 'starting the picture again at the game''s own size' Yellow; $script:tcRaster = $null }
        } while ($script:tcRestart -and (Get-GamePid))
        Close-TrueColour
        [AztTool.AudioMeter]::Mark("the game exited")
        if ($script:loadSilent) { Set-LoadSilence $false 'the game ended' }      # (never leave DOSBox muted)
        for ($k = 0; $k -lt 200; $k++) { $ml = [AztTool.AudioMeter]::Take(); if (-not $ml) { break }; Say $ml DarkGray }      # (what the meter has so far)
        Restore-Viewport
        try { [AztTool.SceneGraph]::Release() } catch { }
        try { $hv.Close() } catch { }
        $hv = $null; $g = $null
        $script:snapOn = $false; $script:hlRapHit = 0L; $script:hlReboot = 0L      # (this attach's snapshot and host addresses end with it)
        if ($Once) { break }
        Say 'waiting for the next game' Green
    }
} finally {
    # a game held behind the loading screen is never left frozen, whatever ended this
    if ($script:gate) { try { $script:gate.Dispose() } catch { }; try { Write-GateNotes } catch { }; $script:gate = $null }
    Stop-SpaceGuard
    if ($script:loadSilent -and $g) { try { Set-LoadSilence $false 'stopping' } catch { } }      # (never leave DOSBox muted)
    if ($script:gpu) { try { $script:gpu.Dispose() } catch { }; $script:gpu = $null }
    Close-TrueColour
    Restore-Viewport
    if ($hv) { try { $hv.Close() } catch { } }
    Say 'stopped; viewport handed back to the engine.' Green
}
