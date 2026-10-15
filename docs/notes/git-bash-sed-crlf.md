---
name: git-bash-sed-crlf
description: "Git Bash `sed -i` strips CRLF from the repo's CRLF files (Build-AztMod.ps1 etc.) -> whole-file diff; also Git Bash grep -c $'\\r' reports 0 on CRLF files."
metadata:
  node_type: memory
  type: feedback
  originSessionId: 4bb44327-05db-4a50-ba64-31912f4aa648
  modified: 2026-10-13T18:38:33.937Z
---

2026-10-13: a one-line `sed -i` on src\Build-AztMod.ps1 turned the whole file LF (28k-line diff). The repo is `* -text` and the scripts are CRLF (`git ls-files --eol` shows i/crlf).

**Why:** Git Bash's sed works in text mode; and its grep hides CR, so `grep -c $'\r'` falsely says 0.
**How to apply:** edit repo files with Edit or PowerShell [IO.File] ([[azrael-powershell-utf8-trap]]), never sed -i. Check with `git ls-files --eol <file>` (w/crlf) or `git diff --stat` after any shell edit.
