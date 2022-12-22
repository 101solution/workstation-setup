$configPath = "c:\config"
if (Test-Path -Path "$configPath" -PathType Container) {
    Write-Output "$configPath exists"
}
else {
    New-Item -Path $configPath -ItemType Directory -Force
}

$githubRepoUrl = "https://api.github.com/repos/101solution/workstation-setup/releases"
Write-Output "Download latest release from github $githubRepoUrl..."
$tags = Invoke-RestMethod -Uri $githubRepoUrl -ErrorAction SilentlyContinue
$latestRelease = ($tags | Where-Object {(-not $_.draft) -and (-not $_.prerelase)} | Select-Object -first 1)
$zipUrl = $latestRelease.zipball_url
$version = $latestRelease.tag_name
Write-Output "Latest version is $version"
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
