# Dev Boxer

Set up an Ubuntu 24.04 VPS as a remote Claude Code development environment with Matrix chat bridge, desktop GUI, and security hardening -- in one command.

## Part of the Matron ecosystem

| Project | Description |
|---------|-------------|
| [Matron Desktop](https://github.com/matronhq/matron-desktop) | Desktop client |
| [Matron Web](https://github.com/matronhq/matron-web) | Web client |
| [Matron iOS](https://github.com/matronhq/matron-ios) | iOS client |
| [Matron Server](https://github.com/matronhq/matron-server) | Matrix homeserver |
| **Dev Boxer** | One-command dev environment setup (this repo) |

## What you get

- **Claude Code** on a persistent remote server -- run long-lived agents without keeping your laptop open
- **Matrix bridge** -- chat with Claude Code from your phone or any Matrix client using `!start`
- **Matron Server** -- bundled Matrix homeserver, no external account needed
- **Desktop GUI** -- XFCE4 via XRDP through an SSH tunnel, no open ports
- **Security hardening** -- SSH key-only auth, custom port, UFW, fail2ban, unattended-upgrades
- **Cloudflare Tunnel** -- zero-trust HTTPS access with optional SSO
- **Dev tools** -- Docker, Node.js, Git, VS Code, Chrome, Firefox, GitHub CLI

## Prerequisites

- Fresh Ubuntu 24.04 VPS with root SSH access
- Cloudflare account with a domain configured
- SSH key pair

## Quick start

```bash
ssh root@your-vps-ip

git clone https://github.com/matronhq/dev-boxer.git
cd dev-boxer

./wizard.sh        # interactive config
sudo ./setup.sh    # run setup (~10-15 min)
```

## Modules

Setup runs 10 idempotent modules in order:

| # | Module | What it does |
|---|--------|--------------|
| 01 | `security` | SSH hardening, UFW firewall, fail2ban, unattended-upgrades |
| 02 | `users` | Linux user creation, SSH key, sudo |
| 03 | `desktop` | XFCE4 + XRDP (SSH tunnel only) |
| 04 | `docker` | Docker Engine + Compose |
| 05 | `dev-tools` | Node.js 20, Git, GitHub CLI, VS Code, Composer |
| 06 | `browsers` | Chrome, Firefox |
| 07 | `claude` | Claude Code CLI |
| 08 | `matrix-bridge` | Matron Server + claude-matrix-bridge |
| 09 | `cloudflare` | Cloudflare Tunnel, DNS records |
| 10 | `desktop-apps` | GitHub Desktop, utilities |

Re-run a single module or resume from a failure:

```bash
sudo ./setup.sh --only security
sudo ./setup.sh --from matrix-bridge
```

## Connecting

### RDP (desktop)

RDP is only accessible through an SSH tunnel:

```bash
ssh -L 3389:localhost:3389 -p 2222 youruser@your-vps-ip -N
```

Connect your RDP client to `localhost:3389`.

### Matrix (chat with Claude)

1. Open any Matrix client (Matron, Element, etc.)
2. Sign in to your homeserver (e.g. `matrix.yourdomain.com` if using bundled mode)
3. Find the bridge room (created during setup)
4. `!start` to begin a Claude Code session
5. `!stop` to end it

## License

MIT
