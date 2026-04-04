#!/bin/bash
# 02-users.sh — Create dev user, sudo, SSH keys, shell setup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
load_config

log_section "User Setup"

HOME_DIR="/home/$USERNAME"

# --- Create user ---

if id "$USERNAME" &>/dev/null; then
    log_skip "User $USERNAME already exists"
else
    log "Creating user $USERNAME..."
    useradd -m -s /bin/bash "$USERNAME"
    log_ok "User $USERNAME created"
fi

# --- Set shell to zsh ---

log "Setting up zsh..."
apt_install zsh
chsh -s "$(which zsh)" "$USERNAME"
log_ok "Shell set to zsh"

# --- Sudo ---

if groups "$USERNAME" | grep -q sudo; then
    log_skip "User $USERNAME already in sudo group"
else
    usermod -aG sudo "$USERNAME"
    log_ok "User $USERNAME added to sudo group"
fi

# Passwordless sudo
if [ ! -f "/etc/sudoers.d/$USERNAME" ]; then
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
    chmod 440 "/etc/sudoers.d/$USERNAME"
    log_ok "Passwordless sudo configured"
else
    log_skip "Sudoers file already exists"
fi

# --- SSH keys ---

SSH_DIR="$HOME_DIR/.ssh"
mkdir -p "$SSH_DIR"

if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
    if grep -qF "$SSH_PUBLIC_KEY" "$SSH_DIR/authorized_keys" 2>/dev/null; then
        log_skip "SSH key already in authorized_keys"
    else
        echo "$SSH_PUBLIC_KEY" >> "$SSH_DIR/authorized_keys"
        log_ok "SSH public key added"
    fi
fi

chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys" 2>/dev/null || true
chown -R "$USERNAME:$USERNAME" "$SSH_DIR"

# --- RDP password ---

if [ -n "${RDP_PASSWORD:-}" ]; then
    echo "$USERNAME:$RDP_PASSWORD" | chpasswd
    log_ok "RDP password set"
fi

# --- GitHub known hosts ---

KNOWN_HOSTS="$SSH_DIR/known_hosts"
if ! grep -q "github.com" "$KNOWN_HOSTS" 2>/dev/null; then
    ssh-keyscan -t ed25519,rsa github.com >> "$KNOWN_HOSTS" 2>/dev/null
    chown "$USERNAME:$USERNAME" "$KNOWN_HOSTS"
    log_ok "github.com added to known_hosts"
else
    log_skip "github.com already in known_hosts"
fi

# --- Restart sshd now that user and SSH keys are in place ---
log "Restarting sshd with hardened config..."
systemctl restart sshd
log_ok "sshd restarted (key-only auth now active)"

log_ok "User setup complete"
