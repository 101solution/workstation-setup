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
filter timestamp { "$(Get-Date -Format o): $_" }

$logFilePath = "$PSScriptRoot\logs\workstation-config.log"
if (-not (Test-Path $logFilePath)) {
    Write-Output "Create log file $logFilePath..." | timestamp
    New-Item -Path $logFilePath -ItemType File -Force | Out-Null
}
$null = Start-Transcript $logFilePath -Append

Write-Output "Loading helper script..." | timestamp
. $PSScriptRoot\helper.ps1

# Rebuild the exact invocation to replay after a reboot, before anything can mutate $PSBoundParameters.
$resumeCommand = Get-ResumeCommand -ScriptPath (Join-Path $PSScriptRoot 'config-workstation.ps1') `
    -BoundParameters $PSBoundParameters

if ($force) {
    Write-Output "-force supplied: discarding any saved progress." | timestamp
    Clear-SetupState
}

$state = Get-SetupState
$state.runCount = [int]$state.runCount + 1
Save-SetupState -State $state

# Invoke-SetupPhase, Request-PhaseReboot and Invoke-RebootGate come from helper.ps1 and are shared
# with config-github-runner.ps1 and docker-ce/config-docker.ps1. They operate on $state and the
# $rebootPending / $rebootReason flags in this script's scope.

Write-Output "" | timestamp
Write-Output "=== Workstation setup: role '$role', run #$($state.runCount), $($state.rebootCount) reboot(s) so far ===" | timestamp
if (@($state.completedPhases).Count -gt 0) {
    Write-Output "Resuming. Already complete: $((@($state.completedPhases) -join ', '))" | timestamp
}

# ---------------------------------------------------------------------------------------------
# Phase: preflight. Make the package sources non-interactive and note any reboot Windows already
# owes us. We record it rather than acting on it now, so it can be merged into the single restart.
# ---------------------------------------------------------------------------------------------
Invoke-SetupPhase -Phase 'preflight' -Body {
    Write-Output "Register NuGet source ..." | timestamp
    Register-PackageSource -provider NuGet -name nugetRepository -location https://www.nuget.org/api/v2 `
        -ForceBootstrap -Force -ErrorAction SilentlyContinue | Out-Null

    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null

    # Without this, Install-Module stops to confirm an untrusted repository.
    Write-Output "Trusting the PSGallery repository so module installs do not prompt ..." | timestamp
    if (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue) {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    }

    if (Test-PendingReboot) {
        Write-Warning "Windows already has a reboot outstanding. Continuing, and folding it into the single restart later; if package installs misbehave, reboot and re-run."
    }
}

Write-Output "Getting package config ..." | timestamp
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
        Write-Output "Skipping WSL (-enableWSL `$false)." | timestamp
        return
    }
    Write-Output "Enabling the WSL2 optional features ..." | timestamp
    if (Enable-WslFeature) {
        Request-PhaseReboot -Reason 'the WSL2 optional features need a restart before a distro can be registered'
        Write-Output "Features enabled; a restart is owed before the distro can be registered." | timestamp
    }
    else {
        Write-Output "WSL optional features are enabled and need no restart." | timestamp
    }
}

# ---------------------------------------------------------------------------------------------
# Phases: everything that does NOT need a restart. These run before the reboot gate so a fresh
# machine ends up fully configured except for the WSL distro.
# ---------------------------------------------------------------------------------------------
Invoke-SetupPhase -Phase 'winget' -Body {
    $wingetPackages = ($packageConfigBase.winget + $packageConfig.winget) | Select-Object -Unique -Property id, source, override
    if (-not $wingetPackages -or $wingetPackages.Count -eq 0) {
        Write-Output "No winget packages for role '$role'." | timestamp
        return
    }
    #call winget list as the first time it takes some time to load
    Write-Output "Run winget list ..." | timestamp
    winget list --accept-source-agreements | Out-Null
    Start-Sleep -Milliseconds 2000
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
Write-Output "Update Environment Variables in the session"  | timestamp
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
    pwsh.exe -command "& {Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Force}" | Out-Null

    Write-Output "Copy ps profile"  | timestamp
    $psProfilePath = $PROFILE.CurrentUserAllHosts -Replace "WindowsPowerShell", "Powershell"
    Write-Output "Creating ps profile $psProfilePath"  | timestamp
    New-Item -ItemType File -Path $psProfilePath -Force | Out-Null

    $profileContent = Get-Content "$PSScriptRoot/profile.ps1" -Encoding UTF8
    $profileContent -replace "#workFolder#", $defaultWorkFolder | Out-File -LiteralPath $psProfilePath -Encoding utf8 -Force
    Unblock-File -LiteralPath $psProfilePath

    if (-not (Test-Path -Path $defaultWorkFolder -PathType Container)) {
        Write-Output "Create folder $defaultWorkFolder"  | timestamp
        New-Item -Path $defaultWorkFolder -ItemType Directory -Force | Out-Null
    }

    Write-Output "Copy oh-my-posh theme"  | timestamp
    $poshContent = Get-Content "$PSScriptRoot/rudolfs-light-cs.omp.json" -Encoding UTF8
    $poshContent -replace "#workFolder#", [regex]::escape($defaultWorkFolder) | Out-File -LiteralPath "$($env:POSH_THEMES_PATH)\rudolfs-light-cs.omp.json" -Encoding utf8 -Force

    Write-Output "Copy git config..."  | timestamp
    Copy-Item "$PSScriptRoot/.gitconfig" -Destination $env:UserProfile -Force
    if ("" -ne $gitUser) {
        Write-Output "Set Git User ..."  | timestamp
        git config --global user.name $gitUser
    }
    if ("" -ne $gitEmail) {
        Write-Output "Set Git User Email..."  | timestamp
        git config --global user.email $gitEmail
    }
}

Invoke-SetupPhase -Phase 'terminal' -Body {
    $terminalSettingFile = "$($env:LocalAppData)\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
    if (-not (Test-Path -LiteralPath $terminalSettingFile)) {
        Write-Output "Settings file not created yet, open Windows Terminal to force it created..."  | timestamp
        # if terminal never run, the settings file will not exist, so need to force it to create by running wt.exe
        Start-Process -FilePath "wt.exe" -ArgumentList "-h"
        Start-Sleep -Milliseconds 800
        Get-Process -Name "WindowsTerminal" -ErrorAction SilentlyContinue | Stop-Process -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $terminalSettingFile)) {
        Write-Warning "Windows Terminal settings file still absent; skipping terminal configuration."
        return
    }

    Write-Output "Update Windows Terminal Settings"  | timestamp
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
    $terminalSettings | ConvertTo-Json -Depth 10 | Format-Json | Out-File $terminalSettingFile -Force -Encoding utf8
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
        Write-Output "Skipping WSL distro registration (-enableWSL `$false)." | timestamp
        return
    }
    $wslCommand = Get-Command -Name wsl.exe -ErrorAction SilentlyContinue
    if (-not $wslCommand) {
        Write-Warning "wsl.exe was not found even though the optional features are enabled; skipping WSL."
        return
    }

    Write-Output "Updating the WSL runtime ..." | timestamp
    & wsl.exe --update | Out-Null
    & wsl.exe --set-default-version 2 | Out-Null

    if (Install-WslDistribution -DistroName 'Ubuntu') {
        Initialize-WslUser -DistroName 'Ubuntu' | Out-Null
    }
}

# ---------------------------------------------------------------------------------------------
# Done: retire every resume hook so a later logon does not re-run setup.
# ---------------------------------------------------------------------------------------------
Complete-Phase -State $state -Phase 'done'
Clear-ResumeHooks -Name $taskName

Write-Output "" | timestamp
Write-Output "=== Workstation setup finished for role '$role' ===" | timestamp
Write-Output "  Runs: $($state.runCount)   Reboots: $($state.rebootCount)" | timestamp
Write-Output "  Phases completed: $((@($state.completedPhases) -join ', '))" | timestamp
Write-Output "  State file: $(Get-SetupStatePath)" | timestamp
Write-Output "  Re-run with -force to redo every phase from scratch." | timestamp

$null = Stop-Transcript
Rename-Item -Path $logFilePath -NewName "workstation-config-$(Get-Date -Format FileDateTime).log" -Force
exit 0
