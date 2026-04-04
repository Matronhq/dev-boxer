#!/bin/bash
# 05-dev-tools.sh — Node.js, Git, Python, uv, GitHub CLI, build tools
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
load_config

log_section "Development Tools"

# --- Base packages ---

log "Installing base development packages..."
apt_install git build-essential make cmake htop jq unzip wget curl tree

log_ok "Base packages installed"

# --- Node.js 20 LTS ---

if command -v node &>/dev/null && node --version | grep -q "v20"; then
    log_skip "Node.js 20 already installed ($(node --version))"
else
    log "Installing Node.js 20 LTS..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >> "$LOG_FILE" 2>&1
    apt_install nodejs
    log_ok "Node.js installed ($(node --version))"
fi

# --- Python 3 + pip ---

if command -v python3 &>/dev/null; then
    log_skip "Python 3 already installed ($(python3 --version))"
else
    apt_install python3
fi
apt_install python3-pip python3-venv
log_ok "Python 3 + pip ready"

# --- uv (Python package manager) ---

if run_as_user "command -v uv" &>/dev/null; then
    log_skip "uv already installed"
else
    log "Installing uv..."
    run_as_user "curl -LsSf https://astral.sh/uv/install.sh | sh" >> "$LOG_FILE" 2>&1
    log_ok "uv installed"
fi

# --- GitHub CLI ---

if command -v gh &>/dev/null; then
    log_skip "GitHub CLI already installed ($(gh --version | head -1))"
else
    log "Installing GitHub CLI..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg >> "$LOG_FILE" 2>&1
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list
    apt-get update -qq >> "$LOG_FILE" 2>&1
    apt_install gh
    log_ok "GitHub CLI installed"
fi

log_ok "Development tools setup complete"
