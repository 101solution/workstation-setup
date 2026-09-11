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
| `config-workstation.ps1` | Main setup, phase-based and resumable. Params: `-role` (default `mrldev`), `-enableWSL` (default `$true`), `-installStax2AWS` (switch), `-gitUser`, `-gitEmail`, `-defaultWorkFolder` (default `c:\projects`), `-resumeMethod`, `-noReboot`, `-force`, `-taskName` |
| `config-github-runner.ps1` | Runner box. `-role` default `runner`. Does **not** merge `packages-min.json`, and additionally installs Docker Engine to `$env:UserProfile\tools` |
| `get-latestPackages.ps1` | Bootstrap: downloads the latest non-draft GitHub release zipball into `c:\config`, renames it to `c:\config\workstation`, then runs `config-workstation.ps1 -role <role>` |
| `docker-ce/config-docker.ps1` | Docker without Docker Desktop: orchestrates the Windows and WSL2 installs. Run it from inside `docker-ce/` |

```powershell
# all require Administrator PowerShell
powershell.exe -executionpolicy bypass -file .\config-workstation.ps1 -role mrldev
powershell.exe -executionpolicy bypass -file .\config-workstation.ps1 -role cloudEngineer -gitUser "Name" -gitEmail "e@x.com"
.\get-latestPackages.ps1 -role mrl     # fetch + run latest release
cd docker-ce; powershell.exe -executionpolicy bypass -file .\config-docker.ps1
```

## Unattended execution and reboot resume

`config-workstation.ps1` is structured as named **phases**. Each completed phase is appended to
`%ProgramData%\workstation-setup\setup-state.json` — deliberately outside the repo, because
`get-latestPackages.ps1` re-downloading the release would otherwise wipe progress. Every phase is
idempotent, so re-running the same command is always safe and skips finished work. `-force` clears
the state and redoes everything.

**Phase order is load-bearing.** `wsl-features` runs first and with `-NoRestart`, then all the slow
work (`winget`, `fonts`, `psmodules`, `stax2aws`, `shell`, `terminal`), then a single reboot gate,
then `wsl-distro`. The point is that **at most one reboot ever happens** and only WSL distro
registration is left on the far side of it. Don't reorder phases so that something slow lands after
the gate.

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

### Logging inside value-returning functions

This repo's logging idiom is `Write-Output "..." | timestamp`, which writes to the **success
stream**. Inside a function that also returns a value, those log lines *become part of the return
value*: `return $false` after two log lines yields `@('msg','msg',$false)`, and `if (Fn)` on a
non-empty array is `$true`. This already caused a latent infinite reboot loop in
`Enable-WslFeature`. Functions whose return value is tested therefore log via **`Write-SetupLog`**
(information stream, still captured by `Start-Transcript`). If you add a function that returns a
value, use `Write-SetupLog`, and sanity-check with `@(Fn).Count -eq 1`.

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
- Roles: `mrldev` (default), `mrl`, `cloudEngineer`, `developer`, `runner`, `ce-corp`, `ce-free`, `min`.
  The README's role table omits `developer` and `min`.
- `override` is forwarded to `winget install --override`, so its contents are the *underlying
  installer's* flag syntax, not WinGet's — e.g. VS Enterprise's `--add Microsoft.VisualStudio.Workload.*`
  or VS Code's `/mergetasks=addcontextmenufiles,...`.
- **Chocolatey is gone**, and as of the 2026-09 cleanup no trace of it remains in the repo.
  Don't add choco packages; WinGet or PSGallery only.

## helper.ps1

Dot-sourced by both config scripts. The obsolete Chocolatey and offline-WinGet helpers were removed
in the 2026-09 cleanup, so what remains is reachable with one exception noted below.

Called: `Install-WinGetPackage`, `Install-PSModule`, `Install-Fonts`, `Update-SessionEnvironment`,
`Format-Json` (pretty-prints Windows Terminal settings), `Install-Stax2AWS-CLI`, plus `Install-WinGet`
and `Install-DockerEngine` (runner script only).

`New-WindowsTask` is the exception: it is currently unreferenced because the post-reboot
continuation calls in both config scripts are commented out. It is kept deliberately — it pairs
with `Remove-WindowsTask`, which still fires whenever `-taskName` is passed. The only *live* reboot
continuation is the `ContainerBootstrap` at-logon task in `docker-ce/install-docker-ce.ps1`.

`Install-WinGetPackage` decides install-vs-upgrade by parsing `winget list` column output through
`Convert-WingetOutput`. That parser locates the header and data rows by content rather than by fixed
line index, but it still slices columns by character offset, so it remains sensitive to a localised
or reformatted header. It deliberately calls `winget list` twice — the first invocation on a cold
machine returns nothing usable.

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
`gh-runner-config-<FileDateTime>.log` by `config-github-runner.ps1`.

## Docker CE (`docker-ce/`)

`docker-ce/config-docker.ps1` is the orchestrator: it sets env vars, runs `./install-docker-ce.ps1`
for Windows, then `wsl -- ./install-docker-ce.sh` for Ubuntu. Two daemons run side by side on
distinct ports, by design:

- **Linux (WSL2) daemon on `tcp://127.0.0.1:2375`** — patched into `/etc/systemd/system/docker.service` by `sed`.
- **Windows daemon on `tcp://127.0.0.1:2378`** — via `daemon.json` (TCP + `npipe://`).
- User-scope `DOCKER_HOST` points at 2375, so bare `docker` targets Linux; a `win` context is created
  for 2378, so `docker -c win` targets Windows. Verify both:
  `docker run hello-world` and `docker -c win run hello-world`.
- `WSLENV`/`BASH_ENV` are set so the Windows-side `DOCKER_HOST` propagates into WSL.
- `install-docker-ce.sh` ends in `sudo shutdown now -r`, restarting WSL.
- `docker-ce/linux/systemd/` enables systemd inside WSL2 — a prerequisite, since the Linux installer
  uses `systemctl`.

`docker-ce/install-docker-ce.ps1` resolves `$global:ScriptFolder` from `$PSScriptRoot`, so the
`daemon.json` copy and the `ContainerBootstrap` reboot-continuation task both work from a git clone
as well as from a `get-latestPackages.ps1` deploy. (It was previously hardcoded to
`c:\config\workstation\docker-ce`.)

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
