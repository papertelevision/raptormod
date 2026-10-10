# AztMod -- the original README (v0.1.0), partly recovered

> Recovered 2026-10-10 when the repo was set up: the first ~80 lines, as read earlier that day, before README.md was
> rewritten. The rest of the file (more technical notes) was not recovered; the same facts live in
> `docs\notes\azrael-le-image-layout.md`, `azrael-key-addresses.md` and `aztmod-patch-framework.md`.

Binary patches for the Steam release of Azrael's Tear (Intelligent Games / Mindscape).
Version 0.1.0 ships one feature: **always-on mouselook**.

## Install

```powershell
.\Apply-AztMod.ps1 -Install -Dest "D:\Games\AzraelsTear-Modded"
```

This copies the entire game (~530 MB) to `-Dest` and patches the copy. **Your Steam install is never modified.**
`-Status` and `-Revert` take the same `-Dest`; `-Revert` restores the byte-identical original from the `.aztbak` backup
taken before the first patch. `-InPlace` patches `GAME\AZRAEL\R.EXE` where it sits -- not recommended: Steam's
*Verify integrity of game files* will silently replace it.

## How it works

The game *already has* proper relative mouselook: an INT 33h event callback feeds mickey deltas through a `/8` divider
into the camera. It was simply gated behind holding the right mouse button. AztMod turns that hold into a toggle and
keeps it engaged. It does **not** add new camera code.

### Image layout (important)

`R.EXE` is Watcom C++ built to a DOS/4GW **LE** executable, uncompressed, LE header at file `0x290FC`.

> **The LE header's "data pages offset" field (LE+0x80) is wrong.** It claims `0x3B400` (-> `0x644FC`). The real offset
> of module page 1 is **`0x61A54`**, derived from the tail: `fileLength - ((numPages-1) x pageSize + lastPageSize)`.
> Verified against the fixup table -- with the header value, 0 of page 1's 217 fixups line up; with `0x61A54`, all 217 do.

| Object | Base | vsize | Module pages |
|---|---|---|---|
| obj1 (code + rodata) | `0x10000` | `0x122973` | 1-291 |
| obj2 (data + BSS + **stack**) | `0x140000` | `0x57DD0` | 292-310 |

obj1's pages are contiguous and identity-mapped, so for any obj1 address:

```
file = 0x61A54 + (linear - 0x10000)
```