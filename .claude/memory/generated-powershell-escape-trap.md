---
name: generated-powershell-escape-trap
description: Never build Windows paths or PowerShell text through Python from the Bash tool — doubled backslashes arrive single and \b, \t, \v become control characters silently
metadata:
  type: feedback
---

Learned 2026-09-18 during run 16, after making the same mistake four times in one session.

Editing files by piping a Python heredoc through the Bash tool **loses one level of backslash
escaping** before Python parses the source. A `\\b` written in the heredoc reaches Python as `\b`
and becomes a **backspace character**; `\\t` becomes a tab, `\\v` a vertical tab, `\\r` a carriage
return. Python only warns for sequences it does not recognise (`\p`, `\S`, `\o`), so the dangerous
cases — the ones that are valid escapes — pass in **complete silence**.

What it produced, all committed-looking and all wrong:

- `...\oh-my-posh\bin` rendered as `...\oh-my-poshin`
- `Programs\oh-my-posh\themes` rendered as `Programs\oh-my-posh<TAB>hemes`, inside the very
  sentence warning about losing a backslash
- `c:\run-v252-test.ps1` and `logs\vm-clear-creds.ps1` rendered as `c:<CR>un-...` and `logs<VT>m-...`

**Why it matters:** the corruption is invisible in a `grep` or a normal diff view, it survives into
a commit, and in a generated `.ps1` it produces a script that parses cleanly and does the wrong
thing. This is the same family as the repo's own rule about parse-checking generated remote scripts
before sending them — see `CLAUDE.md`, "Verifying on a real machine".

**How to apply:**
1. For prose or code containing `\`, use the **Write tool** for the text, then splice it in by line
   index with Python that contains no backslashes of its own. Or use **Edit** directly.
2. If Python must hold the string, use a raw string (`r'...'`) or `chr(92)`.
3. Audit after any such edit: `sum(b.count(bytes([c])) for c in (7,8,9,11,12,13))` over the file
   bytes, and `cat -v` the changed region. A clean `grep` proves nothing here.

Related: [[vm-test-rig-credentials]] — same lesson shape, driver bugs that fail quietly.
