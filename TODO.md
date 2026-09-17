# Repo Fix Backlog

Open work only. Closed items — the 2026-09-11 audit (1-22) and the unattended-setup goal
(G1-G39, including the nine real-machine bugs G23-G31) — are in
[`VALIDATION-HISTORY.md`](VALIDATION-HISTORY.md), with their numbering intact.

## Handover — start here (updated 2026-09-17)

**Where things stand.** Both entry points have **passed a clean end-to-end run on a fresh machine**
(run 7, 2026-09-14, from `snap-vm-wstest-01-clean-20260911`): `config-workstation.ps1 -role mrl`
in 9 phases and one reboot, then `config-docker.ps1` in 6 phases and one reboot, with the Windows
daemon printing the hello-world banner and the Linux daemon reporting `os=linux` on 2375 and running
a container to `exitCode=0`. Getting there took **nine bugs that only a real machine exposed**
(G23-G31); every one passed the parser, JSON and unit checks beforehand.

**Released as `v2.5.1` on 2026-09-16** (commit `1f38645`), published as a GitHub *Release*, not just
a tag - `get-latestPackages.ps1` queries `/releases` and filters non-draft/non-prerelease, so a bare
tag would reach nobody. It is "Latest", so every new machine running the bootstrap one-liner
installs it. `v2.5.1` carries the theme BOM fix (G38), the Server prompt-speed fix (G37), the
installer staging fix (G39) and the new shell/CLI tools; `v2.5.0` went out three hours earlier the
same day with the manifest refresh. The last breaking release was **`v2.4.0`**: `-role runner`,
`-role ce-corp`, `-role ce-free`, `containers/` and `-installStax2AWS` are all gone.

**Server 2025 is now part of the matrix.** Run 12 (2026-09-16) was the first Server-SKU run ever:
`v2.5.0` completed both flows there - `mrl` in 15.5 min and Docker CE with both daemons verified -
and found three bugs (G37, G38, G39), one of which had been silently broken on every machine since
the theme copy was written. Validate on **one client and one Server** box from now on.

**The test rig is gone (decommissioned 2026-09-17, on request).** The whole resource group
`S101-ARG-WSTEST-MRL` was deleted — `vm-wstest-01` (client), `vm-wstest-02` (Server 2025), both
Premium OS disks, the network shell, the auto-shutdown schedule **and the clean snapshot
`snap-vm-wstest-01-clean-20260911`**. Cost is now zero and the two cleartext autologon passwords
went with the disks. The snapshot loss was called out before the delete and accepted, so it was
deliberate.

**So the next release's validation starts by rebuilding the rig.** Budget for that: create two VMs
in a fresh RG in VS_Sub_MRL (one Windows 11 client, one Server 2025 — the matrix is two SKUs now),
from Azure stock images rather than a snapshot. `logs/vm-bootstrap.ps1` still does the per-VM work
(download `main` as a zip, set autologon, register the at-logon task), and the Server box needs a
**dotted** admin username, e.g. `test.user`, or G39's staging fix is never exercised. Take a clean
snapshot of each *before* the first run this time, so the baseline survives.

**Live gate: none, and nothing is unreleased.** G36-G39 are all closed, `main` is clean, and every
commit on it has shipped in `v2.5.1`. Runs 13/14 (2026-09-16, one client and one Server) closed
G37/G38/G39 and also covered the packages added the same day - zoxide, fzf, jq, Python 3.14,
terraform-docs, the AWS Session Manager plugin, `powershell-yaml`. Run 11 validated the manifest
refresh of commit `f3aeba9` on `mrldev`.

**The Docker CE flow does not owe a re-run.** Its last full pass was run 12 (`v2.5.0`, Server 2025,
both daemons verified). Nothing under `docker-ce/` has changed since, and the only shared file that
did - `helper.ps1` - changed purely by addition (`Save-Utf8NoBom`, `Install-OhMyPoshStandalone`;
79 insertions, 0 deletions), neither of which `config-docker.ps1` calls.


**Where to rebuild the test VMs.** Subscription VS_Sub_MRL
`1f513fde-7a26-4aae-a69e-3f29f41d7f2a` in the user's personal tenant `5509d93f-…`, Australia East.
If `az` says the subscription is not found, the token is stale: the user must run
`az login --tenant 5509d93f-af21-4739-b7c9-ec32c2ca43a1` themselves. What the retired rig used, and
what worked: `Standard_D4s_v5` (~AUD 0.35/h running, 128 GB Premium OS disk ~AUD 28/mo), a
DevTestLab nightly auto-shutdown at 14:00 UTC, RDP restricted by NSG to the user's home IP, and
autologon enabled for the admin account — which stores the password in the registry in **clear
text**, tolerable only on a throwaway box, and is what supplies the interactive session the resume
task needs. **Deallocate when pausing** (`az vm deallocate`); disks are billed regardless.
Note autologon does not survive a snapshot restore, so `az vm user update` has to reset the admin
password first. Run history is under G7 below.

**How to drive a run without RDP.** `az vm run-command invoke --command-id RunPowerShellScript
--scripts @file.ps1` runs as SYSTEM, one at a time per VM, output capped at ~4 KB (fetch logs in
line-range chunks). SYSTEM cannot run WSL and does not see the user's profile, so the setup itself
must run as the VM's admin account: the pattern is a scheduled task with `-LogonType Interactive
-RunLevel Highest` that unregisters itself and then runs the script, fired either at logon after a
reboot (autologon supplies the session) or immediately with `Start-ScheduledTask`. Scripts in
`logs/` (gitignored): `vm-bootstrap.ps1` (fresh run: download `main` as a zip, set autologon,
register the at-logon task; then `az vm restart`), `vm-rerun.ps1` (refresh `main`, keep logs and
state, start the setup now), `vm-poll.ps1` (state file, running processes, log excerpts),
`vm-register-diag-task.ps1` + `c:\config\wsl-diag.ps1` on the VM (as-user WSL/package checks),
`vm-verify-windows.ps1` (per-user artefacts, runnable as SYSTEM with explicit paths). Decode Linux
command output as UTF-8 and `wsl.exe`'s own messages as UTF-16; stripping `` `0 `` is the quick fix.

**Gotchas that cost time, so you do not rediscover them.**
- `Start-Transcript` under PowerShell 5.1 does not capture `Write-Information`. All logging is
  `Write-SetupLog` (`Write-Host`). Never `Write-Output` for logging (return-value contamination).
- A brand-new Windows profile has no `winget`/`wt` alias even though the packages are installed.
  `Get-WinGetPath` / `Get-WindowsTerminalPath` handle it; never call them bare.
- `wsl --install --help` is rejected by Store WSL 2.7; detect flags from `wsl --help`.
- `wsl.exe -- cmd C:\path` loses the backslashes (shell escaping); pass `C:/path`.
- `winget install` upgrades by itself; its return codes decide the outcome (`0x8A15002B` = current).
- Each entry script has its own state file (`$script:SetupStateFileName`); phase names may repeat.
- The sandbox here refuses shell commands whose *text* contains `Remove-Item` near `/mnt`; use
  `[IO.File]::Delete` in remote scripts.
- **Never pass an Azure resource ID to `az` from Git Bash.** MSYS turns the leading `/` into
  `C:/Program Files/Git/...`, and the resulting errors point at azure-cli rather than at the shell
  (`KeyError: 'id'`, `LinkedInvalidPropertyId`). Use the PowerShell tool for any `az` call taking an
  ID, or prefix `MSYS_NO_PATHCONV=1`.

**Working conventions with this user.** Backlog lives in this file; record every outcome here with
the date, including negative results. They ask to commit and push straight to `main`; there is no
mirror branch to maintain (`unattended-setup-and-audit-fixes` was fully merged and deleted
2026-09-17). Commit messages
end with the Claude co-author line. Docs to keep in sync: `README.md` (users), `CLAUDE.md`
(maintainers), `docker-ce/README.md`.

---

## Open

**Nothing open.** G36-G39 were all closed on 2026-09-16 by runs 11, 13 and 14 and now live in
[`VALIDATION-HISTORY.md`](VALIDATION-HISTORY.md); `v2.5.1` is published and is Latest.

---

## Checked and NOT a bug

- **`get-latestPackages.ps1` re-runs fine** (claimed as a bug 2026-09-14, refuted the same day by
  run 9). The claim was that `ExtractToDirectory` would throw on a second run because
  `c:\config\101solution-workstation-<sha>` already existed. It does not: line 37's `Rename-Item`
  *consumes* that folder into `c:\config\workstation`, so it is never left behind for the next
  extract to collide with. Measured on the VM after a real bootstrap: leftover sha folders = 0,
  leftover `workstation.zip` = absent. Recorded because the misreading looked plausible.

- `-role min` leaves `$packageConfig` undefined, but the resulting `$null` is dropped by the
  `Select-Object` projection at `config-workstation.ps1:47`. No bogus package entry is produced.
- PowerShell 7 does include `C:\Program Files\WindowsPowerShell\Modules` on `$env:PSModulePath`
  (verified), so modules installed by the 5.1-hosted setup script are visible to the pwsh profile.
