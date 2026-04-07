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

is_wsl() {
    grep -qi "microsoft\|wsl" /proc/version 2>/dev/null && return 0
    [ -f /proc/sys/fs/binfmt_misc/WSLInterop ] && return 0
    return 1
}

# Checks if systemd is PID 1 (reliable on WSL2 with/without systemd enabled)
is_systemd() {
    [ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ]
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
            if is_systemd; then
                sudo systemctl start nordvpnd
            else
                sudo service nordvpnd start 2>/dev/null || sudo nordvpnd &
            fi
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

        # Make socket fix persistent via udev rule (survives reboots; skipped on WSL)
        if is_wsl; then
            echo "              WSL detected — skipping udev rule (udev not active in WSL)."
        elif [ ! -f /etc/udev/rules.d/99-nordvpn.rules ]; then
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

        echo "[NordVPN 8/10] Enabling meshnet..."
        if [ -n "${NORDVPN_TOKEN:-}" ]; then
            sudo -u "$USER" bash -c "nordvpn set meshnet on"
            echo "               Meshnet enabled."
        else
            echo "               Skipping (not logged in)."
        fi

        echo "[NordVPN 9/10] Setting meshnet machine nickname..."
        if [ -n "${NORDVPN_TOKEN:-}" ]; then
            read -rp "  Enter a nickname for this machine on meshnet: " mesh_nickname </dev/tty
            if [ -n "$mesh_nickname" ]; then
                # NordVPN uses the system hostname as the meshnet identifier
                sudo hostnamectl set-hostname "$mesh_nickname" 2>/dev/null || \
                    echo "$mesh_nickname" | sudo tee /etc/hostname > /dev/null
                # Keep /etc/hosts consistent
                sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$mesh_nickname/" /etc/hosts 2>/dev/null || \
                    echo -e "127.0.1.1\t$mesh_nickname" | sudo tee -a /etc/hosts > /dev/null
                echo "               Hostname set to: $mesh_nickname"
            else
                echo "               No nickname entered, skipping."
            fi
        else
            echo "               Skipping (not logged in)."
        fi

        echo "[NordVPN 10/10] Configuring meshnet peer permissions..."
        if [ -n "${NORDVPN_TOKEN:-}" ]; then
            read -rp "  Allow all meshnet peer settings for all detected peers? (Y/n): " mesh_peers_answer </dev/tty
            mesh_peers_answer="${mesh_peers_answer:-Y}"

            if [[ "$mesh_peers_answer" =~ ^[Yy]$ ]]; then
                # Fetch peer hostnames from meshnet
                peer_list=$(sudo -u "$USER" bash -c "nordvpn meshnet peer list 2>/dev/null" \
                    | grep -E "^Hostname:" | awk '{print $2}')

                if [ -z "$peer_list" ]; then
                    echo "               No peers found on meshnet yet."
                    echo "               Re-run after other devices have joined meshnet."
                else
                    while IFS= read -r peer; do
                        echo "               Enabling all permissions for: $peer"
                        sudo -u "$USER" bash -c "nordvpn meshnet peer incoming allow $peer" 2>/dev/null || true
                        sudo -u "$USER" bash -c "nordvpn meshnet peer routing allow $peer"  2>/dev/null || true
                        sudo -u "$USER" bash -c "nordvpn meshnet peer local allow $peer"    2>/dev/null || true
                        sudo -u "$USER" bash -c "nordvpn meshnet peer fileshare allow $peer" 2>/dev/null || true
                    done <<< "$peer_list"
                    echo "               All peer permissions applied."
                fi
            else
                echo "               Skipping peer permissions."
            fi
        else
            echo "               Skipping (not logged in)."
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
    HOST_IP=$(hostname -I | awk '{print $1}')
    SSH_PORT=22

    echo ""
    echo "[SSH 1/7] Installing openssh-server..."
    if ! command -v sshd &>/dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y openssh-server
    else
        echo "      openssh-server already installed, skipping."
    fi

    echo "[SSH 2/7] Enabling and starting SSH service..."
    if is_systemd; then
        sudo systemctl enable ssh
        sudo systemctl start ssh
    else
        sudo service ssh start 2>/dev/null || sudo sshd &
    fi

    echo "[SSH 3/7] Ensuring PasswordAuthentication is enabled..."
    CLOUDINIT_CONF="/etc/ssh/sshd_config.d/50-cloud-init.conf"
    if [ -f "$CLOUDINIT_CONF" ]; then
        sudo sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' "$CLOUDINIT_CONF"
    fi
    grep -q "^PasswordAuthentication yes" /etc/ssh/sshd_config || \
        sudo sed -i '/^#*PasswordAuthentication/c\PasswordAuthentication yes' /etc/ssh/sshd_config

    echo "[SSH 4/7] Ensuring PubkeyAuthentication is enabled..."
    grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config || \
        sudo sed -i '/^#*PubkeyAuthentication/c\PubkeyAuthentication yes' /etc/ssh/sshd_config

    echo "[SSH 5/7] Setting up ~/.ssh directory and authorized_keys..."
    sudo -u "$USERNAME" mkdir -p "$SSH_DIR"
    sudo -u "$USERNAME" touch "$AUTH_KEYS"
    sudo -u "$USERNAME" chmod 700 "$SSH_DIR"
    sudo -u "$USERNAME" chmod 600 "$AUTH_KEYS"

    echo "[SSH 6/7] Restarting SSH to apply config..."
    if is_systemd; then
        sudo systemctl restart ssh
    else
        sudo service ssh restart 2>/dev/null || (sudo pkill sshd 2>/dev/null; sudo sshd)
    fi

    echo "[SSH 7/7] Checking firewall..."
    if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        sudo ufw allow ssh
        echo "      ufw: SSH allowed."
    else
        echo "      ufw inactive, skipping."
    fi

    # ── Client instructions ───────────────────────────────────────────────────
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              SSH SERVER IS READY — port $SSH_PORT                  ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║                                                              ║"
    echo "║  Step 1 — Generate a key on your CLIENT (if you don't       ║"
    echo "║  have one yet):                                              ║"
    echo "║    ssh-keygen -t ed25519 -C \"your@email.com\"                ║"
    echo "║                                                              ║"
    echo "║  Step 2 — Copy your key to this machine:                    ║"
    echo "║    ssh-copy-id -p $SSH_PORT ${USERNAME}@${HOST_IP}          ║"
    echo "║                                                              ║"
    echo "║  Step 3 — Connect:                                          ║"
    echo "║    ssh -p $SSH_PORT ${USERNAME}@${HOST_IP}                  ║"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    if is_wsl; then
        WIN_GW=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -1)
        echo ""
        echo "  WSL note: $HOST_IP is your WSL internal address."
        echo "  From Windows you can connect directly with:"
        echo "    ssh -p $SSH_PORT ${USERNAME}@${HOST_IP}"
        if [ -n "$WIN_GW" ]; then
            echo "  For external access, run in PowerShell (as admin):"
            echo "    netsh interface portproxy add v4tov4 listenport=$SSH_PORT listenaddress=0.0.0.0 connectaddress=$HOST_IP connectport=$SSH_PORT"
        fi
    fi
else
    echo "Skipping SSH server setup."
fi

echo ""
echo "All done."
