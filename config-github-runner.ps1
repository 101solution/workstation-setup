#Requires -RunAsAdministrator
<#
    Installs the PREREQUISITES for a GitHub Actions self-hosted runner: the packages listed in
    packages-<role>.json plus Docker Engine for Windows containers.

    It does NOT download, register or start the runner agent itself. That needs a registration
    token and a target repo/org, so fetch the actions-runner release and run .\config.cmd manually
    once this script completes.

    Unlike config-workstation.ps1 this script does NOT merge packages-min.json: a runner box gets
    exactly what its manifest lists.

    UNATTENDED AND RESUMABLE
    Same phase machinery as config-workstation.ps1 (see helper.ps1). The Containers feature (plus
    Hyper-V on client SKUs) is enabled first with -NoRestart, every package install runs, then there
    is a single reboot gate, and Docker Engine is registered and started on the far side of it,
    because dockerd cannot start until the Containers feature is live. Progress is recorded in
    %ProgramData%\workstation-setup\gh-runner-state.json, so re-running is always safe and -force
    starts over. -resumeMethod, -noReboot and -force behave exactly as in config-workstation.ps1.

    .EXAMPLE
        .\config-github-runner.ps1

    .EXAMPLE
        # Image pipeline: never restart, exit 3010 when one is owed, pipeline sequences the reboot.
        .\config-github-runner.ps1 -resumeMethod None -noReboot
#>
[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $role = "runner",
    [Parameter()]
    [string]
    $taskName = "gh-runner-config-resume",
    [Parameter(HelpMessage = "How setup comes back after a reboot: ScheduledTask, RunOnce or None.")]
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

$logFilePath = "$PSScriptRoot\logs\gh-runner-config.log"
if (-not (Test-Path $logFilePath)) {
    Write-Output "Create log file $logFilePath..." | timestamp
    New-Item -Path $logFilePath -ItemType File -Force | Out-Null
}
$null = Start-Transcript $logFilePath -Append
$finishLog = {
    $null = Stop-Transcript
    Rename-Item -Path $logFilePath -NewName "gh-runner-config-$(Get-Date -Format FileDateTime).log" -Force
}

Write-Output "Loading helper script..." | timestamp
. $PSScriptRoot\helper.ps1
# Own state file, so the 'winget' / 'psmodules' phases here never collide with config-workstation.ps1.
$script:SetupStateFileName = 'gh-runner-state.json'

# Rebuild the exact invocation to replay after a reboot, before anything can mutate $PSBoundParameters.
$resumeCommand = Get-ResumeCommand -ScriptPath (Join-Path $PSScriptRoot 'config-github-runner.ps1') `
    -BoundParameters $PSBoundParameters

if ($force) {
    Write-Output "-force supplied: discarding any saved progress." | timestamp
    Clear-SetupState
}

$state = Get-SetupState
$state.runCount = [int]$state.runCount + 1
Save-SetupState -State $state

Write-Output "" | timestamp
Write-Output "=== Runner prerequisites: role '$role', run #$($state.runCount), $($state.rebootCount) reboot(s) so far ===" | timestamp
if (@($state.completedPhases).Count -gt 0) {
    Write-Output "Resuming. Already complete: $((@($state.completedPhases) -join ', '))" | timestamp
}

# ---------------------------------------------------------------------------------------------
# Phase: preflight. Non-interactive package sources; note any reboot Windows already owes.
# ---------------------------------------------------------------------------------------------
Invoke-SetupPhase -Phase 'preflight' -Body {
    Write-Output "Register NuGet source ..." | timestamp
    Register-PackageSource -provider NuGet -name nugetRepository -location https://www.nuget.org/api/v2 `
        -ForceBootstrap -Force -ErrorAction SilentlyContinue | Out-Null
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null

    Write-Output "Trusting the PSGallery repository so module installs do not prompt ..." | timestamp
    if (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue) {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    }

    if (Test-PendingReboot) {
        Write-Warning "Windows already has a reboot outstanding. Continuing, and folding it into the single restart later; if package installs misbehave, reboot and re-run."
    }
}

Write-Output "Getting package config ..." | timestamp
$packageConfig = Get-Content $PSScriptRoot\packages-$role.json | ConvertFrom-Json
$userToolsPath = "$env:UserProfile\tools"

# ---------------------------------------------------------------------------------------------
# Phase: Windows features for Docker. FIRST and -NoRestart, so the one restart is paid at the end.
# ---------------------------------------------------------------------------------------------
Invoke-SetupPhase -Phase 'containers-feature' -Body {
    Write-Output "Enabling the Windows features Docker Engine needs ..." | timestamp
    if (Enable-ContainerFeature) {
        Request-PhaseReboot -Reason 'the Containers feature needs a restart before the Docker service can start'
        Write-Output "Features enabled; a restart is owed before Docker Engine can be started." | timestamp
    }
    else {
        Write-Output "Container features are enabled and need no restart." | timestamp
    }
}

# ---------------------------------------------------------------------------------------------
# Phases that do NOT need a restart.
# ---------------------------------------------------------------------------------------------
Invoke-SetupPhase -Phase 'winget' -Body {
    $wingetPackages = @($packageConfig.winget)
    if ($wingetPackages.Count -eq 0) {
        Write-Output "No winget packages for role '$role'." | timestamp
        return
    }
    # Windows Server has no inbox winget; a new client profile has it but no per-user alias yet.
    $winget = Get-WinGetPath
    if (-not $winget) {
        Install-WinGet
        Update-SessionEnvironment
        $winget = Get-WinGetPath
    }
    if (-not $winget) {
        throw "winget is unavailable in this session, so no packages can be installed."
    }
    Write-Output "Using winget at $winget" | timestamp
    Write-Output "Run winget list ..." | timestamp
    & $winget list --accept-source-agreements | Out-Null
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

Write-Output "Update Environment Variables in the session" | timestamp
Update-SessionEnvironment

Invoke-SetupPhase -Phase 'psmodules' -Body {
    foreach ($module in @($packageConfig.powershellModule)) {
        Install-PSModule -PsModuleName $module.name
    }
}

# ---------------------------------------------------------------------------------------------
# The single reboot gate. Only Docker Engine is left on the far side of it.
# ---------------------------------------------------------------------------------------------
Invoke-RebootGate -State $state -TaskName $taskName -ResumeCommand $resumeCommand -ResumeMethod $resumeMethod `
    -WorkingDirectory $PSScriptRoot -NoReboot:$noReboot -BeforeExit $finishLog

# ---------------------------------------------------------------------------------------------
# Phase: Docker Engine. Needs the Containers feature live, hence after the gate.
# ---------------------------------------------------------------------------------------------
Invoke-SetupPhase -Phase 'docker-engine' -Body {
    Install-DockerEngine -InstallPath $userToolsPath
}

# ---------------------------------------------------------------------------------------------
# Done: retire every resume hook; record 'done' and exit 0 only if no phase failed.
# ---------------------------------------------------------------------------------------------
Complete-Setup -State $state -TaskName $taskName -Title "Runner prerequisites for role '$role'"
if ($SetupExitCode -eq 0) {
    Write-Output "  Next: download the actions-runner release and run .\config.cmd with a registration token." | timestamp
}

& $finishLog
exit $SetupExitCode
