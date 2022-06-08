[CmdletBinding()]
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
$taskName = "workstation-config"
$argString = "-executionpolicy bypass -file .\config-workstation.ps1 -role $role"
New-WindowsTask -TaskName $taskName -WorkingDirectory $PSScriptRoot -PSCommand $argString

$wingetCmd = Get-Command -Name winget.exe -ErrorAction SilentlyContinue
if ($wingetCmd) {
    $wingetPackages = Get-Content .\winget-packages-$role.json | ConvertFrom-Json
    foreach ($pack in $wingetPackages) {
        Install-WinGetPackage -packageName $pack.name -packageId $pack.id
        Write-Output "Check if computer need restart..."  | timestamp
        $needRestart = Test-VMRestart
        if ($needRestart) {
            Write-Output "Restarting Computer"  | timestamp
            $null = Stop-Transcript
            Restart-Computer -Force
        }
    }
}

$chocoPackages = Get-Content .\choco-packages-$role.json | ConvertFrom-Json
Install-Choco
foreach ($pack in $chocoPackages) {
    Install-Package -packageName $pack.name -additionalParameters $pack.additionalParameters
    Write-Output "Check if computer need restart..."  | timestamp
    $needRestart = Test-VMRestart
    if ($needRestart) {
        Write-Output "Restarting Computer"  | timestamp
        $null = Stop-Transcript
        Restart-Computer -Force
    }
}


#install wsl
$wslCmd = Get-Command -Name wsl.exe -ErrorAction SilentlyContinue
if (-not $wslCmd) {
    wsl --install
    Write-Output "Check if computer need restart..."  | timestamp
    $needRestart = Test-VMRestart
    if ($needRestart) {
        Write-Output "Restarting Computer"  | timestamp
        $null = Stop-Transcript
        Restart-Computer -Force
    }
}
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

#copy pwsh profile
Write-Output "Copy ps profile"  | timestamp
Copy-Item "./profile.ps1" -Destination $Profile -Force

#copy oh-my-posh theme
Write-Output "Copy oh-my-posh theme"  | timestamp
Copy-Item "./rudolfs-light.omp.json" -Destination $env:POSH_THEMES_PATH -Force

#copy git config
Write-Output "Copy git config"  | timestamp
Copy-Item "./.gitconfig" -Destination $env:UserProfile -Force

Remove-WindowsTask -TaskName $taskName

$null = Stop-Transcript
Rename-Item -Path $logFilePath -NewName "workstation-config-$(Get-Date -Format FileDateTime).log" -Force