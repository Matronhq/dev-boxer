# SP4 — Journal-Only Provisioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild dev-boxer's chat stack on matron-journal + matron-bridge with no Matrix anywhere, and make IP + self-signed WSS a co-equal alternative to a Cloudflare domain.

**Architecture:** Two orthogonal config axes — `journal.mode: bundled|external` (where the journal lives) and `exposure.mode: cloudflare|ip` (how the box is reached). Module 08 (`matron`) owns the chat stack and delegates token acquisition to a `JournalEnrollment` object (token file → existing token → local mint → app pairing → non-interactive fail). Module 09 (`exposure`) delegates to an `Exposure` strategy (`Cloudflare` moved intact from today's module 09; `SelfSigned` new). The 601-line wizard splits into per-topic sections whose declarations drive `Config.validation_errors`.

**Tech Stack:** Ruby (stdlib only: yaml/json/net-http/openssl/optparse), minitest, systemd, nginx (IP mode only), openssl CLI, cloudflared.

**Spec:** `docs/superpowers/specs/2026-07-16-sp4-dev-boxer-journal-only-design.md` — read it before starting.

**Branch:** create `feat/sp4-journal-only` from `docs/sp4-journal-only-spec` (which contains the spec; do NOT branch from `main` — it lacks the spec):

```bash
cd ~/dev-boxer && git checkout docs/sp4-journal-only-spec && git pull --ff-only && git checkout -b feat/sp4-journal-only
```

## Global Constraints

- **No Matrix anywhere.** After Task 8 a case-insensitive grep for `matrix` in `lib/`, `bin/`, `templates/`, `setup.rb` must return nothing (`docs/superpowers/` history is exempt).
- **Public repo hygiene:** placeholders are `example.com` / `chat.example.com` — never internal hostnames.
- `hello_world.port` default is **9820** (9810 is matron-journal's default port).
- IP-mode port defaults: journal **8443**, viewer **8444**, hello **8445** (configurable via `exposure.ip.*`).
- Agent token home: `/etc/matron/agent-token`, mode 0600, owned by the dev user.
- Bridge `.env` keys (SP1 surface): `JOURNAL_WS_URL`, `JOURNAL_TOKEN_FILE`, `DEFAULT_WORKDIR`, `HMAC_SECRET`, `VIEWER_BASE_URL`, `MATRON_BRIDGE_API_PORT=9802`, `MATRON_VIEWER_PORT=9803`, plus `NODE_EXTRA_CA_CERTS` only when `journal.ca_file` is set. No `MATRIX_*` keys.
- Upstream repos (public, no auth needed): `https://github.com/Matronhq/matron-journal.git`, `https://github.com/Matronhq/matron-bridge.git`. No code changes to either — SP4 only consumes them.
- `matron-admin agent add <user> <name>` prints exactly: `agent <name> token: <token>\n(store in the bridge credentials file; it is not shown again)` — parse with `/token: (\S+)/`.
- Pairing endpoints (matron-journal, already shipped): `POST /pair/start {}` → `{pair_code, poll_token, expires_in}`; `POST /pair/claim {poll_token}` → `{status:'pending'}` or `{status:'approved', token, device_id}` (exactly once). Errors: `429 rate_limited`, `404 not_found` (expired/unknown). Codes live ~10 min in memory.
- The suite must be green after every task: `rake test` from the repo root (Ruby 3.2, no gems beyond rake/minitest).
- Config schema v2 is a **breaking change** — a `matrix:` key in config is rejected with a pointer to the README upgrade note. No auto-migration.

## File Structure (end state)

```
setup.rb                                   — modified (interactive plumbing)
bin/enroll                                 — NEW (replaces bin/add-bot)
lib/dev_boxer.rb                           — modified (requires)
lib/dev_boxer/config.rb                    — validation v2, derives from wizard sections
lib/dev_boxer/journal_enrollment.rb        — NEW
lib/dev_boxer/exposure.rb                  — NEW (factory + strategy base)
lib/dev_boxer/exposure/cloudflare.rb       — NEW (moved from modules/09_cloudflare.rb)
lib/dev_boxer/exposure/self_signed.rb      — NEW
lib/dev_boxer/module_base.rb               — interactive?, exposure helper
lib/dev_boxer/runner.rb                    — passes interactive:
lib/dev_boxer/wizard.rb                    — thin orchestrator
lib/dev_boxer/wizard/prompter.rb           — NEW (prompt helpers)
lib/dev_boxer/wizard/section.rb            — NEW (base class)
lib/dev_boxer/wizard/server_login_section.rb   — NEW
lib/dev_boxer/wizard/journal_section.rb        — NEW
lib/dev_boxer/wizard/exposure_section.rb       — NEW
lib/dev_boxer/wizard/claude_section.rb         — NEW
lib/dev_boxer/wizard/machine_defaults_section.rb — NEW
lib/dev_boxer/modules/08_matron.rb         — NEW (replaces 08_matrix_bridge.rb)
lib/dev_boxer/modules/09_exposure.rb       — NEW thin module (replaces 09_cloudflare.rb)
lib/dev_boxer/modules/10_desktop_apps.rb   — summary/MOTD updated
lib/dev_boxer/modules/11_hello_world.rb    — port 9820, Matron summary
templates/matron-bridge.env                — NEW
templates/matron-bridge.service            — NEW
templates/matron-viewer.service            — NEW
templates/mcp-config.json                  — path/env updated
templates/CLAUDE.md.template               — service names updated
docs/exposure-modes.md                     — NEW
README.md                                  — rewritten
DELETED: lib/dev_boxer/{matrix_registration,add_bot,credentials_blob}.rb, bin/add-bot,
  lib/dev_boxer/modules/{08_matrix_bridge,09_cloudflare}.rb, docs/adding-bots.md,
  templates/{matrix-bridge.env,claude-matrix-bridge.service,claude-matrix-file-viewer.service,
  docker-compose.matron-server.yml},
  test/{matrix_bridge,matrix_registration,add_bot,credentials_blob,cloudflare_module}_test.rb
```

---

### Task 1: Config schema v2 — validation + `matrix:` rejection

**Files:**
- Modify: `lib/dev_boxer/config.rb:52-98` (replace `validation_errors`), `lib/dev_boxer/config.rb:156-167` (replace `validate_cloudflare_access`)
- Test: `test/config_test.rb`

**Interfaces:**
- Produces: `Config.validation_errors(config)` with v2 semantics; `Config::MATRIX_RETIRED` message constant; private helpers `Config.validate_journal_block`, `Config.validate_exposure_block` (moved into wizard sections in Task 3). `Config.blank?`, `Config.validate_port`, `Config.validate_username` are unchanged and remain callable from outside (they are `def self.` methods; the `private` keyword does not apply to them).
- Consumes: nothing new.

- [ ] **Step 1: Rewrite the validation tests for schema v2**

In `test/config_test.rb`, replace the private `valid_public_config` helper (lines 278-306) with:

```ruby
  def valid_public_config(overrides = {})
    DevBoxer::Config.deep_merge({
      "user" => {
        "name" => "dev",
        "ssh_public_key" => "ssh-ed25519 AAAATEST dev@example.com",
        "rdp_password" => "rdp-secret",
      },
      "ssh" => { "port" => 2222 },
      "journal" => { "mode" => "bundled" },
      "exposure" => {
        "mode" => "cloudflare",
        "cloudflare" => {
          "zone_name" => "example.com",
          "api_token" => "admin-token",
          "zone_api_token" => "zone-token",
          "tunnel" => {
            "hostname" => "dev.example.com",
            "hostname_journal" => "chat.example.com",
            "hostname_viewer" => "viewer.example.com",
            "hostname_hello" => "hello.example.com",
            "create_manually" => false,
          },
        },
      },
      "hello_world" => { "port" => 9820 },
    }, overrides)
  end
```

Update the existing cloudflare-path tests (lines 157-245) mechanically: every test that digs/deletes under `hash["cloudflare"]` now operates on `hash["exposure"]["cloudflare"]`, and every expected error message gains the `exposure.cloudflare.` prefix (e.g. `"exposure.cloudflare.api_token is required until exposure.cloudflare.tunnel.id exists, unless exposure.cloudflare.tunnel.create_manually is true"`, `"exposure.cloudflare.zone_name is required"`, `"exposure.cloudflare.zone_api_token is required unless exposure.cloudflare.dns.create_manually is true"`, `"exposure.cloudflare.api_token is required until exposure.cloudflare.access.app_id exists"`).

Delete `test_validation_accepts_external_mode_with_imported_bot_creds` and `test_validation_accepts_bots_map_under_matrix` (lines 247-274).

Add these new tests:

```ruby
  def test_validation_rejects_retired_matrix_section
    hash = valid_public_config
    hash["matrix"] = { "mode" => "bundled" }

    errors = DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))

    assert_equal 1, errors.grep(/matrix/).length
    assert_match(/retired/, errors.grep(/matrix/).first)
    assert_match(/Upgrading from a Matrix-era install/, errors.grep(/matrix/).first)
  end

  def test_validation_requires_journal_mode
    hash = valid_public_config
    hash.delete("journal")

    errors = DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))

    assert_includes errors, "journal.mode is required"
  end

  def test_validation_rejects_unknown_journal_mode
    hash = valid_public_config("journal" => { "mode" => "sideways" })

    errors = DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))

    assert_includes errors, "journal.mode must be bundled or external"
  end

  def test_validation_requires_url_for_external_journal
    hash = valid_public_config("journal" => { "mode" => "external" })

    errors = DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))

    assert_includes errors, "journal.url is required when journal.mode is external"
  end

  def test_validation_rejects_non_ws_journal_url
    hash = valid_public_config("journal" => { "mode" => "external", "url" => "https://chat.example.com" })

    errors = DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))

    assert_includes errors, "journal.url must be a ws:// or wss:// URL"
  end

  def test_validation_external_journal_does_not_require_journal_hostname
    hash = valid_public_config("journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" })
    hash["exposure"]["cloudflare"]["tunnel"].delete("hostname_journal")

    assert_empty DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))
  end

  def test_validation_bundled_journal_requires_journal_hostname_in_cloudflare_mode
    hash = valid_public_config
    hash["exposure"]["cloudflare"]["tunnel"].delete("hostname_journal")

    errors = DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))

    assert_includes errors, "exposure.cloudflare.tunnel.hostname_journal is required when the journal is bundled"
  end

  def test_validation_requires_exposure_mode
    hash = valid_public_config
    hash.delete("exposure")

    errors = DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))

    assert_includes errors, "exposure.mode is required"
  end

  def test_validation_rejects_unknown_exposure_mode
    hash = valid_public_config
    hash["exposure"] = { "mode" => "carrier-pigeon" }

    errors = DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))

    assert_includes errors, "exposure.mode must be cloudflare or ip"
  end

  def test_validation_ip_mode_accepts_minimal_config
    hash = valid_public_config
    hash["exposure"] = { "mode" => "ip" }

    assert_empty DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))
  end

  def test_validation_ip_mode_rejects_bad_port
    hash = valid_public_config
    hash["exposure"] = { "mode" => "ip", "ip" => { "journal_port" => "loud" } }

    errors = DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))

    assert_includes errors, "exposure.ip.journal_port must be a number"
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `rake test TEST=test/config_test.rb`
Expected: FAIL — new tests error/fail against the v1 validation (missing `matrix.mode` requirements fire, new error strings absent).

- [ ] **Step 3: Implement v2 validation in config.rb**

Replace `validation_errors` (config.rb lines 52-98) and `validate_cloudflare_access` (lines 156-167) with:

```ruby
    MATRIX_RETIRED =
      "config contains a retired `matrix:` section — Matrix support was removed in the " \
      "journal-only migration (config schema v2). Replace it with `journal:` and `exposure:` " \
      "sections; see README \"Upgrading from a Matrix-era install\" and " \
      "docs/superpowers/specs/2026-07-16-sp4-dev-boxer-journal-only-design.md".freeze

    def self.validation_errors(config)
      hash = config.respond_to?(:to_h) ? config.to_h : config
      errors = []

      errors << MATRIX_RETIRED if hash.key?("matrix")

      %w[
        user.name
        user.ssh_public_key
        user.rdp_password
        ssh.port
        hello_world.port
      ].each do |path|
        value = hash.dig(*path.split("."))
        errors << "#{path} is required" if blank?(value)
      end

      validate_journal_block(errors, hash)
      validate_exposure_block(errors, hash)

      validate_port(errors, "ssh.port", hash.dig("ssh", "port"))
      validate_port(errors, "hello_world.port", hash.dig("hello_world", "port"))
      validate_username(errors, hash.dig("user", "name"))

      errors
    end

    # NOTE: validate_journal_block / validate_exposure_block move into the
    # wizard sections (JournalSection.validate / ExposureSection.validate)
    # when the wizard restructure lands — see the SP4 plan, Task 3.
    def self.validate_journal_block(errors, hash)
      mode = hash.dig("journal", "mode")
      if blank?(mode)
        errors << "journal.mode is required"
      elsif !%w[bundled external].include?(mode)
        errors << "journal.mode must be bundled or external"
      end
      return unless mode == "external"

      url = hash.dig("journal", "url")
      if blank?(url)
        errors << "journal.url is required when journal.mode is external"
      elsif !url.to_s.match?(%r{\Awss?://})
        errors << "journal.url must be a ws:// or wss:// URL"
      end
    end

    def self.validate_exposure_block(errors, hash)
      mode = hash.dig("exposure", "mode")
      if blank?(mode)
        errors << "exposure.mode is required"
      elsif !%w[cloudflare ip].include?(mode)
        errors << "exposure.mode must be cloudflare or ip"
      end
      validate_exposure_cloudflare(errors, hash) if mode == "cloudflare"
      validate_exposure_ip(errors, hash) if mode == "ip"
    end

    def self.validate_exposure_cloudflare(errors, hash)
      cf = hash.dig("exposure", "cloudflare") || {}

      errors << "exposure.cloudflare.zone_name is required" if blank?(cf["zone_name"])
      errors << "exposure.cloudflare.tunnel.hostname is required" if blank?(cf.dig("tunnel", "hostname"))
      errors << "exposure.cloudflare.tunnel.hostname_viewer is required" if blank?(cf.dig("tunnel", "hostname_viewer"))

      if hash.dig("journal", "mode") != "external" && blank?(cf.dig("tunnel", "hostname_journal"))
        errors << "exposure.cloudflare.tunnel.hostname_journal is required when the journal is bundled"
      end

      if blank?(cf["zone_api_token"]) && cf.dig("dns", "create_manually") != true
        errors << "exposure.cloudflare.zone_api_token is required unless exposure.cloudflare.dns.create_manually is true"
      end

      if blank?(cf.dig("tunnel", "id")) && blank?(cf["api_token"]) &&
          cf.dig("tunnel", "create_manually") != true
        errors << "exposure.cloudflare.api_token is required until exposure.cloudflare.tunnel.id exists, unless exposure.cloudflare.tunnel.create_manually is true"
      end

      validate_exposure_access(errors, cf)
    end

    def self.validate_exposure_access(errors, cf)
      access = cf["access"] || {}
      return unless access["enabled"] == true

      if blank?(access["app_id"]) && blank?(cf["api_token"])
        errors << "exposure.cloudflare.api_token is required until exposure.cloudflare.access.app_id exists"
      end

      allowed_emails = Array(access["allowed_emails"]).reject { |value| blank?(value) }
      allowed_domains = Array(access["allowed_email_domains"]).reject { |value| blank?(value) }
      if allowed_emails.empty? && allowed_domains.empty?
        errors << "exposure.cloudflare.access needs at least one allowed email or email domain"
      end
    end

    def self.validate_exposure_ip(errors, hash)
      ip = hash.dig("exposure", "ip") || {}
      %w[journal_port viewer_port hello_port].each do |key|
        value = ip[key]
        validate_port(errors, "exposure.ip.#{key}", value) unless value.nil?
      end
    end
```

Delete the old `validate_cloudflare_access` method.

- [ ] **Step 4: Run tests to verify they pass**

Run: `rake test TEST=test/config_test.rb`
Expected: PASS

- [ ] **Step 5: Run the full suite — expect known collateral failures, fix only config-schema ones**

Run: `rake test`
Expected: `test/wizard_test.rb` and `test/cli_test.rb` fail where they assert v1 validation behavior (the wizard still writes v1 configs). Fix ONLY assertions about `Config.validation_errors` semantics: in `test/wizard_test.rb`, the "reuse existing config" test seeds a complete config — update its fixture to the v2 shape from Step 1 so the reuse path still short-circuits. Do not touch wizard prompt-flow tests yet (Task 3 rewrites them); if any other wizard test fails solely because the wizard's output config no longer validates, mark it with `skip "rewritten in SP4 Task 3 (wizard restructure)"` rather than deleting.

Run: `rake test`
Expected: PASS (with the explicit skips visible in the output)

- [ ] **Step 6: Commit**

```bash
git add lib/dev_boxer/config.rb test/config_test.rb test/wizard_test.rb
git commit -m "config: schema v2 — journal/exposure blocks, reject retired matrix: section"
```

---

### Task 2: hello-world default port 9820 + config.example.yml v2

**Files:**
- Modify: `lib/dev_boxer/modules/11_hello_world.rb:18`, `lib/dev_boxer/modules/09_cloudflare.rb:479`, `lib/dev_boxer/wizard.rb:12`
- Rewrite: `config.example.yml`
- Test: `test/hello_world_test.rb`

**Interfaces:**
- Produces: hello-world default port constant behavior `config.hello_world&.port || 9820` (Tasks 4/6/7 rely on 9820).

- [ ] **Step 1: Write the failing test**

Append to `test/hello_world_test.rb` (running `mod.run` is off-limits here — it writes to `/opt` and `/etc` for real, so test the new `hello_port` reader instead):

```ruby
  def test_default_port_is_9820_to_avoid_journal_collision
    mod = build_module(output: StringIO.new)

    assert_equal 9820, mod.send(:hello_port)
  end

  def test_configured_port_overrides_default
    mod = build_module(output: StringIO.new, config_hash: {
      "user" => { "name" => "dev" },
      "hello_world" => { "port" => 12345 },
    })

    assert_equal 12345, mod.send(:hello_port)
  end
```

(Match `build_module`'s existing keyword signature in this test file's helper; extend it to accept `config_hash:` if it doesn't already.)

- [ ] **Step 2: Run to verify it fails**

Run: `rake test TEST=test/hello_world_test.rb`
Expected: FAIL — `hello_port` undefined.

- [ ] **Step 3: Change the three defaults**

- `lib/dev_boxer/modules/11_hello_world.rb`: add a private reader and use it in `run` (line 18):

```ruby
      def hello_port = config.hello_world&.port || 9820
```

and in `run`: `port = hello_port`.

- `lib/dev_boxer/modules/09_cloudflare.rb:479`: `def hello_world_port = config.hello_world&.port || 9820`
- `lib/dev_boxer/wizard.rb:12`: `DEFAULT_HELLO_WORLD_PORT = 9820`

- [ ] **Step 4: Rewrite config.example.yml**

Replace the whole file with:

```yaml
# Dev Boxer config — copy to config.yml and edit.

user:
  name: dev
  ssh_public_key: "ssh-ed25519 AAAAC3Nz... user@laptop"

ssh:
  port: 2222

desktop:
  enabled: false          # optional; run ~/setup-desktop after setup if you want XFCE/XRDP

docker:
  # Optional: relocate Docker + containerd storage to a separate volume.
  data_root: null         # e.g. "/secure/docker"
  containerd_root: null   # auto-derived from data_root if nil
  prune:
    interval: 2h
    keep_until: 4h

claude:
  experience_level: intermediate  # beginner | intermediate | advanced
  plugins:
    - superpowers
    - context7
    - serena

# Where the matron-journal server lives. The journal is the sync service the
# Matron apps (iOS/desktop/web) talk to; the bridge on this box publishes
# Claude's output into it.
journal:
  mode: bundled            # bundled (install it here) | external (use an existing one)
  url: null                # external only: wss://chat.example.com/ws
  token_file: null         # external only: path to a pre-provisioned agent token
                           #   (mint on the journal host: matron-admin agent add <user> <name>)
                           #   Leave null to pair from the Matron app during setup instead.
  ca_file: null            # external only: pinned cert when that journal is self-signed
  agent_name: null         # how this box appears in the app; default: hostname -s
  username: null           # bundled only: journal user to create; default: user.name
  # Bundled mode writes journal.username + journal.user_password to
  # ./secrets.yml (gitignored, mode 0600) — that password is your Matron
  # app login. The agent token lives in /etc/matron/agent-token, not here.

# How this box is reached from the internet.
exposure:
  mode: cloudflare         # cloudflare (own domain, trusted cert)
                           # | ip (no domain; self-signed cert apps must accept)
  ip:
    address: null          # default: auto-detected from `hostname -I`
    journal_port: 8443     # wss://<ip>:8443/ws (bundled journal only)
    viewer_port: 8444      # https://<ip>:8444 file viewer
    hello_port: 8445       # https://<ip>:8445 smoke test
  cloudflare:
    zone_name: example.com
    # zone_api_token is written to secrets.yml by the first-run wizard.
    # Optional api_token is used once for tunnel + Access setup, then wiped.
    dns:
      create_manually: false
    tunnel:
      hostname: dev.example.com
      hostname_journal: chat.example.com   # omitted when journal.mode is external
      hostname_viewer: viewer.example.com
      hostname_hello: hello.example.com
      create_manually: false
      config_managed_locally: false   # if true, don't overwrite /etc/cloudflared/config.yml
    access:
      enabled: true
      account_id: null              # optional override; otherwise derived from zone_name
      app_id: null                  # persisted after the protected Access app is created
      app_name: Dev Boxer
      # Two Access apps: "Dev Boxer" protects *.<zone_name> (allow policy);
      # "Dev Boxer Public" bypasses the journal + bypass_hostnames (bypass
      # policy) so Matron apps and public-* subdomains skip the login wall.
      bypass_app_id: null
      bypass_app_name: Dev Boxer Public
      bypass_hostnames:
        - public-*.example.com
      session_duration: 24h
      allowed_emails: []
      allowed_email_domains:
        - example.com

hello_world:
  port: 9820             # local "hello world" smoke-test service (9810 belongs to the journal)
```

- [ ] **Step 5: Run tests, commit**

Run: `rake test`
Expected: PASS

```bash
git add lib/dev_boxer/modules/11_hello_world.rb lib/dev_boxer/modules/09_cloudflare.rb lib/dev_boxer/wizard.rb config.example.yml test/hello_world_test.rb
git commit -m "hello-world: default port 9820 (9810 is matron-journal); config.example.yml v2"
```

---

### Task 3: Wizard restructure — sections + validation derivation

**Files:**
- Create: `lib/dev_boxer/wizard/prompter.rb`, `lib/dev_boxer/wizard/section.rb`, `lib/dev_boxer/wizard/server_login_section.rb`, `lib/dev_boxer/wizard/journal_section.rb`, `lib/dev_boxer/wizard/exposure_section.rb`, `lib/dev_boxer/wizard/claude_section.rb`, `lib/dev_boxer/wizard/machine_defaults_section.rb`
- Rewrite: `lib/dev_boxer/wizard.rb`
- Modify: `lib/dev_boxer/config.rb` (validation derives from sections)
- Test: rewrite `test/wizard_test.rb`; extend `test/cli_test.rb`

**Interfaces:**
- Produces: `Wizard::SECTIONS` (ordered array of Section classes); Section API — `TITLE` constant (nil suppresses the numbered header), `.owned_keys` (array of dotted path *prefixes*), `.validate(hash, errors)`, `#collect(so_far) → [config_fragment, secrets_fragment]`; `Prompter` with public `ask(label, default:, required:, secret:)`, `ask_integer`, `ask_choice(prompt, choices:, default:)`, `confirm(label, default:)`, `say(text)`, `section_header(title)`, `color(text, code)`.
- Consumes: Task 1's `Config.validate_journal_block` / `validate_exposure_*` bodies (moved into sections and deleted from config.rb), `Config.blank?`, `Config.validate_port`, `Config.validate_username`, `Config.deep_merge`.
- Wizard prompt order (deliberate deviation from the spec's listing order): **server login → journal → exposure → claude** — the exposure section needs `journal.mode` to decide whether to provision a journal hostname; note this in the commit message.

- [ ] **Step 1: Write the new wizard tests**

Replace `test/wizard_test.rb` entirely with:

```ruby
require_relative "test_helper"
require "tmpdir"

class WizardTest < Minitest::Test
  def run_wizard(answers, config_path:)
    input = StringIO.new(answers.join("\n") + "\n")
    output = StringIO.new
    result = DevBoxer::Wizard.run(config_path: config_path, input: input, output: output)
    [result, output.string]
  end

  CLOUDFLARE_BUNDLED_ANSWERS = [
    "alice",                                    # Linux username
    "ssh-ed25519 AAAATEST alice@example.com",   # SSH public key
    "2223",                                     # SSH port
    "bundled",                                  # journal location
    "alice",                                    # journal username
    "cloudflare",                               # exposure mode
    "example.com",                              # base domain
    "yes",                                      # manage DNS
    "zone-token",                               # zone DNS API token
    "yes",                                      # create tunnel + Access
    "alice@example.com, example.com",           # Access allowed
    "setup-token",                              # one-time setup token
    "intermediate",                             # Claude experience level
  ].freeze

  IP_EXTERNAL_ANSWERS = [
    "bob",
    "ssh-ed25519 AAAATEST bob@example.com",
    "2222",
    "external",                                 # journal location
    "wss://chat.example.com/ws",                # journal URL
    "",                                         # token file (skip -> pairing)
    "ip",                                       # exposure mode
    "",                                         # IP address (auto-detect)
    "advanced",
  ].freeze

  def test_cloudflare_bundled_run_writes_v2_config_that_validates
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      result, out = run_wizard(CLOUDFLARE_BUNDLED_ANSWERS, config_path: config_path)

      assert_equal :created, result
      config = YAML.safe_load_file(config_path)
      secrets = YAML.safe_load_file(File.join(dir, "secrets.yml"))

      refute config.key?("matrix")
      assert_equal "alice", config.dig("user", "name")
      assert_equal 2223, config.dig("ssh", "port")
      assert_equal "bundled", config.dig("journal", "mode")
      assert_equal "alice", config.dig("journal", "username")
      assert_equal "cloudflare", config.dig("exposure", "mode")
      assert_equal "example.com", config.dig("exposure", "cloudflare", "zone_name")
      assert_equal "dev.example.com", config.dig("exposure", "cloudflare", "tunnel", "hostname")
      assert_equal "chat.example.com", config.dig("exposure", "cloudflare", "tunnel", "hostname_journal")
      assert_equal "viewer.example.com", config.dig("exposure", "cloudflare", "tunnel", "hostname_viewer")
      assert_equal "hello.example.com", config.dig("exposure", "cloudflare", "tunnel", "hostname_hello")
      assert_equal ["alice@example.com"], config.dig("exposure", "cloudflare", "access", "allowed_emails")
      assert_equal 9820, config.dig("hello_world", "port")
      assert_equal false, config.dig("desktop", "enabled")
      assert_equal "intermediate", config.dig("claude", "experience_level")

      assert_equal "zone-token", secrets.dig("exposure", "cloudflare", "zone_api_token")
      assert_equal "setup-token", secrets.dig("exposure", "cloudflare", "api_token")
      assert secrets.dig("user", "rdp_password")
      assert_equal 0o600, File.stat(File.join(dir, "secrets.yml")).mode & 0o777

      merged = DevBoxer::Config.deep_merge(config, secrets)
      assert_empty DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(merged))

      assert_includes out, "== 1. Server login =="
      assert_includes out, "== 2. Journal =="
      assert_includes out, "== 3. Exposure =="
      assert_includes out, "== 4. Claude behavior =="
      refute_match(/matrix/i, out)
    end
  end

  def test_ip_external_run_writes_v2_config_that_validates
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      result, out = run_wizard(IP_EXTERNAL_ANSWERS, config_path: config_path)

      assert_equal :created, result
      config = YAML.safe_load_file(config_path)
      secrets = YAML.safe_load_file(File.join(dir, "secrets.yml"))

      assert_equal "external", config.dig("journal", "mode")
      assert_equal "wss://chat.example.com/ws", config.dig("journal", "url")
      assert_nil config.dig("journal", "token_file")
      assert_equal "ip", config.dig("exposure", "mode")
      assert_nil config.dig("exposure", "ip", "address")
      assert_equal 8443, config.dig("exposure", "ip", "journal_port")
      assert_equal 8444, config.dig("exposure", "ip", "viewer_port")
      assert_equal 8445, config.dig("exposure", "ip", "hello_port")
      assert_nil config.dig("exposure", "cloudflare")

      merged = DevBoxer::Config.deep_merge(config, secrets)
      assert_empty DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(merged))

      assert_includes out, "self-signed"
      refute_match(/matrix/i, out)
    end
  end

  def test_external_journal_url_is_revalidated_until_ws_scheme
    answers = IP_EXTERNAL_ANSWERS.dup
    answers[4] = "https://chat.example.com"          # wrong scheme first
    answers.insert(5, "wss://chat.example.com/ws")   # corrected on re-prompt
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      _result, out = run_wizard(answers, config_path: config_path)

      assert_includes out, "must start with ws:// or wss://"
      assert_equal "wss://chat.example.com/ws",
        YAML.safe_load_file(config_path).dig("journal", "url")
    end
  end

  def test_reuse_existing_complete_config
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      run_wizard(CLOUDFLARE_BUNDLED_ANSWERS, config_path: config_path)

      input = StringIO.new("y\n")
      output = StringIO.new
      result = DevBoxer::Wizard.run(config_path: config_path, input: input, output: output)

      assert_equal :reused, result
      assert_includes output.string, "Existing config.yml looks complete."
    end
  end

  # The drift guard: every leaf the wizard writes must fall under some
  # section's owned_keys prefix, so a key can't be prompted for without
  # also being owned (and therefore validated) by its section.
  def test_sections_own_every_key_the_wizard_writes
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      run_wizard(CLOUDFLARE_BUNDLED_ANSWERS, config_path: config_path)
      config = YAML.safe_load_file(config_path)
      secrets = YAML.safe_load_file(File.join(dir, "secrets.yml"))

      prefixes = DevBoxer::Wizard::SECTIONS.flat_map(&:owned_keys)
      (leaf_paths(config) + leaf_paths(secrets)).each do |path|
        assert prefixes.any? { |p| path == p || path.start_with?("#{p}.") },
          "#{path} is not covered by any section's owned_keys (#{prefixes.inspect})"
      end
    end
  end

  def test_sections_have_disjoint_ownership
    prefixes = DevBoxer::Wizard::SECTIONS.flat_map(&:owned_keys)
    assert_equal prefixes.uniq.sort, prefixes.sort
  end

  private

  def leaf_paths(hash, prefix = [])
    hash.flat_map do |key, value|
      value.is_a?(Hash) ? leaf_paths(value, prefix + [key]) : [(prefix + [key]).join(".")]
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `rake test TEST=test/wizard_test.rb`
Expected: FAIL (old wizard asks Matrix questions; `SECTIONS` undefined).

- [ ] **Step 3: Create the Prompter**

`lib/dev_boxer/wizard/prompter.rb` — move these methods **verbatim** from today's `wizard.rb` into a `Prompter` class, all public: `ask` (wizard.rb:396-408), `ask_integer` (:410-417), `ask_choice` (:212-219), `confirm` (:528-534), `prompt_for` (:536-544), `read_value` (:546-554), `section_header` (:385-389), `color` (:391-394). Add `say`:

```ruby
require "io/console"

module DevBoxer
  class Wizard
    # All terminal I/O for the wizard. Sections share one instance.
    class Prompter
      attr_reader :input, :output

      def initialize(input: $stdin, output: $stdout)
        @input = input
        @output = output
      end

      def say(text = "")
        output.puts(text)
      end

      # ... moved methods here, bodies unchanged ...
    end
  end
end
```

The moved `confirm` reads `input.gets` and prints to `output` — unchanged. `ask_choice` calls `ask` — unchanged.

- [ ] **Step 4: Create the Section base**

`lib/dev_boxer/wizard/section.rb`:

```ruby
module DevBoxer
  class Wizard
    # One wizard topic. Sections declare the config keys they own
    # (owned_keys + validate), so Config.validation_errors derives from
    # the same declarations that drive the prompts — they cannot drift.
    class Section
      TITLE = nil

      def self.title = self::TITLE

      # Dotted config-path prefixes this section writes. The wizard test
      # asserts every written leaf falls under some section's prefixes.
      def self.owned_keys = []

      # Append validation errors for the keys this section owns.
      def self.validate(hash, errors); end

      def initialize(prompter:, existing:)
        @prompter = prompter
        @existing = existing
      end

      # Returns [config_fragment, secrets_fragment]. `so_far` is the config
      # accumulated from earlier sections, for cross-section defaults.
      def collect(so_far)
        raise NotImplementedError, "#{self.class} must implement #collect"
      end

      private

      attr_reader :prompter, :existing

      def ask(...) = prompter.ask(...)
      def ask_integer(...) = prompter.ask_integer(...)
      def ask_choice(...) = prompter.ask_choice(...)
      def confirm(...) = prompter.confirm(...)
      def say(...) = prompter.say(...)
    end
  end
end
```

- [ ] **Step 5: Create ServerLoginSection**

`lib/dev_boxer/wizard/server_login_section.rb`:

```ruby
require "securerandom"
require_relative "section"

module DevBoxer
  class Wizard
    class ServerLoginSection < Section
      TITLE = "Server login".freeze
      DEFAULT_USERNAME = "dev".freeze
      DEFAULT_SSH_PORT = 2222

      def self.owned_keys = %w[user ssh]

      def self.validate(hash, errors)
        %w[user.name user.ssh_public_key user.rdp_password ssh.port].each do |path|
          errors << "#{path} is required" if Config.blank?(hash.dig(*path.split(".")))
        end
        Config.validate_port(errors, "ssh.port", hash.dig("ssh", "port"))
        Config.validate_username(errors, hash.dig("user", "name"))
      end

      def collect(_so_far)
        explain_linux_username
        username = ask("Linux username", default: existing.dig("user", "name") || default_username)
        explain_ssh_public_key
        ssh_key = ask("SSH public key", default: existing.dig("user", "ssh_public_key") || default_ssh_public_key)
        explain_ssh_port
        ssh_port = ask_integer("SSH port", default: existing.dig("ssh", "port") || DEFAULT_SSH_PORT)
        rdp_password = existing.dig("user", "rdp_password") || SecureRandom.urlsafe_base64(18)

        [
          { "user" => { "name" => username, "ssh_public_key" => ssh_key },
            "ssh" => { "port" => ssh_port } },
          { "user" => { "rdp_password" => rdp_password } },
        ]
      end

      private

      # explain_linux_username, explain_ssh_public_key, explain_ssh_port,
      # default_username, default_ssh_public_key — moved verbatim from
      # wizard.rb:419-433 and :574-584, with every `output.puts` -> `say`.
    end
  end
end
```

- [ ] **Step 6: Create JournalSection**

`lib/dev_boxer/wizard/journal_section.rb` — complete file:

```ruby
require_relative "section"

module DevBoxer
  class Wizard
    class JournalSection < Section
      TITLE = "Journal".freeze

      def self.owned_keys = %w[journal]

      def self.validate(hash, errors)
        mode = hash.dig("journal", "mode")
        if Config.blank?(mode)
          errors << "journal.mode is required"
        elsif !%w[bundled external].include?(mode)
          errors << "journal.mode must be bundled or external"
        end
        return unless mode == "external"

        url = hash.dig("journal", "url")
        if Config.blank?(url)
          errors << "journal.url is required when journal.mode is external"
        elsif !url.to_s.match?(%r{\Awss?://})
          errors << "journal.url must be a ws:// or wss:// URL"
        end
      end

      def collect(so_far)
        explain_journal_modes
        mode = ask_choice(
          "Journal location",
          choices: %w[bundled external],
          default: existing.dig("journal", "mode") || "bundled",
        )

        case mode
        when "bundled"
          explain_journal_username
          name = ask(
            "Journal username",
            default: existing.dig("journal", "username") || so_far.dig("user", "name"),
          )
          [{ "journal" => { "mode" => "bundled", "username" => name } }, {}]
        when "external"
          url = ask_journal_url
          token_file = ask(
            "Path to a pre-provisioned agent token file (Enter to skip and pair from the app)",
            default: existing.dig("journal", "token_file"),
            required: false,
          )
          [{ "journal" => { "mode" => "external", "url" => url, "token_file" => token_file }.compact }, {}]
        end
      end

      private

      def ask_journal_url
        loop do
          url = ask("Journal WebSocket URL (e.g. wss://chat.example.com/ws)",
            default: existing.dig("journal", "url"))
          return url if url.to_s.match?(%r{\Awss?://})

          say "The journal URL must start with ws:// or wss:// — it is the apps' WebSocket endpoint."
        end
      end

      def explain_journal_modes
        say
        say "Journal location:"
        say "Matron needs a matron-journal server — the sync service your phone, desktop, and browser apps talk to."
        say "Choose `bundled` for a self-contained box: Dev Boxer installs matron-journal here and creates your account on it."
        say "Choose `external` to connect this box to a journal you already run elsewhere (e.g. a shared team server). You'll need its wss:// URL, plus either a pre-provisioned agent token file or a person with the Matron app to approve a pairing code during setup."
        say
      end

      def explain_journal_username
        say
        say "Journal username:"
        say "The account you'll sign into the Matron apps with. Defaults to your Linux username, which is usually what you want."
        say "Dev Boxer creates it with a generated password and prints both at the end of setup."
        say
      end
    end
  end
end
```

- [ ] **Step 7: Create ExposureSection**

`lib/dev_boxer/wizard/exposure_section.rb`. New code shown in full; moved methods are listed with their exact source lines and required substitutions.

```ruby
require "uri"
require_relative "section"

module DevBoxer
  class Wizard
    class ExposureSection < Section
      TITLE = "Exposure".freeze

      def self.owned_keys = %w[exposure]

      def self.validate(hash, errors)
        mode = hash.dig("exposure", "mode")
        if Config.blank?(mode)
          errors << "exposure.mode is required"
        elsif !%w[cloudflare ip].include?(mode)
          errors << "exposure.mode must be cloudflare or ip"
        end
        validate_cloudflare(hash, errors) if mode == "cloudflare"
        validate_ip(hash, errors) if mode == "ip"
      end

      # validate_cloudflare, validate_access, validate_ip: move the bodies of
      # Config.validate_exposure_cloudflare / validate_exposure_access /
      # validate_exposure_ip (added in Task 1) here as class methods, renamed
      # exactly as above; change Config.blank? call sites accordingly
      # (they already call Config.blank? / Config.validate_port).

      def collect(so_far)
        explain_exposure_modes
        mode = ask_choice(
          "Exposure mode",
          choices: %w[cloudflare ip],
          default: existing.dig("exposure", "mode") || "cloudflare",
        )
        mode == "ip" ? collect_ip : collect_cloudflare(so_far)
      end

      private

      def collect_ip
        explain_ip_mode
        address = ask(
          "Public IP address (Enter to auto-detect at setup time)",
          default: existing.dig("exposure", "ip", "address"),
          required: false,
        )
        ip = {
          "address" => address,
          "journal_port" => existing.dig("exposure", "ip", "journal_port") || 8443,
          "viewer_port" => existing.dig("exposure", "ip", "viewer_port") || 8444,
          "hello_port" => existing.dig("exposure", "ip", "hello_port") || 8445,
        }
        [{ "exposure" => { "mode" => "ip", "ip" => ip } }, {}]
      end

      def collect_cloudflare(so_far)
        journal_bundled = so_far.dig("journal", "mode") != "external"

        explain_base_domain
        base_domain = normalize_domain(ask("Base domain", default: default_base_domain(existing)))
        manual_dns, zone_token = choose_dns_setup(existing, base_domain)

        tunnel_id = existing.dig("exposure", "cloudflare", "tunnel", "id")
        manual_tunnel, access_config = choose_cloudflare_setup(existing, tunnel_id, manual_dns: manual_dns)

        setup_token = nil
        if needs_setup_token?(tunnel_id: tunnel_id, manual_tunnel: manual_tunnel,
                              access_config: access_config, base_domain: base_domain,
                              journal_bundled: journal_bundled)
          explain_cloudflare_setup_token
          setup_token = ask(
            "One-time Cloudflare account setup token",
            default: existing.dig("exposure", "cloudflare", "api_token"),
            secret: true,
          )
        end

        config = { "exposure" => { "mode" => "cloudflare", "cloudflare" => {
          "zone_name" => base_domain,
          "dns" => { "create_manually" => manual_dns },
          "tunnel" => {
            "id" => tunnel_id,
            "hostname" => "dev.#{base_domain}",
            "hostname_journal" => (journal_bundled ? "chat.#{base_domain}" : nil),
            "hostname_viewer" => "viewer.#{base_domain}",
            "hostname_hello" => "hello.#{base_domain}",
            "create_manually" => manual_tunnel,
            "config_managed_locally" => false,
          }.compact,
          "access" => access_config,
        }.compact } }

        secret_fields = { "api_token" => setup_token, "zone_api_token" => zone_token }.compact
        secrets = secret_fields.empty? ? {} : { "exposure" => { "cloudflare" => secret_fields } }
        [config, secrets]
      end

      def explain_exposure_modes
        say
        say "Exposure mode:"
        say "How should this box be reachable from your phone/laptop?"
        say "`cloudflare` — your own domain behind a Cloudflare Tunnel: real trusted certificate, no open inbound ports, the box can mint project subdomains, optional SSO. Needs a Cloudflare-managed domain (a .uk/.us name is ~$5-6/year)."
        say "`ip` — quick and cheap: no domain needed, the box serves wss/https directly on its IP with a self-signed certificate. Your Matron apps must accept (pin) that certificate the first time, and there's no SSO in front."
        say
      end

      def explain_ip_mode
        say
        say "IP mode:"
        say "Dev Boxer generates a 10-year self-signed certificate for the server IP, terminates TLS with nginx, and opens only the ports it uses in the firewall."
        say "Setup prints the certificate's SHA-256 fingerprint — verify it against the warning your app shows on first connection."
        say
      end

      # Moved from wizard.rb with mechanical updates (old line refs):
      #   choose_dns_setup        (:258-271)  — unchanged except existing.dig
      #                             paths gain the "exposure" prefix:
      #                             existing.dig("cloudflare", "zone_api_token")
      #                             -> existing.dig("exposure", "cloudflare", "zone_api_token")
      #   choose_cloudflare_setup (:273-300)  — same prefix treatment
      #   build_access_config     (:302-323)  — same prefix treatment
      #   needs_setup_token?      (:325-344)  — gains journal_bundled: kwarg,
      #                             passes it to would_be_bypass_destinations
      #   would_be_bypass_destinations (:349-360) — signature becomes
      #     (access_config, base_domain, journal_bundled:) and the matrix line
      #     becomes:
      #       journal = (journal_bundled && !base_domain.to_s.empty?) ? "chat.#{base_domain}" : nil
      #       [journal, *configured].compact.reject { |h| h.to_s.empty? }.uniq
      #   default_access_allowed  (:362-367)  — prefix treatment
      #   parse_access_allowed    (:369-374)  — unchanged
      #   explain_base_domain     (:453-461)  — prose: "dev, matrix, viewer, and hello
      #                             subdomains" -> "dev, chat, viewer, and hello subdomains"
      #   explain_cloudflare_zone_token (:463-481) — prose: "dev, matrix, viewer, hello"
      #                             -> "dev, chat, viewer, hello"
      #   explain_manual_dns_setup (:483-490) — "matrix.#{base_domain}" -> "chat.#{base_domain}"
      #   explain_manual_access_after_manual_dns (:492-498) — "matrix and `public-*`"
      #                             -> "the journal and `public-*`" (both mentions)
      #   explain_cloudflare_automation (:500-506) — "matrix and any `public-`-prefixed"
      #                             -> "the journal and any `public-`-prefixed"
      #   explain_manual_cloudflare_setup (:508-514) — same journal substitution
      #   explain_cloudflare_setup_token (:516-526) — unchanged
      #   normalize_domain        (:556-567)  — unchanged
      #   default_base_domain     (:569-572)  — path prefix:
      #     existing.dig("exposure", "cloudflare", "tunnel", "hostname")
      # All `output.puts` -> `say`; all `output.print`/`input.gets` inside
      # choose_* go through prompter's ask/confirm as they already do.
    end
  end
end
```

- [ ] **Step 8: Create ClaudeSection and MachineDefaultsSection**

`lib/dev_boxer/wizard/claude_section.rb`:

```ruby
require_relative "section"

module DevBoxer
  class Wizard
    class ClaudeSection < Section
      TITLE = "Claude behavior".freeze
      DEFAULT_EXPERIENCE_LEVEL = "intermediate".freeze
      EXPERIENCE_LEVELS = %w[beginner intermediate advanced].freeze

      def self.owned_keys = %w[claude]

      def collect(_so_far)
        explain_claude_experience_level
        config = { "experience_level" => ask_experience_level }
        plugins = existing.dig("claude", "plugins")
        config["plugins"] = plugins unless plugins.nil?
        [{ "claude" => config }, {}]
      end

      private

      # explain_claude_experience_level (wizard.rb:191-199) and
      # ask_experience_level (:201-210) moved verbatim; output.puts -> say,
      # and ask_experience_level's `existing` arg becomes the section's
      # existing reader.
    end
  end
end
```

`lib/dev_boxer/wizard/machine_defaults_section.rb`:

```ruby
require_relative "section"

module DevBoxer
  class Wizard
    # Keys the wizard writes without prompting: desktop/docker defaults and
    # the hello-world smoke-test port. TITLE is nil — no numbered header.
    class MachineDefaultsSection < Section
      DEFAULT_HELLO_WORLD_PORT = 9820

      def self.owned_keys = %w[desktop docker hello_world]

      def self.validate(hash, errors)
        errors << "hello_world.port is required" if Config.blank?(hash.dig("hello_world", "port"))
        Config.validate_port(errors, "hello_world.port", hash.dig("hello_world", "port"))
      end

      def collect(_so_far)
        [{
          "desktop" => { "enabled" => false },
          "docker" => {
            "data_root" => nil,
            "containerd_root" => nil,
            "prune" => { "interval" => "2h", "keep_until" => "4h" },
          },
          "hello_world" => {
            "port" => existing.dig("hello_world", "port") || DEFAULT_HELLO_WORLD_PORT,
          },
        }, {}]
      end
    end
  end
end
```

- [ ] **Step 9: Rewrite the Wizard orchestrator**

Replace `lib/dev_boxer/wizard.rb` with:

```ruby
require "fileutils"
require "yaml"
require_relative "wizard/prompter"
require_relative "wizard/section"
require_relative "wizard/server_login_section"
require_relative "wizard/journal_section"
require_relative "wizard/exposure_section"
require_relative "wizard/claude_section"
require_relative "wizard/machine_defaults_section"

module DevBoxer
  class Wizard
    # Prompt order: journal before exposure, because the exposure section
    # provisions a journal hostname only when the journal is bundled.
    SECTIONS = [
      ServerLoginSection,
      JournalSection,
      ExposureSection,
      ClaudeSection,
      MachineDefaultsSection,
    ].freeze

    def self.run(config_path:, input: $stdin, output: $stdout, force: false)
      new(config_path: config_path, input: input, output: output).run(force: force)
    end

    def initialize(config_path:, input: $stdin, output: $stdout)
      @config_path = config_path
      @secrets_path = Config.secrets_path_for(config_path)
      @prompter = Prompter.new(input: input, output: output)
    end

    def run(force: false)
      existing_config = load_yaml(config_path)
      existing_secrets = load_yaml(secrets_path)
      existing = Config.deep_merge(existing_config, existing_secrets)

      if File.exist?(config_path) && !force && Config.validation_errors(Config.from_hash(existing)).empty?
        prompter.say "Existing config.yml looks complete."
        return :reused if prompter.confirm("Reuse existing config?", default: true)
      end

      print_welcome

      config, secrets = collect_all(existing)
      write_yaml(config_path, config, mode: 0o644)
      write_yaml(secrets_path, secrets, mode: 0o600)

      prompter.say
      prompter.say "Wrote #{config_path}"
      prompter.say "Wrote #{secrets_path} (mode 0600)"
      :created
    end

    private

    attr_reader :config_path, :secrets_path, :prompter

    def collect_all(existing)
      config = {}
      secrets = {}
      number = 0
      SECTIONS.each do |klass|
        if klass.title
          number += 1
          prompter.section_header("#{number}. #{klass.title}")
        end
        fragment, secret_fragment = klass.new(prompter: prompter, existing: existing).collect(config)
        config = Config.deep_merge(config, fragment || {})
        secrets = Config.deep_merge(secrets, secret_fragment || {})
      end
      [config, secrets]
    end

    # print_welcome (wizard.rb:376-383), load_yaml (:586-588), write_yaml
    # (:590-599) move here verbatim; print_welcome uses prompter.say and
    # prompter.color.
  end
end
```

Delete from the old wizard.rb everything not listed as moved (the Matrix section, `ask_blob_until_valid`, `explain_add_bot_blob`, `explain_matrix_location`, `explain_matrix_username`, `explain_external_matrix_username`, the `require "dev_boxer/credentials_blob"` line, `DEFAULT_HELLO_WORLD_PORT`/`DEFAULT_USERNAME`/`DEFAULT_SSH_PORT`/`EXPERIENCE_LEVELS` constants now living in sections).

- [ ] **Step 10: Point Config.validation_errors at the sections**

In `lib/dev_boxer/config.rb`, replace `validation_errors` and delete `validate_journal_block`, `validate_exposure_block`, `validate_exposure_cloudflare`, `validate_exposure_access`, `validate_exposure_ip` (their bodies now live in JournalSection/ExposureSection/ServerLoginSection/MachineDefaultsSection):

```ruby
    def self.validation_errors(config)
      hash = config.respond_to?(:to_h) ? config.to_h : config
      errors = []
      errors << MATRIX_RETIRED if hash.key?("matrix")
      wizard_sections.each { |section| section.validate(hash, errors) }
      errors
    end

    # Lazy so requiring config.rb alone (load order in dev_boxer.rb) does
    # not pull the wizard in a cycle.
    def self.wizard_sections
      require "dev_boxer/wizard"
      Wizard::SECTIONS
    end
```

Remove the now-duplicated `user.*`/`ssh.port`/`hello_world.port` presence + port + username checks from config.rb (they live in ServerLoginSection/MachineDefaultsSection). Keep `blank?`, `validate_port`, `validate_username` in Config — sections call them.

- [ ] **Step 11: Extend cli_test for non-interactive runs**

Append to `test/cli_test.rb`:

```ruby
  def test_non_interactive_with_complete_config_runs_without_prompts
    Dir.mktmpdir do |dir|
      cfg = File.join(dir, "config.yml")
      File.write(cfg, {
        "user" => { "name" => "dev", "ssh_public_key" => "ssh-ed25519 AAAATEST t@e", "rdp_password" => "x" },
        "ssh" => { "port" => 2222 },
        "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" },
        "exposure" => { "mode" => "ip" },
        "hello_world" => { "port" => 9820 },
      }.to_yaml)
      mods_dir = File.join(dir, "modules")
      Dir.mkdir(mods_dir)

      out, err, status = run_setup("--non-interactive", "--config", cfg, "--modules-dir", mods_dir)
      assert status.success?, "expected exit 0\nstdout: #{out}\nstderr: #{err}"
    end
  end

  def test_non_interactive_with_incomplete_config_exits_2_listing_missing_keys
    Dir.mktmpdir do |dir|
      cfg = File.join(dir, "config.yml")
      File.write(cfg, "user:\n  name: dev\n")
      mods_dir = File.join(dir, "modules")
      Dir.mkdir(mods_dir)

      _out, err, status = run_setup("--non-interactive", "--config", cfg, "--modules-dir", mods_dir)
      assert_equal 2, status.exitstatus
      assert_match(/journal\.mode is required/, err)
      assert_match(/exposure\.mode is required/, err)
    end
  end
```

- [ ] **Step 12: Run the wizard + cli + config tests, then the full suite**

Run: `rake test TEST=test/wizard_test.rb && rake test TEST=test/cli_test.rb && rake test TEST=test/config_test.rb`
Expected: PASS. Remove any `skip "rewritten in SP4 Task 3"` markers added in Task 1.

Run: `rake test`
Expected: PASS.

- [ ] **Step 13: Commit**

```bash
git add lib/dev_boxer/wizard.rb lib/dev_boxer/wizard/ lib/dev_boxer/config.rb test/wizard_test.rb test/cli_test.rb
git commit -m "wizard: split into per-topic sections; journal+exposure prompts; validation derives from section declarations

Prompt order is server login -> journal -> exposure (journal first because
the exposure section only provisions a journal hostname when bundled)."
```

---

### Task 4: Exposure interface — Cloudflare (moved) + SelfSigned (new) strategies

**Files:**
- Create: `lib/dev_boxer/exposure.rb`, `lib/dev_boxer/exposure/cloudflare.rb`, `lib/dev_boxer/exposure/self_signed.rb`, `lib/dev_boxer/modules/09_exposure.rb`
- Delete: `lib/dev_boxer/modules/09_cloudflare.rb`
- Modify: `lib/dev_boxer.rb`, `lib/dev_boxer/module_base.rb`, `lib/dev_boxer/runner.rb`, `setup.rb`, `templates/cloudflared-config.yml` (no change needed — verify), `test/modules_shape_test.rb:57`
- Test: create `test/exposure_self_signed_test.rb`; rename+adapt `test/cloudflare_module_test.rb` → `test/exposure_cloudflare_test.rb`

**Interfaces:**
- Produces:
  - `DevBoxer::Exposure.for(config:, shell:, log:, templates_dir: nil, config_path: nil, secrets_path: nil, interactive: true)` → strategy instance.
  - Strategy interface: `setup!` (idempotent, does all system work), `journal_public_url` (String — `wss://…/ws`, or `config.journal.url` pass-through when external), `viewer_base_url` (String, `https://…`, no trailing slash), `hello_url` (String), `summary_lines` (Array of Strings). All URL methods are pure config reads except SelfSigned's IP auto-detection (one `hostname -I` shell call, memoised).
  - `ModuleBase#interactive?` and `ModuleBase#exposure` (private helper, memoised strategy).
  - `Runner.new(..., interactive: true)`; `setup.rb` passes `interactive: interactive && !options[:non_interactive]`.
- Consumes: Task 2's hello default (9820).

- [ ] **Step 1: Write the SelfSigned tests**

Create `test/exposure_self_signed_test.rb`:

```ruby
require_relative "test_helper"
require "tmpdir"
require_relative "support/module_test_case"

class ExposureSelfSignedTest < DevBoxer::Testing::ModuleTestCase
  def build_strategy(config_hash = {})
    base = {
      "user" => { "name" => "dev" },
      "journal" => { "mode" => "bundled" },
      "exposure" => { "mode" => "ip" },
      "hello_world" => { "port" => 9820 },
    }
    DevBoxer::Exposure::SelfSigned.new(
      config: DevBoxer::Config.from_hash(DevBoxer::Config.deep_merge(base, config_hash)),
      shell: @shell,
      log: @log,
    )
  end

  def test_urls_use_configured_address_and_default_ports
    strategy = build_strategy("exposure" => { "ip" => { "address" => "203.0.113.7" } })

    assert_equal "wss://203.0.113.7:8443/ws", strategy.journal_public_url
    assert_equal "https://203.0.113.7:8444", strategy.viewer_base_url
    assert_equal "https://203.0.113.7:8445", strategy.hello_url
  end

  def test_urls_respect_configured_ports
    strategy = build_strategy("exposure" => { "ip" => {
      "address" => "203.0.113.7", "journal_port" => 10443, "viewer_port" => 10444, "hello_port" => 10445,
    } })

    assert_equal "wss://203.0.113.7:10443/ws", strategy.journal_public_url
    assert_equal "https://203.0.113.7:10444", strategy.viewer_base_url
    assert_equal "https://203.0.113.7:10445", strategy.hello_url
  end

  def test_ip_detected_from_hostname_when_not_configured
    respond("hostname -I", success: true, stdout: "198.51.100.5 fe80::1\n")
    strategy = build_strategy

    assert_equal "https://198.51.100.5:8444", strategy.viewer_base_url
  end

  def test_ip_detection_failure_raises_with_remedy
    respond("hostname -I", success: false, stderr: "boom")
    strategy = build_strategy

    error = assert_raises(RuntimeError) { strategy.viewer_base_url }
    assert_match(/exposure\.ip\.address/, error.message)
  end

  def test_external_journal_passes_url_through_and_omits_journal_surface
    strategy = build_strategy(
      "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" },
      "exposure" => { "ip" => { "address" => "203.0.113.7" } },
    )

    assert_equal "wss://chat.example.com/ws", strategy.journal_public_url
    refute_includes strategy.nginx_config, "listen 8443"
    refute_includes strategy.firewall_ports.map(&:to_s), "8443"
  end

  def test_nginx_config_has_three_tls_blocks_with_websocket_upgrade
    strategy = build_strategy("exposure" => { "ip" => { "address" => "203.0.113.7" } })
    conf = strategy.nginx_config

    assert_includes conf, "listen 8443 ssl;"
    assert_includes conf, "listen 8444 ssl;"
    assert_includes conf, "listen 8445 ssl;"
    assert_includes conf, "proxy_pass http://127.0.0.1:9810;"
    assert_includes conf, "proxy_pass http://127.0.0.1:9803;"
    assert_includes conf, "proxy_pass http://127.0.0.1:9820;"
    assert_includes conf, "proxy_set_header Upgrade $http_upgrade;"
    assert_includes conf, "ssl_certificate /etc/matron/tls/cert.pem;"
    assert_includes conf, "ssl_certificate_key /etc/matron/tls/key.pem;"
  end

  def test_setup_generates_cert_with_ip_san_when_missing
    Dir.mktmpdir do |dir|
      respond_default(success: true)
      strategy = build_strategy("exposure" => { "ip" => { "address" => "203.0.113.7" } })

      strategy.stub(:tls_dir, dir) do
        strategy.stub(:nginx_site_path, File.join(dir, "matron")) do
          strategy.setup!
        end
      end

      assert_recorded(/openssl req -x509 .*subjectAltName=IP:203\.0\.113\.7/)
      assert_recorded(/ufw allow 8443\/tcp/)
      assert_recorded(/ufw allow 8444\/tcp/)
      assert_recorded(/ufw allow 8445\/tcp/)
      assert_recorded(/nginx -t/)
    end
  end

  def test_setup_skips_cert_generation_when_san_matches
    Dir.mktmpdir do |dir|
      respond_default(success: true)
      FileUtils.touch(File.join(dir, "cert.pem"))
      FileUtils.touch(File.join(dir, "key.pem"))
      respond("openssl x509 -in #{File.join(dir, 'cert.pem')} -noout -ext subjectAltName",
        success: true, stdout: "X509v3 Subject Alternative Name:\n    IP Address:203.0.113.7\n")
      strategy = build_strategy("exposure" => { "ip" => { "address" => "203.0.113.7" } })

      strategy.stub(:tls_dir, dir) do
        strategy.stub(:nginx_site_path, File.join(dir, "matron")) do
          strategy.setup!
        end
      end

      refute_recorded(/openssl req -x509/)
    end
  end

  def test_summary_lines_include_fingerprint_and_self_signed_warning
    Dir.mktmpdir do |dir|
      FileUtils.touch(File.join(dir, "cert.pem"))
      respond("openssl x509 -in #{File.join(dir, 'cert.pem')} -noout -fingerprint -sha256",
        success: true, stdout: "sha256 Fingerprint=AA:BB:CC\n")
      strategy = build_strategy("exposure" => { "ip" => { "address" => "203.0.113.7" } })

      lines = strategy.stub(:tls_dir, dir) { strategy.summary_lines }

      assert(lines.any? { |l| l.include?("AA:BB:CC") })
      assert(lines.any? { |l| l.include?("wss://203.0.113.7:8443/ws") })
      assert(lines.any? { |l| l =~ /self-signed/i })
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `rake test TEST=test/exposure_self_signed_test.rb`
Expected: FAIL — `DevBoxer::Exposure` undefined.

- [ ] **Step 3: Create the factory + strategy base**

`lib/dev_boxer/exposure.rb` (NOTE: the strategy requires sit at the BOTTOM of this file — `Cloudflare < Base` and `SelfSigned < Base` need `Base` defined first):

```ruby
module DevBoxer
  # How the box is reached from the internet. Strategies share one
  # interface; modules 08/10/11 consume it and MUST NOT branch on the
  # exposure mode themselves.
  module Exposure
    def self.for(config:, shell:, log:, templates_dir: nil, config_path: nil, secrets_path: nil, interactive: true)
      klass =
        case config.exposure&.mode
        when "ip" then SelfSigned
        when "cloudflare", nil then Cloudflare
        else raise "Unknown exposure.mode: #{config.exposure.mode.inspect} (expected cloudflare or ip)"
        end
      klass.new(config: config, shell: shell, log: log, templates_dir: templates_dir,
                config_path: config_path, secrets_path: secrets_path, interactive: interactive)
    end

    class Base
      attr_reader :config, :shell, :log, :templates_dir, :config_path, :secrets_path

      def initialize(config:, shell:, log:, templates_dir: nil, config_path: nil, secrets_path: nil, interactive: true)
        @config = config
        @shell = shell
        @log = log
        @templates_dir = templates_dir
        @config_path = config_path
        @secrets_path = secrets_path
        @interactive = interactive
      end

      def setup! = raise(NotImplementedError)
      def journal_public_url = raise(NotImplementedError)
      def viewer_base_url = raise(NotImplementedError)
      def hello_url = raise(NotImplementedError)
      def summary_lines = raise(NotImplementedError)

      private

      def interactive? = @interactive
      def journal_bundled? = (config.journal&.mode || "bundled") != "external"
      def hello_world_port = config.hello_world&.port || 9820

      def template_path(name)
        raise "templates_dir not set" unless templates_dir
        File.join(templates_dir, name)
      end

      def render_template(template_name, output_path, vars, mode: nil)
        Template.render_to(template_path(template_name), output_path, vars, mode: mode)
      end

      def section(title) = log.section(title)
      def info(msg)      = log.info(msg)
      def ok(msg)        = log.ok(msg)
      def skip(msg)      = log.skip(msg)
      def warn(msg)      = log.warn(msg)
    end
  end
end

require_relative "exposure/cloudflare"
require_relative "exposure/self_signed"
```

- [ ] **Step 4: Create the SelfSigned strategy**

`lib/dev_boxer/exposure/self_signed.rb`:

```ruby
require "fileutils"
require "shellwords"

module DevBoxer
  module Exposure
    # IP mode: nginx terminates TLS on the server's IP with one long-lived
    # self-signed cert (SAN = the IP). No domain, no Cloudflare. Apps must
    # accept/pin the cert (SP5); the summary prints the fingerprint they
    # verify against.
    class SelfSigned < Base
      CERT_DAYS = 3650

      def setup!
        ensure_cert!
        install_nginx
        write_nginx_config
        shell.sh!("nginx -t")
        shell.systemctl(:enable, "nginx")
        shell.systemctl(:restart, "nginx")
        open_firewall
        ok "Self-signed exposure ready on #{ip_address}"
      end

      def journal_public_url
        return config.journal&.url unless journal_bundled?
        "wss://#{ip_address}:#{journal_port}/ws"
      end

      def viewer_base_url = "https://#{ip_address}:#{viewer_port}"
      def hello_url = "https://#{ip_address}:#{hello_port}"

      def summary_lines
        lines = []
        lines << "Journal (Matron apps): #{journal_public_url}" if journal_bundled?
        lines << "Viewer:  #{viewer_base_url}"
        lines << "Hello:   #{hello_url}"
        lines << "Certificate SHA-256 fingerprint: #{fingerprint}"
        lines << "This box uses a self-signed certificate — your Matron apps will warn on"
        lines << "first connection. Accept only if the fingerprint above matches."
        lines
      end

      # Public for tests; pure string build so it can be asserted without FS.
      def nginx_config
        blocks = []
        blocks << server_block(journal_port, 9810) if journal_bundled?
        blocks << server_block(viewer_port, 9803)
        blocks << server_block(hello_port, hello_world_port)
        "# Managed by Dev Boxer — do not edit (see lib/dev_boxer/exposure/self_signed.rb)\n" +
          blocks.join("\n")
      end

      def firewall_ports
        ports = []
        ports << journal_port if journal_bundled?
        ports << viewer_port << hello_port
      end

      private

      def ip_config = config.exposure&.ip

      def ip_address
        configured = ip_config&.address
        return configured unless configured.to_s.empty?
        detected_ip
      end

      def detected_ip
        @detected_ip ||= begin
          out = shell.sh!("hostname -I").strip rescue ""
          ip = out.split(/\s+/).reject(&:empty?).first
          raise "Could not auto-detect this server's IP (hostname -I returned nothing); set exposure.ip.address in config.yml" if ip.nil?
          ip
        end
      end

      def journal_port = ip_config&.journal_port || 8443
      def viewer_port  = ip_config&.viewer_port || 8444
      def hello_port   = ip_config&.hello_port || 8445

      def tls_dir = "/etc/matron/tls"
      def cert_path = "#{tls_dir}/cert.pem"
      def key_path = "#{tls_dir}/key.pem"
      def nginx_site_path = "/etc/nginx/sites-available/matron"
      def nginx_enabled_path = "/etc/nginx/sites-enabled/matron"

      def ensure_cert!
        FileUtils.mkdir_p(tls_dir)
        File.chmod(0o700, tls_dir)
        if File.exist?(cert_path)
          if san_matches?
            skip "TLS certificate already present for #{ip_address}"
            return
          end
          warn "TLS certificate SAN no longer matches #{ip_address} (IP changed?) — regenerating."
          warn "Matron apps that pinned the old certificate must re-accept the new one."
        end
        info "Generating self-signed certificate for #{ip_address} (#{CERT_DAYS} days)"
        shell.sh!(
          "openssl req -x509 -newkey rsa:2048 -sha256 -days #{CERT_DAYS} -nodes " \
          "-keyout #{key_path} -out #{cert_path} " \
          "-subj /CN=#{Shellwords.escape(ip_address)} " \
          "-addext subjectAltName=IP:#{Shellwords.escape(ip_address)}"
        )
        File.chmod(0o600, key_path) if File.exist?(key_path)
        ok "Certificate written to #{cert_path}"
      end

      def san_matches?
        out = shell.sh!("openssl x509 -in #{cert_path} -noout -ext subjectAltName") rescue ""
        out.include?("IP Address:#{ip_address}")
      end

      def fingerprint
        return "(certificate not generated yet)" unless File.exist?(cert_path)
        out = shell.sh!("openssl x509 -in #{cert_path} -noout -fingerprint -sha256").strip
        out.split("=", 2).last
      end

      def install_nginx
        if shell.command_exists?("nginx")
          skip "nginx already installed"
          return
        end
        info "Installing nginx"
        shell.apt_update
        shell.apt_install("nginx")
      end

      def write_nginx_config
        shell.write_file(nginx_site_path, nginx_config)
        shell.sh!("ln -sf #{nginx_site_path} #{nginx_enabled_path}") unless nginx_site_path == nginx_enabled_path
        ok "nginx TLS config deployed"
      end

      def server_block(listen_port, upstream_port)
        <<~NGINX
          server {
            listen #{listen_port} ssl;
            ssl_certificate #{cert_path};
            ssl_certificate_key #{key_path};
            location / {
              proxy_pass http://127.0.0.1:#{upstream_port};
              proxy_http_version 1.1;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "upgrade";
              proxy_set_header Host $host;
              proxy_set_header X-Forwarded-For $remote_addr;
              proxy_read_timeout 7d;
              proxy_send_timeout 7d;
            }
          }
        NGINX
      end

      def open_firewall
        firewall_ports.each { |port| shell.sh!("ufw allow #{port}/tcp") }
        ok "Firewall allows: #{firewall_ports.join(', ')}"
      end
    end
  end
end
```

Note: `write_nginx_config` uses `shell.write_file` (real FS write) — the tests stub `nginx_site_path` into a tmpdir, matching the existing `mod.stub(:bridge_dir, …)` pattern.

- [ ] **Step 5: Move the Cloudflare module into a strategy**

```bash
git mv lib/dev_boxer/modules/09_cloudflare.rb lib/dev_boxer/exposure/cloudflare.rb
git mv test/cloudflare_module_test.rb test/exposure_cloudflare_test.rb
```

Transform `lib/dev_boxer/exposure/cloudflare.rb` (all other method bodies stay byte-identical):

1. Class header: `module DevBoxer / module Exposure / class Cloudflare < Base` (was `Modules::Cloudflare < ModuleBase`); drop `module_name`/`module_order` lines.
2. `def run` → `def setup!`; delete the `unless config.cloudflare&.enabled … return` guard (mode selection replaced `enabled`); delete the trailing `print_hostnames` call (module 09 prints `summary_lines`).
3. Add a private reader `def cf = config.exposure&.cloudflare` and change every `config.cloudflare&.` to `cf&.` (readers at lines 39-58 of the old file).
4. Rename `hostname_matrix` → `hostname_journal` (reader becomes `cf&.tunnel&.hostname_journal`) and update its uses: `configured_hostnames` (old :192), `access_bypass_destinations` (old :330), `render_ingress` (old :463).
5. `render_ingress` journal/viewer targets:

```ruby
      def render_ingress
        rules = []
        if journal_bundled? && !hostname_journal.to_s.empty?
          rules << "  - hostname: #{hostname_journal}\n    service: http://localhost:9810"
        end
        if !hostname_viewer.to_s.empty?
          rules << "  - hostname: #{hostname_viewer}\n    service: http://localhost:9803"
        end
        if !hostname_hello.to_s.empty?
          rules << "  - hostname: #{hostname_hello}\n    service: http://localhost:#{hello_world_port}"
        end
        if !tunnel_hostname.to_s.empty?
          rules << "  - hostname: #{tunnel_hostname}\n    service: https://localhost\n    originRequest:\n      noTLSVerify: true"
        end
        rules << "  - service: http_status:404"
        rules.join("\n")
      end
```

6. `configured_hostnames`: journal hostname included only when `journal_bundled?`:

```ruby
      def configured_hostnames
        hosts = [tunnel_hostname, hostname_viewer, hostname_hello]
        hosts.insert(1, hostname_journal) if journal_bundled?
        hosts.compact.reject { |h| h.to_s.empty? }
      end
```

7. `access_bypass_destinations` (old :322-331): `[hostname_matrix, *configured]` → `[(journal_bundled? ? hostname_journal : nil), *configured]`.
8. Persistence paths: `persist_tunnel_id` writes `{ "exposure" => { "cloudflare" => { "tunnel" => { "id" => id } } } }`; `persist_access_app_id` / `persist_access_bypass_app_id` gain the same `exposure` nesting; `clear_setup_token` digs `data.dig("exposure", "cloudflare")` instead of `data["cloudflare"]`.
9. `$stdin.tty?` (old :258, :396) → `interactive?`.
10. `hello_world_port` reader: delete (Base provides it). Delete the module's use of `cloudflare_hello_hostname` from ModuleBase — inline it here instead:

```ruby
      def hostname_hello
        configured = cf&.tunnel&.hostname_hello
        return configured unless configured.to_s.empty?
        zone_name.to_s.empty? ? nil : "hello.#{zone_name}"
      end
```

11. `print_hostnames` → `summary_lines` returning an array (and journal line gated on bundled):

```ruby
      def summary_lines
        lines = []
        lines << "Main:    https://#{tunnel_hostname}" if tunnel_hostname
        lines << "Journal (Matron apps): #{journal_public_url}" if journal_bundled? && hostname_journal
        lines << "Viewer:  https://#{hostname_viewer}" if hostname_viewer
        lines << "Hello:   https://#{hostname_hello}" if hostname_hello
        if access_enabled?
          lines << "Cloudflare Access protects: #{access_protected_destinations.join(', ')}"
          bypass = access_bypass_destinations
          lines << "Cloudflare Access bypasses: #{bypass.join(', ')}" unless bypass.empty?
        else
          lines << "IMPORTANT: set up Cloudflare Access for zero-trust security. See docs/cloudflare-access.md."
        end
        lines
      end
```

12. Add the three URL methods:

```ruby
      def journal_public_url
        return config.journal&.url unless journal_bundled?
        "wss://#{hostname_journal}/ws"
      end

      def viewer_base_url = "https://#{hostname_viewer}"
      def hello_url = "https://#{hostname_hello}"
```

13. Error-message strings referencing config paths gain the prefix: `"cloudflare.access.account_id is required…"` → `"exposure.cloudflare.access.account_id is required…"`, `"cloudflare.api_token is required…"` → `"exposure.cloudflare.api_token is required…"`, `"cloudflare.zone_name is required…"` → `"exposure.cloudflare.zone_name is required…"`, `"No cloudflare.tunnel.id and no one-time cloudflare.api_token…"` → `"No exposure.cloudflare.tunnel.id and no one-time exposure.cloudflare.api_token…"`, `"cloudflare.tunnel.create_manually is true; …set cloudflare.tunnel.id"` → same with prefixes.

Adapt `test/exposure_cloudflare_test.rb` with the same mechanical rules: instantiation goes through `DevBoxer::Exposure::Cloudflare.new(config:, shell:, log:, templates_dir:, config_path:, secrets_path:)` (no module ctor); config fixtures nest the old `"cloudflare" => {…}` hash under `"exposure" => {"mode" => "cloudflare", "cloudflare" => {…}}` and add `"journal" => {"mode" => "bundled"}`; `hostname_matrix` keys → `hostname_journal`; `mod.run` → `strategy.setup!`; expected persisted YAML paths and error strings gain the `exposure.` prefix; ingress assertions change `localhost:6167` → `localhost:9810` and `localhost:9801` → `localhost:9803`. Delete any test asserting the `enabled: false → skip` behavior. Add one new test:

```ruby
  def test_ingress_omits_journal_hostname_when_journal_external
    strategy = build_strategy(config_with("journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" }))
    refute_includes strategy.send(:render_ingress), "localhost:9810"
  end
```

(`build_strategy`/`config_with` = this file's existing fixture helpers, renamed as needed.)

- [ ] **Step 6: Create the thin module 09 + plumbing**

`lib/dev_boxer/modules/09_exposure.rb`:

```ruby
module DevBoxer
  module Modules
    # Thin shell around the Exposure strategy (lib/dev_boxer/exposure/).
    # All mode-specific behavior lives in the strategies.
    class Exposure < ModuleBase
      module_name  "exposure"
      module_order 9

      def run
        section "Exposure"
        exposure.setup!
        exposure.summary_lines.each { |line| info line }
      end
    end
  end
end
```

`lib/dev_boxer/module_base.rb`: add `interactive` to the ctor and an `exposure` helper; delete `cloudflare_hello_hostname` **in Task 7** (module 10 still calls it — leave it for now):

```ruby
    def initialize(config:, log:, shell: Shell.new, templates_dir: nil, config_path: nil, secrets_path: nil, interactive: true)
      @config = config
      @log = log
      @shell = shell
      @templates_dir = templates_dir
      @config_path = config_path
      @secrets_path = secrets_path
      @interactive = interactive
    end
```

and in the private section:

```ruby
    def interactive? = @interactive

    def exposure
      @exposure ||= DevBoxer::Exposure.for(
        config: config, shell: shell, log: log, templates_dir: templates_dir,
        config_path: config_path, secrets_path: secrets_path, interactive: interactive?,
      )
    end
```

`lib/dev_boxer/runner.rb`: ctor gains `interactive: true`, stored and passed through to `klass.new(…, interactive: @interactive)`.

`setup.rb:153-160`: add `interactive: interactive && !options[:non_interactive],` to the `Runner.new` call.

`lib/dev_boxer.rb`: add `require_relative "dev_boxer/exposure"` after the `template` require.

`test/modules_shape_test.rb:57`: expected names become `%w[browsers claude desktop desktop-apps dev-tools docker exposure hello-world matrix-bridge security users]`.

- [ ] **Step 7: Run tests**

Run: `rake test TEST=test/exposure_self_signed_test.rb && rake test TEST=test/exposure_cloudflare_test.rb && rake test TEST=test/modules_shape_test.rb`
Expected: PASS. Then `rake test` → PASS (module 08 still reads `config.cloudflare` for `CF_HOSTNAME_VIEWER`; its tests pass because that read is nil-safe — Task 6 replaces it).

- [ ] **Step 8: Commit**

```bash
git add -A lib/dev_boxer test/ setup.rb
git commit -m "exposure: strategy interface — Cloudflare moved intact, SelfSigned (IP + self-signed WSS) new"
```

---

### Task 5: JournalEnrollment + bin/enroll + Shell#wait_for_http

**Files:**
- Create: `lib/dev_boxer/journal_enrollment.rb`, `bin/enroll` (mode 0755)
- Modify: `lib/dev_boxer/shell.rb` (add `wait_for_http`), `lib/dev_boxer.rb` (require)
- Test: create `test/journal_enrollment_test.rb`; extend `test/shell_test.rb`

**Interfaces:**
- Produces:
  - `DevBoxer::JournalEnrollment.new(config:, shell:, log:, interactive: false, input: $stdin, token_path: TOKEN_PATH, http_post: nil, sleeper: nil)`
  - `#resolve!(force: false)` → String path to the token file; raises `JournalEnrollment::NotEnrolled` with an operator-actionable message.
  - `#agent_name` → String (`journal.agent_name` or `hostname -s`).
  - `JournalEnrollment.https_base("wss://host[:port]/ws")` → `"https://host[:port]"` (ws→http).
  - `JournalEnrollment.probe(https_base, ca_file: nil)` → `:ok` or a String describing the failure.
  - `JournalEnrollment::TOKEN_PATH = "/etc/matron/agent-token"`.
  - `Shell#wait_for_http(url, timeout: 30)` — true once the URL answers **any** HTTP status (curl without `-f`), unlike `wait_for_url` which requires 2xx.
- Consumes: nothing from Tasks 3-4 (independent of Exposure).

- [ ] **Step 1: Write the tests**

Append to `test/shell_test.rb`:

```ruby
  def test_wait_for_http_accepts_any_http_status
    recorded = []
    shell = DevBoxer::Shell.new(runner: lambda { |cmd, _opts = {}|
      recorded << cmd
      [true, "", ""]  # curl exit 0 == got an HTTP response (even 401)
    })

    assert shell.wait_for_http("http://127.0.0.1:9810/metrics", timeout: 1)
    assert_match(/curl -s -o \/dev\/null/, recorded.first)
    refute_match(/curl -sf/, recorded.first)
  end
```

Create `test/journal_enrollment_test.rb`:

```ruby
require_relative "test_helper"
require "tmpdir"
require_relative "support/module_test_case"

class JournalEnrollmentTest < DevBoxer::Testing::ModuleTestCase
  AGENT_ADD_OUTPUT = "agent dev-4 token: tok_abc123\n(store in the bridge credentials file; it is not shown again)\n".freeze

  def build_enrollment(config_hash, dir:, interactive: false, http_post: nil, input: StringIO.new)
    DevBoxer::JournalEnrollment.new(
      config: DevBoxer::Config.from_hash({ "user" => { "name" => "dev" } }.merge(config_hash)),
      shell: @shell,
      log: @log,
      interactive: interactive,
      input: input,
      token_path: File.join(dir, "agent-token"),
      http_post: http_post,
      sleeper: ->(_seconds) {},
    )
  end

  def test_configured_token_file_wins
    Dir.mktmpdir do |dir|
      provided = File.join(dir, "provided-token")
      File.write(provided, "tok\n")
      enrollment = build_enrollment({ "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws", "token_file" => provided } }, dir: dir)

      assert_equal provided, enrollment.resolve!
    end
  end

  def test_configured_token_file_must_exist
    Dir.mktmpdir do |dir|
      enrollment = build_enrollment({ "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws", "token_file" => "/nope" } }, dir: dir)

      error = assert_raises(DevBoxer::JournalEnrollment::NotEnrolled) { enrollment.resolve! }
      assert_match(/does not exist/, error.message)
    end
  end

  def test_existing_token_at_default_path_is_reused
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "agent-token"), "tok\n")
      enrollment = build_enrollment({ "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" } }, dir: dir)

      assert_equal File.join(dir, "agent-token"), enrollment.resolve!
    end
  end

  def test_bundled_mode_mints_locally_and_writes_token
    Dir.mktmpdir do |dir|
      respond_default(success: true, stdout: AGENT_ADD_OUTPUT)
      enrollment = build_enrollment({ "journal" => { "mode" => "bundled", "username" => "dan", "agent_name" => "dev-4" } }, dir: dir)

      path = enrollment.resolve!

      assert_equal File.join(dir, "agent-token"), path
      assert_equal "tok_abc123\n", File.read(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
      # The inner command is Shellwords-escaped inside the runuser wrapper,
      # so spaces arrive as backslash-space in the recorded string.
      assert_recorded(/matron-admin\\ agent\\ add\\ dan\\ dev-4/)
      assert_recorded(/runuser -u matron/)
    end
  end

  def test_non_interactive_external_without_token_raises_with_remedy
    Dir.mktmpdir do |dir|
      enrollment = build_enrollment({ "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" } }, dir: dir)

      error = assert_raises(DevBoxer::JournalEnrollment::NotEnrolled) { enrollment.resolve! }
      assert_match(/journal\.token_file/, error.message)
      assert_match(/bin\/enroll/, error.message)
    end
  end

  def test_interactive_pairing_start_poll_claim_writes_token
    Dir.mktmpdir do |dir|
      responses = [
        [200, { "pair_code" => "ABCD-EFGH", "poll_token" => "poll1", "expires_in" => 600 }],
        [200, { "status" => "pending" }],
        [200, { "status" => "approved", "token" => "tok_paired", "device_id" => 7 }],
      ]
      calls = []
      http_post = lambda { |url, body| calls << [url, body]; responses.shift }
      enrollment = build_enrollment(
        { "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" } },
        dir: dir, interactive: true, http_post: http_post,
      )

      path = enrollment.resolve!

      assert_equal "tok_paired\n", File.read(path)
      assert_equal "https://chat.example.com/pair/start", calls[0][0]
      assert_equal "https://chat.example.com/pair/claim", calls[1][0]
      assert_equal({ "poll_token" => "poll1" }, calls[1][1])
      assert_includes @log_io.string, "ABCD-EFGH"
      assert_includes @log_io.string, "Settings"
    end
  end

  def test_expired_code_offers_fresh_one
    Dir.mktmpdir do |dir|
      responses = [
        [200, { "pair_code" => "AAAA-AAAA", "poll_token" => "p1", "expires_in" => 600 }],
        [404, { "error" => "not_found" }],
        [200, { "pair_code" => "BBBB-BBBB", "poll_token" => "p2", "expires_in" => 600 }],
        [200, { "status" => "approved", "token" => "tok2", "device_id" => 8 }],
      ]
      http_post = lambda { |_url, _body| responses.shift }
      enrollment = build_enrollment(
        { "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" } },
        dir: dir, interactive: true, http_post: http_post, input: StringIO.new("y\n"),
      )

      assert_equal "tok2\n", File.read(enrollment.resolve!)
    end
  end

  def test_force_skips_existing_token_and_re_enrolls
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "agent-token"), "stale\n")
      respond_default(success: true, stdout: AGENT_ADD_OUTPUT)
      enrollment = build_enrollment({ "journal" => { "mode" => "bundled" } }, dir: dir)

      enrollment.resolve!(force: true)

      assert_equal "tok_abc123\n", File.read(File.join(dir, "agent-token"))
    end
  end

  def test_https_base_conversion
    assert_equal "https://chat.example.com", DevBoxer::JournalEnrollment.https_base("wss://chat.example.com/ws")
    assert_equal "https://203.0.113.7:8443", DevBoxer::JournalEnrollment.https_base("wss://203.0.113.7:8443/ws")
    assert_equal "http://127.0.0.1:9810", DevBoxer::JournalEnrollment.https_base("ws://127.0.0.1:9810/ws")
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `rake test TEST=test/journal_enrollment_test.rb TESTOPTS=-v`
Expected: FAIL — class undefined.

- [ ] **Step 3: Add Shell#wait_for_http**

In `lib/dev_boxer/shell.rb`, below `wait_for_url`:

```ruby
    # Like wait_for_url, but accepts ANY HTTP status — for endpoints that
    # are up-but-authenticated (matron-journal's /metrics 401s without a
    # token). curl without -f exits 0 on any HTTP response.
    def wait_for_http(url, timeout: 30)
      timeout.times do
        return true if sh("curl -s -o /dev/null #{Shellwords.escape(url)}")
        sleep 1
      end
      false
    end
```

- [ ] **Step 4: Implement JournalEnrollment**

`lib/dev_boxer/journal_enrollment.rb` — complete file:

```ruby
require "fileutils"
require "json"
require "net/http"
require "shellwords"
require "uri"

module DevBoxer
  # Resolves the matron-journal agent token this box's bridge authenticates
  # with. Resolution order (SP4 spec §Enrollment):
  #   1. journal.token_file configured        -> use it (must exist)
  #   2. /etc/matron/agent-token present      -> reuse (idempotent re-runs)
  #   3. bundled journal                      -> mint via matron-admin agent add
  #   4. interactive                          -> app-approved pairing
  #   5. otherwise                            -> NotEnrolled
  # bin/enroll re-runs this with force: true (skips 1-2) after a token is
  # revoked or the journal moves.
  class JournalEnrollment
    NotEnrolled = Class.new(StandardError)

    TOKEN_PATH = "/etc/matron/agent-token".freeze
    JOURNAL_DIR = "/opt/matron-journal".freeze
    POLL_INTERVAL = 3
    RATE_LIMIT_BACKOFF = 30

    def self.https_base(ws_url)
      uri = URI(ws_url.to_s)
      scheme = uri.scheme == "ws" ? "http" : "https"
      default_port = scheme == "http" ? 80 : 443
      base = "#{scheme}://#{uri.host}"
      base += ":#{uri.port}" if uri.port && uri.port != default_port
      base
    end

    # Any HTTP response (including 401 from /metrics) means the journal is
    # reachable; only transport/TLS failures return an error string.
    def self.probe(https_base, ca_file: nil)
      uri = URI("#{https_base}/metrics")
      http = Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.ca_file = ca_file unless ca_file.to_s.empty?
      http.open_timeout = 5
      http.read_timeout = 5
      http.request(Net::HTTP::Get.new(uri))
      :ok
    rescue OpenSSL::SSL::SSLError => e
      "TLS verification failed (#{e.message}). If this journal uses a self-signed certificate, set journal.ca_file to its certificate."
    rescue StandardError => e
      "#{e.class}: #{e.message}"
    end

    def initialize(config:, shell:, log:, interactive: false, input: $stdin,
                   token_path: TOKEN_PATH, http_post: nil, sleeper: nil)
      @config = config
      @shell = shell
      @log = log
      @interactive = interactive
      @input = input
      @token_path = token_path
      @http_post = http_post || method(:default_http_post)
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
    end

    def resolve!(force: false)
      unless force
        configured = config.journal&.token_file
        unless configured.to_s.empty?
          unless File.exist?(configured)
            raise NotEnrolled, "journal.token_file is set to #{configured} but that file does not exist"
          end
          log.skip "Using pre-provisioned agent token: #{configured}"
          return configured
        end
        if File.exist?(token_path)
          log.skip "Reusing existing agent token: #{token_path}"
          return token_path
        end
      end

      return mint_local_token if bundled?
      return pair! if interactive

      raise NotEnrolled, <<~MSG
        No agent token found and this run is non-interactive, so the pairing
        flow can't run. Either set journal.token_file to a pre-provisioned
        token (on the journal host: matron-admin agent add <user> <agent-name>),
        or run bin/enroll interactively on this box.
      MSG
    end

    def agent_name
      configured = config.journal&.agent_name
      return configured unless configured.to_s.empty?
      shell.sh!("hostname -s").strip
    end

    private

    attr_reader :config, :shell, :log, :interactive, :input, :token_path

    def bundled? = (config.journal&.mode || "bundled") == "bundled"

    # Run matron-admin as the matron user — as root it would create
    # SQLite -wal/-shm files owned by root and break the service.
    def mint_local_token
      user = config.journal&.username || config.user.name
      cmd = "cd #{JOURNAL_DIR} && MATRON_DB=#{JOURNAL_DIR}/data/matron.db " \
            "npx matron-admin agent add #{Shellwords.escape(user)} #{Shellwords.escape(agent_name)}"
      out = shell.sh!("runuser -u matron -- sh -c #{Shellwords.escape(cmd)}")
      token = out[/token: (\S+)/, 1]
      raise NotEnrolled, "matron-admin agent add did not print a token:\n#{out}" if token.to_s.empty?
      write_token(token)
      log.ok "Agent #{agent_name} minted for journal user #{user}"
      token_path
    end

    def pair!
      base = self.class.https_base(config.journal&.url)
      loop do
        code, body = @http_post.call("#{base}/pair/start", {})
        if code == 429
          log.warn "Pairing rate-limited by the journal — waiting #{RATE_LIMIT_BACKOFF}s"
          @sleeper.call(RATE_LIMIT_BACKOFF)
          next
        end
        raise NotEnrolled, "pair/start failed with HTTP #{code}: #{body.inspect}" unless code == 200

        display_code(body)
        return token_path if poll_for_claim(base, body)

        # nil -> the code expired before approval
        unless confirm_retry?
          raise NotEnrolled, "Pairing abandoned — run bin/enroll when you're ready to try again"
        end
      end
    end

    def display_code(pair)
      minutes = ((pair["expires_in"] || 600) / 60.0).round
      log.info ""
      log.info "Pairing code: #{pair['pair_code']}"
      log.info "In the Matron app: Settings -> Devices -> Add Agent, enter the code,"
      log.info "and name the agent (suggested name: #{agent_name})."
      log.info "The code expires in ~#{minutes} minutes. Waiting for approval (Ctrl-C to abort)..."
    end

    def poll_for_claim(base, pair)
      loop do
        @sleeper.call(POLL_INTERVAL)
        code, body = @http_post.call("#{base}/pair/claim", { "poll_token" => pair["poll_token"] })
        case
        when code == 200 && body["status"] == "approved"
          write_token(body["token"])
          log.ok "Pairing approved — agent token stored at #{token_path}"
          return true
        when code == 200
          next # pending
        when code == 404
          log.warn "The pairing code expired before it was approved."
          return nil
        when code == 429
          log.warn "Rate-limited while polling — backing off #{RATE_LIMIT_BACKOFF}s"
          @sleeper.call(RATE_LIMIT_BACKOFF)
        else
          raise NotEnrolled, "pair/claim failed with HTTP #{code}: #{body.inspect}"
        end
      end
    end

    def confirm_retry?
      log.info "Request a fresh pairing code? [Y/n]:"
      answer = input.gets.to_s.strip.downcase
      answer.empty? || %w[y yes].include?(answer)
    end

    def write_token(token)
      FileUtils.mkdir_p(File.dirname(token_path))
      old_umask = File.umask(0o077)
      begin
        File.write(token_path, "#{token}\n")
      ensure
        File.umask(old_umask)
      end
      File.chmod(0o600, token_path)
      owner = config.user&.name
      shell.sh!("chown #{Shellwords.escape(owner)}:#{Shellwords.escape(owner)} #{Shellwords.escape(token_path)}") if owner
    end

    def default_http_post(url, body)
      uri = URI(url)
      http = Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl = uri.scheme == "https"
      ca = config.journal&.ca_file
      http.ca_file = ca unless ca.to_s.empty?
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.dump(body)
      response = http.request(request)
      parsed = begin
        JSON.parse(response.body)
      rescue JSON::ParserError
        {}
      end
      [response.code.to_i, parsed]
    end
  end
end
```

Add to `lib/dev_boxer.rb` after the config require: `require_relative "dev_boxer/journal_enrollment"`.

- [ ] **Step 5: Create bin/enroll**

`bin/enroll` (then `chmod +x bin/enroll`):

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# Re-enroll this box's bridge with its matron-journal server — use after a
# token was revoked from the app or the journal moved. Skips the existing
# token and re-runs enrollment (local mint in bundled mode, app pairing in
# external mode), then restarts the bridge. Replaces the old bin/add-bot.

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))
require "dev_boxer"

abort "bin/enroll must run as root (it writes /etc/matron and restarts the bridge)" unless Process.uid.zero?

config_path = File.join(ROOT, "config.yml")
abort "config.yml not found at #{config_path} — run setup.rb first" unless File.exist?(config_path)

log = DevBoxer::Log.new
enrollment = DevBoxer::JournalEnrollment.new(
  config: DevBoxer::Config.load(config_path),
  shell: DevBoxer::Shell.new,
  log: log,
  interactive: $stdin.tty?,
)

begin
  path = enrollment.resolve!(force: true)
rescue DevBoxer::JournalEnrollment::NotEnrolled => e
  abort e.message
end

log.ok "Agent token written to #{path}"
DevBoxer::Shell.new.systemctl(:restart, "matron-bridge")
log.ok "matron-bridge restarted"
```

- [ ] **Step 6: Run tests, commit**

Run: `rake test TEST=test/journal_enrollment_test.rb && rake test TEST=test/shell_test.rb && rake test`
Expected: PASS

```bash
git add lib/dev_boxer/journal_enrollment.rb lib/dev_boxer/shell.rb lib/dev_boxer.rb bin/enroll test/journal_enrollment_test.rb test/shell_test.rb
git commit -m "enrollment: agent-token resolution (file > existing > local mint > pairing) + bin/enroll"
```

---

### Task 6: Module 08 → matron (journal install + bridge), retire the Matrix module

**Files:**
- Create: `lib/dev_boxer/modules/08_matron.rb`, `templates/matron-bridge.env`, `templates/matron-bridge.service`, `templates/matron-viewer.service`, `test/matron_module_test.rb`
- Delete: `lib/dev_boxer/modules/08_matrix_bridge.rb`, `lib/dev_boxer/matrix_registration.rb`, `templates/matrix-bridge.env`, `templates/claude-matrix-bridge.service`, `templates/claude-matrix-file-viewer.service`, `templates/docker-compose.matron-server.yml`, `test/matrix_bridge_test.rb`, `test/matrix_registration_test.rb`
- Modify: `templates/mcp-config.json`, `templates/CLAUDE.md.template`, `test/modules_shape_test.rb:57`

**Interfaces:**
- Consumes: `JournalEnrollment` (Task 5), `ModuleBase#exposure` / `#interactive?` (Task 4), `Shell#wait_for_http` (Task 5).
- Produces: module `matron` (order 8); services `matron-journal` (bundled only), `matron-bridge`, `matron-viewer`; secrets keys `journal.username`, `journal.user_password`, `bridge.hmac_secret`; bridge checkout at `~/matron-bridge`.

- [ ] **Step 1: Write the module tests**

Create `test/matron_module_test.rb`:

```ruby
require_relative "test_helper"
require "tmpdir"
require_relative "support/module_test_case"
require_relative "../lib/dev_boxer/modules/08_matron"

class MatronModuleTest < DevBoxer::Testing::ModuleTestCase
  def base_config(overrides = {})
    DevBoxer::Config.deep_merge({
      "user" => { "name" => "dev" },
      "journal" => { "mode" => "bundled", "username" => "dev" },
      "exposure" => { "mode" => "ip", "ip" => { "address" => "203.0.113.7" } },
      "hello_world" => { "port" => 9820 },
    }, overrides)
  end

  def build_matron(config_hash = {}, secrets_path: nil)
    DevBoxer::Modules::Matron.new(
      config: DevBoxer::Config.from_hash(base_config(config_hash)),
      log: @log,
      shell: @shell,
      templates_dir: TEMPLATES_DIR,
      secrets_path: secrets_path,
    )
  end

  def test_bridge_env_vars_bundled_uses_loopback_ws_and_viewer_from_exposure
    Dir.mktmpdir do |dir|
      mod = build_matron({}, secrets_path: File.join(dir, "secrets.yml"))

      vars = mod.send(:bridge_env_vars, "/etc/matron/agent-token")

      assert_equal "ws://127.0.0.1:9810/ws", vars["JOURNAL_WS_URL"]
      assert_equal "/etc/matron/agent-token", vars["JOURNAL_TOKEN_FILE"]
      assert_equal "https://203.0.113.7:8444", vars["VIEWER_BASE_URL"]
      assert_equal "", vars["NODE_EXTRA_CA_LINE"]
      assert vars["HMAC_SECRET"]
      refute(vars.keys.any? { |k| k.start_with?("MATRIX_") })
    end
  end

  def test_bridge_env_vars_external_uses_journal_url_and_ca_line
    Dir.mktmpdir do |dir|
      mod = build_matron(
        { "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws", "ca_file" => "/etc/matron/chat-ca.pem" } },
        secrets_path: File.join(dir, "secrets.yml"),
      )

      vars = mod.send(:bridge_env_vars, "/etc/matron/agent-token")

      assert_equal "wss://chat.example.com/ws", vars["JOURNAL_WS_URL"]
      assert_equal "NODE_EXTRA_CA_CERTS=/etc/matron/chat-ca.pem", vars["NODE_EXTRA_CA_LINE"]
    end
  end

  def test_hmac_secret_is_memoised_and_persisted
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      mod = build_matron({}, secrets_path: secrets_path)

      first = mod.send(:bridge_env_vars, "/t")["HMAC_SECRET"]
      second = mod.send(:bridge_env_vars, "/t")["HMAC_SECRET"]

      assert_equal first, second
      assert_equal first, YAML.safe_load_file(secrets_path).dig("bridge", "hmac_secret")
    end
  end

  def test_hmac_secret_reused_from_config
    mod = DevBoxer::Modules::Matron.new(
      config: DevBoxer::Config.from_hash(base_config("bridge" => { "hmac_secret" => "keepme" })),
      log: @log, shell: @shell, templates_dir: TEMPLATES_DIR,
    )

    assert_equal "keepme", mod.send(:bridge_env_vars, "/t")["HMAC_SECRET"]
  end

  def test_ensure_journal_user_skips_when_password_recorded
    Dir.mktmpdir do |dir|
      mod = build_matron({ "journal" => { "user_password" => "already" } }, secrets_path: File.join(dir, "secrets.yml"))

      mod.send(:ensure_journal_user)

      refute_recorded(/matron-admin/)
    end
  end

  def test_ensure_journal_user_adds_user_and_persists_password
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      respond_default(success: true)
      mod = build_matron({}, secrets_path: secrets_path)
      mod.stub(:journal_user_exists?, false) do
        mod.send(:ensure_journal_user)
      end

      # Inner command is Shellwords-escaped inside the runuser wrapper, so
      # spaces arrive as backslash-space in the recorded string.
      assert_recorded(/matron-admin\\ user\\ add\\ dev\\ --password/)
      secrets = YAML.safe_load_file(secrets_path)
      assert_equal "dev", secrets.dig("journal", "username")
      assert secrets.dig("journal", "user_password")
    end
  end

  def test_ensure_journal_user_resets_password_when_user_exists_but_unrecorded
    Dir.mktmpdir do |dir|
      respond_default(success: true)
      mod = build_matron({}, secrets_path: File.join(dir, "secrets.yml"))
      mod.stub(:journal_user_exists?, true) do
        mod.send(:ensure_journal_user)
      end

      assert_recorded(/matron-admin\\ user\\ passwd\\ dev\\ --password/)
      refute_recorded(/matron-admin\\ user\\ add/)
    end
  end

  def test_probe_failure_raises_before_bridge_install
    mod = build_matron("journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" })

    DevBoxer::JournalEnrollment.stub(:probe, "Errno::ECONNREFUSED: nope") do
      error = assert_raises(RuntimeError) { mod.send(:probe_external_journal!) }
      assert_match(/chat\.example\.com/, error.message)
      assert_match(/ECONNREFUSED/, error.message)
    end
  end

  def test_systemd_units_are_matron_named
    Dir.mktmpdir do |dir|
      respond_default(success: true)
      mod = build_matron({}, secrets_path: File.join(dir, "secrets.yml"))
      mod.stub(:bridge_dir, dir) do
        mod.stub(:unit_dir, dir) do
          mod.send(:install_systemd_units)
        end
      end

      assert File.exist?(File.join(dir, "matron-bridge.service"))
      assert File.exist?(File.join(dir, "matron-viewer.service"))
      assert_includes File.read(File.join(dir, "matron-bridge.service")), "/home/dev/matron-bridge/index.js"
      assert_includes File.read(File.join(dir, "matron-viewer.service")), "viewer/server.js"
      assert_recorded(/systemctl restart matron-bridge/)
      assert_recorded(/systemctl restart matron-viewer/)
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `rake test TEST=test/matron_module_test.rb`
Expected: FAIL — module file missing.

- [ ] **Step 3: Create the templates**

`templates/matron-bridge.env`:

```
# matron-bridge config — deployed by dev-boxer
JOURNAL_WS_URL={{JOURNAL_WS_URL}}
JOURNAL_TOKEN_FILE={{JOURNAL_TOKEN_FILE}}
DEFAULT_WORKDIR=/home/{{USERNAME}}
HMAC_SECRET={{HMAC_SECRET}}
VIEWER_BASE_URL={{VIEWER_BASE_URL}}
MATRON_BRIDGE_API_PORT=9802
MATRON_VIEWER_PORT=9803
{{NODE_EXTRA_CA_LINE}}
```

`templates/matron-bridge.service`:

```
[Unit]
Description=Matron Bridge
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={{USERNAME}}
WorkingDirectory=/home/{{USERNAME}}/matron-bridge
EnvironmentFile=/home/{{USERNAME}}/matron-bridge/.env
ExecStart=/usr/bin/node /home/{{USERNAME}}/matron-bridge/index.js
Restart=always
RestartSec=5
Environment=PATH=/home/{{USERNAME}}/.local/bin:/home/{{USERNAME}}/.claude/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
```

`templates/matron-viewer.service`:

```
[Unit]
Description=Matron Bridge File Viewer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={{USERNAME}}
WorkingDirectory=/home/{{USERNAME}}/matron-bridge
EnvironmentFile=/home/{{USERNAME}}/matron-bridge/.env
ExecStart=/usr/bin/node /home/{{USERNAME}}/matron-bridge/viewer/server.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

`templates/mcp-config.json` — replace the ask-user entry (chrome-devtools entry unchanged):

```json
{
  "mcpServers": {
    "ask-user": {
      "command": "node",
      "args": ["/home/{{USERNAME}}/matron-bridge/ask-user.js"],
      "env": {
        "BRIDGE_API_URL": "http://127.0.0.1:9802"
      }
    },
    "chrome-devtools": {
      "command": "xvfb-run",
      "args": ["--auto-servernum", "--server-args=-screen 0 1920x1080x24", "npx", "chrome-devtools-mcp"],
      "env": {
        "DISPLAY": "",
        "HOME": "/home/{{USERNAME}}"
      }
    }
  }
}
```

(`ask-user.js` reads `BRIDGE_API_URL`, default `http://127.0.0.1:9802` — verified against Matronhq/matron-bridge `ask-user.js:9`.)

`templates/CLAUDE.md.template` — global substitutions: `claude-matrix-bridge.service` → `matron-bridge.service`; `claude-matrix-file-viewer.service` → `matron-viewer.service`; `~/claude-matrix-bridge` → `~/matron-bridge`; `Matrix bridge session` → `Matron bridge session`; `Matrix-to-Claude bridge` → `Matron-to-Claude bridge`; `shared Matrix artifacts` → `shared session artifacts`. Then `grep -in matrix templates/CLAUDE.md.template` must return nothing.

- [ ] **Step 4: Create the module**

Delete `lib/dev_boxer/modules/08_matrix_bridge.rb`, `lib/dev_boxer/matrix_registration.rb`, `test/matrix_bridge_test.rb`, `test/matrix_registration_test.rb`, `templates/matrix-bridge.env`, `templates/claude-matrix-bridge.service`, `templates/claude-matrix-file-viewer.service`, `templates/docker-compose.matron-server.yml`.

Create `lib/dev_boxer/modules/08_matron.rb`:

```ruby
require "securerandom"
require "shellwords"
require_relative "../journal_enrollment"

module DevBoxer
  module Modules
    # Matron chat stack: matron-journal (bundled mode only) + matron-bridge.
    #
    #   journal.mode: bundled  — install matron-journal on this box
    #     (loopback :9810), create the journal user, mint the agent token
    #     locally. Remote clients reach it through the Exposure layer.
    #   journal.mode: external — the bridge talks to a central journal over
    #     wss://; the agent token comes from a pre-provisioned file or
    #     app-approved pairing (JournalEnrollment).
    class Matron < ModuleBase
      module_name  "matron"
      module_order 8

      JOURNAL_REPO = "https://github.com/Matronhq/matron-journal.git".freeze
      BRIDGE_REPO  = "https://github.com/Matronhq/matron-bridge.git".freeze
      JOURNAL_DIR  = JournalEnrollment::JOURNAL_DIR
      JOURNAL_LOCAL_HTTP = "http://127.0.0.1:9810".freeze
      JOURNAL_LOCAL_WS   = "ws://127.0.0.1:9810/ws".freeze

      def run
        section "Matron chat stack"

        case journal_mode
        when "bundled"
          install_journal
          ensure_journal_user
        when "external"
          probe_external_journal!
        else
          raise "Unknown journal.mode: #{journal_mode.inspect} (expected bundled or external)"
        end

        token_file = enrollment.resolve!
        install_bridge
        write_bridge_env(token_file)
        write_mcp_config
        install_systemd_units
        ok "Matron chat stack ready"
      end

      private

      def journal_mode = config.journal&.mode || "bundled"
      def username = config.user.name
      def home_dir = "/home/#{username}"
      def bridge_dir = "#{home_dir}/matron-bridge"
      def journal_username = config.journal&.username || username
      def unit_dir = "/etc/systemd/system"

      def enrollment
        @enrollment ||= JournalEnrollment.new(
          config: config, shell: shell, log: log, interactive: interactive?,
        )
      end

      # ----- bundled journal -----

      def install_journal
        unless shell.user_exists?("matron")
          shell.sh!("useradd --system --home-dir #{JOURNAL_DIR} --shell /usr/sbin/nologin matron")
          ok "System user matron created"
        end

        if Dir.exist?(JOURNAL_DIR)
          skip "matron-journal already cloned"
          shell.sh!(as_matron("git -C #{JOURNAL_DIR} pull --ff-only"))
        else
          info "Cloning matron-journal"
          shell.sh!("git clone #{JOURNAL_REPO} #{JOURNAL_DIR}")
          shell.sh!("chown -R matron:matron #{JOURNAL_DIR}")
        end

        info "Installing matron-journal dependencies"
        shell.sh!(as_matron("cd #{JOURNAL_DIR} && npm ci --omit=dev"))
        shell.sh!(as_matron("mkdir -p #{JOURNAL_DIR}/data"))

        FileUtils.cp("#{JOURNAL_DIR}/deploy/matron-journal.service", "#{unit_dir}/matron-journal.service")
        shell.sh!("systemctl daemon-reload")
        shell.systemctl(:enable, "matron-journal")
        shell.systemctl(:restart, "matron-journal")

        # /metrics 401s without a token — any HTTP status means it's up.
        unless shell.wait_for_http("#{JOURNAL_LOCAL_HTTP}/metrics", timeout: 30)
          raise "matron-journal failed to start. Check: journalctl -u matron-journal"
        end
        ok "matron-journal running on loopback :9810"
      end

      # Run journal admin/file commands as the matron user — root would
      # leave root-owned SQLite WAL files / git objects behind and break
      # the service (git also refuses cross-owner repos).
      def as_matron(cmd)
        "runuser -u matron -- sh -c #{Shellwords.escape(cmd)}"
      end

      def matron_admin(args)
        as_matron("cd #{JOURNAL_DIR} && MATRON_DB=#{JOURNAL_DIR}/data/matron.db npx matron-admin #{args}")
      end

      def ensure_journal_user
        unless config.journal&.user_password.to_s.empty?
          skip "Journal user #{journal_username} already onboarded (password in secrets.yml)"
          return
        end

        password = SecureRandom.urlsafe_base64(18)
        if journal_user_exists?
          # Partial earlier run: user exists but the password was never
          # recorded. matron-admin user passwd converges us.
          info "Journal user #{journal_username} exists but secrets.yml has no password — resetting it"
          shell.sh!(matron_admin("user passwd #{Shellwords.escape(journal_username)} --password #{Shellwords.escape(password)}"))
        else
          info "Creating journal user #{journal_username}"
          shell.sh!(matron_admin("user add #{Shellwords.escape(journal_username)} --password #{Shellwords.escape(password)}"))
        end
        persist_journal_secrets(password)
        ok "Journal user #{journal_username} ready — the password in secrets.yml is your Matron app login"
      end

      def journal_user_exists?
        shell.sh(matron_admin("device list #{Shellwords.escape(journal_username)}") + " >/dev/null 2>&1")
      end

      def persist_journal_secrets(password)
        raise "secrets_path not provided to runner" unless secrets_path
        Config.merge_into_file(secrets_path, {
          "journal" => { "username" => journal_username, "user_password" => password },
        })
      end

      # ----- external journal -----

      def probe_external_journal!
        url = config.journal&.url
        raise "journal.url is required when journal.mode is external" if url.to_s.empty?
        base = JournalEnrollment.https_base(url)
        info "Probing external journal at #{base}"
        result = JournalEnrollment.probe(base, ca_file: config.journal&.ca_file)
        unless result == :ok
          raise "External journal unreachable at #{base}: #{result}\n" \
                "Refusing to install a bridge that would crash-loop — fix journal.url/journal.ca_file and re-run."
        end
        ok "External journal reachable"
      end

      # ----- bridge -----

      def install_bridge
        if Dir.exist?(bridge_dir)
          skip "matron-bridge already cloned"
          shell.sh("su - #{username} -c 'cd #{bridge_dir} && git pull --ff-only'")
        else
          ensure_dev_user_can_clone
          info "Cloning matron-bridge"
          shell.run_as_user(username, "git clone #{BRIDGE_REPO} #{bridge_dir}")
        end

        if Dir.exist?("#{bridge_dir}/node_modules")
          skip "npm dependencies already installed"
        else
          info "Installing npm dependencies"
          shell.run_as_user(username, "cd #{bridge_dir} && npm install")
        end
        ok "matron-bridge installed"
      end

      # matron-bridge is public, so this probe normally passes silently;
      # it still matters for private forks (BRIDGE_REPO overridden).
      def ensure_dev_user_can_clone
        probe = "GIT_TERMINAL_PROMPT=0 git ls-remote #{Shellwords.escape(BRIDGE_REPO)} HEAD >/dev/null 2>&1"
        if shell.sh("su - #{Shellwords.escape(username)} -c #{Shellwords.escape(probe)}")
          return
        end

        unless interactive?
          raise "#{username} cannot clone #{BRIDGE_REPO}; re-run interactively so we can run `gh auth login --web` as #{username}"
        end

        info "GitHub auth required for #{username} to clone the bridge repo"
        info "About to run: gh auth login --web --git-protocol https --hostname github.com (as #{username})"
        info "You'll see a one-time code and a URL — open the URL in any browser, paste the code, and authorize."
        shell.run_as_user_interactive(username, "gh auth login --web --git-protocol https --hostname github.com")
        shell.run_as_user_interactive(username, "gh auth setup-git")
        ok "GitHub CLI authenticated for #{username}"
      end

      def write_bridge_env(token_file)
        info "Generating bridge .env"
        render_template("matron-bridge.env", "#{bridge_dir}/.env", bridge_env_vars(token_file), mode: 0o600)
        shell.sh!("chown #{username}:#{username} #{bridge_dir}/.env")
        ok "Bridge .env generated"
      end

      # Memoised: rendered into .env + mcp config within one run, and
      # HMAC_SECRET must be identical across those renders. Persisted so
      # re-runs keep old viewer links valid.
      def bridge_env_vars(token_file = nil)
        @bridge_env_vars ||= {
          "JOURNAL_WS_URL" => journal_ws_url,
          "JOURNAL_TOKEN_FILE" => token_file,
          "USERNAME" => username,
          "HMAC_SECRET" => hmac_secret,
          "VIEWER_BASE_URL" => exposure.viewer_base_url,
          "NODE_EXTRA_CA_LINE" => node_extra_ca_line,
        }
      end

      def journal_ws_url
        journal_mode == "bundled" ? JOURNAL_LOCAL_WS : config.journal.url
      end

      def hmac_secret
        existing = config.bridge&.hmac_secret
        return existing unless existing.to_s.empty?
        generated = SecureRandom.hex(32)
        Config.merge_into_file(secrets_path, { "bridge" => { "hmac_secret" => generated } }) if secrets_path
        generated
      end

      def node_extra_ca_line
        ca = config.journal&.ca_file
        ca.to_s.empty? ? "" : "NODE_EXTRA_CA_CERTS=#{ca}"
      end

      def write_mcp_config
        info "Generating bridge MCP config"
        render_template("mcp-config.json", "#{bridge_dir}/mcp-config-generated.json", bridge_env_vars)
        shell.sh!("chown #{username}:#{username} #{bridge_dir}/mcp-config-generated.json")
        ok "Bridge MCP config generated"
      end

      def install_systemd_units
        info "Installing systemd services"
        render_template("matron-bridge.service", "#{unit_dir}/matron-bridge.service", bridge_env_vars)
        render_template("matron-viewer.service", "#{unit_dir}/matron-viewer.service", bridge_env_vars)
        shell.sh!("systemctl daemon-reload")
        shell.systemctl(:enable, "matron-bridge")
        shell.systemctl(:enable, "matron-viewer")
        shell.systemctl(:restart, "matron-bridge")
        shell.systemctl(:restart, "matron-viewer")
        ok "Bridge services installed and started"
      end
    end
  end
end
```

Update `test/modules_shape_test.rb:57`: `%w[browsers claude desktop desktop-apps dev-tools docker exposure hello-world matron security users]`.

- [ ] **Step 5: Run tests**

Run: `rake test TEST=test/matron_module_test.rb && rake test TEST=test/modules_shape_test.rb && rake test`
Expected: PASS. If `test/hello_world_test.rb`'s Task 2 test stubbed a Matrix-named method that no longer matters, leave it — Task 7 rewrites module 11's summary anyway.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "matron: module 08 — bundled journal install + bridge on matron-journal; delete Matrix onboarding"
```

---

### Task 7: Summaries — modules 10 & 11 consume the Exposure interface

**Files:**
- Modify: `lib/dev_boxer/modules/11_hello_world.rb`, `lib/dev_boxer/modules/10_desktop_apps.rb`, `lib/dev_boxer/module_base.rb` (delete `cloudflare_hello_hostname`)
- Test: `test/hello_world_test.rb` (rewrite summary tests), `test/desktop_apps_test.rb` (adapt fixtures)

**Interfaces:**
- Consumes: `ModuleBase#exposure` — `journal_public_url`, `summary_lines`; secrets keys `journal.username` / `journal.user_password` (Task 6).

- [ ] **Step 1: Rewrite the module 11 summary tests**

In `test/hello_world_test.rb`, delete the two Matrix login-instruction tests and add:

```ruby
  def test_matron_login_instructions_bundled_show_server_user_password
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      File.write(secrets_path, { "journal" => { "username" => "dan", "user_password" => "journal-pass" } }.to_yaml)
      output = StringIO.new
      mod = build_module(
        secrets_path: secrets_path,
        output: output,
        config_hash: {
          "user" => { "name" => "dev" },
          "journal" => { "mode" => "bundled" },
          "exposure" => { "mode" => "ip", "ip" => { "address" => "203.0.113.7" } },
        },
      )

      mod.send(:print_matron_login_instructions)

      summary = output.string
      assert_includes summary, "Matron — first login"
      assert_includes summary, "wss://203.0.113.7:8443/ws"
      assert_includes summary, "Username: dan"
      assert_includes summary, "Password: journal-pass"
      assert_includes summary, "bin/enroll"
      refute_match(/matrix/i, summary)
    end
  end

  def test_matron_login_instructions_external_point_at_existing_journal
    output = StringIO.new
    mod = build_module(
      output: output,
      config_hash: {
        "user" => { "name" => "dev" },
        "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" },
        "exposure" => { "mode" => "ip", "ip" => { "address" => "203.0.113.7" } },
      },
    )

    mod.send(:print_matron_login_instructions)

    summary = output.string
    assert_includes summary, "wss://chat.example.com/ws"
    assert_includes summary, "existing"
    refute_includes summary, "Password:"
  end
```

(Match `build_module`'s existing keyword signature in this file; extend it to accept `config_hash:` if it doesn't already.)

- [ ] **Step 2: Run to verify failure**

Run: `rake test TEST=test/hello_world_test.rb`
Expected: FAIL — `print_matron_login_instructions` undefined.

- [ ] **Step 3: Rewrite module 11's summary**

In `lib/dev_boxer/modules/11_hello_world.rb`: delete `print_matrix_login_instructions`, `matrix_login_details`, `public_url`, `matrix_recovery_key`, and the `require "yaml"` if now unused; change the `run` call site to `print_matron_login_instructions`; add:

```ruby
      def print_matron_login_instructions
        info ""
        info "=========================================="
        info "  Matron — first login"
        info "=========================================="
        if config.journal&.mode == "external"
          info "This box's bridge is connected to your existing journal:"
          info "  Server: #{config.journal&.url}"
          info "Open the Matron app with your existing account — this box appears"
          info "under Settings -> Devices once the bridge connects."
        else
          secrets = merged_config_hash
          info "Open the Matron app (iOS / desktop / web) and add this server:"
          info "  Server:   #{exposure.journal_public_url}"
          info "  Username: #{secrets.dig('journal', 'username') || username}"
          info "  Password: #{secrets.dig('journal', 'user_password') || '(missing from secrets.yml)'}"
        end
        exposure.summary_lines.each { |line| info line }
        info ""
        info "If the agent token is ever revoked, re-enroll with: sudo bin/enroll"
      end

      def merged_config_hash
        base = config.respond_to?(:to_h) ? config.to_h : {}
        return base unless secrets_path && File.exist?(secrets_path)
        Config.deep_merge(base, YAML.safe_load_file(secrets_path) || {})
      end
```

(Keep `require "yaml"` — `merged_config_hash` still parses secrets.)

- [ ] **Step 4: Update module 10 and ModuleBase**

`lib/dev_boxer/modules/10_desktop_apps.rb`:
- MOTD block (lines ~155-157): `journalctl -u claude-matrix-bridge -f` → `journalctl -u matron-bridge -f`; `sudo systemctl restart claude-matrix-bridge` → `sudo systemctl restart matron-bridge`; `cd ~/claude-matrix-bridge` → `cd ~/matron-bridge` (keep the box-drawing alignment by padding spaces).
- `print_summary` (lines ~168-192): replace the whole `if config.cloudflare&.tunnel&.hostname … end` block and the Access-warning tail with:

```ruby
        exposure.summary_lines.each { |line| info "  #{line}" }
```

- Delete the now-unused `hostname_hello`/`access_enabled?` helpers in this module if present, and delete `cloudflare_hello_hostname` from `lib/dev_boxer/module_base.rb` (last consumer gone).

In `test/desktop_apps_test.rb`: the fixture builder (lines ~133-148) nests its cloudflare hash under `"exposure" => {"mode" => "cloudflare", "cloudflare" => {…}}`, renames `hostname_matrix` → `hostname_journal`, and adds `"journal" => {"mode" => "bundled"}`; the two Access-warning tests now assert against `Exposure::Cloudflare#summary_lines` content (the warning line text is unchanged); the IP-detection tests are unaffected.

- [ ] **Step 5: Run tests, commit**

Run: `rake test`
Expected: PASS

```bash
git add -A
git commit -m "summaries: modules 10/11 consume the Exposure interface; Matron first-login instructions"
```

---

### Task 8: Retire the remaining Matrix machinery + regression guard

**Files:**
- Delete: `lib/dev_boxer/add_bot.rb`, `lib/dev_boxer/credentials_blob.rb`, `bin/add-bot`, `docs/adding-bots.md`, `test/add_bot_test.rb`, `test/credentials_blob_test.rb`
- Create: `test/no_matrix_regression_test.rb`

- [ ] **Step 1: Write the regression guard**

`test/no_matrix_regression_test.rb`:

```ruby
require_relative "test_helper"

# Matrix was retired in the SP4 journal-only migration. This guard keeps it
# from creeping back into the product surface (docs/superpowers history is
# exempt — those documents describe the migration itself).
class NoMatrixRegressionTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  SCANNED = %w[lib bin templates setup.rb install.sh config.example.yml].freeze
  # "matron" contains no "matrix"; allow nothing...
  PATTERN = /matrix/i.freeze
  # ...except config.rb, whose MATRIX_RETIRED rejection of the old schema
  # must, by definition, name the thing it rejects.
  EXEMPT_FILES = %w[lib/dev_boxer/config.rb].freeze

  def test_no_matrix_references_outside_migration_docs
    offenders = []
    SCANNED.each do |entry|
      path = File.join(ROOT, entry)
      files = File.directory?(path) ? Dir.glob(File.join(path, "**", "*")).select { |f| File.file?(f) } : [path]
      files.each do |file|
        next if EXEMPT_FILES.any? { |exempt| file.end_with?(exempt) }
        File.foreach(file).with_index(1) do |line, number|
          offenders << "#{file}:#{number}: #{line.strip}" if line.match?(PATTERN)
        end
      end
    end
    assert_empty offenders, "Matrix references found:\n#{offenders.join("\n")}"
  end
end
```

- [ ] **Step 2: Run to see current offenders**

Run: `rake test TEST=test/no_matrix_regression_test.rb`
Expected: FAIL listing `lib/dev_boxer/add_bot.rb`, `lib/dev_boxer/credentials_blob.rb`, `bin/add-bot` (and nothing else — if anything else appears, it's a leftover from Tasks 3-7; fix it now).

- [ ] **Step 3: Delete the add-bot machinery**

```bash
git rm lib/dev_boxer/add_bot.rb lib/dev_boxer/credentials_blob.rb bin/add-bot docs/adding-bots.md test/add_bot_test.rb test/credentials_blob_test.rb
```

Remove any `require`/`require_relative` of `add_bot` or `credentials_blob` (check `lib/dev_boxer.rb` and `grep -rn "credentials_blob\|add_bot" lib bin setup.rb`).

- [ ] **Step 4: Run tests, commit**

Run: `rake test`
Expected: PASS, including the regression guard.

```bash
git add -A
git commit -m "retire add-bot/credentials-blob machinery; add no-matrix regression guard"
```

---

### Task 9: Docs — README, exposure-modes, cloudflare-access

**Files:**
- Rewrite: `README.md`
- Create: `docs/exposure-modes.md`
- Modify: `docs/cloudflare-access.md`, `docs/adding-mcp-servers.md`

- [ ] **Step 1: Create docs/exposure-modes.md**

```markdown
# Exposure modes

How your box is reached from the internet is one config choice: `exposure.mode`.

| | `cloudflare` | `ip` |
|---|---|---|
| Needs a domain | Yes (Cloudflare-managed; ~$5-6/yr) | No |
| Certificate | Real, trusted everywhere | Self-signed; apps must accept/pin it |
| Inbound ports | None (outbound tunnel) | 8443-8445 open (nginx) |
| SSO in front | Optional (Cloudflare Access) | No |
| Project subdomains later | Yes (`public-*.<zone>`) | No |
| Setup speed | Slower (tokens, DNS) | Fast |

## `cloudflare`

A Cloudflare Tunnel publishes `dev.<zone>`, `chat.<zone>` (bundled journal
only), `viewer.<zone>`, and `hello.<zone>` without opening inbound ports.
Optional Zero Trust Access puts browser surfaces behind SSO — see
[cloudflare-access.md](cloudflare-access.md).

## `ip`

No domain required. Dev Boxer generates a 10-year self-signed certificate
with the server's IP as its subject-alternative name, terminates TLS with
nginx, and opens only the ports in use:

| Port (default) | Serves |
|---|---|
| 8443 | `wss://<ip>:8443/ws` — the journal (bundled mode only) |
| 8444 | `https://<ip>:8444` — file viewer |
| 8445 | `https://<ip>:8445` — hello-world smoke test |

Setup prints the certificate's **SHA-256 fingerprint**. Your Matron app
warns about the unknown certificate on first connection — accept it only if
the fingerprint matches. If the server's IP changes, re-running `setup.rb`
regenerates the certificate (new fingerprint, apps must re-accept).

Trade-off to know: until the Matron apps ship pinned-certificate trust
(SP5), only clients that can accept a self-signed cert can connect.
```

- [ ] **Step 2: Rewrite README.md**

Keep the overall document shape (quick start, no-VPS section, private-forks note, bootstrap instructions) and make these content changes:

1. Tagline: `Set up an Ubuntu 24.04 VPS as a remote Claude Code development environment — Matron chat stack, desktop GUI, security hardening, and your choice of Cloudflare Tunnel or plain IP + self-signed TLS — in one command.`
2. Ecosystem table: drop the `Matron Server` (Matrix homeserver) row; `claude-matrix-bridge` row becomes `[matron-bridge](https://github.com/Matronhq/matron-bridge) | Runs Claude Code sessions and connects them to the journal`; fix the iOS repo name to `matron-apple` if present.
3. "What you get": replace the Matrix bridge + Matron Server bullets with:
   - `**Matron chat** -- talk to Claude Code from the Matron apps (iOS/desktop/web); this box runs [matron-bridge](https://github.com/Matronhq/matron-bridge) and, in bundled mode, its own [matron-journal](https://github.com/Matronhq/matron-journal) sync server`
   - `**Two exposure modes** -- your own domain via Cloudflare Tunnel, or no domain at all via IP + self-signed TLS (see [docs/exposure-modes.md](docs/exposure-modes.md))`
4. Prerequisites: Cloudflare bullets become `- **Cloudflare mode only:** a Cloudflare account with a domain, a zone DNS API token, and optionally a one-time account setup token` and add `- **IP mode:** nothing extra — no domain needed`.
5. "It asks for": replace the Matrix username bullet with `- Where the journal lives: bundled on this box, or the wss:// URL of an existing one` and `- Exposure mode: cloudflare (domain) or ip (self-signed)`; note it derives `dev.<domain>`, `chat.<domain>`, `viewer.<domain>`, `hello.<domain>` in Cloudflare mode.
6. Add a `## Re-enrolling an agent` section: revoked token / moved journal → `sudo bin/enroll`.
7. Add the breaking-change section:

```markdown
## Upgrading from a Matrix-era install

Dev Boxer no longer installs Matrix anything. Config schema v2 removes the
`matrix:` section (setup fails with a pointer here if one is present) and
adds `journal:` + `exposure:`. There is no automatic migration: back up
`config.yml`/`secrets.yml`, re-run `sudo ./setup.rb --reconfigure`, and
answer the journal/exposure questions. Chat history does not carry over —
the journal is a new store.
```

8. Global sweep: no `matrix`, `Element`, `homeserver`, `recovery key`, `add-bot` references remain **outside the "Upgrading from a Matrix-era install" section** (which necessarily names Matrix): `grep -in "matrix\|element\|homeserver\|add-bot" README.md` → only lines from that section.

- [ ] **Step 3: Update docs/cloudflare-access.md and docs/adding-mcp-servers.md**

- `docs/cloudflare-access.md`: replace every `matrix.<zone>`/`hostname_matrix`/"Matrix clients" reference with `chat.<zone>`/`hostname_journal`/"Matron apps"; config path examples gain the `exposure.cloudflare.` prefix. `grep -in matrix docs/cloudflare-access.md` → empty.
- `docs/adding-mcp-servers.md`: `~/claude-matrix-bridge` → `~/matron-bridge`; `claude-matrix-bridge.service` → `matron-bridge.service`; any `MATRIX_BRIDGE_API_PORT` mention → `BRIDGE_API_URL`/`MATRON_BRIDGE_API_PORT` per the mcp-config template. `grep -in matrix docs/adding-mcp-servers.md` → empty.

- [ ] **Step 4: Verify and commit**

Run: `grep -rin "matrix" docs/exposure-modes.md docs/cloudflare-access.md docs/adding-mcp-servers.md; grep -in "matrix" README.md`
Expected: nothing from the three docs files; from README.md only lines inside the "Upgrading from a Matrix-era install" section.

Run: `rake test`
Expected: PASS

```bash
git add README.md docs/
git commit -m "docs: journal-only README, exposure-modes tradeoffs, journal hostnames in cloudflare-access"
```

---

### Task 10: Final sweep — dry run, idempotency review, E2E checklist

**Files:**
- Modify: none expected (fixes only if the sweep finds issues)

- [ ] **Step 1: Full suite + dry run**

```bash
rake test
ruby setup.rb --dry-run --config /tmp/nonexistent-config.yml; echo "exit: $?"
```

Expected: suite PASS; the dry-run exits 2 with "Config file not found" (explicit `--config`) — confirms setup.rb loads with the new module set. Then:

```bash
cd "$(mktemp -d)" && cat > config.yml <<'EOF'
user: { name: dev, ssh_public_key: "ssh-ed25519 AAAATEST t@e", rdp_password: x }
ssh: { port: 2222 }
journal: { mode: bundled, username: dev }
exposure: { mode: ip }
hello_world: { port: 9820 }
EOF
ruby ~/dev-boxer/setup.rb --dry-run --config ./config.yml
```

Expected: exit 0; the plan lists 11 modules with `08 matron` and `09 exposure`.

- [ ] **Step 2: Idempotency desk-check**

Re-read `08_matron.rb` and `exposure/self_signed.rb` confirming every step is skip-or-converge on re-run: journal clone (pull), npm ci (re-runs, converges), user matron (guarded), journal user (password-in-secrets guard + passwd fallback), agent token (enrollment step 2), bridge clone (pull), .env/units (re-render, same content), cert (SAN guard), nginx (rewrite same content), ufw (`ufw allow` is idempotent), cloudflare (tunnel-id/app-id guards — unchanged code). Fix anything that would duplicate or clobber.

- [ ] **Step 3: Record the manual E2E smoke checklist as a PR note**

These need real machines and the Matron apps — they are operator follow-ups after merge, not executor steps. Copy into the PR description:

```
E2E smoke (spec §Verification) — run before tagging:
[ ] Fresh Ubuntu 24.04 VPS, bundled+ip: sudo ./setup.rb; Matron app connects to
    wss://<ip>:8443/ws past the self-signed warning (fingerprint matches the
    setup summary); `new <dir>` spawns a session; a file write posts a viewer
    link that works over :8444; hello-world answers on :8445.
[ ] Same box, second `sudo ./setup.rb` run: all modules skip/converge, no
    service restarts loops, cert fingerprint unchanged.
[ ] external+cloudflare against a central journal with a pre-provisioned
    journal.token_file: bridge connects, no journal hostname/DNS created.
[ ] external+cloudflare via pairing: code displayed, approve in app
    (Settings -> Devices -> Add Agent), token lands in /etc/matron/agent-token,
    bridge connects; then revoke the device in the app and recover with
    sudo bin/enroll.
```

- [ ] **Step 4: Push and open the PR**

```bash
git push -u origin feat/sp4-journal-only
gh pr create --repo Matronhq/dev-boxer --base main \
  --title "SP4: journal-only provisioning — matron-journal/matron-bridge, IP + self-signed WSS exposure" \
  --body-file <(cat <<'EOF'
Implements docs/superpowers/specs/2026-07-16-sp4-dev-boxer-journal-only-design.md.

- journal.mode bundled|external; exposure.mode cloudflare|ip (config schema v2, breaking)
- Module 08 -> matron: bundled matron-journal install + matron-bridge; enrollment
  resolution: token file > existing > local mint > app pairing > non-interactive fail
- Module 09 -> exposure strategies: Cloudflare (moved intact) + SelfSigned (new)
- Wizard split into sections; Config.validation_errors derives from section declarations
- bin/enroll replaces bin/add-bot; all Matrix machinery deleted (regression-guarded)

E2E smoke checklist (operator, post-merge):
<paste Step 3 checklist here>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)
```

(Note: the spec branch `docs/sp4-journal-only-spec` must merge first or be included — this branch contains it since we branched from it; the PR will show the spec commit too, which is fine.)

---

## Self-Review Notes (already applied)

- **Spec coverage check:** config v2 (T1/T2), module 08 bundled+external (T6), enrollment + bin/enroll + pairing edge behavior (T5), exposure interface + self-signed + cloudflare-moved (T4), wizard restructure + --non-interactive (T3), deletions/renames (T4/T6/T8), docs (T9), error handling (probe T6, SAN regen T4, partial onboarding T6, revoked-token recovery documented T7/T9), verification (unit throughout, E2E checklist T10, idempotency T10). Port-collision fix (spec risk) lands in T2, before the bundled journal install in T6. ✓
- **Ordering deviation from spec prose:** wizard asks journal before exposure (exposure needs `journal.mode` for the journal hostname). Deliberate; noted in T3.
- **`matron-admin` runs as the `matron` user** via `runuser` (not in the spec's text) — root-run better-sqlite3 would leave root-owned WAL files and break the service. T5/T6.
- **`hmac_secret` lives at `bridge.hmac_secret`** in secrets.yml (spec says "secrets.yml keeps hmac_secret"; the old home `matrix.hmac_secret` is impossible in v2).
- **Non-interactive exit code is 2, not the spec's 1** — setup.rb already exits 2 for every config problem (missing file, invalid options, incomplete config) and consistency wins; the spec's intent (fail fast, list the missing keys) is preserved. The spec's "'Reuse existing config?' auto-answers yes" is satisfied vacuously: with a complete pre-seeded config setup.rb never invokes the wizard, so no prompt exists to answer.
