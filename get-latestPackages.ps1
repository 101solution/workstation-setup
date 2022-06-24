$configPath = "c:\config"
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