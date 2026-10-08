# Adding MCP Servers and Plugins

Claude Code supports MCP (Model Context Protocol) servers — background processes that expose tools, resources, and prompts to the model. This guide covers the main ways to extend your dev box with additional MCP servers.

## 1. Claude Code Plugins

Claude Code has a first-party plugin registry. Install plugins with:

```bash
claude plugin install <name>@claude-plugins-official
```

Examples:

```bash
# TypeScript language server (hover types, go-to-definition, diagnostics)
claude plugin install typescript-lsp@claude-plugins-official

# Figma integration (read designs, generate components)
claude plugin install figma@claude-plugins-official

# Greptile code search (semantic search across repos)
claude plugin install greptile@claude-plugins-official
```

Plugins install globally and are available in all Claude Code sessions. List installed plugins with `claude plugin list`.

## 2. Global MCP Config

For servers not available as plugins, add them to Claude Code's global MCP config at `~/.claude/settings.json`. Create or edit the file:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "npx",
      "args": ["-y", "@my-org/my-mcp-server"],
      "env": {
        "MY_API_KEY": "your-key-here"
      }
    }
  }
}
```

Each entry under `mcpServers` is a server name mapped to a process definition (`command`, `args`, optional `env`). Claude Code starts these processes on launch and keeps them running for the session.

You can also manage servers via the CLI:

```bash
claude mcp add my-server -- npx -y @my-org/my-mcp-server
claude mcp list
claude mcp remove my-server
```

## 3. Popular MCP Servers

### Puppeteer (browser automation)

Puppeteer needs a display. On a headless server, wrap it with `xvfb-run`:

```json
{
  "mcpServers": {
    "puppeteer": {
      "command": "xvfb-run",
      "args": [
        "--auto-servernum",
        "--server-args=-screen 0 1920x1080x24",
        "npx", "-y", "@modelcontextprotocol/server-puppeteer"
      ],
      "env": {
        "DISPLAY": ""
      }
    }
  }
}
```

### Linear (project management)

Linear's MCP server uses SSE transport — provide the URL directly:

```json
{
  "mcpServers": {
    "linear": {
      "url": "https://mcp.linear.app/sse",
      "env": {
        "LINEAR_API_KEY": "lin_api_xxxxxxxxxxxx"
      }
    }
  }
}
```

Get your Linear API key from **Linear → Settings → API → Personal API keys**.

### Context7 (up-to-date library docs)

Context7 fetches current documentation for libraries and frameworks:

```json
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"]
    }
  }
}
```

No API key required — it queries public documentation sources.

## 4. Bridge MCP Config

matron-bridge runs Claude Code as a subprocess and passes it an MCP config file. To add servers available inside bridge-started sessions, edit:

```
~/matron-bridge/mcp-config-generated.json
```

The format is the same `mcpServers` JSON used in `~/.claude/settings.json`:

```json
{
  "mcpServers": {
    "ask-user": {
      "command": "node",
      "args": ["/home/youruser/matron-bridge/ask-user.js"],
      "env": {
        "BRIDGE_API_URL": "http://127.0.0.1:9802"
      }
    },
    "my-extra-server": {
      "command": "npx",
      "args": ["-y", "@my-org/my-mcp-server"]
    }
  }
}
```

After editing, restart the bridge service for the changes to take effect:

```bash
sudo systemctl restart matron-bridge
```

Note: `mcp-config-generated.json` is regenerated if you re-run `setup.sh`. Keep a backup of any custom additions, or re-apply them after setup.

## Tips

### Servers that need a display

Any server that launches a browser or GUI tool (Puppeteer, Chrome DevTools MCP, etc.) will fail on a headless server without a virtual display. Wrap the command with `xvfb-run --auto-servernum --server-args="-screen 0 1920x1080x24"` as shown in the Puppeteer example above.

### Auth requirements

Many MCP servers require API keys or OAuth tokens. Check the server's documentation before adding it. Store secrets in `env` within the config (the file is `chmod 600` when created by setup), or use a secrets manager and pass values via shell environment.

### Inspect running servers

```bash
# List configured MCP servers and their status
claude mcp list

# View server logs (stdout/stderr from the MCP process)
claude mcp logs my-server
```
