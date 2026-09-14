#Requires -RunAsAdministrator
<#
    Docker without Docker Desktop: a Windows daemon on tcp://127.0.0.1:2378 (reached with
    `docker -c win`) and a Linux daemon inside WSL2 Ubuntu on tcp://127.0.0.1:2375 (bare `docker`),
    running side by side.

    Installs the Windows daemon itself and drives ./install-docker-ce.sh for Ubuntu, with the same
    phase/resume machinery as config-workstation.ps1 (see helper.ps1). The Containers feature, plus
    Hyper-V on client SKUs, is enabled first with -NoRestart; then there is a single reboot gate; then
    both daemons are installed on the far side of it. Progress is recorded in
    %ProgramData%\workstation-setup\docker-ce-state.json, so re-running is always safe and -force
    starts over. -resumeMethod, -noReboot and -force behave exactly as in config-workstation.ps1.

    Prerequisite: WSL2 with an Ubuntu distro whose default user has passwordless sudo, which is what
    config-workstation.ps1 provisions. Can be run from any directory.

    WHY BARE `docker` NEEDS A LOGON TASK
    The Linux daemon is reachable from Windows only while the WSL distro runs: the relayed
    127.0.0.1:2375 port exists only then, and a Windows-side TCP connect does NOT start the distro.
    install-docker-ce.sh restarts WSL, and WSL2 stops idle distros anyway, so `docker ps` would fail
    after every reboot. The wsl-autostart phase registers an at-logon task running
    `wsl -d <distro> -- /bin/true`, which is enough to bring it up.

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
    [Parameter()]
    [string]
    $dockerVersion = "29.8.0",
    [Parameter(HelpMessage = "Name of the at-logon task that starts the WSL distro.")]
    [string]
    $autostartTaskName = "docker-ce-wsl-autostart",
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

$repoRoot = Split-Path -Parent $PSScriptRoot
$logFilePath = "$repoRoot\logs\docker-ce-config.log"
if (-not (Test-Path $logFilePath)) {
    New-Item -Path $logFilePath -ItemType File -Force | Out-Null
}
$null = Start-Transcript $logFilePath -Append
$finishLog = {
    $null = Stop-Transcript
    Rename-Item -Path $logFilePath -NewName "docker-ce-config-$(Get-Date -Format FileDateTime).log" -Force
}

# All logging goes through Write-SetupLog (defined in helper.ps1), so nothing is logged before this.
. "$repoRoot\helper.ps1"
Write-SetupLog "Helper loaded from $repoRoot\helper.ps1"
$script:SetupStateFileName = 'docker-ce-state.json'

# install-docker-ce.sh is invoked with a path relative to the current directory.
Set-Location $PSScriptRoot

$script:DockerServiceName = 'docker'
$script:DockerDataPath = Join-Path $env:ProgramData 'docker'

# Rebuild the exact invocation to replay after a reboot, before anything can mutate $PSBoundParameters.
$resumeCommand = Get-ResumeCommand -ScriptPath (Join-Path $PSScriptRoot 'config-docker.ps1') `
    -BoundParameters $PSBoundParameters

if ($force) {
    Write-SetupLog "-force supplied: discarding any saved progress."
    Clear-SetupState
}

$state = Get-SetupState
$state.runCount = [int]$state.runCount + 1
Save-SetupState -State $state

Write-SetupLog ""
Write-SetupLog "=== Docker CE setup: run #$($state.runCount), $($state.rebootCount) reboot(s) so far ==="
if (@($state.completedPhases).Count -gt 0) {
    Write-SetupLog "Resuming. Already complete: $((@($state.completedPhases) -join ', '))"
}

# ---------------------------------------------------------------------------------------------
# Windows daemon. Folded in from the former install-docker-ce.ps1 worker: once the feature enabling
# moved to the containers-feature phase, the worker's only reason to be a separate process - exiting
# 3010 to ask for a reboot - became unreachable, and with it the second reboot gate this script used
# to run. Failures now simply throw and Invoke-SetupPhase retries the phase on the next run.
# ---------------------------------------------------------------------------------------------

Function Test-DockerService {
    # Return value is tested, so this must log nothing to the success stream.
    return ($null -ne (Get-Service -Name $script:DockerServiceName -ErrorAction SilentlyContinue))
}

Function Test-TcpPort {
    <#
        .SYNOPSIS
            True when something accepts a TCP connection on the port. Return value is tested.
        .DESCRIPTION
            Used instead of Test-NetConnection, which emits a warning on failure and is slower.
    #>
    [CmdletBinding()]
    param (
        [Parameter()] [string] $ComputerName = '127.0.0.1',
        [Parameter(Mandatory)] [int] $Port,
        [Parameter()] [int] $TimeoutMs = 2000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

Function Install-WindowsDocker {
    <#
        .SYNOPSIS
            Installs, configures and starts the Windows daemon on tcp://127.0.0.1:2378.
        .DESCRIPTION
            Idempotent piece by piece rather than gated on "is the service registered": the service
            is registered several steps before daemon.json and the 'win' context exist, so one
            up-front check made a part-failed install look complete on the retry (G25).
    #>
    if (-not (Test-Path -LiteralPath 'C:\docker\dockerd.exe')) {
        $zipPath = Join-Path $env:TEMP "docker-$dockerVersion.zip"
        Write-SetupLog "  Downloading Docker Engine $dockerVersion ..."
        curl.exe -o $zipPath -L "https://download.docker.com/win/static/stable/x86_64/docker-$dockerVersion.zip"
        if (-not (Test-Path -LiteralPath $zipPath)) {
            throw "Docker Engine download failed; $zipPath was not created."
        }
        Expand-Archive -LiteralPath $zipPath -DestinationPath C:\ -Force
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-SetupLog "  C:\docker\dockerd.exe is already present."
    }

    # Append to the MACHINE Path, never to $env:Path: the process value is Machine and User merged,
    # so writing it back bakes the running user's private directories (WindowsApps, WinGet\Links,
    # .dotnet\tools, ...) into the machine Path for every other user on the box. Verified on the
    # test VM, which collected five of azureadmin's directories that way (G24).
    $machinePath = [Environment]::GetEnvironmentVariable('Path', [System.EnvironmentVariableTarget]::Machine)
    if (($machinePath -split ';') -notcontains 'C:\docker') {
        [Environment]::SetEnvironmentVariable('Path', "$($machinePath.TrimEnd(';'));C:\docker", [System.EnvironmentVariableTarget]::Machine)
    }
    if (($env:Path -split ';') -notcontains 'C:\docker') { $env:Path = "$env:Path;C:\docker" }
    [Environment]::SetEnvironmentVariable('DOCKER_HOST', 'tcp://127.0.0.1:2378', [System.EnvironmentVariableTarget]::Machine)

    if (-not (Test-DockerService)) {
        Write-SetupLog "  Registering the docker service ..."
        dockerd --register-service --service-name $script:DockerServiceName
    }

    # dockerd creates its data directories on first run but NOT config\. Docker 20.10 did, which is
    # the only reason starting and stopping the service here used to produce it; 29.x does not, so
    # daemon.json needs a directory to land in or the copy fails with "The directory name is
    # invalid" and the daemon never gets its TCP endpoint (G23).
    $configDir = Join-Path $script:DockerDataPath 'config'
    if (-not (Test-Path -LiteralPath $configDir)) {
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
    }
    Copy-Item "$PSScriptRoot\daemon.json" $configDir -Force

    # daemon.json has to be in place before the daemon reads it, so restart if it is already up.
    if ((Get-Service -Name $script:DockerServiceName).Status -eq 'Running') {
        Restart-Service -Name $script:DockerServiceName
    }
    else {
        Start-Service -Name $script:DockerServiceName
    }

    if ((docker context ls --format '{{.Name}}' 2>$null) -notcontains 'win') {
        docker context create win --docker host=tcp://127.0.0.1:2378
    }

    Write-SetupLog "  Waiting for the Windows daemon on tcp://127.0.0.1:2378 ..."
    $deadline = (Get-Date).AddMinutes(2)
    while (-not (Test-TcpPort -Port 2378) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
    }
    if (-not (Test-TcpPort -Port 2378)) {
        throw "The Windows Docker daemon did not start listening on tcp://127.0.0.1:2378."
    }
    Write-SetupLog "  Windows Docker daemon is up."
}

Function Start-WslDistro {
    <#
        .SYNOPSIS
            Brings the distro up with a no-op and waits for the Linux daemon's port to answer.
        .OUTPUTS
            [bool] $true when 127.0.0.1:2375 answers from Windows. Return value is tested.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $DistroName,
        [Parameter()] [int] $TimeoutSeconds = 90
    )
    Write-SetupLog "  Starting WSL distro '$DistroName' ..."
    & wsl.exe --distribution $DistroName -- /bin/true 2>&1 | Out-Null
    return (Wait-LinuxDockerEndpoint -TimeoutSeconds $TimeoutSeconds)
}

Function Wait-LinuxDockerEndpoint {
    <#
        .SYNOPSIS
            Waits for 127.0.0.1:2375 to answer from Windows, without touching the distro.
        .DESCRIPTION
            Deliberately does NOT run any `wsl` command: invoking wsl starts the distro, which is
            the state being measured. That is exactly how the old docker-linux check ended up
            unable to fail (G27), so the wait that replaces it must not repeat the trick.
        .OUTPUTS
            [bool] Return value is tested.
    #>
    [CmdletBinding()]
    param (
        [Parameter()] [int] $TimeoutSeconds = 90
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort -Port 2375) { return $true }
        Start-Sleep -Seconds 3
    }
    return (Test-TcpPort -Port 2375)
}

# ---------------------------------------------------------------------------------------------
# Phase: Windows features. FIRST and -NoRestart, so the one restart is paid before any install.
# ---------------------------------------------------------------------------------------------
Invoke-SetupPhase -Phase 'containers-feature' -Body {
    Write-SetupLog "Enabling the Windows features the Docker daemon needs ..."
    if (Enable-ContainerFeature) {
        Request-PhaseReboot -Reason 'the Containers feature needs a restart before the Windows Docker daemon can start'
        Write-SetupLog "Features enabled; a restart is owed before Docker can be installed."
    }
    else {
        Write-SetupLog "Container features are enabled and need no restart."
    }
}

# Per-user, idempotent, and independent of both daemons; so it also covers a box where Docker was
# already installed and the docker-windows phase therefore does nothing.
Invoke-SetupPhase -Phase 'environment' -Body {
    Write-SetupLog "Pointing bare `docker` at the Linux daemon and propagating BASH_ENV into WSL ..."
    [Environment]::SetEnvironmentVariable("WSLENV", "BASH_ENV/u", [System.EnvironmentVariableTarget]::User)
    [Environment]::SetEnvironmentVariable("BASH_ENV", "/etc/bash.bashrc", [System.EnvironmentVariableTarget]::User)
    [Environment]::SetEnvironmentVariable("DOCKER_HOST", "tcp://127.0.0.1:2375", [System.EnvironmentVariableTarget]::User)
}

# ---------------------------------------------------------------------------------------------
# The single reboot gate.
# ---------------------------------------------------------------------------------------------
Invoke-RebootGate -State $state -TaskName $taskName -ResumeCommand $resumeCommand -ResumeMethod $resumeMethod `
    -WorkingDirectory $PSScriptRoot -NoReboot:$noReboot -BeforeExit $finishLog

Invoke-SetupPhase -Phase 'docker-windows' -Body {
    Write-SetupLog "Configuring Docker on Windows (host) ..."
    Install-WindowsDocker
}

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

    Write-SetupLog "Configuring Docker on Linux (WSL2 $distroName) ..."
    # Bounded, because an unattended install must never be able to wedge forever. It did: the
    # script's old `sudo shutdown -r now` hung for 20 minutes under systemd-in-WSL on 2026-09-14
    # (G30). That line is gone, but the timeout stays - apt is a network operation and this phase
    # has no other way to give up. On timeout the wsl.exe launcher is killed and the phase throws,
    # so the next run retries it rather than the build hanging silently.
    $installTimeout = [TimeSpan]::FromMinutes(30)
    $wslProcess = Start-Process -FilePath 'wsl.exe' `
        -ArgumentList @('--distribution', $distroName, '--', 'bash', './install-docker-ce.sh') `
        -NoNewWindow -PassThru
    # Reading .Handle caches the process handle. Without it, .ExitCode below is empty even once the
    # process has exited - a documented Start-Process -PassThru quirk, verified on 5.1.26100.
    # Also note Windows PowerShell 5.1 has only WaitForExit() and WaitForExit([int]); the
    # WaitForExit([TimeSpan]) overload is .NET 5+, so the timeout must be passed as milliseconds.
    $null = $wslProcess.Handle
    if (-not $wslProcess.WaitForExit([int]$installTimeout.TotalMilliseconds)) {
        Write-SetupLog "  install-docker-ce.sh exceeded $($installTimeout.TotalMinutes) minutes; killing it."
        try { $wslProcess.Kill() } catch { }
        throw "install-docker-ce.sh did not finish within $($installTimeout.TotalMinutes) minutes. Check 'wsl -d $distroName -- systemctl status docker' and the apt logs in the distro."
    }
    Write-SetupLog "  install-docker-ce.sh exited $($wslProcess.ExitCode)."

    # Verify what the client will actually use: a TCP connect to 2375 from WINDOWS. The old check
    # ran `wsl -- docker version`, which talks to the unix socket inside the distro and - worse -
    # starts the distro, so it could not fail and reported success on an install where bare
    # `docker` did not work (G27).
    Write-SetupLog "Waiting for the Linux daemon on tcp://127.0.0.1:2375 (from Windows) ..."
    if (-not (Start-WslDistro -DistroName $distroName)) {
        throw "The Linux Docker daemon is not reachable on tcp://127.0.0.1:2375 from Windows. Check 'wsl -d $distroName -- systemctl status docker' and that /etc/systemd/system/docker.service carries -H tcp://127.0.0.1:2375."
    }
    Write-SetupLog "Linux Docker daemon is reachable from Windows."
}

# ---------------------------------------------------------------------------------------------
# Phase: keep bare `docker` working across reboots. The relayed 127.0.0.1:2375 port exists only
# while the distro runs, and a Windows-side TCP connect does not start it - so without this, every
# reboot leaves `docker ps` failing until something touches WSL. Measured on the test VM: distro
# stopped => nothing listening and bare `docker` exits 1; after the no-op below, 2375 answers within
# ~15 s and `docker run hello-world` succeeds (G26).
# ---------------------------------------------------------------------------------------------
Invoke-SetupPhase -Phase 'wsl-autostart' -Body {
    $runAsUser = "$($env:USERDOMAIN)\$($env:USERNAME)"
    Write-SetupLog "Registering at-logon keepalive task '$autostartTaskName' for $runAsUser ..."
    # `sleep infinity`, not `/bin/true`: merely *starting* the distro is not enough, because WSL2
    # shuts an idle VM down about a minute after the last session closes. Measured on the test VM -
    # the clean install reported success at 03:36:24 and bare `docker` was refused by 03:39:49, with
    # no reboot involved. Holding one session open for the whole logon keeps the relayed
    # 127.0.0.1:2375 port alive; verified across a 150 s wait (well past the idle timeout) with the
    # distro still running and the listener still present.
    # conhost --headless runs it with no console window: MainWindowHandle is 0, so nothing is left
    # sitting on the user's desktop all session.
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' `
        -Argument "--headless wsl.exe --distribution $distroName -- sleep infinity"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $runAsUser
    # Deliberately not RunLevel Highest: holding a WSL session needs no elevation and this fires at
    # every logon, so it should hold the least privilege that works.
    $principal = New-ScheduledTaskPrincipal -UserId $runAsUser -LogonType Interactive
    # TimeSpan::Zero is "no time limit" to Task Scheduler - required, since the task never exits.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $autostartTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description 'Holds a WSL2 session open so the Linux Docker daemon stays reachable on 127.0.0.1:2375' -Force | Out-Null

    # Start it now, so this session is covered too rather than only sessions after the next logon.
    Start-ScheduledTask -TaskName $autostartTaskName
    if (-not (Wait-LinuxDockerEndpoint)) {
        throw "The keepalive task started but tcp://127.0.0.1:2375 still does not answer from Windows. Check 'Get-ScheduledTaskInfo -TaskName $autostartTaskName' and 'wsl -l --running'."
    }
    Write-SetupLog "  Keepalive running; tcp://127.0.0.1:2375 answers from Windows."
}

# ---------------------------------------------------------------------------------------------
# Done: retire every resume hook; record 'done' and exit 0 only if no phase failed.
# ---------------------------------------------------------------------------------------------
Complete-Setup -State $state -TaskName $taskName -Title "Docker CE setup"
if ($SetupExitCode -eq 0) {
    Write-SetupLog "  Verify in a NEW shell (so DOCKER_HOST is picked up):"
    Write-SetupLog "    docker run hello-world          # Linux daemon, tcp://127.0.0.1:2375"
    Write-SetupLog "    docker -c win run hello-world   # Windows daemon, tcp://127.0.0.1:2378"
    Write-SetupLog "  If bare docker ever fails after a reboot, the distro is not running yet:"
    Write-SetupLog "    wsl -d $distroName -- /bin/true"
}

& $finishLog
exit $SetupExitCode
