# Published v2.6.0 validation handover

Follow-up on 2026-11-09: a Terraform-provisioned Windows 11 workstation completed
the published v2.6.0 setup, confirmed by script hashes. The provisioning task
passed its own name to setup, was reused after one reboot, and was removed when
run 2 recorded all nine phases plus `done`. No duplicate installer was observed.
Signed-in user checks passed for PowerShell 7.6.9, Git 2.55.0.windows.5, .NET SDK
10.0.402, Terraform 1.16.5, Ubuntu WSL 2, its default user, and systemd as PID 1.
Docker was not tested in this follow-up. The task and backend fixes are merged in
az-dev-vm-tf PRs #18 and #19; no new workstation release was needed.

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
See VALIDATION-HISTORY.md for evidence and limits. Compose/Dev Containers
validation remains unperformed. Remove retained managed Run
Commands while a test VM is running before restoring its clean snapshot, so old
automation cannot replay on the restored guest. Private environment details and
guest evidence remain local.
