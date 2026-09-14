
############################################################
# Script to install the community edition of docker on Windows
#
# Worker script driven by ./config-docker.ps1, which owns the reboot/resume logic. Exit codes:
#   0    Docker Engine installed (or already present) and the daemon answered on the 'win' context
#   3010 a Windows feature was enabled and needs a restart first; re-run after rebooting
#   1    failure
############################################################

#Requires -Version 5.0

[CmdletBinding()]
param (
    [Parameter(HelpMessage = "Force Hyper-V isolation. Implied on client SKUs, which cannot run process-isolated containers.")]
    [switch]
    $HyperV,
    [Parameter()]
    [string]
    $DockerVersion = "29.8.0"
)

$global:RebootRequired = $false

# Name of the at-logon task older versions of this script registered to resume after a reboot.
# Resume is now handled by config-docker.ps1; this is only kept so a stale task gets cleaned up.
$global:LegacyBootstrapTask = "ContainerBootstrap"
$global:ScriptFolder = $PSScriptRoot

function Install-Feature {
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()]
        [string]
        $FeatureName
    )

    Write-Output "Querying status of Windows feature: $FeatureName..."
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        if ((Get-WindowsFeature $FeatureName).Installed) {
            Write-Output "Feature $FeatureName is already enabled."
        }
        else {
            Test-Admin

            Write-Output "Enabling feature $FeatureName..."
            $featureInstall = Add-WindowsFeature $FeatureName

            if ($featureInstall.RestartNeeded -eq "Yes") {
                $global:RebootRequired = $true;
            }
        }
    }
    else {
        if ((Get-WindowsOptionalFeature -Online -FeatureName $FeatureName).State -eq "Disabled") {

            Test-Admin

            Write-Output "Enabling feature $FeatureName..."
            $feature = Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -All -NoRestart

            if ($feature.RestartNeeded -eq "True") {
                $global:RebootRequired = $true;
            }
        }
        else {
            Write-Output "Feature $FeatureName is already enabled."
            if ((Get-WindowsEdition -Online).RestartNeeded) {
                $global:RebootRequired = $true;
            }
        }
    }
}

function Install-ContainerHost {
    if (Test-Client) {
        if (-not $HyperV) {
            Write-Output "Enabling Hyper-V containers by default for Client SKU"
            $HyperV = $true
        }
    }
    #
    # Validate required Windows features
    #
    Install-Feature -FeatureName Containers

    if ($HyperV) {
        Install-Feature -FeatureName Hyper-V
    }

    if ($global:RebootRequired) {
        Write-Warning "A restart is required before Docker can be installed. Reboot and re-run; config-docker.ps1 does this automatically."
        exit 3010
    }

    #
    # Unregister the bootstrap task an older version of this script may have left behind
    #
    if ($null -ne (Get-ScheduledTask -TaskName $global:LegacyBootstrapTask -ErrorAction SilentlyContinue)) {
        Unregister-ScheduledTask -TaskName $global:LegacyBootstrapTask -Confirm:$false
    }

    #
    # Install, register, and start Docker
    #
    # Install-Docker is idempotent and checks each piece of the end state separately. Do NOT gate it
    # on Test-Docker: the service is registered early, so a run that failed after that point would
    # look "already installed" on retry and the phase would be recorded complete with no daemon.json
    # and no 'win' context.
    Install-Docker

    Write-Output "Script complete!"
}
$global:AdminPriviledges = $false
$global:DockerDataPath = "$($env:ProgramData)\docker"
$global:DockerServiceName = "docker"


function Test-Admin() {
    # Get the ID and security principal of the current user account
    $myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $myWindowsPrincipal = new-object System.Security.Principal.WindowsPrincipal($myWindowsID)

    # Get the security principal for the Administrator role
    $adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator

    # Check to see if we are currently running "as Administrator"
    if ($myWindowsPrincipal.IsInRole($adminRole)) {
        $global:AdminPriviledges = $true
        return
    }
    else {
        #
        # We are not running "as Administrator"
        # Exit from the current, unelevated, process
        #
        throw "You must run this script as administrator"
    }
}


function Test-Client() {
    return (-not (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue))
}



function Install-Docker() {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $ContainerBaseImage = "hello-world"
    )

    if (-not (Test-Path -LiteralPath 'C:\docker\dockerd.exe')) {
        $zipPath = Join-Path $env:TEMP "docker-$DockerVersion.zip"
        curl.exe -o $zipPath -L https://download.docker.com/win/static/stable/x86_64/docker-$DockerVersion.zip
        if (-not (Test-Path -LiteralPath $zipPath)) {
            throw "Docker Engine download failed; $zipPath was not created."
        }
        Expand-Archive -LiteralPath $zipPath -DestinationPath C:\ -Force
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }

    # Append to the MACHINE Path, never to $env:Path: the process value is Machine and User merged,
    # so writing it back bakes the running user's private directories (WindowsApps, WinGet\Links,
    # .dotnet\tools, ...) into the machine Path for every other user on the box. Verified on the
    # test VM, which collected five of azureadmin's directories that way.
    $machinePath = [Environment]::GetEnvironmentVariable('Path', [System.EnvironmentVariableTarget]::Machine)
    if (($machinePath -split ';') -notcontains 'C:\docker') {
        [Environment]::SetEnvironmentVariable('Path', "$($machinePath.TrimEnd(';'));C:\docker", [System.EnvironmentVariableTarget]::Machine)
    }
    if (($env:Path -split ';') -notcontains 'C:\docker') { $env:Path = "$env:Path;C:\docker" }
    [Environment]::SetEnvironmentVariable("DOCKER_HOST", "tcp://127.0.0.1:2378", [System.EnvironmentVariableTarget]::Machine)

    if (-not (Test-Docker)) {
        dockerd --register-service --service-name $global:DockerServiceName
    }

    # dockerd creates its data directories on first run but NOT config\. The 20.10 build did, which
    # is the only reason starting and stopping the service here used to produce it; 29.x does not,
    # so daemon.json has to be given a directory to land in or the copy fails with "The directory
    # name is invalid" and the Windows daemon never gets its TCP endpoint.
    $configDir = Join-Path $global:DockerDataPath 'config'
    if (-not (Test-Path -LiteralPath $configDir)) {
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
    }
    Copy-Item "$($global:ScriptFolder)\daemon.json" $configDir -Force

    # daemon.json has to be in place before the daemon reads it, so restart if it is already up.
    if ((Get-Service -Name $global:DockerServiceName).Status -eq 'Running') {
        Restart-Service -Name $global:DockerServiceName
    }
    else {
        Start-Docker
    }

    if ((docker context ls --format '{{.Name}}' 2>$null) -notcontains 'win') {
        docker context create win --docker host=tcp://127.0.0.1:2378
    }
    #
    # Waiting for docker to come to steady state
    #
    Wait-Docker
    Write-Output "setting up  environment variable"
    [Environment]::SetEnvironmentVariable("WSLENV", "BASH_ENV/u", [System.EnvironmentVariableTarget]::User)
    [Environment]::SetEnvironmentVariable("BASH_ENV", "/etc/bash.bashrc", [System.EnvironmentVariableTarget]::User)
    [Environment]::SetEnvironmentVariable("DOCKER_HOST", "tcp://127.0.0.1:2375", [System.EnvironmentVariableTarget]::User)
    if (-not [string]::IsNullOrEmpty($ContainerBaseImage)) {
        Write-Output "Attempting to pull specified base image: $ContainerBaseImage"
        docker -c win pull $ContainerBaseImage
    }

    Write-Output "The following images are present on this machine:"

    docker -c win images -a | Write-Output

    Write-Output ""
}

function Start-Docker() {
    Start-Service -Name $global:DockerServiceName
}


function Stop-Docker() {
    Stop-Service -Name $global:DockerServiceName
}


function Test-Docker() {
    $service = Get-Service -Name $global:DockerServiceName -ErrorAction SilentlyContinue

    return ($service -ne $null)
}


function Wait-Docker() {
    Write-Output "Waiting for Docker daemon..."
    $dockerReady = $false
    $startTime = Get-Date

    while (-not $dockerReady) {
        try {
            docker -c win version | Out-Null

            if (-not $?) {
                throw "Docker daemon is not running yet"
            }

            $dockerReady = $true
        }
        catch {
            $timeElapsed = $(Get-Date) - $startTime

            if ($($timeElapsed).TotalMinutes -ge 1) {
                throw "Docker Daemon did not start successfully within 1 minute."
            }

            # Swallow error and try again
            Start-Sleep -sec 1
        }
    }
    Write-Output "Successfully connected to Docker Daemon."
}

try {
    Install-ContainerHost
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
