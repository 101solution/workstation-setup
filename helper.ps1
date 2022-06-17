filter timestamp { "$(Get-Date -Format o): $_" }
function Install-Choco {
    $chocoCmd = Get-Command -Name choco.exe -ErrorAction SilentlyContinue 
    if ($chocoCmd) {
        $chocoVersion = choco -v
        Write-Output "Chocolatery has already installed, version is $chocoVersion" | timestamp
    }
    else {
        Write-Output "Installing Chocolatery"  | timestamp
        Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        Update-SessionEnvironment
        $chocoCmd = Get-Command -Name choco.exe -ErrorAction SilentlyContinue
        if ($chocoCmd) {
            $chocoVersion = choco -v
            Write-Output "Chocolatery is installed, version is $chocoVersion"  | timestamp
        }
    }
}

function Install-ChocoPackage {
    param (
        [string] $packageName,
        [string] $additionalParameters,
        [switch] $force
    )
    Write-Output "Installing package $packageName..." | timestamp
    if ($force) {
        Write-Output "    Installing package $packageName with -force"  | timestamp
        choco install $packageName -y --force --force-dependencies $additionalParameters
    }
    else {
        $nameCompare = [System.StringComparison]::OrdinalIgnoreCase
        $packageInstalled = choco list -lo | Where-object { $_.StartsWith("$packageName ", $nameCompare) }
        if ($packageInstalled) {
            $packageOutdated = choco outdated | Where-object { $_.StartsWith("$packageName|", $nameCompare) } 
            if ($packageOutdated) {
                Write-Output "    Package $packageName is already install but outdated, upgrading..."  | timestamp
                choco upgrade $packageName -y $additionalParameters
            }
            else {
                Write-Output "    Package $packageName is already install with latest version"  | timestamp
            }
        }
        else {
            Write-Output "    Installing package $packageName..."  | timestamp
            choco install $packageName -y $additionalParameters
        }
    }
}

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
Function Test-VMRestart {
    $pendingReboot = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing' | Select-Object 'RebootPending' -ExpandProperty 'RebootPending' -ErrorAction SilentlyContinue
    if ($null -ne $pendingReboot) {
        return $true
    }
    
    $requireReboot = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update' | Select-Object 'RebootRequired' -ExpandProperty 'RebootRequired' -ErrorAction SilentlyContinue
    if ($null -ne $requireReboot) {
        return $true
    }

    $needReboot = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'  | Select-Object 'PendingFileRenameOperations' -ExpandProperty 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
    if ($null -ne $needReboot) {
        return $true
    }
    
    return $false
}
Function Install-Fonts {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $fontName = "Caskaydia Cove Nerd Font Complete Mono Windows Compatible",
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
        New-ItemProperty -Name "$fontName (TrueType)" -Path $fontRegPath -PropertyType string -Value "$fontName.ttf" -Force
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
    ## Called from chocolateysetup.psm1 - wrap any Write-Host in try/catch

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

Function Install-WinGetOffline {
    $wingetCmd = Get-Command -Name winget.exe -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        
        if (-not (Get-AppPackage Microsoft.UI.Xaml.2.7 | Where-Object { $_.version -eq "7.2203.17001.0" -and ($_.Architecture -eq "X64") })) {
            Write-Output "  Installing Microsoft.UI.Xaml.2.7 using offline mode..."
            Add-AppxPackage $PSScriptRoot\winget\Microsoft.UI.Xaml.2.7_7.2203.17001.0_x64__8wekyb3d8bbwe.Appx
        }
        if (-not (Get-AppPackage Microsoft.VCLibs.140.00.UWPDesktop | Where-Object { $_.version -eq "14.0.30704.0" -and ($_.Architecture -eq "X64") })) {
            Write-Output "  Installing Microsoft.VCLibs.140.00.UWPDesktop using offline mode..."
            Add-AppxPackage $PSScriptRoot\winget\Microsoft.VCLibs.140.00.UWPDesktop_14.0.30704.0_x64__8wekyb3d8bbwe.Appx
        }
        Write-Output "Installing WinGet (Microsoft.DesktopAppInstaller) using offline mode..."
        Add-AppxPackage $PSScriptRoot\winget\Microsoft.DesktopAppInstaller_2022.610.123.0_neutral___8wekyb3d8bbwe.Msixbundle
        Update-SessionEnvironment
    }
    
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
        [switch]$Passthru
    )
    $wingetCmd = Get-Command -Name winget.exe -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        Write-Verbose "[$((Get-Date).TimeofDay)] Starting Install winget"

        if ($Iscoreclr -AND ($PSVersionTable.PSVersion -le 7.2)) {
            Write-Warning "If running this command in PowerShell 7, you need at least version 7.2."
            return
        }
        if (-not( Get-Package Microsoft.UI.Xaml -RequiredVersion 2.7.0 -ErrorAction SilentlyContinue)) {
            Install-Package Microsoft.UI.Xaml -RequiredVersion 2.7.0 -Force
        }
        #test for requirement
        $requirement = Get-AppPackage Microsoft.VCLibs.140.00.UWPDesktop

        if (-Not $requirement) {
            Write-Verbose "Installing Desktop App requirement"
            Try {
                $vclib = Join-Path -Path $env:temp -ChildPath "Microsoft.VCLibs.x64.14.00.Desktop.appx"
                Invoke-WebRequest -Uri "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx" -UseBasicParsing -OutFile $vclib -ErrorAction stop
                if (Test-Path $vclib) {
                    Add-AppxPackage -Path $vclib -ErrorAction Stop
                }
                else {
                    Throw "Failed to find $vclib"
                }
            }
            Catch {
                Throw $_
            }
        }

        $uri = "https://api.github.com/repos/microsoft/winget-cli/releases"

        Try {
            Write-Verbose "[$((Get-Date).TimeofDay)] Getting information from $uri"
            $get = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction stop
            if ($preview) {
                Write-Verbose "[$((Get-Date).TimeofDay)] Getting latest preview release"
                $data = ($get | where-object { $_.Prerelease } | Select-Object -first 1).Assets | Where-Object name -Match 'msixbundle'
            }
            else {
                Write-Verbose "[$((Get-Date).TimeofDay)] Getting latest stable release"
                $data = ($get | where-object { -Not $_.Prerelease } | Select-Object -first 1).Assets | Where-Object name -Match 'msixbundle'

            }
            #$data = $get | Select-Object -first 1

            $appx = $data.browser_download_url
            #$data.assets[0].browser_download_url
            Write-Verbose "[$((Get-Date).TimeofDay)] $appx"
            If ($pscmdlet.ShouldProcess($appx, "Downloading asset")) {
                $file = Join-Path -Path $env:temp -ChildPath $data.name

                Write-Verbose "[$((Get-Date).TimeofDay)] Saving to $file"
                Invoke-WebRequest -Uri $appx -UseBasicParsing -DisableKeepAlive -OutFile $file

                Write-Verbose "[$((Get-Date).TimeofDay)] Adding Appx Package"
                Add-AppxPackage -Path $file -ErrorAction Stop

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
    if ($wingetOutput -and ($wingetOutput.Count -ge 4)) {
        $idIndex = $wingetOutput[2].IndexOf("Id")
        $appIndex = $wingetOutput[4].IndexOf($packageId)
        if ($idIndex -ge 0 -and $appIndex -ge 0) {
            $header = $wingetOutput[2].Substring($idIndex) -replace '\s+', ","
            $data = $wingetOutput[4].Substring($appIndex) -replace '\s+', ","
            return  @($header, $data) | ConvertFrom-Csv
        }

    }
    else {
        return $null
    }
}
function Install-WingetPackage {
    param (
        [string] $packageName,
        [string] $packageId
    )
    if (($null -ne $packageName) -and ($packageName -ne '')) {
        Write-Output "Checking package $packageName... using WinGet" | timestamp

        $outputRaw = winget list -e --name $packageName --accept-source-agreements
        $output = Convert-WingetOutput $outputRaw
        if ($null -eq $output) {
            Write-Output "    Installing package $packageName..." | timestamp
            winget install -e --name $packageName -h --accept-package-agreements --accept-source-agreements
        }
        else {
            if (($null -ne $output.Available) -and ($output.Available -ne "")) {
                Write-Output "    Upgarding package $packageName..." | timestamp
                winget upgrade -e --name $packageName -h --accept-package-agreements --accept-source-agreements
            }
            else {
                Write-Output "    Latest version of $packageName... already installed" | timestamp
            }
        }
    }
    else {
        Write-Output "Checking package $packageId... using WinGet" | timestamp

        $outputRaw = winget list -e --id $packageId --accept-source-agreements
        $output = Convert-WingetOutput $outputRaw
        if ($null -eq $output) {
            Write-Output "    Installing package $packageId..." | timestamp
            winget install -e --id $packageId -h --accept-package-agreements --accept-source-agreements
        }
        else {
            if (($null -ne $output.Available) -and ($output.Available -ne "")) {
                Write-Output "    Upgarding package $packageId..." | timestamp
                winget upgrade -e --id $packageId -h --accept-package-agreements --accept-source-agreements
            }
            else {
                Write-Output "    Latest version of $packageId... already installed" | timestamp
            }
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
Function Install-Kubectl {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $InstallPath
    )
    if (-not(Test-Path $InstallPath)) {
        New-Item -Path $InstallPath -ItemType Directory -Force
    }
    $kubrctlCmd = Get-Command -Name kubectl.exe -ErrorAction SilentlyContinue
    if (-not(Test-Path $InstallPath)) {
        New-Item -Path $InstallPath -ItemType Directory -Force
    }
    $latestVersion = Invoke-WebRequest -Uri "https://dl.k8s.io/release/stable.txt"
    $installedVersion = "0.0.0.0"
    if ($kubrctlCmd) {
        $kubeVersion = kubectl version --output=json | ConvertFrom-Json
        if ($kubeVersion) {
            $installedVersion = $kubeVersion.ClientVersion.gitCommit
        }
        if ($installedVersion -eq $latestVersion) {
            Write-Output "Removing old version of Kubectl ..."
            Remove-Item -LiteralPath $InstallPath\kubectl.exe -Force
        }
    }
    if ($installedVersion -eq $latestVersion) {
        Write-Output "Downloading Kubectl $latestVersion ..."
        Invoke-WebRequest -Uri "https://dl.k8s.io/release/$latestVersion/bin/windows/amd64/kubectl.exe" -OutFile $InstallPath\kubectl.exe

        Update-EnvironmentPath -NewPath $InstallPath
        Update-SessionEnvironment
    }

}