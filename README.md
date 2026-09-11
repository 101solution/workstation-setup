# Workstation Configuration

PowerShell scripts that set up a Windows workstation from a role-based package manifest. Setup is
**unattended**: nothing prompts for input, at most one reboot happens (at the very end, only if WSL2
had to be enabled), and setup resumes by itself after that reboot.

## Quick Start (New VM)

Run the following one-liner in **Administrator PowerShell**, replacing `mrldev` with your desired role:

```powershell
Invoke-RestMethod -Uri "https://raw.githubusercontent.com/101solution/workstation-setup/main/get-latestPackages.ps1" -OutFile "$env:temp\get-latestPackages.ps1"; powershell.exe -executionpolicy bypass -file $env:temp\get-latestPackages.ps1 -role mrldev
```

This downloads the latest release to `c:\config\workstation` and runs `config-workstation.ps1`. Walk
away: if Windows restarts, a logon-triggered task finishes the last step (registering the Ubuntu
distro) and removes itself.

## Available Roles

| Role | Description |
|------|-------------|
| `mrldev` | Full developer setup — VS Enterprise, SSMS, DBeaver, Sourcetree, TortoiseGit, Power BI, Wireshark, and more |
| `mrl` | Lighter setup — Terraform, .NET SDK 8, Azure CLI, Postman, AWS CLI, PowerToys, Storage Explorer, AZCopy |
| `cloudEngineer` | Cloud engineering — kubectl, minikube, Terraform, .NET SDK 8, Azure CLI, GitHub CLI, Postman, AWS CLI, NodeJS LTS, Claude Code; Az and AWSPowerShell.NetCore modules |
| `developer` | .NET SDK 8, Azure CLI, Postman, Terraform |
| `ce-corp` | Docker CE setup with Visual Studio Enterprise |
| `ce-free` | Docker CE setup with Visual Studio Community |
| `min` | The base packages only, nothing role-specific |
| `runner` | Prerequisites for a GitHub Actions self-hosted runner — Terraform, .NET SDK 8, Azure CLI, Git, Az module, plus Docker Engine. Installed by `config-github-runner.ps1`, not `config-workstation.ps1` |

Every role layers on the base packages from `packages-min.json`: PowerShell, Git, VS Code,
Oh My Posh, Windows Terminal, Ditto, Bing Wallpaper, 7-Zip, posh-git, PSReadLine, PSRule. The two
exceptions are `min`, which is just that base, and `runner`, which uses its own manifest alone.

## Manual Setup

1. Clone the repo or unzip a release, then open PowerShell in **Administrator** mode.
2. Run:

```powershell
powershell.exe -executionpolicy bypass -file .\config-workstation.ps1 -role <role> -gitUser "Your Name" -gitEmail "you@example.com"
```

### Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `-role` | `mrldev` | Which `packages-<role>.json` to install |
| `-gitUser`, `-gitEmail` | unset | Written to the global git config when given |
| `-defaultWorkFolder` | `c:\projects` | Created if missing. Becomes `$HOME` in the PowerShell 7 profile, the Windows Terminal starting directory and the Oh My Posh theme's home |
| `-enableWSL` | `$true` | Enable WSL2 and register Ubuntu with a ready-to-use user (passwordless sudo, systemd on). `-enableWSL $false` skips all of it |
| `-resumeMethod` | `ScheduledTask` | How setup comes back after the reboot: `ScheduledTask`, `RunOnce` or `None`. See below |
| `-noReboot` | off | Never restart. Exit code 3010 means a restart is owed; for image pipelines that sequence their own reboots |
| `-force` | off | Discard saved progress and redo every phase |

## Unattended execution and reboots

Setup runs as a series of named phases. Each completed phase is recorded in
`%ProgramData%\workstation-setup\setup-state.json`, so **re-running the same command is always safe**:
finished work is skipped and only what is left runs. A phase that fails is logged and retried on the
next run rather than aborting the build.

Phases are ordered so that everything that does not need a restart (packages, fonts, modules, shell
profile, terminal settings) completes first. Only registering the WSL distro waits for the reboot,
and there is at most one reboot. On a machine where WSL2 is already enabled there is none.

How setup resumes after that reboot is chosen with `-resumeMethod`:

| Value | Behaviour |
|-------|-----------|
| `ScheduledTask` (default) | A logon-triggered, elevated scheduled task finishes setup with no human input, then removes itself. The only fully hands-off option, because returning *elevated* after a reboot needs a task, a service or autologon. Falls back to `RunOnce` if task registration is blocked by policy |
| `RunOnce` | No scheduled task. An HKLM `RunOnce` entry relaunches setup after logon and asks for one UAC consent. Self-deleting |
| `None` | Arms nothing. Re-run the same command after the reboot; it finishes in seconds |

For an image pipeline that must control its own reboots:

```powershell
powershell.exe -executionpolicy bypass -file .\config-workstation.ps1 -role mrl -resumeMethod None -noReboot
# exit code 3010 => reboot, then run the identical line again
```

Transcript logs are written to `logs\` next to the script as `workstation-config-<date>.log`.

## Docker without Docker Desktop

After the workstation setup has finished (it provides WSL2 Ubuntu), run:

```powershell
powershell.exe -executionpolicy bypass -file .\docker-ce\config-docker.ps1
```

It installs a Windows Docker daemon and a Linux one inside WSL2 side by side, with the same
unattended phase/resume behaviour and the same `-resumeMethod`, `-noReboot` and `-force` switches.
Details in [docker-ce/README.md](docker-ce/README.md).

## GitHub Actions runner prerequisites

`config-github-runner.ps1` prepares a runner box: the `runner` manifest plus Docker Engine for
Windows containers, unattended and resumable exactly like the workstation script (its state lives in
`gh-runner-state.json`). It does **not** register the runner agent itself; that needs a registration
token, so download the actions-runner release and run its `config.cmd` afterwards.

```powershell
powershell.exe -executionpolicy bypass -file .\config-github-runner.ps1
```

## Terminal

The script configures Oh My Posh and PSReadLine, inspired by:
- [My Ultimate PowerShell prompt with Oh My Posh and the Windows Terminal](https://www.hanselman.com/blog/my-ultimate-powershell-prompt-with-oh-my-posh-and-the-windows-terminal)
- [You should be customizing your PowerShell Prompt with PSReadLine](https://www.hanselman.com/blog/you-should-be-customizing-your-powershell-prompt-with-psreadline)

![Windows Terminal](win-term.png)
