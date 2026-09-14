# How to run Docker on Windows and Linux without Docker Desktop

Two daemons end up running side by side:

- **Linux (WSL2 Ubuntu)** on `tcp://127.0.0.1:2375`. The user-scope `DOCKER_HOST` points here, so a
  bare `docker` command targets Linux containers.
- **Windows** on `tcp://127.0.0.1:2378` (and `npipe://`). A `win` context is created for it, so
  `docker -c win ...` targets Windows containers.

> **Status (2026-09-14): validated end to end on a clean machine** (run 7 in `TODO.md`). Getting
> there took nine real-machine bugs, G23-G31. Both daemons verified: `docker -c win run hello-world`
> prints its banner, and the Linux daemon reports `os=linux arch=amd64` on 2375 and runs a container
> to `exitCode=0`. Bare `docker` survives a reboot via the `wsl-autostart` keepalive.

## Prerequisite

Run the [workstation setup](../README.md#quick-start-new-vm) first. It enables WSL2 and registers an
Ubuntu distro whose default user has passwordless sudo and systemd enabled, both of which the Linux
installer needs.

## Install

From **Administrator PowerShell**, from any directory:

```powershell
powershell.exe -executionpolicy bypass -file .\docker-ce\config-docker.ps1
```

The script is unattended and resumable, using the same phase machinery as `config-workstation.ps1`
(state in `%ProgramData%\workstation-setup\docker-ce-state.json`):

1. `containers-feature` — enables the Containers feature (plus Hyper-V on Windows 10/11) without restarting.
2. `environment` — user-scope `DOCKER_HOST`, `WSLENV` and `BASH_ENV`.
3. **Reboot gate** — restarts once, only if step 1 needed it, and resumes via a logon task.
4. `docker-windows` — Docker static binaries to `C:\docker`, the `docker` service, `daemon.json`,
   the `win` context. Waits for 2378 to answer.
5. `docker-linux` — runs `install-docker-ce.sh` inside Ubuntu: Docker CE from the official apt repo,
   the unit file patched to also listen on 2375, then a WSL restart. Then verifies from **Windows**
   that `127.0.0.1:2375` answers, which is what the client actually uses.
6. `wsl-autostart` — registers an at-logon task running `wsl -d Ubuntu -- /bin/true`. See the note
   below; without it bare `docker` breaks after every reboot.

`-resumeMethod ScheduledTask|RunOnce|None`, `-noReboot` (exit 3010 instead of restarting) and `-force`
(redo everything) work exactly as in the workstation script. Logs go to `logs\docker-ce-config-<date>.log`
in the repo root.

## Verify

Open a **new** PowerShell window (so the user-scope `DOCKER_HOST` is picked up) and run:

```powershell
docker run hello-world          # Linux daemon
docker -c win run hello-world   # Windows daemon
```

## Notes

- **Bare `docker` needs the WSL distro running.** The relayed `127.0.0.1:2375` port exists only
  while the distro is up, and a Windows-side TCP connect does not start it. `install-docker-ce.sh`
  restarts WSL, and WSL2 stops idle distros anyway, so the `wsl-autostart` logon task exists to
  bring it up. If bare `docker` ever fails, start the distro and retry:
  ```powershell
  wsl -d Ubuntu -- /bin/true
  docker run hello-world
  ```
- The old `install-docker-ce.ps1` worker and its 0/3010/1 exit-code protocol were folded into
  `config-docker.ps1` on 2026-09-14; the Windows install is now the `docker-windows` phase.
- systemd inside the distro is required (the Linux installer uses `systemctl`). The workstation
  setup enables it through `/etc/wsl.conf`; nothing extra is needed on a current WSL build.
