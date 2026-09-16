---
name: avoid-scheduled-tasks-preference
description: User prefers to avoid scheduled tasks for post-reboot resume; offer task-free options first
metadata:
  type: feedback
---

Asked on 2026-09-11, in their words: "can I avoid to use schedule task?" — after I had implemented
post-reboot resume via a logon-triggered scheduled task.

**Why:** not stated explicitly. Plausibly the aggressive corporate Defender/MDE posture on managed
machines, or policy around creating scheduled tasks on managed endpoints. Worth asking if it comes
up again rather than assuming.

**How to apply:** when a design needs work to survive a reboot or run in the background, lead with
the task-free option and state the trade-off rather than defaulting to a scheduled task. The
constraint that matters: coming back **elevated** after a reboot genuinely requires a scheduled
task, a Windows service, or autologon with a stored password. HKLM `RunOnce` runs with the logon
user's *filtered* token, so it cannot satisfy `#Requires -RunAsAdministrator` without one UAC
consent. The better lever is usually to **need the reboot less** — in this repo that meant
reordering phases so at most one reboot happens and only a tiny step remains after it.

Resolved by adding `-resumeMethod ScheduledTask|RunOnce|None` to `config-workstation.ps1`; see the
"Unattended execution and reboot resume" section of the repo's CLAUDE.md for the resulting design.
