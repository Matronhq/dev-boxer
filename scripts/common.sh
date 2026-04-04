#!/bin/bash
# common.sh — Shared helpers for dev-boxer setup scripts
# Sourced by all other scripts. Do not run directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="$REPO_DIR/templates"
LOG_FILE="/var/log/dev-boxer-setup.log"

# --- Logging ---

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_section() {
    log ""
    log "=========================================="
    log "  $*"
    log "=========================================="
    log ""
}

log_ok() {
    log "  ✓ $*"
}

log_skip() {
    log "  → $* (already done, skipping)"
}

log_warn() {
    log "  WARNING: $*"
}

log_error() {
    log "  ERROR: $*" >&2
}

# --- Config Loading ---

load_config() {
    local config_file="$REPO_DIR/config.env"
    if [ ! -f "$config_file" ]; then
        log_error "config.env not found. Run ./wizard.sh first."
        exit 1
    fi
    set -a
    # shellcheck source=/dev/null
    source "$config_file"
    set +a
}

# --- OS Check ---

check_ubuntu_2404() {
    if [ ! -f /etc/os-release ]; then
        log_error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    if [ "$ID" != "ubuntu" ] || [[ "$VERSION_ID" != "24.04" ]]; then
        log_error "This script requires Ubuntu 24.04. Detected: $ID $VERSION_ID"
        exit 1
    fi
}

# --- Root Check ---

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root. Use: sudo ./setup.sh"
        exit 1
    fi
}

# --- Template Rendering ---

render_template() {
    local template="$1"
    local output="$2"

    if [ ! -f "$template" ]; then
        log_error "Template not found: $template"
        return 1
    fi

    local content
    content=$(cat "$template")

    # Replace {{VAR_NAME}} placeholders with environment variable values
    while IFS= read -r var_name; do
        local value="${!var_name:-}"
        content="${content//\{\{${var_name}\}\}/$value}"
    done < <(grep -oP '\{\{\K[A-Z_]+(?=\}\})' "$template" | sort -u)

    echo "$content" > "$output"
}

# --- Helpers ---

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >> "$LOG_FILE" 2>&1
}

user_home() {
    getent passwd "$USERNAME" | cut -d: -f6 || echo "/home/$USERNAME"
}

run_as_user() {
    su - "$USERNAME" -c "$*"
}

wait_for_url() {
    local url="$1"
    local max_wait="${2:-30}"

    for i in $(seq 1 "$max_wait"); do
        if curl -sf "$url" > /dev/null 2>&1; then
            return 0
        fi
        if [ "$i" -eq "$max_wait" ]; then
            return 1
        fi
        sleep 1
    done
}
