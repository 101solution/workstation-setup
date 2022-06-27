﻿[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $role = "devops",
    [Parameter()]
    [boolean]
    $enableWSL = $true,
    [Parameter()]
    [string]
    $gitUser = "CShen_101Solution",
    [Parameter()]
    [string]
    $gitEmail = "chuishen@gmail.com",
    [Parameter()]
    [string]
    $defaultWorkFolder = "c:\projects"
)
filter timestamp { "$(Get-Date -Format o): $_" }
$logFilePath = "$PSScriptRoot\logs\workstation-config.log"
if (-not (Test-Path $logFilePath)) {
    Write-Output "Create log file $logFilePath..." | timestamp
    New-Item -Path $logFilePath -ItemType File -Force | Out-Null
}
$null = Start-Transcript $logFilePath -Append

Write-Output "Loading helper script..." | timestamp
. $PSScriptRoot\helper.ps1
#$taskName = "workstation-config"
#$argString = "-executionpolicy bypass -file .\config-workstation.ps1 -role $role"
#New-WindowsTask -TaskName $taskName -WorkingDirectory $PSScriptRoot -PSCommand $argString
Write-Output "Register NuGet source ..." | timestamp
Register-PackageSource -provider NuGet -name nugetRepository -location https://www.nuget.org/api/v2 -ForceBootstrap -Force -ErrorAction SilentlyContinue | Out-Null

Write-Output "Getting package config ..." | timestamp
$packageConfig = Get-Content $PSScriptRoot\packages-$role.json | ConvertFrom-Json

$wingetPackages = $packageConfig.winget
if ($wingetPackages -and $wingetPackages.Count -gt 0) {
    Install-WinGetOffline
    #call winget list as the first time it takes some time to load
    Write-Output "Run winget list ..." | timestamp
    winget list --accept-source-agreements | Out-Null
    Start-Sleep -Milliseconds 2000
    foreach ($pack in $wingetPackages) {
        if ($pack.override) {
            Install-WinGetPackage -packageName $pack.name -packageId $pack.id -overrideParameters $pack.override
        }
        else {
            Install-WinGetPackage -packageName $pack.name -packageId $pack.id
        }
    }
}
    
$chocoPackages = $packageConfig.chocolatey
if ($chocoPackages -and $chocoPackages.Count -gt 0) {
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
}

# $userToolsPath = "$env:UserProfile\tools"

# Install-Kubectl -InstallPath $userToolsPath

#Reload environment variables for the session
Write-Output "Update Environment Variables in the session"  | timestamp
Update-SessionEnvironment
Install-Fonts -fontFolder $PSScriptRoot

$psModules = $packageConfig.powershellModule

foreach ($module in $psModules) {
    Install-PSModule -PsModuleName $module.name
}


pwsh.exe -command "& {Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Force}" | Out-Null
#copy pwsh profile
Write-Output "Copy ps profile"  | timestamp
$psProfilePath = $PROFILE.CurrentUserAllHosts -Replace "WindowsPowerShell", "Powershell"
Write-Output "Creating ps profile $psProfilePath"  | timestamp
New-Item -ItemType File -Path $psProfilePath -Force | Out-Null
Write-Output "unlock ps profile"  | timestamp

Copy-Item "$PSScriptRoot/profile.ps1" -Destination $psProfilePath -Force
Unblock-File -LiteralPath $psProfilePath

if (-not (Test-Path -Path $defaultWorkFolder -PathType Container)) {
    Write-Output "Create folder $defaultWorkFolder"  | timestamp
    New-Item -Path $defaultWorkFolder -ItemType Directory -Force | Out-Null
}
#copy oh-my-posh theme
Write-Output "Copy oh-my-posh theme"  | timestamp
$poshContent = Get-Content "$PSScriptRoot/rudolfs-light-cs.omp.json" -Encoding UTF8
$poshContent -replace "#workFolder#", [regex]::escape($defaultWorkFolder) | Out-File -LiteralPath "$($env:POSH_THEMES_PATH)\rudolfs-light-cs.omp.json" -Encoding utf8 -Force


#copy git config
Write-Output "Copy git config..."  | timestamp
Copy-Item "$PSScriptRoot/.gitconfig" -Destination $env:UserProfile -Force
Write-Output "Set Git User and Email..."  | timestamp
git config --global user.name $gitUser
git config --global user.email $gitEmail


$terminalSettingFile = "$($env:LocalAppData)\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
if (Test-Path -LiteralPath $terminalSettingFile) {
    Write-Output "Update Windows Terminal Settings"  | timestamp
    $defaultSettings = Get-Content -LiteralPath "$PSScriptRoot\terminal-default-settings.json" | ConvertFrom-Json
    $defaultSettings.backgroundImage = "$PSScriptRoot\backgroud\Chongming-China.png"
    $defaultSettings.startingDirectory = $defaultWorkFolder
    $terminalSettings = Get-Content -LiteralPath $terminalSettingFile | ConvertFrom-Json
    $terminalSettings.profiles.defaults = $defaultSettings
    $terminalSettings | ConvertTo-Json -Depth 10 | Format-Json | Out-File $terminalSettingFile -Force -Encoding utf8
}
#Remove-WindowsTask -TaskName $taskName
#install wsl
if ($enableWSL) {
    Write-Output "Installing WSL ...." | timestamp
    $wslCmd = Get-Command -Name wsl.exe -ErrorAction SilentlyContinue
    if ($wslCmd) {
        wsl --update
        wsl --shutdown
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
        $result = wsl -l -v
        if (($result.Count -ge 2) -and ($result[1].Contains("Ubuntu"))) {
            Write-Output "wsl already configured" | timestamp
    
        }
        else {
            Write-Output "Configuring WSL ..." | timestamp
            wsl --install -d Ubuntu
            Write-Output "Restarting computer to continue wsl install...." | timestamp
            $null = Stop-Transcript
            Rename-Item -Path $logFilePath -NewName "workstation-config-$(Get-Date -Format FileDateTime).log" -Force
            Restart-Computer -Force
        }
        
    }
    else {
        Write-Warning "wsl.exe can't find, please fix it and try again  ...." | timestamp
    }
}
else {
    Write-Output "Skipping WSL install...." | timestamp
}
$null = Stop-Transcript
Rename-Item -Path $logFilePath -NewName "workstation-config-$(Get-Date -Format FileDateTime).log" -Force