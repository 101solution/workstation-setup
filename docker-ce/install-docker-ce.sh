#!/bin/bash

# Driven unattended by config-docker.ps1, so nothing here may wait for input. apt honours
# DEBIAN_FRONTEND; the `gpg --yes` below is the other half of that rule.
export DEBIAN_FRONTEND=noninteractive

sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
# --yes is load-bearing: without it, `gpg --dearmor -o` on an EXISTING file blocks on an
# interactive "File exists. Overwrite?" prompt whose stdin is the curl pipe, not a terminal.
# That hung this script indefinitely on every re-run (TODO G31) - twice on the test VM, for 20
# and 30 minutes - while fresh installs were unaffected because the file was absent. Measured in
# Ubuntu WSL with gpg 2.4.9: file absent rc=0; file present rc=124 (blocked, killed by timeout);
# file present with --yes rc=0, keyring still a valid OpenPGP key with Docker's fingerprint
# 9DC858229FC7DD38854AE2D88D81803C0EBFCD88.
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --yes --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io


# Automatically start on startup
sudo systemctl enable docker.service
sudo systemctl enable containerd.service

# Expose the daemon on TCP for the Windows-side docker CLI. Guarded so a re-run (the orchestrator
# retries this script if the daemon does not come up) does not append a second -H tcp:// flag.
if [ ! -f /etc/systemd/system/docker.service ]; then
    sudo cp /lib/systemd/system/docker.service /etc/systemd/system/
fi
if ! grep -q 'tcp://127.0.0.1:2375' /etc/systemd/system/docker.service; then
    sudo sed -i 's/\ -H\ fd:\/\//\ -H\ fd:\/\/\ -H\ tcp:\/\/127.0.0.1:2375/g' /etc/systemd/system/docker.service
fi
sudo systemctl daemon-reload
echo "current user is $USER"
sudo usermod -aG docker "$USER"

# Restart the daemon rather than the whole distro. `sudo shutdown -r now` used to be here, to load
# the patched unit file, but `systemctl daemon-reload` above already does that, and the shutdown
# turned out to hang indefinitely under systemd-in-WSL: on 2026-09-14 a re-run sat in
# `bash ./install-docker-ce.sh` for 20 minutes with unattended-upgrade-shutdown holding the
# shutdown path, wedging the whole unattended install. It worked on the first run and hung on the
# second, so it was non-deterministic as well as unnecessary. Proof it was unnecessary: during that
# hang, docker was already `active` and listening on 127.0.0.1:2375.
# The one thing the restart also did was make `usermod -aG docker` effective immediately; that does
# not matter here, because the Windows client reaches the daemon over TCP and any new WSL session
# picks up the group anyway.
echo "Restarting the docker service so the patched unit file takes effect..."
sudo systemctl restart docker
sudo systemctl is-active docker
