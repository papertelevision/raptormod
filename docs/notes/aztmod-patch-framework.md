---
name: aztmod-patch-framework
description: AztMod is a distributable patcher (not a patched EXE) living in the Steam folder; build with src\Build-AztMod.ps1.
metadata: 
  node_type: memory
  type: project
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-19T15:07:41.202Z
---

The Azrael's Tear mod is called **AztMod** and lives in
`C:\Program Files (x86)\Steam\steamapps\common\Azrael's Tear\AztMod\`.

Design constraints the user set (2026-09-18):
- It must ship as **one patch other gamers can apply to their own install** â€” so it is a
  *patcher* (`Apply-AztMod.ps1` + `AztMod.manifest.json`), never a redistributed EXE.
- All features go in **one** growing patch, not separate mods.
- The user wants **in-game toggles/console** to turn features on and off while testing.
- Steam auto-updates are off; the patcher defaults to **copying the game elsewhere** and
  patching the copy, because Steam's "Verify integrity" would revert an in-place patch.

Layout:
- `Apply-AztMod.ps1` â€” what end users run (`-Install -Dest`, `-Status`, `-Revert`, `-InPlace`)
- `AztMod.manifest.json` â€” generated; SHA-256 gated, expect/replace byte pairs
- `src\Asm.ps1` â€” mini x86-32 assembler with label resolution
- `src\Build-AztMod.ps1` â€” regenerates the manifest from the stub source
- `README.md` â€” full technical notes (image layout, cave, hooks, hazards, roadmap)

All new features go in the shared code cave at linear `0x132980` (see
[[azrael-le-image-layout]] and [[azrael-key-addresses]]); v0.1.0 uses 412 of 1677 bytes.

**Two hazards to re-check for every new hook** (both documented in the README):
1. Hook sites can contain **LE fixups** that the loader rewrites at load time, destroying
   patched bytes. The 25-byte site at `0x13DC8` has them at `+3` and `+13`; the patch
   jumps around them. Always test a candidate site against the fixup table first.
2. **Absolute data addresses in injected code do not work.** Play-testing in the 0.1.x
   builds showed hooks reached via `rel32` ran fine while every path that read a global
   silently did nothing. Since v0.2.0 the stub is position-independent: `AztDeltas`
   derives `esi` = obj1 delta (`call $+5` / `pop eax`) and `edi` = obj2 delta (by reading
   the loader-resolved `&g_mouselookOn` out of the preserved operand at `0x13DCB`), then
   every data reference is `[esi|edi + <build-time address>]`. Correct whether the delta
   is zero or not. **Write all new stub code this way.**

Mouselook design (v0.4.0, settled): **invert the stock gesture.** Look is the default; HOLDING
the right button restores the game's own pointer. `AztFrameHook` is the single authority and
drives everything off `g_rmbHeld` â€” the RMB down/up hooks do nothing when the mod is on. On
entering look mode it calls `SetMousePos(320,188)` to park the pointer centrally, then the stock
`EnterMouselook` (which hides it). Cursor mode is therefore **100% stock**.

Two earlier designs failed, don't retry them:
- v0.2.0 auto-exited look mode on guessed game flags (book/map/save/combat). One fired during
  normal play and the pointer silently un-pinned. **Don't gate on flags you haven't confirmed.**
- v0.3.0 kept the pointer live and pinned it every redraw (hook at `0x3592D`). Pinning worked,
  but it **froze the contextual TAKE/USE/PUSH icons**, because the game re-picks as the pointer
  moves. A pinned-but-live pointer and working context icons are mutually exclusive.

**Left mouse no longer walks forward** (v0.4.0): stock condition is
`forward = forwardKey OR (mouselook AND lmbHeld AND NOT combat)`. `cmp word [g_lmbHeld],0` at
`0x1D705` carries a fixup, so patch the next branch instead â€” `jz 0x1DAA1` at `0x1D70D`
(fixup-free) becomes `jmp 0x1DAA1`. `g_lmbHeld` (`0x182DA6`) has exactly one consumer, so
nothing else changes. Unconditional, so F2 does not restore it.

**Firing is left mouse while in combat mode** (`g_combat` = `0x14721C`; Space toggles it) â€”
gated at `0x15AF4`, then plays `shot.wav` and decrements ammo at `0x14694C`. There is no
separate fire key; `e` is not bound to anything.

**v0.5.0 mode design** â€” look mode = combat ON + mouselook ON + pointer pinned; cursor mode
(hold RMB) = combat OFF + fully stock pointer. The key realisation: **in combat the pointer IS
the crosshair**, a fixed bitmap with no contextual icons, so pinning it there is safe. Pinning
is gated on `g_combat` precisely so it can never re-break the context icons.

Two stock guards that shape all of this:
- `0x131EF` â€” **the Space/combat toggle is refused while mouselook is active.** So combat must
  be toggled on the transition frame, before engaging the look.
- The combat toggle is written inline in the key handler and its OFF path uses that function's
  own stack locals, so it **cannot be called directly**. `AztSendSpace` synthesises an event
  instead: the handler only ever reads bytes `+5`, `+6`, `+7`, so a zeroed 16-byte buffer with
  ascii `0x20` drives the real code path.

**Strafing (v0.6.0)** â€” the game has no lateral axis, but movement is
`newPos = pos + dir * 16` where `dir` (`0x147200` X, `0x147204` Y, `0x147208` Z) is a unit
vector rebuilt from yaw/pitch by `fsin`/`fcos` every frame at `0x1D400`, and **nothing reads it
between the camera call at `0x1D4A4` and the movement maths at `0x1D747`**. So rotating it 90Â°
in that window makes the stock movement code â€” collision and stepping included â€” carry the
player sideways. A 90Â° rotation needs no FPU: swap the X and Z floats and flip bit 31 of one.
Hook is `jnz 0x1DAA1` at `0x1D6E7` (fixup-free), with `pushfd`/`popfd` to reproduce the branch
(`add esp,4` + `jmp` to emulate it being taken). A/D set a strafe-direction variable and remap
to the Up arrow so the stock forward gate opens; releasing one movement key is swallowed while
another is still held. Note `jnz 0x1D721` at `0x1D6F5` jumps **past the combat check**, which is
why W works while combat mode is on.

**Combat is restored self-correctingly (v0.6.1)** â€” anything can clear it (the Q menu sets
`0x152176`, death, scripts). The frame hook checks `g_combat` every frame; if it is off while
mouselook is on it calls `ExitMouselook` for one frame so the next frame's transition can send
Space. It first bails entirely if any of `0x1523D6`, `0x15257C`, `0x181F88`, `0x14721A` is set â€”
**that list is copied from the Space handler's own guards at `0x131E1`, not guessed**, so a menu
is left alone instead of being fought every frame.

**Wall auto-turn removed (v0.6.2)** â€” when movement is blocked the integrator nudged the CAMERA
yaw by Â±10 and abandoned the move, so leaning on a wall slowly spun you. Six sites:
`0x1D879`, `0x1D8EE`, `0x1DA0D`, `0x1DA94` (`sub`) and `0x1DBCB`, `0x1DC31` (`add`), all
`66 83 2D/05 <disp32> 0A` followed immediately by an unconditional `jmp 0x1DE08`, so their flags
are never read. The disp32 at `+3` carries a fixup, so the instruction can't be NOPed â€” but the
immediate at `+7` is clear of it, making this a **one-byte-per-site** change (`0x0A` â†’ `0x00`).
Result is a hard stop at walls. True wall-sliding would need axis-separated retry inside the
movement block and is still open.

**Combat crosshair lines removed (v0.6.1)** â€” six `call 0x3847C` sites inside the combat HUD
block (`0x145C8`, `0x145E8`, `0x14682`, `0x1469F`, `0x146C2`, `0x146E0`) draw lines 551 wide and
281 tall centred on the pointer. `0x3847C` is a shared line/rect primitive with 46 callers so it
cannot be patched itself, and it returns **`ret 8`** â€” the call cannot simply be NOPed or the two
pushed args leak. Replace each with `add esp, 8` + 2 NOPs. The 30x30 circle at `0x15210C` is the
mouse cursor and is unaffected.

**DOSBox writes `stdout.txt` / `stderr.txt` next to the launcher** â€” read them after any crash.
That is how the v0.7.0 failure was identified as `Exit to error: Corrupt MCB chain`.

**Enlarging the 3D viewport â€” the constant FAMILY.** The dimensions are not two numbers, they
are a derived family, and missing ANY member corrupts memory:

| value | meaning | where |
|---|---|---|
| `0x228`/`0x11A` | W / H | surface + device creation |
| `0x227`/`0x119` | W-1 / H-1 | clip limits, line extents |
| `0x114`/`0x8D` | W/2 / H/2 | viewport centre (func `0x165F4`) |
| `0x26010` | **W*H framebuffer bytes** | `0x10E2C` alloc + three `rep movs` counts |
| `0x4C020` | **W*H*2 Z-BUFFER bytes** | `mov eax,0x4C020` at **`0x28168`**, inside the RL device creator `0x28157` |
| `imul/add/sub 0x228` | scanline STRIDE | ~12 sites â€” avoid by not changing width |

v0.7.0 missed the framebuffer bytes â†’ `Corrupt MCB chain`. v0.7.2 missed the z-buffer â†’
`Illegal write to ffffffff` inside the RL rasterizer (`0x1053F8`). **v0.7.3 works**: height only,
282 â†’ 318, origin Y 49 â†’ 0, width left at 552 so the stride family is never touched.
Enabled by `$ENABLE_BIG_VIEW`. Widening later means also doing W-1, W/2 and every stride site.

`Patch-Imm32` in the builder locates the immediate by searching bytes 1..5 of the instruction
(not a fixed `+1`), because these appear as mov/push/imul/add/cmp with different opcode lengths.
The window must stay at 5 â€” at `0x15586` a `mov ebx,0x119` is followed by `push 0x119`.

**Superseded: v0.7.0 first attempt.** Geometry is understood: a 552x282
surface (`0x152150`) blitted as a plain rectangle to `(44, 49)`; the HUD art is a static 640x480
background *underneath*, not a mask, so a bigger rectangle really does show more. Panel art
starts at y=318 (measured from HUDOFF.PCX, whose viewport hole is keyed and bounds
x 44..595, y 50..330). Constants, all fixup-free: width `0x228` at 13 sites, height `0x11A` at 14,
origin as `mov ebx,0x31`/`mov edx,0x2C` pairs at 18 blit sites (matched on the full
`... / mov eax,0x152150 / call 0x33F80` pattern), plus `sub edx,0x2C`/`sub eax,0x31` at
`0x11771`/`0x11774` for picking. Patching all of them to 640x318 at (0,0) **corrupts the DOS
heap on startup**. `0x152150` itself IS resized (`0x10E18`/`0x10E1D` â†’ InitSurface at `0x10E27`),
so something else is still sized from the old constants â€” a surface or the texture cache â€” or an
allocation fails unchecked. **Bisect by group next time**, and gate it behind
`$ENABLE_BIG_VIEW` in the builder (already wired, default `$false`).

**Hook patches must cover whole instructions.** The generator assumed every hook replaced a
5-byte `call`; `hook-strafe` replaces a 6-byte `jnz rel32` and the orphaned byte became a live
`add byte [esi-0x7D], ah`. Symptom was forward + both strafes dead while backward worked (the
only path that branched away before reaching the stray byte). Each hook now declares `len`, and
`tools\Test-Patch.ps1` decodes the original instructions and fails the build on a mismatch.

**Asm.ps1 gotcha, fixed 2026-09-19:** PowerShell hashtables are case-insensitive, so a data
label `aztStrafe` was silently overwritten by a routine `AztStrafe` and the stub read its own
code as a variable. `Labels` is now an Ordinal dictionary and `Add-Label` rejects
case-insensitive duplicates. Caught by `tools\Test-Patch.ps1` before it ever ran.

**Invert mouse Y** is a pure data patch: `g_invertY` (`0x1471DA`, read at `0x1D130`, F10 toggles)
lives in initialised data at file `0x18BC2E` â€” flip `0000` to `0100` and F10 still works.

**WASD** is done by rewriting the event struct rather than adding movement code: in both the
key-down (`0x15E7E`) and key-up (`0x15E8B`) hooks, if the scancode is W/A/S/D (`0x11/0x1E/0x1F/0x20`)
set ascii (`+6`) to 0 and the scancode (`+7`) to the matching arrow (`0x48/0x4B/0x4D/0x50`), then
fall through to the stock handler. Both handlers key off `word [ev+7]`, so press and release both
work. Skip the remap when the save box (`0x1525A0`) is taking typed text. A/D turn â€” the game has
no strafe axis at all.

Verification workflow that caught both: apply the manifest to a scratch copy, reload it
through the custom LE loader (which applies fixups like DOS/4GW does), and disassemble
the hook sites and cave. See [[azrael-re-tooling]].

Not yet play-tested as of 2026-09-18.

## Modal UI must force pointer mode, or it is unusable

AztMod makes mouselook the default, so any modal the game opens while you are in
combat/look mode is drawn but DEAD to the mouse -- you have to hold the right
button to touch it. The stub's guard list (copied from the game's own Space/combat
refusal test) was originally used only to say "a menu is up, leave the game
alone", which is exactly what left those modals unusable.

The fix is to OR the guard into the WANT-CURSOR test instead, so it takes the
same branch the right button does -- `AFH_cursor` already exits mouselook AND
drops combat, and both calls test their flag first so forcing it every frame is
free. When the modal closes the guard clears and the self-correcting block
restores combat.

| flag | what it means | how it was identified |
|---|---|---|
| `$g_guardA` `0x1523D6` | system fold-out (Q menu) | selects hot-spot screens 0/1/2 at `0x132EE` |
| `$g_guardB` `0x181F88` | NPC interaction / dialogue | **exactly two writers** -- `0x2FBC7` sets 1, `0x2FE1C` clears -- bracketing the only site that switches on hot-spot screen 4, the 75-point dialogue table (`0x2FDB7`) |
| `$g_book` `0x15257C` | book / document page | gates the page draw at `0x10AB2`, `0x16574` |
| `$g_guardC` `0x14721A` | (7 writers, not clearly a modal) | left in the bail-out list |

**A flag with exactly two writers, one setting and one clearing, is the signature
of a clean modal state** -- prefer those over ones written from many places.

`$g_book` is still only in the bail-out list: documents did not need it, because
nothing in them has to be clicked. Add it if a page-turn control ever appears
dead.

**Cave budget: the stub is 1659 bytes with 5 SPARE.** Each extra `A-OrAxDi` costs
7. Anything more needs the clock blob at `0x50F2D` (169 free) instead.

**F2 REMOVED (Josh, 2026-10-15: it "seems to disable mouse look. Can we remove that setting?").** F2 was the live master switch (`aztEnabled`): pressed by accident, it turned off mouse look and the rest of the mod. `AztKeyHook` still takes F2 but does nothing with it; it is not passed on to the game's scancode dispatch, which never saw F2 while the mod was on. `aztEnabled` stays 1, and the setting is still in the manifest for tools. The in-game key list no longer names F2. The stub cave shrank by 21 bytes, so the later labels moved; all 454 patch sites verified on install.
