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
        $chocoCmd = Get-Command -Name choco.exe -ErrorAction SilentlyContinue
        if ($chocoCmd) {
            $chocoVersion = choco -v
            Write-Output "Chocolatery is installed, version is $chocoVersion"  | timestamp
        }
    }
}

function Install-Package {
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
    if ($wingetOutput.Count -ge 4) {
        $header = $wingetOutput[2].Substring($wingetOutput[2].IndexOf("Id")) -replace '\s+', ","
        $data = $wingetOutput[4].Substring($wingetOutput[4].IndexOf($packageId)) -replace '\s+', ","
        return  @($header, $data) | ConvertFrom-Csv

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
    if (($packageName -ne $null) -and ($packageName -ne '')) {
        Write-Output "Checking package $packageName... using WinGet" | timestamp

        $outputRaw = winget list -e --name $packageName
        $output = Convert-WingetOutput $outputRaw
        if ($null -eq $output) {
            Write-Output "    Installing package $packageName..." | timestamp
            winget install -e --name $packageName -h --accept-package-agreements
        }
        else {
            if (($null -ne $output.Available) -and ($output.Available -ne "")) {
                Write-Output "    Upgarding package $packageName..." | timestamp
                winget upgrade -e --name $packageName -h --accept-package-agreements
            }
            else {
                Write-Output "    Latest version of $packageName... already installed" | timestamp
            }
        }
    }
    else {
        Write-Output "Checking package $packageId... using WinGet" | timestamp

        $outputRaw = winget list -e --id $packageId
        $output = Convert-WingetOutput $outputRaw
        if ($null -eq $output) {
            Write-Output "    Installing package $packageId..." | timestamp
            winget install -e --id $packageId -h --accept-package-agreements
        }
        else {
            if (($null -ne $output.Available) -and ($output.Available -ne "")) {
                Write-Output "    Upgarding package $packageId..." | timestamp
                winget upgrade -e --id $packageId -h --accept-package-agreements
            }
            else {
                Write-Output "    Latest version of $packageId... already installed" | timestamp
            }
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
    Copy-Item "$fontFolder\$fontName.ttf" "C:\Windows\Fonts" -Force
    New-ItemProperty -Name "$fontName (TrueType)" -Path "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Fonts" -PropertyType string -Value "$fontName.ttf" -Force
}