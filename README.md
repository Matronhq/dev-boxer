# Dev Boxer

Set up an Ubuntu 24.04 VPS as a remote Claude Code development environment — Matron chat stack, desktop GUI, security hardening, and your choice of Cloudflare Tunnel or plain IP + self-signed TLS — in one command.

## Part of the Matron ecosystem

| Project | Description |
|---------|-------------|
| [matron-apple](https://github.com/Matronhq/matron-apple) | Native iPhone and Mac apps |
| [matron-desktop](https://github.com/Matronhq/matron-desktop) | Desktop client for Windows and Linux |
| [matron-web](https://github.com/Matronhq/matron-web) | Browser client |
| [matron-journal](https://github.com/Matronhq/matron-journal) | Sync server for the Matron apps |
| [matron-bridge](https://github.com/Matronhq/matron-bridge) | Runs Claude Code / Codex sessions and connects them to the journal |
| **Dev Boxer** | One-command dev environment setup (this repo) |

## What you get

- **Claude Code** on a persistent remote server -- run long-lived agents without keeping your laptop open
- **Matron chat** -- talk to Claude Code from the Matron apps (iOS/desktop/web); this box runs [matron-bridge](https://github.com/Matronhq/matron-bridge) and, in bundled mode, its own [matron-journal](https://github.com/Matronhq/matron-journal) sync server
- **Two exposure modes** -- your own domain via Cloudflare Tunnel, or no domain at all via IP + self-signed TLS (see [docs/exposure-modes.md](docs/exposure-modes.md))
- **Desktop GUI** -- XFCE4 via XRDP through an SSH tunnel, no open ports
- **Security hardening** -- SSH key-only auth, custom port, UFW, fail2ban, unattended-upgrades
- **Cloudflare Tunnel** -- zero-trust HTTPS access with optional SSO
- **Dev tools** -- Docker, Node.js, Git, VS Code, Chrome, Firefox, GitHub CLI

## Prerequisites

- A fresh **Ubuntu 24.04** machine with sudo access. Anywhere works:
  - **Cheap VPS** (Hetzner / DigitalOcean / etc., ~$5/mo) — fastest path
  - **Spare desktop or laptop** at home (no monthly fee — see [No VPS?](#no-vps-use-spare-hardware))
  - **VM** (multipass, OrbStack, Hyper-V) on top of macOS or Windows
- **Cloudflare mode only:** a Cloudflare account with a domain, a zone DNS API token, and optionally a one-time account setup token
- **IP mode:** nothing extra — no domain needed
- SSH key pair

## Quick start

Run this on the VPS as root, or from a sudo-capable account:

```bash
curl -fsSL https://raw.githubusercontent.com/matronhq/dev-boxer/main/install.sh | sudo bash
```

> **Private forks:** if you fork this repo and keep your fork private, the raw installer URL above won't work unauthenticated. Use `bootstrap-vps.sh` from your fork instead — it installs `gh`, authenticates (interactively via `sudo bash bootstrap-vps.sh`, or unattended with `GH_TOKEN=... sudo -E bash bootstrap-vps.sh`), then clones and hands off to the same installer. It's idempotent to re-run.

### What happens next

The installer clones Dev Boxer to `/opt/dev-boxer`, prompts for the minimum required settings, writes `config.yml` and gitignored `secrets.yml`, then runs the full setup. Later `sudo ./setup.rb ...` reruns from that checkout, which will automatically fast-forward before continuing; set `DEV_BOXER_SKIP_AUTO_UPDATE=1` to disable that.

It asks for:

- Linux username, SSH public key, and SSH port
- GitHub fine-grained PAT (optional; lets the dev user clone private repos without an interactive `gh auth login` mid-setup)
- Base domain, e.g. `example.com`
- Whether Dev Boxer should manage Cloudflare DNS automatically, or whether you will create the required subdomains manually
- Cloudflare zone DNS API token if automatic DNS management is enabled
- Whether Dev Boxer should create the Cloudflare tunnel and Access app automatically, or whether you will create them manually
- One temporary Cloudflare account setup token if automatic tunnel and Access setup is enabled
- Where the journal lives: bundled on this box, or the wss:// URL of an existing one
- Exposure mode: cloudflare (domain) or ip (self-signed)

It derives `dev.<domain>`, `chat.<domain>`, `viewer.<domain>`, and `hello.<domain>` automatically in Cloudflare mode.

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

We recommend giving the dev box its own domain. Dev Boxer can then create new subdomains for projects you make, alongside `dev`, `chat`, `viewer`, and `hello`. Low-cost domains such as `.uk` or `.us` often start around `$5-6/year`, depending on current registrar pricing.

Create a zone-scoped DNS API token from [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) with:

- Zone permissions: `Zone:Read` and `DNS:Edit`
- Zone resource: only the domain you will use, e.g. `example.com`

For first-run Cloudflare setup, Dev Boxer uses two tokens:

- A zone-scoped DNS token with `Zone:Read` and `DNS:Edit`. This stays on the machine in `secrets.yml` so Dev Boxer can manage DNS records for `dev`, `chat`, `viewer`, `hello`, and new subdomains for projects you make. Scope it to this domain only, not all zones. If you prefer not to keep a DNS token on the box, choose manual DNS setup and create the required proxied CNAME records yourself. With manual DNS, Cloudflare Access setup is manual too because Dev Boxer cannot derive the account from the zone token.
- A temporary account setup token for initial tunnel and Access setup. It needs account permissions `Cloudflare One Connector: cloudflared: Edit`, `Access: Apps: Edit`, and `Access: Policies: Edit`. Dev Boxer stores it only in `secrets.yml`, uses it once, then wipes it after setup succeeds.

You can skip automatic tunnel and Access creation. Dev Boxer installs `cloudflared`, pauses, and prints the exact `cloudflared tunnel login` and `cloudflared tunnel create ...` commands to run in another root shell. It then asks for the resulting `TunnelID` and stores only that ID. If you skip automation, you can create the Cloudflare Access app manually later.

Dev Boxer creates proxied Cloudflare DNS records for all configured tunnel hostnames, including `chat.<domain>` (bundled journal mode only), using the zone DNS token.
If a matching CNAME already exists and points somewhere else, Dev Boxer asks before updating it. It never deletes DNS records.

### Cloudflare Access

The wizard can optionally create two Cloudflare Zero Trust Access self-hosted applications:

- Protected: the whole zone, `*.<domain>`. `dev`, `viewer`, `hello`, and any future subdomains you add under the zone are behind browser SSO by default.
- Bypass (no login): `chat.<domain>`, so Matron apps can reach the journal directly, plus `public-*.<domain>`, so any subdomain you deliberately name `public-…` is served without the SSO wall.

Automated Access setup derives the Cloudflare account from the zone and requires a one-time API token with `Access: Apps: Edit` and `Access: Policies: Edit`. Dev Boxer persists the resulting Access app ID and removes the setup token after a successful run.

See [docs/cloudflare-access.md](docs/cloudflare-access.md) for a manual walkthrough, and [docs/exposure-modes.md](docs/exposure-modes.md) for how `cloudflare` compares to `ip` mode.

## Modules

Setup runs 11 idempotent modules in order:

| # | Module | What it does |
|---|--------|--------------|
| 01 | `security`     | SSH hardening, UFW firewall, fail2ban, unattended-upgrades |
| 02 | `users`        | Linux user creation, SSH key, sudo, zsh |
| 03 | `desktop`      | Optional XFCE4 + XRDP + GUI apps (run `~/setup-desktop`) |
| 04 | `docker`       | Docker Engine + Compose |
| 05 | `dev-tools`    | Node.js 22, Git, Python, uv, GitHub CLI |
| 06 | `browsers`     | Chrome, Firefox, Xvfb |
| 07 | `claude`       | Claude Code CLI + plugins + Chrome DevTools MCP |
| 08 | `matron`       | matron-journal (bundled mode) + matron-bridge, agent enrollment |
| 09 | `exposure`     | Cloudflare Tunnel or IP + self-signed TLS, per `exposure.mode` |
| 10 | `desktop-apps` | lazydocker, CLAUDE.md, MOTD, optional desktop helper |
| 11 | `hello-world`  | `localhost:9820` tunnel smoke-test service |

Re-run a single module or resume from a failure:

```bash
sudo ./setup.rb --only security
sudo ./setup.rb --from matron
sudo ./setup.rb --skip desktop --dry-run
```

## Multiple boxes, one journal

Point more than one Dev Boxer install at the same matron-journal by setting `journal.mode: external` and `journal.url` (its `wss://` address) on every box after the first. Provide a pre-minted `journal.token_file` (mint one on the journal host: `matron-admin agent add <user> <name>`), or leave it unset to pair from the Matron app during setup instead. See [docs/exposure-modes.md](docs/exposure-modes.md) for how to reach that journal from the outside.

## Re-enrolling an agent

If the Matron app revokes this box's agent token, or the journal it talks to moves (a new `journal.url`, or switching bundled/external), re-run:

```bash
sudo bin/enroll
```

It skips the existing token, re-resolves one (local mint in bundled mode, app-approved pairing in external mode), writes it to `/etc/matron/agent-token`, and restarts `matron-bridge`. Pass `--config PATH` if `config.yml` isn't at the default location.

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

### Matron chat (chat with Claude)

1. Open the Matron app (iOS, desktop, or web)
2. Add the journal using the `wss://` URL from setup's connection summary (`Journal (Matron apps): ...` — e.g. `wss://chat.yourdomain.com/ws` in Cloudflare mode, `wss://<ip>:8443/ws` in IP mode)
3. Sign in: in bundled mode, either scan the QR printed at the end of setup (signs the first phone in directly) or use the journal username/password setup printed and stored in `secrets.yml`; external mode uses your existing account on that journal
4. Open a chat with the agent this box registered (matron-bridge) and start talking to Claude Code

## Upgrading from a Matrix-era install

Dev Boxer no longer installs Matrix anything. Config schema v2 removes the
`matrix:` section (setup fails with a pointer here if one is present) and
adds `journal:` + `exposure:`. There is no automatic migration: back up
`config.yml`/`secrets.yml`, re-run `sudo ./setup.rb --reconfigure`, and
answer the journal/exposure questions. Chat history does not carry over —
the journal is a new store.

## License

MIT
