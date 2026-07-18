# First-Phone Sign-In QR (matron-admin link-code) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** End bundled-mode provisioning with an ANSI QR on the terminal that signs the first phone straight into the journal account — printed by the new `matron-admin link-code` command (matron-journal feature, already planned separately).

**Architecture:** A shared `JournalEnrollment.matron_admin_command(args)` class method becomes the single place that composes the `runuser -u matron -- sh -c 'cd /opt/matron-journal && MATRON_DB=… npx matron-admin …'` invocation (today that wrapping lives in both `08_matron.rb` and `journal_enrollment.rb`). Module 11's end-of-run `print_matron_login_instructions` then uses it to run `matron-admin link-code <user> --server-url <https base>` and prints the command's stdout (the QR + its own manual-fallback lines). Best-effort: any failure warns and falls back to the username/password lines already printed.

**Tech Stack:** Ruby (stdlib only), Minitest, injected-runner Shell fakes.

## Global Constraints

- Repo: `/Users/danbarker/Dev/dev-boxer`, branch `feat/link-code-qr` (already exists — commit onto it).
- **Test command (this machine has only Ruby 2.6; the repo needs Ruby 3):** full suite `docker run --rm -v "$PWD":/app -w /app ruby:3.3 rake test` (must be the full `ruby:3.3` image — `-slim` lacks git and fails 8 CLI tests); single file `docker run --rm -v "$PWD":/app -w /app ruby:3.3 rake test TEST=test/hello_world_test.rb`. Suite is currently 181 runs, 0 failures.
- The QR step runs ONLY in bundled journal mode (`config.journal&.mode != "external"`), inside `print_matron_login_instructions`' bundled branch — in external mode the journal is on another host, so the loopback-only `/link/preapprove` endpoint this relies on is unreachable by design.
- `--server-url` value: `JournalEnrollment.https_base(exposure.journal_public_url)` — e.g. bundled cloudflare → `https://chat.<domain>`, bundled ip → `https://<ip>:8443`.
- The QR step must be **best-effort**: a `Shell::Error` from the link-code command (e.g. an older matron-journal checkout without the subcommand) is rescued, logged via `warn`, and setup continues — it must never fail provisioning. All matron-admin failure output stays in the local terminal (it can echo the username; that is already printed two lines above).
- All user-supplied values interpolated into shell commands go through `Shellwords.escape` (existing convention).
- Do not change the `matron_admin`/`as_matron` command *strings* — existing tests assert on the recorded command text and must stay green unmodified (except where a step below explicitly edits a test helper's signature).
- **Rollout ordering:** this PR must merge only after the matron-journal link-rendezvous PR (which adds `matron-admin link-code`) — module 08 clones/pulls matron-journal `main` at provision time. Opening the PR early for review is fine.
- TDD, red-green per step. Commit messages end with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: Shared `JournalEnrollment.matron_admin_command`

**Files:**
- Modify: `lib/dev_boxer/journal_enrollment.rb` (add class method ~line 33, after `https_base`; refactor `mint_local_token`, lines 114–124)
- Modify: `lib/dev_boxer/modules/08_matron.rb:101-103` (`matron_admin` delegates)
- Test: `test/journal_enrollment_test.rb`

**Interfaces:**
- Consumes: `JournalEnrollment::JOURNAL_DIR` (`"/opt/matron-journal"`, journal_enrollment.rb:21).
- Produces: `DevBoxer::JournalEnrollment.matron_admin_command(args) → String` — the full root-shell command string. Task 2 calls it from module 11. Contract: for `args = "user add dan"` it returns exactly
  `"runuser -u matron -- sh -c " + Shellwords.escape("cd /opt/matron-journal && MATRON_DB=/opt/matron-journal/data/matron.db npx matron-admin user add dan")`.

- [ ] **Step 1: Write the failing test**

Append to `test/journal_enrollment_test.rb` (inside the existing test class, alongside its other tests — match the file's local style for building nothing: this test needs no instance):

```ruby
def test_matron_admin_command_wraps_runuser_matron_with_db_env
  cmd = DevBoxer::JournalEnrollment.matron_admin_command("user add dan")
  inner = "cd /opt/matron-journal && MATRON_DB=/opt/matron-journal/data/matron.db npx matron-admin user add dan"
  assert_equal "runuser -u matron -- sh -c #{Shellwords.escape(inner)}", cmd
end
```

If the test file does not already `require "shellwords"` (directly or via the code under test), add it at the top.

- [ ] **Step 2: Run test to verify it fails**

Run: `docker run --rm -v "$PWD":/app -w /app ruby:3.3 rake test TEST=test/journal_enrollment_test.rb`
Expected: FAIL with `NoMethodError: undefined method 'matron_admin_command'`

- [ ] **Step 3: Implement the class method and refactor both call sites**

In `lib/dev_boxer/journal_enrollment.rb`, directly after the `https_base` class method (after line 32):

```ruby
    # Full root-shell command for one matron-admin invocation: cd into the
    # checkout, point at the live DB, run as the matron user (root would
    # leave root-owned SQLite WAL files behind and break the service).
    def self.matron_admin_command(args)
      cmd = "cd #{JOURNAL_DIR} && MATRON_DB=#{JOURNAL_DIR}/data/matron.db npx matron-admin #{args}"
      "runuser -u matron -- sh -c #{Shellwords.escape(cmd)}"
    end
```

Refactor `mint_local_token` (keep the comment above it about running as matron — it now lives on the class method, so delete the two-line comment at lines 112–113):

```ruby
    def mint_local_token
      user = config.journal&.username || config.user.name
      out = shell.sh!(self.class.matron_admin_command(
        "agent add #{Shellwords.escape(user)} #{Shellwords.escape(agent_name)}"
      ))
      token = out[/token: (\S+)/, 1]
      raise NotEnrolled, "matron-admin agent add did not print a token:\n#{out}" if token.to_s.empty?
      write_token(token)
      log.ok "Agent #{agent_name} minted for journal user #{user}"
      token_path
    end
```

In `lib/dev_boxer/modules/08_matron.rb`, replace `matron_admin` (lines 101–103) with a delegation (keep `as_matron` untouched — `install_journal` still uses it for git/npm commands):

```ruby
      def matron_admin(args)
        JournalEnrollment.matron_admin_command(args)
      end
```

The produced strings are byte-identical to before, so every existing recorded-command assertion stays green.

- [ ] **Step 4: Run the focused tests, then the full suite**

Run: `docker run --rm -v "$PWD":/app -w /app ruby:3.3 rake test TEST=test/journal_enrollment_test.rb` → PASS
Run: `docker run --rm -v "$PWD":/app -w /app ruby:3.3 rake test` → 182 runs, 0 failures (181 existing + 1 new)

- [ ] **Step 5: Commit**

```bash
git add lib/dev_boxer/journal_enrollment.rb lib/dev_boxer/modules/08_matron.rb test/journal_enrollment_test.rb
git commit -m "Extract shared JournalEnrollment.matron_admin_command

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: First-phone QR in the end-of-run summary

**Files:**
- Modify: `lib/dev_boxer/modules/11_hello_world.rb` (bundled branch of `print_matron_login_instructions`, lines 68–74; new private method; new require)
- Test: `test/hello_world_test.rb`

**Interfaces:**
- Consumes: `JournalEnrollment.matron_admin_command(args)` (Task 1), `JournalEnrollment.https_base(ws_url)` (existing), `exposure.journal_public_url` (existing), `Shell::Error` (raised by `shell.sh!` on failure — full class `DevBoxer::Shell::Error`, referenced as `Shell::Error` from inside the module).
- Produces: terminal output only; no new public interface.

- [ ] **Step 1: Extend the test helper to accept an injectable runner**

In `test/hello_world_test.rb`, replace the private `build_module` helper (lines 69–76) with:

```ruby
  def build_module(output:, secrets_path: nil, config_hash: default_config,
                   runner: ->(_cmd, _opts = {}) { [true, "", ""] })
    DevBoxer::Modules::HelloWorld.new(
      config: DevBoxer::Config.from_hash(config_hash),
      log: DevBoxer::Log.new(io: output, color: false),
      shell: DevBoxer::Shell.new(runner: runner),
      secrets_path: secrets_path,
    )
  end
```

(Default behavior unchanged; existing tests keep passing.)

- [ ] **Step 2: Write the failing tests**

Add to `test/hello_world_test.rb` (and add `require "shellwords"` under the existing requires at the top):

```ruby
  def test_bundled_login_instructions_print_link_code_qr
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      File.write(secrets_path, { "journal" => { "username" => "dan", "user_password" => "journal-pass" } }.to_yaml)
      output = StringIO.new
      recorded = []
      runner = lambda do |cmd, _opts = {}|
        recorded << cmd
        if cmd.include?("link-code")
          [true, "|FAKE-ANSI-QR|\nServer: https://203.0.113.7:8443\nCode: ABCD-EFGH\n", ""]
        else
          [true, "", ""]
        end
      end
      mod = build_module(
        secrets_path: secrets_path,
        output: output,
        runner: runner,
        config_hash: {
          "user" => { "name" => "dev" },
          "journal" => { "mode" => "bundled" },
          "exposure" => { "mode" => "ip", "ip" => { "address" => "203.0.113.7" } },
        },
      )

      mod.send(:print_matron_login_instructions)

      link_cmd = recorded.find { |c| c.include?("link-code") }
      refute_nil link_cmd, "expected a matron-admin link-code invocation"
      assert_includes link_cmd, "runuser -u matron"
      # Inner command is Shellwords-escaped, so spaces appear as "\ ".
      assert_includes link_cmd, "link-code\\ dan\\ --server-url\\ https://203.0.113.7:8443"

      summary = output.string
      assert_includes summary, "|FAKE-ANSI-QR|"
      assert_includes summary, "Code: ABCD-EFGH"
      assert_includes summary, "scan this QR"
      assert_includes summary, "Password: journal-pass"
    end
  end

  def test_bundled_qr_uses_cloudflare_hostname_when_configured
    output = StringIO.new
    recorded = []
    runner = ->(cmd, _opts = {}) { recorded << cmd; [true, "qr\n", ""] }
    mod = build_module(
      output: output,
      runner: runner,
      config_hash: {
        "user" => { "name" => "dev" },
        "journal" => { "mode" => "bundled" },
        "exposure" => {
          "mode" => "cloudflare",
          "cloudflare" => { "tunnel" => { "hostname_journal" => "chat.example.com" } },
        },
      },
    )

    mod.send(:print_matron_login_instructions)

    link_cmd = recorded.find { |c| c.include?("link-code") }
    refute_nil link_cmd
    assert_includes link_cmd, "--server-url\\ https://chat.example.com"
  end

  def test_link_code_failure_warns_and_keeps_password_login
    output = StringIO.new
    runner = lambda do |cmd, _opts = {}|
      cmd.include?("link-code") ? [false, "", "unknown command: link-code"] : [true, "", ""]
    end
    mod = build_module(
      output: output,
      runner: runner,
      config_hash: {
        "user" => { "name" => "dev" },
        "journal" => { "mode" => "bundled" },
        "exposure" => { "mode" => "ip", "ip" => { "address" => "203.0.113.7" } },
      },
    )

    mod.send(:print_matron_login_instructions)

    summary = output.string
    assert_includes summary, "Couldn't mint a sign-in QR"
    assert_includes summary, "bin/enroll" # instructions continue past the failure
  end

  def test_external_mode_never_runs_link_code
    output = StringIO.new
    recorded = []
    runner = ->(cmd, _opts = {}) { recorded << cmd; [true, "", ""] }
    mod = build_module(
      output: output,
      runner: runner,
      config_hash: {
        "user" => { "name" => "dev" },
        "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" },
        "exposure" => { "mode" => "ip", "ip" => { "address" => "203.0.113.7" } },
      },
    )

    mod.send(:print_matron_login_instructions)

    assert_empty recorded.select { |c| c.include?("link-code") }
  end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `docker run --rm -v "$PWD":/app -w /app ruby:3.3 rake test TEST=test/hello_world_test.rb`
Expected: the first three new tests FAIL (no `link-code` command recorded / missing output); `test_external_mode_never_runs_link_code` passes trivially (acceptable — it guards the regression the implementation could introduce).

- [ ] **Step 4: Implement**

In `lib/dev_boxer/modules/11_hello_world.rb`:

Add under the existing `require "yaml"` (line 1):

```ruby
require "shellwords"
```

Replace the bundled `else` branch of `print_matron_login_instructions` (lines 68–74) with:

```ruby
        else
          secrets = merged_config_hash
          journal_user = secrets.dig("journal", "username") || username
          info "Open the Matron app (iOS / desktop / web) and add this server:"
          info "  Server:   #{exposure.journal_public_url}"
          info "  Username: #{journal_user}"
          info "  Password: #{secrets.dig('journal', 'user_password') || '(missing from secrets.yml)'}"
          print_first_phone_qr(journal_user)
        end
```

Add a private method after `print_matron_login_instructions`:

```ruby
      # Prints matron-admin link-code's ANSI QR: scanning it signs the first
      # phone straight into the journal account (pre-approved link code, no
      # approve tap). Best-effort — on any failure the username/password
      # printed above still work.
      def print_first_phone_qr(journal_user)
        server = JournalEnrollment.https_base(exposure.journal_public_url)
        out = shell.sh!(JournalEnrollment.matron_admin_command(
          "link-code #{Shellwords.escape(journal_user)} --server-url #{Shellwords.escape(server)}"
        ))
        info ""
        info "Or scan this QR with the Matron app to sign the first phone in (valid ~10 minutes):"
        out.each_line { |line| info line.chomp }
      rescue Shell::Error => e
        warn "Couldn't mint a sign-in QR (#{e.message.lines.first&.strip}) — sign in with the username/password above."
      end
```

- [ ] **Step 5: Run the focused tests, then the full suite**

Run: `docker run --rm -v "$PWD":/app -w /app ruby:3.3 rake test TEST=test/hello_world_test.rb` → PASS (8 runs in the file)
Run: `docker run --rm -v "$PWD":/app -w /app ruby:3.3 rake test` → 186 runs, 0 failures

- [ ] **Step 6: Update README**

In `README.md`, in the bundled-mode sign-in step of the **Matron chat** connecting section (the numbered list around line 181: "3. Sign in: bundled mode uses the journal username/password setup printed and stored in `secrets.yml`; external mode uses your existing account on that journal"), replace item 3 with:

```markdown
3. Sign in: in bundled mode, either scan the QR printed at the end of setup (signs the first phone in directly) or use the journal username/password setup printed and stored in `secrets.yml`; external mode uses your existing account on that journal
```

- [ ] **Step 7: Commit**

```bash
git add lib/dev_boxer/modules/11_hello_world.rb test/hello_world_test.rb README.md
git commit -m "Print first-phone sign-in QR at end of bundled provisioning

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Final Verification

- [ ] Full suite green: `docker run --rm -v "$PWD":/app -w /app ruby:3.3 rake test` → 186 runs, 0 failures, 0 errors
- [ ] `git log origin/main..HEAD --oneline` shows exactly the plan's commits (plus the plan doc commit)
- [ ] Open a **non-draft** PR against `main` titled "Print first-phone sign-in QR at end of bundled provisioning"; body notes it depends on the matron-journal link-rendezvous PR (`matron-admin link-code`) merging first and must not merge before it. PR body ends with:
  `🤖 Generated with [Claude Code](https://claude.com/claude-code)`
