# Dev Boxer

Set up an Ubuntu 24.04 VPS as a remote Claude Code development environment with Matrix chat bridge, desktop GUI, Cloudflare Tunnel, and security hardening -- in one command.

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
- Cloudflare zone DNS API token
- Optional one-time Cloudflare Tunnel setup token, or willingness to create the tunnel manually
- Optional one-time Cloudflare Access setup token for automated Zero Trust setup
- SSH key pair

## Quick start

Run this on the VPS as root:

```bash
curl -fsSL https://raw.githubusercontent.com/matronhq/dev-boxer/main/install.sh | bash
```

The installer clones Dev Boxer to `/opt/dev-boxer`, prompts for the minimum required settings, writes `config.yml` and gitignored `secrets.yml`, then runs the full setup.

It asks for:

- Linux username, SSH public key, and SSH port
- Base domain, e.g. `example.com`
- Cloudflare zone DNS API token
- Whether Dev Boxer should create the Cloudflare tunnel automatically
- Whether Dev Boxer should create a Cloudflare Access app for `dev.<domain>` and `viewer.<domain>`
- Matrix username

It derives `dev.<domain>`, `matrix.<domain>`, and `viewer.<domain>` automatically.

### Cloudflare setup

Register or transfer a domain with [Cloudflare Registrar](https://www.cloudflare.com/products/registrar/), or add an existing domain to Cloudflare DNS before running the installer.

Create a zone-scoped DNS API token from [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) with:

- Zone permissions: `Zone:Read` and `DNS:Edit`
- Zone resource: the domain you will use, e.g. `example.com`

For tunnel creation, choose one of:

- Let Dev Boxer create the tunnel automatically: create a temporary API token with account permission `Cloudflare Tunnel:Edit`. The installer stores it only in `secrets.yml`, uses it once, then wipes it after the tunnel credentials are created.
- Create the tunnel manually: skip the setup token. Dev Boxer installs `cloudflared`, pauses, and prints the exact `cloudflared tunnel create ...` command to run with your temporary token in another root shell. It then asks for the resulting `TunnelID` and stores only that ID.

Dev Boxer creates proxied Cloudflare DNS records for all configured tunnel hostnames, including `matrix.<domain>`, using the zone DNS token.

### Cloudflare Access

The wizard can optionally create a Cloudflare Zero Trust Access self-hosted application for the browser-facing hostnames:

- Protected: `dev.<domain>` and `viewer.<domain>`
- Excluded: `matrix.<domain>`, so Matrix clients can reach the homeserver API directly

Automated Access setup derives the Cloudflare account from the zone and requires a one-time API token that can edit Zero Trust Access applications and policies. Dev Boxer persists the resulting Access app ID and removes the setup token after a successful run.

## Modules

Setup runs 11 idempotent modules in order:

| # | Module | What it does |
|---|--------|--------------|
| 01 | `security`     | SSH hardening, UFW firewall, fail2ban, unattended-upgrades |
| 02 | `users`        | Linux user creation, SSH key, sudo, zsh |
| 03 | `desktop`      | XFCE4 + XRDP (SSH tunnel only) |
| 04 | `docker`       | Docker Engine + Compose |
| 05 | `dev-tools`    | Node.js 20, Git, Python, uv, GitHub CLI |
| 06 | `browsers`     | Chrome, Firefox, Xvfb |
| 07 | `claude`       | Claude Code CLI + plugins + Chrome DevTools MCP |
| 08 | `matrix-bridge`| Matron Server + claude-matrix-bridge |
| 09 | `cloudflare`   | Cloudflare Tunnel, DNS routes, zone token deploy |
| 10 | `desktop-apps` | VS Code, GitHub Desktop, lazydocker, MOTD |
| 11 | `hello-world`  | `localhost:9810` tunnel smoke-test service |

Re-run a single module or resume from a failure:

```bash
sudo ./setup.rb --only security
sudo ./setup.rb --from matrix-bridge
sudo ./setup.rb --skip desktop --dry-run
```

## Development

```bash
git clone https://github.com/matronhq/dev-boxer.git
cd dev-boxer
cp config.example.yml config.yml   # edit to taste, or run ./bootstrap.sh for the wizard
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
