#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ─── Android Linux VM Detection & Fixes ──────────────────────────────────────

is_android_vm() {
    grep -qi "android" /proc/version 2>/dev/null && return 0
    [ -f /system/build.prop ] && return 0
    command -v getprop &>/dev/null && return 0
    [ -n "${ANDROID_ROOT:-}" ] || [ -n "${ANDROID_DATA:-}" ] && return 0
    return 1
}

if is_android_vm; then
    echo ""
    echo "Android Linux VM detected — applying network fixes..."

    echo "  [android 1/3] Switching to iptables-legacy..."
    sudo apt-get install -y -q iptables
    if update-alternatives --list iptables 2>/dev/null | grep -q legacy; then
        sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
        sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
        echo "                iptables-legacy set."
    else
        echo "                iptables-legacy not available, skipping."
    fi

    echo "  [android 2/3] Disabling IPv6 persistently..."
    if ! grep -q "disable_ipv6 = 1" /etc/sysctl.d/99-disable-ipv6.conf 2>/dev/null; then
        sudo tee /etc/sysctl.d/99-disable-ipv6.conf > /dev/null <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        sudo sysctl --system -q
        echo "                IPv6 disabled."
    else
        echo "                IPv6 already disabled, skipping."
    fi

    echo "  [android 3/3] Enforcing IPv4 only in apt..."
    if [ ! -f /etc/apt/apt.conf.d/99force-ipv4 ]; then
        sudo tee /etc/apt/apt.conf.d/99force-ipv4 > /dev/null <<'EOF'
Acquire::ForceIPv4 "true";
EOF
        echo "                apt forced to IPv4."
    else
        echo "                apt IPv4 already enforced, skipping."
    fi

    echo "Android VM fixes applied."
    echo ""
fi

# ─── Pre-flight: Remove stale/unverifiable apt sources ───────────────────────

echo "Checking for stale apt sources..."

if [ -f /etc/apt/sources.list.d/nordvpn.list ]; then
    if ! gpg --no-default-keyring \
             --keyring /usr/share/keyrings/nordvpn-keyring.gpg \
             --list-keys &>/dev/null 2>&1; then
        echo "  Stale NordVPN apt source detected (GPG key missing) — removing..."
        sudo rm -f /etc/apt/sources.list.d/nordvpn.list
        sudo rm -f /usr/share/keyrings/nordvpn-keyring.gpg
        echo "  Removed. NordVPN will be re-added cleanly if selected later."
    fi
fi

# ─── Core Setup ───────────────────────────────────────────────────────────────

echo "[1/16] apt update..."
sudo apt update
wait

echo "[2/16] apt upgrade..."
sudo apt upgrade -y
wait

echo "[3/16] apt full-upgrade..."
sudo apt full-upgrade -y
wait

echo "[4/16] Installing base packages..."
MISSING_PKGS=()
for pkg in python3-full python-is-python3 build-essential curl wget git; do
    dpkg -s "$pkg" &>/dev/null || MISSING_PKGS+=("$pkg")
done
if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    sudo apt install -y "${MISSING_PKGS[@]}"
else
    echo "      All base packages already installed, skipping."
fi
wait

echo "[5/16] git config user.name..."
current_name=$(git config --global user.name 2>/dev/null || true)
if [ "$current_name" != "charettep" ]; then
    git config --global user.name "charettep"
else
    echo "      Already set, skipping."
fi
wait

echo "[6/16] git config user.email..."
current_email=$(git config --global user.email 2>/dev/null || true)
if [ "$current_email" != "git@charettep.com" ]; then
    git config --global user.email "git@charettep.com"
else
    echo "      Already set, skipping."
fi
wait

echo "[7/16] Installing nvm..."
if [ ! -d "$HOME/.nvm" ]; then
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
else
    echo "      nvm already installed, skipping."
fi
wait

echo "[8/16] Loading nvm into current session..."
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
wait

echo "[9/16] Installing latest Node.js via nvm..."
if ! command -v node &>/dev/null; then
    nvm install node
else
    echo "      Node.js already installed ($(node -v)), skipping."
fi
wait

if command -v cloudflared &>/dev/null; then
    echo "[10-13/16] cloudflared already installed, skipping."
else
    read -rp "Install cloudflared? (Y/n): " cloudflared_answer </dev/tty
    cloudflared_answer="${cloudflared_answer:-Y}"

    if [[ "$cloudflared_answer" =~ ^[Yy]$ ]]; then
        echo "[10/16] Creating keyrings directory..."
        sudo mkdir -p --mode=0755 /usr/share/keyrings
        wait

        echo "[11/16] Adding Cloudflare GPG key..."
        if [ ! -f /usr/share/keyrings/cloudflare-main.gpg ]; then
            curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
        else
            echo "      Cloudflare GPG key already present, skipping."
        fi
        wait

        echo "[12/16] Adding Cloudflare apt repository..."
        if [ ! -f /etc/apt/sources.list.d/cloudflared.list ]; then
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
        else
            echo "      Cloudflare repo already present, skipping."
        fi
        wait

        echo "[13/16] Installing cloudflared..."
        sudo apt-get update
        wait
        sudo apt-get install -y cloudflared
        wait
    else
        echo "Skipping cloudflared."
    fi
fi

echo "[14/16] Installing Claude Code..."
if ! command -v claude &>/dev/null; then
    curl -fsSL https://claude.ai/install.sh | bash
else
    echo "      Claude Code already installed, skipping."
fi
wait

echo "[15/16] Adding ~/.local/bin to PATH..."
if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
    echo "      Added to ~/.bashrc."
else
    echo "      Already in ~/.bashrc, skipping."
fi
export PATH="$HOME/.local/bin:$PATH"
wait

echo "[16/16] Installing Codex CLI..."
if ! command -v codex &>/dev/null; then
    npm i -g @openai/codex
else
    echo "      Codex CLI already installed, skipping."
fi
wait

# ─── NordVPN (optional) ───────────────────────────────────────────────────────

echo ""
if command -v nordvpn &>/dev/null; then
    echo "NordVPN already installed, skipping."
else
    read -rp "Install NordVPN? (Y/n): " nordvpn_answer </dev/tty
    nordvpn_answer="${nordvpn_answer:-Y}"

    if [[ "$nordvpn_answer" =~ ^[Yy]$ ]]; then
        echo ""
        echo "[NordVPN 1/4] Adding GPG key..."
        if [ ! -f /usr/share/keyrings/nordvpn-keyring.gpg ]; then
            curl -s https://repo.nordvpn.com/gpg/nordvpn_public.asc | gpg --dearmor | sudo tee /usr/share/keyrings/nordvpn-keyring.gpg > /dev/null
            echo "              GPG key added."
        else
            echo "              GPG key already present, skipping."
        fi

        echo "[NordVPN 2/4] Adding repository..."
        if [ ! -f /etc/apt/sources.list.d/nordvpn.list ]; then
            echo "deb [signed-by=/usr/share/keyrings/nordvpn-keyring.gpg] https://repo.nordvpn.com/deb/nordvpn/debian stable main" | sudo tee /etc/apt/sources.list.d/nordvpn.list
            echo "              Repository added."
        else
            echo "              Repository already present, skipping."
        fi

        echo "[NordVPN 3/6] Installing NordVPN..."
        sudo apt-get update -q
        sudo apt-get install -y nordvpn
        echo "              NordVPN installed."

        echo "[NordVPN 4/6] Adding user to nordvpn group..."
        if ! getent group nordvpn &>/dev/null; then
            sudo groupadd nordvpn
        fi
        if ! groups "$USER" | grep -q nordvpn; then
            sudo usermod -aG nordvpn "$USER"
            echo "              User added to nordvpn group."
        else
            echo "              User already in nordvpn group, skipping."
        fi

        echo "[NordVPN 5/8] Starting nordvpnd daemon..."
        if ! pgrep nordvpnd &>/dev/null; then
            sudo nordvpnd &
            sleep 3
            echo "              Daemon started."
        else
            echo "              Daemon already running, skipping."
        fi

        echo "[NordVPN 6/8] Fixing socket permissions..."
        if [ -S /run/nordvpn/nordvpnd.sock ]; then
            sudo chown root:nordvpn /run/nordvpn/nordvpnd.sock
            sudo chmod 660 /run/nordvpn/nordvpnd.sock
            echo "              Socket ownership fixed."
        fi

        # Make socket fix persistent via udev rule (survives reboots)
        if [ ! -f /etc/udev/rules.d/99-nordvpn.rules ]; then
            echo 'SUBSYSTEM=="unix", KERNEL=="nordvpnd.sock", GROUP="nordvpn", MODE="0660"' | \
                sudo tee /etc/udev/rules.d/99-nordvpn.rules > /dev/null
            echo "              udev rule added for persistent socket permissions."
        fi

        echo "[NordVPN 7/8] Logging in..."
        if [ -n "${NORDVPN_TOKEN:-}" ]; then
            sudo -u "$USER" bash -c "nordvpn login --token $NORDVPN_TOKEN"
            echo "              Logged in."
        else
            echo "              \$NORDVPN_TOKEN not set — skipping login."
            echo "              To log in manually: nordvpn login --token YOUR_TOKEN_HERE"
        fi

        echo "[NordVPN 8/8] Enabling meshnet..."
        if [ -n "${NORDVPN_TOKEN:-}" ]; then
            sudo -u "$USER" bash -c "nordvpn set meshnet on"
            echo "              Meshnet enabled."
        else
            echo "              Skipping (not logged in)."
        fi

        echo ""
        echo "NordVPN setup complete."
        echo "NOTE: nordvpn group will be active in new shell sessions."
        echo "      To activate it now without logging out, run: newgrp nordvpn"
    else
        echo "Skipping NordVPN."
    fi
fi

# ─── SSH Server (optional) ────────────────────────────────────────────────────

echo ""
if command -v sshd &>/dev/null && (systemctl is-active ssh &>/dev/null 2>&1 || pgrep sshd &>/dev/null); then
    echo "SSH server already running, skipping."
else
    read -rp "Set up SSH server? (Y/n): " ssh_answer </dev/tty
    ssh_answer="${ssh_answer:-Y}"

    if [[ "$ssh_answer" =~ ^[Yy]$ ]]; then
        USERNAME="${SUDO_USER:-${USER:-$(logname 2>/dev/null || whoami)}}"
        if [ "$USERNAME" = "root" ]; then
            echo "ERROR: Cannot detect target user. Run via sudo from your user account."
            exit 1
        fi

        SSH_DIR="/home/$USERNAME/.ssh"
        AUTH_KEYS="$SSH_DIR/authorized_keys"

        echo ""
        echo "[SSH 1/6] Installing openssh-server..."
        if ! command -v sshd &>/dev/null; then
            sudo apt-get update -qq
            sudo apt-get install -y openssh-server
        else
            echo "      openssh-server already installed, skipping."
        fi

        echo "[SSH 2/6] Enabling and starting SSH service..."
        if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null 2>&1; then
            sudo systemctl enable ssh
            sudo systemctl start ssh
        else
            sudo service ssh start 2>/dev/null || sudo sshd &
        fi

        echo "[SSH 3/6] Ensuring PasswordAuthentication is enabled..."
        CLOUDINIT_CONF="/etc/ssh/sshd_config.d/50-cloud-init.conf"
        if [ -f "$CLOUDINIT_CONF" ]; then
            sudo sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' "$CLOUDINIT_CONF"
        fi
        grep -q "^PasswordAuthentication yes" /etc/ssh/sshd_config || \
            sudo sed -i '/^#*PasswordAuthentication/c\PasswordAuthentication yes' /etc/ssh/sshd_config

        echo "[SSH 4/6] Ensuring PubkeyAuthentication is enabled..."
        if ! grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config; then
            sudo sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        fi

        echo "[SSH 5/6] Setting up ~/.ssh directory and authorized_keys..."
        mkdir -p "$SSH_DIR"
        touch "$AUTH_KEYS"
        chmod 700 "$SSH_DIR"
        chmod 600 "$AUTH_KEYS"
        chown -R "$USERNAME:$USERNAME" "$SSH_DIR"

        echo "[SSH 6/6] Restarting SSH to apply config..."
        if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null 2>&1; then
            sudo systemctl restart ssh
        else
            sudo service ssh restart 2>/dev/null || (sudo pkill sshd; sudo sshd)
        fi

        if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
            echo "      ufw detected — allowing SSH..."
            sudo ufw allow ssh
        fi

        echo ""
        echo "SSH server is running on port 22."
        echo "From your client, run:"
        echo "  ssh-copy-id ${USERNAME}@$(hostname -I | awk '{print $1}')"
        echo "  ssh ${USERNAME}@$(hostname -I | awk '{print $1}')"
    else
        echo "Skipping SSH server setup."
    fi
fi

echo ""
echo "All done."
