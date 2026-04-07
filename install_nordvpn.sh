#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "[1/4] Adding NordVPN GPG key..."
if [ ! -f /usr/share/keyrings/nordvpn-keyring.gpg ]; then
    curl -s https://repo.nordvpn.com/gpg/nordvpn_public.asc | gpg --dearmor | sudo tee /usr/share/keyrings/nordvpn-keyring.gpg > /dev/null
    echo "      GPG key added."
else
    echo "      GPG key already present, skipping."
fi

echo "[2/4] Adding NordVPN repository..."
if [ ! -f /etc/apt/sources.list.d/nordvpn.list ]; then
    echo "deb [signed-by=/usr/share/keyrings/nordvpn-keyring.gpg] https://repo.nordvpn.com/deb/nordvpn/debian stable main" | sudo tee /etc/apt/sources.list.d/nordvpn.list
    echo "      Repository added."
else
    echo "      Repository already present, skipping."
fi

echo "[3/4] Installing NordVPN..."
if ! command -v nordvpn &>/dev/null; then
    sudo apt-get update -q
    sudo apt-get install -y nordvpn
    echo "      NordVPN installed."
else
    echo "      NordVPN already installed, skipping."
fi

echo "[4/4] Adding current user to nordvpn group..."
if ! groups "$USER" | grep -q nordvpn; then
    sudo usermod -aG nordvpn "$USER"
    echo "      User added to nordvpn group."
else
    echo "      User already in nordvpn group, skipping."
fi

echo ""
echo "NordVPN installed successfully!"
echo "To log in, generate an access token at nordvpn.com/account and run:"
echo "  nordvpn login --token YOUR_TOKEN_HERE"
echo ""
echo "Activating nordvpn group for current session..."
exec newgrp nordvpn
