# Workstation Configuration
This is PowerShell script to set up workstation with needed software
1. Open PowerShell window in Administrator mode
1. Goto the folder where the script copied to
1. update packages-cloudEngineer.json file to your need
1. run
    > powershell.exe -executionpolicy bypass -file .\config-workstation.ps1

## Automate Download and run latest release
To download the latets release and run the script using defaulr Role (cloudEngineer), you can run the following command to download the file from Github Repo

> Invoke-RestMethod -Uri "https://raw.githubusercontent.com/101solution/workstation-setup/main/get-latestPackages.ps1" -OutFile "$env:temp\get-latestPackages.ps1"

Then run the following command using **admin previllage** to download and run the workstation set up 

> powershell.exe -executionpolicy bypass -file $env:temp\get-latestPackages.ps1

## Default packages 

| Package | source | Note |
| ------- | ------ | -----|
| kubernetes-cli | chocolatey |
| terraform | chocolatey |
| DotNet SDK 7 | winget |
| PowerShell Core | winget |
| Azure CLI | winget |
| Ditto | winget | https://ditto-cp.sourceforge.io/ |
| Git | winget |
| GitHub cli | winget |
| minikube | winget | run Kubernetes cluster on local computer |
| Visual Studio Code | winget |
| Postman | winget  | |
| OhMyPosh | winget |
| AWS CLI | winget |
| Rancher Desktop | winget | Replacing Docker Desktop |
| Adobe Acrobat Reader | winget |
| Windows Terminal | winget |
| PowerToys | winget | |
| Bing Wallpaper | winget | |
| posh-git | Powershell Module |
| PSReadLine | Powershell Module |
| PSRule | Powershell Module |
| Az | Powershell Module |
| AWS PowerShell tools | Powershell Module | |
| Stax2AWS | custom script | optional |
| WSL2 | custom script ||

The script has also configured git using ohmyposh and posh-git, inspired by [My Ultimate PowerShell prompt with Oh My Posh and the Windows Terminal](https://www.hanselman.com/blog/my-ultimate-powershell-prompt-with-oh-my-posh-and-the-windows-terminal).
It also set up PSReadLine by following [You should be customizing your PowerShell Prompt with PSReadLine](https://www.hanselman.com/blog/you-should-be-customizing-your-powershell-prompt-with-psreadline)

## The scripts include windows terminal setting, the end result will be looking like below:
![Windows Terminal](win-term.png)