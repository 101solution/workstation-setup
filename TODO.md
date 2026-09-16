# Repo Fix Backlog

Open work only. Closed items — the 2026-09-11 audit (1-22) and the unattended-setup goal
(G1-G35, including the nine real-machine bugs G23-G31) — are in
[`VALIDATION-HISTORY.md`](VALIDATION-HISTORY.md), with their numbering intact.

## Handover — start here (updated 2026-09-16)

**Where things stand.** Both entry points have **passed a clean end-to-end run on a fresh machine**
(run 7, 2026-09-14, from `snap-vm-wstest-01-clean-20260911`): `config-workstation.ps1 -role mrl`
in 9 phases and one reboot, then `config-docker.ps1` in 6 phases and one reboot, with the Windows
daemon printing the hello-world banner and the Linux daemon reporting `os=linux` on 2375 and running
a container to `exitCode=0`. Getting there took **nine bugs that only a real machine exposed**
(G23-G31); every one passed the parser, JSON and unit checks beforehand.

**Released as `v2.4.0` on 2026-09-14** (commit `f977c29`), published as a GitHub *Release*, not just
a tag - `get-latestPackages.ps1` queries `/releases` and filters non-draft/non-prerelease, so a bare
tag would reach nobody. It is now "Latest", so every new machine running the bootstrap one-liner
installs it. Previous release was `v2.3.2` from April. `v2.4.0` is **breaking**: `-role runner`,
`-role ce-corp`, `-role ce-free`, `containers/` and `-installStax2AWS` are all gone.

**Server 2025 is now part of the matrix.** Run 12 (2026-09-16) was the first Server-SKU run ever:
`v2.5.0` completed both flows there - `mrl` in 15.5 min and Docker CE with both daemons verified -
and found three bugs (G37, G38, G39), one of which had been silently broken on every machine since
the theme copy was written. Validate on **one client and one Server** box from now on.

**State of the test rig (2026-09-16).** `vm-wstest-01` is **deallocated** (`Standard_D4s_v5`), so
compute cost is zero. The two superseded OS disks were deleted today, leaving only the live
`vm-wstest-01-osdisk-202609160942`; storage cost is now one disk. The clean snapshot
`snap-vm-wstest-01-clean-20260911` is intact and is what G36 restores from — remember
`az vm user update` to reset `azureadmin` first, since autologon does not survive a restore.

**Live gate: none.** G37, G38 and G39 all passed on 2026-09-16 (runs 13/14, one client and one Server), so `v2.5.1` can be cut. `v2.5.0` was
published on 2026-09-16 and is Latest; three fixes have landed on `main` since and none of them has
had a full run.
Commit `f3aeba9` (2026-09-16) refreshed every role manifest — .NET SDK 10,
VS Enterprise 2026, five new base-layer packages, `posh-git` replaced by `carapace` — and none of
it had run on a real machine when that was written; run 11 has since validated it on `mrldev`.


**The test VM.** `vm-wstest-01`, resource group `S101-ARG-WSTEST-MRL`, subscription VS_Sub_MRL
`1f513fde-7a26-4aae-a69e-3f29f41d7f2a` in the user's personal tenant `5509d93f-…`. If `az` says
the subscription is not found, the token is stale: the user must run
`az login --tenant 5509d93f-af21-4739-b7c9-ec32c2ca43a1` themselves. Windows 11 Enterprise 24H2,
`Standard_D4s_v5`, Australia East, ~AUD 0.35/h running, nightly auto-shutdown 14:00 UTC.
**Deallocate it when pausing** (`az vm deallocate`). Admin user `azureadmin`; the password is in
the gitignored `logs/vm-wstest-01-admin.txt` (and `vm-bootstrap.ps1`). **Autologon for
`azureadmin` is enabled** (password in the registry in clear text, acceptable on this throwaway
box, RDP is limited to the user's home IP) — remove it or delete the resource group when done.
Clean snapshot `snap-vm-wstest-01-clean-20260911` (stock image, pre-Windows-Update). Restore
procedure and full run history are under G7 below.

**How to drive a run without RDP.** `az vm run-command invoke --command-id RunPowerShellScript
--scripts @file.ps1` runs as SYSTEM, one at a time per VM, output capped at ~4 KB (fetch logs in
line-range chunks). SYSTEM cannot run WSL and does not see the user's profile, so the setup itself
must run as `azureadmin`: the pattern is a scheduled task with `-LogonType Interactive
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
the date, including negative results. They ask to commit and push straight to `main` (branch
`unattended-setup-and-audit-fixes` is kept identical to `main` via fast-forward). Commit messages
end with the Claude co-author line. Docs to keep in sync: `README.md` (users), `CLAUDE.md`
(maintainers), `docker-ce/README.md`.

---

## Open

- [x] **G39. DONE 2026-09-16 by runs 13/14** - Bruno 4.1.0 installed on a deliberately dotted account, `test.user`. Original entry below.
  **G39. `Bruno.Bruno` 4.1.0 crashes when winget stages it under a dotted username. MITIGATED.**
  Found 2026-09-16 on Server 2025 during the `v2.5.0` run: `winget exited with 0x8A150006`, installer
  exit `3221225477`. WER names the faulting module as NSIS's own `System.dll`
  (`0xc0000005`, offset `0x00001581`, module timestamp `0x5c157efa`) loaded from
  `%TEMP%\nsoC7ED.tmp\System.dll` - the copy that run had just extracted, so not a stale file.

  **It is the path, not the SKU.** winget stages installers under `%TEMP%`, inside the user profile.
  The account `chuanhui.shen` gets the 8.3 short name `CHUANH~1.SHE`, and the identical installer
  that crashes from there succeeds when copied to `C:\temp`. `dev-cs-01` was unaffected because its
  account is `cshen`. Bruno 3.4.2 installs fine from either path, so it is a 4.x regression.
  The WER signature matches upstream usebruno/bruno#3404 exactly (closed as no longer reproducing,
  and all its reports were Windows 11, not Server).

  Mitigated in the `winget` phase by staging installers in `%SystemRoot%\Temp\workstation-setup`
  for the duration of the phase and restoring `TEMP`/`TMP` in a `finally`. This addresses the class
  - any NSIS installer with the same path sensitivity - rather than Bruno alone. Verified under
  Windows PowerShell 5.1 that the swap applies, the directory is writable, and the original values
  are restored even when the phase throws.

  **Not yet validated by a run.** This changes the environment for *every* installer in the phase,
  so the two-SKU run under G37 must confirm the whole `mrldev` package set still installs, and that
  Bruno specifically now succeeds on a dotted-username account. Worth reporting upstream with the
  WER data, since #3404 was closed without this path-dependent repro.

- [x] **G38. DONE 2026-09-16 by runs 13/14** - the theme now parses on both SKUs, checked with `oh-my-posh print primary --config`. Original entry below.
  **G38. The deployed oh-my-posh theme carried a UTF-8 BOM and was never parsed. FIXED, needs a run.**
  `config-workstation.ps1` wrote the theme with `Out-File -Encoding utf8` under Windows PowerShell
  5.1, which emits a BOM; oh-my-posh is a Go program and rejects JSON starting with one, showing
  `CONFIG PARSE ERROR` and falling back to a default theme. Affects **every machine and every SKU**,
  and has done since the theme copy was written - client machines too, not just Server.
  Found 2026-09-16 on a Server 2025 box, only because the standalone exe made the prompt fast
  enough to read the error.

  Fixed by `Save-Utf8NoBom` (helper.ps1), used for both the theme and the Windows Terminal
  `settings.json`. Verified under 5.1: first bytes `7B 0D 0A`, `ConvertFrom-Json` accepts it,
  `oh-my-posh print primary --config` parses it, `#workFolder#` substituted. `profile.ps1` keeps
  `Out-File` - a BOM is fine in a `.ps1` and helps 5.1 decode non-ASCII.

  **Why run 11 missed it:** it asserted `Test-Path` on the theme file rather than asking oh-my-posh
  whether it could read it. Recorded in CLAUDE.md as its own measurement trap.

- [x] **G37. DONE 2026-09-16 by runs 13/14** - the client early-return kept the MSIX untouched and Server got the standalone exe (31 ms). Original entry below.
  **G37. Validate the Server-SKU oh-my-posh fix on both SKUs before `v2.5.1`.**
  `Install-OhMyPoshStandalone` (helper.ps1) downloads a plain `oh-my-posh.exe` on Windows Server,
  because MSIX activation of `ohmyposh.cli` there spawns `Microsoft.DesktopAppInstaller!winget` and
  blocks 10-17 s per invocation - on every prompt render. Found on 2026-09-16 when `v2.5.0` was run
  on a fresh **Windows Server 2025** box, the first time this repo had been tried on a Server SKU.

  All three branches of the helper are verified on a real Server 2025 machine (already-present
  no-op, download at the MSIX's version, idempotent re-run; 71 ms against ~13,000 ms). What is
  **not** verified:
  - The **client-SKU early return**. It is a one-line `if (Test-WindowsClientSku) { return }`, but no
    run has exercised it, and client machines must keep the winget-managed MSIX untouched.
  - A full clean-VM run on either SKU with the helper in the `shell` phase.

  So the gate for `v2.5.1` is two runs: one Windows 11 client (confirm the MSIX is left alone and
  the prompt is still ~137 ms) and one Server 2025 (confirm the download happens, no App Installer
  dialog, and a fast prompt in a fresh shell).

  **Add Server 2025 to the validation matrix permanently.** Runs 1-11 were all client SKU, and the
  first Server run immediately found two real issues: this one, and `Bruno.Bruno` failing with
  `0x8A150006` / installer exit `3221225477` (0xC0000005, an access violation in Bruno's own
  installer). The Bruno failure is non-fatal - `Install-WinGetPackage` logs a warning and the phase
  continues - but it means `mrl` on Server does not get Bruno. Worth deciding whether that is
  acceptable or whether Bruno should be dropped from Server-bound roles.

- [x] **G36. Validate the 2026-09-16 manifest refresh on a clean VM before cutting a release.**
  **DONE 2026-09-16 by run 11** (role `mrldev`, 9 phases, one reboot, 33 minutes): VS 2026 with
  both workloads confirmed via `vswhere`, SDK 10.0.401, 0 profile load errors, carapace
  completing `git`/`terraform`/`gh`. Full record in `VALIDATION-HISTORY.md`. The release is no
  longer blocked. Original plan below.
  Commit `f3aeba9` changed what every role installs and **none of it has run on a real machine**.
  Static checks are green (all `.ps1` parse, all five manifests `ConvertFrom-Json`), which per this
  repo's own history means almost nothing — G23-G31 all passed those too. `main` can be pushed
  freely; it is publishing the *Release* that exposes machines, so the gate is release, not push.

  **Run `-role mrldev`, not `-role mrl`.** Every prior validation run (5-9) used `mrl`, so the
  riskiest change here has never been exercised. Budget 45-60 min: VS Enterprise dominates.

  What changed, and what each item needs proving:
  1. **VS 2022 Enterprise → `Microsoft.VisualStudio.Enterprise` (2026, 18.10.1).** The id no longer
     carries a year, so it tracks current VS instead of pinning a major version — a future VS 2027
     will be pulled in on any re-run, because `Install-WinGetPackage` upgrades when the source is
     newer. Both workload ids in the `override` (`Workload.Azure`, `Workload.NetWeb`) are unchanged
     in 2026, confirmed against the Enterprise component directory, but **that was a docs check, not
     a run.** The failure mode is a silent partial install, so verify the workloads actually landed:
     `vswhere -products * -requires Microsoft.VisualStudio.Workload.Azure -property installationPath`.
     Do not treat winget's exit code as evidence — this is the same class of mistake as gating on
     "is the service registered" (G25).
  2. **.NET SDK 8 → 10** in `mrl`, `mrldev`, `cloudEngineer`, `developer`. Confirm with
     `dotnet --list-sdks`. Low risk; SDK 10 targets every installed runtime.
  3. **Five new base-layer packages** — `GitHub.cli`, `Anthropic.Claude`, `OpenJS.NodeJS.LTS`,
     `GoLang.Go`, `rsteube.Carapace`. Every role's `winget` phase got longer. Watch for
     `0x8A150109` / `0x8A15010A` being folded into the single reboot rather than provoking a second.
  4. **`posh-git` → `carapace`.** Needs *positive* confirmation in a fresh shell after setup:
     `git chec` must complete to `checkout`. The `profile.ps1` guard means a blocked or missing
     binary looks identical to a working one that silently does nothing — precisely the
     probe-that-cannot-fail trap from G27. Also check the shell start cost is still ~100 ms and that
     cmdlet/parameter/path completion is intact.
  5. **`cloudEngineer` rebuilt as `mrl` + kubectl + minikube**, with `AWSPowerShell.NetCore` and four
     base-layer duplicates dropped. Worth a second, cheaper run (no VS).

  Known rough edges, already measured on `dev-cs-01`, not defects to chase:
  - `kubectl get po` returns carapace's error marker (`poERR`, `po_`) until a cluster is configured,
    which is the normal state on a freshly provisioned box.
  - carapace is an **unsigned Go binary** that winget installs to a user-writable directory
    (`%LOCALAPPDATA%\Microsoft\WinGet\Packages\…`). That is the class of executable a managed
    endpoint can deny outright, so on a corporate-managed laptop expect no completion at all. The
    `profile.ps1` guard exists so that degrades quietly instead of erroring on every shell start.
  - winget adds that directory to the **user** PATH, so a shell started before setup finishes will
    not see `carapace`. Verified on `dev-cs-01`: a fresh shell with the registry PATH re-read
    resolves it correctly.

  The VM, its clean snapshot and the `az vm run-command` driver are described under G7 and G32 above;
  G32 notes `az vm user update` must reset `azureadmin` first, since autologon does not survive the
  snapshot restore.

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
