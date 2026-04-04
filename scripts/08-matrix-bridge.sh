#!/bin/bash
# 08-matrix-bridge.sh — Matrix bridge + optional Matron Server homeserver
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
load_config

log_section "Matrix Bridge"

HOME_DIR="$(user_home)"
BRIDGE_DIR="$HOME_DIR/claude-matrix-bridge"
MATRIX_SERVER_DIR="$HOME_DIR/matrix-server"

# --- Bundled Matron Server Homeserver ---

if [ "$MATRIX_MODE" = "bundled" ]; then
    log "Setting up bundled Matron Server homeserver..."

    mkdir -p "$MATRIX_SERVER_DIR"
    render_template "$TEMPLATES_DIR/docker-compose.matron-server.yml" "$MATRIX_SERVER_DIR/docker-compose.yml"
    chown -R "$USERNAME:$USERNAME" "$MATRIX_SERVER_DIR"

    # Start Matron Server
    log "Starting Matron Server..."
    run_as_user "cd $MATRIX_SERVER_DIR && docker compose up -d" >> "$LOG_FILE" 2>&1

    if wait_for_url "http://localhost:6167/_matrix/client/versions" 30; then
        log_ok "Matron Server is running"
    else
        log_error "Matron Server failed to start. Check: docker logs matron-server"
        exit 1
    fi

    HOMESERVER_URL="http://localhost:6167"

    # --- Register accounts ---

    if [ -z "${MATRIX_BOT_ACCESS_TOKEN_BUNDLED:-}" ]; then
        log "Registering Matrix accounts..."

        # Generate registration token and bot password
        REG_TOKEN=$(openssl rand -hex 16)
        BOT_PASSWORD=$(openssl rand -hex 16)

        # Temporarily enable registration
        cat > "$MATRIX_SERVER_DIR/docker-compose.override.yml" << EOF
services:
  matron-server:
    environment:
      MATRON_SERVER_ALLOW_REGISTRATION: "true"
      MATRON_SERVER_REGISTRATION_TOKEN: "$REG_TOKEN"
EOF
        chown "$USERNAME:$USERNAME" "$MATRIX_SERVER_DIR/docker-compose.override.yml"
        run_as_user "cd $MATRIX_SERVER_DIR && docker compose down && docker compose up -d" >> "$LOG_FILE" 2>&1

        if ! wait_for_url "http://localhost:6167/_matrix/client/versions" 30; then
            log_error "Matron Server failed to restart with registration enabled"
            rm -f "$MATRIX_SERVER_DIR/docker-compose.override.yml"
            exit 1
        fi

        # Register helper functions
        _register_matrix_account() {
            local username="$1" password="$2" token="$3"
            local payload resp session

            payload=$(python3 -c "
import json,sys
print(json.dumps({
    'username': sys.argv[1], 'password': sys.argv[2],
    'auth': {'type': 'm.login.registration_token', 'token': sys.argv[3]},
    'inhibit_login': True
}))" "$username" "$password" "$token")

            resp=$(curl -s "$HOMESERVER_URL/_matrix/client/v3/register" \
                -X POST -H 'Content-Type: application/json' -d "$payload") || true

            if echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'user_id' in d else 1)" 2>/dev/null; then
                return 0
            fi

            # Try with UIA session
            session=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session',''))" 2>/dev/null || echo "")
            if [ -n "$session" ]; then
                payload=$(python3 -c "
import json,sys
print(json.dumps({
    'username': sys.argv[1], 'password': sys.argv[2],
    'auth': {'type': 'm.login.registration_token', 'token': sys.argv[3], 'session': sys.argv[4]},
    'inhibit_login': True
}))" "$username" "$password" "$token" "$session")

                resp=$(curl -s "$HOMESERVER_URL/_matrix/client/v3/register" \
                    -X POST -H 'Content-Type: application/json' -d "$payload") || true

                if echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'user_id' in d else 1)" 2>/dev/null; then
                    return 0
                fi
            fi

            echo "$resp" | grep -q "M_USER_IN_USE" 2>/dev/null && return 0
            log_warn "Registration response: $resp"
            return 1
        }

        _login_matrix_account() {
            local username="$1" password="$2"
            local payload resp token

            payload=$(python3 -c "
import json,sys
print(json.dumps({
    'type': 'm.login.password',
    'identifier': {'type': 'm.id.user', 'user': sys.argv[1]},
    'password': sys.argv[2]
}))" "$username" "$password")

            resp=$(curl -s "$HOMESERVER_URL/_matrix/client/v3/login" \
                -X POST -H 'Content-Type: application/json' -d "$payload") || true

            token=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true
            if [ -z "$token" ]; then
                log_error "Login failed for $username: $resp"
                return 1
            fi
            echo "$token"
        }

        _register_matrix_account "$MATRIX_BOT_USERNAME" "$BOT_PASSWORD" "$REG_TOKEN"
        log_ok "Bot account @${MATRIX_BOT_USERNAME}:${MATRIX_SERVER_DOMAIN} registered"

        _register_matrix_account "$MATRIX_USER_USERNAME" "$MATRIX_USER_PASSWORD" "$REG_TOKEN"
        log_ok "User account @${MATRIX_USER_USERNAME}:${MATRIX_SERVER_DOMAIN} registered"

        # Disable registration
        rm -f "$MATRIX_SERVER_DIR/docker-compose.override.yml"
        run_as_user "cd $MATRIX_SERVER_DIR && docker compose down && docker compose up -d" >> "$LOG_FILE" 2>&1
        wait_for_url "http://localhost:6167/_matrix/client/versions" 30

        # Login as bot to get access token
        MATRIX_BOT_ACCESS_TOKEN_BUNDLED=$(_login_matrix_account "$MATRIX_BOT_USERNAME" "$BOT_PASSWORD")
        log_ok "Bot access token obtained"

        # Create bridge room
        log "Creating bridge room..."
        ROOM_PAYLOAD=$(python3 -c "
import json,sys
print(json.dumps({
    'name': 'Claude Code Bridge',
    'topic': 'Messages in this room are forwarded to Claude Code',
    'visibility': 'private',
    'preset': 'private_chat',
    'invite': ['@' + sys.argv[1] + ':' + sys.argv[2]],
    'initial_state': [{'type': 'm.room.encryption', 'state_key': '', 'content': {'algorithm': 'm.megolm.v1.aes-sha2'}}]
}))" "$MATRIX_USER_USERNAME" "$MATRIX_SERVER_DOMAIN")

        ROOM_RESP=$(curl -s "$HOMESERVER_URL/_matrix/client/v3/createRoom" \
            -X POST \
            -H "Authorization: Bearer $MATRIX_BOT_ACCESS_TOKEN_BUNDLED" \
            -H 'Content-Type: application/json' \
            -d "$ROOM_PAYLOAD") || true

        MATRIX_BRIDGE_ROOM_ID=$(echo "$ROOM_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['room_id'])" 2>/dev/null) || true

        if [ -n "$MATRIX_BRIDGE_ROOM_ID" ]; then
            log_ok "Bridge room created: $MATRIX_BRIDGE_ROOM_ID"
        else
            log_warn "Failed to create room: $ROOM_RESP"
            log_warn "You can create a room manually from your Matrix client"
        fi

        # Save generated values back to config.env
        {
            echo ""
            echo "# === Generated by 08-matrix-bridge.sh ==="
            echo "MATRIX_BOT_ACCESS_TOKEN_BUNDLED=$MATRIX_BOT_ACCESS_TOKEN_BUNDLED"
            echo "MATRIX_BRIDGE_ROOM_ID=${MATRIX_BRIDGE_ROOM_ID:-}"
        } >> "$REPO_DIR/config.env"

        log_ok "Account registration complete"
    else
        log_skip "Matrix accounts already registered (token exists in config)"
        HOMESERVER_URL="http://localhost:6167"
    fi

    # Always export these for template rendering (needed on re-runs too)
    export MATRIX_HOMESERVER_URL="$HOMESERVER_URL"
    export MATRIX_ALLOWED_USER_IDS="@${MATRIX_USER_USERNAME}:${MATRIX_SERVER_DOMAIN}"

else
    # BYOH mode — use provided values
    log "Using external homeserver: ${MATRIX_HOMESERVER_URL:-}"
    export MATRIX_BOT_ACCESS_TOKEN_BUNDLED="${MATRIX_BOT_ACCESS_TOKEN:-}"
fi

# --- Clone bridge repo ---

if [ -d "$BRIDGE_DIR" ]; then
    log_skip "Bridge repo already cloned"
    run_as_user "cd $BRIDGE_DIR && git pull --ff-only" >> "$LOG_FILE" 2>&1 || true
else
    log "Cloning claude-matrix-bridge..."
    run_as_user "git clone https://github.com/matronhq/claude-matrix-bridge.git $BRIDGE_DIR" >> "$LOG_FILE" 2>&1
    log_ok "Bridge repo cloned"
fi

# --- Install npm dependencies ---

if [ -d "$BRIDGE_DIR/node_modules" ]; then
    log_skip "npm dependencies already installed"
else
    log "Installing npm dependencies..."
    run_as_user "cd $BRIDGE_DIR && npm install" >> "$LOG_FILE" 2>&1
    log_ok "npm dependencies installed"
fi

# --- Generate bridge .env ---

log "Generating bridge .env..."
render_template "$TEMPLATES_DIR/matrix-bridge.env" "$BRIDGE_DIR/.env"
chown "$USERNAME:$USERNAME" "$BRIDGE_DIR/.env"
chmod 600 "$BRIDGE_DIR/.env"
log_ok "Bridge .env generated"

# --- Generate MCP config ---

render_template "$TEMPLATES_DIR/mcp-config.json" "$BRIDGE_DIR/mcp-config-generated.json"
chown "$USERNAME:$USERNAME" "$BRIDGE_DIR/mcp-config-generated.json"
log_ok "Bridge MCP config generated"

# --- Install systemd services ---

log "Installing systemd services..."
render_template "$TEMPLATES_DIR/claude-matrix-bridge.service" /etc/systemd/system/claude-matrix-bridge.service
render_template "$TEMPLATES_DIR/claude-matrix-file-viewer.service" /etc/systemd/system/claude-matrix-file-viewer.service

systemctl daemon-reload
systemctl enable claude-matrix-bridge >> "$LOG_FILE" 2>&1
systemctl enable claude-matrix-file-viewer >> "$LOG_FILE" 2>&1
systemctl restart claude-matrix-bridge >> "$LOG_FILE" 2>&1
systemctl restart claude-matrix-file-viewer >> "$LOG_FILE" 2>&1
log_ok "Bridge services installed and started"

log_ok "Matrix bridge setup complete"
