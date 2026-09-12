# Repo Fix Backlog

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
  az vm update --subscription $sub -g $rg -n $vm --os-disk $new
  az vm start --subscription $sub -g $rg -n $vm
  az disk delete --subscription $sub -g $rg -n $old --yes   # once the VM is confirmed up
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

- [ ] **G11. Confirm whether `docker-ce/linux/systemd/` is now redundant.** `Initialize-WslUser`
  writes `systemd=true` to `/etc/wsl.conf`, which is the modern supported way; the older hack is
  still in the repo. Verify on a real WSL2 install before removing anything.

- [ ] **G14. Docker static binary version is stale.** `install-docker-ce.ps1` pins 20.10.23, from
  2023 and out of support. Bump to a current release from
  https://download.docker.com/win/static/stable/x86_64/ once G7 has proven the flow works at all.
  (`Install-DockerEngine`'s 20.10.21 went away with G19.)

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
