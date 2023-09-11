# install and config systemd
wsl -e ./linux/systemd/ubuntu-wsl2-systemd-script.sh

#install and config docker
wsl -e ./linux/install-docker-ce.sh

[Environment]::SetEnvironmentVariable("WSLENV", "BASH_ENV/u", [System.EnvironmentVariableTarget]::User)
[Environment]::SetEnvironmentVariable("BASH_ENV", "/etc/bash.bashrc", [System.EnvironmentVariableTarget]::User)
[Environment]::SetEnvironmentVariable("DOCKER_HOST", "tcp://127.0.0.1:2375", [System.EnvironmentVariableTarget]::User)