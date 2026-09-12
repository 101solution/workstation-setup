# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Automates Windows workstation setup and Docker-without-Docker-Desktop configuration, driven by
role-based JSON package manifests installed via WinGet and PSGallery.

There is no build, lint, or test. Every change is validated by running the script as Administrator
on a real (preferably throwaway) Windows machine and reading the transcript log.

## Entry Points

| Script | Purpose |
|---|---|
| `config-workstation.ps1` | Main setup, phase-based and resumable. Params: `-role` (default `mrldev`), `-enableWSL` (default `$true`), `-gitUser`, `-gitEmail`, `-defaultWorkFolder` (default `c:\projects`), `-resumeMethod`, `-noReboot`, `-force`, `-taskName` |
| `get-latestPackages.ps1` | Bootstrap: downloads the latest non-draft GitHub release zipball into `c:\config`, renames it to `c:\config\workstation`, then runs `config-workstation.ps1 -role <role>` |
| `docker-ce/config-docker.ps1` | Docker without Docker Desktop: phase-based orchestrator of the Windows and WSL2 installs, own state file `docker-ce-state.json`. Sets its own working directory, so it can be run from anywhere |

```powershell
# all require Administrator PowerShell
powershell.exe -executionpolicy bypass -file .\config-workstation.ps1 -role mrldev
powershell.exe -executionpolicy bypass -file .\config-workstation.ps1 -role cloudEngineer -gitUser "Name" -gitEmail "e@x.com"
.\get-latestPackages.ps1 -role mrl     # fetch + run latest release
powershell.exe -executionpolicy bypass -file .\docker-ce\config-docker.ps1
```

## Unattended execution and reboot resume

Both config scripts are structured as named **phases**, run through `Invoke-SetupPhase` from
`helper.ps1`. Each completed phase is appended to a state file under
`%ProgramData%\workstation-setup\` — deliberately outside the repo, because `get-latestPackages.ps1`
re-downloading the release would otherwise wipe progress. Every phase is idempotent, so re-running
the same command is always safe and skips finished work. `-force` clears the state and redoes
everything.

Each script has its **own state file**, set by assigning `$script:SetupStateFileName` right after
dot-sourcing the helper (`setup-state.json`, `docker-ce-state.json`), so one script's progress can
never make the other skip work. The phase runner relies on the fact that a dot-sourced function's `$script:` scope *is*
the caller's: `Invoke-SetupPhase`, `Request-PhaseReboot` and `Invoke-RebootGate` read `$state`,
`$rebootPending` and `$rebootReason` from the calling script (verified with a scratch test).

**Phase order is load-bearing.** In `config-workstation.ps1`, `wsl-features` runs first and with
`-NoRestart`, then all the slow work (`winget`, `fonts`, `psmodules`, `shell`, `terminal`), then a
single reboot gate, then `wsl-distro`. The Docker CE orchestrator has `containers-feature` and
`environment` before the gate, `docker-windows` and `docker-linux` after it (dockerd cannot start
until the Containers feature is live). The point is that **at most one reboot ever happens**
and only what genuinely needs the restart is left on the far side of it. Don't reorder phases so that
something slow lands after the gate.

`-resumeMethod` picks how setup comes back:

| Value | Behaviour |
|---|---|
| `ScheduledTask` (default) | Logon-triggered elevated task. The only genuinely hands-off option. |
| `RunOnce` | HKLM `RunOnce` entry, no scheduled task, costs one UAC consent. Self-deleting. |
| `None` | Arms nothing; re-run the same command after the reboot to finish. |

The hard constraint behind that table: returning **elevated** after a reboot requires a scheduled
task, a service, or autologon with a stored password. `RunOnce` runs with the logon user's filtered
token, so it cannot satisfy `#Requires -RunAsAdministrator` on its own. `ScheduledTask` falls back
to `RunOnce` automatically if task registration is blocked by policy.

The resume task runs as **the invoking user, elevated — never as SYSTEM**. Setup writes per-user
artefacts (the PowerShell profile, `.gitconfig`, Windows Terminal settings, the Oh My Posh theme);
under SYSTEM those would land in `C:\Windows\System32\config\systemprofile`.

`-noReboot` records what is owed and exits **3010** instead of restarting, for image pipelines that
sequence their own reboots.

### Logging

**All logging goes through `Write-SetupLog`** (defined at the top of `helper.ps1`; it writes a
timestamped line with `Write-Host`). Never log with `Write-Output`, and never use
`Write-Information`. Two reasons, both learned the hard way:

- `Write-Output` writes to the success stream, so inside a function that returns a value the log
  lines *become part of the return value*: `return $false` after two log lines yields
  `@('msg','msg',$false)`, and `if (Fn)` on a non-empty array is `$true`. This once produced a
  latent infinite reboot loop in `Enable-WslFeature`. Sanity-check new value-returning functions
  with `@(Fn).Count -eq 1`.
- Under Windows PowerShell 5.1, which is what these scripts run under, `Start-Transcript` does
  **not** capture the Information stream (verified on 5.1.26100 and on the test VM). An earlier
  `Write-SetupLog` used `Write-Information`, and every diagnostic line from the WSL and feature
  helpers was silently missing from the run 1 transcript. `Write-Host` is captured.

Because the config scripts log nothing before dot-sourcing `helper.ps1`, `Write-SetupLog` is
always defined by the time it is called. Keep it that way.

### Making WSL unattended

A plain `wsl --install -d Ubuntu` launches the distro, whose first-run OOBE blocks on a UNIX
username and password — fatal for an unattended build. `Install-WslDistribution` uses `--no-launch`
where the installed `wsl.exe` supports it (feature-detected at runtime from `wsl --install --help`,
since the inbox stub and the Store build expose different flags) and falls back to the per-distro
launcher's `install --root`. `Initialize-WslUser` then creates the user entirely from the Windows
side via `wsl --user root`, giving it **passwordless sudo** (the repo's Docker CE scripts are full
of unattended `sudo` calls) and writing `/etc/wsl.conf` with `systemd=true` (required by
`docker-ce/linux/install-docker-ce.sh`, which drives `systemctl`).

## Role Manifests

`packages-<role>.json`. Current schema — note the key names changed during the WinGet migration:

```json
{
  "winget": [ { "id": "Publisher.Package", "source": "winget", "override": "<raw installer flags>" } ],
  "powershellModule": [ { "name": "ModuleName" } ]
}
```

- **`packages-min.json` is always merged as the base layer**, unioned with the role file and de-duped
  on `id`/`source`/`override`. The one exception is `-role min`, where the base is used alone.
- Roles: `mrldev` (default), `mrl`, `cloudEngineer`, `developer`, `ce-corp`, `ce-free`, `min`.
  (`runner` and `config-github-runner.ps1` were removed on 2026-09-12; runner boxes are out of scope.)
- `override` is forwarded to `winget install --override`, so its contents are the *underlying
  installer's* flag syntax, not WinGet's — e.g. VS Enterprise's `--add Microsoft.VisualStudio.Workload.*`
  or VS Code's `/mergetasks=addcontextmenufiles,...`.
- **Chocolatey is gone**, and as of the 2026-09 cleanup no trace of it remains in the repo.
  Don't add choco packages; WinGet or PSGallery only.

## helper.ps1

Dot-sourced by both config scripts. The obsolete Chocolatey and offline-WinGet helpers were removed
in the 2026-09 cleanup; `Install-Stax2AWS-CLI`, the runner-only `Install-DockerEngine` /
`Update-EnvironmentPath`, and the long-dead `New-/Remove-WindowsTask` pair were removed on request
the same month. Everything left is reachable.

Called: `Install-WinGetPackage`, `Install-PSModule`, `Install-Fonts`, `Update-SessionEnvironment`,
`Format-Json` (pretty-prints Windows Terminal settings), and `Install-WinGet` (fallback when winget
cannot be resolved at all). **Never call `winget` or `wt` bare**: on a
freshly created user profile the machine-wide Store package exists but the per-user alias in
`%LOCALAPPDATA%\Microsoft\WindowsApps` does not (seen on the Azure Win11 24H2 image, even after a
reboot), so `Get-WinGetPath` / `Get-WindowsTerminalPath` resolve the executable, registering the
package for the user via `Add-AppxPackage -RegisterByFamilyName` when needed. The unattended
machinery lives in two regions at the bottom: state (`Get-/Save-/Clear-SetupState`,
`Complete-Phase`), the phase runner (`Invoke-SetupPhase`, `Request-PhaseReboot`,
`Invoke-RebootGate`, `Complete-Setup` — which records `done` and exits 0 only if no phase threw,
otherwise exits 1 but still clears the resume hooks), resume (`Get-ResumeCommand`,
`Register-ResumeTask`, `Register-ResumeRunOnce`, `Request-Reboot`, `Clear-ResumeHooks`), features
(`Enable-WindowsFeatureSet`, `Enable-WslFeature`, `Enable-ContainerFeature`, `Test-WindowsClientSku`)
and WSL provisioning (`Install-WslDistribution`, `Initialize-WslUser`).

Every reboot continuation goes through `Request-Reboot` (`Register-ResumeTask`, running as the
invoking user). The old `ContainerBootstrap` task name survives in `docker-ce/install-docker-ce.ps1`
only so a stale task from an earlier version gets unregistered.

`Install-WinGetPackage` is a single `winget install` call whose outcome is read from winget's
documented **return codes**, not its text: `0` installed/upgraded, `0x8A15002B` / `0x8A150061` /
`0x8A15010D` already current, `0x8A150014` id not found in the source (warning), and
`0x8A150109` / `0x8A15010A` installer needs a restart, which is folded into the single reboot via
`Request-PhaseReboot`. `winget install` upgrades an installed package itself when the source has a
newer version, so the former `winget list` → column parser → install-or-upgrade dance
(`Convert-WingetOutput`, removed 2026-09-12) is gone. Don't reintroduce output parsing.

## Files Copied Onto the Machine

The second half of `config-workstation.ps1` is a series of copies, each with a transform that must
be preserved when editing the source file:

- `profile.ps1` → `$PROFILE.CurrentUserAllHosts` with `WindowsPowerShell` rewritten to `Powershell`
  — i.e. the PowerShell 7 profile only, never 5.1. Copied with the same `#workFolder#` token
  substitution as the theme, because `profile.ps1` force-overrides `$HOME` and the FileSystem
  provider home to the work folder. Keep that token if you edit the profile.
- `rudolfs-light-cs.omp.json` → `$env:POSH_THEMES_PATH`, with the literal token `#workFolder#`
  substituted for `-defaultWorkFolder`. Keep that token if you edit the theme.
- `terminal-default-settings.json` → merged into Windows Terminal's `settings.json` as
  `profiles.defaults`, with `startingDirectory` overwritten by `-defaultWorkFolder`. If
  `settings.json` doesn't exist yet, the script launches and kills `wt.exe` to force its creation.
- `.gitconfig` → `$env:UserProfile`, then `-gitUser`/`-gitEmail` applied via `git config --global`.
- `CaskaydiaCoveNerdFontMono-Regular.ttf` → `C:\Windows\Fonts` plus a font registry entry. The
  terminal font in `terminal-default-settings.json` depends on this.

Transcript logs go to `$PSScriptRoot\logs\` (gitignored), renamed on exit to
`workstation-config-<FileDateTime>.log` by `config-workstation.ps1` and
`docker-ce-config-<FileDateTime>.log` by `docker-ce/config-docker.ps1`.

## Docker CE (`docker-ce/`)

`docker-ce/config-docker.ps1` is the orchestrator, phase-based like the workstation script: it
enables the Containers feature (plus Hyper-V on client SKUs) with `-NoRestart`, sets the user-scope
env vars, passes the single reboot gate, then runs `./install-docker-ce.ps1` for Windows and
`wsl -d Ubuntu -- bash ./install-docker-ce.sh` for Ubuntu. `install-docker-ce.ps1` is a worker that
never restarts the machine itself: exit 0 success, 3010 a feature still needs a restart (the
orchestrator then runs its gate again), 1 failure. Two daemons run side by side on distinct ports,
by design:

- **Linux (WSL2) daemon on `tcp://127.0.0.1:2375`** — patched into `/etc/systemd/system/docker.service` by `sed`.
- **Windows daemon on `tcp://127.0.0.1:2378`** — via `daemon.json` (TCP + `npipe://`).
- User-scope `DOCKER_HOST` points at 2375, so bare `docker` targets Linux; a `win` context is created
  for 2378, so `docker -c win` targets Windows. Verify both:
  `docker run hello-world` and `docker -c win run hello-world`.
- `WSLENV`/`BASH_ENV` are set so the Windows-side `DOCKER_HOST` propagates into WSL.
- `install-docker-ce.sh` ends in `sudo shutdown -r now`, restarting WSL. That kills the `wsl.exe`
  session, so its exit code is meaningless; the `docker-linux` phase instead polls
  `wsl -- docker version` and throws (so the phase is retried) if the daemon never answers. The
  script is therefore written to be re-runnable: the `sed` that adds `-H tcp://127.0.0.1:2375` is
  guarded by a `grep`, otherwise a second run would append a duplicate `-H`.
- `.gitattributes` pins `*.sh` and the two `linux/systemd/` scripts to LF. Without it a Windows clone
  with `core.autocrlf=true` checks them out CRLF and bash fails on every line.
- `docker-ce/linux/systemd/` is the older way of enabling systemd inside WSL2. `Initialize-WslUser`
  now writes `systemd=true` to `/etc/wsl.conf`, so it is probably redundant (TODO G11).

`docker-ce/install-docker-ce.ps1` resolves `$global:ScriptFolder` from `$PSScriptRoot`, so the
`daemon.json` copy works from a git clone as well as from a `get-latestPackages.ps1` deploy. (It was
previously hardcoded to `c:\config\workstation\docker-ce`.)

## containers/

`install-containerd-runtime.ps1` installs containerd + nerdctl + Windows CNI. **Windows Server only**
(per `containers/readme.md`) — unrelated to and independent of the `docker-ce/` path.

## Distribution

Users bootstrap from the **latest GitHub release**, not from `main`:

```powershell
Invoke-RestMethod -Uri "https://raw.githubusercontent.com/101solution/workstation-setup/main/get-latestPackages.ps1" -OutFile "$env:temp\get-latestPackages.ps1"; powershell.exe -executionpolicy bypass -file $env:temp\get-latestPackages.ps1 -role mrldev
```

So a manifest or script change reaches nobody until a new release tag (`v2.x.y`) is cut.
`get-latestPackages.ps1` is the one exception — it's fetched from raw `main`, so edits to it take
effect immediately.

The README's role table is hand-maintained; update it when adding a role or materially changing a manifest.
