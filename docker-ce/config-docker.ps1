#Requires -RunAsAdministrator
<#
    Docker without Docker Desktop: a Windows daemon on tcp://127.0.0.1:2378 (reached with
    `docker -c win`) and a Linux daemon inside WSL2 Ubuntu on tcp://127.0.0.1:2375 (bare `docker`),
    running side by side.

    Orchestrates ./install-docker-ce.ps1 (Windows) and ./install-docker-ce.sh (Ubuntu) with the same
    phase/resume machinery as config-workstation.ps1 (see helper.ps1). The Containers feature, plus
    Hyper-V on client SKUs, is enabled first with -NoRestart; then there is a single reboot gate; then
    both daemons are installed on the far side of it. Progress is recorded in
    %ProgramData%\workstation-setup\docker-ce-state.json, so re-running is always safe and -force
    starts over. -resumeMethod, -noReboot and -force behave exactly as in config-workstation.ps1.

    Prerequisite: WSL2 with an Ubuntu distro whose default user has passwordless sudo, which is what
    config-workstation.ps1 provisions. Can be run from any directory.

    .EXAMPLE
        .\config-docker.ps1

    .EXAMPLE
        # Image pipeline: never restart, exit 3010 when one is owed, pipeline sequences the reboot.
        .\config-docker.ps1 -resumeMethod None -noReboot
#>
[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $taskName = "docker-ce-config-resume",
    [Parameter()]
    [string]
    $distroName = "Ubuntu",
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

$repoRoot = Split-Path -Parent $PSScriptRoot
$logFilePath = "$repoRoot\logs\docker-ce-config.log"
if (-not (Test-Path $logFilePath)) {
    Write-Output "Create log file $logFilePath..." | timestamp
    New-Item -Path $logFilePath -ItemType File -Force | Out-Null
}
$null = Start-Transcript $logFilePath -Append
$finishLog = {
    $null = Stop-Transcript
    Rename-Item -Path $logFilePath -NewName "docker-ce-config-$(Get-Date -Format FileDateTime).log" -Force
}

Write-Output "Loading helper script..." | timestamp
. "$repoRoot\helper.ps1"
$script:SetupStateFileName = 'docker-ce-state.json'

# install-docker-ce.ps1 and install-docker-ce.sh use paths relative to the current directory.
Set-Location $PSScriptRoot

# Rebuild the exact invocation to replay after a reboot, before anything can mutate $PSBoundParameters.
$resumeCommand = Get-ResumeCommand -ScriptPath (Join-Path $PSScriptRoot 'config-docker.ps1') `
    -BoundParameters $PSBoundParameters

if ($force) {
    Write-Output "-force supplied: discarding any saved progress." | timestamp
    Clear-SetupState
}

$state = Get-SetupState
$state.runCount = [int]$state.runCount + 1
Save-SetupState -State $state

Write-Output "" | timestamp
Write-Output "=== Docker CE setup: run #$($state.runCount), $($state.rebootCount) reboot(s) so far ===" | timestamp
if (@($state.completedPhases).Count -gt 0) {
    Write-Output "Resuming. Already complete: $((@($state.completedPhases) -join ', '))" | timestamp
}

# ---------------------------------------------------------------------------------------------
# Phase: Windows features. FIRST and -NoRestart, so the one restart is paid before any install.
# ---------------------------------------------------------------------------------------------
Invoke-SetupPhase -Phase 'containers-feature' -Body {
    Write-Output "Enabling the Windows features the Docker daemon needs ..." | timestamp
    if (Enable-ContainerFeature) {
        Request-PhaseReboot -Reason 'the Containers feature needs a restart before the Windows Docker daemon can start'
        Write-Output "Features enabled; a restart is owed before Docker can be installed." | timestamp
    }
    else {
        Write-Output "Container features are enabled and need no restart." | timestamp
    }
}

# Per-user, idempotent, and independent of both daemons; so it also covers a box where Docker was
# already installed and the docker-windows phase therefore does nothing.
Invoke-SetupPhase -Phase 'environment' -Body {
    Write-Output "Pointing bare `docker` at the Linux daemon and propagating BASH_ENV into WSL ..." | timestamp
    [Environment]::SetEnvironmentVariable("WSLENV", "BASH_ENV/u", [System.EnvironmentVariableTarget]::User)
    [Environment]::SetEnvironmentVariable("BASH_ENV", "/etc/bash.bashrc", [System.EnvironmentVariableTarget]::User)
    [Environment]::SetEnvironmentVariable("DOCKER_HOST", "tcp://127.0.0.1:2375", [System.EnvironmentVariableTarget]::User)
}

# ---------------------------------------------------------------------------------------------
# The single reboot gate.
# ---------------------------------------------------------------------------------------------
Invoke-RebootGate -State $state -TaskName $taskName -ResumeCommand $resumeCommand -ResumeMethod $resumeMethod `
    -WorkingDirectory $PSScriptRoot -NoReboot:$noReboot -BeforeExit $finishLog

# ---------------------------------------------------------------------------------------------
# Phase: the Windows daemon. install-docker-ce.ps1 exits 3010 if a feature still needs a restart
# (e.g. Windows had one pending that the feature phase could not see), so the gate runs once more.
# ---------------------------------------------------------------------------------------------
Invoke-SetupPhase -Phase 'docker-windows' -Body {
    Write-Output "Configuring Docker on Windows (host) ..." | timestamp
    & "$PSScriptRoot\install-docker-ce.ps1"
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 3010) {
        Request-PhaseReboot -Reason 'install-docker-ce.ps1 reports a Windows feature still needs a restart'
        return
    }
    if ($exitCode -ne 0) {
        throw "install-docker-ce.ps1 exited with $exitCode"
    }
}

Invoke-RebootGate -State $state -TaskName $taskName -ResumeCommand $resumeCommand -ResumeMethod $resumeMethod `
    -WorkingDirectory $PSScriptRoot -NoReboot:$noReboot -BeforeExit $finishLog

# ---------------------------------------------------------------------------------------------
# Phase: the Linux daemon inside WSL2.
# ---------------------------------------------------------------------------------------------
Invoke-SetupPhase -Phase 'docker-linux' -Body {
    if (-not (Get-Command -Name wsl.exe -ErrorAction SilentlyContinue)) {
        throw "wsl.exe not found. Run config-workstation.ps1 first; it enables WSL2 and registers $distroName."
    }
    if (-not (Test-WslDistroRegistered -DistroName $distroName)) {
        throw "WSL distro '$distroName' is not registered. Run config-workstation.ps1 first; it registers $distroName and gives its user passwordless sudo."
    }

    Write-Output "Configuring Docker on Linux (WSL2 $distroName) ..." | timestamp
    # install-docker-ce.sh ends with `sudo shutdown -r now`, which tears down this wsl.exe session,
    # so its exit code is not meaningful. Verify by talking to the daemon on a fresh instance instead.
    & wsl.exe --distribution $distroName -- bash ./install-docker-ce.sh

    Write-Output "Waiting for the Linux daemon to come back on the patched unit file ..." | timestamp
    $ready = $false
    for ($attempt = 1; $attempt -le 12 -and -not $ready; $attempt++) {
        Start-Sleep -Seconds 5
        & wsl.exe --distribution $distroName -- docker version 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $ready = $true }
    }
    if (-not $ready) {
        throw "The Linux Docker daemon in $distroName did not answer after install; check 'wsl -d $distroName -- systemctl status docker'."
    }
    Write-Output "Linux Docker daemon is up." | timestamp
}

# ---------------------------------------------------------------------------------------------
# Done: retire every resume hook so a later logon does not re-run setup.
# ---------------------------------------------------------------------------------------------
Complete-Phase -State $state -Phase 'done'
Clear-ResumeHooks -Name $taskName

Write-Output "" | timestamp
Write-Output "=== Docker CE setup finished ===" | timestamp
Write-Output "  Runs: $($state.runCount)   Reboots: $($state.rebootCount)" | timestamp
Write-Output "  Phases completed: $((@($state.completedPhases) -join ', '))" | timestamp
Write-Output "  State file: $(Get-SetupStatePath)" | timestamp
Write-Output "  Verify in a NEW shell (so DOCKER_HOST is picked up):" | timestamp
Write-Output "    docker run hello-world          # Linux daemon, tcp://127.0.0.1:2375" | timestamp
Write-Output "    docker -c win run hello-world   # Windows daemon, tcp://127.0.0.1:2378" | timestamp

& $finishLog
exit 0
