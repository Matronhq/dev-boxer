# "Link a Phone Later" Provisioning Hints Implementation Plan (dev-boxer)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The bundled-journal provisioning summary prints two copy-paste commands for linking a phone after provisioning: a re-mint of the terminal QR, and a 24-hour PNG hand-off variant with scp/cleanup lines.

**Architecture:** A new private `print_link_later_hints` method in the HelloWorld module (module 11), called from the bundled branch of `print_matron_login_instructions`. It builds the remote commands through the existing `JournalEnrollment.matron_admin_command` / `https_base` helpers (so the printed lines and the code path that actually runs `matron-admin` can never drift apart) and wraps them in `ssh root@<host> …` using a best-effort `hostname -f`.

**Tech Stack:** Ruby, Minitest (`rake test`, or per-file `ruby -Ilib -Itest test/hello_world_test.rb`).

**Spec:** `matron-journal` repo, `docs/superpowers/specs/2026-07-20-preapproved-link-code-persistence-design.md` §5 (approved). The `--expires`/`--png` flags the hints reference are implemented by the matron-journal plan; the hints are just printed strings, so this plan has no runtime dependency on that work.

## Global Constraints

- Bundled-journal mode only — external mode has no local `matron-admin`, so no hints there.
- The block prints unconditionally in bundled mode, even when the at-provision QR mint failed (that is exactly when it is needed).
- The hand-off variant uses exactly `--expires 24h --png /tmp/matron-link.png`, followed by an scp-then-delete line.
- Command strings are built via `JournalEnrollment.matron_admin_command` and `JournalEnrollment.https_base(exposure.journal_public_url)` — never hand-assembled duplicates.
- Modules MUST NOT branch on the exposure mode (`lib/dev_boxer/exposure.rb` contract) — hence `hostname -f` for the SSH host, not exposure internals.
- Existing tests in `test/hello_world_test.rb` must keep passing unchanged.
- Work on a new branch `feat/link-later-hints` off `origin/main`.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `print_link_later_hints` in the HelloWorld module

**Files:**
- Modify: `lib/dev_boxer/modules/11_hello_world.rb`
- Test: `test/hello_world_test.rb`

**Interfaces:**
- Consumes: `JournalEnrollment.https_base(ws_url)` → `"https://host[:port]"`; `JournalEnrollment.matron_admin_command(args)` → the full `runuser -u matron -- sh -c '…'` string; `shell.sh!(cmd)` → stdout string (raises `Shell::Error` on failure); `exposure.journal_public_url`; the module's `info` logger.
- Produces: `print_link_later_hints(journal_user)` (private) and `link_later_host` (private, best-effort `hostname -f` with `"<this-box>"` fallback). No public interface changes.

- [ ] **Step 0: Check out the branch**

The branch already exists with this plan committed on it:

```bash
git checkout feat/link-later-hints
```

- [ ] **Step 1: Write the failing test**

Append inside the `HelloWorldTest` class in `test/hello_world_test.rb` (before the `private` section holding `build_module`):

```ruby
  def test_bundled_summary_prints_link_later_hints
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      File.write(secrets_path, { "journal" => { "username" => "dan", "user_password" => "journal-pass" } }.to_yaml)
      output = StringIO.new
      runner = lambda do |cmd, _opts = {}|
        if cmd.include?("hostname -f")
          [true, "box1.example.com\n", ""]
        elsif cmd.include?("link-code")
          [true, "qr\n", ""]
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

      summary = output.string
      assert_includes summary, "Link a phone later"
      # Both hint lines wrap the real matron-admin command in ssh to this box.
      ssh_lines = summary.lines.select { |l| l.include?("ssh root@box1.example.com") }
      assert_equal 3, ssh_lines.count, summary # re-mint, png mint, and the rm in the scp line
      # The remote command is the same runuser/MATRON_DB wrapper the live QR
      # mint uses (Shellwords-escaped for the ssh hop, hence \-escapes).
      assert_includes summary, "runuser"
      assert_includes summary, "link-code"
      assert_includes summary, "--expires"
      assert_includes summary, "24h"
      assert_includes summary, "/tmp/matron-link.png"
      assert_includes summary, "scp root@box1.example.com:/tmp/matron-link.png ."
    end
  end

  def test_link_later_hints_fall_back_when_hostname_fails
    output = StringIO.new
    runner = lambda do |cmd, _opts = {}|
      # sh! raises Shell::Error itself when the runner reports failure —
      # returning [false, ...] exercises the real error path.
      next [false, "", "boom"] if cmd.include?("hostname -f")
      [true, "", ""]
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

    assert_includes output.string, "ssh root@<this-box>"
  end
```

(`Shell#sh!` in `lib/dev_boxer/shell.rb` calls `@runner.call(cmd, opts)` expecting `[success, stdout, stderr]` and raises `Shell::Error` itself when `success` is false — which is why the failure test returns `[false, "", "boom"]` rather than raising from the lambda.)

- [ ] **Step 2: Run to verify it fails**

Run: `ruby -Ilib -Itest test/hello_world_test.rb`
Expected: the two new tests FAIL with `"Link a phone later"` / `"ssh root@"` missing from the summary; all pre-existing tests still pass.

- [ ] **Step 3: Implement**

In `lib/dev_boxer/modules/11_hello_world.rb`, in `print_matron_login_instructions`, add the call directly after `print_first_phone_qr(journal_user)` in the bundled (`else`) branch:

```ruby
          print_first_phone_qr(journal_user)
          print_link_later_hints(journal_user)
```

In `print_first_phone_qr`, switch the inline args string to the new shared builder (behaviour identical — existing tests prove it):

```ruby
        out = shell.sh!(JournalEnrollment.matron_admin_command(link_code_args(journal_user)))
```

(replacing the current three-line `shell.sh!(JournalEnrollment.matron_admin_command("link-code #{Shellwords.escape(journal_user)} --server-url #{Shellwords.escape(server)}"))` call and deleting the now-unused `server = JournalEnrollment.https_base(exposure.journal_public_url)` local above it).

Add the two private methods after `print_first_phone_qr`:

```ruby
      # Copy-paste commands for linking a phone AFTER provisioning: a fresh
      # terminal QR, and a 24-hour PNG for handing to someone else. Printed
      # even when the at-provision QR mint failed — that is exactly the
      # situation where a re-mint hint is needed. The remote command comes
      # from JournalEnrollment.matron_admin_command so these lines can never
      # drift from what the live mint actually runs.
      def print_link_later_hints(journal_user)
        mint = JournalEnrollment.matron_admin_command(link_code_args(journal_user))
        png = JournalEnrollment.matron_admin_command("#{link_code_args(journal_user)} --expires 24h --png /tmp/matron-link.png")
        host = link_later_host
        info ""
        info "Link a phone later:"
        info "  Mint a fresh sign-in QR in your terminal (valid 10 minutes):"
        info "    ssh root@#{host} #{Shellwords.escape(mint)}"
        info "  Or mint a 24-hour QR image to send to someone — it signs them"
        info "  straight in, so treat the file like a password:"
        info "    ssh root@#{host} #{Shellwords.escape(png)}"
        info "    scp root@#{host}:/tmp/matron-link.png . && ssh root@#{host} rm /tmp/matron-link.png"
      end

      # The one place the link-code invocation is assembled — the live QR
      # mint (print_first_phone_qr) and the printed hints both use it, so
      # the hint lines can never drift from what actually runs.
      def link_code_args(journal_user)
        server = JournalEnrollment.https_base(exposure.journal_public_url)
        "link-code #{Shellwords.escape(journal_user)} --server-url #{Shellwords.escape(server)}"
      end

      # Best-effort SSH host for the hint lines. hostname -f rather than the
      # exposure hostname: in cloudflare mode the public hostname fronts an
      # HTTP-only tunnel you cannot ssh to, and modules must not branch on
      # the exposure mode (see lib/dev_boxer/exposure.rb).
      def link_later_host
        h = shell.sh!("hostname -f").strip
        h.empty? ? "<this-box>" : h
      rescue Shell::Error
        "<this-box>"
      end
```

- [ ] **Step 4: Run to verify it passes**

Run: `ruby -Ilib -Itest test/hello_world_test.rb`
Expected: PASS, all tests.

- [ ] **Step 5: Run the full suite**

Run: `rake test`
Expected: PASS, zero failures.

- [ ] **Step 6: Commit**

```bash
git add lib/dev_boxer/modules/11_hello_world.rb test/hello_world_test.rb
git commit -m "Print link-a-phone-later hints in the provisioning summary

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
