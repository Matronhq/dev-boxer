# Dev Boxer

Set up your first Matron on a fresh Ubuntu 24.04 VPS: browser app, journal, bridge, file viewer and your choice of Claude Code or Codex. The guided starter path uses trusted HTTPS for a public IPv4 address, without a domain.

**Start with the [four-step guide](https://matron.chat/getting-started/).** Development desktops, Cloudflare and other advanced settings remain available.

## Part of the Matron ecosystem

| Project | Description |
|---------|-------------|
| [matron-apple](https://github.com/Matronhq/matron-apple) | Native iPhone and Mac apps |
| [matron-android](https://github.com/Matronhq/matron-android) | Native Android app |
| [matron-desktop](https://github.com/Matronhq/matron-desktop) | Desktop client for Windows and Linux |
| [matron-web](https://github.com/Matronhq/matron-web) | Browser client |
| [matron-journal](https://github.com/Matronhq/matron-journal) | Sync server for the Matron apps |
| [matron-bridge](https://github.com/Matronhq/matron-bridge) | Runs Claude Code / Codex sessions and connects them to the journal |
| **Dev Boxer** | One-command dev environment setup (this repo) |

## What you get

The starter profile installs one AI CLI, the browser app, journal, bridge and file viewer. It sets up SSH keys on port 22, a firewall, automatic OS updates and automatic HTTPS renewal. It omits desktops, Docker, browsers, coding plugins and local voice transcription.

Advanced developer setup retains those optional tools and the Cloudflare/self-signed exposure modes. See [exposure modes](docs/exposure-modes.md).

## Prerequisites

- A **fresh Ubuntu 24.04 x86-64 VPS** with root or sudo access, initially 2 CPUs / 4 GB RAM / 40 GB disk. This size has been exercised in a resource-limited container; a public VPS acceptance run is still required before release.
- A stable public **IPv4** address and inbound TCP ports **22, 80, 443, 8444**. Port 80 must remain reachable for certificate renewal.
- Your SSH **public** key, with its private key kept on your computer.
- A Claude Code or Codex account with CLI access. AI usage and the VPS are separate costs. The [buying guide](https://matron.chat/getting-started/#vps) compares budget providers, contract terms and setup fees.

For spare hardware, ARM64 or Cloudflare, choose Advanced and read the relevant guide below.

## Quick start

Run this on the VPS as root, or from a sudo-capable account:

```bash
curl -fsSL https://raw.githubusercontent.com/matronhq/dev-boxer/main/install.sh | sudo bash
```

> **Private forks:** if you fork this repo and keep your fork private, the raw installer URL above won't work unauthenticated. Use `bootstrap-vps.sh` from your fork instead — it installs `gh`, authenticates (interactively via `sudo bash bootstrap-vps.sh`, or unattended with `GH_TOKEN=... sudo -E bash bootstrap-vps.sh`), then clones and hands off to the same installer. It's idempotent to re-run.

### What happens next

The installer clones Dev Boxer to `/opt/dev-boxer`, saves your settings and private `secrets.yml`, then provisions the server. Choose:

1. **Set up my first Matron** — choose a sign-in name, an AI provider, the public IP and an SSH public key. Accept the certificate terms, then follow the AI sign-in link. Open the printed Matron URL and use the password or phone QR shown only in your terminal.
2. **Add a box to my Matron** — enter the existing HTTPS address, approve the pairing code in Matron, and sign into the AI provider on this box.
3. **Advanced developer setup** — the original wizard, including journal, domain/Cloudflare, desktop and developer configuration. It is also available with `sudo ./setup.rb --advanced` on a new checkout.

Start a chat in the prepared `work` folder. Ask for a reply and a notice in **For you**; check that both arrive. Setup's service checks do not substitute for this test.

Later SSH connections use `ssh dev@YOUR_VPS_IP` on the starter path. Test that login before closing the initial terminal. The agent's `dev` account has passwordless sudo: this is a general-purpose computer, not a restricted connector desk.

Repeating the install command uses the saved settings and installed component revisions. Use `sudo matron status`, `sudo matron login`, or `sudo matron link` for recovery. Make a backup before the explicit `sudo matron update --backup PATH` action. See [backup, restore and recovery](docs/starter-recovery.md).

The starter's component revisions and AI CLI versions are pinned in `components.json`. Ubuntu security updates remain automatic. The original advanced profile keeps its existing component update behavior; installer auto-pull is now opt-in with `DEV_BOXER_AUTO_UPDATE=1`.

### Advanced developer settings

The advanced wizard asks for a Linux username and SSH port, journal mode, exposure mode and Claude experience level. In Cloudflare mode it derives `dev`, `chat`, `viewer` and `hello` hostnames. The rest of this README describes those advanced options.

**Private repos:** the wizard doesn't ask for a GitHub token. To let the dev user clone private repos without an interactive login, add a fine-grained PAT to `secrets.yml` before running setup:

```yaml
github:
  token: github_pat_...
```

Use a fine-grained token with **Contents: Read** on the repositories the dev user clones, or a classic token with the `repo` and `read:org` scopes (`gh` refuses a classic token without `read:org`). Setup checks the token with GitHub before the first step. A refused token stops setup with the reason; in a terminal you can paste a replacement, or press Enter to go on without one and log in with a browser when a private clone needs it. A token that expires within a week gets a warning.

### No VPS? Use spare hardware

Cloudflare Tunnel handles "expose a home box to the internet" without port forwarding or a static IP, so an old Mac mini, a NUC, or a retired laptop runs Dev Boxer just as well as a paid VPS — and you skip the $5–20/month rental fee. Raspberry Pi 4/5 and other arm64 boards work too, with one caveat: Google Chrome has no arm64 Linux build, so Chrome and the Chrome DevTools MCP are skipped — Firefox and everything else install normally.

See [docs/self-hosting-hardware.md](docs/self-hosting-hardware.md) for install paths (bare metal, Apple Silicon via multipass, Windows) and the tradeoffs vs. a VPS.

### Cloudflare setup

Register or transfer a domain with [Cloudflare Registrar](https://www.cloudflare.com/products/registrar/), or add an existing domain to Cloudflare DNS before running the installer.

We recommend giving the dev box its own domain. Dev Boxer can then create new subdomains for projects you make, alongside `dev`, `chat`, `viewer`, and `hello`. Low-cost domains such as `.uk` or `.us` often start around `$5-6/year`, depending on current registrar pricing.

For first-run Cloudflare setup, Dev Boxer uses two API tokens (not the Global API Key), both created at [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens):

| Token | Permissions | Resources | Kept? |
| --- | --- | --- | --- |
| Zone DNS token | Zone → `Zone: Read`, Zone → `DNS: Edit` | Specific zone: only your domain, e.g. `example.com` | Yes, in `secrets.yml` and `~/.cloudflare/token`, so Dev Boxer and your tools can manage DNS records for `dev`, `chat`, `viewer`, `hello` and new project subdomains |
| One-time account setup token | Account → `Cloudflare One Connector: cloudflared: Edit` (`Cloudflare Tunnel: Edit` on older dashboards); plus Account → `Access: Apps: Edit` and `Access: Policies: Edit` if Dev Boxer creates the Access apps | The account that owns your domain | No: stored only in `secrets.yml` until the exposure step succeeds, then wiped |

If you prefer not to keep a DNS token on the box, choose manual DNS setup and create the required proxied CNAME records yourself. With manual DNS, Cloudflare Access setup is manual too because Dev Boxer cannot derive the account from the zone token.

Secret prompts echo a `*` for each character and then say how many characters arrived, so you can see a paste landed (and spot a double paste). Dev Boxer checks each token as soon as you enter it, and refuses it with the reason, before anything is set up:

- **Shape:** 40 characters, or a `cfut_`/`cfat_` prefix followed by about 48. A token pasted twice, a Global API Key, or a value with spaces is refused.
- **Live:** Cloudflare must report the token as active.
- **Access:** the zone token must see your zone and its DNS records. The setup token must see tunnels in the zone's account, and Access apps too when Dev Boxer creates them.

The exposure step checks any saved token again before it uses one. In an interactive run it asks for a new token when the saved one is refused, and saves the replacement.

You can skip automatic tunnel and Access creation. Dev Boxer installs `cloudflared`, pauses, and prints the exact `cloudflared tunnel login` and `cloudflared tunnel create ...` commands to run in another root shell. It then asks for the resulting `TunnelID` and stores only that ID. If you skip automation, you can create the Cloudflare Access app manually later.

Dev Boxer creates proxied Cloudflare DNS records for all configured tunnel hostnames, including `chat.<domain>` (bundled journal mode only), using the zone DNS token.
If a matching CNAME already exists and points somewhere else, Dev Boxer asks before updating it. It never deletes DNS records.

### Cloudflare Access

The wizard can optionally create two Cloudflare Zero Trust Access self-hosted applications:

- Protected: the whole zone, `*.<domain>`. `dev`, `viewer`, `hello`, and any future subdomains you add under the zone are behind browser SSO by default.
- Bypass (no login): `chat.<domain>`, so Matron apps can reach the journal directly, plus `public-*.<domain>`, so any subdomain you deliberately name `public-…` is served without the SSO wall.

Automated Access setup derives the Cloudflare account from the zone and reuses the one-time account setup token above. Dev Boxer persists the resulting Access app ID and removes the setup token after a successful run.

Access is part of Cloudflare Zero Trust, which must be switched on once per Cloudflare account in the dashboard. API tokens cannot do this. Open **Zero Trust** in the dashboard sidebar, pick a team name, and choose the **Free** plan. If it is not on yet, the wizard and the exposure step show these steps and wait for you, before any tunnel or DNS work.

#### If the exposure step stops

Cloudflare errors are printed as one message that says which token was refused, what it needs, and what to do next. Fix the cause, then resume:

```bash
sudo ./setup.rb --from exposure
```

In a terminal, if Cloudflare refuses a token part-way through (for example, it has `Read` where it needs `Edit`), Dev Boxer asks for a replacement on the spot, saves it and carries on.

Re-runs are safe. A tunnel or Access app that an earlier run created is found and reused, matching DNS records are left alone, and a refused saved token is asked for again.

See [docs/cloudflare-access.md](docs/cloudflare-access.md) for a manual walkthrough, and [docs/exposure-modes.md](docs/exposure-modes.md) for how `cloudflare` compares to `ip` mode.

## Modules

The starter runs only security, users, prerequisites, the chosen AI CLI, Matron, exposure and onboarding. Advanced setup uses the developer modules below.

| # | Module | What it does |
|---|--------|--------------|
| 01 | `security`     | SSH hardening, UFW firewall, fail2ban, unattended-upgrades, node_exporter on `127.0.0.1:9100` (`monitoring.node_exporter`); optional Postfix relay via Resend (`email.resend_api_key`) |
| 02 | `users`        | Linux user creation, SSH key, sudo, zsh |
| 03 | `desktop`      | Optional XFCE4 + XRDP + GUI apps (run `~/setup-desktop`) |
| 04 | `docker`       | Docker Engine + Compose |
| 05 | `dev-tools`    | Node.js 22, Git, ffmpeg, Python, uv, GitHub CLI |
| 06 | `browsers`     | Chrome, Firefox, Xvfb |
| 07 | `claude`       | Claude Code CLI + plugins + Chrome DevTools MCP + partial-clone git guard hook |
| 08 | `matron`       | matron-journal (bundled mode) + matron-bridge, agent enrollment, optional local voice-note transcription (whisper.cpp; set `bridge.voice_notes.enabled: false` when your journal transcribes voice notes, and setup removes it; see below) |
| 09 | `exposure`     | Trusted IP HTTPS for the starter; Cloudflare Tunnel or self-signed IP TLS in Advanced |
| 10 | `desktop-apps` | lazydocker, CLAUDE.md, MOTD, optional desktop helper |
| 11 | `hello-world`  | `localhost:9820` tunnel smoke-test service |

**Voice notes.** If the journal this box talks to transcribes voice notes itself (it has a cloud speech-to-text key, or its own whisper.cpp as a fallback), the bridge does not need a local whisper.cpp. Set `bridge.voice_notes.enabled: false`. Setup then skips the whisper.cpp build and removes any install an earlier run left in `~/.local/share/whisper-cpp`. Keep it `true` (the default) only where the journal does not transcribe, so the bridge can do it locally. ffmpeg is installed either way, because the bridge also uses it for video key frames.

If a module fails, setup prints which step failed, why, and the exact command to resume (`sudo ./setup.rb --from <module>`). Every module is idempotent. The full error with its backtrace is saved to `last-error.log` next to `config.yml`, for bug reports.

Before the first step, setup also checks, for the steps about to run:

- **Ports:** two services set to the same port (for example `ssh.port` on the file viewer's 9803), or a port another program already listens on, stop setup before anything changes. The fixed ports are 9802 (bridge API), 9803 (file viewer), 9810 (bundled journal) and 3389 (remote desktop, when enabled).
- **The GitHub token**, as above.
- **A pre-provisioned agent token file** (`journal.token_file`): the bridge runs as the dev user, so a file only root can read is handed to the dev user (mode 0600). If a directory above it is closed to the dev user, setup says so and stops.

The wizard checks answers when you enter them, so mistakes are refused straight away instead of failing later. It checks the SSH public key is one complete key line (a mangled key would lock you out once password login is off), the username and port, that an agent token file exists, the Access email list, and both Cloudflare tokens.

```bash
sudo ./setup.rb --only security
sudo ./setup.rb --from matron
sudo ./setup.rb --skip desktop --dry-run
```

To add more MCP servers to the box's Claude Code, see [docs/adding-mcp-servers.md](docs/adding-mcp-servers.md).

## Multiple boxes, one journal

For the starter path, choose **Add a box to my Matron** on the next VPS. In advanced configuration, point more than one install at the same matron-journal by setting `journal.mode: external` and `journal.url` (its `wss://` address) on every box after the first. Provide a pre-minted `journal.token_file` (mint one on the journal host: `matron-admin agent add <user> <name>`), or leave it unset to pair from the Matron app during setup instead. See [docs/exposure-modes.md](docs/exposure-modes.md) for how to reach that journal from the outside.

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
sudo ./setup.rb --wizard-only      # or hand-edit config.yml, starting from config.example.yml
rake test          # run the minitest suite
ruby setup.rb --dry-run --config config.example.yml --modules-dir lib/dev_boxer/modules
```

## Connecting

### RDP (desktop)

Requires the optional desktop module — run `~/setup-desktop` first. RDP is only accessible through an SSH tunnel:

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
