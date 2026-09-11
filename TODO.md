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
  would silently stop installing WSL for every caller that omits the flag.

---

## Goal: unattended completion with auto-resume (2026-09-11, in progress)

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

### Remaining

- [ ] **G7. Run it end to end on a throwaway VM.** Nothing here has executed on a real machine.
  Verified so far only by: parser checks on all `.ps1`, `bash -n` on both shell scripts, JSON
  validation, unit tests of the resume-command builder (including quote escaping), and unit tests
  of the state machine (fresh/reload/single-element-collapse/old-schema/corrupt-file). **This is
  the only meaningful validation and is required before cutting a release.** Suggested first pass:
  `.\config-workstation.ps1 -role mrl -resumeMethod None -noReboot` on a fresh VM, confirm exit
  3010 and the state file, reboot, re-run, confirm it finishes only `wsl-distro`.

- [ ] **G8. `config-github-runner.ps1` is not resumable.** It has its own flow and installs Docker
  Engine; it should either share the phase/resume machinery or document that it is not unattended.

- [ ] **G9. Unify the Docker CE reboot path.** `docker-ce/install-docker-ce.ps1` still uses its own
  `ContainerBootstrap` at-logon task rather than `Request-Reboot`/`-resumeMethod`.

- [ ] **G10. Update README.md** with `-resumeMethod`, `-noReboot`, `-force` and the unattended
  behaviour. Currently only documents `-role`.

- [ ] **G11. Confirm whether `docker-ce/linux/systemd/` is now redundant.** `Initialize-WslUser`
  writes `systemd=true` to `/etc/wsl.conf`, which is the modern supported way; the older hack is
  still in the repo. Verify on a real WSL2 install before removing anything.

---

## Checked and NOT a bug

- `-role min` leaves `$packageConfig` undefined, but the resulting `$null` is dropped by the
  `Select-Object` projection at `config-workstation.ps1:47`. No bogus package entry is produced.
- PowerShell 7 does include `C:\Program Files\WindowsPowerShell\Modules` on `$env:PSModulePath`
  (verified), so modules installed by the 5.1-hosted setup script are visible to the pwsh profile.
