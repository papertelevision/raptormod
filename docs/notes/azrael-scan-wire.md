---
name: azrael-scan-wire
description: "Scanner wireframe replaced by the host (ScanWire.cs): RAPTOR's own rig WALKING its .ANI cycle from XAF keyframes; the host holds every scan to the stock 4.2 s (uncapped guest ended it in 0.3-1 s = the \"breaks and tears\"). v2 built 2026-10-07, not yet seen in game."
metadata:
  node_type: memory
  type: project
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-07T20:09:22.848Z
---

Josh (2026-10-07): replace the bitmap "wireframe" shown when scanning a creature with a revolving vector wireframe like the boot's chalice, walking like the original, a bit bigger. RAPTOR first (cave two rooms from the start); LURKA (mine shaft) etc. later.

**v1 failure, and why:** "slight rotation, then it breaks and tears". The log showed the guest at 100-300 fps (frame cap lifted under host render). The scan is FRAME-counted: 0x14FE8 blits surface (counter mod 10), `inc word [0x1529CE]`, and past 100 clears the flag `[0x1529CC]`. So a scan lasted 0.3-1 s instead of ~4.2 s at the stock 24 cap. Any frame-counted HUD effect has this problem under host render.

**Game side (obj2 addr; host = MemBase + addr + delta2, delta2 via $S_delta2, usually 0x1F1000):**
- The loader 0x17690 fills ten 140x120 surfaces at 0x152918 + i*0x12 (w, h, ptr), then on success sets counter = 0 and flag = 1 (0x17790/0x17797).
- Other code CLEARS the flag to cancel a scan: 0x111E8, 0x129C9, 0x15CBE, 0x1632C, 0x1661D, 0x2FBBE. While the flag is set, 0x14390/0x143C7 skip drawing their HUD bits in that area.
- The box is game px 20,40..160,160.

**Host side, tools\ScanWire.cs:**
- **Rig:** parses the game's own <NAME>.XAF (tokenizer + block tree): nested objects, `W = local * W_parent`, `v' = v * W`.
  - Keys: rotate (t,w,x,y,z), scale and position (t,x,y,z). Quaternion matrix "as written" (root matches its rest to 4e-8; transposed is off by 2).
  - The keys are the true local transforms. The file's rest matrices for the root's children instead cancel the root's rotation and scale (1.06383 = 1/0.94), so frame 0 != rest for the limbs. Don't "fix" that; posed by the keys the figure is whole.
  - BLOOD* parts are skipped.
  - Walk = the .ANI naming `FILE name.xaf`, its WALK (else RUN, else REST) range: KURT.ANI gives 124-136. Played at 18.2065 frames/s (the engine's aztAnimDue rate), slerp between keys.
  - Every edge is drawn, depth-dimmed. The game's frames are a dense full wireframe, and silhouette-only edges popped.
- **Thread** (1 ms, timeBeginPeriod):
  - Follows the flag. Identifies a scan by a PCX mask match of WIRE\NAME00.PCX (RAPTOR 1.000, LURKA 0.374, MatchAt 0.6).
  - HoldScan: writes counter = elapsed * ScanHz(24) every pass for EVERY scan, ours or not, and never writes the flag, so cancels work.
  - Restart: counter < last written, or the frame fingerprint changed and was stable on two looks.
- **Drawing:**
  - Overlay.Decorate2 = ScanWire.Hook; hide = HideRect2 (Overlay + GpuRaster uHide2) while HideNow (125 ms grace).
  - Box 1.4x the game's, anchored top-left (BoxScale); Fill 0.88, Spin 1.6, fades over 0.15/0.3 s.
  - ~4.5 ms per frame, only while a scan shows.
- **Watcher:** -NoScanWire, -ScanWireSets 'RAPTOR' (comma string). Logs the rig line at start and "scan: ... held to 24 frames/s, N host writes" per scan.

**Verified offline:**
- scratchpad rig-live.ps1: a C# FakeGame thread runs the 0x14FE8 logic at 300 fps. Raptor and Lurka scans both last 4.17 s with no skipped bitmap frames; rescan restarts and re-identifies; a game cancel stays cancelled.
- Test-GpuCompose with HideRect2: 0 px CPU/GPU diff.

Related: [[azrael-gpu-boot]], [[azrael-characters-host-render]], [[azrael-frame-tied-timing]], [[azrael-animation-format]].

## v3 (2026-10-07, after Josh saw v2 and liked it)

- Walk and turn are 10% faster (AnimHz 20.03, Spin 1.76) and the box is 15% larger (BoxScale 1.61).
- Moved left: the box's left edge comes from the VISOR BAND column map (cxiR, AnchorToBand), which puts it near the screen's left edge where the game placed it beside the visor corner. Its size still comes from the view map (cxi).
- SCAN EFFECT over the view rows (ov.ViewRowsOf). All of it is on the scan's own clock and only for replaced sets:
  - **Pulse:** amber wash plus additive lift, with interlaced ~2-px row bands dimmed; rise 0.08 s, fall 0.75 s.
  - **Sweeps:** amber H and V lines ping-ponging (1.9 s / 2.7 s) with phosphor gradient trails and an X/Y coordinate tick (view px) where they cross.
  - **Readout:** Terminator-style typed lines beside the box. Numbers are REAL rig data (bones, vertices, gait frames, match score); digits scramble until they lock. A hex stream sits alongside; SCAN COMPLETE blinks at the end.
- Inks are the boot's palette indices (34, 49, 88, 55), set by the watcher from the live palette.
- Warm() at Use() removes a 33-45 ms first-frame hitch. ~6-10 ms per frame at 2436x1314 while a scan shows.
- The pulse first read as dull olive (it only darkened the scene); the additive amber lift is what made it a pulse.

## v4 (2026-10-07)

- **Sweeps:** ONE pass only, top-left to bottom-right (SweepAt 0.05, SweepTime 1.5). Josh: 'that's all that's needed'; the ping-pong sweeps are gone.
- **Sound:** the boot's BootSound, a separate instance under -NoBootSound / -BootSoundVolume.
  - Degauss at 0.8 share when one of OUR sets starts; Typing(600+i, len/ReadCps) as each readout line starts; Line(700) with SCAN COMPLETE.
  - Played from the scan THREAD on the scan clock. Readout timing (ReadStart/ReadGap/ReadCps) is shared with the drawing, and late cues (>0.15 s) are skipped.
  - Prepare() at Use() keeps the device open so the thunk isn't ~0.5 s late.
  - **BootSound.Dispose is permanent**, so it lives in ScanWire.Close(), NOT Detach (Attach calls Detach first).
  - SoundEvents queue records what played when. Measured: degauss 0.000, lines every 0.30 s from 0.302, complete 3.306.

## v5 (2026-10-07): results by NAME

- **WHO is scanned:** read the way 0x2BE30 does. [0x1521B4] points at 'ZZ'+digits; atoi(+2) is the id. The actor table at 0x1521C4+2 has 0x6F buckets of {next, name ptr, id ptr}, and the name is the .ANI definition (KURTB).
- **Why by name:** KURT and KURTB share raptor.xaf AND identical wire frames (mask 1.00), but their texts differ. KURT.DES = Kurt Thyssen; KURTB.DES = 'Lincoln - Violent record' (the cave raptor).
- **Text source:** DESCRIPT.ZAP entries 'NAME.DES ... $END$'. HUDMES.DAT holds separate proximity HUD warnings (the 'APPROACH WITH CAUTION' line).
- **Watcher:** registers every .ANI whose FILE is a loaded rig (AddCharacter).
- **Result display:** after SCAN COMPLETE, the ' - ' parts are uppercased, one per line, wrapped at 26 characters, in large type (2.6% of view height) on the right with an ANALYSIS RESULT heading. There's a softer second amber pulse (0.45) and a chatter per line.
- **Length:** the scan is held long enough to read it (ScanLength, about 9.4 s for Lincoln), via counter = elapsed/len*100.
- **ITEMS NOT DONE:** item text is an OBJHUD.DAT record (0x19F bytes at 0x1E + obj[+0xE]*0x19F, text at +0xF, printed with fmt 0x143055), but which object was scanned is only in a register in 0x2BE30. Candidate: the object's word +0x10 is set to 1 when scanned (0x2BEC9).

## v6 (2026-10-07): Lurka and the small dinosaurs

- -ScanWireSets default 'RAPTOR,LURKA,EUGBLD':
  - LURKA walks 263-305.
  - EUGBLD (EUGENE/EUGENB) has no WALK, so it uses RUN 2-7.
- A rig with no WIRE\<rig>00.PCX borrows the frames of a character using it (EUGBLD -> EUGENE).
- **Size:** fit by height AND reach round the upright (unit = max(H, 2R*bh/bw)), so the long-tailed dinosaur fits side-on.
- **AutoPhase:** each creature's ten game frames start at their own angle AND turn their own way.
  - At load, the wireframe is drawn at 36 angles x both directions and scored over ALL TEN frames as a sequence (frame i at +i/10 of the turn and of the walk), by silhouette IoU.
  - One frame alone mixes up front and back (it put the raptor at 210 deg). Eugene matched frame for frame.
  - ~2-2.7 s per rig, so it runs on a BACKGROUND thread (the attach must not wait). PhaseNotes are logged as they land; it draws at 0 deg until then.
- Result lines are FLUSH LEFT (Josh 2026-10-07): wrapped continuations used to get a 2-space hanging indent, now removed.

## v7 (2026-10-08): EVERY character -- batch 1 of 2 (Josh: all scanned creatures/items, GPU mode only)

- -ScanWireSets default 'ALL'. A set per character DEFINITION (GAME\AZRAEL\*.ANI with frames in WIRE), named by the definition (KURTB), not by the rig. Sets sharing a rig are separate sets on one rig (KURT/KURTB, SCORP/B/C, THEO/B/C, TALLUB/M, LEO/LEOB, EUGENE/B). 24 sets.
- Frame files don't always carry the definition's name: GEFFRYE = GEFFRYE0 + GEOFF01..09; VINCENT = VINCE00..09 (alias table in Start-ScanWire). The game's own path format is `%swire\%s%02d.pcx`.
- Range: WALK, else RUN, else REST. A one-frame range is a held pose (LEOB 501, THEOB WALK 502); span 0 is handled in the drawing.
- Left to the game: ZOMBIE (frames and text, but no .ANI or rig anywhere: cut) and SAILOR (SAILOR_A.XAF is an 8-vertex box; AddCore rejects rigs under 24 vertices).
- 'dummy' meshes are skipped like BLOOD (their bones stay): TOBIAS's 416-unit `tdummy` shrank him to dots.
- START-ANGLE CACHE: C:\Games\azrael-render\scanwire-phases.txt (key: name|xaf:size:mtime|range|frames|v2). The alignment is ~2 s a set (49 s for all 24) and cached it's 0.5 s. Bump the |vN when the rig loader changes.
- Verified: contact sheet (scratchpad scan-all.ps1) of the game's frame 0 next to ours for all 24.

## v8 (2026-10-08): ITEMS -- batch 2 done (not yet seen in game)

- **Which set:** WIRESCAN.RES lists 35 unique sets (one line per scannable object; BISC serves 24 objects). 0x2BC3C maps object index -> line via the word table at obj2 0x147494. Item sets register by FRAMES only (AddItem) and are identified like characters. CLAUDE is a character first.
- **Which object, at scan time:** [0x1521B4] is the picked RL frame's name for objects too (the room part, e.g. 'flask03'; 'ZZnnnn' for characters). word [0x146872] is the HOVERED object index (-1 = none); [0x1841D0] is the object table; obj+0x3F is its shown name. obj[+0x10] = 1 marks 'scanned'. [0x152914] = 0 means an object scan.
- **Text:** OBJECTS.DAT = u16 count (1020), then 603-byte records: display name +0, object name +0x3C, room part +0x78, scan text +0xCB. Matched by part or object name; a shared part name (flask01 = Essence in HULL01, Aqua Fortis in LAB) is settled by the shown name. OBJHUD.DAT's 0x19F records (from 0x1E) do NOT index by these numbers (the tails are leftover memory from the developers' machine).
- **DRAWN FROM THE GAME'S OWN FRAMES, NOT MESHES** (decided with evidence): the rooms' models of the items are stand-ins. The inkwell, key, gun, ammo bag and Claude's shield are flat textured cards; the flasks are bare pyramids without their labels. The scan frames were rendered from detailed models that never shipped. DrawFrames: teal ink + a 2-px halo per frame (MakeInks, built on first draw), scaled to the box, each frame held then cross-faded over its last 30% (FrameBlend), a turn every 2*pi/Spin s. The readout gets item lines (MATERIAL ANALYSIS, PROFILE VIEWS, EDGE TRACE...).
- Watcher: -NoScanItems. Log line per item scan: 'item: SET: picked X, shown Y -> record'.
- Verified: scratchpad item-live.ps1 (fake guest with the pick, hovered index and object table planted) for Red Salt, Aqua Fortis on a shared part, a BISC shield, and an unknown part (drawn, no text); the result renders through the overlay. items-draw.ps1 is the drawing sheet.
- NOT replaced: Sailor and Zombie (no usable rig). Unused frame sets nothing scans: ESS, BOOK, PAPER, PLACK, EDNECK, RTONGS, WAX_B.

## Slower, and the sniff (Josh, 2026-10-13)
"the scanning animation (the spinning wireframe ...) spins and animates very quickly. Can we slow that down a bit? Also can the scan for these two creatures include their new sniffing animation as well?" **Built 2026-10-13; checked offline; NOT yet seen in game.**
- **~30% slower:** `Spin` 1.76 -> 1.25 rad/s (a turn in ~5 s) and `AnimHz` 20.03 -> 14 frames/s, the walk a little under the engine's 18.2. Items turn slower too (same Spin).
- **A second clip:** `ScanWire.SetExtra(name, from, to)`. The watcher gives a set any `SNIFF` range its installed .ANI has; today that is EUGENE and EUGENB, whose `SNIFF 11-52` Apply-AztMod adds ([[azrael-npc-pace]]). The set walks for whole cycles for about `ExtraAfter` 2 s, plays the clip once (41 frames, ~2.9 s), and walks again. Logged "scanner wireframe: EUGENE also sniffs (frames 11-52) after its walk".
- Checked with `RenderTest`: run at 0.3 / 1.2 s, head down sniffing at 2.5 / 3.3 s, head up jaw open at 4.3 s, running again at 5.3 s.
