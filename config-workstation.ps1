#Requires -RunAsAdministrator
<#
    Configures a Windows workstation from a role-based package manifest.

    UNATTENDED BY DESIGN
    No step prompts for input. Phases are ordered so that at most ONE reboot is ever needed, and it
    falls as late as possible: the WSL optional features are enabled early (cheap, no restart), then
    all the slow work runs, and only registering the WSL distro has to wait for the restart.

    Progress is recorded in %ProgramData%\workstation-setup\setup-state.json - deliberately outside
    the repo, so get-latestPackages.ps1 re-downloading the release cannot discard it. Every phase is
    idempotent, so re-running the same command is always safe and skips completed work.

    RESUMING AFTER THE REBOOT (-resumeMethod)
      ScheduledTask (default) A logon-triggered elevated task finishes the job with no human input.
                              This is the only option that is genuinely hands-off, because coming
                              back elevated after a reboot requires a task, a service, or autologon.
      RunOnce                 No scheduled task. An HKLM RunOnce entry relaunches setup and, because
                              RunOnce runs with a filtered token, asks for one UAC consent. The
                              entry deletes itself once it fires.
      None                    Arms nothing. Re-run the same command after the reboot; only the
                              unfinished WSL phase is left, so it completes in seconds.

    .EXAMPLE
        .\config-workstation.ps1 -role mrldev -gitUser "Name" -gitEmail "name@example.com"

    .EXAMPLE
        # No scheduled task; finish by re-running the same line after the restart.
        .\config-workstation.ps1 -role mrl -resumeMethod None

    .EXAMPLE
        # Image pipeline: never restart, exit 3010 when one is owed, pipeline sequences the reboot.
        .\config-workstation.ps1 -role mrl -resumeMethod None -noReboot

    .EXAMPLE
        # Discard saved progress and run every phase again.
        .\config-workstation.ps1 -role mrl -force
#>
[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $role = "mrldev",
    [Parameter()]
    [string]
    $taskName = "workstation-config-resume",
    [Parameter()]
    [boolean]
    $enableWSL = $true,
    [Parameter()]
    [string]
    $gitUser = "",
    [Parameter()]
    [string]
    $gitEmail = "",
    [Parameter()]
    [string]
    $defaultWorkFolder = "c:\projects",
    [Parameter(HelpMessage = "How setup comes back after a reboot. See the comment-based help.")]
    [ValidateSet('ScheduledTask', 'RunOnce', 'None')]
    [string]
    $resumeMethod = 'ScheduledTask',
    [Parameter(HelpMessage = "Record that a reboot is owed and exit 3010 instead of restarting.")]
    [switch]
    $noReboot,
    [Parameter(HelpMessage = "Ignore saved progress and re-run every phase.")]
    [switch]
    $force
)

$ErrorActionPreference = 'Continue'

$logFilePath = "$PSScriptRoot\logs\workstation-config.log"
if (-not (Test-Path $logFilePath)) {
    New-Item -Path $logFilePath -ItemType File -Force | Out-Null
}
$null = Start-Transcript $logFilePath -Append

# All logging goes through Write-SetupLog (defined in helper.ps1), so nothing is logged before this.
. $PSScriptRoot\helper.ps1
Write-SetupLog "Helper loaded from $PSScriptRoot\helper.ps1"

# Rebuild the exact invocation to replay after a reboot, before anything can mutate $PSBoundParameters.
$resumeCommand = Get-ResumeCommand -ScriptPath (Join-Path $PSScriptRoot 'config-workstation.ps1') `
    -BoundParameters $PSBoundParameters

if ($force) {
    Write-SetupLog "-force supplied: discarding any saved progress."
    Clear-SetupState
}

$state = Get-SetupState
$state.runCount = [int]$state.runCount + 1
Save-SetupState -State $state

# Invoke-SetupPhase, Request-PhaseReboot and Invoke-RebootGate come from helper.ps1 and are shared
# with docker-ce/config-docker.ps1. They operate on $state and the $rebootPending / $rebootReason
# flags in this script's scope.

Write-SetupLog ""
Write-SetupLog "=== Workstation setup: role '$role', run #$($state.runCount), $($state.rebootCount) reboot(s) so far ==="
if (@($state.completedPhases).Count -gt 0) {
    Write-SetupLog "Resuming. Already complete: $((@($state.completedPhases) -join ', '))"
}

# ---------------------------------------------------------------------------------------------
# Phase: preflight. Make the package sources non-interactive and note any reboot Windows already
# owes us. We record it rather than acting on it now, so it can be merged into the single restart.
# ---------------------------------------------------------------------------------------------
Invoke-SetupPhase -Phase 'preflight' -Body {
    Write-SetupLog "Register NuGet source ..."
    Register-PackageSource -provider NuGet -name nugetRepository -location https://www.nuget.org/api/v2 `
        -ForceBootstrap -Force -ErrorAction SilentlyContinue | Out-Null

    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null

    # Without this, Install-Module stops to confirm an untrusted repository.
    Write-SetupLog "Trusting the PSGallery repository so module installs do not prompt ..."
    if (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue) {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    }

    if (Test-PendingReboot) {
        Write-Warning "Windows already has a reboot outstanding. Continuing, and folding it into the single restart later; if package installs misbehave, reboot and re-run."
    }
}

Write-SetupLog "Getting package config ..."
$packageConfigBase = Get-Content $PSScriptRoot\packages-min.json | ConvertFrom-Json
if ($role -ne 'min') {
    $packageConfig = Get-Content $PSScriptRoot\packages-$role.json | ConvertFrom-Json
}

# ---------------------------------------------------------------------------------------------
# Phase: WSL optional features. Deliberately FIRST and -NoRestart, so the restart it may demand is
# known up front but paid for once, at the end, after everything else has installed.
# ---------------------------------------------------------------------------------------------
Invoke-SetupPhase -Phase 'wsl-features' -Body {
    if (-not $enableWSL) {
        Write-SetupLog "Skipping WSL (-enableWSL `$false)."
        return
    }
    Write-SetupLog "Enabling the WSL2 optional features ..."
    if (Enable-WslFeature) {
        Request-PhaseReboot -Reason 'the WSL2 optional features need a restart before a distro can be registered'
        Write-SetupLog "Features enabled; a restart is owed before the distro can be registered."
    }
    else {
        Write-SetupLog "WSL optional features are enabled and need no restart."
    }
}

# ---------------------------------------------------------------------------------------------
# Phases: everything that does NOT need a restart. These run before the reboot gate so a fresh
# machine ends up fully configured except for the WSL distro.
# ---------------------------------------------------------------------------------------------
Invoke-SetupPhase -Phase 'winget' -Body {
    $wingetPackages = ($packageConfigBase.winget + $packageConfig.winget) | Select-Object -Unique -Property id, source, override
    if (-not $wingetPackages -or $wingetPackages.Count -eq 0) {
        Write-SetupLog "No winget packages for role '$role'."
        return
    }
    # A brand-new user profile has App Installer installed machine-wide but no per-user `winget`
    # alias yet (see TODO G15), so resolve the executable rather than assuming it is on PATH.
    $winget = Get-WinGetPath
    if (-not $winget) {
        Write-SetupLog "winget not found for this user; installing App Installer ..."
        Install-WinGet
        Update-SessionEnvironment
        $winget = Get-WinGetPath
    }
    if (-not $winget) {
        throw "winget is unavailable in this session, so no packages can be installed. Every later phase that needs an installed tool (pwsh, git, oh-my-posh, Windows Terminal) will fail too."
    }
    Write-SetupLog "Using winget at $winget"
    foreach ($pack in $wingetPackages) {
        if ($pack.override) {
            Install-WinGetPackage -packageId $pack.id -overrideParameters $pack.override -source $pack.source
        }
        else {
            Install-WinGetPackage -packageId $pack.id -source $pack.source
        }
    }
}

#Reload environment variables for the session
Write-SetupLog "Update Environment Variables in the session"
Update-SessionEnvironment

Invoke-SetupPhase -Phase 'fonts' -Body {
    Install-Fonts -fontFolder $PSScriptRoot
}

Invoke-SetupPhase -Phase 'psmodules' -Body {
    $psModules = ($packageConfigBase.powershellModule + $packageConfig.powershellModule) | Select-Object -Unique -Property name
    foreach ($module in $psModules) {
        Install-PSModule -PsModuleName $module.name
    }
}

# All per-user, which is why the resume task runs as the invoking user and never as SYSTEM.
Invoke-SetupPhase -Phase 'shell' -Body {
    # Everything below is configuration for tools the winget phase installs. Fail with a clear
    # message rather than a cascade of "not recognized" errors if that phase did not complete.
    $pwsh = Get-Command -Name pwsh.exe -ErrorAction SilentlyContinue
    if (-not $pwsh -and (Test-Path -LiteralPath "$env:ProgramFiles\PowerShell\7\pwsh.exe")) {
        $pwsh = Get-Command -Name "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    }
    if (-not $pwsh) {
        throw "pwsh.exe not found. This phase depends on the winget phase installing Microsoft.PowerShell; it will be retried once that has succeeded."
    }
    & $pwsh.Source -command "& {Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Force}" | Out-Null

    Write-SetupLog "Copy ps profile"
    $psProfilePath = $PROFILE.CurrentUserAllHosts -Replace "WindowsPowerShell", "Powershell"
    Write-SetupLog "Creating ps profile $psProfilePath"
    New-Item -ItemType File -Path $psProfilePath -Force | Out-Null

    $profileContent = Get-Content "$PSScriptRoot/profile.ps1" -Encoding UTF8
    $profileContent -replace "#workFolder#", $defaultWorkFolder | Out-File -LiteralPath $psProfilePath -Encoding utf8 -Force
    Unblock-File -LiteralPath $psProfilePath

    if (-not (Test-Path -Path $defaultWorkFolder -PathType Container)) {
        Write-SetupLog "Create folder $defaultWorkFolder"
        New-Item -Path $defaultWorkFolder -ItemType Directory -Force | Out-Null
    }

    # Only when the role actually asks for oh-my-posh: a machine that does not install it should
    # not download a standalone copy, nor be warned about a package it never wanted.
    $poshConfigured = @(($packageConfigBase.winget + $packageConfig.winget) |
        Where-Object { $_.id -eq 'JanDeDobbeleer.OhMyPosh' }).Count -gt 0
    if ($poshConfigured) { Install-OhMyPoshStandalone }

    Write-SetupLog "Copy oh-my-posh theme"
    # POSH_THEMES_PATH is a user env var written by the Oh My Posh installer; the session may not
    # have it yet, and without this guard the theme would be written to the drive root.
    $poshThemesPath = $env:POSH_THEMES_PATH
    if ([string]::IsNullOrWhiteSpace($poshThemesPath)) {
        $poshThemesPath = Join-Path $env:LOCALAPPDATA 'Programs\oh-my-posh\themes'
        Write-SetupLog "POSH_THEMES_PATH not set in this session; using $poshThemesPath"
    }
    if (-not (Test-Path -LiteralPath $poshThemesPath)) {
        New-Item -Path $poshThemesPath -ItemType Directory -Force | Out-Null
    }
    $poshContent = Get-Content "$PSScriptRoot/rudolfs-light-cs.omp.json" -Encoding UTF8
    # BOM-less: oh-my-posh is a Go program and rejects a JSON config that starts with one.
    $poshJson = ($poshContent -replace "#workFolder#", [regex]::escape($defaultWorkFolder)) -join [Environment]::NewLine
    Save-Utf8NoBom -Path "$poshThemesPath\rudolfs-light-cs.omp.json" -Content $poshJson

    Write-SetupLog "Copy git config..."
    Copy-Item "$PSScriptRoot/.gitconfig" -Destination $env:UserProfile -Force
    if (("" -ne $gitUser -or "" -ne $gitEmail) -and -not (Get-Command -Name git.exe -ErrorAction SilentlyContinue)) {
        throw "git.exe not found, so -gitUser/-gitEmail cannot be applied. This phase depends on the winget phase installing Git.Git."
    }
    if ("" -ne $gitUser) {
        Write-SetupLog "Set Git User ..."
        git config --global user.name $gitUser
    }
    if ("" -ne $gitEmail) {
        Write-SetupLog "Set Git User Email..."
        git config --global user.email $gitEmail
    }
}

Invoke-SetupPhase -Phase 'terminal' -Body {
    $terminalSettingFile = "$($env:LocalAppData)\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
    if (-not (Test-Path -LiteralPath $terminalSettingFile)) {
        # Windows Terminal is in-box on Windows 11 and also in packages-min.json, but like winget its
        # per-user alias can be missing on a new profile (TODO G16); resolve it the same way.
        $wt = Get-WindowsTerminalPath
        if (-not $wt) {
            throw "wt.exe not found. This phase depends on Windows Terminal (in-box, or Microsoft.WindowsTerminal from the winget phase); it will be retried on the next run."
        }
        Write-SetupLog "Settings file not created yet, open Windows Terminal to force it created..."
        # if terminal never run, the settings file will not exist, so need to force it to create by running wt.exe
        Start-Process -FilePath $wt -ArgumentList "-h"
        $deadline = (Get-Date).AddSeconds(20)
        while (-not (Test-Path -LiteralPath $terminalSettingFile) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
        }
        Get-Process -Name "WindowsTerminal" -ErrorAction SilentlyContinue | Stop-Process -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $terminalSettingFile)) {
        Write-Warning "Windows Terminal settings file still absent; skipping terminal configuration."
        return
    }

    Write-SetupLog "Update Windows Terminal Settings"
    $defaultSettings = Get-Content -LiteralPath "$PSScriptRoot\terminal-default-settings.json" | ConvertFrom-Json
    $defaultSettings.startingDirectory = $defaultWorkFolder
    $terminalSettings = Get-Content -LiteralPath $terminalSettingFile | ConvertFrom-Json
    # Merge into profiles.defaults rather than replacing the node, so customisation the user has
    # already made (colour scheme, opacity, padding) survives a re-run of this script.
    if ($null -eq $terminalSettings.profiles) {
        $terminalSettings | Add-Member -NotePropertyName 'profiles' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if ($null -eq $terminalSettings.profiles.defaults) {
        $terminalSettings.profiles | Add-Member -NotePropertyName 'defaults' -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    foreach ($property in $defaultSettings.PSObject.Properties) {
        $terminalSettings.profiles.defaults | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
    }
    $terminalJson = $terminalSettings | ConvertTo-Json -Depth 10 | Format-Json
    Save-Utf8NoBom -Path $terminalSettingFile -Content $terminalJson
}

# ---------------------------------------------------------------------------------------------
# The single reboot gate. Everything above is done; only the WSL distro is left.
# ---------------------------------------------------------------------------------------------
Invoke-RebootGate -State $state -TaskName $taskName -ResumeCommand $resumeCommand -ResumeMethod $resumeMethod `
    -WorkingDirectory $PSScriptRoot -NoReboot:$noReboot -BeforeExit {
        $null = Stop-Transcript
        Rename-Item -Path $logFilePath -NewName "workstation-config-$(Get-Date -Format FileDateTime).log" -Force
    }

# ---------------------------------------------------------------------------------------------
# Phase: register the WSL distro and provision its user without the interactive first-run setup.
# ---------------------------------------------------------------------------------------------
Invoke-SetupPhase -Phase 'wsl-distro' -Body {
    if (-not $enableWSL) {
        Write-SetupLog "Skipping WSL distro registration (-enableWSL `$false)."
        return
    }
    $wslCommand = Get-Command -Name wsl.exe -ErrorAction SilentlyContinue
    if (-not $wslCommand) {
        Write-Warning "wsl.exe was not found even though the optional features are enabled; skipping WSL."
        return
    }

    Write-SetupLog "Updating the WSL runtime ..."
    & wsl.exe --update | Out-Null
    & wsl.exe --set-default-version 2 | Out-Null

    # Both helpers return $false (with a warning) on failure. Throw so the phase is NOT recorded
    # complete and is retried next run (TODO G18: run 1 recorded a failed registration as done).
    if (-not (Install-WslDistribution -DistroName 'Ubuntu')) {
        throw "Ubuntu could not be registered without user interaction."
    }
    if (-not (Initialize-WslUser -DistroName 'Ubuntu')) {
        throw "Ubuntu is registered but its user could not be provisioned."
    }
}

# ---------------------------------------------------------------------------------------------
# Done: retire every resume hook; record 'done' and exit 0 only if no phase failed.
# ---------------------------------------------------------------------------------------------
Complete-Setup -State $state -TaskName $taskName -Title "Workstation setup for role '$role'"

$null = Stop-Transcript
Rename-Item -Path $logFilePath -NewName "workstation-config-$(Get-Date -Format FileDateTime).log" -Force
exit $SetupExitCode
