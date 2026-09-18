# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Automates Windows workstation setup and Docker-without-Docker-Desktop configuration, driven by
role-based JSON package manifests installed via WinGet and PSGallery.

There is no build, lint, or test. Every change is validated by running the script as Administrator
on a real (preferably throwaway) Windows machine and reading the transcript log. `TODO.md` holds
open work; `VALIDATION-HISTORY.md` is the record of what has and has not been validated that way.
As of **2026-09-14 (run 7)** both entry points have passed end to end from a clean Azure Windows 11 Enterprise 24H2
snapshot: `config-workstation.ps1 -role mrl` in 9 phases and one reboot, then
`docker-ce/config-docker.ps1` in 6 phases and one reboot, with both daemons verified. Run 12
(2026-09-16) repeated both flows on **Windows Server 2025**, and runs 13/14 validated `v2.5.1` on
one client and one Server box in parallel. Run 16 (2026-09-18) validated the published `v2.5.2` on
both SKUs, upgrading from an already-provisioned state rather than from clean. **Validate on both
SKUs from now on** — the first Server run ever found three real bugs, one of which (G38) had been
silently broken on every machine since the theme copy was written. **The throwaway rig was
decommissioned again on 2026-09-18** — resource group, both VMs and both clean snapshots — so
validating the next release starts by rebuilding it from stock images; `TODO.md` says how, and the
`az vm run-command` driver scripts and run history are under G7 in `VALIDATION-HISTORY.md`. **Treat that history as the main lesson of this repo: nine bugs
(G23-G31) were found only by running it on a real machine, and every one of them had already
passed the parser, JSON and unit checks.** Two of the worst were not install logic at all - one let a part-failed install record
success on retry, and one was a readiness check that started the very distro it was checking, so it
could never fail. Static checks here tell you a change is syntactically sound, nothing more. Cheap local checks that are worth running before any push: parse
every `.ps1` with `[System.Management.Automation.Language.Parser]::ParseFile`, `bash -n` the shell
scripts, and `ConvertFrom-Json` every manifest. Two things about that parse check, both of which
have produced false results here:
- **Run it under pwsh 7, not 5.1.** Windows PowerShell reads a BOM-less UTF-8 file as ANSI, so a
  single non-ASCII character (an em dash was enough) produces a phantom
  *"The string is missing the terminator"* in a file that is perfectly valid.
- **Print the number of files parsed.** A filter typo once excluded every file, so the check
  reported a clean pass having parsed nothing. A pass with no count is indistinguishable from
  a pass over an empty set.

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

**A new release redoes every phase, because skipping is otherwise indistinguishable from working.**
The state file records the release tag under `setupVersion`; `get-latestPackages.ps1` forwards the
tag it downloaded as `-setupVersion`, and when that differs from the recorded one
`config-workstation.ps1` empties `completedPhases` before the first phase runs. Without this the
documented one-liner could never upgrade an existing machine: a second run found `done`, skipped all
nine phases in about a second, and printed a success banner having installed nothing — which is how
`v2.5.1` failed to reach a box on 2026-09-17. Three details are load-bearing:
- **Only the bootstrap knows the version.** A run from a git clone passes nothing, leaves
  `$setupVersion` empty and keeps plain resume behaviour, which is what a maintainer re-running one
  phase wants. Don't "fix" this by adding a checked-in VERSION file — it needs a manual bump at
  release time and will silently rot, exactly like the tag-without-a-release trap below.
- **The forwarding is guarded, and the guard is not optional.** `get-latestPackages.ps1` is served
  from raw `main` but runs `config-workstation.ps1` *from the latest release*, so the two are
  routinely different versions. `config-workstation.ps1` has `[CmdletBinding()]`, which makes an
  unrecognised named parameter a hard `NamedParameterNotFound` error that aborts **before the first
  line of the body**. Passing `-setupVersion` unconditionally would have broken the documented
  one-liner for every user the moment the edit was pushed. It is therefore gated on
  `(Get-Command $script).Parameters.ContainsKey('setupVersion')`. **Any new parameter forwarded from
  that file needs the same treatment.**
- **An unrecorded version counts as different.** Every state file written before 2026-09-17 has no
  `setupVersion`, so the first release after this change must redo those machines, not skip them.
  `Get-SetupState`'s shape-normalisation loop adds the field to an old file automatically.
- **`completedPhases` is emptied in memory, not by deleting the state file**, so `runCount` and
  `rebootCount` survive as an audit trail. On an unattended box the state file is the only record.

Each script has its **own state file**, set by assigning `$script:SetupStateFileName` right after
dot-sourcing the helper (`setup-state.json`, `docker-ce-state.json`), so one script's progress can
never make the other skip work. The phase runner relies on the fact that a dot-sourced function's `$script:` scope *is*
the caller's: `Invoke-SetupPhase`, `Request-PhaseReboot` and `Invoke-RebootGate` read `$state`,
`$rebootPending` and `$rebootReason` from the calling script (verified with a scratch test).

**Phase order is load-bearing.** In `config-workstation.ps1`, `wsl-features` runs first and with
`-NoRestart`, then all the slow work (`winget`, `fonts`, `psmodules`, `longpaths`, `shell`, `terminal`), then a
single reboot gate, then `wsl-distro`. The Docker CE orchestrator has `containers-feature` and
`environment` before the gate, then `docker-windows`, `docker-linux` and `wsl-autostart` after it
(dockerd cannot start until the Containers feature is live). The point is that **at most one reboot ever happens**
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
where the installed `wsl.exe` supports it (feature-detected at runtime from `wsl --help`, since the
inbox stub and the Store build expose different flags; note `wsl --install --help` is *rejected* by
Store WSL 2.7, which is what silently broke this on the test VM) and falls back to the per-distro
launcher's `install --root`. `Initialize-WslUser` then creates the user entirely from the Windows
side via `wsl --user root`, giving it **passwordless sudo** (the repo's Docker CE scripts are full
of unattended `sudo` calls) and writing `/etc/wsl.conf` with `systemd=true` (required by
`docker-ce/linux/install-docker-ce.sh`, which drives `systemctl`).

## Verifying on a real machine

`TODO.md` holds the VM details and the open validation gate; `VALIDATION-HISTORY.md` holds the run
history and uses the G-numbers cited throughout this file. What matters here is *how to measure*,
because nine bugs (G23-G31) plus G35 were found only by running this on real hardware, and several
were initially missed by checks that could not fail:

- **A probe must not create the state it is checking.** The original `docker-linux` readiness
  check ran `wsl -- docker version`, which *starts the distro* - so it passed on a machine where
  bare `docker` was broken (G27). Anything that measures WSL must use `wsl -l -v`,
  `wsl -l --running` or `netstat`, none of which start a distro, and must run **before** anything
  that does.
- **Check that the consumer accepted the artefact, not that the artefact exists.** Run 11 verified
  the oh-my-posh theme file was present and concluded the theme worked. It did not: every deployed
  theme since the beginning carried a UTF-8 BOM and oh-my-posh refused to parse it. `Test-Path` on
  a file another program has to read proves nothing - run that program against it
  (`oh-my-posh print primary --config <file>`) and check for an error.
- **An idempotency guard must check the end state, not a proxy.** Gating the Windows install on
  \"is the service registered\" let a part-failed install report success on retry, because the
  service is created several steps before `daemon.json` and the `win` context (G25).
- **Native `docker` CLI stdout comes back EMPTY inside a non-interactive scheduled task**, even
  through `cmd /c ... > file`. `exit=0` is not evidence there; it produced two false alarms. Verify
  the daemons through the HTTP API instead: `GET /version` (check `Os=linux` to prove you reached
  the WSL2 daemon and not the Windows one), `/_ping`, and for a real container
  `POST /images/create?fromImage=hello-world&tag=latest` **then** create/start/`/logs` - note
  `/containers/create` does *not* auto-pull and 404s on a missing image.
- `Invoke-WebRequest` needs `-UseBasicParsing` under Windows PowerShell 5.1.
- **Never pass an Azure resource ID to `az` from Git Bash**: MSYS rewrites the leading `/` into
  `C:/Program Files/Git/...` and the resulting errors blame azure-cli. Use PowerShell, or
  `MSYS_NO_PATHCONV=1`. After an OS-disk swap, **re-read `storageProfile.osDisk.name` and confirm
  it before starting the VM** - a failed swap is quiet, and `az vm start` will happily boot the
  old disk, which silently invalidates the whole test.
- `az vm run-command` output is capped near 4 KB. A poller that gets truncated before the
  interesting part is worse than none - it hid a 20-minute hang. Print narrowly.
- **Parse-check generated remote scripts locally** with
  `[System.Management.Automation.Language.Parser]::ParseFile` before sending them. Three
  diagnostics failed silently from quoting bugs (nested `@'...'@` here-strings do not work, and
  `\\\"` is not an escape in PowerShell), and each time the silence looked like data about the VM.

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
- Roles: `mrldev` (default), `mrl`, `cloudEngineer`, `developer`, `min`.
  (`runner` and `config-github-runner.ps1` were removed on 2026-09-12; runner boxes are out of scope.)
- `override` is forwarded to `winget install --override`, so its contents are the *underlying
  installer's* flag syntax, not WinGet's — e.g. VS Enterprise's `--add Microsoft.VisualStudio.Workload.*`
  or VS Code's `/mergetasks=addcontextmenufiles,...`.
- **Chocolatey is gone**, and as of the 2026-09 cleanup no trace of it remains in the repo.
  Don't add choco packages; WinGet or PSGallery only.

## Long paths

The `longpaths` phase (`Enable-LongPaths` in `helper.ps1`) lifts the 260-character `MAX_PATH` limit.
It runs after `winget` because it needs `git.exe`, and before the reboot gate because it needs no
restart: the long-path flag is read when a process starts, so anything launched after the phase gets
the new limit.

**Two separate opt-ins, and neither covers the other.** `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled`
is what Win32 callers honour — MSBuild, dotnet, Explorer, Windows PowerShell. **git ignores it
entirely** and needs `core.longpaths`. That is measured, not assumed: on a box with
`LongPathsEnabled` already `1`, `git clone` of a 264-character path still dies with
`error: ... Filename too long` / `fatal: unable to checkout working tree` unless `core.longpaths` is
true (run 16). Setting only one of the two looks like it worked until the other kind of tool hits a
long path.

The failure it exists to prevent is not a clean error. A repo containing a path over 260 characters
(a Power BI custom visual under a long report name is enough) aborts `git clone` with **exit 128
after git has already written thousands of files and no index** — measured on the real repo as
`exit=128 tracked=0 dirty=3936`. So the half-finished clone presents as a mountain of uncommitted
changes, and any tooling with a don't-touch-dirty-work rule then refuses to go near it. The symptom
points at local edits, not at the clone.

**Do not test this with a synthetic repo.** The obvious reproducer — build a deep path with
`hash-object` / `update-index --cacheinfo` / `write-tree`, then clone it — **passed on the test rig
with both opt-ins off, at path lengths up to 774 characters**, and would have argued this phase was
pointless. The same script fails at 294 characters on a developer box with the same git version. The
discrepancy is unexplained. The gate that works is re-cloning a repo that genuinely has the long
paths, into a prefix long enough to reproduce the absolute length.

`core.longpaths` is written to git's **system** scope, so it applies to accounts setup never ran
for; the shipped `.gitconfig` also carries it, which covers the setup user if a Git reinstall
rewrites `etc\gitconfig`. Same value in both, so the two cannot disagree. The phase **reads the
value back** with `git config --system --get` and throws if it is not `true` rather than trusting
the write's exit code: an unwritable `etc\gitconfig` is the realistic failure (unelevated it prints
*error: could not lock config file*), and G38's lesson is that the only proof of a config write is
reading it back out of the tool that has to honour it.

## path-health.ps1

`Get-PathEntry`, `Test-PathHealth`, `Repair-PathHealth`. Its own file because **two different
consumers need the same code**: `profile.ps1` dot-sources it so the functions exist in every shell,
and `helper.ps1` dot-sources it so setup can audit PATH right after writing it. Ported from a
hand-maintained profile that had evolved in a OneDrive folder with no version control.

It detects the failure this repo has itself caused. Windows truncates PATH near 2047 characters when
a process is launched from the GUI, and the cause is usually not growth but **scope mixing** —
writing the merged process PATH back into one scope
(`[Environment]::SetEnvironmentVariable('Path', $env:Path, 'Machine')`). That is exactly G24, where
`Install-WindowsDocker` copied five of `azureadmin`'s directories into the machine variable. **The
key point: exact-string dedupe does not find this**, because every entry is unique within its own
scope — you have to compare across scopes.

`Assert-PathHealth` in `helper.ps1` is the setup-side wrapper, called after the `winget` phase and
immediately after the machine `Path` write in `docker-ce/config-docker.ps1` — G24's exact site, so a
reintroduction shows up in that run's transcript instead of being found months later by hand. It
**reports and never repairs, and never throws**: failing a phase over a pre-existing PATH mess would
block an unattended build for something it did not cause, and silently rewriting a machine-wide
variable mid-setup is worse than the problem. `Repair-PathHealth` is interactive only, supports
`-WhatIf`, and backs the old value up to `%LOCALAPPDATA%\workstation-setup\` first.

`Test-PathHealth -Quiet` is string-only with no disk I/O, which is what makes it cheap enough for
both profile startup and a post-phase check. It is also a value-returning function, so it obeys the
rule below: `@(Test-PathHealth -Quiet).Count` is 1 (verified), and the `-Quiet` branch must stay free
of success-stream output or `if (Test-PathHealth -Quiet)` can be fooled.

## helper.ps1

Dot-sourced by both config scripts. The obsolete Chocolatey and offline-WinGet helpers were removed
in the 2026-09 cleanup; `Install-Stax2AWS-CLI`, the runner-only `Install-DockerEngine` /
`Update-EnvironmentPath`, and the long-dead `New-/Remove-WindowsTask` pair were removed on request
the same month. Everything left is reachable.

Called: `Install-WinGetPackage`, `Install-PSModule`, `Install-Fonts`, `Install-OhMyPoshStandalone`,
`Save-Utf8NoBom`, `Assert-PathHealth` (see `path-health.ps1` above), `Enable-LongPaths`,
`Update-SessionEnvironment`,
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
invoking user). The old `ContainerBootstrap` task is gone entirely, along with the
`install-docker-ce.ps1` worker that used to unregister stale copies of it.

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
  substituted for `-defaultWorkFolder`. Keep that token if you edit the theme. The MSIX build never
  sets `POSH_THEMES_PATH`, so both this copy and `profile.ps1` fall back to
  `%LOCALAPPDATA%\Programs\oh-my-posh	hemes`; they must agree, or the theme lands somewhere nothing
  reads (it silently went to the drive root for ten months on one machine). **Write it with
  `Save-Utf8NoBom`, never `Out-File -Encoding utf8`**: under Windows PowerShell 5.1 that emits a
  BOM, and oh-my-posh is a Go program that rejects a JSON config starting with one - the prompt
  shows `CONFIG PARSE ERROR` and falls back to a default. The same applies to the Windows Terminal
  `settings.json` write. A BOM in a `.ps1` is fine, and on 5.1 it is actively useful, so
  `profile.ps1` is still written with `Out-File`.
- **On Windows Server only**, `Install-OhMyPoshStandalone` downloads `posh-windows-amd64.exe` to
  `%LOCALAPPDATA%\Programs\oh-my-posh\bin`, at the version of the installed MSIX. Server cannot use
  the MSIX for a prompt: every activation of `ohmyposh.cli` first spawns
  `Microsoft.DesktopAppInstaller!winget` and blocks 10-17 s on it, with the App Installer dialog on
  screen, and oh-my-posh runs its exe on *every prompt render*. The same binary outside the package
  runs in ~15-70 ms. Client SKUs are unaffected (57-88 ms) and keep the winget-managed MSIX.
- `terminal-default-settings.json` → merged into Windows Terminal's `settings.json` as
  `profiles.defaults`, with `startingDirectory` overwritten by `-defaultWorkFolder`. If
  `settings.json` doesn't exist yet, the script launches and kills `wt.exe` to force its creation.
- `path-health.ps1` → **next to** the deployed profile, unchanged and with no token substitution.
  `profile.ps1` dot-sources it via `Join-Path $PSScriptRoot 'path-health.ps1'` (verified: `$PSScriptRoot`
  resolves to the profile's own directory when a profile is dot-sourced), behind a `Test-Path` **and**
  a `FullLanguage` check — a partial deploy or a ConstrainedLanguage sandbox must still start a clean
  shell, since a throwing profile breaks every session. Verified both ways: with the sibling present
  the functions load; without it the profile reports 0 errors and everything else still works.
  `Unblock-File` is as important as the copy — a downloaded release zip carries the mark-of-the-web,
  and a blocked script makes every shell start with a security prompt.
- `.gitconfig` → `$env:UserProfile`, then `-gitUser`/`-gitEmail` applied via `git config --global`.
  It carries `core.longpaths = true`, which the `longpaths` phase also writes to git's system scope —
  see "Long paths" below for why both.
- `CaskaydiaCoveNerdFontMono-Regular.ttf` → `C:\Windows\Fonts` plus a font registry entry. The
  terminal font in `terminal-default-settings.json` depends on this.

Transcript logs go to `$PSScriptRoot\logs\` (gitignored), renamed on exit to
`workstation-config-<FileDateTime>.log` by `config-workstation.ps1` and
`docker-ce-config-<FileDateTime>.log` by `docker-ce/config-docker.ps1`.

## Docker CE (`docker-ce/`)

`docker-ce/config-docker.ps1` is the whole Windows side, phase-based like the workstation script:
`containers-feature` (Containers plus Hyper-V on client SKUs, `-NoRestart`), `environment`, the
single reboot gate, then `docker-windows`, `docker-linux` and `wsl-autostart`. The separate
`install-docker-ce.ps1` worker was folded in on 2026-09-14: once feature enabling moved to
`containers-feature`, the worker's only reason to be its own process — exiting 3010 to ask for a
reboot — became unreachable, and the orchestrator's second reboot gate with it. Phases now just
throw, and `Invoke-SetupPhase` retries them. Two daemons run side by side on distinct ports, by
design:

- **Linux (WSL2) daemon on `tcp://127.0.0.1:2375`** — patched into `/etc/systemd/system/docker.service` by `sed`.
- **Windows daemon on `tcp://127.0.0.1:2378`** — via `daemon.json` (TCP + `npipe://`).
- User-scope `DOCKER_HOST` points at 2375, so bare `docker` targets Linux; a `win` context is created
  for 2378, so `docker -c win` targets Windows. Verify both:
  `docker run hello-world` and `docker -c win run hello-world`.
- `WSLENV`/`BASH_ENV` are set so the Windows-side `DOCKER_HOST` propagates into WSL.
- **Bare `docker` only works while the WSL distro is running.** The relayed `127.0.0.1:2375` port
  exists only then, and a Windows-side TCP connect does **not** start the distro. WSL2 also shuts an
  idle distro down about a minute after the last session closes, so *starting* it once is not
  enough - that was the first, wrong fix. The `wsl-autostart` phase therefore **holds a session
  open** for the whole logon: an at-logon task running
  `conhost --headless wsl.exe --distribution Ubuntu -- sleep infinity` (`ExecutionTimeLimit` PT0S,
  since it never exits; `conhost --headless` so no console window is left on the desktop, verified
  by `MainWindowHandle` being 0). Measured on the test VM: after `wsl --terminate`, nothing listens
  and bare `docker` exits 1; with the keepalive up, the listener is present and still present after
  a 150 s wait, well past the idle timeout.
- `install-docker-ce.sh` ends with `systemctl restart docker`, not a WSL restart. It used to end in
  `sudo shutdown -r now`, which was both redundant (`daemon-reload` already loads the patched unit)
  and prone to hanging forever under systemd-in-WSL. The
  `docker-linux` phase verifies **what the client actually uses**: a TCP connect to
  `127.0.0.1:2375` from Windows, via `Start-WslDistro`/`Test-TcpPort`, throwing if it never answers.
  It must not go back to `wsl -- docker version`: that probes the unix socket *inside* the distro
  **and starts the distro**, so it cannot fail — it reported success on a run where bare `docker`
  was broken (G27). The shell script is written to be re-runnable: the `sed` adding
  `-H tcp://127.0.0.1:2375` is `grep`-guarded, or a second run would append a duplicate `-H`.
- `.gitattributes` pins `*.sh` to LF. Without it a Windows clone with `core.autocrlf=true` checks
  them out CRLF and bash fails on every line.
- systemd inside WSL2 comes from `Initialize-WslUser` writing `systemd=true` to `/etc/wsl.conf`
  (and current Ubuntu images ship it on by default). The old `linux/systemd/` PID-namespace hack
  was removed on 2026-09-13 after the test VM showed `systemctl is-system-running` = `running`
  with `/etc/wsl.conf` alone.

`Install-WindowsDocker` copies `daemon.json` from `$PSScriptRoot`, so it works from a git clone as
well as from a `get-latestPackages.ps1` deploy, and it creates `%ProgramData%\docker\config\`
itself: `dockerd` 20.10 created that directory on first run but 29.x does not, which is what broke
the copy on the first real run (G23). It appends `C:\docker` to the **machine** `Path` read
from the machine scope — never `$env:Path`, which is Machine and User merged and would bake the
running user's private directories into the machine `Path` (G24). And it is idempotent piece by
piece rather than gated on "is the service registered", because the service is created several steps
before `daemon.json` and the `win` context, so one up-front check let a part-failed install look
complete on retry (G25).

## Distribution

Users bootstrap from the **latest GitHub release**, not from `main`:

```powershell
Invoke-RestMethod -Uri "https://raw.githubusercontent.com/101solution/workstation-setup/main/get-latestPackages.ps1" -OutFile "$env:temp\get-latestPackages.ps1"; powershell.exe -executionpolicy bypass -file $env:temp\get-latestPackages.ps1 -role mrldev
```

So a manifest or script change reaches nobody until a new `v2.x.y` release is published.
`get-latestPackages.ps1` is the one exception — it's fetched from raw `main`, so edits to it take
effect immediately.

**A git tag is not a release.** `get-latestPackages.ps1` queries the `/releases` API and takes the
first non-draft, non-prerelease entry, so `git push origin v2.x.y` on its own reaches nobody. Cut
the tag *and* publish a GitHub Release from it:

```powershell
git tag -a v2.x.y -m "..."; git push origin v2.x.y
gh release create v2.x.y --verify-tag --title "..." --notes-file notes.md
```

Publishing is the step with real blast radius: the new release immediately becomes what every
machine running the bootstrap one-liner installs. `gh release delete v2.x.y` reverts to the previous
one if needed. Current release: **v2.5.2** (2026-09-18) — the release-version gate, PATH health and
the `longpaths` phase, validated on both SKUs by run 16 the same day.

The README's role table is hand-maintained; update it when adding a role or materially changing a manifest.
