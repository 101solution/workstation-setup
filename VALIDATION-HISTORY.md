# Validation History

Closed work for `workstation-setup`: the 2026-09-11 script audit (items 1-22) and the
unattended-setup goal (G1-G35), including the nine bugs that only a real machine exposed.
Split out of `TODO.md` on 2026-09-16 so the backlog shows only open work. **Item numbers are
unchanged** — `CLAUDE.md` cites G7, G23-G31 and G35 by number, and those references resolve here.

Live backlog: [`TODO.md`](TODO.md).

---

## Where this got to

**Where things stand.** Both entry points have **passed a clean end-to-end run on a fresh machine**
(run 7, 2026-09-14, from `snap-vm-wstest-01-clean-20260911`): `config-workstation.ps1 -role mrl`
in 9 phases and one reboot, then `config-docker.ps1` in 6 phases and one reboot, with the Windows
daemon printing the hello-world banner and the Linux daemon reporting `os=linux` on 2375 and running
a container to `exitCode=0`. Getting there took **nine bugs that only a real machine exposed**
(G23-G31); every one passed the parser, JSON and unit checks beforehand.

**Three releases followed.** `v2.4.0` (2026-09-14, commit `f977c29`) was the first, and the last
**breaking** one: `-role runner`, `-role ce-corp`, `-role ce-free`, `containers/` and
`-installStax2AWS` are all gone. `v2.5.0` (2026-09-16) carried the manifest refresh, and
**`v2.5.1` (2026-09-16, commit `1f38645`) is Latest** — the theme BOM fix (G38), the Server
prompt-speed fix (G37), the installer staging fix (G39) and the new shell/CLI tools. Each was
published as a GitHub *Release*, not just a tag: `get-latestPackages.ps1` queries `/releases` and
filters non-draft/non-prerelease, so a bare tag reaches nobody.

**Live gate: none.** G36 was closed by run 11, and G37/G38/G39 by runs 13/14 — one client and one
Server box, in parallel. Every commit on `main` has shipped in `v2.5.1`.

**Server 2025 is permanently in the matrix.** Run 12 was the first Server-SKU run ever and found
three real bugs immediately, one of which had been silently broken on every machine since the theme
copy was written. Validate on **one client and one Server** box from now on.

**The rig those runs used no longer exists.** Resource group `S101-ARG-WSTEST-MRL` was deleted on
2026-09-17 on request — `vm-wstest-01`, `vm-wstest-02`, both Premium OS disks, the network shell and
the clean snapshot `snap-vm-wstest-01-clean-20260911`. Every run recorded below was measured before
that, and the restore procedures they describe are history, not instructions. `TODO.md` has what to
rebuild.


**Next steps, in order.** Items 1-4 are all done; what remains is housekeeping and the open
items listed under "Remaining" further down.
1. ~~Run the Docker CE flow on the test VM (G7 step 2)~~ - **done: runs 5, 5b, 6, 7, 7b, 8.**
   G7 is closed.
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

---

Findings from an audit of the scripts on 2026-09-11, ordered by impact.
Each item records the failure, the file/line, and the intended fix.

**Status: 22 of 22 closed.** Line numbers below refer to the code *as audited*, before any fixes
were applied, so they will not match the current files. Three items were resolved differently from
the original finding — see the scope notes on items 18, 20 and 22 — and item 21's premise turned out
to be wrong. *(That original caveat - "nothing here has been executed on a real machine" - held
until 2026-09-13/14. It has since been executed: see G7 and run 7. Nine further bugs, G23-G31,
turned up only then.)*

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

## Goal: unattended completion with auto-resume (2026-09-11; validated on a real machine 2026-09-14)

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

### Closed items from "Remaining"

- [x] **RUNS 13 and 14 (2026-09-16): the `v2.5.1` gate, on both SKUs in parallel. PASSED.**
  Two VMs driven together: `vm-wstest-01` (Windows 11 Enterprise 24H2, account `azureadmin`,
  restored from the clean snapshot) and a purpose-built `vm-wstest-02` (**Windows Server 2025**,
  account **`test.user`** - deliberately dotted, so the Bruno fix was exercised rather than assumed).
  9 phases and one reboot each, ~19 and ~18 minutes. A second `-force` pass on both took ~6 minutes
  with `rebootCount` 0, correctly, because the WSL features were already enabled.

  | check | client | Server |
  |---|---|---|
  | oh-my-posh resolves to | MSIX package | standalone exe |
  | one invocation | 74 ms | **31 ms** (was 13,000 ms) |
  | theme first bytes | `7B 0D 0A` | `7B 0D 0A` |
  | theme **parses** | YES | YES |
  | profile load errors | 0 | 0 |
  | Bruno 4.1.0 | installed | **installed on a dotted account** |
  | winget warnings | **0** | **0** |

  G37's client early-return is what the left column proves: the client kept the winget-managed MSIX
  and downloaded nothing. G38 was checked by asking oh-my-posh to *parse* the theme
  (`print primary --config`), not by `Test-Path` - the omission that let the BOM ship. G39 is proven
  on the failure case rather than a passing one.

  The `-force` pass also covered the packages added the same day: zoxide, fzf, jq, Python 3.14 plus
  launcher, terraform-docs, the AWS Session Manager plugin and `powershell-yaml` all resolve on both
  machines, with no new winget warnings.

  **Two of my own probes were wrong before the product was.** A check for
  `...\Microsoft Visual Studio\2026` reported VS missing when it installs under `\18\`, and a check
  formatting `Get-Command z` via `Split-Path $_.Source` printed a blank for `z` because aliases have
  no `Source`. Both looked like product failures. Verify the probe before believing a negative.

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

- [x] **RUN 12 (2026-09-16): `v2.5.0` on Windows Server 2025, workstation + Docker. PASSED, with
  three bugs found.** The first time this repo had ever been run on a Server SKU; runs 1-11 were all
  Windows 10/11. Driven by the user on their own VM, not the test rig.
  - `config-workstation.ps1 -role mrl`: 9 phases, one reboot, 04:36:43Z to 04:52:13Z = **15.5 min**,
    within a minute of the client-SKU figure. Ubuntu registered (`wsl -l -v` shows VERSION 2,
    `Stopped`, which is correct - `--no-launch` means it is never started).
  - `docker-ce/config-docker.ps1`: 6 phases, one reboot, `done`. **Both daemons verified**:
    `docker run hello-world` and `docker -c win run hello-world`. This is the first exercise of the
    Server branch of `Enable-ContainerFeature`, which skips Hyper-V because Server can run
    process-isolated Windows containers.

  Three bugs surfaced, all now fixed on `main` and recorded as G38, G37 and G39:
  1. **The oh-my-posh theme had never been parsed, on any machine or SKU** - `Out-File -Encoding
     utf8` under Windows PowerShell 5.1 writes a BOM and oh-my-posh rejects it. Only visible here
     because fixing the Server prompt speed made the `CONFIG PARSE ERROR` legible.
  2. **MSIX oh-my-posh is unusable for a prompt on Server** - 13,000 ms per invocation against
     57-88 ms on Windows 11, because each activation spawns
     `Microsoft.DesktopAppInstaller!winget` first.
  3. **`Bruno.Bruno` 4.1.0 crashes when staged under a dotted username** - the 8.3 short name
     `CHUANH~1.SHE` breaks its NSIS `System.dll`; the same installer works from `C:\temp`.

  The lesson worth keeping: one run on a SKU nobody had tried found three real defects, one of which
  had been shipping silently since the theme copy was written. **Server 2025 belongs in the
  validation matrix permanently.**

- [x] **RUN 11 (2026-09-16): role `mrldev` on the new manifests. PASSED.** The run G36 asked for,
  from a fresh restore of `snap-vm-wstest-01-clean-20260911`, on `main` at `85aaf52`.
  9 phases, **one reboot**, `runCount` 2, `startedUtc` 02:23:27Z → `lastRunUtc` 02:56:34Z, so
  **33 minutes** including Visual Studio. Verified, not assumed:
  - **VS Enterprise 2026** at `C:\Program Files\Microsoft Visual Studio\18\Enterprise` with
    **both** workloads from the `override` present, confirmed via
    `vswhere -requires Microsoft.VisualStudio.Workload.Azure` and `...Workload.NetWeb`. Note the
    install path is by **major version (18)**, not by year - an intermediate check that looked for
    `...\Microsoft Visual Studio\2026` reported `False` and was simply measuring the wrong path.
  - `dotnet --list-sdks` = `10.0.401`.
  - In a real `azureadmin` pwsh session with the deployed profile: **0 profile load errors**, prompt
    renders 452 chars with 0 errors, theme file present, `$HOME` = `c:\projects`.
  - Completion via carapace: `git chec` → `check-attr`/`check-ignore`/`checkout`,
    `terraform pl` → `plan`, `gh pr ` → `checkout`/`checks`/`close`/`co`.
  - Both MSIX oh-my-posh fixes (`4795534`) confirmed: `PATH has pkg: True` and the package exe
    resolved, against 5 errors plus a modal App Installer dialog before the fix.

  **PowerShell 7 and oh-my-posh both install as MSIX packages here**
  (`Microsoft.PowerShell_7.6.6.0_x64`, `ohmyposh.cli_31.3.0.0_x64`), each reached through a 0-byte
  app-execution-alias stub with the real exe inside `C:\Program Files\WindowsApps\...`. Anything
  that launches them with `Process.Start` and `UseShellExecute=$false` must resolve the package
  folder first; the stub fails with "The file cannot be accessed by the system". That is the same
  trap as CLAUDE.md's "never call `winget` or `wt` bare", now known to cover `pwsh` and
  `oh-my-posh` too.

  Two driver faults cost ~35 minutes before this run started properly; both are recorded in
  `.claude/memory/vm-test-rig-credentials.md`.

- [x] **G32. Retire the test VM. DONE 2026-09-14.** Deallocated, and autologon plus the cleartext `DefaultPassword` removed from the registry (`AutoAdminLogon=0`, `DefaultPassword present=False`, `DefaultUserName` cleared) - the credential exposure is gone and compute cost is zero. All test scheduled tasks had self-unregistered; the product's own `docker-ce-wsl-autostart` keepalive was deliberately left in place. The clean snapshot `snap-vm-wstest-01-clean-20260911` and the current disk are retained so the next release can be validated the same way; reversible, nothing destroyed. **Two superseded OS disks remain unattached and are now pure cost** (`vm-wstest-01-osdisk-202609131329` from runs 5b/6, `...-202609140303` from run 7): delete with `az disk delete --subscription $sub -g $rg -n <name> --yes` once their evidence is definitely not wanted. **Both deleted 2026-09-16 on request**, verified unattached first and checked against the VM's live `storageProfile.osDisk.name` (`vm-wstest-01-osdisk-202609141511`, left alone); the clean snapshot `snap-vm-wstest-01-clean-20260911` was confirmed still present afterwards. Original state: left **running**
  after run 7, with autologon enabled and its password in the registry in clear text, plus a spare
  OS disk (`vm-wstest-01-osdisk-202609131329`) kept only so run-5b/6 evidence stayed inspectable.
  That evidence has served its purpose now the release is cut. Either
  `az vm deallocate --subscription $sub -g $rg -n $vm` to keep it for the next release, or
  `az group delete -n S101-ARG-WSTEST-MRL --subscription $sub --yes --no-wait` to remove it
  entirely. It costs ~AUD 0.35/h while running and auto-shuts-down at 14:00 UTC.

- [x] **G33. `docker run` output is invisible in the repo's own test harness. DONE 2026-09-14** - the guidance now lives in CLAUDE.md under \"Verifying on a real machine\", alongside the other measurement traps (probes that start what they measure, idempotency guards that check a proxy, the run-command output cap, MSYS mangling resource IDs, and parse-checking generated remote scripts). Original finding: native `docker` CLI
  stdout comes back empty inside a non-interactive scheduled task, even through
  `cmd /c ... > file`. It is only a *testing* problem - interactive users see output normally - but
  it produced two false alarms during run 7 and cost real time. If the VM harness is used again,
  verify the daemons through the HTTP API (`GET /version`, `/containers/{id}/logs`) rather than the
  CLI, and remember `Invoke-WebRequest` needs `-UseBasicParsing` on PowerShell 5.1.

- [x] **G35. The documented Quick Start leaves git with no identity. FIXED and VERIFIED 2026-09-14.** Found by run 9, which is
  the first test to take the *documented* path rather than passing parameters directly.
  `get-latestPackages.ps1` accepts and forwards **only** `-role`, and the shipped `.gitconfig` has
  no `[user] name`/`email`, so after the README one-liner `git config --global user.name` and
  `user.email` are both **empty** (measured on the VM). The user's first `git commit` then fails
  with *\"Please tell me who you are\"*. `config-workstation.ps1` has had `-gitUser`/`-gitEmail`
  all along - they are simply unreachable from the one-liner every user is told to run, and every
  previous VM run passed them explicitly, which is why this never showed up.
  *Fixed* in `get-latestPackages.ps1` (`51dd111`): both parameters added and forwarded when
  non-blank, built as an argument array so a name with spaces stays one argument. Because that
  file is fetched from raw `main`, **the fix is live without a new release**. Additive and
  backwards-compatible: argument construction unit-tested over five cases, including that the
  no-git-args call is byte-identical to before (6 elements) and that whitespace-only is ignored.
  *Verified on the VM:* `user.name`/`user.email` empty beforehand; un-recorded only the `shell`
  phase; ran the real one-liner with `-gitUser \"Ada Lovelace\" -gitEmail ada@example.com`; the
  bootstrap it fetched was the fixed one (2598 bytes, `$gitUser` present) and afterwards
  `user.name = [Ada Lovelace]`, `user.email = [ada@example.com]`. The transcript also confirms the
  phase contract: every other phase logged *already complete, skipping* and only `shell` ran.
  README's Quick Start now shows the variant with both parameters.

- [x] **RUN 9 (2026-09-14): the published v2.4.0 release validated end to end. PASSED.**
  Everything before this tested `main` via a bespoke driver; run 9 executed the README one-liner
  verbatim on a machine restored from the clean snapshot, so it is the first test of the actual
  distribution path - `get-latestPackages.ps1` fetched from raw `main`, the `/releases` lookup,
  the zipball, and the deploy into `c:\config\workstation`.
  - Bootstrap: downloaded (1774 bytes), resolved the release, extracted and renamed. Leftover
    sha folder = 0 and `workstation.zip` absent, which is what refuted the G34 claim.
  - `config-workstation.ps1 -role mrl`: 07:19:09 -> 07:32:34, ~13.5 min, 9 phases, 1 reboot,
    `resumeMethod=ScheduledTask`. The winget per-user alias fix (G15) fired as designed:
    *\"winget.exe alias missing for this user; registering...\"* then used the resolved path.
  - **Artifact identity confirmed:** no `.git` in `c:\config\workstation` (so it really is the
    zipball), 19 files, and the removals shipped - no `config-github-runner.ps1`, no `containers/`.
  - `docker-ce\config-docker.ps1` run from the deployed release tree: 6 phases, 1 reboot, `done`.
  - Both daemons verified through the HTTP API, not the CLI: `GET /version` ->
    `29.8.0 os=linux arch=amd64 api=1.56`, and a container pulled, created and started via the
    API reached `state=exited exitCode=0` with `Hello from Docker!` in its log. The keepalive was
    holding the distro at the time (1 listener on 2375).
  *Harness note:* `/containers/create` does **not** auto-pull - it 404s on a missing image. The
  earlier API test only worked because a CLI run had already cached the image. Pull explicitly via
  `POST /images/create?fromImage=...&tag=...` first.

- [x] **G7. Run it end to end on a throwaway VM. DONE 2026-09-13/14** (runs 1-8; run 4 closed the
  workstation half, run 7 the Docker CE half). Originally: nothing had executed on a real machine.
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
