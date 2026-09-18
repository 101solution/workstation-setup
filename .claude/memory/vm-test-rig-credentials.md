---
name: vm-test-rig-credentials
description: How to drive a clean run on the Azure test VM without losing the role or breaking autologon — the two traps that cost runs 10 and 11
metadata:
  type: reference
---

Learned 2026-09-16 across runs 10 and 11 (G36). Both failures were in the *driver*, not the repo,
and both were silent.

**`logs/vm-wstest-01-admin.txt` holds two lines: username, then password.** It is not a bare
password. `(Get-Content ... -Raw).Trim()` yields `azureadmin\n<password>` as one string. Feeding
that to autologon writes a `DefaultPassword` that cannot match the account, no session is created,
and the at-logon task never fires. Read line 2, or better, don't read the file at all (below).

**Never pass anything through `az vm run-command --parameters`.** Parameters are parsed as
`key=value`, so a value containing `=` is silently truncated *and* later parameters are displaced to
their defaults. In run 10 `--parameters "AdminPassword=$pw" "Role=mrldev"` bound
`AdminPassword` to 10 characters and dropped `Role` to its default `mrl` — so the run validated the
wrong role for 20 minutes before anyone noticed. Embed values in the script text and send it with
`--scripts` only.

  *Run 16 (2026-09-18) used `--parameters` anyway and got away with it — the rule still stands.* It
  worked only because neither recorded password happened to contain `=`, which is luck, not safety:
  `[System.Web.Security.Membership]::GeneratePassword` can emit one. The run did do the one thing
  that makes the gamble survivable — the script echoed the role it had baked in (*"armed for
  azureadmin, role mrl"*) and that was read before restarting. If you find yourself reaching for
  `--parameters`, assert every value back out of the remote script's own output first.

**Clean up autologon when the runs are done.** A run arms `AutoAdminLogon=1` with the password in
clear text under `Winlogon`, and nothing disarms it — run 16 left both boxes that way. `quser`-based
debugging needs it, so it cannot be armed later; instead make `logs\vm-clear-creds.ps1` part of
finishing, or delete the VMs, which is the only disarming that cannot be forgotten.

**A no-session failure looks identical to a slow start.** Symptoms: no state file minutes after
restart, task `state=Ready` with `lastRun=11/30/1999` and `lastResult=267011` (0x41303, never run),
and `quser` reporting "No User exists". `Start-ScheduledTask` does **not** rescue it — an
`-LogonType Interactive` task needs a real session. Check `quser` first; it is the fastest
discriminator.

**The better procedure, which avoids all three:**
1. Generate a fresh single-line password per run, avoiding `=` and shell metacharacters. This also
   rotates a credential that tends to end up in transcripts.
2. `az vm user update -u azureadmin -p <pw>`, then write the *same* value into autologon.
3. Embed password and role in a generated copy of `logs/vm-bootstrap.ps1`; pass no `--parameters`.
4. **Assert the role from the generated inner script before restarting:**
   `Get-Content c:\config\run-ws.ps1` must contain `-role <expected>`. Gate the restart on it.
   Asserting what you believe you sent is not the same as asserting what will run.
5. After the restart, confirm `quser` shows an active console session before waiting on phases.

Related: [[avoid-scheduled-tasks-preference]] — the elevated-resume constraint is why this rig needs
an interactive session at all.
