---
name: blood-omen-feasibility
description: "Blood Omen (GOG, C:\\Program Files\\GOG Galaxy\\Games\\Blood Omen) is a native Win32 Watcom PE, NOT DOS — static findings from the 2026-10-02 feasibility pass."
metadata:
  node_type: memory
  type: project
  originSessionId: 4e249ee1-a16a-4a18-aa23-8f9f3dc1b22b
  modified: 2026-10-02T04:35:01.037Z
---

Second project after Azrael (started 2026-10-02). Kain.exe = 1997 Semi Logic port, Watcom PE, base 0x400000, has .reloc, DirectDraw (no D3D) + DirectSound + winmm joyGetPos. Software 2D, max mode 640x480 8/16bpp hard-coded at 0x4283BB.

- Already patched by GOG: detours into nop caves at 0x413454..0x4135A1 (e.g. 0x463EF5, 0x444D4F). Don't clobber them. GOG ddraw.dll 1.1.0.1786 = "DirectX 1-7 wrapper"; dinput.dll + dixi.ini = their pad remapper.
- PE can take a NEW section, so no cave-space crisis like [[azrael-cave-space]].
- Timing: 0x444D44 = elapsed-ms timer (~70 callers); frame waits are `cmp eax,0x10` busy loops on GetTickCount (15.6 ms granularity -> judder). 0x45E378 = emulated PSX VSync(). No timeBeginPeriod anywhere.
- Input: WM_KEYDOWN into 256-dword table 0x8F8FB0; GetAsyncKeyState only clears stuck keys (0x4451CE). Joystick = joyGetPos (4 buttons). bconfig.cfg = VK codes.
- Data: Kain\PILL.BIG = u32 count + {hash,size,offset}x2572, names hashed. Contains standard PSX TIMs (lo/hi pairs: 320x240/640x480 etc. = UI/screens only), VAGp, RIFF WAV. Movies = .JAM ("JAM\0", 320x240, 8bpp) + headerless PSX ADPCM .VAG.
- PILL.BIG name hash SOLVED (0x412720): "GAME/"+name, uppercase, \ and / -> ':', XOR of LE 4-byte chunks.
- .SHA sprites SOLVED: u32 count, u32 dataSize, header (palette = 256xRGB at table-772), table at len-dataSize-8*count of {u32 off,u8 w,h,x,y}; 4bpp low-nibble-first, `00 nn` = skip nn BYTES. Tools + export in Blood Omen\BoMod (Export-Sprites.ps1, ShaTool.cs).
- Kain's body = 20 unnamed sets (archive idx 330-345, 545-549, 2172-2176), frame count = weapon (340 sword, 370 mace, 393/394 axes, 435 long blade), 4 armour palettes each. Forms: KAINWOLF/MIST/DISGUISE.SHA. CHARnnnn.SHA = enemies/NPCs.
- Unverified: whether in-game world tiles/sprites are pixel-doubled 320x240 in hi-res mode.

Not launched — same rule as [[azrael-never-autolaunch]]. No official Blood Omen remaster as of 2026-10 (SR1&2 and Defiance only).
