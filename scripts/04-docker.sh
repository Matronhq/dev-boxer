#!/bin/bash
# 04-docker.sh — Docker CE + Compose
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
load_config

log_section "Docker"

if command -v docker &>/dev/null; then
    log_skip "Docker already installed ($(docker --version))"
else
    log "Installing Docker CE..."

    # Add Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add Docker apt repo
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list

    apt-get update -qq >> "$LOG_FILE" 2>&1
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    log_ok "Docker CE installed"
fi

# Add user to docker group
if groups "$USERNAME" | grep -q docker; then
    log_skip "User $USERNAME already in docker group"
else
    usermod -aG docker "$USERNAME"
    log_ok "User $USERNAME added to docker group"
fi

systemctl enable docker >> "$LOG_FILE" 2>&1
systemctl start docker >> "$LOG_FILE" 2>&1
log_ok "Docker enabled and running"
