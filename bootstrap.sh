#!/bin/bash
# bootstrap.sh — ensure Ruby is installed, then exec the Ruby orchestrator.
# Designed for a fresh Ubuntu 24.04 root shell.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! command -v ruby >/dev/null 2>&1; then
    echo "Installing Ruby..."
    if [ "$EUID" -ne 0 ]; then
        sudo apt-get update -qq
        sudo apt-get install -y ruby
    else
        apt-get update -qq
        apt-get install -y ruby
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Friendly check only when neither $SCRIPT_DIR/config.yml exists nor the user
# passed --config <path> through. If they did pass --config, setup.rb will
# validate the path itself and exit 2 with a clear error if it's missing.
has_config_flag=false
for arg in "$@"; do
    case "$arg" in
        --config|--config=*) has_config_flag=true ;;
    esac
done

if ! $has_config_flag && [ ! -f "$SCRIPT_DIR/config.yml" ]; then
    echo "No config.yml found. Starting first-run setup..."
fi

exec ruby "$SCRIPT_DIR/setup.rb" "$@"
