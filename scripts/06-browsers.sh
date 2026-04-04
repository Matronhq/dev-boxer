#!/bin/bash
# 06-browsers.sh — Google Chrome + Firefox
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
load_config

log_section "Browsers"

# --- Google Chrome ---

if command -v google-chrome-stable &>/dev/null; then
    log_skip "Google Chrome already installed"
else
    log "Installing Google Chrome..."
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        | gpg --dearmor --yes -o /usr/share/keyrings/google-chrome.gpg >> "$LOG_FILE" 2>&1
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list
    apt-get update -qq >> "$LOG_FILE" 2>&1
    apt_install google-chrome-stable
    log_ok "Google Chrome installed"
fi

# --- Firefox (native deb, not snap) ---

if command -v firefox &>/dev/null; then
    log_skip "Firefox already installed"
else
    log "Installing Firefox (native deb)..."

    # Add Mozilla repo
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
        | gpg --dearmor --yes -o /etc/apt/keyrings/packages.mozilla.org.gpg >> "$LOG_FILE" 2>&1
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.gpg] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list

    # Prefer Mozilla repo over snap
    cat > /etc/apt/preferences.d/mozilla << 'EOF'
Package: firefox*
Pin: origin packages.mozilla.org
Pin-Priority: 1001
EOF

    apt-get update -qq >> "$LOG_FILE" 2>&1
    apt_install firefox
    log_ok "Firefox installed (native deb)"
fi

# Install xvfb for headless browser automation (used by Chrome DevTools MCP)
apt_install xvfb
log_ok "Xvfb installed for headless browser automation"

log_ok "Browsers setup complete"
