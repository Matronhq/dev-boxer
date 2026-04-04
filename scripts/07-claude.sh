#!/bin/bash
# 07-claude.sh — Claude Code CLI + plugins + MCP servers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
load_config

log_section "Claude Code"

HOME_DIR="$(user_home)"

# --- Claude Code CLI ---

if run_as_user "command -v claude" &>/dev/null; then
    log_skip "Claude Code CLI already installed"
else
    log "Installing Claude Code CLI..."
    run_as_user "curl -fsSL https://claude.ai/install.sh | sh" >> "$LOG_FILE" 2>&1
    log_ok "Claude Code CLI installed"
fi

# --- Claude Code settings ---

CLAUDE_DIR="$HOME_DIR/.claude"
mkdir -p "$CLAUDE_DIR"

if [ ! -f "$CLAUDE_DIR/settings.json" ]; then
    cat > "$CLAUDE_DIR/settings.json" << 'EOF'
{
  "permissions": {},
  "cleanupOldSessions": {
    "enabled": true,
    "maxAgeDays": 7
  }
}
EOF
    log_ok "Claude Code settings.json created"
else
    log_skip "Claude Code settings.json already exists"
fi

chown -R "$USERNAME:$USERNAME" "$CLAUDE_DIR"

# --- Chrome DevTools MCP ---

if run_as_user "npm list -g chrome-devtools-mcp" &>/dev/null 2>&1; then
    log_skip "Chrome DevTools MCP already installed"
else
    log "Installing Chrome DevTools MCP..."
    run_as_user "npm install -g chrome-devtools-mcp" >> "$LOG_FILE" 2>&1
    log_ok "Chrome DevTools MCP installed"
fi

# --- Claude Code Plugins ---

PLUGINS=(
    superpowers
    context7
    serena
    feature-dev
    code-review
    code-simplifier
    claude-md-management
    github
    frontend-design
    security-guidance
)

log "Installing Claude Code plugins..."
for plugin in "${PLUGINS[@]}"; do
    if run_as_user "claude plugin list 2>/dev/null" | grep -q "${plugin}@claude-plugins-official"; then
        log_skip "Plugin $plugin already installed"
    else
        run_as_user "claude plugin install ${plugin}@claude-plugins-official" >> "$LOG_FILE" 2>&1
        log_ok "Plugin $plugin installed"
    fi
done

log_ok "Claude Code setup complete"
