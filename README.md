# Workstation Configuration
This is PowerShell script to set up workstation with needed software
1. Open PowerShell window in Administrator mode
1. Goto the folder where the script copied to
1. update packages-cloudEngineer.json file to your need
1. run
    > powershell.exe -executionpolicy bypass -file .\config-workstation.ps1

## Automate Download and run latest release
To download the latets release and run the script using defaulr Role (cloudEngineer), you can save the following file to local as and run in pwoershell/cmd
[https://raw.githubusercontent.com/101solution/workstation-setup/main/get-latestPackages.ps1] PowerShell-get-latestPackages.ps1 Script or run the following command to download the file

> $ps_url = "https://raw.githubusercontent.com/101solution/workstation-setup/main/get-latestPackages.ps1"

> Invoke-RestMethod -Uri $ps_url -OutFile "$env:temp\get-latestPackages.ps1"

Then run 

> powershell.exe -executionpolicy bypass -file $env:temp\get-latestPackages.ps1

