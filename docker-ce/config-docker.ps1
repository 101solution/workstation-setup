Write-Output "configuring docker on Windows (host)" 
[Environment]::SetEnvironmentVariable("DOCKER_HOST", "tcp://127.0.0.1:2378", [System.EnvironmentVariableTarget]::User)
./windows/install-docker-ce.ps1

Write-Output "configuring docker on linux (wsl)" 
wsl -- ./linux/install-docker-ce.sh

Write-Output "setting up  environment variable" 
[Environment]::SetEnvironmentVariable("WSLENV", "BASH_ENV/u", [System.EnvironmentVariableTarget]::User)
[Environment]::SetEnvironmentVariable("BASH_ENV", "/etc/bash.bashrc", [System.EnvironmentVariableTarget]::User)
[Environment]::SetEnvironmentVariable("DOCKER_HOST", "tcp://127.0.0.1:2375", [System.EnvironmentVariableTarget]::User)

