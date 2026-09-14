#Requires -RunAsAdministrator
param (
    [Parameter()]
    [string]
    $role = "mrldev",
    [Parameter(HelpMessage = "Forwarded to config-workstation.ps1 -gitUser.")]
    [string]
    $gitUser = "",
    [Parameter(HelpMessage = "Forwarded to config-workstation.ps1 -gitEmail.")]
    [string]
    $gitEmail = ""
)
$configPath = "c:\config"
if (Test-Path -Path "$configPath" -PathType Container) {
    Write-Output "$configPath exists"
}
else {
    New-Item -Path $configPath -ItemType Directory -Force
}

$githubRepoUrl = "https://api.github.com/repos/101solution/workstation-setup/releases"
Write-Output "Download latest release from github $githubRepoUrl..."
try {
    $tags = Invoke-RestMethod -Uri $githubRepoUrl -ErrorAction Stop
}
catch {
    throw "Failed to query $githubRepoUrl - $($_.Exception.Message). Note the GitHub API allows only 60 unauthenticated requests per hour per public IP, which is shared behind corporate NAT."
}
$latestRelease = ($tags | Where-Object {(-not $_.draft) -and (-not $_.prerelease)} | Select-Object -first 1)
$zipUrl = $latestRelease.zipball_url
$version = $latestRelease.tag_name
if ([string]::IsNullOrEmpty($zipUrl)) {
    throw "No published release (non-draft, non-prerelease) found at $githubRepoUrl."
}
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
# Forward the git identity when given. Without this the documented one-liner left git with no
# user.name/user.email - the shipped .gitconfig sets neither - so a new machine's first commit
# failed with "Please tell me who you are" (TODO G35). Found by run 9, the first test to use the
# documented path instead of calling config-workstation.ps1 with parameters directly.
$setupArgs = @('-executionpolicy', 'bypass', '-file', "$configPath\workstation\config-workstation.ps1", '-role', $role)
if (-not [string]::IsNullOrWhiteSpace($gitUser))  { $setupArgs += @('-gitUser', $gitUser) }
if (-not [string]::IsNullOrWhiteSpace($gitEmail)) { $setupArgs += @('-gitEmail', $gitEmail) }
powershell.exe @setupArgs
