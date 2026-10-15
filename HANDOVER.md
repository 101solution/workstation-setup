# v2.6.0 release handover

Release preparation uses `release/v2.6.0`, based on `main`, with the tested
candidate code from `fix/setup-reliability`. The original branch and detailed
operator evidence remain local. This branch omits unpublished test-environment
identifiers and summarizes installation evidence in VALIDATION-HISTORY.md.

Local verification passed on 2026-10-15: 55 PowerShell 7/5.1 assertions, 13
PowerShell files with zero parser errors, eight JSON files, Bash syntax/failure
checks, and Terraform formatting/validation. [PR #9](https://github.com/101solution/workstation-setup/pull/9)
records GitHub CI and supersedes PR #8. CI must pass before merge and release.

Both Windows SKUs passed setup/profile/configuration preservation, the optional
Windows Docker default and reboot resume, and Windows/WSL container checks.
Client upgrade, second-user setup, optional Linux Docker failure/retry and
force/reboot continuation passed; Server package retry and Docker replacement
passed. Client feature reset used a configured OS; no fresh client reinstall or
new full mrldev run was performed. Compose/Dev Containers remain unverified.
