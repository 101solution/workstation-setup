# PATH auditing and repair. Dot-sourced by profile.ps1 (so the functions are available in every
# shell) and by helper.ps1 (so setup can assert PATH health right after it writes PATH).
#
# WHAT THIS GUARDS, AND WHY IT IS IN THIS REPO. Windows truncates PATH near 2047 characters when a
# process is launched from the GUI (https://github.com/microsoft/vscode/issues/210484). The usual
# cause is not gradual growth but scope mixing - writing the MERGED process PATH back into a single
# scope:
#     [Environment]::SetEnvironmentVariable('Path', $env:Path, 'Machine')
# $env:Path is Machine and User concatenated, so that one line copies the running user's private
# directories into the machine variable for every other user on the box, and roughly doubles the
# merged length. It is G24 in VALIDATION-HISTORY.md: Install-WindowsDocker did exactly this and the
# test VM collected five of azureadmin's directories. It also happened ~4 times on a real
# workstation (2026-08-04), leaving 19 C:\Users\* entries in Machine PATH and 23 machine dirs
# duplicated into User PATH, 3857 characters merged.
#
# The detection that matters: exact-string dedupe does NOT find this, because every entry is
# unique within its own scope. You have to compare ACROSS scopes.
#
# Test-PathHealth -Quiet is string-only - no disk I/O - so it is cheap enough for profile startup
# and for a post-phase assertion. The full audit does touch the disk and is interactive only.

function Get-PathEntry {
    # Split a scope's PATH into entries plus a normalised key for cross-scope comparison.
    param([ValidateSet('User', 'Machine')][string]$Scope)
    [Environment]::GetEnvironmentVariable('Path', $Scope) -split ';' |
        Where-Object { $_ } |
        ForEach-Object {
            [pscustomobject]@{
                Path   = $_
                Key    = $_.TrimEnd('\').ToLowerInvariant()
                InUser = $_ -match '^[A-Za-z]:\\Users\\'
            }
        }
}

function Test-PathHealth {
    <#
    .SYNOPSIS
        Audit User and Machine PATH for truncation risk and scope mixing.
    .PARAMETER Quiet
        Emit nothing; return $true if healthy, $false if any issue found. The -Quiet path must
        stay free of success-stream output so `if (Test-PathHealth -Quiet)` cannot be fooled by a
        stray string - see the Write-SetupLog note in CLAUDE.md for what that bug looks like.
    #>
    [CmdletBinding()]
    param([switch]$Quiet)

    $u = Get-PathEntry -Scope User
    $m = Get-PathEntry -Scope Machine
    $uLen = ([Environment]::GetEnvironmentVariable('Path', 'User')).Length
    $mLen = ([Environment]::GetEnvironmentVariable('Path', 'Machine')).Length
    $mKeys = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$m.Key, [StringComparer]::OrdinalIgnoreCase)

    # Machine dirs needlessly repeated in User scope.
    $crossScope = $u | Where-Object { -not $_.InUser -and $mKeys.Contains($_.Key) }
    # User-profile dirs sitting in Machine scope: wrong scope, and per-user paths hardcoded
    # machine-wide. This is the G24 signature.
    $wrongScope = $m | Where-Object { $_.InUser }
    $dupeUser = $u | Group-Object Key | Where-Object Count -gt 1
    $dupeMachine = $m | Group-Object Key | Where-Object Count -gt 1

    $issues = @()
    if ($uLen -gt 1800) { $issues += "User PATH $uLen chars (limit ~2047)" }
    if ($mLen -gt 1800) { $issues += "Machine PATH $mLen chars (limit ~2047)" }
    # @() before .Count - a lone Group-Object result surfaces the group's own member count instead
    # of the number of groups, so one duplicate pair reads as "2".
    if ($crossScope) { $issues += "$(@($crossScope).Count) machine dir(s) duplicated into User scope" }
    if ($wrongScope) { $issues += "$(@($wrongScope).Count) user-profile dir(s) in Machine scope" }
    if ($dupeUser) { $issues += "$(@($dupeUser).Count) duplicate(s) within User scope" }
    if ($dupeMachine) { $issues += "$(@($dupeMachine).Count) duplicate(s) within Machine scope" }

    if ($Quiet) { return (-not $issues) }

    Write-Host "User    : $uLen chars, $(@($u).Count) entries" -ForegroundColor Cyan
    Write-Host "Machine : $mLen chars, $(@($m).Count) entries" -ForegroundColor Cyan
    Write-Host "Merged  : $($uLen + $mLen + 1) chars" -ForegroundColor Cyan

    if (-not $issues) { Write-Host "`nPATH is healthy." -ForegroundColor Green; return }

    Write-Host "`nIssues:" -ForegroundColor Yellow
    $issues | ForEach-Object { Write-Host "  - $_" }

    if ($crossScope) {
        Write-Host "`nIn User but already in Machine (safe to drop from User):" -ForegroundColor Yellow
        $crossScope | ForEach-Object { Write-Host "  $($_.Path)" }
    }
    if ($wrongScope) {
        Write-Host "`nUser-profile dirs in Machine scope (move to User):" -ForegroundColor Yellow
        $wrongScope | ForEach-Object { Write-Host "  $($_.Path)" }
    }
    # The disk check is the only I/O here, which is why it is audit-only and never runs at startup.
    $missing = @($u) + @($m) | Where-Object { -not (Test-Path -LiteralPath $_.Path) }
    if ($missing) {
        Write-Host "`nDo not exist on disk:" -ForegroundColor Yellow
        $missing | Select-Object -Unique Path | ForEach-Object { Write-Host "  $($_.Path)" }
    }
    Write-Host "`nFix with: Repair-PathHealth -Scope User    (Machine scope needs an elevated shell)" -ForegroundColor Cyan
}

function Repair-PathHealth {
    <#
    .SYNOPSIS
        Rewrite a PATH scope: drop wrong-scope, non-existent and duplicate entries.
    .DESCRIPTION
        User scope    - drops entries already provided by Machine scope (excluding user-profile
                        dirs, which legitimately belong in User).
        Machine scope - drops user-profile dirs, which do not belong in a machine-wide variable.
                        Requires elevation.
        Both          - drop dirs missing from disk, and duplicates. Order is preserved.
        Backs the old value up before writing. Setup never calls this: it mutates machine state
        and needs a human to look at what it is about to drop.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidateSet('User', 'Machine')][string]$Scope)

    if ($Scope -eq 'Machine') {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw "Machine scope requires an elevated shell."
        }
    }

    $old = [Environment]::GetEnvironmentVariable('Path', $Scope)
    $entries = Get-PathEntry -Scope $Scope
    $other = if ($Scope -eq 'User') {
        [System.Collections.Generic.HashSet[string]]::new(
            [string[]](Get-PathEntry -Scope Machine).Key, [StringComparer]::OrdinalIgnoreCase)
    }
    else { $null }

    $keep = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $dropped = @()

    foreach ($e in $entries) {
        $why = switch ($true) {
            { $Scope -eq 'Machine' -and $e.InUser } { 'user-profile dir in Machine scope'; break }
            { $Scope -eq 'User' -and -not $e.InUser -and $other.Contains($e.Key) } { 'already in Machine scope'; break }
            { -not (Test-Path -LiteralPath $e.Path) } { 'does not exist'; break }
            { -not $seen.Add($e.Key) } { 'duplicate'; break }
            default { $null }
        }
        if ($why) { $dropped += [pscustomobject]@{ Path = $e.Path; Reason = $why } }
        else { $keep.Add($e.Path) }
    }

    $new = $keep -join ';'
    $dropped | Format-Table -AutoSize | Out-Host
    Write-Host "$Scope PATH: $($old.Length) -> $($new.Length) chars, $(@($entries).Count) -> $($keep.Count) entries" -ForegroundColor Cyan

    if (-not $dropped) { Write-Host "Nothing to do." -ForegroundColor Green; return }

    if ($PSCmdlet.ShouldProcess("$Scope PATH", "drop $(@($dropped).Count) entries")) {
        # Backup goes under LOCALAPPDATA rather than a tool-specific folder: this is a workstation
        # artefact, and the directory has to exist on a freshly provisioned box with nothing else
        # installed.
        $dir = Join-Path $env:LOCALAPPDATA 'workstation-setup'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $bk = Join-Path $dir "$($Scope.ToLower())-path-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
        $old | Set-Content -LiteralPath $bk -Encoding UTF8
        [Environment]::SetEnvironmentVariable('Path', $new, $Scope)
        Write-Host "backup: $bk" -ForegroundColor DarkGray
        Write-Host "$Scope PATH updated. Open a new shell to pick it up." -ForegroundColor Green
    }
}
