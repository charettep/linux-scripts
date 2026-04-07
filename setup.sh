#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "[1/7] apt update..."
sudo apt update
wait

echo "[2/7] apt upgrade..."
sudo apt upgrade -y
wait

echo "[3/7] apt full-upgrade..."
sudo apt full-upgrade -y
wait

echo "[4/7] apt install packages..."
sudo apt install -y python3-full python-is-python3 build-essential curl wget git
wait

echo "[5/7] git config user.name..."
git config --global user.name "charettep"
wait

echo "[6/7] git config user.email..."
git config --global user.email "git@charettep.com"
wait

echo "[7/8] Installing nvm..."
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
wait

echo "[8/9] Loading nvm into current session..."
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
wait

echo "[9/10] Installing latest Node.js via nvm..."
nvm install node
wait

echo "[10/13] Creating keyrings directory..."
sudo mkdir -p --mode=0755 /usr/share/keyrings
wait

echo "[11/13] Adding Cloudflare GPG key..."
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
wait

echo "[12/13] Adding Cloudflare apt repository..."
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
wait

echo "[13/13] Installing cloudflared..."
sudo apt-get update
wait
sudo apt-get install -y cloudflared
wait

echo "[13/13] Done."
