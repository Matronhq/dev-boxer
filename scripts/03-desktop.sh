#!/bin/bash
# 03-desktop.sh — XFCE4 desktop environment + XRDP
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
load_config

log_section "Desktop Environment"

# --- XFCE4 ---

log "Installing XFCE4 desktop..."
apt_install xfce4 xfce4-goodies xfce4-terminal xorg dbus-x11

# Arc theme + Papirus icons
apt_install arc-theme papirus-icon-theme
log_ok "XFCE4 installed with Arc theme and Papirus icons"

# Disable compositor for RDP performance
HOME_DIR="$(user_home)"
XFCE_CONF_DIR="$HOME_DIR/.config/xfce4/xfconf/xfce-perchannel-xml"
mkdir -p "$XFCE_CONF_DIR"

if [ ! -f "$XFCE_CONF_DIR/xfwm4.xml" ]; then
    cat > "$XFCE_CONF_DIR/xfwm4.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
    <property name="theme" type="string" value="Arc-Dark"/>
  </property>
</channel>
EOF
    chown -R "$USERNAME:$USERNAME" "$HOME_DIR/.config"
    log_ok "XFCE compositor disabled, Arc-Dark theme set"
fi

# --- XRDP ---

log "Installing XRDP..."
apt_install xrdp

# Generate self-signed TLS cert for XRDP
if [ ! -f /etc/xrdp/cert.pem ]; then
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout /etc/xrdp/key.pem -out /etc/xrdp/cert.pem \
        -days 3650 -subj "/CN=dev-boxer" >> "$LOG_FILE" 2>&1
    log_ok "XRDP TLS certificate generated"
else
    log_skip "XRDP TLS certificate already exists"
fi

# Deploy XRDP config
cp "$TEMPLATES_DIR/xrdp.ini" /etc/xrdp/xrdp.ini

# Deploy session launcher
cp "$TEMPLATES_DIR/startwm.sh" /etc/xrdp/startwm.sh
chmod +x /etc/xrdp/startwm.sh

# Ensure xrdp user can access the cert
adduser xrdp ssl-cert >> "$LOG_FILE" 2>&1 || true

systemctl enable xrdp >> "$LOG_FILE" 2>&1
systemctl restart xrdp >> "$LOG_FILE" 2>&1
log_ok "XRDP configured and started"

log_ok "Desktop environment setup complete"
log "Access via SSH tunnel: ssh -L 3389:localhost:3389 $USERNAME@<server-ip> -p $SSH_PORT"
