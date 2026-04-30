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

cp config.example.yml config.yml   # edit to taste (interactive wizard coming)
sudo ./bootstrap.sh                # apt-installs ruby, then runs setup.rb (~10-15 min)
```

> Dev Boxer is being rewritten from bash to Ruby. Modules 01–06 are ported;
> 07–10 are still bash files under `scripts/` and aren't wired into `setup.rb`
> yet (port lands in subsequent PRs). Run them manually if needed:
> `sudo bash scripts/07-claude.sh`.

## Modules

Setup runs 10 idempotent modules in order:

| # | Module | Status | What it does |
|---|--------|--------|--------------|
| 01 | `security`     | ruby | SSH hardening, UFW firewall, fail2ban, unattended-upgrades |
| 02 | `users`        | ruby | Linux user creation, SSH key, sudo |
| 03 | `desktop`      | ruby | XFCE4 + XRDP (SSH tunnel only) |
| 04 | `docker`       | ruby | Docker Engine + Compose |
| 05 | `dev-tools`    | ruby | Node.js 20, Git, Python, uv, GitHub CLI |
| 06 | `browsers`     | ruby | Chrome, Firefox, Xvfb |
| 07 | `claude`       | bash | Claude Code CLI |
| 08 | `matrix-bridge`| bash | Matron Server + claude-matrix-bridge |
| 09 | `cloudflare`   | bash | Cloudflare Tunnel, DNS records |
| 10 | `desktop-apps` | bash | GitHub Desktop, utilities |

Re-run a single module or resume from a failure:

```bash
sudo ./setup.rb --only security
sudo ./setup.rb --from matrix-bridge
sudo ./setup.rb --skip desktop --dry-run
```

## Development

```bash
rake test          # run the minitest suite
ruby setup.rb --dry-run --config config.example.yml --modules-dir lib/dev_boxer/modules
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
