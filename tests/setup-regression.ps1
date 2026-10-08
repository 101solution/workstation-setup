# Run without Administrator privileges; all writes stay in a disposable test directory.
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. "$repoRoot\helper.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "workstation-tests-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot | Out-Null
$script:SetupStateRoot = $testRoot
$script:checks = 0
function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
try {
    $script:state = Get-SetupState
    $originalPreference = $ErrorActionPreference
    Invoke-SetupPhase -Phase broken -Body { Write-Error 'Simulated installer failure' }
    Assert-True (-not (Test-PhaseComplete -State $state -Phase broken)) 'A failed phase was recorded complete.'
    Assert-True ($script:failedPhases -contains 'broken') 'A failed phase was not reported.'
    Assert-True ($ErrorActionPreference -eq $originalPreference) 'Phase error preference leaked to the caller.'
    Invoke-SetupPhase -Phase healthy -Body { }
    Assert-True (Test-PhaseComplete -State $state -Phase healthy) 'A later successful phase did not complete.'
    Invoke-SetupPhase -Phase feature-reboot -Body { Request-PhaseReboot -Reason 'feature' }
    Invoke-SetupPhase -Phase package-reboot -Body { Request-PhaseReboot -Reason 'package' }
    Assert-True (-not (Test-PhaseComplete -State $state -Phase package-reboot)) 'A second reboot request was incorrectly recorded complete.'

    $resume = Get-ResumeCommand -ScriptPath "C:\folder with spaces\setup.ps1" -BoundParameters @{
        force = [Management.Automation.SwitchParameter]::new($true)
        role = 'mrl'; gitUser = "O'Brien"; enableWSL = $false
    }
    Assert-True ($resume -notmatch '-force') 'Reboot continuation retained -force.'
    Assert-True ($resume -match "O''Brien" -and $resume -match '-enableWSL \$false') 'Resume arguments lost quoting or boolean values.'

    $script:state = Get-SetupState
    Initialize-SetupInputs -State $state -Inputs @{ winget = 'mrl'; shell = 'folder-a' } -UserPhases @('winget', 'shell') -UserId 'user-a'
    Complete-Phase -State $state -Phase winget
    Complete-Phase -State $state -Phase shell
    Complete-Phase -State $state -Phase fonts
    Initialize-SetupInputs -State $state -Inputs @{ winget = 'mrl'; shell = 'folder-a' } -UserPhases @('winget', 'shell') -UserId 'user-b'
    Assert-True (-not (Test-PhaseComplete -State $state -Phase shell)) 'A second user inherited profile completion.'
    Assert-True (Test-PhaseComplete -State $state -Phase fonts) 'A second user lost machine progress.'
    Initialize-SetupInputs -State $state -Inputs @{ winget = 'mrl'; shell = 'folder-a' } -UserPhases @('winget', 'shell') -UserId 'user-a'
    Assert-True (Test-PhaseComplete -State $state -Phase shell) 'Returning to the original user lost unchanged progress.'
    Initialize-SetupInputs -State $state -Inputs @{ winget = 'mrldev'; shell = 'folder-b' } -UserPhases @('winget', 'shell') -UserId 'user-a'
    Assert-True (-not (Test-PhaseComplete -State $state -Phase winget)) 'Changing the role did not invalidate packages.'
    Assert-True (-not (Test-PhaseComplete -State $state -Phase shell)) 'Changing settings did not invalidate profile configuration.'
    Assert-True (Test-PhaseComplete -State $state -Phase fonts) 'Changing user settings invalidated unrelated machine progress.'
    Save-SetupState -State $state
    $reloaded = Get-SetupState
    Assert-True ($reloaded.phaseInputs.PSObject.Properties['shell@user-a'].Value -eq $state.phaseInputs.PSObject.Properties['shell@user-a'].Value) 'Input fingerprints did not survive persistence.'

    # Exercise native exit handling through a fake WinGet PowerShell script.
    $script:fakeWinget = Join-Path $testRoot 'winget.ps1'
    function Get-WinGetPath { return $script:fakeWinget }
    Set-Content -LiteralPath $script:fakeWinget -Value 'exit 1'
    $script:rebootPending = $false
    Invoke-SetupPhase -Phase failed-package -Body { Install-WinGetPackage -packageId 'Test.Package' }
    Assert-True (-not (Test-PhaseComplete -State $state -Phase failed-package)) 'A failed WinGet install completed the phase.'
    Set-Content -LiteralPath $script:fakeWinget -Value 'exit 0'
    Invoke-SetupPhase -Phase failed-package -Body { Install-WinGetPackage -packageId 'Test.Package' }
    Assert-True (Test-PhaseComplete -State $state -Phase failed-package) 'Retrying a successful package did not complete.'

    $profilePath = Join-Path $testRoot 'profile.ps1'
    Set-Content -LiteralPath $profilePath -Value '$customPreference = 42'
    Set-ManagedProfileLoader -Path $profilePath
    Set-ManagedProfileLoader -Path $profilePath
    $profileText = [IO.File]::ReadAllText($profilePath)
    Assert-True ($profileText.Contains('$customPreference = 42')) 'Profile customization was lost.'
    Assert-True ([regex]::Matches($profileText, '# BEGIN workstation-setup').Count -eq 1) 'Profile loader was duplicated.'
    Assert-True (@(Get-ChildItem "$profilePath.workstation-backup-*").Count -eq 1) 'Profile update was not backed up or unchanged loader was rewritten.'
    $legacyPath = Join-Path $testRoot 'legacy-profile.ps1'
    Set-Content -LiteralPath $legacyPath -Value '$managedOnly = 1'
    Set-ManagedProfileLoader -Path $legacyPath -LegacyContent '$managedOnly = 1'
    Assert-True (-not ([IO.File]::ReadAllText($legacyPath).Contains('$managedOnly = 1'))) 'Unchanged legacy profile would initialize the managed profile twice.'

    $gitPath = Join-Path $testRoot '.gitconfig'
    $sourcePath = Join-Path $testRoot 'defaults.gitconfig'
    Set-Content -LiteralPath $gitPath -Value "[user]`n name = Existing User`n email = existing@example.com`n[core]`n editor = custom-editor"
    Set-Content -LiteralPath $sourcePath -Value "[core]`n editor = code`n longpaths = true"
    Install-ManagedGitConfig -Source $sourcePath -Destination $gitPath
    Install-ManagedGitConfig -Source $sourcePath -Destination $gitPath
    Assert-True ((& git config --file $gitPath --includes --get user.name) -eq 'Existing User') 'Git identity was lost.'
    Assert-True ((& git config --file $gitPath --includes --get core.editor) -eq 'custom-editor') 'Git customization was overridden.'
    Assert-True ((& git config --file $gitPath --includes --get core.longpaths) -eq 'true') 'Managed Git defaults were not loaded.'
    Assert-True ([regex]::Matches([IO.File]::ReadAllText($gitPath), 'path = .workstation.gitconfig').Count -eq 1) 'Git include was duplicated.'

    function Invoke-RestMethod { return [pscustomobject]@{ Os = 'windows'; Version = '29.8.0' } }
    Assert-DockerEndpoint -Port 2378 -Os windows -Version '29.8.0'
    $rejected = $false
    try { Assert-DockerEndpoint -Port 2375 -Os linux } catch { $rejected = $true }
    Assert-True $rejected 'Docker verification accepted the wrong daemon.'
    $rejected = $false
    try { Assert-DockerEndpoint -Port 2378 -Os windows -Version '29.9.0' } catch { $rejected = $true }
    Assert-True $rejected 'Docker verification accepted the wrong version.'

    # Real archive/copy operations, fake version probes and services: never touches C:\docker.
    $dockerDestination = Join-Path $testRoot 'installed-docker'
    New-Item -ItemType Directory -Path $dockerDestination | Out-Null
    Set-Content (Join-Path $dockerDestination 'dockerd.exe') '29.7.0'
    Set-Content (Join-Path $dockerDestination 'docker.exe') '29.7.0'
    function Get-DockerBinaryVersion {
        param($Path)
        if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw).Trim() }
        return ''
    }
    $script:downloads = 0
    $script:stops = 0
    $script:archiveVersion = '29.8.0'
    function Get-Service { param($Name) return [pscustomobject]@{ Name = $Name } }
    function Stop-Service { param($Name) $script:stops++ }
    function Invoke-WebRequest {
        param($Uri, $OutFile, [switch]$UseBasicParsing)
        $script:downloads++
        $archiveRoot = Join-Path $testRoot "archive-$script:downloads"
        New-Item -ItemType Directory -Path (Join-Path $archiveRoot 'docker') | Out-Null
        Set-Content (Join-Path $archiveRoot 'docker\dockerd.exe') $script:archiveVersion
        Set-Content (Join-Path $archiveRoot 'docker\docker.exe') $script:archiveVersion
        Compress-Archive -Path (Join-Path $archiveRoot 'docker') -DestinationPath $OutFile
    }
    Install-WindowsDockerBinaries -Version '29.8.0' -Destination $dockerDestination
    Assert-True ((Get-DockerBinaryVersion (Join-Path $dockerDestination 'dockerd.exe')) -eq '29.8.0') 'Docker upgrade did not replace existing binaries.'
    Assert-True ($script:stops -eq 1) 'Docker service was not stopped before replacement.'
    Install-WindowsDockerBinaries -Version '29.8.0' -Destination $dockerDestination
    Assert-True ($script:downloads -eq 1 -and $script:stops -eq 1) 'Unchanged Docker version was unnecessarily reinstalled.'
    $script:archiveVersion = 'incorrect'
    $rejected = $false
    try { Install-WindowsDockerBinaries -Version '29.9.0' -Destination $dockerDestination } catch { $rejected = $true }
    Assert-True $rejected 'Unexpected downloaded Docker version was accepted.'
    Assert-True ($script:stops -eq 1 -and (Get-DockerBinaryVersion (Join-Path $dockerDestination 'dockerd.exe')) -eq '29.8.0') 'Bad download disrupted the existing Docker installation.'
    Remove-Item -LiteralPath (Join-Path $dockerDestination 'docker.exe')
    $script:archiveVersion = '29.8.0'
    Install-WindowsDockerBinaries -Version '29.8.0' -Destination $dockerDestination
    Assert-True (Test-Path -LiteralPath (Join-Path $dockerDestination 'docker.exe')) 'Partial Docker installation was not repaired.'
    Write-Host "Passed $script:checks regression assertions on PowerShell $($PSVersionTable.PSVersion)."
}
finally {
    $resolvedTest = (Resolve-Path -LiteralPath $testRoot).Path
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test directory escaped TEMP.' }
    Remove-Item -LiteralPath $resolvedTest -Recurse -Force
}
