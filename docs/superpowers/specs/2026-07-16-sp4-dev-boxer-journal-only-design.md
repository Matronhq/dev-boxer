# SP4 — dev-boxer: journal-only provisioning, two exposure modes

> Status: **approved — planning**
> Date: 2026-07-16
> Repo: `dev-boxer` (this repo)
> Program: sub-project 4 of 5 in the Matron journal migration — see
> matron-bridge `docs/superpowers/specs/2026-07-14-matron-bridge-journal-only-design.md`

## Program context

The program moves the whole dev-box stack off Matrix and onto
[matron-journal](https://github.com/Matronhq/matron-journal). Status at the
time of writing:

| SP | Repo(s) | Summary | Status |
|----|---------|---------|--------|
| SP1 | matron-bridge | Retire Matrix; journal sole transport; rename | **done** |
| SP2 | matron-journal | Client API: agent pairing, device management, RPC, roster | **done** |
| SP3 | matron-bridge | Consume SP2 (new-chat primitives) | **done** |
| **SP4 (this doc)** | dev-boxer | Journal-only provisioning; two exposure modes; strip Matrix | — |
| SP5 | matron-apple, matron-web | Trust a pinned self-signed journal cert | downstream of SP4 |

Program-level decisions inherited here, not relitigated:

- **Matrix is fully retired** — not kept optional.
- **No cleartext for remote clients.** Client↔journal transport is always
  TLS: self-signed WSS (IP mode) or a real cert (Cloudflare mode). This is
  transport encryption, not E2E — a deliberate program decision.
- **Exposure is two co-equal choices** presented with tradeoffs; the
  Cloudflare quick tunnel stays rejected.

## Decisions made in this spec

- **`journal.mode: bundled | external`** — parity with the retired
  `matrix.mode`. `external` is how a fleet of boxes (or containers on a
  shared host) all speak to one central journal; `bundled` is the
  self-contained single-box product.
- **Agent enrollment supports both flows, resolved in a fixed order** —
  pre-provisioned token file first (the config-management path), then
  app-approved pairing (the human path). No matron-journal server changes:
  there is deliberately no remote admin/provisioning key (see the enrollment
  spec's security posture — matron-journal
  `docs/superpowers/specs/2026-07-15-app-managed-agent-enrollment-design.md`).
  Fleet operators mint per-agent tokens with `matron-admin agent add` on the
  journal host; humans approve pairs in the app (Settings → Devices → Add
  Agent).
- **Restructure now** rather than a minimal swap: purpose-named modules, an
  Exposure interface, and a wizard split into per-topic sections. The churn
  is forced anyway (the wizard's Matrix section dies and exposure forks), so
  the polish is cheapest here.

## Goal

`setup.rb` provisions an Ubuntu 24.04 box into a Claude Code dev environment
whose chat stack is matron-journal + matron-bridge, with **no Matrix
anywhere**, and with **no hard requirement to own a domain**: the wizard
offers IP + self-signed WSS as a co-equal alternative to a Cloudflare
domain. A `--non-interactive` mode lets configuration management drive the
whole run from a pre-seeded `config.yml`/`secrets.yml`.

## Architecture (end state)

Two orthogonal choices: where the journal lives (`journal.mode`) and how the
box is reached (`exposure.mode`).

```
bundled + ip                               external + cloudflare
────────────                               ─────────────────────
apps ──wss://<ip>:8443/ws──► nginx         apps ──wss://chat.example.com/ws──► central journal
      (self-signed, SAN=IP)    │                                                   ▲
                               ▼                                                   │ agent WS
                     matron-journal (127.0.0.1:9810)                         matron-bridge
                               ▲                                             (on this box)
                               │ ws:// loopback
                         matron-bridge
```

- matron-journal has no TLS of its own and always binds loopback plaintext;
  remote clients reach it only through the exposure layer. The co-located
  bridge connects over loopback `ws://`.
- All four `journal.mode` × `exposure.mode` combinations are valid. With an
  external journal, the exposure layer simply has no journal surface to
  publish (Cloudflare mode creates no journal hostname; IP mode opens no
  journal port).

## Config schema v2

The `matrix:` block is removed; `cloudflare:` nests under `exposure:`.
`user`, `ssh`, `desktop`, `docker`, and `claude` are unchanged. Loading a
config that still contains a `matrix:` key fails with a pointer to this
spec's breaking-change note.

```yaml
journal:
  mode: bundled            # bundled | external
  url: null                # external: wss://chat.example.com/ws
  token_file: null         # external: pre-provisioned agent token path
  ca_file: null            # external: pinned cert if that journal is self-signed
  agent_name: null         # default: hostname -s
  username: null           # bundled: journal user to create (default: user.name)

exposure:
  mode: cloudflare         # cloudflare | ip
  ip:
    address: null          # default: auto-detected server IP
    journal_port: 8443
    viewer_port: 8444
    hello_port: 8445
  cloudflare:              # today's cloudflare block, moved; s/matrix/journal/
    zone_name: example.com
    dns: { ... }           # unchanged
    tunnel:                # hostname_matrix -> hostname_journal
      hostname: dev.example.com
      hostname_journal: chat.example.com
      hostname_viewer: viewer.example.com
      hostname_hello: hello.example.com
      ...
    access: { ... }        # unchanged

hello_world:
  port: 9820               # moved off 9810 — that is matron-journal's default port
```

`secrets.yml` keeps `hmac_secret` (viewer links) and gains
`journal.user_password` in bundled mode. Agent tokens do **not** live in
secrets.yml — their home is `/etc/matron/agent-token` (0600), written by
whichever enrollment path runs; `journal.token_file` points elsewhere only
when an operator pre-placed a token. All add-bot blob keys are gone.

## Module 08 — `08_matron.rb`

One module owning the chat stack.

**Bundled mode:**

1. Clone `Matronhq/matron-journal` → `/opt/matron-journal`,
   `npm ci --omit=dev`, install its committed `deploy/matron-journal.service`
   with `MATRON_DB=/opt/matron-journal/data/matron.db`, loopback bind,
   port 9810. Wait for the loopback port to answer HTTP (any status —
   `/metrics` 401s without a token) before onboarding, mirroring today's
   `wait_for_url` pattern.
2. `matron-admin user add <journal.username>` with a generated password →
   `secrets.yml`, echoed once in the final summary (it is the app login).
3. Resolve the agent token via the enrollment object (which, in bundled
   mode, mints locally with `matron-admin agent add` — see below).
4. Install matron-bridge: clone `Matronhq/matron-bridge` → `~/matron-bridge`
   (this replaces the stale `yearbook/claude-matrix-bridge` clone URL — the
   org bug called out in the SP1 spec), `npm install`, render `.env`, install
   `matron-bridge.service`.

**External mode:** steps 1–3 are replaced by enrollment (below); step 4 is
identical with `JOURNAL_WS_URL=<journal.url>`. Before enrolling, probe the
journal's HTTPS base and fail fast with the probe result if unreachable —
never install a bridge that will crash-loop.

**Bridge `.env`** (keys per the SP1 config surface): `JOURNAL_WS_URL`
(loopback `ws://` in bundled mode, `journal.url` in external),
`JOURNAL_TOKEN_FILE=/etc/matron/agent-token` (or `journal.token_file`),
`HMAC_SECRET` (generated, memoised as today), `VIEWER_BASE_URL` from the
Exposure interface, `MATRON_BRIDGE_API_PORT` / `MATRON_VIEWER_PORT`,
`DEFAULT_WORKDIR`, and `NODE_EXTRA_CA_CERTS=<journal.ca_file>` when set.

## Enrollment — `lib/dev_boxer/journal_enrollment.rb` + `bin/enroll`

Resolution order:

1. `journal.token_file` configured → use it.
2. `/etc/matron/agent-token` already present → reuse (idempotent re-runs).
3. Bundled mode → mint locally via `matron-admin agent add`.
4. Interactive pairing: `POST /pair/start` → display the `XXXX-XXXX` code
   with "Settings → Devices → Add Agent" instructions → poll `POST
   /pair/claim` with the (never-displayed) `poll_token` until approved →
   write the returned token to `/etc/matron/agent-token`.
5. `--non-interactive` skips step 4: no token → exit 1 telling the operator
   to provide `journal.token_file` or run `bin/enroll`.

`bin/enroll` re-runs this resolution on an already-provisioned box (token
revoked, journal moved) and restarts the bridge on success. It replaces
`bin/add-bot` and the credentials-blob machinery outright.

Pairing edge behavior follows the server spec: codes live ~10 minutes in
memory; on expiry the enroller offers a fresh code; 429s surface as a
wait-and-retry message; Ctrl-C mid-poll leaves zero state box-side and zero
DB residue server-side (approved-but-unclaimed pairs vanish on TTL).

## Module 09 — `09_exposure.rb`

`Exposure.for(config)` returns a strategy exposing the same interface:
`setup!`, `journal_public_url`, `viewer_base_url`, `hello_url`,
`summary_lines`. Modules 08 and 11 and the `.env` writer consume the
interface; no `if ip_mode?` conditionals outside the strategies.

**`exposure/self_signed.rb` (IP mode, new):**

- Detect the public IP (reusing the detection added for the setup summary),
  or take `exposure.ip.address`.
- Generate one long-lived (10-year) self-signed cert with `SAN = IP:<ip>` →
  `/etc/matron/tls/{cert,key}.pem`. Idempotent: reuse when present; if the
  detected IP no longer matches the SAN, warn, regenerate, and remind that
  apps must re-accept the cert.
- Install nginx with three TLS server blocks on the same cert:
  `:8443` → journal loopback (WebSocket upgrade headers), `:8444` → viewer,
  `:8445` → hello-world. Journal block omitted in external mode.
- UFW allows exactly the ports in use.
- `summary_lines` prints the wss/https URLs **and the cert's SHA-256
  fingerprint** — what a person verifies against the app's untrusted-cert
  warning (SP5's counterpart).

**`exposure/cloudflare.rb`:** today's module 09 code moved intact —
tunnel/DNS/Access behavior unchanged. `hostname_matrix` becomes
`hostname_journal`, provisioned only when the journal is bundled.

## Wizard restructure + `--non-interactive`

`wizard.rb` (601 lines) becomes `lib/dev_boxer/wizard/` with per-topic
sections — server login, exposure, journal, claude, desktop — sharing the
prompt helpers. Each section declares the config keys it owns (requiredness
+ validation); `Config.validation_errors` derives from those declarations,
so the wizard and validation cannot drift.

- The **exposure** section asks the mode with tradeoff prose: IP mode is
  "quick and cheap, no domain, apps must accept a self-signed cert";
  Cloudflare mode is "your own domain, real trusted cert, box can mint
  subdomains".
- The **journal** section asks bundled vs external; external asks the URL
  and optional token-file path (pairing needs no wizard input — it runs at
  module time).
- `setup.rb --non-interactive`: no prompts at all. A pre-seeded config that
  fails validation exits 1 listing the missing keys; the "Reuse existing
  config?" confirmation auto-answers yes.

## Deletions, renames, docs

**Deleted** (with their tests and templates): `matrix_registration.rb`,
`add_bot.rb`, `credentials_blob.rb`, `bin/add-bot`, the matron-server
homeserver install inside module 08, the wizard's Matrix section including
the here/there add-bot blob import, `docs/adding-bots.md`, and every
`MATRIX_*` key in the bridge `.env` template.

**Renamed/moved:** `08_matrix_bridge.rb` → `08_matron.rb`;
`09_cloudflare.rb` → `09_exposure.rb` (+
`lib/dev_boxer/exposure/{cloudflare,self_signed}.rb`); wizard monolith →
`lib/dev_boxer/wizard/`; bridge dir `~/claude-matrix-bridge` →
`~/matron-bridge`; service `claude-matrix-bridge.service` →
`matron-bridge.service` (SP1's rename table); `hello_world.port` default
9810 → 9820.

**Docs:** README rewritten around the journal story — "Cloudflare account
with a domain" stops being a prerequisite; config.example.yml v2; a short
`docs/exposure-modes.md` tradeoff table; a breaking-change note for
Matrix-era installs (config v2 is not auto-migrated — the repo went public
days ago and the cutover runbook lives with matron-journal).
`docs/cloudflare-access.md` survives with the journal hostname substituted.

## Error handling

- **Pairing:** expiry → offer a fresh code; 429 → wait message; interrupt →
  clean state both sides.
- **Partial bundled onboarding:** if `user add` succeeded but the agent
  token was never written, re-runs detect the existing journal user and mint
  only the missing agent — the add-bot flow's "recoverable partial record"
  philosophy, much simpler without cross-signing.
- **IP change:** SAN mismatch → warn + regenerate + print the new
  fingerprint; journal and bridge are loopback-bound and unaffected.
- **External journal unreachable:** fail fast in module 08 with the probe
  result.
- **Token revoked from the app:** the bridge surfaces auth failure; the
  summary documents `bin/enroll` as the recovery path.

## Non-goals

- No app UI work (SP5 / user-owned), including the self-signed trust flow.
- No matron-journal or matron-bridge code changes — SP4 consumes what SP1–SP3
  shipped. In particular, no remote admin/provisioning endpoint.
- No migration tooling for Matrix-era boxes; the team-rollout runbook owns
  cutover, and config v2 is a documented breaking change.
- No ACME/Let's Encrypt in IP mode — a trusted cert is what Cloudflare mode
  is for.
- No BYOH, no dual-transport fallback, no E2E encryption.

## Verification

- **Unit (existing minitest conventions):** enrollment resolution order
  (token file > existing > local mint > pairing > non-interactive fail);
  Exposure interface answers per mode (URL construction, port defaults,
  external-journal omissions); wizard section key declarations ↔ validation
  parity; config v2 parsing including rejection of a `matrix:` block with a
  helpful error; cert/nginx command construction; module shape tests updated
  for the renames.
- **E2E smoke (scratch VPS):** fresh `bundled+ip` install → app connects to
  `wss://<ip>:8443/ws` past the self-signed warning → `new <dir>` spawns a
  session → a file-write posts a viewer link that works over `:8444`. Then
  `external+cloudflare` against a central journal, once with a
  pre-provisioned token file and once via pairing — the dress rehearsal for
  the downstream config-management work.
- **Idempotency:** a full second `setup.rb` run in both modes is a no-op.

## Risks / watch-items

- **SP5 dependency:** until the apps ship pinned-cert trust, `bundled+ip`
  boxes are only reachable from clients that can accept a self-signed cert.
  The exposure summary should say so plainly.
- **nginx is a new box dependency** (IP mode only). Kept to three small
  server blocks; no other module may grow nginx config without going through
  the Exposure interface.
- **Module 08's Matrix deletion is large** (~200 lines of onboarding).
  The module shape/idempotency tests and the E2E smoke are the safety net —
  same section-by-section discipline the SP1 spec used for `index.js`.
- **Port defaults:** 8443–8445 are opinionated but configurable; the 9810
  hello-world collision fix must land in the same change as the bundled
  journal install, or a re-run on an existing box breaks hello-world.
