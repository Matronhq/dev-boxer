#!/bin/bash
# Self-contained bootstrap for a fresh Ubuntu 24.04 VPS that does not yet have
# any way to clone the (private) Dev Boxer repo. Paste this whole script into
# the root shell of the new box.
#
# What it does:
#   1. Installs prerequisites (curl, git, ca-certs, gnupg, gh, ruby).
#   2. Authenticates the GitHub CLI as root, either non-interactively from the
#      $GH_TOKEN env var or via the interactive `gh auth login --web` flow.
#   3. Configures git's credential helper to use gh.
#   4. Clones (or updates) Dev Boxer into /opt/dev-boxer and execs install.sh,
#      which in turn runs bootstrap.sh (the wizard + module runner).
#
# Usage (interactive web flow):
#   sudo bash bootstrap-vps.sh
#
# Usage (non-interactive, recommended for repeat builds):
#   GH_TOKEN=ghp_xxx sudo -E bash bootstrap-vps.sh
#
# Re-running is safe: gh auth is idempotent and install.sh just `git pull`s
# an existing checkout.
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
    die "run this bootstrap as root (sudo bash bootstrap-vps.sh)"
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

export DEBIAN_FRONTEND=noninteractive

log "Installing prerequisites (ca-certificates, curl, git, gnupg, ruby)"
apt-get update -qq
apt-get install -y -qq ca-certificates curl git gnupg ruby

if ! command -v gh >/dev/null 2>&1; then
    log "Installing GitHub CLI"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    arch="$(dpkg --print-architecture)"
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list
    apt-get update -qq
    apt-get install -y -qq gh
fi

if gh auth status --hostname github.com >/dev/null 2>&1; then
    log "gh already authenticated for github.com"
else
    if [ -n "${GH_TOKEN:-}" ]; then
        log "Authenticating gh from GH_TOKEN env var"
        # `gh auth login --with-token` reads the token from stdin so it never
        # appears on the command line or in /proc/<pid>/cmdline.
        printf '%s' "$GH_TOKEN" | gh auth login --with-token --hostname github.com
        # Don't leave the token sitting in env where child processes inherit it.
        unset GH_TOKEN
    else
        if [ ! -t 0 ] && [ ! -r /dev/tty ]; then
            die "gh not authenticated and no \$GH_TOKEN. Re-run interactively or with GH_TOKEN=ghp_xxx sudo -E bash bootstrap-vps.sh"
        fi
        log "Authenticating gh interactively (device-code flow)"
        if [ ! -t 0 ] && [ -r /dev/tty ]; then
            gh auth login --web --git-protocol https --hostname github.com </dev/tty
        else
            gh auth login --web --git-protocol https --hostname github.com
        fi
    fi
fi

log "Configuring git to use gh as its credential helper for github.com"
gh auth setup-git --hostname github.com

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

log "Handing off to $INSTALL_DIR/bootstrap.sh"
cd "$INSTALL_DIR"
if [ -r /dev/tty ]; then
    exec ./bootstrap.sh "$@" </dev/tty
else
    exec ./bootstrap.sh "$@"
fi
