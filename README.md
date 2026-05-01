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

- A fresh **Ubuntu 24.04** machine with sudo access. Anywhere works:
  - **Cheap VPS** (Hetzner / DigitalOcean / etc., ~$5/mo) — fastest path
  - **Spare desktop or laptop** at home (no monthly fee — see [No VPS?](#no-vps-use-spare-hardware))
  - **VM** (multipass, OrbStack, Hyper-V) on top of macOS or Windows
- Cloudflare account with a domain configured
- Cloudflare zone DNS API token
- Optional one-time Cloudflare account setup token for automated tunnel and Access setup
- SSH key pair

## Quick start

Run this on the VPS as root, or from a sudo-capable account:

```bash
curl -fsSL https://raw.githubusercontent.com/matronhq/dev-boxer/main/install.sh | sudo bash
```

The installer clones Dev Boxer to `/opt/dev-boxer`, prompts for the minimum required settings, writes `config.yml` and gitignored `secrets.yml`, then runs the full setup. Later `sudo ./setup.rb ...` reruns from that checkout automatically fast-forward before continuing; set `DEV_BOXER_SKIP_AUTO_UPDATE=1` to disable that.

It asks for:

- Linux username, SSH public key, and SSH port
- Base domain, e.g. `example.com`
- Whether Dev Boxer should manage Cloudflare DNS automatically, or whether you will create the required subdomains manually
- Cloudflare zone DNS API token if automatic DNS management is enabled
- Whether Dev Boxer should create the Cloudflare tunnel and Access app automatically, or whether you will create them manually
- One temporary Cloudflare account setup token if automatic tunnel and Access setup is enabled
- Matrix username

It derives `dev.<domain>`, `matrix.<domain>`, and `viewer.<domain>` automatically.

### No VPS? Use spare hardware

Cloudflare Tunnel handles "expose a home box to the internet" without port forwarding or a static IP, so an old Mac mini, a NUC, a retired laptop, or even a Raspberry Pi 4/5 (8 GB+) runs Dev Boxer just as well as a paid VPS — and you skip the $5–20/month rental fee.

Three on-ramps depending on what you have:

**PC / Intel Mac / mini PC.** Wipe and install [Ubuntu 24.04 Server](https://ubuntu.com/download/server) from a USB stick (use [Etcher](https://etcher.balena.io/) or `dd` to write the ISO). Boot, finish the installer, then run the Quick start curl command above.

**Apple Silicon Mac.** [Asahi Linux](https://asahilinux.org/) on bare metal is still rough; the easier path is a VM with [multipass](https://multipass.run/):

```bash
brew install --cask multipass
multipass launch 24.04 --name devbox --cpus 4 --memory 8G --disk 50G
multipass shell devbox
# then run the Quick start curl command inside the VM
```

**Windows desktop.** Either install [WSL2 + Ubuntu 24.04](https://learn.microsoft.com/en-us/windows/wsl/install) (caveats: WSL2's systemd support is limited and the XRDP desktop module won't work cleanly) or spin up a real Ubuntu VM via Hyper-V — Hyper-V is the cleaner option for the full feature set.

**Tradeoffs vs. a VPS.** The box has to stay on (keep it plugged in, disable sleep, set BIOS to wake-on-power-loss); flaky home internet means flaky access; and DDoS protection / uptime is on you. But $0/month and 16 GB RAM with a real CPU often beats $5/month and 2 GB RAM if you've got the hardware sitting around.

### Cloudflare setup

Register or transfer a domain with [Cloudflare Registrar](https://www.cloudflare.com/products/registrar/), or add an existing domain to Cloudflare DNS before running the installer.

We recommend giving the dev box its own domain. Dev Boxer can then create new subdomains for projects you make, alongside `dev`, `matrix`, and `viewer`. Low-cost domains such as `.uk` or `.us` often start around `$5-6/year`, depending on current registrar pricing.

Create a zone-scoped DNS API token from [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) with:

- Zone permissions: `Zone:Read` and `DNS:Edit`
- Zone resource: only the domain you will use, e.g. `example.com`

For first-run Cloudflare setup, Dev Boxer uses two tokens:

- A zone-scoped DNS token with `Zone:Read` and `DNS:Edit`. This stays on the machine in `secrets.yml` so Dev Boxer can manage DNS records for `dev`, `matrix`, `viewer`, and new subdomains for projects you make. Scope it to this domain only, not all zones. If you prefer not to keep a DNS token on the box, choose manual DNS setup and create the required proxied CNAME records yourself. With manual DNS, Cloudflare Access setup is manual too because Dev Boxer cannot derive the account from the zone token.
- A temporary account setup token for initial tunnel and Access setup. It needs account permissions `Cloudflare One Connector: cloudflared: Edit`, `Access: Apps: Edit`, and `Access: Policies: Edit`. Dev Boxer stores it only in `secrets.yml`, uses it once, then wipes it after setup succeeds.

You can skip automatic tunnel and Access creation. Dev Boxer installs `cloudflared`, pauses, and prints the exact `cloudflared tunnel create ...` command to run with your temporary token in another root shell. It then asks for the resulting `TunnelID` and stores only that ID. If you skip automation, you can create the Cloudflare Access app manually later.

Dev Boxer creates proxied Cloudflare DNS records for all configured tunnel hostnames, including `matrix.<domain>`, using the zone DNS token.
If a matching CNAME already exists and points somewhere else, Dev Boxer asks before updating it. It never deletes DNS records.

### Cloudflare Access

The wizard can optionally create a Cloudflare Zero Trust Access self-hosted application for the browser-facing hostnames:

- Protected: `dev.<domain>` and `viewer.<domain>`
- Excluded: `matrix.<domain>`, so Matrix clients can reach the homeserver API directly

Automated Access setup derives the Cloudflare account from the zone and requires a one-time API token with `Access: Apps: Edit` and `Access: Policies: Edit`. Dev Boxer persists the resulting Access app ID and removes the setup token after a successful run.

## Modules

Setup runs 11 idempotent modules in order:

| # | Module | What it does |
|---|--------|--------------|
| 01 | `security`     | SSH hardening, UFW firewall, fail2ban, unattended-upgrades |
| 02 | `users`        | Linux user creation, SSH key, sudo, zsh |
| 03 | `desktop`      | Optional XFCE4 + XRDP (run `~/setup-desktop`) |
| 04 | `docker`       | Docker Engine + Compose |
| 05 | `dev-tools`    | Node.js 22, Git, Python, uv, GitHub CLI |
| 06 | `browsers`     | Chrome, Firefox, Xvfb |
| 07 | `claude`       | Claude Code CLI + plugins + Chrome DevTools MCP |
| 08 | `matrix-bridge`| Matron Server + claude-matrix-bridge |
| 09 | `cloudflare`   | Cloudflare Tunnel, DNS routes, zone token deploy |
| 10 | `desktop-apps` | lazydocker, CLAUDE.md, MOTD, optional desktop helper |
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
