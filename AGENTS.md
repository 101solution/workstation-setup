# Repository Guidelines

## Project Structure & Module Organization

This repository automates Windows workstation configuration. Root scripts include `config-workstation.ps1` (setup), `get-latestPackages.ps1` (release bootstrap), `helper.ps1` (shared phase machinery), and `path-health.ps1` (PATH auditing). `packages-<role>.json` defines role packages; `packages-min.json` supplies the shared base. `docker-ce/` contains the optional Docker orchestrator, Bash installer, and daemon configuration. Root assets include the PowerShell profile, terminal settings, Oh My Posh theme, font, and screenshot. Consult `README.md` for usage, `TODO.md` for open work, and `VALIDATION-HISTORY.md` for validation evidence. Generated transcripts belong in gitignored `logs/`.

## Build, Test, and Development Commands

There is no build pipeline, configured linter, or automated test suite. Run installation commands in Administrator PowerShell on a disposable machine:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\config-workstation.ps1 -role mrl
powershell.exe -ExecutionPolicy Bypass -File .\docker-ce\config-docker.ps1
```

The first configures the workstation; run the optional Docker step afterward. Use `-force` to rerun completed phases. Use `-resumeMethod None -noReboot` when managing restarts yourself; exit code 3010 indicates a required reboot.

Before submitting, parse every tracked `.ps1` with `[System.Management.Automation.Language.Parser]::ParseFile` under **PowerShell 7**, reporting file and error counts. Validate JSON with `ConvertFrom-Json` and Bash syntax with `bash -n docker-ce/install-docker-ce.sh`.

## Coding Style & Naming Conventions

Match existing formatting: four-space PowerShell indentation and two-space manifest indentation. Use Verb-Noun function names and `packages-<role>.json` filenames. Preserve Windows PowerShell 5.1 runtime compatibility and LF endings for `.sh` files. Use `Write-SetupLog` for setup logging; success-stream output must contain only return values. Keep phases idempotent, unattended, and resumable. Add packages through WinGet or PSGallery.

## Testing Guidelines

Syntax checks do not establish installation correctness. Validate setup changes on both Windows 11 Enterprise 24H2 and Windows Server 2025, including retries and reboot resume. Inspect transcripts and verify behavior through the consuming tool. For Docker, verify both `docker run hello-world` and `docker -c win run hello-world`. Record results and remaining gaps in `VALIDATION-HISTORY.md`; no coverage threshold or automated test naming convention exists.

## Commit & Pull Request Guidelines

History uses concise imperative subjects, such as “Lift the 260-character path limit during setup.” Follow that style. PRs should explain the changed behavior, affected roles, validation performed, and outstanding gaps; link relevant issues or backlog identifiers. Update README role documentation when manifests change. Keep credentials and generated logs out of commits.
