#!/bin/bash
# wizard.sh — Interactive configuration wizard for dev-boxer
# Prompts for all required values and writes config.env

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

# --- Banner ---

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           dev-boxer  —  Setup Wizard                ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "This wizard will create your config.env file."
echo "You can re-run it at any time to update values."
echo ""

# --- Load existing config ---

if [ -f "$CONFIG_FILE" ]; then
    echo "Found existing config.env — current values will be shown as defaults."
    echo ""
    # shellcheck source=/dev/null
    set -a
    source "$CONFIG_FILE"
    set +a
fi

# --- Helper functions ---

# prompt VAR_NAME "Prompt text" [default_value]
prompt() {
    local var_name="$1"
    local prompt_text="$2"
    local default_val="${3:-${!var_name:-}}"
    local input

    if [ -n "$default_val" ]; then
        read -r -p "  $prompt_text [$default_val]: " input
        if [ -z "$input" ]; then
            input="$default_val"
        fi
    else
        read -r -p "  $prompt_text: " input
    fi

    printf -v "$var_name" '%s' "$input"
}

# prompt_secret VAR_NAME "Prompt text"
prompt_secret() {
    local var_name="$1"
    local prompt_text="$2"
    local input

    read -r -s -p "  $prompt_text: " input
    echo ""
    printf -v "$var_name" '%s' "$input"
}

# prompt_secret_confirm VAR_NAME "Prompt text"
prompt_secret_confirm() {
    local var_name="$1"
    local prompt_text="$2"
    local input confirm

    while true; do
        read -r -s -p "  $prompt_text: " input
        echo ""
        read -r -s -p "  Confirm $prompt_text: " confirm
        echo ""
        if [ "$input" = "$confirm" ]; then
            break
        fi
        echo "  Values do not match, please try again."
    done

    printf -v "$var_name" '%s' "$input"
}

# --- Section: User Setup ---

echo "┌──────────────────────────────────────────────────────────┐"
echo "│  User Setup                                              │"
echo "└──────────────────────────────────────────────────────────┘"
echo ""

while true; do
    prompt USERNAME "Linux username to create"
    if [ -n "$USERNAME" ] && echo "$USERNAME" | grep -qP '^[a-z_][a-z0-9_-]*$'; then
        break
    fi
    echo "  Username must start with a letter or underscore and contain only lowercase letters, digits, underscores, and hyphens."
done

echo ""
echo "  SSH public key — enter the full key string (ssh-ed25519 AAA...)"
echo "  or a path to a public key file (e.g. ~/.ssh/id_ed25519.pub)"
echo ""

while true; do
    prompt SSH_PUBLIC_KEY_INPUT "SSH public key or file path" "${SSH_PUBLIC_KEY:-}"
    if [ -z "$SSH_PUBLIC_KEY_INPUT" ]; then
        echo "  SSH public key is required."
        continue
    fi
    # If it looks like a file path, read the file
    if [ -f "$SSH_PUBLIC_KEY_INPUT" ]; then
        SSH_PUBLIC_KEY=$(cat "$SSH_PUBLIC_KEY_INPUT")
        echo "  Read key from file: $SSH_PUBLIC_KEY_INPUT"
    else
        SSH_PUBLIC_KEY="$SSH_PUBLIC_KEY_INPUT"
    fi
    break
done

echo ""
prompt SSH_PORT "SSH port" "${SSH_PORT:-2222}"

echo ""
while true; do
    prompt_secret_confirm RDP_PASSWORD "RDP password"
    if [ -n "$RDP_PASSWORD" ]; then
        break
    fi
    echo "  RDP password is required."
done

echo ""
prompt RDP_ALLOWED_IP "RDP allowed IP/CIDR (optional, leave blank to skip direct RDP firewall rule)" "${RDP_ALLOWED_IP:-}"

# --- Section: Email Alerts ---

echo ""
echo "┌──────────────────────────────────────────────────────────┐"
echo "│  Email Alerts (optional)                                 │"
echo "└──────────────────────────────────────────────────────────┘"
echo ""
echo "  Email alerts use Resend (https://resend.com) for SMTP."
echo "  Leave the API key blank to skip email alerts."
echo ""

prompt_secret RESEND_API_KEY "Resend API key (leave blank to skip)"

if [ -n "$RESEND_API_KEY" ]; then
    echo ""
    prompt RESEND_FROM_ADDRESS "From address (e.g., devbox@yourdomain.com)" "${RESEND_FROM_ADDRESS:-}"
    prompt ALERT_EMAIL "Alert destination email" "${ALERT_EMAIL:-}"
else
    RESEND_FROM_ADDRESS="${RESEND_FROM_ADDRESS:-}"
    ALERT_EMAIL="${ALERT_EMAIL:-}"
fi

# --- Section: Matrix Bridge ---

echo ""
echo "┌──────────────────────────────────────────────────────────┐"
echo "│  Matrix Bridge                                           │"
echo "└──────────────────────────────────────────────────────────┘"
echo ""
echo "  Modes:"
echo "    bundled  — Runs a Matron Server (Matrix homeserver) on this machine (recommended)"
echo "    byoh     — Bring your own homeserver (e.g., matrix.org account)"
echo ""

prompt MATRIX_MODE "Matrix mode (bundled/byoh)" "${MATRIX_MODE:-bundled}"

if [ "$MATRIX_MODE" = "bundled" ]; then
    echo ""
    prompt MATRIX_SERVER_DOMAIN "Matrix server domain (e.g., matrix.yourdomain.com)" "${MATRIX_SERVER_DOMAIN:-}"
    prompt MATRIX_BOT_USERNAME "Bot account username" "${MATRIX_BOT_USERNAME:-claude-bot}"
    prompt MATRIX_USER_USERNAME "Your Matrix username" "${MATRIX_USER_USERNAME:-}"
    echo ""
    prompt_secret_confirm MATRIX_USER_PASSWORD "Your Matrix password"

    # Clear BYOH fields
    MATRIX_HOMESERVER_URL="${MATRIX_HOMESERVER_URL:-}"
    MATRIX_BOT_ACCESS_TOKEN="${MATRIX_BOT_ACCESS_TOKEN:-}"
    MATRIX_ALLOWED_USER_IDS="${MATRIX_ALLOWED_USER_IDS:-}"
elif [ "$MATRIX_MODE" = "byoh" ]; then
    echo ""
    prompt MATRIX_HOMESERVER_URL "Homeserver URL (e.g., https://matrix.org)" "${MATRIX_HOMESERVER_URL:-}"
    prompt_secret MATRIX_BOT_ACCESS_TOKEN "Bot access token"
    prompt MATRIX_ALLOWED_USER_IDS "Allowed Matrix user IDs (comma-separated, e.g., @you:matrix.org)" "${MATRIX_ALLOWED_USER_IDS:-}"

    # Clear bundled fields
    MATRIX_SERVER_DOMAIN="${MATRIX_SERVER_DOMAIN:-}"
    MATRIX_BOT_USERNAME="${MATRIX_BOT_USERNAME:-claude-bot}"
    MATRIX_USER_USERNAME="${MATRIX_USER_USERNAME:-}"
    MATRIX_USER_PASSWORD="${MATRIX_USER_PASSWORD:-}"
else
    echo "  Unknown MATRIX_MODE: $MATRIX_MODE. Defaulting to bundled."
    MATRIX_MODE="bundled"
fi

# --- Section: Cloudflare Tunnel ---

echo ""
echo "┌──────────────────────────────────────────────────────────┐"
echo "│  Cloudflare Tunnel                                       │"
echo "└──────────────────────────────────────────────────────────┘"
echo ""
echo "  Your Cloudflare API token needs these permissions:"
echo "    Zone > DNS > Edit"
echo "    Account > Cloudflare Tunnel > Edit"
echo ""
echo "  Create a token at: https://dash.cloudflare.com/profile/api-tokens"
echo ""
echo "  NOTE: The API token is used during setup to create the tunnel and DNS"
echo "  records, then DELETED from config.env automatically after setup completes."
echo ""

prompt_secret CLOUDFLARE_API_TOKEN "Cloudflare API token"

echo ""
prompt CLOUDFLARE_DOMAIN "Cloudflare domain (e.g., yourdomain.com)" "${CLOUDFLARE_DOMAIN:-}"

echo ""
prompt CF_HOSTNAME_MAIN "Main hostname" "${CF_HOSTNAME_MAIN:-dev.${CLOUDFLARE_DOMAIN}}"

# Default matrix hostname from MATRIX_SERVER_DOMAIN if bundled
if [ "$MATRIX_MODE" = "bundled" ] && [ -n "${MATRIX_SERVER_DOMAIN:-}" ]; then
    CF_HOSTNAME_MATRIX_DEFAULT="$MATRIX_SERVER_DOMAIN"
else
    CF_HOSTNAME_MATRIX_DEFAULT="${CF_HOSTNAME_MATRIX:-matrix.${CLOUDFLARE_DOMAIN}}"
fi
prompt CF_HOSTNAME_MATRIX "Matrix hostname" "$CF_HOSTNAME_MATRIX_DEFAULT"

prompt CF_HOSTNAME_VIEWER "File viewer hostname" "${CF_HOSTNAME_VIEWER:-viewer.${CLOUDFLARE_DOMAIN}}"

# --- Generate HMAC secret if not set ---

if [ -z "${HMAC_SECRET:-}" ]; then
    echo ""
    echo "  Generating HMAC secret..."
    HMAC_SECRET=$(openssl rand -hex 32)
fi

# --- Write config.env ---

echo ""
echo "  Writing config.env..."

cat > "$CONFIG_FILE" << EOF
# dev-boxer configuration
# Generated by wizard.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Edit this file directly or re-run ./wizard.sh to update values.

# === User Setup ===
USERNAME="${USERNAME}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY}"
SSH_PORT="${SSH_PORT}"
RDP_PASSWORD="${RDP_PASSWORD}"
RDP_ALLOWED_IP="${RDP_ALLOWED_IP}"

# === Email Alerts ===
RESEND_API_KEY="${RESEND_API_KEY}"
RESEND_FROM_ADDRESS="${RESEND_FROM_ADDRESS}"
ALERT_EMAIL="${ALERT_EMAIL}"

# === Matrix Bridge ===
MATRIX_MODE="${MATRIX_MODE}"

# Bundled Matron Server settings
MATRIX_SERVER_DOMAIN="${MATRIX_SERVER_DOMAIN}"
MATRIX_BOT_USERNAME="${MATRIX_BOT_USERNAME}"
MATRIX_USER_USERNAME="${MATRIX_USER_USERNAME}"
MATRIX_USER_PASSWORD="${MATRIX_USER_PASSWORD}"

# BYOH settings
MATRIX_HOMESERVER_URL="${MATRIX_HOMESERVER_URL}"
MATRIX_BOT_ACCESS_TOKEN="${MATRIX_BOT_ACCESS_TOKEN}"
MATRIX_ALLOWED_USER_IDS="${MATRIX_ALLOWED_USER_IDS}"

# === Cloudflare Tunnel ===
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN}"
CLOUDFLARE_DOMAIN="${CLOUDFLARE_DOMAIN}"
CF_HOSTNAME_MAIN="${CF_HOSTNAME_MAIN}"
CF_HOSTNAME_MATRIX="${CF_HOSTNAME_MATRIX}"
CF_HOSTNAME_VIEWER="${CF_HOSTNAME_VIEWER}"

# === Generated (do not edit manually) ===
HMAC_SECRET="${HMAC_SECRET}"
CLOUDFLARE_TUNNEL_ID="${CLOUDFLARE_TUNNEL_ID:-}"
MATRIX_BOT_ACCESS_TOKEN_BUNDLED="${MATRIX_BOT_ACCESS_TOKEN_BUNDLED:-}"
MATRIX_BRIDGE_ROOM_ID="${MATRIX_BRIDGE_ROOM_ID:-}"
EOF

chmod 600 "$CONFIG_FILE"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Configuration saved to config.env                       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Next step: run the setup"
echo ""
echo "    sudo ./setup.sh"
echo ""
echo "  To re-run a single module later:"
echo ""
echo "    sudo ./setup.sh --only <module>"
echo ""
