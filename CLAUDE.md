# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo automates Windows workstation setup and Docker CE configuration for developers and cloud engineers. It uses WinGet, Chocolatey, and PowerShell modules driven by role-based JSON package manifests.

## Architecture

### Entry Points

- **`config-workstation.ps1`** — main setup script; takes `-role`, `-enableWSL`, `-gitUser`, `-gitEmail`, `-defaultWorkFolder` parameters
- **`config-docker.ps1`** — standalone Docker CE setup for Windows (no Docker Desktop)
- **`config-github-runner.ps1`** — sets up a GitHub Actions self-hosted runner
- **`get-latestPackages.ps1`** — fetches the latest GitHub release and runs setup (one-liner bootstrap)

### Role-Based Package System

Package definitions live in `packages-<role>.json` files and are loaded by the setup scripts. Each file contains:
- `chocolatey` — list of Chocolatey package IDs
- `winget` — list of WinGet package IDs (with optional `override` field for install flags)
- `psmodules` — list of PowerShell module names

Roles: `cloudEngineer` (default), `dev`, `qa`, `runner`, `ce-corp`, `ce-free`

### Helper Functions

`helper.ps1` is dot-sourced by the main scripts and provides reusable functions:
- `Install-Choco` / `Install-ChocoPackage` — Chocolatey bootstrap and package install
- `New-WindowsTask` / `Remove-WindowsTask` — scheduled task management (used for post-reboot continuation)
- `Test-VMRestart` — detects pending reboots

### Docker CE (`docker-ce/`)

Two independent paths for running Docker without Docker Desktop:
- **`windows/install-docker-ce.ps1`** — installs Docker Engine natively on Windows, configures `daemon.json` for TCP + named pipe, creates WSL context
- **`linux/install-docker-ce.sh`** — installs Docker CE in Ubuntu WSL2, exposes socket over TCP on port 2375
- **`linux/systemd/`** — enables systemd inside WSL2 (prerequisite for the Linux Docker setup)

The Windows and Linux installs are designed to work together: Linux Docker daemon on 2375, Windows daemon on 2378.

### Terminal & Shell Configuration

- `profile.ps1` — PowerShell profile copied to `$PROFILE`; enables posh-git, Oh My Posh (theme: `rudolfs-light-cs.omp.json`), PSReadLine with history prediction
- `terminal-default-settings.json` — Windows Terminal defaults (CaskaydiaCove NF font, background image, starting dir)
- `.gitconfig` — copied to user home; includes VS Code as diff/merge tool and common aliases

## Running Scripts

All scripts require **Administrator PowerShell**. No build or test commands exist — this is a configuration/automation repo, not a compiled project.

```powershell
# Full workstation setup (default role: cloudEngineer)
.\config-workstation.ps1

# With specific role and git identity
.\config-workstation.ps1 -role dev -gitUser "Name" -gitEmail "email@example.com"

# Docker CE on Windows
.\config-docker.ps1

# GitHub Actions runner
.\config-github-runner.ps1

# Bootstrap from latest GitHub release (run as admin)
.\get-latestPackages.ps1
```

## Key Conventions

- Scripts log output to timestamped files in `c:\logs\` for troubleshooting
- Scheduled tasks are used to resume setup after required reboots (created/removed by helper functions)
- The `override` field in winget package entries passes raw flags to `winget install` (e.g., to add Explorer context menu entries for VS Code)
- `daemon.json` in `docker-ce/windows/` configures the Docker daemon — edit this to change TCP ports or add registries
