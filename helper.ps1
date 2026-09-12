# ---------------------------------------------------------------------------------------------
# LOGGING: every log line in this repo goes through Write-SetupLog. It writes to the host, which
# (a) Start-Transcript captures under Windows PowerShell 5.1 - the Information stream is NOT, so
# Write-Information lines silently vanished from the transcripts - and (b) never lands in the
# success stream, so a function can log freely and still `return $false` without its log lines
# becoming part of the return value (`if (Fn)` on @('msg', $false) is TRUE; that once produced an
# infinite reboot loop). Do not use Write-Output for logging.
# ---------------------------------------------------------------------------------------------
Function Write-SetupLog {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string] $Message
    )
    Write-Host "$(Get-Date -Format o): $Message"
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
    $fontFileExists = Test-Path -LiteralPath "C:\Windows\Fonts\$fontName.ttf"
    if (-not($fontReg) -or -not($fontFileExists)) {
        Write-SetupLog "Installing Font $fontName..."
        Copy-Item "$fontFolder\$fontName.ttf" "C:\Windows\Fonts" -Force
        New-ItemProperty -Name "$fontName (TrueType)" -Path $fontRegPath -PropertyType string -Value "$fontName.ttf" -Force | Out-Null
    }
}

Function Update-SessionEnvironment {
    <#
        .SYNOPSIS
            Reloads the Machine and User environment into this process, so tools an installer just
            added (git, pwsh, oh-my-posh, POSH_THEMES_PATH) are visible without a new shell.
        .DESCRIPTION
            User values override Machine values, PATH is the union of both, and PSModulePath is left
            alone because the process value is the authoritative one.
    #>
    $psModulePath = $env:PSModulePath
    foreach ($scope in 'Machine', 'User') {
        $variables = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::$scope)
        foreach ($name in $variables.Keys) {
            if ($name -in 'Path', 'PSModulePath', 'USERNAME', 'PROCESSOR_ARCHITECTURE') { continue }
            Set-Item -Path "Env:$name" -Value $variables[$name]
        }
    }
    $paths = foreach ($scope in 'Machine', 'User') {
        [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::$scope) -split ';'
    }
    $env:Path = ($paths | Where-Object { $_ } | Select-Object -Unique) -join ';'
    $env:PSModulePath = $psModulePath
}

Function Install-WinGet {
    <#
        .SYNOPSIS
            Installs App Installer (winget) from GitHub, with its two framework dependencies.
        .DESCRIPTION
            Fallback only: the winget phase calls this when Get-WinGetPath finds no winget at all,
            e.g. an image without the Store package. Windows 11 ships it in-box, where the usual
            problem is a missing per-user alias, which Get-WinGetPath handles without downloading.
    #>
    Write-SetupLog "  Installing winget (Microsoft.DesktopAppInstaller) and its dependencies..."
    # The dependencies may already be present; a failure there is not fatal, the bundle install is.
    Add-AppxPackage -Path 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx' -ErrorAction SilentlyContinue
    Add-AppxPackage -Path 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx' -ErrorAction SilentlyContinue
    Add-AppxPackage -Path 'https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle' -ErrorAction Stop
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
        [Parameter(Mandatory)] [string] $PackageName,
        [Parameter(Mandatory)] [string] $PackageFamilyName,
        [Parameter(Mandatory)] [string] $ExeName,
        [Parameter()] [int] $TimeoutSeconds = 120
    )
    $aliasPath = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\$ExeName"
    if (Test-Path -LiteralPath $aliasPath) { return $aliasPath }

    # Nothing to register (and no point waiting for an alias) if the package is not on the machine.
    if (-not (Get-AppxPackage -AllUsers -Name $PackageName -ErrorAction SilentlyContinue)) {
        Write-SetupLog "  $PackageName is not installed for any user."
        return $null
    }

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

    $alias = Register-AppxForCurrentUser -PackageName $PackageName -PackageFamilyName $PackageFamilyName -ExeName $ExeName
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

Function Install-WinGetPackage {
    <#
        .SYNOPSIS
            Installs a package, or upgrades it if a newer version is available, in one winget call.
        .DESCRIPTION
            `winget install` already upgrades an installed package when the source has a newer
            version and returns a distinct code when it is current, so there is no need to run
            `winget list`, parse its column layout and then decide between install and upgrade
            (the old parser sliced columns by character offset and broke on any header change).
            Outcome is decided from winget's documented return codes, not from its text output.
    #>
    param (
        [Parameter(Mandatory)] [string] $packageId,
        [string] $overrideParameters = "",
        [string] $source = "winget"
    )
    $winget = Get-WinGetPath
    if (-not $winget) {
        throw "winget is not available in this session; cannot install $packageId."
    }

    Write-SetupLog "Installing or upgrading $packageId..."
    $arguments = @('install', '-e', '--id', $packageId, '-h', '--accept-package-agreements', '--accept-source-agreements', '--source', $source)
    if ($overrideParameters -ne "") {
        $arguments += @('--override', $overrideParameters)
    }
    $output = & $winget @arguments 2>&1
    $code = '0x{0:X8}' -f ($LASTEXITCODE -band 0xFFFFFFFF)

    # https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md
    switch ($code) {
        '0x00000000' { Write-SetupLog "  $packageId installed or upgraded." }
        '0x8A15002B' { Write-SetupLog "  $packageId is already up to date." }                 # PACKAGE_ALREADY_INSTALLED / no upgrade available
        '0x8A150061' { Write-SetupLog "  $packageId is already up to date (no applicable update)." } # UPDATE_NOT_APPLICABLE
        '0x8A15010D' { Write-SetupLog "  $packageId is already installed." }                  # INSTALL_ALREADY_INSTALLED
        '0x8A150014' { Write-Warning "  $packageId was not found in source '$source'; check the id in the manifest." } # NO_APPLICATIONS_FOUND
        '0x8A15008E' { Write-SetupLog "  $packageId is installed via a different technology (e.g. Store vs MSI); leaving the existing install alone." } # INSTALL_TECHNOLOGY_MISMATCH
        { $_ -in '0x8A150109', '0x8A15010A' } {                                                # INSTALL_REBOOT_REQUIRED_TO_FINISH / _FOR_INSTALL
            Write-SetupLog "  $packageId installed; its installer requires a restart, folded into the single reboot."
            Request-PhaseReboot -Reason "the $packageId installer requires a restart"
        }
        default {
            Write-Warning "  winget exited with $code for $packageId. Last output:"
            @($output | Where-Object { "$_".Trim() } | Select-Object -Last 5) | ForEach-Object { Write-SetupLog "    $_" }
        }
    }
}

Function Install-PSModule {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $PsModuleName
    )
    Write-SetupLog "Checking PS Module $PsModuleName... "
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
            Write-SetupLog "  PS Module $PsModuleName $($availableModule.Version) is already present."
            return
        }
        Write-SetupLog "  Installing PS Module $PsModuleName..."
        Install-Module -Name $PsModuleName -Repository PSGallery -Force -AllowClobber -SkipPublisherCheck
    }
    else {
        $latestModule = Find-Module -Name $PsModuleName -Repository PSGallery
        if ($installedModule.Version.CompareTo($latestModule.Version) -lt 0) {
            Write-SetupLog "  Updating PS Module $PsModuleName from $($installedModule.Version.ToString()) to version $($latestModule.Version.ToString()) ..."
            Update-Module -Name $PsModuleName -Force
        }
        else {
            Write-SetupLog "  Latest PS Module $PsModuleName has been installed."
        }
    }
}
Function Format-Json([Parameter(Mandatory, ValueFromPipeline)][String] $json) {
    $indent = 0;
    ($json -Split "`n" | ForEach-Object {
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
# Setup runs in named phases. Completed phases are recorded in a state file outside the repo so a
# re-download by get-latestPackages.ps1 cannot lose progress. When a step needs a reboot, the state
# is flushed, a resume scheduled task is registered, and the machine restarts; on the next logon the
# task re-invokes this script with the original arguments and every completed phase is skipped.
# ---------------------------------------------------------------------------------------------

$script:SetupStateRoot = Join-Path $env:ProgramData 'workstation-setup'

# Each entry script keeps its own state file, so progress recorded by the workstation script can
# never make the Docker CE orchestrator skip work (or vice versa) when both use a phase name such
# as 'preflight'. Because helper.ps1 is dot-sourced, the caller can override this after sourcing.
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
        Write-SetupLog "Cleared resume state $statePath"
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
            A flag rather than a return value, so a phase body never has to return anything and
            whatever its commands emit can never be mistaken for a result.
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
        Write-SetupLog "--- phase '$Phase': already complete, skipping"
        return
    }
    Write-SetupLog ""
    Write-SetupLog "--- phase '$Phase': starting"
    $rebootOwedBefore = $script:rebootPending
    try {
        & $Body
        if ($script:rebootPending -and -not $rebootOwedBefore) {
            Write-SetupLog "--- phase '$Phase': deferred, needs a restart first"
            return
        }
        Complete-Phase -State $script:state -Phase $Phase
        Write-SetupLog "--- phase '$Phase': complete"
    }
    catch {
        Write-Warning "--- phase '$Phase' failed: $($_.Exception.Message). It will be retried on the next run."
        Write-SetupLog $_.ScriptStackTrace
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
    Write-SetupLog ""
    if ($failed.Count -gt 0) {
        Write-Warning "=== $Title finished with $($failed.Count) FAILED phase(s): $($failed -join ', ') ==="
        Write-SetupLog "  Fix the cause and re-run the same command; completed phases are skipped."
        $script:SetupExitCode = 1
    }
    else {
        Complete-Phase -State $State -Phase 'done'
        Write-SetupLog "=== $Title finished ==="
        $script:SetupExitCode = 0
    }
    Write-SetupLog "  Runs: $($State.runCount)   Reboots: $($State.rebootCount)"
    Write-SetupLog "  Phases completed: $((@($State.completedPhases) -join ', '))"
    Write-SetupLog "  State file: $(Get-SetupStatePath)"
    Write-SetupLog "  Re-run with -force to redo every phase from scratch."
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
    Write-SetupLog "Registered resume task '$TaskName' for $runAsUser at logon"
}

Function Unregister-ResumeTask {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $TaskName
    )
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-SetupLog "Removed resume task '$TaskName'"
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
    Write-SetupLog "Armed RunOnce resume entry '$Name' (expect one UAC prompt after logon)"
}

Function Unregister-ResumeRunOnce {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $Name
    )
    $runOnceKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    if (Get-ItemProperty -Path $runOnceKey -Name $Name -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $runOnceKey -Name $Name -Force -ErrorAction SilentlyContinue
        Write-SetupLog "Removed RunOnce resume entry '$Name'"
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
            Write-SetupLog "No resume mechanism armed (-resumeMethod None)."
        }
    }

    Write-SetupLog ""
    Write-SetupLog "REBOOT REQUIRED: $Reason"
    Write-SetupLog "  Completed phases so far: $((@($State.completedPhases) -join ', '))"
    Write-SetupLog "  Reboot number: $($State.rebootCount)"
    Write-SetupLog "  Resume method: $ResumeMethod"
    if ($ResumeMethod -eq 'None') {
        Write-SetupLog "  To finish, re-run after the reboot:"
        Write-SetupLog "    $ResumeCommand"
    }

    if ($NoReboot) {
        Write-Warning "-noReboot was supplied, so the machine will not be restarted."
        return
    }

    Write-SetupLog "Restarting now."
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
    Write-SetupLog ""
    Write-SetupLog "All phases that do not need a restart are complete."
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
