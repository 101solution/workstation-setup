# Setup Reliability Handover

Updated 2026-10-08 (Australia/Perth).

## Branch and PR

- Branch: `fix/setup-reliability`.
- PR: https://github.com/101solution/workstation-setup/pull/8
- Latest committed/pushed change: `f70003a`, “Fix setup failure reporting, resume behavior, and configuration updates”.
- Review corrections and this note are being committed and pushed together after the user's explicit request. Changed: `AGENTS.md`, `config-workstation.ps1`, `docker-ce/config-docker.ps1`, `helper.ps1`, and `tests/setup-regression.ps1`. New migration fixtures: `legacy/v2.5.2/profile.ps1` and `legacy/v2.5.2/.gitconfig` (the latter is hidden). Use `git log -1` for the handover commit ID.
- `.claude/settings.local.json` was already untracked before this work. Leave it out of commits.
- User authorized fixing, pushing, and raising the PR. The latest request is to save this handover; work was interrupted before VM provisioning.

## Implemented Review Corrections

1. Shell policy: `Set-SetupExecutionPolicy` tolerates `ExecutionPolicyOverride` from inherited Process policy/GPO; other errors still fail. Removed the child `pwsh` policy call.
2. Native stderr: `Invoke-SetupNative` uses `ProcessStartInfo`, separate stdout/stderr capture, and Windows argument quoting. Applied to WSL help/list/start/path translation and Docker contexts. A real native stderr regression runs under PowerShell 5.1.
3. WSL runtime update failure now warns and proceeds with the installed runtime. Missing Terminal settings request a retry rather than throwing or marking completion. Deferred phases are reported and leave `done` unrecorded, with exit code 0; assess this contract during review.
4. WinGet ID-not-found (`0x8A150014`) is a warning again; other unexpected installation failures remain errors.
5. Package preflight checks whether NuGet provider/source exist before installing/registering.
6. Profile migration recognizes the historical v2.5.2 template with its original work folder, removes a matching managed prefix, and preserves appended custom content. Arbitrarily modified legacy profiles still need careful review; do not erase unknown user changes.
7. Git migration removes exact historical key/value defaults using a temporary file and `git config --fixed-value --unset-all`; preserves differing overrides and identity, then loads managed defaults before user settings.
8. Windows Docker context creation moved into a separate per-user `docker-context` phase. Existing contexts are updated to the expected endpoint.
9. Profile-fragment and Git backups are skipped when content is unchanged.
10. `AGENTS.md` now mentions tests and CI.
11. Docker installation compares both client and daemon versions before skipping, validates both staged binaries, and verifies both after copying. Mixed-version retry is covered.
12. Manifest loading now follows transcript startup; failure is logged and exits 1 before state changes.

## Verification Evidence and Remaining Checks

- Original `f70003a`: 32 assertions passed on PowerShell 7.6.6 and Windows PowerShell 5.1.26100.9549, plus syntax/manifest/Bash checks.
- Review corrections: **43 assertions passed on Windows PowerShell 5.1** after the final native-command implementation.
- PowerShell 7.6.6 passed all 43 assertions against the final `ProcessStartInfo` implementation before the handover push. Eight scripts/eight JSON files parsed; manifest schema, Bash syntax, both mocked installer failure checks, and whitespace checks passed.
- The image lookup was interrupted; confirm exact images before provisioning.
- **No VM was provisioned and no installation/reboot validation was performed.** PR remains open; do not merge before the requested client/Server and v2.5.2 upgrade validation.

Run locally:

```powershell
pwsh -NoProfile -File .\scripts\verify.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\setup-regression.ps1
git diff --check
```

With Bash: `bash -n docker-ce/install-docker-ce.sh`, `bash -n tests/docker-installer.sh`, and `bash tests/docker-installer.sh`. On this host use Git Bash with `/usr/bin:/bin` on its PATH; the system `bash.exe` is the WSL launcher.

Update docs that still describe ID-not-found as fatal or claim only 32 assertions. Add migration fixtures to the verification file discovery; the current verifier checks eight scripts/eight JSON files and does not recursively parse `legacy/`. Add a fixture provenance note and consider coverage for an unavailable WSL update, missing manifest logs, and per-user Docker contexts. Review native-command timeout/encoding behavior and profile migration when custom lines were inserted within the old template.

## Azure Validation Preparation

- Azure authentication works. Active subscription at inspection was `sub-lz-dev-appintdevtool-01`; do not change or provision there accidentally.
- Prior test subscription: **VS_Sub_MRL**, ID `1f513fde-7a26-4aae-a69e-3f29f41d7f2a`. Use explicit `--subscription` on every command.
- Confirmed `az vm list` returned `[]` there, and `az group exists --name S101-ARG-WSTEST-MRL` returned `false`. Old VMs and snapshots are gone.
- Intended location: `australiaeast`; previous rig used `Standard_D4s_v5` (see validation history).
- Intended images: `MicrosoftWindowsDesktop:windows-11:win11-24h2-ent:latest` and `MicrosoftWindowsServer:WindowsServer:2025-datacenter-g2:latest`. Exact-image lookups were interrupted; confirm image availability before creating anything.
- Previous admins: `azureadmin` on client and `test.user` on Server (the dot exercises installer staging). Snapshot both before installation. See `TODO.md`, `CLAUDE.md`, and G7 in `VALIDATION-HISTORY.md` for requirements.
- `logs/vm-rig-create.ps1` referenced in TODO is absent. Existing local drivers are `logs/vm-bootstrap.ps1`, `logs/vm-diag.ps1`, and `logs/vm-poll.ps1`; bootstrap targets `main` and includes old hardcoded credentials, so **do not run it unchanged**.
- Build a new driver with fresh credentials, exact PR commit checkout, and confirmed role. Never print credentials or pass them using `az vm run-command --parameters`; embed securely into the generated script. Execute setup as the intended elevated interactive user, not SYSTEM.
- Do not expose RDP broadly. Clear autologon credentials after validation and deallocate VMs when idle.

## Next Actions

1. Review the committed fixes and finish regression gaps/docs described above.
2. Update PR #8 with the final scope and current evidence; the handover push updates its branch automatically.
3. Rebuild the disposable client/Server rig in VS_Sub_MRL, then validate fresh setup with `-force`/reboot resume and upgrade from **published v2.5.2** to the exact PR commit.
4. Exercise failed-package retry, role/work-folder changes, second-user shell/WSL/context setup, configuration migration and identity preservation, Docker upgrades, and Linux failure with an existing daemon. Verify consuming tools and both Docker HTTP APIs/container runs.
5. Record actual outcomes and failures in `VALIDATION-HISTORY.md` and update the open gate in `TODO.md`. Keep claims of local checks distinct from real-machine evidence.
