#!/bin/bash
# setup.sh — Main orchestrator for dev-boxer
# Must be run as root: sudo ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/scripts/common.sh"

# --- Parse arguments ---

ONLY_MODULE=""
FROM_MODULE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --only)
            ONLY_MODULE="$2"
            shift 2
            ;;
        --from)
            FROM_MODULE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: sudo ./setup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --only <module>   Run a single module (e.g., --only security)"
            echo "  --from <module>   Resume from a specific module (e.g., --from matrix-bridge)"
            echo "  -h, --help        Show this help"
            echo ""
            echo "Modules: security, users, desktop, docker, dev-tools, browsers,"
            echo "         claude, matrix-bridge, cloudflare, desktop-apps"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# --- Checks ---

check_root
check_ubuntu_2404
load_config

# --- Module map ---

declare -A MODULE_SCRIPTS=(
    [security]="01-security.sh"
    [users]="02-users.sh"
    [desktop]="03-desktop.sh"
    [docker]="04-docker.sh"
    [dev-tools]="05-dev-tools.sh"
    [browsers]="06-browsers.sh"
    [claude]="07-claude.sh"
    [matrix-bridge]="08-matrix-bridge.sh"
    [cloudflare]="09-cloudflare.sh"
    [desktop-apps]="10-desktop-apps.sh"
)

MODULE_ORDER=(security users desktop docker dev-tools browsers claude matrix-bridge cloudflare desktop-apps)

run_module() {
    local name="$1"
    local script="${MODULE_SCRIPTS[$name]}"
    log_section "Module: $name ($script)"
    if bash "$SCRIPT_DIR/scripts/$script"; then
        log_ok "Module $name completed"
    else
        log_error "Module $name failed!"
        log "To resume from this module, run: sudo ./setup.sh --from $name"
        exit 1
    fi
}

# --- Run ---

log_section "dev-boxer setup starting"
log "Config: $REPO_DIR/config.env"
log "Log: $LOG_FILE"

if [ -n "$ONLY_MODULE" ]; then
    if [ -z "${MODULE_SCRIPTS[$ONLY_MODULE]+x}" ]; then
        log_error "Unknown module: $ONLY_MODULE"
        log "Available modules: ${MODULE_ORDER[*]}"
        exit 1
    fi
    run_module "$ONLY_MODULE"
else
    STARTED=false
    if [ -z "$FROM_MODULE" ]; then
        STARTED=true
    fi

    for module in "${MODULE_ORDER[@]}"; do
        if [ "$STARTED" = false ]; then
            if [ "$module" = "$FROM_MODULE" ]; then
                STARTED=true
            else
                log "Skipping module: $module (resuming from $FROM_MODULE)"
                continue
            fi
        fi
        run_module "$module"
    done

    if [ "$STARTED" = false ]; then
        log_error "Unknown module: $FROM_MODULE"
        log "Available modules: ${MODULE_ORDER[*]}"
        exit 1
    fi
fi

log_section "Setup complete!"
