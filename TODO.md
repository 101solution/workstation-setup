# Repo Fix Backlog

## Handover — start here (updated 2026-09-14)

**Where things stand.** Both entry points have **passed a clean end-to-end run on a fresh machine**
(run 7, 2026-09-14, from `snap-vm-wstest-01-clean-20260911`): `config-workstation.ps1 -role mrl`
in 9 phases and one reboot, then `config-docker.ps1` in 6 phases and one reboot, with the Windows
daemon printing the hello-world banner and the Linux daemon reporting `os=linux` on 2375 and running
a container to `exitCode=0`. Getting there took **nine bugs that only a real machine exposed**
(G23-G31); every one passed the parser, JSON and unit checks beforehand. **Ready to tag**; nothing
reaches users until a `v2.x.y` release is cut, since they bootstrap from the latest release.

**Next steps, in order.**
1. Run the Docker CE flow on the test VM (G7 step 2). The VM is already a configured `mrl`
   workstation with WSL Ubuntu 26.04, which is exactly its precondition. Drive it the same way as
   the workstation runs (below): refresh `main` onto the VM, start
   `docker-ce\config-docker.ps1` as `azureadmin` via a scheduled task, poll, then verify
   `docker run hello-world` and `docker -c win run hello-world` as `azureadmin`. It will download
   Docker 29.8.0 for the first time (G14).
2. ~~Fold `install-docker-ce.ps1` into the orchestrator~~ — **done 2026-09-14 (G28).**
3. ~~Ask the user, then act: keep or delete `containers/` and the `ce-corp` / `ce-free` roles~~ —
   **done 2026-09-14: all three deleted on request.**
4. Re-run the Docker CE flow on the VM to confirm G26/G27/G28/G30, then cut the release.
   **Run 6 (2026-09-14, `-force` on the run-5b disk) did not finish: it hung in `docker-linux`
   and exposed G30.** It did confirm the merged structure works — `containers-feature`,
   `environment` and `docker-windows` all completed, and `Install-WindowsDocker` reported
   *"C:\docker\dockerd.exe is already present"* then *"Windows Docker daemon is up"*. It also
   confirmed, as predicted, that this disk cannot exercise G23/G24/the gate: `rebootCount` stayed 0
   with a null resume command. The run was killed and its state file deleted rather than being let
   fall through to the TCP check, which would have started the distro and recorded a misleading
   `done`. **Next run must be from the clean snapshot** (approved 2026-09-14), which needs
   `az vm user update` to reset `azureadmin` first, since autologon does not survive the restore
   and the old password file is gone.

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

Findings from an audit of the scripts on 2026-09-11, ordered by impact.
Each item records the failure, the file/line, and the intended fix.

**Status: 22 of 22 closed.** Line numbers below refer to the code *as audited*, before any fixes
were applied, so they will not match the current files. Three items were resolved differently from
the original finding — see the scope notes on items 18, 20 and 22 — and item 21's premise turned out
to be wrong. Nothing here has been executed on a real machine: every change is verified only by
parser/syntax checks, JSON validation, and unit-testing the winget output parser. A run on a
throwaway VM is still required before cutting a release.

---

## P1 — Breaks setup

- [x] **1. `get-latestPackages.ps1:17` — prereleases are never filtered out**
  `Where-Object {(-not $_.draft) -and (-not $_.prerelase)}` misspells `prerelease`, so the property
  is `$null` and `-not $null` is always `$true`. Any published prerelease becomes what new machines
  install. Highest blast radius in the repo: this file is fetched from raw `main`, so it bypasses
  the release gate entirely.
  *Fix:* correct the spelling to `prerelease`.

- [x] **2. `get-latestPackages.ps1:16-21` — silent API failure, then garbage install**
  `Invoke-RestMethod -ErrorAction SilentlyContinue` is followed by unconditional use of
  `$latestRelease.zipball_url`. The GitHub releases API is called unauthenticated (60 req/hr per IP,
  shared across everyone behind the corporate NAT), so this does fail in practice — and when it
  does, the script downloads nothing and extracts it.
  *Fix:* check for a null release / zipball URL and `throw` with an actionable message.

- [x] **3. `docker-ce/install-docker-ce.sh:17-18` — the reboot never happens, so port 2375 never opens**
  `sudo usermod -aG docker $USER && newgrp docker` spawns a new shell, so the `sudo shutdown now -r`
  on line 18 never runs under `wsl -- ./install-docker-ce.sh`. That reboot is the only thing that
  loads the unit file patched by the `sed` on line 15 — there is no `systemctl daemon-reload`. Net
  effect: the Linux daemon starts without `-H tcp://127.0.0.1:2375`, so the `DOCKER_HOST` the
  Windows side sets points at a closed port.
  *Fix:* drop `newgrp`, add `systemctl daemon-reload`, and add the missing `apt-get update` before
  the prerequisite install on line 3.

- [x] **4. `docker-ce/install-docker-ce.ps1:14` — hardcoded deploy path**
  `$global:ScriptFolder = "c:\config\workstation\docker-ce"` feeds the `daemon.json` copy on line
  210. Run from a git clone and that copy fails, the Windows daemon never gets its TCP host, and
  `docker -c win` cannot connect.
  *Fix:* use `$PSScriptRoot`.

- [x] **5. `docker-ce/install-docker-ce.ps1:202` — dead copy that always errors**
  `Copy-Item ./daemon.json -Destination "$env:ProgramData\docker\config"` runs before
  `dockerd --register-service` (line 203) creates that directory, and its source is cwd-relative.
  Line 210 already does this correctly.
  *Fix:* delete line 202.

- [x] **6. No `#Requires -RunAsAdministrator` on any entry point**
  Only `#Requires -Version 5.0` exists, and only on two non-entry scripts. All four entry points
  write to `C:\Windows\Fonts`, write HKLM, and call `Enable-WindowsOptionalFeature`. A non-elevated
  run dies partway and leaves a half-configured machine.
  *Fix:* add the directive to `config-workstation.ps1`, `config-github-runner.ps1`,
  `config-docker.ps1`, and `get-latestPackages.ps1`. (`config-docker.ps1` was later deleted under
  item 17, so three entry points carry it now.)

## P2 — Should fix

- [x] **7. `config-github-runner.ps1` does not configure a runner**
  No references to `actions-runner`, `config.cmd`, `svc.sh`, or a registration token — it installs
  packages plus Docker Engine and stops. README and CLAUDE.md both claim it "sets up a GitHub
  Actions self-hosted runner".
  *Fix:* correct the docs to describe what it actually does (runner *prerequisites*). Leave real
  runner registration as separate work, since it needs a token and a target repo/org.

- [x] **8. `config-github-runner.ps1:54` — log filename collision**
  Writes its transcript to `gh-runner-config.log`, then renames it to `workstation-config-<date>.log`,
  colliding with the workstation script's logs in the same folder.
  *Fix:* rename to `gh-runner-config-<date>.log`.

- [x] **9. `helper.ps1:394,399` — `Install-Kubectl` is inert**
  Both comparisons are `-eq` where they must be `-ne`; on a clean machine `$installedVersion` is
  `"0.0.0.0"`, never matches, so the download block never runs. Also `$latestVersion` holds a
  response object rather than `.Content`, and it is compared against `ClientVersion.gitCommit`
  (a commit SHA, not a version). Nothing calls this function.
  *Fix:* delete it — `Kubernetes.kubectl` is already installed via WinGet in
  `packages-cloudEngineer.json`, so it is redundant as well as broken.

- [x] **10. `config-workstation.ps1:128` — destroys Windows Terminal customisation**
  `$terminalSettings.profiles.defaults = $defaultSettings` replaces the whole node, so re-running on
  a tuned machine silently discards the user's own defaults.
  *Fix:* merge property-by-property instead of assigning.

- [x] **11. `profile.ps1` hardcodes `C:\Projects\`**
  `$HOME` and the FileSystem provider home ignore `-defaultWorkFolder`. The Oh My Posh theme gets
  `#workFolder#` substitution and Windows Terminal gets `startingDirectory` — the profile is the only
  consumer left out, so `-defaultWorkFolder d:\work` yields an inconsistent machine.
  *Fix:* give `profile.ps1` the same `#workFolder#` token treatment as the theme.

- [x] **12. `config-workstation.ps1:81` — execution policy set to `Unrestricted` machine-wide**
  *Fix:* use `RemoteSigned`, which supports the same workflow without running unsigned downloads
  unprompted.

- [x] **13. `helper.ps1:470` — PSReadLine reinstalled on every run**
  `Get-InstalledModule -Name PSReadLine` returns nothing on a stock Windows box even though 2.0.0
  ships in-box (verified), so the version check is skipped and `Install-Module` always fires.
  PSReadLine is in `packages-min.json`, so this hits every role.
  *Fix:* fall back to `Get-Module -ListAvailable` for the presence check and add
  `-SkipPublisherCheck` (the in-box copy's authenticode issuer differs from the gallery copy's).

- [x] **14. .NET SDK 7 is out of support** (since May 2024) in `packages-cloudEngineer.json`,
  `packages-developer.json`, and `packages-runner.json`. `mrl`/`mrldev` already use SDK 8.
  *Fix:* move them to `Microsoft.DotNet.SDK.8`.

## P3 — Hygiene

- [x] **15. `backgroud/` was 14 MB, misspelled, and unused.** `terminal-default-settings.json` uses
  `"backgroundImage": "desktopWallpaper"` (the live wallpaper), not a repo file, and nothing else
  referenced the directory. Every new machine was downloading it inside the release zipball.
  *Fixed:* deleted (8 image files). Recoverable from git history if an image is ever wanted back.

- [x] **16. `docker-ce/linux/systemd/README.md`** instructs `cd containers/docker-ce/linux/systemd/`
  — no such path.
  *Fix:* `docker-ce/linux/systemd/`.

- [x] **17. Root `config-docker.ps1`** rebooted via `Restart-Computer -Force` twice with nothing to
  resume, never checked for admin, and ran `docker run hello-world` without waiting for the daemon.
  *Fixed:* deleted. `docker-ce/config-docker.ps1` is the maintained path and handles reboot
  continuation properly via the `ContainerBootstrap` task. Note this also retires the
  `#Requires -RunAsAdministrator` added to it under item 6, leaving three entry points.

- [x] **18. Dead code in `helper.ps1`** — removed `Install-Choco`, `Install-ChocoPackage`,
  `Install-WinGetOffline` (it referenced a `winget/` folder of appx files not present in the repo)
  and `Test-VMRestart`, plus the vestigial `"chocolatey": []` in `packages-developer.json` and a
  stale `chocolateysetup.psm1` comment. No Chocolatey references remain anywhere in the repo.
  **Scope change from the original finding:** `New-WindowsTask` was *kept*. It pairs with the
  still-reachable `Remove-WindowsTask` and the live `-taskName` parameter, so removing it would
  leave a half-mechanism for post-reboot continuation.

- [x] **19. `helper.ps1` `Install-WinGet`** references `$appx` in `ShouldProcess` without defining it,
  and compares `$PSVersionTable.PSVersion` (a `[Version]`) against the double `7.2`.

- [x] **20. `Convert-WingetOutput` hardcoded output line indices** (`[0]` header, `[2]` data) and
  sliced by character offset — fragile against winget's variable-length progress output.
  *Fixed:* the header and data rows are now located by content (the line containing both `Id` and
  `Version`, then the first subsequent line containing the package id). The install-vs-upgrade
  decision logic is deliberately unchanged. Verified against five synthetic output shapes,
  including spinner-prefixed output, which the old fixed-index code silently failed on.
  The doubled `winget list` call was left in place — it is a cold-start workaround, not a bug.

- [x] **21. Inconsistent script encoding** — original finding was wrong: `config-workstation.ps1`
  *and* `config-github-runner.ps1` both carry UTF-8 BOMs; `config-docker.ps1` and
  `get-latestPackages.ps1` do not, and `get-latestPackages.ps1` is LF-only where the rest are CRLF.
  *Resolved as no-change:* UTF-8-with-BOM is the encoding Windows PowerShell 5.1 reads correctly,
  and these scripts are launched via `powershell.exe`, so the BOMs are kept. Recorded here so the
  inconsistency is not mistaken for a defect later.

- [x] **22. `-installStax2AWS` converted to `[switch]`** (and given the `[Parameter()]` attribute
  the other parameters have). **Scope change from the original finding:** `-enableWSL` was left as
  `[boolean]`. Its default is `$true` and a `[switch]` cannot default to true, so converting it
  would silently stop installing WSL for every caller that omits the flag. *(The parameter and
  `Install-Stax2AWS-CLI` were later removed entirely — see G13.)*

---

## Goal: unattended completion with auto-resume (2026-09-11, code complete, awaiting VM run)

> Requirement: setup must complete **without manual interaction** and **auto-resume if a reboot is
> needed**.

Design is documented in the "Unattended execution and reboot resume" section of CLAUDE.md.

### Done

- [x] **G1. Phase-based, resumable `config-workstation.ps1`.** Named phases, each recorded in
  `%ProgramData%\workstation-setup\setup-state.json` (outside the repo, so a re-download by
  `get-latestPackages.ps1` cannot discard progress). Phases are idempotent; a phase that throws is
  logged and left un-recorded so the next run retries it rather than aborting the build.
  `-force` clears state and redoes everything.

- [x] **G2. At most one reboot, as late as possible.** `wsl-features` runs first with `-NoRestart`,
  then all slow work, then a single reboot gate, then `wsl-distro`. A fresh machine ends up fully
  configured except for WSL distro registration before the restart.

- [x] **G3. `-resumeMethod ScheduledTask|RunOnce|None`.** Added in response to "can I avoid to use
  schedule task?". `ScheduledTask` (default) is the only genuinely hands-off option, because
  returning *elevated* after a reboot requires a task, a service, or autologon with a stored
  password — HKLM `RunOnce` runs with a filtered token and would need one UAC consent.
  `ScheduledTask` degrades to `RunOnce` automatically if task registration is blocked by policy.
  The resume task runs as the invoking user (elevated), never SYSTEM, because setup writes per-user
  artefacts.

- [x] **G4. Unattended WSL.** `wsl --install -d Ubuntu` used to launch Ubuntu's OOBE, which blocks
  on a UNIX username/password prompt. Now `--no-launch` where supported (feature-detected at runtime
  from `wsl --install --help`, because the inbox stub and Store build expose different flags), with
  the per-distro `install --root` launcher as fallback. `Initialize-WslUser` provisions the user
  from the Windows side via `wsl --user root`, with passwordless sudo and `systemd=true` in
  `/etc/wsl.conf` — which also unblocks the Docker CE Linux script's unattended `sudo`/`systemctl`.

- [x] **G5. Removed the remaining prompts.** PSGallery marked Trusted and the NuGet provider
  pre-installed so `Install-Module` cannot stop to confirm an untrusted repository; pending-reboot
  detection reinstated as `Test-PendingReboot` (the deleted `Test-VMRestart` checked registry
  *values* where the reboot signals are actually *subkeys*).

- [x] **G6. Fixed a latent infinite reboot loop.** The repo's `Write-Output "..." | timestamp`
  logging writes to the success stream, so inside a value-returning function the log lines become
  part of the return value. `Enable-WslFeature` would have returned `@('msg','msg',$false)`, and
  `if (Fn)` on a non-empty array is `$true` — demanding a reboot forever. Value-returning functions
  now log via `Write-SetupLog` (information stream). Verified: `Test-PendingReboot` returns a
  `Boolean` with `@(...).Count -eq 1`.

- [x] **G8. `config-github-runner.ps1` made resumable** (2026-09-11). The phase runner
  (`Invoke-SetupPhase`, `Request-PhaseReboot`) and a new `Invoke-RebootGate` moved from
  `config-workstation.ps1` into `helper.ps1` so all entry scripts share them; each script names its
  own state file via `$script:SetupStateFileName` so their `winget`/`psmodules` phases cannot
  collide. The runner now has `-resumeMethod`, `-noReboot`, `-force`, and phases
  `preflight → containers-feature → winget → psmodules → [gate] → docker-engine → done`.
  **Added beyond the original finding:** a `containers-feature` phase. The old script registered and
  started `dockerd` without ever enabling the Containers feature (or Hyper-V on a client SKU), which
  dockerd needs to start; this is also what gives the runner a reason to have a reboot gate at all.
  `Install-DockerEngine` was made idempotent (skips download / `--register-service` / start when
  already done, downloads to `%TEMP%`, removes the zip). Unverified on a real machine — see G7.

- [x] **G9. Docker CE reboot path unified** (2026-09-11). `docker-ce/config-docker.ps1` is now the
  phase-based orchestrator (`containers-feature → environment → [gate] → docker-windows → [gate] →
  docker-linux → done`, state in `docker-ce-state.json`, `Set-Location $PSScriptRoot` so it runs
  from anywhere). `install-docker-ce.ps1` lost `Restart-And-Run` and the `ContainerBootstrap` task;
  it is a worker that exits 0 / 3010 (feature needs restart) / 1, and only touches the old task name
  to unregister a stale one. This also fixes a real bug in the old flow: when
  `install-docker-ce.ps1` rebooted, the at-logon task re-ran only *it*, so `config-docker.ps1`'s
  WSL half was silently never executed. Also fixed while here: the Server branch of
  `Install-Feature` called `Add-WindowsFeature` even when already installed; `Install-Docker`
  downloaded to cwd; `install-docker-ce.sh`'s `sed` appended a second `-H tcp://` on every re-run
  (now `grep`-guarded, and the orchestrator verifies the daemon answers instead of trusting the exit
  code, which `shutdown -r` destroys).

- [x] **G10. README.md updated** (2026-09-11): parameter table, unattended/reboot section with the
  `-resumeMethod` table and the image-pipeline example, Docker CE and runner sections, `developer`
  and `min` rows added to the role table, `cloudEngineer` row corrected (SDK 8, not 7), `runner` row
  now says prerequisites. `docker-ce/README.md` rewritten for the new orchestrator.

- [x] **G12. `.gitattributes` added** (2026-09-11). Found while doing G9: the repo had none, and with
  `core.autocrlf=true` (this machine's setting) the `.sh` and `linux/systemd/` scripts check out
  CRLF on a Windows clone, so `bash ./install-docker-ce.sh` would fail with `$'\r': command not
  found`. Release zipballs were unaffected (they take the LF index content), so this only bit git
  clones. `*.sh` and the two namespace scripts are now pinned `eol=lf`.

- [x] **G13. `Install-Stax2AWS-CLI` removed** on request (2026-09-11), together with the
  `-installStax2AWS` switch and the `stax2aws` phase. A machine that was mid-reboot on the previous
  version with `-installStax2AWS` in its saved resume command would fail parameter binding on
  resume; re-run with `-force` in that (unlikely) case.

### Remaining

- [ ] **G7. Run it end to end on a throwaway VM.** Nothing here has executed on a real machine.
  Verified so far only by: parser checks on all `.ps1`, `bash -n` on both shell scripts, JSON
  validation, unit tests of the resume-command builder (including quote escaping), unit tests of
  the state machine (fresh/reload/single-element-collapse/old-schema/corrupt-file), and — after the
  move into `helper.ps1` — a two-run scratch test of the shared phase runner (deferred phase
  re-runs after the "reboot", failed phase is retried, gate exits 3010 with `-noReboot` and passes
  on the second run). **This is the only meaningful validation and is required before cutting a
  release.** Now covers three scripts:
  1. `.\config-workstation.ps1 -role mrl -resumeMethod None -noReboot` on a fresh VM; confirm exit
     3010 and the state file; reboot; re-run; confirm it finishes only `wsl-distro`.
  2. `.\docker-ce\config-docker.ps1 -resumeMethod None -noReboot` on that VM; confirm the Containers
     feature gate, then both `docker run hello-world` and `docker -c win run hello-world`.
  3. `.\config-github-runner.ps1 -resumeMethod None -noReboot` on a Windows Server VM; confirm the
     `docker` service starts after the reboot. Specifically confirm the assumption in G8 that
     dockerd needs the Containers feature to start.
  Then once more with the default `ScheduledTask` resume to see the task fire and remove itself.

  **Test VM (created 2026-09-11):** `vm-wstest-01` in resource group `S101-ARG-WSTEST-MRL`,
  subscription VS_Sub_MRL (`1f513fde-7a26-4aae-a69e-3f29f41d7f2a`), Australia East, Windows 11
  Enterprise 24H2, `Standard_D4s_v5`. RDP is allowed only from the home IP; auto-shutdown 14:00 UTC.
  A clean incremental snapshot `snap-vm-wstest-01-clean-20260911` was taken before any setup ran
  (stock image, pre-Windows-Update). Roll back between test passes by swapping the OS disk:
  ```powershell
  $sub='1f513fde-7a26-4aae-a69e-3f29f41d7f2a'; $rg='S101-ARG-WSTEST-MRL'; $vm='vm-wstest-01'
  $old = az vm show --subscription $sub -g $rg -n $vm --query storageProfile.osDisk.name -o tsv
  $new = "$vm-osdisk-$(Get-Date -Format yyyyMMddHHmm)"
  az vm deallocate --subscription $sub -g $rg -n $vm
  az disk create --subscription $sub -g $rg -n $new --source snap-vm-wstest-01-clean-20260911 --sku Premium_LRS
  # Pass the disk's full resource ID, and RUN THIS FROM POWERSHELL, not Git Bash. Under Git Bash,
  # MSYS rewrites the leading slash of `/subscriptions/...` into `C:/Program Files/Git/subscriptions/...`,
  # which surfaces as a confusing `KeyError: 'id'` from vm/custom.py or a LinkedInvalidPropertyId
  # naming a C:/Program Files/Git/... path. azure-cli itself is fine. (`MSYS_NO_PATHCONV=1` also
  # works if you must use bash.) The failure is quiet enough that a following `az vm start` happily
  # brings the VM up on the OLD disk - that happened twice on 2026-09-14 - so ALWAYS re-read
  # storageProfile.osDisk.name and confirm it BEFORE starting.
  $newId = az disk show --subscription $sub -g $rg -n $new --query id -o tsv
  az vm update --subscription $sub -g $rg -n $vm --os-disk $newId
  az vm start --subscription $sub -g $rg -n $vm
  az vm show --subscription $sub -g $rg -n $vm -d --query "{power:powerState,disk:storageProfile.osDisk.name}"
  # Keep the previous disk until the new run has passed, in case its evidence is still needed:
  # az disk delete --subscription $sub -g $rg -n $old --yes
  ```
  Tear everything down with `az group delete -n $rg --subscription $sub --yes --no-wait`.

  **Run 1 result (2026-09-11, role `mrl`, default `ScheduledTask` resume, driven by autologon +
  an at-logon task as `azureadmin`; transcript in `logs/vm-wstest-01-run1-20260911.log`, gitignored,
  plus the `vm-*.ps1` driver scripts).** The VM is left **deallocated** with autologon still set;
  the OS disk is dirty, so roll back to the snapshot before run 2.

  *What worked — the resume machinery is proven on a real machine:* `wsl-features` enabled both
  features and deferred; the gate registered `workstation-config-resume` for `WSTEST01\azureadmin`
  and rebooted; the task fired at logon, run 2 skipped the completed phases, `wsl --update` pulled
  Store WSL 2.7.13, `done` was recorded and the task removed itself. PSGallery installs
  (posh-git, PSReadLine, PSRule) ran with no prompt. Fonts installed. `Test-PendingReboot` correctly
  saw a reboot the fresh image already owed. Whole thing: 2 runs, 1 reboot, ~3.5 minutes.

  *What failed, and the fixes made (2026-09-12, awaiting run 2 to confirm):*
  - [x] **G15. `winget` is not on PATH for a freshly created user profile.** Both runs failed with
    "The term 'winget' is not recognized". `Microsoft.DesktopAppInstaller 1.26.509.0` *is* installed
    for all users, but `%LOCALAPPDATA%\Microsoft\WindowsApps` for `azureadmin` contained only
    `wsl.exe`/`wslconfig.exe` — the per-user app-execution aliases had not been created, even on
    run 2 after a reboot. Fix: in the `winget` phase, `Add-AppxPackage -RegisterByFamilyName
    -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe`, wait for `Get-Command winget` (bounded),
    and fall back to invoking `winget.exe` by full path from the package `InstallLocation`. Resolve
    once into a script-scoped variable and have `Install-WinGetPackage` use it. Because `winget`
    failed, **nothing** from the manifest was installed, which caused the next two cascades.
    *Done:* `Register-AppxForCurrentUser` / `Get-PackagedExePath` / `Get-WinGetPath` in helper.ps1;
    both `winget` phases and `Install-WinGetPackage` invoke `& (Get-WinGetPath)`, and the phase
    throws a clear message if winget still cannot be found after `Install-WinGet`.
  - [x] **G16. `shell` and `terminal` phases hard-fail when `winget` failed.** `pwsh.exe` and
    `wt.exe` were absent. Fix: check the dependency up front and throw a clear "depends on the
    winget phase" message; for `wt.exe` also try the `Microsoft.WindowsTerminal` package
    `InstallLocation` and `-RegisterByFamilyName`, since Windows Terminal is in-box on 24H2 yet its
    alias was missing too.
    *Done:* `shell` resolves `pwsh.exe` (PATH, then `%ProgramFiles%\PowerShell\7`) and throws a
    "depends on the winget phase" message; also guards `POSH_THEMES_PATH` being unset (the theme
    was headed for the drive root) and checks `git.exe` before `git config`. `terminal` uses
    `Get-WindowsTerminalPath` and waits up to 20 s for `settings.json` to appear.
  - [x] **G17. `wsl --install --help` is not a valid command on WSL 2.7.13** ("Invalid command line
    argument: --help"), so `Test-WslInstallSupportsFlag` always returned false, the launcher
    fallback found no `ubuntu*.exe`, and registration failed. Fix: feature-detect from `wsl --help`
    (which lists `--install ... --no-launch`), or simply attempt `--no-launch` and fall back on a
    non-zero exit.
    *Done:* detection reads `wsl --help` (verified locally on WSL 2.6.3: lists `--no-launch, -n`),
    and `Install-WslDistribution` trusts the registration list over `wsl.exe`'s exit code.
  - [x] **G18. A failed `Install-WslDistribution` was recorded as `wsl-distro` *complete*,** and
    more generally the run ended with "setup finished", `done` recorded and exit 0 despite four
    phase failures. Fix: throw from the phase when the distro is not registered; have
    `Invoke-SetupPhase` track failed phases; at the end, if any failed, do *not* record `done`,
    print the list, and exit 1 — but still clear the resume hooks so a broken phase cannot loop at
    every logon.
    *Done:* `wsl-distro` throws when either helper returns `$false`; `Invoke-SetupPhase` appends to
    `$failedPhases`; new `Complete-Setup` in helper.ps1 (used by all three scripts) always clears
    the resume hooks, records `done` and exits 0 only when nothing failed, otherwise lists the
    failures and exits 1. Unit-tested: failing run → exit 1, `done` absent; clean run → exit 0.
  - [x] Also seen: `Install-Fonts` leaked the `New-ItemProperty` object into the transcript. Piped
    to `Out-Null`.

  *Run 2 plan:* fix G15–G18, push to `main`, restore the snapshot (procedure above), start the VM,
  re-run `logs/vm-bootstrap.ps1` via `az vm run-command` (it re-downloads `main`), restart, poll
  with `logs/vm-poll.ps1`. Expect the winget phase to take 10–20 minutes this time.

  **Run 2 result (2026-09-12, from the clean snapshot, code at `337fb0c`, i.e. before the G19/G20
  cleanup).** G15, G16, G17 and G18 all confirmed fixed on the real machine:
  `winget` resolved at the user's alias path and installed the whole `mrl` manifest (~11 min);
  `fonts`, `psmodules`, `shell`, `terminal` all completed; the gate rebooted, the resume task fired
  and skipped the seven completed phases; `wsl --install --no-launch` registered **Ubuntu 26.04
  LTS** (`/etc/wsl-distribution.conf`: oobe via `/usr/lib/wsl/wsl-setup`, `defaultUid = 1000`,
  `systemd=true` already in its `/etc/wsl.conf`); and the one remaining failure was *reported* as a
  failure: "finished with 1 FAILED phase(s): wsl-distro", exit 1, `done` not recorded, resume task
  removed. Total: 2 runs, 1 reboot, ~15 minutes.
  - [x] **G21. `Initialize-WslUser` lost the backslashes in the script path.** `wslpath` reported
    `C:UsersazureadminAppDataLocalTempwsl-provision-user.sh`: `wsl.exe -- cmd args` goes through
    the distro's shell, which treats `\` as an escape. Reproduced locally (`wslpath -a
    'C:\Windows\win.ini'` fails; `'C:/Windows/win.ini'` works). Fixed by passing the path with
    forward slashes, checking the exit code, and logging wslpath's actual output instead of
    discarding stderr. Diagnosed via a scheduled task running as `azureadmin` (WSL refuses to run
    as SYSTEM, so `az vm run-command` cannot exercise it directly); `logs/vm-wsl-diag-launch2.ps1`
    is the driver.

  **Run 3a result (2026-09-12, code at `bc78b8c`, re-run on the run 2 machine without a snapshot
  restore, driven by `logs/vm-rerun.ps1`).** All seven completed phases skipped, `wsl-distro`
  completed in 10 s, `done` recorded, "finished" with no failures. The new `Write-Host` logging
  shows the helper diagnostics in the transcript for the first time ("Running provisioning script
  at /mnt/c/Users/azureadmin/..."). **End state verified on the machine, not just from the log:**
  - WSL: default user `azureadmin` (uid 1000, in `sudo`), `sudo -n true` exits 0, `systemctl
    is-system-running` = `running`, `/etc/wsl.conf` has `systemd=true` / `default=azureadmin` /
    interop on, sudoers drop-in present.
  - Windows, per-user: PowerShell 7 profile, `.gitconfig`, Oh My Posh theme, Windows Terminal
    `settings.json` (startingDirectory `c:\projects`, font CaskaydiaCove Nerd Font Mono), font file
    and registry entry, `c:\projects` created. Resume task and RunOnce entry both gone.
  - All 16 `mrl`+`min` winget ids report installed; `pwsh`, `git`, `oh-my-posh`, `wt`, `code`,
    `terraform`, `az` all on PATH. Modules posh-git 1.1.0, PSReadLine 2.4.5, PSRule 2.9.0.
  **G7 step 1 is therefore passed** for role `mrl` with the default `ScheduledTask` resume.
  Still owed: (a) one full run from the clean snapshot on the *current* code (`15fa7ae`+), because
  runs 2/3a executed the pre-cleanup winget parser and logging; (b) step 2, the Docker CE flow;
  (c) G11 can now be judged: systemd is running in the distro via `/etc/wsl.conf` alone.

  **Run 4 result (2026-09-13, from the clean snapshot, code at `d157cf0` = everything through
  G11/G14/G20/G21/G22). PASSED end to end with zero failed phases and zero unexpected warnings:**
  2 runs, 1 reboot, 13 minutes (05:39 → 05:52 UTC). This is the first run of the cleaned-up code:
  - winget by return code: 17 packages "installed or upgraded", Windows Terminal "already up to
    date", no not-found / mismatch / unknown-code lines. Bruno, Claude Code and Codex installed.
  - `Write-Host` logging: helper diagnostics visible in the transcript for the first time on a full
    run (pending-reboot source, each feature being enabled, the missing winget alias being
    registered, per-package outcomes).
  - Resume: gate → `ScheduledTask` → run 2 skipped 7 phases → `wsl-distro` in 68 s → `done`.
  - End state verified as in run 3a: WSL user `azureadmin` uid 1000 in `sudo`, `sudo -n true` OK,
    systemd `running`, wsl.conf correct; profile, `.gitconfig`, theme, terminal defaults, font,
    `c:\projects`, modules present; resume task and RunOnce gone; all tools on PATH.
  **(a) above is closed. Remaining for G7: (b) the Docker CE flow.** The VM is left in this
  post-run state, which is exactly the precondition `docker-ce/config-docker.ps1` needs.

  **Run 5 result (2026-09-14, G7 step 2, the Docker CE flow, code at `ea14a11`). The Linux half
  passed; `docker-windows` FAILED.** 2 runs, 1 reboot (01:29 → 01:32 UTC), state
  `docker-ce-state.json`, transcript `docker-ce-config-20260914T0132191606.log` on the VM.
  - *Worked:* `containers-feature` enabled Containers + `Microsoft-Hyper-V` and deferred; the gate
    registered `docker-ce-config-resume` and rebooted; the at-logon resume skipped the completed
    phases; `environment` set the three user variables; `docker-linux` installed docker-ce in
    Ubuntu, patched the unit file, and the daemon answered — *"Linux Docker daemon is up"* after
    ~10 s of the 12-attempt wait. `Complete-Setup` correctly refused to record `done`, reported
    `finished with 1 FAILED phase(s): docker-windows`, and still removed the resume task.
    **The reboot count stayed at 1 — the `Install-Feature` Hyper-V naming bug below did not loop.**
  - *Failed:* `Copy-Item daemon.json` → **"The directory name is invalid."** Three separate bugs,
    all now fixed in `install-docker-ce.ps1` but **not yet re-verified on the VM** (blocked on
    getting the patched file onto the box):
    - [x] **G23. `%ProgramData%\docker\config\` is never created, so `daemon.json` cannot be copied
      and the Windows daemon never gets its TCP endpoint.** `Install-Docker` started and stopped the
      service for 10 s purely so `dockerd` would create that directory. Docker **20.10.23 did;
      29.8.0 does not** — verified on the VM, where `dockerd` created 12 data subdirectories
      (`buildkit`, `containers`, `content`, `image`, `network`, `volumes`, `windowsfilter`, …) and
      no `config`. So the **G14 version bump reintroduced audit item 5's bug class**: a `Copy-Item`
      into a directory that does not exist yet. *Fixed:* `New-Item` the directory explicitly,
      `Copy-Item -Force`, and the start/sleep/stop dance deleted — it had no other purpose.
    - [x] **G24. `Install-Docker` corrupted the machine `Path`.**
      `SetEnvironmentVariable("Path", "$($env:path);C:\docker", Machine)` wrote the *process* Path —
      Machine and User already merged — back into the Machine scope. Confirmed on the VM: five of
      `azureadmin`'s private directories (`…\WindowsApps`, `…\Programs\Microsoft VS Code\bin`,
      `…\WinGet\Links`, `…\.dotnet\tools`, `…\PowerToys\DSCModules\`) ended up in the machine Path,
      where every other user on the box would inherit them. *Fixed:* read the Machine value, append
      `C:\docker` only if absent, write that back; update `$env:Path` separately.
      (`Update-EnvironmentPath`, which did this correctly, was deleted as runner-only under G19.)
    - [x] **G25. A part-failed Windows install looks complete on retry.** `Install-ContainerHost`
      gated the whole install on `if (Test-Docker)`, which only asks whether the *service exists*.
      The service is registered several steps before `daemon.json` and the `win` context, so after
      this failure a re-run would print "Docker is already installed", skip everything, and let
      `Invoke-SetupPhase` record `docker-windows` **complete** with no `daemon.json` and no `win`
      context — silently breaking the "re-running is always safe" premise the whole design rests on.
      *Fixed:* `Install-Docker` is called unconditionally and checks each piece of the end state
      separately (binaries, service, config dir, context).
  - *Still open, not hit this run:* `install-docker-ce.ps1`'s own legacy `Install-Feature` asks for
    the **ServerManager** name `Hyper-V` where the DISM name on a client SKU is `Microsoft-Hyper-V`
    (which `Enable-ContainerFeature` in `helper.ps1` gets right). On client it therefore falls into
    the `else` branch, logs "Feature Hyper-V is already enabled", and defers to
    `(Get-WindowsEdition -Online).RestartNeeded`. Harmless here because that was false, but if it
    ever returns true the phase exits 3010 on every run and the gate reboots forever. Now that
    `config-docker.ps1` owns the features via `Enable-ContainerFeature`, the whole `Install-Feature`
    function in the worker is redundant and should be deleted rather than fixed.
  **Run 5b result (2026-09-14, retry on the same disk with G23-G25 fixed, code at `42ad75d`).
  `docker-windows` passed and `done` was recorded — but the Linux daemon is unreachable from
  Windows, so G7 step 2 is NOT passed.** Runs 3, reboots 1.
  - *G23 verified:* `%ProgramData%\docker\config\daemon.json` is in place
    (`hosts: tcp://127.0.0.1:2378, npipe://`), the service is Running, port **2378 is open**, and
    **`docker -c win run hello-world` printed "Hello from Docker!"** (windows-amd64,
    nanoserver-ltsc2025). The Windows half of the feature works end to end for the first time.
  - *G25 verified:* the retry succeeded on a disk where the `docker` service was **already
    registered** from the failed attempt — the exact path that previously short-circuited to
    "Docker is already installed" and would have recorded a false success.
  - *G24 not exercised,* as predicted: `C:\docker` was already on that disk's machine Path, so the
    fixed write was skipped. Accepted on code review (user's call, 2026-09-14).
  - [x] **G26. Bare `docker` fails whenever the WSL distro is not running.** *(fixed, unverified)* The daemon and the
    plumbing are both correct — `ss -ltn` shows `LISTEN 127.0.0.1:2375`, systemd `running`, the
    `docker` unit `active`, `dockerd -H fd:// -H tcp://127.0.0.1:2375`, `azureadmin` in the `docker`
    group, and with the distro up Windows sees `127.0.0.1:2375 LISTENING` and connects fine.
    **The binding is not the problem** — an earlier reading of this finding blamed the
    `127.0.0.1` bind and proposed `0.0.0.0`; that was wrong, do not do it.
    The actual cause is lifecycle. `install-docker-ce.sh` ends with `sudo shutdown -r now`, and WSL2
    also stops an idle distro on its own. The relayed Windows port only exists while the distro is
    running, and **a Windows-side TCP connect to that port does not start the distro.** Evidence
    from the run-5b verify transcript: the script's header is stamped `02:10:33.52`, the Linux
    `docker run` failed immediately after with `connectex: ... actively refused it`, and `vmmem`
    started at `02:10:34` — the VM only came up when the script's *later* `wsl -- bash -lc` calls
    ran. A 02:23 probe that happened to run `wsl -- hostname -I` first then connected fine.
    So after any reboot, or after an idle timeout, `docker ps` fails until something has started
    the distro. Fix candidates: an at-logon `wsl -d Ubuntu -- /bin/true` (the repo already has task
    registration), or documenting the requirement. Do not change the bind address.
  - [x] **G27. The `docker-linux` readiness check cannot fail, so it gave a false pass.** *(fixed, unverified)* It runs
    `wsl --distribution Ubuntu -- docker version`, which is wrong twice over:
    1. it talks to the **unix socket inside the distro**, not the TCP endpoint the Windows client
       uses, so it says nothing about whether `DOCKER_HOST` works; and
    2. invoking `wsl` **starts the distro**, which is the very condition whose absence is the
       failure mode in G26 — the check creates the state it is supposed to be verifying.
    That is why the run logged "Linux Docker daemon is up", recorded `docker-linux` complete, and
    recorded `done` on an install where bare `docker` did not work. The check must ensure the distro
    is up and then verify from **Windows** with a TCP connect to `127.0.0.1:2375`, failing the phase
    if it does not answer. A check that cannot fail is not a check.
  - *Fixes for G26/G27, committed 2026-09-14:* a new `wsl-autostart` phase registers an at-logon
    task running `wsl -d <distro> -- /bin/true` (not `RunLevel Highest` — starting the distro needs
    no elevation and this fires at every logon), and `docker-linux` now verifies the endpoint the
    client actually uses via `Start-WslDistro`/`Test-TcpPort`: it brings the distro up, then TCP
    connects to `127.0.0.1:2375` **from Windows** and throws if it never answers. `Test-TcpPort`
    uses a raw `TcpClient` rather than `Test-NetConnection`, which warns on failure and is slower.
    The lifecycle experiment that proved all of this is worth keeping: terminate the distro =>
    `netstat` shows nothing on 2375 and bare `docker version` exits 1; `wsl -d Ubuntu -- /bin/true`
    => 2375 LISTENING within ~15 s and `docker run hello-world` exits 0.

  **RUN 7 (2026-09-14): the clean-snapshot end-to-end validation. PASSED.** Restored
  `snap-vm-wstest-01-clean-20260911` (disk `vm-wstest-01-osdisk-202609140303`; the previous disk
  was retained), reset `azureadmin` with `az vm user update`, armed autologon, and ran the real
  user journey. The bootstrap asserted the clean slate first rather than trusting the disk swap:
  docker service absent, no `C:\docker`, empty `%ProgramData%\workstation-setup`, no `C:\docker`
  on the machine Path, **0** leaked `azureadmin` Path entries.

  - `config-workstation.ps1 -role mrl`: **PASS**. 03:14 -> 03:29:57, 9 phases, 1 reboot, resume
    task fired and removed itself. Re-confirms run 4 against current `main`.
  - `config-docker.ps1` (no flags, as a user runs it): **PASS**. 6 phases, 1 reboot. The gate
    genuinely fired - `environment` is recorded *before* `containers-feature` because the latter
    deferred, which is the signature of a real deferral rather than a skip.
  - **G23 verified:** `%ProgramData%\docker\config\daemon.json` present with
    `{ hosts: [tcp://127.0.0.1:2378, npipe://] }`. The `New-Item` fix executed for the first time.
  - **G24 verified twice:** leaked `C:\Users\*` entries in the machine Path = **0**, against 5
    before the fix; re-checked at the end of all testing, still 0.
  - **G30's bounded wait verified:** run 7b threw at 04:27:46, exactly 30:00 after the phase
    started, left `docker-linux` un-recorded, withheld `done`, and reported *finished with 1
    FAILED phase(s)*. That is what turned an indefinite wedge into a retryable failure.
  - **G31 verified:** the retry that previously hung for 20 and 30 minutes completed in ~1 minute,
    and the phase-retry contract held - only the un-recorded `docker-linux` ran, the rest skipped.
  - **G26 verified after a real reboot, unassisted:** uptime 2:59, keepalive task
    `state=Running lastRun=05:11:52`, and **1 Windows listener on 2375 measured before anything
    touched WSL**. Measurement order was deliberate - every `wsl` call came last, because a probe
    that starts the distro manufactures its own pass (the G27 mistake).
  - **Linux daemon proven, not inferred:** `GET /version` -> `29.8.0 os=linux arch=amd64
    api=1.56`, `/_ping` -> OK, and a container created and started through the API reached
    `state=exited exitCode=0` with `Hello from Docker!` in its log.
  - **Windows daemon:** `docker -c win run hello-world` printed the banner.

  *Measurement artifact worth knowing:* native `docker` CLI **stdout comes back empty inside a
  non-interactive scheduled task**, even through `cmd /c ... > file`. It cost two false alarms
  here. `exit=0` alone is not evidence in that context - use the daemon's HTTP API. Proof the CLI
  was working all along: `hello-world:latest` at 25,874 bytes (the *Linux* image; the Windows one
  is ~482 MB) was present on the Linux daemon, pulled by exactly that 'silent' CLI run.
  Also: `Invoke-WebRequest` needs `-UseBasicParsing` under Windows PowerShell 5.1.

- [x] **G31. THE ACTUAL CAUSE of both `docker-linux` hangs: `gpg --dearmor -o` blocks on an
  overwrite prompt on every re-run** (found and fixed 2026-09-14, after G30 got it wrong).
  `curl -fsSL .../gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg`
  asks *"File exists. Overwrite? (y/N)"* when the keyring is already there, and its stdin is the
  curl pipe rather than a terminal, so it waits forever. Measured in Ubuntu WSL with gpg 2.4.9,
  with `timeout` making the answer unambiguous:
    - file absent (fresh install): `rc=0`, 2760 bytes written
    - file present, current command: **`rc=124`** - blocked, killed by timeout
      (`gpg: signal Terminated caught ... exiting`)
    - file present, with `--yes`: `rc=0`, and the keyring is still a valid OpenPGP key carrying
      Docker's fingerprint `9DC858229FC7DD38854AE2D88D81803C0EBFCD88`
  This single line accounts for every observation in both hangs: fresh installs pass, re-runs
  wedge, `apt term.log` shows no new activity, no dpkg/apt locks are held, and `dockerd`'s
  elapsed time matches `init`'s (so `systemctl restart docker`, the script's last line, never
  ran). *Fixed:* `gpg --yes --dearmor`, plus `export DEBIAN_FRONTEND=noninteractive` at the top
  of the script, since nothing in it may ever wait for input.

  **Correction to G30 below.** G30 claimed the final `sudo shutdown -r now` caused run 6's hang.
  That was inferred from the script sitting at what looked like its last line, with a process
  filter that matched `systemd` but not `systemctl`/`sudo`/`usermod` and so could not have shown
  the real child. It is wrong: run 7b hung identically with no `shutdown` in the script at all.
  Removing the reboot is still correct on its own merits - `systemctl daemon-reload` makes it
  redundant, and docker was demonstrably `active` and listening on 2375 without it - but it did
  **not** fix the hang. The part of G30 that genuinely helped was the 30-minute bounded wait,
  which is what turned an indefinite wedge into a clean retryable failure.

  **Hypotheses refuted along the way; do not retry them.**
    - Binding dockerd to `0.0.0.0` (G26 first draft). The `127.0.0.1` bind is correct; the
      endpoint was unreachable because the distro was not running.
    - `az vm update --os-disk` being broken in azure-cli 2.81.0. It was Git Bash: MSYS rewrote the
      leading `/` of the disk's resource ID into `C:/Program Files/Git/...`. Works from PowerShell.
    - The WSL localhost relay only capturing binds made while it is live. Restarting docker
      changed nothing; the relay was already up at baseline.

- [x] **G30. `install-docker-ce.sh`'s final `sudo shutdown -r now` hung the whole install, and
  `docker-linux` had no timeout to escape it** (found 2026-09-14 by run 6, the `-force` pass).
  The phase started at 02:34:08 and logged nothing for 20 minutes. Inside the distro:
  `552 Ss+ 1204 bash ./install-docker-ce.sh` still sitting there, `unattended-upgrade-shutdown
  --wait-for-signal` in the shutdown path, **no** apt or dpkg locks held, and `apt term.log`'s last
  entry from `01:32:05` — i.e. run 5's install, so apt had done nothing at all this time. systemd's
  shutdown simply never completed. It had completed on the first run and hung on the second, so the
  behaviour is **non-deterministic**, which is the worst kind of defect for an unattended installer.
  *The reboot was also unnecessary.* It predates audit item 3, which added `systemctl daemon-reload`
  — that already loads the patched unit. The decisive evidence: during the hang, `systemctl
  is-active docker` was `active` and `ss -ltn` showed `LISTEN 127.0.0.1:2375`, with the reboot never
  having completed. *Fixed:* the shell script now ends with `systemctl restart docker` plus an
  `is-active` echo. The only thing the distro restart also bought was making `usermod -aG docker`
  effective at once, which does not matter here — the Windows client reaches the daemon over TCP,
  and any new WSL session picks the group up anyway.
  *Fixed separately, and kept regardless:* `docker-linux` now runs the script through
  `Start-Process -PassThru` with a **30-minute bounded wait**, killing the launcher and throwing on
  timeout. A phase with no way to give up can wedge a hands-off build forever; apt is a network
  operation, so the timeout earns its place even with the shutdown gone. Two 5.1 traps verified
  locally while writing it: `WaitForExit([TimeSpan])` is .NET 5+ only, so the timeout must be passed
  as `[int]` milliseconds under Windows PowerShell 5.1; and `.ExitCode` on a
  `Start-Process -PassThru` object is **empty** unless `.Handle` is read first, even after
  `HasExited` is true.

- [x] **G28. `install-docker-ce.ps1` folded into `config-docker.ps1`** (2026-09-14, on request).
  Once feature enabling moved to the `containers-feature` phase, the worker's only reason to be a
  separate process — `exit 3010` to request a reboot — was unreachable: all three
  `$global:RebootRequired = $true` assignments lived in its own `Install-Feature`, which was itself
  redundant. **So the orchestrator's second `Invoke-RebootGate` was dead code and is gone too.**
  That also retires the latent bug recorded under run 5: `Install-Feature` asked for the
  ServerManager name `Hyper-V` where the client DISM name is `Microsoft-Hyper-V`, fell into its
  `else` branch, and deferred to `(Get-WindowsEdition -Online).RestartNeeded` — which, had it ever
  returned true, would have exited 3010 on every run and rebooted forever. Deleted rather than
  fixed, since `Enable-ContainerFeature` in `helper.ps1` already gets the names right.
  The Windows install is now `Install-WindowsDocker` plus `Test-DockerService` / `Test-TcpPort` in
  `config-docker.ps1`; phases are `containers-feature`, `environment`, gate, `docker-windows`,
  `docker-linux`, `wsl-autostart`.

- [x] **G29. `containers/`, `ce-corp` and `ce-free` removed** (2026-09-14, on request).
  `containers/install-containerd-runtime.ps1` was a Windows-Server-only containerd + nerdctl + CNI
  path unrelated to `docker-ce/`; `packages-ce-corp.json` and `packages-ce-free.json` only installed
  Visual Studio Professional / Community and predate the current flow. README, CLAUDE.md and the
  role table updated. Recoverable from git history.

  - *Test-VM state, left as the run ended:* the machine `Path` **still carries** the five leaked
    `azureadmin` entries (not yet cleaned), and the `C:\docker` binaries, the registered-but-stopped
    `docker` service and the 12 `dockerd` data directories are all present. Note that because
    `C:\docker` is already on the machine Path, a retry on this disk will **not** exercise G24's
    fixed write path — that one can only be verified from the clean snapshot.

- [x] **G11. `docker-ce/linux/systemd/` removed** (2026-09-13). Run 3a showed `systemctl
  is-system-running` = `running` in the freshly registered Ubuntu 26.04 with nothing but
  `/etc/wsl.conf` (`systemd=true`, which current Ubuntu images also ship by default). The four
  files (`ubuntu-wsl2-systemd-script.sh`, `start-systemd-namespace`, `enter-systemd-namespace`,
  README) and their `.gitattributes` lines are gone; CLAUDE.md and `docker-ce/README.md` updated.

- [x] **G14. Docker static binary bumped 20.10.23 → 29.8.0** (2026-09-13), the newest build in
  https://download.docker.com/win/static/stable/x86_64/ at the time (HEAD returned 200). Not yet
  exercised: the Docker CE flow (G7 step 2) is the first thing that will download it.
  (`Install-DockerEngine`'s 20.10.21 went away with G19.)

- [x] **G22. Small cleanup items** (2026-09-13): `.claude/settings.local.json` pruned to the
  generic allow-list (the stale Chocolatey greps and this session's one-off commands removed);
  `.gitattributes` trimmed to `*.sh` after G11. Typos and the `%` alias were already fixed in G20.

- [x] **G19. Runner script removed** (2026-09-12, on request: "we should remove config github run
  action"). Deleted `config-github-runner.ps1` and `packages-runner.json`, and with them the
  runner-only helpers `Install-DockerEngine` and `Update-EnvironmentPath`, plus the dead
  `New-WindowsTask` / `Remove-WindowsTask` pair (item 18 had kept them for a mechanism that no
  longer exists). `Enable-ContainerFeature` and `Install-WinGet` stay: the Docker CE orchestrator
  and the workstation winget fallback use them. G8 above is now historical. README and CLAUDE.md
  updated. Note this supersedes the G7 step 3 (runner VM test), which is no longer needed.

- [x] **G20. Code cleanup round 1** (2026-09-12, on request; items 1, 2, 3 and 5 of the list
  offered). **Includes a real bug fix:** `Write-SetupLog` used `Write-Information`, which
  `Start-Transcript` does *not* capture under Windows PowerShell 5.1 (verified locally: Output,
  Host and Warning are captured, Information is not; pwsh 7 captures all four). Every diagnostic
  line from the WSL/feature helpers was therefore missing from the run 1 transcript, which is why
  the `wsl-distro` failure had no detail. Now `Write-Host`, and *every* log line in the repo goes
  through it: the 92 `Write-Output "..." | timestamp` call sites were converted and the `timestamp`
  filter deleted, so the success-stream-contamination class of bug can no longer occur.
  Also: `Install-WinGetPackage` is one `winget install` call decided by return code
  (`Convert-WingetOutput` and the double `winget list` warm-up removed; installer "reboot required"
  codes now fold into the single reboot); `Update-SessionEnvironment` rewritten from ~95
  Chocolatey-derived lines to ~20 using `[Environment]::GetEnvironmentVariables`; `Install-WinGet`
  trimmed to the three `Add-AppxPackage` calls; `Register-AppxForCurrentUser` no longer waits two
  minutes for an alias of a package that is not on the machine; typos and the `%` alias fixed.
  **Manifests (same request):** Postman → `Bruno.Bruno` in mrl, mrldev, cloudEngineer, developer;
  `Anthropic.ClaudeCode` and `OpenAI.Codex` added to `packages-min.json` (so every role gets them)
  and the per-role ClaudeCode duplicates removed. IDs verified with `winget search`. The `Az`
  PowerShell module was dropped from `cloudEngineer` (no longer used; it was the last role with it).
  Return-code mapping verified locally: current package → `0x8A15002B`; a Store-installed
  PowerShell 7 against the MSI manifest → `0x8A15008E` (technology mismatch), now logged as
  "leaving the existing install alone" rather than a generic warning.
  Not yet run on the VM — run 2 was already in flight on the previous code; run 3 will exercise it.

---

## Checked and NOT a bug

- `-role min` leaves `$packageConfig` undefined, but the resulting `$null` is dropped by the
  `Select-Object` projection at `config-workstation.ps1:47`. No bogus package entry is produced.
- PowerShell 7 does include `C:\Program Files\WindowsPowerShell\Modules` on `$env:PSModulePath`
  (verified), so modules installed by the 5.1-hosted setup script are visible to the pwsh profile.
