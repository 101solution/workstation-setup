#!/bin/bash

sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
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
echo "Restarting WSL so the docker group and the patched unit file take effect..."
sudo shutdown -r now
