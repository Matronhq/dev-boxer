# dev-boxer

Set up an Ubuntu 24.04 VPS as a remote Claude Code development environment with Matrix chat bridge, desktop GUI, and security hardening — in one command.

## What You Get

- **Claude Code** on a persistent remote server — run long-lived agents without keeping your laptop open
- **Matrix bridge** (via Element) — chat with Claude Code from your phone or any Matrix client using `!start`
- **Desktop GUI** — XFCE4 accessible via XRDP through an SSH tunnel, no open ports required
- **Security hardening** — SSH key-only auth on a non-standard port, UFW firewall, fail2ban, unattended-upgrades
- **Cloudflare Tunnel** — zero-trust HTTPS access with optional Google Workspace SSO, no exposed ports
- **Dev tools** — Docker, Node.js, Git, VS Code, Chrome, Firefox, GitHub CLI, and more

## Prerequisites

- Fresh Ubuntu 24.04 VPS (root SSH access)
- Cloudflare account with a domain configured
- SSH key pair (public key to hand)
- Matrix client such as [Element](https://element.io)

## Quick Start

```bash
# SSH into your VPS as root
ssh root@your-vps-ip

# Clone the repo
git clone https://github.com/matronhq/dev-boxer.git
cd dev-boxer

# Run the interactive config wizard
./wizard.sh

# Run the full setup
sudo ./setup.sh
```

Setup takes around 10–15 minutes. When it finishes, follow the post-setup steps printed at the end.

## Modules

Setup runs 10 modules in order. Each is idempotent — safe to re-run.

| # | Module | What it does |
|---|--------|--------------|
| 01 | `security` | SSH hardening (key-only, custom port), UFW firewall, fail2ban, unattended-upgrades, Prometheus node_exporter |
| 02 | `users` | Creates your Linux user, installs SSH public key, sudo access |
| 03 | `desktop` | XFCE4 desktop environment, XRDP server, dbus session setup |
| 04 | `docker` | Docker Engine + Docker Compose plugin, user added to docker group |
| 05 | `dev-tools` | Node.js 20, Git, GitHub CLI, VS Code (code), Composer |
| 06 | `browsers` | Google Chrome (stable deb), Firefox (native deb, not snap) |
| 07 | `claude` | Claude Code CLI, global npm install, persistent session config |
| 08 | `matrix-bridge` | Matron Server (Matrix homeserver, bundled) or BYOH, claude-matrix-bridge service |
| 09 | `cloudflare` | Cloudflare Tunnel creation, DNS records, cloudflared systemd service |
| 10 | `desktop-apps` | GitHub Desktop, additional desktop utilities |

## Re-running Individual Modules

Run a single module:

```bash
sudo ./setup.sh --only security
```

Resume from a specific module (e.g. after a failure):

```bash
sudo ./setup.sh --from matrix-bridge
```

## Connecting via RDP (Desktop)

RDP is only accessible through an SSH tunnel — no RDP port is exposed to the internet.

```bash
# Open the tunnel (replace port and hostname as needed)
ssh -L 3389:localhost:3389 -p 2222 youruser@your-vps-ip -N
```

Then connect your RDP client to `localhost:3389`. Use your Linux username and the RDP password you set in the wizard.

## Connecting via Matrix

1. Open [Element](https://app.element.io) (or your preferred Matrix client)
2. Sign in to your homeserver (e.g. `matrix.yourdomain.com` if using bundled mode)
3. Find the bridge room (created automatically during setup)
4. Send `!start` to begin a Claude Code session
5. Send `!stop` to end the session

The bridge runs as a systemd service: `sudo systemctl status claude-matrix-bridge`

## Cloudflare Access (Zero-Trust SSO)

To protect your tunnelled services behind Google Workspace SSO, see [docs/cloudflare-access.md](docs/cloudflare-access.md).

## Adding MCP Servers

To add MCP servers to Claude Code on your dev box, see [docs/adding-mcp-servers.md](docs/adding-mcp-servers.md).

## License

MIT — see [LICENSE](LICENSE). Copyright 2026 Yearbook Labs.
