#!/bin/bash
# Public installer for a fresh Ubuntu VPS.
set -euo pipefail

REPO_URL="${DEV_BOXER_REPO_URL:-https://github.com/matronhq/dev-boxer.git}"
BRANCH="${DEV_BOXER_BRANCH:-main}"
INSTALL_DIR="${DEV_BOXER_DIR:-/opt/dev-boxer}"

log() {
    printf '\n==> %s\n' "$1"
}

die() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

if [ "$EUID" -ne 0 ]; then
    die "run this installer as root, e.g. curl -fsSL https://raw.githubusercontent.com/matronhq/dev-boxer/main/install.sh | sudo bash"
fi

if [ ! -r /etc/os-release ]; then
    die "could not detect operating system"
fi

. /etc/os-release

if [ "${ID:-}" != "ubuntu" ]; then
    die "Dev Boxer currently supports Ubuntu 24.04; detected ${PRETTY_NAME:-unknown OS}"
fi

if [ "${VERSION_ID:-}" != "24.04" ]; then
    printf 'Warning: Dev Boxer is tested on Ubuntu 24.04; detected %s.\n' "${PRETTY_NAME:-Ubuntu}"
fi

log "Installing prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl git ruby

if [ -d "$INSTALL_DIR/.git" ]; then
    log "Updating Dev Boxer in $INSTALL_DIR"
    git -C "$INSTALL_DIR" fetch --quiet origin "$BRANCH"
    git -C "$INSTALL_DIR" checkout --quiet "$BRANCH"
    git -C "$INSTALL_DIR" pull --ff-only --quiet origin "$BRANCH"
else
    log "Cloning Dev Boxer into $INSTALL_DIR"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi

log "Starting Dev Boxer setup"
cd "$INSTALL_DIR"
if [ -r /dev/tty ]; then
    exec ./bootstrap.sh "$@" </dev/tty
else
    exec ./bootstrap.sh "$@"
fi
