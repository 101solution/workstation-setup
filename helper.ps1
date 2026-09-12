filter timestamp { "$(Get-Date -Format o): $_" }


Function New-WindowsTask {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $TaskName,
        [Parameter()]
        [string]
        $WorkingDirectory,
        [Parameter()]
        [string]
        $PSCommand
    )
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        $delayTimeSpan = [TimeSpan]::FromMinutes(5)
        $action = New-ScheduledTaskAction -Execute 'Powershell.exe' -Argument $PSCommand -WorkingDirectory $WorkingDirectory
        $trigger = New-ScheduledTaskTrigger -AtStartup -RandomDelay $delayTimeSpan
        $user = "NT AUTHORITY\SYSTEM" # Specify the account to run the script
        $task = Register-ScheduledTask -Action $action -Trigger $trigger -TaskName $TaskName -Description $TaskName -User $user -RunLevel Highest -Force
        Write-Output "Created Scheduled Task - $TaskName"  | timestamp
    }
    else {
        Write-Output "Scheduled Task - $TaskName is exists"  | timestamp
    }
}
Function Remove-WindowsTask {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $TaskName
    )
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Output "Removed Scheduled Task - $TaskName"  | timestamp
    }
}
Function Install-Fonts {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $fontName = "CaskaydiaCoveNerdFontMono-Regular",
        [Parameter()]
        [string]
        $fontFolder = "."
    )
    $fontRegPath = "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
    $fontReg = Get-ItemProperty -Name "$fontName (TrueType)" -Path $fontRegPath -ErrorAction SilentlyContinue 
    $fontFileExixts = Test-Path -LiteralPath "C:\Windows\Fonts\$fontName.ttf"
    if (-not($fontReg) -or -not($fontFileExixts)) {
        Write-Output "Installing Font $fontName..."
        Copy-Item "$fontFolder\$fontName.ttf" "C:\Windows\Fonts" -Force
        New-ItemProperty -Name "$fontName (TrueType)" -Path $fontRegPath -PropertyType string -Value "$fontName.ttf" -Force | Out-Null
    }
}

function Get-EnvironmentVariableNames([System.EnvironmentVariableTarget] $Scope) {
    switch ($Scope) {
        'User' { Get-Item 'HKCU:\Environment' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Property }
        'Machine' { Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' | Select-Object -ExpandProperty Property }
        'Process' { Get-ChildItem Env:\ | Select-Object -ExpandProperty Key }
        default { throw "Unsupported environment scope: $Scope" }
    }
}

Function Get-EnvironmentVariable {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][System.EnvironmentVariableTarget] $Scope,
        [Parameter(Mandatory = $false)][switch] $PreserveVariables = $false,
        [parameter(ValueFromRemainingArguments = $true)][Object[]] $ignoredArguments
    )

    # Do not log function call, it may expose variable names

    [string] $MACHINE_ENVIRONMENT_REGISTRY_KEY_NAME = "SYSTEM\CurrentControlSet\Control\Session Manager\Environment\";
    [Microsoft.Win32.RegistryKey] $win32RegistryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($MACHINE_ENVIRONMENT_REGISTRY_KEY_NAME)
    if ($Scope -eq [System.EnvironmentVariableTarget]::User) {
        [string] $USER_ENVIRONMENT_REGISTRY_KEY_NAME = "Environment";
        [Microsoft.Win32.RegistryKey] $win32RegistryKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($USER_ENVIRONMENT_REGISTRY_KEY_NAME)
    }
    elseif ($Scope -eq [System.EnvironmentVariableTarget]::Process) {
        return [Environment]::GetEnvironmentVariable($Name, $Scope)
    }

    [Microsoft.Win32.RegistryValueOptions] $registryValueOptions = [Microsoft.Win32.RegistryValueOptions]::None

    if ($PreserveVariables) {
        Write-Verbose "Choosing not to expand environment names"
        $registryValueOptions = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    }

    [string] $environmentVariableValue = [string]::Empty

    try {
        #Write-Verbose "Getting environment variable $Name"
        if ($win32RegistryKey -ne $null) {
            # Some versions of Windows do not have HKCU:\Environment
            $environmentVariableValue = $win32RegistryKey.GetValue($Name, [string]::Empty, $registryValueOptions)
        }
    }
    catch {
        Write-Debug "Unable to retrieve the $Name environment variable. Details: $_"
    }
    finally {
        if ($win32RegistryKey -ne $null) {
            $win32RegistryKey.Close()
        }
    }

    if ($environmentVariableValue -eq $null -or $environmentVariableValue -eq '') {
        $environmentVariableValue = [Environment]::GetEnvironmentVariable($Name, $Scope)
    }

    return $environmentVariableValue
}

Function Update-SessionEnvironment {
    $userName = $env:USERNAME
    $architecture = $env:PROCESSOR_ARCHITECTURE
    $psModulePath = $env:PSModulePath

    #ordering is important here, $user should override $machine...
    $ScopeList = 'Process', 'Machine'
    if ($userName -notin 'SYSTEM', "${env:COMPUTERNAME}`$") {
        # but only if not running as the SYSTEM/machine in which case user can be ignored.
        $ScopeList += 'User'
    }
    foreach ($Scope in $ScopeList) {
        Get-EnvironmentVariableNames -Scope $Scope |
        ForEach-Object {
            Set-Item "Env:$_" -Value (Get-EnvironmentVariable -Scope $Scope -Name $_)
        }
    }

    #Path gets special treatment b/c it munges the two together
    $paths = 'Machine', 'User' |
    ForEach-Object {
      (Get-EnvironmentVariable -Name 'PATH' -Scope $_) -split ';'
    } |
    Select-Object -Unique
    $Env:PATH = $paths -join ';'

    # PSModulePath is almost always updated by process, so we want to preserve it.
    $env:PSModulePath = $psModulePath

    # reset user and architecture
    if ($userName) { $env:USERNAME = $userName; }
    if ($architecture) { $env:PROCESSOR_ARCHITECTURE = $architecture; }
}

Function Install-WinGet {
    #Install the latest package from GitHub
    [cmdletbinding(SupportsShouldProcess)]
    [alias("iwg")]
    [OutputType("None")]
    [OutputType("Microsoft.Windows.Appx.PackageManager.Commands.AppxPackage")]
    Param(
        [Parameter(HelpMessage = "Install the latest preview build.")]
        [switch]$Preview,
        [Parameter(HelpMessage = "Display the AppxPackage after installation.")]
        [switch]$Passthru,
        [Parameter(HelpMessage = "Upgrade to Latest version.")]
        [switch]$Upgrade
    )
    Write-Output "  Checking if winget installed..." | timestamp
    $wingetCmd = Get-Command -Name winget.exe -ErrorAction SilentlyContinue
    if ((-not $wingetCmd) -or $Upgrade) {
        Write-Output "  Winget is not installed, install now..." | timestamp

        if ($IsCoreCLR -and ($PSVersionTable.PSVersion -lt [version]"7.2")) {
            Write-Warning "If running this command in PowerShell 7, you need at least version 7.2."
            return
        }

            Write-Output "  Installing required package Microsoft.VCLibs.140.00.UWPDesktop..." | timestamp
            Try {
                Add-AppxPackage -Path https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx -ErrorAction SilentlyContinue
            }
            Catch {
                Throw $_
            }
        
            Write-Output "  Installing required package Microsoft.UI.Xaml.2.8..." | timestamp
            try {
                Add-AppxPackage -Path  https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx -ErrorAction SilentlyContinue
            }
            catch {
                Throw $_
            }

        Try {
            If ($pscmdlet.ShouldProcess("Microsoft.DesktopAppInstaller", "Download and install winget")) {
                Write-Output "  Installing winget cli..." | timestamp
                Add-AppxPackage -Path https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle -ErrorAction Stop

                if ($passthru) {
                    Get-AppxPackage microsoft.desktopAppInstaller
                }
            }
        } #Try
        Catch {
            Write-Verbose "[$((Get-Date).TimeofDay)] There was an error."
            Throw $_
        }
        Write-Verbose "[$((Get-Date).TimeofDay)] Ending $($myinvocation.mycommand)"
    }
}
Function Register-AppxForCurrentUser {
    <#
        .SYNOPSIS
            Registers an already-provisioned Store package for the current user and waits for its
            app-execution alias to appear.
        .DESCRIPTION
            On a freshly created profile the machine-wide package exists but the per-user alias in
            %LOCALAPPDATA%\Microsoft\WindowsApps does not, so `winget`/`wt` are "not recognized"
            (seen on the Azure Win11 24H2 image, even after a reboot). Returns the alias path or $null.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $PackageFamilyName,
        [Parameter(Mandatory)] [string] $ExeName,
        [Parameter()] [int] $TimeoutSeconds = 120
    )
    $aliasPath = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\$ExeName"
    if (Test-Path -LiteralPath $aliasPath) { return $aliasPath }

    Write-SetupLog "  $ExeName alias missing for this user; registering $PackageFamilyName..."
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage $PackageFamilyName -ErrorAction Stop
    }
    catch {
        Write-SetupLog "  Add-AppxPackage -RegisterByFamilyName failed: $($_.Exception.Message)"
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $aliasPath) { return $aliasPath }
        Start-Sleep -Seconds 5
    }
    return $null
}

Function Get-PackagedExePath {
    <#
        .SYNOPSIS
            Resolves an executable that ships in a Store package: PATH first, then the per-user
            alias (registering the package for this user if needed), then the package folder itself.
            Returns $null when none of those exist.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $ExeName,
        [Parameter(Mandatory)] [string] $PackageName,
        [Parameter(Mandatory)] [string] $PackageFamilyName
    )
    $cmd = Get-Command -Name $ExeName -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $alias = Register-AppxForCurrentUser -PackageFamilyName $PackageFamilyName -ExeName $ExeName
    if ($alias) { return $alias }

    $package = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if ($package) {
        $inPackage = Join-Path $package.InstallLocation $ExeName
        if (Test-Path -LiteralPath $inPackage) {
            Write-SetupLog "  Using $ExeName from the package folder: $inPackage"
            return $inPackage
        }
    }
    return $null
}

$script:WinGetExe = $null
Function Get-WinGetPath {
    <#
        .SYNOPSIS
            The winget executable to invoke, resolved once and cached. $null if winget is unavailable.
    #>
    if ($script:WinGetExe -and (Test-Path -LiteralPath $script:WinGetExe)) { return $script:WinGetExe }
    $script:WinGetExe = Get-PackagedExePath -ExeName 'winget.exe' -PackageName 'Microsoft.DesktopAppInstaller' `
        -PackageFamilyName 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
    return $script:WinGetExe
}

Function Get-WindowsTerminalPath {
    return (Get-PackagedExePath -ExeName 'wt.exe' -PackageName 'Microsoft.WindowsTerminal' `
        -PackageFamilyName 'Microsoft.WindowsTerminal_8wekyb3d8bbwe')
}

function Convert-WingetOutput {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string[]]
        $wingetOutput,
        [Parameter()]
        [string]
        $packageId
    )
    if (-not $wingetOutput) {
        return $null
    }

    # Locate the header and data rows by content rather than by fixed index. winget prepends a
    # variable number of progress/spinner lines, so the header is not reliably line 0 and the
    # matching package is not reliably line 2.
    $headerLine = $null
    $headerIndex = -1
    for ($i = 0; $i -lt $wingetOutput.Count; $i++) {
        $line = $wingetOutput[$i]
        if ($line -and ($line.IndexOf("Id") -ge 0) -and ($line.IndexOf("Version") -ge 0)) {
            $headerLine = $line
            $headerIndex = $i
            break
        }
    }
    if ($null -eq $headerLine) {
        return $null
    }

    $dataLine = $null
    for ($i = $headerIndex + 1; $i -lt $wingetOutput.Count; $i++) {
        if ($wingetOutput[$i] -and ($wingetOutput[$i].IndexOf($packageId) -ge 0)) {
            $dataLine = $wingetOutput[$i]
            break
        }
    }
    if ($null -eq $dataLine) {
        return $null
    }

    $idIndex = $headerLine.IndexOf("Id")
    $appIndex = $dataLine.IndexOf($packageId)
    if ($idIndex -lt 0 -or $appIndex -lt 0) {
        return $null
    }

    $header = $headerLine.Substring($idIndex) -replace '\s+', ","
    $data = $dataLine.Substring($appIndex) -replace '\s+', ","
    return @($header, $data) | ConvertFrom-Csv
}
function Install-WingetPackage {
    param (
        [string] $packageId,
        [string] $overrideParameters = "",
        [string] $source = "winget"
    )
    
        Write-Output "Checking package $packageId... using WinGet" | timestamp
        $winget = Get-WinGetPath
        if (-not $winget) {
            throw "winget is not available in this session; cannot install $packageId."
        }

        $outputRaw = & $winget list -e --id $packageId --accept-source-agreements --source $source
        Start-Sleep -Milliseconds 150
        $outputRaw = & $winget list -e --id $packageId --accept-source-agreements --source $source
        $output = Convert-WingetOutput -wingetOutput $outputRaw -packageId $packageId
        if ($null -eq $output) {
            Write-Output "    Installing package $packageId..." | timestamp
            if ($overrideParameters -ne "") {
                & $winget install -e --id $packageId -h --accept-package-agreements --accept-source-agreements --override "$overrideParameters" --source $source
            }
            else {
                & $winget install -e --id $packageId -h --accept-package-agreements --accept-source-agreements --source $source
            }
        }
        else {
            if (($null -ne $output.Available) -and ($output.Available -ne "")) {
                Write-Output "    Upgarding package $packageId..." | timestamp
                & $winget upgrade -e --id $packageId -h --accept-package-agreements --accept-source-agreements --source $source
            }
            else {
                Write-Output "    Latest version of $packageId... already installed" | timestamp
            }
        }
}

Function Update-EnvironmentPath {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $NewPath
    )
    if (Test-Path -path "$NewPath") {
        $containerType = [EnvironmentVariableTarget]::Machine
        $persistedPaths = [Environment]::GetEnvironmentVariable('Path', $containerType) -split ';'
        if ($persistedPaths -notcontains $NewPath) {
            $persistedPaths = $persistedPaths + $NewPath | Where-Object { $_ }
            [Environment]::SetEnvironmentVariable('Path', $persistedPaths -join ';', $containerType)
        }           
    }
}
Function Install-DockerEngine {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $InstallPath
    )
    # Idempotent: safe to re-run after a reboot or on an already-configured box.
    if (-not(Test-Path $InstallPath)) {
        New-Item -Path $InstallPath -ItemType Directory -Force | Out-Null
    }
    $dockerexe = Get-Command -Name docker.exe -ErrorAction SilentlyContinue
    if (-not $dockerexe) {
        $Version = "20.10.21"
        $zipPath = Join-Path $env:TEMP "docker-$Version.zip"
        Write-Output "Downloading Docker Engine $Version..." | timestamp
        curl.exe -L "https://download.docker.com/win/static/stable/x86_64/docker-$Version.zip" -o $zipPath
        if (-not (Test-Path -LiteralPath $zipPath)) {
            throw "Docker Engine download failed; $zipPath was not created."
        }
        Expand-Archive -LiteralPath $zipPath -DestinationPath $InstallPath -Force
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Output "docker.exe already present at $($dockerexe.Source)" | timestamp
    }
    Update-EnvironmentPath -NewPath "$InstallPath\Docker"
    Update-SessionEnvironment
    $dockerexe = Get-Command -Name docker.exe -ErrorAction SilentlyContinue
    if ($dockerexe) {
        if (-not (Get-Service -Name docker -ErrorAction SilentlyContinue)) {
            Write-Output "Registering the docker service..." | timestamp
            dockerd.exe --register-service
        }
        $service = Get-Service -Name docker -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne 'Running') {
            Write-Output "Starting the docker service..." | timestamp
            Start-Service docker
        }
    }
    else {
        Write-Warning "docker.exe still not found after install; skipping service registration."
    }
}
Function Install-PSModule {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $PsModuleName
    )
    Write-Output "Checking PS Module $PsModuleName... " | timestamp
    $installedModule = Get-InstalledModule -Name $PsModuleName -ErrorAction SilentlyContinue

    if ($null -eq $installedModule) {
        # Get-InstalledModule only sees modules installed via PowerShellGet, so modules that ship
        # in-box (PSReadLine) always look absent and get reinstalled on every run. Check the module
        # path as well, and pass -SkipPublisherCheck when we do install: the in-box copy is signed by
        # a different Microsoft authority than the gallery copy, which otherwise blocks the install.
        $availableModule = Get-Module -Name $PsModuleName -ListAvailable -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending | Select-Object -First 1
        $galleryModule = Find-Module -Name $PsModuleName -Repository PSGallery -ErrorAction SilentlyContinue
        if ($availableModule -and $galleryModule -and ($availableModule.Version -ge $galleryModule.Version)) {
            Write-Output "  PS Module $PsModuleName $($availableModule.Version) is already present." | timestamp
            return
        }
        Write-Output "  Installing PS Module $PsModuleName..."  | timestamp
        Install-Module -Name $PsModuleName -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck
    }
    else {
        $latestModule = Find-Module -Name $PsModuleName -Repository PSGallery
        if ($installedModule.Version.CompareTo($latestModule.Version) -lt 0) {
            Write-Output "  Updating PS Module $PsModuleName from $($installedModule.Version.ToString()) to version $($latestModule.Version.ToString()) ..."  | timestamp
            Update-Module -Name $PsModuleName -Force
        }
        else {
            Write-Output "  Latest PS Module $PsModuleName has been installed." | timestamp
        }
    }
}
Function Format-Json([Parameter(Mandatory, ValueFromPipeline)][String] $json) {
    $indent = 0;
    ($json -Split "`n" | % {
        if ($_ -match '[\}\]]\s*,?\s*$') {
            # This line ends with ] or }, decrement the indentation level
            $indent--
        }
        $line = ('  ' * $indent) + $($_.TrimStart() -replace '":  (["{[])', '": $1' -replace ':  ', ': ')
        if ($_ -match '[\{\[]\s*$') {
            # This line ends with [ or {, increment the indentation level
            $indent++
        }
        $line
    }) -Join "`n"
}

#region Unattended execution and reboot resume
# ---------------------------------------------------------------------------------------------
# NOTE ON LOGGING INSIDE VALUE-RETURNING FUNCTIONS
# The `Write-Output "..." | timestamp` idiom used elsewhere in this repo writes to the SUCCESS
# stream, so inside a function that also returns a value the log lines become part of the return
# value. `return $false` after two log lines yields @('msg','msg',$false), and `if (Fn)` on a
# non-empty array is TRUE - which would make Enable-WslFeature demand a reboot forever. Functions
# below whose return value is tested therefore log via Write-SetupLog, which uses the information
# stream (still captured by Start-Transcript) and leaves the success stream clean.
# ---------------------------------------------------------------------------------------------

Function Write-SetupLog {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string] $Message
    )
    Write-Information "$(Get-Date -Format o): $Message" -InformationAction Continue
}

# ---------------------------------------------------------------------------------------------
# Setup runs in named phases. Completed phases are recorded in a state file outside the repo so a
# re-download by get-latestPackages.ps1 cannot lose progress. When a step needs a reboot, the state
# is flushed, a resume scheduled task is registered, and the machine restarts; on the next logon the
# task re-invokes this script with the original arguments and every completed phase is skipped.
# ---------------------------------------------------------------------------------------------

$script:SetupStateRoot = Join-Path $env:ProgramData 'workstation-setup'

# Each entry script keeps its own state file so their phase names cannot collide: the workstation
# and runner scripts both have a 'winget' phase, and the Docker CE orchestrator has its own gate.
# Because helper.ps1 is dot-sourced, the calling script can override this right after sourcing.
$script:SetupStateFileName = 'setup-state.json'

Function Get-SetupStatePath {
    return (Join-Path $script:SetupStateRoot $script:SetupStateFileName)
}

Function Get-SetupState {
    <#
        .SYNOPSIS
            Loads the resume state, or returns a fresh one. Never throws - a corrupt state file
            must degrade to "start from the beginning", not abort an unattended build.
    #>
    $defaults = [ordered]@{
        completedPhases = @()
        rebootCount     = 0
        runCount        = 0
        startedUtc      = (Get-Date).ToUniversalTime().ToString('o')
        lastRunUtc      = $null
        resumeCommand   = $null
        resumeMethod    = $null
    }

    $state = $null
    $statePath = Get-SetupStatePath
    if (Test-Path -LiteralPath $statePath) {
        try {
            $state = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Write-Warning "Resume state at $statePath is unreadable ($($_.Exception.Message)); starting from the first phase."
            $state = $null
        }
    }

    if ($null -eq $state) {
        return [pscustomobject]$defaults
    }

    # Normalise the shape: a state file written by an earlier version of this script will be
    # missing newer fields, and assigning to an absent property on a PSCustomObject throws.
    foreach ($key in $defaults.Keys) {
        if ($null -eq $state.PSObject.Properties[$key]) {
            $state | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key] -Force
        }
    }
    # ConvertFrom-Json collapses a single-element array to a scalar; force it back.
    $state.completedPhases = @($state.completedPhases | Where-Object { $_ })
    return $state
}

Function Save-SetupState {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        $State
    )
    if (-not (Test-Path -LiteralPath $script:SetupStateRoot)) {
        New-Item -Path $script:SetupStateRoot -ItemType Directory -Force | Out-Null
    }
    $State.lastRunUtc = (Get-Date).ToUniversalTime().ToString('o')
    $State | ConvertTo-Json -Depth 10 | Out-File -LiteralPath (Get-SetupStatePath) -Encoding utf8 -Force
}

Function Clear-SetupState {
    $statePath = Get-SetupStatePath
    if (Test-Path -LiteralPath $statePath) {
        Remove-Item -LiteralPath $statePath -Force
        Write-Output "Cleared resume state $statePath" | timestamp
    }
}

Function Test-PhaseComplete {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string] $Phase
    )
    return (@($State.completedPhases) -contains $Phase)
}

Function Complete-Phase {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string] $Phase
    )
    if (-not (Test-PhaseComplete -State $State -Phase $Phase)) {
        $State.completedPhases = @(@($State.completedPhases) + $Phase)
        Save-SetupState -State $State
    }
}

# ---------------------------------------------------------------------------------------------
# Phase runner, shared by every entry script. Contract with the calling script (which this file is
# dot-sourced into, so `$script:` below resolves to the CALLER's script scope):
#   $state          - loaded by the caller via Get-SetupState before the first Invoke-SetupPhase
#   $rebootPending  - set here by Request-PhaseReboot; the caller tests it at its reboot gate
#   $rebootReason   - first reason given, for the log
#   $failedPhases   - names of phases that threw this run; Complete-Setup turns it into exit 1
# ---------------------------------------------------------------------------------------------
$script:rebootPending = $false
$script:rebootReason = ''
$script:failedPhases = @()
$script:SetupExitCode = 0

Function Request-PhaseReboot {
    <#
        .SYNOPSIS
            Called from inside a phase body when the phase cannot finish until Windows restarts.
        .DESCRIPTION
            A flag rather than a return value, because this repo's `Write-Output ... | timestamp`
            logging writes to the success stream and would be mixed into a phase's return value.
    #>
    param ([Parameter(Mandatory)] [string] $Reason)
    $script:rebootPending = $true
    if ([string]::IsNullOrEmpty($script:rebootReason)) {
        $script:rebootReason = $Reason
    }
}

Function Invoke-SetupPhase {
    <#
        .SYNOPSIS
            Runs one phase unless it is already recorded complete, then records it.
        .DESCRIPTION
            A phase that throws is logged and left un-recorded, so the next run retries it instead
            of the whole unattended build aborting. A phase that calls Request-PhaseReboot is also
            left un-recorded so it re-runs after the restart.
    #>
    param (
        [Parameter(Mandatory)] [string] $Phase,
        [Parameter(Mandatory)] [scriptblock] $Body
    )
    if (Test-PhaseComplete -State $script:state -Phase $Phase) {
        Write-Output "--- phase '$Phase': already complete, skipping" | timestamp
        return
    }
    Write-Output "" | timestamp
    Write-Output "--- phase '$Phase': starting" | timestamp
    $rebootOwedBefore = $script:rebootPending
    try {
        & $Body
        if ($script:rebootPending -and -not $rebootOwedBefore) {
            Write-Output "--- phase '$Phase': deferred, needs a restart first" | timestamp
            return
        }
        Complete-Phase -State $script:state -Phase $Phase
        Write-Output "--- phase '$Phase': complete" | timestamp
    }
    catch {
        Write-Warning "--- phase '$Phase' failed: $($_.Exception.Message). It will be retried on the next run."
        Write-Output $_.ScriptStackTrace | timestamp
        $script:failedPhases = @(@($script:failedPhases) + $Phase)
    }
}

Function Complete-Setup {
    <#
        .SYNOPSIS
            Ends a setup run honestly. Always clears the resume hooks (a broken phase must not
            re-run at every logon), but records 'done' and exits 0 only when no phase failed;
            otherwise lists the failures and sets exit code 1 so the caller/pipeline can see it.
            The exit code is left in $SetupExitCode for the calling script to `exit` with.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string] $TaskName,
        [Parameter(Mandatory)] [string] $Title
    )
    Clear-ResumeHooks -Name $TaskName
    $failed = @($script:failedPhases)
    Write-Output "" | timestamp
    if ($failed.Count -gt 0) {
        Write-Warning "=== $Title finished with $($failed.Count) FAILED phase(s): $($failed -join ', ') ==="
        Write-Output "  Fix the cause and re-run the same command; completed phases are skipped." | timestamp
        $script:SetupExitCode = 1
    }
    else {
        Complete-Phase -State $State -Phase 'done'
        Write-Output "=== $Title finished ===" | timestamp
        $script:SetupExitCode = 0
    }
    Write-Output "  Runs: $($State.runCount)   Reboots: $($State.rebootCount)" | timestamp
    Write-Output "  Phases completed: $((@($State.completedPhases) -join ', '))" | timestamp
    Write-Output "  State file: $(Get-SetupStatePath)" | timestamp
    Write-Output "  Re-run with -force to redo every phase from scratch." | timestamp
}

Function Test-PendingReboot {
    <#
        .SYNOPSIS
            True when Windows has a reboot outstanding. Installing on top of a pending reboot is a
            common cause of half-failed MSI/feature installs, so setup drains it first.
    #>
    $pendingKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Services\Pending'
    )
    foreach ($key in $pendingKeys) {
        if (Test-Path -LiteralPath $key) {
            Write-SetupLog "  Pending reboot signalled by $key"
            return $true
        }
    }

    $sessionManager = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
        -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
    if ($sessionManager -and $sessionManager.PendingFileRenameOperations) {
        Write-SetupLog "  Pending reboot signalled by PendingFileRenameOperations"
        return $true
    }

    $activeName = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' `
        -Name 'ComputerName' -ErrorAction SilentlyContinue
    $pendingName = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' `
        -Name 'ComputerName' -ErrorAction SilentlyContinue
    if ($activeName -and $pendingName -and ($activeName.ComputerName -ne $pendingName.ComputerName)) {
        Write-SetupLog "  Pending reboot signalled by a pending computer rename"
        return $true
    }

    return $false
}

Function Get-ResumeCommand {
    <#
        .SYNOPSIS
            Rebuilds the command line that re-invokes setup after a reboot.
        .DESCRIPTION
            Uses -Command rather than -File so PowerShell parses real argument syntax: with -File
            every argument arrives as a string and a [boolean] parameter such as -enableWSL would
            bind the literal text '$true' instead of a boolean.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $ScriptPath,
        [Parameter(Mandatory)] [hashtable] $BoundParameters
    )
    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add("& '$($ScriptPath.Replace("'", "''"))'")
    foreach ($entry in $BoundParameters.GetEnumerator() | Sort-Object Key) {
        $name = $entry.Key
        $value = $entry.Value
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $arguments.Add("-$name") }
        }
        elseif ($value -is [bool]) {
            $arguments.Add("-$name `$$($value.ToString().ToLowerInvariant())")
        }
        else {
            $arguments.Add("-$name '$([string]$value -replace "'", "''")'")
        }
    }
    return ($arguments -join ' ')
}

Function Register-ResumeTask {
    <#
        .SYNOPSIS
            Registers the post-reboot continuation task.
        .DESCRIPTION
            The task runs as the invoking user, elevated, at that user's logon. It must NOT run as
            SYSTEM: setup writes per-user artefacts (the PowerShell profile, .gitconfig, the Windows
            Terminal settings, the Oh My Posh theme) and under SYSTEM those would land in
            C:\Windows\System32\config\systemprofile instead of the real profile.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $TaskName,
        [Parameter(Mandatory)] [string] $ResumeCommand,
        [Parameter()] [string] $WorkingDirectory = $PSScriptRoot
    )
    $runAsUser = "$($env:USERDOMAIN)\$($env:USERNAME)"
    $argumentString = "-ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden -Command `"$ResumeCommand`""

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argumentString -WorkingDirectory $WorkingDirectory
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $runAsUser
    $principal = New-ScheduledTaskPrincipal -UserId $runAsUser -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromHours(6)) -RestartCount 2 `
        -RestartInterval ([TimeSpan]::FromMinutes(5))

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'Resumes workstation setup after a reboot' -Force | Out-Null
    Write-Output "Registered resume task '$TaskName' for $runAsUser at logon" | timestamp
}

Function Unregister-ResumeTask {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $TaskName
    )
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Output "Removed resume task '$TaskName'" | timestamp
    }
}

Function Register-ResumeRunOnce {
    <#
        .SYNOPSIS
            Arms resume through the registry instead of the task scheduler.
        .DESCRIPTION
            For environments where creating scheduled tasks is restricted or audited. The trade-off
            is real: HKLM RunOnce entries execute with the logging-on user's filtered (non-elevated)
            token, so the entry has to relaunch through Start-Process -Verb RunAs to regain admin,
            which costs exactly one UAC consent. RunOnce deletes its own value once it fires, so
            there is nothing left behind to clean up.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $ResumeCommand,
        [Parameter()] [string] $WorkingDirectory = $PSScriptRoot
    )
    $runOnceKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path -LiteralPath $runOnceKey)) {
        New-Item -Path $runOnceKey -Force | Out-Null
    }
    # -EncodedCommand sidesteps the multiple layers of quoting between the registry value, the
    # outer shell and the elevated child process.
    $inner = "Set-Location '$($WorkingDirectory.Replace("'", "''"))'; $ResumeCommand"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner))
    $elevateArgs = "'-ExecutionPolicy','Bypass','-NoProfile','-EncodedCommand','$encoded'"
    $value = "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -Command " +
             "`"Start-Process powershell.exe -Verb RunAs -ArgumentList $elevateArgs`""
    Set-ItemProperty -Path $runOnceKey -Name $Name -Value $value -Force
    Write-Output "Armed RunOnce resume entry '$Name' (expect one UAC prompt after logon)" | timestamp
}

Function Unregister-ResumeRunOnce {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $Name
    )
    $runOnceKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    if (Get-ItemProperty -Path $runOnceKey -Name $Name -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $runOnceKey -Name $Name -Force -ErrorAction SilentlyContinue
        Write-Output "Removed RunOnce resume entry '$Name'" | timestamp
    }
}

Function Clear-ResumeHooks {
    <#
        .SYNOPSIS
            Removes every resume mechanism, whichever one was armed.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $Name
    )
    Unregister-ResumeTask -TaskName $Name
    Unregister-ResumeRunOnce -Name $Name
}

Function Request-Reboot {
    <#
        .SYNOPSIS
            Flushes state, arms the chosen resume mechanism and restarts.
        .PARAMETER ResumeMethod
            ScheduledTask - elevated and fully unattended; the only option that needs no human input.
            RunOnce       - no scheduled task; costs one UAC consent after logon.
            None          - arms nothing. Re-run the same command afterwards; completed phases are
                            skipped, so it resumes exactly where it stopped.
        .DESCRIPTION
            With -NoReboot it records what is owed and returns without restarting, so image
            pipelines can sequence their own restart.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string] $Reason,
        [Parameter(Mandatory)] [string] $TaskName,
        [Parameter(Mandatory)] [string] $ResumeCommand,
        [Parameter()] [ValidateSet('ScheduledTask', 'RunOnce', 'None')] [string] $ResumeMethod = 'ScheduledTask',
        [Parameter()] [string] $WorkingDirectory = $PSScriptRoot,
        [Parameter()] [switch] $NoReboot
    )
    $State.rebootCount = [int]$State.rebootCount + 1
    $State.resumeCommand = $ResumeCommand
    $State.resumeMethod = $ResumeMethod
    Save-SetupState -State $State

    switch ($ResumeMethod) {
        'ScheduledTask' {
            try {
                Register-ResumeTask -TaskName $TaskName -ResumeCommand $ResumeCommand -WorkingDirectory $WorkingDirectory
            }
            catch {
                # Task creation can be blocked by policy. Degrade rather than lose the resume entirely.
                Write-Warning "Could not register the resume task ($($_.Exception.Message)). Falling back to RunOnce."
                Register-ResumeRunOnce -Name $TaskName -ResumeCommand $ResumeCommand -WorkingDirectory $WorkingDirectory
            }
        }
        'RunOnce' {
            Register-ResumeRunOnce -Name $TaskName -ResumeCommand $ResumeCommand -WorkingDirectory $WorkingDirectory
        }
        'None' {
            Write-Output "No resume mechanism armed (-resumeMethod None)." | timestamp
        }
    }

    Write-Output "" | timestamp
    Write-Output "REBOOT REQUIRED: $Reason" | timestamp
    Write-Output "  Completed phases so far: $((@($State.completedPhases) -join ', '))" | timestamp
    Write-Output "  Reboot number: $($State.rebootCount)" | timestamp
    Write-Output "  Resume method: $ResumeMethod" | timestamp
    if ($ResumeMethod -eq 'None') {
        Write-Output "  To finish, re-run after the reboot:" | timestamp
        Write-Output "    $ResumeCommand" | timestamp
    }

    if ($NoReboot) {
        Write-Warning "-noReboot was supplied, so the machine will not be restarted."
        return
    }

    Write-Output "Restarting now." | timestamp
    try { $null = Stop-Transcript } catch { }
    Restart-Computer -Force
    # Restart-Computer is asynchronous; stop doing work while Windows tears the session down.
    Start-Sleep -Seconds 120
    exit 0
}

Function Invoke-RebootGate {
    <#
        .SYNOPSIS
            The single reboot gate. Returns immediately when no phase asked for a restart;
            otherwise arms the resume mechanism and restarts (or, with -NoReboot, runs -BeforeExit
            and exits 3010 so an image pipeline can sequence the restart itself).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string] $TaskName,
        [Parameter(Mandatory)] [string] $ResumeCommand,
        [Parameter()] [ValidateSet('ScheduledTask', 'RunOnce', 'None')] [string] $ResumeMethod = 'ScheduledTask',
        [Parameter()] [string] $WorkingDirectory = $PSScriptRoot,
        [Parameter()] [switch] $NoReboot,
        [Parameter()] [scriptblock] $BeforeExit
    )
    if (-not $script:rebootPending) {
        return
    }
    Write-Output "" | timestamp
    Write-Output "All phases that do not need a restart are complete." | timestamp
    Request-Reboot -State $State -Reason $script:rebootReason -TaskName $TaskName -ResumeCommand $ResumeCommand `
        -ResumeMethod $ResumeMethod -WorkingDirectory $WorkingDirectory -NoReboot:$NoReboot
    # Only reached with -NoReboot; Request-Reboot restarts the machine otherwise.
    if ($BeforeExit) { & $BeforeExit }
    exit 3010
}

#endregion

#region Unattended WSL provisioning

Function Test-WslInstallSupportsFlag {
    <#
        .SYNOPSIS
            Feature-detects a `wsl --install` flag, because the available flags depend on whether
            the inbox stub or the Microsoft Store build of WSL is servicing the command.
        .NOTES
            Reads `wsl --help`, not `wsl --install --help`: the latter is rejected as an invalid
            argument by Store WSL 2.7 (seen on the test VM), which made this always return false.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $Flag
    )
    try {
        $previousEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
        $helpText = (& wsl.exe --help 2>&1) -join "`n"
        [Console]::OutputEncoding = $previousEncoding
        return ($helpText -match [regex]::Escape($Flag))
    }
    catch {
        return $false
    }
}

Function Get-WslDistroState {
    <#
        .SYNOPSIS
            Returns the registered-distro list as plain text, or an empty string when WSL is absent.
            wsl.exe emits UTF-16LE, which shows up as text interleaved with NULs unless the console
            encoding is switched first.
    #>
    try {
        $previousEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
        $output = (& wsl.exe --list --quiet 2>&1) -join "`n"
        [Console]::OutputEncoding = $previousEncoding
        if ($LASTEXITCODE -ne 0) { return "" }
        return $output
    }
    catch {
        return ""
    }
}

Function Test-WslDistroRegistered {
    [CmdletBinding()]
    param (
        [Parameter()] [string] $DistroName = 'Ubuntu'
    )
    $distros = Get-WslDistroState
    return ($distros -match [regex]::Escape($DistroName))
}

Function Test-WindowsClientSku {
    <#
        .SYNOPSIS
            True on Windows 10/11 (workstation), false on Windows Server. Decides whether Docker
            needs Hyper-V isolation: client SKUs cannot run process-isolated Windows containers.
    #>
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    return ($null -ne $os -and [int]$os.ProductType -eq 1)
}

Function Enable-WindowsFeatureSet {
    <#
        .SYNOPSIS
            Enables a set of Windows optional features without restarting.
        .DESCRIPTION
            Uses the DISM cmdlets, which work on both client and Server SKUs. A feature that this
            edition does not offer is warned about and skipped rather than failing the phase.
        .OUTPUTS
            $true when at least one feature needs a reboot before it can be used.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string[]] $FeatureNames
    )
    $rebootRequired = $false
    foreach ($featureName in $FeatureNames) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction SilentlyContinue
        if ($null -eq $feature) {
            Write-Warning "Optional feature $featureName is not available on this edition of Windows."
            continue
        }
        if ($feature.State -eq 'Enabled') {
            Write-SetupLog "  Feature $featureName is already enabled"
            continue
        }
        Write-SetupLog "  Enabling feature $featureName..."
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $featureName -All -NoRestart -WarningAction SilentlyContinue
        if ($result.RestartNeeded) {
            $rebootRequired = $true
        }
    }
    return $rebootRequired
}

Function Enable-WslFeature {
    <#
        .SYNOPSIS
            Enables the two optional features WSL2 needs, without restarting.
        .OUTPUTS
            $true when a reboot is required before WSL can be used.
    #>
    return (Enable-WindowsFeatureSet -FeatureNames @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform'))
}

Function Enable-ContainerFeature {
    <#
        .SYNOPSIS
            Enables what the Windows Docker daemon needs: the Containers feature, plus Hyper-V on
            client SKUs, which can only run Windows containers with Hyper-V isolation.
        .OUTPUTS
            $true when a reboot is required before dockerd can start.
    #>
    $features = @('Containers')
    if (Test-WindowsClientSku) {
        $features += 'Microsoft-Hyper-V'
    }
    return (Enable-WindowsFeatureSet -FeatureNames $features)
}

Function Install-WslDistribution {
    <#
        .SYNOPSIS
            Registers a WSL distro without triggering its interactive first-run setup.
        .DESCRIPTION
            A plain `wsl --install -d Ubuntu` launches the distro, whose OOBE blocks on a UNIX
            username and password prompt - fatal for an unattended build. `--no-launch` avoids that
            on Store WSL; on older builds the per-distro launcher's `install --root` is the
            equivalent non-interactive entry point.
    #>
    [CmdletBinding()]
    param (
        [Parameter()] [string] $DistroName = 'Ubuntu'
    )
    if (Test-WslDistroRegistered -DistroName $DistroName) {
        Write-SetupLog "  Distro $DistroName is already registered"
        return $true
    }

    if (Test-WslInstallSupportsFlag -Flag '--no-launch') {
        Write-SetupLog "  Installing $DistroName with --no-launch (no first-run prompt)..."
        & wsl.exe --install --distribution $DistroName --no-launch
        $installExit = $LASTEXITCODE
        # Trust the registration list over the exit code; wsl.exe has returned non-zero on success.
        if (Test-WslDistroRegistered -DistroName $DistroName) {
            return $true
        }
        Write-Warning "wsl --install --no-launch exited with $installExit and $DistroName is not registered; trying the distro launcher instead."
    }
    else {
        Write-SetupLog "  This build of wsl.exe has no --no-launch flag; using the distro launcher."
    }

    # Fallback for older WSL: the appx launcher installs non-interactively with a root-only account.
    foreach ($launcher in @('ubuntu.exe', 'ubuntu2404.exe', 'ubuntu2204.exe')) {
        $launcherCommand = Get-Command -Name $launcher -ErrorAction SilentlyContinue
        if ($launcherCommand) {
            Write-SetupLog "  Registering $DistroName via $launcher install --root..."
            & $launcherCommand.Source install --root
            if (Test-WslDistroRegistered -DistroName $DistroName) {
                return $true
            }
        }
    }

    Write-Warning "Could not register $DistroName without user interaction. Other setup phases have still completed."
    return $false
}

Function Initialize-WslUser {
    <#
        .SYNOPSIS
            Creates the default WSL user and enables systemd, entirely from the Windows side.
        .DESCRIPTION
            Runs as root via --user root so the distro's interactive OOBE never executes. The user
            gets passwordless sudo because the Docker CE and systemd scripts in this repo are full
            of unattended `sudo` calls that would otherwise block on a password prompt. systemd is
            switched on in /etc/wsl.conf since docker-ce/linux/install-docker-ce.sh drives systemctl.
    #>
    [CmdletBinding()]
    param (
        [Parameter()] [string] $DistroName = 'Ubuntu',
        [Parameter()] [string] $UserName = $env:USERNAME.ToLowerInvariant()
    )
    if (-not (Test-WslDistroRegistered -DistroName $DistroName)) {
        Write-Warning "Distro $DistroName is not registered; skipping user provisioning."
        return $false
    }

    # A Windows account name can contain characters that are illegal in a POSIX user name.
    $linuxUser = ($UserName -replace '[^a-z0-9_-]', '')
    if ([string]::IsNullOrWhiteSpace($linuxUser)) { $linuxUser = 'developer' }
    if ($linuxUser -match '^[0-9]') { $linuxUser = "u$linuxUser" }

    Write-SetupLog "  Provisioning WSL user '$linuxUser' in $DistroName..."

    # Keep this a single-quoted here-string: it is bash source and must reach the distro verbatim.
    $provisionScript = @'
set -e
LINUX_USER="__USER__"
if ! id -u "$LINUX_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$LINUX_USER"
fi
usermod -aG sudo "$LINUX_USER" 2>/dev/null || usermod -aG wheel "$LINUX_USER" 2>/dev/null || true
# No password: an unattended build has nowhere safe to put one, and sudo is NOPASSWD below.
passwd --delete "$LINUX_USER" >/dev/null 2>&1 || true
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$LINUX_USER" > /etc/sudoers.d/90-workstation-setup
chmod 0440 /etc/sudoers.d/90-workstation-setup
cat > /etc/wsl.conf <<WSLCONF
[boot]
systemd=true

[user]
default=$LINUX_USER

[interop]
enabled=true
appendWindowsPath=true
WSLCONF
echo "provisioned $LINUX_USER"
'@
    $provisionScript = $provisionScript.Replace('__USER__', $linuxUser) -replace "`r`n", "`n"

    $scriptPath = Join-Path $env:TEMP 'wsl-provision-user.sh'
    [System.IO.File]::WriteAllText($scriptPath, $provisionScript, (New-Object System.Text.UTF8Encoding($false)))
    $wslScriptPath = & wsl.exe --distribution $DistroName --user root -- wslpath -a "$scriptPath" 2>$null

    if ([string]::IsNullOrWhiteSpace($wslScriptPath)) {
        Write-Warning "Could not translate $scriptPath into a WSL path; skipping user provisioning."
        return $false
    }

    & wsl.exe --distribution $DistroName --user root -- bash "$($wslScriptPath.Trim())"
    $provisionExitCode = $LASTEXITCODE
    Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue

    if ($provisionExitCode -ne 0) {
        Write-Warning "WSL user provisioning exited with $provisionExitCode."
        return $false
    }

    # /etc/wsl.conf is read when the distro next starts, so drop the current instance.
    & wsl.exe --terminate $DistroName | Out-Null
    Write-SetupLog "  WSL user '$linuxUser' ready (passwordless sudo, systemd enabled)"
    return $true
}

#endregion
