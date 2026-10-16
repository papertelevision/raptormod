# Builds AztMod.manifest.json from the stub source below.
#
# Developer tool. End users never run this -- they run ..\Apply-AztMod.ps1
# against the generated manifest.
#
#   .\Build-AztMod.ps1 -GameExe "<path to an UNPATCHED R.EXE>"
#
# v0.4.0 -- inverted mouselook: look by default, hold RMB for the stock pointer.
#
# The game already contains proper relative (mickey-based) mouselook; it is just
# gated behind HOLDING the right mouse button. This mod inverts that gesture:
# look is the default, and holding the right button restores the game's own
# pointer. Cursor mode is therefore 100% stock -- picking and the contextual
# TAKE/USE/PUSH icons are untouched, which is what broke in v0.3.0 when we tried
# to keep a pinned pointer live during look mode.
#
# Left mouse no longer walks you forward; in combat mode it fires the weapon,
# which is the game's only fire control.
#
# Everything is position-INDEPENDENT: the stub derives its own load address and
# the game's data delta at runtime (see AztDeltas), because the image is fully
# relocatable and DOS/4GW does not necessarily honour the stated object bases.

[CmdletBinding()]
param(
    [string]$GameExe = "$PSScriptRoot\..\..\GAME\AZRAEL\R.EXE",
    [string]$OutFile = "$PSScriptRoot\..\AztMod.manifest.json"
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Asm.ps1"

# ---------------------------------------------------------------------------
# Image geometry. The LE header's data-pages offset is WRONG in this binary
# (see AztMod\README.md); 0x61A54 is derived from the file tail and verified
# against the fixup table. obj1's pages are contiguous and identity-mapped.
# ---------------------------------------------------------------------------
$OBJ1_BASE  = 0x10000
$DATA_PAGES = 0x61A54
function Lin2File([uint32]$lin) { return [int]($DATA_PAGES + ($lin - $OBJ1_BASE)) }

# ---- game symbols (recovered by static analysis) ---------------------------
$EnterMouselook = [uint32]0x11640   # sets g_mouselookOn AND hides the pointer
$ExitMouselook  = [uint32]0x1166C   # restores the pointer, clears the flag
$KeyHandler     = [uint32]0x12B88   # KeyDown(eax = event*) ascii@+6 scancode@+7
$GetMickeys     = [uint32]0x3580C   # GetMickeys(eax = &out[2]) -- INT 33h AX=0Bh
$SetMousePos    = [uint32]0x35A45   # SetMousePos(eax = x, edx = y) -- INT 33h AX=4
$HudPrint       = [uint32]0x39080   # HudPrint(eax = text obj, edx = font, ebx = char*)

$KeyUpHandler   = [uint32]0x1374C   # KeyUp(eax = event*); reads word [ev+7] - 0x48
$CursorRedraw   = [uint32]0x3544D   # redraws the pointer from g_mouseX/g_mouseY

$g_mouselookOn  = [uint32]0x147218  # movement integrator consumes mickeys when set
$g_rmbHeld      = [uint32]0x182DAA
$g_mouseOn      = [uint32]0x182DA4  # pointer system live (position updates + draw)
$g_mouseX       = [uint32]0x182D6C
$g_mouseY       = [uint32]0x182D6E
# the copy of the cursor stamped into the UI event record at 0x36D49; this, not
# $g_mouseX/$g_mouseY, is what a widget sees when it is hovered or clicked
$g_evtCursorX   = [uint32]0x182DCA
$g_evtCursorY   = [uint32]0x182DCC
# record counts for the HUDTOP.RES / HUDBOT.RES viewport overlays (see below)
$g_hudTopCount  = [uint32]0x1523C4
$g_hudBotCount  = [uint32]0x1523C8
$g_saveBox      = [uint32]0x1525A0  # (misnamed) the PICTURE VIEW: set by 0x16A80, cleared by 0x16BE0; the key handler's 0x12BF0 gives it ESC (close) and 's'
$g_saveList     = [uint32]0x1523E0  # the fold-out's SAVE list is up (docs\save-load-screen-RE.md s1.3)
$g_listSel      = [uint32]0x146948  # its picked row: 0..4 = a slot (typing its name), -1 none, 6 RESTART
# KEYS FOR TYPING -- one word the overlay rewrites every frame (AztFrameAll): picture view, OR the save list up with a slot
# picked, i.e. the game's own save-name entry (0x12CCB: E0 && sel != -1 -> every key is text). The WASD hooks in the stub
# read it: the stub cave has no byte left for a second test, and `cmp word [esi+d32],0` is the same 8 bytes as the
# `cmp word [edi+0x1525A0],0` it replaced. At a FIXED overlay offset (+19, after the three entry jumps) because the stub is
# assembled before the overlay; until the overlay is read in it is zero-filled BSS = "not typing", i.e. stock WASD.
# (Josh, 2026-10-11: "anytime you save the game, WASD is disabled for typing" -- the hooks only ever tested the picture
# view, so W/A/S/D in a save name became movement keys.) $TYPING_KEYS_AT is set just under $OVERLAY_BASE (derived values
# must sit below their constant: azrael-powershell-null-ordering).
$g_invertY      = [uint32]0x1471DA  # negates the mouselook Y delta at 0x1D130; F10 toggles it
$g_combat       = [uint32]0x14721C  # "sniper" mode: crosshair + left mouse fires
$g_fwdFlag      = [uint32]0x14721E  # forward-key flag; gates the movement block
$g_dirX         = [uint32]0x147200  # forward unit vector, rebuilt each frame at 0x1D400
$g_dirZ         = [uint32]0x147208

# The Space/combat toggle at 0x131E1 refuses to run while any of these is set
# (plus g_mouselookOn and g_book). Copied from the game's own guard list rather
# than guessed, so the mod can tell "a menu is up" from "combat needs restoring".
$g_book         = [uint32]0x15257C
$g_guardA       = [uint32]0x1523D6
$g_guardB       = [uint32]0x181F88
$g_guardC       = [uint32]0x14721A

# "A CONVERSATION IS ON SCREEN." Exactly two writers, both inside the conversation
# bracket: 0x17EDE sets it in the opener 0x17E52 (called from StartConversation,
# 0x1B156, at 0x1B2DB) and 0x17F77 clears it in the closer 0x17F2F (called from
# 0x1B148 and 0x17C69). Everything that navigates the dialogue list tests it --
# six times in the keyboard dispatch 0x12B88 alone, plus the click dispatcher and
# the log draw at 0x14EF8 / 0x14F77.
#
# This REPLACES an earlier guess. $g_guardB (0x181F88) was documented here as the
# talking-to-people flag; it is not. Its setter 0x2FB88 loads "orrpuz\sun.pcx",
# "orrpuz\orrback.pcx" and "%stop0%d.pcx" -- it is the ORRERY PUZZLE, and hot-spot
# screen 4 is the orrery's rings (two 27/28-point concentric polygons), not the
# dialogue choices. The dialogue choices are screen 5 r0, the story log box.
# Keep guardB anyway: the orrery is a click-driven puzzle and wants the pointer
# too. It just never had anything to do with conversations.
$g_convList     = [uint32]0x152B1C
$LOG_TEXT_OBJ   = [uint32]0x1521AC  # the story log's text object

# The frame hook deliberately preserves the original `cmp word [g_mouselookOn],0`
# at +0..+7, so its disp32 operand at +3 still holds the LOADER-RESOLVED address
# of g_mouselookOn. Reading it is how we recover obj2's runtime delta.
$FIXUP_SRC      = [uint32]0x13DCB

# ---- hook sites ------------------------------------------------------------
$HOOK_FRAME     = [uint32]0x13DC8   # 25 bytes, per-frame; HAS FIXUPS at +3 and +13
$HOOK_FRAME_LEN = 25
$HOOK_RMBDN     = [uint32]0x15E41
$HOOK_RMBUP     = [uint32]0x15E59
$HOOK_KEY       = [uint32]0x15E7E   # call KeyHandler
$HOOK_KEYUP     = [uint32]0x15E8B   # call KeyUpHandler
$HOOK_LMBFWD    = [uint32]0x1D70D   # `jz 0x1DAA1` guarding the LMB-walks-forward arm
$HOOK_REDRAW    = [uint32]0x3592D   # call CursorRedraw, inside the mouse move handler
$HOOK_STRAFE    = [uint32]0x1D6E7   # first gate of the forward movement block (jnz 0x1DAA1)
$ACTOR_STEP     = [uint32]0x261C0   # per-frame actor/animation stepper (ONE caller, 0x13DF0)
$HOOK_ACTOR     = [uint32]0x13DF0   # that call, inside the per-frame loop
# 0x36B96 is the screen hot-spot dispatcher: it copies the cursor into locals at
# [ebp-0x10]/[ebp-0xE], then walks the active screen object's region list calling
# the point-in-rect test at 0x336F8. Hooking it is how the shrunken panel becomes
# clickable again. The cursor LOADS at 0x36BA7/0x36BB1 carry LE fixups in their
# disp32 operands, so the hook goes AFTER them, at the first two fixup-free
# instructions (`mov eax,[ebp-4]` + `cmp dword [eax+0x52],0`), which the stub
# reproduces on the way out -- the `cmp`'s flags feed the `jnz` that follows.
$HOOK_HUDPOINT     = [uint32]0x36BBB
$HOOK_HUDPOINT_LEN = 7
# ...but that is only half the story. Widget hover and click actually arrive as
# EVENTS: a 4-way switch at 0x36D32 writes the event sub-type, every arm jumps to
# 0x36D49, which stamps the live cursor into the event record at 0x182DCA/0x182DCC
# and dispatches it with `call 0x3668E`. Because all four arms converge on that
# one store, hooking the dispatch call transforms each event exactly once, on
# values that were just refreshed from the globals -- no risk of compounding.
# The four stores themselves all carry LE fixups; the `call` does not.
$HOOK_HUDEVENT = [uint32]0x36D74
# HUDTOP.RES / HUDBOT.RES are run-length overlays that the game composites
# directly into the 3D framebuffer so the panel artwork bleeds over the edges of
# the view. Each record is `word run; run bytes; word skip`, and the skips are
# authored against a 552-pixel scanline: the first records read 1+551, 2+550,
# 3+549 ... = 552 exactly. At 640 wide every skip advances the wrong amount, the
# overlay smears across rows as a full-width band, and it walks past the end of
# the framebuffer -- which is very likely what was corrupting the heap.
#
# Both are applied by 0x1E65C(eax=data, edx=dest pixels, ebx=count), a cdecl
# thunk onto 0x1E789, from 32 call sites (16 places, top+bottom at each).
#
# First attempt zeroed the two record counts at load time and booted straight
# into "INT:Gate Selector points to illegal descriptor" -- 0x1E789 evidently
# treats the count as a do-while rather than a while, so zero means "loop
# forever". NOPing the calls makes no assumption about the loop at all.
# Split by which overlay each site applies, decided by whichever data pointer --
# 0x1523CC (top) or 0x1523D0 (bot) -- is loaded NEAREST before the call. They come
# in top/bot pairs, so a plain "is it mentioned nearby" test mislabels the second
# of each pair (its lookback still sees the top pointer).
$HUDRES_TOP_CALLS = @(
    0x14870, 0x1544B, 0x15362, 0x1523E, 0x1528A, 0x150D1, 0x16F64, 0x16EEA,
    0x175BA, 0x17243, 0x174D5, 0x173B6, 0x17402, 0x16B49, 0x2FE4B, 0x16A4D)
$HUDRES_BOT_CALLS = @(
    0x14890, 0x15470, 0x15382, 0x1525E, 0x152A9, 0x150F1, 0x16F84, 0x16F0A,
    0x175DA, 0x17262, 0x174F5, 0x173D6, 0x17422, 0x16B69, 0x2FE69, 0x16A6D)
# Intro movies. NOPing the whole sequence function (0x1FF39, one caller at
# 0x1614B) looked tempting and boots straight into
#   "Exit to error: INT:Gate Selector points to illegal descriptor with type f"
# -- it is load-bearing, not just playback. Instead NOP only its three calls to
# the movie player 0x20BD4. The two OTHER call sites, 0x20133 and 0x2019B, are
# %soutro1.mov / %soutro2.mov in a different function and are left alone.
# TM.EXE in AZRAEL.BAT is a separate player; both have to go.
$INTRO_MOVIE_CALLS = @([uint32]0x1FF67, [uint32]0x1FFC0, [uint32]0x2008A)

# ---- cave ------------------------------------------------------------------
$CAVE_BASE  = [uint32]0x132980
$CAVE_LIMIT = [uint32]0x133000

# ---- SECOND CAVE: the middle blitter's dead bank-crossing path ---------------
# The first cave is end-of-image page padding and there is no more of it: obj1's
# page image stops at 0x133000 and raising the object's virtual size only buys
# zero-filled address space with NO FILE BYTES BEHIND IT. So growth has to come
# from code the mod itself made unreachable.
#
# $ENABLE_LFB rewrites three blitters to always take their no-crossing path, and
# lfb-linear-51196 jumps 0x51196 -> 0x51372 unconditionally. Everything between
# is then dead. Checked before use, and both checks matter:
#   * NO FIXUPS in 0x511A0..0x51372 (Test-FixupsIn). 0x33EB8 looked just as dead
#     and had 21 fixups in 198 bytes, which ate an earlier attempt.
#   * NO EXTERNAL ENTRIES -- scanned every E8/E9/EB/7x/0F8x in obj1 for a target
#     inside the range with a source outside it, and there are none. The THIRD
#     blitter's equivalent range is NOT safe: 0x513FB jumps into 0x51441, from
#     before its redirect. Do not use that one.
$CAVE2_BASE  = [uint32]0x511A0
$CAVE2_LIMIT = [uint32]0x51372
# Fixed entry points, so the first cave can call into this blob without having to
# be assembled after it (they are the first three things emitted, and the build
# asserts that). Same convention as $ACTOR_TIME_AT.
$BOX_CLICK  = [uint32]($CAVE2_BASE + 0)    # per-frame icon hit test
$BOX_SCROLL = [uint32]($CAVE2_BASE + 5)    # effective log scroll -> eax
$BOX_PREP   = [uint32]($CAVE2_BASE + 10)   # resize the box, return ebx = blit Y

# ---- THIRD CAVE: the last blitter's dead bank-crossing path ------------------
# 0x51439..0x515E3, freed by lfb-linear-51434 the same way the second cave was.
# An earlier sweep rejected this range over an "external entry" at 0x513FB, which
# was a MIS-DECODE: 0x513FB is not an instruction boundary, it is the middle of
# `mov edi,[ebp+0x44]` and the 0x7D byte read as a `jge`. Disassembling from the
# function's real start shows nothing reaches in here. No fixups either.
#
# It holds the box ARTWORK: two surface headers, two filenames, the loader and
# the text-area inset. All of it is addressed at fixed offsets so the second cave
# can call and reference it without either blob having to be assembled first.
$CAVE3_BASE  = [uint32]0x51440
$CAVE3_LIMIT = [uint32]0x515E3
$BOX_LOAD     = [uint32]($CAVE3_BASE + 0)    # create + load both frames, once
$BOX_SAVEBASE = [uint32]($CAVE3_BASE + 5)    # record the recess surface's real base
$BOX_FILL     = [uint32]($CAVE3_BASE + 10)   # lay the frame's recess into the text surface
$BOX_CONV     = [uint32]($CAVE3_BASE + 15)   # snap the log to the top when a conversation opens
$BOX_SURF_OFF = [uint32]($CAVE3_BASE + 20)   # 0x10-byte surface header
$BOX_SURF_ON  = [uint32]($CAVE3_BASE + 36)   # 0x10-byte surface header
$BOX_STR_OFF  = [uint32]($CAVE3_BASE + 52)   # "boxoff.pcx" + NUL
$BOX_STR_ON   = [uint32]($CAVE3_BASE + 63)   # "boxon.pcx" + NUL
$BOX_BUF      = [uint32]($CAVE3_BASE + 73)   # the recess surface's real pixel base
$BOX_CONV_WAS = [uint32]($CAVE3_BASE + 77)   # last frame's conversation flag
$BOX_CODE3    = [uint32]($CAVE3_BASE + 79)
$SURF_NEW     = [uint32]0x37AC8   # Make(eax = header, edx = w, ebx = h)
$PCX_LOAD     = [uint32]0x38A20   # Load(eax = surface, edx = filename)

# ---- the BSS overlay -------------------------------------------------------
# Every file-backed cave is full and the LE tables cannot be grown (the header's
# data-pages offset does not decode, so nothing already in the file may move --
# see the notes on obj1-vsize). What IS free is the 53 KB between obj1's last
# page and obj2's base, which the loader zero-fills simply because obj1 now says
# it is that big.
#
# That memory has no file offset, so the patcher cannot write it. The bytes have
# to arrive at RUNTIME: the build emits them as AZTCODE.BIN, the installer ships
# it, and AztOverlayLoad reads it into (obj1 delta + $OVERLAY_BASE) on the first
# frame. Overlay code is therefore ORDINARY CAVE CODE in every other respect --
# same esi/edi delta convention, same absolute calls back into the real caves.
#
# AZTCODE.BIN IS NOT OPTIONAL. Routines that live in it are called from patched
# sites by absolute address, so a missing file is a crash, not a degradation.
# The installer ships it as a required art file for that reason.
$OVERLAY_BASE = [uint32]0x133000
$OVERLAY_NAME = 'AZTCODE.BIN'
$TYPING_KEYS_AT = [uint32]($OVERLAY_BASE + 19)     # aztTypingKeys: right after the overlay's three entry jumps (see $g_saveList)

# Pull the overlay in at 0x16146, before the intro sequence, instead of waiting for the
# first rendered frame. Two reasons, and the first is measurable: the boot effect is a CD
# track with ~4 s of start latency, so requesting it on the animation's first frame meant
# four seconds of animation playing to silence. With the overlay up this early, AztCdBoot
# can request it at 0x16150 -- the instant the intro returns -- and the latency is spent on
# the room load instead. The second is structural: intro-time code no longer has to fit in
# a file-backed cave, which is what has had AztOpenMovie wedged into cave 3's last byte.
#
# This REQUIRES AztInjInit to stay off AztInitAll (see AztFrameAll): init now runs before
# the movies, and its 576 KB would come out of the heap the movie player needs.
$ENABLE_EARLY_OVERLAY = $true

# Request the boot effect at 0x16150, before the room loads, rather than on the boot
# sequence's first frame.
#
# OFF, because the problem it solved turned out not to exist. The "~4 s of CD start latency"
# was never latency: the LBA table was built from WHOLE-SECOND durations and the rounding
# error accumulated down the disc, so the game asked the drive to start 418 sectors -- 5.57
# seconds -- before the boot effect, inside the fade-out at the end of PEACEFUL. That fade is
# the mystery orchestral swell, and waiting it out is what looked like latency.
# Build-Soundtrack now decodes each track and lays it out on real sector counts.
#
# With no drift there is nothing to hide, and asking this early would OVERSHOOT: the track
# would start during the room load and be several seconds in by the time the visor animation
# begins, so its opening would be missed. The fallback request in AztBootTick's first frame
# is now the right and only one. $ENABLE_EARLY_OVERLAY stays on -- the overlay being resident
# before the intro is worth having on its own.
$ENABLE_EARLY_CD_BOOT = $false
$OVERLAY_MAGIC = [uint32]0x4F545A41          # 'AZTO' -- also the "is it loaded?" test
# Read a fixed generous length rather than the exact size: DOS AH=3Fh returns
# what it actually read, so this needs no build-order dependency on how big the
# overlay turned out, and 53 KB of BSS means it cannot overrun.
# The WHOLE BSS window: 0x40000 = 256 KB (0x133000..0x173000) since 2026-10-11, when obj1
# grew past obj2's linked base (see $OBJ1_VSIZE). It was 0xD000 = 52 KB, full to 2 bytes.
# ONE DOS read of up to 256 KB: DOS/4GW takes a 32-bit count for AH=3Fh -- the game's own
# fread (0x397B3) hands the whole remainder to its read (0x54044 -> int 21h) with no 64 KB
# chunking. Nothing else lives in this window: the 576 KB staging buffer comes from the
# game's own allocator, not from here. Asserted against the window further down, where
# $OBJ1_VSIZE is finally known.
$OVERLAY_READ = [uint32]0x40000

# ---- LE object table edits -------------------------------------------------
$LE_BASE        = 0x290FC
$OBJTAB_FILE    = $LE_BASE + 0xC4
$OBJ1_VSIZE_OFF = $OBJTAB_FILE + 0
$OBJ1_FLAGS_OFF = $OBJTAB_FILE + 8

# ---- HUD boot banner (pure data; doubles as proof the mod is live) ---------
$BANNER_TEXT  = 'Model 7 Head Up Display'
$BANNER_NEW   = 'AztMod 0.16.0 lfbspike '   # must be exactly 23 characters
$BANNER_FILES = @(0x184B68, 0x18548E)

# ---- screen mode -----------------------------------------------------------
# Stock is VESA mode 0x101 (640x480x8), set at 0x33ABB and fed to INT 10h
# AX=4F02h at 0x33AD4. The mode is also validated against the VESA mode list
# (0x33C03, 0x33C17) and queried with AX=4F01h (0x33C4C) -- all four must agree.
#
# 1024x768x8 is mode 0x105, which this binary already references elsewhere.
#
# The whole point of going wider is that it lets the instrument panel stay at its
# ORIGINAL size and position, (0,318)-(639,479). Every button hot spot is a fixed
# screen rectangle, so leaving the panel alone means every button works with no
# remapping at all -- which is what the rescaled panel could never manage,
# because its highlight draws use the same rectangles as its hit tests.
$SCREEN_W_OLD = 640
$SCREEN_H_OLD = 480
$VESA_MODE_OLD = 0x101
# DISABLED. Switching the mode ALONE -- every size constant left at 640x480, only
# the four 0x101 sites changed to 0x105 -- makes the game exit cleanly before the
# menu. 800x600 (0x103) behaves identically, and DOSBox has the video memory for
# both (tested at vmemsize=4). So the blocker is mode negotiation, not the screen
# size family and not DOSBox: either the game rejects the mode somewhere I have
# not found, or UVBELib (SciTech's VBE driver -- note UVCONFIG.EXE/UVCONFIG.DAT in
# the game directory) only offers the modes it was configured for.
# Next lead: UVCONFIG.DAT, and any fifth site that still compares against 0x101.
# 800x600 (mode 0x103) rather than 1024x768. Two reasons: it is 4:3 like the
# stock 640x480, so every coordinate scales by a single uniform 1.25 with no
# aspect correction anywhere; and the rasteriser is the bottleneck
# (azrael-blit-vs-rasteriser), so 1.56x the pixels is affordable where 1024x768's
# 2.56x is not.
#
# Verified by BIOS query under a matching DOSBox conf: mode 0x103 reports
# ModeAttributes 0x009B (bit 7 = linear framebuffer available), 800x600, 8bpp,
# BytesPerScanLine 800, and PhysBasePtr 0xC0000000 -- the SAME base as 0x101, so
# the LFB patches need no change.
#
# This was impossible before the linear framebuffer: 800x600 is 480,000 bytes =
# 7.32 64KB windows, and the blitter hand-unrolled exactly four boundaries.
$ENABLE_HIRES = $true
# 1024x768 (0x105) RETRIED 2026-09-23, and the earlier verdict deserves revisiting
# rather than repeating. It always set the mode and rendered correctly; it died
# 10-25 s in, and an 8-round bisect of the 184 `call 0x334A0` sites blamed
# `Teleport Player in WORLDENG / "Cannot find teleport object %s"` -- which never
# made sense as a consequence of pixel count.
#
# It does now. At 1024x768 every full-screen surface is 786,432 bytes instead of
# 480,000 and the z-buffer 1,179,648 instead of 704,000, against the FIXED 4.5 MB
# the texture cache used to leave behind (see [[azrael-texture-cache-reserve]]).
# An allocation failing and a world object failing to load are the same event --
# and that reserve is now ours to set. The old runs were also unattended, so the
# teleport may have been an idle event rather than a cause at all.
#
# COST, which is real: the viewport goes from 800x440 (352,000 px) to 1024x576
# (589,824), i.e. 1.68x the rasteriser work, and the rasteriser is the bottleneck
# ([[azrael-blit-vs-rasteriser]]). Expect the frame rate to fall roughly in
# proportion wherever the emulator is CPU-bound.
# 1280x1024 is the next VESA 8-bit mode up (0x107) and it is 5:4, not 4:3. That
# matters less than it sounds: the panel artwork is scaled UNIFORMLY by
# $PANEL_SCALE_EFF and centred, so the extra vertical space goes to the viewport
# rather than stretching anything. What it does NOT fix is $HS, which is derived
# from the WIDTH alone -- at 5:4 the vertical is 2.133 against a horizontal 2.0,
# so anything positioned in SCREEN space with Hi() sits ~6.7% high. Panel-relative
# placement (To-PanelX/Y) is unaffected because the panel is uniform.
#
# Needs `vesa_modes = all` in the DOSBox conf: the `compatible` list is trimmed.
# MEASURED 2026-09-24: 1280x1024 sustains ~22 fps in play against a 48 fps cap
# (0 of 91 one-second samples ever reached the cap), so it was abandoned. Leaving
# the branch in place because the work to support it is done and correct -- it is
# the MACHINE that cannot afford 1.73x the fill, not the build. The art chain must
# be regenerated for whichever resolution is selected; see [[azrael-resolution-asserts]].
# 1600x1200 -- VESA mode 0x120, NOT 0x11C. The standard VBE list stops at
# 1280x1024, so 1600x1200 is a DOSBox extension and its number is whatever DOSBox
# chose. Read out of DOSBOX-STAGING\dosbox.exe's own mode table (a 0x28-stride
# array of {uint32 mode, uint32 type, uint16 w, uint16 h, ...} where type 0x20 is
# M_LIN8): the 8-bit modes on offer are 069h, 100h, 101h, 103h, 105h, 107h,
# **120h = 1600x1200**, 16Eh, 17Dh = 1280x960 and 207h = 1152x864. Guessing 0x11C
# from the VBE spec would have set a mode that does not exist here.
#
# The last two are worth knowing about as fallbacks: 1152x864 and 1280x960 are
# both 4:3, so they drop straight into this branch if 1600x1200 is too slow.
#
# 1600x1200 is 4:3 like 640x480, so $HS is a single uniform 2.5 and nothing needs
# aspect correction -- unlike 1280x1024, which is 5:4 and warns below.
#
# VERIFIED BY BIOS QUERY, not by reading the table. A 56-byte hand-assembled COM
# calling INT 10h AX=4F01h under a matching conf reports, for mode 0x120:
#
#   ModeAttributes 0x009B      bit 7 set, so the linear framebuffer is available
#   1600 x 1200 x 8 bpp
#   BytesPerScanLine 1600      which is why $VIEW_STRIDE is just $SCREEN_W
#   WinSize 64 KB              which is what $VESA_WIN_KB already assumes
#   PhysBasePtr 0xC0000000     the SAME base as 0x101/0x103/0x105, so none of the
#                              LFB patches change for this resolution
#
# The mode is offered at the DEFAULT vmemsize and at 2 MB as well -- 1,920,000
# bytes fits inside 2 MB -- so `vmemsize = 4` in the conf is headroom, not a
# requirement. (An earlier note here claimed it was required; it is not.)
$HIRES_1600 = $true
$HIRES_1280 = $false
$HIRES_1024 = $false
if     ($ENABLE_HIRES -and $HIRES_1600) { $SCREEN_W = 1600; $SCREEN_H = 1200; $VESA_MODE = 0x120 }
elseif ($ENABLE_HIRES -and $HIRES_1280) { $SCREEN_W = 1280; $SCREEN_H = 1024; $VESA_MODE = 0x107 }
elseif ($ENABLE_HIRES -and $HIRES_1024) { $SCREEN_W = 1024; $SCREEN_H = 768; $VESA_MODE = 0x105 }
elseif ($ENABLE_HIRES) { $SCREEN_W = 800; $SCREEN_H = 600; $VESA_MODE = 0x103 }
else               { $SCREEN_W = $SCREEN_W_OLD; $SCREEN_H = $SCREEN_H_OLD; $VESA_MODE = $VESA_MODE_OLD }

$ENABLE_BIG_VIEW = $true
# Re-author HUDTOP/HUDBOT for the new stride instead of disabling them.
$ENABLE_HUD_OVERLAY = $true     # housing top overlaps the viewport (Build-HudOverlay.ps1)
# Rounded viewport corners, the stock game's CRT-face look. The shape was never in
# the artwork -- it came from these same overlays -- so it vanished when the stock
# 552-wide HUDTOP was silenced. Build-HudTop.ps1 synthesises a replacement at the
# real viewport size instead of re-authoring Mindscape's (whose trailer does not
# even parse like HUDBOT's).
$ENABLE_HUD_TOP = $true

# 0x34C40, called on every gauge update with surface 0x163A10.
#
# LEAVE THIS ON. It was guessed to be a redundant bevel and skipped; the result was
# that THE HEALTH BAR DISAPPEARED ENTIRELY. 0x34C40 is what actually draws the
# gauge -- 0x163A10 is the visible bar, not a decoration around it, and the blit of
# 0x163A22 at 0x11E2B is the other half of the pair rather than the whole thing.
# The flag survives only so the experiment is not repeated.
$ENABLE_GAUGE_FRAME = $true

# Draw the FILL pass at 0x11E30 -- surface 0x163A22, the one fed by the raw memcpy at
# 0x28518. OFF: it is the source of the "corrupted particle line", and nothing visible is
# lost by skipping it.
#
# PROVED BY EXPERIMENT, not deduced. Skipping the FRAME draw (0x34C40) instead took the BAR
# away and LEFT the speckle, so the visible bar is the frame and the speckle is this pass.
# With the frame off the speckle covered the WHOLE gauge width, so this surface is garbage
# throughout -- not merely past the old 105 columns.
#
# Why it never showed before: the frame is drawn AFTER this and the same `columns` wide, so
# it covered the garbage exactly. Widening moved the allocation from 1575 to 1950 bytes -- a
# different heap block with noisier rubbish in it -- and anywhere the frame did not reach, it
# showed. THAT is the whole of the old "never resize the gauge" rule, which was a workaround
# for this and not a fact about the resize.
$ENABLE_GAUGE_FILL = $true

# Widen the gauge surface to the reskin's recess. 105 in a ~140-wide well looks
# lost, so this is the part worth having.
$GAUGE_RESIZE = $true
# Extra columns BEYOND the detected recess. The detector returns the registration rectangle
# (130 px) but the painted well is wider: HUD3's floor runs x=500..635/636 on every row the
# bar occupies, so 136 is the hard ceiling.
#
# 2 puts the bar at 132 (x 500..631), leaving 4 px of well showing at the right. 4 was tried
# and reached too far -- fitting the painted well exactly reads as overflowing it, because the
# eye wants to see some recess past the end of the bar.
# BOTH ARE DERIVED in the DERIVED block, from the 1024-era measurement above and
# $HS, which is not defined yet at this point in the file. They used to be the two
# literals 2 and 136, and both are ABSOLUTE PIXEL SIZES that silently belonged to
# one resolution -- at 1600 the detected recess is 203 px, so a 136 px "ceiling"
# rejected correct artwork. See [[azrael-resolution-asserts]].
# The HEIGHT half of the same resize. ON AGAIN AT 1600x1200, and the bisect that
# turned it off has since been explained rather than ignored.
#
# BISECTED 2026-09-24: a stray bright line appeared in the panel a few rows ABOVE
# the bar and tracked the gauge resize exactly. That was never about the height --
# it was the ERASE surface (0x163A22), which has always held heap garbage and was
# only ever hidden because the bar covered it exactly. Resizing moved the
# allocation to a noisier block and the garbage showed. `AztGaugeFill` now fills
# that surface with the well's own floor, which is what made the WIDTH resize safe,
# and it fixes the height for the same reason -- it fills W*H.
#
# Needed now because Mindscape's 15 rows is a 640x480 number: at 1600x1200 the
# panel and its well are 2.5x bigger and the bar reads as a thin line in a deep
# recess. The height comes from the measured recess, like the width.
$GAUGE_RESIZE_H = $true

# Linear framebuffer instead of VBE 1.2 bank switching. At 640x480 this is a
# no-op visually -- it exists to remove the four-bank ceiling that stops any
# higher resolution. Set $false to go straight back to the banked path.
$ENABLE_LFB = $true

# ---- DIAGNOSTIC: fail loudly on the FIRST allocation failure ----------------
# Not a feature. It answers one question: is the freeze in the big room an
# out-of-memory condition?
#
# 0x32C40 is the game's allocator. When 0x401A7 (malloc) returns null it falls
# back to 0x2876C, which PURGES two cached objects -- 0x162B7C and 0x162B84, via
# 0x1CA4D / 0x1CABF / 0x32DF9 -- and retries. Only if the retry ALSO fails does
# it reach 0x287A3 and report through 0x334A0:
#
#     FreeMemory: No memory available / Failed to allocate %d bytes
#
# and 0x334A0 shuts the video and sound down first (0x102B0), so that message
# lands on a clean text screen. A SILENT freeze therefore means one of two
# things, and they want opposite fixes: either the purge "rescued" the
# allocation and freed something still referenced -- a use-after-free, which
# would show up as exactly the garbage blits reported -- or memory was never the
# problem and the fault is somewhere else entirely.
#
# This skips the purge and jumps straight to the report, so the first failure is
# the one that prints. Stack-safe: 0x2876C's four pushes (ebx/ecx/edx/esi) are
# popped by the tail at 0x287B6, which this path still runs through. edx must
# carry the requested size, which is what `mov edx,eax` at 0x28770 already does,
# so the patch keeps that instruction and replaces only `mov ecx,1` after it.
$ENABLE_OOM_TRAP = $true

# ---- DIAGNOSTIC: name the code that crashes Reality Lab ---------------------
# Also not a feature. The host renderer dies with
#
#     RAPTOR ERROR in Rendermorphics ERROR: / Error: object expected in argument
#
# which is RL error code 1 -- an engine call was handed an object handle that is
# not an object. Ten hypotheses have now been eliminated by changing something and
# watching whether the crash moved, and the last of them (the actor scheduler
# looping the script interpreter up to 8x per frame) TRIPLED survival without
# curing it: 180 copies / 8 s before, 597 copies / 27 s after, same push rate.
# That rules it in as a contributor and rules it out as the whole story.
#
# Guessing has run out of road, and the reporter already knows the answer.
# 0x10204 is the error callback: `al` holds the code, and `mov eax, 0x10204` at
# 0x10E92 is the game REGISTERING it with RL. Being a registered callback is
# exactly why no static caller exists and why nine passes of static analysis
# could never name the culprit -- the call comes from inside RL, through a
# pointer. The one thing that does know is the stack at the moment it fires.
#
# So: capture the return-address chain into BSS, and hold the game there briefly
# so the watcher is certain to read it before the process dies. Costs nothing
# when nothing goes wrong -- the hook is on a path that is only ever taken on the
# way to a fatal error.
#
# THE TEXTURE-CACHE PURGE IS ALREADY EXCLUDED, and by this build rather than by
# argument: $ENABLE_OOM_TRAP above skips the purge and reports the FIRST failed
# allocation, so an out-of-memory crash could not reach RL without
# "FreeMemory: No memory available" landing in AZERR.TXT first. It never does.
$ENABLE_RAPTOR_TRAP = $true

# SPACE skips the line of dialogue being spoken, alongside the stock ESC.
# Rides in the clock blob, so it needs the same cave $ENABLE_ACTOR_TIME opens.
$ENABLE_SKIP_SPACE = $true

# F1 opens the help screen even while combat mode is on. Stock refuses, which under
# this mod means "never" -- see the patch for why. Pure data: a conditional jump
# NOPped out, nothing added and no cave needed.
$ENABLE_F1_IN_COMBAT = $true

# Skipping a cutscene ends only that cutscene and moves to the next, instead of abandoning
# the whole intro sequence. Pure data: three compares become stores, no new code.
#
# OFF FOR NOW (Josh, 2026-10-04): one key press should skip the WHOLE intro while testing.
# That is the stock behaviour -- each check jumps to the epilogue with the flag still set --
# and it carries through the extra opening movie too: the movie player polls the same flag
# and stops at once. (AztOpenMovie's own "clear the flag" store has never worked: it is in a
# cave with no fixup and no delta, so it writes built 0x182DB0 while the flag lives at the
# RUNTIME address. Harmless so far, and it is exactly why skip-all works with this off.)
$ENABLE_SKIP_ONE_CUTSCENE = $false

# The intro sequence's "a key was pressed" word. The movie player polls it to stop early and
# the sequence reads it after each movie to decide whether to abandon the rest. LINEAR, i.e.
# after the loader's fixup: it lives in obj2, so the file holds 0x42DB0 and the loader adds
# the 0x140000 object base.
$SKIP_FLAG = 0x182DB0

# ---- THE TITLE MENU (Josh, 2026-10-10: the title image "as a true title screen, with Continue, Load, Options, Quit
# buttons ... Continue will load the most recently dated save file") ---------------------------------------------
# The menu itself is the HOST's (tools\LoadingScreen.cs TitleScreen, run by the loading gate). The game's part:
#  1. THE TITLE WAITS FOR IT. Stock, TITLE.PCX shows for 130 x 20 ms or until a key. The wait loop (0x20015..0x20035)
#     is rewritten around the skip flag's one relocated operand: each pass it ORs 0x0100 into the flag (the marker
#     the host watches for), and leaves when (flag & mask) != 0 -- mask 0x02FF with no host (a key: the title waits
#     for one, as a "press any key" screen), 0x0200 once the host has set 0x8000 ("I am here": keys are ignored and
#     only the host's release, 0x0200, ends it). The host then writes the flag's final value: 1 = skip the rest of
#     the intro (a save is about to be loaded), 0 = play the story intro (a new game).
#  2. KEYS OR THE FLAG, never overwrite it: the keyboard interrupt's `mov word [flag],1` (0x362BB) becomes
#     `or word [flag],1` -- identical whenever the flag was 0 or 1 (every other reader only compares it with 0), and
#     the host's bits survive a key.
#  3. A LOAD FROM THE TITLE: the host leaves slot+1 in the overlay word aztTitleLoad; the first gameplay frame
#     (AztBootTick, state 0) then does what the fold-out's OK does -- selected row = slot, OK = load, the command
#     dispatcher 0x2C408 with cmd 16 -- instead of starting the new-game boot. The load runs through the existing
#     AztLoadHook, so the visor re-boots as on any load.
$ENABLE_TITLE_MENU = $true

# ---- the texture cache's reserve -------------------------------------------
# THIS IS THE BIG-ROOM CRASH, and it is not a leak or an overrun.
#
# At start-up 0x1BE79 finds the largest free block and gives nearly all of it to
# the texture cache, keeping a fixed reserve back for everything else:
#
#   0x1BE87  cmp esi, 0x400000    ; under 4 MB -> fatal "IDataManager"
#   0x1BEA6  cmp esi, 0x800000    ; 8 MB or less -> small mode, 1 MB cache
#   0x1BEC0  sub esi, 0x480000    ; otherwise the cache is (block - 4.5 MB)
#
# The game prints both numbers, and with memsize=32 they read
#
#   MAXIMIUM MEMORY BLOCK FOUND: 29891584
#   TEXTURE CACHE ALLOCATION:    25172992      (= 29891584 - 4718592)
#
# so the WHOLE REST OF THE GAME runs in 4.5 MB. That was ample at 640x480. It is
# not at 800x600: the z-buffer alone went 311,328 -> 704,000, the view
# framebuffer 155,664 -> 352,000, and every full-screen surface 307,200 ->
# 480,000. A big room exhausts what is left, and the failing request was SIXTEEN
# BYTES -- the reserve is simply gone, nothing is running away.
#
# It also explains why raising memsize never helped: a larger pool means a larger
# largest-block, the cache grows to swallow it, and the leftover stays 4.5 MB.
# The dial that matters is the RESERVE, not the pool.
#
# 10 MB leaves the cache ~19.9 MB, still more than double what the game could
# ever have had on 16 MB period hardware, and a smaller cache only costs texture
# re-uploads -- it cannot fail. The 8 MB threshold has to move too: it gates the
# `sub`, so a reserve above it would underflow to a ~4 GB request on any machine
# whose largest block fell between the two. 12 MB keeps at least 2 MB of cache.
$ENABLE_TEX_RESERVE = $true
# Scales with the screen, because that is what consumes it: every full-screen
# surface is SCREEN_W*SCREEN_H bytes and the z-buffer is twice the viewport.
#   640x480  -> stock 4.5 MB was ample
#   800x600  -> 10 MB, measured: the failure was a SIXTEEN BYTE request
#   1024x768 -> 20 MB
#
# RAISED 14 -> 20 MB for full-screen movies and up-rezzed art. THIS IS THE ONLY DIAL
# THAT GIVES HEADROOM. memsize does not: a bigger pool means a bigger largest-block,
# the cache grows to swallow it, and the reserve stays where it was -- which is why the
# old big-room fault address tracked memsize. memsize is also pinned at 32 by the
# extender (64 MB exits after ~17 s), so the split is the only thing left to move.
#
# A full-screen movie costs 2.37 MB on its own: two 786,432-byte surfaces plus the
# 794,624-byte frame buffer (see the MOVIE FRAME BUFFER patch). The z-buffer is another
# 1.57 MB and every full-screen surface 786,432. 14 MB was becoming tight.
#
# The cache drops to about 9.9 MB of the 29.9 MB block, still far more than 1996
# hardware ever had, and a smaller cache only costs texture re-uploads -- it cannot
# fail. If big rooms start thrashing, this is the number to walk back.
# 1600x1200 -> 24 MB, which is the tightest part of this resolution and the first
# thing to suspect if big rooms misbehave. The sums it has to cover all grow by
# 2.44x (the pixel ratio against 1024x768):
#
#   full-screen surface   786,432 -> 1,920,000
#   viewport z-buffer   1,179,648 -> 2,969,600   (2 bytes x 1600x928)
#   injection staging     589,824 -> 1,484,800
#
# ...but the 29.9 MB block does NOT grow, because memsize is pinned at 32 by the
# extender. So the reserve cannot simply be scaled by 2.44 (that lands at 48 MB,
# past the whole block).
#
# THE CACHE THIS LEAVES IS 4.51 MB, not the "~6 MB" an earlier version of this
# comment claimed: the split is (block - reserve) = 29,891,584 - 25,165,824 =
# 4,725,760. At 1024x768's 20 MB reserve it was 8.51 MB, so going to 1600x1200
# HALVED the texture cache. Measured against the shipped art (179 .RES, 2,909
# records): the heaviest room decodes to 2.84 MB and NONE of the 179 exceeds
# 4.51 MB, so the stock art fits with ~1.67 MB to spare.
#
# That spare is also the entire budget for any texture up-rez. A 256->512 upscale
# takes 4x the decoded bytes and would put 47 of the 179 rooms over the cache
# (worst: R22G at 9.81 MB), so it does NOT fit at this resolution -- the screen and
# the texture cache are competing for one fixed block. See
# [[azrael-texture-remaster-verdict]].
#
# ERR HIGH, DELIBERATELY. An undersized CACHE only costs texture re-uploads and
# cannot fail; an undersized RESERVE is a failed allocation, which is fatal and
# arrives as the named "Not enough space in texture cache for %d bytes" error --
# see [[azrael-texture-cache-reserve]] for how to capture the game's own printout.
$TEX_RESERVE = $(if     ($SCREEN_W -ge 1600) { 0x1800000 }     # 24 MB
                 elseif ($SCREEN_W -ge 1024) { 0x1400000 }     # 20 MB
                 else                        { 0xA00000  })    # 10 MB
# Must stay ABOVE the reserve: it gates the `sub`, so a reserve above it underflows to
# a ~4 GB request on any machine whose largest block falls between the two.
$TEX_MIN_BIG = $(if     ($SCREEN_W -ge 1600) { 0x1A00000 }     # 26 MB
                 elseif ($SCREEN_W -ge 1024) { 0x1800000 }
                 else                        { 0xC00000  })
if ($TEX_MIN_BIG -le $TEX_RESERVE) {
    throw ("TEX_MIN_BIG 0x{0:X} must exceed TEX_RESERVE 0x{1:X}, or the reserve underflows to a ~4 GB request" -f $TEX_MIN_BIG, $TEX_RESERVE)
}

# ---- compact the texture cache on every room change -------------------------
# THE CRASH AT 1600x1200 WAS FRAGMENTATION, NOT CAPACITY. The game's own report:
#
#     TEXTURE CACHE ALLOCATION: 4672512      TOTAL: 4423680
#     RAPTOR ERROR in GetTextureMemory
#     Not enough space in texture cache for 262144 bytes      (over by 13,312)
#
# 248,832 bytes were free and it still could not place a 262,144-byte texture,
# because the cache is a FIRST-FIT LINKED LIST (`+0x00` block, `+0x04` size,
# `+0x08` owner with 0 meaning free, `+0x0C` next, walked from `[mgr+0x1C0]`) and
# the free space was in pieces. It also holds several ROOMS at once -- the dump
# listed mine*, pinc*, all2cori, or_tunn3 and 1 MB of LURKA together -- so it
# accumulates as you walk and then hard-fails rather than evicting.
#
# THE ENGINE ALREADY SHIPS THE FIX AND NEVER CALLS IT OFTEN ENOUGH. `0x1C223` is
# `DefragTextureCache` -- that is its own name, pushed to the error reporter at
# `0x1C2C1` -- and it is a COMPACTING collector: it memmoves allocated blocks
# down (`0x4028A`), rewrites each block's address, and updates the owning
# texture's pointer at `[owner+0x1C]`, then coalesces all the free space into one
# block at the top. The game only calls it from the allocator's own failure path
# (`0x1C037`, `0x1C0F1`) and from `0x1C916`, i.e. when it is already too late.
#
# So call it on ROOM CHANGE instead, while the game is loading anyway and no
# render is in flight. `[0x162B74]` is the IDataManager, set at `0x1023E` right
# before its init and read exactly this way by the engine at `0x1C8F4`.
#
# WHAT THIS DOES AND DOES NOT CLAIM. It should stop the fragmentation crash and
# make room loads cheaper, with high confidence. Whether it also cures the
# frame-rate DECAY (Josh's log: 22-23 early, 10-13 after two minutes) is NOT
# established -- that decay might instead be an over-subscribed cache re-decoding
# textures, which compaction cannot fix. Measure before believing it.
$ENABLE_TEX_DEFRAG = $true

# ---- the 1-2-1 trick, applied automatically ---------------------------------
# MEASURED BY JOSH, not theorised: pressing render-level 1, then 2, then 1 again
# improves the frame rate, persistently, with no visible change in resolution.
# The defragment above was built on the assumption that it was a texture-cache
# effect -- IT IS NOT. The defrag changed nothing and the key trick still worked,
# which is what pointed here.
#
# WHAT IT ACTUALLY DOES. `SetRenderLevel` (0x10FEC) early-outs when the requested
# level equals the current one in `word [0x14686C]`, so 1->1 is a no-op while
# 1->2->1 forces two full destroy-and-recreate cycles of the 3D device and
# viewport. The rebuild and the STARTUP path do not configure the device
# identically -- diffed call for call:
#
#   startup 0x10EF0..0x10FBE   0x3A460(0) 0x3A5B0(1) 0x3A5F0(0) CreateViewport
#                              SetBack(30000.0) SetFront(0.8) 0x3A930(0)
#                              **0x3AB70(0)** 0x3ABA0(1)
#   rebuild 0x11043..0x1117B   0x3A460(0) 0x3A5F0(0) 0x3A5B0(1) 0x3ABA0(1)
#                              0x3A930(0) CreateViewport SetBack SetFront ...
#
# `0x3AB70` is a one-line setter, `mov dword [device+0x54], ecx`, and **only the
# startup path calls it**. So a rebuilt device keeps its constructor default for
# `[device+0x54]` while the startup device has it forced to 0 -- and the rebuilt
# state is the fast one. The rebuild also hands `ecx = 0x163610` to a different
# setter than startup does.
#
# WHY THE TOGGLE RATHER THAN THE ONE-DWORD FIX. NOPing the `call 0x3AB70` at
# 0x10FA5 is almost certainly the cheap equivalent, but it rests on my reading of
# one field, whereas the toggle is the exact operation Josh verified by hand. Do
# the verified thing first and keep the cheap one as the follow-up.
#
# FIRED ON ROOM CHANGE, and the first attempt got this wrong. It originally ran
# ONCE from ABT_finish, the moment the boot handed the viewport back -- and Josh
# reported that pressing 1-2-1 by hand STILL gave a further improvement on top.
# The level global `[0x14686C]` ships as 1, so the kick was not bailing out; it
# ran and simply did not help.
#
# THE GAIN IS RESTORATIVE, NOT CONFIGURATIONAL. That is the whole lesson: the
# device state degrades as you play, and the rebuild restores it. Firing at boot
# is too early -- nothing has degraded yet, so there is nothing to restore. Which
# is also why the defragment above changed nothing: both were aimed at a
# configuration problem that does not exist.
#
# Room change is the right trigger: it is when a large room is entered, the cost
# is hidden by the load, and it repeats for as long as the player keeps moving.
# If the frame rate still sags during a LONG stay in one room, a periodic kick is
# the next step -- but that would hitch mid-play, so it is not the default.
#
# MEMORY-SAFE, CHECKED BEFORE ENABLING IT PER ROOM. The device creator 0x28157
# guards the big allocation: `cmp dword [0x147466], 0 / jnz` skips the z-buffer
# malloc when it already exists, so the 2,969,600-byte buffer is allocated ONCE
# however many rebuilds happen. The 60-byte descriptor at `[0x14745C]` is freed
# (`0x32DF9`) before being reallocated. So 87 rooms of rebuilding does not leak.
#
# CLEARED, 2026-10-04. This was switched off for one build as the suspect for the ORRERY
# crash, on the strength of a free-list link (0x063FFFF8) that reads as 1599.9999 in 16.16.
# That was a coincidence: the crash continued with it off, and the real cause was the
# AztScenePart2 skip stub freeing a garbage pointer every suppressed frame (see the note at
# the stub). The kick never touched it.
$ENABLE_RELEVEL_KICK = $true

# ---- RENDER SCALE: draw the 3D smaller and let the engine expand it ---------
# 0 = follow whatever level the player is on (the proven behaviour -- the kick
# just rebuilds and returns to it). 1..4 = force that level on every room change.
#
# THE ENGINE ALREADY IMPLEMENTS ALL OF THIS; nothing here is new rendering code:
#
#   * `SetRenderLevel` sizes a SEPARATE render target -- the surface header at
#     `0x152164` (+0 w, +2 h) -- to ($VIEW_W/level) x ($VIEW_H/level) at 0x1111F,
#     while leaving the full-size screen-facing surface `0x152150` alone (it is
#     only Clear()ed, at 0x1103E).
#   * the present path then EXPANDS it: at 0x142EE it reads the divided width,
#     multiplies by `word [0x14686C]` (the level) to get the destination row step,
#     and steps the source by the scanline stride at 0x14304 -- which AztMod
#     already patches as `view-stride-14304`.
#   * three row scalers are selected by level -- 0x1E61C / 0x1E62C / 0x1E63C,
#     thin Watcom wrappers onto 0x1E674 / 0x1E6EA / 0x1E814 -- and they take the
#     width and height as ARGUMENTS, so they carry no baked-in resolution.
#   * the screen blit 0x33F80 is 1:1 and takes the FULL-size surface, building its
#     destination rect from the source's own w/h at 0x33FDF. So the pipeline is
#     already: render small -> expand to full -> blit full.
#
# WHY A FLAG RATHER THAN MORE ANALYSIS. Josh reports the 1/2/3/4 keys "have not
# worked since we started on this mod", so something in that chain is still
# inconsistent at 1600x1200 -- but the chain is long, every piece looks correct on
# paper, and one look at the screen at level 2 is worth more than another pass of
# static reading. The frame-rate log then prices it.
#
# Level 2 would be a QUARTER of the rasteriser fill with the HUD and panel still
# native, because only the 3D render target is divided.
#
# TESTED 2026-10-03 AT LEVEL 2, AND THE EXPANDER DOES NOT WORK AT 1600x1200:
#   * the 3D viewport came up BLANK; pressing 1 (back to level 1) showed the game
#     correctly and with the good frame rate
#   * the boot animation lost its readouts and kept only the background
#
# Both are the SAME fault, and the startup allocation at 0x10E2C explains why:
#
#     mov eax, 0x26010      ; = $VIEW_W*$VIEW_H, patched
#     call 0x32CE0          ; ONE pixel buffer
#     mov [0x152154], eax   ; the live viewport
#     mov [0x1521BC], eax   ; where levels >= 2 expand TO
#     mov [0x162E2C], eax
#     mov [0x163A34], eax   ; ...and what AztViewInject writes INTO
#
# `[0x163A34]` is that same buffer, so at level 2 the expander overwrites whatever
# the boot animation injected -- the missing readouts are a consequence of the
# broken expansion, not a separate bug.
#
# So the destination is right and full-size; what is wrong is further in, in the
# dispatch around 0x14230..0x1428D that picks a scaler, or in the workers
# 0x1E674 / 0x1E6EA / 0x1E814. BACK TO 0 until that is found -- 0 keeps the
# restorative rebuild Josh confirmed, which is the part that actually works.
$RENDER_SCALE = 0
if ($RENDER_SCALE -lt 0 -or $RENDER_SCALE -gt 4) { throw "RENDER_SCALE must be 0 (follow the player) or 1..4; got $RENDER_SCALE" }
# The report for this lives in the DERIVED block, with the viewport geometry. It was
# printed here first and said "3D drawn at 800x0": $PANEL_TOP_NEW and $VIEW_Y_KEEP are
# both defined BELOW this line, so the height came out $null -> 0 and the build happily
# announced a nonsense figure. See [[azrael-powershell-null-ordering]].

# ---- 3D viewport geometry --------------------------------------------------
# Stock: a 552x282 surface blitted to screen at (44, 49). The HUD art is a static
# 640x480 background underneath; the blit is a plain rectangle, so growing it
# simply covers more of that background. The black surround at x 0..43 / 596..639
# and y 0..48 is therefore free real estate.
#
# Panel art begins at y=318 (measured from HUDOFF.PCX), so a 640x318 view at the
# origin fills everything above it without clipping a single pixel of the panel.
# That is +31% viewport area before any art is touched.
$VIEW_W_OLD = 0x228   # 552
$VIEW_H_OLD = 0x11A   # 282
$VIEW_X_OLD = 0x2C    # 44
$VIEW_Y_OLD = 0x31    # 49
# ---- instrument panel geometry ---------------------------------------------
# $PANEL_SCALE 1.0 means the panel is NOT touched: the artwork keeps its size and
# its (0,318)-(639,479) position, so every hot-spot rectangle in the game is still
# correct and every button lights up where it should. Everything below that is
# gated on $ENABLE_PANEL_RESCALE and only comes back if the scale changes.
$PANEL_SCALE     = 0.55
$PANEL_TOP_OLD   = 318                                        # first row of panel art
$ENABLE_PANEL_RESCALE = ($PANEL_SCALE -ne 1.0)
# First row of the 3D viewport. DEFINED HERE, used as $VIEW_Y far below, because the
# injection rectangle needs it long before the viewport block runs. It is a constant
# 49 at EVERY resolution and must stay one -- see the long note at $VIEW_Y.
$VIEW_Y_KEEP     = 49
# ---- the hi-res scale ---------------------------------------------------------
# 800x600 is 4:3 exactly like the stock 640x480, so the ENTIRE layout is the same
# design at a single uniform factor -- no aspect correction, no per-axis fiddling.
# Every destination coordinate is a 640x480 coordinate multiplied by this.
#
# It folds straight into the panel scale, so To-PanelX/Y keep working unchanged
# and produce screen-space coordinates at whatever resolution is selected.
$HS = $SCREEN_W / $SCREEN_W_OLD                  # 1.25 at 800x600, 1.0 at 640x480
function Hi([double]$v) { [int][Math]::Round($v * $HS) }
$VS = $SCREEN_H / $SCREEN_H_OLD
if ([Math]::Abs($VS - $HS) -gt 0.001) {
    # Not fatal, but everything below assumes one factor. The panel is scaled
    # UNIFORMLY and bottom-anchored, so it and everything placed through
    # To-PanelX/Y stays correct -- the extra height simply becomes viewport. What
    # breaks is anything holding a stock SCREEN coordinate scaled by Hi(), which
    # is now short in Y by the aspect difference. $MAP_Y is the one that matters:
    # it is "panel top + 6" expressed as an absolute, so it floats off the panel.
    Write-Host ("  WARNING: {0}x{1} is {2:N2}:1, not 4:3 -- Hi() is {3:P1} short vertically; panel-relative placement is unaffected" -f `
                $SCREEN_W, $SCREEN_H, ($SCREEN_W / [double]$SCREEN_H), (1 - $HS / $VS))
}
$PANEL_SCALE_EFF = $PANEL_SCALE * $HS
# The rounded viewport corners, passed to Build-HudTop as -Radius and published in
# the manifest for the installer. It was a literal 26 at both 800x600 and 1024x768,
# which means it had stopped being a proportion of anything: at 1600 wide a 26 px
# corner is almost square. Expressed against the 1024 build it comes back as 26
# there and 41 at 1600.
$CORNER_RADIUS = [int][Math]::Round(26 * $HS / 1.6)

$PANEL_H_NEW     = [int][Math]::Round((480 - $PANEL_TOP_OLD) * $PANEL_SCALE_EFF)
$PANEL_W_NEW     = [int][Math]::Round(640 * $PANEL_SCALE_EFF)
$PANEL_TOP_NEW   = $SCREEN_H - $PANEL_H_NEW
$PANEL_LEFT_NEW  = [int](($SCREEN_W - $PANEL_W_NEW) / 2)
$PANEL_RIGHT_NEW = $PANEL_LEFT_NEW + $PANEL_W_NEW - 1
# 16.16 reciprocal of the scale, so the inverse transform is one imul + one sar
# instead of a division: stock = (screen - origin) * $PANEL_RECIP >> 16.
$PANEL_RECIP     = [int][Math]::Round(65536 / $PANEL_SCALE_EFF)
function To-PanelX([int]$stockX) { $PANEL_LEFT_NEW + [int][Math]::Round($stockX * $PANEL_SCALE_EFF) }
function To-PanelY([int]$stockY) { $PANEL_TOP_NEW  + [int][Math]::Round(($stockY - $PANEL_TOP_OLD) * $PANEL_SCALE_EFF) }

# ---- actor / animation rate --------------------------------------------------
# Percent of frames on which actors advance. 100 = stock (every frame), which is
# what makes characters speed up when you raise the emulated CPU, because the
# game has no clock in its animation path at all.
#
# Set it to (the cycles the game looked right at) / (the cycles you now run) x 100.
# 280000 was the old ceiling and 400000 is the current setting, so 70.
#
# Tunable in an installed build without rebuilding -- it is published in the
# manifest's settings as 'aztActorPct'.
$ACTOR_PCT = 70
$ENABLE_ACTOR_RATE = ($ACTOR_PCT -ne 100)

# ---- and why the percentage is the WRONG shape of fix -----------------------
# A fixed share of frames can only be right at ONE frame rate, and the frame rate
# is not one number: it depends on how much geometry the room has. Symptom that
# proved it -- animations too fast in the opening area, correct after walking
# through to a heavier one, with no setting changed in between.
#
# So gate on the CLOCK instead. The BIOS tick at linear 0x46C runs at 18.2065 Hz
# no matter what the renderer is doing, and the game reads it exactly that way
# itself (0x1BC5F and 0x35D50 both do `mov eax,0x46C; mov ecx,[eax]`), which also
# proves low memory is identity-mapped under DOS/4GW -- no base register, no
# fixups. Actors then advance at a fixed rate in real time, and the dial stops
# needing to be re-tuned every time anything else changes.
#
# aztPeriod is in hundredths of a tick: 100 = one tick = 18.2 steps/sec, 50 =
# 36.4, 200 = 9.1. 18.2 Hz is very close to where the percentage dial had landed
# by hand (50% of a ~35 fps frame rate), which is a good sign it is near what the
# original ran at.
$ACTOR_PERIOD = 100

# ---- animation rate ----------------------------------------------------------
# THE ACTOR STEPPER IS NOT WHERE ANIMATION COMES FROM. Setting aztPeriod to 400
# (4.6 Hz, four times slower) changed nothing on screen, which is the whole
# reason this exists. 0x261C0 is a SCRIPT INTERPRETER -- it walks a per-actor
# program counter at [actor+0x3C] over 0x23-byte opcodes and runs behaviour: move
# toward a point, wait, play a sound, start an animation. The mesh frames that
# actually deform a creature are advanced somewhere else entirely, and worse, the
# one caller of 0x261C0 is guarded by `cmp word [0x1525F2],0` at 0x13DE1 -- a flag
# that is SET in the opening room, so in the very room you would test in, the
# actor gate is not even reached.
#
# Animation is driven by Reality Lab MOVE CALLBACKS. 0x44DD0 is AddMoveCallback
# and 0x44D7C is SetTime; the engine invokes every registered callback once per
# rendered frame, from inside its own Move()/render traversal, and each callback
# does the same thing:
#
#   0x22C05  mov edx,eax / inc edx / mov [ebx+0x284],dx    characters, via 0x229A4
#   0x24294  the same three instructions again              characters, direct entry
#   0x1E347  fld1 / fild [ecx+4] / faddp / fistp [ecx+4]    room anims, via 0x1E2A8
#
# ONE ANIMATION FRAME PER RENDERED FRAME, with no clock read anywhere on the
# path. At the 40 fps cap that is 2.2x the 18.2 Hz the 1996 build was paced at,
# and it is why every walk cycle looks hurried.
#
# The fix is a single "has an animation step come due?" flag computed once per
# frame in AztFrameLimit -- the one hook that is unconditional -- and tested at
# all three sites. One flag rather than three accumulators is deliberate: every
# animation in the room has to advance on the SAME frames or they visibly drift
# apart, and the limiter is already the place that knows a frame boundary just
# happened and already has `now` in eax.
#
# MICROSECONDS, not ticks, because AztNow already returns microseconds and this
# rides on its result for free. 54925 us = 18.2065 Hz = the BIOS tick = the rate
# aztPeriod=100 pins the actors to, so animation and actor scripts share one
# reference. BIGGER IS SLOWER. Tunable in an installed build as 'aztAnimPeriod'.
#
# Never more than one step per rendered frame, so this can only ever slow
# animation down, never speed it up, and a frame rate below the animation rate
# simply means animation runs at the frame rate as it always did.
$ANIM_PERIOD_US = 54925
# ---- NPC pace (Josh, 2026-10-13): every character's TRAVEL and STRIDE at NPC_RATE_PCT % of the 18.2 Hz steps -- both
# through one accumulator (AztActorGate, AztNpcStride), so pose and travel slow together; doors, room animations and the
# player's walk bob (aztAnimDue) are untouched. Per character (the host's aztNpcTab from a room's "npcs"): an extra
# share and pauses. See the overlay's AztActorGate and docs\notes\azrael-npc-pace.md.
$ENABLE_NPC_PACE = $true
$NPC_RATE_PCT = 100     # (Josh, 2026-10-13: 90 felt too slow everywhere, then 95; now "all characters move at their 100% animation speed" -- only a room's "npcs" slow anyone: CORICORI's two creatures)
# THE CONVERSATION'S LOOK (Josh, 2026-10-13): the log box opens once the options print, not on the conversation flag
# (overlay AztConvBoxZ), and the game's blinking red "input locked" corner brackets are gone (no-lock-brackets-155DC;
# the host draws its own conversation cue). See docs\notes\azrael-conversation-ui.md.
$ENABLE_CONV_BOX_LATCH = $true
$ENABLE_NO_LOCK_BRACKETS = $true
# M OPENS AND CLOSES THE MAP (Josh, 2026-10-14: "Lets map the M key to open/close the map"). The game's key handler matched
# only a lower-case 'm' (0x135BC) and then refused while the weapon is out ([0x14721C], Space's sniper sight) -- so with the
# weapon drawn, or Shift / Caps Lock, M did nothing. Now 'm' and 'M' both go to the toggle 0x12954 (the same call opens and
# closes it), weapon or not. The map screen's own key gate (0x12BA3) already lets both through. See azrael-map-3d.md.
$ENABLE_M_MAP = $true
# NO SHOT ON THE MAP (Josh, 2026-10-14: "The gun must be disabled while viewing maps, as it keeps shooting while I click to
# drag"). The left-press handler 0x15A5C fires when the weapon is out ([0x14721C]: shot.wav, ammo 0x14694C - 1); its
# `jz 0x1607C` at 0x15AFC (no weapon: the ordinary click) now goes through AztFireGate, which also takes the ordinary
# click while the map / help screen is up (word 0x1525F2). The map's own click handling is unchanged.
$ENABLE_MAP_NO_FIRE = $true
# THE GAME'S OWN MAP, DRAWN RIGHT OR NOT AT ALL (Josh, 2026-10-14: "The old map is still showing in some rooms. Those maps
# became corrupted ... They can be removed completely ... In retro mode we will need to include the original low rez map art
# but make sure they are not corrupted"). The map screen composes into a 640x480 surface (0x12954: 0x1525E0, 0x280 x 0x1E0;
# MAPS.DAT's pieces are placed in 640x480) and 0x1588C blits it to (0, 0) every frame -- on a 1600x1200 screen a
# 640x480 picture in the top-left corner, part of it above the view where the host's true-colour picture does not reach.
# (Its backdrop had been resized to the screen, which no longer fitted the surface: the corruption -- Build-HudArt keeps it
# 640x480 now.) The blit's call (0x1589F) goes through AztMapBlit: the composed map is drawn centred in the 3D view, at its
# own size; and not at all while the host draws its 3D map (aztOldMapOff, written by the watcher in true colour).
$ENABLE_MAP_BLIT = $true

# ---- frame limiter -----------------------------------------------------------
# Gating the actor stepter alone was never going to be enough. The game is
# frame-tied in MANY places -- player movement is `pos += dir * constant` per
# frame at 0x1D747 -- so when the frame rate rises, everything rises with it.
# That is why the first room ran at hyperspeed and settled only once the room had
# enough going on to slow it down: same geometry, different frame rate.
#
# Capping the loop fixes the whole class at once, because every frame-tied system
# then advances at a fixed rate. 30 is still well above the ~18 Hz the game was
# built around, so it keeps most of what the linear framebuffer bought.
#
# AztNow returns MICROSECONDS (it used to return PIT ticks at 1,193,182 Hz, but
# that assumed a divisor the game reprograms -- see AztNow for the whole story).
# MEASURED 2026-09-24, and the cap was fiction at 48.
#
# Logged play sessions (AZTFPS.LOG, one sample per second) reached the cap ZERO
# times out of 91 samples at 1280x1024 and zero out of 115 at 1024x768. Sustained
# gameplay is ~22-24 fps at BOTH, so a 48 cap never limited anything.
#
# That matters beyond smoothness, because movement is frame-tied and $MOVE_SCALE
# divides by this number: at a 48 cap and an actual 22 fps you walk at 46% of the
# intended speed. Setting the cap near what the machine really sustains puts the
# speed back AND evens out the pacing, which is the whole purpose of having a cap.
#
# 24 is the measured MEAN (median 22). Frames above it get paced; the dips below
# still run as fast as they can. Raising it again only re-introduces the speed
# error -- and note Set-FrameCap.ps1 changes the PERIOD only, so a taste change
# there leaves $MOVE_SCALE stale. Change it HERE and rebuild to move both together.
$FRAME_CAP_FPS = 24
$FRAME_PERIOD  = [uint32][Math]::Round(1000000.0 / $FRAME_CAP_FPS)

# ---- FPS LOG (headroom measurement) ----------------------------------------
# Appends one 16-bit frame count per second to this file in GAME\AZRAEL. Costs 8
# bytes a frame in the clock blob plus ~100 in the overlay, and one 2-byte DOS
# write per second. Diagnostic: leave it OFF in anything shipped.
#
# It measures the CAP, not the machine, unless the cap is raised first -- see the
# note on AztFpsTick.
$ENABLE_FPS_LOG = $true
$FPS_LOG_NAME   = 'AZTFPS.LOG'

# ---- 3D SUPPRESSION A/B -- the offload-ceiling measurement ------------------
# DIAGNOSTIC ONLY. Turn this off for anything shipped: it deliberately stops the
# game drawing its 3D view for ten seconds at a time.
#
# THE QUESTION. [[azrael-perf-measured]] says the bottleneck is emulated CPU work
# that does not scale with screen area -- per-polygon transform/clip/setup -- not
# fill. If that is right, moving the renderer to the host (the proven injection
# path, [[azrael-view-injection]]) is the only remaining frame-rate lever. But its
# CEILING is whatever the game runs at with the 3D pass removed, and that number
# has never been measured. If it is 30 fps the whole offload design caps at 30.
#
# HOW. The engine's own 3D block is 0x14162..0x1418A, which it already skips when
# a full-screen 2D view is up (the branch at 0x14160 on $g_book). Its two calls are
# gated per site -- NOT by holding that flag, which corrupts the whole screen and is
# recorded as a dead end in the boot-sequence notes below. From the disassembly:
#
#   0x14182  call 0x3F0D0   -- viewport CLEAR; validates a rect, error 0xA on miss,
#                              CALLEE-POPS (`ret 4`), only 2 callers
#   0x14187  call 0x3F1B0   -- the scene pass; enumerates and walks a list.
#                              Plain `ret`, 11 callers, so it is gated per SITE.
#
# ---- TIER A: THE HOST OWNS THE VIEWPORT ------------------------------------
# $ENABLE_HOST_RENDER emits the two gates below and nothing else. They are keyed
# on `aztSup3D`, a dword THE HOST WRITES over the bridge -- 0 draw as normal,
# 1 skip the scene pass, 2 skip the clear as well. It ships 0, so a build with
# this on is byte-for-byte unchanged in play until something sets it.
#
# Deliberately NOT keyed on aztInjEnable, even though "the host is painting" and
# "stop drawing 3D" nearly coincide. aztInjEnable is the visor boot's flag too, and
# the boot wants the engine's 3D left alone underneath it. One flag per decision.
#
# WHAT THIS IS WORTH, MEASURED -- 2026-10-03, uncapped, 114 samples, level 1:
#
#   scene pass  0x3F1B0   44.70 ms   95.6% of the frame
#   clear       0x3F0D0    0.13 ms    0.3%
#   everything else        1.91 ms    4.1%   (input, script, HUD, audio,
#                                             movement, collision)
#
# 21.4 fps with the 3D, 522.2 without: the host-offload ceiling is **x24.4**, and
# ~x36 in a heavy room, where the baseline read 13-16 fps against the same ~512
# suppressed. The win GROWS with scene complexity, which is the right shape.
# Handing the scene pass to the host leaves the guest ~1.9 ms of work, and that is
# the entire premise of Tier A.
#
# THE MEASUREMENT ONLY WORKED ONCE THE CAP CAME OFF, and the first attempt proved
# it the hard way: a clean 114-sample run returned 22 fps in EVERY condition, dead
# flat, whether the scene pass ran or not. AztFrameLimit SPINS until aztFramePeriod
# elapses (0x50F38..0x50F4B), so work removed from the frame is handed straight back
# as spin and the loop still delivers its 24 fps ceiling. Read-Perf's own header
# said so -- "it measures the CAP, not the machine, wherever the machine could go
# faster". **Any future headroom experiment must lift the cap first.** A host-render
# session wants it lifted too: the host raises it by writing aztFramePeriod, whose
# address is in the manifest's settings table.
#
# A capped sample of 22 does NOT mean the cap is slack -- in that first run it was
# clamping a 522 fps frame down to 22. The limiter exits its spin one clock read
# late, so the achieved period is period + ~3-4 ms of overshoot, which is why capped
# readings sit at 22-23 and never reach 24.
#
# The timed A/B harness that produced these numbers has been REMOVED: it cycled
# phases on a 40-second timer, blanked the viewport and uncapped movement, and its
# job is done. The two gates it used are what remain, now driven by the host.
$ENABLE_HOST_RENDER = $true

# ---- SPLITTING THE SCENE PASS: draw vs simulation --------------------------
# PROVEN BY A/B IN GAME: setting aztSup3D = 2 freezes the player completely -- camera
# moved 0 units and turned 0 degrees across a 25 s run, against 789 units and 175
# degrees with suppression off. So `0x3F1B0` is NOT just drawing; it also advances the
# simulation, which is consistent with it walking a list and calling 0x5B7F0 per scene
# element (Reality Lab's per-frame Move callbacks -- the same ones the animation work
# found, see [[azrael-frame-tied-timing]]).
#
# THAT INVALIDATES THE x24 CEILING as stated. Suppressing 0x3F1B0 took the game from
# 21.4 to 522 fps, but that was the game with no SIMULATION, not the game with no
# RENDERER. The true offload gain is smaller and is not yet known.
#
# So gate its three internal calls separately and find out which is which:
#
#   bit 0  0x3F1EA -> 0x5B7F0   once per scene element; 1 caller
#   bit 1  0x3F202 -> 0x39C14   shared (many callers), so gated per SITE
#   bit 2  0x3F209 -> 0x5B820   its result is TESTED -- the skip path must return al = 0
#                               or the engine takes its error branch into 0x32E60
#
# All three sites are fixup-free and all three targets end in a plain `ret`, so the
# stubs are caller-pops and need no `ret N` (the 0x34C40 trap, see
# [[azrael-status-gauge]]).
$ENABLE_SCENE_SPLIT = $true

# TAG THE FPS SAMPLES so the analysis cannot be wrong about which condition a
# second belongs to. The log writes one 16-bit value per second; measured counts
# never exceed ~40, so the high nibble is free:
#
#   bits 0..11   frame count (4095 max -- 100x any measured value)
#   bits 12..13  render level - 1, read from word [0x14686C]
#   bits 14..15  suppression phase
#
# That makes the SECOND experiment free as well: the game's own render divider
# (keys 1/2/3/4) is still live, so holding each level for a while during the same
# run gives frame rate as a function of (level, phase) -- fill cost and
# per-polygon cost separated, in one sitting, with no second build.
$ENABLE_FPS_TAGS = $ENABLE_FPS_LOG -and $ENABLE_HOST_RENDER
$g_renderLevel   = [uint32]0x14686C   # the live render level, 1..4 (0 before setup)

# ---- CAMERA TRANSFORM LOG ---------------------------------------------------
# The §14 experiment from docs\AZRAEL_REMASTER_FEASIBILITY.md: prove that the
# live camera transform can be READ from the running game before considering any
# host-side renderer. Nothing is changed -- this only observes.
#
# WHAT WAS ESTABLISHED STATICALLY (all from the game's own code, no guesses):
#
#   [0x152144]  camera frame HANDLE -- the frame passed to Viewport::Create at
#               0x10F65 (`mov edx,[0x152144]` right before the call). Written
#               once at 0x10F16 from 0x3A150 and never touched again.
#   [0x162DE4]  the frame the MOVEMENT code drives. All 13 references live
#               inside 0x1CF64..0x1E0A0; written once at 0x1E096.
#   [0x162DC0]  the cached eye-height Y that movement re-applies every frame.
#   [0x147ED8]  Reality Lab's root sentinel (0x554F0 walks parents until it).
#
# These globals hold HANDLES, not object pointers -- Frame::GetPosition (0x3C690)
# and Frame::SetPosition (0x3EC20) both pass them through 0x33048 first. So
# `[0x152144]+0x7C` would read garbage. The handle is resolved by 0x39E50, a
# pure chained-hash lookup (`div 0x3FD` into the bucket table at 0x1831CC,
# matching [obj+0x14]) with NO side effects at all -- which is why it is safe to
# call from the frame loop. 0x42410 is NOT the unwrap: it resolves the handle and
# then returns [root+0x14], the SCENE ROOT's handle, which is what the movement
# code uses as its reference frame.
#
# The object layout, read out of GetPosition itself rather than assumed:
#
#   +0x14  handle          +0x30  parent          +0x44  dirty byte
#   +0x18  type tag (compare against 0x147EDC to prove the object IS a frame)
#   +0x4C  local 4x4       +0x90  world 4x4
#
# GetPosition copies 0x11 dwords from +0x48 (or +0x8C when the reference is NULL)
# and then returns copy offsets 0x34/0x38/0x3C as x/y/z -- so each block is one
# leading dword followed by the 4x4, the translation sits in the matrix's fourth
# row, and the positions land at +0x7C/0x80/0x84 (local) and +0xC0/C4/C8 (world).
# That reconciles the two encodings exactly, which is the check that says the
# layout is right rather than merely plausible.
#
# 0x554F0, the lazy transform refresh, is deliberately NOT called: the renderer
# has already consumed the world matrices by the time the frame hook runs, so
# they are clean, and calling it would mean mutating engine state to observe it.
#
# Decode with tools\Read-CamLog.ps1.
$ENABLE_CAM_LOG = $false
# ---- PUBLISH THE CAMERA RECORD WITHOUT WRITING A FILE -----------------------
# The record (aztCamRec, magic 'CAM1') is what a host renderer reads to know where the
# player is standing and which way they are looking. It is filled every frame from the
# engine's own frames by AztCamSnap, which resolves the handle through the engine's
# 0x39E50 -- a pure lookup the host cannot perform itself, which is the whole reason
# the guest has to publish rather than the host simply reading a global.
#
# The FILE is a separate thing and stays off: a host renderer reads memory, and writing
# the same bytes to disk hundreds of times a second would put a DOS round trip inside
# the frame loop whose timing is the point of the exercise.
#
# Costs ~90 bytes of overlay and two 64-byte copies a frame.
$ENABLE_CAM_PUBLISH = $true
# Derived at the use site, below both flags, so it cannot become the silent $null -> 0
# that a derived value placed above its constants turns into.
$CAM_RECORD = $ENABLE_CAM_LOG -or $ENABLE_CAM_PUBLISH
$CAM_LOG_NAME   = 'AZTCAM.LOG'
$CAM_REC_LEN    = 320        # 0x140 -- see the record map at the data labels

# ---- SCENE GRAPH LOG --------------------------------------------------------
# Stage 2: enumerate the scene graph once a room is live. The tree shape came out
# of the recursive transform propagator at 0x55378, which must walk the hierarchy
# to push world matrices down and therefore names the links outright: `+0x3C`
# first child, `+0x34` next sibling, `+0x30` parent, root when the parent equals
# the sentinel in `[0x147ED8]`.
#
# One 160-byte record per frame node, written as the walk proceeds, so the staging
# cost is one buffer regardless of scene size. Each record carries the frame's
# whole HEADER (`+0x00..+0x4B`) so the attached-visual field can be identified
# offline rather than guessed at in the stub. Decode with tools\Read-SceneLog.ps1.
# ---- GEOMETRY EXPORT --------------------------------------------------------
# Stage 6: dump every mesh's COMPLETE vertex/face/normal arrays so a real OBJ can
# be built. The scene log established the format; this carries the payload.
#
# The payloads are written straight out of the engine's arrays -- INT 21h AH=40h
# takes any address -- so only a fixed 144-byte header per mesh is assembled, and
# mesh size is unbounded. Strides confirmed by dumping: vertices 48, faces 120
# (inline Face objects), normals 12. Decode with tools\Export-Obj.ps1.
# ---- TEXTURE PIXELS ---------------------------------------------------------
# Dumps each DISTINCT texture once (28 in room 1, shared across 117 meshes) with
# its pixels, so a textured OBJ can be built. Which of the Texture object's four
# heap pointers holds the pixels is NOT yet established, so both candidates are
# dumped along with probes -- one run settles it rather than guessing.
# ---- ANIMATION KEYS ---------------------------------------------------------
# Every Animation object plus all its keyframes, so characters can be posed and
# animated host-side. Layout derived from the three key-adders 0x456B0 (rotate,
# quaternion), 0x457AC and 0x458B0 (vec3) -- see the overlay block.
$ENABLE_ANI_LOG = $false
$ANI_LOG_NAME   = 'AZTANI.BIN'
$ANI_HDR_LEN    = 96
$ANI_KEY_LEN    = 40   # 'AKEY'(4)+list(4)+ptr(4)+28 raw = 40, NOT 36. At 36 every
                       # key lost its last 4 bytes -- the fourth quaternion
                       # component -- and the next record's magic read in its place.
                       # Unit length recovers the magnitude but not the SIGN, and the
                       # component order is unknown, so guessing was not an option.

$ENABLE_TEX_LOG = $false
$TEX_LOG_NAME   = 'AZTTEX.BIN'
$TEX_HDR_LEN    = 128   # 64 of fields + a 64-byte .azf filename
# De-dup slots per room. 32 was too few and it showed: room04 references 53 distinct
# textures and room07 41, so both silently lost art once the table filled.
$TEX_TAB_SLOTS  = 256
# Filename hashes remembered for the WHOLE session, so a texture's pixels are written
# once however many rooms share it or however often a room is revisited.
$TEX_SEEN_SLOTS = 1024

# ---- full-frame view injection: the host draws the 3D viewport --------------------
# Proven with a 256x16 strip; this is the same mechanism at full size. The staging
# buffer is a GUEST HEAP allocation (589,824 bytes is far past the 53 KB BSS window),
# made once at overlay init and costing the texture cache 576 KB.
#
# The copy is one flat rep movsd, so INJ_W must equal the surface stride and
# INJ_W*INJ_H must divide by 4.
$ENABLE_VIEW_INJECT = $true
# DERIVED, never written down. These were literal 1024/576 and so silently belonged
# to one resolution: the surface really is $SCREEN_W wide and the viewport really is
# $VIEW_H tall, and a mismatch here does not fail the build -- it shears the injected
# image exactly like the MF stride bug did to the opening movie.
#
# $VIEW_H is computed much further down (it needs the panel geometry), so it is
# recomputed here from the same two terms rather than read early and silently $null.
# See [[azrael-powershell-null-ordering]] -- a derived value placed above the thing it
# derives from becomes 0 and the build still succeeds.
$INJ_W       = $SCREEN_W
$INJ_H       = $(if ($ENABLE_PANEL_RESCALE) { $PANEL_TOP_NEW } else { $PANEL_TOP_OLD }) - $VIEW_Y_KEEP
$VIEW_STRIDE = $SCREEN_W   # surface bytesPerLine == screen width in every LFB mode
# 0, AND IT CANNOT BE ANYTHING ELSE. AztInjBody is one flat `rep movsd` with no row
# loop, which is only correct when the staging buffer's stride equals the surface's
# -- so the injected rectangle must start at column 0 and span the full width.
#
# This was a PHANTOM: the assertion below read $INJ_X while nothing ever defined it,
# so it evaluated $null + $INJ_W and passed by luck rather than by being true. The
# derived-above-constant trap in its purest form -- a check that silently tests
# nothing is worse than no check, because it reads as coverage.
$INJ_X       = 0
if ($INJ_W % 4 -ne 0)  { throw "INJ_W $INJ_W must divide by 4 (the injection copy is rep movsd)" }
if ($INJ_H % 2 -ne 0)  { throw "INJ_H $INJ_H must be even (the shutter splits it in half)" }

# One site. Both 0x1419D and 0x141D2 measured 22 calls/sec with pixels surviving at
# 100%; 0x1419D is the earlier of the two. The HUD-text sites 0x143B4/0x143ED were
# probed and NEVER RUN, and the generic LFB blitters must not be hooked at all -- they
# serve the intro movie and hooking them hung the game.
$INJ_SITES = @(
    @{ At = 0x141D2; Target = 0x1F222; Note = 'after the crosshair lines, before the reticle circle' }
    # 0x141D2, NOT 0x1419D: this site is after the 0x3C690 call at 0x141B0.
    #
    # THAT IS NOT ENOUGH TO HIDE THE RETICLE, and the note here used to claim it was. The
    # visible circle is a SECOND draw, `call 0x38558` at 0x145FD, which is 0x42B bytes
    # PAST this hook -- so the overlay paints first and the circle lands on top of it.
    # Covering by draw order only works for what is drawn before the injection; anything
    # after it needs a gate. Both are gated: see BOOT_RET_SITES.
    #
    # This site was blamed for a freeze once and was innocent: the freeze was the boot's
    # bottom lip writing past the end of the staging buffer, at either site.
)

if ($ENABLE_VIEW_INJECT) {
    if ($INJ_W % 4 -ne 0) { throw "INJ_W must be a multiple of 4 (the copy is rep movsd); got $INJ_W" }
    # ---- the staging buffer's stride, in ASSEMBLY -----------------------------------
    # Row -> offset arithmetic used to be `shl eax,10`, i.e. x1024, written out at
    # sixteen separate sites. 1024 was the viewport width of ONE resolution and the
    # shift silently encoded it; 1600 is not even a power of two. Every site now goes
    # through these four helpers so there is exactly one place the stride is named.
    #
    # imul is 6 bytes against the shift's 3. The overlay has ~19 KB spare, and the
    # alternative -- padding the buffer out to a 2048 stride to keep the shift --
    # would have meant rewriting the flat `rep movsd` injection copy into a row loop.
    # That copy is proven and lives on the path that has frozen the game twice; the
    # arithmetic around it is cosmetic by comparison. Keep the blit, pay the bytes.
    function A-RowsBytes  { param($a,[string]$r='eax')
        switch ($r) { 'eax' { A-ImulEaxImm $a ([uint32]$INJ_W) }
                      'ecx' { A-ImulEcxImm $a ([uint32]$INJ_W) }
                      'edx' { A-ImulEdxImm $a ([uint32]$INJ_W) }
                      default { throw "A-RowsBytes: no emitter for $r" } } }
    function A-RowsDwords { param($a,[string]$r='eax')
        switch ($r) { 'eax' { A-ImulEaxImm $a ([uint32]($INJ_W / 4)) }
                      'ecx' { A-ImulEcxImm $a ([uint32]($INJ_W / 4)) }
                      default { throw "A-RowsDwords: no emitter for $r" } } }
    # A uniform random row in 0..limit-1 from the 16-bit value already in the register.
    #
    # NOT a mask. `and edx,511` reached row 511 of 576 -- 89% of the viewport, close
    # enough to look deliberate -- but it is 55% of a 928-row one, so the bottom half
    # of the visor would simply never glitch and the damage would read as a band. A
    # multiply-high is uniform over the WHOLE height whatever the height is, and the
    # register already holds a clean 0..65535 after the `shr reg,16` at every site.
    function A-RandRow { param($a,[string]$r,[int]$limit)
        if ($limit -lt 1 -or $limit -gt 65535) { throw "A-RandRow: silly limit $limit" }
        switch ($r) { 'eax' { A-ImulEaxImm $a ([uint32]$limit); Add-Bytes $a @(0xC1,0xE8,0x10) }
                      'edx' { A-ImulEdxImm $a ([uint32]$limit); Add-Bytes $a @(0xC1,0xEA,0x10) }
                      default { throw "A-RandRow: no emitter for $r" } } }
    # x is still picked with a mask, because every x site already clips on the right
    # edge and can simply skip the artifact -- the row sites cannot, they have no
    # skip path at all. The mask has to COVER the viewport or the right-hand columns
    # go untouched, so it is the next power of two up and the clip absorbs the rest.
    $INJ_X_MASK = 1; while ($INJ_X_MASK -lt $INJ_W) { $INJ_X_MASK = $INJ_X_MASK * 2 }
    $INJ_X_MASK = $INJ_X_MASK - 1
    if (($INJ_X + $INJ_W) -gt $VIEW_STRIDE) { throw 'injection rectangle runs past the surface width' }
    $lastBand = $INJ_Y + ($INJ_SITES.Count - 1) * $INJ_BAND_STEP + $INJ_BAND
    if ($lastBand -gt $INJ_H) { throw "the last probe band ends at row $lastBand, past the $INJ_H-row viewport" }
    if ($INJ_BAND_STEP -lt $INJ_BAND) { throw 'bands would overlap, so a screenshot could not tell the probes apart' }
    # NO BSS RESERVATION FOR THE STAGING BUFFER. An early version parked it at
    # OVERLAY_BASE+0x5000 and guarded that it fitted the window; the buffer has long since
    # come from the game's own allocator (0x32CE0) instead, and that leftover guard implied
    # the overlay only had 0x5000 to grow into. It has the whole window.
}
$ENABLE_GEO_LOG = $false
$GEO_LOG_NAME   = 'AZTGEO.BIN'
$GEO_HDR_LEN    = 464        # 0x1D0

# Multi-room capture: re-fires on every room change, so one play-through archives the
# game. The trigger is the ROOT FRAME'S FIRST CHILD, not the music cue -- rooms are
# rebuilt on entry so that pointer always changes, whereas adjacent rooms can share a
# music track and would be silently skipped.
$SCN_MAX_ROOMS = 250      # the game has 179 rooms; a cap stops runaway growth
$ROOM_REC_LEN  = 32

$ENABLE_SCENE_LOG = $false
$SCENE_LOG_NAME   = 'AZTSCN.LOG'
$SCN_REC_LEN      = 1456     # 0x5B0

# ---- CD AUDIO ---------------------------------------------------------------
# Recorded music in place of the MIDI cue, via CD redbook audio. See the overlay
# block for how it works and what is still unproven.
#
# The slot numbers are the game's own music table order at 0x152A34, read out of
# the name strings the GM branch installs at 0x138E6:
#   0 awemyst  1 cathedrl  2 egyptian  3 fight2   4 ghosts  5 grail
#   6 ingame   7 ingame2   8 kreepy2   9 kreepy3  10 peaceful
#
# A slot absent from $CD_TRACKS keeps its MIDI cue, so tracks can be added one at
# a time as they are recorded. lba/sectors/us come from the CUE: track 1 is
# AZT.BIN at exactly 217,272 sectors of 2352 with no remainder, so audio track 2
# starts on the boundary at LBA 217272.
$ENABLE_CD_AUDIO = $true
# Writes AZTCD.LOG: 8 bytes per event (dword code, dword value) so a reproduction
# can be read back. Diagnostic only -- turn it off before any release.
$CD_DIAG         = $false

# --- visor boot sequence ------------------------------------------------------
# Holds the 3D pass off for a moment at startup so the viewport can "boot" like a
# screen coming on. PHASE 0 is the plumbing only: a black viewport, then a clean
# handover. The drawing comes later; this exists first because a stuck flag means a
# permanently black viewport, and that risk is worth proving on its own.
#
# HOLD is the intended length. CAP is a backstop that releases the view no matter
# what state the sequence is in -- it is deliberately not the same constant, so that
# a later phase which wedges mid-animation still hands the viewport back.
$ENABLE_BOOT_SEQ = $true
# --- the host's field of view ---------------------------------------------------------
# FIELD OF VIEW (Josh, 2026-10-13: the 50 degree view "is a major reason why this game still doesn't feel modern"; 60 by
# default, 50/60/70 to judge in game). The engine's field is Reality Lab's SetField (0x3A8A0), set to 0.8 in exactly
# four places (0x10F83 startup, 0x11145 the 1/2/3 render level, 0x11398 / 0x11403 the viewport re-created on a room
# load or a close-up) and never changed at run time. The game's cursor pick (0x116E4 -> 0x3BBC4 -> 0x3C1A4) reads the
# viewport's field live, so changing the GAME's field keeps clicks, hover and shots lined up with a host picture drawn
# at the same angle -- the reason a host-only wider view was turned down on 2026-10-05.
# AztFovTick, every frame before the render and the pick: the host writes aztFovTan = tan(vertical FOV / 2) (0 = leave
# the game alone: -Retro, an older host); the overlay turns it into Reality Lab's field for THIS viewport -- the
# half-extent of its larger side, as 0x59404 applies it: x max(1, (w x sx) / (h x sy)) -- and calls SetField when the
# viewport's own field differs (a new viewport from a room load or the 1/2/3 keys comes back at 0.8 and is caught
# before it is drawn). [[azrael-fov]]
$ENABLE_HOST_FOV = $true
# An extra movie, played on the first gameplay frame -- after the game's own intro movies
# and before the visor boot, so the player is given context instead of simply appearing.
# 1024x576 at 12 fps: full screen width, 16:9 letterboxed by the player's own centring,
# and the same 12 fps and 22,050 Hz audio the shipped movies use.
# A SHORT re-boot when a save is loaded, so the visor "wakes" rather than the world simply
# appearing. It is the tail of the same sequence, entered partway through: the clock is set
# back so the run starts at BOOT_REBOOT_FROM, which lands in the mission phase (blanked for
# a reload) and runs on into the shutter and the calibration. About 2.1 s.
#
# Entering the existing timeline rather than writing a second one is the whole trick --
# every beat is a build-time immediate, so a "faster" version would have meant duplicating
# all of them.
$ENABLE_REBOOT_ON_LOAD = $true
$BOOT_REBOOT_FROM      = 14800000
$ENABLE_OPENING_MOVIE = $true
$OPENING_MOVIE_NAME   = 'opening.mov'      # relative: the working directory is GAME\AZRAEL
# 10, NOT 12 -- and this is a format constraint, not a preference. The audio chunk must be
# the same size in every frame (see Convert-ToAnim.ps1), which means the sample rate has to
# divide evenly by the playback fps. 22050/10 = 2205 exactly; 22050/12 = 1837.5, which made
# the chunk alternate 3,674/3,676 bytes, walked the frame's chunk boundary two bytes per
# frame and sheared the picture. Every movie the game ships is played at 10.
$OPENING_MOVIE_FPS    = 10
# Routes the reticle draw at 0x141B0 through a gate so it is hidden while the boot
# overlay is up. Its own flag: if anything regresses, turn THIS off and rebuild to
# isolate it from the rest of the sequence.
$BOOT_HIDE_RETICLE = $true
# The reticle is drawn by TWO calls, and only the first is covered by draw order. Each is
# gated on its own: 0x3C690 and 0x38558 are generic primitives with many callers, so
# neither can be suppressed wholesale. Each stub tail-jumps to the real routine when the
# boot is not up, so ordinary play is byte-for-byte unchanged.
$BOOT_RET_SITES = @(
    @{ At = 0x141B0; Target = 0x3C690; Note = 'crosshair lines (before the injection)' }
    @{ At = 0x145FD; Target = 0x38558; Note = 'reticle circle -- AFTER the injection, so it drew over the overlay' }
    # The ammo count. Drawn at cursor+(-11,-45) by the same generic text routine the rest
    # of the HUD uses, which is why it is gated per call site and not at the routine.
    # 0x14739 is the gapped-crosshair variant of the same draw: it is not the one that
    # runs today, but it is gated too so the block stays coherent if that path is ever
    # restored -- the same reason the view-reticle offsets patch its siblings.
    @{ At = 0x1465A; Target = 0x38EC8; Note = 'ammo count beside the reticle' }
    @{ At = 0x14739; Target = 0x38EC8; Note = 'ammo count, gapped-crosshair variant' }
)
# One stub per DISTINCT target, shared by every site that calls it: the stubs differ only
# in their tail jump, so four sites need three stubs.
$BOOT_RET_TARGETS = @($BOOT_RET_SITES | ForEach-Object { [int]$_.Target } | Sort-Object -Unique)
$BOOT_HOLD_US    = 16900000     # the sequence's own length
# How long after the animation starts the boot effect is asked for. The track is 14.0 s and
# the sequence 16.9 s, so it cannot cover the whole thing; a second of lead-in puts the
# remaining gap at the END, where it settles rather than stops.
#
# This became tunable only once the LBA table was fixed. Before that the drive played 5.57 s
# of PEACEFUL's fade-out first -- the "CD start latency" the rest of this timeline was built
# around -- so where the request went made no predictable difference. See [[azrael-music]].
$BOOT_FX_DELAY_US = 1000000
# --- reticle calibration ------------------------------------------------------
# A square box that closes in on the viewport centre once the shutter is fully open, so
# the visor "acquires" its aim point just before the game's own reticle appears.
#
# It is drawn straight into the SURFACE, not into the staging buffer: by this point the
# shutter has opened all the way, which means the injection copies nothing at all and the
# staging buffer is not on screen. That is also why it can be drawn safely -- see the
# placement note in the hook stub.
$BOOT_CALIB_US = 500000
$BOOT_CALIB_R0 = 140            # half-size at the start...
$BOOT_CALIB_R1 = 22             # ...and where it settles, about the reticle's own size
# ---- the boot animation's inks are DERIVED from the live HUD palette ----------
# THEY WERE HARD-CODED INDICES, AND THAT BROKE SILENTLY AT 1600x1200.
#
# Build-HudSkin regenerates HUD3.PCX for each resolution and its palette comes out in
# a different ORDER, so every literal index here pointed at a colour it was never
# chosen for. Measured against the regenerated art (fill went luma 119 -> 168):
#
#   ink            designed offset   actual offset
#   scanline            -26              -102     4x too dark
#   corruption          +30               -49     INVERTED
#   refresh line        +44               -19     INVERTED
#   shutter lip         +63               -36     INVERTED
#   telemetry           +14               -78     INVERTED
#
# Four elements meant to FLARE were drawing darker than the screen. That is the
# "dark lines that shouldn't be there" which survived three wrong diagnoses -- display
# scaling, scanline band height, and block phase -- and nothing asserted, because
# $BOOT_LUMA was a hand-maintained table that had drifted with the art.
#
# So pick by INTENT: a luma offset from the screen fill, resolved against whatever
# palette the art actually has. Re-running Build-Art can no longer invert them.
$BOOT_PAL_SRC = Join-Path $PSScriptRoot '..\art\HUD3.PCX'
if (-not (Test-Path $BOOT_PAL_SRC)) {
    throw "the boot inks are derived from art\HUD3.PCX, which is missing -- run src\Build-Art.ps1"
}
# A 256-colour PCX keeps its palette in the last 769 bytes behind an 0x0C marker. Read
# it raw: this runs long before the build Add-Types PcxTool.
$_pcxb = [IO.File]::ReadAllBytes((Resolve-Path $BOOT_PAL_SRC).Path)
if ($_pcxb[$_pcxb.Length - 769] -ne 0x0C) { throw 'art\HUD3.PCX has no trailing 256-colour palette' }
$BOOT_PAL = $_pcxb[($_pcxb.Length - 768)..($_pcxb.Length - 1)]
function BootLum([int]$i) { [int](0.299*$BOOT_PAL[$i*3] + 0.587*$BOOT_PAL[$i*3+1] + 0.114*$BOOT_PAL[$i*3+2]) }
# The screen is the anchor everything else is chosen relative to.
$BOOT_FILL_IX = 20
$BOOT_FILL_L  = BootLum $BOOT_FILL_IX
# Warm inks only, so a pick can never land on a grey or on the teal text ramp.
$BOOT_AMBER = @(1..53 | Where-Object {
    $BOOT_PAL[$_*3] -ge $BOOT_PAL[$_*3+1] -and $BOOT_PAL[$_*3+1] -ge $BOOT_PAL[$_*3+2] })
if ($BOOT_AMBER.Count -lt 8) { throw "only $($BOOT_AMBER.Count) warm inks in the HUD palette -- too few to choose from" }
function BootPick([int]$offset) {
    $want = $BOOT_FILL_L + $offset
    $hit  = $BOOT_AMBER | Sort-Object { [Math]::Abs((BootLum $_) - $want) } | Select-Object -First 1
    # THE SIGN IS THE POINT. A flare must stay brighter than the screen and a shadow
    # darker, whatever the palette happens to offer -- that is exactly what failed.
    if ($offset -gt 0 -and (BootLum $hit) -le $BOOT_FILL_L) { throw "no ink brighter than the fill for offset +$offset" }
    if ($offset -lt 0 -and (BootLum $hit) -ge $BOOT_FILL_L) { throw "no ink darker than the fill for offset $offset" }
    return [int]$hit
}
# ...and the same by ABSOLUTE luma, for the warm-up ramp, which climbs from a dark
# tube to the fill rather than sitting a fixed distance from it.
function BootPickL([int]$luma) {
    [int]($BOOT_AMBER | Sort-Object { [Math]::Abs((BootLum $_) - $luma) } | Select-Object -First 1)
}
$BOOT_CALIB_IX = BootPick 63    # the same gold as the shutter lips
# The crosshair that grows inside the box as it closes, so the beat ends on a lock rather
# than on a box that merely stopped shrinking. Arms reach the box edges exactly as it
# settles, because their length is the same fraction of r that the box has travelled.
$BOOT_CALIB_CROSS = $true

# --- phosphor ghost on the shutter --------------------------------------------
# A dim band trailing each retracting panel: phosphor does not switch off the instant the
# beam leaves it. The ghost is part of the COPIED panel, not of the revealed 3D -- the
# panels simply extend a few rows further in and those rows are painted dim.
#
# Its depth shrinks to nothing as the shutter completes, so the 3D is never left with a
# permanent dim border, and it is also capped at h so the two panels cannot cross while the
# opening is still only a few rows tall.
$BOOT_GHOST_ROWS = 10
# Also tracks the screen rather than staying put: the ghost reads as a trail only while it
# is well under the panel fill, and it has sat about 55-65 luma below it at every setting.
# 14 (#715118) was -65 under fill 19; 41 is -56 under fill 20, and more orange with it.
$BOOT_GHOST_IX   = BootPick -56 # warm and well under the panel fill

# --- glyph corruption ---------------------------------------------------------
# Whole character cells replaced by a cell from somewhere else on the same row, for one
# frame. It reads as the readout dropping characters rather than as more static, because
# what lands is a WRONG GLYPH rather than noise.
#
# Written into the staging buffer AFTER the text is drawn, never into the source bitmap:
# the buffer is repainted every frame, so the corruption heals itself and the real artwork
# is never touched.
$BOOT_GLYPH_CELLS = 7           # cells mangled when it fires
$BOOT_GLYPH_ODDS  = 3           # fires when (random AND this) == 0, so 1 frame in 4
$BOOT_CAP_US     = 21000000     # hard backstop, whatever happens
# The shutter opens VERTICALLY: a slit at the centre row growing up and down. That is
# still two panels retracting from the middle, it merges with the CRT warm-up, and it
# keeps the open band a CONTIGUOUS range of rows -- one flat rep stosd per frame
# instead of a 576-iteration per-row loop. A horizontal split would need the loop.
$BOOT_OPEN_SPAN  = 900000       # how long the shutter takes to retract
$BOOT_OPEN_US    = 15500000     # the shutter runs out over the last of the audio
# Palette indices, from the HUD's own amber ramp (only 1..53 belong to the HUD, and
# there is no grey in it at all -- the visor is an amber CRT, so the boot is too).
# THE SCREEN IS AMBER, not olive -- and ORANGE amber, not yellow. Three settings so far:
#   5/4   #716D59 / #595539   luma 108/83    the neutral end of the ramp; read as drab grey-green
#   19/49 #BE9239 / #A27531   luma 149/123   the warm side, but far enough up to read as YELLOW
#   20/16 #A67118 / #8A5510   luma 119/93    HERE: between the two, and a lower G:R ratio
# The 26-luma gap between fill and scan is held across all three, so the scanlines carry
# exactly as far whatever the brightness; and the hue moves by dropping green against red
# (G:R 0.77 -> 0.68) rather than by darkening alone, which is what takes it off yellow.
# Picked by measuring the palette for luminance and R-G, not by eye.
# $BOOT_FILL_IX is set with the ink derivation above -- it is the anchor the rest use.
$BOOT_SCAN_IX    = BootPick -18 # one step down from the fill: the CRT scanline
$BOOT_LIP_IX     = BootPick 63  # the bright edge of each retracting panel
$BOOT_INK_IX     = 88           # #72DFD6, teal -- matches the panel log, not the amber
# The disruption's bright marks. SEPARATE from the lip: the shutter's edge should stay the
# brightest thing on screen, but the corruption sitting 74 luma above the screen was harsh.
# It is the CONTRAST that was tuned and signed off, not the colour -- so this index follows
# the screen down rather than staying put: 25 (#D7B241) was +27 over fill 19, and 27 is +30
# over fill 20. It is also the more orange of the two, matching the screen's new hue.
$BOOT_ART_IX     = BootPick 30  # the corruption streaks: brighter than the screen
# #BEFBFF, a pale cyan. MEASURED, not guessed: the teal ramp runs 88 (#71DFD7) DOWNWARD to
# 103, so there is no brighter teal to flare to -- 88 is already the top of it. 55 is the
# brightest thing in the palette that still reads as the same phosphor rather than as a
# different colour, and it sits inside the 1..56 band that is safe to draw with.
$BOOT_FLARE_IX   = 55
$BOOT_CARET_IX   = 55           # the caret is the same phosphor, just always at full heat
# --- phase 2 effects ----------------------------------------------------------
# How long a newly revealed line stays hot before settling to normal teal. Real phosphor
# overshoots and decays; 120 ms is about three frames at this frame rate, which is enough
# to register as a flash without the line looking like it changed colour.
$BOOT_FLARE_US   = 120000
# The caret blinks on `elapsed >> 18` -- a 262 ms half-period, so ~1.9 Hz.
$BOOT_CARET_SHR  = 18
# Vertical hold slip: the whole image rolls, wrapping, for a few frames.
#
# THE FIRST VERSION WAS INVISIBLE, and the numbers are why. 1-8 rows on a screen that is a
# flat amber field with two thin edge bands displaces almost nothing the eye can lock onto;
# one frame at 24 fps is 42 ms; and 1-in-16 over 2.4 s is about three of those. Three
# 42 ms shifts of a few rows on a blank field is not an effect, it is a rounding error.
#
# So: a bigger roll, held for several frames, more often, and over a window that reaches
# the READOUT -- text is the only thing on this screen with enough structure to show a
# displacement at all.
# A beat of stability first: the banner starts drawing at 0.25 s and the picture should
# look like it is holding before it starts losing lock, or the very first thing the player
# sees is already broken and the slip has nothing to be a departure from.
$BOOT_SLIP_START_US = 1200000
$BOOT_SLIP_US       = 9200000   # runs past the disruption (7.2 s) and through the readout,
                                #   stopping before the closing line types at 9.7 s so the
                                #   last two beats are clean
$BOOT_SLIP_ROWS_MIN = 10        # rows = MIN .. MIN+SPAN-1
$BOOT_SLIP_ROWS_SPAN= 32        # must be a power of two (it is used as a mask)
$BOOT_SLIP_FRAMES   = 3         # held this many frames, so it lasts ~125 ms not 42
# Fires when (random AND odds) == 0. TWO rates, because the same density that reads as
# damage over the corruption reads as a fault over a clean screen: frequent while the
# disruption is up, occasional once it has gone.
# Halved from 7/31 when the split tear went in: three kinds of displacement at the old
# rates read as constant motion rather than as a picture that keeps catching itself.
$BOOT_SLIP_ODDS      = 15       # 1 frame in 16, while the disruption is running
$BOOT_SLIP_ODDS_LATE = 63       # 1 frame in 64, after it

# --- CRT warm-up --------------------------------------------------------------
# The screen comes up almost black and climbs the amber ramp to its normal colour, like a
# tube striking. The corruption is NOT dimmed with it -- a striking tube shows bright scan
# artifacts over a dark screen, which is exactly the contrast this opens on.
#
# Scan trails one step below fill, so the scanlines resolve as the picture brightens
# rather than being there from the first frame. Stage 0 has them equal: no contrast at all
# while the tube is barely lit.
# The amber ramp only has five usable steps (1..5), so a LONGER warm-up means holding each
# step for two stages rather than finding intermediate colours -- the neighbouring palette
# entries are a different hue and would make the tube change colour as it warms, not just
# brightness. Holding is also truer to a real tube: it sits dark, then rises.
# Every step is on the AMBER side of the ramp now, so the tube warms through deep orange to
# the screen's own colour instead of rising through olive and then changing hue at the end.
#
# THE RAMP HAS TO BE REBUILT WHENEVER THE FINAL COLOUR CHANGES, and that is a trap: the
# previous ladder climbed to 20 at stage 5 and 19 at stage 6, which was correct while the
# final was 19. Lowering the final to 20 left stages 5 and 6 ABOVE it, so the tube would have
# brightened past its own colour and then dimmed back into it. Nothing would have failed --
# it would just have looked wrong. Hence the monotonic assertion below.
# Lumas: 15, 15, 38, 63, 71, 84, 93, 119 (fill) / 15, 15, 15, 38, 63, 71, 84, 93 (scan).
# DERIVED LIKE THE INKS, and for the same reason: these were literal indices too, and
# against the regenerated palette the ramp stopped climbing -- stage 6 came out at luma
# 66 after stage 5's 149, i.e. the tube brightened and then went dark again.
#
# The shape is kept exactly: the original lumas were 15,15,38,63,71,84,93,119 against a
# fill of 119, so the ramp is expressed as those FRACTIONS of whatever the fill is now.
# The scan colour lags the fill by one stage, which is what makes the scanlines fade in
# as the tube comes up; the last stage must BE the normal pair, which is asserted below.
$_warmFrac = @(0.126, 0.126, 0.319, 0.529, 0.597, 0.706)
$_warmFill = @($_warmFrac | ForEach-Object { BootPickL ([int]($BOOT_FILL_L * $_)) }) +
             @($BOOT_SCAN_IX, $BOOT_FILL_IX)
$BOOT_WARM_STAGES = @(0..($_warmFill.Count - 1) | ForEach-Object {
    @{ Fill = $_warmFill[$_]; Scan = $_warmFill[[Math]::Max(0, $_ - 1)] }
})
# ---- CRT interlacing: OFF at 1600x1200 ---------------------------------------
# The scanline is every other row painted one palette step darker. At 640..1024 that
# reads as a CRT; at 1600x1200 it reads as banding, and Josh asked for it removed
# after three attempts to make it behave (a 2-row band made it markedly worse -- see
# $BOOT_SCAN_H).
#
# THE TELL THAT FOUND IT: the lines "only appear towards the end of the 7s and text
# screen loading, and fully on the mission/objective screen". That is a timing
# signature, not a display one -- during the disruption the glitch code repaints the
# background every frame, and only once it stops (7.2 s) does AztBootClear's scanline
# pass own the screen. A display-scaling artefact would have been constant.
#
# Collapsing scan onto fill is all it takes, and it is one edit rather than four:
# aztScanDw == aztFillDw makes AztBootClear's dark pass paint the fill colour, makes
# aztBootTab2 identical to aztBootTab so the text blocks stop interlacing too, and
# makes the refresh-line eraser repaint correctly whichever table it picks. The warm
# -up stages collapse with it so the tube still brightens, just without the stripe.
$ENABLE_BOOT_SCANLINES = $true
if (-not $ENABLE_BOOT_SCANLINES) {
    $BOOT_SCAN_IX = $BOOT_FILL_IX
    $BOOT_WARM_STAGES = @($BOOT_WARM_STAGES | ForEach-Object { @{ Fill = $_.Fill; Scan = $_.Fill } })
}
$BOOT_WARM_STAGE_US = 300000
$BOOT_WARM_US = $BOOT_WARM_STAGES.Count * $BOOT_WARM_STAGE_US   # 2.4 s, twice the old 1.2
# It now overlaps the slip and the tears, which both start at 1.2 s. That is deliberate:
# the visor glitching while the tube is still coming up reads better than the two phases
# being neatly separated.
# The last stage MUST be the normal colour: it is what the screen holds for the rest of the
# sequence, and the expansion tables are left rebuilt to it.
if ($BOOT_WARM_STAGES[-1].Fill -ne $BOOT_FILL_IX -or $BOOT_WARM_STAGES[-1].Scan -ne $BOOT_SCAN_IX) {
    throw 'the last warm-up stage must equal the normal fill/scan, or the screen never settles'
}
if ($BOOT_SLIP_ROWS_SPAN -band ($BOOT_SLIP_ROWS_SPAN - 1)) {
    throw "BOOT_SLIP_ROWS_SPAN must be a power of two; got $BOOT_SLIP_ROWS_SPAN"
}
# NO BRIGHTNESS FLASH. One was tried alongside the slip -- the screen jumping two steps up
# the amber ramp (fill 5 -> 7, scan 4 -> 6) for the slip's frames. It worked, but it read
# as the picture blinking rather than as the hold slipping, so it is gone. The variable
# fill/scan colours it needed are kept: they cost nothing, and the CRT warm-up in the next
# batch wants exactly that hook.
                                #   fill 5 (lum 110) over scan 4 (lum 84) keeps the same 26-point
                                #   gap that read well at 4/33, just brighter overall

# The game's OWN OS-intro banner, copied byte for byte out of R.EXE at 0x184B82..0x184C05:
# a large numeral 7 drawn in '7' characters. It appears as a block, not a line at a time,
# because that is how the engine's own boot screen presents it.
$BOOT_BANNER = @(
    '         77777777777777777'
    '                          77'
    '                        77'
    '                      77'
    '                    77'
    '                  77'
    '                77'
    '              77'
    '            77'
)
# The readout, one line at a time under the banner.
$BOOT_LINES = @(
    'DEPLOYING MS-2 HELMET INTERFACE...'      # (Josh, 2026-10-14; was 'INITIATING MS-2 HELMET H.U.D...')
    'SYSTEM CHECK INITIATING...'
    'FALL DETECTED, INITIATING SELF SCAN...'
    'NO INJURIES DETECTED...'
    'SUIT DAMAGE MINIMAL...'
    'RAPTOR HEART RATE... 125BPM...'
    'HEALTH SYSTEM INITIATED...'
)
# The closing line is NOT part of the block above: it types itself in, so it needs its own
# bitmap and its own scratch copy, exactly like the mission line.
$BOOT_FINAL_TEXT = 'SYSTEM CHECK COMPLETE.'
$BOOT_FINAL_H    = 16
# BOOT_FINAL_Y is DERIVED further down, from BOOT_TXT_Y + BOOT_TXT_ROWS: it must sit flush
# under the last readout row, and hard-coding it meant that adding or removing a banner
# line silently left a gap or an overlap.
$BOOT_FINAL_US   = 9700000      # starts typing 0.5 s after the last readout line. The gaps
                                #   either side of this line are kept tight on purpose:
                                #   they are the only slack left, and every 100 ms taken
                                #   out of them is 100 ms more on the objective.
$BOOT_FIN_TYPE_US = 900000      # ...over this long, then holds until the mission wipe
# Defined HERE, above the mission constants that reference it -- PowerShell would have
# silently resolved it to $null and built a zero-size font, not raised an error.
# ---- the boot animation's own scale ------------------------------------------
# EVERY size below was authored and tuned against a 1024-wide viewport. At 1600 the
# panel, the log and the gauge all scaled and the animation did not, so the readout
# sits as a small block in the middle of a big screen -- Josh's screenshot.
#
# Scaled against 1024 rather than 640 deliberately: 1024 is the layout that was
# actually signed off, so this reproduces THAT look at the new size instead of
# re-deriving a design nobody has seen. At 1024 it is exactly 1.0 and every number
# below is unchanged, so this cannot disturb the resolution it was tuned at.
# CAPPED, because the readout is stored as a 1bpp BITMAP IN THE OVERLAY and its byte
# cost grows as the SQUARE of this. The full 1600/1024 = 1.5625 assembled to 57,612
# bytes against the old 53,248-byte window (it ended at obj2's linked base then; it is
# 256 KB since 2026-10-11, see $OBJ1_VSIZE). 1.40 is 90% of the ideal size, which is not
# a difference you can see, and it is the size that was signed off -- left as it is.
$BOOT_DESIGN_W = 1024
# 1.40. It was briefly dropped to 1.25 to pay for 4-row block alignment while the
# scanline band was 2; that band is back to 1, the alignment costs nothing again, and
# 1.25 made the mission text illegible. 1.40 is the size that was signed off.
$BOOT_S_MAX    = 1.40
$BOOT_S        = [Math]::Min($INJ_W / [double]$BOOT_DESIGN_W, $BOOT_S_MAX)
function Bs ([double]$v) { [int][Math]::Round($v * $BOOT_S) }
# ...and an EVEN variant. The animation draws alternating scan lines, so anything
# that positions a row -- line height, the banner gap -- has to keep its parity or
# the scan pattern inverts from one line to the next. BOOT_TXT_Y is `-band -2` for
# the same reason.
# ---- the CRT scanline band, in rows ------------------------------------------
# The scanlines are not drawn as lines: every pixel goes through a byte -> 8-pixel
# expansion table, and a row is bright or dark purely by WHICH table it uses --
# aztBootTab emits the fill colour for background bits, aztBootTab2 the scan colour.
# So the band height is "how many consecutive rows use the same table", and it was
# hard-wired to ONE because the selection is a parity test.
#
# One row was right at 640..1024 wide. At 1600 it is 2.5x finer than designed: it
# stops reading as scanlines, it beats against the display's own scaling, and any
# phase difference at a block's edge shows the block as a rectangle -- which is what
# Josh photographed. Two rows restores the intended coarseness.
# ONE. 2 WAS TRIED AT 1600x1200 AND IS WORSE -- do not "fix" this again.
#
# The reasoning for scaling it was sound and the result was not: at ONE row the
# display's own resampling BLENDS the alternating rows into a mid-tone, which is why
# the interlace reads as a soft texture. At TWO rows the bands survive resampling
# intact, so instead of softening the pattern it made the scanlines genuinely
# visible and much darker -- the opposite of what was wanted. Josh: "the interlacing
# lines are darker than they were previously."
#
# The broad dark band people see in the lower third is NOT this: it is moire between
# the 1-row pattern and the non-integer vertical scale the display applies, and it
# belongs to `integer_scaling` in the conf, not to the animation.
#
# The machinery below (band-aligned blocks, the XOR table pick, the generalised
# clear) is all still correct and costs nothing at 1, so it is kept -- it just is
# not used. Set this to 2 only if the display is driven at an integer scale.
$BOOT_SCAN_H = 1
if ($BOOT_SCAN_H -notin @(1,2)) {
    # 4+ would need a different table-selection trick again; see the XOR note below.
    throw "BOOT_SCAN_H is $BOOT_SCAN_H; only 1 and 2 are implemented"
}
# The pattern repeats every 2 bands, so EVERY row quantity that positions a block or
# a line has to be a multiple of that or the bands step out of phase across it. At
# BOOT_SCAN_H = 1 this is "even", exactly as before.
$BOOT_ROW_ALIGN = 2 * $BOOT_SCAN_H
function Bse([double]$v) {
    $r = Bs $v
    $m = $r % $BOOT_ROW_ALIGN
    if ($m) { $r + ($BOOT_ROW_ALIGN - $m) } else { $r }
}
$BOOT_FONT_PX  = Bs 13          # readout, banner, closing line, mission header
# The text block. Narrowed 448 -> 320 to reclaim BSS: every bitmap is this wide, and three
# of them are stored twice (each typed element keeps a scratch copy), so the empty right
# margin was being paid for six times over. The longest line of anything drawn into it is
# the mission header at 273px, and the build asserts that below.
#
# Must be a multiple of 8 (it is a 1bpp pitch) and the pitch must fit an imm8, because the
# blit compares against it with `cmp ecx, pitch`.
# MULTIPLE OF 8, always: $BOOT_TXT_PITCH is $BOOT_TXT_W/8 and the block is packed
# 1bpp, so a width that is not a whole number of bytes silently loses the last few
# columns of every row. Rounded UP so the scaled ink cannot be clipped.
$BOOT_TXT_W    = [int][Math]::Ceiling((Bs 320) / 8.0) * 8
$BOOT_TXT_H    = Bse 16         # per line
# The closing line is rendered at readout size, so its bitmap is one readout line tall.
# It was a literal 16 declared ABOVE the scale helpers exist, which left it unscaled and
# -- worse -- not a multiple of the scanline band pair, so the closing line carried its
# own rectangle. Set here instead, where $BOOT_TXT_H is known; nothing reads it between.
$BOOT_FINAL_H  = $BOOT_TXT_H
# A blank line's worth of air between the banner and the readout beneath it. It is added
# INSIDE the bitmap and then subtracted from BOOT_TXT_Y, which lifts the banner by exactly
# this much and leaves the readout and closing line on the rows they were already on --
# the point being to move the 7 up, not to push the text down.
$BOOT_BAN_GAP  = Bse 16         # must be EVEN, like BOOT_TXT_Y, for scanline parity
# BOTH ARE DERIVED further down, from the INK rather than from the 448-wide container.
# They were 288 and 56: the container was centred, but the text is left-justified inside it
# and never fills it, so the visible block sat left of centre -- and 56 put it 96 rows above
# centre, which was the obvious one on screen.
                                #   so the readout rows line up with the scanline parity
$BOOT_HDR_US   = 650000         # line 0 appears here: the band only reaches y=120 at 629ms,
                                #   any earlier and the header floats on the black panel
$BOOT_BANNER_US  = 250000       # the banner starts drawing almost immediately
$BOOT_BAN_STEP   = 380000       # ...one line at a time, so it builds rather than appearing.
                                #   PACED TO FILL THE OPENING: 9 lines from 0.25 s finish at
                                #   3.29 s, which leaves a 0.7 s beat before the readout
                                #   instead of the 2.4 s hole this used to leave at 170 ms.
                                #   Slowing the banner is what buys that, rather than moving
                                #   the readout off the audio.
# Damaged-visor burst: static, edge dropout, flickering blocks and the bright pulsing
# bands top and bottom. Each row is one stage:
#   {centre streaks, edge dropout streaks, margin blocks, band rows}
#
# ROUGHLY EXPONENTIAL, ratio ~0.7 per stage: most of the reduction happens in the first
# third, and the last four stages are a near-empty tail. That is what stops it ENDING
# rather than fading -- with a linear ramp, or with few enough stages, the final step is
# from "clearly some corruption" to "none" and reads as a cut.
#
# THE BAND IS IN THE TABLE TOO. It used to pulse at a constant 4..11 rows for the whole
# burst and then vanish, which was its own abrupt cut regardless of what the artifacts
# did -- the brightest thing on screen switching off in one frame. It now decays with
# everything else and is gone a stage before the last artifact.
# Tear is a CHANCE OUT OF 256, not an odds mask: a mask cannot express "never", because
# (random AND 0) is always 0. The first two stages are 0 so the tearing starts at 1.2 s,
# once the tube has warmed and the picture has had a moment to look like it is holding --
# the same beat the hold slip starts on.
$BOOT_DIS_STAGES = @(
    #  streaks  edge  blocks  band  tear    t
    @{ Streaks = 54; Edges = 44; Blocks = 18; Band = 11; Tear =  0 }   # 0.0  heavy
    @{ Streaks = 38; Edges = 31; Blocks = 13; Band =  9; Tear =  0 }   # 0.6
    @{ Streaks = 26; Edges = 21; Blocks =  9; Band =  7; Tear = 12 }   # 1.2
    @{ Streaks = 17; Edges = 14; Blocks =  6; Band =  6; Tear = 10 }   # 1.8
    @{ Streaks = 11; Edges =  9; Blocks =  4; Band =  5; Tear =  8 }   # 2.4
    @{ Streaks =  7; Edges =  6; Blocks =  3; Band =  4; Tear =  6 }   # 3.0
    @{ Streaks =  5; Edges =  4; Blocks =  2; Band =  3; Tear =  4 }   # 3.6
    @{ Streaks =  3; Edges =  2; Blocks =  1; Band =  2; Tear =  3 }   # 4.2
    @{ Streaks =  2; Edges =  2; Blocks =  1; Band =  2; Tear =  2 }   # 4.8
    @{ Streaks =  1; Edges =  1; Blocks =  0; Band =  1; Tear =  1 }   # 5.4  a trace
    @{ Streaks =  1; Edges =  1; Blocks =  0; Band =  1; Tear =  0 }   # 6.0
    @{ Streaks =  1; Edges =  0; Blocks =  0; Band =  0; Tear =  0 }   # 6.6  all but gone
)
$BOOT_TEAR_ROWS_MIN  = 8        # band height: MIN .. MIN+SPAN-1
$BOOT_TEAR_ROWS_SPAN = 32       # power of two (used as a mask)
$BOOT_TEAR_SHIFT_MIN = 16       # sideways displacement, in pixels
$BOOT_TEAR_SHIFT_SPAN= 128      # power of two

# --- the sizes the glitch artifacts can reach, and the margins they live in ------
# These were literals spread across the emitters, with the clearance between them
# worked out in a comment ("x is masked to 0..63 and the length to 4..35, so the
# worst case is 98: that cannot leave the 160-wide margin"). That reasoning was
# correct and entirely about ONE viewport width -- at 1600 a 160 px margin is a
# third of the slice of screen it was drawn for, so the streaks bunched into the
# extreme edges. The margins now scale with the viewport and the clearance is
# CHECKED rather than reasoned about.
$BOOT_EDGE_LEN_MAX = 35         # streak length is 4..35 (mask 31 + 4)
$BOOT_BLK_W_MAX    = 19         # block width  is 4..19 (mask 15 + 4)
$BOOT_BLK_H_MAX    = 9          # block height is 2..9  (mask  7 + 2)
# Both margins are the 1024-era figures scaled by the viewport, which reproduces
# 160 and 96 exactly at 1024 -- this is a no-op there, not a re-tune.
$BOOT_EDGE_MARGIN  = [int][Math]::Round(160 * $INJ_W / 1024.0)
$BOOT_BLK_MARGIN   = [int][Math]::Round( 96 * $INJ_W / 1024.0)
# The x spread inside each margin stays a MASK, so it has to be a power of two
# minus one -- the largest that still leaves the artifact's own length inside the
# margin. At 1024 both come out at the hand-picked 63 and 63; at 1600, 127 and 127.
function Fit-Mask([int]$margin, [int]$maxLen) {
    $m = 1
    while ((($m * 2 - 1) + $maxLen) -le $margin) { $m = $m * 2 }
    $m - 1
}
$BOOT_EDGE_XMASK = Fit-Mask $BOOT_EDGE_MARGIN $BOOT_EDGE_LEN_MAX
$BOOT_BLK_XMASK  = Fit-Mask $BOOT_BLK_MARGIN  $BOOT_BLK_W_MAX
if (($BOOT_EDGE_XMASK + $BOOT_EDGE_LEN_MAX) -gt $BOOT_EDGE_MARGIN) { throw 'edge streaks can leave their margin' }
if (($BOOT_BLK_XMASK  + $BOOT_BLK_W_MAX)    -gt $BOOT_BLK_MARGIN)  { throw 'glitch blocks can leave their margin' }
if ($BOOT_EDGE_MARGIN -gt ($INJ_W / 2) -or $BOOT_BLK_MARGIN -gt ($INJ_W / 2)) {
    throw 'the two margins overlap in the middle of the viewport'
}

# --- the split tear -----------------------------------------------------------
# Not a band: everything BELOW a split row moves, and a second split below the first moves
# again on top of that. So the 7 keeps its head while its tail and all the text under it
# step right, then part of that steps right again -- the stepped look of a display losing
# sync, rather than a strip sliding across an intact picture.
#
# It is the same rotate the band tear uses, called twice on two stacked regions that both
# run to the bottom of the text block. The lower region therefore gets BOTH shifts, which
# is what makes the second step read as cumulative.
$BOOT_SPLIT_ODDS     = 31       # fires when (random AND this) == 0, so 1 frame in 32
$BOOT_SPLIT_SHIFT_MIN = 12      # each step, in pixels
$BOOT_SPLIT_SHIFT_SPAN= 32      # power of two
$BOOT_SPLIT_GAP_MIN   = 48      # least distance between the two split rows
$BOOT_SPLIT_GAP_SPAN  = 64      # power of two
foreach ($n in @($BOOT_TEAR_ROWS_SPAN, $BOOT_TEAR_SHIFT_SPAN)) {
    if ($n -band ($n - 1)) { throw "tear span $n must be a power of two; it is used as a mask" }
}
# The band can start on any row in 0..511 and is at most MIN+SPAN-1 tall, so the deepest
# row it can touch is 511+39 = 550 of 576. Checked rather than reasoned about once.
if ((511 + $BOOT_TEAR_ROWS_MIN + $BOOT_TEAR_ROWS_SPAN - 1) -ge $INJ_H) {
    throw 'a tear band can run past the bottom of the viewport'
}
$BOOT_DIS_STAGE_US = 600000
# DERIVED, never hard-coded: the stage index is el/STAGE_US and is only ever computed while
# el < DISRUPT, so this product is exactly what keeps the index inside the table.
$BOOT_DISRUPT_US = $BOOT_DIS_STAGES.Count * $BOOT_DIS_STAGE_US   # 7.2 s; overlaps the readout
# A MISSING KEY WOULD EMIT ZERO, not an error -- that column would silently disappear from
# the whole effect. Checked here so a typo in the table is a build failure instead.
foreach ($st in $BOOT_DIS_STAGES) {
    foreach ($k in @('Streaks','Edges','Blocks','Band','Tear')) {
        if (-not $st.ContainsKey($k)) { throw "disruption stage table: a row is missing '$k'" }
    }
}
if ($BOOT_DIS_STAGES[-1].Streaks + $BOOT_DIS_STAGES[-1].Edges +
    $BOOT_DIS_STAGES[-1].Blocks  + $BOOT_DIS_STAGES[-1].Band -gt 4) {
    throw 'disruption: the last stage is not a near-empty tail, so the burst will end as a cut'
}
# 4.0 s is where the CD effect becomes audible -- the track has ~4 s of start latency that
# cannot be removed, only worked around -- so the readout starts ON the sound. DO NOT move
# this to close a gap: the hole that used to sit here was fixed by slowing the banner's
# draw-in (BOOT_BAN_STEP) to fill the opening, which costs nothing in sync.
$BOOT_TEXT_US  = 4000000
$BOOT_MISSION_US = 11400000     # screen clears, then the mission block alone. It types for
                                #   1.2 s and then HOLDS until the shutter at 15.5 -- 2.9 s
                                #   fully up. The shutter and the total are pinned to the
                                #   audio, so this hold is whatever is left over: it grows
                                #   only by taking slack out of the beats above it.
$BOOT_MIS_CY   = [int]($INJ_H / 2)   # the block's vertical CENTRE: the MIDDLE OF THE
                                #   beat stays put as lines are added or removed
# The mission block deliberately does not follow BOOT_TXT_X -- it used to share it, so
# re-centring the readout silently dragged the mission along too.
#
# What is pinned is where the TEXT lands on screen, not where the block starts. The text is
# centred inside the block, so narrowing the block moves the text within it; deriving the
# block's X from the approved text position is what keeps the text put through changes to
# either the block width or the wording.
$BOOT_MIS_TEXT_X = Bs 368       # the screen column the mission text was signed off at
$BOOT_LINE_US  = 864000         # one line every this long; 12 lines ends at 13.5 s
# Stored 1 BIT per pixel: 640x192 is 15,360 bytes that way and 122,880 at 8bpp, and the
# BSS window only has ~40 KB left. Expansion at runtime is a 256-entry table lookup
# (bit pattern -> 8 bytes of fill/ink), which needs no bit twiddling in the blit: the
# text sits on the flat fill colour, so the copy can be opaque and there is no mask.
$BOOT_ALL_LINES = @($BOOT_BANNER) + @($BOOT_LINES)   # banner first, readout under it
$BOOT_TXT_ROWS = $BOOT_ALL_LINES.Count * $BOOT_TXT_H + $BOOT_BAN_GAP
# BOOT_TXT_X / BOOT_TXT_Y / BOOT_FINAL_Y are derived in the DERIVED block below, which is
# where the rasteriser they measure with is available.
# The mission block: a short header at the READOUT's size, then the objective at the
# larger size. All of it is ONE bitmap, so the existing left-to-right reveal wipes the
# whole block as a unit -- every line arrives together rather than one at a time, which
# is what separates this beat from the staggered readout above it.
$BOOT_MIS_SMALL = @(
    'MISSION: Aetermis Penetrated. 12/2/2012'
    'All systems functional'
)
$BOOT_MIS_TEXT = 'OBJECTIVE: LOCATE HOLY GRAIL'
$BOOT_MIS_PX   = Bs 16          # INTEGER: see the rasteriser note. 16 and 17 share an
                                #   advance width in Consolas, so 16 is the crisp one.
$BOOT_MIS_SM_PX = $BOOT_FONT_PX # the readout's own size, so the header matches it exactly
$BOOT_MIS_SM_H  = Bse 16        # ...and the readout's line box
$BOOT_MIS_GAP   = Bse 8         # between the header block and the objective
$BOOT_MIS_BIG_H = 32            # the objective's line box at 16px
# A warning marker above the block, left-aligned with the text: a filled octagon with a
# knocked-out "!". It lives IN the mission bitmap rather than being drawn as its own
# element, which means the existing left-to-right reveal types it in with everything else
# and it costs no extra code -- only the taller bitmap.
#
# The 1bpp expansion is what makes a two-tone icon possible at all: set bits become ink,
# clear bits become the screen, so a solid octagon of set bits with an unset "!" inside
# reads as a teal sign with the exclamation punched through it.
$BOOT_MIS_ICON_H   = 26         # the octagon is square, so this is its width too
$BOOT_MIS_ICON_GAP = 8          # between the icon and the first header line
$BOOT_MIS_TYPE_US = 1200000     # it must NOT still be typing when the panels retract;
                                #   the build prints and asserts the whole timeline below
# ONE scripted tear across the objective line, a beat after it has settled. Confined to the
# mission block's own rectangle so the next frame's blit repaints it -- see AztBootTearMis.
# TWO of them, so the briefing stutters twice rather than once. Both split at the same
# place -- the boundary between the header lines and the objective -- because that is the
# only seam in the block, and a shift there reads as the lower half letting go.
$BOOT_MIS_TEAR_US  = 13300000   # ~0.7 s after the block finishes typing
$BOOT_MIS_TEAR2_US = 14500000   # and again, before the shutter at 15.5
$BOOT_MIS_TEAR_DUR = 100000     # a few frames at 24 fps
$BOOT_MIS_TEAR_PX  = Bs 48      # sideways displacement of the mission block

# --- boot progress bar --------------------------------------------------------
# Under the readout, filling as the check proceeds. It reaches 100% exactly as
# "SYSTEM CHECK COMPLETE." finishes typing, which is what makes it feel like it was
# measuring something rather than just animating.
$BOOT_BAR_H        = Bse 10     # including the frame top and bottom
$BOOT_BAR_GAP_ABOVE = Bse 12    # between the readout and the bar
$BOOT_BAR_GAP_BELOW = Bse 12    # between the bar and the closing line UNDER it
$BOOT_BAR_TRACK_IX = BootPick -58  # warm, and clearly under the fill, so the empty
                                #   part reads as a groove rather than as more screen

# --- rolling refresh line -----------------------------------------------------
# A bright line travelling down the screen on a loop, the whole time the visor screen is up:
# the tube's own refresh beat. NOT the whole-screen brightness flash that was tried with the
# hold slip and cut -- that read as the picture blinking. A line that MOVES reads as scan,
# and it brightens the text's background without erasing the glyphs, because it only
# overwrites pixels that are currently the fill or the scanline colour.
#
# IT HAS TO ERASE ITSELF. Nothing repaints the background after the disruption's final clear
# (see AztBootClear), so a line drawn and left would smear a permanent bright streak across
# the screen. AztBootSweepOff repaints last frame's rows BEFORE anything else draws, which is
# also why the sweep is split into two routines rather than one.
# Like the artifacts, this follows the screen rather than staying at the top of the ramp: it
# was the lip colour (50, luma 182) at +33 over fill 19, which would have become +63 over the
# darker fill 20 and made the line far more prominent than it was signed off at. 34 is the
# brightest strongly-orange entry under it, at +44.
$BOOT_SWEEP_IX   = BootPick 44  # the refresh line: a bright beat across the screen
$BOOT_SWEEP_ROWS = 2
$BOOT_SWEEP_US   = 1500000      # one pass, top to bottom

# --- phosphor decay on the wipe -----------------------------------------------
# The readout used to be CUT at BOOT_MISSION_US -- one hard frame, in a sequence that is
# otherwise entirely analogue. Now its ink walks down the teal ramp first and the mission
# text lands on the afterglow.
#
# The window sits BEFORE BOOT_MISSION_US, not after: it eats the tail of the readout's hold
# rather than the mission's time on screen, so the briefing's timing is untouched.
#
# No new palette indices and no second pair of expansion tables: the ink is dimmed IN the
# tables (AztBootInk), so the text, the progress bar and the telemetry column all fade
# together with no per-element work.
$BOOT_DECAY_US   = 400000
$BOOT_DECAY_RAMP = @(92, 96, 100)   # the teal ramp, 88 (ink) descending to 103

# --- memory-dump telemetry column ---------------------------------------------
# A narrow column of hex words in the left margin, churning while the visor is damaged and
# freezing as the check completes. The readout says what the machine FOUND; this is the only
# thing on screen that says it is WORKING.
$BOOT_DUMP_US    = 800000       # before the banner: the machine was already booting
$BOOT_DUMP_COLS  = 4            # digits per row, so one 16-bit word
# WIDTH OF ONE HEX CELL, in pixels, and it must be a multiple of 8 -- the strip is
# packed 1bpp and the draw loop expands it a byte at a time.
#
# It was 8, sized for a 13px Consolas whose advance quantises to 7px. Scaling the
# animation took the digits to ~18px and they stopped fitting: the build reported
# "144 row(s) reach the cell edge", which is silent clipping, not a cosmetic issue.
#
# 16 rather than a byte-doubling table: the draw loop expands each byte through a
# 256 x 8 table, so a 16-wide cell would otherwise need a 256 x 16 table -- 4 KB per
# table, two tables, and the overlay has ~2 KB spare. Running the EXISTING table
# twice per row costs 16 bytes of strip per row and no new data, and renders the
# glyphs at 16 px rather than doubling them from 8.
$BOOT_HEX_CELL   = 16
if ($BOOT_HEX_CELL % 8) { throw "BOOT_HEX_CELL must be a multiple of 8 (1bpp strip); got $BOOT_HEX_CELL" }
$BOOT_DUMP_GAP   = Bs 72        # MINIMUM clearance between the column and the readout block
$BOOT_DUMP_PAD   = Bs 24        # margin from the viewport's left edge, so it does not butt it
# AMBER, NOT THE TEAL RAMP. The column used to be the readout's own ink pushed 8 steps down
# that ramp, which landed on index 96 -- #359578, luma 117, actually DARKER than the screen it
# sits on (120). It read as something switched off rather than as instrumentation idling.
#
# 21 is #C9790F: the same orange as the fill's #A47318, lifted to luma 133. Close enough to
# belong to the screen rather than sit on top of it, far enough to read. The teal is left to
# the readout, which is the only thing that should be competing for attention.
#
# A FIXED INDEX, so it no longer fades with the readout's decay. That coupling was deliberate
# once -- the old note warned about "a lit strip beside a fading block" -- but the column now
# runs the whole animation, through the mission wipe and on to the shutter, so staying lit
# while the readout fades is the behaviour that was asked for, not a regression.
$BOOT_DUMP_IX    = BootPick 14  # the telemetry column, just above the screen
$BOOT_DUMP_FAST  = 16           # cells re-rolled per frame while the disruption runs
$BOOT_DUMP_SLOW  = 3            # ...and after it, until the readout completes
# DERIVED, so adding a header line cannot leave the bitmap the wrong height: the blit
# copies BOOT_MIS_H rows whatever the content is, and a stale constant here would either
# clip the objective off or trail blank rows.
$BOOT_MIS_TEXT_TOP = $BOOT_MIS_ICON_H + $BOOT_MIS_ICON_GAP        # where the header starts
$BOOT_MIS_OBJ_ROW  = $BOOT_MIS_TEXT_TOP + $BOOT_MIS_SMALL.Count * $BOOT_MIS_SM_H + $BOOT_MIS_GAP
# ROUNDED UP TO A WHOLE BAND PAIR. It is a sum of line heights and gaps, so it lands
# wherever it lands -- and the block's scanline phase is derived from this total, so an
# unaligned value puts the mission block's background out of step with the screen and
# draws a faint rectangle round the text. The spare rows are blank bitmap, below the
# last line, so nothing moves.
$BOOT_MIS_H        = [int][Math]::Ceiling(($BOOT_MIS_OBJ_ROW + $BOOT_MIS_BIG_H) / [double]$BOOT_ROW_ALIGN) * $BOOT_ROW_ALIGN
$BOOT_TXT_PITCH = [int]($BOOT_TXT_W / 8)
if ($BOOT_TXT_W % 8) { throw "BOOT_TXT_W must be a multiple of 8; got $BOOT_TXT_W" }
if ($BOOT_TXT_PITCH -gt 127) { throw "the blit compares the pitch as an imm8; $BOOT_TXT_PITCH will not fit" }

# --- the boot text rasteriser -------------------------------------------------
# GDI (TextRenderer), NOT GDI+ (Graphics.DrawString). Everything here ends up bilevel, so
# the only thing that matters is how well-formed the glyph is BEFORE the threshold -- and
# GDI+ at these sizes produces broken stems and blobby counters that survive thresholding
# as visible mush. GDI's hinted rasteriser at an INTEGER pixel size gives clean, even
# stems: measured side by side it was not a subtle difference.
#
# Consolas quantises its advance width, so 12px and 13px are both 7px/char -- 13 is the
# taller glyph at no cost in width. Sizes must stay integers: a fractional size defeats
# the hinting that makes this crisp in the first place. ($BOOT_FONT_PX is set above.)
#
# These live ABOVE the derived block because the block measures text to centre it, and a
# function must be defined before the line that calls it runs.
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$BOOT_TF_FLAGS = ([System.Windows.Forms.TextFormatFlags]::NoPrefix -bor
                  [System.Windows.Forms.TextFormatFlags]::NoPadding -bor
                  [System.Windows.Forms.TextFormatFlags]::SingleLine)

function New-BootFont { param([int]$Px)
    New-Object System.Drawing.Font('Consolas', [single]$Px, [System.Drawing.FontStyle]::Bold,
                                   [System.Drawing.GraphicsUnit]::Pixel)
}
function Draw-BootText { param($G, [string]$Text, $Font, [int]$X, [int]$Y)
    [System.Windows.Forms.TextRenderer]::DrawText($G, $Text, $Font,
        (New-Object System.Drawing.Point($X, $Y)), [System.Drawing.Color]::White, $BOOT_TF_FLAGS)
}
function Measure-BootText { param($G, [string]$Text, $Font)
    ([System.Windows.Forms.TextRenderer]::MeasureText($G, $Text, $Font,
        (New-Object System.Drawing.Size 4000, 100), $BOOT_TF_FLAGS)).Width
}

# === everything below is DERIVED, and must stay below every constant it reads ==========
# ---- the gauge well, scaled off the resolution it was measured at ---------------
# Measured by hand on the 1024 HUD3: the detector returns a 130 px registration
# rectangle at x=500 but the painted floor (index 1) runs x=500..635/636 on every
# row the bar occupies, so the well is 136 and 2 extra columns put the bar at 132
# with a little recess still showing past its end. Both numbers are pixels on THAT
# artwork; the art is generated by scaling the same source, so the well scales with
# it. $HS/1.6 reproduces 136 and 2 exactly at 1024.
#
# FLOOR, not Round, for the ceiling: 136 x 1.5625 is 212.5 and [Math]::Round is
# banker's rounding, so Round would give 212 here and 213 for a neighbouring value
# -- and this is a limit, where under-estimating the well is the safe direction.
$GAUGE_W_MAX   = [int][Math]::Floor(136 * $HS / 1.6)
$GAUGE_W_EXTRA = [int][Math]::Floor(2 * $HS / 1.6)
# PowerShell resolves an undefined variable to $null and $null arithmetic to 0, silently.
# Both of these blocks were written above the mission constants and built without a murmur:
# BOOT_MIS_Y came out 36px low, and the timeline printed the mission line as zero-length.
# Nothing failed -- it just quietly meant something else. Hence the explicit null check.
foreach ($n in @('BOOT_MIS_H','BOOT_MIS_CY','BOOT_MIS_TEXT_X','BOOT_MIS_TYPE_US','BOOT_BANNER_US','BOOT_BAN_STEP',
                 'BOOT_TEXT_US','BOOT_LINE_US','BOOT_FINAL_US','BOOT_FIN_TYPE_US',
                 'BOOT_MISSION_US','BOOT_OPEN_US','BOOT_OPEN_SPAN','BOOT_HOLD_US','BOOT_CAP_US',
                 'BOOT_DISRUPT_US')) {
    if ($null -eq (Get-Variable $n -ValueOnly -ErrorAction SilentlyContinue)) {
        throw "`$$n is not defined yet -- a derived boot value is above the constant it reads"
    }
}

# Centre the readout on its OWN INK, not on the 448-wide container. Every line is drawn
# left-justified at x=0 in that container and the longest reaches ~431, so centring the
# container left the visible text off-centre. Measured rather than hard-coded: the text has
# changed repeatedly this session, and a stale constant here is invisible until someone
# looks closely.
$_g  = [System.Drawing.Graphics]::FromImage((New-Object System.Drawing.Bitmap 8, 8))
$_f  = New-BootFont $BOOT_FONT_PX
$BOOT_TXT_INK_W = 0
$_sum = 0; $_n = 0
foreach ($_l in ($BOOT_ALL_LINES + @($BOOT_FINAL_TEXT))) {
    $_w = Measure-BootText $_g $_l $_f
    if ($_w -gt $BOOT_TXT_INK_W) { $BOOT_TXT_INK_W = $_w }
    $_sum += $_w; $_n++
}
$_f.Dispose(); $_g.Dispose()
if ($BOOT_TXT_INK_W -gt $BOOT_TXT_W) {
    throw ("readout ink is {0}px but the block is only {1}px wide" -f $BOOT_TXT_INK_W, $BOOT_TXT_W)
}
$BOOT_TXT_MEAN_W = [int]($_sum / $_n)

# MIX is how far to lean from "centre the widest line" (0) toward "centre the average
# line" (1). It exists because the block is left-justified, so one line much longer than
# the rest drags the arithmetic centre away from where the eye puts it.
#
# It is back to 0 -- plain centring on the widest line -- because the SKEW WAS THE REAL
# PROBLEM and has been removed at the source: the heart-rate line used to measure 434px
# against a 183px average, and is now in line with the others. With the spread narrow,
# arithmetic and optical centring agree and a fudge factor is not needed.
$BOOT_TXT_OPT_MIX = 0.0
$BOOT_TXT_OPT_W = [int]($BOOT_TXT_INK_W + ($BOOT_TXT_MEAN_W - $BOOT_TXT_INK_W) * $BOOT_TXT_OPT_MIX)
# -band -8 keeps the destination 8-byte aligned: the blit expands one source byte into
# eight destination bytes with dword moves, so an aligned start keeps those moves aligned.
$BOOT_TXT_X = ([int](($INJ_W - $BOOT_TXT_OPT_W) / 2) + 4) -band -8   # NEAREST 8, not down
if (($BOOT_TXT_X + $BOOT_TXT_W) -gt $INJ_W) {
    throw ("readout block x={0} + {1} wide runs past the {2}px viewport" -f `
           $BOOT_TXT_X, $BOOT_TXT_W, $INJ_W)
}
# The whole stack, centred as one: readout rows, the bar, then the closing line UNDER the
# bar so it reads as the completion message for it. Even throughout, for scanline parity.
#
# The banner gap used to be excluded from the centring and subtracted afterwards, to lift
# the banner without moving anything below it. That was right when the gap was being ADDED
# to an already-placed block; now the stack is being laid out from scratch, so it is simply
# centred whole -- which is why the readout sits a few rows higher than it did.
$BOOT_TXT_STACK_H = $BOOT_TXT_ROWS + $BOOT_BAR_GAP_ABOVE + $BOOT_BAR_H +
                    $BOOT_BAR_GAP_BELOW + $BOOT_FINAL_H
$BOOT_TXT_BLOCK_H = $BOOT_TXT_STACK_H            # kept: the build prints it
$BOOT_TXT_Y   = [int](($INJ_H - $BOOT_TXT_STACK_H) / 2) -band (-$BOOT_ROW_ALIGN)
$BOOT_BAR_Y   = $BOOT_TXT_Y + $BOOT_TXT_ROWS + $BOOT_BAR_GAP_ABOVE
$BOOT_FINAL_Y = $BOOT_BAR_Y + $BOOT_BAR_H + $BOOT_BAR_GAP_BELOW
# How many whole character lines fit the stack. The glyph corruption picks a LINE and
# copies BOOT_TXT_H rows, so this has to floor -- a partial line at the bottom would let
# the copy run past the block it is meant to stay inside.
$BOOT_GLYPH_LINES = [int][Math]::Floor($BOOT_TXT_STACK_H / $BOOT_TXT_H)
if ($BOOT_TXT_Y -lt 0 -or ($BOOT_FINAL_Y + $BOOT_FINAL_H) -gt $INJ_H) {
    throw ("readout stack y={0} h={1} does not fit the {2}-row viewport" -f `
           $BOOT_TXT_Y, $BOOT_TXT_STACK_H, $INJ_H)
}
foreach ($v in @($BOOT_TXT_Y, $BOOT_BAR_Y, $BOOT_FINAL_Y)) {
    if ($v % 2) { throw "every element of the readout stack must sit on an even row; got $v" }
}

# The telemetry column sits at the FAR LEFT of the viewport, not tucked against the readout.
# It used to be derived from the readout's own x minus a gap, which put it at 272 -- close
# enough to read as part of the text block rather than as instrumentation running down the
# side of the screen. $BOOT_DUMP_PAD is the margin from the left edge so it does not butt
# against it; $BOOT_DUMP_GAP now only has to keep it clear of the readout, which the assertion
# below checks rather than the arithmetic guaranteeing.
#
# STILL 8-ALIGNED. The cells are 8 px wide and the blit addresses them in whole bytes, so a
# column that does not start on a multiple of 8 would shear every glyph in it.
#
# Its row count is the same floor as the glyph corruption's -- whole character lines only --
# so the column ends level with the bottom of the readout stack.
$BOOT_DUMP_ROWS = $BOOT_GLYPH_LINES
$BOOT_DUMP_W    = $BOOT_DUMP_COLS * $BOOT_HEX_CELL
$BOOT_DUMP_X    = $BOOT_DUMP_PAD -band -8
$BOOT_DUMP_Y    = $BOOT_TXT_Y
$BOOT_DUMP_CELLS = $BOOT_DUMP_COLS * $BOOT_DUMP_ROWS
if ($BOOT_DUMP_X -lt 8) {
    throw ("the telemetry column starts at x={0}: it would touch the left edge" -f $BOOT_DUMP_X)
}
if (($BOOT_DUMP_X + $BOOT_DUMP_W + $BOOT_DUMP_GAP) -gt $BOOT_TXT_X) {
    throw ("the telemetry column (x={0}..{1}) leaves less than the {2}px gap before the readout block at x={3}" -f `
           $BOOT_DUMP_X, ($BOOT_DUMP_X + $BOOT_DUMP_W), $BOOT_DUMP_GAP, $BOOT_TXT_X)
}
if ($BOOT_DUMP_Y % 2) { throw "BOOT_DUMP_Y must be even: the column picks its expansion table by row parity" }
if (($BOOT_DUMP_Y + $BOOT_DUMP_ROWS * $BOOT_TXT_H) -gt $INJ_H) {
    throw ("the telemetry column runs to row {0} of {1}" -f `
           ($BOOT_DUMP_Y + $BOOT_DUMP_ROWS * $BOOT_TXT_H), $INJ_H)
}
# The column's blit is UNROLLED over the columns, addressing cells as [edx+k] and destination
# dwords as [edi+8k+4]. Both are disp8 forms, so a wide column would silently need disp32.
if (($BOOT_DUMP_COLS * $BOOT_HEX_CELL - 4) -gt 127) { throw "BOOT_DUMP_COLS=$BOOT_DUMP_COLS at a ${BOOT_HEX_CELL}px cell overflows the disp8 destination offsets" }
if ($BOOT_DUMP_COLS -gt 127) { throw "BOOT_DUMP_COLS=$BOOT_DUMP_COLS overflows the disp8 cell offsets" }

# The scripted tear's band: the objective line's rows inside the mission block. Derived, so
# it follows the block if a header line is added -- a hard-coded row would quietly tear the
# wrong thing, and worse, could reach outside the rectangle the blit repaints.
# The bar spans the readout's own ink width and sits under the block, so it reads as part
# of the same element. Derived from the text rather than placed by eye: the readout has
# moved and been re-centred repeatedly, and a bar that did not follow it would be obvious.
$BOOT_BAR_X = $BOOT_TXT_X
$BOOT_BAR_W = $BOOT_TXT_INK_W
# ($BOOT_BAR_Y is derived above, with the rest of the stack.)
# Full exactly as the closing line finishes typing.
$BOOT_BAR_SPAN = ($BOOT_FINAL_US + $BOOT_FIN_TYPE_US) - $BOOT_TEXT_US
if ($BOOT_BAR_SPAN -le 0) { throw 'the progress bar would finish before it starts' }
if (($BOOT_BAR_Y + $BOOT_BAR_H) -gt $INJ_H) {
    throw ("the progress bar ends at row {0}, past the {1}-row viewport" -f ($BOOT_BAR_Y + $BOOT_BAR_H), $INJ_H)
}
if (($BOOT_BAR_X + $BOOT_BAR_W) -gt $INJ_W) { throw 'the progress bar runs past the viewport width' }
# (span * interior width) must stay inside 32 bits, or the mul feeds the div a non-zero
# high word and the fill comes out as nonsense rather than as an error.
if ([double]$BOOT_BAR_SPAN * ($BOOT_BAR_W - 2) -ge 4294967296.0) {
    throw 'progress bar: span * width overflows 32 bits'
}

# The calibration starts the moment the shutter finishes, and must finish before handover:
# it draws into the surface only while the boot still owns the frame.
$BOOT_CALIB_START = $BOOT_OPEN_US + $BOOT_OPEN_SPAN
if (($BOOT_CALIB_START + $BOOT_CALIB_US) -gt $BOOT_HOLD_US) {
    throw ("the calibration ends at {0:N2}s, after handover at {1:N2}s" -f `
           (($BOOT_CALIB_START + $BOOT_CALIB_US)/1e6), ($BOOT_HOLD_US/1e6))
}
# The box is centred, so its widest extent decides whether it fits.
if (($INJ_W / 2 - $BOOT_CALIB_R0) -lt 0 -or ($INJ_W / 2 + $BOOT_CALIB_R0) -ge $INJ_W -or
    ($INJ_H / 2 - $BOOT_CALIB_R0) -lt 0 -or ($INJ_H / 2 + $BOOT_CALIB_R0) -ge $INJ_H) {
    throw "the calibration box at r=$BOOT_CALIB_R0 does not fit the viewport"
}

$BOOT_MIS_TEAR_ROW = $BOOT_MIS_Y + $BOOT_MIS_OBJ_ROW
if (($BOOT_MIS_TEAR_ROW + $BOOT_MIS_BIG_H) -gt ($BOOT_MIS_Y + $BOOT_MIS_H)) {
    throw 'the scripted tear band runs outside the mission block, so it would never heal'
}
if ($BOOT_MIS_TEAR_PX -lt 1 -or $BOOT_MIS_TEAR_PX -ge $BOOT_TXT_W) {
    throw "BOOT_MIS_TEAR_PX must be within the block width; got $BOOT_MIS_TEAR_PX"
}

# Derived from the centre so the block grows symmetrically; masked even for scanline parity.
$BOOT_MIS_Y    = ($BOOT_MIS_CY - [int]($BOOT_MIS_H / 2)) -band (-$BOOT_ROW_ALIGN)

# The mission block's own width and X. The renderer centres its lines on the widest, so
# that margin is measured here and shared, rather than being recomputed there -- two copies
# of the same calculation is exactly how the objective row drifted out of step before.
$_g2 = [System.Drawing.Graphics]::FromImage((New-Object System.Drawing.Bitmap 8, 8))
$_fs = New-BootFont $BOOT_MIS_SM_PX
$_fb = New-BootFont $BOOT_MIS_PX
$BOOT_MIS_INK_W = 0
foreach ($_l in $BOOT_MIS_SMALL) {
    $_w = Measure-BootText $_g2 $_l $_fs
    if ($_w -gt $BOOT_MIS_INK_W) { $BOOT_MIS_INK_W = $_w }
}
$_w = Measure-BootText $_g2 $BOOT_MIS_TEXT $_fb
if ($_w -gt $BOOT_MIS_INK_W) { $BOOT_MIS_INK_W = $_w }
$_fs.Dispose(); $_fb.Dispose(); $_g2.Dispose()
if ($BOOT_MIS_INK_W -gt $BOOT_TXT_W) {
    throw ("the mission block needs {0}px but BOOT_TXT_W is {1}" -f $BOOT_MIS_INK_W, $BOOT_TXT_W)
}
$BOOT_MIS_LEFT = [Math]::Max(0, [int](($BOOT_TXT_W - $BOOT_MIS_INK_W) / 2))
# Nearest 8, so the blit's dword writes stay aligned; costs a pixel or two of placement.
# CENTRED ON THE VIEWPORT, not placed from the signed-off text column. $BOOT_MIS_TEXT_X
# was a screen column approved at 1024 and merely scaled, which lands the block left of
# centre at 1600 -- the readout block beside it IS centred ($BOOT_TXT_X), so the two
# disagreed and it showed.
#
# The ink is already centred INSIDE the block by $BOOT_MIS_LEFT, so centring the block
# centres the ink: x + LEFT = (INJ_W - inkW)/2 reduces to (INJ_W - BOOT_TXT_W)/2 once
# LEFT = (BOOT_TXT_W - inkW)/2 is substituted. Nearest 8 for the blit's dword writes.
$BOOT_MIS_X = ([int](($INJ_W - $BOOT_TXT_W) / 2) + 4) -band -8
# ---- the scanline bands have to line up across every block ---------------------
# The table is picked from each block's own DOWN counter, so the derivation only
# holds when the block's origin AND its row total are both multiples of the band
# pair. Get one wrong and that block's background steps out of phase with the
# screen's, which does not look like a bug -- it looks like a faint rectangle
# around the text, which is exactly what was reported at 1600x1200.
foreach ($chk in @(
        @{ n = 'BOOT_TXT_Y';    v = $BOOT_TXT_Y    },
        @{ n = 'BOOT_TXT_H';    v = $BOOT_TXT_H    },
        @{ n = 'BOOT_TXT_ROWS'; v = $BOOT_TXT_ROWS },
        @{ n = 'BOOT_BAN_GAP';  v = $BOOT_BAN_GAP  },
        @{ n = 'BOOT_MIS_Y';    v = $BOOT_MIS_Y    },
        @{ n = 'BOOT_MIS_H';    v = $BOOT_MIS_H    },
        @{ n = 'BOOT_FINAL_H';  v = $BOOT_FINAL_H  })) {
    if (($chk.v % $BOOT_ROW_ALIGN) -ne 0) {
        throw ("{0} is {1}, which is not a multiple of the {2}-row scanline band pair -- its background would sit out of phase with the screen" -f `
               $chk.n, $chk.v, $BOOT_ROW_ALIGN)
    }
}
if ($BOOT_MIS_X -lt 0 -or ($BOOT_MIS_X + $BOOT_TXT_W) -gt $INJ_W) {
    throw ("the mission block at x={0} does not fit the viewport" -f $BOOT_MIS_X)
}
if ($BOOT_MIS_Y -lt 0 -or ($BOOT_MIS_Y + $BOOT_MIS_H) -gt $INJ_H) {
    throw ("mission block y={0} h={1} does not fit the {2}-row viewport" -f $BOOT_MIS_Y, $BOOT_MIS_H, $INJ_H)
}

# The decay fades the readout out just BEFORE the mission wipe, and the telemetry column
# freezes just before that -- so by the time anything is fading, nothing is still moving.
$BOOT_DECAY_FROM  = $BOOT_MISSION_US - $BOOT_DECAY_US
# The column churns until the SHUTTER starts taking the screen away, not until the readout
# finishes. It used to stop at 10.60 s, which left it frozen for the last six seconds of the
# sequence -- the stretch where the mission block is just sitting there and nothing else moves.
# Running it to the shutter keeps something alive on screen for the whole animation.
#
# $BOOT_OPEN_US is defined ~600 lines above this, so reading it here is safe; a value derived
# from a constant BELOW it would silently be $null, and $null arithmetic is 0.
$BOOT_DUMP_FREEZE = $BOOT_OPEN_US

# ---- the boot, for the host's own HD copy of it (tools\BootHd.cs) --------------------
# The GPU version draws this sequence itself at display resolution, following the guest's
# clock (aztBootEl) so the CD effect stays in step. It reads EVERYTHING from here -- texts,
# beats, effect tables, sizes and the ink INDICES (resolved against the live palette by the
# watcher, so it shows exactly the colours the 8-bit boot does) -- rather than keeping its
# own copy that would drift the next time a beat is retimed. Sizes are in viewport pixels
# (INJ_W x INJ_H); the host scales them to its picture. Writing it changes nothing in R.EXE.
if ($ENABLE_BOOT_SEQ) {
    $bootHd = [ordered]@{
        injW = $INJ_W; injH = $INJ_H
        # the scale the 8-bit boot was built at, and the one it was designed for: the cap is BSS
        # (the 1bpp bitmaps), which the host does not have, so it draws at the designed size
        scale = $BOOT_S; designW = $BOOT_DESIGN_W
        banner = @($BOOT_BANNER); lines = @($BOOT_LINES); final = $BOOT_FINAL_TEXT
        missionSmall = @($BOOT_MIS_SMALL); mission = $BOOT_MIS_TEXT
        us = [ordered]@{
            hold = $BOOT_HOLD_US; fxDelay = $BOOT_FX_DELAY_US; banner = $BOOT_BANNER_US; banStep = $BOOT_BAN_STEP
            text = $BOOT_TEXT_US; line = $BOOT_LINE_US; final = $BOOT_FINAL_US; finType = $BOOT_FIN_TYPE_US
            mission = $BOOT_MISSION_US; misType = $BOOT_MIS_TYPE_US; misTear = @($BOOT_MIS_TEAR_US, $BOOT_MIS_TEAR2_US); misTearDur = $BOOT_MIS_TEAR_DUR
            open = $BOOT_OPEN_US; openSpan = $BOOT_OPEN_SPAN; calib = $BOOT_CALIB_US; reboot = $BOOT_REBOOT_FROM
            warmStage = $BOOT_WARM_STAGE_US; disStage = $BOOT_DIS_STAGE_US; slipStart = $BOOT_SLIP_START_US; slipEnd = $BOOT_SLIP_US
            flare = $BOOT_FLARE_US; caretShr = $BOOT_CARET_SHR; sweep = $BOOT_SWEEP_US; decay = $BOOT_DECAY_US; dump = $BOOT_DUMP_US
            barSpan = $BOOT_BAR_SPAN
        }
        ink = [ordered]@{
            fill = $BOOT_FILL_IX; scan = $BOOT_SCAN_IX; text = $BOOT_INK_IX; flare = $BOOT_FLARE_IX; caret = $BOOT_CARET_IX
            art = $BOOT_ART_IX; lip = $BOOT_LIP_IX; ghost = $BOOT_GHOST_IX; sweep = $BOOT_SWEEP_IX; track = $BOOT_BAR_TRACK_IX
            dump = $BOOT_DUMP_IX; calib = $BOOT_CALIB_IX; decay = @($BOOT_DECAY_RAMP)
            warm = @($BOOT_WARM_STAGES | ForEach-Object { ,@($_.Fill, $_.Scan) })
        }
        dis = @($BOOT_DIS_STAGES | ForEach-Object { ,@($_.Streaks, $_.Edges, $_.Blocks, $_.Band, $_.Tear) })
        px = [ordered]@{
            font = $BOOT_FONT_PX; misSmall = $BOOT_MIS_SM_PX; misBig = $BOOT_MIS_PX
            lineH = $BOOT_TXT_H; banGap = $BOOT_BAN_GAP; finalH = $BOOT_FINAL_H
            txtX = $BOOT_TXT_X; txtY = $BOOT_TXT_Y; inkW = $BOOT_TXT_INK_W
            barX = $BOOT_BAR_X; barY = $BOOT_BAR_Y; barW = $BOOT_BAR_W; barH = $BOOT_BAR_H; finalY = $BOOT_FINAL_Y
            misX = ($BOOT_MIS_X + $BOOT_MIS_LEFT); misY = $BOOT_MIS_Y; misTextTop = $BOOT_MIS_TEXT_TOP; misSmH = $BOOT_MIS_SM_H
            misObjRow = $BOOT_MIS_OBJ_ROW; misBigH = $BOOT_MIS_BIG_H; misW = $BOOT_MIS_INK_W; misH = $BOOT_MIS_H; icon = $BOOT_MIS_ICON_H; misTearPx = $BOOT_MIS_TEAR_PX
            dumpX = $BOOT_DUMP_X; dumpY = $BOOT_DUMP_Y; dumpCols = $BOOT_DUMP_COLS; dumpRows = $BOOT_DUMP_ROWS; hexCell = $BOOT_HEX_CELL
            dumpFast = $BOOT_DUMP_FAST; dumpSlow = $BOOT_DUMP_SLOW
            glyphCells = $BOOT_GLYPH_CELLS; glyphOdds = $BOOT_GLYPH_ODDS
            edgeMargin = $BOOT_EDGE_MARGIN; blkMargin = $BOOT_BLK_MARGIN
            tearRows = @($BOOT_TEAR_ROWS_MIN, $BOOT_TEAR_ROWS_SPAN); tearShift = @($BOOT_TEAR_SHIFT_MIN, $BOOT_TEAR_SHIFT_SPAN)
            split = @($BOOT_SPLIT_ODDS, $BOOT_SPLIT_SHIFT_MIN, $BOOT_SPLIT_SHIFT_SPAN, $BOOT_SPLIT_GAP_MIN, $BOOT_SPLIT_GAP_SPAN)
            slip = @($BOOT_SLIP_ROWS_MIN, $BOOT_SLIP_ROWS_SPAN, $BOOT_SLIP_FRAMES, $BOOT_SLIP_ODDS, $BOOT_SLIP_ODDS_LATE)
            sweepRows = $BOOT_SWEEP_ROWS; ghostRows = $BOOT_GHOST_ROWS; calibR = @($BOOT_CALIB_R0, $BOOT_CALIB_R1)
        }
    }
    # $null is 0 in arithmetic and "null" in JSON, silently -- a value read above its constant.
    foreach ($sec in 'us', 'ink', 'px') {
        foreach ($k in @($bootHd[$sec].Keys)) {
            if ($null -eq $bootHd[$sec][$k]) { throw "boot-hd.json: $sec.$k is null -- derived above the constant it reads?" }
        }
    }
    $bootHdPath = Join-Path $PSScriptRoot '..\art\boot-hd.json'
    [IO.File]::WriteAllText($bootHdPath, ($bootHd | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
    Write-Host ("boot (HD copy): {0}" -f (Resolve-Path $bootHdPath).Path)
}

# --- the boot timeline, checked and printed -----------------------------------
# These beats are a dozen independent constants and retiming one of them has twice now
# meant hand-checking the rest. The ordering is an invariant, so it is asserted: a beat
# that starts before the one it follows has finished is a build failure, not something to
# notice in game. (An element still TYPING when the shutter starts is the nastiest of
# these, because it looks like a glitch rather than a timing bug.)
$BOOT_TL = [ordered]@{
    'banner draws in' = @($BOOT_BANNER_US, ($BOOT_BANNER_US + ($BOOT_BANNER.Count - 1) * $BOOT_BAN_STEP))
    'disruption'      = @(0,                $BOOT_DISRUPT_US)
    'hold slip'       = @($BOOT_SLIP_START_US, $BOOT_SLIP_US)
    'readout'         = @($BOOT_TEXT_US,    ($BOOT_TEXT_US + ($BOOT_LINES.Count - 1) * $BOOT_LINE_US))
    'closing types'   = @($BOOT_FINAL_US,   ($BOOT_FINAL_US + $BOOT_FIN_TYPE_US))
    'dump churns'     = @($BOOT_DUMP_US,    $BOOT_DUMP_FREEZE)
    'readout decays'  = @($BOOT_DECAY_FROM, $BOOT_MISSION_US)
    'mission types'   = @($BOOT_MISSION_US, ($BOOT_MISSION_US + $BOOT_MIS_TYPE_US))
    'shutter'         = @($BOOT_OPEN_US,    ($BOOT_OPEN_US + $BOOT_OPEN_SPAN))
    'calibration'     = @($BOOT_CALIB_START,($BOOT_CALIB_START + $BOOT_CALIB_US))
    'hand over'       = @($BOOT_HOLD_US,    $BOOT_HOLD_US)
}
if ($ENABLE_BOOT_SEQ) {
    Write-Host 'boot timeline:'
    foreach ($k in $BOOT_TL.Keys) {
        $a, $b = $BOOT_TL[$k]
        Write-Host ("   {0,-16} {1,6:N2} - {2,6:N2} s" -f $k, ($a/1e6), ($b/1e6))
    }
    # Each beat after the readout must start only once the previous one has finished. The
    # decay is in this chain deliberately: it must not begin while the closing line is still
    # typing, or it would dim a line that is still being revealed.
    $seq = @('readout','closing types','readout decays','mission types','shutter','hand over')
    for ($i = 1; $i -lt $seq.Count; $i++) {
        $pe = $BOOT_TL[$seq[$i-1]][1]; $cs = $BOOT_TL[$seq[$i]][0]
        if ($cs -lt $pe) {
            throw ("boot timeline: '{0}' starts at {1:N2}s but '{2}' does not finish until {3:N2}s" -f `
                   $seq[$i], ($cs/1e6), $seq[$i-1], ($pe/1e6))
        }
    }
    if ($BOOT_HOLD_US -ge $BOOT_CAP_US) { throw 'boot timeline: HOLD must be below the CAP backstop' }

    # The reload re-boot enters the timeline at this point, so it has to land in the mission
    # phase -- the one beat a reload blanks -- and still have the shutter ahead of it.
    # Both mission stutters must land while the block is up and fully typed, and finish
    # before the shutter starts taking it away.
    foreach ($t in @($BOOT_MIS_TEAR_US, $BOOT_MIS_TEAR2_US)) {
        if ($t -lt ($BOOT_MISSION_US + $BOOT_MIS_TYPE_US) -or ($t + $BOOT_MIS_TEAR_DUR) -gt $BOOT_OPEN_US) {
            throw ("a mission stutter at {0:N2}s falls outside the block's settled window {1:N2}-{2:N2}s" -f `
                   ($t/1e6), (($BOOT_MISSION_US + $BOOT_MIS_TYPE_US)/1e6), ($BOOT_OPEN_US/1e6))
        }
    }
    if ($ENABLE_REBOOT_ON_LOAD) {
        if ($BOOT_REBOOT_FROM -lt $BOOT_MISSION_US -or $BOOT_REBOOT_FROM -ge $BOOT_OPEN_US) {
            throw ("BOOT_REBOOT_FROM {0:N2}s must fall between the mission wipe {1:N2}s and the shutter {2:N2}s" -f `
                   ($BOOT_REBOOT_FROM/1e6), ($BOOT_MISSION_US/1e6), ($BOOT_OPEN_US/1e6))
        }
        Write-Host ("   reload re-boot  enters at {0:N2}s -> {1:N2}s of shutter and calibration" -f `
                    ($BOOT_REBOOT_FROM/1e6), (($BOOT_HOLD_US - $BOOT_REBOOT_FROM)/1e6))
    }
    # The slip only runs inside phase 1, so a window reaching past the mission wipe would
    # silently do nothing for its last stretch rather than fail.
    if ($BOOT_SLIP_US -gt $BOOT_MISSION_US) {
        throw ("boot timeline: the slip window ends at {0:N2}s, after the mission wipe at {1:N2}s" -f `
               ($BOOT_SLIP_US/1e6), ($BOOT_MISSION_US/1e6))
    }
    Write-Host ("   readout block  x={0} (widest {1}px, mean {2}px, centred on {3}px), y={4}..{5} of {6}" -f `
                $BOOT_TXT_X, $BOOT_TXT_INK_W, $BOOT_TXT_MEAN_W, $BOOT_TXT_OPT_W,
                $BOOT_TXT_Y, ($BOOT_TXT_Y + $BOOT_TXT_BLOCK_H), $INJ_H)
    Write-Host ("                  typical line centres at {0}, viewport centre is {1}" -f `
                ($BOOT_TXT_X + [int]($BOOT_TXT_MEAN_W / 2)), [int]($INJ_W / 2))
    Write-Host ("   mission block  y={0}..{1}, fully up for {2:N2} s before the shutter" -f `
                $BOOT_MIS_Y, ($BOOT_MIS_Y + $BOOT_MIS_H),
                (($BOOT_OPEN_US - ($BOOT_MISSION_US + $BOOT_MIS_TYPE_US)) / 1e6))

    # THE DECAY RAMP MUST STAY ON THE TEAL RAMP, and must only ever get dimmer. Both the
    # table repaint and the dump's post-pass recognise ink by the range 88..103, so a step
    # outside it would be treated as background on the next pass and overwritten, and a step
    # that went brighter would read as the readout flaring rather than fading.
    foreach ($c in $BOOT_DECAY_RAMP) {
        if ($c -lt $BOOT_INK_IX -or $c -gt ($BOOT_INK_IX + 15)) {
            throw ("decay step {0} is outside the teal ramp {1}..{2}" -f $c, $BOOT_INK_IX, ($BOOT_INK_IX + 15))
        }
    }
    $_prev = $BOOT_INK_IX
    foreach ($c in $BOOT_DECAY_RAMP) {
        if ($c -le $_prev) { throw "the decay ramp must descend in brightness (indices increasing); $c follows $_prev" }
        $_prev = $c
    }
    # The dump's dim offset walks the same ramp, so it is clamped to its end at runtime --
    # but if even the FIRST step were off the end the column would never be dimmer than the
    # readout, which is the whole point of it.
    # The column is amber now rather than a step down the teal ramp, so the old "does it run
    # off the end of the ramp" check no longer applies. Its replacement lives with the other
    # colour assertions further down -- Lum is not defined until then, and calling it up here
    # is an outright error rather than a silent $null.
    if ($BOOT_DUMP_IX -lt 1 -or $BOOT_DUMP_IX -gt 53) {
        throw "BOOT_DUMP_IX=$BOOT_DUMP_IX is outside the HUD palette budget (1..53)"
    }
    Write-Host ("   decay          ink {0} -> {1} over {2:N2}s, then the wipe" -f `
                $BOOT_INK_IX, ($BOOT_DECAY_RAMP -join ' -> '), ($BOOT_DECAY_US / 1e6))
    Write-Host ("   dump column    x={0}..{1}, y={2}..{3}, {4} cells, amber ink {5}, freezes at {6:N2}s" -f `
                $BOOT_DUMP_X, ($BOOT_DUMP_X + $BOOT_DUMP_W), $BOOT_DUMP_Y,
                ($BOOT_DUMP_Y + $BOOT_DUMP_ROWS * $BOOT_TXT_H), $BOOT_DUMP_CELLS,
                $BOOT_DUMP_IX, ($BOOT_DUMP_FREEZE / 1e6))
    # The sweep's row comes from `(el mod period) * span / period`. The multiply is the one
    # place this can overflow silently, and it would land the line at a wrong -- possibly
    # out-of-range -- row rather than failing.
    if ([double]($BOOT_SWEEP_US - 1) * ($INJ_H - $BOOT_SWEEP_ROWS + 1) -ge 4294967296.0) {
        throw 'the sweep row multiply overflows 32 bits'
    }
    if ($BOOT_SWEEP_ROWS -lt 1 -or $BOOT_SWEEP_ROWS -gt ($INJ_H / 2)) {
        throw "BOOT_SWEEP_ROWS=$BOOT_SWEEP_ROWS is not a sane line thickness"
    }
    Write-Host ("   refresh line   {0} row(s), index {1}, one pass every {2:N2}s" -f `
                $BOOT_SWEEP_ROWS, $BOOT_SWEEP_IX, ($BOOT_SWEEP_US / 1e6))

    # --- the boot palette, checked and printed --------------------------------
    # The screen's brightness has now been retuned three times, and every time the SIZE of
    # each relationship -- scanline gap, corruption contrast, how far under the fill the
    # ghost sits -- was what had been judged and signed off, while the absolute colours were
    # what moved. Re-deriving those by hand each time is how the warm-up ramp came to climb
    # past its own final colour and dim back into it: nothing failed, it just looked wrong.
    #
    # Luma for the indices the boot actually uses, measured from the game's merged palette
    # (hud3 + pal + h1) with 0.299/0.587/0.114. A LOOKUP, not a palette file read: the build
    # must not acquire a dependency on an external .pal that a clean install would not have,
    # and these seventeen entries are fixed data in a 1996 game.
    #     1 #101008   2 #282818  11 #55491C  14 #715118  16 #8A5510  20 #A67118
    #    21 #C9790F  27 #D78E10  34 #E39E18  38 #553910  41 #613908  50 #F3B614
    #    55 #BEFBFF  88 #71DFD7  92 #51BAA6  96 #359679 100 #147149 103 #005524
    #
    # 21 was added for the telemetry column. Verified against this table's own convention
    # rather than assumed: index 20 in the installed HUD3.PCX computes to exactly 119 under
    # 0.299/0.587/0.114, which is what the table already records, so 21's 133 is on the same
    # footing as the rest.
    $BOOT_LUMA = @{   1 =  15;   2 =  38;  11 =  71;  14 =  84;  16 =  93;  20 = 119
                     21 = 133;  27 = 149;  34 = 163;  38 =  61;  41 =  63;  50 = 182
                     55 = 233;  88 = 189;  92 = 152;  96 = 118; 100 =  81; 103 =  54 }
    # MEASURED, from the same palette the inks are picked from -- not from the
    # hand-maintained $BOOT_LUMA above. That table had drifted badly against the
    # regenerated art (it claimed index 20 was luma 119 when the art says 168), which
    # is exactly why four inverted inks got through without a single assertion firing.
    # The table is kept only as the record of what each ink was chosen to look like.
    function Lum { param([int]$i) return (BootLum $i) }
    $fillL = Lum $BOOT_FILL_IX; $scanL = Lum $BOOT_SCAN_IX
    Write-Host ("   screen         fill {0} luma {1} / scan {2} luma {3}, gap {4}" -f `
                $BOOT_FILL_IX, $fillL, $BOOT_SCAN_IX, $scanL, ($fillL - $scanL))
    Write-Host ("                  corruption +{0}, refresh line +{1}, shutter lip +{2}, ghost {3}, bar groove {4}" -f `
                ((Lum $BOOT_ART_IX) - $fillL), ((Lum $BOOT_SWEEP_IX) - $fillL),
                ((Lum $BOOT_LIP_IX) - $fillL), ((Lum $BOOT_GHOST_IX) - $fillL),
                ((Lum $BOOT_BAR_TRACK_IX) - $fillL))
    # Darker than the fill ONLY while interlacing is on. With $ENABLE_BOOT_SCANLINES
    # off the two are deliberately the same ink -- that is how the stripe is removed --
    # so require equality instead of silently skipping the check.
    if ($ENABLE_BOOT_SCANLINES) {
        if ($scanL -ge $fillL) { throw "the scanline colour must be darker than the fill; got $scanL vs $fillL" }
    } elseif ($scanL -ne $fillL) {
        throw "scanlines are off, so the scan ink must equal the fill; got $scanL vs $fillL"
    }
    foreach ($n in @('ART','SWEEP','LIP')) {
        $v = Get-Variable ("BOOT_{0}_IX" -f $n) -ValueOnly
        if ((Lum $v) -le $fillL) { throw "BOOT_${n}_IX ($v) must be brighter than the fill; luma $(Lum $v) vs $fillL" }
    }
    foreach ($n in @('GHOST','BAR_TRACK')) {
        $v = Get-Variable ("BOOT_{0}_IX" -f $n) -ValueOnly
        if ((Lum $v) -ge $scanL) { throw "BOOT_${n}_IX ($v) must be darker than the scanlines; luma $(Lum $v) vs $scanL" }
    }
    # The telemetry column has to sit BETWEEN the screen and the readout: brighter than the
    # fill or it reads as switched off -- which is exactly what the old teal index 96 did, at
    # luma 117 against a 120 screen -- and dimmer than the readout, which must stay the
    # brightest thing on the display.
    $dumpL = Lum $BOOT_DUMP_IX
    if ($dumpL -le $fillL) {
        throw "BOOT_DUMP_IX ($BOOT_DUMP_IX) is luma $dumpL, not brighter than the fill ($fillL): it would read as switched off"
    }
    if ($dumpL -ge (Lum $BOOT_INK_IX)) {
        throw "BOOT_DUMP_IX ($BOOT_DUMP_IX) is luma $dumpL, not dimmer than the readout ink ($(Lum $BOOT_INK_IX)): the column would outshine the text"
    }
    Write-Host ("   dump ink       {0} luma {1}  (fill {2}, readout {3})" -f $BOOT_DUMP_IX, $dumpL, $fillL, (Lum $BOOT_INK_IX))
    # THE WARM-UP MUST ONLY EVER GET BRIGHTER, and must finish exactly on the screen colour.
    $pf = -1; $ps = -1
    for ($i = 0; $i -lt $BOOT_WARM_STAGES.Count; $i++) {
        $f = Lum $BOOT_WARM_STAGES[$i].Fill; $s = Lum $BOOT_WARM_STAGES[$i].Scan
        if ($f -lt $pf) { throw ("warm-up stage {0} dims the fill: luma {1} after {2}" -f $i, $f, $pf) }
        if ($s -lt $ps) { throw ("warm-up stage {0} dims the scanlines: luma {1} after {2}" -f $i, $s, $ps) }
        if ($s -gt $f)  { throw ("warm-up stage {0} has brighter scanlines than fill: {1} vs {2}" -f $i, $s, $f) }
        $pf = $f; $ps = $s
    }
    $lastW = $BOOT_WARM_STAGES[-1]
    if ($lastW.Fill -ne $BOOT_FILL_IX -or $lastW.Scan -ne $BOOT_SCAN_IX) {
        throw 'the last warm-up stage must be the screen colour itself'
    }
    Write-Host ("   warm-up        fill luma {0}" -f (($BOOT_WARM_STAGES | ForEach-Object { Lum $_.Fill }) -join ' -> '))
    Write-Host ("                  scan luma {0}" -f (($BOOT_WARM_STAGES | ForEach-Object { Lum $_.Scan }) -join ' -> '))
}

# Renders the readout to 1bpp at BUILD time.
function Render-BootText {
    $bmp = New-Object System.Drawing.Bitmap ($BOOT_TXT_W, $BOOT_TXT_ROWS)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Black)
    # TextRenderer maps this onto the DC's text quality, so it is what keeps GDI from
    # antialiasing according to the machine's ClearType setting.
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
    $font = New-BootFont $BOOT_FONT_PX
    for ($i = 0; $i -lt $BOOT_ALL_LINES.Count; $i++) {
        # Everything below the banner is pushed down by the gap inside the bitmap; the
        # whole bitmap is then drawn that much higher, so only the banner appears to move.
        $y = $i * $BOOT_TXT_H
        if ($i -ge $BOOT_BANNER.Count) { $y += $BOOT_BAN_GAP }
        Draw-BootText $g $BOOT_ALL_LINES[$i] $font 0 $y
    }
    $g.Dispose()
    $out = New-Object byte[] ($BOOT_TXT_PITCH * $BOOT_TXT_ROWS)
    $widest = 0
    for ($y = 0; $y -lt $BOOT_TXT_ROWS; $y++) {
        for ($x = 0; $x -lt $BOOT_TXT_W; $x++) {
            if ($bmp.GetPixel($x, $y).R -ge 128) {
                # `-shr 3`, NOT [int]($x/8). [int] on a fraction uses BANKER'S ROUNDING, not
                # truncation, so every x ending .5 -- i.e. every x congruent to 4 mod 8 --
                # packed into the NEXT byte. It rendered as almost-text: recognisable but
                # unreadable, because one pixel in eight was displaced by 8 columns.
                $b = $y * $BOOT_TXT_PITCH + ($x -shr 3)
                $out[$b] = $out[$b] -bor [byte](0x80 -shr ($x % 8))
                if ($x -gt $widest) { $widest = $x }
            }
        }
    }
    $bmp.Dispose()
    # A line running off the right edge would be silently clipped, so say so at build time.
    Write-Host ("boot readout: {0} lines ({1} banner + {2} readout), widest ink at x={3} of {4}{5}" -f `
                $BOOT_ALL_LINES.Count, $BOOT_BANNER.Count, $BOOT_LINES.Count, $widest, $BOOT_TXT_W,
                $(if ($widest -ge $BOOT_TXT_W - 1) { '   *** CLIPPED ***' } else { '' }))
    return $out
}

# The 16 hex digits for the telemetry column, as one 1bpp strip -- and TRANSPOSED.
#
# Stored as out[row * 16 + glyph], not out[glyph * 16 + row]. The column's blit walks one
# PIXEL ROW across all four cells before moving down, so what it needs contiguous is "the
# bits for row rr of every glyph". With the natural layout the inner loop would have to hold
# both a per-glyph base and a row offset, and there is no register left for the second one:
# esi is the obj1 delta, ebp is the expansion table, edi is the destination, edx is the cell
# cursor. Transposing moves that addressing into one `[ebx + glyph]`.
# $BOOT_HEX_CELL is defined up with $BOOT_DUMP_COLS, NOT here. It was here first and
# $BOOT_DUMP_W (= COLS * CELL, ~400 lines earlier) read it as $null -> 0, so the build
# cheerfully reported a column running "x=32..32" and nothing asserted, because a
# zero-width column only makes the clearance check pass more easily. Third time this
# trap has bitten; see [[azrael-powershell-null-ordering]].
function Render-BootHex {
    $bmp = New-Object System.Drawing.Bitmap ($BOOT_HEX_CELL, $BOOT_TXT_H)
    $stride = 16 * ($BOOT_HEX_CELL / 8)          # 16 glyphs, 2 bytes each
    $out = New-Object byte[] ($BOOT_TXT_H * $stride)
    $font = New-BootFont $BOOT_FONT_PX
    $chars = '0123456789ABCDEF'
    for ($g = 0; $g -lt 16; $g++) {
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.Clear([System.Drawing.Color]::Black)
        $gfx.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
        Draw-BootText $gfx $chars[$g] $font 0 0
        $gfx.Dispose()
        for ($y = 0; $y -lt $BOOT_TXT_H; $y++) {
            $b0 = 0; $b1 = 0
            for ($x = 0; $x -lt 8; $x++) {
                if ($bmp.GetPixel($x,     $y).R -ge 128) { $b0 = $b0 -bor (0x80 -shr $x) }
                if ($bmp.GetPixel($x + 8, $y).R -ge 128) { $b1 = $b1 -bor (0x80 -shr $x) }
            }
            # TRANSPOSED, as before: row-major by glyph, so the draw loop needs only
            # `[ebx + glyph*2]` and advances ebx by one stride per row.
            $out[$y * $stride + $g*2]     = [byte]$b0
            $out[$y * $stride + $g*2 + 1] = [byte]$b1
        }
    }
    $font.Dispose(); $bmp.Dispose()
    # Still worth checking: a font whose digits reach the LAST column of the cell would
    # be clipped silently. Now it is the second byte's low bit that matters.
    $clipped = 0
    for ($y = 0; $y -lt $BOOT_TXT_H; $y++) {
        for ($g = 0; $g -lt 16; $g++) { if ($out[$y * $stride + $g*2 + 1] -band 1) { $clipped++ } }
    }
    Write-Host ("boot hex strip: 16 glyphs x {0} rows, {1}px cell{2}" -f $BOOT_TXT_H, $BOOT_HEX_CELL,
                $(if ($clipped) { "   *** $clipped row(s) reach the cell edge ***" } else { '' }))
    return $out
}

# The closing readout line, rendered alone at readout size so it can be typed in.
function Render-BootFinal {
    $bmp = New-Object System.Drawing.Bitmap ($BOOT_TXT_W, $BOOT_FINAL_H)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Black)
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
    $font = New-BootFont $BOOT_FONT_PX
    Draw-BootText $g $BOOT_FINAL_TEXT $font 0 0
    $g.Dispose()
    $out = New-Object byte[] ($BOOT_TXT_PITCH * $BOOT_FINAL_H)
    $widest = 0
    for ($y = 0; $y -lt $BOOT_FINAL_H; $y++) {
        for ($xx = 0; $xx -lt $BOOT_TXT_W; $xx++) {
            if ($bmp.GetPixel($xx, $y).R -ge 128) {
                $b = $y * $BOOT_TXT_PITCH + ($xx -shr 3)
                $out[$b] = $out[$b] -bor [byte](0x80 -shr ($xx % 8))
                if ($xx -gt $widest) { $widest = $xx }
            }
        }
    }
    $bmp.Dispose()
    Write-Host ("boot final:   '{0}', widest ink {1} of {2}" -f $BOOT_FINAL_TEXT, $widest, $BOOT_TXT_W)
    return $out
}

# The mission line, on its own and about twice the size. Same width and pitch as the readout
# so the identical blit can draw it -- only the source, the row count and the destination
# differ, which keeps one blit routine rather than two.
function Render-BootMission {
    $bmp = New-Object System.Drawing.Bitmap ($BOOT_TXT_W, $BOOT_MIS_H)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Black)
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
    $small = New-BootFont $BOOT_MIS_SM_PX
    $big   = New-BootFont $BOOT_MIS_PX
    $rows = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $BOOT_MIS_SMALL.Count; $i++) {
        [void]$rows.Add(@{ Text = $BOOT_MIS_SMALL[$i]; Font = $small
                           Y = ($BOOT_MIS_TEXT_TOP + $i * $BOOT_MIS_SM_H) })
    }
    [void]$rows.Add(@{ Text = $BOOT_MIS_TEXT; Font = $big; Y = $BOOT_MIS_OBJ_ROW })
    # LEFT-JUSTIFIED, on a margin taken from the WIDEST line's centred position. Centring
    # each line on its own width left them ragged; centring the block and then flushing
    # everything left against that margin keeps the block's bounding box exactly where it
    # was on screen, so nothing appears to move -- only the short lines shift left.
    #
    # $BOOT_MIS_LEFT is computed once in the derived block and shared, because BOOT_MIS_X
    # is derived FROM it: recomputing the margin here would let the two drift apart and
    # silently move the text off the position it was signed off at.
    $left = $BOOT_MIS_LEFT
    foreach ($r in $rows) { Draw-BootText $g $r.Text $r.Font $left $r.Y }

    # The warning octagon, left-aligned with the text. WHITE is a set bit (ink) and BLACK
    # is clear (screen), so the octagon is filled white and the "!" punched out in black.
    # The bar and dot are drawn as rectangles rather than as a glyph: at 26px a font's
    # exclamation is a thin, badly-hinted stroke, and two rectangles are exactly crisp.
    $n = $BOOT_MIS_ICON_H
    $c = [int]($n * 0.293)                       # the corner cut of a regular octagon
    $oct = @(
        (New-Object System.Drawing.Point(($left + $c),      0)),
        (New-Object System.Drawing.Point(($left + $n - $c), 0)),
        (New-Object System.Drawing.Point(($left + $n),      $c)),
        (New-Object System.Drawing.Point(($left + $n),      ($n - $c))),
        (New-Object System.Drawing.Point(($left + $n - $c), $n)),
        (New-Object System.Drawing.Point(($left + $c),      $n)),
        (New-Object System.Drawing.Point( $left,            ($n - $c))),
        (New-Object System.Drawing.Point( $left,            $c))
    )
    $g.FillPolygon([System.Drawing.Brushes]::White, [System.Drawing.Point[]]$oct)
    $bw = [Math]::Max(3, [int]($n / 7))          # the stroke of the "!"
    $bx = $left + [int](($n - $bw) / 2)
    $g.FillRectangle([System.Drawing.Brushes]::Black, $bx, [int]($n * 0.20), $bw, [int]($n * 0.42))
    $g.FillRectangle([System.Drawing.Brushes]::Black, $bx, [int]($n * 0.72), $bw, [int]($n * 0.15) + 1)
    $g.Dispose()
    $out = New-Object byte[] ($BOOT_TXT_PITCH * $BOOT_MIS_H)
    $widest = 0
    for ($y = 0; $y -lt $BOOT_MIS_H; $y++) {
        for ($xx = 0; $xx -lt $BOOT_TXT_W; $xx++) {
            if ($bmp.GetPixel($xx, $y).R -ge 128) {
                $b = $y * $BOOT_TXT_PITCH + ($xx -shr 3)      # -shr 3, never [int](x/8)
                $out[$b] = $out[$b] -bor [byte](0x80 -shr ($xx % 8))
                if ($xx -gt $widest) { $widest = $xx }
            }
        }
    }
    $bmp.Dispose()
    Write-Host ("boot mission: {0} rows, {1} lines, widest ink {2} of {3}{4}" -f `
                $BOOT_MIS_H, $rows.Count, $widest, $BOOT_TXT_W,
                $(if ($widest -ge $BOOT_TXT_W - 1) { '   *** CLIPPED ***' } else { '' }))
    for ($i = 0; $i -lt $rows.Count; $i++) {
        Write-Host ("   y={0,3}  x={1,3}  {2,4}px  '{3}'" -f `
                    $rows[$i].Y, $left, $rows[$i].Font.Size, $rows[$i].Text)
    }
    return $out
}
$CD_TEST_SLOT    = 6                     # phase A plays this at start-up
# Generated by src\Build-Soundtrack.ps1 from the MP3s in music-export\Soundtrack_mp3,
# which also writes the matching AZT.CUE. Absent = that cue keeps its MIDI, so the
# soundtrack can be replaced one track at a time.
$CD_TRACKS = @{}
$mtFile = Join-Path $PSScriptRoot '..\art\music-tracks.json'
if (Test-Path $mtFile) {
    $mt = Get-Content $mtFile -Raw | ConvertFrom-Json
    foreach ($prop in $mt.PSObject.Properties) {
        $CD_TRACKS[[int]$prop.Name] = @{ lba     = [int]$prop.Value.lba
                                         sectors = [int]$prop.Value.sectors
                                         us      = [uint32]$prop.Value.us }
    }
}

# ---- where the boot effect sits inside the boot timeline ---------------------
# HERE, not with the rest of the timeline checks: those run around line 1570 and $CD_TRACKS
# is not filled in until this line. Placed up there it read as $null, the whole block was
# skipped, and the build printed nothing and asserted nothing -- the same silent-$null shape
# as the derived-above-constant trap, just expressed as a test that never ran.
#
# Worth asserting at all because the two numbers live in different files: the track's length
# comes from art\music-tracks.json (written by Build-Soundtrack) and the delay is a constant
# in this one, so they can drift apart with nothing to notice it.
if ($ENABLE_BOOT_SEQ -and $ENABLE_CD_AUDIO -and $CD_TRACKS.ContainsKey(11)) {
    $fxUs  = [double]$CD_TRACKS[11].us
    $fxEnd = $BOOT_FX_DELAY_US + $fxUs
    Write-Host ("boot effect: {0:N2} - {1:N2} s of a {2:N2} s sequence  (track {3:N2}s, {4:N2}s of animation after it)" -f `
                ($BOOT_FX_DELAY_US/1e6), ($fxEnd/1e6), ($BOOT_HOLD_US/1e6), ($fxUs/1e6), (($BOOT_HOLD_US - $fxEnd)/1e6))
    if ($fxEnd -gt $BOOT_HOLD_US) {
        throw ("boot effect: still playing at {0:N2}s but the sequence hands over at {1:N2}s -- it would be cut off" -f `
               ($fxEnd/1e6), ($BOOT_HOLD_US/1e6))
    }
    if ($BOOT_FX_DELAY_US -ge $BOOT_HOLD_US) { throw 'boot effect: asked for after the sequence has already ended' }
}

# The game's 16-slot timer service (ISR at 0x604A2). Slot 15 is the one that
# keeps the BIOS tick alive, so its accumulator is a microsecond counter inside
# the current tick and its period is 54925 us. Byte offset 0x3C = slot 15.
$TIMER_STATE15  = 0x148524 + 0x3C   # = 0x148560, set to 2 at 0x60753
$TIMER_ACC15    = 0x148564 + 0x3C   # = 0x1485A0, us elapsed inside this tick
$TIMER_PERIOD15 = 0x1485A4 + 0x3C   # = 0x1485E0, 0xD68D = 54925 us = 18.2065 Hz

# Where the clock/limiter blob lives -- declared up here because the cave stub
# has to call into it, and the stub is assembled first.
#
# THE LIMITER MUST BE THE FIRST THING IN THAT BLOB, so its address is exactly
# $ACTOR_TIME_AT and the stub can reach it with a literal. Anything emitted
# before it would silently move it.
$ACTOR_TIME_AT  = [uint32]0x50F2D
$ACTOR_TIME_CAP = 419
# Needs the ~1300 bytes of bank-crossing code that only go dead when the linear
# framebuffer is on, so it rides with that flag; otherwise the percentage gate
# stays in use.
$ENABLE_ACTOR_TIME = $ENABLE_LFB

# ---- story / message log -----------------------------------------------------
# The log is the text-box object at 0x1521AC: a 170x206 surface floated over the
# right of the 3D view. Scaling it is genuinely two immediates (see textbox-w/h)
# because the renderer derives wrap width from the surface and line height from
# the font, so the text simply re-wraps.
#
# The box is RIGHT-anchored: narrowing it shifts its draw X by the width delta so
# the right edge does not move, and the hot spots inside it take the same shift.
# Width and height scale INDEPENDENTLY. Narrow is what keeps the log out of the
# scene; tall is what stops it scrolling every other line, and the two wants pull
# in opposite directions. Only the width feeds the right-anchor shift.
# HEIGHT IS BACK TO STOCK (1.0). The box doubles as the CONVERSATION menu: the
# draw path at 0x14F86 branches on 0x152B32 and builds a rect (0, selY, 170, 206)
# for the selectable list. That 206 is the stock box height and is NOT derived
# from textbox-h, so shrinking the box to 175 left the list laid out against 206
# -- the bottom ~31px, four dialogue lines at the stock 7px pitch, fell outside
# what was actually drawn. They could not be seen or picked.
#
# convlist-w / convlist-h below now drive that rect from these same constants, so
# the two can no longer drift; keeping the height at 1.0 also means the list has
# exactly the stock number of visible lines. There is room: the box runs screen y
# 84..290 and the view bottom is 489.
# ---- MOVE THE LOG INTO THE PANEL -------------------------------------------
# The revolving story text normally draws INTO THE 3D VIEW: its destination at
# 0x14F9D is 0x152150, the view surface (the same one the crosshair and reticle
# draw into, see func 0x16043). That is why its Y is bounded by the view height
# and it cannot simply be moved down -- the destination surface has to change.
#
# 0x152AD4 is the panel's big right-hand box: a 170x100 surface created at
# 0x10BA8, touched by nothing except the scan display (func 0x11E68), and blitted
# only when scan mode is on ([0x1523E2], toggled at 0x1351C by the keyboard
# dispatch and by the SCAN button). Pointing the log at it and making that blit
# unconditional puts the log in the box.
#
# KNOWN CONSEQUENCES, both accepted deliberately:
#   * the DIALOGUE CHOICE LIST is the same box (0x14F86 branches on 0x152B32),
#     so conversation options move too and get the panel's height instead of 206.
#   * while scan mode is ON the scan readout owns that surface and takes the box
#     over, because it still writes 0x152AD4.
# THE BOX IS NEVER REPAINTED, so without a clear every frame draws on top of the
# last and the text stacks into an unreadable pile -- the view surface it used to
# live on is redrawn in full each frame, which is why it never needed one. The
# two clearing shims below cost 28 bytes, which only became available after
# AztActorTick and AztNoHudOverlay were gated out of the stub (112 bytes back).
$ENABLE_LOG_IN_PANEL = $true
$LOG_INSET = 2                    # margin inside the panel box
# SCROLLBACK. The log's text surface is DELIBERATELY TALLER THAN THE BOX -- the
# box shows a window onto it and the arrows slide that window.
#
# This is the whole shape of the thing, and getting it wrong cost a round:
#
#   * 0x39120 renders INCREMENTALLY. HudPrint appends and draws only the new
#     text; when the cursor runs past the surface height (0x3927D) it memmoves
#     the surface up by a line (0x392A9) and carries on. So the surface IS the
#     scrollback bitmap -- history lives in it, not anywhere else.
#   * 0x37D98 CLAMPS A POSITIVE Y TO ZERO (0x37DF1) and reads a NEGATIVE one as
#     a source offset (0x37E2F). The clip rect is built before that clamp, so
#     the box does not move. That is why scrolling is one `sub` (AztLogClearBx).
#   * therefore making the surface exactly the box height, which is what the
#     first cut did, means offset 0 already shows everything: nothing above to
#     scroll up into, only blank below. Which is exactly what it did.
#
# aztLogScroll is HOW FAR BACK YOU HAVE SCROLLED FROM THE NEWEST TEXT, in pixels.
# Zero is the bottom, and that is where it starts. Measuring from the bottom
# rather than from the top of the surface is what lets ONE number work in both
# box states: how much is hidden above the window depends on how tall the window
# is, but "20 pixels back from the end" does not.
#
# $LOG_HISTORY is scrollback beyond the EXPANDED box, so there is something to
# scroll in both states. Collapsed, the reachable range is this plus $BOX_EXTEND.
$LOG_HISTORY = 120                # ~15 lines behind the expanded box
$BOX_EXTEND  = 120                # how much taller the expanded box is
# THE WIDESCREEN PANEL (Build-HudWide.ps1, 2026-10-06) opens its log box by a height of its
# own, recorded in hud-box.json as `extend`. Read here, before anything derives from it.
$boxExtJson = Join-Path $PSScriptRoot '..\art\hud-box.json'
if (Test-Path $boxExtJson) { $bxe = Get-Content $boxExtJson -Raw | ConvertFrom-Json; if ($bxe.PSObject.Properties['extend']) { $BOX_EXTEND = [int]$bxe.extend } }
# The UPPER limit is not a constant -- it is (surface - window), which differs
# per state -- so it is enforced in AztBoxWindow, which knows which state it is
# in, and written back so the value can never run away. The key handlers only
# clamp the bottom end, where 0 is 0 in either state.
$LOG_SCROLL_STEP = 8
# ---- EXPANDING LOG BOX -------------------------------------------------------
# A toggle that grows the box UPWARD over the 3D view, plus an automatic expand
# whenever a conversation is on screen. The viewport is NOT touched -- this is an
# overlay on top of it, which is what the stock floating log always was.
#
# It works by flipping three fields of the box surface 0x152AD4 every frame,
# because `Blit` (0x33F80) blits a whole surface from its own base:
#   +2  height      84 <-> 204
#   +E  clip y1     83 <-> 203
#   +4  pixel base  buf + 120 rows <-> buf
# and the blit's Y goes 499 <-> 379 to match. Moving the base rather than just
# the height is what keeps the BOTTOM edge nailed down, so the last line of text
# never moves and the box only ever grows into empty space above.
#
# The surface is allocated at the EXTENDED size (hud-scan-h) so the buffer is big
# enough for both; collapsed simply ignores the top 120 rows.
$ENABLE_LOG_BOX_TOGGLE = $true
# THE TOGGLE IS PART OF THE ARTWORK NOW. Both frames carry a chevron in the
# top-right module -- up on the closed one, down on the open one -- so swapping
# the image swaps the icon for free and no sprite has to be drawn. These are the
# CLICK bounds for it, box-local, deliberately generous: the whole button rather
# than the ink, and stopping short of the vent slots below it.
# The recess background. Index 2 is #2C2A18, the same dark olive the artwork's
# own recess uses, so the flat fill and the frame agree.
$BOX_FILL_COL = 2
$BOX_ICON_X0 = 0   # replaced from art\hud-box.json
$BOX_ICON_X1 = 0
$BOX_ICON_Y0 = 0
$BOX_ICON_Y1 = 0
# The log's font. GENBLU2.PCX is 1191x15 and was built for a box twice this size;
# SMALLFON.PCX is the same glyph strip at 11 rows. The filename is fixed at
# 0x1400FE with exactly 12 bytes before the next string, so 'smallfon.pcx' does
# not fit -- AztMod ships the small strip UNDER THE NAME GENBLU2.PCX instead,
# which costs nothing because that file is already in the re-palette set.
$LOG_FONT_SRC = 'SMALLFON.PCX'

# ---- THE LOG KEEPS MINDSCAPE'S OWN FONT ------------------------------------
# Compared side by side against vanilla, the stock sheets read as crisper in the
# story/dialogue box, and the reason is structural rather than a matter of taste:
#
#   stock RUSGLD2  1380x12, indices 54 + 56 only   -- a hand-made bitmap face,
#   stock GENBLU2  1380x12, indices 54 + 55 only      solid 3px strokes, no
#                                                     partial coverage anywhere
#
# Nothing generated from a TrueType outline at this size can match that. Verdana
# at 12.5em/15 rows is mostly anti-aliased fringe, and every way of resolving the
# fringe has now been tried and rejected: six levels snapped to the full palette
# (dots, because the mid-tones landed on scene indices), six levels restricted to
# 1..56 (stable but muddy), two levels (the stems collapse to black), and a
# hinted 1bpp render at 8/11 (reads as an approximation of the typeface).
#
# So the log simply does not ship a replacement any more. Build-Font skips both
# sheets, they leave the manifest's art list, and the installer's own sweep --
# "any art this build no longer ships must go back to stock" -- restores them
# from the .aztbak copies. The rest of the HUD keeps the generated face.
#
# Two consequences, both fine and both wanted: line height comes off the sheet
# (0x39255), so 12 rows instead of 15 packs MORE lines into the box; and the
# stock glyphs are a little wider, so a 150px line holds a few characters fewer.
# FALSE AGAIN AT 1600x1200, and the reasoning above has not been thrown away -- it
# was all measured at 1024x768, where the generated sheet was 12 rows. It is the
# SIZE that changed, not the verdict.
#
# The stock sheets are 1380x12, authored for 640x480. $HS went 1.6 -> 2.5, so the
# panel, the log recess and every widget grew 56% while the log text stayed at 12
# rows -- Josh's "the interface text is far too small now". Keeping stock was right
# when the alternative was a bad 12-row render; it is wrong when the alternative is
# a good 24-row one, because anti-aliased glyphs get BETTER as they get bigger,
# which is exactly the opposite of the regime the old note was written in.
#
# WHY 24 AND NOT Hi(12) = 30. The renderer takes the wrap width from the surface
# and the line height from the sheet, so a taller font costs characters per line in
# a fixed 287 px recess. Measured on the generated sheets (139 glyphs, sheet width
# / 139 = average advance):
#
#     rows   avg advance   chars per line in 287 px
#     12 (stock)   9.9         ~29
#     19          10.5         ~27
#     24          12.4         ~23     <-- chosen
#     30          14.9         ~19
#
# 30 is the principled scale and reads as cramped prose; 24 is double the stock
# height -- an unmistakable fix -- and still holds a sensible line. Raise it to 30
# here and in src\Build-Art.ps1 together if a bigger face is wanted.
$LOG_FONT_STOCK  = $false
$LOG_FONT_ROWS   = 21        # 24 until 2026-10-07 (Josh: slightly smaller, more text in the log)
$LOG_FONT_EM     = 17.5      # rows x 10/12, the stock sheet's own em-to-row ratio
$LOG_FONT_LEVELS = 6         # a bigger glyph shows steps that 4 hid at 640x480
# THE HANDSHAKE. Build-Art generates the sheets and this build publishes their size,
# so the two have to agree -- and the engine takes LINE HEIGHT off the sheet itself
# (0x39255), which means a stale sheet does not look wrong, it silently re-wraps the
# whole log at the wrong leading. Check it rather than hope.
if (-not $LOG_FONT_STOCK) {
    $_lf = Join-Path $PSScriptRoot '..\art\RUSGLD2.PCX'
    if (-not (Test-Path $_lf)) {
        throw "the log font is generated now, but art\RUSGLD2.PCX is missing -- run src\Build-Art.ps1 (or set `$LOG_FONT_STOCK = `$true)"
    }
    # Straight out of the PCX header (ymax-ymin+1 at offsets 10/6), NOT via
    # [LeTool.Pcx]: this check runs long before Build-AztMod Add-Types PcxTool, and
    # using it here fails with "Unable to find type [LeTool.Pcx]".
    $_lfb = [IO.File]::ReadAllBytes((Resolve-Path $_lf).Path)
    if ($_lfb[0] -ne 0x0A) { throw "art\RUSGLD2.PCX is not a PCX (first byte 0x$('{0:X2}' -f $_lfb[0]))" }
    $_lfh = [BitConverter]::ToUInt16($_lfb,10) - [BitConverter]::ToUInt16($_lfb,6) + 1
    if ($_lfh -ne $LOG_FONT_ROWS) {
        throw ("art\RUSGLD2.PCX is {0} rows but this build expects {1}. Re-run src\Build-Art.ps1 -Only Font (both files carry the size; change them together)." -f $_lfh, $LOG_FONT_ROWS)
    }
}
$BLIT            = [uint32]0x33F80   # Blit(eax = surface, edx = x, ebx = y)
$SURF_CLEAR      = [uint32]0x37FC8   # Clear(eax = surface); what 0x11ECC uses
$TEXT_DRAW_PLAIN = [uint32]0x37D98   # draw a text block   (called from 0x14FA6)
$TEXT_DRAW_LIST  = [uint32]0x37E74   # draw the selectable list (from 0x14FE3)

$TEXTBOX_SCALE_W = 0.70
$TEXTBOX_SCALE_H = 1.00
$TEXTBOX_W_OLD  = 170
$TEXTBOX_H_OLD  = 206
$TEXTBOX_RIGHT_PAD = 14   # gap left between the box and the right edge of the view
$ENABLE_TEXTBOX_RESCALE = ($TEXTBOX_SCALE_W -ne 1.0 -or $TEXTBOX_SCALE_H -ne 1.0)
$TEXTBOX_W      = [int][Math]::Round($TEXTBOX_W_OLD * $TEXTBOX_SCALE_W)
$TEXTBOX_H      = [int][Math]::Round($TEXTBOX_H_OLD * $TEXTBOX_SCALE_H)
# The VISIBLE height. Only differs from the surface when the log is in the panel
# and carries scrollback; everywhere else the box is the surface.
$LOG_WIN_H      = $TEXTBOX_H
# Right-anchored, then pulled back off the edge by the padding.
$TEXTBOX_DX_EXTRA = ($TEXTBOX_W_OLD - $TEXTBOX_W) - $TEXTBOX_RIGHT_PAD

# Full screen width, from under the compass strip down to the top of the panel --
# wherever the panel currently starts.
$VIEW_W = $SCREEN_W
$VIEW_X = 0
# y 0..48 carries the compass strip; covering it makes it flicker.
#
# THE STRIP MUST NOT SCALE. It used to be `Hi 49` = 61 at 800x600, on the theory
# that it scales with everything else. It does not: rows 0..48 of HUD3.PCX are
# COMPLETELY EMPTY (verified -- every pixel is background index 54), and the only
# thing up there is COMPMAP.PCX, a fixed 348x24 sprite blitted at (146,15) by
# 0x13EFD/0x13F02. Nothing about it scales, so reserving 61 rows for a 24-row
# sprite just left a band of dead background and pushed the viewport down.
$COMPASS_W = 348
$COMPASS_H = 24
$COMPASS_Y = 15
$VIEW_Y = $VIEW_Y_KEEP
if ($VIEW_Y -lt $COMPASS_Y + $COMPASS_H) { throw "the viewport would cover the compass" }
# ...and the bottom edge follows from the top, not from a repeated literal. The
# old form subtracted a hard-coded 49 from the panel top while VIEW_Y was 61, so
# the viewport ran 12 rows PAST the panel top and covered the inventory.
$VIEW_H = $(if ($ENABLE_PANEL_RESCALE) { $PANEL_TOP_NEW } else { $PANEL_TOP_OLD }) - $VIEW_Y
# $INJ_H is the same quantity computed ~1400 lines earlier, because the injection
# rectangle is needed before the panel geometry is read. Tie the two together: if
# they ever drift, the host's pixels land on a surface of a different height and
# the boot animation writes past the end of its own buffer.
if ($ENABLE_VIEW_INJECT -and $INJ_H -ne $VIEW_H) {
    throw "INJ_H $INJ_H does not match the viewport height $VIEW_H -- the two derivations have drifted apart"
}
if ($ENABLE_VIEW_INJECT -and $INJ_W -ne $VIEW_W) {
    throw "INJ_W $INJ_W does not match the viewport width $VIEW_W"
}
# Reported HERE, not at $RENDER_SCALE, because the viewport height only exists by now.
if ($ENABLE_RELEVEL_KICK) {
    if ($RENDER_SCALE -eq 0) {
        Write-Host "render scale: following the player's own level (device rebuild only)"
    } else {
        Write-Host ("render scale: forcing level {0} -- 3D drawn at {1}x{2}, expanded by the engine to {3}x{4} ({5:P0} of the fill); HUD and panel stay native" -f `
            $RENDER_SCALE, [int]($VIEW_W/$RENDER_SCALE), [int]($VIEW_H/$RENDER_SCALE),
            $VIEW_W, $VIEW_H, (1.0/($RENDER_SCALE*$RENDER_SCALE)))
    }
}

# 3D viewport centre. Derived from the stock combat edge-turn thresholds
# (x 49..589, y 54..322 => a 552x282 view at x 44..596, y 47..329).
$CENTRE_X = [int]($VIEW_X + $VIEW_W/2)
$CENTRE_Y = [int]($VIEW_Y + $VIEW_H/2)

# ---- the system fold-out (Q menu) ------------------------------------------
# SAVE%02d.pcx, 14 frames, blitted INTO the 3D view surface at 0x14CFF. Stock is
# 206x170 at in-view (377,34) and it slides 7 px per animation step; AztMod used
# to add 44 to the X purely to hold its stock SCREEN position while the view
# origin moved.
#
# Now it is REBUILT at 2x by src\Build-SysMenu.ps1 and latched to the right edge
# of the viewport, which is where a fold-out on the player's wrist belongs. 2x
# exactly, because every one of the game's own slider constants is an 8-bit
# immediate and a non-integer factor turns each of them into its own problem.
#
# THE SLIDE IS TURNED OFF (imul 7 -> 0). The regenerated frames animate the panel
# ARRIVING -- each one reveals more of it from the right edge leftwards -- so a
# simultaneous X slide would fight the artwork instead of adding to it.
# 1.6x rather than 2x: at 2x it was right, just large enough to own the screen.
# The plates below were MEASURED at 2x (412x340), so that stays the reference
# space they are expressed in and everything scales off it -- re-measuring them
# every time the panel is resized is how the artwork and the hit test drift
# apart.
# THE TWO VISOR MENUS, BALANCED (Josh, 2026-10-09: "move both the system menu and the save/load graphics to the left so
# that, when both are open, there is exactly the same space on the left and right"). Both sat 90 px from the left and the
# system menu ran ~21 px past the right edge; 56 px left makes it ~34 / 35 game px each side (the picture's mapping is a
# plain scale, so that holds on any display). This moves the fold-out (art, hot spots, slider maths -- retro too) and the
# memory core's hot spots; tools\ScanWire.cs VisorMenu carries the same numbers.
$MENU_SHIFT = 56
$SYSMENU_REF_W = 412
$SYSMENU_REF_H = 340
# DERIVED from the stock fold-out, not written down. 330x272 was exactly Hi(206) x
# Hi(170) at 1024 and reads as 32% of the viewport's width there; left as a literal
# it would have been 21% at 1600, i.e. the panel quietly shrinking as the screen
# grew. Hi() reproduces 330x272 at 1024 to the pixel, so this is a no-op there.
$SYSMENU_W  = Hi 206
$SYSMENU_H  = Hi 170
$SYSMENU_K  = $SYSMENU_W / [double]$SYSMENU_REF_W
$SYSMENU_VX = $VIEW_W - $SYSMENU_W - $MENU_SHIFT   # in-view: flush with the right edge, less the menus' balance shift
$SYSMENU_VY = 40                             # near the TOP, not centred
function Sys-S([double]$v) { return [int][Math]::Round($v * $SYSMENU_K) }
$SYSMENU_SX = $VIEW_X + $SYSMENU_VX          # the same thing in SCREEN coords,
$SYSMENU_SY = $VIEW_Y + $SYSMENU_VY          # which is what hot spots are in

# The five control plates, in PANEL-LOCAL coordinates at the 2x size. Measured
# off the master by isolating bright warm-gold blobs, then checked by eye against
# design\incoming\sysmenu\plates-detected.png. src\Build-SysMenu.ps1 states the
# same five rectangles and draws the lit states from them, so the artwork and the
# hit test are derived from one measurement -- if these ever disagree, a button
# lights up somewhere other than where it can be clicked.
$SYSMENU_PLATES = @(
    @{ n='load';  x=134; y= 71; w=59; h=19 }
    @{ n='music'; x=241; y=106; w=59; h=20 }
    @{ n='quit';  x=177; y=144; w=38; h=23 }
    @{ n='sfx';   x=240; y=187; w=32; h=20 }
    @{ n='save';  x=137; y=213; w=59; h=19 }
)
$SYSMENU_PAD = 4                             # clickable margin around a plate

# The confirm prompt, in the SAME 412x340 reference space as the plates above.
#
# This is the one fold-out control that was not stated here, and it was the one that did
# not work. Its hot spot was hand-placed in panel-local coordinates (100,260,100x32) while
# Build-SysMenu draws the caption centred on reference x=150 with its top at y=266 -- which
# scales to local y 213..233. The rectangle therefore sat 53 px BELOW the words, and its
# bottom edge ran 20 px past the bottom of a 272-tall panel. Every other control worked
# because every other control came from $SYSMENU_PLATES.
#
# Georgia Bold at 15 reference-pt measures 120x25 for 'Quit Game' and 92x25 for 'confirm';
# the box is sized for the wider of the two, since one rectangle serves both captions.
$SYSMENU_CONFIRM = @{ cx = 150; y = 266; w = 120; h = 26 }

# The two volume level bars (temp.pcx and bemp.pcx, stock 87x27), scaled with
# everything else so they fill the new panel instead of sitting in it like
# postage stamps. That means moving EVERY constant in the slider chain, and three
# of them are 8-bit immediates with no room to widen:
#
#   0x14D50  cmp eax,87        clamp    -> AztSliderClamp0/1
#   0x14E34  imul edx,edx,87   vol->px  -> AztSliderPx0/1
#   0x14E91  imul edx,edx,87   vol->px
#
# The rest (the /87 divisor, the source-rect extents, the bar surface and its
# buffer) are imm32 or imm16 and change in place. They all have to move together:
# the click maths, the source rect and the bar image are three descriptions of
# the same track, and any one of them left at 87 puts the fill somewhere the
# pointer is not.
# SIZED FROM THE ARTWORK, NOT FROM THE STOCK BAR.
#
# These used to be `0x57 * W / 206` and `0x1B * H / 170` -- Mindscape's 87x27 bar
# scaled by the ratio of the new fold-out to the OLD one. That keeps the bar's
# proportion of the *stock* panel, which has nothing to do with where the recess is
# in the new render: the bars came out undersized and sat high in their well.
#
# The well is the big dark ellipse on the left of the master. Measured off
# master.png (dark, opaque, largest run per row) it spans REF x 15..221 at its
# widest, and the clear band between the `load` plate (REF y 71) and the `save`
# plate (REF y 213) is REF y ~90..213. So: two bars 192 wide and 58 tall, inset to
# x 22, stacked at y 90 and y 155 -- 2*58 + 7 of gap = 123 = exactly that band, so
# they are evenly spaced in it instead of crowding the top.
#
# src\Build-SysMenu.ps1 renders the bar art from these SAME four REF numbers via
# its own $SK (which is $W/412, identical to $SYSMENU_K), so the art and the click
# maths cannot drift apart.
# Widened LEFT by 10 REF px on 2026-09-24: the right end was landing correctly but
# the bar stopped short of the ellipse's left side. The right edge is held fixed at
# REF 214 (= 12 + 202, previously 22 + 192), because that end was already right.
# Measured interior of the well at the bars' own rows is REF x ~5..221, so 12 keeps
# a margin off the curve.
$SYSMENU_SLIDER_REF_W = 202
$SYSMENU_SLIDER_REF_H = 58
$SYSMENU_SLIDER_W  = Sys-S $SYSMENU_SLIDER_REF_W
$SYSMENU_SLIDER_H  = Sys-S $SYSMENU_SLIDER_REF_H
$SYSMENU_SLIDER_LX = Sys-S 12                # panel-local X of the track's LEFT end
# The clear shell between the load bar and the save bar is the only place two
# bars fit without covering a label.
$SYSMENU_SLIDER_LY = @((Sys-S 90), (Sys-S 155))   # panel-local Y, music then sfx
# The mouse maths is `value = RIGHT_EDGE - mouseX` clamped to 0..87, so the
# constant the game compares against is the track's RIGHT end in screen space.
$SYSMENU_SLIDER_R  = $SYSMENU_SX + $SYSMENU_SLIDER_LX + $SYSMENU_SLIDER_W

# ===========================================================================
#  Stub
# ===========================================================================
$a = New-Asm -Base $CAVE_BASE

# ---- data (reached as [esi + <label>]) ----
Add-Label $a 'aztMagic';      A-Db $a ([byte[]][char[]]'AZTM')
Add-Label $a 'aztVersion';    A-Dw $a 0x0900
Add-Label $a 'aztEnabled';    A-Dw $a 1      # master switch (F2)
Add-Label $a 'aztWantCursor'; A-Dw $a 0      # 0 = look, 1 = free pointer (F3 / RMB)
# 1 = the recorded soundtrack, 0 = Mindscape's original MIDI score (F4).
# IT LIVES HERE, NOT IN THE OVERLAY, because the key handler is in this blob and is
# assembled first -- it cannot name an overlay label, but the overlay can name this
# one. The overlay watches it for changes rather than being poked directly.
Add-Label $a 'aztCdOn';       A-Dw $a 1
Add-Label $a 'aztCentreX';    A-Dw $a $CENTRE_X
Add-Label $a 'aztCentreY';    A-Dw $a $CENTRE_Y
Add-Label $a 'aztScratch';    A-Dw $a 0; A-Dw $a 0   # GetMickeys output
Add-Label $a 'aztStrafeDir';  A-Dw $a 0      # 0 none, 1 right, 2 left
Add-Label $a 'aztFwdHeld';    A-Dw $a 0      # W currently held
Add-Label $a 'aztLogScroll';  A-Dw $a 0      # pixels scrolled BACK from the newest text
Add-Label $a 'aztKeyEv';      A-Db $a ([byte[]](,0 * 16))  # synthetic key event
Add-Label $a 'aztSaveX';      A-Db $a ([byte[]](,0 * 4))   # pre-move position, wall slide
Add-Label $a 'aztSaveZ';      A-Db $a ([byte[]](,0 * 4))
Add-Label $a 'aztSlideDone';  A-Dw $a 0      # one slide retry per frame
Add-Label $a 'aztRetry';      A-Db $a ([byte[]](,0 * 4))   # where to resume the blocked step
Add-Label $a 'aztSaveDirX';   A-Db $a ([byte[]](,0 * 4))   # pre-slide movement vector
Add-Label $a 'aztSaveDirZ';   A-Db $a ([byte[]](,0 * 4))
# actor / animation rate throttle -- percent of frames on which actors step
Add-Label $a 'aztActorPct';   A-Dw $a $ACTOR_PCT
Add-Label $a 'aztActorAcc';   A-Dw $a 0
# the wall normal, copied out of 0x162DD4 and normalised in place by 0x441A8.
# Must stay three CONTIGUOUS floats -- 0x441A8 is handed a pointer to the lot.
Add-Label $a 'aztWallN';      A-Db $a ([byte[]](,0 * 4))   # .X
Add-Label $a 'aztWallNY';     A-Db $a ([byte[]](,0 * 4))   # .Y, forced to 0
Add-Label $a 'aztWallNZ';     A-Db $a ([byte[]](,0 * 4))   # .Z

# ---------------------------------------------------------------------------
# AztDeltas -> esi = obj1 delta, edi = obj2 delta. Clobbers eax.
#
# esi comes from call/pop: the difference between where we actually are and
# where we were built to be. edi comes from reading a loader-resolved pointer
# out of the game's own preserved instruction operand.
# ---------------------------------------------------------------------------
Add-Label $a 'AztDeltas'
A-CallNext $a
Add-Label $a 'AztDeltaRef'
A-PopEax $a
A-SubEaxImm $a 'AztDeltaRef'
A-MovEsiEax $a
A-MovEaxSi  $a $FIXUP_SRC          # mov eax, [esi + 0x13DCB]
A-SubEaxImm $a $g_mouselookOn
A-MovEdiEax $a
A-Ret $a

# ---------------------------------------------------------------------------
# AztFrameHook -- reached once per frame from HOOK_FRAME.
# ---------------------------------------------------------------------------
Add-Label $a 'AztFrameHook'
A-PushEax $a; A-PushEsi $a; A-PushEdi $a
# Cap the frame rate here, at the top of the ONLY hook that is reached
# unconditionally every frame. It was originally hung off the actor hook, which
# is guarded by `cmp word [0x1525F2],0 / jnz` at 0x13DE1 -- a hold-the-actors
# flag SET in the opening room and cleared by a room load, so the first room ran
# uncapped until you walked out and back.
#
# Called by literal address because AztFrameLimit lives in a second blob that is
# assembled after this one; it is emitted FIRST there, so its address is exactly
# $ACTOR_TIME_AT, and the build asserts that. It preserves every register.
if ($ENABLE_ACTOR_TIME) { A-Call $a $ACTOR_TIME_AT }
A-Call $a 'AztDeltas'

# One wall-slide retry per frame. Cleared BEFORE the F2 check on purpose: the
# slide patches are unconditional, so if this only ran while the mod was enabled,
# disabling it would leave the flag stuck and silently kill sliding for good.
A-MovWordSiImm $a 'aztSlideDone' 0

A-CmpWordSiImm $a 'aztEnabled' 0
A-Jz $a 'AFH_vanilla'

# The log box's expand/collapse icon is hit-tested here rather than through the
# hot-spot polygon tables: those are prebuilt into malloc'd copies at start-up
# (0x2A3F4 -> 0x164D9C+N*14), so adding an entry would mean growing and
# relocating a table. Reading the cursor and the button ourselves is 40 bytes in
# the second cave and touches none of the game's own picking.
#
# Same literal-address convention as AztFrameLimit above: AztBoxClick is the
# FIRST trampoline in the box blob, which the build asserts.
if ($ENABLE_LOG_BOX_TOGGLE) { A-Call $a $BOX_CLICK }

# v0.4.0 simply INVERTS the stock gesture: look is the default, and holding the
# right button gives back the game's own pointer. That means cursor mode is 100%
# stock -- the contextual TAKE/USE/PUSH icons and picking are untouched by us,
# which is what broke when v0.3.0 tried to keep a pinned pointer live.
# aztWantCursor (F3) is an extra keyboard override, OR'd with the button.
#
# ...and so is having a MENU up. $g_guardA is the UI-screen selector: 0 means the
# normal in-world screen, non-zero means one of the fold-out screens (the Q system
# menu -- hot-spot screens 1..3 carry its volume sliders and save/load/quit
# buttons, see the hotspots block). It used to fall through to the guard list
# below, which just returns and leaves whatever mode was already active. If the Q
# menu was opened during combat that meant staying in LOOK mode, so the buttons
# were only reachable while physically holding the right button -- the menu was
# up and apparently dead until you did.
#
# Routing it to AFH_cursor instead is exactly the right-button path: it exits
# mouselook AND drops combat, so opening the menu behaves as if the pointer were
# already being held. It is idempotent (both calls test their flag first), so
# forcing it every frame the menu is up costs nothing, and when the menu closes
# the guard clears and the self-correcting block below restores combat.
# $g_guardB is the ORRERY PUZZLE (see its declaration -- it was long mislabelled
# here as the talking-to-people flag, which is why NPC dialogue never picked this
# path). $g_convList is the real one: while it is set the story log is a list of
# selectable dialogue lines, and without this the lines could only be clicked
# while physically holding the right button, exactly as the Q menu could not.
#
# Note the conversation opener 0x17E52 turns combat off ITSELF (0x17EBE/0x17EC3),
# so AFH_cursor's own combat drop is a no-op here; what matters is that routing
# conversations to AFH_cursor also stops the self-correcting block below from
# seeing "combat is off" and switching it straight back on.
A-MovAxDi $a $g_rmbHeld
A-OrAxSi  $a 'aztWantCursor'
A-OrAxDi  $a $g_guardA
A-OrAxDi  $a $g_guardB
A-OrAxDi  $a $g_convList
A-TestAxAx $a
A-Jnz $a 'AFH_cursor'

# --- LOOK MODE: combat on (crosshair + left click fires), pointer pinned ---
# In combat the pointer IS the crosshair: a fixed bitmap with no contextual
# icons, so pinning it is safe. That is the crucial difference from v0.3.0,
# which pinned the context-sensitive pointer and froze its icons.
# If a menu or modal is up, Space would be refused anyway -- leave the game
# completely alone rather than fighting it every frame.
#
# $g_guardA, $g_guardB and $g_convList USED to be re-loaded here and are not any
# more, because reaching this point PROVES all three are zero: the test above OR'd
# them into ax and fell through only on ax == 0. Dropping the two dead `or`s pays
# for the $g_convList one added above, which matters -- the cave had 5 bytes left.
A-MovAxDi $a $g_book
A-OrAxDi  $a $g_guardC
A-TestAxAx $a
A-Jnz $a 'AFH_done'

# Self-correcting: whatever turns combat off (the Q menu, death, a script), we
# notice and restore it. Space is refused while mouselook is on (stock guard at
# 0x131EF), so if combat is off while we are looking, drop the look for one frame
# and the transition path below puts both back.
A-CmpWordDiImm $a $g_combat 0
A-Jnz $a 'AFH_combatOk'
A-CmpWordDiImm $a $g_mouselookOn 0
A-Jz $a 'AFH_sendSpace'
A-Call $a $ExitMouselook
A-Jmp $a 'AFH_done'
Add-Label $a 'AFH_sendSpace'
A-Call $a 'AztSendSpace'

Add-Label $a 'AFH_combatOk'
A-CmpWordDiImm $a $g_mouselookOn 0
A-Jnz $a 'AFH_pin'                 # already looking -> just keep it pinned
A-LeaEaxSi $a 'aztScratch'
A-Call $a $GetMickeys              # flush pending motion so the view does not jump
A-MovWordDiImm $a $g_mouselookOn 1 # engage mickey look WITHOUT hiding the pointer
Add-Label $a 'AFH_pin'
A-MovWordDiImm $a $g_mouseOn 1
A-MovzxEdxSi $a 'aztCentreY'
A-MovzxEaxSi $a 'aztCentreX'
A-Call $a $SetMousePos
A-Jmp $a 'AFH_done'

# --- CURSOR MODE: combat off, pointer back, entirely stock from here ---
Add-Label $a 'AFH_cursor'
A-CmpWordDiImm $a $g_mouselookOn 0
A-Jz $a 'AFH_done'                 # already in cursor mode
A-Call $a $ExitMouselook           # transition frame
A-CmpWordDiImm $a $g_combat 0
A-Jz $a 'AFH_done'
A-Call $a 'AztSendSpace'           # drop combat so the context pointer comes back
A-Jmp $a 'AFH_done'

# --- mod disabled: reproduce the original 25 bytes ---
Add-Label $a 'AFH_vanilla'
A-CmpWordDiImm $a $g_mouselookOn 0
A-Jz $a 'AFH_done'
A-CmpWordDiImm $a $g_rmbHeld 0
A-Jnz $a 'AFH_done'
A-Call $a $ExitMouselook

Add-Label $a 'AFH_done'
A-PopEdi $a; A-PopEsi $a; A-PopEax $a
A-Ret $a

# ---------------------------------------------------------------------------
# AztRmbDown -- replaces `call EnterMouselook`. Right button toggles modes.
# ---------------------------------------------------------------------------
# The stock handlers do the opposite of what we want (press = enter look), so when
# the mod is on they do nothing at all and AztFrameHook drives everything from
# g_rmbHeld. One frame of latency, one source of truth.
Add-Label $a 'AztRmbDown'
A-PushEax $a; A-PushEsi $a; A-PushEdi $a
A-Call $a 'AztDeltas'
A-CmpWordSiImm $a 'aztEnabled' 0
A-Jz $a 'ARD_vanilla'
A-PopEdi $a; A-PopEsi $a; A-PopEax $a
A-Ret $a
Add-Label $a 'ARD_vanilla'
A-PopEdi $a; A-PopEsi $a; A-PopEax $a
A-Jmp $a $EnterMouselook

# ---------------------------------------------------------------------------
# AztRmbUp -- replaces `call ExitMouselook`. In toggle mode, release does nothing.
# ---------------------------------------------------------------------------
Add-Label $a 'AztRmbUp'
A-PushEax $a; A-PushEsi $a; A-PushEdi $a
A-Call $a 'AztDeltas'
A-CmpWordSiImm $a 'aztEnabled' 0
A-Jz $a 'ARU_vanilla'
A-PopEdi $a; A-PopEsi $a; A-PopEax $a
A-Ret $a
Add-Label $a 'ARU_vanilla'
A-PopEdi $a; A-PopEsi $a; A-PopEax $a
A-Jmp $a $ExitMouselook

# ---------------------------------------------------------------------------
# AztSendSpace -- synthesise a Space keypress to toggle combat mode.
#
# The combat toggle is written inline in the key handler and its OFF path uses
# locals from that function's own stack frame, so it cannot be called directly.
# Driving the real handler with a fake event runs the exact stock code. The
# handler only ever reads bytes +5, +6 and +7 of an event, so a zeroed buffer
# with ascii = 0x20 is enough.
# ---------------------------------------------------------------------------
Add-Label $a 'AztSendSpace'
A-LeaEaxSi $a 'aztKeyEv'
A-MovByteEaxDispImm $a 6 0x20      # ascii ' '
A-MovWordEaxDispImm $a 7 0x39      # scancode Space
A-Call $a $KeyHandler
A-Ret $a

# ---------------------------------------------------------------------------
# AztCursorRedraw -- replaces `call CursorRedraw` in the mouse move handler.
#
# Pins the crosshair while looking. Deliberately gated on g_combat: v0.3.0 had
# this hook without that check, and pinning the *context-sensitive* pointer
# froze its TAKE/USE/PUSH icons, because the game re-picks as the pointer moves.
# The combat crosshair is a fixed bitmap, so pinning it costs nothing.
# ---------------------------------------------------------------------------
Add-Label $a 'AztCursorRedraw'
A-PushEax $a; A-PushEsi $a; A-PushEdi $a
A-Call $a 'AztDeltas'
A-CmpWordSiImm $a 'aztEnabled' 0
A-Jz $a 'ACR_done'
A-CmpWordSiImm $a 'aztWantCursor' 0
A-Jnz $a 'ACR_done'
A-CmpWordDiImm $a $g_rmbHeld 0
A-Jnz $a 'ACR_done'
A-CmpWordDiImm $a $g_mouselookOn 0
A-Jz $a 'ACR_done'
A-CmpWordDiImm $a $g_combat 0
A-Jz $a 'ACR_done'                 # never pin a context cursor -- see above
A-MovAxSi $a 'aztCentreX'
A-MovDiAx $a $g_mouseX
A-MovAxSi $a 'aztCentreY'
A-MovDiAx $a $g_mouseY
Add-Label $a 'ACR_done'
A-PopEdi $a; A-PopEsi $a; A-PopEax $a
A-Jmp $a $CursorRedraw

# ---------------------------------------------------------------------------
# AztActorTick -- replaces `call 0x261C0`, the per-frame actor/animation stepper.
#
# The game is frame-tied end to end: movement is `pos += dir * constant` and the
# animation system (0x20000..0x25000) never reads a clock once. So raising the
# emulated CPU buys frame rate and game speed together, and characters start
# moving like cartoons.
#
# 0x261C0 is where actors advance. It walks the actor list and bumps each one's
# keyframe cursor -- `inc word [eax+0x3C]`, seven sites at 0x26233..0x26488, all
# inside this one function -- then reads that cursor back at 0x2626B, scales it
# by the 0x23-byte keyframe record size and pulls the actor's transform out of
# it. So the cursor drives pose AND position together; throttling it slows both
# coherently rather than desyncing them.
#
# Gating the single call site is far better than patching the seven `inc`s: each
# of those is 4 bytes, too short for a 5-byte call, whereas 0x13DF0 is exactly
# one 5-byte `call` reached once per frame from one place in the whole binary.
#
# A percentage, not an integer divider: "every Nth frame" can only express 1/2,
# 1/3... and the honest ratio here is old-cycles / new-cycles, e.g. 280000/400000
# = 70%. So accumulate the percentage each frame and step when it crosses 100.
# All 16-bit integer maths, no FPU, no clock.
# ASSEMBLED ONLY WHEN IT IS ACTUALLY HOOKED. hook-actor picks AztActorTime (in
# the clock blob) when $ENABLE_ACTOR_TIME is on and this percentage version only
# as the fallback, so with the clock version live these 56 bytes were dead weight
# in a cave that had 12 free.
if ($ENABLE_ACTOR_RATE -and -not $ENABLE_ACTOR_TIME) {
Add-Label $a 'AztActorTick'
A-PushEsi $a; A-PushEdi $a
A-PushEax $a                          # eax is 0x261C0's argument -- AztDeltas eats it
A-Call $a 'AztDeltas'
A-MovAxSi $a 'aztActorPct'
A-AddSiAx $a 'aztActorAcc'
A-CmpWordSiImm $a 'aztActorAcc' 100
A-Jb $a 'AAT_skip'
A-SubWordSiImm $a 'aztActorAcc' 100
A-PopEax $a; A-PopEdi $a; A-PopEsi $a
A-Jmp $a $ACTOR_STEP                  # tail-call: its ret returns to the game
Add-Label $a 'AAT_skip'
A-PopEax $a; A-PopEdi $a; A-PopEsi $a
A-Ret $a
}   # end if (percentage actor stepper)

# ---------------------------------------------------------------------------
# AztStrafe -- replaces `jnz 0x1DAA1` at 0x1D6E7, the first gate of the forward
# movement block. Flags are still live on entry, so they are saved and the
# original branch is reproduced on the way out.
#
# The game has no strafe axis. But movement is `newPos = pos + dir * 16`, and
# `dir` is a unit vector rebuilt from yaw/pitch every frame at 0x1D400. Nothing
# reads it between the camera call at 0x1D4A4 and the movement maths at 0x1D747,
# so rotating it 90 degrees here makes the *stock* movement code -- including all
# of its collision and step handling -- carry the player sideways.
#
# Rotating by 90 degrees needs no FPU at all: it is a swap of the X and Z floats
# with one of them negated, and negating an IEEE float is just flipping bit 31.
# ---------------------------------------------------------------------------
Add-Label $a 'AztStrafe'
A-Pushfd $a
A-PushEax $a; A-PushEdx $a; A-PushEsi $a; A-PushEdi $a
A-Call $a 'AztDeltas'
A-CmpWordSiImm $a 'aztEnabled' 0
A-Jz $a 'AS_done'
A-CmpWordSiImm $a 'aztStrafeDir' 0
A-Jz $a 'AS_done'
A-CmpWordDiImm $a $g_fwdFlag 0         # only while the movement block will actually run
A-Jz $a 'AS_done'
A-MovEaxDi $a $g_dirX
A-MovEdxDi $a $g_dirZ
A-CmpWordSiImm $a 'aztStrafeDir' 1
A-Jnz $a 'AS_left'
# right: x' = z, z' = -x
A-XorEaxImm  $a 0x80000000
A-MovDiEdx32 $a $g_dirX
A-MovDiEax32 $a $g_dirZ
A-Jmp $a 'AS_done'
Add-Label $a 'AS_left'
# left: x' = -z, z' = x
A-XorEdxImm  $a 0x80000000
A-MovDiEdx32 $a $g_dirX
A-MovDiEax32 $a $g_dirZ
Add-Label $a 'AS_done'
A-PopEdi $a; A-PopEsi $a; A-PopEdx $a; A-PopEax $a
A-Popfd $a
A-Jz $a 'AS_fall'                      # original was `jnz 0x1DAA1`
A-AddEspImm $a 4                       # discard our return address...
A-Jmp $a ([uint32]0x1DAA1)             # ...and take the branch the game wanted
Add-Label $a 'AS_fall'
A-Ret $a

# RETIRED with the hot-spot polygon patches (hotspots-screen*), which fix the hit
# test and the highlight draw together. Kept for reference but NOT emitted -- the
# cave is only 1664 bytes and the wall-slide stubs need the room.
$ENABLE_CURSOR_REMAP = $false
if ($ENABLE_CURSOR_REMAP) {

# ---------------------------------------------------------------------------
# AztHudPoint -- rescale a screen click into stock instrument-panel space.
#
# The panel artwork is drawn at $PANEL_SCALE and re-centred, but every hot-spot
# rectangle the game tests against was authored against the full-size 640x480
# artwork. Rather than move several dozen rectangles that live in runtime-built
# region objects, this inverts the artwork transform on the single point the
# dispatcher is about to test.
#
#   inside the new panel rect -> stock = (screen - origin) * recip >> 16
#   below y=318 but outside it -> forced to 317, so a click in the enlarged 3D
#                                 view cannot fall through onto a panel hot spot
#   anything else              -> untouched
#
# The rect guard matters: 0x36B96 also dispatches full-screen menus, whose own
# hot spots are already correct. Limiting the remap to the panel's new footprint
# keeps those working everywhere except the bottom-centre band.
#
# No deltas are needed -- every value here is an immediate baked in at build
# time, and ebp already points at the caller's frame.
# ---------------------------------------------------------------------------
Add-Label $a 'AztHudPoint'
A-PushEbx $a; A-PushEcx $a
A-MovsxEcxEbpDisp $a 0xF2              # ecx = y  (word [ebp-0x0E])
A-CmpEcxImm $a $PANEL_TOP_NEW
A-Jl  $a 'AHP_above'
A-MovsxEbxEbpDisp $a 0xF0              # ebx = x  (word [ebp-0x10])
A-CmpEbxImm $a $PANEL_LEFT_NEW
A-Jl  $a 'AHP_done'
A-CmpEbxImm $a $PANEL_RIGHT_NEW
A-Jg  $a 'AHP_done'
A-SubEcxImm  $a $PANEL_TOP_NEW
A-ImulEcxImm $a $PANEL_RECIP
A-SarEcxImm  $a 16
A-AddEcxImm  $a $PANEL_TOP_OLD
A-SubEbxImm  $a $PANEL_LEFT_NEW
A-ImulEbxImm $a $PANEL_RECIP
A-SarEbxImm  $a 16
A-MovEbpDispBx $a 0xF0
A-MovEbpDispCx $a 0xF2
A-Jmp $a 'AHP_done'

# y is above the shrunken panel. If it still reads as panel territory to the
# stock hot spots (>= 318) it is really a click in the enlarged 3D view, so push
# it one row clear.
Add-Label $a 'AHP_above'
A-CmpEcxImm $a $PANEL_TOP_OLD
A-Jl $a 'AHP_done'
A-MovEbpDispImm16 $a 0xF2 ([uint16]($PANEL_TOP_OLD - 1))

Add-Label $a 'AHP_done'
A-PopEcx $a; A-PopEbx $a
A-MovEaxEbpDisp $a 0xFC                # mov eax, dword [ebp-0x04]   (replaced)
A-CmpDwordEaxDispImm $a 0x52 0         # cmp dword [eax+0x52], 0     (replaced)
A-Ret $a                               # `ret` leaves the flags alone

# ---------------------------------------------------------------------------
# AztHudEvent -- the same remap, applied to the mouse EVENT record.
#
# Replaces `call 0x3668E` at the end of the event builder, so the coordinates a
# widget receives are already in stock-artwork space. This is the path that
# drives hover highlighting and clicks; AztHudPoint alone was not enough,
# because the dispatcher's own cursor read feeds a different scan.
#
# Tail-call: our caller's return address is left in place, so 0x3668E returns
# straight to 0x36D79 exactly as the original `call` would have.
# ---------------------------------------------------------------------------
Add-Label $a 'AztHudEvent'
A-PushEax $a; A-PushEdx $a; A-PushEbx $a; A-PushEcx $a; A-PushEsi $a; A-PushEdi $a
A-Call $a 'AztDeltas'
A-MovsxEcxDi $a $g_evtCursorY
A-CmpEcxImm $a $PANEL_TOP_NEW
A-Jl $a 'AHE_above'
A-MovsxEbxDi $a $g_evtCursorX
A-CmpEbxImm $a $PANEL_LEFT_NEW
A-Jl $a 'AHE_done'
A-CmpEbxImm $a $PANEL_RIGHT_NEW
A-Jg $a 'AHE_done'
A-SubEcxImm  $a $PANEL_TOP_NEW
A-ImulEcxImm $a $PANEL_RECIP
A-SarEcxImm  $a 16
A-AddEcxImm  $a $PANEL_TOP_OLD
A-SubEbxImm  $a $PANEL_LEFT_NEW
A-ImulEbxImm $a $PANEL_RECIP
A-SarEbxImm  $a 16
A-MovDiBx $a $g_evtCursorX
A-MovDiCx $a $g_evtCursorY
A-Jmp $a 'AHE_done'

Add-Label $a 'AHE_above'
A-CmpEcxImm $a $PANEL_TOP_OLD
A-Jl $a 'AHE_done'
A-MovWordDiImm $a $g_evtCursorY ([uint16]($PANEL_TOP_OLD - 1))

Add-Label $a 'AHE_done'
A-PopEdi $a; A-PopEsi $a; A-PopEcx $a; A-PopEbx $a; A-PopEdx $a; A-PopEax $a
A-Jmp $a ([uint32]0x3668E)              # the call we replaced, as a tail call

}   # end if ($ENABLE_CURSOR_REMAP)

# ---------------------------------------------------------------------------
# AztNoHudOverlay -- switch off the HUDTOP/HUDBOT viewport overlays.
#
# Runs once, at the end of the loader, after both .RES files have been read.
# The record counts are 32-bit and live in BSS, so writing zero to both halves
# leaves every one of the 16 overlay call sites with nothing to draw.
#
# esi still holds the open file handle that the replaced `mov eax,esi` feeds to
# the close call, so it is saved across AztDeltas (which returns its own esi).
# ---------------------------------------------------------------------------
# ASSEMBLED ONLY WHEN THE OVERLAYS ARE SUPPRESSED. This zeroes the HUDTOP/HUDBOT
# record counts so all 16 overlay call sites draw nothing -- but AztMod now SHIPS
# both overlays (they are what gives the viewport its rounded corners and the
# panel its bleed), so nothing has called this for some time. 56 dead bytes.
if (-not ($ENABLE_HUD_TOP -or $ENABLE_HUD_OVERLAY)) {
Add-Label $a 'AztNoHudOverlay'
A-PushEsi $a; A-PushEdi $a; A-PushEdx $a
A-PushEax $a
A-Call $a 'AztDeltas'
A-MovWordDiImm $a $g_hudTopCount            0
A-MovWordDiImm $a ([uint32]($g_hudTopCount + 2)) 0
A-MovWordDiImm $a $g_hudBotCount            0
A-MovWordDiImm $a ([uint32]($g_hudBotCount + 2)) 0
A-PopEax $a
A-PopEdx $a; A-PopEdi $a; A-PopEsi $a
A-MovEaxEsi $a                          # mov eax, esi   (replaced)
A-Jmp $a ([uint32]0x3997D)              # the close call we replaced, tail-called
}   # end if (overlays suppressed)

# ---------------------------------------------------------------------------
# Wall sliding.
#
# Stock behaviour on a blocked move is to nudge the player's facing by +/-10 and
# abandon the move (six sites, all `sub/add word [0x162DF8],0xA` + `jmp 0x1DE08`).
# That is the devs' crude anti-stick: turn until you are no longer facing the
# wall. no-wall-turn already neuters the rotation, which leaves a dead stop --
# so this puts a real slide in its place.
#
# The movement math at 0x1D747 does, in effect:
#     local[+0x0C] += dirX * speed      (X)
#     local[+0x14] += dirZ * speed      (Z)
# then collision-tests the result. The two locals are updated IN PLACE, so a
# retry has to put them back first -- hence the save hook.
#
# esp is constant through the whole function (prologue does `mov ebp,esp` /
# `sub esp,0x104` / `and esp,-8`, and every callee in the path is stdcall:
# 0x11E68 ret 0xC, 0x10180 ret 0x18, 0x10160 ret 0xC, 0x3EC20 ret 0xC). So both
# stubs can reach the locals at fixed esp offsets.
#
# The slide direction: the game leaves the wall vector in 0x162DD4 as three
# floats (X,Y,Z) -- it is what the stock code feeds the cross product that picks
# the rotation sign. AztWallSlide projects the movement vector onto the wall
# plane with it; see the design note there for why that is a projection and not
# an axis drop, and why it takes two attempts.
# ---------------------------------------------------------------------------
# AztSaveMove -- replaces `fadd dword [esp+0x14]` + `fxch`, the last point at
# which BOTH position locals still hold the pre-move value.
#
# There are TWO movement paths, identical but for their speed constant: 0x1D747
# (uses [0x141800]) and 0x1D8FB (uses [0x1417FC]). Both are hooked, and one stub
# serves both: the save point sits exactly 0x19 past the start of its own path in
# each case, so the retry target falls out of our own return address. No branch,
# no second copy -- which matters, because the cave has no room for one.
Add-Label $a 'AztSaveMove'
A-PushEax $a; A-PushEsi $a; A-PushEdi $a
A-Call $a 'AztDeltas'
# esp is now 16 below the call site: ret addr + three pushes
A-MovEaxEspDisp $a 0x1C          # local +0x0C = X
A-MovSiEax32 $a 'aztSaveX'
A-MovEaxEspDisp $a 0x24          # local +0x14 = Z
A-MovSiEax32 $a 'aztSaveZ'
A-MovEaxEspDisp $a 0x0C          # our return address
A-SubEaxImm $a 0x19              # -> the head of whichever path called us
A-MovSiEax32 $a 'aztRetry'
# the movement vector too: a second slide attempt needs the unmodified one back
A-MovEaxDi $a $g_dirX
A-MovSiEax32 $a 'aztSaveDirX'
A-MovEaxDi $a $g_dirZ
A-MovSiEax32 $a 'aztSaveDirZ'
A-PopEdi $a; A-PopEsi $a; A-PopEax $a
A-FaddEspDisp $a 0x18            # the replaced fadd, +4 for our return address
A-Fxch $a                        # the replaced fxch
A-Ret $a

# ---------------------------------------------------------------------------
# AztWallSlide -- replaces each `jmp 0x1DE08` on a blocked move. Jumped to, not
# called, so esp is exactly the function's esp on entry.
# ---------------------------------------------------------------------------
#
# The slide vector is a proper PROJECTION, not an axis drop.
#
# v0.11.3 zeroed whichever of dirX / dirZ the wall most opposed. That is only
# correct for a wall that runs along a world axis; on an angled wall it shoves
# you along X or Z, which is still into the wall, so you stick. Azrael's
# geometry has plenty of angled walls, which is exactly where it still stuck.
#
# What we want is the movement vector with its wall-perpendicular part removed:
#
#     d  = v . n                 (2D: Y is flattened, this is a floor slide)
#     v' = v - n*d
#
# n must be unit length for that to hold, and 0x162DD4 is not normalised -- the
# stock code always copies it and calls 0x441A8 first. So do the same: copy the
# three floats into aztWallN, force .Y to zero, and hand 0x441A8 the pointer.
# 0x441A8 normalises in place, returns the pointer in eax, and clobbers nothing
# else (it and 0x441E4 both save edx/ebx and never touch esi/edi), and it has a
# zero-vector guard that yields (1,0,0) rather than a NaN.
#
# Do NOT renormalise v' afterwards. Losing speed as you turn into the wall is
# the behaviour we want; renormalising would slingshot you along it.
#
# TWO attempts, because I still have not proved whether 0x162DD4 holds the wall
# normal or its tangent. Conveniently the two readings are complements of each
# other and share the same dot product:
#
#     n is the normal   ->  v' = v - n*d
#     n is the tangent  ->  v' =     n*d
#
# so attempt 1 takes the first and attempt 2 the second. Whichever reading is
# right, one of them slides; and on an inside corner, where the right answer
# can legitimately still be blocked, we stop after two tries instead of
# grinding. Clobbering dirX/dirZ is free: 0x1D429..0x1D43B rebuilds all three
# direction components from the camera angles at the top of every frame.
Add-Label $a 'AztWallSlide'
A-PushEax $a; A-PushEdx $a; A-PushEsi $a; A-PushEdi $a
A-Call $a 'AztDeltas'
A-CmpWordSiImm $a 'aztSlideDone' 1
A-Ja $a 'AWS_abandon'                     # both readings tried -- let it stop
# put the position AND the movement vector back the way they were
A-MovEaxSi $a 'aztSaveX'
A-MovEspDispEax $a 0x1C
A-MovEaxSi $a 'aztSaveZ'
A-MovEspDispEax $a 0x24
A-MovEaxSi $a 'aztSaveDirX'
A-MovDiEax32 $a $g_dirX
A-MovEaxSi $a 'aztSaveDirZ'
A-MovDiEax32 $a $g_dirZ
# n = normalise(flatten(wall vector)).  eax is scratch across the call.
A-MovEaxDi $a ([uint32]0x162DD4)
A-MovSiEax32 $a 'aztWallN'
A-MovEaxDi $a ([uint32]0x162DDC)
A-MovSiEax32 $a 'aztWallNZ'
A-MovDwordSiImm $a 'aztWallNY' 0
A-LeaEaxSi $a 'aztWallN'
A-Call $a ([uint32]0x441A8)
# d = v . n, left on st0.  The x87 stack is empty here: every one of the four
# call sites ends fsubp / fldz / fcompp, which nets back to zero.
A-FldSi $a 'aztSaveDirX'
A-FmulSi $a 'aztWallN'
A-FldSi $a 'aztSaveDirZ'
A-FmulSi $a 'aztWallNZ'
A-FaddpSt1 $a                             # st0 = d
A-CmpWordSiImm $a 'aztSlideDone' 0
A-Jnz $a 'AWS_alongN'
# attempt 1 -- n is the normal: v' = v - n*d
A-FldSt0 $a
A-FmulSi $a 'aztWallN'                    # st0 = d*n.X
A-FsubrSi $a 'aztSaveDirX'                # st0 = dirX - d*n.X
A-FstpDi $a $g_dirX
A-FmulSi $a 'aztWallNZ'                   # st0 = d*n.Z
A-FsubrSi $a 'aztSaveDirZ'                # st0 = dirZ - d*n.Z
A-FstpDi $a $g_dirZ
A-Jmp $a 'AWS_retry'
# attempt 2 -- n is the tangent: v' = n*d
Add-Label $a 'AWS_alongN'
A-FldSt0 $a
A-FmulSi $a 'aztWallN'
A-FstpDi $a $g_dirX
A-FmulSi $a 'aztWallNZ'
A-FstpDi $a $g_dirZ
Add-Label $a 'AWS_retry'
A-IncWordSi $a 'aztSlideDone'
A-MovEaxSi $a 'aztRetry'                  # load before esi is popped
A-PopEdi $a; A-PopEsi $a; A-PopEdx $a
A-AddEspImm $a 4                          # discard the saved eax; we return through it
A-JmpEax $a                               # redo the step with the slid vector
Add-Label $a 'AWS_abandon'
A-PopEdi $a; A-PopEsi $a; A-PopEdx $a; A-PopEax $a
A-Jmp $a ([uint32]0x1DE08)                # the original abandon

# ---------------------------------------------------------------------------
# AztKeyUpHook -- replaces `call KeyUpHandler`. Remap only; no other behaviour.
# ---------------------------------------------------------------------------
Add-Label $a 'AztKeyUpHook'
A-PushEdx $a; A-PushEsi $a; A-PushEdi $a
A-PushEax $a
A-Call $a 'AztDeltas'
A-PopEax $a
A-CmpWordSiImm $a 'aztEnabled' 0
A-Jz $a 'AKU_pass'
A-CmpWordSiImm $a $TYPING_KEYS_AT 0   # don't eat W/A/S/D while keys are text (a save name; the picture view)
A-Jnz $a 'AKU_pass'
A-MovDxEaxDisp $a 7
A-CmpDxImm $a 0x11; A-Jz $a 'AKU_w'
A-CmpDxImm $a 0x1F; A-Jz $a 'AKU_s'
A-CmpDxImm $a 0x1E; A-Jz $a 'AKU_ad'
A-CmpDxImm $a 0x20; A-Jz $a 'AKU_ad'
A-Jmp $a 'AKU_pass'

# Releasing one movement key must not stop you if another is still held, so the
# release is swallowed in that case and the game's forward flag stays set.
Add-Label $a 'AKU_w'
A-MovWordSiImm $a 'aztFwdHeld' 0
A-CmpWordSiImm $a 'aztStrafeDir' 0
A-Jnz $a 'AKU_swallow'
A-MovByteEaxDispImm $a 6 0; A-MovWordEaxDispImm $a 7 0x48
A-Jmp $a 'AKU_pass'

Add-Label $a 'AKU_s'
A-MovByteEaxDispImm $a 6 0; A-MovWordEaxDispImm $a 7 0x50
A-Jmp $a 'AKU_pass'

Add-Label $a 'AKU_ad'
A-MovWordSiImm $a 'aztStrafeDir' 0
A-CmpWordSiImm $a 'aztFwdHeld' 0
A-Jnz $a 'AKU_swallow'
A-MovByteEaxDispImm $a 6 0; A-MovWordEaxDispImm $a 7 0x48
A-Jmp $a 'AKU_pass'

Add-Label $a 'AKU_swallow'
A-PopEdi $a; A-PopEsi $a; A-PopEdx $a
A-Ret $a

Add-Label $a 'AKU_pass'
A-PopEdi $a; A-PopEsi $a; A-PopEdx $a
A-Jmp $a $KeyUpHandler

# ---------------------------------------------------------------------------
# AztKeyHook -- replaces `call KeyHandler`. eax = event struct.
# WASD remap, then F2 master toggle / F3 look-cursor. Everything else passes
# through untouched.
# ---------------------------------------------------------------------------
Add-Label $a 'AztKeyHook'
A-PushEdx $a; A-PushEsi $a; A-PushEdi $a
A-PushEax $a                       # event pointer must survive AztDeltas
A-Call $a 'AztDeltas'
A-PopEax $a
A-CmpWordSiImm $a 'aztEnabled' 0
A-Jz $a 'AKH_pass'
A-CmpWordSiImm $a $TYPING_KEYS_AT 0   # keys are text (a save name; the picture view) -- leave W/A/S/D alone
A-Jnz $a 'AKH_fkeys'
# W/S become the stock forward/back arrows. A/D ALSO become forward, but record
# a strafe direction that AztStrafe uses to rotate the movement vector.
A-MovDxEaxDisp $a 7
# THE ARROWS SCROLL THE STORY LOG. They tested first, and that ordering is the
# whole trick: W and S are REWRITTEN into scancodes 0x48/0x50 a few lines below,
# so a code that is still 0x48 or 0x50 at this point can only have come from the
# player pressing a real arrow key. Movement is on WASD now, so the arrows were
# redundant duplicates.
# BYTE compares, not the word in dx. `mov dx, word [eax+7]` spans bytes +7 AND
# +8, which is fine for W/S/A/D because the remap below WRITES a clean word there
# (0x0048), zeroing +8 -- but a real arrow arrives straight from the game with
# whatever it puts in +8, so `cmp dx, 0x48` can miss. The game reads this field a
# byte at a time itself (0x12BB3 is `mov dl, byte [ebx+6]`). Same 4 bytes either
# way, and it reads memory directly so it does not care what dx holds.
A-CmpByteEaxDispImm $a 7 0x48; A-Jz $a 'AKH_scrollUp'
A-CmpByteEaxDispImm $a 7 0x50; A-Jz $a 'AKH_scrollDn'
A-CmpDxImm $a 0x11; A-Jz $a 'AKH_w'
A-CmpDxImm $a 0x1F; A-Jz $a 'AKH_s'
A-CmpDxImm $a 0x1E; A-Jz $a 'AKH_a'
A-CmpDxImm $a 0x20; A-Jz $a 'AKH_d'
A-Jmp $a 'AKH_fkeys'

Add-Label $a 'AKH_w'
A-MovWordSiImm $a 'aztFwdHeld' 1
A-MovByteEaxDispImm $a 6 0; A-MovWordEaxDispImm $a 7 0x48
A-Jmp $a 'AKH_pass'
Add-Label $a 'AKH_s'
A-MovByteEaxDispImm $a 6 0; A-MovWordEaxDispImm $a 7 0x50
A-Jmp $a 'AKH_pass'
Add-Label $a 'AKH_a'
A-MovWordSiImm $a 'aztStrafeDir' 2
A-MovByteEaxDispImm $a 6 0; A-MovWordEaxDispImm $a 7 0x48
A-Jmp $a 'AKH_pass'
Add-Label $a 'AKH_d'
A-MovWordSiImm $a 'aztStrafeDir' 1
A-MovByteEaxDispImm $a 6 0; A-MovWordEaxDispImm $a 7 0x48
A-Jmp $a 'AKH_pass'

# Scrolling. aztLogScroll counts pixels BACK from the newest text, so Up adds and
# Down subtracts. Eight pixels a step, about a line, which key repeat turns into a
# usable rate; one pixel a step was unusably slow.
#
# ONLY THE BOTTOM END IS CLAMPED HERE. The top depends on the box's height, which
# this code has no business knowing, so AztBoxWindow clamps it and writes the
# clamped value back -- one frame later at worst, and the value can never run away
# far enough to matter. Zero, on the other hand, is zero in either state.
#
# A-SubWordSiImm with 0xF8 is "subtract -8", i.e. add 8: the same instruction as
# the decrement, and no separate add helper.
Add-Label $a 'AKH_scrollUp'
A-SubWordSiImm $a 'aztLogScroll' 0xF8    # -(-8) = +8, further back
A-Jmp $a 'AKH_swallow'

Add-Label $a 'AKH_scrollDn'
A-CmpWordSiImm $a 'aztLogScroll' $LOG_SCROLL_STEP
A-Jb  $a 'AKH_swallow'                   # already at the newest text
A-SubWordSiImm $a 'aztLogScroll' $LOG_SCROLL_STEP
# falls through into the swallow -- saves the five bytes a jump would cost

# The arrows must NOT reach the game: stock they are forward/back, and a scroll
# that also walked the player would be worse than no scroll at all. Same epilogue
# as AKH_pass but returning instead of tail-calling the real handler.
Add-Label $a 'AKH_swallow'
A-PopEdi $a; A-PopEsi $a; A-PopEdx $a
A-Ret $a

Add-Label $a 'AKH_fkeys'
A-CmpByteEaxDispImm $a 6 0         # function keys arrive with ascii 0
A-Jnz $a 'AKH_pass'
A-MovDxEaxDisp $a 7
# SHORT BRANCHES THROUGHOUT. Every target here is inside the same ~120-byte
# handler, and the rel32 forms cost 4 extra bytes each -- enough that adding F4
# overflowed the stub cave. The assembler throws if one ever grows out of rel8
# range, so this cannot go wrong silently.
A-CmpDxImm $a 0x3C                 # F2
A-JzS $a 'AKH_f2'
A-CmpDxImm $a 0x3D                 # F3
A-JzS $a 'AKH_f3'
A-CmpDxImm $a 0x3E                 # F4
A-JzS $a 'AKH_f4'
A-JmpS $a 'AKH_pass'

# F2 NO LONGER TURNS THE MOD OFF (Josh, 2026-10-15: "a setting assigned to f2 that seems to disable mouse look. Can we remove
# that setting?"). It was the master switch (aztEnabled) -- pressed by accident it took mouse look and the rest away. The key
# is still taken here and does nothing (passed on, it would reach the game's own scancode dispatch, which F2 never reached
# since the mod began); aztEnabled stays 1.
Add-Label $a 'AKH_f2'
A-JmpS $a 'AKH_apply'

Add-Label $a 'AKH_f3'
A-XorEdxEdx $a
A-CmpWordSiImm $a 'aztWantCursor' 0
A-JnzS $a 'AKH_f3s'
A-IncDx $a
Add-Label $a 'AKH_f3s'
A-MovSiDx $a 'aztWantCursor'
A-JmpS $a 'AKH_apply'

# F4: swap between the recorded soundtrack and the original MIDI score. Only the
# flag moves here -- the overlay notices the change on its next frame poll and does
# the work, because stopping CD audio and handing the sequencer its volume back
# both need the obj2 delta and the real-mode buffer, neither of which this blob has.
Add-Label $a 'AKH_f4'
A-XorEdxEdx $a
A-CmpWordSiImm $a 'aztCdOn' 0
A-JnzS $a 'AKH_f4s'
A-IncDx $a
Add-Label $a 'AKH_f4s'
A-MovSiDx $a 'aztCdOn'

Add-Label $a 'AKH_apply'
A-PopEdi $a; A-PopEsi $a; A-PopEdx $a
A-Jmp $a 'AztFrameHook'            # apply now, then return to caller

Add-Label $a 'AKH_pass'
A-PopEdi $a; A-PopEsi $a; A-PopEdx $a
A-Jmp $a $KeyHandler

# ---- clear the log box before drawing into it ------------------------------
# The log used to draw into the 3D VIEW surface, which the renderer repaints in
# full every frame, so it never needed to clear up after itself. The panel box
# is not repainted, so once the log moved there every frame drew on top of the
# last and the text stacked into an unreadable pile.
#
# The scan display already does this correctly -- 0x11ECC is `mov eax,0x152AD4 /
# call 0x37FC8`, i.e. clear the surface first -- so these two shims just do the
# same thing on the way into each text draw. They are entered by retargeting the
# CALL at each draw site (a relative operand, so no fixup in the way, unlike the
# destination itself) and leave by JMP, which keeps the caller's stack frame
# exactly as the real routine expects.
#
# Which register holds the surface differs between the two paths, hence two
# shims rather than one: the plain text draw has it in EBX, the conversation
# list in ECX.
if ($ENABLE_LOG_IN_PANEL) {
    # The Bx shim also applies the scroll offset, because this is the only place
    # that sees the draw call with its argument still on the stack.
    #
    # 0x37D98 takes the block's Y as a PUSHED dword and -- crucially -- CLAMPS a
    # positive one to zero at 0x37DF1 (`cmp word [esp+0x28],0 / jle / xor`). A
    # NEGATIVE Y is not a screen position at all: 0x37E2F subtracts it from the
    # text object's source origin, i.e. it is a scroll offset into the accumulated
    # text. The clip rect is built BEFORE that clamp, so the box itself does not
    # move. That is what makes scrolling two instructions instead of a rewrite.
    #
    # The log text really is an ever-growing buffer -- HudPrint (0x39080) reallocs
    # [obj+8] to strlen+6 on every line and appends -- so there is genuine
    # scrollback behind the window, not just the eight lines on show.
    #
    # Stack at entry: [esp]=return, [esp+4]=the pushed Y. pushad puts 0x20 bytes
    # under that, hence [esp+0x24].
    Add-Label $a 'AztLogClearBx'
    A-Db  $a @(0x60)              # pushad
    A-Db  $a @(0x93)              # xchg eax,ebx  -> eax = the destination surface
    A-Call $a $SURF_CLEAR
    # eax = the scroll offset that actually applies. With the expanding box that
    # is not simply aztLogScroll -- an expanded box shows the whole surface, so
    # its offset is zero -- and doing the test out in the box blob rather than
    # here also gives the first cave seven bytes back.
    if ($ENABLE_LOG_BOX_TOGGLE) { A-Call $a $BOX_SCROLL }
    else {
        A-Call $a 'AztDeltas'     # esi = obj1 delta (clobbers eax/esi/edi, all saved)
        A-MovzxEaxSi $a 'aztLogScroll'
    }
    A-Db  $a @(0x29,0x44,0x24,0x24)   # sub dword [esp+0x24], eax
    A-Db  $a @(0x61)              # popad
    A-Jmp $a $TEXT_DRAW_PLAIN

    Add-Label $a 'AztLogClearCx'
    A-Db  $a @(0x60)              # pushad
    A-Db  $a @(0x89,0xC8)         # mov eax,ecx
    A-Call $a $SURF_CLEAR
    # The conversation path needs the recess sized and its background laid in
    # just as the narration path does -- it simply has no scroll offset to apply,
    # so the return value goes unused. Without this the list drew onto whatever
    # extent the last blit happened to leave set, over a cleared (black) recess.
    # BISECT SWITCH. The freeze under test appeared after this shim started
    # calling into the box blob, and the reporter's own account ties it to that
    # change, so it is one flag rather than a source edit. Setting it false gives
    # back the stock two-instruction shim; the cost is that dialogue draws from
    # the top of the text surface again and has to be scrolled to.
    $CONV_USES_BOX = $false
    if ($ENABLE_LOG_BOX_TOGGLE -and $CONV_USES_BOX) {
        A-Call $a $BOX_SCROLL
        # ...AND APPLY IT, which this path never did. Only the narration draw
        # subtracted the offset, so the option list always rendered from row 0 --
        # the OLDEST end of a 316-row surface -- and the dialogue sat below the
        # 196-row window until the player scrolled down to find it.
        #
        # The offset goes in at +0x28, not +0x24 as in AztLogClearBx: this call
        # site pushes TWO arguments (0x14FCA the Y, then 0x14FDA the X), so with
        # pushad's 0x20 on top the Y is the second one up.
        A-Db $a @(0x29,0x44,0x24,0x28)   # sub dword [esp+0x28], eax
    }
    A-Db  $a @(0x61)              # popad
    A-Jmp $a $TEXT_DRAW_LIST
}

# ---- AztGaugeFill: the health gauge's ERASE surface ---------------------------
# Displaces `call 0x40182` at 0x28518 -- the memcpy that fills gauge surface 0x163A22 from
# [ebp-0x10]. That surface is the gauge's background: 0x11E30 draws it every frame and the
# bar (0x34C40, surface 0x163A10) is drawn over the health portion of it, so it is what makes
# the bar SHRINK when damage is taken.
#
# Whatever [ebp-0x10] points at, the result is not the panel behind the gauge -- it is heap
# rubbish. Proven: skipping the bar draw left the speckle and skipping THIS left a bar that
# could never shrink. Stock hid it because the bar covered the erase exactly at 105 columns;
# widening to 130 moved the allocation from 1575 to 1950 bytes, into a block with noisier
# contents, and every pixel the bar did not reach showed it.
#
# So do not copy anything: fill it with the WELL'S OWN FLOOR instead. Index 1 (#12130B),
# measured across HUD3 rows 658..678, is what the recess is painted in, so erasing to it is
# exactly what the pass is supposed to achieve.
#
# eax = destination, ebx = length, edx = the source we are ignoring -- the register contract
# of the memcpy this replaces. THIRTEEN BYTES, which is the whole of the stub cave's
# remaining slack; the build asserts it below.
if ($ENABLE_GAUGE_FILL) {
    Add-Label $a 'AztGaugeFill'
    A-Db $a @(0x60)                  # pushad
    A-PushDsPopEs $a                 # rep stosb needs es = ds
    A-Db $a @(0x89,0xC7)             # mov edi, eax   -- destination
    A-Db $a @(0x89,0xD9)             # mov ecx, ebx   -- byte count
    A-Db $a @(0xB0,0x01)             # mov al, 1      -- the well's floor
    A-Db $a @(0xF3,0xAA)             # rep stosb
    A-Db $a @(0x61)                  # popad
    A-Db $a @(0xC3)                  # ret
}

# ---- AztCdBoot: start the visor boot effect BEFORE the room loads -------------
# Displaces `call 0x11688` at 0x16150, the first instruction after the intro sequence
# returns. Ten bytes, and it buys back ~4 seconds.
#
# The effect is a CD track and the drive takes ~4 s between the Play request and audible
# sound. It used to be requested on the boot animation's FIRST FRAME, so the animation had
# to be held back to meet it -- four seconds of sequence playing to silence. Requesting it
# here spends that latency on the room and texture load that follows, which is dead time
# anyway. Measured, not assumed: the delay was confirmed still ~4 s after the track was cut
# from 2.02 MB/44.1 kHz stereo to 617 KB/22 kHz mono, so it is drive latency, not file size.
#
# A LITERAL ADDRESS, NOT A LABEL: this blob is assembled long before the overlay, so the
# overlay's labels do not exist yet -- hence the fixed entry vector at +14. The rel32 is
# still correct at runtime because the stub cave and the overlay are both in obj1 and shift
# by the SAME delta, so the distance between them never changes. (An ABSOLUTE address here
# would be the pointer-to-nowhere that crashed the opening movie.)
#
# No pushad: AztCdBootStart does its own, which keeps this to a call and a tail jump.
# Gated on EARLY_OVERLAY as well: without it the overlay is not resident at 0x16150 and
# this would call into zeroed BSS.
if ($ENABLE_CD_AUDIO -and $ENABLE_BOOT_SEQ -and $ENABLE_EARLY_OVERLAY -and $ENABLE_EARLY_CD_BOOT) {
    Add-Label $a 'AztCdBoot'
    A-Call $a ([uint32]($OVERLAY_BASE + 14))
    A-Jmp  $a ([uint32]0x11688)
}

$asm = Invoke-Asm $a
if ($env:AZT_DUMP_STUB) {
    $ls = @($asm.Labels.GetEnumerator() | Sort-Object Value)
    Write-Host "--- stub layout ---"
    for ($i=0; $i -lt $ls.Count; $i++) {
        $end = if ($i+1 -lt $ls.Count) { $ls[$i+1].Value } else { $asm.End }
        Write-Host ("  {0,-18} 0x{1:X6}  {2,5} bytes" -f $ls[$i].Key, $ls[$i].Value, ($end - $ls[$i].Value))
    }
}
# ---- STRING POOL, at the very top of the stub cave -------------------------
# Data does not need a CODE cave, and pushing a path as immediates spends code bytes
# to store bytes: "opening.mov" cost 15 bytes of `push imm32` plus 2 for `mov eax,esp`
# plus 3 for the `add esp` to unwind it -- 20 bytes of cave 3, the cave that is full, to
# hold 12 bytes of text. A literal address is `mov eax,imm32`, five bytes, and the text
# moves to slack that was being wasted anyway.
#
# IT CANNOT GO IN THE BSS OVERLAY. The overlay is read on the first rendered frame and
# the intro sequence runs before that, so at AztOpenMovie time 0x133000 is still zeroed.
# Anything the intro touches has to be file-backed.
#
# NOR IN obj2's ZERO RUNS. There are 26,837 bytes of them, but zero-filled data in a data
# object is zero-INITIALISED, not unused: the big ones sit on a regular ~0x800 stride, an
# array of runtime buffers. Our bytes would be overwritten, or worse, read as a buffer.
#
# So: the top of the stub cave, growing DOWN from the limit while the stub grows up, with
# the assertion below catching the day they meet.
$stringPool = New-Object System.Collections.ArrayList
$poolTop    = $CAVE_LIMIT
function Add-PooledString {
    param([string]$text)
    $bytes = [byte[]]([System.Text.Encoding]::ASCII.GetBytes($text) + 0)
    $script:poolTop = [uint32]($script:poolTop - $bytes.Length)
    [void]$script:stringPool.Add([pscustomobject]@{ Addr = $script:poolTop; Bytes = $bytes; Text = $text })
    return $script:poolTop
}
# NOTHING IS POOLED YET, AND THE MOVIE NAME MUST NOT BE until the overlay moves.
#
# A pooled string is only reachable from code that can add the obj1 delta to it, because obj1
# is not loaded where it was built -- see AztDeltas. AztOpenMovie runs from the intro sequence
# with the game's own esi, pooling "opening.mov" here and loading it with `mov eax,imm32`
# handed the movie player a pointer to nowhere AND CRASHED THE GAME at that movie.
#
# The mechanism is correct and stays, for callers that HAVE the delta -- i.e. anything in the
# BSS overlay, and anything in a cave with room for the 12-byte call/pop/sub to derive it.
# Address a pooled string as `lea eax,[esi + addr]`, never as an absolute.

if ($asm.End -gt $poolTop) {
    throw ("stub cave exhausted: code ends 0x{0:X} but the string pool starts 0x{1:X}" -f $asm.End, $poolTop)
}
Write-Host ("stub: {0} bytes, 0x{1:X}..0x{2:X} ({3} bytes spare in cave, {4} of them held by {5} pooled string(s))" -f `
    $asm.Bytes.Length, $asm.Base, $asm.End, ($CAVE_LIMIT - $asm.End), ($CAVE_LIMIT - $poolTop), $stringPool.Count)
foreach ($s in $stringPool) {
    Write-Host ("  string 0x{0:X6}  {1,3} bytes  '{2}'" -f $s.Addr, $s.Bytes.Length, $s.Text)
}

# ===========================================================================
#  Patch list
# ===========================================================================
$raw = [System.IO.File]::ReadAllBytes($GameExe)
function Hex([byte[]]$b) { ($b | ForEach-Object { '{0:X2}' -f $_ }) -join '' }

function New-Patch {
    param([string]$Name, [int]$FileOffset, [byte[]]$Expect, [byte[]]$Replace, [string]$Note)
    $actual = $raw[$FileOffset..($FileOffset + $Expect.Length - 1)]
    if ((Hex $actual) -ne (Hex $Expect)) {
        throw ("{0}: expected {1} at file 0x{2:X} but found {3}" -f $Name, (Hex $Expect), $FileOffset, (Hex $actual))
    }
    if ($Replace.Length -ne $Expect.Length) { throw ("{0}: length mismatch" -f $Name) }
    [ordered]@{ name=$Name; note=$Note; offset=$FileOffset; expect=(Hex $Expect); replace=(Hex $Replace) }
}
function CallRel32([uint32]$from, [uint32]$to) {
    $rel = [int64]$to - ([int64]$from + 5)
    $u = [uint32]($rel -band [int64]4294967295)
    return ,([byte[]]@(0xE8, ($u -band 0xFF), (($u -shr 8) -band 0xFF), (($u -shr 16) -band 0xFF), (($u -shr 24) -band 0xFF)))
}
function JmpRel32([uint32]$from, [uint32]$to) {
    $rel = [int64]$to - ([int64]$from + 5)
    $u = [uint32]($rel -band [int64]4294967295)
    return ,([byte[]]@(0xE9, ($u -band 0xFF), (($u -shr 8) -band 0xFF), (($u -shr 16) -band 0xFF), (($u -shr 24) -band 0xFF)))
}

$patches = @()

# THE DEFAULT VOLUMES (Josh, 2026-10-10: "set the default volume at 50% for music and 100% for sound"). The levels are
# int16 words in obj2's file-backed data, 0..127 (docs\system-menu-RE.md s2.1): SFX 0x14693E, music 0x146940, both 100
# stock. Nothing saves them with a game, so these are what every session starts at: music 64 (half), effects 127 (full).
# (Josh, 2026-10-13: "Set the music volume to 30 by default, sound at 100 as it is now": the menu shows level x 100 / 127,
# so 38 reads 30%)
$VOL_SFX_DEFAULT = 127; $VOL_MUSIC_DEFAULT = 38
$patches += New-Patch -Name 'volume-defaults-14693E' -FileOffset ($DATA_PAGES + 291 * 4096 + (0x14693E - 0x140000)) `
    -Expect ([byte[]]@(100, 0, 100, 0)) -Replace ([byte[]]@($VOL_SFX_DEFAULT, 0, $VOL_MUSIC_DEFAULT, 0)) `
    -Note ("default volumes: effects {0}/127, music {1}/127" -f $VOL_SFX_DEFAULT, $VOL_MUSIC_DEFAULT)

# The stock size is 0x122973, obj1's 291 file-backed pages actually cover to
# 0x133000, and obj2 does not start until 0x140000. Two different things live in
# that headroom:
#
#   0x132973..0x133000   FILE-BACKED slack in obj1's last page -- the stub cave.
#                        Patchable, because there are real bytes on disk behind
#                        it. This is the only kind of cave the patcher can write.
#   0x133000..0x140000   BEYOND the last page: 53 KB the loader ZERO-FILLS on
#                        demand simply because the object says it is that big.
#                        Not patchable (no file offset), but writable at runtime.
#
# Every file-backed cave in this build is within a few bytes of full and there is no
# unreferenced padding anywhere in obj1, so the only way to add code is to put it in
# that BSS at runtime -- see AztOverlay.
#
# THE WINDOW IS NO LONGER CAPPED AT obj2's LINKED BASE (Josh, 2026-10-11: "If there is a
# ceiling, lets raise it a logical amount ... users will be fine with a larger download").
# It was 0x130000 (window 0x133000..0x140000 = 52 KB, full to 2 bytes). DOS/4GW does not
# load the objects at their linked bases: obj1 runs at 0x200000 (delta 0x1F0000) and obj2
# one page past obj1's END (0x331000 = 0x200000 + 0x130000 + 0x1000, delta 0x1F1000) --
# two separate placements, not one block keeping the linked layout (that would give both
# the same delta). Growing obj1 therefore moves obj2 UP by the same amount, and the linked
# ranges overlapping is nothing the loader looks at: every absolute reference in the
# image is a fixup against (object, offset).
#   * obj2's delta becomes vsize + 0xC1000 (0x224000 at 0x163000). Guest code takes it
#     from AztDeltas (a loader-resolved pointer), never from obj1's delta -- the one place
#     that added 0x1000 to esi (AztScenePart2's refresh) now calls AztDeltas.
#   * The host derives it at attach time from string needles, trying this layout's value
#     and the old 0x1F1000 (GuestBase.ps1, LoadingScreen.cs GameGate), and logs which.
#   * tools\LeTool.cs prefers the LATER object where linked ranges overlap, so loading a
#     patched R.EXE (Test-Patch) still reads obj2's data at 0x140000+.
# 0x163000 = a 256 KB window (0x133000..0x173000), five times the old one; the guest
# loses 204 KB of heap to it, against 32 MB.
$OBJ1_VSIZE = 0x163000
if ($OBJ1_VSIZE % 0x1000) { throw ("obj1 vsize 0x{0:X} must be whole pages (obj2 lands a page past its end)" -f $OBJ1_VSIZE) }
if ($OBJ1_VSIZE -gt 0x200000) { throw ("obj1 vsize 0x{0:X}: raise it deliberately -- every MB comes out of the game's heap" -f $OBJ1_VSIZE) }
$OBJ2_DELTA_EXPECTED = [uint32]($OBJ1_VSIZE + 0xC1000)     # (obj1 runs at 0x200000; obj2 a page past its end, linked at 0x140000)
# AztOverlayLoad reads $OVERLAY_READ bytes straight into $OVERLAY_BASE, so that read must
# fit the BSS window. Checked HERE because $OBJ1_VSIZE, which defines the window's top, is
# only known this far down -- the limit itself has to be declared much earlier.
$OVERLAY_WINDOW = [uint32]($OBJ1_BASE + $OBJ1_VSIZE - $OVERLAY_BASE)
if ($OVERLAY_READ -gt $OVERLAY_WINDOW) {
    throw ("OVERLAY_READ 0x{0:X} would read past the BSS window (0x{1:X} bytes at 0x{2:X})" -f `
           $OVERLAY_READ, $OVERLAY_WINDOW, $OVERLAY_BASE)
}
$patches += New-Patch -Name 'obj1-vsize' -FileOffset $OBJ1_VSIZE_OFF `
    -Expect ([byte[]]@(0x73,0x29,0x12,0x00)) `
    -Replace ([byte[]][BitConverter]::GetBytes([uint32]$OBJ1_VSIZE)) `
    -Note ("obj1 virtual size 0x122973 -> 0x{0:X}: the stub cave, plus {1:N0} bytes of zero-filled BSS at 0x{2:X} for the overlay" -f `
           $OBJ1_VSIZE, ($OBJ1_BASE + $OBJ1_VSIZE - 0x133000), 0x133000)

$patches += New-Patch -Name 'obj1-flags' -FileOffset $OBJ1_FLAGS_OFF `
    -Expect ([byte[]]@(0x45,0x20,0x00,0x00)) -Replace ([byte[]]@(0x47,0x20,0x00,0x00)) `
    -Note 'obj1 flags 0x2045 -> 0x2047 (add WRITE for the mod settings block)'

$patches += New-Patch -Name 'stub' -FileOffset (Lin2File $CAVE_BASE) `
    -Expect ([byte[]](, 0 * $asm.Bytes.Length)) -Replace $asm.Bytes `
    -Note ("AztMod stub at linear 0x{0:X}" -f $CAVE_BASE)

# The pooled strings, one patch each at the top of the same cave. Separate patches rather
# than one blob so Assert-NoOverlap sees each string's own bytes and the manifest names them.
foreach ($s in $stringPool) {
    $patches += New-Patch -Name ("string-{0:X}" -f $s.Addr) -FileOffset (Lin2File $s.Addr) `
        -Expect ([byte[]](, 0 * $s.Bytes.Length)) -Replace $s.Bytes `
        -Note ("pooled string '{0}' at linear 0x{1:X}" -f $s.Text, $s.Addr)
}


# ===========================================================================
#  LINEAR FRAMEBUFFER  ($ENABLE_LFB)
# ===========================================================================
# The video layer is VBE 1.2 BANKED: it writes through a 64 KB window at
# 0xA0000 and hand-unrolls exactly four bank boundaries, which is why 640x480
# (4.69 windows) is the ceiling and 800x600 (7.32) is not.
#
# This replaces the banking with a VESA 2.0 linear framebuffer. Verified by
# querying the BIOS under a matching DOSBox conf: ModeAttributes = 0x009B (bit 7
# set = LFB available) and PhysBasePtr = 0xC0000000.
#
# THE SPIKE RUNS AT 640x480 AND CHANGES NOTHING VISIBLE. If it works the picture
# is identical; the point is that it removes the bank ceiling, so resolution
# afterwards becomes a question of constants and art rather than of blitters.
#
# Three things make this a patch rather than a rewrite:
#
#  1. The copy is `rep movsw` and its per-scanline advance is ALREADY 32-bit
#     (`add edi,ebx` / `add esi,[ebp-4]`), so the loop is linear-safe untouched.
#     Only the INITIAL offset is 16-bit -- 3 identical `mul dx` + `add ax,cx`
#     pairs. `mul edx` / `add eax,ecx` are SHORTER encodings, and edx/ecx are
#     already zero-extended by the preceding `movzx`. edx is dead across the
#     multiply on both successor paths (reloaded at 0x50F3B and 0x510D9), so
#     widening it is safe.
#  2. The window base is computed in 8 byte-identical 7-byte sequences
#     (`movzx edi,word [ebp+d]; shl edi,4` -- segment<<4 = 0xA0000, which is why
#     no 0xA0000 immediate exists anywhere). `mov edi,imm32` is 5 bytes, so each
#     is replaced in place with two NOPs to spare.
#  3. The init needed ~60 bytes and the cave had 24 -- but 0x33EB8, the routine
#     that precomputes the four bank boundaries, is 198 bytes with a SINGLE
#     caller (0x33A73) and becomes entirely dead here. We overwrite it in place
#     with our own init, which the game then calls at exactly the right moment.
#
# The immediates start life as 0xA0000. AztLfbInit overwrites them once, at
# startup, with the mapped linear base. Self-modifying, but only an immediate
# and only before the blitters have run; obj1 already carries WRITE (obj1-flags).
# If the DPMI mapping fails they stay 0xA0000 and you get a visibly wrong screen
# rather than a wild pointer.
# ORed into the mode number at the single 4F02h site that owns it. Zero unless the
# LFB is enabled, so the expression below reads the same either way.
$LFB_MODE_BIT = [uint32]0

if ($ENABLE_LFB) {
    # PhysBasePtr for mode 0x101, read out of the BIOS with a DEBUG.COM script
    # under a DOSBox conf matching the game's. Also confirmed ModeAttributes
    # 0x009B -- bit 7 set, so the mode really does offer a linear framebuffer.
    # NOTE the L: PowerShell reads a bare 0xC0000000 as a NEGATIVE Int32 and the
    # cast to uint32 then throws.
    $LFB_BASE  = [uint32]0xC0000000L
    $LFB_MUL   = @(0x50F17,0x5118E,0x5142C)     # `mul dx` + `add ax,cx`

    # ---- v0.16.0 ran, and showed the shortcut was wrong ---------------------
    #
    # ---- use the game's OWN no-crossing path ---------------------------------
    #
    # Two earlier attempts fought the bank logic. Both were unnecessary: each
    # blitter already contains a LINEAR fast path for rects that do not straddle
    # a window boundary, and it is exactly what a framebuffer wants -- rows from
    # [ebp+rows], no boundary table, no stack juggling, no `int 10h`, and per-row
    # advances that were already 32-bit (`add edi,ebx`).
    #
    # It is selected by `cmp word [ebp+flag],0 / jz short / jmp <crossing>`. Make
    # that jump unconditional and every blit takes Mindscape's own tested code.
    #
    # What failed before, recorded so it is not retried:
    #   * Reporting the window as 1 MB does NOT stop splitting. When the boundary
    #     lies beyond the rect, 0x50F5B's `rowsLeft -= rowsUntilBoundary; jg` goes
    #     negative and falls into 0x50F60, which does `dec word [ebp-0x6]` (bank
    #     index to -1) and walks the boundary table BACKWARDS. Stock never reaches
    #     that path because a 64 KB window always splits a 480-row screen.
    #   * Hand-writing "copy all remaining rows" over the split decision assembled
    #     and balanced correctly but still rendered wrong -- because the crossing
    #     machinery has more state than that one decision.
    #
    # PROVEN, not assumed: a sweep of every decoded branch shows each crossing
    # region has exactly ONE entry from outside, and it is the `jmp` inside the
    # test being replaced here. So all 13 remaining `shl <r>,4` window-base
    # computations, all 9 `int 10h` bank switches and the whole boundary walk
    # become unreachable.
    # The BLITTER now ignores banks -- but the C-level dispatcher that calls it
    # (0x34109 onward) still works out which bank a rect starts in and passes
    # BANK-RELATIVE coordinates. With a linear framebuffer those land short by
    # the bank origin, and because the origin changes as you cross rows 102 / 204
    # / 307 / 409 the cursor appears to jump around the screen rather than being
    # displaced by a constant. Hovering the panel (y 391..479) spans two banks,
    # which is why the pointer could never be put on the UI.
    #
    # So force the dispatcher to see one bank as well. The boundaries come from
    # dividing the window size by the stride at 0x33EBB, and the window size is
    # computed once at 0x33D21 as `WinSize_KB << 10`; shifting by 14 instead
    # reports 1 MB and puts all four boundaries at rows 1638..6553.
    #
    # This is the same one-byte patch that FAILED on its own in the first
    # attempt, and it is safe now for a specific reason: its failure was that the
    # blitter's boundary SEARCH walked backwards off the table when a boundary
    # lay beyond the rect (0x50F5B -> 0x50F60). That search is no longer reached
    # at all -- lfb-linear-* jumps straight past it. The two patches are only
    # correct together.
    #
    # THE SHIFT IS RESOLUTION-DEPENDENT, and hard-coding 0x0E silently broke 1280.
    #
    # The boundary the dispatcher computes is `windowSize / stride`, and the stride
    # is $SCREEN_W. A fixed 1 MB therefore moves as the screen widens:
    #
    #     640 wide -> row 1638      1024 wide -> row 1024      1280 wide -> row 819
    #
    # 819 is INSIDE a 1024-row screen, so every rect starting at or below it was
    # handed bank-relative coordinates against a linear framebuffer: the whole
    # panel band (top 846), the log box, the automap, the scan readout, the gauge
    # and the buttons all drew near the top of the screen instead, leaving the
    # panel's wells showing the flat fills Build-HudButtons puts in them. The
    # full-screen HUD repaint survived because it STARTS at row 0, which is how the
    # panel could look present but mis-coloured.
    #
    # So derive the shift instead: the smallest one whose window covers the entire
    # framebuffer, which puts the first boundary at or past the last row.
    $VESA_WIN_KB = 64                                # what DOSBox reports for these modes
    $FB_BYTES    = [int64]$SCREEN_W * $SCREEN_H
    $winShift    = 10
    while ((([int64]$VESA_WIN_KB) -shl $winShift) -lt $FB_BYTES -and $winShift -lt 20) { $winShift++ }
    $winBytes = ([int64]$VESA_WIN_KB) -shl $winShift
    if ($winBytes -lt $FB_BYTES) {
        throw "cannot report a VESA window big enough for ${SCREEN_W}x${SCREEN_H} ($FB_BYTES bytes) -- the bank dispatcher would split the panel band"
    }
    $bankRow = [int][Math]::Floor($winBytes / $SCREEN_W)
    if ($bankRow -lt $SCREEN_H) { throw "bank boundary at row $bankRow is inside a $SCREEN_H-row screen" }
    Write-Host ("lfb one-bank: window reported as {0:N0} KB (shl {1}), first bank boundary at row {2} of {3}" -f `
        ($winBytes / 1024), $winShift, $bankRow, $SCREEN_H)
    $winShiftOff = (Lin2File ([uint32]0x33D23))      # imm8 of `shl edx, 0x0A`
    $patches += New-Patch -Name 'lfb-one-bank' -FileOffset $winShiftOff `
        -Expect ([byte[]]@(0x0A)) -Replace ([byte[]]@([byte]$winShift)) `
        -Note ("window reported as {0:N0} KB, so the dispatcher puts every rect in bank 0 (first boundary row {1}, screen {2}) and passes absolute coordinates" -f `
               ($winBytes / 1024), $bankRow, $SCREEN_H)

    foreach ($t in @(@{ at=0x50F1F; linear=0x510D0; flag=0x38; fn='0x50EA5' },
                     @{ at=0x51196; linear=0x51372; flag=0x3C; fn='0x5111C' },
                     @{ at=0x51434; linear=0x515E3; flag=0x40; fn='0x513BF' })) {
        $o   = Lin2File ([uint32]$t.at)
        $exp = $raw[$o..($o+8)]                       # cmp(5) + jz(2) + jmp(2)
        if ($exp[0] -ne 0x66 -or $exp[1] -ne 0x83 -or $exp[2] -ne 0x7D -or
            $exp[3] -ne [byte]$t.flag -or $exp[4] -ne 0x00 -or $exp[5] -ne 0x74) {
            throw ("LFB crossing test 0x{0:X} is not 'cmp word [ebp+0x{1:X}],0; jz'" -f $t.at, $t.flag)
        }
        $rel = [int]$t.linear - ([int]$t.at + 5)
        $rep = [byte[]]@(0xE9) + [BitConverter]::GetBytes([int]$rel) + @(0x90,0x90,0x90,0x90)
        $patches += New-Patch -Name ("lfb-linear-{0:X}" -f $t.at) -FileOffset $o `
            -Expect $exp -Replace $rep `
            -Note ("blitter {0}: always take the existing no-crossing path at 0x{1:X}" -f $t.fn, $t.linear)
    }

    # Ask for the mode WITH the linear-framebuffer bit (bit 14). Only the 4F02h
    # site takes it; the 4F01h mode-info sites must keep the plain mode number.
    #
    # THIS SITE IS NOT PATCHED HERE. 0x33ABB is the same dword the hires block
    # rewrites as `vesa-mode-33ABB`, and for a long time BOTH patches were emitted
    # against it: this one turning 0x101 into 0x4101, that one turning 0x101 into
    # 0x105. They expect the same original bytes and write the same four bytes, so
    # whichever came second silently won -- and it was the hires one, which meant
    # the LFB bit was never actually requested in any hires build. The shipped
    # R.EXE read `05 01 00 00`, plain banked mode 0x105. It worked only by
    # accident: `lfb-one-bank` widens the reported window until the whole
    # framebuffer fits in bank 0, so the blitter's linear writes land correctly
    # whether or not the mode was set with bit 14.
    #
    # So the bit travels as a VALUE instead, and the ONE patch that owns this site
    # ORs it in. Two patches can no longer disagree about the same bytes, and
    # Assert-NoOverlap (before the manifest is written) now fails the build if any
    # pair of patches touches the same file byte again.
    $LFB_MODE_BIT = [uint32]0x4000

    # The INITIAL destination pointer in each blitter: `movzx <r>,word [ebp+d];
    # shl <r>,4` builds the window base as segment<<4 = 0xA0000. Hand it the
    # linear framebuffer instead. Note 0x513BF uses ESI, not EDI -- it is the
    # read-back path, which is why the mouse cursor picked up a stray image when
    # only the EDI sites were patched.
    #
    # ONLY the initial computations are patched. The other thirteen `shl <r>,4`
    # sites belong to continuation paths that no longer execute; left pointing at
    # 0xA0000 they would scribble on the unused VGA window rather than over the
    # picture, which is the safer way to be wrong.
    foreach ($b in @(@{ at=0x50ED9; reg='edi'; modrm=0x7D; op=0xBF; sh=0xE7 },
                     @{ at=0x51150; reg='edi'; modrm=0x7D; op=0xBF; sh=0xE7 },
                     @{ at=0x513F3; reg='esi'; modrm=0x75; op=0xBE; sh=0xE6 })) {
        $o = Lin2File ([uint32]$b.at)
        $exp = $raw[$o..($o+6)]
        if ($exp[0] -ne 0x0F -or $exp[1] -ne 0xB7 -or $exp[2] -ne $b.modrm -or
            $exp[4] -ne 0xC1 -or $exp[5] -ne $b.sh -or $exp[6] -ne 0x04) {
            throw ("LFB base site 0x{0:X} is not 'movzx {1},word [ebp+d]; shl {1},4'" -f $b.at, $b.reg)
        }
        $rep = [byte[]]@($b.op) + [BitConverter]::GetBytes([uint32]$LFB_BASE) + @(0x90,0x90)
        $patches += New-Patch -Name ("lfb-base-{0:X}" -f $b.at) -FileOffset $o `
            -Expect $exp -Replace $rep `
            -Note ('{0} base: segment<<4 (0xA0000) -> linear framebuffer 0x{1:X}' -f $b.reg, $LFB_BASE)
    }

    # 3 x `mul dx` + `add ax,cx`  ->  `mul edx` + `add eax,ecx` + 2 NOPs.
    # This is the only 16-bit address arithmetic in the blit; everything else
    # was already 32-bit because it only ever stepped by a stride.
    foreach ($s in $LFB_MUL) {
        $o = Lin2File ([uint32]$s)
        $exp = $raw[$o..($o+5)]
        $want = [byte[]]@(0x66,0xF7,0xE2,0x66,0x03,0xC1)
        for ($k = 0; $k -lt 6; $k++) {
            if ($exp[$k] -ne $want[$k]) { throw ("LFB mul site 0x{0:X} is not 'mul dx; add ax,cx'" -f $s) }
        }
        $patches += New-Patch -Name ("lfb-offset-{0:X}" -f $s) -FileOffset $o `
            -Expect $exp -Replace ([byte[]]@(0xF7,0xE2,0x03,0xC1,0x90,0x90)) `
            -Note 'framebuffer offset widened to 32-bit (was window-relative, so 16-bit sufficed)'
    }
}

# ===========================================================================
#  AztActorTime -- advance actors on the CLOCK, not on frames
# ===========================================================================
# See $ACTOR_PERIOD above for why. Lives in the bank-crossing code that the
# linear framebuffer made unreachable: 0x50F2D..0x510CF, 419 bytes with ZERO
# fixups (unlike 0x33EB8, which had 21 in 198 bytes and ate an earlier attempt).
if ($ENABLE_ACTOR_TIME) {
    $t = New-Asm -Base $ACTOR_TIME_AT

    # ---- AztFrameLimit -- MUST BE FIRST, it is called by literal address -----
    # Spin until a whole frame period has passed. A spin is right inside an
    # emulator: the surplus cycles have to go somewhere, and burning them is
    # precisely what caps the loop.
    #
    # aztLastFrame is set to NOW rather than advanced by one period, so a frame
    # that overruns simply does not wait -- no debt accumulates and no catch-up
    # burst follows a loading screen. Subtraction is unsigned, so the timer
    # wrapping (~60 min) costs one unthrottled frame and nothing worse.
    #
    # CALLED FROM AztFrameHook, not from the actor hook. The actor call at
    # 0x13DF0 is guarded by `cmp word [0x1525F2],0 / jnz` -- a "hold the actors"
    # flag that is SET in the opening room and cleared by a room load. Hanging
    # the limiter off it meant the first room ran uncapped until you walked out
    # and back, which is exactly the bug it was supposed to fix.
    Add-Label $t 'AztFrameLimit'
    A-PushEax $t; A-PushEbx $t; A-PushEcx $t; A-PushEdx $t; A-PushEsi $t; A-PushEdi $t
    A-Call $t $asm.Labels['AztDeltas']
    Add-Label $t 'AFL_spin'
    A-Call $t 'AztNow'
    A-MovEbxSi $t 'aztLastFrame'
    A-SubEaxEbx $t
    A-CmpEaxSi $t 'aztFramePeriod'
    A-Jb $t 'AFL_spin'
    A-Call $t 'AztNow'
    A-MovSiEax32 $t 'aztLastFrame'

    # ---- has an animation step come due? -- see $ANIM_PERIOD_US -------------
    # Rides on the eax AztNow just returned, so the clock is free. Decided ONCE
    # per frame and read by all six animation sites, because they have to step
    # together or the room drifts out of sync with itself.
    #
    # aztAnimLast ADVANCES BY ONE PERIOD, it is not set to now. Setting it to now
    # is what aztLastFrame does above and it was wrong here: the step can only
    # land on a frame boundary, so discarding the remainder quantises the rate to
    # the frame time and the dial stops meaning what it says. At a 60 fps cap the
    # only reachable rates were 20, 15 and 12 Hz -- the 18.2 Hz default was really
    # delivering 15.0, and the same default at a 40 fps cap delivered 13.3, so
    # RAISING THE CAP SPED ANIMATION UP by 12% even though it is clock-gated.
    # Carrying the remainder makes the average come out at the requested rate
    # whatever the cap is, with at most one frame of jitter either side.
    #
    # The debt that buys has to be bounded, or a loading screen would be followed
    # by a burst of catch-up at frame rate. More than half a second behind is not
    # a slow frame, it is a stall, so snap to now and drop the debt. A room that
    # renders slower than the animation rate simply runs animation at the frame
    # rate -- one step per frame is the ceiling everywhere -- and this snap stops
    # its arrears growing without bound.
    A-MovWordSiImm $t 'aztAnimDue' 0
    A-MovEbxEax $t                              # ebx = now
    A-SubEaxSi $t 'aztAnimLast'                 # eax = now - last  (unsigned)
    A-CmpEaxSi $t 'aztAnimPeriod'
    A-JbS $t 'AFL_noanim'
    A-MovWordSiImm $t 'aztAnimDue' 1
    A-MovEcxSi $t 'aztAnimPeriod'
    A-AddSiEcx $t 'aztAnimLast'                 # last += period, remainder kept
    A-CmpEaxImm $t 500000
    A-JbeS $t 'AFL_noanim'
    A-MovSiEbx32 $t 'aztAnimLast'               # stalled: snap, no catch-up burst
    Add-Label $t 'AFL_noanim'

    # ---- pull in the BSS overlay, once ---------------------------------------
    # This is the earliest hook that is reached unconditionally every frame and
    # already has esi, so it costs nine bytes a frame and needs no new entry
    # point. The "have we done it?" flag is the overlay's own magic dword: BSS
    # starts zeroed, so a zero there means not loaded, and nothing else can put
    # 'AZTO' in it.
    #
    # The two movies that play BEFORE the main loop (MINDLOGO, INTRO) are the
    # 640x480 ones, so nothing that needs the overlay can run ahead of it.
    A-CmpDwordSiImm $t $OVERLAY_BASE 0
    A-JnzS $t 'AFL_haveOvl'
    A-Call $t 'AztOverlayLoad'
    Add-Label $t 'AFL_haveOvl'

    # ---- per-frame overlay entry (+9) ---------------------------------------
    # By literal, not by label: the overlay is assembled after this blob, so its
    # labels do not exist yet. Reached only below AFL_haveOvl, which guarantees the
    # overlay is resident. ebx is still `now` here, which is what the tick wants,
    # and eax/ebx/ecx/edx are all dead before the pops below.
    #
    # THIS IS NOT THE FPS LOG'S CALL, whatever it used to be gated on. It is the ONLY
    # thing that enters AztFrameAll, and AztFrameAll drives AztBootTick -- the visor
    # boot animation -- as well as AztCdPoll. Hanging it off $ENABLE_FPS_LOG meant that
    # turning the fps log off silently deleted the boot sequence and the CD polling,
    # with nothing in the build to say so. Gate it on whether ANYTHING per-frame is on.
    #
    # Derived HERE, at the use site, not up with the constants: every flag it reads is
    # defined by line 800 and this is line ~3450, so it cannot become the $null -> 0 that
    # a derived value placed above its constants silently turns into.
    $NEED_OVL_FRAME = $ENABLE_FPS_LOG -or $CAM_RECORD -or $ENABLE_SCENE_LOG -or `
                      $ENABLE_BOOT_SEQ -or $ENABLE_CD_AUDIO -or $ENABLE_HOST_FOV
    if ($NEED_OVL_FRAME) {
        A-LeaEaxSi $t ([uint32]($OVERLAY_BASE + 9))
        A-CallEax  $t
    }

    A-PopEdi $t; A-PopEsi $t; A-PopEdx $t; A-PopEcx $t; A-PopEbx $t; A-PopEax $t
    A-Ret $t

    # ---- AztOverlayLoad -- read AZTCODE.BIN into the BSS, then run its init ---
    # DOS INT 21h rather than the game's stdio: AH=3Dh/3Fh/3Eh are two bytes
    # each where fopen/fread/fclose would be a 5-byte rel32 each, and DOS/4GW
    # translates the flat DS:EDX itself. Failure is silent by design -- pushad
    # restores everything, the magic stays zero, and the frame hook simply tries
    # again next frame rather than the game dying on a bad handle.
    Add-Label $t 'AztOverlayLoad'
    A-Pushad $t
    A-Call $t $asm.Labels['AztDeltas']          # esi = obj1 delta
    A-XorEaxEax $t
    A-MovAhImm $t 0x3D                          # open, read-only
    A-LeaEdxSi $t 'aztOvlName'
    A-Int $t 0x21
    A-JbS $t 'AOL_out'                          # CF = could not open
    A-XchgEaxEbx $t                             # handle -> ebx (1 byte; mov is 2)
    A-MovAhImm $t 0x3F                          # read (AL is ignored)
    A-MovEcxImm $t $OVERLAY_READ
    A-LeaEdxSi $t $OVERLAY_BASE
    A-Int $t 0x21
    A-MovAhImm $t 0x3E                          # close -- ebx still holds the handle
    A-Int $t 0x21
    # Hand control to the overlay's own init, which is what patches the sites
    # that only exist once it is resident. Entry is at +4, past the magic.
    A-LeaEaxSi $t ([uint32]($OVERLAY_BASE + 4))
    A-CallEax $t
    Add-Label $t 'AOL_out'
    A-Popad $t
    A-Ret $t
    Add-Label $t 'aztOvlName'; A-Asciiz $t $OVERLAY_NAME

    # ---- AztEarlyOvl: pull the overlay in BEFORE the intro sequence -----------
    # Displaces `call 0x10220` at 0x16146, the instruction immediately preceding the ONLY
    # call to the intro sequence (0x1614B -> 0x1FF39). Ten bytes.
    #
    # The overlay used to arrive on the first RENDERED frame, from AztFrameLimit, which is
    # far too late for two things:
    #   - the boot effect's CD latency, which AztCdBoot now starts during the room load;
    #   - anything the intro itself wants, which is why AztOpenMovie is stuck in a cave
    #     with one byte spare. With the overlay resident this early it can move into the
    #     ~19 KB of free BSS whenever we choose to.
    #
    # SAFE TO RUN THIS EARLY because AztInitAll no longer allocates: AztInjInit's 576 KB
    # moved to the first frame. What remains is AztCdInit (64 bytes of DOS low memory, not
    # the heap the movies use) and AztBootInit (zeroes two dwords).
    #
    # No pushad: AztOverlayLoad already brackets itself with pushad/popad and derives its
    # own esi, so this is a call and a tail jump. AztFrameLimit still tests the magic and
    # will simply find it already set, so nothing loads twice.
    if ($ENABLE_EARLY_OVERLAY) {
        Add-Label $t 'AztEarlyOvl'
        A-Call $t 'AztOverlayLoad'
        A-Jmp  $t ([uint32]0x10220)
    }

    # ---- AztNow: microseconds, from the game's OWN timer bookkeeping ---------
    #
    # !! DO NOT READ PIT CHANNEL 0 DIRECTLY. !! This used to latch the counter
    # (out 0x43,0; in al,0x40 twice) and return ticks*65536 + (65535-count),
    # which assumes the BIOS divisor of 65536 is still loaded. IT USUALLY IS NOT.
    #
    # The game installs its own INT 8 handler at 0x604A2 and runs a 16-slot timer
    # service. 0x60640 picks the SHORTEST period any slot has asked for and
    # reprograms channel 0 to match (0x605C8: mov al,0x36 / out 0x43,al, divisor
    # to port 0x40, saved at 0x14866E). Periods are in MICROSECONDS -- 0x605F8
    # converts with us * 10000/8380, i.e. us * 1.193182 PIT ticks per us. So as
    # soon as Miles registers a fast slot for audio mixing, the divisor drops far
    # below 65536 and the old maths is nonsense: (65535-count) then oscillates in
    # a narrow band and goes BACKWARDS every time the counter wraps, which makes
    # the unsigned `elapsed` enormous and the spin exit immediately. The limiter
    # fails OPEN -- exactly the "first room runs uncapped" symptom, and it varies
    # by room because the active audio slots do.
    #
    # Slot 15 is the one that keeps the BIOS tick alive, and it hands us a
    # correct clock for free. From the ISR itself: state[i] at 0x148524, period[i]
    # at 0x1485A4, accumulator[i] at 0x148564, pending[i] at 0x1485E4, i a BYTE
    # offset. The accumulate loop covers all 16 slots (edi < 0x40) but the
    # callback loop only covers 0..14 (edi < 0x3C), and slot 15's pending counter
    # -- 0x1485E4 + 0x3C = 0x148620 -- is precisely the counter the ISR uses to
    # chain to the original INT 8. 0x60753 sets state[15] (0x148560) to 2 and
    # registers it with period 0xD68D = 54925 us = 18.2065 Hz.
    #
    # So accumulator[15] at 0x1485A0 is a free-running microsecond count INSIDE
    # the current BIOS tick, advanced by the ISR at whatever rate the PIT happens
    # to be running, and reset in lockstep with the tick at 0x46C:
    #
    #     now_us = [0x46C] * period15 + accumulator15
    #
    # That is correct for ANY divisor, which is the whole point. Resolution is
    # the current PIT period, so it is fine while audio is running and degrades
    # to 54.9 ms if nothing has asked for anything faster -- in which case the
    # cap simply becomes 18.2 fps. That is a SAFE failure: the game's own design
    # rate, never faster than intended.
    #
    # period15 is read rather than hard-coded, so it tracks whatever the game
    # registered. mul discards the high half in edx, so this wraps at 2^32 us ~
    # 71.6 minutes; the subtraction is unsigned, so a wrap costs one unthrottled
    # frame and nothing worse.
    #
    # Reading the tick and the accumulator is a two-part read the timer interrupt
    # can land inside, so it runs with interrupts off -- pushfd/popfd rather than
    # sti, to restore whatever the caller had.
    Add-Label $t 'AztNow'
    A-PushEbx $t; A-PushEcx $t; A-PushEdx $t; A-PushEsi $t; A-PushEdi $t
    A-Call $t $asm.Labels['AztDeltas']          # esi = obj1 delta, edi = obj2 delta
    A-Pushfd $t
    A-Cli $t
    A-MovEaxImm $t 0x46C                        # low memory is identity-mapped
    A-MovEaxEaxPtr $t                           # eax = BIOS tick
    A-MovEcxDi $t $TIMER_PERIOD15               # ecx = slot 15 period (54925 us)
    A-MulEcx $t                                 # edx:eax = tick * period
    A-AddEaxDi $t $TIMER_ACC15                  # + us elapsed inside this tick
    A-Popfd $t
    A-PopEdi $t; A-PopEsi $t; A-PopEdx $t; A-PopEcx $t; A-PopEbx $t
    A-Ret $t

    # ---- AztActorTime -- advance actors on the CLOCK, not on frames ----------
    # Redundant now that the frame rate is pinned, but harmless and it keeps the
    # actors right even in the states where the limiter's own hook is skipped.
    Add-Label $t 'AztActorTime'
    A-PushEbx $t; A-PushEcx $t; A-PushEdx $t; A-PushEsi $t; A-PushEdi $t
    A-PushEax $t                       # [esp] = 0x261C0's own argument
    A-Call $t $asm.Labels['AztDeltas'] # esi = obj1 delta (position-independent)

    A-MovEaxImm $t 0x46C
    A-MovEaxEaxPtr $t
    A-MovEbxSi $t 'aztLastTick'
    A-MovSiEax32 $t 'aztLastTick'
    A-SubEaxEbx $t
    A-Jz $t 'AAT_check'
    A-CmpEaxImm $t 8
    A-Jbe $t 'AAT_scale'
    A-MovEaxImm $t 8                   # clamp: a loading screen must not burst
    Add-Label $t 'AAT_scale'
    A-ImulEaxImm $t 100                # 100 units == one tick
    A-AddSiAx $t 'aztTickAcc'

    # ONE ACTOR STEP PER FRAME. This used to loop back to AAT_check and drain the
    # accumulator, running 0x261C0 -- the SCRIPT interpreter -- up to eight times in a
    # single frame (the tick delta above is clamped at 8, not the step count).
    #
    # Harmless while frames are short. Not harmless once something makes a frame long,
    # and the host renderer does exactly that: AztInjBody copies 1.48 MB into the
    # viewport every frame, which is real emulated CPU inside DOSBox's fixed cycle
    # budget. Frames stretch, more BIOS ticks elapse per frame, the scripts run ahead of
    # the engine state they drive, and Reality Lab is handed an object that does not
    # exist yet -- RAPTOR ERROR in Rendermorphics / object expected in argument.
    #
    # MEASURED, and this is what pinned it: at the normal copy rate the game died after
    # ~180 copies in ~8 s, repeatedly. At one copy in four -- same work, four times the
    # wall clock -- it passed 730 copies and 130 s with no crash. Rate-dependent, not
    # cumulative and not time-based, which points at frame LENGTH rather than at what the
    # copy writes (both buffers measure 1,484,805 bytes for a 1,484,800-byte copy).
    #
    # The ANIMATION gate already takes this precaution -- never more than one step per
    # rendered frame. The actor scheduler never got the same treatment.
    #
    # The remainder is DROPPED, not carried: keeping it would step twice next frame and
    # put the burst straight back. At a normal frame rate the accumulator rarely exceeds
    # one period so this costs nothing, and when frames are slow the actors run at the
    # frame rate -- which is what the stock game did.
    Add-Label $t 'AAT_check'
    A-MovAxSi $t 'aztTickAcc'
    A-MovBxSi $t 'aztPeriod'
    A-CmpAxBx $t
    A-Jb $t 'AAT_done'
    A-MovWordSiImm $t 'aztTickAcc' 0   # no debt carried: one step per frame
    A-MovEaxEspPtr $t
    if ($ENABLE_NPC_PACE) {
        # through the overlay's NPC pace gate (AztActorGate, at the fixed +21 entry): it steps 0x261C0 NPC_RATE_PCT % of the time
        A-Db $t @(0x8D, 0x8E); Add-Abs32 $t ([uint32]($OVERLAY_BASE + 21))      # lea ecx,[esi+AztOvlActor]
        A-Db $t @(0xFF, 0xD1)                                                     # call ecx
    } else {
        A-Call $t $ACTOR_STEP          # 0x261C0 pushes esi at entry, so esi survives
    }

    Add-Label $t 'AAT_done'
    A-PopEax $t
    A-PopEdi $t; A-PopEsi $t; A-PopEdx $t; A-PopEcx $t; A-PopEbx $t
    A-Ret $t

    Add-Label $t 'aztLastTick';    A-Db $t ([byte[]](,0 * 4))
    Add-Label $t 'aztTickAcc';     A-Dw $t 0
    Add-Label $t 'aztPeriod';      A-Dw $t $ACTOR_PERIOD
    Add-Label $t 'aztLastFrame';   A-Db $t ([byte[]](,0 * 4))
    Add-Label $t 'aztFramePeriod'; A-Db $t ([byte[]][BitConverter]::GetBytes([uint32]$FRAME_PERIOD))

    # ---- AztAnimGate -- ZF=1 means HOLD this animation frame ------------------
    # Factored out because there are SIX advance sites and one gate has to serve
    # them all. `cmp` sets the flags and `pop` does not disturb them, so the
    # registers are restored BEFORE the caller branches and nothing has to be
    # unwound on either path. AztDeltas clobbers eax, esi and edi and nothing
    # else, which is why only those three are saved -- every caller keeps its own
    # record pointer in ebx, ecx or edx across this.
    Add-Label $t 'AztAnimGate'
    A-PushEsi $t; A-PushEdi $t; A-PushEax $t
    A-Call $t $asm.Labels['AztDeltas']
    A-CmpWordSiImm $t 'aztAnimDue' 0
    A-PopEax $t; A-PopEdi $t; A-PopEsi $t
    A-Ret $t

    # AztAnimStep / AztAnimAddEdx / AztAnimAddEdxSt used to sit here. They are in
    # the OVERLAY now (search AztAnimStep below) -- 58 bytes that this blob no
    # longer had, once AztOverlayLoad moved in. They still call AztAnimGate here
    # by absolute address, which is the normal cross-blob convention.

    Add-Label $t 'aztAnimLast';    A-Db $t ([byte[]](,0 * 4))
    Add-Label $t 'aztAnimPeriod';  A-Db $t ([byte[]][BitConverter]::GetBytes([uint32]$ANIM_PERIOD_US))
    Add-Label $t 'aztAnimDue';     A-Dw $t 0

    # ---- AztBookPos: centre the book page in the full-screen surface ---------
    # Book pages are D:\TEXTURES\books\<name><n>.pcx (format at 0x14076C), and
    # MEASURED off the disc they are all 640x480. 0x1647B loads one into surface
    # 0x152580 -- which scr-w/h-116C2 grew to the full screen -- via 0x38A20,
    # whose ebx/ecx are the destination X/Y offsets (confirmed in 0x3E330: it
    # tests xOff+imageWidth against the surface width at 0x3E420 and
    # yOff+imageHeight against its height at 0x3E447). Both are zeroed at
    # 0x1646B/0x1646D, so at 800x600 a 640x480 page lands in the TOP-LEFT corner
    # -- 80px left and 60px up of centre. That is the off-centre scroll.
    #
    # It needs 8 bytes of immediates where the original has 4, so the site jumps
    # here instead. `lea edx,[esp+0x300]` comes along for the ride because this is
    # a JMP, not a call -- esp is unchanged, so the filename buffer is still at
    # the same offset. Nothing here needs a fixup: esp-relative, immediates, and
    # a PC-relative jump back.
    #
    # $BOOK_FULLSCREEN: src\Build-Books.ps1 rescales the shipped pages to the
    # screen size at install time, because blitting a 640x480 page 1:1 into a
    # bigger screen makes it physically SMALLER -- 86% of the width at the
    # original 640x480, 69% at 800x600, 54% at 1024x768. Centring never addressed
    # that; only rescaling the art does.
    #
    # A screen-sized page then belongs at (0,0), which is what the stock code
    # already does, so this whole patch drops out. THE TWO MUST AGREE: if the
    # pages are not rescaled and this is on, every page sits in the top-left
    # corner instead of centred. Apply-AztMod runs Build-Books on install for
    # exactly that reason.
    $BOOK_FULLSCREEN = $true

# How much of the screen HEIGHT a page occupies; the canvas stays screen-sized and the rest
# is black. See Build-Books.ps1 -- the game still gets a screen-sized image at (0,0), so this
# is purely how the art is composed and changes nothing in the patch set.
$BOOK_FILL_PCT = 80

# Up-rezzed replacement pages, used INSTEAD of upscaling the shipped 640x480 ones.
#
# Apply-AztMod regenerates the pages on every install, and it used to call Build-Books with
# no -InDir -- which means it rescaled from the pristine .src each time and silently threw
# away imported high-resolution art. Naming the folder here keeps the installer and the
# import in step. A build that cannot see the folder just falls back to the .src pages, so
# a redistributable package is unaffected.
$BOOK_SOURCE_DIR = 'C:\Games\RaptorMod\sources\books'
    if ($BOOK_FULLSCREEN) { $BOOK_W = $SCREEN_W; $BOOK_H = $SCREEN_H }
    else                  { $BOOK_W = 640;       $BOOK_H = 480 }
    $BOOK_X = [int](($SCREEN_W - $BOOK_W) / 2)
    $BOOK_Y = [int](($SCREEN_H - $BOOK_H) / 2)
    # Emitted only when it is actually hooked -- 20 bytes of a blob that has none
    # to spare, and the hook below is guarded by the same condition.
    if ($BOOK_X -ne 0 -or $BOOK_Y -ne 0) {
        Add-Label $t 'AztBookPos'
        A-MovCxImm $t ([uint16]$BOOK_Y)      # ecx = Y offset
        A-MovBxImm $t ([uint16]$BOOK_X)      # ebx = X offset
        A-LeaEdxEspDisp $t 0x300             # the instruction the jump displaced
        A-Jmp $t ([uint32]0x16476)
    }

    # ---- AztSkipKey: SPACE also skips a line of dialogue ---------------------
    # The game already has this, bound to Escape and nothing else. In the key
    # handler (0x12B88, ebx = the event record, ascii at +6):
    #
    #   0x12D41  cmp word [0x152B28], 0   ; speaking? no -> normal keys, 0x12F24
    #   0x12D4F  cmp byte [ebx+5], 1      ; a key-DOWN event
    #   0x12D5E  cmp eax, 0x1B            ; ESC, and only ESC
    #   0x12D67  call 0x17C08             ; end the line early
    #
    # 0x17C08 is the same routine the natural end of speech uses: 0x13B35 polls
    # the channel with 0x321B4 each frame and calls it when the sample stops. It
    # clears the speaking flag, releases the channel through 0x31C11 / 0x3231F,
    # and re-draws the option list -- so this is the game's own path, not a
    # synthesised one, and skipping cannot leave the conversation half-advanced.
    #
    # Adding a second accepted key does not fit in place: `cmp eax,0x1B` plus its
    # 6-byte `jnz` is 9 bytes, and testing two values needs 10. So the site jumps
    # here. Everything else while speaking already falls through to 0x12F2F and is
    # swallowed, which is why Space was free to take.
    # ...and it lives in the OVERLAY now, for the same reason as the animation
    # steppers: this blob had to make room for AztOverlayLoad. Nothing can press a
    # key before the first frame, which is when the overlay arrives.

    $tAsm = Invoke-Asm $t
    if ($tAsm.Labels['AztFrameLimit'] -ne $ACTOR_TIME_AT) {
        throw ("AztFrameLimit must be first in the blob: it is at 0x{0:X}, the stub calls 0x{1:X}" -f `
               $tAsm.Labels['AztFrameLimit'], $ACTOR_TIME_AT)
    }
    if ($tAsm.Bytes.Length -gt $ACTOR_TIME_CAP) {
        throw ("clock blob is {0} bytes, only {1} available at 0x{2:X}" -f `
               $tAsm.Bytes.Length, $ACTOR_TIME_CAP, $ACTOR_TIME_AT)
    }

    # No guest code writes aztFramePeriod any more -- the A/B harness that did has
    # been removed. The HOST raises the cap for a host-render session, reading the
    # address out of the manifest's own settings table (see the aztFramePeriod entry
    # near the end of this file), which is where every other host tool gets it.
    $o = Lin2File $ACTOR_TIME_AT
    $patches += New-Patch -Name 'actor-time' -FileOffset $o `
        -Expect $raw[$o..($o + $tAsm.Bytes.Length - 1)] -Replace $tAsm.Bytes `
        -Note ("AztFrameLimit ({0} fps cap) + AztActorTime ({1:N1} Hz actors), on the PIT clock" -f `
               $FRAME_CAP_FPS, (18.2065 * 100 / $ACTOR_PERIOD))
    Write-Host ("clock blob: {0} bytes of {1} at 0x{2:X}  (limit {3} fps)" -f `
                $tAsm.Bytes.Length, $ACTOR_TIME_CAP, $ACTOR_TIME_AT, $FRAME_CAP_FPS)

    # ---- the two early hooks, back to back in the game's own start-up --------
    #   0x16146  call 0x10220   -> AztEarlyOvl : read the overlay, then carry on
    #   0x1614B  call 0x1FF39      the intro sequence, UNTOUCHED
    #   0x16150  call 0x11688   -> AztCdBoot   : start the boot effect, then carry on
    #
    # EMITTED HERE, not with the other cave patches, because AztEarlyOvl lives in the clock
    # blob and that is only assembled on the line above -- referencing it any earlier gets a
    # null address and a patch that calls offset zero.
    #
    # Both sites are checked against the FILE: plain E8 rel32 with no fixup, so the bytes on
    # disk are the bytes that execute and the target can be verified arithmetically.
    if ($ENABLE_EARLY_OVERLAY) {
        $earlySites = @(
            @{ at = [uint32]0x16146; calls = [uint32]0x10220; label = 'AztEarlyOvl'; blob = $tAsm
               note = 'the BSS overlay is read here, before the intro, not on the first rendered frame' }
        )
        if ($ENABLE_CD_AUDIO -and $ENABLE_BOOT_SEQ -and $ENABLE_EARLY_CD_BOOT) {
            $earlySites += @{ at = [uint32]0x16150; calls = [uint32]0x11688; label = 'AztCdBoot'; blob = $asm
                              note = 'the visor boot effect is requested here, so its ~4s of CD latency lands on the room load' }
        }
        foreach ($e in $earlySites) {
            $eo  = Lin2File $e.at
            $old = $raw[$eo..($eo + 4)]
            if ($old[0] -ne 0xE8) { throw ("early hook: expected E8 at 0x{0:X5}, found 0x{1:X2}" -f $e.at, $old[0]) }
            $tgt = [uint32]($e.at + 5 + [BitConverter]::ToInt32(([byte[]]$old[1..4]), 0))
            if ($tgt -ne $e.calls) {
                throw ("early hook: 0x{0:X5} calls 0x{1:X5}, expected 0x{2:X5}" -f $e.at, $tgt, $e.calls)
            }
            $dst = $e.blob.Labels[$e.label]
            if (-not $dst) { throw ("early hook: {0} was never assembled" -f $e.label) }
            $patches += New-Patch -Name ("early-{0:X}" -f $e.at) -FileOffset $eo `
                -Expect $old -Replace (CallRel32 $e.at $dst) -Note $e.note
            Write-Host ("early hook 0x{0:X5}: was call 0x{1:X5}, now {2} at 0x{3:X5}" -f $e.at, $e.calls, $e.label, $dst)
        }
    }

    # =======================================================================
    #  THE OVERLAY -- ships as AZTCODE.BIN, read into the BSS at 0x133000
    # =======================================================================
    # Assembled AFTER the clock blob so it can call back into it (AztAnimGate)
    # by absolute address, and BEFORE the patch table so the sites that target
    # it can resolve. It is not bounded by anything but the 53 KB of BSS, which
    # is why everything that outgrew a real cave ends up here.
    $ovl = New-Asm -Base $OVERLAY_BASE

    # The magic doubles as the "is it loaded?" flag the frame hook tests, so it
    # MUST be first and must be non-zero.
    Add-Label $ovl 'aztOvlMagic'
    A-Db $ovl ([byte[]][BitConverter]::GetBytes([uint32]$OVERLAY_MAGIC))

    # ---- FIXED ENTRY VECTOR -- two 5-byte jumps at +4 and +9 ----------------
    # The overlay is assembled AFTER the clock blob, so code in the clock blob
    # cannot name a label in here. Both directions are solved the same way the
    # init already was: a jump at a LITERAL offset that the caller computes as
    # `lea eax,[esi+0x13300N] / call eax`. Keep these two first and fixed-size, and
    # anything in the clock blob can reach into the overlay.
    #
    #   +4  AztOvlInit   once, immediately after the read      (AztOverlayLoad)
    #   +9  AztOvlFrame  every frame, once the overlay is up   (AztFrameLimit)
    #  +14  AztOvlCdBoot once, after the intro, before the room loads (AztCdBoot stub)
    Add-Label $ovl 'AztOvlInit'
    A-Jmp $ovl 'AztInitAll'
    Add-Label $ovl 'AztOvlFrame'
    A-Jmp $ovl 'AztFrameAll'
    Add-Label $ovl 'AztOvlCdBoot'
    A-Jmp $ovl 'AztCdBootStart'
    #  +19  aztTypingKeys: a WORD the stub's WASD hooks read (see $g_saveList). Fixed here, asserted after assembly.
    Add-Label $ovl 'aztTypingKeys'; A-Dw $ovl 0
    #  +21  AztOvlActor: the clock blob's actor step goes through the NPC pace gate ($ENABLE_NPC_PACE). Asserted.
    if ($ENABLE_NPC_PACE) { Add-Label $ovl 'AztOvlActor'; A-Jmp $ovl 'AztActorGate' }

    # Everything that runs once at load, and everything that runs per frame. The
    # three fixed entries above are jumps so that this list can grow without moving
    # the literals the caves call.
    Add-Label $ovl 'AztInitAll'
    A-Call $ovl 'AztFpsInit'
    A-Call $ovl 'AztCamInit'
    A-Call $ovl 'AztCdInit'
    if ($ENABLE_BOOT_SEQ) { A-Call $ovl 'AztBootInit' }
    # AztInjInit IS NOT CALLED HERE ANY MORE -- see AztFrameAll. It asks the game's own
    # allocator for 576 KB, and this init now runs BEFORE the intro movies, where that
    # allocation would be taken out of the heap the movie player needs ~2.4 MB of. That
    # is the documented crash: a movie played with the memory already spoken for dies.
    # Deferred to the first rendered frame, which is where it used to happen anyway.
    # AztSceneLog needs no init: it opens its file lazily, on the frame it fires.
    A-Ret $ovl

    # ---- the boot effect, started EARLY ---------------------------------------
    # Reached from the AztCdBoot stub at 0x16150, i.e. the instant the intro sequence
    # returns and before the room and its textures load. The point is the ~4 SECONDS of
    # CD start latency: the sound was previously requested on the boot animation's first
    # frame and arrived four seconds into it, so the visual timeline had to be held back
    # to meet it. Requesting it here spends that latency on the room load instead.
    #
    # NOT in AztInitAll, even though that now runs early enough: AztInitAll fires before
    # the intro MOVIES, and the boot effect would then play underneath them.
    #
    # AztBootTick still asks for slot 11 on its first frame and that is deliberate -- it
    # costs nothing (AztCdPlay returns early for a track already playing, so the track is
    # NOT restarted) and it remains the fallback if this early request failed.
    #
    # esi/edi ARE NOT SET on entry. Every other overlay routine is reached from the frame
    # hook, which already holds the deltas; this one is reached from a bare trampoline, so
    # it derives them itself. pushad/popad so the trampoline can stay a plain call+jmp.
    Add-Label $ovl 'AztCdBootStart'
    if ($ENABLE_CD_AUDIO -and $ENABLE_BOOT_SEQ -and $ENABLE_EARLY_CD_BOOT) {
        A-Pushad $ovl
        A-Call $ovl $asm.Labels['AztDeltas']     # esi = obj1 delta, edi = obj2 delta
        A-MovEaxImm $ovl 11                      # slot 11 = BOOTFX
        A-Call $ovl 'AztCdPlay'
        A-Popad $ovl
    }
    A-Ret $ovl

    # ---------------------------------------------------------------------------
    # AztStepRetry (OVERLAY: the stub cave is full) -- replaces the `jnz 0x1DE08` after each forward path's GROUND test
    # (0x11E68 at 0x1D78C / 0x1D940). Jumped to, so esp is the function's own.
    # ---------------------------------------------------------------------------
    # Josh, 2026-10-15: "it's easy to get stuck on the geometry in the game ... in
    # Room Review everything is so much smoother". The wall tests are thin (a ray at
    # eye height and an 8-unit point test, face interiors only) and already slide.
    # What stops the player DEAD is the ground test at the new spot, which rejects a
    # step when (a) no floor face is found under it -- the faces are tested in rounded
    # integer coordinates, so seams between floor polygons can drop a step -- or (b)
    # an up-facing face sits above knee height (eye - 22 + v) under it: a lip, a
    # ledge, a plinth, the top of an object. Stock: the step is simply abandoned.
    #
    # Now the step is retried along ONE AXIS of its own direction, the larger first,
    # then the other -- as Room Review's walk does -- so a diagonal step round a lip or
    # off a seam carries on instead of stopping. Shares aztSlideDone with the wall
    # slide (two retries a frame in all). No wall normal is involved (0x11E68 makes
    # none), and the retried step runs every test again, so nothing new can pass.
    Add-Label $ovl 'AztStepRetry'
    A-PushEax $ovl; A-PushEdx $ovl; A-PushEsi $ovl; A-PushEdi $ovl
    A-Call $ovl ([uint32]$asm.Labels['AztDeltas'])
    A-CmpWordSiImm $ovl ([uint32]$asm.Labels['aztSlideDone']) 1
    A-Ja $ovl 'ASR_abandon'                     # two retries this frame already
    A-MovEaxSi $ovl ([uint32]$asm.Labels['aztSaveX'])                  # the position back where it was
    A-MovEspDispEax $ovl 0x1C
    A-MovEaxSi $ovl ([uint32]$asm.Labels['aztSaveZ'])
    A-MovEspDispEax $ovl 0x24
    A-CmpWordSiImm $ovl ([uint32]$asm.Labels['aztSlideDone']) 0
    A-Jnz $ovl 'ASR_second'
    # first retry this frame: remember the direction, keep its larger axis
    A-MovEaxDi $ovl $g_dirX
    A-MovSiEax32 $ovl 'aztStepDirX'
    A-MovEaxDi $ovl $g_dirZ
    A-MovSiEax32 $ovl 'aztStepDirZ'
    A-MovWordSiImm $ovl 'aztStepMine' 1
    Add-Label $ovl 'ASR_pick'                   # |Z| vs |X| as IEEE bits (sign masked: same order as the magnitudes)
    A-MovEaxDi $ovl $g_dirZ
    A-AndEaxImm $ovl ([uint32]0x7FFFFFFF)
    A-MovEdxDi $ovl $g_dirX
    A-AndEdxImm $ovl ([uint32]0x7FFFFFFF)
    A-CmpEaxEdx $ovl
    A-Ja $ovl 'ASR_keepZ'
    Add-Label $ovl 'ASR_keepX'
    A-MovDwordDiImm $ovl $g_dirZ ([uint32]0)
    A-Jmp $ovl 'ASR_retry'
    Add-Label $ovl 'ASR_keepZ'
    A-MovDwordDiImm $ovl $g_dirX ([uint32]0)
    A-Jmp $ovl 'ASR_retry'
    # second retry: after our own first one, the OTHER axis of the remembered direction;
    # after a wall slide, the larger axis of the slid direction
    Add-Label $ovl 'ASR_second'
    A-CmpWordSiImm $ovl 'aztStepMine' 1
    A-Jnz $ovl 'ASR_pick'
    A-MovWordSiImm $ovl 'aztStepMine' 0
    A-MovEaxSi $ovl 'aztStepDirX'
    A-MovDiEax32 $ovl $g_dirX
    A-MovEaxSi $ovl 'aztStepDirZ'
    A-MovDiEax32 $ovl $g_dirZ
    A-AndEaxImm $ovl ([uint32]0x7FFFFFFF)
    A-MovEdxDi $ovl $g_dirX
    A-AndEdxImm $ovl ([uint32]0x7FFFFFFF)
    A-CmpEaxEdx $ovl
    A-Ja $ovl 'ASR_keepX'                       # Z was kept first: now X
    A-Jmp $ovl 'ASR_keepZ'
    Add-Label $ovl 'ASR_retry'
    A-IncWordSi $ovl ([uint32]$asm.Labels['aztSlideDone'])
    A-MovEaxSi $ovl ([uint32]$asm.Labels['aztRetry'])                  # load before esi is popped
    A-PopEdi $ovl; A-PopEsi $ovl; A-PopEdx $ovl
    A-AddEspImm $ovl 4                          # discard the saved eax; we return through it
    A-JmpEax $ovl                               # redo the step along one axis
    Add-Label $ovl 'ASR_abandon'
    A-PopEdi $ovl; A-PopEsi $ovl; A-PopEdx $ovl; A-PopEax $ovl
    A-Jmp $ovl ([uint32]0x1DE08)                # the original abandon
    Add-Label $ovl 'aztStepMine';   A-Dw $ovl 0                   # this frame's first retry was ours (AztFrameAll clears it)
    Add-Label $ovl 'aztStepDirX';   A-Db $ovl ([byte[]](,0 * 4))  # the direction before it
    Add-Label $ovl 'aztStepDirZ';   A-Db $ovl ([byte[]](,0 * 4))

    # ebx = now on entry, and every one of these clobbers it, so it is re-supplied
    # from the stack before each call rather than saved once.
    Add-Label $ovl 'AztFrameAll'
    # KEYS FOR TYPING (see $g_saveList): picture view, or the save list up with a slot 0..4 picked (the game's save-name
    # entry). -1 (none) and 6 (RESTART) compare above 4 unsigned. esi/edi hold the deltas here (reached from the frame hook).
    A-MovAxDi $ovl $g_saveBox                  # ax = the picture view
    A-CmpWordDiImm $ovl $g_saveList 0
    A-JzS $ovl 'AFA_typed'
    A-CmpWordDiImm $ovl $g_listSel 4
    A-JaS $ovl 'AFA_typed'
    A-OrAxImm $ovl 1
    Add-Label $ovl 'AFA_typed'
    A-MovSiAx $ovl 'aztTypingKeys'
    A-MovWordSiImm $ovl 'aztStepMine' 0         # (AztStepRetry: a new frame's movement)
    # THE STAGING BUFFER IS ALLOCATED HERE, NOT IN AztInitAll, because init now runs
    # before the intro movies and this asks for 576 KB of the same heap the movie player
    # needs. Once, on the first rendered frame -- which is exactly when it used to happen.
    # The flag is its own: aztInjBufPtr cannot serve, because 0 is also what a FAILED
    # allocation leaves behind, and retrying it every frame for the whole game would be a
    # new bug rather than a fallback.
    if ($ENABLE_VIEW_INJECT) {
        A-CmpDwordSiImm $ovl 'aztInjDone' 0
        A-JnzS $ovl 'AFA_haveInj'
        A-MovDwordSiImm $ovl 'aztInjDone' 1
        A-PushEbx $ovl
        A-Call $ovl 'AztInjInit'
        A-PopEbx $ovl
        Add-Label $ovl 'AFA_haveInj'
    }
    A-PushEbx $ovl
    A-Call $ovl 'AztFpsTick'
    A-PopEbx $ovl
    A-PushEbx $ovl
    A-Call $ovl 'AztCamLog'
    A-PopEbx $ovl
    if ($ENABLE_SCENE_LOG) {           # (only when it does something: the overlay is at its ceiling)
        A-PushEbx $ovl
        A-Call $ovl 'AztSceneLog'      # one shot; returns immediately once done
        A-PopEbx $ovl
    }
    if ($ENABLE_TEX_DEFRAG -or $ENABLE_RELEVEL_KICK) {
        A-PushEbx $ovl
        A-Call $ovl 'AztRoomTick'      # defrag and/or rebuild the device on a room change
        A-PopEbx $ovl
    }
    if ($ENABLE_BOOT_SEQ) {
        A-PushEbx $ovl
        A-Call $ovl 'AztBootTick'      # holds the 3D off while the visor "boots"
        A-PopEbx $ovl
    }
    if ($ENABLE_NPC_PACE) {
        # THIS FRAME'S CHARACTER STRIDE (AztNpcStride): the animation tick, thinned to aztNpcPct
        A-MovWordSiImm $ovl 'aztCharDue' 0
        A-CmpWordSiImm $ovl ([uint32]$tAsm.Labels['aztAnimDue']) 0
        A-JzS $ovl 'AFA_nochar'
        A-PushEdx $ovl
        A-MovzxEdxSi $ovl 'aztCharAcc'
        A-Db $ovl @(0x66, 0x03, 0x96); Add-Abs32 $ovl 'aztNpcPct'                 # add dx,[esi+aztNpcPct]
        A-Db $ovl @(0x66, 0x83, 0xFA, 0x64)                                         # cmp dx,100
        A-JbS $ovl 'AFA_charheld'
        A-Db $ovl @(0x66, 0x83, 0xEA, 0x64)                                         # sub dx,100
        A-MovWordSiImm $ovl 'aztCharDue' 1
        Add-Label $ovl 'AFA_charheld'
        A-MovSiDx $ovl 'aztCharAcc'
        A-PopEdx $ovl
        Add-Label $ovl 'AFA_nochar'
    }
    if ($ENABLE_HOST_FOV) {
        A-PushEbx $ovl
        A-Call $ovl 'AztFovTick'       # the host's field of view, before this frame's render and pick
        A-PopEbx $ovl
    }
    A-Call $ovl 'AztCdPoll'            # last, so it gets `now` live in ebx
    A-Ret $ovl

    # ---- AztDefragTick: compact the texture cache when the room changes -------
    # See the $ENABLE_TEX_DEFRAG note for why, and for what it does NOT promise.
    #
    # The room signature is lifted verbatim from AztSceneLog rather than invented:
    # the root frame's **LAST** child (room frames are APPENDED, so the FIRST child
    # is the movement frame and never changes -- a first-child signature fires once
    # in a whole play-through), XORed with the music cue because the allocator can
    # hand back a reused pointer for a different room and a bare compare would then
    # read as "same room". Getting that wrong is silent, which is why it is copied.
    if ($ENABLE_TEX_DEFRAG -or $ENABLE_RELEVEL_KICK) {
        Add-Label $ovl 'AztRoomTick'
        A-Pushad $ovl
        if ($ENABLE_VIEW_INJECT) {
            # NOTHING WHILE THE BOOT OVERLAY OWNS THE VIEWPORT. The first room is loaded
            # and its frames exist well before the 16.9 s boot animation finishes, so the
            # room signature changes DURING the boot -- and tearing the 3D surfaces down
            # and rebuilding them underneath the animation is how the readouts were lost
            # at level 2. `aztInjEnable` is exactly "the boot is painting", so waiting for
            # it to clear costs two instructions and removes the whole interaction.
            A-CmpDwordSiImm $ovl 'aztInjEnable' 0
            A-Jnz $ovl 'ADF_out'
        }
        A-MovEaxDi    $ovl 0x152144             # the scene's reference frame handle
        A-TestEaxEax  $ovl
        A-Jz $ovl 'ADF_out'
        A-Call $ovl ([uint32]0x42410)           # -> the ROOT frame's handle
        A-TestEaxEax  $ovl
        A-Jz $ovl 'ADF_out'
        A-Call $ovl ([uint32]0x39E50)           # handle -> object
        A-TestEaxEax  $ovl
        A-Jz $ovl 'ADF_out'
        A-MovEbxEaxD8 $ovl 0x40                 # root's LAST child = room-specific
        A-TestEbxEbx  $ovl
        A-Jz $ovl 'ADF_out'                     # empty scene: nothing loaded yet
        A-MovEaxDi    $ovl 0x152AD0             # the music cue, as a second source
        A-XorEbxEax   $ovl
        A-CmpEbxSi    $ovl 'aztDefragSig'
        A-Jz $ovl 'ADF_out'                     # same room, nothing to do
        A-MovSiEbx32  $ovl 'aztDefragSig'
        # THE FIRST ROOM IS NOT DEFRAGGED. On the first signature there is nothing
        # in the cache to compact, and running a memmove over a freshly built arena
        # during the opening load would cost a stall for no benefit.
        A-CmpDwordSiImm $ovl 'aztDefragSeen' 0
        A-Jnz $ovl 'ADF_do'
        A-MovDwordSiImm $ovl 'aztDefragSeen' 1
        A-Jmp $ovl 'ADF_out'
        Add-Label $ovl 'ADF_do'
        if ($ENABLE_TEX_DEFRAG) {
            A-MovEaxDi   $ovl 0x162B74          # the IDataManager, as 0x1C8F4 reads it
            A-TestEaxEax $ovl
            A-Jz $ovl 'ADF_nodefrag'            # not built yet: the intro runs before it
            A-Call $ovl ([uint32]0x1C223)       # DefragTextureCache
            Add-Label $ovl 'ADF_nodefrag'
        }
        # ...then rebuild the 3D device, which is what actually recovers the frame
        # rate. AFTER the defrag, deliberately: compaction moves texture pixels and
        # rewrites owner pointers, so it should finish before anything else touches
        # the renderer.
        if ($ENABLE_RELEVEL_KICK) { A-Call $ovl 'AztRelevelKick' }
        A-IncDwordSi $ovl 'aztDefragCount'      # readable over the bridge, to prove it fired
        Add-Label $ovl 'ADF_out'
        A-Popad $ovl
        A-Ret   $ovl

        Add-Label $ovl 'aztDefragSig';   A-Dd $ovl 0   # last room signature
        Add-Label $ovl 'aztDefragSeen';  A-Dd $ovl 0   # a first room has been seen
        Add-Label $ovl 'aztDefragCount'; A-Dd $ovl 0   # how many compactions have run
    }

    # ---- AztRelevelKick: Josh's 1-2-1, done for him --------------------------
    # See the $ENABLE_RELEVEL_KICK note for why this works and what it is really
    # changing. Reads the CURRENT level rather than assuming 1, so it ends on
    # whatever level is actually in force and cannot strand the player at a
    # resolution they did not choose.
    #
    # SetRenderLevel pushes and pops ebx/ecx/edx/esi/edi/ebp itself, so ebx
    # survives the first call and still holds the level to go back to -- and our
    # esi/edi deltas survive too. The pushad is belt and braces.
    if ($ENABLE_RELEVEL_KICK) {
        Add-Label $ovl 'AztRelevelKick'
        A-Pushad $ovl
        if ($RENDER_SCALE -eq 0) {
            # FOLLOW THE PLAYER. Read the level in force and come back to it, so a
            # level chosen with the 1/2/3/4 keys is not silently overridden on the
            # next room change.
            A-Db $ovl @(0x0F,0xB7,0x9F)         # movzx ebx, word [edi+d32]
            Add-Abs32 $ovl ([uint32]0x14686C)   #   ebx = the current render level
            A-TestEbxEbx $ovl
            A-Jz $ovl 'ARK_out'                 # never set: the device is not up yet
            A-MovEaxImm $ovl 1                  # temp level = 1 ...
            A-Db $ovl @(0x83,0xFB,0x01)         # cmp ebx, 1
            A-Jnz $ovl 'ARK_go'
            A-MovEaxImm $ovl 2                  # ... unless we are already on 1
            Add-Label $ovl 'ARK_go'
            A-Call $ovl ([uint32]0x10FEC)       # away from the current level
            A-Db $ovl @(0x89,0xD8)              # mov eax, ebx
            A-Call $ovl ([uint32]0x10FEC)       # ...and straight back to it
        } else {
            # FORCE A LEVEL. Still a round trip, because SetRenderLevel early-outs
            # when the requested level already matches `word [0x14686C]` -- going
            # straight to the target would do nothing at all on the second and every
            # later room change, and the rebuild is the half that recovers the frame
            # rate. So bounce off the other level first, then land on the target.
            A-MovEaxImm $ovl ([uint32]$(if ($RENDER_SCALE -eq 1) { 2 } else { 1 }))
            A-Call $ovl ([uint32]0x10FEC)       # the bounce, so the rebuild happens
            A-MovEaxImm $ovl ([uint32]$RENDER_SCALE)
            A-Call $ovl ([uint32]0x10FEC)       # ...and land on the wanted level
        }
        Add-Label $ovl 'ARK_out'
        A-Popad $ovl
        A-Ret   $ovl
    }

    # ---- moved out of the clock blob, unchanged ----------------------------
    # Same code as before, same absolute calls into the real caves. See the
    # comments at their patch sites for what each one is for.
    Add-Label $ovl 'AztAnimStep'
    A-Call $ovl $tAsm.Labels['AztAnimGate']
    A-JzS $ovl 'AAS_out'
    if ($ENABLE_NPC_PACE) {
        A-Call $ovl 'AztNpcStride'                    # ebx = the character: the NPC pace and its own share
        A-JzS $ovl 'AAS_out'
    }
    A-Db $ovl @(0x89,0xC2)                            # mov edx, eax
    A-Db $ovl @(0x42)                                 # inc edx
    A-Db $ovl @(0x66,0x89,0x93,0x84,0x02,0x00,0x00)   # mov word [ebx+0x284], dx
    Add-Label $ovl 'AAS_out'
    A-Ret $ovl

    Add-Label $ovl 'AztAnimAddEdx'
    A-Call $ovl $tAsm.Labels['AztAnimGate']
    A-JzS $ovl 'AAE_out'
    A-Db $ovl @(0xD9,0xE8)                            # fld1
    A-Db $ovl @(0xDB,0x42,0x04)                       # fild dword [edx+4]
    A-FaddpSt1 $ovl                                   # faddp st(1), st
    A-Call $ovl ([uint32]0x37A9E)
    A-Db $ovl @(0xDB,0x5A,0x04)                       # fistp dword [edx+4]
    Add-Label $ovl 'AAE_out'
    A-Ret $ovl

    Add-Label $ovl 'AztAnimAddEdxSt'
    A-Db $ovl @(0xDB,0x42,0x04)                       # fild dword [edx+4]  st0=x
    A-Db $ovl @(0xD9,0xC0)                            # fld st(0)           st0=x st1=x
    A-Call $ovl $tAsm.Labels['AztAnimGate']
    A-JzS $ovl 'AAES_out'
    A-Db $ovl @(0xD9,0xE8)                            # fld1
    A-FaddpSt1 $ovl                                   # faddp st(1), st     st0=x+1 st1=x
    Add-Label $ovl 'AAES_out'
    A-Ret $ovl

    # ---- the two fold-out volume sliders -----------------------------------
    # The draw sites are `push imm8 <Y> / add esi, imm32 <X>` -- eight bytes with
    # no fixups. The Y is an imm8, and the rebuilt panel sits far enough down the
    # viewport that its sliders are past 127, so the push has to be re-issued at
    # full width. There is no room in place, hence a trampoline; this is what the
    # BSS overlay is for.
    #
    # A JMP, not a call: the push is an ARGUMENT for the blit that follows, so
    # the stack must be exactly as the game left it. Jumping back to the byte
    # after the replaced range keeps that true.
    for ($sl = 0; $sl -lt 2; $sl++) {
        Add-Label $ovl ("AztSlider{0}" -f $sl)
        A-PushImm32 $ovl ([uint32]($SYSMENU_VY + $SYSMENU_SLIDER_LY[$sl]))
        A-AddEsiImm32 $ovl ([uint32]($SYSMENU_VX + $SYSMENU_SLIDER_LX))
        A-Jmp $ovl ([uint32]@(0x14E70, 0x14ED1)[$sl])
    }

    # volume -> fill pixels. Stock is `imul edx,edx,87 / mov ebx,127 / ... idiv`,
    # and only the 87 changes -- but it is an imm8 and 174 is not, so the whole
    # 15-byte block comes here and is re-issued with an imm32.
    for ($sl = 0; $sl -lt 2; $sl++) {
        Add-Label $ovl ("AztSliderPx{0}" -f $sl)
        A-Db $ovl @(0x69,0xD2); A-Db $ovl ([byte[]][BitConverter]::GetBytes([uint32]$SYSMENU_SLIDER_W))  # imul edx,edx,W
        A-MovEbxImm $ovl ([uint32]0x7F)                 # mov ebx,127 -- the volume range, unchanged
        A-Db $ovl @(0x89,0xD0)                          # mov eax,edx
        A-Db $ovl @(0xC1,0xFA,0x1F)                     # sar edx,31
        A-Db $ovl @(0xF7,0xFB)                          # idiv ebx
        A-Jmp $ovl ([uint32]@(0x14E43, 0x14EA0)[$sl])
    }

    # The upper clamp. `cmp eax,87 / jle` is five bytes and `cmp eax,imm32 / jle`
    # is seven, so the test moves here; the clamp STORE stays in place, because
    # it writes its value as an imm16 which 174 fits.
    for ($sl = 0; $sl -lt 2; $sl++) {
        Add-Label $ovl ("AztSliderClamp{0}" -f $sl)
        A-CmpEaxImm $ovl ([uint32]$SYSMENU_SLIDER_W)
        A-Jle $ovl ([uint32]@(0x14D5E, 0x14DF1)[$sl])   # in range: skip the store
        A-Jmp $ovl ([uint32]@(0x14D55, 0x14DE8)[$sl])   # too big: clamp it
    }

    Add-Label $ovl 'AztSkipKey'
    A-Db $ovl @(0x83,0xF8,0x20)                # cmp eax, ' '
    A-JzS $ovl 'ASK_hit'
    A-Db $ovl @(0x83,0xF8,0x1B)                # cmp eax, ESC -- kept, it was the stock key
    A-JzS $ovl 'ASK_hit'
    A-Jmp $ovl ([uint32]0x12F2F)               # not ours: swallow it as before
    Add-Label $ovl 'ASK_hit'
    A-Jmp $ovl ([uint32]0x12D67)               # call 0x17C08 and carry on

    # ---- FPS LOG -- the headroom measurement -------------------------------
    #
    # Writes ONE 16-BIT FRAME COUNT PER SECOND to AZTFPS.LOG, rather than drawing
    # a number on the HUD. A file is far less code than digit conversion plus a
    # DrawString into the view surface, it cannot corrupt what is on screen, and it
    # gives a per-second TIME SERIES to analyse instead of a figure someone has to
    # read off a moving picture. Decode with:
    #
    #     $b = [IO.File]::ReadAllBytes('...\AZTFPS.LOG')
    #     0..($b.Count/2 - 1) | ForEach-Object { [BitConverter]::ToUInt16($b, $_*2) }
    #
    # To measure the machine's CEILING rather than the cap, raise the cap first
    # with Set-FrameCap.ps1 -- at 48 fps a healthy log just reads 48 all the way
    # down and tells you only that there is SOME headroom, not how much.
    # NO LONG-LIVED HANDLE ANY MORE -- see AztFpsWrite. This only truncates the file
    # so each run starts clean, then closes it again immediately. Keeping it open was
    # the design that produced a 0-byte log, and it also leaked a DOS handle for the
    # whole session.
    Add-Label $ovl 'AztFpsInit'
    if ($ENABLE_FPS_LOG) {
        A-XorEcxEcx $ovl                       # CX = attributes (normal)
        A-MovAhImm  $ovl 0x3C                  # create/truncate
        A-LeaEdxSi  $ovl 'aztFpsName'
        A-Int       $ovl 0x21
        A-JbS       $ovl 'AFI_out'
        A-MovBxAx   $ovl
        A-MovAhImm  $ovl 0x3E                  # close: the write path reopens per sample
        A-Int       $ovl 0x21
        Add-Label $ovl 'AFI_out'
    }
    A-Ret $ovl

    # ebx = now (microseconds) on entry -- AztFrameLimit has it live at the call.
    # eax/ebx/ecx/edx are all dead in the caller by then, esi is read-only here.
    Add-Label $ovl 'AztFpsTick'
    if ($ENABLE_FPS_LOG) {
        A-MovSiEbx32 $ovl 'aztFpsNow'          # stash it: ebx is needed for the handle
        A-MovEcxImm  $ovl 1
        A-AddSiEcx   $ovl 'aztFpsCount'        # one more frame

        # ---- FIRST-CALL MARKER, and why it is worth a whole DOS write ----------
        # A run came back with AZTFPS.LOG present but ZERO BYTES. The file's mere
        # existence proves only that AztFpsInit ran, and AztFpsInit is reached from
        # the EARLY hook at 0x16146 -- not from the frame chain. So an empty log is
        # equally consistent with two very different faults: the per-frame chain
        # never running, or it running and every DOS write failing. Nothing on disk
        # could tell them apart, and the two need opposite fixes.
        #
        # One 0xFFFF word written the first time this routine is entered settles it.
        # Phase 3 is impossible (there are only three), so 0xFFFF cannot be mistaken
        # for a sample, and Read-Perf names it. ebx is still `now` here and the write
        # clobbers it, hence the push.
        A-CmpDwordSiImm $ovl 'aztFpsSeen' 0
        A-JnzS $ovl 'AFT_marked'
        A-MovDwordSiImm $ovl 'aztFpsSeen' 1
        A-MovWordSiImm $ovl 'aztFpsValue' 0xFFFF
        A-PushEbx $ovl
        A-Call $ovl 'AztFpsWrite'
        A-PopEbx $ovl
        Add-Label $ovl 'AFT_marked'

        A-MovEaxSi   $ovl 'aztFpsWinStart'
        A-TestEaxEax $ovl
        A-JnzS       $ovl 'AFT_have'
        A-MovSiEbx32 $ovl 'aztFpsWinStart'     # first frame ever: open the window
        A-JmpS       $ovl 'AFT_out'
        Add-Label $ovl 'AFT_have'

        A-MovEbxSi   $ovl 'aztFpsWinStart'
        A-MovEaxSi   $ovl 'aztFpsNow'
        A-SubEaxEbx  $ovl                      # eax = elapsed (unsigned)
        A-CmpEaxImm  $ovl 1000000
        A-JbS        $ovl 'AFT_out'

        # A whole second. ADVANCE the window by exactly one second rather than
        # setting it to now, for the same reason the animation gate does: setting
        # it to now quantises the sample period to the frame time. Bound the debt
        # so a loading screen cannot be followed by a burst of junk samples.
        A-MovEcxImm  $ovl 1000000
        A-AddSiEcx   $ovl 'aztFpsWinStart'
        A-CmpEaxImm  $ovl 3000000
        A-JbeS       $ovl 'AFT_nosnap'
        A-MovEbxSi   $ovl 'aztFpsNow'
        A-MovSiEbx32 $ovl 'aztFpsWinStart'     # stalled: snap, drop the arrears
        Add-Label $ovl 'AFT_nosnap'

        A-MovAxSi    $ovl 'aztFpsCount'        # publish the low 16 bits
        # A CALL, NOT INLINE. Inlining the ~30 bytes of bit-packing here pushed
        # AFT_out 161 bytes from the short branches above it and the assembler
        # refused the build -- which is the guard working as designed. Out of line
        # it costs five bytes in the hot path and the branches stay in rel8 range.
        if ($ENABLE_FPS_TAGS) { A-Call $ovl 'AztFpsTag' }
        A-MovSiAx    $ovl 'aztFpsValue'
        A-MovDwordSiImm $ovl 'aztFpsCount' 0
        A-Call $ovl 'AztFpsWrite'
        Add-Label $ovl 'AFT_out'
    }
    A-Ret $ovl

    # ---- AztFpsWrite: OPEN, APPEND, WRITE, CLOSE -- every single sample --------
    #
    # WHY SO BLUNT. The previous design held one handle, created before the intro,
    # for the whole session, wrote 2 bytes a second into it and never closed it --
    # relying on INT 21h AH=68h (commit) to get the bytes onto disk. It produced a
    # log that was PRESENT AND 0 BYTES while the frame chain was provably running:
    # the boot animation played, the frame cap held, and the A/B phases cycled on
    # screen, so AztFpsTick was certainly being entered 20+ times a second.
    #
    # That leaves only the file I/O, and a long-lived handle has several ways to
    # die quietly that none of this code can see: the game opens hundreds of files
    # of its own, and a buffered write that is never closed is at the mercy of
    # whether AH=68h does anything at all on this host.
    #
    # Opening and closing per sample removes the entire class. A close is the one
    # operation guaranteed to flush, the handle cannot go stale because it does not
    # outlive the call, and it costs four INT 21h calls ONCE A SECOND -- against a
    # frame budget of ~40 ms, unmeasurable. Robustness beats elegance when the
    # elegant version returns no data.
    #
    # The file is opened (AH=3Dh) and SEEKED TO END (AH=42h), never created here --
    # a create would truncate and the log would only ever hold its last second.
    # AztFpsInit does the one truncation, at startup. If the open fails the file is
    # missing, so it is created as a fallback.
    #
    # `pop` does not touch the flags, which is what lets the handle be restored
    # between the write and its CF test.
    Add-Label $ovl 'AztFpsWrite'
    if ($ENABLE_FPS_LOG) {
        A-MovAlImm  $ovl 1                     # open for WRITE
        A-MovAhImm  $ovl 0x3D
        A-LeaEdxSi  $ovl 'aztFpsName'
        A-Int       $ovl 0x21
        A-JbS       $ovl 'AFW_create'
        Add-Label $ovl 'AFW_have'
        A-MovBxAx   $ovl                       # bx = handle, for every call below
        A-PushEbx   $ovl
        A-XorEcxEcx $ovl
        A-XorEdxEdx $ovl
        A-MovAxImm16 $ovl 0x4202               # seek, relative to END, offset 0
        A-Int       $ovl 0x21
        A-PopEbx    $ovl
        A-PushEbx   $ovl
        A-MovAhImm  $ovl 0x40                  # write the sample
        A-MovEcxImm $ovl 2
        A-LeaEdxSi  $ovl 'aztFpsValue'
        A-Int       $ovl 0x21
        A-PopEbx    $ovl
        A-JbS       $ovl 'AFW_close'
        A-IncDwordSi $ovl 'aztFpsWrites'
        Add-Label $ovl 'AFW_close'
        A-MovAhImm  $ovl 0x3E                  # close -- this is the flush
        A-Int       $ovl 0x21
        A-Ret $ovl

        Add-Label $ovl 'AFW_create'
        A-IncDwordSi $ovl 'aztFpsFails'        # the open failed: file missing?
        A-XorEcxEcx $ovl
        A-MovAhImm  $ovl 0x3C
        A-LeaEdxSi  $ovl 'aztFpsName'
        A-Int       $ovl 0x21
        A-JbS       $ovl 'AFW_out'             # cannot create either: give up quietly
        A-IncDwordSi $ovl 'aztFpsOpens'
        A-JmpS      $ovl 'AFW_have'
        Add-Label $ovl 'AFW_out'
    }
    A-Ret $ovl

    if ($ENABLE_FPS_LOG) {
        Add-Label $ovl 'aztFpsSeen';     A-Dd $ovl 0   # AztFpsTick has been entered
        Add-Label $ovl 'aztFpsWrites';   A-Dd $ovl 0   # samples committed to disk
        Add-Label $ovl 'aztFpsOpens';    A-Dd $ovl 0   # had to create the file
        Add-Label $ovl 'aztFpsFails';    A-Dd $ovl 0   # opens that failed
        Add-Label $ovl 'aztFpsName';     A-Asciiz $ovl $FPS_LOG_NAME
        Add-Label $ovl 'aztFpsHandle';   A-Dw $ovl 0
        Add-Label $ovl 'aztFpsValue';    A-Dw $ovl 0
        Add-Label $ovl 'aztFpsCount';    A-Dd $ovl 0
        Add-Label $ovl 'aztFpsWinStart'; A-Dd $ovl 0
        Add-Label $ovl 'aztFpsNow';      A-Dd $ovl 0
    }

    # ---- the tagged FPS sample ------------------------------------------------
    # ax = the second's frame count on entry, ax = the tagged word on exit. Reads
    # edx only, so AztFpsTick's esi/edi contract is untouched. See $ENABLE_FPS_TAGS
    # for the bit layout.
    if ($ENABLE_FPS_TAGS) {
        Add-Label $ovl 'AztFpsTag'
        # CLAMP, DO NOT MASK. With the cap lifted in the measurement phases the frame
        # count is no longer bounded by 24 and a logic-only frame could plausibly run
        # into the thousands. `and ax,0x0FFF` on 4100 yields 4 -- a wrap that reads as
        # a catastrophic slowdown instead of an overflow, and nothing would say so.
        # 4095 as a ceiling is self-evidently a clamp when it appears.
        A-CmpAxImm16 $ovl 0x0FFF
        A-JbeS $ovl 'AFG_fits'
        A-MovAxImm16 $ovl 0x0FFF
        Add-Label $ovl 'AFG_fits'
        A-AndAxImm $ovl 0x0FFF
        A-MovzxEdxWordDi $ovl $g_renderLevel
        # 0 means the level has not been set yet -- the intro runs before it. Count
        # that as level 1 rather than letting `dec` wrap it round to 3 and report a
        # level the player never chose.
        A-TestEdxEdx $ovl
        A-JnzS $ovl 'AFG_lvlok'
        A-IncEdx $ovl
        Add-Label $ovl 'AFG_lvlok'
        A-DecEdx $ovl
        A-AndEdxImm8 $ovl 3
        A-ShlEdxImm $ovl 12
        A-OrAxDx $ovl
        A-MovEdxSi $ovl 'aztSup3D'
        A-AndEdxImm8 $ovl 3
        A-ShlEdxImm $ovl 14
        A-OrAxDx $ovl
        A-Ret $ovl
    }

    if ($ENABLE_HOST_RENDER) {
        # AztSupGate replaces `call 0x3F1B0` at 0x14187 -- the scene pass, 95.6% of the
        # frame. Skipped once the host sets aztSup3D >= 1.
        #
        # THE TAIL-CALL RULE. The draw path must JMP, never call-then-ret: our return
        # address would otherwise sit on top of the caller's stack arguments and shift
        # every one of them by 4, which is exactly how the intro movie hung the first
        # time injection was built ([[azrael-view-injection]]).
        #
        # The decision is made while esi still holds the delta, and each path restores
        # and then acts -- popfd would destroy the flags a branch after it would need.
        Add-Label $ovl 'AztSupGate'
        A-Pushfd $ovl
        A-Pushad $ovl
        A-CallNext $ovl
        Add-Label $ovl 'ASG_ref'
        A-PopEax $ovl
        A-SubEaxImm $ovl 'ASG_ref'
        A-MovEsiEax $ovl                       # esi = obj1 delta, position-independent
        A-CmpDwordSiImm $ovl 'aztSup3D' 1
        A-JbS $ovl 'ASG_draw'
        A-IncDwordSi $ovl 'aztSupSkips'
        A-Popad $ovl
        A-Popfd $ovl
        A-Ret $ovl                             # caller-pops: 0x3F1B0 ends in a plain ret
        Add-Label $ovl 'ASG_draw'
        A-IncDwordSi $ovl 'aztSupDraws'
        A-Popad $ovl
        A-Popfd $ovl
        A-Jmp $ovl ([uint32]0x3F1B0)

        # AztClrGate replaces `call 0x3F0D0` at 0x14182 -- the viewport clear, measured
        # at 0.3% of the frame. Skipped once the host sets aztSup3D >= 2, which it
        # should: with the host painting every pixel there is nothing to clear, and a
        # clear would race the injected frame.
        #
        # ITS SKIP PATH RETURNS WITH `ret 4`, NOT `ret`. 0x3F0D0 is callee-pops: the
        # site pushes one argument at 0x1417A and all three of the function's exits
        # are `ret 0x4`. A plain ret here would leave esp 4 low and the game would die
        # on the first frame -- the 0x34C40 lesson from the status-gauge work.
        Add-Label $ovl 'AztClrGate'
        A-Pushfd $ovl
        A-Pushad $ovl
        A-CallNext $ovl
        Add-Label $ovl 'ACG_ref'
        A-PopEax $ovl
        A-SubEaxImm $ovl 'ACG_ref'
        A-MovEsiEax $ovl
        A-CmpDwordSiImm $ovl 'aztSup3D' 2
        A-JbS $ovl 'ACG_draw'
        A-IncDwordSi $ovl 'aztSupClrSkips'
        A-Popad $ovl
        A-Popfd $ovl
        A-RetImm $ovl 4
        Add-Label $ovl 'ACG_draw'
        A-Popad $ovl
        A-Popfd $ovl
        A-Jmp $ovl ([uint32]0x3F0D0)

        # THE HOST WRITES THIS. 0 = draw as normal (shipped), 1 = skip the scene pass,
        # 2 = skip the clear too. Nothing in the guest ever changes it, so there is no
        # way for the game to strand itself without a picture: if the host dies mid-run
        # the viewport freezes, and the next launch starts at 0 again.
        Add-Label $ovl 'aztSup3D';       A-Dd $ovl 0
        Add-Label $ovl 'aztSupSkips';    A-Dd $ovl 0   # scene passes suppressed
        Add-Label $ovl 'aztSupDraws';    A-Dd $ovl 0   # scene passes allowed
        Add-Label $ovl 'aztSupClrSkips'; A-Dd $ovl 0   # clears suppressed
    }

    # ---- the three internal gates; see $ENABLE_SCENE_SPLIT ------------------
    # One stub each, all reading one host-written bitmask, so any combination can be
    # tried from the host without a rebuild. Each is a plain tail call when its bit is
    # clear, so with aztSceneParts = 0 the game is byte-for-byte unchanged.
    if ($ENABLE_SCENE_SPLIT) {
        $sceneParts = @(
            # Parts 0 (0x5B7F0, the move pass) and 1 (0x39C14) had their own stubs and call-site
            # hooks for the original three-way experiment. Nothing has set their bits since, and
            # their ~75 bytes were needed for AztVelGate below, so both sites are stock again.
            @{ Lbl = 'AztScenePart2'; Target = 0x5B820; Bit = 4; ZeroAl = $true  }
        )
        foreach ($sp in $sceneParts) {
            Add-Label $ovl $sp.Lbl
            A-Pushfd $ovl
            A-Pushad $ovl
            A-Call $ovl $asm.Labels['AztDeltas']   # esi = obj1 delta, edi = obj2 delta (the refresh reads obj2)
            A-MovEaxSi $ovl 'aztSceneParts'
            A-AndEaxImm $ovl ([uint32]$sp.Bit)
            A-TestEaxEax $ovl
            A-JzS $ovl ($sp.Lbl + '_run')
            # Only part 2's skip count is read by anything (Start-HostRender.ps1); the other
            # two counters were 20 bytes of an overlay with one byte left, and went to pay
            # for the player exemption above.
            if ($sp.Bit -eq 4) { A-IncDwordSi $ovl ($sp.Lbl + '_skips') }
            if ($sp.ZeroAl) {
                # ---- KEEP THE WORLD-MATRIX CACHE FRESH WHILE NOTHING IS DRAWN -----------
                # frame+0x90 (the world matrix) is a cache the engine refreshes when it is
                # about to draw a frame. Skipping the draw therefore lets it go stale while
                # animation keeps rewriting the locals -- MEASURED live: a dead Raptor's
                # root bone cached 18.7 units from where its local put it, dirty flag set.
                # The host no longer reads the cache, but the ENGINE still does: the cursor
                # pick at 0x116E4 walks these same matrices, so with a stale cache the
                # pointer lands on where a character or a door USED to be.
                #
                # 0x552C4 is the engine's own "refresh every dirty frame under this one":
                # a clean frame recurses into its children, a dirty one goes to the
                # propagator 0x55378. It is entered at 0x552D2 -- past its test of the
                # frame's own dirty byte -- because the top of the tree, [0x147ED8], is not
                # a real frame (zero matrix rows, NaN in its "world") and must never be
                # handed to the propagator itself. 0x552C4 opens with `push edx` and ends
                # `pop edx / ret`, hence the push before the jump. Registers are free here:
                # this sits inside the stub's pushad, and edi is obj2's delta from AztDeltas.
                # (It used to be esi + 0x1000 -- "obj2 lies one page past obj1" -- which stopped
                # being true when obj1 grew past obj2's linked base; see $OBJ1_VSIZE.)
                Add-Bytes $ovl @(0x8B,0x87); Add-Abs32 $ovl ([uint32]0x147ED8)   # mov eax, [edi + root]
                A-Call $ovl ($sp.Lbl + '_refresh')     # the two-instruction thunk after this stub's ret
            }
            A-Popad $ovl
            A-Popfd $ovl
            if ($sp.ZeroAl) {
                # 0x5B820's caller does `test al,al` and branches into 0x32E60 on
                # non-zero. popad restores whatever eax held, so the skip path has to
                # clear it AFTER the restore -- clobbering flags here is harmless
                # because the very next instruction is that `test`.
                #
                # AND IT MUST WRITE BOTH OUTPUTS. THIS WAS THE HOST-RENDER CRASH, ALL OF IT.
                # 0x5B820 is called as (eax = &count, edx = &array) and fills both; its
                # caller 0x3F1B0 then loops `count` times over `array` and finally FREES
                # `array` (0x3F2D3: mov eax,[esp+4] / call 0x39C14). Returning al = 0
                # without touching them left both as whatever the stack last held, so on
                # every suppressed frame the engine walked a garbage list and then freed a
                # garbage pointer -- usually a block that was live or already free. That is
                # a double free per frame: the heap's counts going negative, free-list
                # links leading out of RAM (the 0x6400000 "allocations"), handles that stop
                # resolving, and a crash whose delay shrank as the frame rate rose (8-100 s
                # at 22 fps, 4 s at 50). 0x5B820 has this exact exit itself for "nothing to
                # draw" at 0x5B835: zero both and return 0. A zero count skips the loop and
                # 0x39C14 ignores a null pointer.
                A-Db $ovl @(0x83,0x20,0x00)           # and dword [eax], 0   -- count = 0
                A-Db $ovl @(0x83,0x22,0x00)           # and dword [edx], 0   -- array = null
                A-XorEaxEax $ovl
            }
            A-Ret $ovl
            if ($sp.ZeroAl) {
                # The thunk, parked after the ret so the skip path needs no jump round it
                # (the overlay had 37 bytes left; this and the move gate take 36 of them).
                Add-Label $ovl ($sp.Lbl + '_refresh')
                A-Db $ovl @(0x52)                         # push edx  -- what 0x552C4's own entry does
                A-Jmp $ovl ([uint32]0x552D2)              # ...its pop edx / ret returns to the stub
            }
            Add-Label $ovl ($sp.Lbl + '_run')
            A-Popad $ovl
            A-Popfd $ovl
            A-Jmp $ovl ([uint32]$sp.Target)
        }
        # THE HOST WRITES THIS. Bit 0 = skip 0x5B7F0, bit 1 = skip 0x39C14,
        # bit 2 = skip 0x5B820. Ships 0: nothing is skipped and play is unchanged.
        Add-Label $ovl 'aztSceneParts'; A-Dd $ovl 0
        foreach ($sp in $sceneParts) { if ($sp.Bit -eq 4) { Add-Label $ovl ($sp.Lbl + '_skips'); A-Dd $ovl 0 } }

        # ---- AztVelGate: built-in velocity and rotation on the CLOCK (aztSceneParts bit 3) ----
        # Reality Lab's per-object tick 0x551BC runs for every frame object on EVERY RENDERED
        # FRAME. After the move callbacks it does, with no clock anywhere:
        #
        #     0x551FE  cmp byte [obj+0x45],0 / jz 0x5521A     rotation: [+0x120] += [+0x124]
        #     0x5521A  cmp byte [obj+0x46],0 / jz 0x5525F     velocity: position += [+0x128..]
        #
        # The game drives doors, scripted moves and walking characters through these two
        # (setters 0x49D30 / 0x55450), so they run at the frame rate -- about ten times too
        # fast once the host renderer took the frame cap off.
        #
        # THE FIRST ATTEMPT GATED THE WHOLE PASS, AND CRAWLED THE PLAYER. The player's movement
        # is a move CALLBACK, so it runs inside the pass too, stepping by a distance sized for
        # the real frame rate; held to 18 Hz it covered a twentieth of the ground. An exemption
        # by root handle could not work either: read live, the movement frame is not a root
        # child but sits inside the main scene object. So the gate is HERE instead, after the
        # callbacks have already run: only the velocity and rotation steps wait for the
        # 18.2 Hz animation tick, and nothing the player does goes through them.
        #
        # eax is free at this point (the callback loop has finished with it and 0x5525F
        # reloads it), ebx is the object and must survive, flags are dead. Reached by a JMP
        # from 0x551FE, so every exit is a jump back into 0x551BC.
        # ---- AztGateHold: "is this a frame the clock-gated things must sit out?" -----------
        # ONE COPY, three users (velocity, door stepper, gravity). Returns ZF = 1 to HOLD:
        # the host has asked for gating (aztSceneParts bit 3) and this frame is not on the
        # 18.2 Hz animation tick. ZF = 0 otherwise. Every register is preserved; pop does
        # not touch flags, and `test esp,esp` clears ZF because esp is never zero.
        # (Each gate used to carry these 30 bytes itself; sharing them is what paid for
        # the gravity gate in an overlay with 31 bytes left.)
        Add-Label $ovl 'AztGateHold'
        A-PushEax $ovl
        A-CallNext $ovl
        Add-Label $ovl 'AGH_ref'
        A-PopEax $ovl
        A-SubEaxImm $ovl 'AGH_ref'                                                           # eax = obj1 delta
        Add-Bytes $ovl @(0xF6,0x80); Add-Abs32 $ovl 'aztSceneParts'; Add-Bytes $ovl @(0x08)   # test byte [eax+aztSceneParts], 8
        A-JzS $ovl 'AGH_run'                                                                 # host has not asked: never hold
        Add-Bytes $ovl @(0x66,0x83,0xB8); Add-Abs32 $ovl $tAsm.Labels['aztAnimDue']; Add-Bytes $ovl @(0x00)   # cmp word [eax+aztAnimDue], 0  -> ZF = not due
        A-PopEax $ovl
        A-Ret $ovl
        Add-Label $ovl 'AGH_run'
        A-Db $ovl @(0x85,0xE4)                                                               # test esp, esp  -> ZF = 0
        A-PopEax $ovl
        A-Ret $ovl

        Add-Label $ovl 'AztVelGate'
        A-Call $ovl 'AztGateHold'
        A-JzS $ovl 'AVG_hold'                                                                # not a tick frame: skip both steps
        A-Db $ovl @(0x80,0x7B,0x45,0x00)                                                     # cmp byte [ebx+0x45], 0   -- displaced
        A-Jz  $ovl ([uint32]0x5521A)                                                         # displaced jz
        A-Jmp $ovl ([uint32]0x55204)
        Add-Label $ovl 'AVG_hold'
        A-Jmp $ovl ([uint32]0x5525F)

        # ---- AztEventGate: DOORS. The event scripts and their queued rotations, on the clock ----
        # MEASURED, step by step, from the host: a door turns a fixed 6 or 10 degrees on EVERY
        # RENDERED FRAME until it has opened -- 90 degrees in 15 frames. At the game's own
        # ~18 fps that is most of a second; with the host renderer's cap off it is 58 ms, and
        # the wait before it swings shut is counted in frames too. "They open nearly instantly."
        #
        # It is none of the things gated before (not Reality Lab's built-in rotation -- that
        # flag is off on every door -- and not keyframes). The frame loop has one call for it:
        #
        #     0x148ED  cmp word [0x1525F2],0 / jnz
        #     0x148F7  call 0x2D470
        #
        # and 0x2D470 is `call 0x1CBD4` falling straight into 0x2D478. 0x1CBD4 walks the queue
        # at [0x162B98] -- the nodes the script opcode at 0x2B11E allocates when a rotation is
        # to be spread over more than one step -- turning each object by its per-step angle
        # (word[+9] degrees x pi / 180, through 0x29F70) and counting the node down; 0x2D478
        # is the event-script interpreter those nodes belong to, waits and all. One call, once
        # a frame, no clock.
        #
        # So that one call runs only on the 18.2 Hz animation tick when the host asks for it
        # (the same aztSceneParts bit 3 as the velocity gate): the door turns its 6 degrees
        # 18 times a second, and the scripts' frame-counted waits last what they were written
        # to last. Skipped, nothing has happened at all -- 0x2D478 saves every register it
        # uses, and eax is put back here because the caller's next branch is not known to
        # ignore it. The player is not involved: movement is a move callback.
        #
        # CORRECTED 2026-10-05: THE GATE IS ON 0x1CBD4 ALONE, at the call inside 0x2D470.
        # The first version replaced the frame loop's call at 0x148F7 and so held back
        # 0x2D478 as well -- and 0x2D478 is not an interpreter at all. It is the status
        # line: it formats the name of whatever is under the cursor ([0x146870]) and
        # "Holding : %s" and draws them, and nine other places call it. Drawn on one frame
        # in seven, the hover text flickered out, which read as the cursor no longer
        # finding doors and items. 0x1CBD4 has exactly one caller (0x2D470), so gating it
        # there keeps the doors on the tick and leaves the status line on every frame.
        Add-Label $ovl 'AztEventGate'
        A-Call $ovl 'AztGateHold'
        A-JzS $ovl 'AEG_hold'
        A-Jmp $ovl ([uint32]0x1CBD4)                                                         # tail call: its ret goes back to 0x2D475
        Add-Label $ovl 'AEG_hold'
        A-Ret $ovl

        # ---- AztFallGate: GRAVITY ON THE CLOCK ------------------------------------------------
        # The ground test 0x11E68 ends by deciding whether the player is standing or falling:
        #
        #     0x12283  fild dword [esp+0x8C]      ; v + 15      (v = word [0x152592], fall speed)
        #     0x1228A  fcompp / fnstsw ax / sahf  ; against  eye - (floor + 45)
        #     0x1228F  jbe 0x122F4                ; FALLING:  eye -= v ;  v += 6
        #     0x12291  ...                        ; standing: eye = floor + 45, damage if v > 60
        #
        # Once per FRAME, no clock. At the game's own ~18 fps a floor that is missing for one
        # frame costs nothing -- the first falling frame moves the eye by v = 0 -- and the next
        # frame stands the player back up. With the host renderer the same 55 ms is sixteen
        # frames: the eye drops 0+6+12+18... and after four of them it is more than 23 units
        # down, which is further than the test will ever reach back UP for a floor. The player
        # is then under the room for good, standing on the catch plane `Object03`, where no
        # exit trigger can be touched and the walls are somewhere overhead. MEASURED: back into
        # the corridor from the spa, one step, eye -38.8 -> -74.8 -> -95.5, with the floor it
        # fell past (tunnel03 at -83.8) still in the test's own hit list.
        #
        # So the falling step runs only on the animation tick when the host asks for gating,
        # exactly like the velocity and door gates: gravity has the timing it was written for,
        # and a one-tick gap is harmless again. On a held frame nothing moves and v is kept.
        # Standing is never held.
        #
        # Reached by a CALL that replaces the 7-byte fild (esp-relative, no fixup; the falling
        # block itself has three fixed-up operands and cannot be touched). The return address
        # is dropped into eax, which the original clobbers with fnstsw two instructions later
        # and reloads before its next use on both paths; every exit is a jump back in.
        Add-Label $ovl 'AztFallGate'
        A-PopEax $ovl                                                                        # drop the return address: esp is the original's again
        A-Db $ovl @(0xDB,0x84,0x24,0x8C,0x00,0x00,0x00)                                      # fild dword [esp+0x8C]   -- displaced
        A-Db $ovl @(0xDE,0xD9, 0xDF,0xE0, 0x9E)                                              # fcompp / fnstsw ax / sahf  -- the original's own test
        A-JbeS $ovl 'AFG_fall'
        A-Jmp $ovl ([uint32]0x12291)                                                         # standing: straight on
        Add-Label $ovl 'AFG_fall'
        A-Call $ovl 'AztGateHold'
        A-JzS $ovl 'AFG_hold'
        A-Jmp $ovl ([uint32]0x122F4)                                                         # a tick frame (or no gating): fall one step
        Add-Label $ovl 'AFG_hold'
        A-Jmp $ovl ([uint32]0x12320)                                                         # between ticks: stay exactly where we are
    }

    # ---- CAMERA TRANSFORM LOG (the §14 experiment) --------------------------
    #
    # PURELY OBSERVATIONAL. One fixed-size binary record per frame appended to
    # AZTCAM.LOG. Binary rather than text because formatting 32 floats without a
    # printf would be more stub code than the whole rest of this feature, and
    # because raw bits let Read-CamLog.ps1 see exactly what the engine holds --
    # no rounding introduced between the game and the analysis.
    #
    # Both candidate frames are logged, not just the likely one. The viewport's
    # camera ([0x152144]) and the frame the movement code drives ([0x162DE4]) are
    # DIFFERENT globals, and whether they are the same frame, parent and child, or
    # unrelated is exactly what this run decides. Logging both settles it in one
    # pass; logging one would only have produced another inference.
    Add-Label $ovl 'AztCamInit'
    if ($ENABLE_CAM_LOG) {
        A-MovEcxImm $ovl 0                     # CX = attributes (normal)
        A-MovAhImm  $ovl 0x3C                  # create/truncate
        A-LeaEdxSi  $ovl 'aztCamName'
        A-Int       $ovl 0x21
        A-JbS       $ovl 'ACI_out'             # CF: no log; the tick sees handle 0
        A-MovSiAx   $ovl 'aztCamHandle'
        Add-Label $ovl 'ACI_out'
    }
    A-Ret $ovl

    # eax = handle, ebp = destination. Fills, relative to ebp:
    #   +0x00 object   +0x04 type tag   +0x08 parent
    #   +0x0C world 4x4 (64)            +0x4C local 4x4 (64)
    # Object and type are zeroed first, so a handle that fails to resolve shows up
    # in the log as zeros rather than as a stale record that looks plausible.
    #
    # esi/edi are saved and restored because they carry the obj1/obj2 deltas that
    # every A-*Si / A-*Di form in this overlay is addressed through -- clobbering
    # them would leave the SECOND call in AztCamLog reading from nowhere.
    Add-Label $ovl 'AztCamSnap'
    if ($CAM_RECORD) {
        A-PushEsi $ovl
        A-PushEdi $ovl
        A-XorEbxEbx  $ovl
        A-MovEbpD8Ebx $ovl 0x00
        A-MovEbpD8Ebx $ovl 0x04
        A-MovEbpD8Ebx $ovl 0x08
        A-TestEaxEax $ovl
        A-JzS $ovl 'ACS_out'

        A-Call $ovl ([uint32]0x39E50)          # handle -> object; pure lookup
        A-MovEbpD8Eax $ovl 0x00
        A-TestEaxEax $ovl
        A-JzS $ovl 'ACS_out'                   # unknown handle: leave it zeroed

        A-MovEbxEaxD8 $ovl 0x18                # type tag (0x147EDC == frame)
        A-MovEbpD8Ebx $ovl 0x04
        A-MovEbxEaxD8 $ovl 0x30                # parent
        A-MovEbpD8Ebx $ovl 0x08

        A-PushDsPopEs $ovl                     # rep movsd writes through es
        A-LeaEsiEaxD32 $ovl 0x90               # world 4x4
        A-LeaEdiEbpD8  $ovl 0x0C
        A-MovEcxImm    $ovl 16
        A-RepMovsd     $ovl
        A-LeaEsiEaxD32 $ovl 0x4C               # local 4x4 (eax survives movsd)
        A-LeaEdiEbpD8  $ovl 0x4C
        A-MovEcxImm    $ovl 16
        A-RepMovsd     $ovl

        Add-Label $ovl 'ACS_out'
        A-PopEdi $ovl
        A-PopEsi $ovl
    }
    A-Ret $ovl

    # ebx = now (microseconds) on entry, same contract as AztFpsTick.
    Add-Label $ovl 'AztCamLog'
    if ($CAM_RECORD) {
        # THE HANDLE CHECK ONLY GUARDS THE FILE. In publish-only mode there is no file
        # and no handle, and bailing on a zero handle would skip the record fill too --
        # leaving the host reading a record that is never written.
        if ($ENABLE_CAM_LOG) {
            A-MovAxSi    $ovl 'aztCamHandle'
            A-TestAxAx   $ovl
            A-Jz         $ovl 'CAMT_out'       # create failed: log nothing
        }
        A-Pushad     $ovl

        A-MovSiEbx32 $ovl 'aztCamTime'
        A-MovEcxImm  $ovl 1
        A-AddSiEcx   $ovl 'aztCamFrameNo'

        A-MovEaxDi   $ovl 0x147ED8             # RL root sentinel
        A-MovSiEax32 $ovl 'aztCamRoot'
        # The deltas themselves. Every pointer the engine hands back is relocated,
        # so without these a logged type tag or frame pointer cannot be checked
        # against a linear address from the notes -- the first run read the frame
        # tag as 0x338EDC and there was no way to PROVE that was 0x147EDC+delta
        # rather than a different class that merely looked plausible.
        A-MovSiEsi32 $ovl 'aztCamDelta1'
        A-MovSiEdi32 $ovl 'aztCamDelta2'
        A-MovEaxDi   $ovl 0x162DC0             # the cached eye-height Y
        A-MovSiEax32 $ovl 'aztCamEyeY'
        A-MovEaxDi   $ovl 0x152AD0             # current music cue == room hint
        A-MovSiEax32 $ovl 'aztCamCue'

        A-MovEaxDi   $ovl 0x152144             # the viewport's camera frame
        A-MovSiEax32 $ovl 'aztCamIface'
        A-LeaEbpSi   $ovl 'aztCamObj'
        A-Call       $ovl 'AztCamSnap'

        A-MovEaxDi   $ovl 0x162DE4             # the frame movement drives
        A-MovSiEax32 $ovl 'aztMovIface'
        A-LeaEbpSi   $ovl 'aztMovObj'
        A-Call       $ovl 'AztCamSnap'

        # ---- the FILE, which publish-only mode does not want ------------------
        # A host renderer reads the record straight out of memory every frame. Writing
        # the same bytes to disk 400 times a second as well would put a DOS round trip
        # inside the frame loop -- the very loop whose timing is the thing being
        # improved.
        if ($ENABLE_CAM_LOG) {
            A-MovBxSi    $ovl 'aztCamHandle'
            A-MovAhImm   $ovl 0x40
            A-MovEcxImm  $ovl $CAM_REC_LEN
            A-LeaEdxSi   $ovl 'aztCamRec'
            A-Int        $ovl 0x21

            # Commit every 32 records rather than every one. The game never returns
            # through here to close the handle, so an unflushed run would be lost on
            # quit -- but committing 24 times a second would put a disk round trip
            # inside the frame loop and perturb the timing this log sits next to.
            A-MovEaxSi   $ovl 'aztCamFrameNo'
            A-AndEaxImm  $ovl 31
            A-TestEaxEax $ovl
            A-JnzS       $ovl 'CAMT_noflush'
            A-MovBxSi    $ovl 'aztCamHandle'
            A-MovAhImm   $ovl 0x68
            A-Int        $ovl 0x21
            Add-Label $ovl 'CAMT_noflush'
        }

        A-Popad $ovl
        Add-Label $ovl 'CAMT_out'
    }
    A-Ret $ovl

    # =========================================================================
    #  FULL-FRAME VIEW INJECTION -- the host draws the 3D viewport.
    #
    #  Proven with a 256x16 strip at two probe sites; 0x1419D and 0x141D2 both run
    #  once per frame (22/sec) and their pixels survive into the surface the engine
    #  blits. This is the same mechanism scaled to the whole 1024x576 viewport.
    #
    #  The staging buffer is a GUEST HEAP allocation, not BSS: a full frame is
    #  589,824 bytes and the BSS window is only 53,248. It is allocated once at load
    #  through the game's own allocator (0x32CE0: size in eax, pointer out in eax,
    #  preserves esi/edi), so it costs the texture cache 576 KB -- see the
    #  texture-cache-reserve notes if big rooms start failing to load.
    #
    #  The copy is ONE flat rep movsd because the surface stride (1024) equals the
    #  frame width, so there are no per-row gaps to step over.
    # =========================================================================
    if ($ENABLE_VIEW_INJECT) {

        # ---- allocate the staging buffer once, at overlay init ---------------
        Add-Label    $ovl 'AztInjInit'
        A-Pushad     $ovl
        A-MovEaxImm  $ovl ($INJ_W * $INJ_H)
        A-Call       $ovl ([uint32]0x32CE0)      # the game's own allocator
        A-MovSiEax32 $ovl 'aztInjBufPtr'         # 0 stays 0 if it failed; the body checks
        A-Popad      $ovl
        A-Ret        $ovl

        # ---- the copy -------------------------------------------------------
        Add-Label    $ovl 'AztInjBody'
        # EITHER FLAG ARMS THE COPY, BUT THEY MEAN DIFFERENT THINGS.
        #
        # aztInjEnable is the VISOR BOOT's flag, and two other places read it as exactly "the
        # boot is painting": AztRoomTick skips the texture defrag and the relevel kick while
        # it is set, and the reticle gate hides the reticle. The host renderer was setting
        # that same flag and holding it for an entire session, so the defrag never ran again.
        #
        # The texture cache is a fragmenting first-fit list. With the defrag suppressed it
        # fills, an allocation fails, and the fallback at 0x2876C PURGES -- freeing the
        # cache's companion buffers at [0x162B7C]/[0x162B84] while the renderer still holds
        # them. That is the documented use-after-free: garbage blits (the diagonal lines seen
        # early on), then a wild pointer, then "RAPTOR ERROR in Rendermorphics / object
        # expected in argument".
        #
        # It fitted every measurement available AT THE TIME: only ever while injecting;
        # unaffected by host CPU load, posing, the direction flag, split/roll state, and both
        # buffer sizes (all measured and cleared); and time-dependent rather than
        # deterministic, because it depends on how fast the cache fragments.
        #
        # IT IS NOT THE CAUSE OF THE REMAINING CRASH, and splitting the flag was still right.
        # $ENABLE_OOM_TRAP skips the purge entirely and reports the first failed allocation
        # through 0x334A0, so this path cannot run without "FreeMemory: No memory available"
        # reaching AZERR.TXT ahead of it. Live AZERR.TXT files from the crash carry the RAPTOR
        # error alone. No allocation failed, so nothing was purged and nothing was freed under
        # the renderer. See $ENABLE_RAPTOR_TRAP for what replaced this line of reasoning.
        #
        # aztHostInject is therefore its own flag, exactly as aztInjSync was split out of
        # aztSup3D for the same class of reason. The boot keeps aztInjEnable; the host uses
        # this one, and AztRoomTick keeps running.
        A-MovEbxSi   $ovl 'aztInjEnable'
        A-TestEbxEbx $ovl
        A-JnzS       $ovl 'AIB_armed'
        A-MovEbxSi   $ovl 'aztHostInject'
        A-TestEbxEbx $ovl
        A-Jz         $ovl 'AIB_done'
        Add-Label    $ovl 'AIB_armed'
        A-MovEbxSi   $ovl 'aztInjBufPtr'         # source; 0 = allocation failed
        A-TestEbxEbx $ovl
        A-Jz         $ovl 'AIB_done'
        A-MovEaxDi   $ovl ([uint32]0x163A34)     # destination: the shared surface
        A-TestEaxEax $ovl
        A-Jz         $ovl 'AIB_done'

        # ---- THE SYNC HANDSHAKE (Tier A, stage A2) --------------------------
        # MEASURED NEED, not a precaution. With the host writing the staging buffer
        # freely while this routine copies out of it, 4% of displayed rows came from
        # a different host frame at 60 host / 22 guest, and 91% unthrottled. A tear
        # line that moves every frame would survive any amount of renderer quality.
        #
        # One frame, one copy: the host fills the buffer, sets aztInjReady, then waits
        # for it to clear. We copy only when it is set and clear it when done, so the
        # host can never be writing the buffer we are reading.
        #
        # ONLY IN HOST-RENDER MODE. The visor boot fills this same buffer from guest
        # code and has no producer to set `ready`, so gating it unconditionally would
        # silently kill the boot animation. aztSup3D is exactly "the host owns the
        # viewport", so the boot path is untouched.
        if ($ENABLE_HOST_RENDER) {
            # KEYED ON ITS OWN FLAG, not on aztSup3D.
            #
            # It used to engage only when aztSup3D was set, on the assumption that
            # "the host suppressed the engine" and "the host wants a handshake" were
            # the same thing. They are not: the working configuration suppresses the
            # engine's RASTERISER through aztSceneParts and leaves aztSup3D at 0 --
            # under which the old condition silently disabled the handshake and put
            # the tearing straight back, with nothing to say so.
            #
            # A dedicated flag cannot drift like that, and the visor boot -- which
            # fills this same buffer from guest code and has no producer to set
            # `ready` -- never touches it.
            A-CmpDwordSiImm $ovl 'aztInjSync' 0
            A-JzS $ovl 'AIB_nogate'
            A-CmpDwordSiImm $ovl 'aztInjReady' 0
            A-JnzS $ovl 'AIB_nogate'
            # Nothing fresh. Leave the viewport holding the last frame -- which is the
            # right failure mode: a stale frame reads as a dropped frame, whereas
            # copying a half-written buffer reads as corruption.
            A-IncDwordSi $ovl 'aztInjStarve'
            A-Jmp $ovl 'AIB_done'
            Add-Label $ovl 'AIB_nogate'
        }
        # THE DELTA MUST SURVIVE THE COPY. esi becomes the copy source below, so by
        # AIB_copied it is a heap pointer, not the obj1 delta -- reading
        # [esi+aztInjReady] there would land over a megabyte into the staging buffer.
        # This is the esi-clobber trap that cost a first-frame freeze once already.
        A-PushEsi $ovl

        # SPLIT MODE: copy only rows [0,top) and [bot,H), leaving the middle band as the
        # engine rendered it. That is how the boot shutter opens -- the 3D is revealed by
        # copying LESS of our buffer, not by drawing the 3D into it. Reading the surface
        # back does not work: by the time we run, this very routine has already replaced
        # it with our own overlay, so the "3D" read back is just our amber.
        # aztInjTopDw and aztInjBotOff are read BEFORE esi becomes the copy source.
        A-CmpDwordSiImm $ovl 'aztInjSplit' 0
        A-Jz $ovl 'AIB_full'
        A-MovEcxSi $ovl 'aztInjTopDw'            # dwords in the upper panel
        A-MovEbpSi $ovl 'aztInjBotOff'           # byte offset of the lower panel
        A-Db $ovl @(0x50)                        # push eax  (surface)
        A-Db $ovl @(0x53)                        # push ebx  (buffer)
        A-MovEdiEax   $ovl
        A-MovEsiEbx   $ovl
        A-PushDsPopEs $ovl
        A-RepMovsd    $ovl                       # upper panel
        A-Db $ovl @(0x5B)                        # pop ebx
        A-Db $ovl @(0x58)                        # pop eax
        A-Db $ovl @(0x8D,0x3C,0x28)              # lea edi,[eax+ebp]
        A-Db $ovl @(0x8D,0x34,0x2B)              # lea esi,[ebx+ebp]
        A-MovEcxImm $ovl ([int]($INJ_W * $INJ_H / 4))
        A-Db $ovl @(0xC1,0xED,0x02)              # shr ebp, 2   -> botOff in dwords
        A-Db $ovl @(0x29,0xE9)                   # sub ecx, ebp -> dwords remaining
        A-RepMovsd    $ovl                       # lower panel
        A-JmpS $ovl 'AIB_copied'

        Add-Label $ovl 'AIB_full'
        # VERTICAL HOLD SLIP. aztInjRoll is a byte offset (always a whole number of rows,
        # so always dword-aligned); non-zero rolls the frame up by that much and wraps the
        # rows that fall off the top back onto the bottom.
        #
        # This is FREE. The copy is the same total number of dwords either way -- it is
        # split into two runs instead of one, and the only extra work is computing where
        # the split is. Rolling the 576 KB staging buffer in place would have been a real
        # memmove every slip frame; this is the same rep movsd it always was.
        #
        # READ BEFORE esi BECOMES THE COPY SOURCE, exactly as the split path above reads
        # its own variables. This was written after the mov and it froze the game on the
        # first slip: [esi+aztInjRoll] resolved against the staging buffer instead of the
        # obj1 delta, more than a megabyte past a 576 KB allocation, so the roll offset was
        # whatever happened to be there and rep movsd walked off into unmapped memory.
        A-MovEbpSi   $ovl 'aztInjRoll'
        A-MovEdiEax   $ovl
        A-MovEsiEbx   $ovl                       # esi = staging buffer, NOT the delta now
        A-PushDsPopEs $ovl
        A-TestEbpEbp $ovl
        A-JzS $ovl 'AIB_plain'
        # Belt and braces: a roll at or past the buffer length would make the first run's
        # length negative. It cannot happen from AztBootSlip, but this routine can no
        # longer see the variable's provenance, so it refuses anything out of range
        # instead of trusting it.
        A-Db $ovl @(0x81,0xFD)                   # cmp ebp, imm32
        A-Dd32 $ovl ([uint32]($INJ_W * $INJ_H))
        A-JaeS $ovl 'AIB_plain'
        A-Db $ovl @(0x01,0xEE)                   # add esi, ebp  -> start partway down
        A-MovEcxImm $ovl ([int]($INJ_W * $INJ_H / 4))
        A-Db $ovl @(0x89,0xE8)                   # mov eax, ebp
        A-Db $ovl @(0xC1,0xE8,0x02)              # shr eax, 2    -> roll in dwords
        A-Db $ovl @(0x29,0xC1)                   # sub ecx, eax  -> dwords in the first run
        A-RepMovsd $ovl                          # buffer[roll..end] -> surface[0..]
        A-MovEsiEbx $ovl                         # wrap: back to the top of the buffer
        A-Db $ovl @(0x89,0xE9)                   # mov ecx, ebp
        A-Db $ovl @(0xC1,0xE9,0x02)              # shr ecx, 2
        A-RepMovsd $ovl                          # buffer[0..roll] -> the rest of the surface
        A-JmpS $ovl 'AIB_copied'
        Add-Label $ovl 'AIB_plain'
        A-MovEcxImm   $ovl ([int]($INJ_W * $INJ_H / 4))
        A-RepMovsd    $ovl
        # falls through into AIB_copied -- every copy path converges here, and only the
        # copy paths do, which is what keeps the push/pop balanced. The early-outs above
        # jump straight to AIB_done because they ran before the push.
        Add-Label $ovl 'AIB_copied'
        A-PopEsi $ovl                            # esi is the obj1 delta again
        if ($ENABLE_HOST_RENDER) {
            A-MovDwordSiImm $ovl 'aztInjReady' 0 # consumed: the host may fill the next
            A-IncDwordSi $ovl 'aztInjShown'
        }
        Add-Label $ovl 'AIB_done'
        A-Ret     $ovl

        # ---- reticle calibration ---------------------------------------------
        # esi = obj1 delta, edi = obj2 delta, both live. Draws a square box closing in on
        # the viewport centre, straight into the shared surface.
        #
        # WHY THIS IS SAFE TO DRAW OVER THE 3D. It only runs after the shutter has opened
        # fully, and at full open the injection's split copy moves ZERO bytes -- top is 0
        # rows and the bottom panel starts past the end -- so the surface holds the engine's
        # own frame and nothing overwrites what is drawn here. It is called BEFORE
        # AztInjBody for exactly that reason: with nothing being copied the order does not
        # matter, and calling it first means the injection's esi lifetime is left alone.
        # That register lifetime is what froze the game when the hold slip went in.
        Add-Label $ovl 'AztBootCalib'
        A-Pushad $ovl
        A-CmpDwordSiImm $ovl 'aztBootState' 1
        A-Jnz $ovl 'ABK_out'                     # not during the boot: never draw
        A-MovEaxSi  $ovl 'aztBootEl'
        A-SubEaxImm $ovl $BOOT_CALIB_START
        A-CmpEaxImm $ovl ([int]$BOOT_CALIB_US)
        A-Jae $ovl 'ABK_out'                     # unsigned: also catches "not yet"
        # r = R0 - (R0-R1) * t / CALIB_US
        A-MovEcxImm $ovl ([int]($BOOT_CALIB_R0 - $BOOT_CALIB_R1))
        A-MulEcx    $ovl                         # < 2^32, so edx is 0 for the divide
        A-MovEcxImm $ovl ([int]$BOOT_CALIB_US)
        A-DivEcx    $ovl
        A-MovEbxImm $ovl ([int]$BOOT_CALIB_R0)
        A-Db $ovl @(0x29,0xC3)                   # sub ebx, eax   -> ebx = r
        A-MovEaxDi  $ovl ([uint32]0x163A34)      # the shared surface
        A-TestEaxEax $ovl
        A-Jz $ovl 'ABK_out'
        A-Db $ovl @(0x89,0xC5)                   # mov ebp, eax   -- the surface base

        # edx = the box's top-left byte offset = (cy-r)*stride + (cx-r)
        A-MovEdxImm $ovl ([int]($INJ_H / 2))
        A-Db $ovl @(0x29,0xDA)                   # sub edx, ebx
        A-Db $ovl @(0xC1,0xE2,0x0A)              # shl edx, 10    -- x INJ_W
        A-Db   $ovl @(0x81,0xC2)                 # add edx, imm32
        A-Dd32 $ovl ([uint32]($INJ_W / 2))
        A-Db $ovl @(0x29,0xDA)                   # sub edx, ebx
        A-MovEaxImm $ovl ([uint32]($BOOT_CALIB_IX * 0x01010101))
        A-PushDsPopEs $ovl

        A-Db $ovl @(0x8D,0x7C,0x15,0x00)         # lea edi,[ebp+edx]  -- the top edge
        A-Db $ovl @(0x89,0xD9)                   # mov ecx, ebx
        A-Db $ovl @(0xD1,0xE1)                   # shl ecx, 1
        A-Db $ovl @(0x41)                        # inc ecx            -- 2r+1 across
        A-Db $ovl @(0xF3,0xAA)                   # rep stosb

        A-Db $ovl @(0x89,0xDF)                   # mov edi, ebx       -- the bottom edge
        A-Db $ovl @(0xC1,0xE7,0x0B)              # shl edi, 11        -- 2r rows down
        A-Db $ovl @(0x01,0xD7)                   # add edi, edx
        A-Db $ovl @(0x01,0xEF)                   # add edi, ebp
        A-Db $ovl @(0x89,0xD9)                   # mov ecx, ebx
        A-Db $ovl @(0xD1,0xE1)
        A-Db $ovl @(0x41)
        A-Db $ovl @(0xF3,0xAA)

        A-Db $ovl @(0x8D,0x7C,0x15,0x00)         # lea edi,[ebp+edx]  -- the left edge
        A-Db $ovl @(0x89,0xD9)                   # mov ecx, ebx
        A-Db $ovl @(0xD1,0xE1)
        A-Db $ovl @(0x41)
        Add-Label $ovl 'ABK_l'
        A-Db $ovl @(0xAA)                        # stosb  (edi += 1)
        A-Db   $ovl @(0x81,0xC7)                 # add edi, imm32
        A-Dd32 $ovl ([uint32]($INJ_W - 1))       # ...so the net step is one whole row
        A-DecEcx $ovl
        A-JnzS $ovl 'ABK_l'

        A-Db $ovl @(0x8D,0x7C,0x15,0x00)         # lea edi,[ebp+edx]  -- the right edge
        A-Db $ovl @(0x01,0xDF)                   # add edi, ebx
        A-Db $ovl @(0x01,0xDF)                   # add edi, ebx       -- +2r across
        A-Db $ovl @(0x89,0xD9)                   # mov ecx, ebx
        A-Db $ovl @(0xD1,0xE1)
        A-Db $ovl @(0x41)
        Add-Label $ovl 'ABK_r'
        A-Db $ovl @(0xAA)
        A-Db   $ovl @(0x81,0xC7)
        A-Dd32 $ovl ([uint32]($INJ_W - 1))
        A-DecEcx $ovl
        A-JnzS $ovl 'ABK_r'

        # THE CROSSHAIR, growing inward as the box closes. Its arm is (R0 - r), the distance
        # the box has already travelled, so the arms touch the box edges at the exact moment
        # it settles -- the beat ends on a lock instead of on a box that stopped shrinking.
        if ($BOOT_CALIB_CROSS) {
            $cCentre = [uint32]($INJ_H / 2 * $INJ_W + $INJ_W / 2)
            A-MovEaxImm $ovl ([int]$BOOT_CALIB_R0)
            A-Db $ovl @(0x29,0xD8)               # sub eax, ebx   -> arm = R0 - r
            A-Jz $ovl 'ABK_out'                  # the first frame: nothing to draw yet
            A-Db $ovl @(0x39,0xD8)               # cmp eax, ebx   -- never outside the box
            A-JbeS $ovl 'ABK_arm'
            A-Db $ovl @(0x89,0xD8)               # mov eax, ebx
            Add-Label $ovl 'ABK_arm'
            # horizontal
            A-MovEdxImm $ovl $cCentre
            A-Db $ovl @(0x29,0xC2)               # sub edx, eax
            A-Db $ovl @(0x8D,0x7C,0x15,0x00)     # lea edi,[ebp+edx]
            A-Db $ovl @(0x89,0xC1)               # mov ecx, eax
            A-Db $ovl @(0xD1,0xE1)               # shl ecx, 1
            A-Db $ovl @(0x41)                    # inc ecx       -- 2*arm+1
            A-PushEax $ovl
            A-MovEaxImm $ovl ([uint32]($BOOT_CALIB_IX * 0x01010101))
            A-Db $ovl @(0xF3,0xAA)               # rep stosb
            A-PopEax $ovl
            # vertical
            A-Db $ovl @(0x89,0xC2)               # mov edx, eax
            A-Db $ovl @(0xC1,0xE2,0x0A)          # shl edx, 10   -- arm rows
            A-MovEcxImm $ovl $cCentre
            A-Db $ovl @(0x29,0xD1)               # sub ecx, edx
            A-Db $ovl @(0x8D,0x7C,0x0D,0x00)     # lea edi,[ebp+ecx]
            A-Db $ovl @(0x89,0xC1)               # mov ecx, eax
            A-Db $ovl @(0xD1,0xE1)
            A-Db $ovl @(0x41)
            A-MovEaxImm $ovl ([uint32]($BOOT_CALIB_IX * 0x01010101))
            Add-Label $ovl 'ABK_v'
            A-Db $ovl @(0xAA)                    # stosb
            A-Db   $ovl @(0x81,0xC7)
            A-Dd32 $ovl ([uint32]($INJ_W - 1))   # ...so the net step is one whole row
            A-DecEcx $ovl
            A-JnzS $ovl 'ABK_v'
        }
        Add-Label $ovl 'ABK_out'
        A-Popad $ovl
        A-Ret   $ovl

        # ---- the hook stub --------------------------------------------------
        # TAIL CALL, and it must be: `call target` + `ret` would put our return
        # address on top of the caller's stack arguments (0x38EC8 reads its argument
        # at [esp+0x38]) and the game hangs on the intro movie. Doing the work first
        # and JUMPING to the displaced target leaves the stack exactly as the callee
        # expects, and its own ret returns to the game.
        for ($pi = 0; $pi -lt $INJ_SITES.Count; $pi++) {
            Add-Label    $ovl ("AztInjProbe{0}" -f $pi)
            A-Pushfd     $ovl                    # pushad does NOT save EFLAGS
            A-Pushad     $ovl
            # CLD -- THE DIRECTION FLAG IS INHERITED FROM WHEREVER THE GAME WAS.
            #
            # Everything reached from here copies with `rep movsd`: AztInjBody's 1.48 MB
            # frame, AztBootCalib's panels. `rep movsd` walks BACKWARDS when DF is set, so a
            # single frame entered with DF=1 writes a megabyte and a half BELOW the
            # destination -- straight through the heap Reality Lab keeps its objects in.
            #
            # That is the fault behind "RAPTOR ERROR in Rendermorphics / object expected in
            # argument": intermittent, only ever while injecting, and not reproducible by
            # load. Bisected -- stable for minutes with -NoInject at identical host CPU load,
            # dead in 4-19 s with injection on, and the injection destination never moved
            # (dst 1), so it was not a resized surface. DF set on ~1 frame in 200 at 22 fps
            # is one corruption every ~9 s, which is where these crashes actually landed.
            #
            # One byte, and the pushfd/popfd either side restore the game's own DF on exit.
            # There is exactly ONE other cld in this overlay against ~35 rep movsd/stosd
            # sites; the rest inherit DF too and are worth auditing.
            A-Db         $ovl @(0xFC)            # cld
            A-CallNext   $ovl
            Add-Label    $ovl ("AIP_ref{0}" -f $pi)
            A-PopEax     $ovl
            A-SubEaxImm  $ovl ("AIP_ref{0}" -f $pi)
            A-MovEsiEax  $ovl                    # esi = obj1 delta
            A-MovEaxSi   $ovl $FIXUP_SRC
            A-SubEaxImm  $ovl $g_mouselookOn
            A-MovEdiEax  $ovl                    # edi = obj2 delta
            A-IncDwordSi $ovl ("aztInjCount{0}" -f $pi)   # before any early-out
            A-Call       $ovl 'AztBootCalib'     # BEFORE the body: see its own comment
            A-Call       $ovl 'AztInjBody'
            A-Popad      $ovl
            A-Popfd      $ovl
            A-Jmp        $ovl ([uint32]$INJ_SITES[$pi].Target)
        }

        for ($pi = 0; $pi -lt $INJ_SITES.Count; $pi++) {
            Add-Label $ovl ("aztInjCount{0}" -f $pi); A-Dd $ovl 0
        }
        Add-Label $ovl 'aztInjEnable'; A-Dd $ovl 0
        Add-Label $ovl 'aztInjBufPtr'; A-Dd $ovl 0   # host reads this to find the buffer
        Add-Label $ovl 'aztInjDone';   A-Dd $ovl 0   # the allocation has been ATTEMPTED
        # ---- the sync handshake's three words ------------------------------
        # aztInjReady is a one-way baton: the HOST sets it when the buffer holds a
        # complete frame, the guest clears it when that frame has been copied, and
        # neither writes it while the other might. The two counters make the pacing
        # visible instead of inferred -- `starve` rising means the host cannot keep
        # up, `shown` is frames that actually reached the screen.
        Add-Label $ovl 'aztInjReady';  A-Dd $ovl 0
        Add-Label $ovl 'aztInjStarve'; A-Dd $ovl 0   # guest frames with nothing fresh
        Add-Label $ovl 'aztInjShown';  A-Dd $ovl 0   # host frames actually displayed
        # 1 = the host is driving the one-frame handshake. Ships 0, so the boot and any
        # unsynchronised host both copy every frame exactly as before.
        Add-Label $ovl 'aztInjSync';   A-Dd $ovl 0
        # 1 = the HOST renderer owns the viewport. Deliberately NOT aztInjEnable, which
        # other code reads as `the visor boot is painting` and which gates the texture
        # defrag -- see the note in AztInjBody.
        Add-Label $ovl 'aztHostInject'; A-Dd $ovl 0
    }
    if ($CAM_RECORD) {
        Add-Label $ovl 'aztCamName';   A-Asciiz $ovl $CAM_LOG_NAME
        Add-Label $ovl 'aztCamHandle'; A-Dw $ovl 0

        # ONE CONTIGUOUS RECORD -- a single INT 21h AH=40h writes the whole run of
        # labels below, so nothing may be inserted between them and the order here
        # IS the on-disk format that Read-CamLog.ps1 decodes.
        #
        #   +0x000 magic 'CAM1'      +0x004 frame no      +0x008 time (us)
        #   +0x00C cam handle        +0x010 cam object    +0x014 cam type
        #   +0x018 cam parent        +0x01C cam world 4x4 +0x05C cam local 4x4
        #   +0x09C mov handle        +0x0A0 mov object    +0x0A4 mov type
        #   +0x0A8 mov parent        +0x0AC mov world 4x4 +0x0EC mov local 4x4
        #   +0x12C eye Y             +0x130 music cue     +0x134 root sentinel
        #   +0x138 obj1 delta (esi)  +0x13C obj2 delta (edi)          = 0x140 bytes
        Add-Label $ovl 'aztCamRec';     A-Dd32 $ovl 0x314D4143   # 'CAM1'
        Add-Label $ovl 'aztCamFrameNo'; A-Dd $ovl 0
        Add-Label $ovl 'aztCamTime';    A-Dd $ovl 0
        Add-Label $ovl 'aztCamIface';   A-Dd $ovl 0
        Add-Label $ovl 'aztCamObj';     A-Dd $ovl 0              # ebp base, cam
        Add-Label $ovl 'aztCamType';    A-Dd $ovl 0
        Add-Label $ovl 'aztCamParent';  A-Dd $ovl 0
        Add-Label $ovl 'aztCamWorld';   A-Db $ovl (New-Object byte[] 64)
        Add-Label $ovl 'aztCamLocal';   A-Db $ovl (New-Object byte[] 64)
        Add-Label $ovl 'aztMovIface';   A-Dd $ovl 0
        Add-Label $ovl 'aztMovObj';     A-Dd $ovl 0              # ebp base, mov
        Add-Label $ovl 'aztMovType';    A-Dd $ovl 0
        Add-Label $ovl 'aztMovParent';  A-Dd $ovl 0
        Add-Label $ovl 'aztMovWorld';   A-Db $ovl (New-Object byte[] 64)
        Add-Label $ovl 'aztMovLocal';   A-Db $ovl (New-Object byte[] 64)
        Add-Label $ovl 'aztCamEyeY';    A-Dd $ovl 0
        Add-Label $ovl 'aztCamCue';     A-Dd $ovl 0
        Add-Label $ovl 'aztCamRoot';    A-Dd $ovl 0
        Add-Label $ovl 'aztCamDelta1';  A-Dd $ovl 0              # esi, obj1 delta
        Add-Label $ovl 'aztCamDelta2';  A-Dd $ovl 0              # edi, obj2 delta
    }

    # ---- SCENE GRAPH ENUMERATION -------------------------------------------
    #
    # The tree shape is not guessed. The recursive transform propagator at
    # 0x55378 -- which HAS to walk the hierarchy to push world matrices down --
    # spells it out:
    #
    #     0005537E  mov ebp, eax
    #     00055380  mov ebx, [eax+0x30]        ; parent
    #     00055383  mov byte [eax+0x44], 0     ; clear dirty
    #     0005538C  cmp ebx, [0x147ED8]        ; parent == sentinel -> this is a root
    #     00055394  lea edx, [ebp+0x48]        ; local block
    #     00055397  add ebx, 0x8C              ; parent's world block
    #     0005539D  lea eax, [ebp+0x8C]        ; my world block
    #     000553A3  call 0x4272C               ; world = local x parentWorld
    #     000553AA  mov ecx, 0x11 / rep movsd  ; a root just copies local -> world
    #     000553BA  mov edx, [ebp+0x3C]        ; *** FIRST CHILD ***
    #     000553C3  call 0x55378               ; recurse
    #     000553C8  mov edx, [edx+0x34]        ; *** NEXT SIBLING ***
    #
    # So it is an ordinary first-child / next-sibling tree: `+0x3C` first child,
    # `+0x34` next sibling, `+0x30` parent, and a frame is a root when its parent
    # equals the sentinel in `[0x147ED8]`. `0x4272C` is the 4x4 multiply and
    # `0x552EC` builds the local matrix.
    #
    # The walk here is ITERATIVE, using the parent link to back out, so it needs no
    # stack of its own and cannot blow the game's stack however deep the scene is.
    # It is also hard-capped, because a corrupt or cyclic link would otherwise spin
    # forever inside a frame hook with the game unresponsive.
    #
    # ONE SHOT. It fires on the first frame where the camera's world translation is
    # non-zero -- i.e. once a room is actually loaded rather than while the menu is
    # up, where every matrix is still identity.
    #
    # Each node is written as its own 160-byte record, so only one staging buffer is
    # needed no matter how large the scene is. The record carries the whole frame
    # HEADER (`+0x00..+0x4B`, everything ahead of the local matrix) rather than just
    # the fields already understood, because the next thing needed is whichever field
    # holds the attached visual/mesh list, and dumping the header means finding it
    # offline instead of guessing at it here.
    # ebx = source pointer, ebp = destination. Clears 128 bytes at the destination,
    # then copies 128 bytes from the source ONLY IF the source looks like a heap
    # address. That guard is the whole point: these sources come from fields whose
    # meaning is still being established, so a float (0x42C80000) or a small count
    # would otherwise be dereferenced as a pointer and fault the game inside a frame
    # hook. Clearing first means "not a pointer" reads as zeros rather than as the
    # previous node's bytes.
    Add-Label $ovl 'AztScnBlk'
    if ($ENABLE_SCENE_LOG) {
        A-PushEsi $ovl
        A-PushEdi $ovl
        A-PushDsPopEs $ovl
        A-MovEdiEbp $ovl
        A-XorEaxEax $ovl
        A-MovEcxImm $ovl 32
        A-RepStosd  $ovl
        A-PopEdi $ovl
        A-PopEsi $ovl

        A-CmpEbxImm $ovl 0x00800000
        A-JbS       $ovl 'ASB_out'
        A-CmpEbxImm $ovl 0x03000000
        A-JaeS      $ovl 'ASB_out'
        A-PushEsi $ovl
        A-PushEdi $ovl
        A-MovEdiEbp $ovl
        A-MovEsiEbx $ovl
        A-MovEcxImm $ovl 32
        A-RepMovsd  $ovl
        A-PopEdi $ovl
        A-PopEsi $ovl
        Add-Label $ovl 'ASB_out'
    }
    A-Ret $ovl

    # ---- GEOMETRY EXPORT ----------------------------------------------------
    #
    # Writes every mesh's COMPLETE vertex, face and normal arrays, so the result can
    # be turned into an OBJ. The scene log proved the format; this carries the data.
    #
    # The trick that makes it simple: INT 21h AH=40h writes from ANY address, so the
    # payloads go straight out of the game's own arrays. No staging buffer, and
    # therefore no ceiling on mesh size -- only a fixed 144-byte header per mesh needs
    # assembling. Four writes per mesh: header, vertices, faces, normals.
    #
    # Strides are the ones confirmed by dumping the payloads: vertices 48 bytes
    # (x,y,z,colour,u,v), faces 120 (inline Face objects), normals 12.
    #
    # Every count is capped and every base pointer range-checked before use. A
    # plausible-looking but wrong count would otherwise have DOS read megabytes from
    # unmapped memory, which is a far worse failure than a missing mesh.
    Add-Label $ovl 'AztGeoWrite'               # edx = buffer, ecx = byte count
    if ($ENABLE_GEO_LOG) {
        A-PushEax $ovl
        A-MovBxSi  $ovl 'aztGeoHandle'
        A-MovAhImm $ovl 0x40
        A-Int      $ovl 0x21
        A-PopEax $ovl
    }
    A-Ret $ovl

    # ---- TEXTURE PIXEL DUMP -------------------------------------------------
    #
    # Writes each DISTINCT texture once, with its pixels. Room 1 has 28 distinct
    # textures shared across 117 meshes, so de-duplicating turns ~20 MB of repeated
    # writes into ~4.6 MB. The table is a flat 32-entry list of Texture object
    # pointers, linear-scanned -- at 28 entries that is cheaper than anything clever.
    #
    # WHICH POINTER HOLDS THE PIXELS IS NOT YET ESTABLISHED. The Texture object has
    # four heap pointers (+0x04, +0x20, +0x24, +0x54) and known dimensions at
    # +0x30/+0x34 with log2(width) at +0x40. Rather than guess and waste a run, this
    # dumps width*height from BOTH +0x20 and +0x24 (the shape of D3DRM's buffer1 /
    # buffer2), 1024 bytes from +0x54 (a 256-entry palette, matching the 256 at +0x44)
    # and a 256-byte probe of +0x04. One run then settles it either way.
    #
    # Every pointer goes through the same range check as everywhere else, and each
    # length is derived from the logged dimensions so the decoder can re-derive it.
    Add-Label $ovl 'AztTexWrite'               # edx = buffer, ecx = byte count
    if ($ENABLE_TEX_LOG) {
        A-PushEax $ovl
        A-MovBxSi  $ovl 'aztTexHandle'
        A-MovAhImm $ovl 0x40
        A-Int      $ovl 0x21
        A-PopEax $ovl
    }
    A-Ret $ovl

    # ebx = source pointer, ecx = byte count. Skips silently unless the pointer is
    # plausible and the count is sane -- a bogus length would have DOS read megabytes
    # of unmapped memory, which is far worse than a missing texture.
    Add-Label $ovl 'AztTexBlob'
    if ($ENABLE_TEX_LOG) {
        A-TestEcxEcx $ovl
        A-JzS        $ovl 'ATB_out'
        A-CmpEcxImm  $ovl 0x00100000           # 1 MB cap: largest here is 512x512
        A-JaeS       $ovl 'ATB_out'
        # FLOOR LOWERED TO 0x80000 on this path only. The texture pixel buffers live at
        # 0x38A038..0x582038 -- BELOW the 0x800000 floor used everywhere else -- which is
        # exactly why the first pixel dump captured structs instead of pixels. These
        # pointers come out of a D3DRMIMAGE whose width/height/depth were already
        # validated, and the length cap above still applies.
        A-CmpEbxImm  $ovl 0x00080000
        A-JbS        $ovl 'ATB_out'
        A-CmpEbxImm  $ovl 0x03000000
        A-JaeS       $ovl 'ATB_out'
        A-MovEdxEbx  $ovl
        A-Call       $ovl 'AztTexWrite'
        Add-Label $ovl 'ATB_out'
    }
    A-Ret $ovl

    # ---- ANIMATION KEYS -----------------------------------------------------
    #
    # Dumps every Animation object and all of its keyframes, so characters can be
    # posed and animated host-side instead of being stuck in the rest pose that made
    # the creatures float outside the room.
    #
    # THE LAYOUT CAME OUT OF THE THREE KEY-ADDERS, not from guessing:
    #   0x456B0  allocates a 0x1C (28) byte record, writes the time to key+0x08 and
    #            FOUR floats to key+0x0C -- a QUATERNION -- and links it off Anim+0x2C
    #   0x457AC  allocates 0x18 (24), time at +0x08 and a VEC3 at +0x0C/+0x10/+0x14,
    #            linked off Anim+0x34
    #   0x458B0  the same 24-byte shape, linked off Anim+0x3C
    # Each adder does `fld [node+0x08] / fcomp <newTime>` while walking, so the lists
    # are kept SORTED BY TIME. Which of +0x34 / +0x3C is position and which is scale is
    # not decidable from the code -- scale keys cluster around 1.0 and position keys
    # track the bone offsets, so the DATA will say.
    #
    # The list head at Anim+0x2C etc. is itself a node: the first real key is at
    # [[Anim+0x2C]], and `next` is at +0x00. The head is emitted too and the decoder
    # discards it, rather than encoding an assumption about it here.
    #
    # Two record types, each self-identifying, so the decoder never has to infer a
    # count: 'ANI1' (96 bytes) per Animation, then 'AKEY' (36) per key.
    Add-Label $ovl 'AztAniWrite'               # edx = buffer, ecx = byte count
    if ($ENABLE_ANI_LOG) {
        A-PushEax $ovl
        A-MovBxSi  $ovl 'aztAniHandle'
        A-MovAhImm $ovl 0x40
        A-Int      $ovl 0x21
        A-PopEax $ovl
    }
    A-Ret $ovl

    # ebx = list head pointer, aztAniList = which list. Walks `next` at +0x00 and
    # writes one 'AKEY' per node. Hard-capped: a corrupt link would otherwise spin
    # forever inside a frame hook with the game unresponsive.
    Add-Label $ovl 'AztAniKeys'
    if ($ENABLE_ANI_LOG) {
        A-MovDwordSiImm $ovl 'aztAniCount' 0
        Add-Label $ovl 'AAK_loop'
        A-CmpEbxImm $ovl 0x00080000
        A-Jb        $ovl 'AAK_done'
        A-CmpEbxImm $ovl 0x03000000
        A-Jae       $ovl 'AAK_done'
        A-CmpDwordSiImm32 $ovl 'aztAniCount' 4096
        A-Jae       $ovl 'AAK_done'

        A-PushEbx $ovl                         # copy 28 bytes of the node
        A-PushEsi $ovl
        A-PushEdi $ovl
        A-PushDsPopEs $ovl
        A-LeaEdiSi  $ovl 'aztAniKeyData'
        A-MovEsiEbx $ovl
        A-MovEcxImm $ovl 7                     # 28 bytes: the largest key record
        A-RepMovsd  $ovl
        A-PopEdi $ovl
        A-PopEsi $ovl
        A-PopEbx $ovl

        A-MovSiEbx32 $ovl 'aztAniKeyPtr'
        # COPY THE LIST ID INTO THE RECORD. Setting aztAniList and never moving it into
        # aztAniKeyList meant every key on disk claimed list 0, so rotation, position and
        # scale keys were indistinguishable -- and the vec3 keys, read as quaternions,
        # looked like 968 corrupt rotations. The data was always fine; only the label was
        # lost. (Recoverable offline from each list's head/tail pair, but not worth the
        # confusion.)
        A-PushEbx    $ovl
        A-MovEaxSi   $ovl 'aztAniList'
        A-MovSiEax32 $ovl 'aztAniKeyList'
        A-PopEbx     $ovl
        A-MovEcxImm  $ovl $ANI_KEY_LEN
        A-LeaEdxSi   $ovl 'aztAniKeyRec'
        A-PushEbx $ovl
        A-Call    $ovl 'AztAniWrite'
        A-PopEbx  $ovl

        A-IncDwordSi   $ovl 'aztAniCount'
        A-MovEbxEbxPtr $ovl                    # next
        A-Jmp          $ovl 'AAK_loop'
        Add-Label $ovl 'AAK_done'
    }
    A-Ret $ovl

    Add-Label $ovl 'AztAniEmit'
    if ($ENABLE_ANI_LOG) {
        A-MovAxSi    $ovl 'aztAniHandle'
        A-TestAxAx   $ovl
        A-Jz         $ovl 'AANI_out'
        A-MovEaxSi   $ovl 'aztScnObj'
        A-TestEaxEax $ovl
        A-Jz         $ovl 'AANI_out'

        A-MovEbxEaxD8 $ovl 0x20                # the move-callback node
        A-CmpEbxImm   $ovl 0x00080000
        A-Jb          $ovl 'AANI_out'
        A-CmpEbxImm   $ovl 0x03000000
        A-Jae         $ovl 'AANI_out'
        A-MovEaxEbx   $ovl
        A-MovEbxEaxD8 $ovl 0x04                # its arg: the Animation object
        A-CmpEbxImm   $ovl 0x00080000
        A-Jb          $ovl 'AANI_out'
        A-CmpEbxImm   $ovl 0x03000000
        A-Jae         $ovl 'AANI_out'
        A-MovSiEbx32  $ovl 'aztAniPtr'

        A-MovEaxSi   $ovl 'aztScnObj'
        A-MovSiEax32 $ovl 'aztAniFrame'

        A-PushEsi $ovl                         # the whole 76-byte Animation object
        A-PushEdi $ovl
        A-PushDsPopEs $ovl
        A-LeaEdiSi  $ovl 'aztAniObj'
        A-MovEsiEbx $ovl
        A-MovEcxImm $ovl 19                    # 76 bytes
        A-RepMovsd  $ovl
        A-PopEdi $ovl
        A-PopEsi $ovl

        A-MovEcxImm $ovl $ANI_HDR_LEN
        A-LeaEdxSi  $ovl 'aztAniRec'
        A-Call      $ovl 'AztAniWrite'

        # the three key lists
        foreach ($lst in @(@{ off = 0x2C; id = 0 }, @{ off = 0x34; id = 1 }, @{ off = 0x3C; id = 2 })) {
            A-MovDwordSiImm $ovl 'aztAniList' $lst.id
            A-MovEaxSi      $ovl 'aztAniPtr'
            A-MovEbxEaxD8   $ovl $lst.off
            A-Call          $ovl 'AztAniKeys'
        }
        Add-Label $ovl 'AANI_out'
    }
    A-Ret $ovl

    # EVERY FACE'S TEXTURE, NOT JUST face[0]'S.
    #
    # Reading only face[0] lost any texture used solely by a mesh's later faces, which
    # is not a rare case: `dorwall06` alone uses three. Measured across seven captured
    # rooms, room03 referenced 19 distinct textures and only 14 were dumped even though
    # it was nowhere near the table cap -- that gap was entirely this.
    Add-Label $ovl 'AztTexEmit'
    if ($ENABLE_TEX_LOG) {
        A-MovAxSi    $ovl 'aztTexHandle'
        A-TestAxAx   $ovl
        A-Jz         $ovl 'ATE_done'
        A-MovEaxSi   $ovl 'aztScnMeshP'
        A-TestEaxEax $ovl
        A-Jz         $ovl 'ATE_done'

        A-MovEbxEaxD8 $ovl 0x54                # face count
        A-TestEbxEbx  $ovl
        A-Jz          $ovl 'ATE_done'
        A-CmpEbxImm   $ovl 0x1000              # sanity cap
        A-Jae         $ovl 'ATE_done'
        A-MovSiEbx32  $ovl 'aztTexFCnt'
        A-MovEbxEaxD8 $ovl 0x5C                # -> the inline Face array
        A-CmpEbxImm   $ovl 0x00800000
        A-Jb          $ovl 'ATE_done'
        A-CmpEbxImm   $ovl 0x03000000
        A-Jae         $ovl 'ATE_done'
        A-MovSiEbx32  $ovl 'aztTexFBase'
        A-MovDwordSiImm $ovl 'aztTexFIdx' 0

        Add-Label $ovl 'ATE_faceloop'
        A-MovEaxSi   $ovl 'aztTexFIdx'
        A-CmpEaxSi   $ovl 'aztTexFCnt'
        A-Jae        $ovl 'ATE_done'
        A-ImulEaxImm $ovl 120                  # face stride
        A-MovEbxSi   $ovl 'aztTexFBase'
        A-AddEaxEbx  $ovl                      # eax = &face[idx]
        A-MovEbxEaxD8 $ovl 0x3C                # -> its Texture
        A-IncDwordSi $ovl 'aztTexFIdx'
        A-CmpEbxImm  $ovl 0x00800000
        A-Jb         $ovl 'ATE_faceloop'
        A-CmpEbxImm  $ovl 0x03000000
        A-Jae        $ovl 'ATE_faceloop'

        # --- already written? linear scan of the de-dup table
        A-MovEcxSi32 $ovl 'aztTexCnt'
        A-TestEcxEcx $ovl
        A-JzS        $ovl 'ATE_new'
        A-LeaEdxSi   $ovl 'aztTexTab'
        Add-Label $ovl 'ATE_scan'
        A-CmpEbxEdxPtr $ovl
        A-Jz           $ovl 'ATE_faceloop'     # duplicate: on to the next face
        A-AddEdxImm8   $ovl 4
        A-DecEcx       $ovl
        A-JnzS         $ovl 'ATE_scan'

        Add-Label $ovl 'ATE_new'
        A-MovEcxSi32 $ovl 'aztTexCnt'
        A-CmpEcxImm  $ovl $TEX_TAB_SLOTS      # table full: stop recording new ones
        A-Jae        $ovl 'ATE_done'
        A-LeaEdxSi   $ovl 'aztTexTab'
        A-ShlEcxImm  $ovl 2
        A-AddEdxEcx  $ovl
        A-MovEdxPtrEbx $ovl
        A-IncDwordSi $ovl 'aztTexCnt'

        # --- THE FILENAME, INTO THE HEADER --------------------------------------
        # It used to be recovered from the `+0x24` probe blob, which is fragile and, more
        # to the point, is one of the blobs now skipped on a repeat. The name is the only
        # load-invariant identity a texture has, so it belongs in the header.
        A-PushEbx $ovl
        A-PushEsi $ovl
        A-PushEdi $ovl
        A-LeaEdiSi  $ovl 'aztTexName64'
        A-XorEaxEax $ovl
        A-MovEcxImm $ovl 16
        A-RepStosd  $ovl
        A-PopEdi $ovl
        A-PopEsi $ovl
        A-PopEbx $ovl
        A-MovEaxEbxD8 $ovl 0x24                # -> the filename string
        A-CmpEaxImm   $ovl 0x00080000
        A-Jb          $ovl 'ATE_noname'
        A-PushEbx $ovl
        A-PushEsi $ovl
        A-PushEdi $ovl
        A-LeaEdiSi  $ovl 'aztTexName64'
        A-MovEsiEax $ovl
        A-MovEcxImm $ovl 16                    # 64 bytes, zero padded
        A-RepMovsd  $ovl
        A-PopEdi $ovl
        A-PopEsi $ovl
        A-PopEbx $ovl
        Add-Label $ovl 'ATE_noname'

        # --- FNV-1a over that name, to skip pixels we already have -------------
        # The texture OBJECT pointer only de-dups within one room: the engine frees and
        # re-allocates on every room load, so a revisit re-dumps every pixel. The .azf
        # filename is stable for the whole session, so hash that instead.
        #
        # A 32-bit hash can collide. That is tolerable ONLY because the name is written
        # into every header regardless: a collision means one texture's pixels are
        # skipped, and the decoder -- which matches name -> pixels -- can SEE that a name
        # has no pixels anywhere and say so. Detectable, not silent.
        A-MovEcxImm  $ovl 0x811C9DC5           # FNV-1a offset basis
        A-LeaEaxSi   $ovl 'aztTexName64'
        Add-Label $ovl 'ATE_hash'
        A-MovzxEdxByteEax $ovl
        A-TestDlDl   $ovl
        A-JzS        $ovl 'ATE_hashed'
        A-XorEcxEdx  $ovl
        A-ImulEcxImm $ovl 16777619
        A-IncEax     $ovl
        A-JmpS       $ovl 'ATE_hash'
        Add-Label $ovl 'ATE_hashed'
        A-MovSiEcx32 $ovl 'aztTexHash'

        # have we written this name's pixels already, this session?
        A-MovDwordSiImm $ovl 'aztTexRepeat' 0
        A-MovEaxSi   $ovl 'aztTexSeenN'
        A-TestEaxEax $ovl
        A-JzS        $ovl 'ATE_notseen'
        A-LeaEdxSi   $ovl 'aztTexSeen'
        Add-Label $ovl 'ATE_seenscan'
        A-CmpEcxEdxPtr $ovl
        A-JzS          $ovl 'ATE_isrepeat'
        A-AddEdxImm8   $ovl 4
        A-DecEax       $ovl
        A-JnzS         $ovl 'ATE_seenscan'
        A-JmpS         $ovl 'ATE_notseen'
        Add-Label $ovl 'ATE_isrepeat'
        A-MovDwordSiImm $ovl 'aztTexRepeat' 1
        A-JmpS $ovl 'ATE_seendone'
        Add-Label $ovl 'ATE_notseen'
        A-MovEaxSi   $ovl 'aztTexSeenN'
        A-CmpEaxImm  $ovl $TEX_SEEN_SLOTS
        A-JaeS       $ovl 'ATE_seendone'       # table full: dump it again rather than lose it
        A-LeaEdxSi   $ovl 'aztTexSeen'
        A-ShlEaxImm  $ovl 2
        A-AddEdxEax  $ovl
        A-MovEdxPtrEcx $ovl
        A-IncDwordSi $ovl 'aztTexSeenN'
        Add-Label $ovl 'ATE_seendone'

        # --- header
        A-MovSiEbx32 $ovl 'aztTexPtr'
        A-MovEaxEbx  $ovl                      # eax = Texture object
        foreach ($fld in @(@{ off = 0x14; lbl = 'aztTexHnd' }, @{ off = 0x30; lbl = 'aztTexW'  },
                           @{ off = 0x34; lbl = 'aztTexH'   }, @{ off = 0x40; lbl = 'aztTexL2' },
                           @{ off = 0x04; lbl = 'aztTexP04' }, @{ off = 0x20; lbl = 'aztTexP20' },
                           @{ off = 0x24; lbl = 'aztTexP24' }, @{ off = 0x54; lbl = 'aztTexP54' })) {
            A-MovEbxEaxD8 $ovl $fld.off
            A-MovSiEbx32  $ovl $fld.lbl
        }
        # bufLen = width * height   (8 bits per pixel)
        A-MovEaxSi  $ovl 'aztTexW'
        A-MovEcxSi32 $ovl 'aztTexH'
        A-MulEcx    $ovl                       # edx:eax = eax * ecx
        A-MovSiEax32 $ovl 'aztTexBufLen'
        A-MovDwordSiImm $ovl 'aztTexProbeLen' 256
        A-MovDwordSiImm $ovl 'aztTexPalLen'   1024

        A-MovEcxImm $ovl $TEX_HDR_LEN
        A-LeaEdxSi  $ovl 'aztTexRec'
        A-Call      $ovl 'AztTexWrite'

        # --- payloads: JUST the pixels and the palette, and only for a NEW filename.
        # The four probe blobs (+0x04, +0x20, +0x24, +0x54) existed only to work out WHICH
        # pointer held the pixels. That is settled -- buffer1 is at image+0x1C -- so they
        # are now dead weight, and they were roughly 3x the size of the pixels themselves.
        # Dropping them takes a 256x256 record from ~263 KB to 66.5 KB before any de-dup.
        A-CmpDwordSiImm $ovl 'aztTexRepeat' 0
        A-Jnz $ovl 'ATE_nopix'

        # THE ACTUAL PIXELS. +0x54 is a D3DRMIMAGE -- confirmed because its first fields
        # read 256,256,1,1,8,0,256 for a 256x256 texture, matching the documented order
        # (width, height, aspectx, aspecty, depth, rgb, bytes_per_line, buffer1,
        # buffer2, r/g/b/a masks, palette_size, palette). So buffer1 is at image+0x1C
        # and the palette at image+0x38. The previous run logged neither: it dumped
        # 1024 bytes OF the image struct, and buffer1 was below the old range floor.
        A-MovEaxSi    $ovl 'aztTexP54'
        A-CmpEaxImm   $ovl 0x00080000
        A-Jb          $ovl 'ATE_noimg'
        A-MovEbxEaxD8 $ovl 0x1C                # buffer1 -> the pixels
        A-MovSiEbx32  $ovl 'aztTexPix'
        A-MovEaxSi    $ovl 'aztTexP54'
        A-MovEbxEaxD8 $ovl 0x38                # the palette
        A-MovSiEbx32  $ovl 'aztTexPal'
        A-MovEbxSi    $ovl 'aztTexPix'
        A-MovEcxSi32  $ovl 'aztTexBufLen'
        A-Call        $ovl 'AztTexBlob'
        A-MovEbxSi    $ovl 'aztTexPal'
        A-MovEcxImm   $ovl 1024
        A-Call        $ovl 'AztTexBlob'
        Add-Label $ovl 'ATE_noimg'
        Add-Label $ovl 'ATE_nopix'
        A-Jmp $ovl 'ATE_faceloop'      # this texture done; next face
        Add-Label $ovl 'ATE_done'
    }
    A-Ret $ovl

    Add-Label $ovl 'AztGeoEmit'
    if ($ENABLE_GEO_LOG) {
        A-MovAxSi    $ovl 'aztGeoHandle'
        A-TestAxAx   $ovl
        A-Jz         $ovl 'AGE_out'
        A-MovEaxSi   $ovl 'aztScnMeshP'        # set by AztScnEmit; 0 = no mesh
        A-TestEaxEax $ovl
        A-Jz         $ovl 'AGE_out'

        A-MovSiEax32 $ovl 'aztGeoMesh'
        foreach ($fld in @(@{ off = 0x48; lbl = 'aztGeoVCnt'  }, @{ off = 0x54; lbl = 'aztGeoFCnt'  },
                           @{ off = 0x60; lbl = 'aztGeoNCnt'  }, @{ off = 0x50; lbl = 'aztGeoVBase' },
                           @{ off = 0x5C; lbl = 'aztGeoFBase' }, @{ off = 0x68; lbl = 'aztGeoNBase' })) {
            A-MovEbxEaxD8 $ovl $fld.off
            A-MovSiEbx32  $ovl $fld.lbl
        }
        A-MovEbxSi   $ovl 'aztScnObj'
        A-MovSiEbx32 $ovl 'aztGeoFrame'
        A-MovEbxSi   $ovl 'aztScnDepth'
        A-MovSiEbx32 $ovl 'aztGeoDepth'

        # the frame's world 4x4 -- the OBJ needs it to place this mesh in the room
        A-MovEaxSi $ovl 'aztScnObj'
        A-PushEsi $ovl
        A-PushEdi $ovl
        A-PushDsPopEs $ovl
        A-LeaEdiSi     $ovl 'aztGeoWorld'
        A-LeaEsiEaxD32 $ovl 0x90
        A-MovEcxImm    $ovl 16
        A-RepMovsd     $ovl
        A-PopEdi $ovl
        A-PopEsi $ovl

        # the frame's name, so meshes are identifiable in the export
        A-PushEsi $ovl
        A-PushEdi $ovl
        A-LeaEdiSi  $ovl 'aztGeoName'
        A-XorEaxEax $ovl
        A-MovEcxImm $ovl 8
        A-RepStosd  $ovl
        A-PopEdi $ovl
        A-PopEsi $ovl
        A-MovEaxSi    $ovl 'aztScnObj'
        A-MovEbxEaxD8 $ovl 0x24
        A-CmpEbxImm   $ovl 0x00800000
        A-JbS         $ovl 'AGE_noname'
        A-CmpEbxImm   $ovl 0x03000000
        A-JaeS        $ovl 'AGE_noname'
        A-PushEsi $ovl
        A-PushEdi $ovl
        A-LeaEdiSi  $ovl 'aztGeoName'
        A-MovEsiEbx $ovl
        A-MovEcxImm $ovl 8                     # 32 bytes, zero padded
        A-RepMovsd  $ovl
        A-PopEdi $ovl
        A-PopEsi $ovl
        Add-Label $ovl 'AGE_noname'

        # THE LOCAL MATRIX. This was an unsampled gap: the scene log's header dump
        # stops at frame+0x4B and its world block starts at +0x90, so +0x4C..+0x8B was
        # never captured. It matters because the cached WORLD matrices go stale on
        # animated sub-trees -- the engine only re-propagates DIRTY frames, and
        # AztSceneLog deliberately does not call the lazy refresh 0x554F0 (that would
        # mean mutating engine state to observe it). Measured on the XAFQ1 creature:
        # the chain is exact until EUBUM -> EUTAIL, which jumps (37,192,648), and every
        # offset below that is small and consistent -- a whole sub-skeleton carrying
        # rest-pose world matrices. With the LOCAL matrices the hierarchy can be
        # composed host-side instead, which is also what animation drives.
        A-MovEaxSi $ovl 'aztScnObj'
        A-PushEsi $ovl
        A-PushEdi $ovl
        A-LeaEdiSi     $ovl 'aztGeoLocal'
        A-LeaEsiEaxD32 $ovl 0x4C
        A-MovEcxImm    $ovl 16
        A-RepMovsd     $ovl
        A-PopEdi $ovl
        A-PopEsi $ovl

        # THE TEXTURE AND MATERIAL of the mesh's first face. Face::SetTexture
        # (0x49308) stores into face+0x3C and Face::SetMaterial (0x493E4) into
        # face+0x40 -- which are exactly the two unexplained heap pointers seen in the
        # wall2 face. The face array holds INLINE Face objects, so face[0] is at the
        # array base itself. AztScnBlk clears each buffer and range-checks the pointer,
        # so a mesh with no texture reads as zeros rather than as the previous mesh's.
        foreach ($att in @(@{ off = 0x3C; lbl = 'aztGeoTex0' }, @{ off = 0x40; lbl = 'aztGeoMat0' })) {
            A-XorEbxEbx  $ovl                  # default: nothing
            A-MovEaxSi   $ovl 'aztScnMeshP'
            A-MovEbxEaxD8 $ovl 0x5C            # -> &face[0]
            A-CmpEbxImm  $ovl 0x00800000
            A-JbS        $ovl ('AGE_att{0:X}' -f $att.off)
            A-CmpEbxImm  $ovl 0x03000000
            A-JaeS       $ovl ('AGE_att{0:X}' -f $att.off)
            A-MovEaxEbx  $ovl                  # eax = face[0]
            A-MovEbxEaxD8 $ovl $att.off        # -> Texture / Material
            Add-Label $ovl ('AGE_att{0:X}' -f $att.off)
            A-LeaEbpSi $ovl $att.lbl
            A-Call     $ovl 'AztScnBlk'
        }

        A-MovEcxImm $ovl $GEO_HDR_LEN
        A-LeaEdxSi  $ovl 'aztGeoRec'
        A-Call      $ovl 'AztGeoWrite'

        # the three payloads, straight out of the engine's arrays
        foreach ($pl in @(@{ cnt = 'aztGeoVCnt'; base = 'aztGeoVBase'; stride =  48; tag = 'V' },
                          @{ cnt = 'aztGeoFCnt'; base = 'aztGeoFBase'; stride = 120; tag = 'F' },
                          @{ cnt = 'aztGeoNCnt'; base = 'aztGeoNBase'; stride =  12; tag = 'N' })) {
            $skip = 'AGE_skip' + $pl.tag
            A-MovEcxSi32 $ovl $pl.cnt
            A-TestEcxEcx $ovl
            A-JzS        $ovl $skip
            A-CmpEcxImm  $ovl 0x4000           # sanity cap: room 1's largest is 47
            A-JaeS       $ovl $skip
            A-ImulEcxImm $ovl $pl.stride
            A-MovEdxSi32 $ovl $pl.base
            A-CmpEdxImm  $ovl 0x00800000
            A-JbS        $ovl $skip
            A-CmpEdxImm  $ovl 0x03000000
            A-JaeS       $ovl $skip
            A-Call       $ovl 'AztGeoWrite'
            Add-Label $ovl $skip
        }
        Add-Label $ovl 'AGE_out'
    }
    A-Ret $ovl

    Add-Label $ovl 'AztScnEmit'
    if ($ENABLE_SCENE_LOG) {
        A-MovSiEax32 $ovl 'aztScnObj'
        A-MovEbxSi   $ovl 'aztScnDepth'
        A-MovSiEbx32 $ovl 'aztScnDepthF'

        A-PushEsi $ovl                         # the deltas: rep movsd needs esi/edi
        A-PushEdi $ovl
        A-PushDsPopEs $ovl
        A-LeaEdiSi     $ovl 'aztScnHdr'        # dest FIRST -- esi is about to go
        A-MovEsiEax    $ovl
        A-MovEcxImm    $ovl 19                 # 76 bytes: +0x00..+0x4B
        A-RepMovsd     $ovl
        A-PopEdi $ovl
        A-PopEsi $ovl

        A-PushEsi $ovl
        A-PushEdi $ovl
        A-LeaEdiSi     $ovl 'aztScnWorld'
        A-LeaEsiEaxD32 $ovl 0x90               # the world 4x4
        A-MovEcxImm    $ovl 16
        A-RepMovsd     $ovl
        A-PopEdi $ovl
        A-PopEsi $ovl

        # The region PAST the world matrix, which the first pass never looked at.
        # The header census found a (count, array) pair at +0x1C/+0x20 and a
        # per-frame pointer at +0x24, but nothing above +0xCF had been sampled at
        # all -- and an attached-visual list is just as likely to live there.
        A-PushEsi $ovl
        A-PushEdi $ovl
        A-LeaEdiSi     $ovl 'aztScnTail'
        A-LeaEsiEaxD32 $ovl 0xD0
        A-MovEcxImm    $ovl 28                 # 112 bytes: +0xD0..+0x13F
        A-RepMovsd     $ovl
        A-PopEdi $ovl
        A-PopEsi $ovl

        # The REST of the frame. The class table in obj2 gives every Reality Lab
        # class its name and object size -- Frame is 736 bytes (0x2E0) -- so the
        # first pass, which stopped at +0x13F, had seen less than half of it. That is
        # where the visuals were hiding: Frame::AddVisual (0x49940) validates its two
        # arguments as Frame and Visual and then does `add eax,0x268` before calling
        # the list-append at 0x54C38. So:
        #
        #   +0x268  visual count      +0x26C  capacity     +0x270  -> Visual*[]
        #
        # which is the engine's ordinary dynamic-array shape (0x54C38 stores
        # items[count] = item through [list+0x08] and bumps [list+0x00]).
        A-PushEsi $ovl
        A-PushEdi $ovl
        A-LeaEdiSi     $ovl 'aztScnRest'
        A-LeaEsiEaxD32 $ovl 0x140
        A-MovEcxImm    $ovl 104                # 416 bytes: +0x140..+0x2DF
        A-RepMovsd     $ovl
        A-PopEdi $ovl
        A-PopEsi $ovl

        # The first attached Visual, if any: count at +0x268, array at +0x270.
        # Cleared first so "no visual" reads as zeros rather than the last node's.
        A-PushEsi $ovl
        A-PushEdi $ovl
        A-LeaEdiSi  $ovl 'aztScnVis0'
        A-XorEaxEax $ovl
        A-MovEcxImm $ovl 32
        A-RepStosd  $ovl
        A-PopEdi $ovl
        A-PopEsi $ovl

        A-MovDwordSiImm $ovl 'aztScnMeshP' 0
        A-MovEaxSi     $ovl 'aztScnObj'
        A-MovEbxEaxD32 $ovl 0x268              # visual count
        A-TestEbxEbx   $ovl
        A-JzS          $ovl 'ASE_novis'
        A-MovEbxEaxD32 $ovl 0x270              # -> Visual*[]
        A-TestEbxEbx   $ovl
        A-JzS          $ovl 'ASE_novis'
        A-MovEbxEbxPtr $ovl                    # -> the first Visual
        A-TestEbxEbx   $ovl
        A-JzS          $ovl 'ASE_novis'
        A-MovSiEbx32 $ovl 'aztScnMeshP'        # stash: the Mesh
        A-PushEsi $ovl
        A-PushEdi $ovl
        A-LeaEdiSi  $ovl 'aztScnVis0'
        A-MovEsiEbx $ovl
        A-MovEcxImm $ovl 32                    # 128 bytes of it (a Mesh is 272)
        A-RepMovsd  $ovl
        A-PopEdi $ovl
        A-PopEsi $ovl
        Add-Label $ovl 'ASE_novis'

        # THE MESH'S THREE ARRAYS. Mesh holds three {count, capacity, pointer}
        # triples at +0x48, +0x54 and +0x60 -- the engine's generic list shape, per
        # the append at 0x54C38. Their counts are geometrically sensible (a wall quad
        # is 4/2/4, a floor slab 8/6/12, a head 47/46/47) but WHICH is vertices and
        # which is faces has only been inferred from those counts, never read out of
        # code. So dump the payloads and stop guessing.
        #
        # arr2[0] is also followed, because an array of Face objects would hold
        # POINTERS (Face is its own 120-byte class) while vertex data would be inline
        # floats. One dump distinguishes the two.
        #
        # AztScnBlk range-checks every pointer before dereferencing it, so a float or
        # a small integer mistaken for an address cannot fault the game.
        A-MovEaxSi $ovl 'aztScnMeshP'
        A-TestEaxEax $ovl
        A-Jz $ovl 'ASE_nomesh'
        foreach ($ar in @(@{ off = 0x50; lbl = 'aztScnA1' },
                          @{ off = 0x5C; lbl = 'aztScnA2' },
                          @{ off = 0x68; lbl = 'aztScnA3' })) {
            A-MovEaxSi    $ovl 'aztScnMeshP'
            A-MovEbxEaxD8 $ovl $ar.off
            A-LeaEbpSi    $ovl $ar.lbl
            A-Call        $ovl 'AztScnBlk'
        }
        # arr2[0], dereferenced only if arr2 itself is a plausible pointer.
        A-MovEaxSi    $ovl 'aztScnMeshP'
        A-MovEbxEaxD8 $ovl 0x5C
        A-CmpEbxImm   $ovl 0x00800000
        A-JbS         $ovl 'ASE_f0zero'
        A-CmpEbxImm   $ovl 0x03000000
        A-JaeS        $ovl 'ASE_f0zero'
        A-MovEbxEbxPtr $ovl
        A-JmpS        $ovl 'ASE_f0go'
        Add-Label $ovl 'ASE_f0zero'
        A-XorEbxEbx $ovl
        Add-Label $ovl 'ASE_f0go'
        A-LeaEbpSi $ovl 'aztScnF0'
        A-Call     $ovl 'AztScnBlk'
        A-JmpS     $ovl 'ASE_meshdone'

        Add-Label $ovl 'ASE_nomesh'            # no mesh: still clear all four
        foreach ($lbl in @('aztScnA1','aztScnA2','aztScnA3','aztScnF0')) {
            A-XorEbxEbx $ovl
            A-LeaEbpSi  $ovl $lbl
            A-Call      $ovl 'AztScnBlk'
        }
        Add-Label $ovl 'ASE_meshdone'

        # Follow the two candidate pointers. Each target buffer is CLEARED first, so
        # a null pointer reads as zeros rather than leaving the previous node's bytes
        # in place and looking like real data. eax is free to clobber here because the
        # node was stashed in aztScnObj on entry.
        foreach ($cand in @(@{ off = 0x20; lbl = 'aztScnP20' }, @{ off = 0x24; lbl = 'aztScnP24' })) {
            A-PushEsi $ovl
            A-PushEdi $ovl
            A-LeaEdiSi  $ovl $cand.lbl
            A-XorEaxEax $ovl
            A-MovEcxImm $ovl 16
            A-RepStosd  $ovl
            A-PopEdi $ovl
            A-PopEsi $ovl

            A-MovEaxSi    $ovl 'aztScnObj'
            A-MovEbxEaxD8 $ovl $cand.off
            A-TestEbxEbx  $ovl
            A-JzS         $ovl ("ASE_skip{0:X}" -f $cand.off)
            A-PushEsi $ovl
            A-PushEdi $ovl
            A-LeaEdiSi  $ovl $cand.lbl
            A-MovEsiEbx $ovl
            A-MovEcxImm $ovl 16                # 64 bytes of whatever it points at
            A-RepMovsd  $ovl
            A-PopEdi $ovl
            A-PopEsi $ovl
            Add-Label $ovl ("ASE_skip{0:X}" -f $cand.off)
        }
        A-MovEaxSi $ovl 'aztScnObj'            # restore: the caller walks from eax

        A-PushEax $ovl                         # AH=40h returns the count in eax
        A-MovBxSi   $ovl 'aztScnHandle'
        A-MovAhImm  $ovl 0x40
        A-MovEcxImm $ovl $SCN_REC_LEN
        A-LeaEdxSi  $ovl 'aztScnRec'
        A-Int       $ovl 0x21
        A-PopEax $ovl
    }
    A-Ret $ovl

    # Registers are saved with pushad because this runs inside the frame limiter and
    # calls into engine code. NOTE the two exit labels: the one-shot test happens
    # BEFORE pushad and so leaves via ASL_out, while every bail inside the body must
    # leave via ASL_bail, which is ahead of popad. Jumping an in-body failure
    # straight to ASL_out would pop nothing and unbalance the stack.
    Add-Label $ovl 'AztSceneLog'
    if ($ENABLE_SCENE_LOG) {
        # MULTI-ROOM CAPTURE. This used to be one-shot; now it re-fires on every ROOM
        # CHANGE so a whole play-through archives the game.
        #
        # THE TRIGGER IS THE SCENE ITSELF, not the music cue. Rooms are rebuilt on entry,
        # so the root frame's FIRST CHILD pointer changes; the music cue was the obvious
        # signal but adjacent rooms can share a track, which would silently skip rooms.
        # The signature is cheap and cannot miss a rebuild.
        #
        # Files are opened ONCE, on the first dump, and stay open: AH=3Ch truncates, so
        # re-creating them per room would throw away every previous room. Each dump
        # begins with a 'ROOM' marker in each file, so the streams stay self-delimiting.
        A-Pushad $ovl
        A-CmpDwordSiImm32 $ovl 'aztScnDumps' $SCN_MAX_ROOMS
        A-Jae $ovl 'ASL_bail'

        A-MovEaxDi   $ovl 0x152144             # the camera frame's handle
        A-TestEaxEax $ovl
        A-Jz         $ovl 'ASL_bail'
        A-Call       $ovl ([uint32]0x39E50)    # -> object, side-effect free
        A-TestEaxEax $ovl
        A-Jz         $ovl 'ASL_bail'

        # Still at the origin means the menu is up and every matrix is identity;
        # enumerating then would dump a scene that does not exist yet.
        A-MovEbxEaxD32 $ovl 0xC0               # world X
        A-OrEbxEaxD32  $ovl 0xC8               # world Z
        A-Jz           $ovl 'ASL_bail'

        # The root comes from the ENGINE, not from a hand-rolled climb. 0x42410
        # resolves a handle and returns [root+0x14] -- the handle of the topmost
        # frame -- by calling 0x55540, which walks `+0x30` until the parent equals
        # the sentinel. That is precisely the root-finding the movement code uses for
        # its own reference frame, so using it removes a whole class of error rather
        # than reimplementing it here.
        A-MovEaxDi   $ovl 0x152144
        A-Call       $ovl ([uint32]0x42410)    # -> the ROOT frame's handle
        A-TestEaxEax $ovl
        A-Jz         $ovl 'ASL_bail'
        A-MovSiEax32 $ovl 'aztScnRootH'        # MUST be stashed in memory: see below

        # --- has the room changed? ---------------------------------------------
        # THE SIGNATURE IS THE ROOT'S **LAST** CHILD, NOT ITS FIRST.
        # Measured: the first child is the movement frame (node 1, unnamed), created once
        # at init and identical in every room -- so a first-child signature never changes,
        # and the capture duly fired exactly once across five rooms. Room frames are
        # APPENDED to the root, so the LAST child is room-specific (it was 'XAFQ2' in
        # room 1).
        #
        # The music cue is XORed in as a second source: the allocator can hand back a
        # reused pointer for a different room's last frame, and a bare pointer compare
        # would then read as "same room" and silently skip it.
        A-Call       $ovl ([uint32]0x39E50)    # root handle -> root object
        A-TestEaxEax $ovl
        A-Jz         $ovl 'ASL_bail'
        A-MovEbxEaxD8 $ovl 0x40                # root's LAST child
        A-TestEbxEbx $ovl
        A-Jz         $ovl 'ASL_bail'           # empty scene: nothing to dump yet
        A-MovEaxDi   $ovl 0x152AD0             # the music cue, as a second source
        A-XorEbxEax  $ovl
        A-CmpEbxSi   $ovl 'aztScnSig'
        A-Jz         $ovl 'ASL_bail'           # same room, already captured
        A-MovSiEbx32 $ovl 'aztScnSig'

        # INT 21h AH=3Ch RETURNS THE HANDLE IN AX, so the create DESTROYS eax. The
        # first version of this walked the parent chain from eax straight after the
        # create and duly climbed from wreckage -- it emitted exactly one node whose
        # object was 0x001300F0, an address in obj1's BSS that is neither heap nor a
        # runtime pointer, with a header of all zeros. Hence the root handle is kept
        # in memory across the create and only resolved to an object afterwards.
        #
        # Opened once only: truncating per room would discard every earlier room.
        A-CmpWordSiImm $ovl 'aztScnOpened' 0
        A-Jnz $ovl 'ASL_isopen'
        A-MovWordSiImm $ovl 'aztScnOpened' 1
        A-MovEcxImm $ovl 0
        A-MovAhImm  $ovl 0x3C
        A-LeaEdxSi  $ovl 'aztScnName'
        A-Int       $ovl 0x21
        A-Jb        $ovl 'ASL_bail'
        A-MovSiAx   $ovl 'aztScnHandle'

        # The geometry file. Opened here, in the same gap, for the same reason the
        # root handle was stashed first: each create returns its handle in AX and so
        # destroys eax.
        if ($ENABLE_GEO_LOG) {
            A-MovEcxImm $ovl 0
            A-MovAhImm  $ovl 0x3C
            A-LeaEdxSi  $ovl 'aztGeoName2'
            A-Int       $ovl 0x21
            A-JbS       $ovl 'ASL_nogeo'
            A-MovSiAx   $ovl 'aztGeoHandle'
            Add-Label $ovl 'ASL_nogeo'
        }
        if ($ENABLE_TEX_LOG) {
            A-MovEcxImm $ovl 0
            A-MovAhImm  $ovl 0x3C
            A-LeaEdxSi  $ovl 'aztTexName'
            A-Int       $ovl 0x21
            A-JbS       $ovl 'ASL_notex'
            A-MovSiAx   $ovl 'aztTexHandle'
            Add-Label $ovl 'ASL_notex'
        }
        if ($ENABLE_ANI_LOG) {
            A-MovEcxImm $ovl 0
            A-MovAhImm  $ovl 0x3C
            A-LeaEdxSi  $ovl 'aztAniName'
            A-Int       $ovl 0x21
            A-JbS       $ovl 'ASL_noani'
            A-MovSiAx   $ovl 'aztAniHandle'
            Add-Label $ovl 'ASL_noani'
        }
        Add-Label $ovl 'ASL_isopen'

        # --- a 'ROOM' marker in every stream, so each stays self-delimiting ----
        A-IncDwordSi $ovl 'aztScnDumps'
        A-MovEaxSi   $ovl 'aztScnDumps'
        A-MovSiEax32 $ovl 'aztRoomSeq'
        A-MovEaxDi   $ovl 0x152AD0             # the music cue: a useful room hint
        A-MovSiEax32 $ovl 'aztRoomCue'
        A-MovEaxSi   $ovl 'aztScnSig'
        A-MovSiEax32 $ovl 'aztRoomSig'
        A-MovEaxSi   $ovl 'aztScnRootH'
        A-MovSiEax32 $ovl 'aztRoomRoot'
        foreach ($h in @(@{ f = 'aztScnHandle'; on = $true },
                         @{ f = 'aztGeoHandle'; on = $ENABLE_GEO_LOG },
                         @{ f = 'aztTexHandle'; on = $ENABLE_TEX_LOG },
                         @{ f = 'aztAniHandle'; on = $ENABLE_ANI_LOG })) {
            if (-not $h.on) { continue }
            A-MovAxSi  $ovl $h.f
            A-TestAxAx $ovl
            A-JzS      $ovl ('ASL_nomark_' + $h.f)
            A-MovBxSi  $ovl $h.f
            A-MovAhImm $ovl 0x40
            A-MovEcxImm $ovl $ROOM_REC_LEN
            A-LeaEdxSi  $ovl 'aztRoomRec'
            A-Int       $ovl 0x21
            Add-Label $ovl ('ASL_nomark_' + $h.f)
        }

        # RESET THE TEXTURE DE-DUP TABLE PER ROOM. Keeping it across rooms would save
        # space, but the engine frees and re-allocates textures between rooms, so a
        # pointer can be REUSED for different art -- a global table would then skip a
        # texture it had never actually seen. Correctness over size.
        if ($ENABLE_TEX_LOG) { A-MovDwordSiImm $ovl 'aztTexCnt' 0 }

        A-MovEaxSi   $ovl 'aztScnRootH'
        A-Call       $ovl ([uint32]0x39E50)    # handle -> root object
        A-TestEaxEax $ovl
        A-Jz         $ovl 'ASL_close'

        A-MovDwordSiImm $ovl 'aztScnDepth' 0
        A-MovDwordSiImm $ovl 'aztScnCount' 0

        Add-Label $ovl 'ASL_visit'
        A-Call        $ovl 'AztScnEmit'        # also leaves the Mesh in aztScnMeshP
        A-Call        $ovl 'AztGeoEmit'        # ...which this consumes
        A-Call        $ovl 'AztTexEmit'        # de-duplicated texture pixels
        A-Call        $ovl 'AztAniEmit'        # animation keyframes
        A-MovEaxSi    $ovl 'aztScnObj'         # both clobber eax; the walk needs it
        A-IncDwordSi  $ovl 'aztScnCount'
        A-CmpDwordSiImm32 $ovl 'aztScnCount' 4096
        A-Jae         $ovl 'ASL_close'         # cyclic or corrupt: stop, do not hang

        A-MovEbxEaxD8 $ovl 0x3C                # descend to the first child
        A-TestEbxEbx  $ovl
        A-JzS         $ovl 'ASL_side'
        A-MovEaxEbx   $ovl
        A-IncDwordSi  $ovl 'aztScnDepth'
        A-Jmp         $ovl 'ASL_visit'

        Add-Label $ovl 'ASL_side'
        A-MovEbxEaxD8 $ovl 0x34                # else across to the next sibling
        A-TestEbxEbx  $ovl
        A-JzS         $ovl 'ASL_upone'
        A-MovEaxEbx   $ovl
        A-Jmp         $ovl 'ASL_visit'

        Add-Label $ovl 'ASL_upone'             # else back out through the parent
        A-CmpDwordSiImm $ovl 'aztScnDepth' 0
        A-Jle         $ovl 'ASL_close'
        A-MovEbxEaxD8 $ovl 0x30
        A-TestEbxEbx  $ovl
        A-JzS         $ovl 'ASL_close2'
        A-CmpEbxDi    $ovl 0x147ED8
        A-JzS         $ovl 'ASL_close2'
        A-MovEaxEbx   $ovl
        A-DecDwordSi  $ovl 'aztScnDepth'
        A-JmpS        $ovl 'ASL_side'

        Add-Label $ovl 'ASL_close2'
        Add-Label $ovl 'ASL_close'
        A-MovBxSi  $ovl 'aztScnHandle'
        A-MovAhImm $ovl 0x68                   # COMMIT ONLY -- never close, the
        A-Int      $ovl 0x21                   # handle must survive the next room
        if ($ENABLE_GEO_LOG) {
            A-MovAxSi  $ovl 'aztGeoHandle'
            A-TestAxAx $ovl
            A-JzS      $ovl 'ASL_geoclosed'
            A-MovBxSi  $ovl 'aztGeoHandle'
            A-MovAhImm $ovl 0x68        # COMMIT ONLY -- never close: the
            A-Int      $ovl 0x21        # handles must survive for the next room
            Add-Label $ovl 'ASL_geoclosed'
        }
        if ($ENABLE_TEX_LOG) {
            A-MovAxSi  $ovl 'aztTexHandle'
            A-TestAxAx $ovl
            A-JzS      $ovl 'ASL_texclosed'
            A-MovBxSi  $ovl 'aztTexHandle'
            A-MovAhImm $ovl 0x68        # COMMIT ONLY -- never close: the
            A-Int      $ovl 0x21        # handles must survive for the next room
            Add-Label $ovl 'ASL_texclosed'
        }
        if ($ENABLE_ANI_LOG) {
            A-MovAxSi  $ovl 'aztAniHandle'
            A-TestAxAx $ovl
            A-JzS      $ovl 'ASL_aniclosed'
            A-MovBxSi  $ovl 'aztAniHandle'
            A-MovAhImm $ovl 0x68        # COMMIT ONLY -- never close: the
            A-Int      $ovl 0x21        # handles must survive for the next room
            Add-Label $ovl 'ASL_aniclosed'
        }
        Add-Label $ovl 'ASL_bail'
        A-Popad $ovl
        Add-Label $ovl 'ASL_out'
    }
    A-Ret $ovl

    if ($ENABLE_SCENE_LOG) {
        Add-Label $ovl 'aztScnName';   A-Asciiz $ovl $SCENE_LOG_NAME
        Add-Label $ovl 'aztScnHandle'; A-Dw $ovl 0
        Add-Label $ovl 'aztScnDone';   A-Dw $ovl 0    # legacy, no longer read
        Add-Label $ovl 'aztScnOpened'; A-Dw $ovl 0    # files created once
        Add-Label $ovl 'aztScnSig';    A-Dd $ovl 0    # root's first child = room id
        Add-Label $ovl 'aztScnDumps';  A-Dd $ovl 0    # rooms captured so far

        # 32-byte 'ROOM' marker, written into EVERY stream at the start of each room.
        Add-Label $ovl 'aztRoomRec';   A-Dd32 $ovl 0x4D4F4F52   # 'ROOM'
        Add-Label $ovl 'aztRoomSeq';   A-Dd $ovl 0
        Add-Label $ovl 'aztRoomCue';   A-Dd $ovl 0
        Add-Label $ovl 'aztRoomSig';   A-Dd $ovl 0
        Add-Label $ovl 'aztRoomRoot';  A-Dd $ovl 0
        Add-Label $ovl 'aztRoomPad';   A-Db $ovl (New-Object byte[] 12)
        Add-Label $ovl 'aztScnDepth';  A-Dd $ovl 0
        Add-Label $ovl 'aztScnCount';  A-Dd $ovl 0
        Add-Label $ovl 'aztScnRootH';  A-Dd $ovl 0    # survives the INT 21h create
        Add-Label $ovl 'aztScnMeshP';  A-Dd $ovl 0    # the node's Mesh, 0 if none
    }

    if ($ENABLE_GEO_LOG) {
        Add-Label $ovl 'aztGeoName2';  A-Asciiz $ovl $GEO_LOG_NAME
        Add-Label $ovl 'aztGeoHandle'; A-Dw $ovl 0

        # ONE CONTIGUOUS 144-BYTE HEADER, written by a single INT 21h AH=40h and
        # followed immediately by the three payloads. Decoded by tools\Export-Obj.ps1.
        #   +0x00 'GEO1'  +0x04 frame  +0x08 depth
        #   +0x0C vCount  +0x10 fCount +0x14 nCount
        #   +0x18 vBase   +0x1C fBase  +0x20 nBase    (bases: for index recovery --
        #   +0x24 mesh                                 faces point, they do not index)
        #   +0x28 world 4x4 (64)   +0x68 name (32)   +0x88 pad (8)
        Add-Label $ovl 'aztGeoRec';   A-Dd32 $ovl 0x314F4547   # 'GEO1'
        Add-Label $ovl 'aztGeoFrame'; A-Dd $ovl 0
        Add-Label $ovl 'aztGeoDepth'; A-Dd $ovl 0
        Add-Label $ovl 'aztGeoVCnt';  A-Dd $ovl 0
        Add-Label $ovl 'aztGeoFCnt';  A-Dd $ovl 0
        Add-Label $ovl 'aztGeoNCnt';  A-Dd $ovl 0
        Add-Label $ovl 'aztGeoVBase'; A-Dd $ovl 0
        Add-Label $ovl 'aztGeoFBase'; A-Dd $ovl 0
        Add-Label $ovl 'aztGeoNBase'; A-Dd $ovl 0
        Add-Label $ovl 'aztGeoMesh';  A-Dd $ovl 0
        Add-Label $ovl 'aztGeoWorld'; A-Db $ovl (New-Object byte[] 64)
        Add-Label $ovl 'aztGeoName';  A-Db $ovl (New-Object byte[] 32)
        Add-Label $ovl 'aztGeoLocal'; A-Db $ovl (New-Object byte[] 64)   # frame+0x4C
        Add-Label $ovl 'aztGeoTex0';  A-Db $ovl (New-Object byte[] 128)  # face[0]+0x3C
        Add-Label $ovl 'aztGeoMat0';  A-Db $ovl (New-Object byte[] 128)  # face[0]+0x40
        Add-Label $ovl 'aztGeoPad';   A-Db $ovl (New-Object byte[] 8)
    }

    if ($ENABLE_TEX_LOG) {
        Add-Label $ovl 'aztTexName';   A-Asciiz $ovl $TEX_LOG_NAME
        Add-Label $ovl 'aztTexHandle'; A-Dw $ovl 0
        Add-Label $ovl 'aztTexCnt';    A-Dd $ovl 0
        Add-Label $ovl 'aztTexTab';    A-Db $ovl (New-Object byte[] ($TEX_TAB_SLOTS*4))
        Add-Label $ovl 'aztTexFCnt';   A-Dd $ovl 0    # the mesh's face count
        Add-Label $ovl 'aztTexFBase';  A-Dd $ovl 0    # its inline Face array
        Add-Label $ovl 'aztTexFIdx';   A-Dd $ovl 0    # which face we are on
        Add-Label $ovl 'aztTexSeenN';  A-Dd $ovl 0    # filename hashes seen this session
        Add-Label $ovl 'aztTexSeen';   A-Db $ovl (New-Object byte[] ($TEX_SEEN_SLOTS*4))

        # ONE CONTIGUOUS 64-BYTE HEADER, then the payloads. Lengths are logged so the
        # decoder re-derives the layout instead of assuming it.
        Add-Label $ovl 'aztTexRec';      A-Dd32 $ovl 0x31584554   # 'TEX1'
        Add-Label $ovl 'aztTexPtr';      A-Dd $ovl 0
        Add-Label $ovl 'aztTexHnd';      A-Dd $ovl 0
        Add-Label $ovl 'aztTexW';        A-Dd $ovl 0
        Add-Label $ovl 'aztTexH';        A-Dd $ovl 0
        Add-Label $ovl 'aztTexL2';       A-Dd $ovl 0
        Add-Label $ovl 'aztTexP04';      A-Dd $ovl 0
        Add-Label $ovl 'aztTexP20';      A-Dd $ovl 0
        Add-Label $ovl 'aztTexP24';      A-Dd $ovl 0
        Add-Label $ovl 'aztTexP54';      A-Dd $ovl 0
        Add-Label $ovl 'aztTexProbeLen'; A-Dd $ovl 0
        Add-Label $ovl 'aztTexBufLen';   A-Dd $ovl 0
        Add-Label $ovl 'aztTexPalLen';   A-Dd $ovl 0
        Add-Label $ovl 'aztTexName64'; A-Db $ovl (New-Object byte[] 64)   # the .azf name
        Add-Label $ovl 'aztTexHash';   A-Dd $ovl 0
        Add-Label $ovl 'aztTexRepeat'; A-Dd $ovl 0
        Add-Label $ovl 'aztTexPix';      A-Dd $ovl 0
        Add-Label $ovl 'aztTexPal';      A-Dd $ovl 0
        Add-Label $ovl 'aztTexPad';      A-Db $ovl (New-Object byte[] 4)
    }

    if ($ENABLE_ANI_LOG) {
        Add-Label $ovl 'aztAniName';   A-Asciiz $ovl $ANI_LOG_NAME
        Add-Label $ovl 'aztAniHandle'; A-Dw $ovl 0
        Add-Label $ovl 'aztAniList';   A-Dd $ovl 0
        Add-Label $ovl 'aztAniCount';  A-Dd $ovl 0

        # 96-byte Animation header: 'ANI1', frame, anim ptr, the 76-byte object, pad
        Add-Label $ovl 'aztAniRec';    A-Dd32 $ovl 0x31494E41   # 'ANI1'
        Add-Label $ovl 'aztAniFrame';  A-Dd $ovl 0
        Add-Label $ovl 'aztAniPtr';    A-Dd $ovl 0
        Add-Label $ovl 'aztAniObj';    A-Db $ovl (New-Object byte[] 76)
        Add-Label $ovl 'aztAniPad';    A-Db $ovl (New-Object byte[] 8)

        # 36-byte key: 'AKEY', which list, the node pointer, 28 raw bytes
        Add-Label $ovl 'aztAniKeyRec';  A-Dd32 $ovl 0x59454B41  # 'AKEY'
        Add-Label $ovl 'aztAniKeyList'; A-Dd $ovl 0
        Add-Label $ovl 'aztAniKeyPtr';  A-Dd $ovl 0
        Add-Label $ovl 'aztAniKeyData'; A-Db $ovl (New-Object byte[] 28)

        # ONE CONTIGUOUS 160-BYTE NODE RECORD -- see the assertion in the build.
        #   +0x000 'SNOD'  +0x004 object  +0x008 depth
        #   +0x00C frame header, 76 raw bytes from [obj+0x00]
        #   +0x058 world 4x4, 64 bytes from [obj+0x90]
        #   +0x098 tail, 112 bytes from [obj+0xD0]  -- previously unsampled
        #   +0x108 64 bytes from *[obj+0x20]        -- candidate, cleared if null
        #   +0x148 64 bytes from *[obj+0x24]        -- candidate, cleared if null
        #   +0x188 pad                                              = 0x190
        Add-Label $ovl 'aztScnRec';    A-Dd32 $ovl 0x444F4E53   # 'SNOD'
        Add-Label $ovl 'aztScnObj';    A-Dd $ovl 0
        Add-Label $ovl 'aztScnDepthF'; A-Dd $ovl 0
        Add-Label $ovl 'aztScnHdr';    A-Db $ovl (New-Object byte[] 76)
        Add-Label $ovl 'aztScnWorld';  A-Db $ovl (New-Object byte[] 64)
        Add-Label $ovl 'aztScnTail';   A-Db $ovl (New-Object byte[] 112)
        Add-Label $ovl 'aztScnRest';   A-Db $ovl (New-Object byte[] 416)   # obj+0x140..0x2DF
        Add-Label $ovl 'aztScnVis0';   A-Db $ovl (New-Object byte[] 128)   # first Visual
        Add-Label $ovl 'aztScnA1';     A-Db $ovl (New-Object byte[] 128)   # *[mesh+0x50]
        Add-Label $ovl 'aztScnA2';     A-Db $ovl (New-Object byte[] 128)   # *[mesh+0x5C]
        Add-Label $ovl 'aztScnA3';     A-Db $ovl (New-Object byte[] 128)   # *[mesh+0x68]
        Add-Label $ovl 'aztScnF0';     A-Db $ovl (New-Object byte[] 128)   # *(arr2[0])
        Add-Label $ovl 'aztScnP20';    A-Db $ovl (New-Object byte[] 64)
        Add-Label $ovl 'aztScnP24';    A-Db $ovl (New-Object byte[] 64)
        Add-Label $ovl 'aztScnPad';    A-Db $ovl (New-Object byte[] 8)
    }

    # ---- CD AUDIO (phase A: prove DPMI + MSCDEX from protected mode) --------
    #
    # The game has NO audio playback path -- all music is MIDI through Miles. To
    # play a recorded track the only route is CD redbook audio, which means calling
    # MSCDEX (INT 2Fh AX=1510h) from a DOS/4GW protected-mode binary. That needs
    # DPMI: a real-mode buffer for the request block (INT 31h AX=0100h) and a
    # real-mode call to deliver it (AX=0300h with a 50-byte RMCS).
    #
    # VALIDATED OUTSIDE THE GAME FIRST. A hand-assembled real-mode CDTEST.COM
    # issued exactly this request block against the same CUE and returned PLAY OK
    # with audible output, so the request layout, the drive lookup and the sector
    # arithmetic are known good. What is unproven is only the DPMI marshalling.
    #
    # PHASE A DOES NOT HOOK THE MUSIC. It starts the track at overlay init and
    # loops it from the frame poll. That is deliberate: the music functions can run
    # before the overlay is resident, and a patch site jumping into zeroed BSS
    # would execute 0x00 0x00 pairs and crash. Wiring the cues needs a trampoline
    # that is safe before load, which is phase B.
    #
    # EVERY FAILURE PATH FALLS BACK TO MIDI. If the allocation fails, or MSCDEX is
    # absent, aztCdOk stays 0 and nothing else is attempted.
    Add-Label $ovl 'AztCdInit'
    if ($ENABLE_CD_AUDIO) {
        A-MovEaxImm $ovl 0x0100                    # DPMI: allocate DOS memory
        A-MovEbxImm $ovl 4                         # 4 paragraphs = 64 bytes
        A-Int $ovl 0x31
        A-JbS $ovl 'ACI_fail'                      # CF = no low memory
        A-MovzxEaxAx $ovl                          # AX = real-mode segment
        A-MovSiEax32 $ovl 'aztCdSeg'
        A-ShlEaxImm $ovl 4                         # linear = segment * 16, and the
        A-MovSiEax32 $ovl 'aztCdLin'               # low 1 MB is identity-mapped
        A-MovDwordSiImm $ovl 'aztRmEax' 0x1500     # MSCDEX: get drive info
        A-MovDwordSiImm $ovl 'aztRmEbx' 0
        A-Call $ovl 'AztRmInt2F'
        A-MovEaxSi $ovl 'aztRmEbx'                 # EBX = number of CD drives
        A-TestEaxEax $ovl
        A-JzS $ovl 'ACI_fail'
        A-MovEaxSi $ovl 'aztRmEcx'                 # ECX = first CD drive letter
        A-AndEaxImm $ovl 0xFFFF
        A-MovSiEax32 $ovl 'aztCdDrive'
        A-MovDwordSiImm $ovl 'aztCdOk' 1
        if ($CD_DIAG) {
            A-MovEcxImm $ovl 0                     # attributes
            A-MovAhImm  $ovl 0x3C                  # create/truncate AZTCD.LOG
            A-LeaEdxSi  $ovl 'aztCdLogName'
            A-Int       $ovl 0x21
            A-JbS       $ovl 'ACI_nolog'
            A-MovSiAx   $ovl 'aztCdLogH'
            Add-Label $ovl 'ACI_nolog'
        }
        A-Ret $ovl
        Add-Label $ovl 'ACI_fail'
        A-MovDwordSiImm $ovl 'aztCdOk' 0
    }
    A-Ret $ovl

    # Invoke INT 2Fh in real mode. Caller has already filled aztRmEax/Ebx/Ecx and,
    # for a device request, aztRmEs. SS:SP left zero so DPMI supplies a stack.
    Add-Label $ovl 'AztRmInt2F'
    if ($ENABLE_CD_AUDIO) {
        A-MovDwordSiImm $ovl 'aztRmSp' 0           # zeroes SP and SS together
        A-MovWordSiImm  $ovl 'aztRmFlags' 0
        A-PushDsPopEs $ovl                         # ES:EDI must address the RMCS
        A-LeaEdiSi $ovl 'aztRmcs'
        A-MovEaxImm $ovl 0x0300                    # DPMI: simulate real-mode int
        A-MovEbxImm $ovl 0x2F                      # BL = 2Fh, BH = 0
        A-MovEcxImm $ovl 0                         # no stack words to copy
        A-Int $ovl 0x31
    }
    A-Ret $ovl

    # ---- DIAGNOSTIC: what actually drives the CD player ---------------------
    # eax = event code, edx = value. Appends 8 bytes to AZTCD.LOG so a reproduction
    # can be read back offline. Two theories about the MP3 doubling on a volume
    # change have now been wrong -- and the slot provably does NOT change when the
    # slider moves, since neither of 0x152AD0's two writers is on that path -- so
    # this records what really happens rather than guessing a third time.
    #   1 = AztCdSwitch entered   2 = Play issued   3 = Stop issued   4 = loop restart
    Add-Label $ovl 'AztCdLog'
    if ($ENABLE_CD_AUDIO -and $CD_DIAG) {
        A-Pushad $ovl
        A-MovSiEax32 $ovl 'aztLogRec'
        A-MovSiEdx32 $ovl 'aztLogRec2'
        A-MovAxSi $ovl 'aztCdLogH'
        A-TestAxAx $ovl
        A-JzS $ovl 'ACL_out'
        A-MovBxSi $ovl 'aztCdLogH'
        A-MovAhImm $ovl 0x40
        A-MovEcxImm $ovl 8
        A-LeaEdxSi $ovl 'aztLogRec'
        A-Int $ovl 0x21
        A-MovBxSi $ovl 'aztCdLogH'
        A-MovAhImm $ovl 0x68                       # commit, so a quit keeps the log
        A-Int $ovl 0x21
        Add-Label $ovl 'ACL_out'
        A-Popad $ovl
    }
    A-Ret $ovl

    # eax = track slot 0..10. Returns eax = 1 if CD audio started, 0 to use MIDI.
    Add-Label $ovl 'AztCdPlay'
    if ($ENABLE_CD_AUDIO) {
        # EDI IS THE OBJ2 DELTA and this routine uses it to address the request
        # buffer. The poll needs it afterwards to reach the MIDI volume word, so it
        # is saved across the whole body rather than recomputed.
        A-PushEdi $ovl
        A-CmpDwordSiImm $ovl 'aztCdOk' 0
        A-Jz $ovl 'ACP_no'
        # IDEMPOTENT. Re-issuing Play for a track already playing starts it over the
        # top of itself rather than repositioning, which was heard as the same MP3
        # doubling when the volume slider re-triggered a switch. The loop path
        # clears aztCdCur first, so a genuine restart still gets through.
        A-CmpDwordSiImm $ovl 'aztCdCur' 0
        A-JzS $ovl 'ACP_go'
        A-CmpEaxSi $ovl 'aztCdIdx'
        A-JnzS $ovl 'ACP_go'
        A-PopEdi $ovl
        A-MovEaxImm $ovl 1                         # already playing it: report success
        A-Ret $ovl
        Add-Label $ovl 'ACP_go'
        A-MovSiEax32 $ovl 'aztCdIdx'               # remember it, for looping
        A-Db $ovl @(0x89,0xC2)                     # mov edx, eax
        A-Db $ovl @(0x6B,0xD2,0x0C)                # imul edx, edx, 12
        A-LeaEaxSi $ovl 'aztCdTab'
        A-Db $ovl @(0x01,0xD0)                     # add eax, edx  -> table entry
        A-Db $ovl @(0x8B,0x18)                     # mov ebx, [eax]      start LBA
        A-Db $ovl @(0x85,0xDB)                     # test ebx, ebx
        A-Jz $ovl 'ACP_no'                        # 0 = no audio for this slot
        A-PushEax $ovl
        A-MovEaxSi $ovl 'aztCdLin'
        A-Db $ovl @(0x89,0xC7)                     # mov edi, eax
        A-PopEax $ovl
        A-Db $ovl @(0xC6,0x47,0x00,0x16)           # mov byte [edi+0], 22   length
        A-Db $ovl @(0xC6,0x47,0x01,0x00)           # mov byte [edi+1], 0    subunit
        A-Db $ovl @(0xC6,0x47,0x02,0x84)           # mov byte [edi+2], 132  play
        A-Db $ovl @(0x66,0xC7,0x47,0x03,0x00,0x00) # mov word [edi+3], 0    status
        A-Db $ovl @(0xC7,0x47,0x05,0x00,0x00,0x00,0x00)
        A-Db $ovl @(0xC7,0x47,0x09,0x00,0x00,0x00,0x00)
        A-Db $ovl @(0xC6,0x47,0x0D,0x00)           # mov byte [edi+13], 0   HSG
        A-Db $ovl @(0x89,0x5F,0x0E)                # mov [edi+14], ebx      start
        A-Db $ovl @(0x8B,0x48,0x04)                # mov ecx, [eax+4]       sectors
        A-Db $ovl @(0x89,0x4F,0x12)                # mov [edi+18], ecx
        if ($CD_DIAG) {
            A-PushEax $ovl
            A-MovEdxSi32 $ovl 'aztCdIdx'
            A-MovEaxImm $ovl 2                     # 2 = a Play was really issued
            A-Call $ovl 'AztCdLog'
            A-PopEax $ovl
        }
        A-MovDwordSiImm $ovl 'aztRmEax' 0x1510     # MSCDEX: send device request
        A-MovDwordSiImm $ovl 'aztRmEbx' 0          # request is at segment:0000
        A-PushEax $ovl
        A-MovEaxSi $ovl 'aztCdDrive'
        A-MovSiEax32 $ovl 'aztRmEcx'
        A-MovEaxSi $ovl 'aztCdSeg'
        A-MovSiAx $ovl 'aztRmEs'
        A-PopEax $ovl
        A-Db $ovl @(0x8B,0x48,0x08)                # mov ecx, [eax+8]  duration us
        A-PushEcx $ovl
        A-Call $ovl 'AztRmInt2F'
        A-Call $ovl $tAsm.Labels['AztNow']         # eax = now, in microseconds
        A-PopEcx $ovl
        # START AND DURATION, NOT AN END TIME. AztNow is the BIOS tick at 0x46C scaled to
        # microseconds and truncated to 32 bits, and that tick counts from MIDNIGHT -- so
        # `now` wraps every ~71.6 minutes of wall-clock time whatever the game is doing.
        # Storing now+duration overflowed whenever the game was launched inside the last
        # few minutes of a wrap window, and `now >= end` was then true on the very next
        # frame and every frame after: the track restarted continuously and no music was
        # ever heard. Comparing ELAPSED against the duration is wrap-safe, because the
        # subtraction stays correct modulo 2^32 for any interval shorter than the wrap.
        A-MovSiEax32 $ovl 'aztCdStart'
        A-Db $ovl @(0x89,0xC8)                     # mov eax, ecx
        A-MovSiEax32 $ovl 'aztCdDur'
        A-MovDwordSiImm $ovl 'aztCdCur' 1
        A-PopEdi $ovl
        A-MovEaxImm $ovl 1
        A-Ret $ovl
        Add-Label $ovl 'ACP_no'
        A-PopEdi $ovl
    }
    A-XorEaxEax $ovl
    A-Ret $ovl

    Add-Label $ovl 'AztCdStop'
    if ($ENABLE_CD_AUDIO) {
        A-PushEdi $ovl
        A-CmpDwordSiImm $ovl 'aztCdCur' 0
        A-JzS $ovl 'ACSt_out'
        A-MovEaxSi $ovl 'aztCdLin'
        A-Db $ovl @(0x89,0xC7)                     # mov edi, eax
        # ITS OWN BUFFER, AT +48. This used to be built over the play request at
        # +0, and the stop then had no audible effect even though the identical
        # request works from a real-mode test program -- so the command and the
        # emulator are both fine, and overwriting a block MSCDEX may still be
        # holding was the only structural difference. +0 is the play request, +32
        # the volume control block, +48 this one; all inside the 64-byte allocation.
        A-Db $ovl @(0xC6,0x47,0x30,0x0D)           # mov byte [edi+48], 13  length
        A-Db $ovl @(0xC6,0x47,0x31,0x00)           # subunit
        A-Db $ovl @(0xC6,0x47,0x32,0x85)           # command 133 = stop audio
        A-Db $ovl @(0x66,0xC7,0x47,0x33,0x00,0x00) # status
        A-Db $ovl @(0xC7,0x47,0x35,0x00,0x00,0x00,0x00)   # reserved, +53
        A-Db $ovl @(0xC7,0x47,0x39,0x00,0x00,0x00,0x00)   # reserved, +57
        if ($CD_DIAG) {
            A-MovEaxImm $ovl 3                     # 3 = Stop issued
            A-XorEdxEdx $ovl
            A-Call $ovl 'AztCdLog'
        }
        A-MovDwordSiImm $ovl 'aztRmEax' 0x1510
        A-MovDwordSiImm $ovl 'aztRmEbx' 48         # the request is at segment:0030
        A-MovEaxSi $ovl 'aztCdDrive'
        A-MovSiEax32 $ovl 'aztRmEcx'
        A-MovEaxSi $ovl 'aztCdSeg'
        A-MovSiAx $ovl 'aztRmEs'
        A-Call $ovl 'AztRmInt2F'
        A-MovDwordSiImm $ovl 'aztCdCur' 0
        Add-Label $ovl 'ACSt_out'
        A-PopEdi $ovl
    }
    A-Ret $ovl

    # eax = slot. Starts CD audio for it and mutes the MIDI, or stops CD audio and
    # gives the MIDI its volume back.
    #
    # MUTING RATHER THAN INTERCEPTING. The obvious approach is to stop the play
    # call reaching Miles, but that means hooking functions that can run before the
    # overlay is resident. Driving the volume word the options slider already
    # writes does the same job from the frame poll, with no extra patch sites --
    # and it was proven by hand: turning music to 0 in-game silenced the MIDI while
    # the CD track kept playing.
    Add-Label $ovl 'AztCdSwitch'
    if ($ENABLE_CD_AUDIO) {
        if ($CD_DIAG) {
            A-PushEax $ovl
            A-Db $ovl @(0x89,0xC2)                 # mov edx, eax   (the slot)
            A-MovEaxImm $ovl 1
            A-Call $ovl 'AztCdLog'
            A-PopEax $ovl
        }
        A-PushEax $ovl                             # keep the slot
        A-Call $ovl 'AztCdPlay'                    # eax = 1 if CD audio started
        A-PushEax $ovl
        A-TestEaxEax $ovl
        A-JnzS $ovl 'ACSw_nostop'
        A-Call $ovl 'AztCdStop'                    # MIDI cue: make sure CD is idle
        Add-Label $ovl 'ACSw_nostop'
        A-PopEcx $ovl                              # ecx = did CD start?
        A-PopEax $ovl                              # eax = slot
        # Rebuild the track record the way the options slider does at 0x14D7E:
        # record = obj2delta + 0x152A34 + slot*12.
        A-Db $ovl @(0x89,0xC2)                     # mov edx, eax
        A-Db $ovl @(0x6B,0xD2,0x0C)                # imul edx, edx, 12
        A-Db $ovl @(0x89,0xF8)                     # mov eax, edi
        A-AddEaxImm32 $ovl 0x152A34
        A-Db $ovl @(0x01,0xD0)                     # add eax, edx
        A-Db $ovl @(0x85,0xC9)                     # test ecx, ecx
        A-JnzS $ovl 'ACSw_mute'
        # MIDI cue. 0x3B048 EARLY-OUTS WHEN [eax+8] IS STILL 0 -- that field is the
        # loaded sequence, and on the frame a room changes the game has set the cue
        # but not yet loaded the XMI. Restoring the volume then does nothing at all,
        # the sequencer stays at the 0 we set for the CD room, and the new room
        # plays silently. So only clear aztCdMuted once the call can actually land;
        # until then the poll retries every frame.
        A-Db $ovl @(0x83,0x78,0x08,0x00)           # cmp dword [eax+8], 0
        A-JnzS $ovl 'ACSw_loaded'
        if ($CD_DIAG) {
            A-PushEax $ovl
            A-MovEaxImm $ovl 5                     # 5 = restore skipped, no sequence
            A-XorEdxEdx $ovl
            A-Call $ovl 'AztCdLog'
            A-PopEax $ovl
        }
        A-JmpS $ovl 'ACSw_done'
        Add-Label $ovl 'ACSw_loaded'
        A-MovEdxDi $ovl 0x14693E                   # the player's own slider value
        A-Db $ovl @(0xC1,0xFA,0x10)                # sar edx, 16
        A-MovDwordSiImm $ovl 'aztCdMuted' 0
        A-JmpS $ovl 'ACSw_go'
        Add-Label $ovl 'ACSw_mute'
        A-XorEdxEdx $ovl                           # volume 0 under the CD track
        A-MovDwordSiImm $ovl 'aztCdMuted' 1
        Add-Label $ovl 'ACSw_go'
        # VOLUME IS AN ARGUMENT, NOT A VARIABLE. Writing 0x146940 does nothing to a
        # sequence that is already playing -- that was the first attempt and the
        # MIDI simply kept going. The slider sets volume by RE-PLAYING the current
        # track through 0x3B048 with the level in edx, so that is what happens here.
        A-Call $ovl ([uint32]0x3B048)
        Add-Label $ovl 'ACSw_done'
    }
    A-Ret $ovl

    # Re-assert the mute on the cue that is currently playing from CD.
    #
    # THE VOLUME SLIDER UN-MUTES US. Muting works by re-playing the cue at volume 0
    # through 0x3B048, and that is exactly what the slider does with its own level --
    # so moving it puts the MIDI straight back underneath the CD track. Because the
    # recorded track is a re-recording of the same cue, that reads as the MP3
    # doubling rather than as two different pieces, which is how it was reported.
    #
    # Proven by the diagnostic log: one SWITCH and one PLAY, no second Play and no
    # loop timer, so the CD player was never the thing making a second sound.
    Add-Label $ovl 'AztCdMuteNow'
    if ($ENABLE_CD_AUDIO) {
        A-MovEaxSi $ovl 'aztCdSlot'
        A-Db $ovl @(0x89,0xC2)                     # mov edx, eax
        A-Db $ovl @(0x6B,0xD2,0x0C)                # imul edx, edx, 12
        A-Db $ovl @(0x89,0xF8)                     # mov eax, edi
        A-AddEaxImm32 $ovl 0x152A34
        A-Db $ovl @(0x01,0xD0)                     # add eax, edx -> the record
        A-Db $ovl @(0x83,0x78,0x08,0x00)           # cmp dword [eax+8], 0
        A-JnzS $ovl 'ACMn_go'
        if ($CD_DIAG) {
            A-MovEaxImm $ovl 8                     # 8 = mute SKIPPED, no sequence
            A-XorEdxEdx $ovl
            A-Call $ovl 'AztCdLog'
        }
        A-JmpS $ovl 'ACMn_out'
        Add-Label $ovl 'ACMn_go'
        A-XorEdxEdx $ovl
        A-Call $ovl ([uint32]0x3B048)
        Add-Label $ovl 'ACMn_out'
    }
    A-Ret $ovl

    # eax = the MIDI-scale level (0..127) the slider just derived. Sets the CD
    # audio channel volume to match, so the in-game music slider controls the
    # recorded track instead of being inert.
    #
    # Without this there is no way to change the MP3's level from inside the game at
    # all: CD audio is a separate mixer channel and the slider only ever spoke to
    # the MIDI synth. MSCDEX exposes it as IOCTL Output control block 3 (Audio
    # Channel Control), which sets the level for each output channel.
    #
    # The control block goes at +32 in the same 64-byte real-mode buffer the play
    # request uses at +0, so no second allocation is needed.
    Add-Label $ovl 'AztCdSetVol'
    if ($ENABLE_CD_AUDIO) {
        A-PushEdi $ovl
        A-Db $ovl @(0xD1,0xE0)                     # shl eax,1   0..127 -> 0..254
        A-CmpEaxImm $ovl 255
        A-JbeS $ovl 'ACSv_ok'
        A-MovEaxImm $ovl 255
        Add-Label $ovl 'ACSv_ok'
        A-PushEax $ovl
        A-MovEaxSi $ovl 'aztCdLin'
        A-Db $ovl @(0x89,0xC7)                     # mov edi, eax
        A-PopEax $ovl                              # al = volume
        A-Db $ovl @(0xC6,0x47,0x20,0x03)           # +32 code 3: channel control
        A-Db $ovl @(0xC6,0x47,0x21,0x00)           # +33 input for output 0
        A-Db $ovl @(0x88,0x47,0x22)                # +34 volume 0
        A-Db $ovl @(0xC6,0x47,0x23,0x01)           # +35 input for output 1
        A-Db $ovl @(0x88,0x47,0x24)                # +36 volume 1
        A-Db $ovl @(0xC6,0x47,0x25,0x02)           # +37/38 output 2 silent
        A-Db $ovl @(0xC6,0x47,0x26,0x00)
        A-Db $ovl @(0xC6,0x47,0x27,0x03)           # +39/40 output 3 silent
        A-Db $ovl @(0xC6,0x47,0x28,0x00)
        A-Db $ovl @(0xC6,0x47,0x00,0x1A)           # request: length 26
        A-Db $ovl @(0xC6,0x47,0x01,0x00)           # subunit
        A-Db $ovl @(0xC6,0x47,0x02,0x0C)           # command 12 = IOCTL output
        A-Db $ovl @(0x66,0xC7,0x47,0x03,0x00,0x00) # status
        A-Db $ovl @(0xC7,0x47,0x05,0x00,0x00,0x00,0x00)
        A-Db $ovl @(0xC7,0x47,0x09,0x00,0x00,0x00,0x00)
        A-Db $ovl @(0xC6,0x47,0x0D,0x00)           # media descriptor
        A-MovEaxSi $ovl 'aztCdSeg'
        A-ShlEaxImm $ovl 16
        A-Db $ovl @(0x83,0xC8,0x20)                # or eax,32 -> seg:0020
        A-Db $ovl @(0x89,0x47,0x0E)                # +14 transfer address
        A-Db $ovl @(0x66,0xC7,0x47,0x12,0x09,0x00) # +18 byte count = 9
        A-MovDwordSiImm $ovl 'aztRmEax' 0x1510
        A-MovDwordSiImm $ovl 'aztRmEbx' 0
        A-MovEaxSi $ovl 'aztCdDrive'
        A-MovSiEax32 $ovl 'aztRmEcx'
        A-MovEaxSi $ovl 'aztCdSeg'
        A-MovSiAx $ovl 'aztRmEs'
        A-Call $ovl 'AztRmInt2F'
        A-PopEdi $ovl
    }
    A-Ret $ovl

    # Hand the sequencer its volume back for whatever cue is current. Used when F4
    # switches to the original score; the slot's sequence is loaded by then, since
    # the room has been playing, so this does not need the retry the room-change
    # path does.
    Add-Label $ovl 'AztCdUnmute'
    if ($ENABLE_CD_AUDIO) {
        A-MovEaxSi $ovl 'aztCdSlot'
        A-CmpEaxImm $ovl 11                        # unsigned, so -1 fails this too
        A-JaeS $ovl 'ACU_out'
        A-Db $ovl @(0x89,0xC2)                     # mov edx, eax
        A-Db $ovl @(0x6B,0xD2,0x0C)                # imul edx, edx, 12
        A-Db $ovl @(0x89,0xF8)                     # mov eax, edi
        A-AddEaxImm32 $ovl 0x152A34
        A-Db $ovl @(0x01,0xD0)                     # add eax, edx -> the record
        A-Db $ovl @(0x83,0x78,0x08,0x00)           # cmp dword [eax+8], 0
        A-JzS $ovl 'ACU_out'
        # RESTART IT, do not merely un-mute. The sequencer is never stopped -- only
        # driven to volume 0 -- so on its own it keeps running underneath the CD
        # track and comes back mid-phrase, which is heard as "one carries on while
        # the other starts over". 0x3B088 with edx=0, ebx=0x2710 is exactly how the
        # game starts a cue on a room change (0x11231), so this replays it from the
        # beginning; 0x3B048 then sets the level, as the options slider does.
        A-PushEax $ovl
        A-XorEdxEdx $ovl
        A-MovEbxImm $ovl 0x2710
        A-Call $ovl ([uint32]0x3B088)
        A-PopEax $ovl
        A-MovEdxDi $ovl 0x14693E                   # the player's own slider value
        A-Db $ovl @(0xC1,0xFA,0x10)                # sar edx, 16
        A-Call $ovl ([uint32]0x3B048)
        Add-Label $ovl 'ACU_out'
    }
    A-Ret $ovl

    # ===========================================================================
    #  Visor boot sequence -- PHASE 0: paint the viewport black, then hand over.
    # ===========================================================================
    # DO NOT SUPPRESS THE 3D PASS TO DO THIS. The first attempt held the engine's own
    # switch at 0x15257C to skip the 3D block, which is a state the game enters itself
    # for full-screen 2D views -- and it corrupted the WHOLE SCREEN: orange smear,
    # misplaced HUD, garbage on the first frame. Reverted. That matches the recorded
    # HUDTOP/HUDBOT.RES failure mode, where the HUD composites into the framebuffer
    # with stride-sensitive writes and produces exactly that smear when the surface
    # state it depends on has not been set up. Skipping the 3D block evidently leaves
    # that state unset at startup. The flag is fine to READ; do not hold it.
    #
    # Instead, let the 3D render normally and PAINT OVER IT through AztViewInject,
    # which is already hooked at 0x1419D, already proven (22 calls/sec, pixels
    # surviving at 100%), and already owns a 1024x576 staging buffer. It runs before
    # the HUD draws, so the panel stays on top and can narrate the boot. Zero control
    # flow is changed: we only set a flag the injection body already tests.
    #
    # TWO WAYS OUT, because a stuck flag means a viewport that never comes back:
    #   1. the normal duration expires;
    #   2. a hard cap fires regardless of state.
    # (2) is not redundant with (1): if a later phase wedges mid-animation the cap
    # still hands the view back. State 2 is terminal, so this runs once per process
    # and then returns on its second instruction forever after.
    #
    # DELIBERATELY NOT SKIPPABLE. An earlier version aborted on a key waiting in the
    # BIOS buffer at 0x41A, which killed the whole effect: the key pressed to dismiss
    # the intro movies is still pending there when the sequence starts, and nothing
    # drains it. No input is read at all now, so no input state can suppress it.
    if ($ENABLE_BOOT_SEQ) {
        # ---- the reticle gate -------------------------------------------------
        # 0x3C690 is a GENERIC draw primitive with 29 callers, so it cannot be suppressed
        # wholesale. Only the one call at 0x141B0 draws the reticle, and it runs just after
        # our injection site, which is why the reticle lands on top of the overlay. This
        # stub replaces that single call: while the boot is up it returns without drawing,
        # otherwise it tail-jumps to the real routine so nothing changes.
        #
        # The decision is made while esi is still the obj1 delta -- popfd would destroy the
        # flags, so each path restores and then acts, rather than branching after the pop.
        if ($BOOT_HIDE_RETICLE) {
            for ($gi = 0; $gi -lt $BOOT_RET_TARGETS.Count; $gi++) {
                Add-Label $ovl ("AztRetGate{0}" -f $gi)
                A-Pushfd $ovl
                A-Pushad $ovl
                A-CallNext $ovl
                Add-Label $ovl ("ARG{0}_ref" -f $gi)
                A-PopEax $ovl
                A-SubEaxImm $ovl ("ARG{0}_ref" -f $gi)
                A-MovEsiEax $ovl                 # esi = obj1 delta
                A-CmpDwordSiImm $ovl 'aztInjEnable' 0
                A-Jz $ovl ("ARG{0}_draw" -f $gi)
                A-Popad $ovl
                A-Popfd $ovl
                A-Ret $ovl                       # boot is up: no reticle
                Add-Label $ovl ("ARG{0}_draw" -f $gi)
                A-Popad $ovl
                A-Popfd $ovl
                A-Jmp $ovl ([uint32]$BOOT_RET_TARGETS[$gi])   # tail call, stack untouched
            }
        }

        # ---- hold the MIDI down under the boot effect --------------------------
        # The effect is CD audio; the room's cue is MIDI, and they are separate outputs, so
        # without this they simply play together. Normally AztCdSwitch mutes the sequencer
        # whenever a CD track takes over -- but the boot gates AztCdPoll off, so nothing
        # was doing that job.
        #
        # RUN IT EVERY FRAME, not once. 0x3B048 early-outs while [record+8] is still 0 --
        # that field is the loaded sequence, and on the frame a room changes the game has
        # set the cue but not yet loaded the XMI, so a single attempt silently does nothing.
        # Retrying costs one compare per frame and is how the CD path solves the same race.
        # Volume is an ARGUMENT to 0x3B048, not a variable: it re-plays the cue at edx.
        if ($ENABLE_CD_AUDIO) {
            Add-Label $ovl 'AztBootMute'
            A-Pushad $ovl
            A-MovzxEaxByteDi $ovl 0x152AD0             # the cue the game is asking for
            A-CmpEaxImm $ovl 11
            A-Jae $ovl 'ABM_out'                       # nonsense index: leave it alone
            A-Db $ovl @(0x89,0xC2)                     # mov edx, eax
            A-Db $ovl @(0x6B,0xD2,0x0C)                # imul edx, edx, 12
            A-Db $ovl @(0x89,0xF8)                     # mov eax, edi
            A-AddEaxImm32 $ovl 0x152A34
            A-Db $ovl @(0x01,0xD0)                     # add eax, edx -> the music record
            A-CmpDwordEaxDispImm $ovl 8 0
            A-Jz $ovl 'ABM_out'                        # no sequence loaded yet; try again
            A-XorEdxEdx $ovl                           # volume 0
            A-Call $ovl ([uint32]0x3B048)
            A-MovDwordSiImm $ovl 'aztCdMuted' 1
            Add-Label $ovl 'ABM_out'
            A-Popad $ovl
            A-Ret $ovl
        }

        # ---- TRIED AND REVERTED: zeroing the music volume global ------------------
        # The ~2 s ambient sound at the very start of a new game is NOT the room's MIDI cue
        # started through 0x3B048, however much it looks like it. All four callers of that
        # function (0x1154A, 0x13B18, 0x13E59, 0x14D94) take their volume the same way --
        # `mov edx,[0x14693E] / sar edx,0x10`, the player's 16.16 slider -- so zeroing that
        # global from AztCdBootStart should have made any cue started during the load silent.
        #
        # IT DID NOT. The sound was unchanged, which rules the theory out: whatever makes it
        # does not read that global. It also cost real latency -- the in-game music took
        # noticeably longer to arrive after the sequence, almost certainly because the cue
        # HAD been started at volume 0 and the volume is baked in at play time, so restoring
        # the global changed nothing until the next cue change re-played it.
        #
        # Left here as a dead end rather than deleted: the four call sites and the meaning of
        # 0x14693E are correct and worth keeping, it is the conclusion drawn from them that
        # was wrong. Next suspects are the PCM path (270 WAVs ship in GAME\AZRAEL, 22050/22222
        # Hz mono 8-bit) and anything the intro tears down on its way out.
        # ---- hold the HUD whoosh until the visor has finished booting -----------
        # hud3.wav: the ~2 s orchestral whoosh heard at the very start of a new game, which
        # belongs AFTER the boot sequence rather than before it -- it is the "you are here"
        # sting for the visor coming up, and it was landing while the visor was still warming.
        #
        # It is a PCM sample, not a cue and not a CD track, which is why muting the sequencer
        # did nothing. The string "hud3.wav" sits at obj2 0x143160 in the HUD resource block,
        # beside nbut0off.pcx and friends, and reaches 0x100BC from two sites: 0x2C2E8 inside
        # the HUD routine 0x2C2D4 (the startup path, via 0x16D92) and 0x2C85E.
        #
        # 0x100BC TAKES ONLY EAX. It sets ebx/ecx/edx itself and reads its volume from the SFX
        # global 0x14693C, so replaying the call later needs nothing but the string pointer --
        # no register capture, no guessing at an argument list.
        #
        # Both call sites are redirected here. While the boot is up the call is swallowed and
        # a debt recorded; afterwards it plays normally, so a HUD raised later in the game
        # still whooshes. The debt is a flag, not a count: the two sites firing together still
        # owes exactly one.
        if ($ENABLE_BOOT_SEQ) {
            Add-Label $ovl 'AztWhooshGate'
            A-Pushad $ovl
            A-Call $ovl $asm.Labels['AztDeltas']       # esi/edi: the call sites hold game regs
            A-CmpDwordSiImm $ovl 'aztBootState' 2
            A-Jae $ovl 'AWG_play'                      # boot over: behave exactly as before
            A-MovDwordSiImm $ovl 'aztWhooshOwed' 1
            A-Popad $ovl
            A-Ret $ovl                                 # swallowed; the caller cannot tell
            Add-Label $ovl 'AWG_play'
            A-Popad $ovl                               # eax is the string again
            A-Jmp $ovl ([uint32]0x100BC)               # tail call: its ret goes to the game

            # Called at ABT_finish. esi/edi are live there -- AztBootTick runs from
            # AztFrameAll, which is entered with both deltas set.
            Add-Label $ovl 'AztWhooshPlay'
            A-CmpDwordSiImm $ovl 'aztWhooshOwed' 0
            A-Jz $ovl 'AWP_out'
            A-MovDwordSiImm $ovl 'aztWhooshOwed' 0
            A-Pushad $ovl
            A-Db $ovl ([byte[]](@(0x8D,0x87) + [BitConverter]::GetBytes([uint32]0x143160)))  # lea eax,[edi+"hud3.wav"]
            A-Call $ovl ([uint32]0x100BC)
            A-Popad $ovl
            Add-Label $ovl 'AWP_out'
            A-Ret $ovl
        }

        Add-Label $ovl 'AztBootInit'
        A-MovDwordSiImm $ovl 'aztBootState' 0
        A-MovDwordSiImm $ovl 'aztBootT0'    0
        A-Ret $ovl

        # Black the staging buffer once, when the sequence starts. Phase 0 paints a
        # flat colour, so this is the whole picture; later phases redraw per frame.
        # pushad both saves the deltas and lets rep stosd have edi.
        Add-Label $ovl 'AztBootClear'
        A-Pushad      $ovl
        A-MovEaxSi    $ovl 'aztInjBufPtr'       # 0 = the allocation failed at init
        A-TestEaxEax  $ovl
        A-Jz          $ovl 'ABC_skip'
        A-MovEdiEax   $ovl
        # VARIABLE, not an immediate: the slip's brightness flash works by raising these two
        # for one frame, so the whole screen redraws brighter. They hold the normal colours
        # the rest of the time and are initialised to them, so a clear that happens before
        # anything sets them still paints the right amber.
        A-MovEaxSi    $ovl 'aztFillDw'                              # the amber screen
        A-MovEcxImm   $ovl ([int]($INJ_W * $INJ_H / 4))
        A-PushDsPopEs $ovl
        A-RepStosd    $ovl
        # CRT scanlines: every other row one step darker. Rows 1,3,..,575 -- ODD rows, which
        # is why BOOT_TXT_Y must be even: the readout's own background alternates in step
        # with this, so the text block does not read as a clean rectangle cut out of the
        # scanlines. Drawn once here, because nothing repaints the background afterwards.
        A-MovEaxSi   $ovl 'aztInjBufPtr'
        A-TestEaxEax $ovl
        A-Jz $ovl 'ABC_skip'
        # A BAND, not a row. Rows 0..SCAN_H-1 are bright, SCAN_H..2*SCAN_H-1 dark, so
        # the first dark band starts at row SCAN_H and each pass writes SCAN_H rows
        # then skips SCAN_H. At SCAN_H = 1 this is byte-identical to the old "start on
        # row 1, write one row, skip one".
        A-AddEaxImm  $ovl ([uint32]($INJ_W * $BOOT_SCAN_H))     # first dark band
        A-MovEdiEax  $ovl
        A-MovEbxImm  $ovl ([int]($INJ_H / (2 * $BOOT_SCAN_H)))  # how many dark bands
        Add-Label $ovl 'ABC_scan'
        A-MovEcxImm $ovl ([int]($INJ_W * $BOOT_SCAN_H / 4))
        A-MovEaxSi  $ovl 'aztScanDw'
        A-RepStosd  $ovl                         # one dark BAND
        A-Db   $ovl @(0x81,0xC7)                 # add edi, imm32 -- skip the bright band
        A-Dd32 $ovl ([uint32]($INJ_W * $BOOT_SCAN_H))
        A-Db $ovl @(0x4B)                        # dec ebx
        A-Jnz $ovl 'ABC_scan'

        Add-Label $ovl 'ABC_skip'
        A-Popad $ovl
        A-Ret   $ovl

        # Emits "ecx = how many of family N to draw this frame", read from aztBootDisTab.
        # One scriptblock rather than three copies: the three families differ only by a
        # 4-byte offset into the stage row, and three hand-written copies of a div/mul
        # sequence is three chances to mistype one.
        #
        # ORDER MATTERS: mul writes edx, so the lea that loads the table base has to come
        # after it, not before. ebx holds the staging buffer throughout AztBootGlitch and
        # esi is the obj1 delta -- neither is touched here.
        $EmitStageCount = {
            param($a, $fam)
            A-MovEaxSi  $a 'aztBootEl'
            A-XorEdxEdx $a                       # div reads edx:eax
            A-MovEcxImm $a ([int]$BOOT_DIS_STAGE_US)
            A-DivEcx    $a                       # eax = stage index
            A-MovEcxImm $a 20                    # 5 dwords per stage row
            A-MulEcx    $a
            if ($fam -ne 0) { A-AddEaxImm32 $a ([uint32]($fam * 4)) }
            A-LeaEdxSi  $a 'aztBootDisTab'
            A-Db $a @(0x01,0xD0)                 # add eax, edx
            A-Db $a @(0x8B,0x08)                 # mov ecx, [eax]
        }

        # ---- damaged-visor disruption ----------------------------------------
        # Static streaks and brightened edges over the first few seconds, thinning out as the
        # visor stabilises. It has to REDRAW THE BACKGROUND every frame, because the streaks
        # are scattered and there is no record of where the last frame put them -- so this
        # runs AztBootClear first and the banner is drawn over it afterwards.
        #
        # A plain 32-bit LCG supplies the randomness; the low bits of an LCG are famously
        # poor, so every field is taken from the HIGH end of the word. Extents are masked
        # rather than divided (x is 0..1023, row 0..511 inside 576), and a streak that would
        # run past the right edge is skipped rather than wrapped -- wrapping would draw a
        # bright line down the left of the screen every time.
        Add-Label $ovl 'AztBootGlitch'
        A-Pushad $ovl
        A-Call $ovl 'AztBootClear'               # wipe the previous frame's streaks

        A-MovEbxSi   $ovl 'aztInjBufPtr'
        A-TestEbxEbx $ovl
        A-Jz $ovl 'ABG_out'

        # Bright bands top and bottom, pulsing. The pulse is a stepped sawtooth off the
        # clock -- a real sine is not worth a trig routine for something this brief.
        #
        # The pulse is now PROPORTIONAL to the stage's band height rather than a fixed
        # 4..11: rows * (5..8) / 8. Scaling rather than subtracting a pulse is deliberate,
        # because a subtracted pulse goes NEGATIVE once the stage height falls below it,
        # and a negative row count here is a rep stosd of ~4 billion dwords through the
        # end of the buffer. Scaling cannot leave 0..height, whatever the table says.
        & $EmitStageCount $ovl 3                 # ecx = this stage's band height
        A-MovEaxSi  $ovl 'aztBootEl'
        A-Db $ovl @(0xC1,0xE8,0x11)              # shr eax, 17   (~131 ms per step)
        A-AndEaxImm $ovl 3
        A-AddEaxImm $ovl 5                       # 5..8
        A-MulEcx    $ovl                         # <= 11*8 = 88, so edx = 0
        A-Db $ovl @(0xC1,0xE8,0x03)              # shr eax, 3    -> 5/8..8/8 of the height
        A-RowsDwords $ovl 'eax'                  # rows * INJ_W / 4 dwords
        A-Db $ovl @(0x89,0xC1)                   # mov ecx, eax  (dwords for one band)
        A-Db $ovl @(0x89,0xDF)                   # mov edi, ebx  -> the top edge
        A-MovEaxImm $ovl ([uint32]($BOOT_ART_IX * 0x01010101))
        A-PushEcx $ovl
        A-PushDsPopEs $ovl
        A-RepStosd $ovl
        A-PopEcx $ovl
        # the bottom edge: buffer end minus the same number of dwords
        A-Db $ovl @(0x89,0xC8)                   # mov eax, ecx
        A-Db $ovl @(0xC1,0xE0,0x02)              # shl eax, 2    -> bytes
        A-Db $ovl @(0x89,0xDF)                   # mov edi, ebx
        A-AddEdiImm32 $ovl ([uint32]($INJ_W * $INJ_H))
        A-Db $ovl @(0x29,0xC7)                   # sub edi, eax
        A-MovEaxImm $ovl ([uint32]($BOOT_ART_IX * 0x01010101))
        A-RepStosd $ovl

        # How many of each artifact this frame: a STEPPED lookup, not a linear fade.
        # ecx <- aztBootDisTab[stage][family], where stage = el / BOOT_DIS_STAGE_US.
        # The caller only runs this while el < BOOT_DISRUPT_US and DISRUPT is exactly
        # stages*STAGE_US, so the index cannot walk off the end of the table.
        & $EmitStageCount $ovl 0
        A-TestEcxEcx $ovl
        A-Jz $ovl 'ABG_edges'                    # NOT 'out': the edge artifacts still run
        A-MovSiEcx32 $ovl 'aztBootGlCnt'

        Add-Label $ovl 'ABG_next'
        A-MovEaxSi  $ovl 'aztBootSeed'           # seed = seed*1103515245 + 12345
        A-ImulEaxImm $ovl 1103515245
        A-AddEaxImm  $ovl 12345
        A-MovSiEax32 $ovl 'aztBootSeed'
        A-Db $ovl @(0x89,0xC2)                   # mov edx, eax
        A-Db $ovl @(0xC1,0xEA,0x10)              # shr edx, 16
        A-RandRow   $ovl 'edx' $INJ_H            # row 0..INJ_H-1, uniform over the height
        A-RowsBytes $ovl 'edx'                   # row -> byte offset (x INJ_W)
        A-Db $ovl @(0x89,0xC1)                   # mov ecx, eax
        A-Db $ovl @(0xC1,0xE9,0x04)              # shr ecx, 4
        A-Db $ovl @(0x89,0xC8)                   # mov eax, ecx
        A-AndEaxImm $ovl ([int]$INJ_X_MASK)      # x over the whole width; the clip below absorbs the overshoot
        A-Db $ovl @(0xC1,0xE9,0x14)              # shr ecx, 20
        A-Db   $ovl @(0x81,0xE1)                 # and ecx, imm32
        A-Dd32 $ovl 127
        A-AddEcxImm $ovl 8                       # length 8..135
        # skip rather than wrap if it would run off the right edge
        A-PushEax $ovl
        A-Db $ovl @(0x01,0xC8)                   # add eax, ecx
        A-CmpEaxImm $ovl ([uint32]$INJ_W)
        A-PopEax $ovl
        A-Ja $ovl 'ABG_skip'
        A-Db $ovl @(0x01,0xD0)                   # add eax, edx   -> row*1024 + x
        A-AddEaxEbx $ovl
        A-MovEdiEax $ovl
        A-MovEaxImm $ovl ([uint32]($BOOT_ART_IX * 0x01010101))
        A-Db $ovl @(0xF3,0xAA)                   # rep stosb
        Add-Label $ovl 'ABG_skip'
        A-DecDwordSi $ovl 'aztBootGlCnt'
        A-Jnz $ovl 'ABG_next'

        # ---- edge dropout: short streaks confined to the outer columns --------
        # The streaks above are scattered over the whole viewport; these crowd the two
        # margins, so the damage reads as worst at the edges of the visor rather than
        # uniform. HALF OF THEM ARE DRAWN IN THE DARK COLOUR: bright-only streaks look
        # like flare, and a damaged panel should drop signal as well as flare.
        #
        # ebp holds the raw LCG word for the whole iteration, so every field is a shift
        # and a mask off one register -- no stack juggling to keep bits alive. ebp is
        # inside the pushad, and esi (obj1 delta) and ebx (the buffer) are untouched.
        #
        # No clipping test, because the ranges cannot reach an edge by construction:
        # $BOOT_EDGE_XMASK plus $BOOT_EDGE_LEN_MAX is asserted at build time to fit
        # inside $BOOT_EDGE_MARGIN, and both scale with the viewport. That assertion
        # replaces a comment that did the same sum by hand for a 1024-wide viewport
        # and would have been quietly wrong at any other width.
        Add-Label $ovl 'ABG_edges'
        & $EmitStageCount $ovl 1
        A-TestEcxEcx $ovl
        A-Jz $ovl 'ABG_blocks'
        A-MovSiEcx32 $ovl 'aztBootEdCnt'

        Add-Label $ovl 'ABE_next'
        A-MovEaxSi   $ovl 'aztBootSeed'
        A-ImulEaxImm $ovl 1103515245
        A-AddEaxImm  $ovl 12345
        A-MovSiEax32 $ovl 'aztBootSeed'
        A-Db $ovl @(0x89,0xC5)                   # mov ebp, eax  -- the word for this streak
        A-Db $ovl @(0x89,0xC2)                   # mov edx, eax
        A-Db $ovl @(0xC1,0xEA,0x10)              # shr edx, 16
        A-RandRow   $ovl 'edx' $INJ_H            # row 0..INJ_H-1, uniform over the height
        A-RowsBytes $ovl 'edx'                   # row -> byte offset (x INJ_W)
        A-Db $ovl @(0x89,0xE9)                   # mov ecx, ebp
        A-Db $ovl @(0xC1,0xE9,0x04)              # shr ecx, 4
        A-Db   $ovl @(0x81,0xE1)                 # and ecx, imm32 -- no A-AndEcxImm helper
        A-Dd32 $ovl 31
        A-AddEcxImm $ovl 4                       # length 4..35
        A-Db $ovl @(0x89,0xE8)                   # mov eax, ebp
        A-Db $ovl @(0xC1,0xE8,0x09)              # shr eax, 9
        A-AndEaxImm $ovl ([int]$BOOT_EDGE_XMASK) # x within the margin, clearance asserted
        A-Db $ovl @(0xF7,0xC5)                   # test ebp, imm32  -- which margin
        A-Dd32 $ovl 0x40000000
        A-Jz $ovl 'ABE_left'
        A-AddEaxImm32 $ovl ([uint32]($INJ_W - $BOOT_EDGE_MARGIN))
        Add-Label $ovl 'ABE_left'
        A-Db $ovl @(0x01,0xD0)                   # add eax, edx
        A-AddEaxEbx $ovl
        A-MovEdiEax $ovl
        A-Db $ovl @(0xF7,0xC5)                   # test ebp, imm32  -- bright or dropout
        A-Dd32 $ovl 0x20000000
        A-Jz $ovl 'ABE_dark'
        A-MovEaxImm $ovl ([uint32]($BOOT_ART_IX * 0x01010101))
        A-Jmp $ovl 'ABE_fill'
        Add-Label $ovl 'ABE_dark'
        A-MovEaxImm $ovl ([uint32]($BOOT_SCAN_IX * 0x01010101))
        Add-Label $ovl 'ABE_fill'
        A-Db $ovl @(0xF3,0xAA)                   # rep stosb
        A-DecDwordSi $ovl 'aztBootEdCnt'
        A-Jnz $ovl 'ABE_next'

        # ---- flickering blocks in the margins ---------------------------------
        # Small filled rectangles, 4..19 wide by 2..9 tall, in the same two margins.
        # They are redrawn from a fresh random word every frame and never persist, so
        # they flicker on their own -- no per-block state to keep, and the flicker rate
        # is the frame rate rather than something that has to be timed.
        #
        # Each row is one rep stosb and then edi is walked back by the width and on by
        # one stride, which keeps the inner loop to a single string op per row.
        Add-Label $ovl 'ABG_blocks'
        & $EmitStageCount $ovl 2
        A-TestEcxEcx $ovl
        A-Jz $ovl 'ABG_out'
        A-MovSiEcx32 $ovl 'aztBootBlkCnt'

        Add-Label $ovl 'ABK_next'
        A-MovEaxSi   $ovl 'aztBootSeed'
        A-ImulEaxImm $ovl 1103515245
        A-AddEaxImm  $ovl 12345
        A-MovSiEax32 $ovl 'aztBootSeed'
        A-Db $ovl @(0x89,0xC5)                   # mov ebp, eax
        A-Db $ovl @(0x89,0xC2)                   # mov edx, eax
        A-Db $ovl @(0xC1,0xEA,0x10)              # shr edx, 16
        A-RandRow   $ovl 'edx' ([int]($INJ_H - $BOOT_BLK_H_MAX))   # leaves room for the block's height
        A-RowsBytes $ovl 'edx'                   # row -> byte offset (x INJ_W)
        A-Db $ovl @(0x89,0xE8)                   # mov eax, ebp
        A-Db $ovl @(0xC1,0xE8,0x09)              # shr eax, 9
        A-AndEaxImm $ovl ([int]$BOOT_BLK_XMASK)  # x within the margin, clearance asserted
        A-Db $ovl @(0xF7,0xC5)                   # test ebp, imm32  -- which margin
        A-Dd32 $ovl 0x40000000
        A-Jz $ovl 'ABK_left'
        A-AddEaxImm32 $ovl ([uint32]($INJ_W - $BOOT_BLK_MARGIN))
        Add-Label $ovl 'ABK_left'
        A-Db $ovl @(0x01,0xD0)                   # add eax, edx
        A-AddEaxEbx $ovl
        A-MovEdiEax $ovl                         # edi = the block's top-left
        A-Db $ovl @(0x89,0xE9)                   # mov ecx, ebp
        A-Db $ovl @(0xC1,0xE9,0x04)              # shr ecx, 4
        A-Db   $ovl @(0x81,0xE1)                 # and ecx, imm32
        A-Dd32 $ovl 15
        A-AddEcxImm $ovl 4                       # width 4..19
        A-Db $ovl @(0x89,0xE8)                   # mov eax, ebp
        A-Db $ovl @(0xC1,0xE8,0x18)              # shr eax, 24
        A-AndEaxImm $ovl 7
        A-AddEaxImm32 $ovl 2                     # height 2..9
        A-Db $ovl @(0xF7,0xC5)                   # test ebp, imm32  -- lit or dead block
        A-Dd32 $ovl 0x20000000
        A-Jz $ovl 'ABK_dark'
        A-MovEdxImm $ovl ([uint32]($BOOT_ART_IX * 0x01010101))
        A-Jmp $ovl 'ABK_row'
        Add-Label $ovl 'ABK_dark'
        A-MovEdxImm $ovl ([uint32]($BOOT_SCAN_IX * 0x01010101))
        Add-Label $ovl 'ABK_row'
        A-PushEcx $ovl                           # rep stosb eats ecx, and al must hold
        A-PushEax $ovl                           # the colour -- so both are saved per row
        A-Db $ovl @(0x89,0xD0)                   # mov eax, edx
        A-Db $ovl @(0xF3,0xAA)                   # rep stosb
        A-PopEax  $ovl
        A-PopEcx  $ovl
        A-Db $ovl @(0x29,0xCF)                   # sub edi, ecx   -- back to the row start
        A-AddEdiImm32 $ovl ([uint32]$INJ_W)      # ...and on to the next row
        A-DecEax $ovl
        A-Jnz $ovl 'ABK_row'
        A-DecDwordSi $ovl 'aztBootBlkCnt'
        A-Jnz $ovl 'ABK_next'

        Add-Label $ovl 'ABG_out'
        A-Popad $ovl
        A-Ret   $ovl

        # ---- the shutter -----------------------------------------------------
        # h = half the open band, in rows, 1..288. Before STRIKE it stays at 1, so the
        # screen is a single bright slit -- the tube striking -- and it then grows
        # linearly to full height by OPEN. The band is rows [288-h, 288+h), which is
        # CONTIGUOUS, so filling it is one rep stosd; that is the whole reason the
        # shutter opens vertically rather than horizontally.
        #
        # The band is only ever redrawn where it already is or wider, and the initial
        # clear blacked everything, so nothing outside needs clearing per frame. The
        # lips are drawn after the fill, which also wipes the previous frame's lips.
        #
        # (t-STRIKE)*288 peaks at 650000*288 = 187,200,000, inside 32 bits, so mul
        # leaves edx = 0 and the following div is safe without zeroing it.
        # TWO PHASES, in this order:
        #   1. amber screen, readout typing in                     (el < BOOT_OPEN_US)
        #   2. the shutter retracts, REVEALING the 3D behind it    (el >= BOOT_OPEN_US)
        # Phase 2 works by copying the live rendered surface back INTO our staging buffer
        # for the open band. The injection is a whole-frame copy, so there is no way to
        # partially cover -- but there is no need to: put the 3D in the middle of our own
        # buffer and the full copy leaves amber panels above and below it. The 3D comes
        # from the frame we are painting over, so it may lag by one frame, which is not
        # perceptible at this speed and costs nothing.
        # ---- vertical hold slip ----------------------------------------------
        # Decides, once per frame, whether the injection should roll this frame. It only
        # sets a variable; the roll itself costs nothing because the injection does it as
        # part of the copy it was making anyway.
        #
        # Rolling DOWN is expressed as a large roll up -- (total - n) rows -- because the
        # injection's two-run copy only walks forward. That keeps one code path instead of
        # two and cannot produce a negative offset.
        # ---- glyph corruption -------------------------------------------------
        # Replaces whole 8-pixel character cells with a cell taken from somewhere else on
        # the SAME ROW. That is what makes it read as dropped characters rather than as more
        # static: what lands is a wrong glyph, in the right colours, on the right baseline.
        #
        # It writes into the staging buffer AFTER the text, never into the source bitmap --
        # the buffer is repainted every frame, so this heals itself and the artwork that
        # every other frame is drawn from is never touched.
        #
        # Confined to the readout block's own rectangle, so it can only ever mangle text.
        Add-Label $ovl 'AztBootGlyph'
        A-Pushad $ovl
        A-MovEaxSi   $ovl 'aztBootSeed'
        A-ImulEaxImm $ovl 1103515245
        A-AddEaxImm  $ovl 12345
        A-MovSiEax32 $ovl 'aztBootSeed'
        A-Db $ovl @(0x89,0xC5)                   # mov ebp, eax
        A-Db $ovl @(0xC1,0xE8,0x0C)              # shr eax, 12
        A-AndEaxImm  $ovl ([int]$BOOT_GLYPH_ODDS)
        A-TestEaxEax $ovl
        A-Jnz $ovl 'ABY_out'                     # did not fire this frame
        A-MovEbxSi   $ovl 'aztInjBufPtr'
        A-TestEbxEbx $ovl
        A-Jz $ovl 'ABY_out'
        A-MovDwordSiImm $ovl 'aztGlyphLeft' ([int]$BOOT_GLYPH_CELLS)

        Add-Label $ovl 'ABY_next'
        A-MovEaxSi   $ovl 'aztBootSeed'
        A-ImulEaxImm $ovl 1103515245
        A-AddEaxImm  $ovl 12345
        A-MovSiEax32 $ovl 'aztBootSeed'
        A-Db $ovl @(0x89,0xC5)                   # mov ebp, eax  -- the word for this cell
        # A WHOLE LINE, not an arbitrary row. A character cell is 8 wide by BOOT_TXT_H tall,
        # so the pick has to land on a line boundary and the copy has to be that tall --
        # swapping a single scanline of one glyph is invisible, which is exactly what the
        # first version of this did.
        A-Db $ovl @(0xC1,0xE8,0x10)              # shr eax, 16
        A-MovEcxImm $ovl ([int]$BOOT_GLYPH_LINES)
        A-XorEdxEdx $ovl
        A-DivEcx    $ovl                         # edx = line index
        A-Db $ovl @(0x89,0xD0)                   # mov eax, edx
        # imul, NOT `shl 4`. This said "x BOOT_TXT_H" in its comment while actually
        # multiplying by a hard-coded 16, which was invisible until the animation was
        # scaled and BOOT_TXT_H became 22: every line then landed at the wrong row, so
        # the readout populated in the wrong places and the flare brightened rows that
        # held no text. See [[azrael-stride-derived-offsets]] -- same class of bug.
        A-ImulEaxImm $ovl ([uint32]$BOOT_TXT_H)  # line -> row
        A-AddEaxImm32 $ovl ([uint32]$BOOT_TXT_Y)
        A-RowsBytes $ovl 'eax'                      # -> byte offset of that screen row
        A-AddEaxEbx $ovl
        A-MovEdiEax $ovl                         # edi = the line's first row in the buffer
        # destination cell and source cell, both whole 8-pixel cells inside the block
        A-Db $ovl @(0x89,0xE8)                   # mov eax, ebp
        A-Db $ovl @(0xC1,0xE8,0x04)              # shr eax, 4
        A-AndEaxImm $ovl ([int]($BOOT_TXT_PITCH - 1))
        A-ShlEaxImm $ovl 3                       # cell -> pixels
        A-Db $ovl @(0x89,0xE9)                   # mov ecx, ebp
        A-Db $ovl @(0xC1,0xE9,0x14)              # shr ecx, 20
        A-Db   $ovl @(0x81,0xE1)                 # and ecx, imm32
        A-Dd32 $ovl ([uint32]($BOOT_TXT_PITCH - 1))
        A-ShlEcxImm $ovl 3
        A-Db $ovl @(0x89,0xFA)                   # mov edx, edi   -- keep the row base
        A-Db $ovl @(0x01,0xC7)                   # add edi, eax   -- destination cell
        A-AddEdiImm32 $ovl ([uint32]$BOOT_TXT_X)
        A-Db $ovl @(0x01,0xCA)                   # add edx, ecx   -- source cell
        A-Db   $ovl @(0x81,0xC2)                 # add edx, imm32
        A-Dd32 $ovl ([uint32]$BOOT_TXT_X)
        # DWORD MOVES, NOT rep movsb. A string copy would need esi as its source, and esi is
        # the obj1 delta that the next loop iteration reads its variables through -- the
        # same register-lifetime trap that froze the game once already.
        A-MovEcxImm $ovl ([int]$BOOT_TXT_H)      # the full height of a character cell
        Add-Label $ovl 'ABY_row'
        A-Db $ovl @(0x8B,0x02)                   # mov eax,[edx]
        A-Db $ovl @(0x89,0x07)                   # mov [edi],eax
        A-Db $ovl @(0x8B,0x42,0x04)              # mov eax,[edx+4]
        A-Db $ovl @(0x89,0x47,0x04)              # mov [edi+4],eax
        A-Db   $ovl @(0x81,0xC2)                 # add edx, imm32
        A-Dd32 $ovl ([uint32]$INJ_W)
        A-AddEdiImm32 $ovl ([uint32]$INJ_W)
        A-DecEcx $ovl
        A-JnzS $ovl 'ABY_row'
        A-DecDwordSi $ovl 'aztGlyphLeft'
        A-Jnz $ovl 'ABY_next'
        Add-Label $ovl 'ABY_out'
        A-Popad $ovl
        A-Ret   $ovl

        # ---- boot progress bar -----------------------------------------------
        # A framed track under the readout, filling from BOOT_TEXT_US to the moment the
        # closing line finishes typing. Redrawn whole every frame -- both the filled part
        # and the empty groove -- so it needs no memory of what it drew last time and the
        # disruption repainting the background underneath it does not matter.
        #
        # Each interior row writes EXACTLY BOOT_BAR_W bytes: 1 frame + filled + remainder
        # + 1 frame. That identity is what keeps it inside its own rectangle whatever the
        # fill happens to be, including 0 and full, where one of the two runs is empty and
        # rep stosb simply does nothing.
        Add-Label $ovl 'AztBootBar'
        A-Pushad $ovl
        A-MovEaxSi  $ovl 'aztBootEl'
        A-CmpEaxImm $ovl $BOOT_TEXT_US
        A-Jb $ovl 'ABB_out'                      # nothing to report yet
        A-SubEaxImm $ovl $BOOT_TEXT_US
        A-CmpEaxImm $ovl ([int]$BOOT_BAR_SPAN)
        A-JbS $ovl 'ABB_prog'
        A-MovEaxImm $ovl ([int]$BOOT_BAR_SPAN)   # clamp: it stays full, it never overruns
        Add-Label $ovl 'ABB_prog'
        A-MovEcxImm $ovl ([int]($BOOT_BAR_W - 2))
        A-MulEcx    $ovl                         # asserted at build time to fit 32 bits,
        A-MovEcxImm $ovl ([int]$BOOT_BAR_SPAN)   #   so edx is 0 going into the divide
        A-DivEcx    $ovl
        A-Db $ovl @(0x89,0xC2)                   # mov edx, eax  -- filled pixels, kept

        A-MovEbxSi   $ovl 'aztInjBufPtr'
        A-TestEbxEbx $ovl
        A-Jz $ovl 'ABB_out'
        A-MovEaxImm $ovl ([int]($BOOT_BAR_Y * $INJ_W + $BOOT_BAR_X))
        A-AddEaxEbx $ovl
        A-MovEbxEax $ovl                         # ebx walks down the bar, row by row
        A-PushDsPopEs $ovl

        A-Db $ovl @(0x89,0xDF)                   # mov edi, ebx   -- the top frame row
        A-MovEaxSi  $ovl 'aztInkDw'                 # VARIABLE: the bar fades with the readout
        A-MovEcxImm $ovl ([int]$BOOT_BAR_W)
        A-Db $ovl @(0xF3,0xAA)                   # rep stosb

        A-MovEbpImm $ovl ([int]($BOOT_BAR_H - 2))
        Add-Label $ovl 'ABB_row'
        A-Db   $ovl @(0x81,0xC3)                 # add ebx, imm32
        A-Dd32 $ovl ([uint32]$INJ_W)
        A-Db $ovl @(0x89,0xDF)                   # mov edi, ebx
        A-MovEaxSi  $ovl 'aztInkDw'                 # VARIABLE: the bar fades with the readout
        A-MovEcxImm $ovl 1
        A-Db $ovl @(0xF3,0xAA)                   # the left frame pixel
        A-Db $ovl @(0x89,0xD1)                   # mov ecx, edx
        A-Db $ovl @(0xF3,0xAA)                   # ...the filled part, same ink
        A-MovEaxImm $ovl ([uint32]($BOOT_BAR_TRACK_IX * 0x01010101))
        A-MovEcxImm $ovl ([int]($BOOT_BAR_W - 2))
        A-Db $ovl @(0x29,0xD1)                   # sub ecx, edx
        A-Db $ovl @(0xF3,0xAA)                   # ...and the empty groove after it
        A-MovEaxSi  $ovl 'aztInkDw'                 # VARIABLE: the bar fades with the readout
        A-MovEcxImm $ovl 1
        A-Db $ovl @(0xF3,0xAA)                   # the right frame pixel
        A-DecEbp $ovl
        A-Jnz $ovl 'ABB_row'

        A-Db   $ovl @(0x81,0xC3)                 # add ebx, imm32
        A-Dd32 $ovl ([uint32]$INJ_W)
        A-Db $ovl @(0x89,0xDF)                   # mov edi, ebx   -- the bottom frame row
        A-MovEaxSi  $ovl 'aztInkDw'                 # VARIABLE: the bar fades with the readout
        A-MovEcxImm $ovl ([int]$BOOT_BAR_W)
        A-Db $ovl @(0xF3,0xAA)
        Add-Label $ovl 'ABB_out'
        A-Popad $ovl
        A-Ret   $ovl

        # ---- horizontal tear bands -------------------------------------------
        # Displaces a band of rows sideways, wrapping, for one frame. It runs LAST in the
        # phase, after the text, so it tears the readout too -- text is what makes a
        # horizontal displacement obvious, and tearing only the background would be nearly
        # as invisible as the first hold slip was.
        #
        # One frame, not several: unlike the slip, this is a big displacement that cuts
        # through glyphs, so it registers immediately, and holding it would read as the
        # picture being bent rather than torn.
        #
        # ESI IS THE OBJ1 DELTA AND THE ROTATE NEEDS IT AS A STRING SOURCE. The scratch
        # address is resolved into ebp first and the delta is parked on the stack, which is
        # the only reason this can use rep movs at all. Getting that wrong is what froze
        # the game when the hold slip was added.
        Add-Label $ovl 'AztBootTear'
        A-Pushad $ovl
        A-MovEaxSi  $ovl 'aztBootEl'
        A-CmpEaxImm $ovl $BOOT_DISRUPT_US
        A-Jae $ovl 'ABR_out'                     # the stage index is only valid inside this
        & $EmitStageCount $ovl 4                 # ecx = this stage's chance out of 256
        A-TestEcxEcx $ovl
        A-Jz $ovl 'ABR_out'
        A-MovEaxSi   $ovl 'aztBootSeed'
        A-ImulEaxImm $ovl 1103515245
        A-AddEaxImm  $ovl 12345
        A-MovSiEax32 $ovl 'aztBootSeed'
        A-Db $ovl @(0x89,0xC5)                   # mov ebp, eax  -- the word for this tear
        A-Db $ovl @(0xC1,0xE8,0x0C)              # shr eax, 12
        A-AndEaxImm  $ovl 255
        A-Db $ovl @(0x39,0xC8)                   # cmp eax, ecx
        A-Jae $ovl 'ABR_out'                     # did not fire this frame

        A-Db $ovl @(0x89,0xE8)                   # mov eax, ebp
        A-Db $ovl @(0xC1,0xE8,0x04)              # shr eax, 4
        A-AndEaxImm  $ovl ([int]($BOOT_TEAR_ROWS_SPAN - 1))
        A-AddEaxImm  $ovl ([int]$BOOT_TEAR_ROWS_MIN)
        A-MovSiEax32 $ovl 'aztTearRows'
        A-Db $ovl @(0x89,0xE8)                   # mov eax, ebp
        A-Db $ovl @(0xC1,0xE8,0x10)              # shr eax, 16
        A-RandRow    $ovl 'eax' ([int]($INJ_H - ($BOOT_TEAR_ROWS_MIN + $BOOT_TEAR_ROWS_SPAN - 1)))   # leaves room for the band
        A-RowsBytes  $ovl 'eax'                     # -> byte offset; x = 0, so the full width
        A-MovSiEax32 $ovl 'aztTearOff'
        A-MovDwordSiImm $ovl 'aztTearW' ([int]$INJ_W)
        A-Db $ovl @(0x89,0xEA)                   # mov edx, ebp
        A-Db $ovl @(0xC1,0xEA,0x18)              # shr edx, 24
        A-AndEdxImm  $ovl ([int]($BOOT_TEAR_SHIFT_SPAN - 1))
        A-AddEdxImm8 $ovl ([byte]$BOOT_TEAR_SHIFT_MIN)   # 16..143 px
        A-Db $ovl @(0xF7,0xC5)                   # test ebp, imm32  -- which way
        A-Dd32 $ovl 0x00800000
        A-JzS $ovl 'ABR_dir'
        # A right shift by M is a left ROTATE by (W-M), so one rotate serves both
        # directions and neither needs a backward copy.
        A-Db $ovl @(0x89,0xD1)                   # mov ecx, edx
        A-MovEdxImm $ovl ([uint32]$INJ_W)
        A-Db $ovl @(0x29,0xCA)                   # sub edx, ecx
        Add-Label $ovl 'ABR_dir'
        A-MovSiEdx32 $ovl 'aztTearShift'
        A-Call $ovl 'AztBootTearDo'
        Add-Label $ovl 'ABR_out'
        A-Popad $ovl
        A-Ret   $ovl

        # The rotate itself, driven by aztTearOff / aztTearW / aztTearRows / aztTearShift.
        # It is parameterised on WIDTH as well as position so the mission tear can be
        # confined to the mission block. That matters: a tear inside the block is repainted
        # by the next frame's blit and heals itself, while one reaching the bare screen
        # either side would stay torn for good -- nothing repaints the background once the
        # mission phase has wiped it.
        Add-Label $ovl 'AztBootTearDo'
        A-Pushad $ovl
        A-MovEbxSi   $ovl 'aztInjBufPtr'
        A-TestEbxEbx $ovl
        A-Jz $ovl 'ABD_out'
        A-Db   $ovl @(0x03,0x9E)                 # add ebx,[esi+d32] -- the band's first row
        # Add-Abs32, NOT A-Dd32: this displacement is a LABEL and has to be resolved.
        # A-Dd32 emits a literal dword and throws on a string, which is at least loud.
        Add-Abs32 $ovl 'aztTearOff'
        A-MovEaxSi   $ovl 'aztTearW'             # eax holds the width for the whole loop
        A-MovEdxSi32 $ovl 'aztTearShift'
        A-MovEcxSi   $ovl 'aztTearRows'
        A-LeaEbpSi $ovl 'aztTearScratch'         # absolute, BEFORE esi is given away
        A-PushEsi  $ovl                          # park the obj1 delta...
        A-PushEcx  $ovl                          # ...then the row counter ON TOP of it, so
                                                 #    [esp] is the counter and not the delta
        A-PushDsPopEs $ovl
        Add-Label $ovl 'ABD_row'
        A-Db $ovl @(0x89,0xDE)                   # mov esi, ebx      -- the row
        A-Db $ovl @(0x89,0xEF)                   # mov edi, ebp      -- the scratch
        A-Db $ovl @(0x89,0xC1)                   # mov ecx, eax
        A-Db $ovl @(0xC1,0xE9,0x02)              # shr ecx, 2
        A-RepMovsd  $ovl                         # keep an untouched copy of the row
        A-Db $ovl @(0x8D,0x74,0x15,0x00)         # lea esi,[ebp+edx] -- scratch + shift
        A-Db $ovl @(0x89,0xDF)                   # mov edi, ebx
        A-Db $ovl @(0x89,0xC1)                   # mov ecx, eax
        A-Db $ovl @(0x29,0xD1)                   # sub ecx, edx      -- W - shift
        A-Db $ovl @(0xF3,0xA4)                   # rep movsb         -- the tail moves left
        A-Db $ovl @(0x89,0xEE)                   # mov esi, ebp
        A-Db $ovl @(0x8D,0x3C,0x03)              # lea edi,[ebx+eax]
        A-Db $ovl @(0x29,0xD7)                   # sub edi, edx
        A-Db $ovl @(0x89,0xD1)                   # mov ecx, edx
        A-Db $ovl @(0xF3,0xA4)                   # rep movsb         -- the head wraps round
        A-Db   $ovl @(0x81,0xC3)                 # add ebx, imm32 -- no A-AddEbxImm32 helper
        A-Dd32 $ovl ([uint32]$INJ_W)             # the ROW STRIDE, not the band width
        A-Db $ovl @(0xFF,0x0C,0x24)              # dec dword [esp]
        A-Jnz $ovl 'ABD_row'
        A-PopEax $ovl                            # drop the row counter...
        A-PopEsi $ovl                            # ...and the delta is the delta again
        Add-Label $ovl 'ABD_out'
        A-Popad $ovl
        A-Ret   $ovl

        # ---- the split tear ---------------------------------------------------
        # Two split rows. Everything below the first steps right; everything below the
        # second steps right again on top of it. Both regions run to the BOTTOM of the text
        # block, which is what stacks the shifts rather than isolating them.
        #
        # Full screen width on purpose: a real tear does not stop at the edge of the text.
        # The background either side is flat, so the displacement is only visible where
        # there is content -- which is exactly the text.
        Add-Label $ovl 'AztBootSplit'
        A-Pushad $ovl
        A-MovEaxSi  $ovl 'aztBootEl'
        A-CmpEaxImm $ovl $BOOT_DISRUPT_US
        A-Jae $ovl 'ABS2_out'                    # nothing repaints the background after this
        A-MovEaxSi   $ovl 'aztBootSeed'
        A-ImulEaxImm $ovl 1103515245
        A-AddEaxImm  $ovl 12345
        A-MovSiEax32 $ovl 'aztBootSeed'
        A-Db $ovl @(0x89,0xC5)                   # mov ebp, eax  -- the word for this split
        A-Db $ovl @(0xC1,0xE8,0x0C)              # shr eax, 12
        A-AndEaxImm  $ovl ([int]$BOOT_SPLIT_ODDS)
        A-TestEaxEax $ovl
        A-Jnz $ovl 'ABS2_out'

        A-MovDwordSiImm $ovl 'aztTearW' ([int]$INJ_W)
        # --- first split: row A, everything below it
        A-Db $ovl @(0x89,0xE8)                   # mov eax, ebp
        A-Db $ovl @(0xC1,0xE8,0x10)              # shr eax, 16
        # 0..63, NOT 0..127. Three cascading gaps of up to 111 rows each have to fit below
        # this first split and still leave rows before the foot of the block: 189 + 111 +
        # 111 = 411 of 448. A wider first range would let the last split start past the end.
        A-AndEaxImm $ovl 63
        A-AddEaxImm32 $ovl ([uint32]$BOOT_TXT_Y)         # A = block top + 0..63
        A-Db $ovl @(0x89,0xC3)                   # mov ebx, eax   -- keep A
        A-RowsBytes $ovl 'eax'
        A-MovSiEax32 $ovl 'aztTearOff'
        A-MovEaxImm $ovl ([int]($BOOT_TXT_Y + $BOOT_TXT_STACK_H))
        A-Db $ovl @(0x29,0xD8)                   # sub eax, ebx   -- rows to the block's foot
        A-MovSiEax32 $ovl 'aztTearRows'
        A-Db $ovl @(0x89,0xE8)                   # mov eax, ebp
        A-Db $ovl @(0xC1,0xE8,0x18)              # shr eax, 24
        A-AndEaxImm $ovl ([int]($BOOT_SPLIT_SHIFT_SPAN - 1))
        A-AddEaxImm $ovl ([int]$BOOT_SPLIT_SHIFT_MIN)
        A-Db $ovl @(0x89,0xC1)                   # mov ecx, eax
        A-MovEaxImm $ovl ([uint32]$INJ_W)
        A-Db $ovl @(0x29,0xC8)                   # sub eax, ecx   -- right M = left (W-M)
        A-MovSiEax32 $ovl 'aztTearShift'
        A-Call $ovl 'AztBootTearDo'

        # --- second and third splits, each below the last and each running to the foot.
        # Three steps rather than two: the second lands in the lower half of the 7 and the
        # third below it, so the shape comes apart in stages down the screen instead of
        # breaking once. Emitted as a loop over two different bit fields of the same word.
        foreach ($sp in @(@(0x04, 0x0A), @(0x0D, 0x13))) {
            A-Db $ovl @(0x89,0xE8)               # mov eax, ebp
            A-Db $ovl @(0xC1,0xE8,[byte]$sp[0])  # shr eax, n   -- this split's gap bits
            A-AndEaxImm $ovl ([int]($BOOT_SPLIT_GAP_SPAN - 1))
            A-AddEaxImm $ovl ([int]$BOOT_SPLIT_GAP_MIN)
            A-AddEaxEbx $ovl                     # this row = the previous one + gap
            A-Db $ovl @(0x89,0xC3)               # mov ebx, eax   -- keep it for the next
            A-RowsBytes $ovl 'eax'
            A-MovSiEax32 $ovl 'aztTearOff'
            A-MovEaxImm $ovl ([int]($BOOT_TXT_Y + $BOOT_TXT_STACK_H))
            A-Db $ovl @(0x29,0xD8)               # sub eax, ebx   -- rows to the foot
            A-MovSiEax32 $ovl 'aztTearRows'
            A-Db $ovl @(0x89,0xE8)               # mov eax, ebp
            A-Db $ovl @(0xC1,0xE8,[byte]$sp[1])  # shr eax, n   -- this split's shift bits
            A-AndEaxImm $ovl ([int]($BOOT_SPLIT_SHIFT_SPAN - 1))
            A-AddEaxImm $ovl ([int]$BOOT_SPLIT_SHIFT_MIN)
            A-Db $ovl @(0x89,0xC1)               # mov ecx, eax
            A-MovEaxImm $ovl ([uint32]$INJ_W)
            A-Db $ovl @(0x29,0xC8)               # sub eax, ecx
            A-MovSiEax32 $ovl 'aztTearShift'
            A-Call $ovl 'AztBootTearDo'
        }
        Add-Label $ovl 'ABS2_out'
        A-Popad $ovl
        A-Ret   $ovl

        # ---- the one scripted tear, over the mission block --------------------
        # A single glitch a beat after the objective has settled: the player reads it, then
        # the visor stutters once. TIME-WINDOWED rather than flagged -- the unsigned
        # subtract wraps enormous before the window, so no state is needed and nothing can
        # leave it latched on.
        #
        # The band is the OBJECTIVE line's rows and exactly the mission block's columns,
        # which is what lets it heal: AztBootMission repaints that rectangle every frame.
        Add-Label $ovl 'AztBootTearMis'
        A-Pushad $ovl
        A-MovEaxSi  $ovl 'aztBootEl'
        A-SubEaxImm $ovl $BOOT_MIS_TEAR_US
        A-CmpEaxImm $ovl $BOOT_MIS_TEAR_DUR
        A-JbS $ovl 'ABMT_do'
        A-MovEaxSi  $ovl 'aztBootEl'             # the second stutter, later in the hold
        A-SubEaxImm $ovl $BOOT_MIS_TEAR2_US
        A-CmpEaxImm $ovl $BOOT_MIS_TEAR_DUR
        A-Jae $ovl 'ABMT_out'
        Add-Label $ovl 'ABMT_do'
        A-MovDwordSiImm $ovl 'aztTearOff' ([int]($BOOT_MIS_TEAR_ROW * $INJ_W + $BOOT_MIS_X))
        A-MovDwordSiImm $ovl 'aztTearW'     ([int]$BOOT_TXT_W)
        A-MovDwordSiImm $ovl 'aztTearRows'  ([int]$BOOT_MIS_BIG_H)
        A-MovDwordSiImm $ovl 'aztTearShift' ([int]($BOOT_TXT_W - $BOOT_MIS_TEAR_PX))
        A-Call $ovl 'AztBootTearDo'
        Add-Label $ovl 'ABMT_out'
        A-Popad $ovl
        A-Ret   $ovl

        # ---- CRT warm-up -----------------------------------------------------
        # Walks the fill and scan colours up the amber ramp over BOOT_WARM_US. Two jobs,
        # and the second is the one that is easy to miss:
        #
        #  1. Set aztFillDw/aztScanDw, EVERY frame -- AztBootPaint resets them to normal
        #     on entry, so this has to put the warm values back each time.
        #  2. Repaint the text expansion tables' BACKGROUND entries. The readout's
        #     background is baked into those tables at build time, so dimming only the
        #     clear would leave the banner sitting on a normal-brightness rectangle: a
        #     bright box on a dark screen, worse than no warm-up at all.
        #
        # The table rewrite is gated on the stage CHANGING, so it runs five times in the
        # whole sequence rather than every frame. It tests against the ink colour rather
        # than the old background, which makes it idempotent -- it does not need to know
        # what the tables currently hold.
        # ---- the ink colour, as one place ------------------------------------
        # eax = the wanted ink index. Repaints the ink bytes in BOTH expansion tables and
        # mirrors the value into aztInkDw (for the progress bar, which writes pixels directly
        # rather than through a table) and aztDumpIx (the telemetry column's dimmer shade).
        #
        # This is what makes the phosphor decay nearly free: the text, the bar and the column
        # all fade together without any of them knowing about it, and no second pair of
        # expansion tables -- which would have been 4 KB of BSS per decay step.
        #
        # GATED ON THE VALUE CHANGING, like AztBootWarm: the common case is an ordinary frame
        # asking for the ink it already has, and that costs a compare and a jump. The tables
        # are only walked on the three or four frames where a step actually lands.
        Add-Label $ovl 'AztBootInk'
        A-Pushad $ovl
        A-CmpEaxSi $ovl 'aztInkIx'
        A-Jz $ovl 'ABI_out'                          # the tables already say this
        A-MovSiEax32 $ovl 'aztInkIx'
        A-Db $ovl @(0x89,0xC2)                       # mov edx, eax -- dl, kept across both passes
        A-Db $ovl @(0xC1,0xE0,0x08)                  # shl eax, 8
        A-Db $ovl @(0x09,0xD0)                       # or  eax, edx
        A-Db $ovl @(0x89,0xC1)                       # mov ecx, eax
        A-Db $ovl @(0xC1,0xE0,0x10)                  # shl eax, 16
        A-Db $ovl @(0x09,0xC8)                       # or  eax, ecx   -- ix * 0x01010101
        A-MovSiEax32 $ovl 'aztInkDw'
        # aztDumpIx IS NOT RECOMPUTED HERE ANY MORE. It used to be the current ink plus
        # BOOT_DUMP_DIM, clamped to the end of the teal ramp, so the column tracked the
        # readout's decay. It is now a fixed amber index -- see $BOOT_DUMP_IX -- set once in
        # the data block below, so there is nothing per-frame to do and the decay leaves it
        # alone by design.
        # Replace every byte on the teal ramp with the new index. The INVERSE of the pass in
        # AztBootWarm -- that one repaints the background and skips the ink -- and idempotent
        # for the same reason: the test is the ramp, not one exact value, so running it twice
        # or running it after a background repaint both land in the same place.
        $EmitInkPass = {
            param($a, $tab, $lbl)
            A-LeaEdiSi  $a $tab
            A-MovEcxImm $a 2048
            Add-Label $a $lbl
            A-Db $a @(0x8A,0x07)                     # mov al, [edi]
            A-Db $a @(0x2C,[byte]$BOOT_INK_IX)       # sub al, ink
            A-Db $a @(0x3C,0x10)                     # cmp al, 16
            A-Db $a @(0x73,0x02)                     # jae +2 -- background, leave it
            A-Db $a @(0x88,0x17)                     # mov [edi], dl
            A-Db $a @(0x47)                          # inc edi
            A-DecEcx $a
            A-JnzS $a $lbl
        }
        & $EmitInkPass $ovl 'aztBootTab'  'ABI_t1'
        & $EmitInkPass $ovl 'aztBootTab2' 'ABI_t2'
        Add-Label $ovl 'ABI_out'
        A-Popad $ovl
        A-Ret   $ovl

        Add-Label $ovl 'AztBootWarm'
        A-Pushad $ovl
        A-MovEaxSi  $ovl 'aztBootEl'
        A-CmpEaxImm $ovl $BOOT_WARM_US
        A-JbS $ovl 'ABW_stage'
        A-MovEaxImm $ovl ([int]($BOOT_WARM_STAGES.Count - 1))   # warmed up: hold the last
        A-JmpS $ovl 'ABW_have'
        Add-Label $ovl 'ABW_stage'
        A-XorEdxEdx $ovl
        A-MovEcxImm $ovl ([int]$BOOT_WARM_STAGE_US)
        A-DivEcx    $ovl                         # eax = stage index
        Add-Label $ovl 'ABW_have'
        A-PushEax   $ovl                         # keep the stage for the change test
        A-MovEcxImm $ovl 8                       # 2 dwords per stage row
        A-MulEcx    $ovl
        A-LeaEdxSi  $ovl 'aztBootWarmTab'
        A-Db $ovl @(0x01,0xD0)                   # add eax, edx
        A-Db $ovl @(0x8B,0x08)                   # mov ecx, [eax]      -- fill
        A-MovSiEcx32 $ovl 'aztFillDw'
        A-Db $ovl @(0x8B,0x48,0x04)              # mov ecx, [eax+4]    -- scan
        A-MovSiEcx32 $ovl 'aztScanDw'
        A-PopEax    $ovl
        A-CmpEaxSi  $ovl 'aztWarmStage'
        A-JzS $ovl 'ABW_out'                     # same stage: the tables already match
        A-MovSiEax32 $ovl 'aztWarmStage'

        # A RANGE TEST, not `cmp byte [edi], BOOT_INK_IX`.
        #
        # This loop repaints BACKGROUND bytes and has to recognise the ink to leave it alone.
        # It used to do that by comparing against the ink index as an immediate, which was
        # only correct while the ink never changed. The phosphor decay walks the ink down the
        # teal ramp (88..103) inside these same tables, so an immediate test would see a
        # dimmed ink byte as background and paint over it -- turning a fading readout into a
        # half-erased one, and only if the warm-up and the decay ever overlapped. They do not
        # today (the warm-up is done at 2.4 s, the decay starts at 11.0 s), which is exactly
        # the kind of coupling that survives until someone retimes one of them.
        $EmitWarmPass = {
            param($a, $tab, $src, $lbl)
            A-LeaEdiSi  $a $tab
            A-MovEaxSi  $a $src                      # al is the index; the rest is the same byte
            A-MovEbxEax $a                           # bl = the background colour, since al is scratch
            A-MovEcxImm $a 2048
            Add-Label $a $lbl
            A-Db $a @(0x8A,0x07)                     # mov al, [edi]
            A-Db $a @(0x2C,[byte]$BOOT_INK_IX)       # sub al, ink
            A-Db $a @(0x3C,0x10)                     # cmp al, 16
            A-Db $a @(0x72,0x02)                     # jb +2 -- on the teal ramp, so it IS ink
            A-Db $a @(0x88,0x1F)                     # mov [edi], bl
            A-Db $a @(0x47)                          # inc edi
            A-DecEcx $a
            A-JnzS $a $lbl
        }
        & $EmitWarmPass $ovl 'aztBootTab'  'aztFillDw' 'ABW_t1'   # even rows: the fill colour
        & $EmitWarmPass $ovl 'aztBootTab2' 'aztScanDw' 'ABW_t2'   # odd rows: the scanline colour

        Add-Label $ovl 'ABW_out'
        A-Popad $ovl
        A-Ret   $ovl

        Add-Label $ovl 'AztBootSlip'
        A-Pushad $ovl
        A-MovEaxSi  $ovl 'aztBootEl'
        A-CmpEaxImm $ovl $BOOT_SLIP_START_US
        A-Jb  $ovl 'ABS_out'                     # too early: let the picture hold first
        A-CmpEaxImm $ovl $BOOT_SLIP_US
        A-Jae $ovl 'ABS_out'                     # past the window: never slip again
        # Already mid-slip? Hold the SAME roll for BOOT_SLIP_FRAMES frames. A fresh random
        # offset each frame would read as noise; one displacement held for ~125 ms reads as
        # the picture losing lock and catching it again.
        A-MovEaxSi   $ovl 'aztSlipLeft'
        A-TestEaxEax $ovl
        A-JzS $ovl 'ABS_new'
        A-DecEax $ovl
        A-MovSiEax32 $ovl 'aztSlipLeft'
        A-JmpS $ovl 'ABS_apply'

        Add-Label $ovl 'ABS_new'
        # Pick this frame's rate first: ecx survives the LCG below, which only touches eax
        # and edx.
        A-MovEcxImm $ovl ([int]$BOOT_SLIP_ODDS)
        A-MovEaxSi  $ovl 'aztBootEl'
        A-CmpEaxImm $ovl $BOOT_DISRUPT_US
        A-JbS $ovl 'ABS_odds'
        A-MovEcxImm $ovl ([int]$BOOT_SLIP_ODDS_LATE)   # the corruption has gone: rarer
        Add-Label $ovl 'ABS_odds'
        A-MovEaxSi   $ovl 'aztBootSeed'
        A-ImulEaxImm $ovl 1103515245
        A-AddEaxImm  $ovl 12345
        A-MovSiEax32 $ovl 'aztBootSeed'
        A-Db $ovl @(0x89,0xC2)                   # mov edx, eax  -- keep the word
        A-Db $ovl @(0xC1,0xE8,0x0C)              # shr eax, 12   -- high bits; LCG low bits are poor
        A-Db $ovl @(0x21,0xC8)                   # and eax, ecx
        A-TestEaxEax $ovl
        A-Jnz $ovl 'ABS_out'                     # did not fire this frame
        A-Db $ovl @(0x89,0xD0)                   # mov eax, edx
        A-Db $ovl @(0xC1,0xE8,0x11)              # shr eax, 17
        A-AndEaxImm  $ovl ([int]($BOOT_SLIP_ROWS_SPAN - 1))
        A-AddEaxImm  $ovl ([int]$BOOT_SLIP_ROWS_MIN)
        A-RowsBytes  $ovl 'eax'                     # rows -> byte offset (x INJ_W)
        A-Db $ovl @(0xF7,0xC2)                   # test edx, imm32  -- up or down
        A-Dd32 $ovl 0x00400000
        A-Jz $ovl 'ABS_store'
        A-Db $ovl @(0x89,0xC1)                   # mov ecx, eax
        A-MovEaxImm $ovl ([uint32]($INJ_W * $INJ_H))
        A-Db $ovl @(0x29,0xC8)                   # sub eax, ecx   -> roll the other way
        Add-Label $ovl 'ABS_store'
        A-MovSiEax32 $ovl 'aztSlipRoll'
        A-MovDwordSiImm $ovl 'aztSlipLeft' ([int]($BOOT_SLIP_FRAMES - 1))

        # Apply this frame's slip. The roll only -- a brightness flash was tried here and
        # removed: it made the roll easier to spot but read as the picture blinking rather
        # than as the hold slipping, and the retuned roll carries the effect on its own.
        Add-Label $ovl 'ABS_apply'
        A-MovEaxSi   $ovl 'aztSlipRoll'
        A-MovSiEax32 $ovl 'aztInjRoll'
        Add-Label $ovl 'ABS_out'
        A-Popad $ovl
        A-Ret   $ovl

        # ---- rolling refresh line --------------------------------------------
        # TWO routines, not one, and the reason is the whole design of this effect: nothing
        # repaints the screen background after the disruption's final clear, so a bright line
        # written into the staging buffer STAYS there. AztBootSweepOff repaints last frame's
        # rows at the top of AztBootPaint, before anything else draws; AztBootSweepOn draws
        # the new one at the very end, after the text, the tear and the split.
        #
        # That ordering also means the tear never sees a sweep line: if it did, the rotate
        # would displace it and the erase -- which only knows the row it drew at -- would miss.
        Add-Label $ovl 'AztBootSweepOff'
        A-Pushad $ovl
        A-MovEaxSi  $ovl 'aztSweepOff'
        A-CmpEaxImm $ovl 0xFFFFFFFFL
        A-Jz $ovl 'ABSO_out'                     # nothing drawn yet
        A-MovEbxSi   $ovl 'aztInjBufPtr'
        A-TestEbxEbx $ovl
        A-Jz $ovl 'ABSO_out'
        A-Db $ovl @(0x89,0xC2)                   # mov edx, eax
        A-Db $ovl @(0xC1,0xEA,0x0A)              # shr edx, 10  -- the row, for its parity
        A-AddEaxEbx  $ovl
        A-MovEdiEax  $ovl
        A-MovEbpImm  $ovl ([int]$BOOT_SWEEP_ROWS)
        A-PushDsPopEs $ovl
        Add-Label $ovl 'ABSO_row'
        # Repaint in the CURRENT fill/scan colours, read from the variables rather than baked
        # in: during the warm-up the screen is several steps darker than its final amber, and
        # an erase in the final colour would leave a bright band exactly where the line was.
        A-Db $ovl @(0xF6,0xC2,[byte]$BOOT_SCAN_H) # test dl, BOOT_SCAN_H -- the band bit
        A-JzS $ovl 'ABSO_even'
        A-MovEaxSi $ovl 'aztScanDw'
        A-JmpS $ovl 'ABSO_have'
        Add-Label $ovl 'ABSO_even'
        A-MovEaxSi $ovl 'aztFillDw'
        Add-Label $ovl 'ABSO_have'
        A-MovEcxImm $ovl ([int]($INJ_W / 4))
        A-RepStosd  $ovl                         # one row; edi lands on the next
        A-Db $ovl @(0x42)                        # inc edx
        A-DecEbp $ovl
        A-Jnz $ovl 'ABSO_row'
        A-MovDwordSiImm $ovl 'aztSweepOff' 0xFFFFFFFFL
        Add-Label $ovl 'ABSO_out'
        A-Popad $ovl
        A-Ret   $ovl

        # The row scales from the remainder of el/period, over a span of (H - ROWS + 1) rather
        # than H: that makes the bottom row the line can reach exactly the last one it fits
        # in, so no clamp is needed and no arrangement of the clock can put it past the end of
        # the buffer.
        Add-Label $ovl 'AztBootSweepOn'
        A-Pushad $ovl
        A-MovEbxSi   $ovl 'aztInjBufPtr'
        A-TestEbxEbx $ovl
        A-Jz $ovl 'ABSN_out'
        A-MovEaxSi  $ovl 'aztBootEl'
        A-XorEdxEdx $ovl
        A-MovEcxImm $ovl ([int]$BOOT_SWEEP_US)
        A-DivEcx    $ovl                         # edx = how far into this pass
        A-Db $ovl @(0x89,0xD0)                   # mov eax, edx
        A-MovEcxImm $ovl ([int]($INJ_H - $BOOT_SWEEP_ROWS + 1))
        A-MulEcx    $ovl                         # asserted at build time to fit 32 bits
        A-MovEcxImm $ovl ([int]$BOOT_SWEEP_US)
        A-DivEcx    $ovl                         # eax = the row
        A-RowsBytes $ovl 'eax'                      # -> byte offset
        A-MovSiEax32 $ovl 'aztSweepOff'          # remembered, so next frame can erase it
        A-AddEaxEbx $ovl
        A-MovEdiEax $ovl
        # EDI FIRST, then ebx is recycled: bl/bh carry the two background colours to test
        # against, and the buffer pointer is not needed again.
        A-MovEaxSi  $ovl 'aztFillDw'
        A-MovEbxEax $ovl                         # bl = fill
        A-MovEaxSi  $ovl 'aztScanDw'
        A-Db $ovl @(0x88,0xC7)                   # mov bh, al    -- bh = scanline
        A-MovEcxImm $ovl ([int]($BOOT_SWEEP_ROWS * $INJ_W))
        # ONLY OVER BACKGROUND. Ink is left alone, so the line brightens the space around the
        # glyphs and passes behind them rather than erasing them -- which is what reads as a
        # refresh beat instead of a wipe. The disruption's artifacts are left alone too.
        Add-Label $ovl 'ABSN_px'
        A-Db $ovl @(0x8A,0x07)                   # mov al, [edi]
        A-Db $ovl @(0x38,0xD8)                   # cmp al, bl
        A-Db $ovl @(0x74,0x04)                   # je +4 -> the store
        A-Db $ovl @(0x38,0xF8)                   # cmp al, bh
        A-Db $ovl @(0x75,0x03)                   # jne +3 -> past the store
        A-Db $ovl @(0xC6,0x07,[byte]$BOOT_SWEEP_IX)   # mov byte [edi], sweep
        A-Db $ovl @(0x47)                        # inc edi
        A-DecEcx $ovl
        A-JnzS $ovl 'ABSN_px'
        Add-Label $ovl 'ABSN_out'
        A-Popad $ovl
        A-Ret   $ovl

        # ---- the telemetry column --------------------------------------------
        # Hex words in the left margin, re-rolled fast while the visor is damaged, slowly
        # after that, and frozen once the readout completes. The readout says what the check
        # FOUND; this is the only thing on screen that says the machine is working.
        Add-Label $ovl 'AztBootDump'
        A-Pushad $ovl
        A-MovEaxSi  $ovl 'aztBootEl'
        A-CmpEaxImm $ovl $BOOT_DUMP_US
        A-Jb $ovl 'ADM_out'
        A-MovEbxSi   $ovl 'aztInjBufPtr'
        A-TestEbxEbx $ovl
        A-Jz $ovl 'ADM_out'

        # SEEDED ONCE, all of it. The cell table is zero-filled BSS, so without this the
        # column's first frames are a block of '0' -- which reads as a placeholder rather
        # than as data, and the roll only replaces a dozen cells a frame.
        A-CmpDwordSiImm $ovl 'aztDumpInit' 0
        A-Jnz $ovl 'ADM_roll'
        A-MovDwordSiImm $ovl 'aztDumpInit' 1
        A-LeaEdiSi $ovl 'aztDumpCells'
        A-MovEbpImm $ovl ([int]$BOOT_DUMP_CELLS)
        Add-Label $ovl 'ADM_seed'
        A-MovEaxSi   $ovl 'aztBootSeed'          # the same LCG the disruption uses
        A-ImulEaxImm $ovl 1103515245
        A-AddEaxImm  $ovl 12345
        A-MovSiEax32 $ovl 'aztBootSeed'
        A-Db $ovl @(0xC1,0xE8,0x1C)              # shr eax, 28   -- the HIGH nibble; an LCG's
        A-Db $ovl @(0x88,0x07)                   #   low bits are poor. mov [edi], al
        A-Db $ovl @(0x47)                        # inc edi
        A-DecEbp $ovl
        A-Jnz $ovl 'ADM_seed'

        # How many cells change this frame.
        Add-Label $ovl 'ADM_roll'
        A-MovEbpImm $ovl ([int]$BOOT_DUMP_SLOW)
        A-MovEaxSi  $ovl 'aztBootEl'
        A-CmpEaxImm $ovl $BOOT_DISRUPT_US
        A-JaeS $ovl 'ADM_rate'
        A-MovEbpImm $ovl ([int]$BOOT_DUMP_FAST)
        Add-Label $ovl 'ADM_rate'
        A-MovEaxSi  $ovl 'aztBootEl'
        A-CmpEaxImm $ovl $BOOT_DUMP_FREEZE
        A-JbS $ovl 'ADM_rlp'
        A-XorEaxEax $ovl
        A-Db $ovl @(0x89,0xC5)                   # mov ebp, eax  -- frozen: the check is done
        Add-Label $ovl 'ADM_rlp'
        A-TestEbpEbp $ovl
        A-Jz $ovl 'ADM_blit'
        Add-Label $ovl 'ADM_r1'
        A-MovEaxSi   $ovl 'aztBootSeed'
        A-ImulEaxImm $ovl 1103515245
        A-AddEaxImm  $ovl 12345
        A-MovSiEax32 $ovl 'aztBootSeed'
        A-Db $ovl @(0x89,0xC1)                   # mov ecx, eax
        A-Db $ovl @(0xC1,0xE9,0x1C)              # shr ecx, 28   -- the new digit
        A-Db $ovl @(0xC1,0xE8,0x08)              # shr eax, 8    -- drop the poor low bits
        A-AndEaxImm  $ovl 0x000FFFFF
        A-XorEdxEdx  $ovl
        A-PushEcx    $ovl                        # div writes ecx's job away
        A-MovEcxImm  $ovl ([int]$BOOT_DUMP_CELLS)
        A-DivEcx     $ovl                        # edx = the cell, 0..CELLS-1 exactly
        A-PopEcx     $ovl
        # A DIVIDE, NOT A MASK. BOOT_DUMP_CELLS is derived from the readout stack's height and
        # is not a power of two (80 today), so a mask would either bias the picks or need a
        # skip-and-retry; one div per rolled cell is a rounding error next to the blit below.
        A-LeaEdiSi $ovl 'aztDumpCells'
        A-Db $ovl @(0x01,0xD7)                   # add edi, edx
        A-Db $ovl @(0x88,0x0F)                   # mov [edi], cl
        A-DecEbp $ovl
        A-Jnz $ovl 'ADM_r1'

        # ---- blit the column -------------------------------------------------
        # Registers are exactly full here: esi is the obj1 delta, edi the destination, ebx the
        # transposed glyph strip, ebp the expansion table, edx the cell cursor, eax and ecx
        # scratch. Both loop counters therefore live on the stack.
        #
        # The per-cell expansion is UNROLLED over BOOT_DUMP_COLS, which is what frees the
        # register the column counter would have taken -- and the cell and destination
        # offsets become disp8 immediates (asserted to fit at build time).
        Add-Label $ovl 'ADM_blit'
        A-LeaEdxSi $ovl 'aztDumpCells'
        A-MovEaxImm $ovl ([uint32]($BOOT_DUMP_Y * $INJ_W + $BOOT_DUMP_X))
        A-AddEaxEbx $ovl
        A-MovEdiEax $ovl
        A-MovEaxImm $ovl ([int]$BOOT_DUMP_ROWS)
        A-PushEax   $ovl                         # [esp] = cell rows left
        Add-Label $ovl 'ADM_crow'
        A-LeaEbxSi  $ovl 'aztDumpHex'            # row 0 of the strip, for this cell row
        A-MovEaxImm $ovl ([int]$BOOT_TXT_H)
        A-PushEax   $ovl                         # [esp] = pixel rows left in this cell row
        Add-Label $ovl 'ADM_prow'
        # Parity off the DOWN counter, exactly as the readout's blit does it: it starts on
        # BOOT_TXT_H (even) and alternates, and BOOT_DUMP_Y is asserted even, so bit 0 clear
        # means an even screen row and therefore the bright table.
        A-Db $ovl @(0x8B,0x04,0x24)              # mov eax, [esp]
        if ($BOOT_SCAN_H -eq 2) {
            # Same XOR as the readout's blit -- see the proof there. This counter runs
            # down from BOOT_TXT_H, which is aligned to the band pair, and BOOT_DUMP_Y
            # is BOOT_TXT_Y, so every cell row starts on the same phase. ecx is free:
            # it is not loaded until the digit's bits are expanded below.
            A-Db $ovl @(0x89,0xC1)               # mov ecx, eax
            A-Db $ovl @(0xD1,0xE9)               # shr ecx, 1
            A-Db $ovl @(0x31,0xC8)               # xor eax, ecx
        }
        A-Db $ovl @(0xA8,0x01)                   # test al, 1
        A-JzS $ovl 'ADM_even'
        A-LeaEbpSi $ovl 'aztBootTab2'
        A-JmpS $ovl 'ADM_tab'
        Add-Label $ovl 'ADM_even'
        A-LeaEbpSi $ovl 'aztBootTab'
        Add-Label $ovl 'ADM_tab'
        # TWO HALVES PER DIGIT now that the cell is 16 px wide (see Render-BootHex): the
        # same 256 x 8 expansion table is run twice, once per strip byte, instead of
        # needing a 256 x 16 table the overlay has no room for. The digit is re-read from
        # [edx+k] for the second half rather than parked in a register -- esi is the obj1
        # delta, ebp the table, edi the destination and edx the cell cursor, so there is
        # no spare one, which is the same constraint that made the strip transposed.
        for ($k = 0; $k -lt $BOOT_DUMP_COLS; $k++) {
            $cell = $k * $BOOT_HEX_CELL
            A-Db $ovl @(0x0F,0xB6,0x42,[byte]$k)         # movzx eax, byte [edx+k]  -- the digit
            A-Db $ovl @(0x0F,0xB6,0x04,0x43)             # movzx eax, byte [ebx+eax*2]  -- left bits
            A-Db $ovl @(0x8D,0x4C,0xC5,0x00)             # lea ecx, [ebp+eax*8]
            A-Db $ovl @(0x8B,0x01)                       # mov eax, [ecx]
            A-Db $ovl @(0x89,0x47,[byte]$cell)           # mov [edi+cell], eax
            A-Db $ovl @(0x8B,0x41,0x04)                  # mov eax, [ecx+4]
            A-Db $ovl @(0x89,0x47,[byte]($cell + 4))     # mov [edi+cell+4], eax
            A-Db $ovl @(0x0F,0xB6,0x42,[byte]$k)         # movzx eax, byte [edx+k]  -- again
            A-Db $ovl @(0x0F,0xB6,0x44,0x43,0x01)        # movzx eax, byte [ebx+eax*2+1] -- right bits
            A-Db $ovl @(0x8D,0x4C,0xC5,0x00)             # lea ecx, [ebp+eax*8]
            A-Db $ovl @(0x8B,0x01)                       # mov eax, [ecx]
            A-Db $ovl @(0x89,0x47,[byte]($cell + 8))     # mov [edi+cell+8], eax
            A-Db $ovl @(0x8B,0x41,0x04)                  # mov eax, [ecx+4]
            A-Db $ovl @(0x89,0x47,[byte]($cell + 12))    # mov [edi+cell+12], eax
        }
        # edi was addressed by displacement throughout, so it is still on this row's first
        # pixel: one whole row advances it, with no width fixup.
        A-AddEdiImm32 $ovl ([uint32]$INJ_W)
        A-Db $ovl @(0x83,0xC3,[byte](16 * ($BOOT_HEX_CELL / 8)))   # add ebx, stride -- next strip row
        A-Db $ovl @(0xFF,0x0C,0x24)              # dec dword [esp]
        A-Jnz $ovl 'ADM_prow'
        A-Db $ovl @(0x83,0xC4,0x04)              # add esp, 4
        A-Db $ovl @(0x83,0xC2,[byte]$BOOT_DUMP_COLS)  # add edx, COLS -- the next cell row
        A-Db $ovl @(0xFF,0x0C,0x24)              # dec dword [esp]
        A-Jnz $ovl 'ADM_crow'
        A-Db $ovl @(0x83,0xC4,0x04)              # add esp, 4

        # ---- and dim it ------------------------------------------------------
        # The column shares the readout's expansion tables, so it comes out at the readout's
        # own brightness and competes with it. One post-pass over its rectangle pushes the ink
        # BOOT_DUMP_DIM steps down the teal ramp. aztDumpIx, not an immediate, so the decay
        # carries the column with it instead of leaving a lit strip beside a fading block.
        A-MovEbxSi   $ovl 'aztInjBufPtr'
        A-MovEaxImm  $ovl ([uint32]($BOOT_DUMP_Y * $INJ_W + $BOOT_DUMP_X))
        A-AddEaxEbx  $ovl
        A-MovEdiEax  $ovl
        A-MovEdxSi32 $ovl 'aztDumpIx'            # dl = the target shade
        A-MovEbpImm  $ovl ([int]($BOOT_DUMP_ROWS * $BOOT_TXT_H))
        Add-Label $ovl 'ADM_dr'
        A-MovEcxImm $ovl ([int]$BOOT_DUMP_W)
        Add-Label $ovl 'ADM_db'
        A-Db $ovl @(0x8A,0x07)                   # mov al, [edi]
        A-Db $ovl @(0x2C,[byte]$BOOT_INK_IX)     # sub al, ink
        A-Db $ovl @(0x3C,0x10)                   # cmp al, 16
        A-Db $ovl @(0x73,0x02)                   # jae +2 -- background, leave it
        A-Db $ovl @(0x88,0x17)                   # mov [edi], dl
        A-Db $ovl @(0x47)                        # inc edi
        A-DecEcx $ovl
        A-JnzS $ovl 'ADM_db'
        A-AddEdiImm32 $ovl ([uint32]($INJ_W - $BOOT_DUMP_W))
        A-DecEbp $ovl
        A-Jnz $ovl 'ADM_dr'
        Add-Label $ovl 'ADM_out'
        A-Popad $ovl
        A-Ret   $ovl

        Add-Label $ovl 'AztBootPaint'
        A-Pushad $ovl
        # No slip unless this frame asks for one. Cleared HERE rather than at the end of the
        # slip window, because the mission and shutter phases never call AztBootSlip and a
        # stale roll would leave the whole handover permanently offset.
        A-MovDwordSiImm $ovl 'aztInjRoll' 0
        # ...and the screen paints at its normal brightness. Nothing raises these today,
        # but the reset belongs HERE rather than in whatever sets them: the mission and
        # shutter phases run none of the phase-1 routines, so a tint left set anywhere else
        # would light the whole rest of the sequence.
        A-MovDwordSiImm $ovl 'aztFillDw' ([uint32]($BOOT_FILL_IX * 0x01010101))
        A-MovDwordSiImm $ovl 'aztScanDw' ([uint32]($BOOT_SCAN_IX * 0x01010101))
        # ERASE LAST FRAME'S REFRESH LINE FIRST, before any phase draws and before the warm-up
        # changes the fill colours out from under it. Unconditional, including in the shutter
        # phase: that is what guarantees no bright line is ever left behind on the handover.
        A-Call $ovl 'AztBootSweepOff'
        A-MovEaxSi  $ovl 'aztBootEl'
        A-CmpEaxImm $ovl $BOOT_OPEN_US
        A-Jae $ovl 'ABP_reveal'                  # phase 3: the shutter
        A-CmpEaxImm $ovl $BOOT_MISSION_US
        A-Jae $ovl 'ABP_mission'                 # phase 2: the mission line
        # Phase 1. The disruption owns the background while it lasts (it repaints every
        # frame); once it stops, ONE more clear is needed or the last frame's streaks stay
        # on screen for the rest of the sequence.
        #
        # THE SLIP DECIDES FIRST, before the clear. It does not need to today -- the roll is
        # consumed by the injection, long after this -- but anything that tints the screen
        # for a frame has to be set before AztBootGlitch repaints it, or it misses its own
        # frame entirely. That caught out the brightness flash, and the CRT warm-up below
        # depends on it.
        A-Call $ovl 'AztBootWarm'                # sets the fill/scan colours for this frame
        A-Call $ovl 'AztBootSlip'

        # ---- the phosphor decay owns the last stretch of phase 1 --------------
        # Everything still redraws, so the fade is exact -- but the disruption, the glyph
        # corruption, the tear and the split are all SKIPPED. Not for cost: this is the one
        # stretch where the background is not being repainted by the disruption, so a tear or
        # a displaced glyph cell here would never heal. The same reason AztBootTearMis is
        # confined to the mission block's own rectangle.
        A-MovEaxSi  $ovl 'aztBootEl'
        A-CmpEaxImm $ovl $BOOT_DECAY_FROM
        A-Jb $ovl 'ABP_live'
        A-SubEaxImm $ovl $BOOT_DECAY_FROM
        A-MovEcxImm $ovl ([int]$BOOT_DECAY_RAMP.Count)
        A-MulEcx    $ovl                         # el*3 against a 0.4 s window: edx stays 0
        A-MovEcxImm $ovl ([int]$BOOT_DECAY_US)
        A-DivEcx    $ovl                         # eax = the step
        A-CmpEaxImm $ovl ([int]($BOOT_DECAY_RAMP.Count - 1))
        A-JbeS $ovl 'ABP_dk'
        A-MovEaxImm $ovl ([int]($BOOT_DECAY_RAMP.Count - 1))
        Add-Label $ovl 'ABP_dk'
        A-MovEcxImm $ovl 4
        A-MulEcx    $ovl
        A-LeaEdxSi  $ovl 'aztBootDecayTab'
        A-Db $ovl @(0x01,0xD0)                   # add eax, edx
        A-Db $ovl @(0x8B,0x00)                   # mov eax, [eax]  -- this step's ink index
        A-Call $ovl 'AztBootInk'
        A-Call $ovl 'AztBootText'
        A-Call $ovl 'AztBootBar'
        A-Call $ovl 'AztBootFinal'
        A-Call $ovl 'AztBootDump'
        A-Jmp $ovl 'ABP_sweep'

        Add-Label $ovl 'ABP_live'
        # Restore full-brightness ink. A no-op on every frame but the first after a decay
        # (AztBootInk compares before it walks the tables), and it has to be here rather than
        # only at the wipe: the reload re-boot re-enters mid-sequence with whatever the tables
        # were last left holding.
        A-MovEaxImm $ovl ([int]$BOOT_INK_IX)
        A-Call $ovl 'AztBootInk'
        A-MovEaxSi  $ovl 'aztBootEl'
        A-CmpEaxImm $ovl $BOOT_DISRUPT_US
        A-Jae $ovl 'ABP_settled'
        A-Call $ovl 'AztBootGlitch'
        A-JmpS $ovl 'ABP_txt'
        Add-Label $ovl 'ABP_settled'
        A-CmpDwordSiImm $ovl 'aztBootDisDone' 0
        A-Jnz $ovl 'ABP_txt'
        A-MovDwordSiImm $ovl 'aztBootDisDone' 1
        A-Call $ovl 'AztBootClear'
        Add-Label $ovl 'ABP_txt'
        A-Call $ovl 'AztBootText'                # banner, then the readout
        A-Call $ovl 'AztBootBar'                 # ...and the progress bar under it
        A-Call $ovl 'AztBootDump'                # ...and the telemetry column beside them
        A-MovEaxSi  $ovl 'aztBootEl'             # then the closing line, typing itself in
        A-CmpEaxImm $ovl $BOOT_FINAL_US
        A-JbS $ovl 'ABP_tear'
        A-Call $ovl 'AztBootFinal'
        # LAST, so it tears everything drawn this frame -- background, artifacts and text.
        Add-Label $ovl 'ABP_tear'
        A-Call $ovl 'AztBootGlyph'               # before the tear, so torn cells move with it
        A-Call $ovl 'AztBootTear'
        A-Call $ovl 'AztBootSplit'
        # The refresh line goes on after the tear, never before: the tear rotates whole rows
        # and would carry the line somewhere the erase does not know to look.
        Add-Label $ovl 'ABP_sweep'
        A-Call $ovl 'AztBootSweepOn'
        A-Jmp $ovl 'ABP_out'

        # WIPE THE SCREEN ONCE. The banner and readout are still sitting in the buffer, and
        # the mission line is supposed to land on blank amber. AztBootClear repaints the fill
        # and the scanlines, so it is exactly the wipe needed -- but it must happen on one
        # frame only, or the mission line would be erased again every frame after it.
        Add-Label $ovl 'ABP_mission'
        A-CmpDwordSiImm $ovl 'aztBootWiped' 0
        A-Jnz $ovl 'ABP_mtext'
        A-MovDwordSiImm $ovl 'aztBootWiped' 1
        A-Call $ovl 'AztBootClear'
        Add-Label $ovl 'ABP_mtext'
        # BACK TO FULL INK before the briefing draws. The decay left the expansion tables
        # holding the last step of the ramp, and the mission block goes through those same
        # tables -- without this it would type itself in already half-faded.
        A-MovEaxImm $ovl ([int]$BOOT_INK_IX)
        A-Call $ovl 'AztBootInk'
        # THE TELEMETRY COLUMN SURVIVES THE WIPE. Extending its churn window was not enough on
        # its own: this phase repaints the screen once and then draws only the briefing, so the
        # column was simply never redrawn after the wipe and vanished the moment the mission
        # line appeared. Drawn here, every frame, exactly as ABP_live does it -- and after the
        # ink restore above, so it dims from full ink rather than from the decay's last step.
        #
        # BEFORE the reload check below, so a re-boot keeps it too: that path skips the
        # briefing and would otherwise sit on blank amber with nothing moving at all.
        A-Call $ovl 'AztBootDump'
        # A RELOAD GETS THE WIPE BUT NOT THE BRIEFING. The mission text belongs to starting
        # the game; replaying it every time a save is loaded would wear out fast, and the
        # blank amber it leaves is exactly the "visor re-engaging" beat the reload wants.
        if ($ENABLE_REBOOT_ON_LOAD) {
            A-CmpDwordSiImm $ovl 'aztReboot' 0
            A-Jnz $ovl 'ABP_msweep'              # still gets the refresh line
        }
        A-Call $ovl 'AztBootMission'
        A-Call $ovl 'AztBootTearMis'             # AFTER the blit, so there is text to tear
        Add-Label $ovl 'ABP_msweep'
        A-Call $ovl 'AztBootSweepOn'             # ...and the line passes over the briefing too
        A-Jmp $ovl 'ABP_out'

        Add-Label $ovl 'ABP_reveal'
        A-MovEaxSi  $ovl 'aztBootEl'
        A-SubEaxImm $ovl $BOOT_OPEN_US
        A-MovEcxImm $ovl ([int]($INJ_H / 2))
        A-MulEcx    $ovl
        A-MovEcxImm $ovl ([int]$BOOT_OPEN_SPAN)
        A-DivEcx    $ovl
        A-TestEaxEax $ovl
        A-Jnz $ovl 'ABP_clamp'
        A-MovEaxImm $ovl 1
        Add-Label $ovl 'ABP_clamp'
        A-CmpEaxImm $ovl ([int]($INJ_H / 2))
        A-JbeS $ovl 'ABP_hok'
        A-MovEaxImm $ovl ([int]($INJ_H / 2))
        Add-Label $ovl 'ABP_hok'
        A-MovSiEax32 $ovl 'aztBootH'

        A-RowsBytes $ovl 'eax'                      # h * 1024 bytes = h rows
        A-MovEbxEax $ovl
        A-MovEaxImm $ovl ([int]($INJ_H / 2 * $INJ_W))
        A-SubEaxEbx $ovl                         # eax = (288-h)*1024, the band's top
        A-MovSiEax32 $ovl 'aztBootTop'

        # GHOST DEPTH, in rows: min(BOOT_GHOST_ROWS, h, 288-h).
        #   capped at h       so the two panels cannot cross while the slit is only a few
        #                     rows tall, which would give the split copy negative lengths
        #   capped at 288-h   so it reaches zero exactly as the shutter completes, instead
        #                     of leaving a permanent dim border around the revealed 3D
        A-MovEaxSi  $ovl 'aztBootH'
        A-MovEcxImm $ovl ([int]$BOOT_GHOST_ROWS)
        A-Db $ovl @(0x39,0xC1)                   # cmp ecx, eax
        A-JbeS $ovl 'ABP_g1'
        A-Db $ovl @(0x89,0xC1)                   # mov ecx, eax   -- g = h
        Add-Label $ovl 'ABP_g1'
        A-MovEdxImm $ovl ([int]($INJ_H / 2))
        A-Db $ovl @(0x29,0xC2)                   # sub edx, eax   -- 288 - h
        A-Db $ovl @(0x39,0xD1)                   # cmp ecx, edx
        A-JbeS $ovl 'ABP_g2'
        A-Db $ovl @(0x89,0xD1)                   # mov ecx, edx
        Add-Label $ovl 'ABP_g2'
        A-MovSiEcx32 $ovl 'aztBootGhost'

        # Tell the injection to copy only the two panels -- plus the ghost rows, which are
        # part of the panel as far as the copy is concerned. top is already (288-h)*1024.
        A-MovEaxSi   $ovl 'aztBootTop'
        A-MovEcxSi   $ovl 'aztBootGhost'
        A-RowsBytes  $ovl 'ecx'                     # ghost rows, in bytes
        A-Db $ovl @(0x01,0xC8)                   # add eax, ecx
        A-Db $ovl @(0xC1,0xE8,0x02)              # shr eax, 2  -> dwords
        A-MovSiEax32 $ovl 'aztInjTopDw'
        A-MovEaxSi   $ovl 'aztBootH'
        A-RowsBytes  $ovl 'eax'                     # h rows, in bytes
        A-AddEaxImm  $ovl ([uint32]($INJ_H / 2 * $INJ_W))
        A-MovEcxSi   $ovl 'aztBootGhost'
        A-RowsBytes  $ovl 'ecx'
        A-Db $ovl @(0x29,0xC8)                   # sub eax, ecx
        A-MovSiEax32 $ovl 'aztInjBotOff'         # (288+h-g)*1024
        A-MovDwordSiImm $ovl 'aztInjSplit' 1

        # The lips go on the panels' INNER edges -- the last two rows of the upper panel
        # and the first two of the lower -- because only the panels are copied now.
        A-MovEbxSi   $ovl 'aztInjBufPtr'
        A-TestEbxEbx $ovl
        A-Jz $ovl 'ABP_out'
        A-MovEaxSi   $ovl 'aztBootTop'
        A-CmpEaxImm  $ovl 2048
        A-Jb $ovl 'ABP_lolip'                    # panel too thin to carry a lip
        A-SubEaxImm  $ovl 2048
        A-AddEaxEbx  $ovl
        A-MovEdiEax  $ovl
        A-MovEcxImm  $ovl 512                    # 2 rows
        A-MovEaxImm  $ovl ([uint32]($BOOT_LIP_IX * 0x01010101))
        A-PushDsPopEs $ovl
        A-RepStosd   $ovl

        # The phosphor ghost: g rows of dim fill INSIDE the opening, one band trailing each
        # panel. Drawn after the lip so the bright edge stays the outermost thing, and the
        # fade reads outward from it: panel, lip, ghost, world.
        A-MovEcxSi   $ovl 'aztBootGhost'
        A-TestEcxEcx $ovl
        A-Jz $ovl 'ABP_nogh'
        A-MovEaxSi   $ovl 'aztBootTop'           # the upper ghost starts at the band's top
        A-AddEaxEbx  $ovl
        A-MovEdiEax  $ovl
        A-RowsDwords  $ovl 'ecx'                      # rows * 1024 / 4 dwords
        A-MovEaxImm  $ovl ([uint32]($BOOT_GHOST_IX * 0x01010101))
        A-RepStosd   $ovl
        A-MovEaxSi   $ovl 'aztBootH'             # the lower one ends at the band's bottom
        A-RowsBytes  $ovl 'eax'
        A-AddEaxImm  $ovl ([uint32]($INJ_H / 2 * $INJ_W))
        A-MovEcxSi   $ovl 'aztBootGhost'
        A-RowsBytes  $ovl 'ecx'
        A-Db $ovl @(0x29,0xC8)                   # sub eax, ecx   -> (288+h-g)*1024
        A-AddEaxEbx  $ovl
        A-MovEdiEax  $ovl
        A-MovEcxSi   $ovl 'aztBootGhost'
        A-RowsDwords  $ovl 'ecx'
        A-MovEaxImm  $ovl ([uint32]($BOOT_GHOST_IX * 0x01010101))
        A-RepStosd   $ovl
        Add-Label $ovl 'ABP_nogh'

        Add-Label $ovl 'ABP_lolip'
        # THE LOWER PANEL SHRINKS TO NOTHING. At h=288 its offset IS the end of the buffer,
        # so drawing a lip there wrote up to 2,048 bytes PAST a 576 KB heap allocation on
        # the last two frames of the reveal. That corrupted the heap exactly as the
        # animation finished: the viewport stopped updating and input died while the music
        # kept playing. Skip the lip once there is no panel left to put it on.
        A-MovEaxSi   $ovl 'aztInjBotOff'
        A-CmpEaxImm  $ovl ([uint32]($INJ_W * $INJ_H - 2048))
        A-Ja $ovl 'ABP_out'
        A-AddEaxEbx  $ovl
        A-MovEdiEax  $ovl
        A-MovEcxImm  $ovl 512
        A-MovEaxImm  $ovl ([uint32]($BOOT_LIP_IX * 0x01010101))
        A-PushDsPopEs $ovl
        A-RepStosd   $ovl

        Add-Label $ovl 'ABP_out'
        A-Popad $ovl
        A-Ret   $ovl

        # ---- the readout -----------------------------------------------------
        # Lines are stacked contiguously in the source bitmap, so "show the first N"
        # is just "blit the first N*16 rows" -- no per-line bookkeeping at all.
        #
        # ebx = source bits, ebp = expansion table, edi = destination. Each source byte
        # becomes eight destination bytes via one table lookup and two dword moves, so
        # the inner loop never touches a bit.
        # How much of the block is on screen. The banner is 6 lines and appears as a BLOCK,
        # so the count jumps straight to 6; the readout then adds one line at a time under it.
        Add-Label $ovl 'AztBootText'
        A-Pushad $ovl
        A-MovDwordSiImm $ovl 'aztCaretH' 0       # the block does not type, so no caret
        A-MovEaxSi  $ovl 'aztBootEl'
        A-CmpEaxImm $ovl $BOOT_BANNER_US
        A-Jb $ovl 'ABX_out'                      # amber screen, nothing on it yet
        A-CmpEaxImm $ovl $BOOT_TEXT_US
        A-Jb $ovl 'ABX_banner'                   # still drawing the banner
        A-SubEaxImm $ovl $BOOT_TEXT_US
        A-XorEdxEdx $ovl                         # div needs it zeroed; sub left it dirty
        A-MovEcxImm $ovl $BOOT_LINE_US
        A-DivEcx    $ovl
        # div leaves the REMAINDER in edx, which is exactly how long the newest line has
        # been up. The flare needs that and it is already computed -- no second divide.
        A-MovSiEdx32 $ovl 'aztFlareAge'
        A-AddEaxImm $ovl ([int]($BOOT_BANNER.Count + 1))   # banner + the line that landed
        A-JmpS $ovl 'ABX_clamp'
        # The banner DRAWS IN, one line at a time, instead of appearing whole.
        Add-Label $ovl 'ABX_banner'
        A-SubEaxImm $ovl $BOOT_BANNER_US
        A-XorEdxEdx $ovl
        A-MovEcxImm $ovl $BOOT_BAN_STEP
        A-DivEcx    $ovl
        A-MovSiEdx32 $ovl 'aztFlareAge'          # remainder = age of the newest banner line
        A-AddEaxImm $ovl 1
        A-CmpEaxImm $ovl ([int]$BOOT_BANNER.Count)
        A-JbeS $ovl 'ABX_clamp'
        A-MovEaxImm $ovl ([int]$BOOT_BANNER.Count)
        # CLAMPED, so the remainder above is meaningless -- it keeps cycling every step and
        # would re-flare the last line forever. Poison the age so the flare test fails.
        A-MovDwordSiImm $ovl 'aztFlareAge' 0xFFFFFFFFL
        Add-Label $ovl 'ABX_clamp'
        A-CmpEaxImm $ovl ([int]$BOOT_ALL_LINES.Count)
        A-JbeS $ovl 'ABX_n'
        A-MovEaxImm $ovl ([int]$BOOT_ALL_LINES.Count)
        A-MovDwordSiImm $ovl 'aztFlareAge' 0xFFFFFFFFL   # same, for the readout
        Add-Label $ovl 'ABX_n'
        A-MovSiEax32 $ovl 'aztBootLineN'         # keep the line count for the flare
        A-ImulEaxImm $ovl ([uint32]$BOOT_TXT_H)  # rows per line -- NOT a shl, see above
        # ...plus the banner gap, but ONLY once the readout has started. The gap sits
        # between the banner and the readout inside the bitmap, so while just the banner is
        # up the row count must not include it, or the reveal would run past what is drawn.
        if ($BOOT_BAN_GAP -gt 0) {
            A-CmpEaxImm $ovl ([int]($BOOT_BANNER.Count * $BOOT_TXT_H))
            A-JbeS $ovl 'ABX_nogap'
            A-AddEaxImm32 $ovl ([uint32]$BOOT_BAN_GAP)
            Add-Label $ovl 'ABX_nogap'
        }
        A-MovSiEax32 $ovl 'aztBootRows'

        # ---- phosphor flare: which rows, if any, are still hot ----------------
        # Only the newest line, and only for BOOT_FLARE_US after it lands. The post-pass
        # that does the brightening runs after the blit, so this just works out where.
        A-MovDwordSiImm $ovl 'aztFlareRows' 0
        A-MovEaxSi  $ovl 'aztFlareAge'
        A-CmpEaxImm $ovl ([int]$BOOT_FLARE_US)
        A-Jae $ovl 'ABX_noflare'
        A-MovEaxSi   $ovl 'aztBootLineN'
        A-TestEaxEax $ovl
        A-Jz $ovl 'ABX_noflare'                  # nothing drawn yet
        A-DecEax $ovl                            # index of the newest line
        A-Db $ovl @(0x89,0xC2)                   # mov edx, eax
        A-ImulEaxImm $ovl ([uint32]$BOOT_TXT_H)  # its first row inside the bitmap
        A-CmpEdxImm $ovl ([int]$BOOT_BANNER.Count)
        A-JbS $ovl 'ABX_flnogap'                 # a banner line sits above the gap
        A-AddEaxImm32 $ovl ([uint32]$BOOT_BAN_GAP)
        Add-Label $ovl 'ABX_flnogap'
        A-RowsBytes $ovl 'eax'                      # rows -> byte offset (x INJ_W)
        A-AddEaxImm32 $ovl ([uint32]($BOOT_TXT_Y * $INJ_W + $BOOT_TXT_X))
        A-MovSiEax32 $ovl 'aztFlareOff'
        A-MovDwordSiImm $ovl 'aztFlareRows' ([int]$BOOT_TXT_H)
        Add-Label $ovl 'ABX_noflare'

        A-MovEbxSi   $ovl 'aztInjBufPtr'
        A-TestEbxEbx $ovl
        A-Jz $ovl 'ABX_out'
        A-MovEaxImm $ovl ([int]($BOOT_TXT_Y * $INJ_W + $BOOT_TXT_X))
        A-AddEaxEbx $ovl
        A-MovEdiEax $ovl                         # edi = first destination pixel
        A-LeaEaxSi  $ovl 'aztBootBits'
        A-MovEbxEax $ovl                         # ebx = source
        A-Jmp $ovl 'ABX_row'   # rel32: AztBootMission now sits between here and the blit

        # The mission line: same width, pitch and tables, so it reuses the blit below --
        # only the source, the row count and the destination differ.
        # TYPES IN LEFT TO RIGHT, and it does that WITHOUT touching the blit. Each frame it
        # rebuilds a scratch copy of the bitmap holding only the revealed columns, with the
        # rest ZEROED -- and a zero source byte expands, through the same table, to eight
        # background pixels. So the blit runs unchanged at full width and the untyped tail
        # simply draws as background. Changing the blit's own column count instead would
        # have meant a variable row stride, which needs a register none of them has spare.
        # Reveal is in whole bytes, i.e. 8-pixel steps, which at this size is under a
        # character and reads as smooth.
        # Two things type themselves in now -- the closing readout line and the mission line --
        # so the mechanism is driven by variables instead of being written twice. The caller
        # sets aztTyp* and the revealed column count, then tail-jumps here; this builds the
        # partially-revealed scratch copy and falls into the shared blit.
        Add-Label $ovl 'AztBootTyped'
        A-Pushad $ovl
        # The block's flare was already applied this frame by AztBootText; clear it so its
        # row range is not brightened a second time over this element's destination.
        A-MovDwordSiImm $ovl 'aztFlareRows' 0
        A-MovEbxSi  $ovl 'aztTypSrc'             # ebx = the real bitmap
        A-MovEaxSi  $ovl 'aztTypScr'
        A-MovEdiEax $ovl                         # edi = scratch
        A-MovEaxSi  $ovl 'aztBootCols'
        A-Db $ovl @(0x89,0xC2)                   # mov edx, eax
        A-MovEaxSi  $ovl 'aztTypRows'
        A-MovSiEax32 $ovl 'aztBootRows'
        Add-Label $ovl 'ABM2_row'
        A-Db $ovl @(0x31,0xC9)                   # xor ecx, ecx
        Add-Label $ovl 'ABM2_col'
        A-Db $ovl @(0x39,0xD1)                   # cmp ecx, edx
        A-Db $ovl @(0x73,0x04)                   # jae +4  (past the reveal: write 0)
        A-Db $ovl @(0x8A,0x04,0x0B)              # mov al, [ebx+ecx]
        A-Db $ovl @(0xEB,0x02)                   # jmp +2
        A-Db $ovl @(0x30,0xC0)                   # xor al, al
        A-Db $ovl @(0x88,0x04,0x0F)              # mov [edi+ecx], al
        A-Db $ovl @(0x41)                        # inc ecx
        A-Db $ovl @(0x83,0xF9,[byte]$BOOT_TXT_PITCH)  # cmp ecx, pitch
        A-Db $ovl @(0x72,0xEE)                   # jb ABM2_col
        A-Db   $ovl @(0x81,0xC3)                 # add ebx, imm32
        A-Dd32 $ovl ([uint32]$BOOT_TXT_PITCH)
        A-AddEdiImm32 $ovl ([uint32]$BOOT_TXT_PITCH)
        A-DecDwordSi $ovl 'aztBootRows'
        A-Jnz $ovl 'ABM2_row'

        A-MovEaxSi   $ovl 'aztTypRows'           # the blit consumes the counter, so reload
        A-MovSiEax32 $ovl 'aztBootRows'
        A-MovEbxSi   $ovl 'aztInjBufPtr'
        A-TestEbxEbx $ovl
        A-Jz $ovl 'ABX_out'
        A-MovEaxSi  $ovl 'aztTypDest'
        A-AddEaxEbx $ovl
        A-MovEdiEax $ovl
        A-MovEbxSi  $ovl 'aztTypScr'             # blit the partially-typed copy
        A-Jmp $ovl 'ABX_row'

        # ---- the two typed elements -------------------------------------------
        # Each works out how much is revealed, points the shared routine at its own bitmap
        # and scratch, and tail-jumps. Reveal is in whole bytes (8 px), which is under a
        # character at either size and reads as smooth.
        Add-Label $ovl 'AztBootFinal'
        A-MovEaxSi  $ovl 'aztBootEl'
        A-SubEaxImm $ovl $BOOT_FINAL_US
        A-MovEcxImm $ovl ([int]$BOOT_TXT_PITCH)
        A-MulEcx    $ovl
        A-MovEcxImm $ovl ([int]$BOOT_FIN_TYPE_US)
        A-DivEcx    $ovl
        A-CmpEaxImm $ovl ([int]$BOOT_TXT_PITCH)
        A-JbeS $ovl 'ABF_k'
        A-MovEaxImm $ovl ([int]$BOOT_TXT_PITCH)
        Add-Label $ovl 'ABF_k'
        A-MovSiEax32 $ovl 'aztBootCols'
        A-LeaEaxSi   $ovl 'aztBootFinBits';    A-MovSiEax32 $ovl 'aztTypSrc'
        A-LeaEaxSi   $ovl 'aztBootFinScratch'; A-MovSiEax32 $ovl 'aztTypScr'
        A-MovEaxImm  $ovl ([int]$BOOT_FINAL_H); A-MovSiEax32 $ovl 'aztTypRows'
        A-MovEaxImm  $ovl ([int]($BOOT_FINAL_Y * $INJ_W + $BOOT_TXT_X))
        A-MovSiEax32 $ovl 'aztTypDest'
        A-MovDwordSiImm $ovl 'aztCaretH' ([int]$BOOT_FINAL_H)   # a block cursor on the line
        A-MovDwordSiImm $ovl 'aztCaretY' 0
        A-Jmp $ovl 'AztBootTyped'

        Add-Label $ovl 'AztBootMission'
        A-MovEaxSi  $ovl 'aztBootEl'
        A-SubEaxImm $ovl $BOOT_MISSION_US
        A-MovEcxImm $ovl ([int]$BOOT_TXT_PITCH)
        A-MulEcx    $ovl
        A-MovEcxImm $ovl ([int]$BOOT_MIS_TYPE_US)
        A-DivEcx    $ovl
        A-CmpEaxImm $ovl ([int]$BOOT_TXT_PITCH)
        A-JbeS $ovl 'ABM_k'
        A-MovEaxImm $ovl ([int]$BOOT_TXT_PITCH)
        Add-Label $ovl 'ABM_k'
        A-MovSiEax32 $ovl 'aztBootCols'
        A-LeaEaxSi   $ovl 'aztBootMisBits';    A-MovSiEax32 $ovl 'aztTypSrc'
        A-LeaEaxSi   $ovl 'aztBootMisScratch'; A-MovSiEax32 $ovl 'aztTypScr'
        A-MovEaxImm  $ovl ([int]$BOOT_MIS_H);  A-MovSiEax32 $ovl 'aztTypRows'
        A-MovEaxImm  $ovl ([int]($BOOT_MIS_Y * $INJ_W + $BOOT_MIS_X))
        A-MovSiEax32 $ovl 'aztTypDest'
        # The caret rides the OBJECTIVE line, not the whole 72-row block: the reveal wipes
        # all three lines at once, and a 72px blinking bar would read as a wipe head rather
        # than a cursor.
        A-MovDwordSiImm $ovl 'aztCaretH' ([int]$BOOT_MIS_BIG_H)
        A-MovDwordSiImm $ovl 'aztCaretY' ([int]$BOOT_MIS_OBJ_ROW)
        A-Jmp $ovl 'AztBootTyped'

        Add-Label $ovl 'ABX_row'
        # Pick the table for this row's BAND. aztBootRows counts DOWN from the block's
        # row total, so the band has to be derived from a counter that runs backwards.
        #
        # AT BOOT_SCAN_H = 1 that is just parity, because negation preserves it
        # (-i == i mod 2): the low bit alternates every row and is 0 on the first,
        # which with an aligned BOOT_TXT_Y is a bright row.
        #
        # AT BOOT_SCAN_H = 2 parity is not enough -- `mod 4` does NOT survive negation.
        # With the block origin and the row total both multiples of 4:
        #     i   mod 4 = 0 1 2 3      band = ((start+i) >> 1) & 1 = 0 0 1 1
        #     c = T - i, so c mod 4 = 0 3 2 1
        #     therefore c -> band:  0->0  1->1  2->1  3->0
        # which is exactly bit0(c) XOR bit1(c). Three instructions, no new state, and
        # no need to reconstruct the absolute row. ecx is free here; it is not loaded
        # with the byte count until after the table is chosen.
        A-MovEaxSi $ovl 'aztBootRows'
        if ($BOOT_SCAN_H -eq 2) {
            A-Db $ovl @(0x89,0xC1)               # mov ecx, eax
            A-Db $ovl @(0xD1,0xE9)               # shr ecx, 1
            A-Db $ovl @(0x31,0xC8)               # xor eax, ecx
        }
        A-Db $ovl @(0xA8,0x01)                   # test al, 1
        A-JzS $ovl 'ABX_even'
        A-LeaEbpSi $ovl 'aztBootTab2'            # odd countdown  -> odd screen row -> dark
        A-JmpS $ovl 'ABX_tab'
        Add-Label $ovl 'ABX_even'
        A-LeaEbpSi $ovl 'aztBootTab'             # even countdown -> even screen row -> bright
        Add-Label $ovl 'ABX_tab'
        A-MovEcxImm $ovl $BOOT_TXT_PITCH
        Add-Label $ovl 'ABX_byte'
        A-Db $ovl @(0x0F,0xB6,0x03)              # movzx eax, byte [ebx]
        A-Db $ovl @(0x8D,0x54,0xC5,0x00)         # lea edx, [ebp+eax*8]
        A-Db $ovl @(0x8B,0x02)                   # mov eax, [edx]
        A-Db $ovl @(0x89,0x07)                   # mov [edi], eax
        A-Db $ovl @(0x8B,0x42,0x04)              # mov eax, [edx+4]
        A-Db $ovl @(0x89,0x47,0x04)              # mov [edi+4], eax
        A-Db $ovl @(0x83,0xC7,0x08)              # add edi, 8
        A-Db $ovl @(0x43)                        # inc ebx
        A-Db $ovl @(0x49)                        # dec ecx
        A-JnzS $ovl 'ABX_byte'
        A-Db $ovl @(0x81,0xC7)                   # add edi, imm32
        # A-Dd32, NOT A-Dd. A-Dd IGNORES its argument and emits four ZERO bytes -- it is
        # the placeholder used to declare variables, and passing it a real value is
        # silent. Assembled as `add edi,0` the destination never stepped a row, so all
        # 192 rows wrote as one continuous run at the wrong pitch and the readout
        # sheared across the whole screen.
        A-Dd32 $ovl ([uint32]($INJ_W - $BOOT_TXT_W))  # ... to the next row
        A-DecDwordSi $ovl 'aztBootRows'
        A-Jnz $ovl 'ABX_row'

        # ---- post-passes, over what was just drawn ---------------------------
        # These sit AFTER the blit loop and BEFORE ABX_out on purpose: the early exits
        # above jump straight to ABX_out, so a frame with no staging buffer skips both
        # rather than writing through a null pointer.

        # PHOSPHOR FLARE: rewrite ink to the hot colour across the newest line's rows.
        # A second pair of expansion tables would have been 4 KB of BSS for the same
        # result; this is ~25 bytes, and it only runs during the ~120 ms after a line
        # lands, so scanning the rows byte by byte costs nothing worth measuring.
        A-CmpDwordSiImm $ovl 'aztFlareRows' 0
        A-JzS $ovl 'ABX_car0'
        A-MovEbxSi   $ovl 'aztInjBufPtr'
        A-TestEbxEbx $ovl
        A-JzS $ovl 'ABX_car0'
        A-MovEaxSi  $ovl 'aztFlareOff'
        A-AddEaxEbx $ovl
        A-MovEdiEax $ovl
        A-MovEdxSi32 $ovl 'aztFlareRows'
        Add-Label $ovl 'ABX_flr'
        A-MovEcxImm $ovl ([int]$BOOT_TXT_W)
        Add-Label $ovl 'ABX_flp'
        A-Db $ovl @(0x80,0x3F,[byte]$BOOT_INK_IX)     # cmp byte [edi], ink
        A-Db $ovl @(0x75,0x03)                        # jne +3 (past the store)
        A-Db $ovl @(0xC6,0x07,[byte]$BOOT_FLARE_IX)   # mov byte [edi], flare
        A-Db $ovl @(0x47)                             # inc edi
        A-DecEcx $ovl
        A-JnzS $ovl 'ABX_flp'
        A-AddEdiImm32 $ovl ([uint32]($INJ_W - $BOOT_TXT_W))
        A-Db $ovl @(0x4A)                             # dec edx
        A-JnzS $ovl 'ABX_flr'

        # CARET: a solid block at the reveal column, blinking, gone once the line is whole.
        Add-Label $ovl 'ABX_car0'
        A-CmpDwordSiImm $ovl 'aztCaretH' 0
        A-JzS $ovl 'ABX_out'
        A-MovEaxSi  $ovl 'aztBootCols'
        A-CmpEaxImm $ovl ([int]$BOOT_TXT_PITCH)
        A-JaeS $ovl 'ABX_out'                    # fully revealed: the cursor is done
        A-MovEaxSi  $ovl 'aztBootEl'
        A-Db $ovl @(0xC1,0xE8,[byte]$BOOT_CARET_SHR)  # shr eax, n
        A-Db $ovl @(0xA8,0x01)                        # test al, 1
        A-JzS $ovl 'ABX_out'                     # the off half of the blink
        A-MovEbxSi   $ovl 'aztInjBufPtr'
        A-TestEbxEbx $ovl
        A-JzS $ovl 'ABX_out'
        A-MovEaxSi  $ovl 'aztTypDest'
        A-AddEaxEbx $ovl
        A-MovEdiEax $ovl
        A-MovEaxSi  $ovl 'aztCaretY'
        A-RowsBytes $ovl 'eax'                      # row offset -> bytes (x INJ_W)
        A-Db $ovl @(0x01,0xC7)                   # add edi, eax
        A-MovEaxSi  $ovl 'aztBootCols'
        A-ShlEaxImm $ovl 3                       # revealed bytes -> pixels
        A-Db $ovl @(0x01,0xC7)                   # add edi, eax
        A-MovEdxSi32 $ovl 'aztCaretH'
        A-MovEaxImm $ovl ([uint32]($BOOT_CARET_IX * 0x01010101))
        A-PushDsPopEs $ovl
        Add-Label $ovl 'ABX_car'
        A-MovEcxImm $ovl 8                       # one character cell wide
        A-Db $ovl @(0xF3,0xAA)                   # rep stosb
        A-AddEdiImm32 $ovl ([uint32]($INJ_W - 8))
        A-Db $ovl @(0x4A)                        # dec edx
        A-JnzS $ovl 'ABX_car'

        Add-Label $ovl 'ABX_out'
        A-Popad $ovl
        A-Ret   $ovl

        # ---- re-boot the visor when a save is loaded ---------------------------
        # Replaces the single `call 0x4A994` at 0x2CD63 -- the one caller of the function
        # that fopen's SAVE%d.dat with "rb". The real load runs first with the caller's own
        # arguments, then the clock is wound back so the boot sequence restarts partway in.
        #
        # SAFE IN THE OVERLAY, unlike the opening movie: a load can only be asked for from
        # the in-game fold-out, which means gameplay has started and the overlay has been
        # resident since the first frame.
        if ($ENABLE_REBOOT_ON_LOAD) {
            Add-Label $ovl 'AztLoadHook'
            A-Call $ovl ([uint32]0x4A994)        # the real load; its result is unused here
            A-Pushfd $ovl
            A-Pushad $ovl
            A-CallNext $ovl
            Add-Label $ovl 'ALH_ref'
            A-PopEax $ovl
            A-SubEaxImm $ovl 'ALH_ref'
            A-MovEsiEax $ovl                     # esi = obj1 delta
            A-Call $ovl $tAsm.Labels['AztNow']   # eax = now
            A-SubEaxImm $ovl ([int]$BOOT_REBOOT_FROM)
            A-MovSiEax32 $ovl 'aztBootT0'        # ...so `el` already reads BOOT_REBOOT_FROM
            A-MovDwordSiImm $ovl 'aztBootState' 1
            A-MovDwordSiImm $ovl 'aztReboot' 1
            A-MovDwordSiImm $ovl 'aztBootWiped' 0    # let the mission phase blank the screen
            A-MovDwordSiImm $ovl 'aztBootDisDone' 1  # the disruption is long past; no settle clear
            A-Popad $ovl
            A-Popfd $ovl
            A-Ret $ovl
        }

        Add-Label $ovl 'AztBootTick'            # ebx = now, in microseconds
        A-CmpDwordSiImm $ovl 'aztBootState' 2
        A-JnzS $ovl 'ABT_live'                  # (jnz +1 / ret, not jz ABT_out -- which is only a ret -- three bytes fewer)
        A-Ret $ovl                              # already finished, for good
        Add-Label $ovl 'ABT_live'

        # STATE 0: the opening movie, then nothing else this frame.
        #
        # It plays HERE rather than from the intro sequence for one reason: the intro movies
        # run before the first frame hook, so the overlay is not resident yet and none of
        # this code exists. On the first gameplay frame it is, and the room behind is hidden
        # by the movie and then by the visor boot, so the player never sees it.
        #
        # State 3, not straight to 1: ebx is `now` from BEFORE the movie, so using it as T0
        # would start the boot clock ten seconds in the past and the whole sequence would be
        # skipped by the hard cap. Handing off to the next frame gets a fresh clock for free
        # and gives the engine a frame to re-establish its own palette after the movie's.
        A-CmpDwordSiImm $ovl 'aztBootState' 0
        A-Jnz $ovl 'ABT_running'
        if ($ENABLE_TITLE_MENU -and $ENABLE_REBOOT_ON_LOAD) {
            # A LOAD FROM THE TITLE MENU (see $ENABLE_TITLE_MENU). The host has already written the game's own state as
            # the fold-out leaves it for OK: the selected row 0x146948 = the slot (it is -1 in every other first frame:
            # file data, nothing selects a row before play) and 0x1524CC = 0 (OK loads). So, in place of the new game's
            # boot: the command dispatcher with cmd 16 (in al, as the ESC key's patch sends cmd 5), as a TAIL jump -- its
            # own ret ends this frame's AztBootTick. The load goes through AztLoadHook, which starts the visor's re-boot.
            # (16 bytes: the overlay is at its 0xD000 ceiling -- see the AztSceneLog call and ABT's first exit.)
            Add-Bytes $ovl @(0xF6, 0x87); Add-Abs32 $ovl ([uint32]0x146949); Add-Bytes $ovl @(0x80)   # test byte [edi+0x146949],0x80
            A-JnzS $ovl 'ABT_fresh'                  # -1: no row, a new game
            Add-Bytes $ovl @(0xB0, 0x10)             # mov al,16: OK
            A-Jmp $ovl ([uint32]0x2C408)             # the command dispatcher (it keeps esi/edi), returning for us
            Add-Label $ovl 'ABT_fresh'
        }
        A-MovSiEbx32 $ovl 'aztBootT0'           # first frame: start the clock
        A-MovDwordSiImm $ovl 'aztBootState' 1
        A-Call $ovl 'AztBootClear'
        if ($ENABLE_CD_AUDIO) {
            # The boot effect, slot 11. The engine has no PCM path at all, so redbook audio
            # is the only way to play a recorded sound; this is the same MSCDEX route the
            # soundtrack uses. AztCdPoll is held off below until the sequence finishes, or
            # it would switch the drive to the room's music cue on the very next frame.
            # SAVE EBX. It carries `now` for the rest of this routine, and AztCdPlay
            # destroys it fetching the start LBA (`mov ebx,[eax]`). Without this the
            # elapsed time below computed LBA-minus-now, wrapped huge, tripped the hard
            # cap and ended the whole sequence on its first frame -- no animation, and
            # aztBootState went straight to 2, which released the music poll and cut the
            # effect off. One clobbered register, both symptoms.
            A-MovDwordSiImm $ovl 'aztBootFxDone' 0   # re-arm: the request is below, on a timer
        }

        Add-Label $ovl 'ABT_running'
        A-MovEaxEbx $ovl
        A-SubEaxSi  $ovl 'aztBootT0'            # eax = elapsed us
        A-MovSiEax32 $ovl 'aztBootEl'           # kept: the key test below clobbers eax

        # ---- the boot effect starts $BOOT_FX_DELAY_US INTO the sequence ----------
        # Not on the first frame. The effect is 14.0 s against a 16.9 s animation, so starting
        # it with the first frame leaves the sequence running on in silence; holding it back a
        # second moves that gap to where it reads as a settle rather than a stop.
        #
        # This is only tunable at all because the LBA table was fixed -- before that the drive
        # spent 5.57 s in the tail of PEACEFUL first, which is the "latency" the whole boot
        # timeline was built around. See [[azrael-music]].
        #
        # SAVE EAX AND EBX. eax is the elapsed time the cap tests below depend on, ebx is `now`
        # for the rest of the routine, and AztCdPlay destroys both -- it fetches the start LBA
        # with `mov ebx,[eax]`. Losing ebx once already made the elapsed time compute as
        # LBA-minus-now, wrap huge, trip the hard cap and end the whole sequence on its first
        # frame: no animation, and aztBootState straight to 2, which released the music poll
        # and cut the effect off. One clobbered register, both symptoms.
        if ($ENABLE_CD_AUDIO) {
            A-CmpDwordSiImm $ovl 'aztBootFxDone' 0
            A-JnzS $ovl 'ABT_fxdone'
            A-CmpEaxImm $ovl $BOOT_FX_DELAY_US
            A-Jb $ovl 'ABT_fxdone'
            A-MovDwordSiImm $ovl 'aztBootFxDone' 1
            A-PushEax $ovl
            A-PushEbx $ovl
            A-MovEaxImm $ovl 11
            A-Call $ovl 'AztCdPlay'
            A-PopEbx $ovl
            A-PopEax $ovl
            Add-Label $ovl 'ABT_fxdone'
        }

        A-CmpEaxImm $ovl $BOOT_CAP_US
        A-Jae $ovl 'ABT_finish'                 # hard cap, whatever the state
        A-CmpEaxImm $ovl $BOOT_HOLD_US
        A-Jae $ovl 'ABT_finish'                 # normal end

        # NO KEY SKIP. There was one, testing the BIOS keyboard buffer at 0x41A -- and it
        # was the bug that made the whole sequence vanish: a key pressed to dismiss the
        # intro movies is STILL PENDING in that buffer when the sequence starts, nothing
        # here drains it, so the very first frame saw "a key is waiting" and aborted.
        # The animation is short and plays once per new game, so it is simply not
        # skippable. The duration and the hard cap above are the only ways out, which
        # also means there is no input state that can suppress it.
        A-Call $ovl 'AztBootPaint'
        if ($ENABLE_CD_AUDIO) { A-Call $ovl 'AztBootMute' }   # keep the MIDI down, every frame
        A-MovDwordSiImm $ovl 'aztInjEnable' 1   # our pixels go into the viewport
        A-Ret $ovl

        Add-Label $ovl 'ABT_finish'
        A-MovDwordSiImm $ovl 'aztInjEnable' 0   # hand the viewport back to the 3D
        A-MovDwordSiImm $ovl 'aztInjSplit' 0
        # NO RELEVEL KICK HERE. It was tried at exactly this point and did nothing:
        # the gain is RESTORATIVE, not configurational, so firing it before anything
        # has degraded restores nothing. It now runs on room change instead.
        if ($ENABLE_CD_AUDIO) {
            # Let the music poll take the drive back. aztCdSlot = -1 makes it see a cue
            # change and switch; aztCdCur = 0 stops AztCdPlay treating that switch as a
            # no-op because the boot effect is still the track it last issued.
            #
            # NOT AFTER A RELOAD. There was no boot effect to take the drive back from, and
            # forcing a re-switch would restart the room's music from the top every time a
            # save is loaded -- an audible jolt in place of a track that was playing fine.
            if ($ENABLE_REBOOT_ON_LOAD) {
                A-CmpDwordSiImm $ovl 'aztReboot' 0
                A-JnzS $ovl 'ABT_nocd'
            }
            A-MovDwordSiImm $ovl 'aztCdSlot' 0xFFFFFFFFL
            A-MovDwordSiImm $ovl 'aztCdCur'  0
            if ($ENABLE_REBOOT_ON_LOAD) { Add-Label $ovl 'ABT_nocd' }
        }
        if ($ENABLE_REBOOT_ON_LOAD) { A-MovDwordSiImm $ovl 'aztReboot' 0 }
        # The visor is up: pay back the HUD whoosh the gate swallowed on the way in.
        A-Call $ovl 'AztWhooshPlay'
        A-MovDwordSiImm $ovl 'aztBootState' 2
        Add-Label $ovl 'ABT_out'
        A-Ret $ovl
    }

    # ebx = now. Notices a cue change and switches source; otherwise keeps the MIDI
    # down and restarts the CD track when its running time is up. The loop is timed
    # from our own clock rather than polled from MSCDEX, which keeps this to zero
    # real-mode calls on an ordinary frame.
    Add-Label $ovl 'AztCdPoll'
        # HANDS OFF WHILE THE VISOR IS BOOTING. The boot effect owns the drive for those
        # twelve seconds, and the CD plays one track at a time -- without this the poll
        # would spot the room's music cue on the very next frame and cut the effect off
        # almost as soon as it started. aztBootState reaches 2 only when the sequence ends.
        if ($ENABLE_BOOT_SEQ) {
            A-CmpDwordSiImm $ovl 'aztBootState' 2
            A-Jb $ovl 'ACPo_out'
        }
    if ($ENABLE_CD_AUDIO) {
        A-CmpDwordSiImm $ovl 'aztCdOk' 0
        A-Jz $ovl 'ACPo_out'
        # ---- F4: recorded soundtrack or Mindscape's original score -----------
        # The key handler only flips the flag; the transition happens here, where
        # the obj2 delta and the real-mode buffer are both available.
        A-MovzxEaxSi $ovl ([uint32]$asm.Labels['aztCdOn'])
        A-CmpEaxSi $ovl 'aztCdOnLast'
        A-JzS $ovl 'ACPo_nochange'
        A-MovSiEax32 $ovl 'aztCdOnLast'
        if ($CD_DIAG) {
            A-PushEax $ovl
            A-Db $ovl @(0x89,0xC2)                 # mov edx, eax  (the new mode)
            A-MovEaxImm $ovl 7                     # 7 = F4 pressed
            A-Call $ovl 'AztCdLog'
            A-PopEax $ovl
        }
        A-TestEaxEax $ovl
        A-JzS $ovl 'ACPo_toMidi'
        A-MovDwordSiImm $ovl 'aztCdSlot' 0xFFFFFFFFL   # force a re-switch
        A-JmpS $ovl 'ACPo_nochange'
        Add-Label $ovl 'ACPo_toMidi'
        A-Call $ovl 'AztCdStop'
        A-Call $ovl 'AztCdUnmute'
        A-MovDwordSiImm $ovl 'aztCdSlot' 0xFFFFFFFFL
        A-MovDwordSiImm $ovl 'aztCdMuted' 0
        Add-Label $ovl 'ACPo_nochange'
        A-CmpWordSiImm $ovl ([uint32]$asm.Labels['aztCdOn']) 0
        A-Jz $ovl 'ACPo_out'                       # original score: hands off
        # THE GAME ALREADY TRACKS THE CURRENT CUE, at 0x152AD0 -- the options slider
        # reads exactly this byte to work out which record to re-play. Reading it
        # is simpler and more reliable than the hook that used to record the play
        # call, and it catches a cue change however it was triggered.
        A-MovzxEaxByteDi $ovl 0x152AD0
        A-CmpEaxImm $ovl 11                        # 11 music slots
        A-JaeS $ovl 'ACPo_loop'                    # nonsense index: leave it alone
        A-CmpEaxSi $ovl 'aztCdSlot'
        A-JzS $ovl 'ACPo_loop'                     # same cue as last frame
        A-MovSiEax32 $ovl 'aztCdSlot'
        A-Call $ovl 'AztCdSwitch'
        A-Jmp $ovl 'ACPo_out'
        Add-Label $ovl 'ACPo_loop'
        A-CmpDwordSiImm $ovl 'aztCdCur' 0
        A-JnzS $ovl 'ACPo_cd'
        # Nothing on CD. If the sequencer is still held at 0 from a previous CD
        # room, keep retrying the restore until the new cue's sequence has loaded.
        A-CmpDwordSiImm $ovl 'aztCdMuted' 0
        A-JzS $ovl 'ACPo_out'
        A-MovEaxSi $ovl 'aztCdSlot'
        A-Call $ovl 'AztCdSwitch'
        A-JmpS $ovl 'ACPo_out'
        Add-Label $ovl 'ACPo_cd'
        # Did the slider just hand the MIDI its volume back? 0x146940 is the level
        # the slider derives and writes immediately before re-playing the cue.
        #
        # WATCH IT, DO NOT WRITE IT. Zeroing it did re-mute reliably, but 0x146940
        # is also the value the slider DISPLAYS and reads back, so stamping it to 0
        # every frame pinned the control at zero and took away all volume control.
        # Comparing against the last value seen detects a move just as well and
        # leaves the player's setting intact.
        A-MovzxEaxDi $ovl 0x146940
        A-CmpEaxSi $ovl 'aztCdLastVol'
        A-JzS $ovl 'ACPo_stillmute'
        A-MovSiEax32 $ovl 'aztCdLastVol'
        if ($CD_DIAG) {
            A-PushEax $ovl
            A-Db $ovl @(0x89,0xC2)                 # mov edx, eax  (the new level)
            A-MovEaxImm $ovl 6                     # 6 = slider moved, re-muting
            A-Call $ovl 'AztCdLog'
            A-PopEax $ovl
        }
        A-Call $ovl 'AztCdSetVol'                  # drive the CD track's own level
        A-Call $ovl 'AztCdMuteNow'                 # and put the MIDI back down
        Add-Label $ovl 'ACPo_stillmute'
        A-Db $ovl @(0x89,0xD8)                     # mov eax, ebx   (now)
        A-SubEaxSi $ovl 'aztCdStart'               # elapsed; wrap-safe, unlike now >= end
        A-CmpEaxSi $ovl 'aztCdDur'
        A-JbS $ovl 'ACPo_out'                      # still within the track
        if ($CD_DIAG) {
            A-MovEdxSi32 $ovl 'aztCdIdx'
            A-MovEaxImm $ovl 4                     # 4 = the loop timer fired
            A-Call $ovl 'AztCdLog'
        }
        A-MovDwordSiImm $ovl 'aztCdCur' 0          # let the idempotence guard pass
        A-MovEaxSi $ovl 'aztCdIdx'
        A-Call $ovl 'AztCdPlay'
        Add-Label $ovl 'ACPo_out'
    }
    A-Ret $ovl

    if ($ENABLE_CD_AUDIO) {
        Add-Label $ovl 'aztCdOk';    A-Dd $ovl 0
        Add-Label $ovl 'aztCdSeg';   A-Dd $ovl 0
        Add-Label $ovl 'aztCdLin';   A-Dd $ovl 0
        Add-Label $ovl 'aztCdDrive'; A-Dd $ovl 0
        Add-Label $ovl 'aztCdCur';   A-Dd $ovl 0
        Add-Label $ovl 'aztCdIdx';   A-Dd $ovl 0
        Add-Label $ovl 'aztCdStart'; A-Dd $ovl 0   # when the track was started
        Add-Label $ovl 'aztCdDur';   A-Dd $ovl 0   # ...and how long it runs for
    }
    # Visor boot state. 0 = not started, 1 = running, 2 = finished and terminal.
    # Declared outside the CD block because the boot sequence does not depend on it.
    if ($ENABLE_BOOT_SEQ) {
        Add-Label $ovl 'aztBootState';   A-Dd $ovl 0
        # 1 = the boot effect has been asked for this run. Reset on the sequence's first
        # frame, so a reload re-boot starts it on the same timer.
        Add-Label $ovl 'aztBootFxDone';  A-Dd $ovl 0
        # 1 = the gate swallowed hud3.wav and ABT_finish still owes it. See AztWhooshGate.
        Add-Label $ovl 'aztWhooshOwed';  A-Dd $ovl 0
        Add-Label $ovl 'aztBootT0';      A-Dd $ovl 0
        Add-Label $ovl 'aztBootEl';      A-Dd $ovl 0   # elapsed us, kept across the key test
        Add-Label $ovl 'aztBootH';       A-Dd $ovl 0   # half the open band, in rows
        Add-Label $ovl 'aztBootTop';     A-Dd $ovl 0   # byte offset of the band's first row
        Add-Label $ovl 'aztBootBandPtr'; A-Dd $ovl 0   # buffer + that offset
        Add-Label $ovl 'aztBootRows';    A-Dd $ovl 0   # rows of readout to blit this frame
        Add-Label $ovl 'aztBootWiped';   A-Dd $ovl 0   # 1 once the screen has been cleared for the mission line
        Add-Label $ovl 'aztBootDisDone'; A-Dd $ovl 0   # 1 once the disruption has had its final wipe
        Add-Label $ovl 'aztBootSeed';    A-Dd32 $ovl 0x13579BDF   # LCG state; any odd value will do
        Add-Label $ovl 'aztBootGlCnt';   A-Dd $ovl 0   # streaks left to draw this frame
        Add-Label $ovl 'aztBootEdCnt';   A-Dd $ovl 0   # ...edge dropout streaks left
        Add-Label $ovl 'aztBootBlkCnt';  A-Dd $ovl 0   # ...flickering margin blocks left

        # One row of five dwords per disruption stage: {streaks, edges, blocks, band, tear}.
        # A-Dd32, NOT A-Dd -- A-Dd ignores its argument and emits four zero bytes, which
        # here would be a silently artifact-free boot rather than an error.
        Add-Label $ovl 'aztBootDisTab'
        foreach ($st in $BOOT_DIS_STAGES) {
            A-Dd32 $ovl ([uint32]$st.Streaks)
            A-Dd32 $ovl ([uint32]$st.Edges)
            A-Dd32 $ovl ([uint32]$st.Blocks)
            A-Dd32 $ovl ([uint32]$st.Band)
            A-Dd32 $ovl ([uint32]$st.Tear)
        }
        # One row's worth of scratch for the tear's rotate. A rotate needs the bytes that
        # fall off one end kept somewhere; doing it with a small buffer instead would mean
        # a backward `std; rep movsb` for one of the two directions, and leaving the
        # direction flag set would corrupt every string op downstream.
        Add-Label $ovl 'aztReboot';      A-Dd $ovl 0   # 1 = this run is a reload, not a start
        Add-Label $ovl 'aztBootGhost';   A-Dd $ovl 0   # phosphor ghost depth, in rows
        Add-Label $ovl 'aztGlyphLeft';   A-Dd $ovl 0   # cells left to mangle this frame
        Add-Label $ovl 'aztTearOff';     A-Dd $ovl 0   # byte offset of the band's first row
        Add-Label $ovl 'aztTearW';       A-Dd $ovl 0   # band width; a multiple of 4
        Add-Label $ovl 'aztTearRows';    A-Dd $ovl 0
        Add-Label $ovl 'aztTearShift';   A-Dd $ovl 0   # LEFT rotate, in pixels, 1..W-1
        Add-Label $ovl 'aztTearScratch'
        for ($o = 0; $o -lt $INJ_W; $o += 64) { A-Db $ovl (New-Object byte[] 64) }
        Add-Label $ovl 'aztBootCols';    A-Dd $ovl 0   # revealed bytes per row, this frame
        Add-Label $ovl 'aztBootLineN';   A-Dd $ovl 0   # lines on screen, for the flare
        Add-Label $ovl 'aztFlareAge';    A-Dd $ovl 0   # how long the newest line has been up
        Add-Label $ovl 'aztFlareRows';   A-Dd $ovl 0   # rows to brighten; 0 = none
        Add-Label $ovl 'aztFlareOff';    A-Dd $ovl 0   # ...at this byte offset in the buffer
        Add-Label $ovl 'aztCaretH';      A-Dd $ovl 0   # caret height in rows; 0 = no caret
        Add-Label $ovl 'aztCaretY';      A-Dd $ovl 0   # ...this many rows into the element
        Add-Label $ovl 'aztTypSrc';      A-Dd $ovl 0   # which bitmap is being typed
        Add-Label $ovl 'aztTypScr';      A-Dd $ovl 0   # ...and its scratch copy
        Add-Label $ovl 'aztTypRows';     A-Dd $ovl 0
        Add-Label $ovl 'aztTypDest';     A-Dd $ovl 0   # byte offset into the staging buffer
        Add-Label $ovl 'aztInjSplit';    A-Dd $ovl 0   # 1 = copy only the two panels
        Add-Label $ovl 'aztInjRoll';     A-Dd $ovl 0   # vertical hold slip, in bytes; 0 = none
        Add-Label $ovl 'aztSlipRoll';    A-Dd $ovl 0   # the roll being held across frames
        Add-Label $ovl 'aztSlipLeft';    A-Dd $ovl 0   # frames left to hold it
        # A-Dd32, NOT A-Dd: these carry a REAL initial value. A-Dd ignores its argument and
        # emits zeroes, which here would paint the first cleared frame black instead of amber.
        Add-Label $ovl 'aztFillDw';      A-Dd32 $ovl ([uint32]($BOOT_FILL_IX * 0x01010101))
        Add-Label $ovl 'aztScanDw';      A-Dd32 $ovl ([uint32]($BOOT_SCAN_IX * 0x01010101))
        # -1 so the FIRST frame always counts as a stage change and rebuilds the tables.
        # Initialised to 0 it would match stage 0 and silently skip the only rebuild that
        # matters -- the one that dims the text background at the very start.
        Add-Label $ovl 'aztWarmStage';   A-Dd32 $ovl 0xFFFFFFFFL
        # Two dwords per warm-up stage: the packed fill colour, then the packed scan colour.
        Add-Label $ovl 'aztBootWarmTab'
        foreach ($st in $BOOT_WARM_STAGES) {
            A-Dd32 $ovl ([uint32]($st.Fill * 0x01010101))
            A-Dd32 $ovl ([uint32]($st.Scan * 0x01010101))
        }
        # One dword per decay step: the ink index to repaint the expansion tables with. A
        # dword each rather than packed bytes because AztBootInk takes the index in eax and
        # does its own replication -- the bar wants the packed form, the dump wants the index.
        Add-Label $ovl 'aztBootDecayTab'
        foreach ($c in $BOOT_DECAY_RAMP) { A-Dd32 $ovl ([uint32]$c) }
        Add-Label $ovl 'aztInjTopDw';    A-Dd $ovl 0   # dwords in the upper panel
        Add-Label $ovl 'aztInjBotOff';   A-Dd $ovl 0   # byte offset of the lower panel

        # 256 entries of 8 bytes: one source bit pattern -> the eight pixels it paints.
        # This is what makes the blit trivial -- no shifting, no masking, and because the
        # text sits on the flat fill colour the copy can be opaque.
        Add-Label $ovl 'aztBootTab'
        $tab = New-Object byte[] 2048
        for ($tb = 0; $tb -lt 256; $tb++) {
            for ($bit = 0; $bit -lt 8; $bit++) {
                $tab[$tb*8 + $bit] = if ($tb -band (0x80 -shr $bit)) { [byte]$BOOT_INK_IX } else { [byte]$BOOT_FILL_IX }
            }
        }
        for ($o = 0; $o -lt $tab.Length; $o += 256) { A-Db $ovl ($tab[$o..([Math]::Min($o+255, $tab.Length-1))]) }

        # The same table for ODD rows, where the background is the scanline colour instead
        # of the fill. The blit picks between the two by row parity, so the readout's
        # background stays in step with the scanlines drawn behind it.
        Add-Label $ovl 'aztBootTab2'
        $tab2 = New-Object byte[] 2048
        for ($tb = 0; $tb -lt 256; $tb++) {
            for ($bit = 0; $bit -lt 8; $bit++) {
                $tab2[$tb*8 + $bit] = if ($tb -band (0x80 -shr $bit)) { [byte]$BOOT_INK_IX } else { [byte]$BOOT_SCAN_IX }
            }
        }
        for ($o = 0; $o -lt $tab2.Length; $o += 256) { A-Db $ovl ($tab2[$o..([Math]::Min($o+255, $tab2.Length-1))]) }

        Add-Label $ovl 'aztBootBits'
        $bits = Render-BootText
        for ($o = 0; $o -lt $bits.Length; $o += 256) { A-Db $ovl ($bits[$o..([Math]::Min($o+255, $bits.Length-1))]) }

        Add-Label $ovl 'aztBootFinScratch'
        for ($o = 0; $o -lt ($BOOT_TXT_PITCH * $BOOT_FINAL_H); $o += 64) { A-Db $ovl (New-Object byte[] ([Math]::Min(64, ($BOOT_TXT_PITCH * $BOOT_FINAL_H) - $o))) }

        Add-Label $ovl 'aztBootFinBits'
        $fbits = Render-BootFinal
        for ($o = 0; $o -lt $fbits.Length; $o += 256) { A-Db $ovl ($fbits[$o..([Math]::Min($o+255, $fbits.Length-1))]) }

        Add-Label $ovl 'aztBootMisScratch'   # the partially-typed copy, rebuilt each frame
        for ($o = 0; $o -lt ($BOOT_TXT_PITCH * $BOOT_MIS_H); $o += 64) { A-Db $ovl (New-Object byte[] ([Math]::Min(64, ($BOOT_TXT_PITCH * $BOOT_MIS_H) - $o))) }

        Add-Label $ovl 'aztBootMisBits'
        $mbits = Render-BootMission
        for ($o = 0; $o -lt $mbits.Length; $o += 256) { A-Db $ovl ($mbits[$o..([Math]::Min($o+255, $mbits.Length-1))]) }

        # ---- the ink colour, as a variable ----------------------------------
        # The expansion tables above bake the ink in, so dimming the readout means repainting
        # them (AztBootInk). These three mirror what the tables currently hold, so the things
        # that DON'T go through a table -- the progress bar's frame and fill, and the
        # telemetry column's post-pass -- fade in step with the text instead of staying lit.
        Add-Label $ovl 'aztInkIx';   A-Dd32 $ovl ([uint32]$BOOT_INK_IX)
        Add-Label $ovl 'aztInkDw';   A-Dd32 $ovl ([uint32]($BOOT_INK_IX * 0x01010101))
        Add-Label $ovl 'aztDumpIx';  A-Dd32 $ovl ([uint32]$BOOT_DUMP_IX)

        # Byte offset of the refresh line drawn last frame, so it can be erased before
        # anything else draws. -1 = nothing on screen.
        Add-Label $ovl 'aztSweepOff'; A-Dd32 $ovl 0xFFFFFFFFL

        # One nibble per cell of the telemetry column, as whole bytes: the blit indexes the
        # transposed strip with it directly, and packing two per byte would cost a shift and
        # a mask in the inner loop to save 40 bytes.
        Add-Label $ovl 'aztDumpInit'; A-Dd $ovl 0
        Add-Label $ovl 'aztDumpCells'
        for ($o = 0; $o -lt $BOOT_DUMP_CELLS; $o += 64) {
            A-Db $ovl (New-Object byte[] ([Math]::Min(64, $BOOT_DUMP_CELLS - $o)))
        }
        Add-Label $ovl 'aztDumpHex'
        $hbits = Render-BootHex
        for ($o = 0; $o -lt $hbits.Length; $o += 256) { A-Db $ovl ($hbits[$o..([Math]::Min($o+255, $hbits.Length-1))]) }
    }
    if ($ENABLE_CD_AUDIO) {
        # Written by AztMusicRec in the art blob (file-backed, runs even before the
        # overlay is resident) with the record pointer the game last asked to play.
        Add-Label $ovl 'aztMusicPtr'; A-Dd $ovl 0
        Add-Label $ovl 'aztCdVol';    A-Dd $ovl 0    # (unused now the volume is an argument)
        # 1 while the sequencer is being held at volume 0 for a CD room. Cleared
        # only once a restore call has actually landed on a loaded sequence.
        Add-Label $ovl 'aztCdMuted';  A-Dd $ovl 0
        # Last value seen at 0x146940, so a slider move is detected by comparison
        # rather than by writing the control back to zero. -1 forces the CD level to
        # be set from the slider on the first poll.
        Add-Label $ovl 'aztCdLastVol'; A-Dd32 $ovl 0xFFFFFFFFL
        # Mirrors aztCdOn (F4, in the stub blob) so a press is seen as a change.
        # Starts at 1 to match its default, or the first poll would see a phantom
        # transition before the player has touched anything.
        Add-Label $ovl 'aztCdOnLast';  A-Dd32 $ovl 1
        if ($CD_DIAG) {
            Add-Label $ovl 'aztCdLogH';   A-Dw $ovl 0
            Add-Label $ovl 'aztLogRec';   A-Dd $ovl 0
            Add-Label $ovl 'aztLogRec2';  A-Dd $ovl 0
            Add-Label $ovl 'aztCdLogName'; A-Asciiz $ovl 'AZTCD.LOG'
        }
        # The cue seen last frame. Starts at -1, not 0, or slot 0 (awemyst) would
        # look like it was already playing and never switch.
        # (0xFFFFFFFF without the L is Int32 -1 to PowerShell and fails the uint32
        # cast -- the same trap as the LFB base address.)
        Add-Label $ovl 'aztCdSlot';   A-Dd32 $ovl 0xFFFFFFFFL
        # The DPMI real-mode call structure, 50 bytes, field order fixed by spec.
        Add-Label $ovl 'aztRmcs'
        A-Dd $ovl 0                                 # +00 EDI
        A-Dd $ovl 0                                 # +04 ESI
        A-Dd $ovl 0                                 # +08 EBP
        A-Dd $ovl 0                                 # +0C reserved
        Add-Label $ovl 'aztRmEbx';   A-Dd $ovl 0    # +10
        A-Dd $ovl 0                                 # +14 EDX
        Add-Label $ovl 'aztRmEcx';   A-Dd $ovl 0    # +18
        Add-Label $ovl 'aztRmEax';   A-Dd $ovl 0    # +1C
        Add-Label $ovl 'aztRmFlags'; A-Dw $ovl 0    # +20
        Add-Label $ovl 'aztRmEs';    A-Dw $ovl 0    # +22
        A-Dw $ovl 0                                 # +24 DS
        A-Dw $ovl 0                                 # +26 FS
        A-Dw $ovl 0                                 # +28 GS
        A-Dw $ovl 0                                 # +2A IP
        A-Dw $ovl 0                                 # +2C CS
        Add-Label $ovl 'aztRmSp';    A-Dw $ovl 0    # +2E
        A-Dw $ovl 0                                 # +30 SS
        # Eleven slots of {startLBA, sectors, durationUs}; 0 = keep the MIDI cue.
        Add-Label $ovl 'aztCdTab'
        # Slot 11 is NOT a music cue: it is the visor boot effect, played once by the boot
        # sequence. The table is OURS -- the game's own music table at 0x152A34 still has
        # exactly 11 entries and is not extended, so no engine structure is touched.
        for ($slot = 0; $slot -lt 12; $slot++) {
            $t = $CD_TRACKS[$slot]
            if ($t) { A-Dd32 $ovl $t.lba; A-Dd32 $ovl $t.sectors; A-Dd32 $ovl $t.us }
            else    { A-Dd $ovl 0; A-Dd $ovl 0; A-Dd $ovl 0 }
        }
    }

    # ---- AztRaptorTrap: who hands Reality Lab a dead object? -----------------
    # Replaces the first eight bytes of 0x10204, RL's registered error callback
    # (`movsx eax, al` + `call 0x32FF4`, the code -> message lookup), and both are
    # re-issued at the bottom so the message still prints exactly as it did.
    #
    # A JMP, NOT A CALL. Eight bytes cannot hold a call AND a jump back, and a jmp
    # is better here anyway: it pushes nothing, so [esp] on entry is already the
    # return address of whoever inside RL raised the error. That address is the
    # whole point of this routine. The site's own `ret` at 0x1021F then finds the
    # stack exactly as it left it.
    #
    # ONLY THE FIRST ERROR IS KEPT. Once RL is confused it tends to report
    # repeatedly, and the later ones are consequences of the first.
    if ($ENABLE_RAPTOR_TRAP -and $ENABLE_HOST_RENDER) {
        Add-Label $ovl 'AztRaptorTrap'
        A-Pushfd $ovl
        A-Pushad $ovl                                 # eax..edi, 32 bytes; eax at [esp+28]
        A-Call   $ovl $asm.Labels['AztDeltas']        # esi = obj1 delta (eats eax/esi/edi)

        A-IncDwordSi $ovl 'aztRaptorSeen'             # every report, captured or not
        A-CmpDwordSiImm $ovl 'aztRaptorHit' 0
        A-Jnz $ovl 'ART_wait'                         # already hold the first one

        A-MovEaxEspDisp $ovl 28                       # pushad's eax: the RL code in al
        A-MovSiEax32 $ovl 'aztRaptorCode'
        # Where the stack IS, so the host can read all of it -- the failing handle, the
        # list it came from -- instead of only the 20 return addresses sifted below.
        A-Db $ovl @(0x89,0xE0)                        # mov eax, esp (entry esp - 36)
        A-MovSiEax32 $ovl 'aztRaptorEsp'

        # FILTERED, not copied wholesale. A straight 64-dword `rep movsd` of the
        # stack needed 256 bytes of a BSS window that turned out to have 333 left,
        # and most of what it captured was locals and spilled floats. Keeping only
        # the dwords that COULD be return addresses scans three times deeper into
        # 80 bytes, and every slot that comes back is worth symbolising.
        #
        # The test is "inside obj1", which is exactly 0x10000..OBJ1_BASE+OBJ1_VSIZE -- obj1
        # starts at 0x10000 and the BSS window that ends it runs to 0x173000 now (it was
        # 0x140000, obj2's linked base, until obj1 grew). Any return address is in obj1 by definition, and the
        # heap (0xA86038, 0x1138038) and obj2's data are both above it. Overlay
        # addresses at 0x133000 are inside the range deliberately: a frame that
        # came back through our own code is worth seeing, not worth hiding.
        #
        # `sub eax, esi` FIRST, AND THE FIRST VERSION DID NOT. The stack holds
        # RUNTIME addresses and the range above is BUILT addresses -- which is the
        # entire reason AztDeltas exists, obj1 not being loaded where it was
        # built. The delta is 0x1F0000 in practice (the same 0x1F0000 the host adds
        # to read these very symbols), so every genuine return address sat around
        # 0x200000..0x330000 and failed the test: the trap fired correctly on a
        # live crash and reported "nothing that looked like a return address".
        # Converting here rather than in the host also means the captured values
        # are directly comparable to R.EXE linear addresses, which is what the
        # disassembler wants. A heap pointer or small integer minus the delta
        # lands outside the range anyway, so the filter is no weaker for it.
        A-LeaEdiSi $ovl 'aztRaptorStack'
        A-Db $ovl @(0x89,0xE3)                        # mov ebx, esp
        A-Db $ovl @(0x83,0xC3,0x24)                   # add ebx, 36 -- past pushfd+pushad
        A-MovEcxImm $ovl 192                          # dwords of stack to sift
        A-MovEdxImm $ovl 20                           # slots to fill
        A-PushDsPopEs $ovl
        # CLD. stosd below walks edi FORWARD, and the direction flag belongs to
        # whoever we interrupted -- this is the same trap that already cost a
        # first-frame freeze in the inject probe wrapper.
        A-Db $ovl @(0xFC)                             # cld
        Add-Label $ovl 'ART_scan'
        A-Db $ovl @(0x8B,0x03)                        # mov eax, [ebx]
        A-Db $ovl @(0x83,0xC3,0x04)                   # add ebx, 4
        A-Db $ovl @(0x29,0xF0)                        # sub eax, esi -- runtime -> built
        A-CmpEaxImm $ovl 0x10000
        A-Jb  $ovl 'ART_next'                         # below obj1
        A-CmpEaxImm $ovl ([uint32]($OBJ1_BASE + $OBJ1_VSIZE))
        A-Jae $ovl 'ART_next'                         # past obj1's end
        A-Db $ovl @(0xAB)                             # stosd
        A-DecEdx $ovl
        A-Jz $ovl 'ART_sifted'                        # slots full
        Add-Label $ovl 'ART_next'
        A-DecEcx $ovl
        A-Jnz $ovl 'ART_scan'
        Add-Label $ovl 'ART_sifted'

        A-MovDwordSiImm $ovl 'aztRaptorHit' 1         # the host's cue to dump it

        # Hold the game here so a 10 Hz watcher cannot miss the capture before the
        # process dies. BOUNDED, at ~91 BIOS ticks (5 s), and only while a host
        # renderer is actually attached -- nothing should ever stall waiting for a
        # reader that was never started. A tick delta across the midnight wrap
        # reads as a huge unsigned number and simply ends the wait early, which is
        # the harmless direction.
        Add-Label $ovl 'ART_wait'
        A-CmpDwordSiImm $ovl 'aztHostInject' 0
        A-Jz $ovl 'ART_go'
        A-MovEaxImm $ovl 0x46C
        A-MovEaxEaxPtr $ovl
        A-MovSiEax32 $ovl 'aztRaptorT0'
        Add-Label $ovl 'ART_spin'
        A-CmpDwordSiImm $ovl 'aztRaptorHit' 0
        A-Jz $ovl 'ART_go'                            # the host read it: carry on
        A-MovEaxImm $ovl 0x46C
        A-MovEaxEaxPtr $ovl
        A-SubEaxSi $ovl 'aztRaptorT0'
        A-CmpEaxImm $ovl 91
        A-Jb $ovl 'ART_spin'

        Add-Label $ovl 'ART_go'
        A-Popad $ovl
        A-Popfd $ovl
        A-Db $ovl @(0x0F,0xBE,0xC0)                   # movsx eax, al   -- displaced
        A-Call $ovl ([uint32]0x32FF4)                 # displaced: eax = message text
        A-Jmp $ovl ([uint32]0x1020C)                  # ...into `push eax`, unchanged

        Add-Label $ovl 'aztRaptorHit';   A-Dd $ovl 0  # 1 = a capture is waiting
        Add-Label $ovl 'aztRaptorSeen';  A-Dd $ovl 0  # total reports this session
        Add-Label $ovl 'aztRaptorCode';  A-Dd $ovl 0  # RL error code (1 = object expected)
        Add-Label $ovl 'aztRaptorT0';    A-Dd $ovl 0  # tick the bounded wait started on
        Add-Label $ovl 'aztRaptorEsp';   A-Dd $ovl 0  # RUNTIME esp inside the trap
        # 20 slots, zero-filled: a short chain simply leaves trailing zeros, so the
        # host needs no count and a partial capture still reads correctly.
        Add-Label $ovl 'aztRaptorStack'; A-Db $ovl (New-Object byte[] 80)
    }

    # ---- the cursor pick must survive a handle that no longer resolves -------
    # WHAT THE RAPTOR TRAP CAUGHT (2026-10-04, all 9 captured frames genuine):
    #   0x14895 call 0x116E4   the per-frame cursor pick
    #   0x11830 call 0x3A420   "what does the picked handle belong to"
    #   0x3A42E call 0x33048   resolve handle -> 0x39E50 returns null -> RL error 1
    # 0x116E4 asks RL what is under the cursor (0x3BBC4) and passes the handle it
    # gets back straight to 0x3A420 with no check. With the host owning the 3D that
    # handle is sometimes one RL no longer knows, and RL's answer to that is fatal.
    # So resolve it first with the same lookup 0x33048 uses; a dead handle takes
    # the routine's own "nothing under the cursor" exit at 0x11D3A, which is where
    # `cmp al, 5 / jz` three instructions earlier already goes with this same esp.
    if ($ENABLE_HOST_RENDER) {
        Add-Label $ovl 'AztPickGuard'
        A-Db   $ovl @(0x50)                           # push eax -- the picked handle
        A-Call $ovl ([uint32]0x39E50)                 # eax = its record, or 0
        A-Db   $ovl @(0x85,0xC0)                      # test eax, eax
        A-Db   $ovl @(0x58)                           # pop eax (flags untouched)
        A-Jz   $ovl 'APG_dead'
        A-Jmp  $ovl ([uint32]0x3A420)                 # live: the displaced call, as a tail call
        Add-Label $ovl 'APG_dead'
        A-Db   $ovl @(0x83,0xC4,0x04)                 # add esp, 4 -- drop our return address
        A-Jmp  $ovl ([uint32]0x11D3A)                 # nothing picked
    }

    # ---- AztFovTick: the host's field of view (see $ENABLE_HOST_FOV) ----------------------
    # esi/edi = the deltas (from AztFrameAll). Everything saved: pushad/popad. LAST in the overlay, so adding it moved
    # no other routine or data word.
    if ($ENABLE_HOST_FOV) {
        Add-Label $ovl 'AztFovTick'
        A-Pushad $ovl
        A-MovEaxSi $ovl 'aztFovTan'
        A-TestEaxEax $ovl
        A-Jle $ovl 'AFV_out'                     # 0 = the game's own field; never a field <= 0 (Reality Lab's error path)
        A-MovEaxDi $ovl 0x152138                 # the viewport's handle
        A-TestEaxEax $ovl
        A-Jz $ovl 'AFV_out'                      # none yet (the intro, the boot)
        A-Call $ovl ([uint32]0x39E50)            # handle -> object; a pure lookup, 0 if not found
        A-TestEaxEax $ovl
        A-Jz $ovl 'AFV_out'
        A-MovEbxEax $ovl                         # ebx = the viewport
        A-Db $ovl ([byte[]]@(0x8B, 0x4B, 0x2C))                       # mov ecx,[ebx+0x2C]   its device
        A-Db $ovl ([byte[]]@(0x85, 0xC9))                             # test ecx,ecx
        A-Jz $ovl 'AFV_out'
        A-Db $ovl ([byte[]]@(0x8B, 0x43, 0x3C))                       # mov eax,[ebx+0x3C]   width
        A-Db $ovl ([byte[]]@(0x0F, 0xAF, 0x81, 0x60, 0x01, 0x00, 0x00)) # imul eax,[ecx+0x160]  x the device's x scale
        A-Db $ovl ([byte[]]@(0x8B, 0x53, 0x40))                       # mov edx,[ebx+0x40]   height
        A-Db $ovl ([byte[]]@(0x0F, 0xAF, 0x91, 0x64, 0x01, 0x00, 0x00)) # imul edx,[ecx+0x164]  x its y scale
        A-Db $ovl ([byte[]]@(0x39, 0xD0))                             # cmp eax,edx
        A-JbeS $ovl 'AFV_square'                 # not wider than tall: the field is the vertical half-extent itself
        A-Db $ovl ([byte[]]@(0x50, 0x52))                             # push eax; push edx
        A-Db $ovl ([byte[]]@(0xDB, 0x44, 0x24, 0x04))                 # fild dword [esp+4]   w
        A-Db $ovl ([byte[]]@(0xDA, 0x34, 0x24))                       # fidiv dword [esp]    / h
        A-Db $ovl ([byte[]]@(0x83, 0xC4, 0x08))                       # add esp,8
        A-FmulSi $ovl 'aztFovTan'                # field = tan(v/2) x aspect
        A-JmpS $ovl 'AFV_have'
        Add-Label $ovl 'AFV_square'
        A-FldSi $ovl 'aztFovTan'
        Add-Label $ovl 'AFV_have'
        A-FstpSi $ovl 'aztFovWant'
        A-MovEcxSi32 $ovl 'aztFovWant'
        A-Db $ovl ([byte[]]@(0x3B, 0x8B, 0xFC, 0x00, 0x00, 0x00))     # cmp ecx,[ebx+0xFC]   the viewport's own +field
        A-Jz $ovl 'AFV_out'                      # already so
        A-Db $ovl ([byte[]]@(0xFF, 0xB6)); Add-Abs32 $ovl 'aztFovWant' # push dword [esi+aztFovWant]
        A-MovEaxDi $ovl 0x152138
        A-Call $ovl ([uint32]0x3A8A0)            # SetField(viewport, field) -- ret 4: it pops its argument
        A-IncDwordSi $ovl 'aztFovSets'
        Add-Label $ovl 'AFV_out'
        A-Popad $ovl
        A-Ret $ovl
        Add-Label $ovl 'aztFovTan';  A-Dd $ovl 0          # the HOST writes it: tan(vertical FOV / 2) as a float; 0 = off
        Add-Label $ovl 'aztFovWant'; A-Dd $ovl 0          # this frame's field (the host may read it back)
        Add-Label $ovl 'aztFovSets'; A-Dd $ovl 0          # how many times it was applied (each new viewport, each change)
    }

    # ---- NPC PACE (Josh, 2026-10-13: "slow down the animation of all npcs by a small amount, say 10% ... the 2 creatures
    # in the cori cori room are especially fast, so I need them only to be slowed a total of 20%. Additionally, I'd like
    # them to pause every once in a while, rather than constantly running around ... an easier chance to scan them") -------
    # A CHARACTER MOVES ON TWO CLOCKS (docs\notes\azrael-npc-pace.md): its TRAVEL, scripts and AI on the actor stepper
    # 0x261C0 (AztActorTime, 18.2 Hz), its STRIDE on the move callback's frame +1 (AztAnimStep, on aztAnimDue -- which
    # the doors, room animations and the player's walk bob share, so it is not slowed itself). Both pass through
    # aztNpcPct here (an accumulator: 90 = 9 steps in 10), so pose and travel slow together and nothing else does.
    # PER CHARACTER, aztNpcTab: up to 4 entries the HOST writes from a room's "npcs" block -- {dd character, db pct,
    # db stride acc, db AI acc, db hold, db pause state, 3 spare} (12 bytes): pct scales that character's stride (AztNpcStride) and its AI step
    # (AztNpcAi at 0x2662E: dh = 0 = no AI this step, so RandomMovement / the mover 0x258A8 wait with it); hold makes
    # a calm wanderer stand (AztNpcHold at 0x2694E: RUN -> REST via 0x23DC8, and the game's own WANDER restart from
    # REST is held off until the host lets go). Scripts, combat, conversations and the dead are never held.
    if ($ENABLE_NPC_PACE) {
        # entered from AztActorTime (the clock blob) by `lea ecx,[esi+AztOvlActor] / call ecx`, eax = 0x261C0's argument,
        # esi = the obj1 delta
        Add-Label $ovl 'AztActorGate'
        A-PushEdx $ovl
        A-MovzxEdxSi $ovl 'aztNpcAcc'
        A-Db $ovl @(0x66, 0x03, 0x96); Add-Abs32 $ovl 'aztNpcPct'                  # add dx,[esi+aztNpcPct]
        A-Db $ovl @(0x66, 0x83, 0xFA, 0x64)                                          # cmp dx,100
        A-JbS $ovl 'AAG_hold'
        A-Db $ovl @(0x66, 0x83, 0xEA, 0x64)                                          # sub dx,100
        A-MovSiDx $ovl 'aztNpcAcc'
        A-PopEdx $ovl
        A-Jmp $ovl $ACTOR_STEP                                                       # the step (its ret returns to the blob)
        Add-Label $ovl 'AAG_hold'
        A-MovSiDx $ovl 'aztNpcAcc'
        A-PopEdx $ovl
        A-Ret $ovl

        # the stride: ZF = 1 to HOLD this character's frame (after the global gate passed). ebx = the character.
        # Every register preserved (pop does not touch the flags; `test esp,esp` clears ZF).
        Add-Label $ovl 'AztNpcStride'
        A-PushEax $ovl; A-PushEcx $ovl; A-PushEdx $ovl
        A-CallNext $ovl
        Add-Label $ovl 'ANS_ref'
        A-PopEax $ovl
        A-SubEaxImm $ovl 'ANS_ref'                                                   # eax = obj1 delta
        A-Db $ovl @(0x66, 0x83, 0xB8); Add-Abs32 $ovl 'aztCharDue'; A-Db $ovl @(0x00) # cmp word [eax+aztCharDue],0
        A-JzS $ovl 'ANS_done'                                                        # not a character frame: hold (ZF=1)
        A-Db $ovl @(0x8D, 0x88); Add-Abs32 $ovl 'aztNpcTab'                          # lea ecx,[eax+aztNpcTab]
        A-Db $ovl @(0xBA, 0x04, 0x00, 0x00, 0x00)                                    # mov edx,4
        Add-Label $ovl 'ANS_loop'
        A-Db $ovl @(0x39, 0x19)                                                      # cmp [ecx],ebx
        A-JzS $ovl 'ANS_found'
        A-Db $ovl @(0x83, 0xC1, 0x0C)                                                # add ecx,12
        A-Db $ovl @(0x4A)                                                            # dec edx
        A-JnzS $ovl 'ANS_loop'
        A-Db $ovl @(0x85, 0xE4)                                                      # test esp,esp -> ZF=0: step
        A-JmpS $ovl 'ANS_done'
        Add-Label $ovl 'ANS_found'
        A-Db $ovl @(0x8A, 0x51, 0x05)                                                # mov dl,[ecx+5]   the stride acc
        A-Db $ovl @(0x02, 0x51, 0x04)                                                # add dl,[ecx+4]   + its pct
        A-Db $ovl @(0x80, 0xFA, 0x64)                                                # cmp dl,100
        A-JbS $ovl 'ANS_hold'
        A-Db $ovl @(0x80, 0xEA, 0x64)                                                # sub dl,100
        A-Db $ovl @(0x88, 0x51, 0x05)                                                # mov [ecx+5],dl
        A-Db $ovl @(0x85, 0xE4)                                                      # test esp,esp -> ZF=0: step
        A-JmpS $ovl 'ANS_done'
        Add-Label $ovl 'ANS_hold'
        A-Db $ovl @(0x88, 0x51, 0x05)                                                # mov [ecx+5],dl
        A-Db $ovl @(0x31, 0xD2)                                                      # xor edx,edx -> ZF=1: hold
        Add-Label $ovl 'ANS_done'
        A-PopEdx $ovl; A-PopEcx $ovl; A-PopEax $ovl
        A-Ret $ovl

        # 0x2662E `mov dh,[eax+0x260]` (6 bytes) -> `call AztNpcAi / nop`: dh = the state, or 0 (no AI this step) for a
        # character in the table whose AI step is not due. eax = the character; only dh changes.
        Add-Label $ovl 'AztNpcAi'
        A-Db $ovl @(0x8A, 0xB0, 0x60, 0x02, 0x00, 0x00)                              # mov dh,[eax+0x260]  (displaced)
        A-PushEbx $ovl; A-PushEcx $ovl; A-PushEsi $ovl
        A-CallNext $ovl
        Add-Label $ovl 'ANA_ref'
        A-PopEsi $ovl
        A-Db $ovl @(0x81, 0xEE); Add-Abs32 $ovl 'ANA_ref'                            # sub esi,ANA_ref -> obj1 delta
        A-Db $ovl @(0x8D, 0x9E); Add-Abs32 $ovl 'aztNpcTab'                          # lea ebx,[esi+aztNpcTab]
        A-Db $ovl @(0xB9, 0x04, 0x00, 0x00, 0x00)                                    # mov ecx,4
        Add-Label $ovl 'ANA_loop'
        A-Db $ovl @(0x39, 0x03)                                                      # cmp [ebx],eax
        A-JzS $ovl 'ANA_found'
        A-Db $ovl @(0x83, 0xC3, 0x0C)                                                # add ebx,12
        A-Db $ovl @(0x49)                                                            # dec ecx
        A-JnzS $ovl 'ANA_loop'
        A-JmpS $ovl 'ANA_out'
        Add-Label $ovl 'ANA_found'
        A-Db $ovl @(0x8A, 0x4B, 0x06)                                                # mov cl,[ebx+6]   the AI acc
        A-Db $ovl @(0x02, 0x4B, 0x04)                                                # add cl,[ebx+4]   + its pct
        A-Db $ovl @(0x80, 0xF9, 0x64)                                                # cmp cl,100
        A-JbS $ovl 'ANA_skip'
        A-Db $ovl @(0x80, 0xE9, 0x64)                                                # sub cl,100
        A-Db $ovl @(0x88, 0x4B, 0x06)                                                # mov [ebx+6],cl
        A-JmpS $ovl 'ANA_out'
        Add-Label $ovl 'ANA_skip'
        A-Db $ovl @(0x88, 0x4B, 0x06)                                                # mov [ebx+6],cl
        A-Db $ovl @(0x30, 0xF6)                                                      # xor dh,dh: no AI this step
        Add-Label $ovl 'ANA_out'
        A-PopEsi $ovl; A-PopEcx $ovl; A-PopEbx $ovl
        A-Ret $ovl

        # 0x2694E..0x26966 (the WANDER restart: `test di,di / jz / cmp byte [eax+0x260],1 / jnz / mov edx,5 /
        # call 0x23DC8`) -> `call AztNpcHold / jmp 0x26966`. eax = the character, di = its WANDER word.
        Add-Label $ovl 'AztNpcHold'
        A-Pushad $ovl
        A-CallNext $ovl
        Add-Label $ovl 'ANH_ref'
        A-PopEsi $ovl
        A-Db $ovl @(0x81, 0xEE); Add-Abs32 $ovl 'ANH_ref'                            # sub esi,ANH_ref -> obj1 delta
        A-Db $ovl @(0x8D, 0x9E); Add-Abs32 $ovl 'aztNpcTab'                          # lea ebx,[esi+aztNpcTab]
        A-Db $ovl @(0xB9, 0x04, 0x00, 0x00, 0x00)                                    # mov ecx,4
        Add-Label $ovl 'ANH_loop'
        A-Db $ovl @(0x39, 0x03)                                                      # cmp [ebx],eax
        A-JzS $ovl 'ANH_found'
        A-Db $ovl @(0x83, 0xC3, 0x0C)                                                # add ebx,12
        A-Db $ovl @(0x49)                                                            # dec ecx
        A-JnzS $ovl 'ANH_loop'
        A-JmpS $ovl 'ANH_stock'
        Add-Label $ovl 'ANH_found'
        # [ebx+7]: bit 0 = the host asks for a pause, bit 7 = this paused it (the host clears bit 0 to let go);
        # [ebx+8] = the state to pause in (REST 1, SNIFF 0xA ...: one the character's .ANI has a range for)
        A-Db $ovl @(0xF6, 0x43, 0x07, 0x01)                                          # test byte [ebx+7],1
        A-JzS $ovl 'ANH_resume'
        A-Db $ovl @(0x66, 0x83, 0x78, 0x08, 0x00)                                    # cmp word [eax+8],0   hunting the player?
        A-Jl $ovl 'ANH_stock'
        A-Db $ovl @(0x66, 0x83, 0x78, 0x0C, 0x00)                                    # cmp word [eax+0xC],0 dead?
        A-JzS $ovl 'ANH_stock'
        A-Db $ovl @(0x66, 0x83, 0x78, 0x3A, 0x00)                                    # cmp word [eax+0x3A],0 a script running?
        A-JnzS $ovl 'ANH_stock'
        A-Db $ovl @(0x66, 0x83, 0xB8, 0x62, 0x02, 0x00, 0x00, 0x00)                  # cmp word [eax+0x262],0 talking?
        A-JnzS $ovl 'ANH_stock'
        A-Db $ovl @(0x80, 0xB8, 0x60, 0x02, 0x00, 0x00, 0x05)                        # cmp byte [eax+0x260],5  running?
        A-JnzS $ovl 'ANH_out'                                                        # (paused already, or busy: no restart)
        A-Db $ovl @(0x0F, 0xB6, 0x53, 0x08)                                          # movzx edx,byte [ebx+8]  the pause's state
        A-Db $ovl @(0x85, 0xD2)                                                      # test edx,edx
        A-JnzS $ovl 'ANH_state'
        A-Db $ovl @(0xB2, 0x01)                                                      # mov dl,1 = REST (none given)
        Add-Label $ovl 'ANH_state'
        A-Db $ovl @(0x80, 0x4B, 0x07, 0x80)                                          # or byte [ebx+7],0x80  paused by us
        A-Call $ovl ([uint32]0x23DC8)                                                # stand / sniff
        A-JmpS $ovl 'ANH_out'
        Add-Label $ovl 'ANH_resume'                                                  # not held: did we pause it?
        A-Db $ovl @(0xF6, 0x43, 0x07, 0x80)                                          # test byte [ebx+7],0x80
        A-JzS $ovl 'ANH_stock'
        A-Db $ovl @(0xC6, 0x43, 0x07, 0x00)                                          # mov byte [ebx+7],0
        A-Db $ovl @(0x8A, 0x53, 0x08)                                                # mov dl,[ebx+8]
        A-Db $ovl @(0x84, 0xD2)                                                      # test dl,dl
        A-JnzS $ovl 'ANH_was'
        A-Db $ovl @(0xB2, 0x01)                                                      # mov dl,1
        Add-Label $ovl 'ANH_was'
        A-Db $ovl @(0x3A, 0x90, 0x60, 0x02, 0x00, 0x00)                              # cmp dl,[eax+0x260]   still in the pause?
        A-JnzS $ovl 'ANH_stock'                                                      # (shot, scripted...: the game decides)
        A-Db $ovl @(0xBA, 0x05, 0x00, 0x00, 0x00)                                    # mov edx,5 = RUN: off again
        A-Call $ovl ([uint32]0x23DC8)
        A-JmpS $ovl 'ANH_out'
        Add-Label $ovl 'ANH_stock'                                                   # the game's own restart, as it was
        A-Db $ovl @(0x66, 0x85, 0xFF)                                                # test di,di
        A-JzS $ovl 'ANH_out'
        A-Db $ovl @(0x80, 0xB8, 0x60, 0x02, 0x00, 0x00, 0x01)                        # cmp byte [eax+0x260],1
        A-JnzS $ovl 'ANH_out'
        A-Db $ovl @(0xBA, 0x05, 0x00, 0x00, 0x00)                                    # mov edx,5 = RUN
        A-Call $ovl ([uint32]0x23DC8)
        Add-Label $ovl 'ANH_out'
        A-Popad $ovl
        A-Ret $ovl

        Add-Label $ovl 'aztNpcPct';  A-Dw $ovl $NPC_RATE_PCT     # every character's pace, % of the 18.2 Hz steps (host may write it)
        Add-Label $ovl 'aztNpcAcc';  A-Dw $ovl 0
        Add-Label $ovl 'aztCharAcc'; A-Dw $ovl 0
        Add-Label $ovl 'aztCharDue'; A-Dw $ovl 0                 # this frame's character stride is due (AztFrameAll)
        Add-Label $ovl 'aztNpcTab';  A-Db $ovl (New-Object byte[] 48)   # 4 x {dd char, db pct, db strideAcc, db aiAcc, db hold, db pauseState, 3 spare}
    }

    # ---- THE LOG BOX WAITS FOR THE OPTIONS (Josh, 2026-10-13: "the conversation log will not expand until the dialogue
    # options are available. Currently it is open and blank until the character is done saying its first line and dialogue
    # options appear"). The box used to open on the conversation flag itself ([0x152B1C]), so it stood open and empty all
    # through the NPC's opening line: the game's list builder (0x17FF6) defers while a line is spoken (0x152B28 -> the
    # pending flag 0x152B26) and only prints the options once it ends. aztConvBox latches instead:
    #   0 = no conversation; 2 = one is up, box still collapsed; 1 = the options have printed -- open until it ends.
    # The first frame of a conversation only ARMS it (2): the option count 0x162B34 is only zeroed when the NEXT list is
    # built, so it is stale then, and AztBoxPrep's BOX_CONV rewinds the log's text cursor that same frame. It opens (1) once
    # nobody is speaking, there are options, and the text cursor of the log ([0x1521AC]+6) has moved: the list is printed.
    # Called by the box blob's AztBoxWindow and its click test in place of their [0x152B1C] test (3 bytes shorter).
    #   in: esi = obj1 delta, edi = obj2 delta.  Keeps every register; out: ZF = 1 when the conversation holds the box open.
    if ($ENABLE_CONV_BOX_LATCH) {
        Add-Label $ovl 'AztConvBoxZ'
        A-CmpWordDiImm $ovl $g_convList 0
        A-JnzS $ovl 'ACZ_up'
        A-MovWordSiImm $ovl 'aztConvBox' 0                      # no conversation
        A-JmpS $ovl 'ACZ_out'
        Add-Label $ovl 'ACZ_up'
        A-CmpWordSiImm $ovl 'aztConvBox' 2
        A-JzS $ovl 'ACZ_armed'
        A-CmpWordSiImm $ovl 'aztConvBox' 0
        A-JnzS $ovl 'ACZ_out'                                   # (1: open, stays open)
        A-MovWordSiImm $ovl 'aztConvBox' 2                      # first sight: arm only
        A-JmpS $ovl 'ACZ_out'
        Add-Label $ovl 'ACZ_armed'
        A-CmpWordDiImm $ovl ([uint32]0x152B28) 0                # a line is being spoken
        A-JnzS $ovl 'ACZ_out'
        A-CmpWordDiImm $ovl ([uint32]0x162B34) 0                # no options
        A-JzS $ovl 'ACZ_out'
        A-PushEax $ovl
        A-Db $ovl @(0x8B, 0x87); Add-Abs32 $ovl $LOG_TEXT_OBJ  # mov eax,[edi+textobj]
        A-Db $ovl @(0x85, 0xC0)                                 # test eax,eax
        A-JzS $ovl 'ACZ_pop'
        A-Db $ovl @(0x66, 0x83, 0x78, 0x06, 0x00)               # cmp word [eax+6],0   nothing printed yet
        A-JzS $ovl 'ACZ_pop'
        A-MovWordSiImm $ovl 'aztConvBox' 1                      # the options are up: open
        Add-Label $ovl 'ACZ_pop'
        A-PopEax $ovl
        Add-Label $ovl 'ACZ_out'
        A-CmpWordSiImm $ovl 'aztConvBox' 1
        A-Ret $ovl
        Add-Label $ovl 'aztConvBox'; A-Dw $ovl 0                # (the host's Panel reads it: BoxOpen)
    }

    # ---- THE ORIGINAL SCORE STAYS DOWN UNDER A RECORDED TRACK (Josh, 2026-10-13: "If I adjust volume, it still switches
    # to the old midi. It should never switch unless I click F4"). The recorded soundtrack plays as CD audio with the MIDI
    # sequence kept running at volume 0 (AztCdSwitch). But the game sets the MIDI's volume back to the player's level in SIX
    # places that the overlay's slider check (a change at 0x146940) never sees, or sees a frame late:
    #   0x3B048 (set volume now; eax = cue record, edx = level): 0x14D94 the music slider, 0x13E59, 0x13B18, 0x1154A;
    #   0x3B088 (fade to a level; ebx = ms): 0x16CC0, and 0x17FE2 -- the end of EVERY conversation (back to the
    #   slider's level over a second, after 0x17E6E faded it out at the start).
    # Each now calls through a gate: while the recorded track is the source (aztCdOn) and the MIDI is held under it
    # (aztCdMuted), the level becomes 0; otherwise the call is untouched. F4 (aztCdOn 0, aztCdMuted 0) gives the MIDI its
    # level back as before. Every register but edx (the level) is kept; the jump keeps the caller's return address.
    if ($ENABLE_CD_AUDIO) {
        Add-Label $ovl 'AztMidiQuiet'
        A-PushEsi $ovl
        A-CallNext $ovl
        Add-Label $ovl 'AMQ_ref'
        A-PopEsi $ovl
        A-Db $ovl @(0x81, 0xEE); Add-Abs32 $ovl 'AMQ_ref'                       # sub esi, AMQ_ref -> obj1 delta
        A-CmpWordSiImm $ovl ([uint32]$asm.Labels['aztCdOn']) 0
        A-JzS $ovl 'AMQ_out'                                                      # the original score (F4): untouched
        A-CmpDwordSiImm $ovl 'aztCdMuted' 0
        A-JzS $ovl 'AMQ_out'                                                      # no recorded track for this cue
        A-XorEdxEdx $ovl                                                          # level 0 under the recorded track
        Add-Label $ovl 'AMQ_out'
        A-PopEsi $ovl
        A-Ret $ovl
        Add-Label $ovl 'AztMidiVol48'                                             # in place of `call 0x3B048`
        A-Call $ovl 'AztMidiQuiet'
        A-Jmp $ovl ([uint32]0x3B048)
        Add-Label $ovl 'AztMidiVol88'                                             # in place of `call 0x3B088`
        A-Call $ovl 'AztMidiQuiet'
        A-Jmp $ovl ([uint32]0x3B088)
    }

    # ---- M opens and closes the map ($ENABLE_M_MAP): in place of `cmp al,'m' / jz 0x13391` at 0x135BC (al = the key's
    # character); 0x1339F is the toggle call past the weapon test at 0x13391; 0x135C4 is where any other key goes on
    if ($ENABLE_MAP_NO_FIRE) {
        # in place of `jz 0x1607C` at 0x15AFC; ZF is the handler's `cmp word [weapon],0`
        Add-Label $ovl 'AztFireGate'
        A-Jz $ovl ([uint32]0x1607C)                # no weapon: the ordinary click, as before
        A-PushEax $ovl; A-PushEsi $ovl; A-PushEdi $ovl
        A-Call $ovl ([uint32]$asm.Labels['AztDeltas'])   # esi / edi = the obj1 / obj2 deltas (eax, esi, edi clobbered: all saved)
        A-CmpWordDiImm $ovl ([uint32]0x1525F2) 0   # the map (or help) screen up?
        A-PopEdi $ovl; A-PopEsi $ovl; A-PopEax $ovl    # (pops keep the flags)
        A-Jnz $ovl ([uint32]0x1607C)               # yes: the ordinary click, no shot
        A-Jmp $ovl ([uint32]0x15B02)               # no: on to the shot, as before
    }
    if ($ENABLE_M_MAP) {
        Add-Label $ovl 'AztMKey'
        A-Db $ovl @(0x3C, 0x6D)                    # cmp al, 'm'
        A-Jz $ovl ([uint32]0x1339F)
        A-Db $ovl @(0x3C, 0x4D)                    # cmp al, 'M'
        A-Jz $ovl ([uint32]0x1339F)
        A-Jmp $ovl ([uint32]0x135C4)
    }

    # ---- AztMapBlit ($ENABLE_MAP_BLIT): in place of `call 0x33F80` at 0x1589F (eax = the map's surface 0x1525E0, edx = x,
    # ebx = y, both 0 there). Tail-jumps to the blit with the map centred in the view; returns at once while the host
    # draws its own map (aztOldMapOff != 0). eax/esi/edi kept round the deltas; pops leave the flags.
    if ($ENABLE_MAP_BLIT) {
        Add-Label $ovl 'AztMapBlit'
        A-PushEax $ovl; A-PushEsi $ovl; A-PushEdi $ovl; A-Call $ovl ([uint32]$asm.Labels['AztDeltas'])
        A-MovEaxSi $ovl 'aztOldMapOff'
        A-TestEaxEax $ovl
        A-PopEdi $ovl; A-PopEsi $ovl; A-PopEax $ovl
        A-Jnz $ovl 'AMB_skip'
        $mbX = [int]($VIEW_X + [Math]::Max(0, ($VIEW_W - 640) / 2)); $mbY = [int]($VIEW_Y + [Math]::Max(0, ($VIEW_H - 480) / 2))
        A-Db $ovl ([byte[]](@(0xBA) + [BitConverter]::GetBytes([int]$mbX)))      # mov edx, x
        A-Db $ovl ([byte[]](@(0xBB) + [BitConverter]::GetBytes([int]$mbY)))      # mov ebx, y
        A-Jmp $ovl ([uint32]0x33F80)
        # (the host draws the map: the game's picture is not drawn -- but the strip ABOVE the view, outside the host's window,
        # would keep the HUD's last frame (compass, top band) in the MAP's palette: a pale banner -- Josh, 2026-10-14. So that
        # strip is covered with the backdrop's own black: its bottom rows (the wiped panel band, 322..479) blitted at
        # y = VIEW_Y - 480, across the screen in 640-wide steps; the blit clips what falls off the screen.)
        Add-Label $ovl 'AMB_skip'
        for ($bx = 0; $bx -lt $SCREEN_W; $bx += 640) {
            A-PushEax $ovl
            A-Db $ovl ([byte[]](@(0xBA) + [BitConverter]::GetBytes([int]$bx)))                 # mov edx, x
            A-Db $ovl ([byte[]](@(0xBB) + [BitConverter]::GetBytes([int]($VIEW_Y - 480))))     # mov ebx, y (above the screen)
            A-Call $ovl ([uint32]0x33F80)
            A-PopEax $ovl
        }
        A-Ret $ovl
        Add-Label $ovl 'aztOldMapOff'; A-Dd $ovl 0          # the HOST writes it: 1 = it draws the map, the game's is not drawn
    }

    $ovlAsm = Invoke-Asm $ovl
    if ($ENABLE_NPC_PACE -and $ovlAsm.Labels['AztOvlActor'] -ne ($OVERLAY_BASE + 21)) { throw ("AztOvlActor must sit at 0x{0:X} (the clock blob calls that literal); it is at 0x{1:X}" -f ($OVERLAY_BASE + 21), $ovlAsm.Labels['AztOvlActor']) }
    if ($ovlAsm.Labels['aztTypingKeys'] -ne $TYPING_KEYS_AT) {
        throw ("aztTypingKeys must sit at 0x{0:X} (the stub's WASD hooks read that literal); it is at 0x{1:X}" -f $TYPING_KEYS_AT, $ovlAsm.Labels['aztTypingKeys'])
    }
    if ($ovlAsm.Labels['AztOvlInit'] -ne ($OVERLAY_BASE + 4)) {
        throw ("AztOvlInit must sit at +4 (the loader calls that literal); it is at 0x{0:X}" -f $ovlAsm.Labels['AztOvlInit'])
    }
    if ($ovlAsm.Labels['AztOvlFrame'] -ne ($OVERLAY_BASE + 9)) {
        throw ("AztOvlFrame must sit at +9 (AztFrameLimit calls that literal); it is at 0x{0:X}" -f $ovlAsm.Labels['AztOvlFrame'])
    }
    if ($ovlAsm.Labels['AztOvlCdBoot'] -ne ($OVERLAY_BASE + 14)) {
        throw ("AztOvlCdBoot must sit at +14 (the AztCdBoot stub calls that literal); it is at 0x{0:X}" -f $ovlAsm.Labels['AztOvlCdBoot'])
    }

    # ---- WRITE THE OVERLAY SYMBOL MAP ------------------------------------------
    # The manifest carries 8 symbols, and none of them are the overlay's. Every
    # time something in here has had to be inspected -- in the blob, in a live
    # process over the bridge, or in a disassembly -- the addresses have had to be
    # recovered by hunting for byte signatures, and the host/guest bridge notes
    # warn that rebuilding to recover them can produce a blob that differs from
    # the one the running game loaded. Writing the map beside the manifest costs
    # nothing and removes that whole class of guesswork.
    $symPath = Join-Path (Split-Path -Parent $OutFile) 'AztMod.overlay.sym'
    $symLines = New-Object System.Collections.Generic.List[string]
    $symLines.Add(("# AztMod overlay symbols -- base 0x{0:X}, {1} bytes" -f $OVERLAY_BASE, $ovlAsm.Bytes.Count))
    $symLines.Add("# linear  name          (sorted by address; add the obj1 delta for runtime)")
    foreach ($k in ($ovlAsm.Labels.Keys | Sort-Object { [uint32]$ovlAsm.Labels[$_] })) {
        $symLines.Add(("0x{0:X6}  {1}" -f [uint32]$ovlAsm.Labels[$k], $k))
    }
    # Outside the overlay but read by the host's widescreen panel (tools\Panel.cs): the log's
    # scroll offset lives in the stub cave. (aztBoxBig is fixed at CAVE2_BASE+15 by design.)
    if ($a.Labels.ContainsKey('aztLogScroll')) { $symLines.Add(("0x{0:X6}  aztLogScroll" -f [uint32]$a.Labels['aztLogScroll'])) }
    [IO.File]::WriteAllLines($symPath, $symLines)
    Write-Host ("overlay symbols: {0} written to {1}" -f $ovlAsm.Labels.Count, (Split-Path $symPath -Leaf))

    # ---- the HUD whoosh moves to the END of the boot ---------------------------
    # Both sites that hand "hud3.wav" to the sound player are redirected to AztWhooshGate,
    # which swallows it while the visor is booting and replays it at ABT_finish. See the
    # routine for why only eax matters and why the string is at obj2 0x143160.
    if ($ENABLE_BOOT_SEQ) {
        $whooshTgt = [uint32]$ovlAsm.Labels['AztWhooshGate']
        if ($whooshTgt -lt $OVERLAY_BASE) { throw 'AztWhooshGate resolved below the overlay base' }
        foreach ($ws in @(0x2C2E8, 0x2C85E)) {
            $wo   = Lin2File ([uint32]$ws)
            $worg = $raw[$wo..($wo + 4)]
            if ($worg[0] -ne 0xE8) { throw ("hud whoosh: expected E8 at 0x{0:X5}, found 0x{1:X2}" -f $ws, $worg[0]) }
            $wreal = [uint32]($ws + 5 + [BitConverter]::ToInt32(([byte[]]$worg[1..4]), 0))
            if ($wreal -ne [uint32]0x100BC) {
                throw ("hud whoosh: 0x{0:X5} calls 0x{1:X5}, expected the sound player 0x100BC" -f $ws, $wreal)
            }
            $patches += New-Patch -Name ("hud-whoosh-{0:X5}" -f $ws) -FileOffset $wo `
                -Expect $worg -Replace (CallRel32 $ws $whooshTgt) `
                -Note 'hud3.wav is held back until the visor finishes booting, then played once'
        }
        Write-Host ("hud whoosh: 2 site(s) -> AztWhooshGate at 0x{0:X5}, replayed at ABT_finish" -f $whooshTgt)
    }
    if ($ovlAsm.Bytes.Length -gt $OVERLAY_READ) {
        throw ("overlay is {0} bytes, more than AztOverlayLoad reads ({1})" -f $ovlAsm.Bytes.Length, $OVERLAY_READ)
    }
    Write-Host ("overlay: {0} bytes at 0x{1:X} -> {2}  ({3:N0} bytes of BSS still free)" -f `
                $ovlAsm.Bytes.Length, $OVERLAY_BASE, $OVERLAY_NAME,
                ($OBJ1_BASE + $OBJ1_VSIZE - $OVERLAY_BASE - $ovlAsm.Bytes.Length))

    # The camera log is written with ONE `int 21h` AH=40h of $CAM_REC_LEN bytes
    # starting at aztCamRec, so the record is only correct if every field label is
    # contiguous, in the declared order, and the run is exactly that long. Assert
    # it: a stray label between two fields would silently shift the file format and
    # the decoder would report confident nonsense. Two fields are also read through
    # ebp with an 8-bit displacement by AztCamSnap, so their spacing is checked too.
    if ($ENABLE_CAM_LOG) {
        $camMap = @(
            @('aztCamRec',0),     @('aztCamFrameNo',4), @('aztCamTime',4),
            @('aztCamIface',4),   @('aztCamObj',4),     @('aztCamType',4),
            @('aztCamParent',4),  @('aztCamWorld',4),   @('aztCamLocal',64),
            @('aztMovIface',64),  @('aztMovObj',4),     @('aztMovType',4),
            @('aztMovParent',4),  @('aztMovWorld',4),   @('aztMovLocal',64),
            @('aztCamEyeY',64),   @('aztCamCue',4),     @('aztCamRoot',4),
            @('aztCamDelta1',4),  @('aztCamDelta2',4)
        )
        $base = $ovlAsm.Labels['aztCamRec']
        $prev = $null
        foreach ($e in $camMap) {
            $a = $ovlAsm.Labels[$e[0]]
            if ($null -ne $prev -and ($a - $prev) -ne [uint32]$e[1]) {
                throw ("camera record is not contiguous: {0} is {1} bytes after the previous field, expected {2}" -f `
                       $e[0], ($a - $prev), $e[1])
            }
            $prev = $a
        }
        $camLen = ($prev + 4) - $base          # aztCamDelta2 is the last dword
        if ($camLen -ne $CAM_REC_LEN) {
            throw ("camera record spans {0} bytes but CAM_REC_LEN is {1}" -f $camLen, $CAM_REC_LEN)
        }
        # AztCamSnap writes both blocks through `mov [ebp+d8]` / `lea edi,[ebp+d8]`,
        # which cannot reach past +0x7F, and expects local to sit 0x40 after world.
        foreach ($pair in @(@('aztCamObj','aztCamWorld',0x0C), @('aztCamObj','aztCamLocal',0x4C),
                            @('aztMovObj','aztMovWorld',0x0C), @('aztMovObj','aztMovLocal',0x4C))) {
            $d = $ovlAsm.Labels[$pair[1]] - $ovlAsm.Labels[$pair[0]]
            if ($d -ne [uint32]$pair[2]) {
                throw ("{0} is +0x{1:X} from {2}, but AztCamSnap encodes +0x{3:X}" -f $pair[1], $d, $pair[0], $pair[2])
            }
            if ($d -gt 0x7F) { throw ("{0} at +0x{1:X} is out of reach of an 8-bit displacement" -f $pair[1], $d) }
        }
        Write-Host ("camera log: {0}-byte record at 0x{1:X}, contiguous and in range -> {2}" -f `
                    $camLen, $base, $CAM_LOG_NAME)
    }

    # Same discipline for the scene node record: one INT 21h AH=40h writes the whole
    # run, so a label out of place would silently shift the on-disk format.
    if ($ENABLE_SCENE_LOG) {
        $scnMap = @(
            @('aztScnRec',0), @('aztScnObj',4), @('aztScnDepthF',4),
            @('aztScnHdr',4), @('aztScnWorld',76), @('aztScnTail',64),
            @('aztScnRest',112), @('aztScnVis0',416),
            @('aztScnA1',128), @('aztScnA2',128), @('aztScnA3',128), @('aztScnF0',128),
            @('aztScnP20',128), @('aztScnP24',64), @('aztScnPad',64)
        )
        $sBase = $ovlAsm.Labels['aztScnRec']
        $sPrev = $null
        foreach ($e in $scnMap) {
            $a = $ovlAsm.Labels[$e[0]]
            if ($null -ne $sPrev -and ($a - $sPrev) -ne [uint32]$e[1]) {
                throw ("scene node record is not contiguous: {0} is {1} bytes after the previous field, expected {2}" -f `
                       $e[0], ($a - $sPrev), $e[1])
            }
            $sPrev = $a
        }
        $scnLen = ($sPrev + 8) - $sBase        # aztScnPad is 8 bytes
        if ($scnLen -ne $SCN_REC_LEN) {
            throw ("scene node record spans {0} bytes but SCN_REC_LEN is {1}" -f $scnLen, $SCN_REC_LEN)
        }
        Write-Host ("scene log: {0}-byte node record at 0x{1:X}, contiguous -> {2}" -f `
                    $scnLen, $sBase, $SCENE_LOG_NAME)
    }

    # The geometry header is one INT 21h write followed immediately by the payloads,
    # so a label out of place would shift the whole file format and every mesh after
    # it. Same assertion as the other two records.
    if ($ENABLE_GEO_LOG) {
        $geoMap = @(
            @('aztGeoRec',0),   @('aztGeoFrame',4), @('aztGeoDepth',4),
            @('aztGeoVCnt',4),  @('aztGeoFCnt',4),  @('aztGeoNCnt',4),
            @('aztGeoVBase',4), @('aztGeoFBase',4), @('aztGeoNBase',4),
            @('aztGeoMesh',4),  @('aztGeoWorld',4), @('aztGeoName',64),
            @('aztGeoLocal',32), @('aztGeoTex0',64), @('aztGeoMat0',128),
            @('aztGeoPad',128)
        )
        $gBase = $ovlAsm.Labels['aztGeoRec']
        $gPrev = $null
        foreach ($e in $geoMap) {
            $a = $ovlAsm.Labels[$e[0]]
            if ($null -ne $gPrev -and ($a - $gPrev) -ne [uint32]$e[1]) {
                throw ("geometry header is not contiguous: {0} is {1} bytes after the previous field, expected {2}" -f `
                       $e[0], ($a - $gPrev), $e[1])
            }
            $gPrev = $a
        }
        $geoLen = ($gPrev + 8) - $gBase
        if ($geoLen -ne $GEO_HDR_LEN) {
            throw ("geometry header spans {0} bytes but GEO_HDR_LEN is {1}" -f $geoLen, $GEO_HDR_LEN)
        }
        Write-Host ("geometry log: {0}-byte header at 0x{1:X}, contiguous -> {2}" -f `
                    $geoLen, $gBase, $GEO_LOG_NAME)
    }

    # ---- the SIX animation-advance sites --------------------------------------
    # Found by sweeping the whole image for both shapes of "+1 into an animation
    # frame" -- `fld1 ... fild [r+4] ... fistp [r+4]` and `inc r / mov word
    # [r+0x284],r16` -- rather than by following callbacks, because the first
    # attempt followed callbacks, found three, and missed the three in 0x1E4B0.
    # That is exactly the set the opening room was using.
    #
    # Verified before writing this, for every range: no branch anywhere in the
    # image lands inside it, and none carries an LE fixup, so there is no
    # relocated operand to preserve. (0x1E536's neighbour DOES carry one, which
    # is why that range stops short of it -- see AztAnimAddEdxSt.)
    #
    # `tail` is how the stock range ended: a range that fell through needs
    # nothing, a range that jumped away has that jump re-issued so both paths
    # rejoin exactly where they used to.
    foreach ($s in @(
        @{ n='anim-step-callback'; at=[uint32]0x22C05; len=15; to='AztAnimStep'; tail=[uint32]0x22CB1
           want=[byte[]]@(0x89,0xC2,0x42,0x66,0x89,0x93,0x84,0x02,0x00,0x00,0xE9,0x9D,0x00,0x00,0x00)
           d='character animation advances on the clock, not once per rendered frame (move callback 0x229A4)' },
        @{ n='anim-step-direct';   at=[uint32]0x24294; len=15; to='AztAnimStep'; tail=[uint32]0x24342
           want=[byte[]]@(0x89,0xC2,0x42,0x66,0x89,0x93,0x84,0x02,0x00,0x00,0xE9,0x9F,0x00,0x00,0x00)
           d='the same advance again, on the direct entry at 0x24090' },
        @{ n='anim-step-room';     at=[uint32]0x1E347; len=17; to='AztAnimAddEdx'; movEdxEcx=$true; tailShort=[uint32]0x1E366
           want=[byte[]]@(0xD9,0xE8,0xDB,0x41,0x04,0xDE,0xC1,0xE8,0x4B,0x97,0x01,0x00,0xDB,0x59,0x04,0xEB,0x0E)
           d='room animations advance on the clock (move callback 0x1E2A8; its ecx moved to edx)' },
        @{ n='anim-step-room2-a';  at=[uint32]0x1E509; len=15; to='AztAnimAddEdx'
           want=[byte[]]@(0xD9,0xE8,0xDB,0x42,0x04,0xDE,0xC1,0xE8,0x89,0x95,0x01,0x00,0xDB,0x5A,0x04)
           d='the SECOND room-animation callback 0x1E4B0, advance 1 of 3 -- the one the opening room uses' },
        @{ n='anim-step-room2-b';  at=[uint32]0x1E536; len=9;  to='AztAnimAddEdxSt'
           want=[byte[]]@(0xD9,0xE8,0xDB,0x42,0x04,0xD9,0xC9,0xD8,0xC1)
           d='0x1E4B0 advance 2 of 3; stops short of the fixed-up load at 0x1E53F' },
        @{ n='anim-step-room2-c';  at=[uint32]0x1E568; len=15; to='AztAnimAddEdx'
           want=[byte[]]@(0xD9,0xE8,0xDB,0x42,0x04,0xDE,0xC1,0xE8,0x2A,0x95,0x01,0x00,0xDB,0x5A,0x04)
           d='0x1E4B0 advance 3 of 3 -- it can bump twice in one frame, so this ran at up to 2x the frame rate' }
    )) {
        $of  = Lin2File $s.at
        $exp = $raw[$of..($of + $s.len - 1)]
        if ((Hex $exp) -ne (Hex $s.want)) {
            throw ("{0}: 0x{1:X} is not the animation advance -- found {2}" -f $s.n, $s.at, (Hex $exp))
        }
        $rep = New-Object byte[] $s.len
        $i = 0
        if ($s.ContainsKey('movEdxEcx')) { $rep[0] = 0x89; $rep[1] = 0xCA; $i = 2 }   # mov edx, ecx
        (CallRel32 ([uint32]($s.at + $i)) $ovlAsm.Labels[$s.to]).CopyTo($rep, $i)
        $i += 5
        if ($s.ContainsKey('tail')) {
            (JmpRel32 ([uint32]($s.at + $i)) $s.tail).CopyTo($rep, $i); $i += 5
        }
        for ($k = $i; $k -lt $s.len; $k++) { $rep[$k] = 0x90 }
        # A short tail goes at the very END of the range, so the padding sits
        # between the call and it rather than after an unreachable jump.
        if ($s.ContainsKey('tailShort')) {
            $at = [uint32]($s.at + $s.len - 2)
            $d8 = [int]$s.tailShort - [int]($at + 2)
            if ($d8 -lt -128 -or $d8 -gt 127) { throw ("{0}: short tail out of range" -f $s.n) }
            $rep[$s.len - 2] = 0xEB; $rep[$s.len - 1] = [byte]($d8 -band 0xFF)
        }
        $patches += New-Patch -Name $s.n -FileOffset $of -Expect $exp -Replace $rep -Note $s.d
    }

    if ($ENABLE_NPC_PACE) {
        # the AI step (0x2662E) and the WANDER restart (0x2694E..0x26966) -- no fixups, nothing branches into either
        foreach ($s in @(
            @{ n='npc-ai-2662E'; at=[uint32]0x2662E; to='AztNpcAi'; tail=$null
               want=[byte[]]@(0x8A,0xB0,0x60,0x02,0x00,0x00)
               d='a character''s AI step at its own pace (AztNpcAi: dh = 0 = not this step; the room''s "npcs")' },
            @{ n='npc-hold-2694E'; at=[uint32]0x2694E; to='AztNpcHold'; tail=[uint32]0x26966
               want=[byte[]]@(0x66,0x85,0xFF,0x74,0x13,0x80,0xB8,0x60,0x02,0x00,0x00,0x01,0x75,0x0A,0xBA,0x05,0x00,0x00,0x00,0xE8,0x62,0xD4,0xFF,0xFF)
               d='the WANDER restart, or a pause (AztNpcHold: RUN -> REST while the host holds a character)' }
        )) {
            $of = Lin2File $s.at; $len = $s.want.Length
            $exp = $raw[$of..($of + $len - 1)]
            if ((Hex $exp) -ne (Hex $s.want)) { throw ("{0}: 0x{1:X} is not what was disassembled -- found {2}" -f $s.n, $s.at, (Hex $exp)) }
            $rep = New-Object byte[] $len; for ($k = 0; $k -lt $len; $k++) { $rep[$k] = 0x90 }
            (CallRel32 $s.at $ovlAsm.Labels[$s.to]).CopyTo($rep, 0)
            if ($s.tail) { (JmpRel32 ([uint32]($s.at + 5)) $s.tail).CopyTo($rep, 5) }
            $patches += New-Patch -Name $s.n -FileOffset $of -Expect $exp -Replace $rep -Note $s.d
        }
        Write-Host ("npc pace: every character at {0}% (actor steps and stride), per-character shares and pauses from the host" -f $NPC_RATE_PCT)
    }
    Write-Host ("animation gate: one step per {0} us ({1:N1} Hz), six sites" -f `
                $ANIM_PERIOD_US, (1000000.0 / $ANIM_PERIOD_US))

    if ($ENABLE_HOST_RENDER) {
        $pgAt   = [uint32]0x11830
        $pgWant = [byte[]]@(0xE8,0xEB,0x8B,0x02,0x00)                 # call 0x3A420
        $pgOf   = Lin2File $pgAt
        $pgExp  = $raw[$pgOf..($pgOf + 4)]
        if ((Hex $pgExp) -ne (Hex $pgWant)) {
            throw ("pick-guard: 0x{0:X} is not `call 0x3A420` -- found {1}" -f $pgAt, (Hex $pgExp))
        }
        $patches += New-Patch -Name 'pick-guard' -FileOffset $pgOf -Expect $pgExp `
            -Replace (CallRel32 $pgAt $ovlAsm.Labels['AztPickGuard']) `
            -Note 'cursor pick: a handle Reality Lab cannot resolve means nothing picked, not a fatal error'
        Write-Host ("pick guard: 0x{0:X} -> AztPickGuard at 0x{1:X}" -f $pgAt, $ovlAsm.Labels['AztPickGuard'])
    }

    # ---- no red "input locked" brackets (Josh, 2026-10-13: "when talking to characters, there is a red glow that appears
    # in the 4:3 aspect from the original game. I want that removed"). While a modal holds the controls -- a conversation
    # (0x14721A, set by the opener 0x17E52) or a script lock (0x1471F0) -- the main loop draws four corner brackets of 8 lines
    # in palette 127 (247,20,0) with 0x3847C, every other frame (the phase word 0x152108). Stock they were 20 px; the view
    # patches (view-w1/h1-*) widened their ends but not their starts (531, 261), so in the mod they are long red lines
    # along the view's edges, blinking at frame rate: the glow. The phase test always skips the draws now; the toggle at
    # 0x156B2 still runs (nothing else reads 0x152108). No fixups in 0x155DC..0x155E1. The host draws its own conversation
    # cue (the visor's amber edge and the recording badge).
    # ---- the MIDI's volume calls through AztMidiVol48/88 (see the overlay; Josh, 2026-10-13). Each site is a plain
    # `call rel32` with no fixups (Test-FixupsIn) and no other patch on it; the build checks each is still calling the
    # routine it expects.
    if ($ENABLE_CD_AUDIO) {
        foreach ($mv in @(@(0x14D94, 0x3B048, 'AztMidiVol48', 'the music slider'),
                          @(0x13E59, 0x3B048, 'AztMidiVol48', 'a restore after a pause'),
                          @(0x13B18, 0x3B048, 'AztMidiVol48', 'a restore in the main loop'),
                          @(0x1154A, 0x3B048, 'AztMidiVol48', 'a restore at a room''s cue'),
                          @(0x16CC0, 0x3B088, 'AztMidiVol88', 'a fade back up'),
                          @(0x17FE2, 0x3B088, 'AztMidiVol88', 'the fade back up when a conversation ends'))) {
            $mvAt = [uint32]$mv[0]; $mvOf = Lin2File $mvAt
            $mvExp = $raw[$mvOf..($mvOf + 4)]
            if ((Hex $mvExp) -ne (Hex (CallRel32 $mvAt ([uint32]$mv[1])))) { throw ("midi gate: 0x{0:X} is not `call 0x{1:X}` -- found {2}" -f $mvAt, $mv[1], (Hex $mvExp)) }
            $patches += New-Patch -Name ("midi-quiet-{0:X}" -f $mvAt) -FileOffset $mvOf -Expect $mvExp `
                -Replace (CallRel32 $mvAt $ovlAsm.Labels[$mv[2]]) `
                -Note ("{0}: the MIDI stays at 0 under a recorded track (F4 gives it back)" -f $mv[3])
        }
    }

    if ($ENABLE_MAP_NO_FIRE) {
        $fgAt = [uint32]0x15AFC; $fgOf = Lin2File $fgAt
        $fgExp = $raw[$fgOf..($fgOf + 5)]
        if ((Hex $fgExp) -ne (Hex ([byte[]]@(0x0F, 0x84, 0x7A, 0x05, 0x00, 0x00)))) { throw ("map-no-fire: 0x{0:X} is not `jz 0x1607C` -- found {1}" -f $fgAt, (Hex $fgExp)) }
        $fgRep = (JmpRel32 $fgAt $ovlAsm.Labels['AztFireGate']) + [byte[]]@(0x90)
        $patches += New-Patch -Name 'map-no-fire-15AFC' -FileOffset $fgOf -Expect $fgExp -Replace $fgRep `
            -Note 'no shot while the map / help screen is up (AztFireGate): the left click there is the ordinary one'
    }
    if ($ENABLE_MAP_BLIT) {
        $mbAt = [uint32]0x1589F; $mbOf = Lin2File $mbAt
        $mbExp = $raw[$mbOf..($mbOf + 4)]
        if ((Hex $mbExp) -ne (Hex (CallRel32 $mbAt ([uint32]0x33F80)))) { throw ("map-blit: 0x{0:X} is not ``call 0x33F80`` -- found {1}" -f $mbAt, (Hex $mbExp)) }
        $patches += New-Patch -Name 'map-blit-1589F' -FileOffset $mbOf -Expect $mbExp -Replace (CallRel32 $mbAt $ovlAsm.Labels['AztMapBlit']) `
            -Note 'the game''s map: centred in the view at its own 640x480, or not drawn while the host draws the 3D map (AztMapBlit, aztOldMapOff)'
    }

    if ($ENABLE_M_MAP) {
        $mkAt = [uint32]0x135BC; $mkOf = Lin2File $mkAt
        $mkExp = $raw[$mkOf..($mkOf + 7)]
        if ((Hex $mkExp) -ne (Hex ([byte[]]@(0x3C, 0x6D, 0x0F, 0x84, 0xCD, 0xFD, 0xFF, 0xFF)))) { throw ("m-key: 0x{0:X} is not `cmp al,'m' / jz 0x13391` -- found {1}" -f $mkAt, (Hex $mkExp)) }
        $mkRep = (JmpRel32 $mkAt $ovlAsm.Labels['AztMKey']) + [byte[]]@(0x90, 0x90, 0x90)
        $patches += New-Patch -Name 'm-key-map-135BC' -FileOffset $mkOf -Expect $mkExp -Replace $mkRep `
            -Note 'M (either case) opens and closes the map, weapon drawn or not (AztMKey)'
    }

    if ($ENABLE_NO_LOCK_BRACKETS) {
        $lbAt  = [uint32]0x155DC
        $lbOf  = Lin2File $lbAt
        $lbExp = $raw[$lbOf..($lbOf + 5)]
        if ((Hex $lbExp) -ne (Hex ([byte[]]@(0x0F,0x84,0xD0,0x00,0x00,0x00)))) { throw ("no-lock-brackets: 0x{0:X} is not `jz 0x156B2` -- found {1}" -f $lbAt, (Hex $lbExp)) }
        $patches += New-Patch -Name 'no-lock-brackets-155DC' -FileOffset $lbOf -Expect $lbExp `
            -Replace ([byte[]]@(0x90,0xE9,0xD0,0x00,0x00,0x00)) `
            -Note 'the red blinking lock brackets: always skip their 8 line draws (nop; jmp 0x156B2)'
    }

    # ---- the Reality Lab error callback, so the crash names itself -----------
    # Verified before writing this, not assumed: no LE fixup falls inside the
    # range, and no branch anywhere in the image lands inside it either, so there
    # is no relocated operand to preserve and no second entry to keep working.
    if ($ENABLE_RAPTOR_TRAP -and $ENABLE_HOST_RENDER) {
        $rtAt   = [uint32]0x10204
        $rtWant = [byte[]]@(0x0F,0xBE,0xC0,0xE8,0xE8,0x2D,0x02,0x00)  # movsx eax,al / call 0x32FF4
        $rtOf   = Lin2File $rtAt
        $rtExp  = $raw[$rtOf..($rtOf + 7)]
        if ((Hex $rtExp) -ne (Hex $rtWant)) {
            throw ("raptor-trap: 0x{0:X} is not the RL error callback -- found {1}" -f $rtAt, (Hex $rtExp))
        }
        $rtRep = New-Object byte[] 8
        (JmpRel32 $rtAt $ovlAsm.Labels['AztRaptorTrap']).CopyTo($rtRep, 0)
        for ($k = 5; $k -lt 8; $k++) { $rtRep[$k] = 0x90 }
        $patches += New-Patch -Name 'raptor-trap' -FileOffset $rtOf -Expect $rtExp -Replace $rtRep `
            -Note 'records the caller chain when Reality Lab reports an error, then reports it as before'
        Write-Host ("raptor trap: 0x{0:X} -> AztRaptorTrap at 0x{1:X}" -f $rtAt, $ovlAsm.Labels['AztRaptorTrap'])
    }

    # ...and the site that hands the ESC-only test over to AztSkipKey. Nine bytes
    # replaced -- `cmp eax,0x1B` and its long `jnz` -- by a jump and padding. The
    # routine re-issues both comparisons and both destinations, so the stock ESC
    # behaviour is preserved exactly and Space joins it.
    if ($ENABLE_SKIP_SPACE) {
        $ofSkip  = Lin2File ([uint32]0x12D5E)
        $expSkip = $raw[$ofSkip..($ofSkip + 8)]
        $wantS   = [byte[]]@(0x83,0xF8,0x1B,0x0F,0x85,0xC8,0x01,0x00,0x00)
        for ($k = 0; $k -lt $wantS.Length; $k++) {
            if ($expSkip[$k] -ne $wantS[$k]) { throw "0x12D5E is not 'cmp eax,0x1B / jnz 0x12F2F' -- the dialogue skip test moved" }
        }
        $repSkip = (JmpRel32 0x12D5E $ovlAsm.Labels['AztSkipKey']) + [byte[]]@(0x90,0x90,0x90,0x90)
        if ($repSkip.Length -ne $expSkip.Length) { throw "skip-space replacement is the wrong length" }
        $patches += New-Patch -Name 'skip-space-12D5E' -FileOffset $ofSkip -Expect $expSkip -Replace $repSkip `
            -Note 'SPACE skips a line of dialogue, as ESC already did (both now go to the game''s own end-of-speech path)'
    }

    # ---- F1 opens the help screen in combat mode too ---------------------------
    #
    # F1 is the help screen. The keydown handler reaches it at 0x12FE7:
    #
    #     0x12FE7  cmp word [0x14721C], 0      <- 0x14721C is $g_combat
    #     0x12FEF  jnz 0x1371B                 <- in combat mode: do nothing AT ALL
    #     0x12FF5  mov eax, -1                 <- -1 = help rather than a map id
    #     0x12FFA  call 0x12954                <- toggle help mode
    #
    # Stock, that is a reasonable rule: combat mode is a thing you deliberately
    # enter for a fight, and you should not be able to pause into a help screen
    # mid-fight. Under this mod it is close to permanent -- mouse-look is the
    # default, the crosshair is pinned to the view centre, and left mouse fires --
    # so the help screen became unreachable in ordinary play. It presents as F1
    # doing absolutely nothing, with no clue that a mode gate is responsible.
    #
    # Six NOPs over the conditional, leaving the compare in place. Deliberately NOT
    # touching the flag itself: it drives the crosshair, the firing behaviour and
    # the mouse confine rect (see the notes on 0x13240), and forcing it would change
    # all of those. This only removes the refusal.
    if ($ENABLE_F1_IN_COMBAT) {
        # THE COMPARE IS VERIFIED BUT NOT TOUCHED, and the reason is the whole shape of
        # this patch: byte 5 of `cmp word [0x14721C],0` is an LE FIXUP. The file holds
        # 0x00 there and the loader writes 0x14 into it, so a patch whose Expect came
        # from the disassembly would never match, and one that REPLACED those bytes
        # would overwrite a relocation. Only the conditional jump below it is touched --
        # six plain bytes with no fixup in them.
        $ofCmp = Lin2File ([uint32]0x12FE7)
        $wantC = [byte[]]@(0x66,0x83,0x3D,0x1C,0x72,0x00,0x00,0x00)   # as it sits IN THE FILE
        for ($k = 0; $k -lt $wantC.Length; $k++) {
            if ($raw[$ofCmp + $k] -ne $wantC[$k]) {
                throw ("0x12FE7 is not the combat-mode test on the help toggle (file byte {0} is 0x{1:X2}, expected 0x{2:X2})" -f `
                       $k, $raw[$ofCmp + $k], $wantC[$k])
            }
        }
        $ofF1  = Lin2File ([uint32]0x12FEF)
        $expF1 = $raw[$ofF1..($ofF1 + 5)]
        $wantF1 = [byte[]]@(0x0F,0x85,0x26,0x07,0x00,0x00)            # jnz 0x1371B
        for ($k = 0; $k -lt $wantF1.Length; $k++) {
            if ($expF1[$k] -ne $wantF1[$k]) {
                throw ("0x12FEF is not 'jnz 0x1371B' -- the help toggle's combat gate moved (byte {0} is 0x{1:X2})" -f $k, $expF1[$k])
            }
        }
        $patches += New-Patch -Name 'f1-help-in-combat' -FileOffset $ofF1 `
            -Expect $expF1 -Replace ([byte[]]@(0x90,0x90,0x90,0x90,0x90,0x90)) `
            -Note 'F1 opens the help screen even in combat mode (stock refuses, and this mod is in combat mode nearly always)'
    }

    # ...and the site that jumps into AztBookPos. 11 bytes replaced: the two
    # `xor` pairs plus the `lea` they precede, which the routine re-issues.
    if ($BOOK_X -ne 0 -or $BOOK_Y -ne 0) {
        $ofBook  = Lin2File ([uint32]0x1646B)
        $expBook = $raw[$ofBook..($ofBook + 10)]
        $wantB   = [byte[]]@(0x31,0xC9,0x31,0xDB,0x8D,0x94,0x24,0x00,0x03,0x00,0x00)
        for ($k = 0; $k -lt $wantB.Length; $k++) {
            if ($expBook[$k] -ne $wantB[$k]) { throw "0x1646B is not 'xor ecx,ecx / xor ebx,ebx / lea edx,[esp+0x300]'" }
        }
        $relB = [int]$tAsm.Labels['AztBookPos'] - (0x1646B + 5)
        $repBook = [byte[]]@(0xE9) + [BitConverter]::GetBytes([int32]$relB) + @(0x90,0x90,0x90,0x90,0x90,0x90)
        if ($repBook.Length -ne $expBook.Length) { throw "book-centre replacement is the wrong length" }
        $patches += New-Patch -Name 'book-centre' -FileOffset $ofBook -Expect $expBook -Replace $repBook `
            -Note ("book page (640x480) loaded at ({0},{1}) instead of (0,0), so it centres on the {2}x{3} surface" -f `
                   $BOOK_X, $BOOK_Y, $SCREEN_W, $SCREEN_H)
    }

    # ---- movement distance, rescaled for the cap ----------------------------
    # Once the frame rate is PINNED, every remaining frame-tied constant can be
    # corrected statically -- no runtime gate, no percentage, just arithmetic.
    #
    # Movement is `pos += dir * k` per frame, and k is a plain float in obj2:
    #   [0x141800] = 16.0, read at 0x1D74D / 0x1D761   (2 sites)
    #   [0x1417FC] =  8.0, read at 0x1D901..0x1DD46    (8 sites, incl. wall slide)
    # Neither has a fixup on it.
    #
    # Scale by designFps/capFps so distance per SECOND is unchanged. 18.2065 is
    # the reference because it is the BIOS tick rate, which is what aztPeriod=100
    # pins the actors to -- so movement and animation share one reference and
    # stay coherent at any cap.
    $DESIGN_FPS = 18.2065
    $MOVE_SCALE = $DESIGN_FPS / $FRAME_CAP_FPS
    $OBJ2_FILE_M = 0x184A54
    foreach ($c in @(@{ at=0x141800; was=16.0; what='run' },
                     @{ at=0x1417FC; was=8.0;  what='walk / wall slide' })) {
        $om  = $OBJ2_FILE_M + ([int]$c.at - 0x140000)
        $exp = [byte[]][BitConverter]::GetBytes([single]$c.was)
        for ($k = 0; $k -lt 4; $k++) {
            if ($raw[$om+$k] -ne $exp[$k]) { throw ("movement constant 0x{0:X} is not {1}" -f $c.at, $c.was) }
        }
        $new = [single]($c.was * $MOVE_SCALE)
        $patches += New-Patch -Name ("move-scale-{0:X}" -f $c.at) -FileOffset $om `
            -Expect $exp -Replace ([byte[]][BitConverter]::GetBytes($new)) `
            -Note ("{0} distance per frame {1} -> {2:N4}, so speed matches {3:N1} fps at a {4} fps cap" -f `
                   $c.what, $c.was, $new, $DESIGN_FPS, $FRAME_CAP_FPS)
    }
    Write-Host ("move-scale: x{0:N4}  (16.0 -> {1:N4}, 8.0 -> {2:N4})" -f $MOVE_SCALE, (16*$MOVE_SCALE), (8*$MOVE_SCALE))
}

# ---- eye height ------------------------------------------------------------
# How tall the player is. 0x10EC8 creates the camera as a CHILD frame of
# [0x15213C] (`mov eax,[0x15213C] / call 0x3A150` -> stored at [0x152140]), and
# 0x1388A is the only place its offset inside that parent is ever set:
#
#   0x13888  push 0            ; x
#   0x1388A  push 0xC28C0000   ; y = -70.0f   <-- this
#   0x1389A  push 0            ; z
#   0x1389C  call 0x3EC20      ; SetPosition(camera, [0x15213C], x, y, z)
#
# so it is a true eye-height offset, not a spawn position: negative Y is up here,
# and the whole scene is built around that. -70.0 appears EXACTLY ONCE in the
# image, which is what makes this a one-immediate change rather than a hunt.
#
# Walking is ~291 units/second (16.0 per frame at 18.2 fps), so if running is
# about 4 m/s the scale is roughly 73 units per metre -- which puts the stock eye
# at under a metre. That matches "I feel way too short" rather well.
#
# The immediate is 0x1388B..0x1388E and carries no fixup; the one at 0x13891
# belongs to the `mov edx,[0x15213C]` that follows it, so the four bytes are ours
# alone. Published as a setting, so Set-EyeHeight.ps1 can retune an installed
# build without a rebuild.
#
# Collision is decided on X and Z (0x11E68 / 0x10180 take horizontal pairs), so
# raising this does not let you walk through anything -- the risk is cosmetic,
# clipping the view into a low ceiling.
$EYE_HEIGHT = [single](-85.0)
$EYE_STOCK  = [single](-70.0)
$EYE_AT     = [uint32]0x1388B
$ofEye  = Lin2File $EYE_AT
$expEye = [byte[]][BitConverter]::GetBytes($EYE_STOCK)
for ($k = 0; $k -lt 4; $k++) {
    if ($raw[$ofEye+$k] -ne $expEye[$k]) { throw "0x1388B is not the -70.0f camera height" }
}
$patches += New-Patch -Name 'eye-height' -FileOffset $ofEye `
    -Expect $expEye -Replace ([byte[]][BitConverter]::GetBytes($EYE_HEIGHT)) `
    -Note ("camera eye height {0} -> {1} (negative Y is up)" -f $EYE_STOCK, $EYE_HEIGHT)

# Invert mouse Y by default. g_invertY (0x1471DA) is read inside the mickey-look
# branch at 0x1D130 and toggled by F10, and it lives in INITIALISED data, so we
# just flip its starting value. Pure data, no code, and F10 still works at runtime.
$OBJ2_FILE   = 0x184A54
$invertYFile = $OBJ2_FILE + ([int]$g_invertY - 0x140000)
$patches += New-Patch -Name 'invert-mouse-y' -FileOffset $invertYFile `
    -Expect ([byte[]]@(0x00,0x00)) -Replace ([byte[]]@(0x01,0x00)) `
    -Note 'mouse Y inverted by default (F10 still toggles it in game)'

$i = 0
foreach ($bf in $BANNER_FILES) {
    $i++
    $patches += New-Patch -Name ("banner-$i") -FileOffset $bf `
        -Expect ([System.Text.Encoding]::ASCII.GetBytes($BANNER_TEXT)) `
        -Replace ([System.Text.Encoding]::ASCII.GetBytes($BANNER_NEW)) `
        -Note ("HUD boot banner -> '{0}' (pure data; visible proof the mod is live)" -f $BANNER_NEW.Trim())
}

# ---- map screen: load our backdrop instead of the disc's -------------------
#
# The dimmed instrument panel players see behind the map is BAKED into the map
# screen's backdrop image -- there is no runtime blit to disable. The image is
# D:\TEXTURES\MAPS\MAPBKGRD.PCX inside AZT.BIN, loaded at 0x1ECA6 by formatting
# "%smaps\mapbkgrd.pcx" with the first line of RESOURCE.CFG ("D:\TEXTURES\").
#
# We cannot rewrite a 500 MB CD image, so shorten the format string instead:
# dropping "%smaps\" leaves a bare filename, which resolves against the working
# directory (C:\AZRAEL). Build-HudArt.ps1 extracts the disc original, paints the
# panel band out and installs it there under that exact name.
#
# Removing the %s is safe: the prefix is still pushed, but sprintf is cdecl and
# the caller cleans all 12 bytes at 0x1ECBA, so an unused argument costs nothing.
#
# The replacement must fit the original INCLUDING its NUL, so it is padded back
# out to 20 bytes -- anything shorter would shift "maps.dat", which follows it.
$MAP_PATH_OLD = "%smaps\mapbkgrd.pcx`0"
$MAP_PATH_NEW = "mapbkgrd.pcx"
$mapOld = [System.Text.Encoding]::ASCII.GetBytes($MAP_PATH_OLD)
$mapNew = New-Object byte[] $mapOld.Length      # zero-filled: name + NUL padding
[Array]::Copy([System.Text.Encoding]::ASCII.GetBytes($MAP_PATH_NEW), $mapNew, $MAP_PATH_NEW.Length)
$patches += New-Patch -Name 'map-backdrop-path' -FileOffset 0x186304 `
    -Expect $mapOld -Replace $mapNew `
    -Note ("map backdrop path '{0}' -> '{1}' (loads AztMod's panel-free copy from C:\AZRAEL)" -f `
           $MAP_PATH_OLD.TrimEnd([char]0), $MAP_PATH_NEW)

# Frame hook. This block contains LE fixups at +3 and +13 which the loader
# rewrites at load time, so we route AROUND them:
#   +0    EB 0F      jmp +17
#   +2..+16          ORIGINAL bytes, now unreachable -- fixups land on dead data
#                    (+3 is also where AztDeltas reads the resolved obj2 pointer)
#   +17   E8 rel32   call AztFrameHook
#   +22..+24 90      pad; falls through to +25
$frameOff  = Lin2File $HOOK_FRAME
$frameOrig = $raw[$frameOff..($frameOff + $HOOK_FRAME_LEN - 1)]
$frameRepl = $frameOrig.Clone()
$frameRepl[0] = 0xEB
$frameRepl[1] = 0x0F
(CallRel32 ([uint32]($HOOK_FRAME + 17)) $asm.Labels['AztFrameHook']).CopyTo($frameRepl, 17)
$frameRepl[22] = 0x90; $frameRepl[23] = 0x90; $frameRepl[24] = 0x90
foreach ($fx in @(3, 13)) {
    for ($k = 0; $k -lt 4; $k++) {
        if ($frameRepl[$fx + $k] -ne $frameOrig[$fx + $k]) {
            throw ("hook-frame would overwrite fixup slot +{0}" -f ($fx + $k))
        }
    }
}
# Viewport injection probes. Every site is a 5-byte `call rel32` that Test-FixupsIn
# reports as "no fixups in range" -- an LE fixup landing inside a patched operand is
# rewritten by the loader and silently corrupts the patch. The build re-derives each
# site's ORIGINAL target from the file and refuses to proceed if it disagrees with the
# table, so a stale address cannot quietly send a probe to the wrong function.
if ($ENABLE_VIEW_INJECT) {
    for ($pi = 0; $pi -lt $INJ_SITES.Count; $pi++) {
        $site = [uint32]$INJ_SITES[$pi].At
        $off  = Lin2File $site
        $orig = $raw[$off..($off + 4)]
        if ($orig[0] -ne 0xE8) {
            throw ("inject probe {0}: expected E8 (call) at 0x{1:X5}, found 0x{2:X2}" -f $pi, $site, $orig[0])
        }
        $realTgt = [uint32]($site + 5 + [BitConverter]::ToInt32(([byte[]]$orig[1..4]), 0))
        if ($realTgt -ne [uint32]$INJ_SITES[$pi].Target) {
            throw ("inject probe {0} at 0x{1:X5}: file calls 0x{2:X5} but the table says 0x{3:X5}" -f `
                   $pi, $site, $realTgt, $INJ_SITES[$pi].Target)
        }
        $tgt = [uint32]$ovlAsm.Labels[("AztInjProbe{0}" -f $pi)]
        if ($tgt -lt $OVERLAY_BASE) {
            throw ("overlay label AztInjProbe{0} resolved to 0x{1:X}, below the overlay base" -f $pi, $tgt)
        }
        $patches += New-Patch -Name ("hook-inject-{0}" -f $pi) -FileOffset $off `
            -Expect $orig -Replace (CallRel32 $site $tgt) `
            -Note ("probe {0}: call 0x{1:X5} -> AztInjProbe{0} ({2}); band Y={3}" -f `
                   $pi, $realTgt, $INJ_SITES[$pi].Note, ($INJ_Y + $pi * $INJ_BAND_STEP))
    }
}

# Loading a save, routed through AztLoadHook so the visor re-boots afterwards. The site is
# the ONE caller of the function that fopen's SAVE%d.dat with "rb" -- found by resolving the
# format string's operand, then its two users ("wb" saves, "rb" loads), then that function's
# single caller. Verified against the file, so a stale address cannot redirect the wrong call.
if ($ENABLE_BOOT_SEQ -and $ENABLE_REBOOT_ON_LOAD) {
    $ldSite = [uint32]0x2CD63
    $ldOff  = Lin2File $ldSite
    $ldOrig = $raw[$ldOff..($ldOff + 4)]
    if ($ldOrig[0] -ne 0xE8) { throw ("load hook: expected E8 at 0x{0:X5}" -f $ldSite) }
    $ldReal = [uint32]($ldSite + 5 + [BitConverter]::ToInt32(([byte[]]$ldOrig[1..4]), 0))
    if ($ldReal -ne [uint32]0x4A994) {
        throw ("load hook at 0x{0:X5}: calls 0x{1:X5}, expected the save loader 0x4A994" -f $ldSite, $ldReal)
    }
    $ldTgt = [uint32]$ovlAsm.Labels['AztLoadHook']
    if ($ldTgt -lt $OVERLAY_BASE) { throw 'AztLoadHook resolved below the overlay base' }
    $patches += New-Patch -Name 'reboot-on-load' -FileOffset $ldOff `
        -Expect $ldOrig -Replace (CallRel32 $ldSite $ldTgt) `
        -Note ("load SAVE%d.dat -> AztLoadHook: the visor re-boots from {0:N2}s afterwards" -f ($BOOT_REBOOT_FROM/1e6))
}

# The reticle draws, routed through AztRetGateN so the boot overlay can hide them. Each is
# verified against the file the same way the inject probes are: the call's real target is
# read back and must match, so a stale address cannot silently redirect the wrong call.
if ($ENABLE_BOOT_SEQ -and $BOOT_HIDE_RETICLE) {
    for ($gi = 0; $gi -lt $BOOT_RET_SITES.Count; $gi++) {
        $g       = $BOOT_RET_SITES[$gi]
        $retSite = [uint32]$g.At
        $retOff  = Lin2File $retSite
        $retOrig = $raw[$retOff..($retOff + 4)]
        if ($retOrig[0] -ne 0xE8) {
            throw ("reticle gate: expected E8 (call) at 0x{0:X5}, found 0x{1:X2}" -f $retSite, $retOrig[0])
        }
        $retReal = [uint32]($retSite + 5 + [BitConverter]::ToInt32(([byte[]]$retOrig[1..4]), 0))
        if ($retReal -ne [uint32]$g.Target) {
            throw ("reticle gate at 0x{0:X5}: file calls 0x{1:X5}, expected 0x{2:X5}" -f $retSite, $retReal, $g.Target)
        }
        $sx = [array]::IndexOf($BOOT_RET_TARGETS, [int]$g.Target)   # which shared stub
        if ($sx -lt 0) { throw ("no AztRetGate stub for target 0x{0:X5}" -f $g.Target) }
        $retTgt = [uint32]$ovlAsm.Labels[("AztRetGate{0}" -f $sx)]
        if ($retTgt -lt $OVERLAY_BASE) { throw ("AztRetGate{0} resolved below the overlay base" -f $sx) }
        $patches += New-Patch -Name ("hook-reticle-{0:X5}" -f $retSite) -FileOffset $retOff `
            -Expect $retOrig -Replace (CallRel32 $retSite $retTgt) `
            -Note ("{0}: call 0x{1:X5} -> AztRetGate{2}, skipped while the boot overlay is up" -f `
                   $g.Note, $retReal, $sx)
    }
}
# The two calls inside the engine's own 3D block, routed through the host-render
# gates. See $ENABLE_HOST_RENDER. Each call's real target is read back out of the
# file and must match, so a stale address cannot silently redirect some other call
# -- and Test-FixupsIn reports both sites clean, which matters here because the
# `cmp` two instructions above them carries fixups at +3 and +11 and must not be
# touched.
if ($ENABLE_HOST_RENDER) {
    $supSites = @(
        @{ At = 0x14187; Target = 0x3F1B0; Stub = 'AztSupGate'; Note = 'scene pass -- off at aztSup3D >= 1' }
        @{ At = 0x14182; Target = 0x3F0D0; Stub = 'AztClrGate'; Note = 'viewport clear (callee-pops) -- off at aztSup3D >= 2' }
    )
    foreach ($s in $supSites) {
        $supSite = [uint32]$s.At
        $supOff  = Lin2File $supSite
        $supOrig = $raw[$supOff..($supOff + 4)]
        if ($supOrig[0] -ne 0xE8) {
            throw ("3D A/B gate: expected E8 (call) at 0x{0:X5}, found 0x{1:X2}" -f $supSite, $supOrig[0])
        }
        $supReal = [uint32]($supSite + 5 + [BitConverter]::ToInt32(([byte[]]$supOrig[1..4]), 0))
        if ($supReal -ne [uint32]$s.Target) {
            throw ("3D A/B gate at 0x{0:X5}: file calls 0x{1:X5}, expected 0x{2:X5}" -f $supSite, $supReal, $s.Target)
        }
        $supTgt = [uint32]$ovlAsm.Labels[$s.Stub]
        if ($supTgt -lt $OVERLAY_BASE) { throw ("{0} resolved below the overlay base" -f $s.Stub) }
        $patches += New-Patch -Name ("hook-sup3d-{0:X5}" -f $supSite) -FileOffset $supOff `
            -Expect $supOrig -Replace (CallRel32 $supSite $supTgt) `
            -Note ("host render: call 0x{0:X5} -> {1} ({2})" -f $supReal, $s.Stub, $s.Note)
    }
}
# The three calls INSIDE the scene pass, each routed through its own gate so the host
# can suppress them independently and find which one is the renderer and which one is
# the simulation. See $ENABLE_SCENE_SPLIT.
if ($ENABLE_SCENE_SPLIT) {
    $spSites = @(
        @{ At = 0x3F209; Target = 0x5B820; Stub = 'AztScenePart2'; Note = 'result is tested; skip returns al=0' }
    )
    foreach ($s in $spSites) {
        $spSite = [uint32]$s.At
        $spOff  = Lin2File $spSite
        $spOrig = $raw[$spOff..($spOff + 4)]
        if ($spOrig[0] -ne 0xE8) { throw ("scene split: expected E8 at 0x{0:X5}, found 0x{1:X2}" -f $spSite, $spOrig[0]) }
        $spReal = [uint32]($spSite + 5 + [BitConverter]::ToInt32(([byte[]]$spOrig[1..4]), 0))
        if ($spReal -ne [uint32]$s.Target) {
            throw ("scene split at 0x{0:X5}: file calls 0x{1:X5}, expected 0x{2:X5}" -f $spSite, $spReal, $s.Target)
        }
        $spTgt = [uint32]$ovlAsm.Labels[$s.Stub]
        if ($spTgt -lt $OVERLAY_BASE) { throw ("{0} resolved below the overlay base" -f $s.Stub) }
        $patches += New-Patch -Name ("hook-scenepart-{0:X5}" -f $spSite) -FileOffset $spOff `
            -Expect $spOrig -Replace (CallRel32 $spSite $spTgt) `
            -Note ("scene split: call 0x{0:X5} -> {1} ({2})" -f $spReal, $s.Stub, $s.Note)
    }
}
if ($ENABLE_SCENE_SPLIT) {
    # 0x551FE: `cmp byte [ebx+0x45],0 / jz 0x5521A` -- six bytes, no fixup (neither operand
    # is an address), and the only branches that land on it land on its first byte.
    $vgAt   = [uint32]0x551FE
    $vgWant = [byte[]]@(0x80,0x7B,0x45,0x00,0x74,0x16)
    $vgOf   = Lin2File $vgAt
    $vgExp  = $raw[$vgOf..($vgOf + 5)]
    if ((Hex $vgExp) -ne (Hex $vgWant)) { throw ("vel-gate: 0x{0:X} is not the rotation test -- found {1}" -f $vgAt, (Hex $vgExp)) }
    $vgRep = New-Object byte[] 6
    (JmpRel32 $vgAt $ovlAsm.Labels['AztVelGate']).CopyTo($vgRep, 0); $vgRep[5] = 0x90
    $patches += New-Patch -Name 'vel-gate' -FileOffset $vgOf -Expect $vgExp -Replace $vgRep `
        -Note 'built-in object velocity/rotation steps on the 18.2 Hz tick when the host asks (aztSceneParts bit 3)'
    Write-Host ("vel gate: 0x{0:X} -> AztVelGate at 0x{1:X}" -f $vgAt, $ovlAsm.Labels['AztVelGate'])

    # 0x148F7: `call 0x2D470`, the frame loop's one call into the event scripts and their
    # queued rotations. A relative call, so no fixup, and nothing branches into its middle.
    # (It is the call INSIDE 0x2D470 that is replaced, not the frame loop's call to it at
    # 0x148F7: what follows that inner call, 0x2D478, draws the hover text and must run
    # every frame. See AztEventGate.)
    $egAt   = [uint32]0x2D470
    $egOf   = Lin2File $egAt
    $egExp  = $raw[$egOf..($egOf + 4)]
    if ($egExp[0] -ne 0xE8) { throw ("event-gate: expected a call at 0x{0:X}, found {1}" -f $egAt, (Hex $egExp)) }
    $egReal = [uint32]($egAt + 5 + [BitConverter]::ToInt32(([byte[]]$egExp[1..4]), 0))
    if ($egReal -ne [uint32]0x1CBD4) { throw ("event-gate: 0x{0:X} calls 0x{1:X}, expected 0x1CBD4" -f $egAt, $egReal) }
    $patches += New-Patch -Name 'event-gate' -FileOffset $egOf -Expect $egExp `
        -Replace (CallRel32 $egAt $ovlAsm.Labels['AztEventGate']) `
        -Note 'queued door rotations (0x1CBD4) step on the 18.2 Hz tick when the host asks (aztSceneParts bit 3); the status line after it runs every frame'
    Write-Host ("event gate: 0x{0:X} -> AztEventGate at 0x{1:X}" -f $egAt, $ovlAsm.Labels['AztEventGate'])

    # 0x12283: `fild dword [esp+0x8C]`, the first instruction of the ground test's
    # standing-or-falling decision. Seven bytes, esp-relative (no fixup), reached only by
    # falling through from 0x1227C. See AztFallGate.
    $fgAt   = [uint32]0x12283
    $fgWant = [byte[]]@(0xDB,0x84,0x24,0x8C,0x00,0x00,0x00, 0xDE,0xD9, 0xDF,0xE0, 0x9E, 0x76,0x63)
    $fgOf   = Lin2File $fgAt
    $fgSeen = $raw[$fgOf..($fgOf + 13)]
    if ((Hex $fgSeen) -ne (Hex $fgWant)) { throw ("fall-gate: 0x{0:X} is not the falling test -- found {1}" -f $fgAt, (Hex $fgSeen)) }
    $fgRep = New-Object byte[] 7
    (CallRel32 $fgAt $ovlAsm.Labels['AztFallGate']).CopyTo($fgRep, 0); $fgRep[5] = 0x90; $fgRep[6] = 0x90
    $patches += New-Patch -Name 'fall-gate' -FileOffset $fgOf -Expect ([byte[]]$fgSeen[0..6]) -Replace $fgRep `
        -Note 'gravity (the falling step of the ground test) runs on the 18.2 Hz tick when the host asks (aztSceneParts bit 3)'
    Write-Host ("fall gate: 0x{0:X} -> AztFallGate at 0x{1:X}" -f $fgAt, $ovlAsm.Labels['AztFallGate'])
}
$patches += New-Patch -Name 'hook-frame' -FileOffset $frameOff `
    -Expect $frameOrig -Replace $frameRepl `
    -Note 'per-frame mouselook gate -> AztFrameHook (routed around LE fixups at +3/+13)'

# Left mouse must not walk you forward. The stock condition is
#   forward = forwardKey OR (mouselook AND lmbHeld AND NOT combat)
# and `cmp word [g_lmbHeld],0` at 0x1D705 carries a fixup, so we patch the
# following branch instead: `jz 0x1DAA1` -> `jmp 0x1DAA1`, which drops the whole
# lmbHeld arm. g_lmbHeld (0x182DA6) has exactly one consumer -- this gate -- so
# nothing else changes. Unconditional by design: F2 does not restore it.
$lmbOff  = Lin2File $HOOK_LMBFWD
$lmbRel  = [int64]0x1DAA1 - ([int64]$HOOK_LMBFWD + 5)
$lmbU    = [uint32]($lmbRel -band [int64]4294967295)
$patches += New-Patch -Name 'lmb-no-forward' -FileOffset $lmbOff `
    -Expect ([byte[]]@(0x0F,0x84,0x8E,0x03,0x00,0x00)) `
    -Replace ([byte[]]@(0xE9, ($lmbU -band 0xFF), (($lmbU -shr 8) -band 0xFF), (($lmbU -shr 16) -band 0xFF), (($lmbU -shr 24) -band 0xFF), 0x90)) `
    -Note 'left mouse no longer walks forward (it fires the weapon in combat mode)'

# ---- enlarge the 3D viewport ----------------------------------------------
# All of these are plain `mov reg, imm32` / `sub reg, imm8`, every one fixup-free
# (verified with Test-FixupsIn). Addresses were enumerated by disassembling for
# the exact immediates rather than byte-scanning, so each New-Patch below also
# asserts the original value before writing.
# Locates the immediate inside an instruction rather than assuming an encoding.
# The viewport constants appear as mov/push/imul/add/sub/cmp with 1, 2 and 3 byte
# opcodes, so hard-coding "+1" only worked for `mov reg, imm32` and silently
# mis-patched everything else.
function Patch-Imm32 {
    param([string]$Name, [uint32]$Lin, [int]$Old, [int]$New, [string]$Note, [int]$Size = 4)
    $base = Lin2File $Lin
    $exp  = [BitConverter]::GetBytes([uint32]$Old)[0..($Size-1)]
    $rep  = [BitConverter]::GetBytes([uint32]$New)[0..($Size-1)]
    $at   = -1
    # Window is 1..5: an immediate never starts later than +5 (worst case is a
    # 3-byte opcode+modrm+disp8 before an imm16). Searching further once matched
    # the NEXT instruction's identical immediate -- e.g. `mov ebx,0x119` followed
    # by `push 0x119` at 0x15586.
    for ($k = 1; $k -le 5; $k++) {
        $m = $true
        for ($j = 0; $j -lt $Size; $j++) { if ($raw[$base + $k + $j] -ne $exp[$j]) { $m = $false; break } }
        if ($m) { if ($at -ge 0) { throw ("{0}: ambiguous immediate" -f $Name) }; $at = $base + $k }
    }
    if ($at -lt 0) { throw ("{0}: value 0x{1:X} not found at 0x{2:X}" -f $Name, $Old, $Lin) }
    return (New-Patch -Name $Name -FileOffset $at -Expect ([byte[]]$exp) -Replace ([byte[]]$rep) -Note $Note)
}

# NOTE: the movie CENTRING box at 0x20CF5/0x20D14 is already repointed at the screen size
# by the scr-h-/scr-w- family, so it needs nothing here. Adding a second patch for it is
# what Assert-NoOverlap exists to catch.
# ---- MOVIE FRAME BUFFER -----------------------------------------------------
# THE HARD LIMIT ON MOVIE SIZE. The IAnimation constructor mallocs a FIXED 400,000-byte
# block and stores it at 0x162FEC; DecodeAnimationFrame reads every frame's decompressed
# payload straight into it, with no bounds check:
#     0x20360  mov ebx, 0x61A80     ; 400,000
#     0x2036A  mov eax, 0x61A80     ; 400,000  -> malloc -> [0x162FEC]
# 400,000 is just over the largest movie the game ships (640x480 = 307,200), so it was
# sized for the shipped set and nothing more. A 1024x768 frame is 786,432 bytes plus its
# chunk headers -- nearly DOUBLE -- and writing it corrupts the heap. The game keeps
# running, but every allocation after it fails: the 3D textures and the HUD surfaces come
# back empty, which looks like "the game loaded but the viewport and HUD are blank".
#
# Sized from the screen, because a full-screen movie is exactly a screen-sized frame, plus
# a page for the palette and chunk headers.
if ($ENABLE_HIRES) {
    # + 32 KB, NOT the screen size alone. Frame 0 carries more than the picture:
    #     w*h      the keyframe            (1024x768 = 786,432)
    #     768+16   the palette chunk
    #     16,384   the AUDIO PRIMING chunk, on every movie that has sound (+16)
    #     16       the keyframe's own chunk header
    # which is 803,632 for a full-screen movie with audio. A first attempt used +8,192 and
    # overflowed by 9,008 bytes on exactly one file -- the 50-frame INTRO sting, the only
    # full-screen movie that also has audio. Silent MINDLOGO fitted with 7,392 to spare, so
    # the mistake looked like it worked right up until the one case that had both.
    $MOVIE_BUF = $SCREEN_W * $SCREEN_H + 32768
    $patches += Patch-Imm32 -Name 'movie-buf-size'  -Lin 0x2036A -Old 400000 -New $MOVIE_BUF `
                -Note ("movie frame buffer 400,000 -> {0:N0} bytes (allocation)" -f $MOVIE_BUF)
    $patches += Patch-Imm32 -Name 'movie-buf-size2' -Lin 0x20360 -Old 400000 -New $MOVIE_BUF `
                -Note ("movie frame buffer 400,000 -> {0:N0} bytes (surface hint)" -f $MOVIE_BUF)
}
if ($ENABLE_BIG_VIEW) {
# HEIGHT ONLY. The width is deliberately left at 552 so the scanline STRIDE is
# untouched -- `imul reg,0x228` / `add esi,0x228` appear at a dozen sites and are
# where the real danger is. Growing only downward still gains a lot once the
# panel is scaled, and it exercises the same constant family.
#
# The family that must move together:
#   H        282 -> $VIEW_H        surface/device height
#   H-1      281 -> $VIEW_H-1      clip limits and line draws
#   H/2      141 -> $VIEW_H/2      viewport centre (func 0x165F4 only)
#   W*H   0x26010 -> W*$VIEW_H     FRAMEBUFFER BYTE SIZE -- the one that was
#                                  missed in v0.7.0 and overran the heap by 48 KB
foreach ($s in @(0x10E18,0x10F02,0x10F4C,0x10FB4,0x11043,0x112A4,0x1133E,0x117E1,
                 0x14260,0x1432B,0x14364,0x1660E,0x169EE,0x17865,0x17941,0x17984)) {
    $patches += Patch-Imm32 -Name ("view-h-{0:X}" -f $s) -Lin $s -Old $VIEW_H_OLD -New $VIEW_H `
        -Note ("3D viewport height {0} -> {1}" -f $VIEW_H_OLD, $VIEW_H)
}
foreach ($s in @(0x117A2,0x145D7,0x146D3,0x15586,0x1558B,0x155A6,0x15614,0x15619,
                 0x15634,0x15682,0x15687,0x1569A)) {
    $patches += Patch-Imm32 -Name ("view-h1-{0:X}" -f $s) -Lin $s -Old ($VIEW_H_OLD-1) -New ($VIEW_H-1) `
        -Note 'viewport height-1 (clip limit / line extent)'
}
foreach ($s in @(0x166A6,0x1673D,0x16765,0x16845,0x169E9,0x16A2A)) {
    $patches += Patch-Imm32 -Name ("view-hc-{0:X}" -f $s) -Lin $s -Old ([int]($VIEW_H_OLD/2)) -New ([int]($VIEW_H/2)) `
        -Note 'viewport vertical centre'
}
# this one stores a 16-bit immediate
$patches += Patch-Imm32 -Name 'view-hc-169F5' -Lin 0x169F5 -Old ([int]($VIEW_H_OLD/2)) -New ([int]($VIEW_H/2)) -Size 2 -Note 'viewport vertical centre (imm16)'
foreach ($s in @(0x10E2C,0x14258,0x167CA,0x16865,0x169FC,0x17843)) {
    $patches += Patch-Imm32 -Name ("view-bytes-{0:X}" -f $s) -Lin $s `
        -Old ($VIEW_W_OLD * $VIEW_H_OLD) -New ($VIEW_W * $VIEW_H) `
        -Note ("framebuffer byte size {0} -> {1}" -f ($VIEW_W_OLD*$VIEW_H_OLD), ($VIEW_W*$VIEW_H))
}

# ---- WIDTH -----------------------------------------------------------------
# Only emitted when the width actually changes. This is the dangerous family:
# 552 doubles as the scanline STRIDE, so it appears in imul/add/sub arithmetic
# that walks the framebuffer. Miss one and pixels land on the wrong rows.
if ($VIEW_W -ne $VIEW_W_OLD) {
    # plain width: surface/device creation and bounds checks
    foreach ($s in @(0x10E1D,0x10F1B,0x10F55,0x10FC3,0x11067,0x112C6,0x1135C,0x117C3,
                     0x11796,0x14217,0x157FB,0x16624,0x16819,0x169D4,0x16AF3,0x1781F)) {
        $patches += Patch-Imm32 -Name ("view-w-{0:X}" -f $s) -Lin $s -Old $VIEW_W_OLD -New $VIEW_W `
            -Note ("3D viewport width {0} -> {1}" -f $VIEW_W_OLD, $VIEW_W)
    }
    # the SAME constant used as a stride: `imul reg,552` indexes a scanline,
    # `add/sub esi,552` steps to the next one
    foreach ($s in @(0x10953,0x1291F,0x14270,0x1427C,0x14304,0x1433B,0x14346,0x14374,
                     0x167FE,0x1683B,0x1788F,0x17916,0x17966)) {
        $patches += Patch-Imm32 -Name ("view-stride-{0:X}" -f $s) -Lin $s -Old $VIEW_W_OLD -New $VIEW_W `
            -Note 'framebuffer scanline stride'
    }
    # Offsets DERIVED from the stride: `row * 552` constants that index into the
    # framebuffer. These are the family members that took longest to find,
    # because they do not look like the stride at all.
    #
    # 0x10947/0x10959 are a loop that grabs a 180x40 thumbnail out of the view:
    # it walks byte offsets from 71*552 to 111*552 stepping by the stride. With
    # the stride at 640 but the terminator left at 111*552, `cmp esi,0xEF58` is
    # never equal, the loop never exits, and it copies its way off the end of
    # both the framebuffer and the heap -- which is the "Illegal write to
    # <top of RAM>" flood that survived the HUD-overlay fix.
    #
    # Found by scanning every immediate in the image for exact multiples of 552.
    # Anything that appears here in future is the same class of bug.
    foreach ($o in @(@(0x10947,71), @(0x10959,111), @(0x16B91,27), @(0x16C23,27), @(0x16C12,208))) {
        $patches += Patch-Imm32 -Name ("view-rowoff-{0:X}" -f $o[0]) -Lin $o[0] `
            -Old ($o[1] * $VIEW_W_OLD) -New ($o[1] * $VIEW_W) `
            -Note ("framebuffer offset, row {0} ({1} -> {2})" -f $o[1], ($o[1]*$VIEW_W_OLD), ($o[1]*$VIEW_W))
    }
    foreach ($s in @(0x145B6,0x1468C,0x15581,0x155A1,0x1560F,0x1562F,0x1564C,0x15666)) {
        $patches += Patch-Imm32 -Name ("view-w1-{0:X}" -f $s) -Lin $s -Old ($VIEW_W_OLD-1) -New ($VIEW_W-1) `
            -Note 'viewport width-1 (clip limit / line extent)'
    }
    foreach ($s in @(0x166AB,0x16742,0x16780,0x16834,0x1685C,0x169CF,0x16A0F)) {
        $patches += Patch-Imm32 -Name ("view-wc-{0:X}" -f $s) -Lin $s `
            -Old ([int]($VIEW_W_OLD/2)) -New ([int]($VIEW_W/2)) -Note 'viewport horizontal centre'
    }
    $patches += Patch-Imm32 -Name 'view-wc-169DB' -Lin 0x169DB `
        -Old ([int]($VIEW_W_OLD/2)) -New ([int]($VIEW_W/2)) -Size 2 -Note 'viewport horizontal centre (imm16)'
}
# RenderMorphics Z-BUFFER. A single fixed allocation of W*H*2 (16-bit depth)
# inside the device creator at 0x28157, which all three SetRenderResolution
# paths call. Missing it is what left the rasterizer writing past the depth
# buffer and faulting on a bad pointer in v0.7.2.
$patches += Patch-Imm32 -Name 'view-zbuf-28168' -Lin 0x28168 `
    -Old ($VIEW_W_OLD * $VIEW_H_OLD * 2) -New ($VIEW_W * $VIEW_H * 2) `
    -Note ("z-buffer bytes {0} -> {1}" -f ($VIEW_W_OLD*$VIEW_H_OLD*2), ($VIEW_W*$VIEW_H*2))
# blit origin (44,49) -> ($VIEW_X,$VIEW_Y). Sites were matched on the full
# pattern `mov ebx,0x31 / mov edx,0x2C / mov eax,0x152150 / call Blit` so that
# unrelated uses of 44 and 49 elsewhere in the HUD are not touched.
foreach ($pair in @(
    @(0x150F6,0x150FB), @(0x15263,0x15268), @(0x152AE,0x152B3), @(0x15387,0x1538C),
    @(0x15475,0x1547A), @(0x1584C,0x15851), @(0x16756,0x1675B), @(0x1678E,0x16793),
    @(0x16B6E,0x16B73), @(0x16C2D,0x16C32), @(0x16F0F,0x16F14), @(0x16F89,0x16F8E),
    @(0x17267,0x1726C), @(0x173DB,0x173E0), @(0x17427,0x1742C), @(0x174FA,0x174FF),
    @(0x175DF,0x175E4), @(0x2FE6E,0x2FE73))) {
    if ($VIEW_Y -ne $VIEW_Y_OLD) { $patches += Patch-Imm32 -Name ("view-y-{0:X}" -f $pair[0]) -Lin $pair[0] -Old $VIEW_Y_OLD -New $VIEW_Y -Note 'viewport blit Y' }
    if ($VIEW_X -ne $VIEW_X_OLD) { $patches += Patch-Imm32 -Name ("view-x-{0:X}" -f $pair[1]) -Lin $pair[1] -Old $VIEW_X_OLD -New $VIEW_X -Note 'viewport blit X' }
}
# screen -> viewport conversion used for 3D picking (`sub edx,0x2C` / `sub eax,0x31`)
foreach ($s in @(@(0x11771,$VIEW_X_OLD,$VIEW_X), @(0x11774,$VIEW_Y_OLD,$VIEW_Y)) | Where-Object { $_[1] -ne $_[2] }) {
    $o = (Lin2File $s[0]) + 2           # skip opcode + modrm
    $patches += New-Patch -Name ("view-pick-{0:X}" -f $s[0]) -FileOffset $o `
        -Expect ([byte[]]@([byte]$s[1])) -Replace ([byte[]]@([byte]$s[2])) `
        -Note 'screen->viewport offset for 3D picking'
}
# ---- the mouse CONFINE-TO-VIEWPORT rect -----------------------------------
#
# 0x13240 is a toggle on the flag [0x14721C]:
#   flag == 0 -> 0x132AF, full-screen rect (0,0,639,479)  <- scr-w1/h1 patched
#   flag != 0 -> 0x1324D, confine the pointer to the 3D VIEWPORT
#
# The second branch was missed entirely, and it is the LAST of the seven callers
# of the range setter 0x35939 still carrying stock coordinates. Register roles
# (Watcom: eax, edx, ebx, ecx then stack) confirmed by tracing the two calls --
# 0x3561D and 0x35A45 both save/restore edx, ebx and ecx, so the values set
# before them survive into the rect build at 0x13281:
#
#   0x13252 edx=240 \ cursor position for this mode
#   0x13261 eax=320 /
#   0x13257 ecx=595 -> rect.right    0x13266 ebx=49  -> rect.top
#   0x13275 edx=44  -> rect.left     0x13270 push 330 -> rect.bottom
#
# (44, 49, 595, 330) is exactly the stock viewport, so this scales with it.
$VIEW_R = $VIEW_X + $VIEW_W - 1
$VIEW_B = $VIEW_Y + $VIEW_H - 1
foreach ($m in @(
    @{ n='confine-l'; at=0x13275; old=$VIEW_X_OLD;                     new=$VIEW_X; t='rect left' },
    @{ n='confine-t'; at=0x13266; old=$VIEW_Y_OLD;                     new=$VIEW_Y; t='rect top' },
    @{ n='confine-r'; at=0x13257; old=($VIEW_X_OLD+$VIEW_W_OLD-1);     new=$VIEW_R; t='rect right' },
    @{ n='confine-b'; at=0x13270; old=($VIEW_Y_OLD+$VIEW_H_OLD-1);     new=$VIEW_B; t='rect bottom' },
    @{ n='confine-cx'; at=0x13261; old=[int]($SCREEN_W_OLD/2); new=[int]($SCREEN_W/2); t='cursor X' },
    @{ n='confine-cy'; at=0x13252; old=[int]($SCREEN_H_OLD/2); new=[int]($SCREEN_H/2); t='cursor Y' }
) | Where-Object { $_.old -ne $_.new }) {
    $patches += Patch-Imm32 -Name $m.n -Lin $m.at -Old $m.old -New $m.new `
        -Note ("mouse confined to the viewport: {0} {1} -> {2}" -f $m.t, $m.old, $m.new)
}

}   # end if ($ENABLE_BIG_VIEW)

# ---- HUD widgets stranded inside the enlarged viewport ---------------------
# Three live widgets are drawn at hard-coded SCREEN coordinates that used to be
# inside the instrument panel. Now the panel is half size and the view reaches
# y=398, so they float in the middle of the 3D scene -- this is the "partial UI
# image fixed in the viewport". They are not decoration:
#
#   0x163A40  automap      103x69  at (70,345)  -- 3D-rendered level map
#   0x163A10  gauge frame  105x15  at (320,357) -- drawn via 0x34C40
#   0x163A22  gauge fill   105x15  at (320,357) -- ecx = fill amount, /1000
#   0x152AD4  scan readout 170x100 at (470,380) -- the "Unknown Object.." box
#
# Sizes come from the create calls (0x37B04 / 0x287DA / 0x37AC8, edx=w ebx=h),
# not from guessing at the artwork.
#
# They are relocated into the HUD strip below the viewport: automap into the
# left gutter, gauge onto the shrunken panel, scan box into the right gutter.
# Only the scan box is resized, because 100 rows will not fit under y=399; the
# automap keeps its stock size, since shrinking a 3D-rendered surface would
# crop the map rather than scale it.
if ($ENABLE_PANEL_RESCALE) {
    # automap keeps its stock 103x69 and is centred in the left gutter;
    # the scan box is resized to fill the right gutter exactly.
    $MAP_X_OLD  = 70;  $MAP_Y_OLD  = 345
    # Tucked flush against the panel's left edge and centred in the panel band, so
    # it reads as part of the HUD instead of floating in the gutter. Kept at its
    # stock 103x69: it is invback2.pcx plus a runtime list of notes/items, and the
    # list does not scale with the window, so shrinking it would cost legibility.
    # The whole notes/inventory HOUSING is copied 1:1 into the left gutter by
    # Build-HudArt.ps1 -- window, bezel and the two up/down buttons -- rather than
    # scaled with the panel. These numbers MUST match the ones there.
    #
    # Cluster = the window (70..172) plus the buttons out to 193, i.e. 124x69. The
    # gutter is $PANEL_LEFT_NEW wide and the band $PANEL_H_NEW tall (144x89 at
    # 0.55), so a 10px bezel each side lands exactly on the gutter.
    # The source region is PINNED to the window's click-zone origin, not centred on
    # the cluster. The game's hit test (0x2C462) treats (50,340) -- 20 left and 5
    # above the window -- as local (0,0) and converts a click with `x - 50`, so that
    # origin has to stay on screen. Centring the housing put it at -10, which cannot
    # even be encoded. Starting the copy exactly there maps it to (0, panel top):
    # non-negative by construction, and the numbers stay exact with no clamping.
    $INV_CX0 = 70; $INV_CY0 = 345; $INV_CX1 = 193; $INV_CY1 = 413   # window + both buttons
    $INV_H   = $PANEL_H_NEW
    # THE DELTA IS THE INVARIANT, not the edges. +62 is what puts the housing over
    # the panel's own shrunken copy of this same lens (the reason the inventory
    # appeared twice) and keeps MAP_X at 132, so the click origin stays at 112.
    # Widening the copy therefore moves BOTH edges and changes nothing else.
    # Left edge: the lens artwork starts around x=38-48 depending on the row, so
    # cutting at 50 clipped it. 28 takes the whole lens plus a few pixels of the
    # dark border, giving a clean edge instead of a slice through the gradient.
    # Right edge: the buttons end at 193; +4 of margin, and the destination must
    # still clear the first real panel control at x=261.
    $INV_SRC_X = 28
    $INV_SRC_R = 197
    $INV_SRC_Y = 340           # = HOT_MAP_Y_OLD
    $INV_W     = $INV_SRC_R - $INV_SRC_X + 1
    $INV_DX  = 62
    # THE LAYOUT IS DESIGNED IN 640x480 AND THEN SCALED. The housing sits at
    # (90, 391) with the panel top at 391 in that design space; Hi() carries it to
    # whatever resolution is selected, and the art generator scales the copy by
    # the same factor, so bezel and window stay registered at any size.
    $INV_DST_X = Hi ($INV_SRC_X + $INV_DX)         # 90 -> 113 at 800x600
    $INV_W_DST = Hi $INV_W                         # the copy scales with the screen
    $INV_DY    = $PANEL_TOP_NEW - (Hi $INV_SRC_Y)
    if ($INV_CX0 -lt $INV_SRC_X -or $INV_CX1 -gt $INV_SRC_R -or $INV_CY1 -ge $INV_SRC_Y + (480 - $PANEL_TOP_OLD)) {
        throw "inventory housing source region does not contain the window and buttons"
    }
    # The first real panel control is at stock x=261, which scales with everything.
    if ($INV_DST_X + $INV_W_DST -gt (Hi 261)) { throw "housing would cover the panel controls at x=261" }
    if ($INV_DST_X -lt 0) { throw "housing would start off the left edge" }
    # The window itself rides the same delta, so it stays registered to its bezel.
    $MAP_X  = Hi (70  + $INV_DX)                   # 132 -> 165
    $MAP_Y  = Hi (345 + 51)                        # 396 -> 495, i.e. panel top + 6
    $BAR_X_OLD  = 320; $BAR_Y_OLD  = 357
    $BAR_X  = To-PanelX 320
    $BAR_Y  = To-PanelY 357
    $SCAN_X_OLD = 470; $SCAN_Y_OLD = 380;  $SCAN_W_OLD = 170; $SCAN_H_OLD = 100
    $SCAN_X = $PANEL_RIGHT_NEW + 1
    $SCAN_Y = $PANEL_TOP_NEW
    $SCAN_W = $SCREEN_W - $SCAN_X
    $SCAN_H = $PANEL_H_NEW

    # ---- THE ARTWORK WINS ---------------------------------------------------
    # Everything above derives the widget positions from the STOCK layout scaled
    # up. With a reskin that is backwards: the panel art decides where the
    # recesses are, and the engine has to be moved onto them. Build-HudSkin.ps1
    # measures the eight registration blocks out of the render and writes them to
    # art\hud-layout.json; this overrides the derived values with the measured
    # ones whenever that file exists.
    #
    # Regions are identified by SHAPE, not by the order they were found, so a
    # re-render that shifts things cannot silently swap the automap for the scan
    # readout and leave the game drawing into the wrong hole.
    $layoutFile = Join-Path $PSScriptRoot '..\art\hud-layout.json'
    if (Test-Path $layoutFile) {
        $L = Get-Content $layoutFile -Raw | ConvertFrom-Json
        if ($L.panelTop -ne $PANEL_TOP_NEW -or $L.screenW -ne $SCREEN_W) {
            throw "art\hud-layout.json is for a $($L.screenW)-wide panel at top $($L.panelTop); this build is $SCREEN_W / $PANEL_TOP_NEW. Re-run Build-HudSkin.ps1."
        }
        $rg = @($L.regions)
        if ($rg.Count -ne 8) { throw "hud-layout.json has $($rg.Count) regions, expected 8" }
        $sy = { param($r) $r.y + $PANEL_TOP_NEW }            # panel-local -> screen

        $scanR  = $rg | Where-Object { $_.x -gt ($SCREEN_W/2) } | Sort-Object { -($_.w*$_.h) } | Select-Object -First 1
        $mapR   = $rg | Where-Object { $_.x -lt ($SCREEN_W/2) } | Sort-Object { -($_.w*$_.h) } | Select-Object -First 1
        # IDENTIFY BY ASPECT, NOT BY ABSOLUTE SIZE. These two tests used to read
        # `h -le 14` and `w -lt 20`, which are the pixel sizes the regions happen
        # to have at one resolution -- at 1280x1024 the same artwork measures
        # 163x18 and 23 wide, and both tests failed on unchanged geometry. Aspect
        # ratio is the actual shape and survives any panel scale:
        #   gauge  163x18 -> 9.1 wide      (every other region is under 2.1)
        #   ctrl    23x46 -> 2.0 tall      (every other region is under 0.6)
        $gaugeR = $rg | Where-Object { ($_.w / $_.h) -ge 4.0 } | Select-Object -First 1
        $ctrl   = @($rg | Where-Object { ($_.h / $_.w) -ge 1.5 } | Sort-Object y)
        $acts   = @($rg | Where-Object { $_ -ne $scanR -and $_ -ne $mapR -and $_ -ne $gaugeR -and $ctrl -notcontains $_ } | Sort-Object y)
        foreach ($chk in @(@('scan',$scanR),@('automap',$mapR),@('gauge',$gaugeR))) {
            if (-not $chk[1]) { throw "could not identify the $($chk[0]) region in hud-layout.json" }
        }
        if ($ctrl.Count -ne 2) { throw "expected 2 narrow control regions, found $($ctrl.Count)" }
        if ($acts.Count -ne 3) { throw "expected 3 action-button regions, found $($acts.Count)" }

        # CENTRE THE CONTENT IN THE WINDOW. The engine draws the map / inventory
        # at this origin and the content is a fixed 103x69 (INVBACK2.PCX; the
        # stock map rect is 102x68), but the artwork's window is 132x77. Using
        # the window's own top-left left it hard against the top-left corner with
        # all the slack on the right and bottom. The window RECT stays the full
        # 132x77 for the hot spot -- only the draw origin is inset.
        # THE CONTENT FILLS THE RECESS NOW, so there is nothing to centre. It used
        # to be centred because INVBACK2.PCX ships 103x69 -- exactly the stock
        # layout's window -- and the reskin's recess is bigger, which left a band
        # of bare recess all round it. Build-HudInv.ps1 stretches the art to the
        # recess instead, and it is drawn at the corner.
        $INV_CONTENT_W = $mapR.w; $INV_CONTENT_H = $mapR.h
        $MAP_WIN_X = $mapR.x; $MAP_WIN_Y = & $sy $mapR
        $MAP_X = $MAP_WIN_X
        $MAP_Y = $MAP_WIN_Y
        $BAR_X  = $gaugeR.x; $BAR_Y  = & $sy $gaugeR
        $SCAN_X = $scanR.x;  $SCAN_Y = & $sy $scanR
        $SCAN_W = $scanR.w;  $SCAN_H = $scanR.h
        # The widescreen panel's health well is its own width, not the old art's 136 px
        # (Build-HudWide.ps1 writes it): the ceiling is the well this art actually has.
        if ($L.PSObject.Properties['gaugeWellW']) { $GAUGE_W_MAX = [int]$L.gaugeWellW }
        # The log box is now the panel's right-hand well, so the text surface has
        # to be sized to it rather than to a fraction of the stock box.
        if ($ENABLE_LOG_IN_PANEL) {
            $TEXTBOX_W = $SCAN_W - 2*$LOG_INSET
            # TWO HEIGHTS, AND THEY ARE NOT THE SAME NUMBER.
            #   $LOG_WIN_H  what you can SEE -- the well in the panel art. This is
            #               what the hot spot has to match.
            #   $TEXTBOX_H  the SURFACE the text is rendered into, taller by the
            #               scrollback. Never use it for anything on screen.
            $LOG_WIN_H = $SCAN_H - 2*$LOG_INSET
            # The rows between the viewport's bottom edge and the top of the well.
            # The box claims them so the expanded state cannot leave a residue in
            # them -- see the box blob for why that is the fix rather than a repair.
            $BOX_LIP     = $SCAN_Y - ($VIEW_Y + $VIEW_H)
            if ($BOX_LIP -lt 0) { throw "the readout well ($SCAN_Y) starts above the viewport's bottom edge" }
            # THE FRAME IS A SEPARATE, LARGER SURFACE THAN THE TEXT.
            #
            # The first attempt made one surface the size of the whole well and
            # drew the frame into it, which put the new bezel INSIDE the panel's
            # existing one -- a frame nested in a frame. The frame has to cover
            # the old well entirely, and that means extending past the recess on
            # every side, including the left.
            #
            # It cannot be one surface, because 0x37D98 pins the text block to its
            # destination's (0,0) and a positive x is clamped away, so a left
            # inset is not expressible. Two surfaces make it moot: the FRAME blits
            # first at its own origin, the RECESS blits on top at the offset the
            # artwork measured, and the text lands at the recess's own (0,0).
            #
            # The pads come from the panel art: the well assembly and its bolts run
            # x 537..743, y 489..593, against a registration block of (554,499)
            # 174x84. Measured once by hand off HUD3.PCX, then written down here,
            # because a re-skin that moves the well moves the registration block
            # with it and these stay right.
            # PAD_B runs to the PANEL'S BOTTOM EDGE, not to the old well's rail:
            # the rows below that rail are the panel's own bottom shadow, and
            # stopping short of them left the frame floating with a strip of the
            # old art beneath it.
            $BOX_PAD_L = 17; $BOX_PAD_R = 16
            $BOX_PAD_B = ($SCREEN_H - 1) - ($SCAN_Y + $SCAN_H - 1)
            $FRAME_X       = $SCAN_X - $BOX_PAD_L
            $FRAME_W       = $SCAN_W + $BOX_PAD_L + $BOX_PAD_R
            $FRAME_H_SMALL = $SCAN_H + $BOX_LIP + $BOX_PAD_B
            $FRAME_H_BIG   = $FRAME_H_SMALL + $BOX_EXTEND
            $FRAME_Y_SMALL = $SCAN_Y - $BOX_LIP
            $FRAME_Y_BIG   = $FRAME_Y_SMALL - $BOX_EXTEND
            # THE TEXT AREA OVERLAY (Build-HudWide.ps1, 2026-10-06) rises above the panel even when
            # closed: its frame starts lift rows above the panel's top. The box is repainted after the
            # view every frame anyway (the open state already lives there), so only the numbers move.
            if ($bxe -and $bxe.PSObject.Properties['lift']) {
                $FRAME_Y_SMALL -= [int]$bxe.lift; $FRAME_H_SMALL += [int]$bxe.lift
                $FRAME_Y_BIG = $FRAME_Y_SMALL - $BOX_EXTEND; $FRAME_H_BIG = $FRAME_H_SMALL + $BOX_EXTEND
            }

            $boxJson = Join-Path $PSScriptRoot '..\art\hud-box.json'
            if (-not (Test-Path $boxJson)) { throw "the expanding box needs art\hud-box.json -- run src\Build-HudBox.ps1" }
            $bj = Get-Content $boxJson -Raw | ConvertFrom-Json
            if ([int]$bj.frameW -ne $FRAME_W -or [int]$bj.frameHOff -ne $FRAME_H_SMALL -or [int]$bj.frameHOn -ne $FRAME_H_BIG) {
                throw ("art\hud-box.json is for a {0}x{1}/{2} frame; this build needs {3}x{4}/{5}. Re-run Build-HudBox.ps1 with -BoxW {3} -BoxHOff {4} -BoxHOn {5}." -f `
                       $bj.frameW, $bj.frameHOff, $bj.frameHOn, $FRAME_W, $FRAME_H_SMALL, $FRAME_H_BIG)
            }
            # The recess, in screen terms. Its OPEN height is derived rather than
            # measured so the bottom edge is pinned to the pixel: the two frames
            # were rendered separately and their rails differ by a row.
            $RECESS_DX       = [int]$bj.recessX
            $RECESS_DY       = [int]$bj.recessY
            $RECESS_X        = $FRAME_X + $RECESS_DX
            $RECESS_W        = [int]$bj.recessW
            $RECESS_H_SMALL  = [int]$bj.recessHOff
            $RECESS_H_BIG    = $RECESS_H_SMALL + $BOX_EXTEND
            $RECESS_Y_SMALL  = $FRAME_Y_SMALL + $RECESS_DY
            $RECESS_Y_BIG    = $RECESS_Y_SMALL - $BOX_EXTEND

            # The toggle's click bounds, frame-local, measured off the chevron in
            # the closed frame and padded out to the button.
            $BOX_ICON_X0 = [int]$bj.iconX0; $BOX_ICON_X1 = [int]$bj.iconX1
            $BOX_ICON_Y0 = [int]$bj.iconY0; $BOX_ICON_Y1 = [int]$bj.iconY1

            $TEXTBOX_W = $RECESS_W
            # The text surface has to out-reach the EXPANDED recess, or opening the
            # box puts the whole thing on screen and the arrows have nothing to do.
            $TEXTBOX_H = if ($ENABLE_LOG_BOX_TOGGLE) { $RECESS_H_BIG + $LOG_HISTORY }
                         else { $LOG_WIN_H + $LOG_HISTORY }
            $TEXTBOX_DX_EXTRA = 0
            Write-Host ("log box: frame {0}x{1} at ({2},{3}), opens to {0}x{4} at ({2},{5})" -f `
                $FRAME_W, $FRAME_H_SMALL, $FRAME_X, $FRAME_Y_SMALL, $FRAME_H_BIG, $FRAME_Y_BIG)
            Write-Host ("         recess {0}x{1} at ({2},{3}), opens to {0}x{4} at ({2},{5}), text surface {6} rows" -f `
                $RECESS_W, $RECESS_H_SMALL, $RECESS_X, $RECESS_Y_SMALL, $RECESS_H_BIG, $RECESS_Y_BIG, $TEXTBOX_H)
        }

        $script:SKIN_ACTIONS = @($acts | ForEach-Object { @{ x=$_.x; y=(& $sy $_); w=$_.w; h=$_.h } })
        $script:SKIN_CTRLS   = @($ctrl | ForEach-Object { @{ x=$_.x; y=(& $sy $_); w=$_.w; h=$_.h } })

        # ---- and the CLICK REGIONS follow the artwork too --------------------
        # Drawing was moved onto the new panel above, but the hot-spot polygons
        # are transformed further down by rules keyed to the STOCK layout
        # (To-PanelX/Y, the housing shift). That put every control's click area
        # where the old scaled layout had it, so the buttons drew in one place
        # and responded in another -- i.e. nothing on the panel was clickable.
        #
        # These are screen 0's polygon bounding boxes as decoded from the stock
        # table, paired with the artwork rect each one now belongs to. Each
        # polygon's points are mapped bbox-to-bbox, so the SHAPE is preserved
        # (they are 4-, 6-, 7- and 9-point outlines, not rectangles) and it lands
        # exactly on the new socket.
        $script:SKIN_HOT = @(
            @{ n='inventory window'; old=@(70,345,172,413);  new=@($MAP_WIN_X, $MAP_WIN_Y, $mapR.w, $mapR.h) },
            @{ n='sort arrow up';    old=@(179,345,193,368); new=@($ctrl[0].x, (& $sy $ctrl[0]), $ctrl[0].w, $ctrl[0].h) },
            @{ n='sort arrow down';  old=@(178,371,191,394); new=@($ctrl[1].x, (& $sy $ctrl[1]), $ctrl[1].w, $ctrl[1].h) },
            @{ n='NBUT0 scan';       old=@(233,338,310,372); new=@($acts[0].x, (& $sy $acts[0]), $acts[0].w, $acts[0].h) },
            @{ n='NBUT1 map';        old=@(213,381,283,420); new=@($acts[1].x, (& $sy $acts[1]), $acts[1].w, $acts[1].h) },
            @{ n='NBUT2 menu';       old=@(360,387,444,426); new=@($acts[2].x, (& $sy $acts[2]), $acts[2].w, $acts[2].h) }
        )
        # Counted PER REGION, not in total. Several of these polygons appear on
        # more than one UI screen -- the menu button is on screen 0 and on all
        # three fold-out screens, because the panel stays visible while the menu
        # is open and the same button closes it again. Every copy has to move.
        $script:skinHotFound = @{}
        foreach ($h0 in $script:SKIN_HOT) { $script:skinHotFound[$h0.n] = 0 }
        Write-Host ("layout from artwork: map ({0},{1}) {2}x{3}  scan ({4},{5}) {6}x{7}  gauge ({8},{9})" -f `
            $MAP_X,$MAP_Y,$mapR.w,$mapR.h,$SCAN_X,$SCAN_Y,$SCAN_W,$SCAN_H,$BAR_X,$BAR_Y)
    }

    # automap: four draw sites, each `mov ebx,345` / `mov edx,70` feeding either
    # Blit(0x33F80) directly or the helper at 0x10AA8 that precedes it.
    foreach ($p in @(@(0x12B4E,0x12B59), @(0x15873,0x15878),
                     @(0x1654F,0x1655A), @(0x15DDE,0x15DE9))) {
        if ($MAP_Y -ne $MAP_Y_OLD) { $patches += Patch-Imm32 -Name ("hud-map-y-{0:X}" -f $p[0]) -Lin $p[0] -Old $MAP_Y_OLD -New $MAP_Y -Note 'automap Y -> HUD strip' }
        if ($MAP_X -ne $MAP_X_OLD) { $patches += Patch-Imm32 -Name ("hud-map-x-{0:X}" -f $p[1]) -Lin $p[1] -Old $MAP_X_OLD -New $MAP_X -Note 'automap X -> left gutter' }
    }
    # THE INVENTORY SURFACE IS CREATED AT A HARD-CODED 103x69 (0x138C4:
    # `mov ebx,0x45 / mov edx,0x67 / mov eax,0x163A40 / call 0x287DA`), and
    # INVBACK2.PCX is loaded INTO it. Stretching the art alone therefore did
    # nothing -- the surface stayed the old size and the bigger image was simply
    # clipped to it. Both numbers have to move with the artwork.
    if ($INV_CONTENT_H -ne 69) {
        $patches += Patch-Imm32 -Name 'inv-h-138C4' -Lin 0x138C4 -Old 69 -New $INV_CONTENT_H `
            -Note ("inventory surface height 69 -> {0} (fills the reskinned recess)" -f $INV_CONTENT_H)
    }
    if ($INV_CONTENT_W -ne 103) {
        $patches += Patch-Imm32 -Name 'inv-w-138C9' -Lin 0x138C9 -Old 103 -New $INV_CONTENT_W `
            -Note ("inventory surface width 103 -> {0}" -f $INV_CONTENT_W)
    }
    # status gauge: the blit of the fill, the frame draw at 0x34C40 (which takes
    # y as a pushed argument and x in ecx), and the init draw at 0x350CC.
    foreach ($p in @(@(0x11E1F,0x11E24), @(0x11E47,0x11E4C), @(0x284D8,0x284DD))) {
        if ($BAR_Y -ne $BAR_Y_OLD) { $patches += Patch-Imm32 -Name ("hud-bar-y-{0:X}" -f $p[0]) -Lin $p[0] -Old $BAR_Y_OLD -New $BAR_Y -Note 'status gauge Y -> panel' }
        if ($BAR_X -ne $BAR_X_OLD) { $patches += Patch-Imm32 -Name ("hud-bar-x-{0:X}" -f $p[1]) -Lin $p[1] -Old $BAR_X_OLD -New $BAR_X -Note 'status gauge X' }
    }
    # ---- RESIZE THE GAUGE, not just move it --------------------------------
    #
    # Only X and Y were ever patched, so the health bar stayed Mindscape's 105x15
    # inside a reskinned recess it could not fill. Exactly the bug the inventory
    # window had (see inv-h-138C4 above): the SURFACE size is hard-coded at the
    # create call and the art alone cannot change it.
    #
    # Two surfaces are built back to back at 0x284A4..0x28518 -- a frame (0x163A10)
    # and a fill (0x163A22 = frame + 0x12) -- each 105x15 with its own 1575-byte
    # (105*15) malloc, and the fill's pixels are then memcpy'd from H1.PCX with the
    # same 1575 length. All five numbers have to move together or the copy runs off
    # the end of the smaller buffer.
    #
    # AND THE SCALE HAS TO MOVE WITH THEM. The draw at 0x11E2B blits `ecx` columns
    # of the fill, where ecx = (health >> 16) * 8 / 1000 -- calibrated so that full
    # health is 105. Widen the surface without touching that and the bar tops out at
    # 105 of 130 columns: full health would permanently read as 81%. Rescaling the
    # DIVISOR by the width ratio fixes it without needing to know the maximum health
    # value at all, because it is a pure old-width / new-width proportion.
    if ($gaugeR) {
        $BAR_W_OLD = 105; $BAR_H_OLD = 15; $BAR_BYTES_OLD = $BAR_W_OLD * $BAR_H_OLD
        # $GAUGE_RESIZE = $true keeps Mindscape's 105x15 gauge surface and only
        # changes the ART, which is the bisect for the stray line above the bar:
        # the line arrived with this whole block, and this splits it into "the
        # surface was resized" versus "H1.PCX's content changed".
        # WIDTH ONLY, BY DEFAULT. Bisected 2026-09-24: resizing the gauge surface
        # put a stray bright line in the panel a few rows ABOVE the bar, and
        # reverting the resize removed it. The width is what the reskin actually
        # needs (105 in a ~140-wide recess looks lost); the height was changed only
        # because the registration block measures 14, while the real black well is
        # about 20 rows deep and a 15-row bar sits in it perfectly well. So keep
        # Mindscape's height unless $GAUGE_RESIZE_H is explicitly set.
        # $GAUGE_W_EXTRA widens the bar PAST the detected recess. The detector finds the
        # registration rectangle (130 px), but the painted black well is wider than that:
        # measured on HUD3, the floor (index 1) runs from x=500 to x=635 or 636 on every one
        # of the bar's rows 662..676, so 136 is the hard maximum and anything beyond it would
        # paint over the bezel. 134 leaves 2 px of well showing at the right, which is what
        # keeps it reading as a bar sitting IN the recess rather than overflowing it.
        if ($GAUGE_RESIZE) {
            $BAR_W = [int]$gaugeR.w + $GAUGE_W_EXTRA
            if ($BAR_W -gt $GAUGE_W_MAX) {
                throw ("gauge width $BAR_W exceeds the painted well ($GAUGE_W_MAX px from x=$($gaugeR.x)); it would run onto the bezel")
            }
        } else { $BAR_W = $BAR_W_OLD }
        if ($GAUGE_RESIZE_H) { $BAR_H = [int]$gaugeR.h } else { $BAR_H = $BAR_H_OLD }
        $BAR_BYTES = $BAR_W * $BAR_H
        if ($BAR_H -ne $BAR_H_OLD) {
            foreach ($a in @(0x284A4, 0x284F2)) {
                $patches += Patch-Imm32 -Name ("hud-bar-h-{0:X}" -f $a) -Lin $a -Old $BAR_H_OLD -New $BAR_H `
                    -Note ("gauge surface height {0} -> {1}" -f $BAR_H_OLD, $BAR_H)
            }
        }
        if ($BAR_W -ne $BAR_W_OLD) {
            foreach ($a in @(0x284A9, 0x284F7)) {
                $patches += Patch-Imm32 -Name ("hud-bar-w-{0:X}" -f $a) -Lin $a -Old $BAR_W_OLD -New $BAR_W `
                    -Note ("gauge surface width {0} -> {1} (fills the reskinned recess)" -f $BAR_W_OLD, $BAR_W)
            }
        }
        if ($BAR_BYTES -ne $BAR_BYTES_OLD) {
            # two mallocs and the H1.PCX memcpy length
            foreach ($a in @(0x284B8, 0x28501, 0x28510)) {
                $patches += Patch-Imm32 -Name ("hud-bar-bytes-{0:X}" -f $a) -Lin $a -Old $BAR_BYTES_OLD -New $BAR_BYTES `
                    -Note ("gauge pixel buffer {0} -> {1} bytes ({2}x{3})" -f $BAR_BYTES_OLD, $BAR_BYTES, $BAR_W, $BAR_H)
            }
            # H1.PCX must BE that size or the copy reads past its end.
            # Straight off the PCX header rather than through PcxTool -- this script
            # does not Add-Type the imaging helpers and should not start.
            # Xmin/Ymin/Xmax/Ymax are words at offsets 4/6/8/10.
            $h1 = Join-Path $PSScriptRoot '..\art\H1.PCX'
            if (-not (Test-Path $h1)) { throw "the resized gauge needs art\H1.PCX -- run src\Build-HudBar.ps1" }
            $h1b = [System.IO.File]::ReadAllBytes((Resolve-Path $h1).Path)
            if ($h1b.Length -lt 128) { throw "art\H1.PCX is too short to be a PCX" }
            $h1w = [BitConverter]::ToUInt16($h1b,8) - [BitConverter]::ToUInt16($h1b,4) + 1
            $h1h = [BitConverter]::ToUInt16($h1b,10) - [BitConverter]::ToUInt16($h1b,6) + 1
            if ($h1w -ne $BAR_W -or $h1h -ne $BAR_H) {
                throw ("art\H1.PCX is {0}x{1} but the gauge is {2}x{3}; re-run src\Build-HudBar.ps1" -f `
                       $h1w, $h1h, $BAR_W, $BAR_H)
            }
        }
        $BAR_DIV_OLD = 1000
        # FLOOR, NOT ROUND. The columns shown are `health*8/div` under INTEGER division, so a
        # divisor rounded UP leaves the bar one pixel short of the end at full health -- 808
        # gives 129 of 130, which is exactly the "nearly full" look this resize exists to fix.
        # Flooring the divisor makes the last column land. Asking for one column too many is
        # harmless: the surface's own clip rect (set to w-1 by 0x37B04) clamps it.
        $BAR_DIV = [int][Math]::Floor($BAR_DIV_OLD * $BAR_W_OLD / [double]$BAR_W)
        if ($BAR_DIV -ne $BAR_DIV_OLD) {
            $patches += Patch-Imm32 -Name 'hud-bar-scale-11E13' -Lin 0x11E13 -Old $BAR_DIV_OLD -New $BAR_DIV `
                -Note ("health -> pixels divisor {0} -> {1}, so full health fills {2} columns not {3}" -f `
                       $BAR_DIV_OLD, $BAR_DIV, $BAR_W, $BAR_W_OLD)
        }
        # ---- the engine's own gauge frame ----------------------------------
        #
        # The gauge is TWO surfaces: the fill (0x163A22, which gets H1.PCX and is
        # blitted `ecx` columns wide for the health level) and a frame (0x163A10)
        # handed to 0x34C40 on every gauge draw, independent of the level.
        #
        # 0x34C40 draws that frame over the whole gauge rect every time, and its
        # bottom edge lands as a bright horizontal line across the full width of the
        # well -- visible past the end of the bar, which is exactly how it was
        # reported ("lines the bottom of the blank space behind the health bar").
        # Against Mindscape's original recess, which had its own bevel baked into
        # the panel art, it blended in. Against the reskin's flat black well it is
        # the only thing in there.
        #
        # The reskinned panel already draws the recess bezel, so the engine's copy is
        # redundant.
        #
        # 0x34C40 IS CALLEE-POPS -- it ends `ret 4` at 0x350C9, so it removes the
        # pushed y itself. NOPing the call therefore does NOT balance: `push 0x165`
        # is left stranded, the following `add esp,0xC` runs anyway, and esp comes
        # back 4 bytes high, so the caller returns into garbage. That crashed the
        # game on first load. Replace the call with `add esp,4` instead, which does
        # exactly what the callee's `ret 4` would have done.
        if (-not $ENABLE_GAUGE_FRAME) {
            $gfAt = [uint32]0x11E5C
            $patches += New-Patch -Name 'hud-bar-noframe-11E5C' -FileOffset (Lin2File $gfAt) `
                -Expect (CallRel32 $gfAt ([uint32]0x34C40)) `
                -Replace ([byte[]]@(0x83,0xC4,0x04,0x90,0x90)) `
                -Note 'gauge frame draw (0x34C40) skipped -- `add esp,4` replaces the callee-pop, so the stack still balances'
        }

        # ---- the gauge's erase surface -------------------------------------
        # KEEP THE PASS, FIX WHAT IT DRAWS. Skipping the 0x33F80 call at 0x11E30 removed the
        # speckle and also removed the bar's ability to SHRINK -- that pass is the erase, and
        # the bar is simply drawn over the health portion of it. So the memcpy that fills it
        # is redirected to AztGaugeFill instead, which paints the well's own floor.
        #
        # PLAIN NOPS WOULD HAVE BEEN SAFE at 0x11E30, unlike the frame draw above: 0x33F80
        # takes all four arguments in registers, with no push before and no `add esp` after,
        # and ends in a plain `ret` -- which is why AztOpenMovie can tail-jump to it. Noted in
        # case the pass ever does need disabling.
        if ($ENABLE_GAUGE_FILL) {
            $gcAt = [uint32]0x28518
            $patches += New-Patch -Name 'hud-bar-erase-28518' -FileOffset (Lin2File $gcAt) `
                -Expect (CallRel32 $gcAt ([uint32]0x40182)) `
                -Replace (CallRel32 $gcAt $asm.Labels['AztGaugeFill']) `
                -Note 'gauge erase surface filled with the well floor (index 1) instead of memcpy-ing heap garbage from [ebp-0x10]'
        } else {
            $gfiAt = [uint32]0x11E30
            $patches += New-Patch -Name 'hud-bar-nofill-11E30' -FileOffset (Lin2File $gfiAt) `
                -Expect (CallRel32 $gfiAt ([uint32]0x33F80)) `
                -Replace ([byte[]]@(0x90,0x90,0x90,0x90,0x90)) `
                -Note 'gauge fill pass skipped entirely -- removes the speckle but the bar can no longer shrink'
        }

        # Full health must land INSIDE the surface: the blit takes ecx as a column
        # count and nothing clamps it to the width.
        $fullCols = [int][Math]::Floor($BAR_W_OLD * $BAR_DIV_OLD / [double]$BAR_DIV)
        if ($fullCols -gt $BAR_W) {
            throw ("full health would draw $fullCols columns into a $BAR_W-wide gauge surface")
        }
        Write-Host ("status gauge: {0}x{1} -> {2}x{3} at ({4},{5}), divisor {6} -> {7} (full health = {8} cols)" -f `
            $BAR_W_OLD, $BAR_H_OLD, $BAR_W, $BAR_H, $BAR_X, $BAR_Y, $BAR_DIV_OLD, $BAR_DIV, $fullCols)
    }
    # scan readout: one draw site, plus the single create at 0x10BAD.
    # WITH THE EXPANDING BOX the draw site's `mov ebx, <Y>` becomes a call: the Y
    # is no longer a constant, and the same call is where the surface gets resized.
    if ($ENABLE_LOG_BOX_TOGGLE) {
        foreach ($s in @(0x12336, 0x127F9)) {
            $o = Lin2File $s
            $exp = [byte[]]@(0xBB) + [BitConverter]::GetBytes([uint32]$SCAN_Y_OLD)
            for ($k = 0; $k -lt 5; $k++) {
                if ($raw[$o+$k] -ne $exp[$k]) { throw ("expected 'mov ebx,{0}' at 0x{1:X}" -f $SCAN_Y_OLD, $s) }
            }
            $patches += New-Patch -Name ("box-prep-{0:X}" -f $s) -FileOffset $o `
                -Expect $exp -Replace (CallRel32 ([uint32]$s) $BOX_PREP) `
                -Note 'log box: size the surface for this frame and return its blit Y'
        }
    }
    elseif ($SCAN_Y -ne $SCAN_Y_OLD) {
        $patches += Patch-Imm32 -Name 'hud-scan-y-12336' -Lin 0x12336 -Old $SCAN_Y_OLD -New $SCAN_Y -Note 'scan readout Y -> HUD strip'
        $patches += Patch-Imm32 -Name 'hud-scan-y-127F9' -Lin 0x127F9 -Old $SCAN_Y_OLD -New $SCAN_Y -Note 'scan readout Y -> panel (second draw site)'
    }
    if ($SCAN_X -ne $SCAN_X_OLD) { $patches += Patch-Imm32 -Name 'hud-scan-x-1233B' -Lin 0x1233B -Old $SCAN_X_OLD -New $RECESS_X -Note 'scan readout X -> right gutter' }
    # The surface is allocated at the EXPANDED height so one buffer serves both
    # states; collapsed just moves its base down and shortens it.
    $SCAN_H_ALLOC = if ($ENABLE_LOG_BOX_TOGGLE) { $RECESS_H_BIG } else { $SCAN_H }
    if ($SCAN_H_ALLOC -ne $SCAN_H_OLD) { $patches += Patch-Imm32 -Name 'hud-scan-h-10B9E' -Lin 0x10B9E -Old $SCAN_H_OLD -New $SCAN_H_ALLOC -Note ("scan surface height {0} (allocated for the expanded log box)" -f $SCAN_H_ALLOC) }
    if ($RECESS_W -ne $SCAN_W_OLD) { $patches += Patch-Imm32 -Name 'hud-scan-w-10BA3' -Lin 0x10BA3 -Old $SCAN_W_OLD -New $RECESS_W -Note 'scan surface width, so it fits in the right gutter' }

# ===========================================================================
# THE EXPANDING LOG BOX -- second cave blob
# ===========================================================================
# Everything here lives at $CAVE2_BASE because the first cave has single-digit
# bytes left. It is self-contained: it carries its OWN copy of the delta finder,
# so it never has to be assembled before the main stub, and the main stub reaches
# it only through the three fixed trampolines at the top.
#
# Surface 0x152AD4, fields set by the constructor at 0x37AC8:
#   +0 width   +2 height   +4 pixels   +8/+A/+C/+E clip x0,y0,x1,y1
if ($ENABLE_LOG_BOX_TOGGLE) {
    if (-not $ENABLE_LFB) { throw 'the box blob lives in blitter code that only $ENABLE_LFB makes dead' }

    $SURF_BOX     = [uint32]0x152AD4
    $g_lmbHeld    = [uint32]0x182DA6
    $g_mouseX     = [uint32]0x182D6C
    $g_mouseY     = [uint32]0x182D6E
    $CONV_PICK    = [uint32]0x180C0   # pick the conversation option under a Y
    # The UI sound-effect player: PlayUiSfx(eax = wav filename). Found by walking
    # its 14 call sites -- spaper.wav for the page turn, SCAN.WAV for the scanner,
    # spick.wav, hud3.wav, hudlockr.wav.
    #
    # It takes nothing but the name: it reads the sound object from 0x1824E8
    # itself and re-applies the SFX volume slider from 0x14693C afterwards, so the
    # toggle honours the volume setting for free. It also declines to play while
    # 0x1525A0 or $g_convList is set, i.e. it stays quiet during dialogue.
    #
    # Register-safe for our purposes: it pushes ebx/ecx/edx/esi and never touches
    # edi at all, so both cave base registers survive the call.
    $SFX_PLAY     = [uint32]0x100BC
    # WHICH OF THE MENU'S TWO SOUNDS. hud3.wav is NOT the one: both 0x143160 and
    # 0x143169 are byte-identical copies of that name, and the menu plays it on
    # open AND on close, so it cannot be what distinguishes them.
    #
    # The short latch is hudlockr.wav, and it belongs to the menu's ANIMATION
    # rather than to either toggle path. 0x1523E6 is the step counter and
    # 0x1523E8 the direction; 0x1493B advances one by the other each frame and
    # 0x1495B fires the sample when the step lands on exactly 6:
    #
    #   opening  0x2C86A sets direction +1  -> 0..6, hits 6, latch plays
    #   closing  0x2C2F9 sets direction -1  -> 6..0, never equals 6 again
    #
    # So it is the open-only sound, which is the one asked for, for BOTH
    # directions of the log box.
    $SND_MENU     = [uint32]0x14063A  # "hudlockr.wav", in obj2 -- reach it off edi

    # THE BOX OWNS EVERY ROW IT CAN EVER COVER, IN BOTH STATES. It used to start
    # at the well (499) while the expanded one started at 379, which left the ten
    # rows between the viewport's bottom edge (488) and the well orphaned: the
    # expanded box painted over them, and nothing repainted them afterwards. The
    # 3D view repaints 0..488 every frame and the panel art is drawn once at
    # start-up, so those ten rows kept the last thing the expanded box put there
    # -- a short strip of stale text hanging above the collapsed box that drifted
    # out of step with it as you scrolled.
    #
    # Extending the COLLAPSED box up to the viewport edge makes the residue
    # impossible rather than repairing it: whatever the expanded box covers, the
    # collapsed one covers too, and repaints every frame. It costs ten rows of the
    # panel's top bevel in this column, which the replacement artwork puts back --
    # and it is the shape that artwork wants anyway, since the box then owns its
    # whole rect and the frame can be part of the image in both states.
    $BOX_LIP      = $SCAN_Y - ($VIEW_Y + $VIEW_H)
    if ($BOX_LIP -lt 0) { throw "the readout well ($SCAN_Y) starts above the viewport's bottom edge" }
    # Frame sizes for the loader; recess sizes for the text window.
    # Collapsed, the visible rows are the LAST $RECESS_H_SMALL of the buffer, so
    # Collapsed, the visible rows are the LAST $RECESS_H_SMALL of the buffer, so
    # the base moves down by the extension. This is what pins the bottom edge.
    # base moves down by the extension. This is what pins the bottom edge.
    $BOX_BASE_OFF = $BOX_EXTEND * $RECESS_W
    $BOX_BASE_OFF = $BOX_EXTEND * $RECESS_W
    # How far back you can scroll in each state: everything the text surface holds
    # that the window cannot show at once. The expanded box shows 120 rows more,
    # so it has 120 rows less to scroll through -- which is why there was nothing
    # to scroll at all while the surface was only as tall as the expanded box.
    $BOX_MAXOFF_SMALL = $TEXTBOX_H - $RECESS_H_SMALL
    $BOX_MAXOFF_SMALL = $TEXTBOX_H - $RECESS_H_SMALL
    $BOX_MAXOFF_BIG   = $TEXTBOX_H - $RECESS_H_BIG
    $BOX_MAXOFF_BIG   = $TEXTBOX_H - $RECESS_H_BIG
    if ($BOX_MAXOFF_BIG -le 0) { throw "the text surface ($TEXTBOX_H) is no taller than the open recess ($RECESS_H_BIG)" }
    if ($BOX_MAXOFF_BIG -le 0) { throw "the text surface ($TEXTBOX_H) is no taller than the open recess ($RECESS_H_BIG)" }
    if ($FRAME_Y_BIG -lt 0) { throw "the open log box starts above the screen (y=$FRAME_Y_BIG)" }
    if ($FRAME_Y_BIG -lt 0) { throw "the open log box starts above the screen (y=$FRAME_Y_BIG)" }

    # ---- the artwork blob, in the third cave --------------------------------
    # Fixed layout so the second cave can reach it without an assembly order.
    $q = New-Asm -Base $CAVE3_BASE
    Add-Label $q 'BoxArt0'; A-Jmp $q 'AztBoxLoad'
    Add-Label $q 'BoxArt1'; A-Jmp $q 'AztBoxSaveBase'
    Add-Label $q 'BoxArt2'; A-Jmp $q 'AztBoxFill'
    Add-Label $q 'BoxArt3'; A-Jmp $q 'AztBoxConv'
    Add-Label $q 'boxOffSurf'; A-Db $q ([byte[]](,0 * 16))
    Add-Label $q 'boxOnSurf';  A-Db $q ([byte[]](,0 * 16))
    Add-Label $q 'sBoxOff'; A-Db $q ([byte[]][System.Text.Encoding]::ASCII.GetBytes("boxoff.pcx") + [byte[]]@(0))
    Add-Label $q 'sBoxOn';  A-Db $q ([byte[]][System.Text.Encoding]::ASCII.GetBytes("boxon.pcx")  + [byte[]]@(0))
    Add-Label $q 'aztBoxBuf'; A-Db $q ([byte[]](,0 * 4))   # the recess surface's real base
    Add-Label $q 'aztConvWas'; A-Dw $q 0   # last frame's conversation flag, for the edge
    Add-Label $q 'AztBoxCode'

    # The recess surface's real pixel base, recorded before we ever move it.
    # Reading it back later would give whichever end we last pointed at.
    # Lay the frame's own recess pixels into the text surface: same size, but a
    # row at a time because the two have different strides.
    #   in: eax = recess base, ecx = its bytes, ebp = the frame's header
    Add-Label $q 'AztBoxFill'
    # edx CARRIES THE SCROLL OFFSET for the caller -- borrowing it for the end
    # pointer handed AztLogClearBx a framebuffer address to subtract from the
    # draw Y, which put the text somewhere off the bottom of memory.
    A-Db   $q @(0x52)                                      # push edx
    A-Db   $q @(0x01,0xC1)                                 # add ecx, eax -> end
    A-Db   $q @(0x89,0xCA)                                 # mov edx, ecx
    A-Db   $q @(0x8B,0x75,0x04)                            # mov esi, [ebp+4]
    A-Db   $q @(0x85,0xF6)                                 # test esi, esi
    A-JzS  $q 'ABF_ret'                                    # art missing: leave it cleared
    A-Db   $q @(0x81,0xC6); Add-Abs32 $q ($RECESS_DY * $FRAME_W + $RECESS_DX)
    A-Db   $q @(0x89,0xC7)                                 # mov edi, eax
    A-Db   $q @(0xFC)                                      # cld
    Add-Label $q 'ABF_row'
    A-Db   $q @(0xB9); Add-Abs32 $q $RECESS_W              # mov ecx, one row
    A-Db   $q @(0xF3,0xA4)                                 # rep movsb
    A-Db   $q @(0x83,0xC6, [byte]($FRAME_W - $RECESS_W))   # add esi, the stride difference
    A-Db   $q @(0x39,0xD7)                                 # cmp edi, edx
    A-JbS  $q 'ABF_row'
    Add-Label $q 'ABF_ret'
    A-Db   $q @(0x5A)                                      # pop edx
    A-Ret  $q

    # WHEN A CONVERSATION OPENS, START THE LOG AGAIN FROM THE TOP.
    #
    # This replaces the scroll offset the list draw briefly carried, and it is a
    # better answer for two reasons. The dialogue lands at the top of the recess
    # instead of wherever the narration happened to leave the cursor -- and, more
    # importantly, THE OFFSET STAYS ZERO. The game maps a click to an option from
    # its SCREEN position and knows nothing about a source offset, so any offset
    # silently shifts which option you pick. Rewinding the cursor keeps the text
    # and the hit test in the same coordinate space.
    #
    # Rising edge only: it fires once per conversation, not once per frame.
    # Clearing the surface costs the narration scrollback, which is the point.
    Add-Label $q 'AztBoxConv'
    A-Db   $q @(0x0F,0xB7,0x87); Add-Abs32 $q $g_convList          # movzx eax,[edi+conv]
    A-Db   $q @(0x0F,0xB7,0x8E); Add-Abs32 $q 'aztConvWas'         # movzx ecx,[esi+was]
    A-Db   $q @(0x66,0x89,0x86); Add-Abs32 $q 'aztConvWas'         # mov [esi+was], ax
    A-Db   $q @(0x66,0x85,0xC0)                                    # test ax, ax
    A-JzS  $q 'ABC2_ret'                                           # no conversation
    A-Db   $q @(0x66,0x85,0xC9)                                    # test cx, cx
    A-JnzS $q 'ABC2_ret'                                           # already open -- not an edge
    A-Db   $q @(0x8B,0x87); Add-Abs32 $q $LOG_TEXT_OBJ             # mov eax,[edi+textobj]
    A-Db   $q @(0x85,0xC0)                                         # test eax, eax
    A-JzS  $q 'ABC2_ret'
    A-Db   $q @(0x66,0xC7,0x40,0x06,0x00,0x00)                     # mov word [eax+6], 0  (y cursor)
    A-Db   $q @(0x66,0xC7,0x40,0x04,0x00,0x00)                     # mov word [eax+4], 0  (x cursor)
    # Wind the reader all the way back too, so the window shows row 0 and the
    # effective offset is zero -- see above.
    A-MovWordSiImm $q $asm.Labels['aztLogScroll'] $BOX_MAXOFF_BIG
    A-Db   $q @(0x8B,0x00)                                         # mov eax,[eax] -- its surface
    A-Call $q $SURF_CLEAR
    Add-Label $q 'ABC2_ret'
    A-Ret  $q

    Add-Label $q 'AztBoxSaveBase'
    A-Db   $q @(0x83,0xBE); Add-Abs32 $q $BOX_BUF; A-Db $q @(0x00)
    A-JnzS $q 'ABB_ret'
    A-Db   $q @(0x8B,0x87); Add-Abs32 $q ($SURF_BOX + 4)
    A-Db   $q @(0x89,0x86); Add-Abs32 $q $BOX_BUF
    Add-Label $q 'ABB_ret'
    A-Ret  $q

    # Load both frames once, the first time the log draws. Lazily rather than at
    # start-up because there is no spare room in the HUD init to hook, and by the
    # time anything draws the log the palette and the file system are long ready.
    # The guard is the pixel pointer: 0x37AC8 mallocs it, so non-zero means done.
    #
    # esi = obj1 delta on entry. 0x37AC8 and 0x38A20 both preserve esi/edi/ebp
    # (Watcom register convention), so it survives four calls.
    Add-Label $q 'AztBoxLoad'
    A-Db   $q @(0x83,0xBE); Add-Abs32 $q ($BOX_SURF_OFF + 4); A-Db $q @(0x00)
    A-JnzS $q 'ABL_ret'
    foreach ($s in @(@($BOX_SURF_OFF, $FRAME_H_SMALL, $BOX_STR_OFF),
                     @($BOX_SURF_ON,  $FRAME_H_BIG,   $BOX_STR_ON))) {
        A-Db $q @(0xBA); Add-Abs32 $q $FRAME_W                  # mov edx, width
        A-Db $q @(0xBB); Add-Abs32 $q $s[1]                   # mov ebx, height
        A-Db $q @(0x8D,0x86); Add-Abs32 $q $s[0]              # lea eax,[esi+hdr]
        A-Call $q $SURF_NEW
        A-Db $q @(0x8D,0x86); Add-Abs32 $q $s[0]              # lea eax,[esi+hdr]
        A-Db $q @(0x8D,0x96); Add-Abs32 $q $s[2]              # lea edx,[esi+name]
        A-Db $q @(0x31,0xC9,0x31,0xDB)                        # xor ecx,ecx / xor ebx,ebx
        A-Call $q $PCX_LOAD
    }
    Add-Label $q 'ABL_ret'
    A-Ret  $q

    # --- CLICKING A CONVERSATION OPTION --------------------------------------
    # 0x180C0 is the picker: the caller at 0x2D0B5 hands it the raw cursor Y and
    # it walks 0x162B36[], a table of per-option bottoms, taking the first one
    # the cursor is above. Event 0x18 reaches it unconditionally while a
    # conversation is up (the dispatcher at 0x2D0F1 indexes 0x2C3A0 and 0x2C424
    # lets 0x18 and 0x1A past the early-out), so there is no other gate -- and
    # that is the whole bug. The table is built at 0x1809E as
    #
    #     entry[i] = <log text object's Y cursor> + 0x59
    #
    # i.e. SCREEN coordinates for a box whose row 0 sat at y=89, and the bounds
    # test at 0x180EA/0x180F3 is the matching 89..294. Our recess is at 387..582,
    # so every click fell outside and nothing was ever selectable.
    #
    # Rebasing the constants would work only while the offset is zero. The table
    # is built when the options PRINT and read when the player CLICKS, and
    # between those two moments the scroll offset can change -- which would move
    # the text on screen without moving the table, i.e. silently pick the wrong
    # line. So the table stays in the TEXT SURFACE's own coordinates (the +0x59
    # becomes +0) and the conversion happens here, at click time, against the
    # offset that is live right now.
    #
    # A conversation always forces the box open, so the open recess is the one
    # to measure against: AztBoxWindow reads $g_convList exactly the same way.
    Add-Label $q 'AztConvHit'
    A-PushEsi $q
    A-PushEdx $q
    A-PushEax $q                                   # the raw Y, while esi is found
    A-CallNext $q
    Add-Label $q 'ACH_ref'
    A-PopEax $q
    A-SubEaxImm $q 'ACH_ref'
    A-MovEsiEax $q                                 # esi = obj1 delta
    A-PopEax $q
    A-SubEaxImm $q $RECESS_Y_BIG                   # -> recess-local
    A-Db $q @(0x78); Add-Rel8 $q 'ACH_miss'        # js  -- above the box
    A-CmpEaxImm $q $RECESS_H_BIG
    A-Db $q @(0x7D); Add-Rel8 $q 'ACH_miss'        # jge -- below it
    # The rows hidden above the window, exactly as AztBoxWindow computes them:
    # the clamp has to be repeated because the key handlers can leave
    # aztLogScroll past the open box's limit while the box is closed.
    A-Db $q @(0x0F,0xB7,0x96); Add-Abs32 $q $asm.Labels['aztLogScroll']  # movzx edx,[esi+scroll]
    A-Db $q @(0x81,0xFA);      Add-Abs32 $q $BOX_MAXOFF_BIG              # cmp edx, limit
    A-JbeS $q 'ACH_have'
    A-Db $q @(0xBA);           Add-Abs32 $q $BOX_MAXOFF_BIG              # mov edx, limit
    Add-Label $q 'ACH_have'
    A-Db $q @(0x05);           Add-Abs32 $q $BOX_MAXOFF_BIG              # add eax, limit
    A-Db $q @(0x29,0xD0)                                                 # sub eax, edx
    A-JmpS $q 'ACH_go'
    Add-Label $q 'ACH_miss'
    # Out of every option's range, so the picker's own upper bound rejects it.
    A-MovEaxImm $q 0xFFFF
    Add-Label $q 'ACH_go'
    A-PopEdx $q
    A-PopEsi $q
    A-Jmp $q $CONV_PICK

    # Shrink the box surface from the whole frame to just the recess, so the text
    # -- which 0x37D98 pins to (0,0) and cannot be offset -- lands inside the
    # bezel instead of on it. The numbers are MEASURED OUT OF THE ARTWORK by
    # Build-HudBox, so a re-render moves the text with the rail.
    #
    # Only the top and bottom, and the right by way of a narrower text surface.
    # There is no left inset to be had: the draw is clamped to x=0, which is why
    # the art brief asks for a 3px left rail that text may touch.

    # A hook used to live here that recorded the record pointer each time the game
    # started a cue, so the overlay could tell which track was wanted. It is gone:
    # the game keeps the current slot in a byte at 0x152AD0 -- the options slider
    # reads exactly that to decide which record to re-play -- so the overlay reads
    # it directly. That removed a patch site, freed 31 bytes of cave, and leaves
    # 0x3B048 unmodified, which matters because AztCdSwitch now CALLS it.

    # ---- the extra opening movie, tacked onto the end of this blob -----------
    # It lives HERE, in a file-backed cave, because the intro movies play BEFORE the first
    # frame hook -- so the BSS overlay is not resident yet and nothing in it can be called.
    # An earlier attempt played it from the overlay on the first gameplay frame instead and
    # crashed: the room and its texture cache are already resident by then, and the player
    # wants ~2.4 MB (two screen-sized surfaces plus its frame buffer) that is no longer there.
    # Here, it runs in the same conditions as the three movies before it.
    #
    # THE PATH GOES ON THE STACK, pushed as three dwords, which is how the game's own third
    # call does it (`lea eax,[ebp-0x78]`). It is not elegant -- 20 bytes of a 419-byte cave to
    # carry 12 bytes of text -- but it is the only form that fits AND is correct.
    #
    # DO NOT "OPTIMISE" THIS INTO A POINTER TO A POOLED STRING. I did, with the string in the
    # stub cave's tail and `mov eax,imm32` to address it, and THE GAME CRASHED AT THE MOVIE.
    # obj1 is NOT loaded at the address it was built for: that is the entire reason AztDeltas
    # exists ("esi = obj1 delta ... the difference between where we actually are and where we
    # were built to be"). An absolute obj1 address is a pointer to nowhere, and the player gets
    # it as a filename. The stack costs bytes but needs no delta, which is why the game's own
    # code does it this way too.
    #
    # Addressing a pooled string correctly needs the delta in esi -- call/pop/sub, 12 bytes --
    # and that plus a delta-correct flag store is 55 bytes in a cave that allows 45. The real
    # fix is to move this routine into the BSS overlay, which has ~19 KB free and AztDeltas
    # already, and that needs the overlay loaded BEFORE the intro: hook 0x16146, the `call
    # 0x10220` immediately preceding the only call to the intro sequence at 0x1614B.
    if ($ENABLE_OPENING_MOVIE) {
        $nm = [System.Text.Encoding]::ASCII.GetBytes($OPENING_MOVIE_NAME)
        if (($nm.Length + 1) % 4 -ne 0) {
            throw ("OPENING_MOVIE_NAME must be a whole number of dwords including its NUL; '{0}' is {1}+1" -f $OPENING_MOVIE_NAME, $nm.Length)
        }
        $dw = @()
        for ($i = 0; $i -lt $nm.Length; $i += 4) {
            # [int] ON EVERY BYTE BEFORE SHIFTING. `-shl` keeps the LEFT operand's type, so
            # [byte]0x6F -shl 8 is 0, not 0x6F00 -- it silently truncates instead of widening.
            # Unfixed, every dword here carried only its first character and the path the
            # player received was one letter long.
            $b0=[int]$nm[$i]; $b1=[int]$nm[$i+1]; $b2=[int]$nm[$i+2]
            $b3 = if (($i+3) -lt $nm.Length) { [int]$nm[$i+3] } else { 0 }
            $dw += [uint32]($b0 -bor ($b1 -shl 8) -bor ($b2 -shl 16) -bor ($b3 -shl 24))
        }
        # HOOKED AT 0x200A0, NOT 0x2008A.
        #
        # THE SKEW WAS NEVER ANYTHING TO DO WITH THIS HOOK, and the earlier note here claiming
        # it was -- back-to-back calls to the player skipping a teardown -- was wrong, as were
        # the geometry theories before it (1024x576, x384, x476 were all blamed in turn). The
        # picture was sheared before the file was ever written: Media Foundation hands back
        # 1470x630 frames in a buffer padded to 1472x640, MF_MT_DEFAULT_STRIDE reports the
        # UNPADDED 5880, and tools\Mp4Reader.cs believed it, losing two pixels a row. Decoding
        # our own OPENING.MOV back to PNG showed the shear sitting in the file with the block
        # codec still reporting 100% of blocks accounted -- self-consistent, just skewed.
        # Mp4Reader now derives the pitch from the buffer length and checks it against the
        # picture. See [[azrael-mov-format]].
        #
        # The hook position is still the right one on its own merits: 0x200A0 is after the
        # fade at 0x20094, i.e. the first point where the previous movie is fully finished.
        # It holds `call 0x33F80`, the epilogue's screen clear, which this tail-jumps to when
        # the movie ends -- so the clear still happens, just after our movie instead of before.
        Add-Label $q 'AztOpenMovie'
        A-Pushad $q
        # CLEAR THE SKIP FLAG FIRST. Reaching here with it set means the player skipped the
        # story intro, and the movie player polls this same word to stop early -- so ours
        # would be abandoned the instant it started, one skip taking out two movies. Clearing
        # it re-arms the flag for our movie, which stays independently skippable because a
        # fresh keypress sets it again. Same reasoning as the skip-one sites below.
        #
        # WRITTEN THROUGH EBX, AND THE FPS PUSHED RATHER THAN MOVED, because this cave was
        # down to its last byte: the obvious `mov word [skipFlag],0` is 9 bytes and overran
        # it by 3. The call needs ebx = 0 anyway, so zeroing it first and storing BX costs 7
        # instead of 9, and `push imm8 / pop edx` is 3 where `mov edx,imm32` is 5. Both still
        # earn their keep now the string has moved out, so both stay.
        A-XorEbxEbx $q                       # 0 for the store below AND the call's own argument
        A-Db $q ([byte[]](@(0x66,0x89,0x1D) + [BitConverter]::GetBytes([uint32]$SKIP_FLAG)))
        for ($i = $dw.Count - 1; $i -ge 0; $i--) { A-PushImm32 $q $dw[$i] }   # reverse: esp ends at the first char
        A-Db $q @(0x89,0xE0)                 # mov eax, esp  -- the path
        if ($OPENING_MOVIE_FPS -lt 1 -or $OPENING_MOVIE_FPS -gt 127) {
            throw "OPENING_MOVIE_FPS must fit in a push imm8 (1..127), got $OPENING_MOVIE_FPS"
        }
        A-Db $q ([byte[]]@(0x6A, [byte]$OPENING_MOVIE_FPS, 0x5A))   # push fps / pop edx
        A-Call $q ([uint32]0x20BD4)
        A-AddEspImm $q ([int]($dw.Count * 4))
        A-Popad $q
        # TAIL JUMP, not call+ret: popad has already restored the eax/ebx/edx the displaced
        # call needs, and 0x33F80's own ret then returns to 0x200A5 as if nothing moved.
        A-Jmp $q ([uint32]0x33F80)
    }

    $tArt = Invoke-Asm $q
    foreach ($e in @(@('BoxArt0',$BOX_LOAD), @('BoxArt1',$BOX_SAVEBASE), @('BoxArt2',$BOX_FILL), @('BoxArt3',$BOX_CONV), @('boxOffSurf',$BOX_SURF_OFF),
                     @('boxOnSurf',$BOX_SURF_ON), @('sBoxOff',$BOX_STR_OFF), @('sBoxOn',$BOX_STR_ON),
                     @('AztBoxCode',$BOX_CODE3))) {
        if ($q.Labels[$e[0]] -ne $e[1]) {
            throw ("{0} landed at 0x{1:X}, but the fixed layout says 0x{2:X}" -f $e[0], $q.Labels[$e[0]], $e[1])
        }
    }
    if ($tArt.End -gt $CAVE3_LIMIT) {
        throw ("box art blob is {0} bytes, only {1} available at 0x{2:X}" -f `
               $tArt.Bytes.Length, ($CAVE3_LIMIT - $CAVE3_BASE), $CAVE3_BASE)
    }
    # The extra movie is hooked into the intro sequence's EPILOGUE, at the screen clear that
    # follows the last movie's fade -- not onto the last movie's call. See AztOpenMovie for
    # why: a movie played as a second back-to-back call to 0x20BD4 never gets the teardown the
    # sequence performs after every other movie, and renders skewed.
    if ($ENABLE_OPENING_MOVIE) {
        $mvSite = [uint32]0x200A0
        $mvOff  = Lin2File $mvSite
        $mvOrig = $raw[$mvOff..($mvOff + 4)]
        if ($mvOrig[0] -ne 0xE8) { throw ("opening movie: expected E8 at 0x{0:X5}" -f $mvSite) }
        $mvReal = [uint32]($mvSite + 5 + [BitConverter]::ToInt32(([byte[]]$mvOrig[1..4]), 0))
        if ($mvReal -ne [uint32]0x33F80) {
            throw ("opening movie: 0x{0:X5} calls 0x{1:X5}, expected the epilogue blit 0x33F80" -f $mvSite, $mvReal)
        }
        $patches += New-Patch -Name 'opening-movie' -FileOffset $mvOff `
            -Expect $mvOrig -Replace (CallRel32 $mvSite $q.Labels['AztOpenMovie']) `
            -Note ("{0} plays at {1} fps after the last intro movie has faded, then the epilogue blit runs" -f `
                   $OPENING_MOVIE_NAME, $OPENING_MOVIE_FPS)
    }

    # ---- skipping one cutscene advances to the next ----------------------------
    #
    # The intro sequence checks the skip flag after each movie and, if it is set, jumps to
    # 0x20099 -- the EPILOGUE. So pressing a key during the Mindscape logo abandoned the
    # whole sequence, including the story intro, and dropped the player into the game.
    #
    #     0x1FFA6  cmp word [0x182DB0], 0      (after mindlogo.mov)
    #     0x1FFAE  jnz 0x20099                 -> skip EVERYTHING
    #     0x1FFCF  cmp word [0x182DB0], 0      (after intro.mov)
    #     0x1FFD7  jnz 0x20099
    #     0x20049  cmp word [0x182DB0], 0      (after the title screen)
    #     0x20051  jnz 0x20099                 -- SHORT jnz, 2 bytes, not 6
    #
    # Each pair becomes "clear the flag and carry on", so a skip ends only the movie being
    # watched. The player itself polls the same flag to stop early, so clearing it here is
    # exactly what re-arms the next one.
    #
    # THE THIRD SITE IS NOT OPTIONAL, and leaving it out is worse than not patching at all.
    # The title screen is a timed wait that ALSO breaks early on the flag:
    #
    #     0x20019  call 0x35448          ; delay
    #     0x20024  cmp edx, 0x82         ; ...up to 130 times
    #     0x2002C  cmp word [0x182DB0],0
    #     0x20034  jz  0x20019           ; loop while NOT skipped
    #
    # so the only way past the title screen without waiting it out is to set the flag, and
    # 0x20049 then reads that same flag and throws away the story intro. With the first two
    # sites patched and this one left alone the sequence became mindlogo -> title -> game,
    # losing MOV\INTRO.MOV entirely. All three or none.
    #
    # THE ADDRESS OPERAND IS A RELOCATION and must not be rewritten -- byte 5 holds 0x04 in
    # the file and 0x18 once the loader has fixed it up. `cmp word [disp32],imm8` is
    # 66 83 3D <disp32> <imm8> and `mov word [disp32],imm16` is 66 C7 05 <disp32> <imm16>:
    # the disp32 sits at the SAME offset in both, so only bytes 1-2 and the tail change and
    # the fixup still lands on its own four bytes.
    if ($ENABLE_TITLE_MENU) {
        # 1. THE TITLE WAIT (see $ENABLE_TITLE_MENU). Stock bytes 0x20015..0x20035:
        #      xor edx,edx / jmp 20024 / L: mov eax,20 / call 0x35448 / inc edx / cmp edx,130 / jae out /
        #      cmp word [flag],0 / jz L
        #    The flag's address is the one relocated operand, at 0x2002F; it stays where it is and becomes the
        #    immediate of `mov ecx,&flag` (B9 at 0x2002E), which the loop is built around:
        #      20015  EB 17            jmp 2002E          (load ecx, then into the loop)
        #      20017  66 81 09 00 01   L: or word [ecx],0x0100     the marker: "the title is up"
        #      2001C  66 8B 01         mov ax,[ecx]
        #      2001F  66 99            cwd                          dx = 0xFFFF if the host's 0x8000 is set
        #      20021  66 F7 D2         not dx
        #      20024  30 F6            xor dh,dh                    no host: 0x00FF; host: 0x0000
        #      20026  80 CE 02         or dh,2                      mask: 0x02FF / 0x0200
        #      20029  66 85 D0         test ax,dx
        #      2002C  75 08            jnz 20036          out (on to the fade and the story intro)
        #      2002E  B9 <&flag>       mov ecx,&flag      (the relocated operand)
        #      20033  EB E2            jmp L
        #      20035  90
        #    No delay call: it spins, as the game's own frame loop does. edx/eax are free here (the old counter, and
        #    0x20036 loads eax itself); 0x35448 (the old delay) is never left holding anything.
        $tw = Lin2File ([uint32]0x20015); $twExp = [byte[]]$raw[$tw..($tw + 32)]
        $stockTw = [byte[]]@(0x31, 0xD2, 0xEB, 0x0B, 0xB8, 0x14, 0x00, 0x00, 0x00, 0xE8, 0x25, 0x54, 0x01, 0x00, 0x42, 0x81, 0xFA, 0x82, 0x00, 0x00, 0x00, 0x73, 0x0A, 0x66, 0x83, 0x3D)
        for ($k = 0; $k -lt $stockTw.Length; $k++) { if ($twExp[$k] -ne $stockTw[$k]) { throw ("title menu: 0x{0:X5} is not the stock title wait (byte {1})" -f (0x20015 + $k), $k) } }
        $twFlag = [uint32]([BitConverter]::ToUInt32($twExp, 26) + 0x140000)
        if ($twFlag -ne [uint32]$SKIP_FLAG -or $twExp[30] -ne 0x00 -or $twExp[31] -ne 0x74 -or $twExp[32] -ne 0xE3) { throw ("title menu: the title wait does not test the skip flag (0x{0:X})" -f $twFlag) }
        $twRep = [byte[]](@(0xEB, 0x17, 0x66, 0x81, 0x09, 0x00, 0x01, 0x66, 0x8B, 0x01, 0x66, 0x99, 0x66, 0xF7, 0xD2, 0x30, 0xF6, 0x80, 0xCE, 0x02, 0x66, 0x85, 0xD0, 0x75, 0x08, 0xB9) + $twExp[26..29] + @(0xEB, 0xE2, 0x90))
        if ($twRep.Length -ne 33) { throw "title menu: the new title wait is $($twRep.Length) bytes, not 33" }
        $patches += New-Patch -Name 'title-wait-20015' -FileOffset $tw -Expect $twExp -Replace $twRep `
            -Note 'title waits: marker 0x100 each pass; leaves on a key (no host) or the host''s release 0x200 (host bit 0x8000 set)'
        # 2. KEYS OR THE FLAG (0x362BB): 66 C7 05 <&flag> 01 00 -> 66 83 0D <&flag> 01 90 -- `or word [flag],1`, the
        #    operand in the same place.
        $ki = Lin2File ([uint32]0x362BB); $kiExp = [byte[]]$raw[$ki..($ki + 8)]
        if ($kiExp[0] -ne 0x66 -or $kiExp[1] -ne 0xC7 -or $kiExp[2] -ne 0x05 -or $kiExp[7] -ne 0x01 -or $kiExp[8] -ne 0x00 -or ([BitConverter]::ToUInt32($kiExp, 3) + 0x140000) -ne [uint32]$SKIP_FLAG) { throw 'title menu: 0x362BB is not mov word [skip flag],1' }
        $kiRep = [byte[]](@(0x66, 0x83, 0x0D) + $kiExp[3..6] + @(0x01, 0x90))
        $patches += New-Patch -Name 'title-keyor-362BB' -FileOffset $ki -Expect $kiExp -Replace $kiRep -Note 'keyboard interrupt: or word [skip flag],1 (keeps the title host''s bits)'
        # 3. THE TITLE AFTER THE VIDEOS (Josh, 2026-10-10: "Main logo, second logo video, font based intro video -> Main
        #    title. If clicking space key in any of those videos it will skip to the main title. When starting a new game the
        #    player will then see the custom intro video ... If loading a game they will see the quick loading visor
        #    animation"). Stock order: logo -> logo -> TITLE -> story intro -> epilogue (where AztOpenMovie, 0x200A0, plays the
        #    custom opening movie), any key abandoning the lot. New order, by jumps alone (the blocks hold relocated operands
        #    and cannot move): logo -> logo -> story intro -> TITLE -> epilogue. Each skip check `cmp word [flag],0` becomes
        #    `btr dword [flag],0` -- the same 8 bytes, the operand where it was -- so a key both decides the jump (CF) AND is
        #    cleared: the title always starts with no key pending (its loop would leave at once on one). Then the opening
        #    movie plays only for a new game: the host leaves the flag 0 for that, 1 for a load (it stops the movie at once).
        #      0x1FFA6 (after logo 1)  btr / jc  TITLE              a key: straight to the title
        #      0x1FFCF (after logo 2)  btr / jnc STORY (0x20069)     no key: the story intro; a key: on into the title
        #      0x20044 (title, last)   jmp 0x20099                   (the title's fade-out call) -> the epilogue
        #      0x20049 (after story)   btr / jmp TITLE              (was the post-title check) the story intro -> the title
        #      0x20094 (story, last)   jmp 0x20049                   (the story's fade-out call) -> the check above
        #    (The two fade-outs go: the host covers the title, and the movies' last frames cut to the next thing.)
        # STORY_AT is 0x20069, the intro.mov call's setup, NOT the story block's head 0x20053: that blits the TITLE surface
        # [ebp-0x14] and waits 30 ms (stock: the title, then the story) -- in this order the title has not been loaded
        # yet, so it blitted whatever the stack held (a surface descriptor of garbage: dims and a pixel pointer).
        $TITLE_AT = [uint32]0x1FFDD; $STORY_AT = [uint32]0x20069; $EPI_AT = [uint32]0x20099
        if ($raw[(Lin2File $STORY_AT)] -ne 0xFF -or $raw[(Lin2File $STORY_AT) + 1] -ne 0x35) { throw 'title order: 0x20069 is not push dword [..] (the intro.mov name)' }
        $btrSite = {
            param([uint32]$site, [byte[]]$jump)
            $so = Lin2File $site; $exp = [byte[]]$raw[$so..($so + 7 + $jump.Length)]
            if ($exp[0] -ne 0x66 -or $exp[1] -ne 0x83 -or $exp[2] -ne 0x3D -or $exp[7] -ne 0x00 -or ([BitConverter]::ToUInt32($exp, 3) + 0x140000) -ne [uint32]$SKIP_FLAG) { throw ("title order: 0x{0:X5} is not 'cmp word [skip flag],0'" -f $site) }
            @{ New = [byte[]](@(0x0F, 0xBA, 0x35) + $exp[3..6] + @(0x00) + $jump); Exp = $exp }
        }
        $rel32 = { param([uint32]$from, [uint32]$to) [BitConverter]::GetBytes([int]([int64]$to - [int64]$from)) }
        # after logo 1: jc TITLE (near: 0F 82 rel32, where the near jnz was)
        $r = & $btrSite 0x1FFA6 ([byte[]](@(0x0F, 0x82) + (& $rel32 ([uint32](0x1FFA6 + 14)) $TITLE_AT)))
        if ($r.Exp[8] -ne 0x0F -or $r.Exp[9] -ne 0x85) { throw 'title order: 0x1FFAE is not a near jnz' }
        $patches += New-Patch -Name 'title-order-1FFA6' -FileOffset (Lin2File 0x1FFA6) -Expect $r.Exp -Replace $r.New -Note 'after logo 1: btr [skip flag],0 / jc the title'
        # after logo 2: jnc STORY, else falls into the title
        $r = & $btrSite 0x1FFCF ([byte[]](@(0x0F, 0x83) + (& $rel32 ([uint32](0x1FFCF + 14)) $STORY_AT)))
        if ($r.Exp[8] -ne 0x0F -or $r.Exp[9] -ne 0x85) { throw 'title order: 0x1FFD7 is not a near jnz' }
        $patches += New-Patch -Name 'title-order-1FFCF' -FileOffset (Lin2File 0x1FFCF) -Expect $r.Exp -Replace $r.New -Note 'after logo 2: btr [skip flag],0 / jnc the story intro (a key: on into the title)'
        # the title's fade-out call -> the epilogue
        $so = Lin2File 0x20044; $exp = [byte[]]$raw[$so..($so + 4)]
        if ($exp[0] -ne 0xE8 -or ([uint32](0x20049 + [BitConverter]::ToInt32($exp, 1))) -ne [uint32]0x1FACC) { throw 'title order: 0x20044 is not call 0x1FACC' }
        $patches += New-Patch -Name 'title-order-20044' -FileOffset $so -Expect $exp -Replace ([byte[]](@(0xE9) + (& $rel32 ([uint32]0x20049) $EPI_AT))) -Note 'the title done: jmp the epilogue (the opening movie for a new game)'
        # after the story: btr / jmp short TITLE (the short jnz's place)
        $r = & $btrSite 0x20049 ([byte[]]@(0xEB, [byte](([int]$TITLE_AT - 0x20053) -band 0xFF)))
        if ($r.Exp[8] -ne 0x75) { throw 'title order: 0x20051 is not a short jnz' }
        if (([int]$TITLE_AT - 0x20053) -lt -128) { throw 'title order: the title is out of short-jump reach' }
        $patches += New-Patch -Name 'title-order-20049' -FileOffset (Lin2File 0x20049) -Expect $r.Exp -Replace $r.New -Note 'after the story intro: btr [skip flag],0 / jmp the title'
        # the story's fade-out call -> the check above
        $so = Lin2File 0x20094; $exp = [byte[]]$raw[$so..($so + 4)]
        if ($exp[0] -ne 0xE8 -or ([uint32](0x20099 + [BitConverter]::ToInt32($exp, 1))) -ne [uint32]0x1FACC) { throw 'title order: 0x20094 is not call 0x1FACC' }
        $patches += New-Patch -Name 'title-order-20094' -FileOffset $so -Expect $exp -Replace ([byte[]](@(0xE9) + (& $rel32 ([uint32]0x20099) ([uint32]0x20049)))) -Note 'the story intro done: jmp to the title'
        # 5. A LOAD SKIPS THE OPENING MOVIE (2026-10-10: Continue "went to a black screen"). The movie player 0x20BD4 never
        #    reads the skip flag: it drains the input queue, then plays until a KEY event (type 2) or its frame count --
        #    and every other event (the mouse) counts as a frame. So a load from the title played all of OPENING.MOV (58 MB)
        #    behind the screen unless the mouse happened to move; "stops at once on flag 1" was never true. The title's
        #    exit now tests the HOST'S LOAD BIT (0x0002 -- the keyboard interrupt only ever sets bit 0, so a no-host title
        #    taken with a key still plays the movie) and jumps over the movie's call to the epilogue's wait and free:
        #      0x2003E  test byte [ecx],2 / jnz 0x200A5 / nop     (ecx = &flag: the wait loop's own register -- 0x37FC8
        #                                                       keeps it, its memset pushes and pops it)
        #    (the 6 bytes were `lea eax,[ebp-0x378]` for the fade call 0x20044 no longer makes; no fixup in them)
        $so = Lin2File 0x2003E; $exp = [byte[]]$raw[$so..($so + 5)]
        if ($exp[0] -ne 0x8D -or $exp[1] -ne 0x85 -or [BitConverter]::ToInt32($exp, 2) -ne -0x378) { throw 'title load: 0x2003E is not lea eax,[ebp-0x378]' }
        $so2 = Lin2File 0x200A5; if ($raw[$so2] -ne 0xB8 -or $raw[$so2 + 1] -ne 0x1E) { throw 'title load: 0x200A5 is not mov eax,0x1E (the epilogue wait)' }
        $patches += New-Patch -Name 'title-loadskip-2003E' -FileOffset $so -Expect $exp -Replace ([byte[]]@(0xF6, 0x01, 0x02, 0x75, [byte](0x200A5 - 0x20043), 0x90)) -Note 'the title done: the host''s load bit (2) -> over the opening movie to the epilogue''s wait and free'        # 6. THE LOGO'S MUSIC STOPS AT THE TITLE (Josh, 2026-10-10: "make sure the music stops playing if I skip that intro
        #    logo video"). The intro starts LOGO.WAV through the sound driver (0x1FF56, first free channel = 0) under the
        #    silent MINDLOGO; stock, only the epilogue stopped it (0x200B7: 0x31C11(handle, 0)) -- and a key at the logo now
        #    goes to the TITLE, so it played on under Loading RaptorMod and the menu. The title stage stops channel 0 first,
        #    in the bytes the BLACK title freed: its palette read (0x1FFEE..0x1FFFD) and fade-in (0x2000A..0x20014) are a
        #    fade to black now, so they go and the blit moves down. The driver handle [0x1824E8] needs an obj2 address and
        #    there is no fixup to spare -- so it is reached FROM the one already there: 0x1FFF4's `mov eax,"title.pcx"`
        #    (0x141B2B, relocated by the loader, its operand left exactly as it was) + 0x409BD, both in obj2.
        #      0x1FFEE  nop x6
        #      0x1FFF4  mov eax,0x141B2B              (unchanged: the fixup's)
        #      0x1FFF9  mov eax,[eax+0x409BD]         = [0x1824E8], the sound driver
        #      0x1FFFF  xor edx,edx / call 0x31C11     stop channel 0 (it checks the driver; a stopped channel is a no-op)
        #      0x20006  xor ebx,ebx / xor edx,edx / lea eax,[ebp-0x14] / call 0x33F80     the title's blit, as before
        #      0x20012  nop x3                         -> the wait loop at 0x20015
        $so = Lin2File 0x1FFEE; $exp = [byte[]]$raw[$so..($so + 38)]
        $hexOf = { param([byte[]]$b) ($b | ForEach-Object { '{0:X2}' -f $_ }) -join '' }
        $want = '8D9588FCFFFF' + 'B8' + (& $hexOf ([byte[]]$exp[7..10])) + 'E8' + (& $hexOf ([byte[]]$exp[12..15])) + '31DB31D28D45ECE8' + (& $hexOf ([byte[]]$exp[24..27])) + '8D8588FCFFFFE8' + (& $hexOf ([byte[]]$exp[35..38]))
        if ((& $hexOf $exp) -ne $want) { throw 'title logo stop: 0x1FFEE..0x20014 is not the title''s palette read / blit / fade-in' }
        if ([uint32](0x1FFFE + [BitConverter]::ToInt32($exp, 12)) -ne [uint32]0x3E7B4 -or [uint32](0x2000A + [BitConverter]::ToInt32($exp, 24)) -ne [uint32]0x33F80 -or [uint32](0x20015 + [BitConverter]::ToInt32($exp, 35)) -ne [uint32]0x1FBC2) { throw 'title logo stop: the calls are not 0x3E7B4 / 0x33F80 / 0x1FBC2' }
        if (([BitConverter]::ToUInt32($exp, 7) + 0x140000) -ne [uint32]0x141B2B) { throw 'title logo stop: 0x1FFF4 does not load 0x141B2B ("title.pcx")' }
        $rep = [byte[]](@(0x90,0x90,0x90,0x90,0x90,0x90) + @(0xB8) + $exp[7..10] + @(0x8B,0x80) + [BitConverter]::GetBytes([int](0x1824E8 - 0x141B2B)) +
                        @(0x31,0xD2,0xE8) + (& $rel32 ([uint32]0x20006) ([uint32]0x31C11)) + @(0x31,0xDB,0x31,0xD2,0x8D,0x45,0xEC,0xE8) + (& $rel32 ([uint32]0x20012) ([uint32]0x33F80)) + @(0x90,0x90,0x90))
        if ($rep.Length -ne 39) { throw ("title logo stop: {0} bytes, not 39" -f $rep.Length) }
        $patches += New-Patch -Name 'title-logostop-1FFEE' -FileOffset $so -Expect $exp -Replace $rep -Note 'the title stage: stop sound channel 0 (LOGO.WAV) first; the black title''s palette read and fade-in dropped'
        if ($ENABLE_SKIP_ONE_CUTSCENE) { throw '$ENABLE_SKIP_ONE_CUTSCENE and $ENABLE_TITLE_MENU both rewrite the intro''s skip checks: one or the other' }
        # 4. NO OLD TITLE IMAGE (Josh, 2026-10-10: "We can remove the old title as well that is sandwiched in the intro
        #    movies (its a still image)") -- done with ART, not code: TITLE.PCX is an all-black 1600x1200 image
        #    (src\Build-Title.ps1 -Import -InDir design\title-black). Jumping over the load (0x1FFDD -> 0x20015) and the
        #    free (0x20036 -> 0x20099) was tried and is WRONG (whether it caused that session's hang or the movie below did): the epilogue's 0x200A0 blit
        #    (AztOpenMovie's hook) and 0x200B2 free both take the surface at [ebp-0x14], which only the TITLE.PCX load at
        #    0x1FFE9 ever fills (the frame's enter 0x378 leaves it garbage). Never skip that load.
    }
    if ($ENABLE_SKIP_ONE_CUTSCENE) {
        foreach ($site in @(0x1FFA6, 0x1FFCF, 0x20049)) {
            $so = Lin2File ([uint32]$site)
            # the compare is always 8 bytes; the jump that follows it is not
            $cmp = $raw[$so..($so + 7)]
            if ($cmp[0] -ne 0x66 -or $cmp[1] -ne 0x83 -or $cmp[2] -ne 0x3D -or $cmp[7] -ne 0x00) {
                throw ("skip-one: 0x{0:X5} is not 'cmp word [skipFlag],0'" -f $site)
            }
            # the operand is pre-fixup in the file; add the obj2 base to compare it
            $flagLin = [uint32]([BitConverter]::ToUInt32(([byte[]]$cmp[3..6]), 0) + 0x140000)
            if ($flagLin -ne [uint32]$SKIP_FLAG) {
                throw ("skip-one: 0x{0:X5} tests 0x{1:X5}, not the skip flag 0x{2:X5}" -f $site, $flagLin, $SKIP_FLAG)
            }
            $j = $raw[($so + 8)..($so + 9)]
            if ($j[0] -eq 0x0F -and $j[1] -eq 0x85) {
                $jLen = 6
                $tgt  = [uint32]($site + 14 + [BitConverter]::ToInt32(([byte[]]$raw[($so + 10)..($so + 13)]), 0))
            } elseif ($j[0] -eq 0x75) {
                $jLen = 2
                $tgt  = [uint32]($site + 10 + [int][sbyte]$j[1])
            } else {
                throw ("skip-one: 0x{0:X5} is not followed by a jnz (got {1:X2} {2:X2})" -f $site, $j[0], $j[1])
            }
            if ($tgt -ne [uint32]0x20099) {
                throw ("skip-one: 0x{0:X5} jumps to 0x{1:X5}, expected the epilogue 0x20099" -f $site, $tgt)
            }
            $total = 8 + $jLen
            $exp   = $raw[$so..($so + $total - 1)]
            $rep   = [byte[]]$exp.Clone()
            $rep[1] = 0xC7; $rep[2] = 0x05          # cmp -> mov, same operand position
            $rep[7] = 0x00; $rep[8] = 0x00          # imm16 = 0 -- the mov is 9 bytes, one more
            for ($k = 9; $k -lt $total; $k++) { $rep[$k] = 0x90 }   # than the 8-byte cmp
            $patches += New-Patch -Name ("skip-one-{0:X}" -f $site) -FileOffset $so `
                -Expect $exp -Replace $rep `
                -Note 'skipping a cutscene clears the skip flag and plays the next one, instead of abandoning the intro'
        }
    }

    $o3 = Lin2File $CAVE3_BASE
    $patches += New-Patch -Name 'box-art-blob' -FileOffset $o3 `
        -Expect $raw[$o3..($o3 + $tArt.Bytes.Length - 1)] -Replace $tArt.Bytes `
        -Note ("log box frames: boxoff.pcx {0}x{1} / boxon.pcx {0}x{2}, recess {3}x{4}" -f `
               $FRAME_W, $FRAME_H_SMALL, $FRAME_H_BIG, $RECESS_W, $RECESS_H_SMALL)
    Write-Host ("box art blob: {0} bytes of {1} at 0x{2:X}" -f `
                $tArt.Bytes.Length, ($CAVE3_LIMIT - $CAVE3_BASE), $CAVE3_BASE)


    # --- and the three sites AztConvHit takes over ---------------------------
    # The option table moves into the text surface's own coordinates, so the
    # +0x59 that used to turn it into screen Y goes away and the picker's
    # bounds become the surface's, not the old box's. AztConvHit does the
    # screen->surface conversion and rejects anything outside the open recess
    # itself, so the lower bound here is only a formality.
    $convHit = $q.Labels['AztConvHit']
    $patches += Patch-Imm32 -Name 'conv-hit-table-1809E' -Lin 0x1809E -Size 1 -Old 0x59 -New 0 `
        -Note 'per-option hit table is in text-surface rows, not screen rows'
    $patches += Patch-Imm32 -Name 'conv-hit-lo-180EA' -Lin 0x180EA -Size 1 -Old 0x59 -New 0 `
        -Note 'option picker lower bound: the top of the text surface'
    $patches += Patch-Imm32 -Name 'conv-hit-hi-180F3' -Lin 0x180F3 -Old 0x126 -New ($TEXTBOX_H - 1) `
        -Note ("option picker upper bound: the bottom of the {0}-row text surface" -f $TEXTBOX_H)
    $oCall = Lin2File 0x2D0BD
    $patches += New-Patch -Name 'conv-hit-call-2D0BD' -FileOffset $oCall `
        -Expect (CallRel32 0x2D0BD $CONV_PICK) -Replace (CallRel32 0x2D0BD $convHit) `
        -Note ("conversation click goes through AztConvHit at 0x{0:X}: screen Y -> text-surface row" -f $convHit)

    $convBoxZ = $null
    if ($ENABLE_CONV_BOX_LATCH) { $convBoxZ = $ovlAsm.Labels['AztConvBoxZ']; if (-not $convBoxZ) { throw "AztConvBoxZ is not in the overlay" } }
    $t = New-Asm -Base $CAVE2_BASE

    # --- the three fixed entry points. FIRST, IN THIS ORDER, 5 bytes each ---
    Add-Label $t 'BoxTramp0'; A-Jmp $t 'AztBoxClick'
    Add-Label $t 'BoxTramp1'; A-Jmp $t 'AztBoxScroll'
    Add-Label $t 'BoxTramp2'; A-Jmp $t 'AztBoxPrep'

    Add-Label $t 'aztBoxBig'; A-Dw $t 0        # the sticky user toggle
    Add-Label $t 'aztBoxLmb'; A-Dw $t 0        # last frame's button, for the edge

    # A local copy of AztDeltas: esi = obj1 delta, edi = obj2 delta. Duplicated
    # rather than called so this blob has no build-order dependency on the stub.
    Add-Label $t 'AztBoxDeltas'
    A-CallNext $t
    Add-Label $t 'AztBoxRef'
    A-PopEax $t
    A-SubEaxImm $t 'AztBoxRef'
    A-MovEsiEax $t
    A-MovEaxSi  $t $FIXUP_SRC
    A-SubEaxImm $t $g_mouselookOn
    A-MovEdiEax $t
    A-Ret $t

    # --- eax = the scroll offset that applies right now -----------------------
    # An expanded box shows the whole text surface, so there is nothing hidden
    # above it and the offset is zero. aztLogScroll itself is left alone, so
    # collapsing returns you to where you were reading.
    # It also narrows the surface to the visible WINDOW and paints the window's
    # background, both of which have to happen between the clear and the text.
    #
    # THE BOX IS ALWAYS BLITTED AT ITS FULL EXPANDED EXTENT. Blitting only the
    # collapsed 84 rows at y=499 left rows 489..498 -- the ten rows of panel art
    # between the viewport's bottom edge and the top of the well -- holding
    # whatever the expanded box last drew there, because the 3D view repaints
    # 0..488 every frame and nothing repaints the panel. Painting the whole
    # 379..582 span every frame, transparent above the window, cannot leave a
    # residue anywhere. Only the DRAW side narrows, because 0x37D98 clamps a
    # positive destination Y to zero and so cannot be asked to start at row 120.
    # THE EXTENT AND THE BLIT Y MUST BE DECIDED TOGETHER. They used to be set in
    # two different routines at two different moments -- the height when the text
    # drew, the Y when the box blitted -- and the two could disagree. Collapse the
    # box and the height stayed at 204 until the log next printed something, while
    # the Y had already gone back to 499: a 204-row blit starting at 499 ran off
    # the bottom of the panel, which is the black background spilling out of the
    # well. One routine, one answer.
    #
    #   in:  esi/edi deltas    out: eax base, ecx window bytes, ebx blit Y,
    #                               edx the scroll offset to apply
    Add-Label $t 'AztBoxWindow'
    A-Call $t $BOX_SAVEBASE                      # make sure aztBoxBuf is filled in
    A-CmpWordSiImm $t 'aztBoxBig' 0
    A-JnzS $t 'ABW_big'
    if ($ENABLE_CONV_BOX_LATCH) {
        A-Call $t $convBoxZ                    # the conversation holds it open once its options print (ZF)
        A-JzS $t 'ABW_big'
    } else {
        A-CmpWordDiImm $t $g_convList 0
        A-JnzS $t 'ABW_big'
    }
    # collapsed: the window is the LAST $RECESS_H_SMALL rows of the buffer
    A-Db   $t @(0x8B,0x86); Add-Abs32 $t $BOX_BUF
    A-Db   $t @(0x05);      Add-Abs32 $t $BOX_BASE_OFF
    A-Db   $t @(0xB9);      Add-Abs32 $t ($RECESS_H_SMALL * $RECESS_W)   # mov ecx, window bytes
    A-Db   $t @(0x66,0xC7,0x87); Add-Abs32 $t ($SURF_BOX + 2);   A-Dw $t $RECESS_H_SMALL
    A-Db   $t @(0x66,0xC7,0x87); Add-Abs32 $t ($SURF_BOX + 0xE); A-Dw $t ($RECESS_H_SMALL - 1)
    A-Db   $t @(0xBA);      Add-Abs32 $t $BOX_MAXOFF_SMALL        # mov edx, furthest back
    A-Db   $t @(0x8D,0xAE); Add-Abs32 $t $BOX_SURF_OFF            # lea ebp, [esi+closed frame]
    A-MovEbxImm $t $RECESS_Y_SMALL
    A-JmpS $t 'ABW_set'
    Add-Label $t 'ABW_big'
    A-Db   $t @(0x8B,0x86); Add-Abs32 $t $BOX_BUF
    A-Db   $t @(0xB9);      Add-Abs32 $t ($RECESS_H_BIG * $RECESS_W)
    A-Db   $t @(0x66,0xC7,0x87); Add-Abs32 $t ($SURF_BOX + 2);   A-Dw $t $RECESS_H_BIG
    A-Db   $t @(0x66,0xC7,0x87); Add-Abs32 $t ($SURF_BOX + 0xE); A-Dw $t ($RECESS_H_BIG - 1)
    A-Db   $t @(0xBA);      Add-Abs32 $t $BOX_MAXOFF_BIG
    A-Db   $t @(0x8D,0xAE); Add-Abs32 $t $BOX_SURF_ON             # lea ebp, [esi+open frame]
    A-MovEbxImm $t $RECESS_Y_BIG
    Add-Label $t 'ABW_set'
    A-Db   $t @(0x89,0x87); Add-Abs32 $t ($SURF_BOX + 4)          # mov [edi+surf+4], eax
    # edx is how far back this state CAN go; aztLogScroll is how far back the
    # player asked to go. Clamp there and write it back, because the key handlers
    # deliberately do not know the limit -- it changes when the box does, and a
    # value left over from the other state would scroll into blank surface.
    # The scratch is EAX, not ebp: ebp now carries the frame to copy, and eax has
    # already been written into the surface so it can simply be read back.
    A-Db   $t @(0x0F,0xB7,0x86); Add-Abs32 $t $asm.Labels['aztLogScroll']  # movzx eax,[esi+scroll]
    A-Db   $t @(0x39,0xD0)                                        # cmp eax, edx
    A-JbeS $t 'ABW_off'
    A-Db   $t @(0x89,0xD0)                                        # mov eax, edx
    A-Db   $t @(0x66,0x89,0x86); Add-Abs32 $t $asm.Labels['aztLogScroll']  # mov [esi+scroll], ax
    Add-Label $t 'ABW_off'
    A-Db   $t @(0x29,0xC2)                                        # sub edx, eax -> rows to skip
    A-Db   $t @(0x8B,0x87); Add-Abs32 $t ($SURF_BOX + 4)          # mov eax, the window base
    A-Ret  $t

    Add-Label $t 'AztBoxScroll'
    A-Call $t 'AztBoxDeltas'
    A-Call $t $BOX_LOAD                                           # first call only
    A-Call $t 'AztBoxWindow'      # eax base, ecx bytes, edx scroll, ebx Y, ebp frame
    # The recess background comes STRAIGHT OUT OF THE FRAME IMAGE. A flat fill
    # was close but not the same thing: the measured recess is a pixel or two
    # bigger than the flat part of the art, so a solid colour laid over it
    # clipped the inner bevel. Copying the real pixels cannot disagree with
    # the frame, because it IS the frame.
    A-Call $t $BOX_FILL
    A-Db   $t @(0x89,0xD0)                                        # mov eax, edx (the scroll)
    A-Ret $t

    # The surface's real pixel base, recorded before we ever move it. Reading it
    # back later would give whichever end we last pointed at.

    # --- return ebx = the Y to blit the window at ------------------------------
    # BLIT THE WINDOW, NOT THE WHOLE SURFACE. Blitting the full 379..582 extent
    # every frame was an attempt to stop the collapsed box leaving a residue in
    # the ten rows of panel art above the well, and it FLICKERED: index 0 is not
    # transparent here, so a collapsed box painted a black 174x204 rectangle over
    # the 3D view and the two fought over those rows frame by frame. The view is
    # opaque and redrawn every frame; anything of ours that overlaps it has to be
    # something we mean to show.
    #
    # It re-runs AztBoxWindow rather than trusting whatever the last text draw
    # left behind: the log only prints when something happens, so on a quiet frame
    # the extent could be a state or two out of date.
    Add-Label $t 'AztBoxPrep'
    A-Db   $t @(0x60)                          # pushad
    A-Call $t 'AztBoxDeltas'
    # LOAD HERE TOO, not only in AztBoxScroll. Only the STORY TEXT draw goes
    # through AztBoxScroll; a conversation takes the list path (AztLogClearCx ->
    # 0x37E74) and never touches it. Talk to someone before any narration has
    # been printed and this blitted a surface header 0x37AC8 had never filled in,
    # i.e. a null pixel pointer -- which is the crash on starting a dialogue.
    A-Call $t $BOX_LOAD
    A-Call $t $BOX_CONV                        # once per conversation, not per frame
    A-Call $t 'AztBoxWindow'                   # ebx = the recess's Y, ebp = its frame
    # Belt and braces: if the PCX is missing the header exists but its pixels do
    # not, and a blit of that would fault just the same.
    A-Db   $t @(0x83,0x7D,0x04,0x00)                       # cmp dword [ebp+4], 0
    A-JzS  $t 'ABP_noframe'
    # THE FRAME GOES DOWN FIRST, underneath the recess the caller is about to
    # blit. Doing it here rather than in the caller means every route that draws
    # the box gets it: the per-frame repaint after the view, and the HUD redraw
    # the movement code triggers. The frame's Y is the recess's less the offset
    # the artwork measured, and Blit preserves ebx so the caller still gets it.
    A-Db   $t @(0x53)                                      # push ebx
    A-Db   $t @(0x83,0xEB, [byte]$RECESS_DY)               # sub ebx, recess top
    A-Db   $t @(0x89,0xE8)                                 # mov eax, ebp (the frame)
    A-Db   $t @(0xBA); Add-Abs32 $t $FRAME_X               # mov edx, frame X
    A-Call $t $BLIT
    A-Db   $t @(0x5B)                                      # pop ebx
    Add-Label $t 'ABP_noframe'
    # popad would undo the return value, so write ebx into its own saved slot.
    # pushad pushes eax..edi, so from the current esp: edi+0, esi+4, ebp+8,
    # esp+0xC, ebx+0x10.
    A-Db   $t @(0x89,0x5C,0x24,0x10)           # mov [esp+0x10], ebx
    # No icon to draw: the chevron is part of BOXOFF/BOXON now.
    A-Db   $t @(0x61)                          # popad
    A-Ret  $t

    # --- the toggle square, painted straight into the surface -----------------

    # --- the icon's hit test, once a frame from AztFrameHook ------------------
    Add-Label $t 'AztBoxClick'
    A-Db   $t @(0x60)                          # pushad
    A-Call $t 'AztBoxDeltas'
    A-Db   $t @(0x0F,0xB7,0x87); Add-Abs32 $t $g_lmbHeld          # movzx eax, [edi+lmb]
    A-Db   $t @(0x0F,0xB7,0x8E); Add-Abs32 $t 'aztBoxLmb'         # movzx ecx, [esi+last]
    A-Db   $t @(0x66,0x89,0x86); Add-Abs32 $t 'aztBoxLmb'         # mov [esi+last], ax
    A-Db   $t @(0x66,0x85,0xC0)                # test ax, ax
    A-JzS  $t 'ABC_out'                        # not held
    A-Db   $t @(0x66,0x85,0xC9)                # test cx, cx
    A-JnzS $t 'ABC_out'                        # held last frame too -- not an edge

    A-Db   $t @(0x0F,0xB7,0x87); Add-Abs32 $t $g_mouseX
    A-Db   $t @(0x3D); Add-Abs32 $t ($FRAME_X + $BOX_ICON_X0)
    A-JbS  $t 'ABC_out'
    A-Db   $t @(0x3D); Add-Abs32 $t ($FRAME_X + $BOX_ICON_X1)
    A-JaS  $t 'ABC_out'
    A-Db   $t @(0x0F,0xB7,0x87); Add-Abs32 $t $g_mouseY
    # The icon rides the box's top edge, so which Y to expect depends on the
    # state we are currently IN, not the one we are about to switch to.
    A-Db   $t @(0xBA); Add-Abs32 $t $FRAME_Y_SMALL                  # mov edx, small top
    A-CmpWordSiImm $t 'aztBoxBig' 0
    A-JnzS $t 'ABC_bigY'
    if ($ENABLE_CONV_BOX_LATCH) {
        A-Call $t $convBoxZ                    # (keeps eax: the mouse Y)
        A-JnzS $t 'ABC_haveY'
    } else {
        A-CmpWordDiImm $t $g_convList 0
        A-JzS  $t 'ABC_haveY'
    }
    Add-Label $t 'ABC_bigY'
    A-Db   $t @(0xBA); Add-Abs32 $t $FRAME_Y_BIG
    Add-Label $t 'ABC_haveY'
    A-Db   $t @(0x29,0xD0)                     # sub eax, edx  -> box-local Y
    A-Db   $t @(0x3D); Add-Abs32 $t $BOX_ICON_Y0
    A-JbS  $t 'ABC_out'
    A-Db   $t @(0x3D); Add-Abs32 $t $BOX_ICON_Y1
    A-JaS  $t 'ABC_out'

    Add-Label $t 'ABC_toggle'                 # (the toggle itself: also the E key's way in -- key-e-*, below)
    A-Db   $t @(0x66,0x83,0xB6); Add-Abs32 $t 'aztBoxBig'; A-Db $t @(0x01)  # xor word [esi+big],1
    # Collapsing puts the reading position back at the newest text: while it was
    # expanded the arrows still moved aztLogScroll, with nothing on screen to
    # show for it, so it could be anywhere.
    A-CmpWordSiImm $t 'aztBoxBig' 0
    A-JnzS $t 'ABC_snd'
    A-MovWordSiImm $t $asm.Labels['aztLogScroll'] 0   # back to the newest text
    # ...and it makes the system menu's noise, because it is the same gesture: a
    # panel sliding open over the view. Only the TOGGLE path reaches here -- every
    # "not our click" exit above jumps straight to ABC_out -- so it fires once per
    # actual state change and not once per frame while the button is held.
    Add-Label $t 'ABC_snd'
    A-Db   $t @(0x8D,0x87); Add-Abs32 $t $SND_MENU    # lea eax,[edi+"hudlockr.wav"]
    A-Call $t $SFX_PLAY
    Add-Label $t 'ABC_out'
    A-Db   $t @(0x61)                          # popad
    A-Ret  $t

    # --- repaint the box every time the view reaches the screen ---------------
    # THIS IS WHY THE EXPANDED BOX FLICKERED. The box's own blit lives in
    # 0x11E68, a real HUD-redraw function -- but one the MOVEMENT code calls, not
    # the frame loop. log-box-always only made the blit unconditional INSIDE that
    # function; it did nothing about how often the function runs. The 3D view is
    # painted every frame and is opaque, so an expanded box got wiped and only
    # came back when something moved. Collapsed it sits below the view entirely,
    # which is exactly why it never flickered in that state.
    #
    # So: wrap the view's own Blit. Every `mov eax,0x152150 / ... / call 0x33F80`
    # becomes a call here instead, which does the real blit and then puts the box
    # back on top. The operand is rel32, so none of the 18 sites has a fixup in
    # the way.
    Add-Label $t 'AztBoxAfterView'
    A-Call $t $BLIT                                    # the view, as before
    A-Db   $t @(0x60)                                  # pushad
    A-Call $t 'AztBoxPrep'                             # ebx = the box's Y, extents set
    A-Call $t 'AztBoxDeltas'                           # edi = obj2 delta; leaves ebx alone
    A-Db   $t @(0x8D,0x87); Add-Abs32 $t $SURF_BOX     # lea eax, [edi+surf]
    A-Db   $t @(0xBA);      Add-Abs32 $t $RECESS_X       # mov edx, X
    A-Call $t $BLIT
    A-Db   $t @(0x61)                                  # popad
    A-Ret  $t

    $tBox = Invoke-Asm $t
    foreach ($e in @(@('BoxTramp0',$BOX_CLICK), @('BoxTramp1',$BOX_SCROLL), @('BoxTramp2',$BOX_PREP))) {
        if ($t.Labels[$e[0]] -ne $e[1]) {
            throw ("{0} is at 0x{1:X}, but the stub calls 0x{2:X}" -f $e[0], $t.Labels[$e[0]], $e[1])
        }
    }
    if ($tBox.End -gt $CAVE2_LIMIT) {
        throw ("box blob is {0} bytes, only {1} available at 0x{2:X}" -f `
               $tBox.Bytes.Length, ($CAVE2_LIMIT - $CAVE2_BASE), $CAVE2_BASE)
    }
    # Every site that paints the view surface onto the screen, found by scanning
    # obj1 for `mov eax,0x152150` with a call to Blit within the next 24 bytes.
    $afterView = $t.Labels['AztBoxAfterView']
    $nView = 0
    for ($lin = 0x10000; $lin -lt 0x132000; $lin++) {
        if ($raw[(Lin2File ([uint32]$lin))] -ne 0xB8) { continue }
        # IN THE FILE the operand is the OBJ-RELATIVE offset, 0x12150 -- the loader
        # writes obj2's base over it from the fixup record. Searching for the
        # linear address finds nothing at all, which is how this first ran.
        if ([BitConverter]::ToUInt32($raw, (Lin2File ([uint32]($lin+1)))) -ne 0x12150) { continue }
        for ($k = 5; $k -le 24; $k++) {
            $at = [uint32]($lin + $k)
            $fo = Lin2File $at
            if ($raw[$fo] -ne 0xE8) { continue }
            $exp = CallRel32 $at $BLIT
            $same = $true
            for ($j = 0; $j -lt 5; $j++) { if ($raw[$fo+$j] -ne $exp[$j]) { $same = $false; break } }
            if (-not $same) { continue }
            $patches += New-Patch -Name ("box-after-view-{0:X}" -f $at) -FileOffset $fo `
                -Expect $exp -Replace (CallRel32 $at $afterView) `
                -Note 'view blit also repaints the log box, so the view cannot wipe it'
            $nView++
            break
        }
    }
    if ($nView -lt 10) { throw "only $nView view-to-screen blits found; expected 18" }
    Write-Host ("log box repainted after {0} view blits" -f $nView)

    # ---- TWO KEYS (Josh, 2026-10-09): ESC opens and closes the system menu, E expands / collapses the log ----------------
    # docs\system-menu-RE.md s5. ESC reaches 0x13713 only when nothing else uses it (not speaking, no conversation, no slot
    # picked / name being typed, no book view, picture modal, opening hold or death) -- there it did nothing; now it issues
    # command 5, exactly as the menu button (cmd 5 keeps its own refusals: animating, help/map, scripts). 'e' and 'E' were
    # unbound; they now run the log box's own toggle (AztBoxClick's tail: flip aztBoxBig, collapse = back to the newest text,
    # hudlockr.wav) -- save-name typing returns before this dispatch, so a name can still hold an E. No new cave bytes: three
    # of the handler's duplicate "no match" epilogues become short jumps to a surviving one, and their room holds the code.
    # All six sites fixup-free and no branch lands inside them (checked in the RE).
    $epi = [byte[]]@(0x81, 0xC4, 0x3C, 0x03, 0x00, 0x00, 0x5F, 0x5E, 0x5A, 0x59, 0x5B, 0xC3)
    $abcT = [uint32]$t.Labels['ABC_toggle']; $abcD = [uint32]$t.Labels['AztBoxDeltas']
    if (-not $abcT -or -not $abcD) { throw 'keys: ABC_toggle / AztBoxDeltas not found in the box blob' }
    $rel = { param([uint32]$from, [uint32]$to) $v = [uint32](([int64]$to - [int64]$from + 4294967296) % 4294967296); [byte[]]@(($v -band 0xFF), (($v -shr 8) -band 0xFF), (($v -shr 16) -band 0xFF), (($v -shr 24) -band 0xFF)) }
    $t2 = & $rel ([uint32]0x136D4) $abcT; $t1 = & $rel ([uint32]0x13682) $abcD
    $keyPatches = @(
        @('key-esc-13713', 0x13713, [byte[]]@(0x84, 0xC0, 0x0F, 0x84, 0x2E, 0xF9, 0xFF, 0xFF), [byte[]]@(0x84, 0xC0, 0x74, 0xB3, 0x3C, 0x1B, 0x74, 0x83), 'test al,al / jz Z / cmp al,ESC / jz E (else the epilogue at 0x1371B)'),
        @('key-esc-body-1369C', 0x1369C, $epi, [byte[]]@(0xEB, 0x7D, 0x6A, 0x05, 0x58, 0xE8, 0x62, 0x8D, 0x01, 0x00, 0xEB, 0x73), "'0' -> 0x1371B; E: push 5 / pop eax / call 0x2C408 (cmd 5: the system menu) / jmp 0x1371B"),
        @('key-z-136C8', 0x136C8, $epi, ([byte[]](@(0xEB, 0x51, 0xE9, 0x7A, 0xF9, 0xFF, 0xFF, 0xE9) + $t2)), "'&'..'+' -> 0x1371B; Z: jmp 0x13049 (the scancode keys, moved from 0x13713); T2: jmp ABC_toggle"),
        @('key-t1-1367A', 0x1367A, $epi, ([byte[]](@(0xEB, 0x20, 0x60, 0xE8) + $t1 + @(0xEB, 0x4B, 0x90, 0x90))), "'6'..';' -> 0x1369C; T1: pushad / call AztBoxDeltas / jmp T2"),
        @('key-e-135F6', 0x135F6, $epi, [byte[]]@(0x3C, 0x65, 0x75, 0x10, 0xE8, 0x7D, 0x00, 0x00, 0x00, 0xEB, 0x09, 0x90), "'e': call T1 (toggle the log box), then the epilogue at 0x1360A"),
        @('key-E-13628', 0x13628, $epi, [byte[]]@(0x3C, 0x45, 0x75, 0x10, 0xE8, 0x4B, 0x00, 0x00, 0x00, 0xEB, 0x09, 0x90), "'E': call T1 (toggle the log box), then the epilogue at 0x1363C"))
    foreach ($kp in $keyPatches) {
        if ($kp[2].Length -ne $kp[3].Length) { throw ("{0}: {1} bytes expected, {2} given" -f $kp[0], $kp[2].Length, $kp[3].Length) }
        $patches += New-Patch -Name $kp[0] -FileOffset (Lin2File ([uint32]$kp[1])) -Expect $kp[2] -Replace $kp[3] -Note $kp[4]
    }
    Write-Host ("keys: ESC = the system menu (cmd 5), E = the log box (ABC_toggle 0x{0:X}, AztBoxDeltas 0x{1:X})" -f $abcT, $abcD)

    $o = Lin2File $CAVE2_BASE
    $patches += New-Patch -Name 'box-blob' -FileOffset $o `
        -Expect $raw[$o..($o + $tBox.Bytes.Length - 1)] -Replace $tBox.Bytes `
        -Note ("log box recess: {0}x{1} -> {0}x{2}, toggle at ({3},{4})" -f `
               $RECESS_W, $RECESS_H_SMALL, $RECESS_H_BIG, ($FRAME_X + $BOX_ICON_X0), ($FRAME_Y_SMALL + $BOX_ICON_Y0))
    Write-Host ("box blob: {0} bytes of {1} at 0x{2:X}  (collapsed y={3}, expanded y={4})" -f `
                $tBox.Bytes.Length, ($CAVE2_LIMIT - $CAVE2_BASE), $CAVE2_BASE, $FRAME_Y_SMALL, $FRAME_Y_BIG)
}

    # The compass. COMPMAP.PCX is a 348x24 sprite (surface built at 0x10C09/0x10C0E
    # with ebx=0x18, edx=0x15C) blitted straight to the screen at 0x13F0C with
    # ebx=Y at 0x13EFD and edx=X at 0x13F02.
    #
    # X is 0x92 = 146 = (640 - 348) / 2 -- dead centre of a 640-wide screen, and
    # therefore 80px LEFT of centre on an 800-wide one. It is NOT derived from any
    # screen constant, so nothing in the scr-* family moved it.
    #
    # Only X changes: the sprite keeps its native size (scaling it would mean
    # resizing its pixel buffer, and the degree-label loop at 0x13EA3 draws into
    # that buffer with a hard-coded 15px-per-15-degrees step), and Y stays at 15
    # because the strip above the viewport no longer scales either.
    $COMPASS_X_OLD = 146
    $COMPASS_X     = [int](($SCREEN_W - $COMPASS_W) / 2)
    if ($COMPASS_X -lt 0) { throw "the compass is wider than the screen" }
    if ($COMPASS_X -ne $COMPASS_X_OLD) {
        $patches += Patch-Imm32 -Name 'hud-comp-x-13F02' -Lin 0x13F02 -Old $COMPASS_X_OLD -New $COMPASS_X `
            -Note ("compass X {0} -> {1} (centred on a {2}-wide screen)" -f $COMPASS_X_OLD, $COMPASS_X, $SCREEN_W)
    }

    # ---- every OTHER hand-centred readout ------------------------------------
    # Found by sweeping all `call 0x33F80` (blit surface to screen) sites for a
    # hard-coded edx, then checking each against (640 - surfaceWidth) / 2. Only
    # these two were left; everything else was already 0 (view-relative) or in the
    # scr-*/hud-* families.
    #
    #   0x10B7E  the "-%d-" counter above the compass. sprintf of the format at
    #            0x1400C3 into an 80x13 surface built at 0x10AC0, text centred
    #            inside it, blitted at 280 = (640-80)/2. This is a STOCK readout,
    #            not something the mod added -- it just sat 80px off-centre.
    #   0x10877  a 180x40 caption surface (0x152390, created at 0x10926/0x1092C,
    #            text centred inside it at 0x1084F), blitted at 230 = (640-180)/2.
    #
    # Only X moves. Neither Y is a centring expression (0 and 120), and the strip
    # these sit in does not scale -- same reasoning as the compass.
    foreach ($c in @(@{ at=0x10B7E; w=80;  old=280; n='num'; what='"-%d-" counter' },
                     @{ at=0x10877; w=180; old=230; n='cap'; what='caption box' })) {
        if ($c.old -ne [int](($SCREEN_W_OLD - $c.w) / 2)) {
            throw ("blit X {0} at 0x{1:X} is not (640 - {2}) / 2 -- the surface is not what this expects" -f $c.old, $c.at, $c.w)
        }
        $newX = [int](($SCREEN_W - $c.w) / 2)
        if ($newX -ne $c.old) {
            $patches += Patch-Imm32 -Name ("hud-{0}-x-{1:X}" -f $c.n, $c.at) -Lin $c.at -Old $c.old -New $newX `
                -Note ("{0} ({1}px wide) re-centred: X {2} -> {3}" -f $c.what, $c.w, $c.old, $newX)
        }
    }

    # The scan readout is drawn from TWO places. hud-scan-*-12336 only moved one;
    # this is the other (surface 0x152AD4 at the same stock 470,380). Its Y is
    # handled with the first site's, above -- box-prep-127F9 takes it over when
    # the expanding box is on, and patching it twice would collide.
    if ($SCAN_X -ne $SCAN_X_OLD) { $patches += Patch-Imm32 -Name 'hud-scan-x-127FE' -Lin 0x127FE -Old $SCAN_X_OLD -New $RECESS_X -Note 'scan readout X -> right gutter (second draw site)' }
}

# If the resolution is left at stock, the hires block below does not run and
# nothing else owns the 4F02h mode number -- the LFB bit would simply be dropped.
# Request it here in that case, at the same site and for the same reason, so that
# turning $ENABLE_HIRES off cannot silently disable the linear framebuffer too.
if (-not $ENABLE_HIRES -and $LFB_MODE_BIT) {
    $stockSet = [uint32]($VESA_MODE_OLD -bor $LFB_MODE_BIT)
    $patches += Patch-Imm32 -Name 'vesa-mode-33ABB' -Lin 0x33ABB -Old $VESA_MODE_OLD -New $stockSet `
        -Note ("VESA mode 0x{0:X} -> 0x{1:X} (stock resolution, linear framebuffer requested)" -f $VESA_MODE_OLD, $stockSet)
}

# ---- screen resolution -----------------------------------------------------
# Same discipline as the viewport family: the mode number, then every constant
# derived from the screen's width and height. Grouped so a boot test can isolate
# them from the viewport work.
if ($ENABLE_HIRES) {
    # The VESA mode itself: set (0x33ABB), the two mode-list scans, and get-info.
    #
    # 0x33ABB is the 4F02h SET site and it is the ONLY one that may carry the
    # linear-framebuffer bit -- the 4F01h mode-info and mode-list sites must see the
    # plain mode number or they will not match the BIOS's own tables. This patch is
    # the single owner of those four bytes; the LFB block deliberately no longer
    # patches them, it just supplies $LFB_MODE_BIT. See the long note there.
    $modeSet = [uint32]($VESA_MODE -bor $LFB_MODE_BIT)
    $patches += Patch-Imm32 -Name 'vesa-mode-33ABB' -Lin 0x33ABB -Old $VESA_MODE_OLD -New $modeSet -Note ("VESA mode 0x{0:X} -> 0x{1:X} ({2}x{3}x8{4})" -f $VESA_MODE_OLD,$modeSet,$SCREEN_W,$SCREEN_H,$(if ($LFB_MODE_BIT) { ', linear framebuffer requested' } else { '' }))
    $patches += Patch-Imm32 -Name 'vesa-mode-33C03' -Lin 0x33C03 -Old $VESA_MODE_OLD -New $VESA_MODE -Size 2 -Note 'VESA mode-list scan'
    $patches += Patch-Imm32 -Name 'vesa-mode-33C17' -Lin 0x33C17 -Old $VESA_MODE_OLD -New $VESA_MODE -Size 2 -Note 'VESA mode-list scan'
    $patches += Patch-Imm32 -Name 'vesa-mode-33C4C' -Lin 0x33C4C -Old $VESA_MODE_OLD -New $VESA_MODE -Note 'VESA get-mode-info (AX=4F01h)'

    # full-screen surfaces: `mov ebx,480 / mov edx,640` immediately before a
    # create. Listed as (heightSite, widthSite) pairs.
    foreach ($p in @(@(0x116BD,0x116C2), @(0x12A34,0x12A39), @(0x12AA7,0x12AAC),
                     @(0x13433,0x13438), @(0x1FCB7,0x1FCBC), @(0x1FCC9,0x1FCCE),
                     @(0x1FF76,0x1FF7B), @(0x200DA,0x200DF), @(0x20138,0x2013D),
                     @(0x201A0,0x201A5), @(0x283C7,0x283CC), @(0x283DB,0x283E0))) {
        $patches += Patch-Imm32 -Name ("scr-h-{0:X}" -f $p[0]) -Lin $p[0] -Old $SCREEN_H_OLD -New $SCREEN_H -Note 'full-screen surface height'
        $patches += Patch-Imm32 -Name ("scr-w-{0:X}" -f $p[1]) -Lin $p[1] -Old $SCREEN_W_OLD -New $SCREEN_W -Note 'full-screen surface width'
    }
    # screen descriptor init at 0x33F30: total bytes, then height
    $patches += Patch-Imm32 -Name 'scr-bytes-33F51' -Lin 0x33F51 -Old ($SCREEN_W_OLD*$SCREEN_H_OLD) -New ($SCREEN_W*$SCREEN_H) -Note 'screen byte size'
    $patches += Patch-Imm32 -Name 'scr-h-33F56'     -Lin 0x33F56 -Old $SCREEN_H_OLD -New $SCREEN_H -Note 'screen height'
    $patches += Patch-Imm32 -Name 'scr-w-33EC1'     -Lin 0x33EC1 -Old $SCREEN_W_OLD -New $SCREEN_W -Note 'screen stride'
    # other whole-screen allocations
    foreach ($s in @(0x116A2, 0x1FD09, 0x1FE48)) {
        $patches += Patch-Imm32 -Name ("scr-bytes-{0:X}" -f $s) -Lin $s -Old ($SCREEN_W_OLD*$SCREEN_H_OLD) -New ($SCREEN_W*$SCREEN_H) -Note 'whole-screen buffer'
    }
    # scanline stride pushed into the blit helpers
    foreach ($s in @(0x34300, 0x34782, 0x34B9F, 0x3502A, 0x35337)) {
        $patches += Patch-Imm32 -Name ("scr-stride-{0:X}" -f $s) -Lin $s -Old $SCREEN_W_OLD -New $SCREEN_W -Note 'screen scanline stride'
    }
    # centring maths in the movie player: (640 - w) / 2 and (480 - h) / 2
    $patches += Patch-Imm32 -Name 'scr-w-1FDB9' -Lin 0x1FDB9 -Old $SCREEN_W_OLD -New $SCREEN_W -Note 'centre a full-screen image horizontally'
    $patches += Patch-Imm32 -Name 'scr-w-20D14' -Lin 0x20D14 -Old $SCREEN_W_OLD -New $SCREEN_W -Note 'centre a full-screen image horizontally'
    $patches += Patch-Imm32 -Name 'scr-h-20CF5' -Lin 0x20CF5 -Old $SCREEN_H_OLD -New $SCREEN_H -Note 'centre a full-screen image vertically'
    # full-screen clip rects and mouse limits: (0,0)-(639,479)
    foreach ($s in @(0x10239, 0x132B9, 0x16DAF, 0x16FF6, 0x179FC, 0x33A8B, 0x35CFE)) {
        $patches += Patch-Imm32 -Name ("scr-w1-{0:X}" -f $s) -Lin $s -Old ($SCREEN_W_OLD-1) -New ($SCREEN_W-1) -Note 'screen width-1 (clip / mouse limit)'
    }
    foreach ($s in @(0x1024A, 0x132C5, 0x16DBB, 0x16FF1, 0x17A08, 0x33A7F, 0x35CF8)) {
        $patches += Patch-Imm32 -Name ("scr-h1-{0:X}" -f $s) -Lin $s -Old ($SCREEN_H_OLD-1) -New ($SCREEN_H-1) -Note 'screen height-1 (clip / mouse limit)'
    }
    $patches += Patch-Imm32 -Name 'scr-w1-35C48' -Lin 0x35C48 -Old ($SCREEN_W_OLD-1) -New ($SCREEN_W-1) -Size 2 -Note 'mouse clip width-1 (imm16)'
    $patches += Patch-Imm32 -Name 'scr-h1-35C4E' -Lin 0x35C4E -Old ($SCREEN_H_OLD-1) -New ($SCREEN_H-1) -Size 2 -Note 'mouse clip height-1 (imm16)'

    # ---- the mouse NORMALISERS, and why the cursor was stuck in a 640x480 box --
    #
    # The event handler does `cursorX = driverX / [0x182D50]` (0x358E6), and that
    # divisor is built at 0x35C7A..0x35C86 as `(maxX + 1) / [0x14388A]`, where
    # 0x14388A is a DOUBLE holding 640.0 (and 0x143892 holds 480.0).
    #
    # Stock: (639 + 1) / 640 = 1.0, so the cursor tracks the driver exactly.
    # Raising maxX to 799 and leaving the constant at 640 gives 800/640 = 1.25 --
    # which DIVIDES the position DOWN, pinning the cursor inside 0..639 on an
    # 800-wide screen. Fixing maxX alone made it worse, not better.
    #
    # So these have to move with the screen: 800/800 = 1.0 again. Plain doubles
    # in obj2, no fixups, and nothing else reads them.
    $OBJ2_FILE_D = 0x184A54
    foreach ($d in @(@{ at=0x14388A; was=640.0; now=[double]$SCREEN_W; ax='horizontal' },
                     @{ at=0x143892; was=480.0; now=[double]$SCREEN_H; ax='vertical' })) {
        $od  = $OBJ2_FILE_D + ([int]$d.at - 0x140000)
        $exp = [byte[]][BitConverter]::GetBytes([double]$d.was)
        for ($k = 0; $k -lt 8; $k++) {
            if ($raw[$od+$k] -ne $exp[$k]) { throw ("mouse normaliser 0x{0:X} is not {1}" -f $d.at, $d.was) }
        }
        $patches += New-Patch -Name ("mouse-norm-{0:X}" -f $d.at) -FileOffset $od `
            -Expect $exp -Replace ([byte[]][BitConverter]::GetBytes([double]$d.now)) `
            -Note ("{0} mouse normaliser {1} -> {2}, so the cursor reaches the whole screen" -f $d.ax, $d.was, $d.now)
    }

    # ---- the ABSOLUTE mouse clip rect ---------------------------------------
    #
    # This is the one that actually caps the pointer. 0x35939 does NOT hand the
    # caller's rect to the driver -- it first builds a bounding rect
    #
    #     (0, 0, round(divX * [0x143858]), round(divY * [0x143850]))
    #
    # at 0x35986..0x359D0 and INTERSECTS the caller's rect with it (0x33550)
    # before issuing INT 33h AX=7/8. Those two doubles are 639.0 and 479.0, so
    # every one of the seven callers was being clipped back to 640x480 no matter
    # what rect it asked for.
    #
    # Symptoms this explains exactly, and nothing else did: the cap was identical
    # from every code path; it was exactly 4/5 on BOTH axes at 800x600; and the
    # top stayed 0, so the pointer could still reach up into the compass strip
    # while being unable to reach the panel at the bottom.
    #
    # NOTE these are a DIFFERENT pair from the mouse-norm doubles at 0x14388A /
    # 0x143892 (640.0 / 480.0). Those feed the divisor; these bound the rect.
    # Patching one pair and not the other is why this took so long to find.
    foreach ($d in @(@{ at=0x143858; was=($SCREEN_W_OLD-1); now=($SCREEN_W-1); ax='width' },
                     @{ at=0x143850; was=($SCREEN_H_OLD-1); now=($SCREEN_H-1); ax='height' })) {
        $od  = $OBJ2_FILE_D + ([int]$d.at - 0x140000)
        $exp = [byte[]][BitConverter]::GetBytes([double]$d.was)
        for ($k = 0; $k -lt 8; $k++) {
            if ($raw[$od+$k] -ne $exp[$k]) { throw ("mouse clip bound 0x{0:X} is not {1}" -f $d.at, $d.was) }
        }
        $patches += New-Patch -Name ("mouse-clip-{0:X}" -f $d.at) -FileOffset $od `
            -Expect $exp -Replace ([byte[]][BitConverter]::GetBytes([double]$d.now)) `
            -Note ("absolute mouse clip {0} {1} -> {2} (0x35939 intersects every rect with this)" -f $d.ax, $d.was, $d.now)
    }

    # ---- force the divisor to exactly 1.0 -----------------------------------
    #
    # DO NOT delete the divide at 0x358E6. It is one half of a MATCHED PAIR:
    #
    #   0x35939  driver range  = screen rect  * [0x182D50]   (screen -> driver)
    #   0x358E6  cursor        = driver coord / [0x182D50]   (driver -> screen)
    #   0x35A45  set cursor    = screen coord * [0x182D50]
    #
    # Removing only the divide leaves the multiply shrinking the range unopposed,
    # and 0x35964 writes the scaled value BACK INTO THE RECT IN PLACE -- so every
    # repeat call compounds it (799 -> 639 -> 511 ...). That is the "cursor box
    # gets smaller after a room change" bug, and it is proof the divisor != 1.0.
    #
    # The divisor is (driverMaxX + 1) / [0x14388A], and driverMaxX comes from the
    # DRIVER via INT 33h AX=0x31, not from any constant we patch -- 0x35C48 is
    # only the fallback for when the driver does not support that call. So the
    # ratio cannot be balanced from our side with any confidence.
    #
    # But the game already HAS a 1:1 path, gated at 0x35CA0 on [0x147592]: it
    # stores 1.0 into both divisors. Forcing that branch makes all three sites
    # identity simultaneously and keeps the pair matched, which is why this works
    # where balancing the ratio and deleting the divide both failed.
    $ofU = Lin2File ([uint32]0x35CA8)
    if ($raw[$ofU] -ne 0x75 -or $raw[$ofU+1] -ne 0x20) {
        throw "0x35CA8 is not the 'jnz' that skips the unity-divisor block"
    }
    $patches += New-Patch -Name 'mouse-unity' -FileOffset $ofU `
        -Expect ([byte[]]@(0x75,0x20)) -Replace ([byte[]]@(0x90,0x90)) `
        -Note 'always take the game''s own 1:1 mouse path (divisors forced to 1.0)'

    # The divide at 0x358E6 / 0x35900 is deliberately LEFT ALONE -- see above.
    # (A previous attempt NOPed all six bytes of `fdiv qword [0x182D50]`. Besides
    # breaking the pair, the last four bytes carry LE fixups, so the loader wrote
    # the operand straight back and the IMAGE ran two NOPs followed by `push eax`
    # / `sub eax,...` live in the mouse handler. If a site like that ever does
    # need neutralising, jump over the operand with `EB 04` rather than NOP it.)

    # WHERE THE POINTER IS PARKED: `mov edx,y / mov eax,x / call 0x35A45` (SetMousePos) at three sites:
    #   0x132AF  Space turning combat OFF -- the mod's look -> interactive switch goes through it (AztSendSpace)
    #   0x16DA5  0x16CCC, a mode exit that puts the stock pointer back
    #   0x179F2  0x179EC, a conversation starting
    # They parked at the SCREEN's centre (800, 600). The look-mode crosshair is pinned at the 3D VIEW's centre
    # (aztCentreX/Y = 800, 513 -- AztFrameHook / AztCursorRedraw), so on right-click the interactive cursor appeared
    # 87 game px BELOW the reticle (Josh, 2026-10-11: "they move down because a portion of the viewport is obscured ...
    # centered in the viewable viewport like the main reticule in all cases"). All three now park on the view centre.
    # (The hot spot is (15,15) for every cursor -- set once at 0x10E79 -- the middle of the 30 x 30 bitmap.)
    foreach ($s in @(0x132AF, 0x16DA5, 0x179F2)) {
        $patches += Patch-Imm32 -Name ("scr-hc-{0:X}" -f $s) -Lin $s `
            -Old ([int]($SCREEN_H_OLD/2)) -New ([int]$CENTRE_Y) -Note 'pointer park Y: the 3D view centre (where the look-mode reticle is)'
    }
    foreach ($s in @(0x132B4, 0x16DAA, 0x179F7)) {
        $patches += Patch-Imm32 -Name ("scr-wc-{0:X}" -f $s) -Lin $s -Old ([int]($SCREEN_W_OLD/2)) -New ([int]$CENTRE_X) -Note 'pointer park X: the 3D view centre'
    }
}

# ---- skip the startup logo / intro movies ----------------------------------
# DISABLED -- see the note at $INTRO_MOVIE_CALLS. Skipping the movie calls fails
# exactly like skipping the whole sequence did: the player at 0x20BD4 evidently
# does more than play (it owns the video mode / event pump during startup), so
# NOPing it leaves the extender in a state that dies with
#   "Exit to error: INT:Gate Selector points to illegal descriptor with type f"
# The intro is skipped from outside the executable instead -- see -SkipIntro in
# Apply-AztMod.ps1, which renames the .MOV files so the player no-ops on a
# missing file and AZRAEL.BAT stops invoking TM.EXE.
if ($false) {
foreach ($c in $INTRO_MOVIE_CALLS) {
    $off = Lin2File $c
    $patches += New-Patch -Name ("no-intro-movie-{0:X}" -f $c) -FileOffset $off `
        -Expect $raw[$off..($off + 4)] -Replace ([byte[]]@(0x90,0x90,0x90,0x90,0x90)) `
        -Note 'skip one startup movie (return value unused)'
}
}

# ---- HUDTOP/HUDBOT viewport overlays ---------------------------------------
# RESTORED in v0.14. These are what gave the HUD its character: run-length
# overlays composited into the 3D framebuffer so the compass strip and the panel
# bleed over the view instead of meeting it at a hard rectangle.
#
# They were disabled because the skips are authored against a 552-pixel scanline,
# so at 640 the overlay smeared across rows and walked off the end of the
# framebuffer -- almost certainly what corrupted the heap. Build-HudOverlay.ps1
# re-authors both files for a 640 stride, and because the word count AND the
# destination offset both live in the .RES trailer, that needs no code patch at
# all. The generator checks the bound: last byte written is 218071 of 218880.
#
# Set $ENABLE_HUD_OVERLAY = $false to go back to NOPing the 32 call sites.
if ($ENABLE_BIG_VIEW -and $VIEW_W -ne $VIEW_W_OLD) {
    # HUDTOP is never re-authored -- stock is still 552-stride and would smear --
    # so its 16 sites always stay NOPed. HUDBOT is regenerated by
    # Build-HudOverlay.ps1, so its 16 sites survive when the overlay is enabled.
    $silence = $(if ($ENABLE_HUD_TOP)     { @() } else { $HUDRES_TOP_CALLS }) +
           $(if ($ENABLE_HUD_OVERLAY) { @() } else { $HUDRES_BOT_CALLS })
    foreach ($c in $silence) {
        $off = Lin2File ([uint32]$c)
        if ($raw[$off] -ne 0xE8) { throw ("hudres call at 0x{0:X} is not a call" -f $c) }
        $patches += New-Patch -Name ("no-hudres-{0:X}" -f $c) -FileOffset $off `
            -Expect $raw[$off..($off + 4)] -Replace ([byte[]]@(0x90,0x90,0x90,0x90,0x90)) `
            -Note 'skip one 552-wide HUD overlay pass (it smears across a 640-wide view)'
    }
}

# ---- overlays drawn INTO the view surface ----------------------------------
# A cluster of HUD elements is composited into 0x152150 itself rather than onto
# the screen, so their coordinates are view-relative. The stock view was 552
# wide; these sit hard against its right edge (the 206x170 story/hint box at
# 0x152120 actually overhangs it by 31px, which is how the artwork was drawn).
# Widening the view to 640 left them stranded 88px short of the new right edge.
# Shifting them by exactly the width delta restores the stock right margin.
#
# Draw sites, all `ecx/push = X, push = Y` into dest 0x152150:
#   0x14CFF  0x152120  206x170  X = 0x179 + 7*slidein, Y = 34   system fold-out
#   0x14FA6  [0x1521AC]         X = 0x17D,             Y = 35   story log
#   0x14FE3  [0x1521AC] (text)  X = 0x17D,             Y = 35   story log text
#   0x14E83  0x1523EC  87x27    X = esi + 0x18D,       Y = 77   volume slider 1
#   0x14EE4  0x152400  87x27    X = esi + 0x18D,       Y = 106  volume slider 2
#
# TWO DIFFERENT THINGS SHARE THIS CORNER, and they do NOT move together.
#
# 0x152120 is not a "SAVE%02d.pcx thumbnail" as I first had it -- SAVE00..13 are
# the 14 frames of the SYSTEM FOLD-OUT (Q, or the panel button), which slides out
# 7px per frame and carries the volume sliders and the save/load/quit buttons.
# Its hot spots are in SCREEN coordinates and are not scaled by anything, so the
# artwork has to land back on its stock SCREEN position: the view origin moved
# from x=44 to x=0, so its view-relative X goes UP by exactly that 44. Shifting
# it by the width delta instead put it 88px out, and the sliders another 37 on
# top -- hence "the sound levels are wrong and I can't click save/load/quit".
#
# The story log at [0x1521AC] is the opposite case: it is right-anchored against
# the view's right edge, so it follows the widening, plus the width it gave up
# when TEXTBOX_SCALE narrowed it.
#
# The story log's own click area (screen 5's hot spot) has to be remapped onto
# wherever this puts the box, so the two numbers are published for the hot-spot
# block below instead of being recomputed there.
$LOG_DRAW_X_OLD = 0x17D
$LOG_DRAW_Y     = 0x23
$LOG_DRAW_X_NEW = if ($ENABLE_LOG_IN_PANEL) { $LOG_INSET }
                  else { $LOG_DRAW_X_OLD + ($VIEW_W - $VIEW_W_OLD) + $TEXTBOX_DX_EXTRA }
$LOG_DRAW_Y_NEW = if ($ENABLE_LOG_IN_PANEL) { $LOG_INSET } else { $LOG_DRAW_Y }
$LOG_HOT_OLD    = @(414, 89, 583, 294)           # minX, minY, maxX, maxY
if ($ENABLE_BIG_VIEW -and $VIEW_W -ne $VIEW_W_OLD) {
    $DX = $VIEW_W - $VIEW_W_OLD
    # The fold-out no longer "stays put": it is rebuilt at 2x and latched to the
    # right edge, so its X is computed rather than nudged. The two slider draw
    # sites used to be nudged here too -- they are trampolines now, because their
    # Y is an imm8 that cannot reach the new position (see AztSlider0/1).
    foreach ($o in @(@(0x14CF0, 0x179, 'foldout', 'system fold-out panel'),
                     @(0x14F92, 0x17D, 'log',     'story log'),
                     @(0x14FDA, 0x17D, 'log',     'story log text'))) {
        $new = if ($o[2] -eq 'foldout') { $SYSMENU_VX } else { $LOG_DRAW_X_NEW }
        if ($o[2] -eq 'log' -and $o[1] -ne $LOG_DRAW_X_OLD) {
            throw "story log draw site 0x$('{0:X}' -f $o[0]) holds $($o[1]), expected $LOG_DRAW_X_OLD"
        }
        $patches += Patch-Imm32 -Name ("view-overlay-x-{0:X}" -f $o[0]) -Lin $o[0] `
            -Old $o[1] -New $new `
            -Note ("{0}: in-view X {1} -> {2} ({3})" -f $o[3], $o[1], $new,
                   $(if ($o[2] -eq 'foldout') { 'latched to the viewport right edge' } else { 'follows the view right edge' }))
    }

    # ---- the SOURCE surface the frames are loaded into ----------------------
    # Without this the panel appears with three quarters missing, and it looks
    # like a clipping bug in the blit rather than what it is: the frames are read
    # into surface 0x152120, which 0x10CC9 creates at exactly 206x170 with a
    # malloc'd buffer of 0x88CC = 35020 = 206*170 bytes. A 412x340 PCX loaded
    # into that keeps only its top-left quarter -- and the hot spots still work,
    # because they are screen geometry and never touch this surface, which is
    # what makes the symptom so misleading.
    #
    # 0x37B04 is the no-allocate surface init (it writes 0xCCCCCCCC into the
    # buffer pointer); the caller allocates straight after and stores the result
    # at +4, so the size constant has to move with the dimensions.
    foreach ($s in @(@(0x10CBA, 0xAA,   $SYSMENU_H,                'height'),
                     @(0x10CBF, 0xCE,   $SYSMENU_W,                'width'),
                     @(0x10CCE, 0x88CC, ($SYSMENU_W * $SYSMENU_H), 'pixel buffer'))) {
        $patches += Patch-Imm32 -Name ("sysmenu-surf-{0}" -f ($s[3] -replace ' ','')) -Lin $s[0] `
            -Old $s[1] -New $s[2] `
            -Note ("fold-out source surface {0} {1} -> {2}" -f $s[3], $s[1], $s[2])
    }

    # ---- the rest of the fold-out's geometry --------------------------------
    # Y is still an imm8 here and 118 fits, so this one stays in place.
    $ofY = Lin2File ([uint32]0x14CE9)
    if ($raw[$ofY] -ne 0x6A -or $raw[$ofY+1] -ne 0x22) { throw '0x14CE9 is not `push 0x22` (the fold-out draw Y)' }
    if ($SYSMENU_VY -gt 127) { throw ("fold-out Y {0} will not fit the push imm8 at 0x14CE9" -f $SYSMENU_VY) }
    $patches += New-Patch -Name 'sysmenu-y' -FileOffset $ofY `
        -Expect ([byte[]]@(0x6A,0x22)) -Replace ([byte[]]@(0x6A,[byte]$SYSMENU_VY)) `
        -Note ("system fold-out draw Y {0} -> {1} (near the top of the viewport)" -f 0x22, $SYSMENU_VY)

    # Kill the 7-px-per-step slide: the regenerated frames do the arrival.
    $ofS = Lin2File ([uint32]0x14CE6)
    if ($raw[$ofS] -ne 0x6B -or $raw[$ofS+1] -ne 0xC0 -or $raw[$ofS+2] -ne 0x07) {
        throw '0x14CE6 is not `imul eax,eax,7` (the fold-out slide step)'
    }
    $patches += New-Patch -Name 'sysmenu-slide' -FileOffset $ofS `
        -Expect ([byte[]]@(0x6B,0xC0,0x07)) -Replace ([byte[]]@(0x6B,0xC0,0x00)) `
        -Note 'fold-out slide 7 px/step -> 0; the rebuilt frames animate the arrival instead'

    # The slider draw sites -> the overlay, which re-issues push/add at full width.
    foreach ($sl in @(@(0, 0x14E68, 0x4D), @(1, 0x14EC9, 0x6A))) {
        $ofSl = Lin2File ([uint32]$sl[1])
        $want = [byte[]]@(0x6A, [byte]$sl[2], 0x81, 0xC6, 0x8D, 0x01, 0x00, 0x00)
        $got  = $raw[$ofSl..($ofSl+7)]
        if ((Hex $got) -ne (Hex $want)) {
            throw ("slider {0} draw site 0x{1:X} is not `push imm8 / add esi,0x18D` -- found {2}" -f $sl[0], $sl[1], (Hex $got))
        }
        $rep = New-Object byte[] 8
        (JmpRel32 ([uint32]$sl[1]) $ovlAsm.Labels[("AztSlider{0}" -f $sl[0])]).CopyTo($rep, 0)
        for ($k = 5; $k -lt 8; $k++) { $rep[$k] = 0x90 }
        $patches += New-Patch -Name ("sysmenu-slider{0}" -f $sl[0]) -FileOffset $ofSl `
            -Expect $got -Replace $rep `
            -Note ("volume slider {0} draws at in-view ({1},{2}) via the overlay (its Y no longer fits an imm8)" -f `
                   $sl[0], ($SYSMENU_VX + $SYSMENU_SLIDER_LX), ($SYSMENU_VY + $SYSMENU_SLIDER_LY[$sl[0]]))
    }

    # `value = RIGHT_EDGE - mouseX`, clamped to 0..W: the right end of the track
    # in SCREEN space. One site per slider.
    foreach ($at in @(0x14D26, 0x14DB8)) {
        $patches += Patch-Imm32 -Name ("sysmenu-slider-right-{0:X}" -f $at) -Lin $at `
            -Old 0x210 -New $SYSMENU_SLIDER_R `
            -Note ("volume slider track right edge {0} -> {1} (screen X)" -f 0x210, $SYSMENU_SLIDER_R)
    }

    # ---- scale the whole slider chain ---------------------------------------
    # The bar surfaces and their pixel buffers (temp.pcx / bemp.pcx, 87x27).
    foreach ($s in @(@(0x10C1D, 0x1B,  $SYSMENU_SLIDER_H, 'bar 0 height'),
                     @(0x10C22, 0x57,  $SYSMENU_SLIDER_W, 'bar 0 width'),
                     @(0x10C33, 0x92D, ($SYSMENU_SLIDER_W * $SYSMENU_SLIDER_H), 'bar 0 buffer'),
                     @(0x10C53, 0x1B,  $SYSMENU_SLIDER_H, 'bar 1 height'),
                     @(0x10C58, 0x57,  $SYSMENU_SLIDER_W, 'bar 1 width'),
                     @(0x10C67, 0x92D, ($SYSMENU_SLIDER_W * $SYSMENU_SLIDER_H), 'bar 1 buffer'))) {
        $patches += Patch-Imm32 -Name ("sysmenu-bar-{0}" -f ($s[3] -replace ' ','')) -Lin $s[0] `
            -Old $s[1] -New $s[2] -Note ("volume {0} {1} -> {2}" -f $s[3], $s[1], $s[2])
    }

    # The /87 that turns a track position into a 0..127 volume, and the source
    # rect the fill is cut from: `mov esi,87` is the right-hand end it counts
    # back from, `mov ecx,86` the rect's right edge, `push 26` its bottom.
    foreach ($s in @(@(0x14D6A, 0x57, $SYSMENU_SLIDER_W,       'slider 0 track length'),
                     @(0x14DFD, 0x57, $SYSMENU_SLIDER_W,       'slider 1 track length'),
                     @(0x14E43, 0x57, $SYSMENU_SLIDER_W,       'slider 0 fill origin'),
                     @(0x14EA0, 0x57, $SYSMENU_SLIDER_W,       'slider 1 fill origin'),
                     @(0x14E4A, 0x56, ($SYSMENU_SLIDER_W - 2), 'slider 0 rect right'),
                     @(0x14EA7, 0x56, ($SYSMENU_SLIDER_W - 2), 'slider 1 rect right'))) {
        $patches += Patch-Imm32 -Name ("sysmenu-{0}" -f ($s[3] -replace ' ','')) -Lin $s[0] `
            -Old $s[1] -New $s[2] -Note ("volume {0} {1} -> {2}" -f $s[3], $s[1], $s[2])
    }
    # `push imm8` rect bottom -- 52 still fits, so these stay in place.
    foreach ($at in @(0x14E48, 0x14EA5)) {
        $of = Lin2File ([uint32]$at)
        if ($raw[$of] -ne 0x6A -or $raw[$of+1] -ne 0x1B - 1) { throw ("0x{0:X} is not ``push 0x1A``" -f $at) }
        $patches += New-Patch -Name ("sysmenu-rect-bottom-{0:X}" -f $at) -FileOffset $of `
            -Expect ([byte[]]@(0x6A,0x1A)) -Replace ([byte[]]@(0x6A,[byte]($SYSMENU_SLIDER_H - 2))) `
            -Note ("volume slider source rect bottom 26 -> {0}" -f ($SYSMENU_SLIDER_H - 2))
    }
    # The clamp STORE writes its limit as an imm16, so only the test had to move.
    foreach ($at in @(0x14D5C, 0x14DEF)) {
        $of = Lin2File ([uint32]$at)
        if ([BitConverter]::ToUInt16($raw, $of) -ne 0x57) { throw ("0x{0:X} is not the imm16 clamp limit 87" -f $at) }
        $patches += New-Patch -Name ("sysmenu-clamp-store-{0:X}" -f $at) -FileOffset $of `
            -Expect ([byte[]][BitConverter]::GetBytes([uint16]0x57)) `
            -Replace ([byte[]][BitConverter]::GetBytes([uint16]$SYSMENU_SLIDER_W)) `
            -Note ("volume slider clamp limit 87 -> {0}" -f $SYSMENU_SLIDER_W)
    }
    # ...and the two blocks that could not be widened in place.
    foreach ($s in @(@(0, 0x14D50, 5,  'Clamp'), @(1, 0x14DE3, 5,  'Clamp'),
                     @(0, 0x14E34, 15, 'Px'),    @(1, 0x14E91, 15, 'Px'))) {
        $of  = Lin2File ([uint32]$s[1])
        $exp = $raw[$of..($of + $s[2] - 1)]
        $rep = New-Object byte[] $s[2]
        (JmpRel32 ([uint32]$s[1]) $ovlAsm.Labels[("AztSlider{0}{1}" -f $s[3], $s[0])]).CopyTo($rep, 0)
        for ($k = 5; $k -lt $s[2]; $k++) { $rep[$k] = 0x90 }
        $patches += New-Patch -Name ("sysmenu-slider{0}-{1}" -f $s[0], $s[3].ToLower()) -FileOffset $of `
            -Expect $exp -Replace $rep `
            -Note ("volume slider {0} {1} via the overlay (its 87 will not fit an imm8)" -f $s[0], $s[3].ToLower())
    }
}

# ---- redirect the log into the panel box -----------------------------------
if ($ENABLE_LOG_IN_PANEL) {
    $LOG_SURF_OLD = 0x152150      # the 3D view surface
    $LOG_SURF_NEW = 0x152AD4      # the panel's right-hand well

    # THE OPERAND IS OWNED BY A FIXUP, NOT BY THE CODE. `mov ebx, 0x152150` is an
    # absolute obj2 address, so the file holds 50 21 01 00 (the obj2-RELATIVE
    # offset) and the loader writes base+offset over it from the fixup record.
    # Patching the code bytes accomplishes nothing -- the loader stamps them back.
    #
    # So the RECORD is retargeted instead: 0x12150 -> 0x12AD4. Verified safe --
    # each of these two records feeds exactly ONE source site, so nothing else
    # that references the view surface moves with them. (A record can carry a
    # source LIST; retargeting one of those would drag every site in it along.)
    foreach ($s in @(@(0x2BA35, 0x14F9E, 'story text'),
                     @(0x2BC4E, 0x14FCD, 'conversation list'))) {
        $patches += New-Patch -Name ("log-surf-{0:X}" -f $s[1]) -FileOffset $s[0] `
            -Expect  ([BitConverter]::GetBytes([uint32]($LOG_SURF_OLD - 0x140000))) `
            -Replace ([BitConverter]::GetBytes([uint32]($LOG_SURF_NEW - 0x140000))) `
            -Note ("{0}: LE fixup at 0x{1:X} retargeted -- destination surface 0x{2:X} -> 0x{3:X} (the panel box, was the 3D view)" -f `
                   $s[2], $s[1], $LOG_SURF_OLD, $LOG_SURF_NEW)
    }

    # The Y coordinates are PUSH imm8 (6A 23), not imm32, at both sites.
    foreach ($s in @(@(0x14F90, 'story text'), @(0x14FCA, 'conversation list'))) {
        $patches += Patch-Imm32 -Name ("log-y-{0:X}" -f $s[0]) -Lin $s[0] -Size 1 `
            -Old $LOG_DRAW_Y -New $LOG_DRAW_Y_NEW `
            -Note ("{0}: Y {1} -> {2}, inside the panel box" -f $s[1], $LOG_DRAW_Y, $LOG_DRAW_Y_NEW)
    }

    # The box is only blitted while scan mode is on. NOP the branch, not the
    # compare -- the compare's flags are not used again, but the jump is what
    # skips the blit.
    $jz = Lin2File 0x12334
    if ($raw[$jz] -ne 0x74 -or $raw[$jz+1] -ne 0x14) {
        throw ("expected jz +0x14 at 0x12334, found {0:X2} {1:X2}" -f $raw[$jz], $raw[$jz+1])
    }
    $patches += New-Patch -Name 'log-box-always' -FileOffset $jz `
        -Expect ([byte[]]@(0x74,0x14)) -Replace ([byte[]]@(0x90,0x90)) `
        -Note 'panel box is blitted every frame, not only in scan mode'

    # Route both text draws through the clearing shims. The CALL operand is
    # relative, so unlike the destination surface it is ours to rewrite.
    foreach ($c in @(@(0x14FA6, $TEXT_DRAW_PLAIN, 'AztLogClearBx', 'story text'),
                     @(0x14FE3, $TEXT_DRAW_LIST,  'AztLogClearCx', 'conversation list'))) {
        $off = Lin2File $c[0]
        $exp = CallRel32 $c[0] $c[1]
        for ($k = 0; $k -lt 5; $k++) {
            if ($raw[$off+$k] -ne $exp[$k]) { throw ("{0}: expected call 0x{1:X} at 0x{2:X}" -f $c[3], $c[1], $c[0]) }
        }
        $patches += New-Patch -Name ("log-clear-{0:X}" -f $c[0]) -FileOffset $off `
            -Expect $exp -Replace (CallRel32 $c[0] $asm.Labels[$c[2]]) `
            -Note ("{0}: draw now goes via {1}, which clears the panel box first" -f $c[3], $c[2])
    }
}

# ---- shrink the story / message log ----------------------------------------
# The log is the text-box object at 0x1521AC, built by 0x38FE4 at 0x10D16 with
# edx = width and ebx = height. Watcom hoists both immediates well above the
# call and lets them survive two intervening StLoadFont calls (both push/pop
# ebx and edx), so the two `mov`s to patch are NOT adjacent to it:
#
#   0x10CF1  mov ebx, 0xCE   -> height 206
#   0x10D05  mov edx, 0xAA   -> width  170
#
# Everything downstream follows automatically, which is why this is only two
# immediates: the renderer at 0x39120 takes its WRAP WIDTH from the surface
# (0x3924A reads width off [obj+0]) and its LINE HEIGHT from the font surface
# (0x39255), so re-wrapping and clipping need no other change.
if ($ENABLE_TEXTBOX_RESCALE) {
    if ($TEXTBOX_H -ne $TEXTBOX_H_OLD) {
        $patches += Patch-Imm32 -Name 'textbox-h' -Lin 0x10CF1 -Old $TEXTBOX_H_OLD -New $TEXTBOX_H `
            -Note ("story log height {0} -> {1}" -f $TEXTBOX_H_OLD, $TEXTBOX_H)
    }
    if ($TEXTBOX_W -ne $TEXTBOX_W_OLD) {
        $patches += Patch-Imm32 -Name 'textbox-w' -Lin 0x10D05 -Old $TEXTBOX_W_OLD -New $TEXTBOX_W `
            -Note ("story log width {0} -> {1} (text re-wraps itself)" -f $TEXTBOX_W_OLD, $TEXTBOX_W)
    }

    # START THE RENDER CURSOR AT THE BOTTOM OF THE SURFACE.
    #
    # The surface is taller than the window and the window is pinned to its foot,
    # so a fresh surface renders its first line at y=0 -- 120px ABOVE anything you
    # can see. The box would read empty for the first ~15 lines of the game, until
    # enough text had accumulated for 0x392A9 to scroll the surface down to where
    # the window is. Starting the cursor at the window's top edge instead means
    # line one lands in view and the scrollback fills in behind it.
    #
    # The text object is 0x14 bytes: +0 surface, +4 x cursor, +6 y cursor, +8 the
    # (realloc'd, unbounded) string, +0xC its length, +0x12 a suppress-render flag.
    # The constructor zeroes both cursors at 0x3902A/0x39044. It has EXACTLY ONE
    # caller, 0x10D16, which builds the story log -- verified by scanning obj1 for
    # E8 rel32 -- so this is safe to patch in the constructor itself.
    #
    # The X cursor is NOT independently initialised -- 0x39044 copies it FROM the
    # Y cursor (`mov ax,[ecx+6] / mov [ecx+4],ax`), which only reads as sane while
    # both are zero. Left alone it would start the first line 120px in from the
    # left margin, so that copy becomes an explicit zero.
    # The top of the DEFAULT window in the surface's own coordinates: everything
    # the collapsed box cannot show at once sits above it.
    $LOG_CURSOR_START = if ($ENABLE_LOG_BOX_TOGGLE) { $TEXTBOX_H - $RECESS_H_SMALL } else { $LOG_HISTORY }
    if ($ENABLE_LOG_IN_PANEL -and $LOG_CURSOR_START -gt 0) {
        # -Lin IS THE INSTRUCTION, NOT THE IMMEDIATE. Patch-Imm32 scans +1..+5 for
        # the old value, so handing it the immediate's own address walks the
        # window PAST the instruction: 0x3902E + 5 is the zero in the NEXT one,
        # `mov dword [ecx+8], 0` -- the string buffer pointer. That assembled
        # cleanly, verified cleanly, and set the log's text pointer to 120.
        $patches += Patch-Imm32 -Name 'log-cursor-start' -Lin 0x3902A -Size 2 -Old 0 -New $LOG_CURSOR_START `
            -Note ("story log render cursor starts at y={0}, the top of the visible window" -f $LOG_CURSOR_START)
        $xc = Lin2File 0x39044
        $xcExp = [byte[]]@(0x66,0x8B,0x41,0x06)          # mov ax, word [ecx+6]
        for ($k = 0; $k -lt 4; $k++) {
            if ($raw[$xc+$k] -ne $xcExp[$k]) { throw ("expected 'mov ax,[ecx+6]' at 0x39044, found {0:X2}" -f $raw[$xc+$k]) }
        }
        $patches += New-Patch -Name 'log-cursor-x0' -FileOffset $xc `
            -Expect $xcExp -Replace ([byte[]]@(0x31,0xC0,0x90,0x90)) `
            -Note 'story log X cursor starts at 0, not copied from the Y cursor'
    }

    # THE SECOND COPY OF THE BOX SIZE. When the log is showing a CONVERSATION the
    # draw path forks at 0x14F86 and builds a rect for the selectable list:
    #
    #   0014FAD  push 0xCE            ; y1 = 206  <- box height, hard-coded
    #   0014FB2  mov  ecx, 0xAA       ; x1 = 170  <- box width,  hard-coded
    #   0014FBA  mov  ebx, [0x152B30] ; y0 = the selected line's pixel offset
    #   0014FC5  call 0x335EC         ; MakeRect(x0=0, y0, x1, y1) -- four words
    #
    # 0x335EC really is a rect builder (it stores dx,bx,cx and the pushed word at
    # +0,+2,+4,+6, and 0x33602 validates x0<=x1 / y0<=y1), so these two immediates
    # are the box's own width and height. They are NOT derived from textbox-w/h,
    # which is how the list ended up laid out against 206 inside a 175-tall box.
    # THIS RECT IS IN THE DESTINATION'S TERMS, NOT THE TEXT SURFACE'S. While the
    # box and the text surface were the same object that distinction did not
    # exist, and "must match the story log box" meant textbox-w/h. Once the
    # RECESS became its own, smaller surface the two parted company: the text
    # surface is 316 rows of scrollback, the recess only 196, and handing 0x37E74
    # a 316-row rect against a 29400-byte destination walked 120 rows off the end
    # of it. That is the hard crash on starting a conversation, and why the
    # options never appeared -- the draw was malformed before it drew anything.
    #
    # A conversation always forces the box open, so the open recess is the right
    # height to use.
    # ...THAT WAS WRONG, and the correction is worth keeping written down.
    # 0x37E74 INTERSECTS AND VALIDATES: 0x37EC3 calls the rect-intersect at
    # 0x33550 and 0x37ECA calls 0x33624, bailing out entirely when the result is
    # empty. An oversized rect is therefore clipped, not written past the end of
    # the destination -- so this was never the crash.
    #
    # Setting it to the recess height instead made things worse: 0x152B30 is the
    # selected line's pixel offset in the TEXT SURFACE, which is 316 rows deep, so
    # once the player scrolled past row 196 the rect inverted (y0 > y1), the
    # validation rejected it and the option list stopped drawing at all.
    $CONVLIST_H = $TEXTBOX_H
    foreach ($t in @(@('convlist-h', 0x14FAD, $TEXTBOX_H_OLD, $CONVLIST_H, 'height'),
                     @('convlist-w', 0x14FB2, $TEXTBOX_W_OLD, $TEXTBOX_W, 'width'))) {
        if ($t[3] -ne $t[2]) {
            $patches += Patch-Imm32 -Name $t[0] -Lin $t[1] -Old $t[2] -New $t[3] `
                -Note ("conversation list rect {0} {1} -> {2} (must match the story log box)" -f $t[4], $t[2], $t[3])
        }
    }
}

# ---- the texture cache's reserve -------------------------------------------
# See $ENABLE_TEX_RESERVE above. Two immediates, and they must move together.
if ($ENABLE_TEX_RESERVE) {
    if ($TEX_MIN_BIG -le $TEX_RESERVE) {
        throw ("the small-cache threshold (0x{0:X}) must exceed the reserve (0x{1:X}), or `sub esi` underflows" -f $TEX_MIN_BIG, $TEX_RESERVE)
    }
    $patches += Patch-Imm32 -Name 'tex-reserve-1BEC0' -Lin 0x1BEC0 -Old 0x480000 -New $TEX_RESERVE `
        -Note ("texture cache reserve {0:N0} -> {1:N0} bytes, so the rest of the game has room at 800x600" -f 0x480000, $TEX_RESERVE)
    $patches += Patch-Imm32 -Name 'tex-minbig-1BEA6' -Lin 0x1BEA6 -Old 0x800000 -New $TEX_MIN_BIG `
        -Note ("small-cache threshold {0:N0} -> {1:N0} bytes; it gates the subtraction above and must stay clear of it" -f 0x800000, $TEX_MIN_BIG)
}

# ---- DIAGNOSTIC: the out-of-memory trap ------------------------------------
# See $ENABLE_OOM_TRAP above. Seven bytes at 0x28770:
#
#   mov edx, eax       89 C2                 <- kept: the requested size, for %d
#   mov ecx, 0x1       B9 01 00 00 00        <- replaced by jmp 0x287A3
#
# 0x287A3 is the "still null after the purge" arm, so this simply reports on the
# FIRST failure instead of the second. All four allocator variants (0x32C40,
# 0x32C88, 0x32CCF, 0x32D1E) funnel through here, so one site covers them.
if ($ENABLE_OOM_TRAP) {
    $oo  = Lin2File 0x28770
    $exp = [byte[]]@(0x89,0xC2,0xB9,0x01,0x00,0x00,0x00)
    $rep = [byte[]]@(0x89,0xC2) + (JmpRel32 0x28772 0x287A3)
    $patches += New-Patch -Name 'oom-trap-28770' -FileOffset $oo -Expect $exp -Replace $rep `
        -Note 'DIAGNOSTIC: first allocation failure reports "No memory available" instead of purging and retrying'
}

# ---- HUD hit regions -------------------------------------------------------
# Most panel hot spots are rectangles held in runtime region objects; those are
# handled wholesale by hook-hudpoint. What is left is the handful of tests the
# game hard-codes against the raw cursor globals (x = word [0x182D6C],
# y = word [0x182D6E]), which the hook deliberately does not touch.
if ($ENABLE_PANEL_RESCALE) {
    # Automap click. Stock tests x>50 && y>340 and passes (x-50, y-340) into the
    # map as local coordinates, i.e. the hot-spot origin sits 20 left and 5 above
    # the blit. The map is NOT rescaled, so carrying that same offset across is
    # exact -- no rounding, no gain change.
    $HOT_MAP_X_OLD = 50;  $HOT_MAP_Y_OLD = 340
    $HOT_MAP_X = $MAP_X - ($MAP_X_OLD - $HOT_MAP_X_OLD)
    $HOT_MAP_Y = $MAP_Y - ($MAP_Y_OLD - $HOT_MAP_Y_OLD)
    $patches += Patch-Imm32 -Name 'hit-map-x-2C462' -Lin 0x2C462 -Old $HOT_MAP_X_OLD -New $HOT_MAP_X -Size 1 -Note 'automap hot-spot left edge'
    $patches += Patch-Imm32 -Name 'hit-map-x-2C494' -Lin 0x2C494 -Old $HOT_MAP_X_OLD -New $HOT_MAP_X -Size 1 -Note 'automap click -> map-local X'
    $patches += Patch-Imm32 -Name 'hit-map-y-2C472' -Lin 0x2C472 -Old $HOT_MAP_Y_OLD -New $HOT_MAP_Y -Note 'automap hot-spot top edge'
    $patches += Patch-Imm32 -Name 'hit-map-y-2C483' -Lin 0x2C483 -Old $HOT_MAP_Y_OLD -New $HOT_MAP_Y -Note 'automap click -> map-local Y'

    # The one panel control tested inline rather than through a region:
    # x>=554 && y>=437. Its DRAW is a separate pair of immediates at 0x1576B /
    # 0x15770 -- a small surface built on the stack and blitted to the same
    # (554,437). Patching the test without the draw is exactly the "it lights up
    # in its old position" symptom, so both move together.
    # THIS IS THE REPLAY BUTTON -- the one that appears after dialogue to play the
    # line again. 0x15745 formats "REPLAY%d.PCX" with [0x152AEE]>>16, so it has
    # seven frames of its own art; it is NOT one of the three NBUT lamps.
    #
    # ITS SPRITE IS NOT SCALED. To-PanelY squashes the POSITION by the panel's
    # 0.685 factor while REPLAY*.PCX stays 86x43, so the stock placement -- which
    # fitted exactly, 437 + 43 = 480 = the bottom of a 480-line screen -- became
    # 571 + 43 = 614 on a 600-line one. Fourteen rows off the bottom of the
    # framebuffer, which is the same class of overrun that used to corrupt the
    # heap here. So it is placed from the readout window and the sprite size
    # rather than by scaling a coordinate, and the fit is asserted.
    $REPLAY_W = 86; $REPLAY_H = 43
    $BTN_X = $SCAN_X + [int](($SCAN_W - $REPLAY_W) / 2)
    $BTN_Y = $SCAN_Y + $SCAN_H - $REPLAY_H
    # The widescreen panel has its own replay key, in the log's control column; hud-layout.json
    # says where (clamped by Build-HudWide so the 86x43 sprite stays on the game's screen).
    $layoutRp = Join-Path $PSScriptRoot '..\art\hud-layout.json'
    if (Test-Path $layoutRp) { $Lrp = Get-Content $layoutRp -Raw | ConvertFrom-Json; if ($Lrp.PSObject.Properties['replay']) { $BTN_X = [int]$Lrp.replay.x; $BTN_Y = [int]$Lrp.replay.y } }
    if ($BTN_X -lt 0 -or ($BTN_X + $REPLAY_W) -gt $SCREEN_W) { throw "replay button x $BTN_X + $REPLAY_W does not fit in $SCREEN_W" }
    if ($BTN_Y -lt $PANEL_TOP_NEW -or ($BTN_Y + $REPLAY_H) -gt $SCREEN_H) { throw "replay button y $BTN_Y + $REPLAY_H does not fit the panel ($PANEL_TOP_NEW..$SCREEN_H)" }
    $patches += Patch-Imm32 -Name 'hit-btn-x-15A6D' -Lin 0x15A6D -Old 554 -New $BTN_X -Note ("replay button, hit test left edge -> {0}" -f $BTN_X)
    $patches += Patch-Imm32 -Name 'hit-btn-y-15A7B' -Lin 0x15A7B -Old 437 -New $BTN_Y -Note ("replay button, hit test top edge -> {0}" -f $BTN_Y)
    $patches += Patch-Imm32 -Name 'draw-btn-x-15770' -Lin 0x15770 -Old 554 -New $BTN_X -Note ("replay button, DRAW X (must match the hit test)")
    $patches += Patch-Imm32 -Name 'draw-btn-y-1576B' -Lin 0x1576B -Old 437 -New $BTN_Y -Note ("replay button {0}x{1} bottom-aligned in the readout: ({2},{3})..({4},{5})" -f `
        $REPLAY_W,$REPLAY_H,$BTN_X,$BTN_Y,($BTN_X+$REPLAY_W-1),($BTN_Y+$REPLAY_H-1))

    # Cursor-near-the-edge zones, inset 5px from the stock view (x 49..589,
    # y 54..322 => a 552x282 view at (44,49)). Re-derive them from the new view.
    $patches += Patch-Imm32 -Name 'hit-edge-r-13F26' -Lin 0x13F26 -Old 589 -New ($VIEW_X + $VIEW_W - 6)  -Note 'view edge zone, right'
    $patches += Patch-Imm32 -Name 'hit-edge-l-13F3C' -Lin 0x13F3C -Old 49  -New ($VIEW_X + 5) -Size 1    -Note 'view edge zone, left'
    $patches += Patch-Imm32 -Name 'hit-edge-b-13F4D' -Lin 0x13F4D -Old 322 -New ($VIEW_Y + $VIEW_H - 8)  -Note 'view edge zone, bottom'

    # NOT PATCHED, AND THIS IS DELIBERATE: 0x14D26 and 0x14DB8.
    #
    # They read `528 - cursorX` into [0x146940] / [0x14693E]. I had these down as
    # "text scrollbar anchors" and ran them through To-PanelX, which was wrong
    # twice over. They are the two VOLUME SLIDERS in the system fold-out (Q), the
    # ones drawn at 0x14E6A / 0x14ECB; and 528 is a SCREEN x compared against the
    # cursor, not a panel coordinate, so rescaling it with the panel was
    # meaningless. The result was sliders that read the wrong level and buttons
    # that could not be clicked at all.
    #
    # The fold-out is put back at its stock SCREEN position (see the overlay
    # block above), so 528 is correct exactly as Mindscape left it.

    # obj2 (base 0x140000) is file-backed for its first 0x13000 bytes; beyond that
    # is BSS. Both the button anchor and the hot-spot tables live in that window.
    $OBJ2_FILE = $DATA_PAGES + 291*4096
    function Obj2File([int]$lin) { return $OBJ2_FILE + ($lin - 0x140000) }

    # ---- the contextual panel buttons (nbut0/1/2) -----------------------------
    # Three lit/unlit sprite pairs blitted straight onto the panel. The hot-spot
    # polygons above make the CLICK land correctly; these make the highlight
    # actually appear under the cursor at the right size.
    #
    # The draw anchors are static data, not code -- which is why no scan of code
    # immediates ever found them. There are THREE, stored as two parallel word
    # arrays: X at 0x147488 = {235, 213, 363} and Y at 0x14748E = {343, 381, 386}.
    #
    # The call sites reach them by misaligned dword reads, taking the high word:
    #   nbut0: dword[0x147486]>>16 = X[0],  dword[0x14748C]>>16 = Y[0]
    #   nbut2: dword[0x14748A]>>16 = X[2],  dword[0x147490]>>16 = Y[2]
    # nbut1 (X[1], Y[1]) has no draw site in this build but is moved anyway.
    #
    # Each entry lines up with a hot spot on screen 0: X[0]/Y[0] with #0
    # (x 233..310, y 338..372), X[1]/Y[1] with #5 (x 213..283), X[2]/Y[2] with #6
    # (x 360..444, y 387..426).
    #
    # Because the reads are misaligned, each word is the high half of one dword
    # and the discarded low half of another, so all six patch independently.
    # Getting this wrong is quiet: patching only entry 0 leaves the right-hand
    # pair drawing at its stock Y, i.e. visible but floating above its button.
    $NBUT_ANCHORS = @(
        @{ i = 0; x = 235; y = 343 },
        @{ i = 1; x = 213; y = 381 },
        @{ i = 2; x = 363; y = 386 }
    )
    foreach ($a in $NBUT_ANCHORS) {
        # With a reskin the sockets come from the artwork, not from the scaled
        # stock layout -- see the hud-layout.json block above.
        $nx = To-PanelX $a.x; $ny = To-PanelY $a.y
        if ($script:SKIN_ACTIONS) { $nx = $script:SKIN_ACTIONS[$a.i].x; $ny = $script:SKIN_ACTIONS[$a.i].y }
        foreach ($axis in @(
            @{ n = 'X'; lin = 0x147488 + $a.i*2; was = $a.x; now = $nx },
            @{ n = 'Y'; lin = 0x14748E + $a.i*2; was = $a.y; now = $ny })) {
            $off = Obj2File $axis.lin
            $found = [BitConverter]::ToInt16($raw, $off)
            if ($found -ne $axis.was) { throw ("nbut anchor {0}{1}: expected {2}, found {3}" -f $axis.n, $a.i, $axis.was, $found) }
            $patches += New-Patch -Name ("nbut-anchor{0}-{1}" -f $a.i, $axis.n) -FileOffset $off `
                -Expect ([BitConverter]::GetBytes([int16]$axis.was)) -Replace ([BitConverter]::GetBytes([int16]$axis.now)) `
                -Note ("contextual button {0} anchor {1}: {2} -> {3}" -f $a.i, $axis.n, $axis.was, $axis.now)
        }
    }
    # Surface dimensions and pixel-buffer sizes, which must match the rescaled
    # artwork Build-HudArt.ps1 writes. Watcom leaves ebx/edx set up for the NEXT
    # create across the intervening malloc, so the pairs are not adjacent --
    # hence the explicit site list rather than a pattern.
    #   (heightSite, widthSite, bufferSite, stockW, stockH)
    # The six sites are three ON/OFF PAIRS: entries 0-1 are button 0, 2-3 are
    # button 1, 4-5 are button 2. Both halves of a pair must get the same size or
    # the highlighted state reads a differently-shaped buffer.
    $bi = 0
    foreach ($b in @(@(0x2D1E7, 0x2D1EC, 0x2D1FB, 83, 36),
                     @(0x2D200, 0x2D205, 0x2D21E, 83, 36),
                     @(0x2D223, 0x2D228, 0x2D241, 77, 42),
                     @(0x2D246, 0x2D24B, 0x2D264, 77, 42),
                     @(0x2D269, 0x2D26E, 0x2D287, 90, 43),
                     @(0x2D28C, 0x2D291, 0x2D2AA, 90, 43))) {
        $nw = [int][Math]::Round($b[3] * $PANEL_SCALE)
        $nh = [int][Math]::Round($b[4] * $PANEL_SCALE)
        if ($script:SKIN_ACTIONS) {
            $s = $script:SKIN_ACTIONS[[int][Math]::Floor($bi/2)]
            $nw = $s.w; $nh = $s.h
        }
        $bi++
        $patches += Patch-Imm32 -Name ("nbut-h-{0:X}" -f $b[0]) -Lin $b[0] -Old $b[4] -New $nh -Note 'contextual button sprite height'
        $patches += Patch-Imm32 -Name ("nbut-w-{0:X}" -f $b[1]) -Lin $b[1] -Old $b[3] -New $nw -Note 'contextual button sprite width'
        $patches += Patch-Imm32 -Name ("nbut-buf-{0:X}" -f $b[2]) -Lin $b[2] -Old ($b[3]*$b[4]) -New ($nw*$nh) `
            -Note ("contextual button pixel buffer {0} -> {1}" -f ($b[3]*$b[4]), ($nw*$nh))
    }

    # ---- the hot-spot POLYGON tables ------------------------------------------
    # This is where the panel buttons actually live. 0x2A349 builds screen N's
    # hot-spot list from a static table at [0x14712E + N*4] (7 screens):
    #     word count
    #     count x { word n;  int16 x,y [n];  word flagA; word flagB; word cursorIcon }
    # 0x33698 turns each point run into a 16-byte region and derives the bounding
    # box (+6..+0xC) from the points at runtime, and 0x336F8 tests bbox then
    # point-in-polygon. The "icon" selects the cursor shape (mice\*.pcx). The whole
    # block, 0x146A7C..0x14712E, sits in obj2's FILE-BACKED data, so the points
    # are rewritten here and no cursor remapping is needed at all -- which also
    # means the highlight draw, which reads the same region, lands correctly.
    #
    # Rules, per point:
    #   y >= 318                 panel artwork -> panel transform
    #   the automap rect         -> the automap's relocated rect (it is not scaled)
    #   the stock viewport rect  -> the new viewport rect
    #   the system fold-out      left alone: its artwork is drawn back at the
    #                            stock screen position (view-overlay-x), so its
    #                            stock hot spots are already right
    #   inside the stock view    an overlay composited INTO the view; the view
    #                            origin moved from x=44 to x=0, so -44
    $HOT_TABLE_PTRS = 0x14712E
    $VIEW_DX   = $VIEW_X - $VIEW_X_OLD               # -44

    # The story log's box, in SCREEN coordinates, before and after. The draw X is
    # view-relative (0x17D stock, patched by view-overlay-x-14F92) and the draw Y
    # is 0x23; the size is what textbox-w / textbox-h set.
    $LOG_BOX_OLD = @(($LOG_DRAW_X_OLD + $VIEW_X_OLD), ($LOG_DRAW_Y + $VIEW_Y_OLD))
    # With the log in the panel its click area is the panel box, not a point in
    # the view -- the coordinates are screen-absolute either way.
    # WITH THE EXPANDING BOX the click area is the EXPANDED rect, not the
    # collapsed one. Dialogue expands the box automatically, and options drawn in
    # the revealed half have to be pickable -- they were not, which made
    # conversations unplayable. The cost is that while the box is collapsed a
    # 174x120 strip of the view's bottom-right corner belongs to the log rather
    # than to the world; the alternative is moving the polygon at run time, which
    # means finding it in the malloc'd copy the prebuild makes at 0x164D9C.
    $LOG_HOT_TOP = if ($ENABLE_LOG_BOX_TOGGLE) { $RECESS_Y_BIG } else { $SCAN_Y }
    $LOG_BOX_NEW = if ($ENABLE_LOG_IN_PANEL) { @($RECESS_X, $LOG_HOT_TOP) }
                   else { @(($LOG_DRAW_X_NEW + $VIEW_X), ($LOG_DRAW_Y + $VIEW_Y)) }
    $LOG_SCALE_X = $TEXTBOX_W / $TEXTBOX_W_OLD
    # The VISIBLE height. With the expanding box that is the EXPANDED window, so
    # the click rows line up with the options on screen; without it, the fixed
    # one. Never the text SURFACE, which carries scrollback nobody can click.
    $LOG_HOT_H   = if ($ENABLE_LOG_BOX_TOGGLE) { $RECESS_H_BIG } else { $LOG_WIN_H }
    $LOG_SCALE_Y = $LOG_HOT_H / $TEXTBOX_H_OLD
    $script:logHotFound = 0

    $MAP_RECT_OLD = @(70,345,172,413)
    # PARENTHESES ARE LOAD-BEARING. PowerShell's comma binds tighter than '+', so
# @($a, $b, $a + 102, $b + 68) parses as ($a,$b,$a) + (102,$b) + 68 -- a SIX
# element array (41,401,41,102,401,68). That silently made [2] and [3] the wrong
# numbers and collapsed the notes/inventory hot spot to a 1px sliver, so the
# window could not be clicked at all.
$MAP_RECT_NEW = @($MAP_X, $MAP_Y, ($MAP_X + 102), ($MAP_Y + 68))

    # ---- the system fold-out's controls ------------------------------------
    # Which action id is which control was recovered by drawing the stock
    # polygons onto the stock artwork -- nothing in the table says. Result, in
    # panel-local coordinates of the 206x170 original:
    #
    #   000C load plate      000B save plate     000D quit arrow
    #   0008 music button    0007 sfx button
    #   000A music slider    0009 sfx slider     0010 confirm prompt
    #
    # Matched on the exact stock bounding box, so a table that ever differs from
    # what was measured fails the assertion below instead of quietly leaving a
    # button dead. The new rectangles come from $SYSMENU_PLATES, which
    # src\Build-SysMenu.ps1 also draws the lit states from.
    $FOLD_OX = 421; $FOLD_OY = 83        # where the stock panel sat on screen
    function Fold-Old([int]$x0,[int]$y0,[int]$x1,[int]$y1) {
        return ,@(($FOLD_OX + $x0), ($FOLD_OY + $y0), ($FOLD_OX + $x1), ($FOLD_OY + $y1))
    }
    function Fold-New([int]$lx,[int]$ly,[int]$lw,[int]$lh) {
        return ,@(($SYSMENU_SX + $lx), ($SYSMENU_SY + $ly), $lw, $lh)
    }
    $SYSMENU_HOT = @()
    foreach ($m in @(
            @{ n='load';  old=(Fold-Old 45 31 107 46);   plate=0 }
            @{ n='save';  old=(Fold-Old 45 94 107 109);  plate=4 }
            @{ n='quit';  old=(Fold-Old 87 57 107 84);   plate=2 }
            @{ n='music'; old=(Fold-Old 109 33 155 69);  plate=1 }
            @{ n='sfx';   old=(Fold-Old 109 71 139 106); plate=3 })) {
        # The plates are in the 412x340 reference space they were measured in, so
        # they scale to whatever size the panel is actually built at.
        $pl = $SYSMENU_PLATES[$m.plate]
        $SYSMENU_HOT += @{ n=$m.n; old=$m.old
                           new=(Fold-New ((Sys-S $pl.x) - $SYSMENU_PAD) ((Sys-S $pl.y) - $SYSMENU_PAD) `
                                         ((Sys-S $pl.w) + 2*$SYSMENU_PAD) ((Sys-S $pl.h) + 2*$SYSMENU_PAD)) }
    }
    # The sliders keep their 87 px travel, so their hot spots keep that width --
    # the click maths and the rectangle have to describe the same track or the
    # thumb jumps to somewhere the pointer is not.
    $SYSMENU_HOT += @{ n='music-slider'; old=(Fold-Old 20 43 106 69)
                       new=(Fold-New $SYSMENU_SLIDER_LX $SYSMENU_SLIDER_LY[0] $SYSMENU_SLIDER_W $SYSMENU_SLIDER_H) }
    $SYSMENU_HOT += @{ n='sfx-slider';   old=(Fold-Old 20 72 106 98)
                       new=(Fold-New $SYSMENU_SLIDER_LX $SYSMENU_SLIDER_LY[1] $SYSMENU_SLIDER_W $SYSMENU_SLIDER_H) }
    # The confirm prompt. DERIVED from $SYSMENU_CONFIRM, which states the same anchor
    # Build-SysMenu draws the caption at -- see the note there for what hand-placing it
    # cost. Padded like the plates so the words are not the exact edge of the target.
    $_cfW = (Sys-S $SYSMENU_CONFIRM.w) + 2*$SYSMENU_PAD
    $_cfH = (Sys-S $SYSMENU_CONFIRM.h) + 2*$SYSMENU_PAD
    $_cfX = (Sys-S ($SYSMENU_CONFIRM.cx - $SYSMENU_CONFIRM.w / 2)) - $SYSMENU_PAD
    $_cfY = (Sys-S $SYSMENU_CONFIRM.y) - $SYSMENU_PAD
    $SYSMENU_HOT += @{ n='confirm'; old=(Fold-Old 38 126 74 138); new=(Fold-New $_cfX $_cfY $_cfW $_cfH) }

    # EVERY fold-out hot spot must lie inside the panel. The confirm prompt's old
    # rectangle ran off the bottom edge, which is both a dead click area and a sign the
    # number was never derived from anything -- and nothing in the build noticed. A hot
    # spot outside the artwork cannot be correct, so it fails the build now.
    foreach ($m in $SYSMENU_HOT) {
        $hx, $hy, $hw, $hh = $m.new
        $lx = $hx - $SYSMENU_SX; $ly = $hy - $SYSMENU_SY
        if ($lx -lt 0 -or $ly -lt 0 -or ($lx + $hw) -gt $SYSMENU_W -or ($ly + $hh) -gt $SYSMENU_H) {
            throw ("fold-out hot spot '{0}' is outside the {1}x{2} panel: local ({3},{4}) {5}x{6}" -f `
                   $m.n, $SYSMENU_W, $SYSMENU_H, $lx, $ly, $hw, $hh)
        }
    }
    # THE VISOR'S MEMORY CORE (2026-10-09, Josh: the save/load list's text was "far too small"). The host draws a large
    # save/load screen (tools\ScanWire.cs, VisorMenu) where the game's tiny list was; its click targets move here to
    # THAT layout -- the close box, the five rows and RESTART, on both UI screens that carry the list (2: nothing picked,
    # 3: a row picked, OK live) -- and the row maths at 0x2CC37 (below) takes the new top and pitch. Matched on their
    # exact stock boxes (docs\save-load-screen-RE.md s4.1); new = x, y, w, h in screen px. VisorMenu's numbers are these.
    $ENABLE_MEMCORE = $true
    $SLOTLIST_TOP = 280; $SLOTLIST_PITCH = 76; $SLOTLIST_ROWH = 68; $SLOTLIST_X0 = 130 - $MENU_SHIFT; $SLOTLIST_X1 = 970 - $MENU_SHIFT
    $SLOTLIST_HOT = @()
    if ($ENABLE_MEMCORE) {
        $SLOTLIST_HOT += @{ n='close';   old=@(198, 93, 206, 101);  new=@((950 - $MENU_SHIFT), 160, 40, 40) }
        for ($sr = 0; $sr -lt 5; $sr++) {
            $SLOTLIST_HOT += @{ n=("row{0}" -f $sr); old=@(198, (114 + 24*$sr), 389, (127 + 24*$sr))
                                new=@($SLOTLIST_X0, ($SLOTLIST_TOP + $SLOTLIST_PITCH*$sr), ($SLOTLIST_X1 - $SLOTLIST_X0), $SLOTLIST_ROWH) }
        }
        $SLOTLIST_HOT += @{ n='restart'; old=@(264, 90, 323, 103);  new=@((130 - $MENU_SHIFT), 676, 430, 60) }
        if ($SLOTLIST_PITCH -gt 127 -or $SLOTLIST_ROWH -ge $SLOTLIST_PITCH) { throw "memory core: the row pitch must be <= 127 (imm8) and taller than a row" }
    }
    $script:slotHotFound = @{}
    $script:sysHotFound = @{}

    for ($scr = 0; $scr -lt 7; $scr++) {
        $tbl = 0x140000 + [BitConverter]::ToUInt32($raw, (Obj2File ($HOT_TABLE_PTRS + $scr*4)))
        $end = if ($scr -lt 6) { 0x140000 + [BitConverter]::ToUInt32($raw, (Obj2File ($HOT_TABLE_PTRS + ($scr+1)*4))) } else { $HOT_TABLE_PTRS }
        $off = Obj2File $tbl
        $exp = $raw[$off..($off + ($end - $tbl) - 1)]
        $rep = [byte[]]$exp.Clone()
        $p = 2; $count = [BitConverter]::ToInt16($exp, 0); $changed = 0
        for ($h = 0; $h -lt $count; $h++) {
            $n = [BitConverter]::ToInt16($exp, $p); $p += 2
            $xs = @(); $ys = @()
            for ($k = 0; $k -lt $n; $k++) { $xs += [BitConverter]::ToInt16($exp, $p + $k*4); $ys += [BitConverter]::ToInt16($exp, $p + $k*4 + 2) }
            $minX = ($xs | Measure-Object -Minimum).Minimum; $maxX = ($xs | Measure-Object -Maximum).Maximum
            $minY = ($ys | Measure-Object -Minimum).Minimum; $maxY = ($ys | Measure-Object -Maximum).Maximum
            # Anything wholly inside the region Build-HudArt copies 1:1 rides that
            # copy: the notes/inventory window and its two up/down buttons.
            $inHousing = ($minX -ge $INV_SRC_X -and $maxX -lt $INV_SRC_X + $INV_W -and `
                          $minY -ge $INV_SRC_Y -and $maxY -lt $INV_SRC_Y + $INV_H)
            $isView = ($n -eq 4 -and $minX -eq $VIEW_X_OLD -and $minY -eq $VIEW_Y_OLD -and $maxX -eq $VIEW_X_OLD+$VIEW_W_OLD -and $maxY -eq $VIEW_Y_OLD+$VIEW_H_OLD)
            $inView = ($minY -ge $VIEW_Y_OLD -and $maxY -le $VIEW_Y_OLD+$VIEW_H_OLD -and $minX -ge $VIEW_X_OLD -and $maxX -le $VIEW_X_OLD+$VIEW_W_OLD)
            # The rect 421..627 x 83..253 is the SYSTEM FOLD-OUT (the 206x170
            # SAVE%02d.pcx panel drawn at 0x14CFF), not the story log -- the log's
            # own hot spot is screen 5's 414..583 x 89..294 and does not match
            # this. Everything in here is the fold-out's controls: the two volume
            # sliders at 441..527 and the save/load/quit buttons. They are drawn
            # back at their stock screen position, so they must NOT be moved.
            $inFoldout = ($inView -and $minX -ge 421 -and $maxX -le 627 -and $minY -ge 83 -and $maxY -le 253)
            # THE STORY LOG'S OWN CLICK AREA. Screen 5 is switched on in exactly
            # one place, 0x17F21, and the two instructions either side of it set
            # [0x1521AC]->word[0x12] -- that IS the story-log object. Its quad
            # 414..583 x 89..294 sits over the log's stock screen rect (425,84)
            # 170x206, inset 11px left and overhanging 4px at the bottom.
            #
            # A plain translation is wrong here, because the log did not just
            # move: TEXTBOX_SCALE shrank it to 119x175 as well. So remap each
            # point through the box -- same position relative to the box, scaled
            # by how much the box scaled. Under the old VIEW_DX rule this landed
            # at 370..539 while the log draws at 506..625, overlapping it by only
            # 28%, which is why most of the log was dead to the mouse.
            $isStoryLog = ($n -eq 4 -and $minX -eq $LOG_HOT_OLD[0] -and $minY -eq $LOG_HOT_OLD[1] -and `
                                        $maxX -eq $LOG_HOT_OLD[2] -and $maxY -eq $LOG_HOT_OLD[3])
            if ($isStoryLog) { $script:logHotFound++ }
            # a whole-screen catch-all (screen 6) must stay whole-screen
            $isFullScreen = ($minX -le 0 -and $minY -le 0 -and $maxX -ge $SCREEN_W_OLD-1 -and $maxY -ge $SCREEN_H_OLD-1)
            # Does this polygon belong to a control the reskin relocated? Matched
            # on its exact stock bounding box, so a table that ever differs from
            # what was measured fails the assertion below rather than silently
            # leaving a button dead to the mouse.
            # NOT $h -- the enclosing region loop is `for ($h = 0; ...; $h++)`, and
            # binding a hashtable to it makes that outer increment die with
            # "the '++' operator works only on numbers".
            $foldout = $null
            foreach ($fh in $SYSMENU_HOT) {
                if ($minX -eq $fh.old[0] -and $minY -eq $fh.old[1] -and $maxX -eq $fh.old[2] -and $maxY -eq $fh.old[3]) {
                    $foldout = $fh; $script:sysHotFound[$fh.n] = [int]$script:sysHotFound[$fh.n] + 1; break
                }
            }
            $slot = $null
            foreach ($sl in $SLOTLIST_HOT) {
                if ($minX -eq $sl.old[0] -and $minY -eq $sl.old[1] -and $maxX -eq $sl.old[2] -and $maxY -eq $sl.old[3]) {
                    $slot = $sl; $script:slotHotFound[$sl.n] = [int]$script:slotHotFound[$sl.n] + 1; break
                }
            }
            $skin = $null
            if ($script:SKIN_HOT) {
                foreach ($sh in $script:SKIN_HOT) {
                    if ($minX -eq $sh.old[0] -and $minY -eq $sh.old[1] -and $maxX -eq $sh.old[2] -and $maxY -eq $sh.old[3]) {
                        $skin = $sh; $script:skinHotFound[$sh.n] = [int]$script:skinHotFound[$sh.n] + 1; break
                    }
                }
            }
            for ($k = 0; $k -lt $n; $k++) {
                $x = $xs[$k]; $y = $ys[$k]; $nx = $x; $ny = $y
                if ($slot) {
                    # the memory core's layout (bbox -> bbox, as the fold-out's controls)
                    $ow = [Math]::Max(1, $slot.old[2] - $slot.old[0])
                    $oh = [Math]::Max(1, $slot.old[3] - $slot.old[1])
                    $nx = $slot.new[0] + [int][Math]::Round(($x - $slot.old[0]) * $slot.new[2] / $ow)
                    $ny = $slot.new[1] + [int][Math]::Round(($y - $slot.old[1]) * $slot.new[3] / $oh)
                } elseif ($skin) {
                    # bbox -> bbox, so the outline keeps its shape on the new socket
                    $ow = [Math]::Max(1, $skin.old[2] - $skin.old[0])
                    $oh = [Math]::Max(1, $skin.old[3] - $skin.old[1])
                    $nx = $skin.new[0] + [int][Math]::Round(($x - $skin.old[0]) * $skin.new[2] / $ow)
                    $ny = $skin.new[1] + [int][Math]::Round(($y - $skin.old[1]) * $skin.new[3] / $oh)
                } elseif ($isFullScreen) {
                    # A whole-screen catch-all has to stay whole-screen, which at
                    # hi-res means the NEW screen, not 639x479.
                    $nx = if ($x -le 0) { 0 } else { $SCREEN_W - 1 }
                    $ny = if ($y -le 0) { 0 } else { $SCREEN_H - 1 }
                } elseif ($foldout) {
                    # bbox -> bbox, exactly like $skin: the polygon keeps its shape
                    # and lands on the control's new plate.
                    $ow = [Math]::Max(1, $foldout.old[2] - $foldout.old[0])
                    $oh = [Math]::Max(1, $foldout.old[3] - $foldout.old[1])
                    $nx = $foldout.new[0] + [int][Math]::Round(($x - $foldout.old[0]) * $foldout.new[2] / $ow)
                    $ny = $foldout.new[1] + [int][Math]::Round(($y - $foldout.old[1]) * $foldout.new[3] / $oh)
                } elseif ($inFoldout) {
                    throw ("un-mapped fold-out hot spot ({0},{1})..({2},{3}) -- add it to `$SYSMENU_HOT" -f $minX,$minY,$maxX,$maxY)
                } elseif ($isStoryLog -and $ENABLE_LOG_IN_PANEL -and $ENABLE_LOG_BOX_TOGGLE) {
                    # EXACTLY THE OPEN RECESS (Josh, 2026-10-13: "sometimes I cannot select the first option in the
                    # dialogue choices"). Scaling the stock quad through the box carried its 5-row top inset along, x2.7
                    # with the box: the quad began at y 555 while the options' row 0 -- which AztConvHit measures from
                    # $RECESS_Y_BIG -- is at 541. A click on the first option's top line (most of a one-line option)
                    # fell above the quad, so the game never raised event 0x18 for it; just below the text it worked.
                    # Its sides were off too (28 px past the left, 31 px short of the right). The stock inset existed
                    # because the stock table's row 0 was screen y 89 (text Y + 0x59) -- the quad's top WAS the text's
                    # row 0, and that is what it has to stay: the recess's first row to its last, edge to edge.
                    $nx = if ($x -eq $LOG_HOT_OLD[0]) { $RECESS_X } else { $RECESS_X + $RECESS_W - 1 }
                    $ny = if ($y -eq $LOG_HOT_OLD[1]) { $RECESS_Y_BIG } else { $RECESS_Y_BIG + $RECESS_H_BIG - 1 }
                } elseif ($isStoryLog) {
                    $nx = $LOG_BOX_NEW[0] + [int][Math]::Round(($x - $LOG_BOX_OLD[0]) * $LOG_SCALE_X)
                    $ny = $LOG_BOX_NEW[1] + [int][Math]::Round(($y - $LOG_BOX_OLD[1]) * $LOG_SCALE_Y)
                } elseif ($inHousing) {
                    # Inside the 1:1 housing copy: shift by exactly the delta the
                    # artwork moved. One rule covers the window AND both up/down
                    # buttons, so they cannot drift apart, and they stay full size
                    # instead of being panel-scaled away from what they scroll.
                    # SCALED, not just shifted. The art generator draws the
                    # housing at Hi(src + 62) with the panel top as its origin and
                    # the copy scaled by the screen factor, so the hot spots have
                    # to follow the same transform -- otherwise they stay in
                    # 640-space and nothing on the panel can be hovered, which is
                    # exactly what happened at 800x600.
                    # At 640x480 (HS = 1) this is identical to the old x+62 / y+51.
                    $nx = Hi ($x + $INV_DX)
                    $ny = $PANEL_TOP_NEW + (Hi ($y - $INV_SRC_Y))
                } elseif ($isView) {
                    $nx = if ($x -eq $VIEW_X_OLD) { $VIEW_X } else { $VIEW_X + $VIEW_W }
                    $ny = if ($y -eq $VIEW_Y_OLD) { $VIEW_Y } else { $VIEW_Y + $VIEW_H }
                } elseif ($y -ge $PANEL_TOP_OLD) {
                    $nx = To-PanelX $x; $ny = To-PanelY $y
                } elseif ($inView) {
                    $nx = $x + $VIEW_DX
                }
                if ($nx -ne $x -or $ny -ne $y) {
                    [BitConverter]::GetBytes([int16]$nx).CopyTo($rep, $p + $k*4)
                    [BitConverter]::GetBytes([int16]$ny).CopyTo($rep, $p + $k*4 + 2)
                    $changed++
                }
            }
            $p += $n*4 + 6
        }
        if ($p -ne $exp.Length) { throw ("hot-spot table {0}: walked {1} bytes of {2}" -f $scr, $p, $exp.Length) }
        if ($changed) {
            $patches += New-Patch -Name ("hotspots-screen{0}" -f $scr) -FileOffset $off -Expect $exp -Replace $rep `
                -Note ("hot-spot polygons for UI screen {0}: {1} points moved with the panel / view" -f $scr, $changed)
        }
    }
    # The story log's quad is matched by its exact stock geometry, so if the
    # tables ever differ from what was measured here it must fail loudly rather
    # than quietly leave the log unclickable again.
    if ($script:logHotFound -ne 1) {
        throw ("expected exactly one story-log hot spot ({0}), found {1}" -f ($LOG_HOT_OLD -join ','), $script:logHotFound)
    }
    # Same contract for the fold-out. The panel appears on three UI screens, so
    # each control should have been matched on every screen that carries it; a
    # count of zero means the measurement is stale and that button is now dead.
    foreach ($sl in $SLOTLIST_HOT) {
        if ([int]$script:slotHotFound[$sl.n] -ne 2) {
            throw ("memory core: slot-list hot spot '{0}' ({1}) matched {2} times, expected 2 (UI screens 2 and 3)" -f $sl.n, ($sl.old -join ','), [int]$script:slotHotFound[$sl.n])
        }
    }
    if ($ENABLE_MEMCORE) {
        # WHICH row the click picked comes from the cursor's Y alone (0x2CBF3): `sub edx,0x72 / mov ebx,0x18 / mov eax,edx`
        # -> `lea eax,[edx-TOP] / push PITCH / pop ebx / nop`. The following `sar edx,0x1F` then works on the raw Y (always
        # >= 0 inside a row), so edx:eax is still the right dividend. 10 bytes, no fixups (checked).
        $rmAt = [uint32]0x2CC37; $topNeg = [uint32]([int64]4294967296 - $SLOTLIST_TOP)
        $patches += New-Patch -Name 'memcore-rowmath-2CC37' -FileOffset (Lin2File $rmAt) `
            -Expect ([byte[]]@(0x83, 0xEA, 0x72, 0xBB, 0x18, 0x00, 0x00, 0x00, 0x89, 0xD0)) `
            -Replace ([byte[]]@(0x8D, 0x82, ($topNeg -band 0xFF), (($topNeg -shr 8) -band 0xFF), (($topNeg -shr 16) -band 0xFF), (($topNeg -shr 24) -band 0xFF), 0x6A, $SLOTLIST_PITCH, 0x5B, 0x90)) `
            -Note ("save/load row from the cursor: (Y - {0}) / {1} -- the memory core's rows (VisorMenu), not the stock 114/24" -f $SLOTLIST_TOP, $SLOTLIST_PITCH)
        # A STOCK BUG, FIXED (Josh, 2026-10-09): picking RESTART sets the selection to 6 without backing anything up, and
        # every "put the edited name back" site then copies the backup into slot 6 -- 0x152434 + 180 = 0x1524E8, inside a
        # live object at 0x1524D0 (RESTART, then the close box, was enough). Each site reads the selection, `cmp reg,-1 /
        # jz skip`; it becomes `cmp reg,5 / jae skip` (unsigned: -1 and 6 both skip, 0..4 restore). Two bytes a site, after
        # the relocated operand, no fixups (checked). The six: close 0x2C2D4, QUIT, LOAD off, SAVE off, close box, row click.
        foreach ($rs in @(0x2C30E, 0x2C92B, 0x2CA46, 0x2CB26, 0x2CBA2, 0x2CBFC)) {
            $patches += New-Patch -Name ("memcore-restore-guard-{0:X5}" -f $rs) -FileOffset (Lin2File ([uint32]($rs + 2))) `
                -Expect ([byte[]]@(0xFF, 0x74, 0x2F)) -Replace ([byte[]]@(0x05, 0x73, 0x2F)) `
                -Note 'save/load name restore: only for slots 0..4 (stock restored into "slot 6" after RESTART, corrupting 0x1524D0)'
        }
        Write-Host ("memory core: slot list hot spots moved ({0}), rows from y {1} every {2}" -f (($SLOTLIST_HOT | ForEach-Object { $_.n }) -join ', '), $SLOTLIST_TOP, $SLOTLIST_PITCH)
    }
    foreach ($fh in $SYSMENU_HOT) {
        if (-not $script:sysHotFound[$fh.n]) {
            throw ("fold-out control '{0}' ({1}) was never matched -- its stock hot spot has moved" -f $fh.n, ($fh.old -join ','))
        }
    }
    Write-Host ("system fold-out: {0}x{1} at screen ({2},{3}); controls remapped {4}" -f `
                $SYSMENU_W, $SYSMENU_H, $SYSMENU_SX, $SYSMENU_SY,
                (($SYSMENU_HOT | ForEach-Object { "{0} x{1}" -f $_.n, $script:sysHotFound[$_.n] }) -join ', '))
    # Same contract for the reskin's controls: every relocated region must have
    # been found exactly once. A miss here is a button that draws in its new home
    # and clicks in its old one, which is silent and maddening to diagnose.
    if ($script:SKIN_HOT) {
        $missed = @($script:SKIN_HOT | Where-Object { $script:skinHotFound[$_.n] -lt 1 } | ForEach-Object { $_.n })
        if ($missed.Count) {
            throw ("these reskin hot spots were never found in the stock polygon tables: {0} -- the tables do not look like what Build-HudSkin measured against" -f ($missed -join ', '))
        }
        Write-Host "hot spots moved onto the artwork:"
        foreach ($h2 in $script:SKIN_HOT) {
            Write-Host ("   {0,-17} ({1},{2})..({3},{4}) -> ({5},{6}) {7}x{8}   x{9}" -f `
                $h2.n, $h2.old[0], $h2.old[1], $h2.old[2], $h2.old[3], $h2.new[0], $h2.new[1], $h2.new[2], $h2.new[3], $script:skinHotFound[$h2.n])
        }
    }
}

# Stop the game auto-turning you away from walls.
#
# When movement is blocked the integrator nudges the CAMERA yaw by +/-10 and
# abandons the move, so leaning on a wall slowly spins you. Six sites do it, each
# immediately followed by an unconditional `jmp 0x1DE08` -- so the flags the
# add/sub sets are never read, and zeroing the immediate turns each into a no-op.
#
# The instruction is `66 83 2D <disp32> 0A`; the disp32 at +3 carries a fixup, so
# the whole instruction cannot be NOPed. The immediate at +7 is clear of it, which
# is why this is a one-byte change per site rather than a hook.
foreach ($w in @(0x1D879, 0x1D8EE, 0x1DA0D, 0x1DA94, 0x1DBCB, 0x1DC31)) {
    $o = (Lin2File $w) + 7
    if ($raw[$o] -ne 0x0A) { throw ("expected yaw nudge 0x0A at 0x{0:X}+7" -f $w) }
    $patches += New-Patch -Name ("no-wall-turn-{0:X}" -f $w) -FileOffset $o `
        -Expect ([byte[]]@(0x0A)) -Replace ([byte[]]@(0x00)) `
        -Note 'wall collision no longer rotates the player away'
}

# ---- wall sliding -----------------------------------------------------------
# Two patches per the design note above AztWallSlide: a save hook, and the
# blocked-move exits redirected into the slide stub.
#
# There are TWO forward paths, selected at 0x1D733 / 0x1D741, and they differ only
# in which speed constant they use:
#
#   path A  head 0x1D747  speed [0x141800]
#   path B  head 0x1D8FB  speed [0x1417FC]
#
# and each path runs TWO collision tests, each with its own wall-normal block and
# its own private exit:
#
#   | path | save   | 0x10160 fails      | 0x10180 fails      |
#   |------|--------|--------------------|--------------------|
#   | A    | 0x1D75B| jae 0x1D873 -> 0x1D881 | jae 0x1D8E8 -> 0x1D8F6 |
#   | B    | 0x1D90F| jae 0x1DA07 -> 0x1DA15 | jae 0x1DA8E -> 0x1DA9C |
#
# v0.11.1/v0.11.2 paired 0x1D881 with path A and 0x1D8F6 with path B. That was
# simply wrong -- BOTH belong to path A. Path B, which is the path ordinary
# movement actually falls into, had no slide hooks at all, which is why no
# version so far produced any sliding.
#
# Do NOT touch the shared `+10` site at 0x1DC31: FOUR tests jump to it and a fifth
# falls in from 0x1DC2B. v0.11.0 redirected it and three unrelated movement paths
# ended up restoring path A's stack slots and resuming path A's code -- the player
# could walk through walls and get teleported. Only the private exits are safe.
#
# To still catch both sides of a wall, each `jae 0x1DC31` is retargeted to the very
# next instruction so both branches fall into that test's own private exit. Nothing
# is lost: no-wall-turn has already zeroed both rotation immediates, so the two
# branches are behaviourally identical.
#
# Not hooked HERE: the earlier `call 0x11E68 / test ax,ax / jnz 0x1DE08` at 0x1D78C and
# 0x1D940 (they are now AztStepRetry's -- see step-retry below: 0x11E68 is the GROUND test,
# and it makes no wall normal). v0.11.2 treated those as a wall test; they are not. 0x11E68
# drives the object-scan readout (it touches 0x152AD4 and 0x1523E2) and rejects a
# step that runs into an interactive OBJECT, without computing a wall normal -- so
# sliding there would retry against a stale 0x162DD4.
$o = Lin2File 0x1D733
if ($raw[$o] -ne 0x0F -or $raw[$o+1] -ne 0x84) { throw 'movement path selector at 0x1D733 moved' }
foreach ($h in @(
    @{ save = 0x1D75B; head = 0x1D747 },   # path A, speed [0x141800]
    @{ save = 0x1D90F; head = 0x1D8FB }    # path B, speed [0x1417FC]
)) {
    if (($h.save - $h.head) -ne 0x14) { throw ("save offset for 0x{0:X} is not +0x14" -f $h.head) }
    $o = Lin2File $h.save
    if ($raw[$o] -ne 0xD8) { throw ("no fadd at 0x{0:X} -- movement layout changed" -f $h.save) }
    $patches += New-Patch -Name ("slide-save-{0:X}" -f $h.save) -FileOffset $o `
        -Expect $raw[$o..($o + 5)] `
        -Replace ([byte[]]((CallRel32 ([uint32]$h.save) $asm.Labels['AztSaveMove']) + @(0x90))) `
        -Note 'record the pre-move position so a blocked step can be retried'
}
foreach ($x in @(
    @{ jae = 0x1D873; exit = 0x1D881 },    # path A, 0x10160
    @{ jae = 0x1D8E8; exit = 0x1D8F6 },    # path A, 0x10180
    @{ jae = 0x1DA07; exit = 0x1DA15 },    # path B, 0x10160
    @{ jae = 0x1DA8E; exit = 0x1DA9C }     # path B, 0x10180
)) {
    $o = Lin2File $x.jae
    if ($raw[$o] -ne 0x0F -or $raw[$o+1] -ne 0x83) { throw ("no jae at 0x{0:X}" -f $x.jae) }
    $patches += New-Patch -Name ("slide-jae-{0:X}" -f $x.jae) -FileOffset $o `
        -Expect $raw[$o..($o + 5)] `
        -Replace ([byte[]](@(0x0F, 0x83) + [BitConverter]::GetBytes([int](($x.jae + 6) - ($x.jae + 6))))) `
        -Note 'both wall sides now use this test''s own collision exit'

    $o = Lin2File $x.exit
    if ($raw[$o] -ne 0xE9) { throw ("no jmp at 0x{0:X} -- collision exit layout changed" -f $x.exit) }
    $rel = [int]$asm.Labels['AztWallSlide'] - ([int]$x.exit + 5)
    $patches += New-Patch -Name ("slide-exit-{0:X}" -f $x.exit) -FileOffset $o `
        -Expect $raw[$o..($o + 4)] `
        -Replace ([byte[]](@(0xE9) + [BitConverter]::GetBytes([int]$rel))) `
        -Note 'blocked move slides along the wall instead of stopping dead'
}

# The GROUND test's reject (0x11E68 nonzero: no floor under the new spot, or a face
# above knee height there) now retries the step along one axis -- AztStepRetry. The
# `jnz 0x1DE08` is the step's own private abandon (rel32, no fixup).
foreach ($r in @(0x1D78C, 0x1D940)) {
    $o = Lin2File $r
    if ($raw[$o] -ne 0x0F -or $raw[$o+1] -ne 0x85 -or ([BitConverter]::ToInt32($raw, $o + 2) + $r + 6) -ne 0x1DE08) { throw ("no jnz 0x1DE08 at 0x{0:X} -- ground-test exit moved" -f $r) }
    $rel = [int]$ovlAsm.Labels['AztStepRetry'] - ([int]$r + 6)
    $patches += New-Patch -Name ("step-retry-{0:X}" -f $r) -FileOffset $o `
        -Expect $raw[$o..($o + 5)] `
        -Replace ([byte[]](@(0x0F, 0x85) + [BitConverter]::GetBytes([int]$rel))) `
        -Note 'a step the ground test rejects (a seam, a lip, an object top) is retried along one axis instead of stopping dead'
}

# Remove the pitch indicator -- the little vertical scale, drawn into the LEFT
# edge of the 3D view at view-relative x 3..29, y 104..166, whose marker slides
# with how far up or down you are looking.
#
# It is driven by word [0x14720E], the camera pitch (clamped to 60 and 300, i.e.
# +/-60 degrees, at 0x1D3D0/0x1D3F0). That global is the ONLY pitch value the HUD
# draws from, so this block is the whole feature: a scale, a moving marker, and a
# "%d" readout printed next to it at 0x14573.
#
# No need to touch any of the ten draw calls. The block already opens with its
# own guard -- `cmp word [0x146972],0 / jz 0x14578` -- that jumps clean past the
# lot. Forcing that branch unconditional removes it in one 6-byte patch, with no
# stack juggling (0x3847C is `ret 8`) and no dead pushes.
$o = Lin2File 0x143C1
if ($raw[$o] -ne 0x0F -or $raw[$o+1] -ne 0x84) { throw 'pitch indicator guard at 0x143C1 is not a jz rel32' }
$rel = 0x14578 - (0x143C1 + 5)
$patches += New-Patch -Name 'no-pitch-indicator' -FileOffset $o `
    -Expect $raw[$o..($o + 5)] `
    -Replace ([byte[]](@(0xE9) + [BitConverter]::GetBytes([int]$rel) + @(0x90))) `
    -Note 'skip the camera-pitch scale on the left edge of the view'

# Remove the full-screen combat crosshair lines, keeping the 30x30 circle cursor.
# Six calls inside the combat HUD block draw lines 551 wide / 281 tall centred on
# the pointer. 0x3847C is a shared line/rect primitive (46 callers) so it cannot
# be patched itself -- and it returns `ret 8`, so the call cannot simply be NOPed
# either: the two pushed arguments still have to be cleaned up. `add esp, 8` does
# exactly that and skips the draw.
foreach ($c in @(0x145C8, 0x145E8, 0x14682, 0x1469F, 0x146C2, 0x146E0)) {
    $o = Lin2File $c
    if ($raw[$o] -ne 0xE8) { throw ("no call at 0x{0:X} -- crosshair layout changed" -f $c) }
    $patches += New-Patch -Name ("no-crosshair-{0:X}" -f $c) -FileOffset $o `
        -Expect $raw[$o..($o + 4)] `
        -Replace ([byte[]]@(0x83, 0xC4, 0x08, 0x90, 0x90)) `
        -Note 'skip one full-screen combat crosshair line (stack args still cleaned)'
}

# ---- move the combat reticle with the viewport ------------------------------
# The combat HUD draws into the VIEW surface (0x152150), so it converts the
# screen-space cursor to view space first -- the same `sub x,0x2C / sub y,0x31`
# pair that 3D picking uses at 0x11771. That X conversion was left at 44 while
# view-pick-11771 moved picking to 0, so the reticle sat 44px LEFT of where the
# game was actually aiming. The Y side is untouched because the view still starts
# at y=49.
#
# The locals are identified by the line extents, not by guessing: 0x145AE feeds a
# line spanning 0..551 (view WIDTH-1) so [ebp+0x5C] is Y, and 0x145CF feeds one
# spanning 0..281 (view HEIGHT-1) so [ebp+0x5A] is X.
#
# Only 0x145D4 and 0x14649 are visible today -- the reticle circle (0x38558 at
# 0x145FD) and the status text beside it. The 0x146xx pair belongs to the gapped
# crosshair variant whose four line draws no-crosshair already removes, but they
# are the same conversion and are corrected too so the block stays coherent if
# those lines are ever restored.
#
# Every site is `83 E8 ib`, so this is one byte each. New = old + VIEW_DX, which
# goes negative for offsets that sat right of the cursor -- fine as a signed imm8.
if ($ENABLE_BIG_VIEW -and $VIEW_X -ne $VIEW_X_OLD) {
    $dx = $VIEW_X - $VIEW_X_OLD                       # -44
    foreach ($r in @(@(0x145D4, 0x2C, 'reticle circle'),
                     @(0x14649, 0x21, 'combat status text'),
                     @(0x14675, 0x36, 'gapped crosshair, left span'),
                     @(0x14693, 0x22, 'gapped crosshair, right span'),
                     @(0x146B1, 0x2C, 'gapped crosshair, vertical'))) {
        $o = Lin2File $r[0]
        if ($raw[$o] -ne 0x83 -or $raw[$o+1] -ne 0xE8 -or $raw[$o+2] -ne $r[1]) {
            throw ("combat HUD: expected 'sub eax, 0x{0:X}' at 0x{1:X}" -f $r[1], $r[0])
        }
        $new = $r[1] + $dx
        if ($new -lt -128 -or $new -gt 127) { throw ("reticle offset at 0x{0:X} will not fit an imm8" -f $r[0]) }
        $patches += New-Patch -Name ("view-reticle-{0:X}" -f $r[0]) -FileOffset ($o + 2) `
            -Expect ([byte[]]@($r[1])) -Replace ([byte[]]@([byte]($new -band 0xFF))) `
            -Note ("{0}: screen->view X offset {1} -> {2}" -f $r[2], $r[1], $new)
    }
}

# `len` is the length of the ORIGINAL instruction, and must be stated explicitly.
# A 5-byte call is emitted and the remainder padded with NOPs.
#
# Getting this wrong is nasty. hook-strafe replaces a 6-byte `jnz rel32`, but the
# generator used to assume every hook replaced a 5-byte `call`. The leftover byte
# became a stray `add byte [esi-0x7D], ah` that executed on the fall-through path,
# corrupting memory and desynchronising the decode. Symptom: forward and both
# strafes dead, while backward -- the only path that branches away before reaching
# the orphaned byte -- kept working.
foreach ($h in @(
    @{ n='hook-rmb-down'; at=$HOOK_RMBDN;  len=5; to='AztRmbDown';      d='RMB press -> handled by the frame hook' },
    @{ n='hook-rmb-up';   at=$HOOK_RMBUP;  len=5; to='AztRmbUp';        d='RMB release -> handled by the frame hook' },
    @{ n='hook-keydown';  at=$HOOK_KEY;    len=5; to='AztKeyHook';      d='key down -> WASD remap + F2/F3, else pass through' },
    @{ n='hook-keyup';    at=$HOOK_KEYUP;  len=5; to='AztKeyUpHook';    d='key up -> WASD remap so movement flags clear correctly' },
    @{ n='hook-redraw';   at=$HOOK_REDRAW; len=5; to='AztCursorRedraw'; d='pin the combat crosshair to the view centre while looking' },
    @{ n='hook-strafe';   at=$HOOK_STRAFE; len=6; to='AztStrafe';       d='rotate the movement vector 90 degrees while A or D is held' }
) + $(if ($ENABLE_ACTOR_TIME) { @(
    # Clock-gated: the percentage version below can only be right at one frame
    # rate, and the frame rate varies room to room.
    @{ n='hook-actor';    at=$HOOK_ACTOR;  len=5; abs=$tAsm.Labels['AztActorTime'];
       d=("actors advance on the 18.2 Hz BIOS clock (period {0}/100 tick), not on frames" -f $ACTOR_PERIOD) }
) } elseif ($ENABLE_ACTOR_RATE) { @(
    @{ n='hook-actor';    at=$HOOK_ACTOR;  len=5; to='AztActorTick';    d=("actors advance on {0}% of frames, so raising the CPU does not speed them up" -f $ACTOR_PCT) }
) } else { @() }) + $(if ($false) { @(
    # RETIRED. These rewrote the cursor into stock-artwork space so the game's
    # hot-spot polygons would still match a rescaled panel. They fixed the hit
    # test but not the highlight draw, which reads the same polygon. Now the
    # polygons themselves are rewritten in data (hotspots-screen*), so both the
    # test and the draw are right and a cursor remap would double-transform.
    @{ n='hook-hudpoint'; at=$HOOK_HUDPOINT; len=$HOOK_HUDPOINT_LEN; to='AztHudPoint'; d='remap a screen click onto the rescaled instrument panel' },
    @{ n='hook-hudevent'; at=$HOOK_HUDEVENT; len=5; to='AztHudEvent'; d='remap the mouse EVENT record, so hover and click reach the right widget' }
) })) {
    $off = Lin2File $h.at
    if ($h.len -lt 5) { throw ("{0}: cannot hook a {1}-byte instruction" -f $h.n, $h.len) }
    $repl = New-Object byte[] $h.len
    # `to` names a label in the cave stub; `abs` is an absolute address, for a
    # hook that targets a second blob assembled somewhere else.
    $target = if ($h.ContainsKey('abs')) { [uint32]$h.abs } else { $asm.Labels[$h.to] }
    (CallRel32 $h.at $target).CopyTo($repl, 0)
    for ($k = 5; $k -lt $h.len; $k++) { $repl[$k] = 0x90 }
    $patches += New-Patch -Name $h.n -FileOffset $off `
        -Expect $raw[$off..($off + $h.len - 1)] -Replace $repl -Note $h.d
}

# ---- Assert-NoOverlap ------------------------------------------------------
# NO TWO PATCHES MAY TOUCH THE SAME FILE BYTE.
#
# This is not hypothetical tidiness. `lfb-mode-bit` and `vesa-mode-33ABB` both
# owned the four bytes at file 0x85510 for many builds: both expected 01 01 00 00,
# one wrote 01 41 00 00 (mode 0x101 + the LFB bit) and the other 05 01 00 00 (mode
# 0x105). The applier walks the list in order, so the second silently overwrote the
# first and the LFB bit was never requested in any hires build -- the shipped R.EXE
# read 05 01 00 00. Nothing detected it: the patch count was right, every site
# verified against the pristine bytes, and the game ran (because `lfb-one-bank`
# makes the whole framebuffer fit bank 0 either way). The only symptom was a patch
# that quietly did nothing.
#
# It also explains why Test-Patch.ps1 threw `vesa-mode-33ABB: mismatch at +1`: it
# checks each patch's expected bytes AFTER applying the earlier ones, so an overlap
# looks to it like a corrupt manifest, and it aborted before its other checks ran.
#
# Overlap is always a bug -- either two patches disagree, or one is dead. Fail the
# build and name both, rather than let ordering decide.
$byteOwner = @{}
$overlaps  = New-Object System.Collections.ArrayList
foreach ($p in $patches) {
    $len = if ($p.replace) { $p.replace.Length / 2 } else { 0 }
    for ($i = 0; $i -lt $len; $i++) {
        $addr = [int]$p.offset + $i
        if ($byteOwner.ContainsKey($addr)) {
            $key = "{0} vs {1}" -f $byteOwner[$addr], $p.name
            if (-not $overlaps.Contains($key)) { [void]$overlaps.Add($key) }
        } else {
            $byteOwner[$addr] = $p.name
        }
    }
}
if ($overlaps.Count) {
    Write-Host "PATCHES OVERLAP -- two patches write the same file bytes:" -ForegroundColor Red
    foreach ($o in $overlaps) { Write-Host ("   {0}" -f $o) -ForegroundColor Red }
    throw ("{0} overlapping patch pair(s); the applier's order would decide the result" -f $overlaps.Count)
}
Write-Host ("no-overlap check: {0} patches cover {1:N0} distinct file bytes, none shared" -f `
            $patches.Count, $byteOwner.Count)

$manifest = [ordered]@{
    modName      = 'AztMod'
    modVersion   = '0.16.0'
    feature      = ("FPS mode + WASD + {0}x{1}" -f $SCREEN_W, $SCREEN_H)
    # The installer needs this: a hi-res build only works once UVCONFIG.DAT is out
    # of the way (see the note in Apply-AztMod.ps1).
    hires        = $ENABLE_HIRES
    # ---- THE VIEW GEOMETRY, for every host-side tool ------------------------
    # Published because host tools kept hard-coding it and so kept belonging to one
    # resolution: Test-FullFrame.ps1 still defaults to 1024x576, which has been wrong
    # since the 1600x1200 move, and a frame of the wrong width does not fail -- it
    # SHEARS, the same silent failure the opening movie had. Anything host-side reads
    # these instead of assuming, and then it cannot disagree with the build.
    view         = [ordered]@{
        screenW  = $SCREEN_W
        screenH  = $SCREEN_H
        injX     = $INJ_X
        injY     = $VIEW_Y_KEEP
        injW     = $INJ_W
        injH     = $INJ_H
        stride   = $VIEW_STRIDE
        bytes    = ($INJ_W * $INJ_H)
        hookAt   = ('0x{0:X}' -f $INJ_SITES[0].At)
    }
    targetFile   = 'GAME/AZRAEL/R.EXE'
    targetSha256 = (Get-FileHash -Path $GameExe -Algorithm SHA256).Hash
    targetLength = $raw.Length
    caveBase     = ('0x{0:X}' -f $CAVE_BASE)
    caveEnd      = ('0x{0:X}' -f $asm.End)
    keys         = @(
        'Mouse             look around -- the default now, nothing to hold'
        'W S               forward / back'
        'A D               STRAFE left / right (true lateral movement)'
        'HOLD right mouse  restores the game''s normal pointer with its contextual'
        '                  TAKE / USE / PUSH icons. Release to go back to looking.'
        'Left mouse        fires the weapon IN COMBAT MODE (Space toggles combat).'
        '                  It no longer walks you forward. Outside combat it does'
        '                  nothing -- the game has no separate fire key.'
        'UP / DOWN arrows  scroll the story log in the panel. They no longer move'
        '                  you -- movement is WASD, so they were duplicates.'
        'F3                sticky cursor mode, if you would rather not hold a button'
        'F10               invert mouse Y (stock game feature)'
        ''
        ('The HUD boot banner reads "{0}" when the mod is live.' -f $BANNER_NEW)
    )
    symbols      = ($asm.Labels.GetEnumerator() | Sort-Object Value |
                      ForEach-Object { [ordered]@{ name=$_.Key; linear=('0x{0:X}' -f $_.Value) } })
    # The BSS overlay travels INSIDE the manifest rather than as a second file.
    # Its routines are called from patched sites by absolute address, so a
    # manifest and an AZTCODE.BIN from different builds would be a crash with no
    # symptom to trace -- keeping them in one artifact makes that impossible.
    overlay      = $(if ($ENABLE_ACTOR_TIME) { [ordered]@{
        name  = $OVERLAY_NAME
        dir   = 'GAME/AZRAEL'
        base  = ('0x{0:X}' -f $OVERLAY_BASE)
        bytes = (Hex $ovlAsm.Bytes)
    } } else { $null })
    settings     = @(
        [ordered]@{ name='aztEnabled';    linear=('0x{0:X}' -f $asm.Labels['aztEnabled']);    file=(Lin2File $asm.Labels['aztEnabled']);    size=2; default=1;         desc='master switch (F2 in game)' }
        [ordered]@{ name='aztWantCursor'; linear=('0x{0:X}' -f $asm.Labels['aztWantCursor']); file=(Lin2File $asm.Labels['aztWantCursor']); size=2; default=0;         desc='0 = centred look, 1 = free pointer' }
        [ordered]@{ name='aztCentreX';    linear=('0x{0:X}' -f $asm.Labels['aztCentreX']);    file=(Lin2File $asm.Labels['aztCentreX']);    size=2; default=$CENTRE_X; desc='pointer anchor X (3D view centre)' }
        [ordered]@{ name='aztCentreY';    linear=('0x{0:X}' -f $asm.Labels['aztCentreY']);    file=(Lin2File $asm.Labels['aztCentreY']);    size=2; default=$CENTRE_Y; desc='pointer anchor Y (3D view centre)' }
        [ordered]@{ name='aztActorPct';   linear=('0x{0:X}' -f $asm.Labels['aztActorPct']);   file=(Lin2File $asm.Labels['aztActorPct']);   size=2; default=$ACTOR_PCT; desc='percent of frames on which actors/animations advance (100 = stock)' }
    ) + $(if ($ENABLE_ACTOR_TIME) { @(
        [ordered]@{ name='aztPeriod'; linear=('0x{0:X}' -f $tAsm.Labels['aztPeriod']); file=(Lin2File $tAsm.Labels['aztPeriod']); size=2; default=$ACTOR_PERIOD; desc='hundredths of a BIOS tick between actor steps (100 = 18.2 Hz); bigger = slower' }
        [ordered]@{ name='aztFramePeriod'; linear=('0x{0:X}' -f $tAsm.Labels['aztFramePeriod']); file=(Lin2File $tAsm.Labels['aztFramePeriod']); size=4; default=$FRAME_PERIOD; desc=('MICROSECONDS per frame; {0} = {1} fps. Bigger = slower cap.' -f $FRAME_PERIOD, $FRAME_CAP_FPS) }
        [ordered]@{ name='aztAnimPeriod'; linear=('0x{0:X}' -f $tAsm.Labels['aztAnimPeriod']); file=(Lin2File $tAsm.Labels['aztAnimPeriod']); size=4; default=$ANIM_PERIOD_US; desc=('MICROSECONDS per animation frame; {0} = {1:N1} Hz. Bigger = slower.' -f $ANIM_PERIOD_US, (1000000.0 / $ANIM_PERIOD_US)) }
    ) } else { @() }) + @(
        # Not in the cave like the others -- this one is a float immediate in the
        # game's own code, so it is a PATCH SITE that is also tunable. Set-EyeHeight
        # writes it as a float; the rest are integers.
        [ordered]@{ name='aztEyeHeight'; linear=('0x{0:X}' -f $EYE_AT); file=$ofEye; size=4; kind='float'; default=$EYE_HEIGHT; desc='camera eye height in world units; NEGATIVE IS UP, so -85 is taller than -70 (stock)' }
    )
    # How to REGENERATE the replacement art, rather than ship it.
    #
    # HUD3/HUDOFF and the NBUT sprites are rescaled from Mindscape's own artwork,
    # so a redistributable build must not carry them -- the installer rebuilds
    # them from the player's own game files. The fonts are ours, but generating
    # them on the spot keeps the package free of rendered Microsoft font bitmaps
    # too, and costs nothing since the generator is already here.
    art          = [ordered]@{
        hudScale   = $PANEL_SCALE
        screenW    = $SCREEN_W
        screenH    = $SCREEN_H
        # THE FONT HAS TO SCALE WITH THE SCREEN. 10/12 are the 640x480 numbers, so
        # leaving them alone at 800x600 rendered the HUD text at 80% of its former
        # size relative to everything around it -- which is most of why it became
        # hard to read. Build-Font's own notes say the renderer takes line height
        # straight off the sheet (0x39255), so a taller sheet re-spaces text with
        # no code change; only the story log's fixed box can run out of lines.
        fontFace   = 'Verdana'
        fontEm     = 10 * $HS
        fontHeight = Hi 12
        # THE LOG USES THE SAME SHEET AS THE REST OF THE HUD. It was briefly taken
        # down to 8/11 with a hinted two-level render to fit more prose in a 170px
        # box, and the result read as an approximation of the typeface rather than
        # a smaller version of it: at 11 rows Verdana's curves have too few pixels
        # to survive being snapped to a grid, and killing the anti-aliasing to
        # avoid the grey fringe took the last of the shape with it.
        #
        # The per-sheet override below stays wired up -- Build-Font and the
        # installer both honour it -- so a future attempt has one place to change.
        # If it is worth retrying, move $EmSize/$Height down TOGETHER and leave the
        # anti-aliasing on; the fringe is the lesser problem of the two.
        # PUBLISHED, not 0, because the log sheets are generated again at 1600x1200 --
        # the installer re-runs Build-Font from these for the redistributable path, and
        # a 0 here would silently give it the stock 12 rows back. See $LOG_FONT_STOCK.
        logFontEm     = $LOG_FONT_EM
        logFontHeight = $LOG_FONT_ROWS
        # The speckle in the log box was a PALETTE problem, not a level count -- the
        # anti-aliasing mid-tones were landing on scene-palette indices. Build-Font
        # fixes it by restricting the ramp search to 1..56.
        #
        # TWO LEVELS WAS TRIED AND IS WRONG: it pins every partial-coverage pixel to
        # the shadow, and at 12 rows most of a Verdana stem was partial coverage, so
        # the glyphs went black. At 24 rows there is room for the mid-tones, which is
        # why 6 is usable now and was not then.
        logFontLevels = $LOG_FONT_LEVELS
        logFontCrisp  = $false
        logFontStock  = $LOG_FONT_STOCK
        # More ink levels, because a bigger glyph shows the quantisation steps that
        # 4 hid at 640x480. Build-Ramp snaps each level to the nearest palette
        # entry, so asking for more than the palette can distinguish is harmless.
        fontLevels = $(if ($HS -gt 1) { 6 } else { 4 })
        # Geometry for Build-HudOverlay. HUDBOT.RES is run-length data addressed by
        # framebuffer OFFSET, so it is only valid for one exact viewport -- publish
        # the numbers rather than letting the generator default to 640x480 ones.
        viewY      = $VIEW_Y
        viewW      = $VIEW_W
        viewH      = $VIEW_H
        panelTop   = $PANEL_TOP_NEW
        cornerRadius = $CORNER_RADIUS
        # Tells the installer to run src\Build-Books.ps1 over GAME\AZTEX\BOOKS.
        # It is published rather than assumed because it MUST agree with whether
        # `book-centre` is in the patch list -- see $BOOK_FULLSCREEN.
        bookFullscreen = $BOOK_FULLSCREEN
        bookFillPct    = $BOOK_FILL_PCT
        bookSource     = $BOOK_SOURCE_DIR
        # The rebuilt system fold-out. Generated by src\Build-SysMenu.ps1 from the
        # single master render, not shipped as fourteen hand-made files -- see
        # that script for why one master is the only way the animation stays
        # stable.
        sysMenuW   = $SYSMENU_W
        sysMenuH   = $SYSMENU_H
        files      = @(0..13 | ForEach-Object { "SAVE{0:00}.PCX" -f $_ }) +
                     @('HUD3.PCX','HUDOFF.PCX','MAPBKGRD.PCX') +
                     # H1.PCX is the health fill. It only ships once the gauge has
                     # been resized -- a rebuilt H1 is the size of the recess, and
                     # the memcpy length is patched to match, so the two are only
                     # ever correct together.
                     $(if ($gaugeR) { @('H1.PCX') } else { @() }) +
                     $(if ($ENABLE_HUD_OVERLAY) { @('HUDBOT.RES') } else { @() }) +
                     $(if ($ENABLE_HUD_TOP)     { @('HUDTOP.RES') } else { @() }) + @(
                       'NBUT0OFF.PCX','NBUT0ON.PCX','NBUT1OFF.PCX','NBUT1ON.PCX','NBUT2OFF.PCX','NBUT2ON.PCX') +
                     $(if ($LOG_FONT_STOCK) { @() } else { @('RUSGLD2.PCX','GENBLU2.PCX') }) +
                     $(if ($ENABLE_LOG_BOX_TOGGLE) { @('BOXOFF.PCX','BOXON.PCX') } else { @() })
    }
    patches      = $patches
}

$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path $OutFile -Encoding utf8
Write-Host "wrote $OutFile  ($($patches.Count) patches)"


























