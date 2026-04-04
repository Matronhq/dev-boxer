#!/bin/bash
# 09-cloudflare.sh — Cloudflare Tunnel creation and DNS setup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
load_config

log_section "Cloudflare Tunnel"

if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
    if [ -n "${CLOUDFLARE_TUNNEL_ID:-}" ]; then
        log_skip "Tunnel already created (ID: $CLOUDFLARE_TUNNEL_ID), API token already cleaned up"
        # Still ensure service is running
        if systemctl is-active cloudflared-tunnel &>/dev/null; then
            log_skip "cloudflared service already running"
        else
            systemctl start cloudflared-tunnel >> "$LOG_FILE" 2>&1
            log_ok "cloudflared service started"
        fi
        exit 0
    else
        log_error "No Cloudflare API token and no existing tunnel ID. Re-run wizard.sh."
        exit 1
    fi
fi

# --- Install cloudflared ---

if command -v cloudflared &>/dev/null; then
    log_skip "cloudflared already installed ($(cloudflared --version 2>&1 | head -1))"
else
    log "Installing cloudflared..."
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
        | gpg --dearmor --yes -o /usr/share/keyrings/cloudflare-main.gpg >> "$LOG_FILE" 2>&1
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
        > /etc/apt/sources.list.d/cloudflared.list
    apt-get update -qq >> "$LOG_FILE" 2>&1
    apt_install cloudflared
    log_ok "cloudflared installed"
fi

# --- Create tunnel ---

mkdir -p /etc/cloudflared

if [ -z "${CLOUDFLARE_TUNNEL_ID:-}" ]; then
    log "Creating Cloudflare tunnel..."

    # Use TUNNEL_API_TOKEN env var for non-interactive auth (no cert.pem needed)
    export TUNNEL_API_TOKEN="$CLOUDFLARE_API_TOKEN"

    TUNNEL_NAME="dev-boxer-$(hostname -s)"
    TUNNEL_OUTPUT=$(cloudflared tunnel create "$TUNNEL_NAME" \
        --credentials-file /etc/cloudflared/credentials.json \
        -o json 2>&1) || true

    # Extract tunnel ID from credentials file (most reliable)
    CLOUDFLARE_TUNNEL_ID=""
    if [ -f /etc/cloudflared/credentials.json ]; then
        CLOUDFLARE_TUNNEL_ID=$(python3 -c "
import json
with open('/etc/cloudflared/credentials.json') as f:
    print(json.load(f)['TunnelID'])
" 2>/dev/null) || true
    fi

    # Fallback: parse JSON output
    if [ -z "$CLOUDFLARE_TUNNEL_ID" ]; then
        CLOUDFLARE_TUNNEL_ID=$(echo "$TUNNEL_OUTPUT" | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        if 'id' in d: print(d['id']); sys.exit(0)
    except json.JSONDecodeError: continue
sys.exit(1)
" 2>/dev/null) || true
    fi

    if [ -z "$CLOUDFLARE_TUNNEL_ID" ]; then
        log_error "Failed to create tunnel. Output: $TUNNEL_OUTPUT"
        exit 1
    fi

    log_ok "Tunnel created: $TUNNEL_NAME (ID: $CLOUDFLARE_TUNNEL_ID)"

    # Save tunnel ID to config
    echo "CLOUDFLARE_TUNNEL_ID=$CLOUDFLARE_TUNNEL_ID" >> "$REPO_DIR/config.env"
    export CLOUDFLARE_TUNNEL_ID
else
    log_skip "Tunnel already exists (ID: $CLOUDFLARE_TUNNEL_ID)"
fi

# --- Create DNS routes ---

log "Setting up DNS routes..."

create_dns_route() {
    local hostname="$1"
    if [ -n "$hostname" ]; then
        cloudflared tunnel route dns --overwrite-dns "$CLOUDFLARE_TUNNEL_ID" "$hostname" >> "$LOG_FILE" 2>&1 || true
        log_ok "DNS route: $hostname → tunnel"
    fi
}

create_dns_route "${CF_HOSTNAME_MAIN:-}"
create_dns_route "${CF_HOSTNAME_MATRIX:-}"
create_dns_route "${CF_HOSTNAME_VIEWER:-}"

# --- Deploy tunnel config ---

log "Deploying tunnel config..."
render_template "$TEMPLATES_DIR/cloudflared-config.yml" /etc/cloudflared/config.yml
log_ok "Tunnel config deployed"

# --- Install systemd service ---

cp "$TEMPLATES_DIR/cloudflared-tunnel.service" /etc/systemd/system/cloudflared-tunnel.service
systemctl daemon-reload
systemctl enable cloudflared-tunnel >> "$LOG_FILE" 2>&1
systemctl restart cloudflared-tunnel >> "$LOG_FILE" 2>&1
log_ok "cloudflared service installed and started"

# --- Delete Cloudflare API token ---

log "Cleaning up Cloudflare API token..."
sed -i '/^CLOUDFLARE_API_TOKEN=/d' "$REPO_DIR/config.env"
export -n TUNNEL_API_TOKEN 2>/dev/null || true
unset CLOUDFLARE_API_TOKEN TUNNEL_API_TOKEN
log_ok "API token removed from config.env and environment"

log_ok "Cloudflare Tunnel setup complete"
log "Main:    https://${CF_HOSTNAME_MAIN:-}"
log "Matrix:  https://${CF_HOSTNAME_MATRIX:-}"
log "Viewer:  https://${CF_HOSTNAME_VIEWER:-}"
log ""
log "IMPORTANT: Set up Cloudflare Access for zero-trust security."
log "See docs/cloudflare-access.md for instructions."
