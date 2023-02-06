
############################################################
# Script to install the community edition of docker on Windows
############################################################

#Requires -Version 5.0


$global:RebootRequired = $false

$global:ErrorFile = "$pwd\Install-ContainerHost.err"

$global:BootstrapTask = "ContainerBootstrap"


function Restart-And-Run(){
    Test-Admin

    Write-Output "Restart is required; restarting now..."

    $argList = $script:MyInvocation.Line.replace($script:MyInvocation.InvocationName, "")

    #
    # Update .\ to the invocation directory for the bootstrap
    #
    $scriptPath = $script:MyInvocation.MyCommand.Path

    $argList = $argList -replace "\.\\", "$pwd\"

    if ((Split-Path -Parent -Path $scriptPath) -ne $pwd)
    {
        $sourceScriptPath = $scriptPath
        $scriptPath = "$pwd\$($script:MyInvocation.MyCommand.Name)"

        Copy-Item $sourceScriptPath $scriptPath
    }

    Write-Output "Creating scheduled task action ($scriptPath $argList)..."
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoExit $scriptPath $argList"

    Write-Output "Creating scheduled task trigger..."
    $trigger = New-ScheduledTaskTrigger -AtLogOn

    Write-Output "Registering script to re-run at next user logon..."
    Register-ScheduledTask -TaskName $global:BootstrapTask -Action $action -Trigger $trigger -RunLevel Highest | Out-Null

    try
    {
        Restart-Computer -Force
        
    }
    catch
    {
        Write-Error $_

        Write-Output "Please restart your computer manually to continue script execution."
    }

    exit
}


function Install-Feature {
    [CmdletBinding()]
    param(
        [ValidateNotNullOrEmpty()]
        [string]
        $FeatureName
    )

    Write-Output "Querying status of Windows feature: $FeatureName..."
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue)
    {
        if ((Get-WindowsFeature $FeatureName).Installed)
        {
            Write-Output "Feature $FeatureName is already enabled."
        }
        else
        {
            Test-Admin

            Write-Output "Enabling feature $FeatureName..."
        }

        $featureInstall = Add-WindowsFeature $FeatureName

        if ($featureInstall.RestartNeeded -eq "Yes")
        {
            $global:RebootRequired = $true;
        }
    }
    else
    {
        if ((Get-WindowsOptionalFeature -Online -FeatureName $FeatureName).State -eq "Disabled")
        {

            Test-Admin

            Write-Output "Enabling feature $FeatureName..."
            $feature = Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -All -NoRestart

            if ($feature.RestartNeeded -eq "True")
            {
                $global:RebootRequired = $true;
            }
        }
        else
        {
            Write-Output "Feature $FeatureName is already enabled."
            if ((Get-WindowsEdition -Online).RestartNeeded)
            {
                $global:RebootRequired = $true;
            }
        }
    }
}

function Install-ContainerHost {
    "If this file exists when Install-ContainerHost.ps1 exits, the script failed!" | Out-File -FilePath $global:ErrorFile

    if (Test-Client)
    {
        if (-not $HyperV)
        {
            Write-Output "Enabling Hyper-V containers by default for Client SKU"
            $HyperV = $true
        }    
    }
    #
    # Validate required Windows features
    #
    Install-Feature -FeatureName Containers

    if ($HyperV)
    {
        Install-Feature -FeatureName Hyper-V
    }

    if ($global:RebootRequired)
    {
        if ($NoRestart)
        {
            Write-Warning "A reboot is required; stopping script execution"
            exit
        }

        Restart-And-Run
    }

    #
    # Unregister the bootstrap task, if it was previously created
    #
    if ((Get-ScheduledTask -TaskName $global:BootstrapTask -ErrorAction SilentlyContinue) -ne $null)
    {
        Unregister-ScheduledTask -TaskName $global:BootstrapTask -Confirm:$false
    }    


    #
    # Install, register, and start Docker
    #
    if (Test-Docker)
    {
        Write-Output "Docker is already installed."
    }
    else
    {
        Install-Docker -DockerPath $DockerPath -DockerDPath $DockerDPath -ContainerBaseImage $ContainerBaseImage
        
    }


    Remove-Item $global:ErrorFile

    Write-Output "Script complete!"
}
$global:AdminPriviledges = $false
$global:DockerDataPath = "$($env:ProgramData)\docker"
$global:DockerServiceName = "docker"


function Test-Admin() {
    # Get the ID and security principal of the current user account
    $myWindowsID=[System.Security.Principal.WindowsIdentity]::GetCurrent()
    $myWindowsPrincipal=new-object System.Security.Principal.WindowsPrincipal($myWindowsID)
  
    # Get the security principal for the Administrator role
    $adminRole=[System.Security.Principal.WindowsBuiltInRole]::Administrator
  
    # Check to see if we are currently running "as Administrator"
    if ($myWindowsPrincipal.IsInRole($adminRole))
    {
        $global:AdminPriviledges = $true
        return
    }
    else
    {
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
        $dockerVersion = "20.10.23",
        [Parameter()]
        [string]
        $ContainerBaseImage = "hello-world"
    )

    curl.exe -o docker.zip -LO https://download.docker.com/win/static/stable/x86_64/docker-$dockerVersion.zip 
    Expand-Archive docker.zip -DestinationPath C:\
    [Environment]::SetEnvironmentVariable("Path", "$($env:path);C:\docker", [System.EnvironmentVariableTarget]::Machine)
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine")
    dockerd --register-service --service-name $global:DockerServiceName
    Start-Docker

    #
    # Waiting for docker to come to steady state
    #
    Wait-Docker

    if(-not [string]::IsNullOrEmpty($ContainerBaseImage)) {
        Write-Output "Attempting to pull specified base image: $ContainerBaseImage"
        docker pull $ContainerBaseImage
    }

    Write-Output "The following images are present on this machine:"
    
    docker images -a | Write-Output

    Write-Output ""
}

function Start-Docker() {
    Start-Service -Name $global:DockerServiceName
}


function 
Stop-Docker()
{
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

    while (-not $dockerReady)
    {
        try
        {
            docker version | Out-Null

            if (-not $?)
            {
                throw "Docker daemon is not running yet"
            }

            $dockerReady = $true
        }
        catch 
        {
            $timeElapsed = $(Get-Date) - $startTime

            if ($($timeElapsed).TotalMinutes -ge 1)
            {
                throw "Docker Daemon did not start successfully within 1 minute."
            } 

            # Swallow error and try again
            Start-Sleep -sec 1
        }
    }
    Write-Output "Successfully connected to Docker Daemon."
}

try
{
    Install-ContainerHost
    # Create a wsl context if you'd like to run linux container On windows client 
    docker context create wsl --docker host=tcp://127.0.0.1:2375
    setx WSLENV BASH_ENV/u
    setx BASH_ENV /etc/bash.bashrc
}
catch 
{
    Write-Error $_
}