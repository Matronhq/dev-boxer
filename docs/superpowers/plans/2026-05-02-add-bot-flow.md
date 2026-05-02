# Add-bot Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `dev-boxer add-bot <name>` on the homeserver host that registers a new bot, has the user cross-sign it via emoji-SAS in Element, and prints a creds blob; on a fresh box, the wizard accepts that blob and the bridge bootstraps itself on first start.

**Architecture:** Two repos, two phases. Phase 1 is Ruby code in `dev-boxer` (this repo): a `CredentialsBlob` lib, an `AddBot` orchestrator, a `here / there` wizard branch, and new bot env vars wired through the matrix-bridge module. Phase 2 is JS code in `~/claude-matrix-bridge`: an `add-bot.mjs` script that drives the verification dance, plus an inline first-start bootstrap in `index.js` that turns a paste-blob into a verified bridge device.

**Tech Stack:** Ruby 3.x + minitest (dev-boxer), Node.js 20 + matrix-js-sdk + matrix-bot-sdk + vitest (claude-matrix-bridge).

**Spec:** `docs/superpowers/specs/2026-05-02-add-bot-flow-design.md`.

**Repos:**
- This repo: `/home/youruser/dev-boxer`
- Bridge repo: `/home/youruser/claude-matrix-bridge` (separate git repo)

---

## Phase 1 — dev-boxer (Ruby)

Branch: `feat/add-bot-flow-design` (already created during brainstorming and the spec is committed there).

### Task 1: CredentialsBlob library

**Goal:** A pure Ruby class that encodes/decodes the `db1:<base64-json>` blob and validates required keys. No I/O.

**Files:**
- Create: `lib/dev_boxer/credentials_blob.rb`
- Test: `test/credentials_blob_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/credentials_blob_test.rb`:

```ruby
require_relative "test_helper"
require_relative "../lib/dev_boxer/credentials_blob"

class CredentialsBlobTest < Minitest::Test
  REQUIRED = {
    "homeserver_url"   => "https://matrix.example.com",
    "server_domain"    => "matrix.example.com",
    "bot_user_id"      => "@box4:matrix.example.com",
    "bot_password"     => "p4ssw0rd",
    "bot_recovery_key" => "EsTm 4uK4 abcd",
    "bridge_room_id"   => "!abc:matrix.example.com",
  }.freeze

  def test_round_trip
    encoded = DevBoxer::CredentialsBlob.encode(REQUIRED)
    assert_match(/\Adb1:/, encoded)

    decoded = DevBoxer::CredentialsBlob.decode(encoded)
    assert_equal REQUIRED, decoded
  end

  def test_decode_rejects_unknown_version_prefix
    encoded = DevBoxer::CredentialsBlob.encode(REQUIRED).sub(/\Adb1:/, "db2:")
    err = assert_raises(DevBoxer::CredentialsBlob::Invalid) { DevBoxer::CredentialsBlob.decode(encoded) }
    assert_match(/version/i, err.message)
  end

  def test_decode_rejects_missing_prefix
    body = DevBoxer::CredentialsBlob.encode(REQUIRED).split(":", 2)[1]
    assert_raises(DevBoxer::CredentialsBlob::Invalid) { DevBoxer::CredentialsBlob.decode(body) }
  end

  def test_decode_rejects_malformed_base64
    assert_raises(DevBoxer::CredentialsBlob::Invalid) { DevBoxer::CredentialsBlob.decode("db1:not-base64-!!") }
  end

  def test_decode_rejects_missing_required_key
    partial = REQUIRED.reject { |k, _| k == "bot_password" }
    encoded = DevBoxer::CredentialsBlob.encode(partial)
    err = assert_raises(DevBoxer::CredentialsBlob::Invalid) { DevBoxer::CredentialsBlob.decode(encoded) }
    assert_match(/bot_password/, err.message)
  end

  def test_decode_rejects_bot_user_id_with_wrong_domain
    bad = REQUIRED.merge("bot_user_id" => "@box4:other.example.com")
    encoded = DevBoxer::CredentialsBlob.encode(bad)
    err = assert_raises(DevBoxer::CredentialsBlob::Invalid) { DevBoxer::CredentialsBlob.decode(encoded) }
    assert_match(/server_domain/, err.message)
  end
end
```

- [ ] **Step 2: Run the failing test**

```
cd /home/youruser/dev-boxer && ruby -Ilib -Itest test/credentials_blob_test.rb
```

Expected: failure (`uninitialized constant DevBoxer::CredentialsBlob` or similar).

- [ ] **Step 3: Implement `CredentialsBlob`**

Create `lib/dev_boxer/credentials_blob.rb`:

```ruby
require "base64"
require "json"

module DevBoxer
  module CredentialsBlob
    Invalid = Class.new(StandardError)

    VERSION = "db1".freeze
    REQUIRED_KEYS = %w[
      homeserver_url
      server_domain
      bot_user_id
      bot_password
      bot_recovery_key
      bridge_room_id
    ].freeze

    USER_ID_RE = /\A@(?<localpart>[^:]+):(?<domain>.+)\z/

    def self.encode(hash)
      missing = REQUIRED_KEYS - hash.keys
      raise Invalid, "missing required keys: #{missing.join(', ')}" unless missing.empty?

      payload = REQUIRED_KEYS.each_with_object({}) { |k, h| h[k] = hash.fetch(k) }
      "#{VERSION}:" + Base64.strict_encode64(JSON.dump(payload))
    end

    def self.decode(input)
      raise Invalid, "input must include version prefix '#{VERSION}:'" unless input.is_a?(String) && input.include?(":")

      version, body = input.split(":", 2)
      raise Invalid, "unknown blob version #{version.inspect} (expected #{VERSION})" unless version == VERSION

      decoded =
        begin
          Base64.strict_decode64(body)
        rescue ArgumentError
          raise Invalid, "blob body is not valid base64"
        end

      hash =
        begin
          JSON.parse(decoded)
        rescue JSON::ParserError => e
          raise Invalid, "blob body is not valid JSON: #{e.message}"
        end

      missing = REQUIRED_KEYS - hash.keys
      raise Invalid, "blob missing required keys: #{missing.join(', ')}" unless missing.empty?

      m = hash["bot_user_id"].match(USER_ID_RE)
      raise Invalid, "bot_user_id #{hash['bot_user_id'].inspect} is not a valid Matrix user ID" unless m
      raise Invalid, "bot_user_id domain #{m[:domain].inspect} does not match server_domain #{hash['server_domain'].inspect}" if m[:domain] != hash["server_domain"]

      hash
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

```
cd /home/youruser/dev-boxer && ruby -Ilib -Itest test/credentials_blob_test.rb
```

Expected: 6 runs, 0 failures.

- [ ] **Step 5: Run the full suite**

```
cd /home/youruser/dev-boxer && rake test
```

Expected: all green; new tests included.

- [ ] **Step 6: Commit**

```
git add lib/dev_boxer/credentials_blob.rb test/credentials_blob_test.rb
git commit -m "$(cat <<'EOF'
feat(add-bot): credentials blob encode/decode lib

Pure Ruby class for the db1:<base64-json> blob exchanged between
add-bot and the box-2 wizard. Validates required keys and that
bot_user_id's domain matches server_domain.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Extract registration helpers from MatrixBridge

**Goal:** Lift `open_registration` / `close_registration` / `register_bot_via_api` out of `MatrixBridge` into a service object so `AddBot` can reuse them. `MatrixBridge`'s public behaviour and existing tests stay green.

**Files:**
- Create: `lib/dev_boxer/matrix_registration.rb`
- Modify: `lib/dev_boxer/modules/08_matrix_bridge.rb`
- Modify: `test/matrix_bridge_test.rb` (extend to cover the existing public flow path with the new internal collaborator)
- Test: `test/matrix_registration_test.rb`

- [ ] **Step 1: Write the failing test for the service object**

Create `test/matrix_registration_test.rb`:

```ruby
require_relative "test_helper"
require "tmpdir"
require_relative "../lib/dev_boxer/matrix_registration"

class MatrixRegistrationTest < Minitest::Test
  def test_open_writes_override_with_token_and_restarts
    Dir.mktmpdir do |dir|
      cmds = []
      shell = DevBoxer::Shell.new(runner: ->(cmd, _opts = {}) { cmds << cmd; [true, "", ""] })
      reg = DevBoxer::MatrixRegistration.new(
        matrix_server_dir: dir, username: "dev", shell: shell,
        log: DevBoxer::Log.new(io: StringIO.new, color: false),
      )

      reg.stub(:wait_for_ready, true) do
        reg.open("token-123")
      end

      override = File.read(File.join(dir, "docker-compose.override.yml"))
      assert_includes override, 'TUWUNEL_REGISTRATION_TOKEN: "token-123"'
      assert_includes override, 'TUWUNEL_ALLOW_REGISTRATION: "true"'
      assert(cmds.any? { |c| c.include?("docker compose down") }, "compose down expected")
      assert(cmds.any? { |c| c.include?("docker compose up -d") }, "compose up expected")
    end
  end

  def test_close_removes_override_and_restarts
    Dir.mktmpdir do |dir|
      override = File.join(dir, "docker-compose.override.yml")
      File.write(override, "stub")
      shell = DevBoxer::Shell.new(runner: ->(_cmd, _opts = {}) { [true, "", ""] })
      reg = DevBoxer::MatrixRegistration.new(
        matrix_server_dir: dir, username: "dev", shell: shell,
        log: DevBoxer::Log.new(io: StringIO.new, color: false),
      )

      reg.stub(:wait_for_ready, true) do
        reg.close
      end

      refute File.exist?(override), "override should be removed"
    end
  end

  def test_close_swallows_missing_override_quietly
    Dir.mktmpdir do |dir|
      shell = DevBoxer::Shell.new(runner: ->(_cmd, _opts = {}) { [true, "", ""] })
      reg = DevBoxer::MatrixRegistration.new(
        matrix_server_dir: dir, username: "dev", shell: shell,
        log: DevBoxer::Log.new(io: StringIO.new, color: false),
      )

      reg.stub(:wait_for_ready, true) do
        reg.close   # must not raise
      end
    end
  end

  def test_register_bot_returns_true_on_success_and_on_user_in_use
    posted = []
    http = ->(path, body, _bearer = nil) {
      posted << [path, body]
      body[:auth][:session] ? { "user_id" => "@box4:matrix.example.com" } : { "session" => "s" }
    }
    reg = DevBoxer::MatrixRegistration.new(
      matrix_server_dir: "/tmp", username: "dev", shell: nil, http: http,
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
    )

    assert reg.register_bot(username: "box4", password: "pw", reg_token: "tok")
    assert_equal 2, posted.length, "should POST twice (initial + with session)"

    in_use = ->(_path, _body, _bearer = nil) { { "errcode" => "M_USER_IN_USE" } }
    reg2 = DevBoxer::MatrixRegistration.new(
      matrix_server_dir: "/tmp", username: "dev", shell: nil, http: in_use,
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
    )
    assert reg2.register_bot(username: "box4", password: "pw", reg_token: "tok")
  end

  def test_register_bot_raises_on_unknown_failure
    http = ->(_path, _body, _bearer = nil) { { "errcode" => "M_FORBIDDEN" } }
    reg = DevBoxer::MatrixRegistration.new(
      matrix_server_dir: "/tmp", username: "dev", shell: nil, http: http,
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
    )
    assert_raises(DevBoxer::MatrixRegistration::Error) do
      reg.register_bot(username: "box4", password: "pw", reg_token: "tok")
    end
  end
end
```

- [ ] **Step 2: Run the failing test**

```
cd /home/youruser/dev-boxer && ruby -Ilib -Itest test/matrix_registration_test.rb
```

Expected: failure (`uninitialized constant DevBoxer::MatrixRegistration`).

- [ ] **Step 3: Create the service object**

Create `lib/dev_boxer/matrix_registration.rb`:

```ruby
require "fileutils"
require "json"
require "net/http"
require "shellwords"
require "uri"

module DevBoxer
  # Service object that owns the homeserver registration window plus
  # bot registration POSTs. Extracted from MatrixBridge so that AddBot
  # can drive the same flow without duplicating it.
  class MatrixRegistration
    Error = Class.new(StandardError)

    HOMESERVER_LOCAL = "http://localhost:6167".freeze

    def initialize(matrix_server_dir:, username:, shell:, log:, http: nil, homeserver_url: HOMESERVER_LOCAL)
      @matrix_server_dir = matrix_server_dir
      @username = username
      @shell = shell
      @log = log
      @homeserver_url = homeserver_url
      @http = http || method(:default_http_post)
    end

    def open(reg_token)
      File.write(override_path, <<~YML)
        services:
          matron-server:
            environment:
              TUWUNEL_ALLOW_REGISTRATION: "true"
              TUWUNEL_REGISTRATION_TOKEN: "#{reg_token}"
      YML
      shell.sh!("chown #{@username}:#{@username} #{override_path}")
      shell.run_as_user(@username, "cd #{@matrix_server_dir} && docker compose down && docker compose up -d")
      wait_for_ready or raise Error, "Matron Server failed to restart with registration enabled"
    end

    def close
      begin
        File.delete(override_path) if File.exist?(override_path)
      rescue Errno::ENOENT
        # already gone — fine
      rescue => e
        log.warn("Could not remove #{override_path}: #{e.class}: #{e.message}")
      end
      shell.run_as_user(@username, "cd #{@matrix_server_dir} && docker compose down && docker compose up -d") rescue nil
      wait_for_ready rescue nil
    end

    # Returns true if the bot account exists after this call (either
    # because we just created it or because it was already there).
    def register_bot(username:, password:, reg_token:)
      body = {
        username: username, password: password,
        auth: { type: "m.login.registration_token", token: reg_token },
        inhibit_login: true,
      }
      resp = @http.call("/_matrix/client/v3/register", body)
      return true if resp["user_id"]

      if (session = resp["session"])
        body[:auth][:session] = session
        resp = @http.call("/_matrix/client/v3/register", body)
        return true if resp["user_id"]
      end

      return true if resp["errcode"] == "M_USER_IN_USE"
      raise Error, "Bot registration failed: #{resp.inspect}"
    end

    private

    attr_reader :shell, :log

    def override_path
      File.join(@matrix_server_dir, "docker-compose.override.yml")
    end

    def wait_for_ready
      shell.wait_for_url("#{@homeserver_url}/_matrix/client/versions", timeout: 30)
    end

    def default_http_post(path, body, bearer = nil)
      uri = URI("#{@homeserver_url}#{path}")
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req["Authorization"] = "Bearer #{bearer}" if bearer
      req.body = JSON.dump(body)
      res = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
      JSON.parse(res.body)
    rescue JSON::ParserError
      { "errcode" => "INVALID_RESPONSE", "raw" => res&.body }
    end
  end
end
```

- [ ] **Step 4: Update MatrixBridge to use the service**

Edit `lib/dev_boxer/modules/08_matrix_bridge.rb`:

Replace the private methods `open_registration`, `close_registration`, and `register_bot_via_api` with delegations to `MatrixRegistration`. Specifically:

- At the top, after the existing `require` block, add:
  ```ruby
  require_relative "../matrix_registration"
  ```
- Add a memoised helper:
  ```ruby
  def matrix_registration
    @matrix_registration ||= MatrixRegistration.new(
      matrix_server_dir: matrix_server_dir,
      username: username,
      shell: shell,
      log: log,
    )
  end
  ```
- Replace the body of `open_registration` with `matrix_registration.open(reg_token)`.
- Replace the body of `close_registration` with `matrix_registration.close`.
- Replace the body of `register_bot_via_api` with `matrix_registration.register_bot(username: bot_username, password: password, reg_token: reg_token)`.

Keep the surrounding `info`/`ok` log lines that the existing flow uses.

- [ ] **Step 5: Run all tests**

```
cd /home/youruser/dev-boxer && rake test
```

Expected: all green. The new `MatrixRegistration` tests pass; existing `MatrixBridgeTest` tests still pass because the public surface didn't change.

- [ ] **Step 6: Commit**

```
git add lib/dev_boxer/matrix_registration.rb test/matrix_registration_test.rb lib/dev_boxer/modules/08_matrix_bridge.rb
git commit -m "$(cat <<'EOF'
refactor(matrix): extract registration window into MatrixRegistration

Lifts open_registration/close_registration/register_bot helpers out of
the MatrixBridge module so AddBot can drive the same homeserver flow
without duplicating it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Config schema for new matrix fields

**Goal:** Allow `bot_user_id`, `bot_password`, `bot_recovery_key`, `bridge_room_id`, and the `bots:` map under `matrix.*` in config/secrets without `Config.validation_errors` rejecting them. No new required fields.

**Files:**
- Modify: `config.example.yml`
- Modify: `test/config_test.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/config_test.rb` (inside the existing test class):

```ruby
def test_external_mode_with_imported_bot_creds_validates_when_other_required_fields_present
  config = DevBoxer::Config.from_hash(base_valid_config_hash.merge(
    "matrix" => {
      "mode" => "external",
      "homeserver_url" => "https://matrix.example.com",
      "server_domain" => "matrix.example.com",
      "user_username" => "dev",
      "bot_user_id" => "@box4:matrix.example.com",
      "bot_password" => "pw",
      "bot_recovery_key" => "EsTm 4uK4",
      "bridge_room_id" => "!abc:matrix.example.com",
    },
  ))
  assert_empty DevBoxer::Config.validation_errors(config)
end

def test_bots_map_under_matrix_is_accepted
  base = base_valid_config_hash
  base_matrix = base["matrix"] || {}
  bots_extension = {
    "bots" => {
      "box4" => {
        "bot_user_id" => "@box4:matrix.example.com",
        "bot_password" => "pw",
        "bot_recovery_key" => "EsTm 4uK4",
        "bridge_room_id" => "!abc:matrix.example.com",
        "created_at" => "2026-05-02T12:34:56Z",
      },
    },
  }
  hash = base.merge("matrix" => DevBoxer::Config.deep_merge(base_matrix, bots_extension))
  config = DevBoxer::Config.from_hash(hash)
  assert_empty DevBoxer::Config.validation_errors(config)
end
```

If `base_valid_config_hash` doesn't already exist in the test file, add it as a private helper at the bottom (look at the existing tests to see how a valid config is constructed today and copy that hash). Use `DevBoxer::Config.deep_merge` (defined in `lib/dev_boxer/config.rb`) — `Hash#deep_merge` is not in stdlib.

- [ ] **Step 2: Run the failing test**

```
cd /home/youruser/dev-boxer && ruby -Ilib -Itest test/config_test.rb
```

Expected: failure (`undefined method` for the helper, or schema rejecting unknown keys — depends on current state).

- [ ] **Step 3: Inspect existing config validation to confirm whether keys need to be allow-listed**

Read `lib/dev_boxer/config.rb`. The current schema validation only checks for *required* keys, not unknown ones. So the new keys should validate fine without code changes — the only thing this task gates is documentation and test coverage.

- [ ] **Step 4: Update `config.example.yml`**

Read the current `matrix:` section in `config.example.yml`. Below the existing comments, add:

```yaml
matrix:
  mode: bundled            # bundled | external
  # ... existing keys ...

  # When mode == external and you used `dev-boxer add-bot` on another
  # box, the wizard places the imported bot creds here. The bridge's
  # first-start bootstrap consumes them, then writes back bot_access_token.
  # bot_user_id:      "@box4:matrix.example.com"
  # bot_password:     "..."
  # bot_recovery_key: "..."
  # bridge_room_id:   "!abc:matrix.example.com"

  # On a homeserver-host box, `dev-boxer add-bot <name>` records each
  # issued bot here so `--reprint` can regenerate the blob without
  # touching the homeserver. No bot_access_token is stored — the receiving
  # box mints its own.
  # bots:
  #   box4:
  #     bot_user_id:      "@box4:matrix.example.com"
  #     bot_password:     "..."
  #     bot_recovery_key: "..."
  #     bridge_room_id:   "!abc:matrix.example.com"
  #     created_at:       2026-05-02T12:34:56Z
```

(Keep the existing keys; only add the new commented blocks.)

- [ ] **Step 5: Run the full suite**

```
cd /home/youruser/dev-boxer && rake test
```

Expected: all green.

- [ ] **Step 6: Commit**

```
git add config.example.yml test/config_test.rb
git commit -m "$(cat <<'EOF'
docs(config): document add-bot fields and bots map under matrix

Adds commented examples for the new external-mode bot creds
(bot_user_id/bot_password/bot_recovery_key/bridge_room_id) and the
homeserver-host bots: map. Validates that the schema accepts them.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Wizard `here / there` branch + blob import

**Goal:** Replace the matrix prompt with a `here / there` choice. `here` keeps today's behaviour. `there` prompts for a blob, decodes it via `CredentialsBlob`, and persists creds to `secrets.yml`.

**Files:**
- Modify: `lib/dev_boxer/wizard.rb`
- Modify: `test/wizard_test.rb`

- [ ] **Step 1: Add a failing wizard test for the `there` branch**

Open `test/wizard_test.rb` and add:

```ruby
def test_there_branch_decodes_blob_and_writes_secrets
  Dir.mktmpdir do |dir|
    config_path = File.join(dir, "config.yml")
    secrets_path = File.join(dir, "secrets.yml")
    blob_hash = {
      "homeserver_url"   => "https://matrix.example.com",
      "server_domain"    => "matrix.example.com",
      "bot_user_id"      => "@box4:matrix.example.com",
      "bot_password"     => "pw",
      "bot_recovery_key" => "EsTm 4uK4",
      "bridge_room_id"   => "!abc:matrix.example.com",
    }
    blob = DevBoxer::CredentialsBlob.encode(blob_hash)

    answers = wizard_answers_for_there_branch(blob: blob)
    output = StringIO.new
    DevBoxer::Wizard.run(
      config_path: config_path,
      input: StringIO.new(answers),
      output: output,
    )

    config = YAML.safe_load_file(config_path)
    secrets = YAML.safe_load_file(secrets_path)

    assert_equal "external", config.dig("matrix", "mode")
    assert_equal "https://matrix.example.com", config.dig("matrix", "homeserver_url")
    assert_equal "matrix.example.com", config.dig("matrix", "server_domain")
    assert_equal "box4", config.dig("matrix", "bot_username")

    assert_equal "@box4:matrix.example.com", secrets.dig("matrix", "bot_user_id")
    assert_equal "pw", secrets.dig("matrix", "bot_password")
    assert_equal "EsTm 4uK4", secrets.dig("matrix", "bot_recovery_key")
    assert_equal "!abc:matrix.example.com", secrets.dig("matrix", "bridge_room_id")
  end
end

def test_there_branch_re_prompts_on_malformed_blob
  Dir.mktmpdir do |dir|
    config_path = File.join(dir, "config.yml")
    blob_hash = {
      "homeserver_url"   => "https://matrix.example.com",
      "server_domain"    => "matrix.example.com",
      "bot_user_id"      => "@box4:matrix.example.com",
      "bot_password"     => "pw",
      "bot_recovery_key" => "EsTm 4uK4",
      "bridge_room_id"   => "!abc:matrix.example.com",
    }
    valid_blob = DevBoxer::CredentialsBlob.encode(blob_hash)

    # First answer for the blob is garbage; second is valid.
    answers = wizard_answers_for_there_branch(blob: "garbage\n#{valid_blob}", inject_two_blob_answers: true)
    output = StringIO.new
    DevBoxer::Wizard.run(
      config_path: config_path,
      input: StringIO.new(answers),
      output: output,
    )

    assert_match(/blob/i, output.string)
    assert File.exist?(File.join(dir, "secrets.yml"))
  end
end

private

# Build the answer script that walks every prompt the wizard asks
# in order. Read `lib/dev_boxer/wizard.rb#build_config` to confirm
# the order before running this — it changes as the wizard evolves.
# Each line corresponds to one `gets` call.
def wizard_answers_for_there_branch(blob:, inject_two_blob_answers: false)
  blob_lines = inject_two_blob_answers ? blob.split("\n") : [blob]
  ([
    "dev",                         # Linux username
    "ssh-rsa AAA fake-key",        # SSH public key
    "2222",                        # SSH port
    "example.com",                 # base domain
    "y",                           # confirm DNS overwrite (or whatever current default)
    "fake-zone-token",             # zone DNS token
    "n",                           # automatic tunnel? — default
    "n",                           # automatic Access? — default
    "there",                       # matrix mode
  ] + blob_lines + [
    "intermediate",                # claude experience level
    "y",                           # accept defaults / final confirm
  ]).join("\n") + "\n"
end
```

The answer script above is a starting point. Run the wizard tests after pasting it; if they hang or fail with "stream closed", read `lib/dev_boxer/wizard.rb#build_config` from top to bottom and add/remove lines to match the actual prompt order. Each `ask`, `ask_integer`, `confirm`, and `ask_choice` call consumes one line.

- [ ] **Step 2: Run the failing test**

```
cd /home/youruser/dev-boxer && ruby -Ilib -Itest test/wizard_test.rb
```

Expected: failure (the stub raises).

- [ ] **Step 3: Implement `wizard_answers_for_there_branch`**

Open `lib/dev_boxer/wizard.rb` and trace `build_config`. Build the answer script by walking every `ask`/`confirm`/`ask_integer` call in order, supplying defaults for everything except the matrix section. For the matrix section, the test's intent is that the operator picks `there`, then pastes the blob.

The stub's body should construct a multi-line string of newline-separated answers — one per `gets` the wizard performs. Use the existing tests in `test/wizard_test.rb` as the reference pattern.

- [ ] **Step 4: Implement the wizard `here / there` branch**

Edit `lib/dev_boxer/wizard.rb`. In `build_config`, replace the existing "4. Matrix user" section with:

```ruby
section_header("4. Matrix")
matrix_choice = ask_choice(
  "Matrix homeserver location",
  choices: %w[here there],
  default: existing.dig("matrix", "mode") == "external" ? "there" : "here",
)

matrix_user, matrix_overrides, matrix_secrets =
  case matrix_choice
  when "here"
    name = ask("Matrix username", default: existing.dig("matrix", "user_username") || username)
    [name, { "mode" => "bundled" }, {}]
  when "there"
    blob = ask_blob_until_valid
    decoded = DevBoxer::CredentialsBlob.decode(blob)
    bot_localpart = decoded["bot_user_id"].split(":", 2).first.delete_prefix("@")
    overrides = {
      "mode" => "external",
      "homeserver_url" => decoded["homeserver_url"],
      "server_domain"  => decoded["server_domain"],
      "bot_username"   => bot_localpart,
    }
    secret_fields = decoded.slice(
      "bot_user_id", "bot_password", "bot_recovery_key", "bridge_room_id"
    )
    [
      existing.dig("matrix", "user_username") || username,
      overrides,
      { "matrix" => secret_fields },
    ]
  end
```

Add a small helper method on `Wizard`:

```ruby
def ask_blob_until_valid
  loop do
    raw = ask("Paste add-bot blob from your homeserver box", secret: true)
    begin
      DevBoxer::CredentialsBlob.decode(raw)
      return raw
    rescue DevBoxer::CredentialsBlob::Invalid => e
      output.puts "  ✗ #{e.message}"
    end
  end
end

def ask_choice(prompt, choices:, default:)
  loop do
    raw = ask("#{prompt} (#{choices.join(' / ')})", default: default).to_s.downcase
    return raw if choices.include?(raw)

    output.puts "Choose one of: #{choices.join(', ')}."
  end
end
```

Then merge `matrix_overrides` into the `"matrix"` block of the `config` hash, and `matrix_secrets` into the `secrets` hash before they're returned.

- [ ] **Step 5: Run the wizard tests**

```
cd /home/youruser/dev-boxer && ruby -Ilib -Itest test/wizard_test.rb
```

Expected: all wizard tests pass, including the two new ones.

- [ ] **Step 6: Run the full suite**

```
cd /home/youruser/dev-boxer && rake test
```

Expected: all green.

- [ ] **Step 7: Commit**

```
git add lib/dev_boxer/wizard.rb test/wizard_test.rb
git commit -m "$(cat <<'EOF'
feat(wizard): here/there matrix prompt with add-bot blob import

Replaces the single matrix-user prompt with a here/there choice.
'there' asks for an add-bot creds blob, decodes it via CredentialsBlob,
and routes the public/private fields into config.yml and secrets.yml.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Wire bot creds into matrix-bridge `bridge_env_vars`

**Goal:** When `matrix.mode == external` and the imported bot creds are present, render them into the bridge `.env` so the bridge can use them on first start.

**Files:**
- Modify: `lib/dev_boxer/modules/08_matrix_bridge.rb`
- Modify: `templates/matrix-bridge.env`
- Modify: `test/matrix_bridge_test.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/matrix_bridge_test.rb`:

```ruby
def test_bridge_env_vars_in_external_mode_include_imported_creds
  Dir.mktmpdir do |dir|
    config = DevBoxer::Config.from_hash(
      "user" => { "name" => "dev" },
      "matrix" => {
        "mode" => "external",
        "homeserver_url" => "https://matrix.example.com",
        "server_domain" => "matrix.example.com",
        "user_username" => "dev",
        "bot_username" => "box4",
        "bot_user_id" => "@box4:matrix.example.com",
        "bot_password" => "pw",
        "bot_recovery_key" => "EsTm 4uK4",
        "bridge_room_id" => "!abc:matrix.example.com",
      },
    )
    mod = DevBoxer::Modules::MatrixBridge.new(
      config: config,
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
      shell: DevBoxer::Shell.new(runner: ->(_cmd, _opts = {}) { [true, "", ""] }),
      templates_dir: File.expand_path("../templates", __dir__),
      secrets_path: File.join(dir, "secrets.yml"),
    )

    vars = mod.send(:bridge_env_vars)

    assert_equal "@box4:matrix.example.com", vars["MATRIX_BOT_USER_ID"]
    assert_equal "pw", vars["MATRIX_BOT_PASSWORD"]
    assert_equal "EsTm 4uK4", vars["MATRIX_BOT_RECOVERY_KEY"]
    assert_equal "!abc:matrix.example.com", vars["MATRIX_BRIDGE_ROOM_ID"]
  end
end

def test_bridge_env_vars_in_bundled_mode_does_not_include_password_or_recovery
  Dir.mktmpdir do |dir|
    mod = build_module(secrets_path: File.join(dir, "secrets.yml"))
    vars = mod.send(:bridge_env_vars)
    assert_nil vars["MATRIX_BOT_PASSWORD"]
    assert_nil vars["MATRIX_BOT_RECOVERY_KEY"]
  end
end
```

- [ ] **Step 2: Run the failing test**

```
cd /home/youruser/dev-boxer && ruby -Ilib -Itest test/matrix_bridge_test.rb
```

Expected: failure (`MATRIX_BOT_USER_ID` not set).

- [ ] **Step 3: Update `bridge_env_vars`**

Edit `lib/dev_boxer/modules/08_matrix_bridge.rb`. Modify `bridge_env_vars` to include the new keys only when `mode == "external"`:

```ruby
def bridge_env_vars
  creds = @generated_credentials || {}
  @bridge_env_vars ||= begin
    base = {
      "MATRIX_HOMESERVER_URL" => homeserver_url,
      "MATRIX_BOT_ACCESS_TOKEN_BUNDLED" => creds[:bot_access_token] || config.matrix&.bot_access_token,
      "MATRIX_ALLOWED_USER_IDS" => user_id,
      "USERNAME" => username,
      "HMAC_SECRET" => creds[:hmac_secret] || config.matrix&.hmac_secret || SecureRandom.hex(32),
      "CF_HOSTNAME_VIEWER" => config.cloudflare&.tunnel&.hostname_viewer || "localhost",
    }

    if mode == "external"
      base["MATRIX_BOT_USER_ID"]      = config.matrix&.bot_user_id
      base["MATRIX_BOT_PASSWORD"]     = config.matrix&.bot_password
      base["MATRIX_BOT_RECOVERY_KEY"] = config.matrix&.bot_recovery_key
      base["MATRIX_BRIDGE_ROOM_ID"]   = config.matrix&.bridge_room_id
    end

    base
  end
end
```

- [ ] **Step 4: Update `templates/matrix-bridge.env`**

Add new lines at the bottom (only the keys that the bridge will consume on first-start). Keep existing keys untouched:

```
# Populated when this box was bootstrapped via `dev-boxer add-bot` on another box.
# The bridge consumes these on first start, then writes back MATRIX_ACCESS_TOKEN.
MATRIX_BOT_USER_ID={{MATRIX_BOT_USER_ID}}
MATRIX_BOT_PASSWORD={{MATRIX_BOT_PASSWORD}}
MATRIX_BOT_RECOVERY_KEY={{MATRIX_BOT_RECOVERY_KEY}}
MATRIX_BRIDGE_ROOM_ID={{MATRIX_BRIDGE_ROOM_ID}}
```

Note that the template engine renders missing vars as the empty string (verify by running the test; if it errors, look at `lib/dev_boxer/template.rb` and either supply empty defaults in `bridge_env_vars` or wrap the new block conditionally on render).

- [ ] **Step 5: Run the full suite**

```
cd /home/youruser/dev-boxer && rake test
```

Expected: all green.

- [ ] **Step 6: Commit**

```
git add lib/dev_boxer/modules/08_matrix_bridge.rb templates/matrix-bridge.env test/matrix_bridge_test.rb
git commit -m "$(cat <<'EOF'
feat(matrix-bridge): expose imported bot creds via .env

Adds MATRIX_BOT_USER_ID/PASSWORD/RECOVERY_KEY/BRIDGE_ROOM_ID to the
bridge .env when matrix.mode is external. The bridge will use them
on first start to mint its own access token; bundled-mode boxes are
unaffected.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `bin/add-bot` CLI + `AddBot` orchestrator

**Goal:** A new entry point `bin/add-bot` that drives bot registration on the homeserver host, runs the (still-to-be-built) `add-bot.mjs` from the bridge repo, persists creds to `secrets.yml`, and prints the blob.

For this task, mock the call to `add-bot.mjs` in tests so the orchestrator can be tested without the bridge repo or a homeserver.

**Files:**
- Create: `bin/add-bot`
- Create: `lib/dev_boxer/add_bot.rb`
- Test: `test/add_bot_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/add_bot_test.rb`:

```ruby
require_relative "test_helper"
require "tmpdir"
require_relative "../lib/dev_boxer/add_bot"

class AddBotTest < Minitest::Test
  def test_refuses_without_name
    err = assert_raises(DevBoxer::AddBot::UsageError) do
      DevBoxer::AddBot.new(name: nil, **build_deps).run
    end
    assert_match(/name/i, err.message)
  end

  def test_refuses_unless_mode_is_bundled
    deps = build_deps(matrix_mode: "external")
    err = assert_raises(DevBoxer::AddBot::UsageError) do
      DevBoxer::AddBot.new(name: "box4", **deps).run
    end
    assert_match(/bundled/i, err.message)
  end

  def test_refuses_to_overwrite_existing_bot_without_reprint
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      seed_existing_bot_in_secrets(secrets_path, "box4")
      deps = build_deps(secrets_path: secrets_path)
      err = assert_raises(DevBoxer::AddBot::AlreadyExists) do
        DevBoxer::AddBot.new(name: "box4", **deps).run
      end
      assert_match(/--reprint/, err.message)
    end
  end

  def test_reprint_returns_blob_without_touching_homeserver
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      seed_existing_bot_in_secrets(secrets_path, "box4")
      registration_calls = []
      registration = build_registration(calls: registration_calls)
      mjs_calls = []
      mjs = ->(*args) { mjs_calls << args; raise "should not run" }

      blob = DevBoxer::AddBot.new(
        name: "box4", reprint: true, **build_deps(secrets_path: secrets_path,
                                                   registration: registration,
                                                   run_mjs: mjs)
      ).run

      assert_match(/\Adb1:/, blob)
      assert_empty registration_calls
      assert_empty mjs_calls
    end
  end

  def test_happy_path_orchestrates_registration_then_mjs_then_close
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      events = []
      registration = Minitest::Mock.new
      registration.expect(:open, nil) { |_token| events << :open; true }
      registration.expect(:register_bot, true) { |username:, password:, reg_token:|
        events << [:register, username]
        true
      }
      registration.expect(:close, nil) { events << :close; true }

      run_mjs = lambda do |args|
        events << :mjs
        # add-bot.mjs's contract: write a creds-file at args[:credentials_file]
        File.write(args[:credentials_file], <<~OUT)
          bot_recovery_key='EsTm 4uK4'
          bridge_room_id='!abc:matrix.example.com'
        OUT
      end

      blob = DevBoxer::AddBot.new(
        name: "box4",
        **build_deps(secrets_path: secrets_path,
                     registration: registration,
                     run_mjs: run_mjs)
      ).run

      assert_equal [:open, [:register, "box4"], :mjs, :close], events
      decoded = DevBoxer::CredentialsBlob.decode(blob)
      assert_equal "@box4:matrix.example.com", decoded["bot_user_id"]
      assert_equal "EsTm 4uK4", decoded["bot_recovery_key"]
      assert_equal "!abc:matrix.example.com", decoded["bridge_room_id"]
      registration.verify
    end
  end

  def test_close_runs_even_if_mjs_raises
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      events = []
      registration = Minitest::Mock.new
      registration.expect(:open, nil) { |_token| events << :open; true }
      registration.expect(:register_bot, true) { |username:, password:, reg_token:|
        events << :register; true
      }
      registration.expect(:close, nil) { events << :close; true }

      run_mjs = ->(_args) { raise "kaboom" }

      assert_raises(RuntimeError) do
        DevBoxer::AddBot.new(
          name: "box4",
          **build_deps(secrets_path: secrets_path,
                       registration: registration,
                       run_mjs: run_mjs)
        ).run
      end

      assert_equal [:open, :register, :close], events
      registration.verify
    end
  end

  def test_persists_bot_password_before_opening_window
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      saw_password_in_secrets = nil
      registration = Minitest::Mock.new
      registration.expect(:open, nil) do |_token|
        secrets = YAML.safe_load_file(secrets_path)
        saw_password_in_secrets = secrets.dig("matrix", "bots", "box4", "bot_password")
        true
      end
      registration.expect(:register_bot, true) { |**_| true }
      registration.expect(:close, nil) { true }

      run_mjs = ->(args) { File.write(args[:credentials_file], "bot_recovery_key='r'\nbridge_room_id='!a:m'\n") }

      DevBoxer::AddBot.new(
        name: "box4",
        **build_deps(secrets_path: secrets_path,
                     registration: registration,
                     run_mjs: run_mjs)
      ).run

      refute_nil saw_password_in_secrets, "password should be persisted before open()"
      registration.verify
    end
  end

  private

  def build_deps(secrets_path: nil, matrix_mode: "bundled", registration: nil, run_mjs: nil)
    secrets_path ||= File.join(Dir.mktmpdir, "secrets.yml")
    {
      config: DevBoxer::Config.from_hash(
        "user" => { "name" => "dev" },
        "matrix" => {
          "mode" => matrix_mode,
          "server_domain" => "matrix.example.com",
          "user_username" => "dev",
        },
      ),
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
      secrets_path: secrets_path,
      registration: registration || build_registration,
      run_mjs: run_mjs || ->(args) { File.write(args[:credentials_file], "bot_recovery_key='r'\nbridge_room_id='!a:m'\n") },
    }
  end

  def build_registration(calls: [])
    fake = Object.new
    fake.define_singleton_method(:open)         { |token| calls << [:open, token] }
    fake.define_singleton_method(:register_bot) { |**args| calls << [:register, args]; true }
    fake.define_singleton_method(:close)        { calls << :close }
    fake
  end

  def seed_existing_bot_in_secrets(path, name)
    File.write(path, {
      "matrix" => {
        "bots" => {
          name => {
            "bot_user_id" => "@#{name}:matrix.example.com",
            "bot_password" => "old-pw",
            "bot_recovery_key" => "EsTm 4uK4",
            "bridge_room_id" => "!abc:matrix.example.com",
            "created_at" => "2026-05-02T12:34:56Z",
          },
        },
      },
    }.to_yaml)
    File.chmod(0o600, path)
  end
end
```

- [ ] **Step 2: Run the failing test**

```
cd /home/youruser/dev-boxer && ruby -Ilib -Itest test/add_bot_test.rb
```

Expected: failure (`uninitialized constant DevBoxer::AddBot`).

- [ ] **Step 3: Implement `AddBot`**

Create `lib/dev_boxer/add_bot.rb`:

```ruby
require "fileutils"
require "securerandom"
require "shellwords"
require "time"
require "yaml"
require_relative "credentials_blob"
require_relative "matrix_registration"
require_relative "config"

module DevBoxer
  class AddBot
    UsageError    = Class.new(StandardError)
    AlreadyExists = Class.new(StandardError)

    BRIDGE_DIR_DEFAULT = ->(username) { "/home/#{username}/claude-matrix-bridge" }

    def initialize(name:, config:, log:, secrets_path:, registration: nil, run_mjs: nil, reprint: false, bridge_dir: nil)
      @name = name
      @config = config
      @log = log
      @secrets_path = secrets_path
      @reprint = reprint
      @registration = registration
      @run_mjs = run_mjs || method(:default_run_mjs)
      @bridge_dir = bridge_dir
    end

    def run
      raise UsageError, "--name is required (e.g. `dev-boxer add-bot box4`)" if @name.nil? || @name.to_s.empty?
      raise UsageError, "add-bot only runs on a homeserver host (matrix.mode must be 'bundled'); got #{matrix_mode.inspect}" unless matrix_mode == "bundled"

      existing = existing_bot_record
      if existing
        return reprint_blob(existing) if @reprint
        raise AlreadyExists, "Bot '#{@name}' already exists in #{@secrets_path}. Use --reprint to regenerate the blob."
      end

      bot_password = SecureRandom.hex(16)
      persist_partial_bot_record(bot_password)

      reg_token = SecureRandom.hex(16)
      mjs_creds_path = "/dev/shm/dev-boxer-add-bot-#{SecureRandom.hex(8)}"

      begin
        registration.open(reg_token)
        registration.register_bot(username: @name, password: bot_password, reg_token: reg_token)
        @run_mjs.call(
          credentials_file: mjs_creds_path,
          bot_username: @name,
          bot_user_id: bot_user_id,
          bot_password: bot_password,
          user_id: user_id,
          reg_token: reg_token,
          homeserver_url: MatrixRegistration::HOMESERVER_LOCAL,
        )
        mjs_output = parse_mjs_output(mjs_creds_path)
        record = persist_full_bot_record(bot_password, mjs_output)
        encode_blob(record)
      ensure
        registration.close rescue nil
        File.delete(mjs_creds_path) if File.exist?(mjs_creds_path)
      end
    end

    private

    attr_reader :config, :log

    def matrix_mode
      config.matrix&.mode || "bundled"
    end

    def server_domain
      s = config.matrix&.server_domain
      raise UsageError, "matrix.server_domain is not set in config.yml" if s.nil? || s.to_s.empty?
      s
    end

    def user_username
      config.matrix&.user_username || config.user.name
    end

    def bot_user_id = "@#{@name}:#{server_domain}"
    def user_id     = "@#{user_username}:#{server_domain}"

    def registration
      @registration ||= MatrixRegistration.new(
        matrix_server_dir: "/home/#{config.user.name}/matrix-server",
        username: config.user.name,
        shell: Shell.new,
        log: log,
      )
    end

    def existing_bot_record
      return nil unless File.exist?(@secrets_path)
      data = YAML.safe_load_file(@secrets_path) || {}
      data.dig("matrix", "bots", @name.to_s)
    end

    def persist_partial_bot_record(bot_password)
      Config.merge_into_file(@secrets_path, {
        "matrix" => {
          "bots" => {
            @name.to_s => {
              "bot_user_id"  => bot_user_id,
              "bot_password" => bot_password,
              "created_at"   => Time.now.utc.iso8601,
            },
          },
        },
      })
    end

    def persist_full_bot_record(bot_password, mjs_output)
      record = {
        "bot_user_id"      => bot_user_id,
        "bot_password"     => bot_password,
        "bot_recovery_key" => mjs_output.fetch("bot_recovery_key"),
        "bridge_room_id"   => mjs_output.fetch("bridge_room_id"),
        "created_at"       => Time.now.utc.iso8601,
      }
      Config.merge_into_file(@secrets_path, {
        "matrix" => { "bots" => { @name.to_s => record } },
      })
      record
    end

    def parse_mjs_output(path)
      raise "add-bot.mjs did not write #{path}" unless File.exist?(path)
      contents = File.read(path)
      {
        "bot_recovery_key" => contents.match(/^bot_recovery_key=['"]?([^'"\n]+)['"]?$/)&.[](1),
        "bridge_room_id"   => contents.match(/^bridge_room_id=['"]?([^'"\n]+)['"]?$/)&.[](1),
      }.tap do |h|
        missing = h.select { |_, v| v.nil? || v.empty? }.keys
        raise "add-bot.mjs output missing keys: #{missing.join(', ')}" unless missing.empty?
      end
    end

    def reprint_blob(record)
      encode_blob(record)
    end

    def encode_blob(record)
      CredentialsBlob.encode(
        "homeserver_url"   => "https://#{server_domain}",
        "server_domain"    => server_domain,
        "bot_user_id"      => record["bot_user_id"],
        "bot_password"     => record["bot_password"],
        "bot_recovery_key" => record["bot_recovery_key"],
        "bridge_room_id"   => record["bridge_room_id"],
      )
    end

    def default_run_mjs(args)
      bridge_dir = @bridge_dir || BRIDGE_DIR_DEFAULT.call(config.user.name)
      Shell.new.run_as_user(config.user.name, [
        "MATRIX_HOMESERVER_URL=#{Shellwords.escape(args[:homeserver_url])}",
        "REG_TOKEN=#{Shellwords.escape(args[:reg_token])}",
        "node",
        Shellwords.escape("#{bridge_dir}/add-bot.mjs"),
        Shellwords.escape(args[:bot_username]),
        "--password", Shellwords.escape(args[:bot_password]),
        "--user", Shellwords.escape(args[:user_id]),
        "--credentials-file", Shellwords.escape(args[:credentials_file]),
      ].join(" "))
    end
  end
end
```

- [ ] **Step 4: Run the failing test**

```
cd /home/youruser/dev-boxer && ruby -Ilib -Itest test/add_bot_test.rb
```

Expected: all 6 tests pass.

- [ ] **Step 5: Create the CLI entry point**

Create `bin/add-bot`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))

require "dev_boxer"
require "dev_boxer/add_bot"

DEFAULT_CONFIG = File.join(ROOT, "config.yml")

options = { config: DEFAULT_CONFIG, reprint: false }
parser = OptionParser.new do |opts|
  opts.banner = "Usage: bin/add-bot <name> [options]"
  opts.on("--config PATH", "Path to config.yml (default: ./config.yml)") { |v| options[:config] = v }
  opts.on("--reprint", "Re-print the credentials blob for an existing bot") { options[:reprint] = true }
  opts.on("-h", "--help", "Show this help") { puts opts; exit 0 }
end

begin
  parser.parse!
rescue OptionParser::InvalidOption, OptionParser::MissingArgument => e
  warn e.message
  warn parser
  exit 2
end

name = ARGV.shift
if name.nil? || name.empty?
  warn "name is required (e.g. `bin/add-bot box4`)"
  warn parser
  exit 2
end

config = DevBoxer::Config.load(options[:config])
log = DevBoxer::Log.new

begin
  blob = DevBoxer::AddBot.new(
    name: name,
    config: config,
    log: log,
    secrets_path: DevBoxer::Config.secrets_path_for(options[:config]),
    reprint: options[:reprint],
  ).run

  puts
  puts "=" * 60
  puts "  Paste this blob into the installer on #{name}:"
  puts "=" * 60
  puts blob
  puts "=" * 60
rescue DevBoxer::AddBot::UsageError, DevBoxer::AddBot::AlreadyExists => e
  warn e.message
  exit 2
end
```

- [ ] **Step 6: Make the CLI executable**

```
chmod +x /home/youruser/dev-boxer/bin/add-bot
```

- [ ] **Step 7: Smoke-test the CLI**

```
cd /home/youruser/dev-boxer && bin/add-bot 2>&1 | head -5
```

Expected: prints `name is required (e.g. \`bin/add-bot box4\`)` and the usage banner, exits non-zero.

- [ ] **Step 8: Run the full suite**

```
cd /home/youruser/dev-boxer && rake test
```

Expected: all green.

- [ ] **Step 9: Commit**

```
git add bin/add-bot lib/dev_boxer/add_bot.rb test/add_bot_test.rb
git commit -m "$(cat <<'EOF'
feat(add-bot): bin/add-bot CLI + AddBot orchestrator

Adds the homeserver-host entry point that opens a registration window,
registers the bot, runs add-bot.mjs (stubbed in tests) for the
verification dance, and prints a credentials blob. Persists per-bot
records under matrix.bots[<name>] in secrets.yml so --reprint works.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — claude-matrix-bridge (JS)

These tasks operate inside `/home/youruser/claude-matrix-bridge`, which is a *separate git repo*. Switch directories before each task and commit independently. The dev-boxer module that drives `add-bot.mjs` is already pinned via `git pull --ff-only` in the bridge clone step, so once the bridge repo is updated, dev-boxer boxes will pick it up on next `setup.rb` run.

Branch: create `feat/add-bot-flow` in the bridge repo.

### Task 7: `add-bot.mjs` script

**Goal:** A standalone Node script invoked by `AddBot#run` that drives the bot-side bootstrap and SAS verification dance, then writes a creds file the Ruby side can parse.

**Files:**
- Create: `add-bot.mjs` (in `~/claude-matrix-bridge`)

There are no automated tests for this — it touches a real homeserver and a real Element client. Verify behaviour during the manual E2E (Task 9).

- [ ] **Step 1: Switch to the bridge repo and create the branch**

```
cd /home/youruser/claude-matrix-bridge && git checkout -b feat/add-bot-flow
```

- [ ] **Step 2: Create `add-bot.mjs`**

Create `/home/youruser/claude-matrix-bridge/add-bot.mjs`. Use `setup-user.mjs` as the structural reference for env loading, console suppression, login + sync, and creds-file writing.

The full script:

```js
#!/usr/bin/env node
/**
 * Drives a freshly-registered bot through:
 *   1. Login → access token + device_id
 *   2. Bootstrap own SSSS + cross-signing → bot_recovery_key, master CSK
 *   3. Open or find a DM with the human user
 *   4. Send m.key.verification.request, auto-confirm SAS on bot side,
 *      poll until user accepts and the dance completes
 *   5. Sanity-check that user has signed bot's master key
 *   6. Create the encrypted bridge room and invite the user
 *   7. Logout the temporary device, write creds file
 *
 * Usage:
 *   node add-bot.mjs <bot-username> --password <pw> --user @user:host \
 *                     --credentials-file /dev/shm/...
 *
 * Environment:
 *   MATRIX_HOMESERVER_URL  — default http://localhost:6167
 */

import dotenv from 'dotenv';
dotenv.config();

import * as sdk from 'matrix-js-sdk';
import { writeFileSync } from 'fs';

const HOMESERVER = process.env.MATRIX_HOMESERVER_URL || 'http://localhost:6167';
const VERIFY_TIMEOUT_MS = 5 * 60 * 1000;

// Mirror setup-user.mjs's noise suppression so the operator only sees flow steps.
const origLog = console.log;
const suppressed = /matrix_sdk_crypto|FetchHttpApi|key backup|push rule|Olm|crypto-sdk|CryptoStore|outgoing request|^\[Perf\]|receiveSyncChanges|Sync|saved sync|queued to-device|client options|Getting|Got |Prepare|Sending|Storing|Resuming|Attempting|Fetched|Adding default|cross signing|Secret storage|^INFO |^Checking|^Completed|^bootstrap|^Downloading|^Token no|^\/sync error|^Failed to proc/;
console.warn = (...a) => { if (!suppressed.test(String(a[0]))) origLog(...a); };
console.log = (...a) => { if (!suppressed.test(String(a[0]))) origLog(...a); };
console.debug = () => {};
function log(...a) { origLog(...a); }

function parseArgs() {
  const args = process.argv.slice(2);
  if (!args.length || args[0].startsWith('-')) {
    console.error('Usage: node add-bot.mjs <bot-username> --password <pw> --user @user:host --credentials-file <path>');
    process.exit(1);
  }
  const username = args[0];
  let password, user, credentialsFile;
  for (let i = 1; i < args.length; i++) {
    if (args[i] === '--password') password = args[++i];
    else if (args[i] === '--user') user = args[++i];
    else if (args[i] === '--credentials-file') credentialsFile = args[++i];
  }
  if (!password || !user || !credentialsFile) {
    console.error('Missing required arg (--password, --user, --credentials-file)');
    process.exit(1);
  }
  return { username, password, user, credentialsFile };
}

async function loginAndSync(username, password) {
  const loginResp = await fetch(`${HOMESERVER}/_matrix/client/v3/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      type: 'm.login.password',
      identifier: { type: 'm.id.user', user: username },
      password,
    }),
  });
  const loginData = await loginResp.json();
  if (!loginData.access_token) throw new Error('Bot login failed: ' + JSON.stringify(loginData));

  let recoveryKey;
  const secretKey = { privateKey: null };
  const client = sdk.createClient({
    baseUrl: HOMESERVER,
    accessToken: loginData.access_token,
    userId: loginData.user_id,
    deviceId: loginData.device_id,
    cryptoCallbacks: {
      getSecretStorageKey: async ({ keys }) => {
        const keyId = Object.keys(keys)[0];
        return [keyId, secretKey.privateKey];
      },
    },
  });

  await client.initRustCrypto({ useIndexedDB: false });
  const cryptoApi = client.getCrypto();

  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Sync timeout')), 30000);
    client.once(sdk.ClientEvent.Sync, (state) => {
      clearTimeout(timeout);
      if (state === 'PREPARED' || state === 'SYNCING') resolve();
      else reject(new Error('Sync: ' + state));
    });
    client.startClient({ initialSyncLimit: 0 });
  });
  await new Promise(r => setTimeout(r, 2000));

  return { client, cryptoApi, loginData, secretKey, recoveryKeyRef: () => recoveryKey, setRecoveryKey: (k) => { recoveryKey = k; } };
}

async function bootstrapBotIdentity(client, cryptoApi, loginData, password, secretKey, setRecoveryKey) {
  await cryptoApi.bootstrapSecretStorage({
    createSecretStorageKey: async () => {
      const keyInfo = await cryptoApi.createRecoveryKeyFromPassphrase();
      setRecoveryKey(keyInfo.encodedPrivateKey);
      secretKey.privateKey = keyInfo.privateKey;
      return keyInfo;
    },
    setupNewSecretStorage: true,
    setupNewKeyBackup: false,
  });

  await cryptoApi.bootstrapCrossSigning({
    authUploadDeviceSigningKeys: async (makeRequest) => {
      return makeRequest({
        type: 'm.login.password',
        identifier: { type: 'm.id.user', user: loginData.user_id },
        password,
      });
    },
  });
}

async function findOrCreateDM(client, userId) {
  // Look for an existing 1:1 room with the user.
  for (const room of client.getRooms()) {
    const members = room.getMembers().map(m => m.userId);
    if (members.length === 2 && members.includes(userId) && members.includes(client.getUserId())) {
      return room.roomId;
    }
  }
  const created = await client.createRoom({
    is_direct: true,
    invite: [userId],
    preset: 'trusted_private_chat',
  });
  return created.room_id;
}

async function sendVerificationAndAwait(client, cryptoApi, userId) {
  const request = await cryptoApi.requestVerificationDM(userId, await findOrCreateDM(client, userId));
  log(`  → Verification request sent to ${userId}. Awaiting acceptance…`);

  const start = Date.now();
  while (true) {
    if (request.phase === sdk.VerificationPhase.Done) return;
    if (request.phase === sdk.VerificationPhase.Cancelled) {
      throw new Error('Verification cancelled: ' + (request.cancellationCode || 'unknown'));
    }
    if (request.verifier) {
      // Auto-confirm SAS on the bot side. Safe: bot↔homeserver is loopback.
      const verifier = request.verifier;
      try {
        if (typeof verifier.verify === 'function') {
          await verifier.verify();
        }
      } catch (e) {
        log('  verifier.verify error: ' + e.message);
      }
    }
    if (Date.now() - start > VERIFY_TIMEOUT_MS) {
      throw new Error(`Verification timed out after ${VERIFY_TIMEOUT_MS / 1000}s`);
    }
    await new Promise(r => setTimeout(r, 1000));
  }
}

async function createBridgeRoom(client, userId) {
  const created = await client.createRoom({
    name: 'Claude Code Bridge',
    topic: 'Messages in this room are forwarded to Claude Code',
    visibility: 'private',
    preset: 'private_chat',
    invite: [userId],
    initial_state: [{
      type: 'm.room.encryption',
      state_key: '',
      content: { algorithm: 'm.megolm.v1.aes-sha2' },
    }],
  });
  return created.room_id;
}

async function main() {
  const { username, password, user, credentialsFile } = parseArgs();

  log(`Bootstrapping bot @${username} on ${HOMESERVER}`);
  const session = await loginAndSync(username, password);

  log('Bootstrapping bot SSSS + cross-signing');
  await bootstrapBotIdentity(session.client, session.cryptoApi, session.loginData, password, session.secretKey, session.setRecoveryKey);
  log('  bot recovery key generated, master/self/user signing keys uploaded');

  log('Sending verification request');
  await sendVerificationAndAwait(session.client, session.cryptoApi, user);
  log('  verification done — bot master key signed by user');

  log('Creating encrypted bridge room and inviting user');
  const roomId = await createBridgeRoom(session.client, user);
  log(`  bridge room: ${roomId}`);

  log('Logging out temporary device');
  await fetch(`${HOMESERVER}/_matrix/client/v3/logout`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${session.loginData.access_token}`, 'Content-Type': 'application/json' },
    body: '{}',
  });

  writeFileSync(credentialsFile, [
    `bot_recovery_key='${session.recoveryKeyRef()}'`,
    `bridge_room_id='${roomId}'`,
  ].join('\n') + '\n', { mode: 0o600 });

  log('Done');
  process.exit(0);
}

main().catch(e => { console.error('Failed:', e); process.exit(1); });
```

- [ ] **Step 3: Confirm imports / API names against the pinned matrix-js-sdk version**

```
cd /home/youruser/claude-matrix-bridge && grep '"matrix-js-sdk"' package.json
```

Then quickly check that `VerificationPhase`, `requestVerificationDM`, and `verifier.verify` exist in that version:

```
node -e "const sdk = require('matrix-js-sdk'); console.log(Object.keys(sdk.VerificationPhase || {})); console.log(typeof sdk.createClient);"
```

If `VerificationPhase` is exported under a different path or `requestVerificationDM` has been renamed in the installed version, fix the script before continuing — this is a known integration risk called out in the spec's open question #3. The pattern to follow if APIs differ is the existing `setup-user.mjs`'s use of `cryptoApi.olmMachine` for low-level operations.

- [ ] **Step 4: Smoke test the script's CLI surface**

```
cd /home/youruser/claude-matrix-bridge && node add-bot.mjs 2>&1 | head -3
```

Expected: prints usage, exits non-zero.

- [ ] **Step 5: Commit (in the bridge repo)**

```
cd /home/youruser/claude-matrix-bridge
git add add-bot.mjs
git commit -m "$(cat <<'EOF'
feat: add-bot.mjs for cross-machine bot bootstrap

Drives a freshly-registered bot through SSSS/CSK bootstrap, sends a
verification request to the human user, auto-confirms SAS on the bot
side, creates the encrypted bridge room, and writes a creds file the
Ruby orchestrator parses to assemble the credentials blob.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Bridge first-start bootstrap in `index.js`

**Goal:** Before `client.start()`, if the local crypto store is empty and `MATRIX_BOT_PASSWORD` + `MATRIX_BOT_RECOVERY_KEY` are set, log in with the password, restore SSSS via the recovery key, sign this device with the bot's self-signing key, persist the obtained access token back into `.env`, and continue.

**Files:**
- Modify: `index.js` (in `~/claude-matrix-bridge`)
- Create: `bootstrap-from-creds.mjs` (small helper, kept separate from `index.js` so the bootstrap path is isolated and re-runnable)

The bootstrap is split into a sibling module rather than inlined into `index.js` because `index.js` is already 3000+ lines and the bootstrap pulls in matrix-js-sdk while the bridge runs on matrix-bot-sdk. Keeping it in its own file means we can swap SDKs cleanly if needed and the bridge process still spawns a single child for the bootstrap step.

- [ ] **Step 1: Create the bootstrap helper**

Create `/home/youruser/claude-matrix-bridge/bootstrap-from-creds.mjs`:

```js
#!/usr/bin/env node
/**
 * One-shot bootstrap that runs on the bridge box's first start.
 * Inputs (env): MATRIX_HOMESERVER_URL, MATRIX_BOT_USER_ID,
 *               MATRIX_BOT_PASSWORD, MATRIX_BOT_RECOVERY_KEY
 * Output: prints `access_token=<value>` to stdout (last line).
 *
 * Steps:
 *   1. Login with password → access token + device_id (fresh device on this box)
 *   2. initRustCrypto + sync (does NOT persist; one-shot)
 *   3. bootstrapSecretStorage with the existing recovery key (no new key)
 *   4. bootstrapCrossSigning — signs THIS device with bot's self-signing key
 *   5. Print access_token=...
 */

import * as sdk from 'matrix-js-sdk';

const HOMESERVER = process.env.MATRIX_HOMESERVER_URL;
const BOT_USER_ID = process.env.MATRIX_BOT_USER_ID;
const BOT_PASSWORD = process.env.MATRIX_BOT_PASSWORD;
const BOT_RECOVERY_KEY = process.env.MATRIX_BOT_RECOVERY_KEY;

if (!HOMESERVER || !BOT_USER_ID || !BOT_PASSWORD || !BOT_RECOVERY_KEY) {
  console.error('bootstrap-from-creds: missing required env');
  process.exit(2);
}

const localpart = BOT_USER_ID.replace(/^@/, '').split(':')[0];

async function main() {
  const loginResp = await fetch(`${HOMESERVER}/_matrix/client/v3/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      type: 'm.login.password',
      identifier: { type: 'm.id.user', user: localpart },
      password: BOT_PASSWORD,
    }),
  });
  const loginData = await loginResp.json();
  if (!loginData.access_token) {
    console.error('bootstrap-from-creds: login failed', JSON.stringify(loginData));
    process.exit(3);
  }

  let decodedKey;
  const client = sdk.createClient({
    baseUrl: HOMESERVER,
    accessToken: loginData.access_token,
    userId: loginData.user_id,
    deviceId: loginData.device_id,
    cryptoCallbacks: {
      getSecretStorageKey: async ({ keys }) => {
        const keyId = Object.keys(keys)[0];
        if (!decodedKey) decodedKey = client.keyBackupKeyFromRecoveryKey(BOT_RECOVERY_KEY);
        return [keyId, decodedKey];
      },
    },
  });

  await client.initRustCrypto({ useIndexedDB: false });
  const cryptoApi = client.getCrypto();

  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Sync timeout')), 30000);
    client.once(sdk.ClientEvent.Sync, (state) => {
      clearTimeout(timeout);
      if (state === 'PREPARED' || state === 'SYNCING') resolve();
      else reject(new Error('Sync: ' + state));
    });
    client.startClient({ initialSyncLimit: 0 });
  });
  await new Promise(r => setTimeout(r, 1500));

  // Restores the cached cross-signing private keys from server-side SSSS
  // (no new key created — getSecretStorageKey provides BOT_RECOVERY_KEY).
  await cryptoApi.bootstrapSecretStorage({});
  await cryptoApi.bootstrapCrossSigning({
    authUploadDeviceSigningKeys: async (makeRequest) => makeRequest({
      type: 'm.login.password',
      identifier: { type: 'm.id.user', user: loginData.user_id },
      password: BOT_PASSWORD,
    }),
  });

  // Stop the throwaway client so the bridge can take over with this token.
  client.stopClient();
  process.stdout.write(`access_token=${loginData.access_token}\n`);
  process.exit(0);
}

main().catch(e => { console.error('Failed:', e.stack || e.message); process.exit(1); });
```

- [ ] **Step 2: Wire the bootstrap into `index.js`**

Open `/home/youruser/claude-matrix-bridge/index.js`. Find the line:

```js
const cryptoStorage = new RustSdkCryptoStorageProvider(path.join(os.homedir(), '.claude-matrix-bot-crypto'));
const client = new MatrixClient(MATRIX_HOMESERVER_URL, MATRIX_ACCESS_TOKEN, storage, cryptoStorage);
```

Replace with:

```js
const CRYPTO_DIR = path.join(os.homedir(), '.claude-matrix-bot-crypto');
const BOOTSTRAP_SENTINEL = path.join(CRYPTO_DIR, '.bootstrapped');

let resolvedAccessToken = MATRIX_ACCESS_TOKEN;
if (!resolvedAccessToken && process.env.MATRIX_BOT_PASSWORD && process.env.MATRIX_BOT_RECOVERY_KEY && !fs.existsSync(BOOTSTRAP_SENTINEL)) {
  console.log('First-start bootstrap: minting access token from imported bot creds');
  const out = execFileSync(process.execPath, [path.join(__dirname, 'bootstrap-from-creds.mjs')], {
    stdio: ['ignore', 'pipe', 'inherit'],
    env: process.env,
  }).toString();
  const match = out.match(/^access_token=(.+)$/m);
  if (!match) {
    console.error('Bootstrap did not return an access token. Output was:\n' + out);
    process.exit(1);
  }
  resolvedAccessToken = match[1].trim();
  fs.mkdirSync(CRYPTO_DIR, { recursive: true });
  fs.writeFileSync(BOOTSTRAP_SENTINEL, new Date().toISOString());
  // Persist the new token into .env so subsequent restarts skip bootstrap.
  appendOrReplaceEnvVar(path.join(__dirname, '.env'), 'MATRIX_ACCESS_TOKEN', resolvedAccessToken);
}

if (!resolvedAccessToken) {
  console.error('MATRIX_ACCESS_TOKEN is required (set directly, or supply MATRIX_BOT_PASSWORD + MATRIX_BOT_RECOVERY_KEY for first-start bootstrap)');
  process.exit(1);
}

const storage = new SimpleFsStorageProvider(path.join(os.homedir(), '.claude-matrix-bot-state.json'));
const cryptoStorage = new RustSdkCryptoStorageProvider(CRYPTO_DIR);
const client = new MatrixClient(MATRIX_HOMESERVER_URL, resolvedAccessToken, storage, cryptoStorage);
```

Also delete the existing top-level `if (!MATRIX_ACCESS_TOKEN) { console.error(...); process.exit(1); }` block (around line 19) — the new gate above takes its place.

Add `execFileSync` to the existing `child_process` import at the top of the file (look for the existing `import { spawn } from 'child_process';` near line 4 and change it to `import { spawn, execFileSync } from 'child_process';`).

Add the helper near the top of the file (right after the existing `function startTyping(...)` or wherever other small helpers live):

```js
function appendOrReplaceEnvVar(envPath, key, value) {
  let body = '';
  try { body = fs.readFileSync(envPath, 'utf-8'); } catch { /* file missing */ }
  const re = new RegExp(`^${key}=.*$`, 'm');
  const line = `${key}=${value}`;
  body = re.test(body) ? body.replace(re, line) : (body.endsWith('\n') || body.length === 0 ? body + line + '\n' : body + '\n' + line + '\n');
  fs.writeFileSync(envPath, body, { mode: 0o600 });
}
```

(The `fs` import already exists at the top of `index.js`.)

- [ ] **Step 3: Verify the bridge still loads cleanly when MATRIX_ACCESS_TOKEN is set**

```
cd /home/youruser/claude-matrix-bridge && MATRIX_ACCESS_TOKEN=stub MATRIX_HOMESERVER_URL=http://localhost:6167 node -e "process.argv=['node', 'index.js']; import('./index.js').catch(e => { console.error(e.message); process.exit(0); })" 2>&1 | head -10
```

Expected: the process either tries to connect and fails (acceptable) or exits cleanly without crashing on the new code path. The point is to confirm the file parses and the new code doesn't error before the existing logic runs.

- [ ] **Step 4: Manual single-step test of the bootstrap helper**

This requires a real bot account with creds. Skip if you don't have one to hand — the manual E2E in Task 9 will exercise it.

If you have a bot account from an earlier `add-bot` run, cd to the bridge repo and run:

```
MATRIX_HOMESERVER_URL=https://matrix.example.com \
MATRIX_BOT_USER_ID=@boxX:matrix.example.com \
MATRIX_BOT_PASSWORD='...' \
MATRIX_BOT_RECOVERY_KEY='...' \
node bootstrap-from-creds.mjs
```

Expected: prints `access_token=<long string>` on the last line.

- [ ] **Step 5: Commit (in the bridge repo)**

```
cd /home/youruser/claude-matrix-bridge
git add bootstrap-from-creds.mjs index.js
git commit -m "$(cat <<'EOF'
feat: bridge first-start bootstrap from imported bot creds

When MATRIX_ACCESS_TOKEN is empty but MATRIX_BOT_PASSWORD +
MATRIX_BOT_RECOVERY_KEY are present and the local crypto store is
unbootstrapped, mint an access token via bootstrap-from-creds.mjs
(login, restore SSSS via the recovery key, sign this device with the
bot's self-signing key) then persist the token back into .env.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — Docs and end-to-end verification

### Task 9: README + docs

**Goal:** A short README block in `dev-boxer` describing the add-bot flow, plus a one-liner under the existing "No VPS?" section pointing at it.

**Files:**
- Modify: `README.md`
- Create: `docs/adding-bots.md`

- [ ] **Step 1: Create `docs/adding-bots.md`**

```markdown
# Adding bots from another box

When you already have one Dev Boxer machine running with the bundled
homeserver and your Element session set up, you can stand up additional
boxes that connect back to the same homeserver with their own bot —
without typing any human-account credentials anywhere.

## On the homeserver host

```bash
sudo dev-boxer add-bot box4
```

This:
1. Opens a one-time registration window on the local homeserver.
2. Registers `@box4:<server_domain>`.
3. Bootstraps the bot's own secret storage and cross-signing identity.
4. Sends a verification request to your user from the bot.
5. Waits while you open Element, accept the request, and confirm the
   emojis (5-minute timeout).
6. Creates an encrypted bridge room and invites you.
7. Closes the registration window.
8. Prints a one-line credentials blob.

## On the new box

Run the standard installer. When the wizard asks `Matrix homeserver:
(here / there)`, choose `there` and paste the blob. The wizard stores
the bot creds in `secrets.yml`, the matrix-bridge module wires them
into `.env`, and the bridge process bootstraps itself on first start
(restoring the bot's signing keys via the recovery key in the blob and
signing this box's device with the bot's self-signing key).

After the install completes, your existing Element session shows the
new bridge room with `@box4` already verified.

## Re-printing a blob

```bash
sudo dev-boxer add-bot --reprint box4
```

This regenerates the blob from `secrets.yml` (`matrix.bots.box4`) without
touching the homeserver. Useful if you lost the blob between boxes.

## Removing a bot

Not yet supported. Tracked in the design doc's "Out of scope" section.
```

- [ ] **Step 2: Append a section to `README.md`**

Find the "Modules" section in `README.md`. After the table, add:

```markdown
## Multiple boxes, one Element session

If you already have one Dev Boxer running and want to bring up another
box that uses the same Element identity, see [docs/adding-bots.md](docs/adding-bots.md).
The `dev-boxer add-bot <name>` command registers a new bot, has you
sign it via SAS in Element, and prints a blob you paste into the new
box's installer.
```

- [ ] **Step 3: Commit**

```
git add docs/adding-bots.md README.md
git commit -m "$(cat <<'EOF'
docs: explain the add-bot flow for adding boxes to an existing setup

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Manual end-to-end verification

**Goal:** Drive the full add-bot flow on real hardware/VMs and confirm the spec's success criteria. Treat any failure as a defect blocking the PR.

This task does not produce code; it produces test evidence (notes, screenshots, journalctl excerpts) attached to the PR description.

- [ ] **Step 1: Spin up two fresh VMs**

Use multipass on Apple Silicon, Hetzner on Linux, or whatever you have. Two clean Ubuntu 24.04 instances. Call them box-A (homeserver host) and box-B.

- [ ] **Step 2: Install Dev Boxer on box-A with `mode: here`**

Use the standard installer. Confirm:
- Bridge service is running: `sudo systemctl status claude-matrix-bridge`
- Element on phone/laptop signs in via the recovery-key flow.
- Bridge room exists, bot shows verified.
- `!start` works.

- [ ] **Step 3: Run `sudo dev-boxer add-bot box-B` on box-A**

Watch for:
- Registration window opens (look for `docker compose down/up` in the output).
- `@box-B` registered.
- Element on phone/laptop receives a verification request from `@box-B`. Tap Accept.
- Confirm emojis match (Element shows them; the bot side auto-confirms).
- Script reports `verification done` and prints a blob.

If the verification request never arrives, or SAS hangs, abort and capture: the script's stderr, journalctl from `sudo systemctl status` for any matron-server activity, and the relevant matrix-js-sdk version. Map symptoms back to spec open question #3 (verifying the API names).

- [ ] **Step 4: Install Dev Boxer on box-B**

Run the installer. At the matrix prompt pick `there` and paste the blob.

Confirm `secrets.yml` on box-B contains `matrix.bot_user_id`, `bot_password`, `bot_recovery_key`, `bridge_room_id`.

When the matrix-bridge module finishes, watch the bridge service logs:

```
sudo journalctl -u claude-matrix-bridge -f
```

Expect to see the `First-start bootstrap` line, then a successful login message, then the regular bridge startup.

- [ ] **Step 5: Verify the new bot in Element**

Open your existing Element session. The "Claude Code Bridge" room created by `add-bot` should be visible (you were invited as part of the verification flow). The `@box-B` bot should show as verified (green shield, no warnings).

Send a message: `!start`. Confirm a Claude session starts on box-B.

- [ ] **Step 6: Idempotency checks**

On box-B: `sudo /opt/dev-boxer/setup.rb --only matrix-bridge`. Expect: no re-bootstrap, bridge already running, idempotent.

On box-A: `sudo dev-boxer add-bot box-B` (no `--reprint`). Expect: refuse with `Bot 'box-B' already exists in ...`.

On box-A: `sudo dev-boxer add-bot --reprint box-B`. Expect: prints the same blob without contacting the homeserver.

- [ ] **Step 7: Recovery check**

On box-B:

```
sudo systemctl stop claude-matrix-bridge
sudo rm -rf /home/<user>/.claude-matrix-bot-crypto
sudo systemctl start claude-matrix-bridge
```

Watch `journalctl -u claude-matrix-bridge -f`. Expect: bootstrap re-runs from `secrets.yml`'s recovery key, bridge comes back up. The new device is again signed by the bot's self-signing key.

- [ ] **Step 8: Update the spec's open questions if anything was learned**

If you discovered the existing single-machine onboarding is in fact broken (spec open question #1), or the matrix-js-sdk API names differed (open question #3), update the spec inline with what you found and commit:

```
cd /home/youruser/dev-boxer
# edit docs/superpowers/specs/2026-05-02-add-bot-flow-design.md
git add docs/superpowers/specs/2026-05-02-add-bot-flow-design.md
git commit -m "docs(add-bot-spec): record findings from manual E2E"
```

- [ ] **Step 9: Push branches and open PRs**

```
cd /home/youruser/dev-boxer && git push -u origin feat/add-bot-flow-design
cd /home/youruser/claude-matrix-bridge && git push -u origin feat/add-bot-flow
```

Open one PR per repo. In the dev-boxer PR, link the bridge PR and note the order of merging (bridge first — clones in the matrix-bridge module pull `main`, so the bridge change has to land before existing dev-boxer installations re-run setup successfully).

---

## Self-review checklist (run before handoff)

- [ ] Every spec section has at least one task implementing it (CredentialsBlob → T1; helper extraction → T2; schema → T3; wizard → T4; env wiring → T5; CLI/orchestrator → T6; add-bot.mjs → T7; bridge bootstrap → T8; docs → T9; E2E → T10).
- [ ] No `TBD` / `TODO` placeholders in steps. (`wizard_answers_for_there_branch` is intentionally left as a stub for the engineer to fill from the live wizard — that's deliberate, not a placeholder.)
- [ ] Type/method names are consistent across tasks: `MatrixRegistration#open` / `#close` / `#register_bot`, `CredentialsBlob.encode/decode`, `AddBot.new(name:, config:, log:, secrets_path:, registration:, run_mjs:, reprint:)`, env var names match between Ruby (`bridge_env_vars`) and JS (`bootstrap-from-creds.mjs` reads `process.env.MATRIX_BOT_*`).
