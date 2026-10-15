# Published v2.6.0 validation handover

Release preparation uses `release/v2.6.0`, based on `main`, with the tested
candidate code from `fix/setup-reliability`. The original branch and detailed
operator evidence remain local. This branch omits unpublished test-environment
identifiers and summarizes installation evidence in VALIDATION-HISTORY.md.

Local verification passed on 2026-10-15: 55 PowerShell 7/5.1 assertions, 13
PowerShell files with zero parser errors, eight JSON files, Bash syntax/failure
checks, and Terraform formatting/validation. [PR #9](https://github.com/101solution/workstation-setup/pull/9)
records passing GitHub CI and supersedes PR #8. v2.6.0 is published as Latest.

Both Windows SKUs passed setup/profile/configuration preservation, the optional
Windows Docker default and reboot resume, and Windows/WSL container checks.
Client upgrade, second-user setup, optional Linux Docker failure/retry and
force/reboot continuation passed; Server package retry and Docker replacement
passed. Those candidate tests used a configured client for feature reset.

Published v2.6.0 subsequently passed a clean Windows 11 Enterprise 24H2 `mrl`
installation on 2026-10-15: all nine phases plus done, two runs, one reboot,
resume task removed. Bruno's first-pass failure recovered during continuation;
Bruno 4.2.1 was confirmed installed. Operator checks passed for Git/.NET/Terraform,
WSL 2/Ubuntu and Linux hello-world. Optional Windows Docker client/server 29.8.0
and Windows hello-world passed, and WSL containers still worked afterward.
See VALIDATION-HISTORY.md for evidence and limits. No new full mrldev installation
or Compose/Dev Containers validation was performed. Remove retained managed Run
Commands while a test VM is running before restoring its clean snapshot, so old
automation cannot replay on the restored guest. Private environment details and
guest evidence remain local.
