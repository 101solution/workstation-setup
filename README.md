# Workstation Configuration
This is PowerShell script to set up workstation with needed software
1. Open PowerShell window in Administrator mode
1. Goto the folder where the script copied to
1. update choco-packages.json file to your need
1. run (role can be dev, cloudEngineer or qa, default role is cloudEngineer)
    > powershell.exe -executionpolicy bypass -file .\config-workstation.ps1 -role dev

## Automate Download and run latest release
To download the latets release and run the script using defaulr Role (cloudEngineer), you can save the following file to local as and run in pwoershell/cmd
https://github.com/101solution/workstation-setup/blob/main/get-latestPackages.ps1 or copy paster the scripts below and save it on your local disk as get-latestPackages.ps1

```
$configPath = "c:\config"
if (Test-Path -Path "$configPath" -PathType Container) {
    Write-Output "$configPath exists"
}
else {
    New-Item -Path $configPath -ItemType Directory -Force
}
Write-Output "Download latest workstaion config from github..."
$githubRepoUrl = "https://api.github.com/repos/101solution/workstation-setup/tags"
$tags = Invoke-RestMethod -Uri $githubRepoUrl -ErrorAction SilentlyContinue
$zipUrl = ($tags | Select-Object -first 1).zipball_url
Invoke-RestMethod -Uri $zipUrl -OutFile "$configPath\workstation.zip"
#Using .Net class System.IO.Compression.ZipFile
Add-Type -Assembly "System.IO.Compression.Filesystem"
[System.IO.Compression.ZipFile]::ExtractToDirectory("$configPath\workstation.zip", "$configPath")
if (Test-Path -Path "$configPath\workstation" -PathType Container) {
    Remove-Item -Path "$configPath\workstation" -Recurse -Force
}
Get-Item -Path "$configPath\101solution-workstation-*" | Rename-item -NewName "workstation"
Remove-Item -Path "$configPath\workstation.zip" -Force
Write-Output "Start workstation configuration..."
powershell.exe -executionpolicy bypass -file $configPath\workstation\config-workstation.ps1
```
Then run 

```
powershell.exe -executionpolicy bypass -file .\get-latestPackages.ps11
```
