﻿[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $role = "devops"
)
$logFilePath = "c:\temp\workstation-config.log"
if (-not (Test-Path $logFilePath)) {
    New-Item -Path $logFilePath -ItemType File -Force
}
$null = Start-Transcript $logFilePath -Append
filter timestamp { "$(Get-Date -Format o): $_" }

. .\helper.ps1
#$taskName = "workstation-config"
#$argString = "-executionpolicy bypass -file .\config-workstation.ps1 -role $role"
#New-WindowsTask -TaskName $taskName -WorkingDirectory $PSScriptRoot -PSCommand $argString
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
#Install Package Provider Source
Register-PackageSource -provider NuGet -name nugetRepository -location https://www.nuget.org/api/v2
#Install Prerequisites for WinGet
Install-Package Microsoft.UI.Xaml -Force
Install-WinGet
$wingetPackages = Get-Content .\winget-packages-$role.json | ConvertFrom-Json
foreach ($pack in $wingetPackages) {
    Install-WinGetPackage -packageName $pack.name -packageId $pack.id
}

    
$chocoPackages = Get-Content .\choco-packages-$role.json | ConvertFrom-Json
Install-Choco
foreach ($pack in $chocoPackages) {
    Install-ChocoPackage -packageName $pack.name -additionalParameters $pack.additionalParameters
    #Write-Output "Check if computer need restart..."  | timestamp
    #$needRestart = Test-VMRestart
    #if ($needRestart) {
    #    Write-Output "Restarting Computer"  | timestamp
    #    $null = Stop-Transcript
    #    Restart-Computer -Force
    #}
}


#install wsl
$wslCmd = Get-Command -Name wsl.exe -ErrorAction SilentlyContinue
if (-not $wslCmd) {
    wsl --install
    #    Write-Output "Check if computer need restart..."  | timestamp
    #    $needRestart = Test-VMRestart
    #    if ($needRestart) {
    #        Write-Output "Restarting Computer"  | timestamp
    #        $null = Stop-Transcript
    #        Restart-Computer -Force
    #    }
}
#Reload environment variables for the session
Write-Output "Update Environment Variables in the session"  | timestamp
Update-SessionEnvironment
Install-Fonts
#install posh-git

$poshGit = Get-InstalledModule -Name posh-git -ErrorAction SilentlyContinue

if ($null -eq $poshGit) {
    Write-Output "Install posh-git"  | timestamp
    Install-Module -Name posh-git -Repository PSGallery -Force
}

#install Az

$azModule = Get-InstalledModule -Name Az -ErrorAction SilentlyContinue

if ($null -eq $azModule) {
    Write-Output "Install Az Module"  | timestamp
    Install-Module -Name Az -Repository PSGallery -Force
}

#install PSReadLine

$psReadLine = Get-InstalledModule -Name PSReadLine -ErrorAction SilentlyContinue

if ($null -eq $psReadLine) {
    Write-Output "Install PSReadLine"  | timestamp
    Install-Module -Name PSReadLine -Repository PSGallery -Force
}
pwsh.exe -command "& {Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Force}"
#copy pwsh profile
Write-Output "Copy ps profile"  | timestamp
$psProfilePath = $PROFILE.CurrentUserAllHosts -Replace "WindowsPowerShell", "Powershell"
Write-Output "Creating ps profile"  | timestamp
New-Item -ItemType File -Path $psProfilePath -Force 
Write-Output "unlock ps profile"  | timestamp

Copy-Item "./profile.ps1" -Destination $psProfilePath -Force
Unblock-File -LiteralPath $psProfilePath

#copy oh-my-posh theme
Write-Output "Copy oh-my-posh theme"  | timestamp
Copy-Item "./rudolfs-light-cs.omp.json" -Destination $env:POSH_THEMES_PATH -Force


#copy git config
Write-Output "Copy git config"  | timestamp
Copy-Item "./.gitconfig" -Destination $env:UserProfile -Force

#Remove-WindowsTask -TaskName $taskName

$null = Stop-Transcript
Rename-Item -Path $logFilePath -NewName "workstation-config-$(Get-Date -Format FileDateTime).log" -Force