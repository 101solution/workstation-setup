# How to run Docker on Windows and Linux without Docker Desktop


## On Windows 
*The server may restart once, but the task will continue after reboot*
1. Run [Config Workstation script] (https://github.com/101solution/workstation-setup#automate-download-and-run-latest-release)
1. Run 
> powershell.exe -executionpolicy bypass -file c:/config/workstation/docker-ce/install-docker-ce.ps1


## To Test if both docker CE set up properly, please run the following command on Windows Powershell
> docker run -it hello-world

> docker -c win run -it hello-world