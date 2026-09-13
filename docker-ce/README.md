# How to run Docker on Windows and Linux without Docker Desktop

Two daemons end up running side by side:

- **Linux (WSL2 Ubuntu)** on `tcp://127.0.0.1:2375`. The user-scope `DOCKER_HOST` points here, so a
  bare `docker` command targets Linux containers.
- **Windows** on `tcp://127.0.0.1:2378` (and `npipe://`). A `win` context is created for it, so
  `docker -c win ...` targets Windows containers.

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
4. `docker-windows` — runs `install-docker-ce.ps1`: Docker static binaries to `C:\docker`, the
   `docker` service, `daemon.json`, the `win` context.
5. `docker-linux` — runs `install-docker-ce.sh` inside Ubuntu: Docker CE from the official apt repo,
   the unit file patched to also listen on 2375, then a WSL restart. Waits for the daemon to answer.

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

- `install-docker-ce.ps1` is a worker driven by the orchestrator. Exit code 0 is success, 3010 means
  a Windows feature still needs a restart, 1 is failure. Running it on its own never restarts the
  machine.
- systemd inside the distro is required (the Linux installer uses `systemctl`). The workstation
  setup enables it through `/etc/wsl.conf`; nothing extra is needed on a current WSL build.
