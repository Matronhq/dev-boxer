#!/bin/bash
# 10-desktop-apps.sh — VS Code, GitHub Desktop, lazydocker, CLAUDE.md, summary
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
load_config

log_section "Desktop Apps & Final Setup"

HOME_DIR="$(user_home)"

# --- VS Code ---

if command -v code &>/dev/null; then
    log_skip "VS Code already installed"
else
    log "Installing VS Code..."
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor --yes -o /usr/share/keyrings/microsoft.gpg >> "$LOG_FILE" 2>&1
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
        > /etc/apt/sources.list.d/vscode.list
    apt-get update -qq >> "$LOG_FILE" 2>&1
    apt_install code
    log_ok "VS Code installed"
fi

# --- GitHub Desktop ---

if command -v github-desktop &>/dev/null; then
    log_skip "GitHub Desktop already installed"
else
    log "Installing GitHub Desktop..."
    curl -fsSL https://apt.packages.shiftkey.dev/gpg.key \
        | gpg --dearmor --yes -o /usr/share/keyrings/shiftkey-packages.gpg >> "$LOG_FILE" 2>&1
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/shiftkey-packages.gpg] https://apt.packages.shiftkey.dev/ubuntu/ any main" \
        > /etc/apt/sources.list.d/shiftkey-packages.list
    apt-get update -qq >> "$LOG_FILE" 2>&1
    apt_install github-desktop
    log_ok "GitHub Desktop installed"
fi

# --- lazydocker ---

if command -v lazydocker &>/dev/null; then
    log_skip "lazydocker already installed"
else
    log "Installing lazydocker..."
    LAZYDOCKER_VERSION=$(curl -s https://api.github.com/repos/jesseduffield/lazydocker/releases/latest | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))")
    curl -fsSL "https://github.com/jesseduffield/lazydocker/releases/download/v${LAZYDOCKER_VERSION}/lazydocker_${LAZYDOCKER_VERSION}_Linux_x86_64.tar.gz" \
        | tar xz -C /usr/local/bin lazydocker >> "$LOG_FILE" 2>&1
    log_ok "lazydocker installed (v$LAZYDOCKER_VERSION)"
fi

# --- Desktop shortcuts ---

DESKTOP_DIR="$HOME_DIR/Desktop"
mkdir -p "$DESKTOP_DIR"

create_shortcut() {
    local name="$1" exec="$2" icon="$3"
    cat > "$DESKTOP_DIR/$name.desktop" << EOF
[Desktop Entry]
Type=Application
Name=$name
Exec=$exec
Icon=$icon
Terminal=false
EOF
    chmod +x "$DESKTOP_DIR/$name.desktop"
}

create_shortcut "VS Code" "code" "visual-studio-code"
create_shortcut "Firefox" "firefox" "firefox"
create_shortcut "Chrome" "google-chrome-stable" "google-chrome"
create_shortcut "Terminal" "xfce4-terminal" "utilities-terminal"

chown -R "$USERNAME:$USERNAME" "$DESKTOP_DIR"
log_ok "Desktop shortcuts created"

# --- Generate CLAUDE.md ---

log "Generating CLAUDE.md..."
CLAUDE_DIR="$HOME_DIR/.claude"
mkdir -p "$CLAUDE_DIR"
render_template "$TEMPLATES_DIR/CLAUDE.md.template" "$CLAUDE_DIR/CLAUDE.md"
chown -R "$USERNAME:$USERNAME" "$CLAUDE_DIR"
log_ok "CLAUDE.md generated at $CLAUDE_DIR/CLAUDE.md"

# --- Post-install summary ---

log_section "Setup Complete!"

log "Your dev-boxer is ready."
log ""
log "=== Connection Details ==="
log ""
log "SSH:"
log "  ssh $USERNAME@<server-ip> -p $SSH_PORT"
log ""
log "RDP (via SSH tunnel):"
log "  ssh -L 3389:localhost:3389 $USERNAME@<server-ip> -p $SSH_PORT"
log "  Then connect RDP client to localhost:3389"
log ""

if [ -n "${CF_HOSTNAME_MAIN:-}" ]; then
    log "Cloudflare Tunnel URLs:"
    log "  Main:    https://${CF_HOSTNAME_MAIN}"
    [ -n "${CF_HOSTNAME_MATRIX:-}" ] && log "  Matrix:  https://${CF_HOSTNAME_MATRIX}"
    [ -n "${CF_HOSTNAME_VIEWER:-}" ] && log "  Viewer:  https://${CF_HOSTNAME_VIEWER}"
    log ""
fi

log "Matrix Bridge:"
log "  1. Open Element and set homeserver to https://${CF_HOSTNAME_MATRIX:-your-matrix-hostname}"
log "  2. Log in as @${MATRIX_USER_USERNAME:-your-username}:${MATRIX_SERVER_DOMAIN:-your-domain}"
log "  3. Open the 'Claude Code Bridge' room"
log "  4. Send !start to begin a Claude Code session"
log ""
log "Services:"
log "  sudo systemctl status claude-matrix-bridge"
log "  sudo systemctl status claude-matrix-file-viewer"
log "  sudo systemctl status cloudflared-tunnel"
log "  sudo systemctl status xrdp"
log ""
log "IMPORTANT: Set up Cloudflare Access for zero-trust security!"
log "See: docs/cloudflare-access.md"
