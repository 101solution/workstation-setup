# How to run Docker on Windows and Linux without Docker Desktop

The default installation configures **Windows Docker** on `tcp://127.0.0.1:2378`
(and `npipe://`). Use `docker-w ...` in the deployed PowerShell profile, or
`docker.exe -c win ...`, for Windows containers.

For Linux containers, [WSL 2.9.3+ includes `wslc.exe`](https://learn.microsoft.com/en-us/windows/wsl/wsl-container)
and requires no separate engine installation. Update WSL, then run `wslc run --rm hello-world`.
The deployed PowerShell profile aliases `docker` to `wslc`; `docker-w` explicitly
calls `docker.exe -c win`, bypassing that alias. Use `docker.exe` for the real Docker CLI/API.
Version 3.0.3 passed hello-world, image building, and Windows localhost port forwarding on
Windows Server 2025 and Windows 11 Enterprise 24H2 on 2026-10-13.

Add `-installLinuxDocker` when a workflow needs the Linux Docker API. This installs Docker CE
inside Ubuntu on `tcp://127.0.0.1:2375`, sets user-scope `DOCKER_HOST` to that endpoint, and installs
a WSL keepalive task. Existing Linux Docker installations, tasks, and user environment are
retained when the switch is omitted. Compose and Dev Containers compatibility with wslc is
unverified; wslc uses its own CLI and API.

> **Status (2026-09-14): validated end to end on a clean machine** (run 7 in `VALIDATION-HISTORY.md`). Getting
> there took nine real-machine bugs, G23-G31. Both daemons verified: `docker -c win run hello-world`
> prints its banner, and the Linux daemon reports `os=linux arch=amd64` on 2375 and runs a container
> to `exitCode=0`. Bare `docker` survives a reboot via the `wsl-autostart` keepalive.

## Prerequisite

For `-installLinuxDocker`, run the [workstation setup](../README.md#quick-start-new-vm) first. It enables WSL2 and registers an
Ubuntu distro whose default user has passwordless sudo and systemd enabled, both of which the Linux
installer needs.

## Install

From **Administrator PowerShell**, from any directory:

```powershell
powershell.exe -executionpolicy bypass -file .\docker-ce\config-docker.ps1
# Also install Linux Docker CE when its API is required:
powershell.exe -executionpolicy bypass -file .\docker-ce\config-docker.ps1 -installLinuxDocker
```

The script is unattended and resumable, using the same phase machinery as `config-workstation.ps1`
(state in `%ProgramData%\workstation-setup\docker-ce-state.json`):

1. `containers-feature` — enables the Containers feature (plus Hyper-V on Windows 10/11) without restarting.
2. `environment` — with `-installLinuxDocker`, user-scope `DOCKER_HOST`, `WSLENV` and `BASH_ENV`.
3. **Reboot gate** — restarts once, only if step 1 needed it, and resumes via a logon task.
4. `docker-windows` — Docker static binaries to `C:\docker`, the `docker` service, `daemon.json`,
   then a per-user `docker-context` phase creates or updates `win`. Waits for 2378 to answer.
5. `docker-linux` — with `-installLinuxDocker`, runs `install-docker-ce.sh` inside Ubuntu: Docker CE from the official apt repo,
   the unit file patched to also listen on 2375, then `systemctl restart docker`. Then verifies from
   **Windows** that `127.0.0.1:2375` answers, which is what the client actually uses. The whole
   script runs under a 30-minute bounded wait, so it can never wedge the install.
6. `wsl-autostart` — with `-installLinuxDocker`, registers an at-logon task that **holds a WSL session open**
   (`conhost --headless wsl.exe --distribution Ubuntu -- sleep infinity`). See the note
   below; without it bare `docker` breaks after every reboot.

`-resumeMethod ScheduledTask|RunOnce|None`, `-noReboot` (exit 3010 instead of restarting) and `-force`
(redo everything) work exactly as in the workstation script. Logs go to `logs\docker-ce-config-<date>.log`
in the repo root.

One difference from the workstation script: this one has **no release-version tracking**, because
`get-latestPackages.ps1` never invokes it and so there is no tag to compare. Its phases are skipped
whenever they are already recorded as complete, so **to re-apply a newer release of the Docker CE
scripts after changes to their orchestration logic, pass `-force`**. Unchanged inputs preserve
completed phases; the input tracking below automatically handles version and installer changes.

Changes to `-installLinuxDocker`, `-dockerVersion`, daemon configuration, the Linux installer, or the selected distro
invalidate affected phases automatically. Windows setup compares installed and requested versions,
validates downloaded binaries before replacing them, stops the service for replacement, and checks
the running daemon's OS and version. Linux installer failures fail the phase even when an older
daemon remains reachable. User environment, WSL installation, and keepalive progress are recorded
per Windows user. `-force` is omitted from reboot continuation.

## Verify

Open a **new** PowerShell window (so the user-scope `DOCKER_HOST` is picked up) and run:

```powershell
wslc run --rm hello-world       # WSL Linux containers
docker run --rm hello-world     # Profile alias for wslc
docker-w run hello-world        # Windows daemon through the profile function
# Without the deployed profile: docker.exe -c win run hello-world
# With -installLinuxDocker, in a new shell:
docker.exe run hello-world      # Optional Linux Docker daemon
```

## Notes

- **Linux `docker.exe` needs the WSL distro running.** The relayed `127.0.0.1:2375` port exists only
  while the distro is up, and a Windows-side TCP connect does not start it. WSL2 shuts an idle
  distro down about a minute after the last session closes, so the `wsl-autostart` logon task does
  not merely start it - it holds a session open. If Linux `docker.exe` fails, start it and retry:
  ```powershell
  wsl -d Ubuntu -- /bin/true
  docker.exe run hello-world
  ```
- The old `install-docker-ce.ps1` worker and its 0/3010/1 exit-code protocol were folded into
  `config-docker.ps1` on 2026-09-14; the Windows install is now the `docker-windows` phase.
- systemd inside the distro is required (the Linux installer uses `systemctl`). The workstation
  setup enables it through `/etc/wsl.conf`; nothing extra is needed on a current WSL build.
