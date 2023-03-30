# How to run Docker on Windows and Linux without Docker Desktop

Script to enable systemd support on current Ubuntu WSL2 images from the Windows store. 


Instructions from [Running Windows and Linux containers without Docker Desktop](https://lippertmarkus.com/2021/09/04/containers-without-docker-desktop/) turned into the scripts. Thanks to [Markus Lippert](https://lippertmarkus.com/) on the article above

## On Windows
1. Run [Config Workstation script] (https://github.com/101solution/workstation-setup#automate-download-and-run-latest-release)
1. Run 
> powershell.exe -executionpolicy bypass -file c:/config/workstation/containers/docker-ce/windows/install-docker-ce.ps1
## On WSL2 Ubuntu
1. Goto workstation config folder
> cd /mnt/c/config/workstation
1. Run the following bash file to enable systemd
> bash containers/docker-ce/linux/systemd/ubuntu-wsl2-systemd-script.sh
1. Run the following bash file to config docker
> bash containers/docker-ce/linux/install-docker-ce.sh

## To Test if both docker CE set up properly, please run the following command on Windows Powershell
> docker run hello-world
> docker -c wsl run hello-world