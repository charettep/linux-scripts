#!/bin/bash
set -euo pipefail

# SSH Server Setup Script
# Idempotent — safe to run multiple times on any Ubuntu/Debian server.
# Run as a user with sudo privileges.

USERNAME="${SUDO_USER:-${USER:-$(logname 2>/dev/null || whoami)}}"
if [ "$USERNAME" = "root" ]; then
    echo "ERROR: Cannot detect target user. Run via sudo from your user account (e.g. sudo bash setup-ssh-server.sh)."
    exit 1
fi

SSH_DIR="/home/$USERNAME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

echo "[1/6] Installing openssh-server..."
sudo apt-get update -qq
sudo apt-get install -y openssh-server

echo "[2/6] Enabling and starting SSH service..."
if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null 2>&1; then
    sudo systemctl enable ssh
    sudo systemctl start ssh
else
    sudo service ssh start 2>/dev/null || sudo sshd &
fi

echo "[3/6] Ensuring PasswordAuthentication is enabled..."
CLOUDINIT_CONF="/etc/ssh/sshd_config.d/50-cloud-init.conf"
if [ -f "$CLOUDINIT_CONF" ]; then
    sudo sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' "$CLOUDINIT_CONF"
fi
grep -q "^PasswordAuthentication yes" /etc/ssh/sshd_config || \
    sudo sed -i '/^#*PasswordAuthentication/c\PasswordAuthentication yes' /etc/ssh/sshd_config

echo "[4/6] Ensuring PubkeyAuthentication is enabled..."
if ! grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config; then
    sudo sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
fi

echo "[5/6] Setting up ~/.ssh directory and authorized_keys..."
mkdir -p "$SSH_DIR"
touch "$AUTH_KEYS"
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"
chown -R "$USERNAME:$USERNAME" "$SSH_DIR"

echo "[6/6] Restarting SSH to apply config..."
if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null 2>&1; then
    sudo systemctl restart ssh
else
    sudo service ssh restart 2>/dev/null || (sudo pkill sshd; sudo sshd)
fi

# Allow SSH through firewall if ufw is active
if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    echo "      ufw detected — allowing SSH..."
    sudo ufw allow ssh
fi

echo ""
echo "Done. SSH server is running on port 22."
echo "From your client, run:"
echo "  ssh-copy-id ${USERNAME}@$(hostname -I | awk '{print $1}')"
echo "  ssh ${USERNAME}@$(hostname -I | awk '{print $1}')"
