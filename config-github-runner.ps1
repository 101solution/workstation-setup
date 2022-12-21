[CmdletBinding()]
param (
    [Parameter()]
    [string]
    $role = "runner",
    [Parameter()]
    [string]
    $taskName = ""
)
$restartComputer = $false
filter timestamp { "$(Get-Date -Format o): $_" }
$logFilePath = "$PSScriptRoot\logs\gh-runner-config.log"
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

$userToolsPath = "$env:UserProfile\tools"

Install-DockerEngine -InstallPath $userToolsPath


$psModules = $packageConfig.powershellModule

foreach ($module in $psModules) {
    Install-PSModule -PsModuleName $module.name
}

$null = Stop-Transcript
Rename-Item -Path $logFilePath -NewName "workstation-config-$(Get-Date -Format FileDateTime).log" -Force