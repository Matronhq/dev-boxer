#!/bin/bash
# bootstrap.sh — ensure Ruby is installed, then exec the Ruby orchestrator.
# Designed for a fresh Ubuntu 24.04 root shell.
set -euo pipefail

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

if [ ! -f "$SCRIPT_DIR/config.yml" ]; then
    echo "No config.yml found. Run wizard.rb first, or copy config.example.yml."
    exit 1
fi

exec ruby "$SCRIPT_DIR/setup.rb" "$@"
