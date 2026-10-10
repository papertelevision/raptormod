---
name: azrael-powershell-utf8-trap
description: "Get-Content -Raw plus Set-Content silently mangles UTF-8 files in PowerShell 5.1 - use [IO.File]::ReadAllText/WriteAllText instead."
metadata:
  node_type: memory
  type: feedback
  originSessionId: 605a7dd5-4527-433c-918c-9df228826b25
  modified: 2026-09-27T00:44:08.912Z
---

**Never round-trip a UTF-8 file through `Get-Content -Raw` + `Set-Content` in PowerShell
5.1.** `Get-Content` decodes a BOM-less UTF-8 file as the system ANSI codepage, so every
multi-byte character is silently corrupted, and `Set-Content -Encoding utf8` then writes
the corruption back as valid UTF-8.

**Why:** this damaged 302 characters in `docs\AZRAEL_REMASTER_FEASIBILITY.md` in a single
string-replace — em dashes, `§`, `→`, `×`, `≤`, `✔` — while the replace itself silently
matched nothing. The damage is invisible in a terminal that renders the wrong codepage,
which is how it nearly went unnoticed.

**How to apply:** for any file that may hold non-ASCII, use .NET directly:

```powershell
$s = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)
# ... edits ...
[IO.File]::WriteAllText($f, $s, (New-Object Text.UTF8Encoding($false)))   # $false = no BOM
```

Better still, prefer the Edit tool for text files — it is encoding-aware.

**Repairing it if it happens:** the corruption is a cp1252→UTF-8 round trip, so it is
exactly reversible per sequence. Enumerate `[ÂÃâ][^\x00-\x7F]{1,2}`, and
for each match decode `Encoding(1252).GetBytes(seq)` as UTF-8 to get the original
character. Replace longest sequences first. **Do not** round-trip the WHOLE file that
way: correctly-encoded characters are usually representable in cp1252 too and would be
destroyed by the same treatment.

Related: [[azrael-re-tooling]]
