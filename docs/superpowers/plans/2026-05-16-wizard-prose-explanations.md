# Wizard Prose Explanations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every wizard prompt a short prose preface (what's being asked, why, what to do), replacing the seven existing `What:` / `Why:` / `How:` / `Tip:` / `Cost:` / `Link:` labelled-bullet blocks with prose in the same style, and filling six missing prefaces (Linux username, SSH key, SSH port, Matrix here/there, Matrix username, add-bot blob) plus rewriting the inline Claude-behavior summary as a proper `explain_*` method.

**Architecture:** Single-file source change in `lib/dev_boxer/wizard.rb`. Each prompt gets a small private `explain_*` method that emits one paragraph via `output.puts`; the wizard calls it on the line immediately before the corresponding `ask`/`ask_choice`/`confirm`. No new files, no copy-extraction abstraction, no flag toggles. Existing wizard tests assert on specific substrings of the rendered output; updates to those assertions are part of the change.

**Tech Stack:** Ruby 3.2, Minitest, Rake.

**Spec:** `docs/superpowers/specs/2026-05-16-wizard-explanations-design.md`

**Branch:** `feat/wizard-prose-explanations` (already created, off `main`, spec already committed as `a00b64d`).

---

## House style for the prose

- Each `explain_*` method begins and ends with a blank `output.puts` line (matches the existing pattern).
- Second line is the topic header followed by `:` — e.g. `"Linux username:"`. No indentation on this line.
- Body sentences follow, one per `output.puts` call, no leading whitespace. Each sentence stands as its own readable line in the terminal.
- Plain language. No `What:` / `Why:` / `How:` / `Tip:` / `Cost:` / `Link:` labels. Inline URLs into the sentences instead of appending a separate `Link:` line.
- US spelling, sentence case, ASCII dashes (`—` is fine where it improves the read).

---

## Task 1: Add prefaces for server-login prompts

**Files:**
- Modify: `lib/dev_boxer/wizard.rb` (add three new `explain_*` methods and three wiring lines in `build_config`)
- Modify: `test/wizard_test.rb` (add three `assert_includes` lines)

- [ ] **Step 1: Add the failing assertions to the wizard test**

Open `test/wizard_test.rb`. Find the line near the top of `test_wizard_writes_config_and_secrets` that asserts `wizard_output, "== 1. Server login =="` and add the three new assertions immediately after it:

```ruby
      assert_includes wizard_output, "== 1. Server login =="
      assert_includes wizard_output, "Linux username:"
      assert_includes wizard_output, "The Linux account you'll ssh into"
      assert_includes wizard_output, "SSH public key:"
      assert_includes wizard_output, "Paste the public key you'll use to ssh into the box"
      assert_includes wizard_output, "SSH port:"
      assert_includes wizard_output, "non-standard port to cut down on the noise"
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `cd ~/projects/dev-boxer && rake test TESTOPTS='--name=test_wizard_writes_config_and_secrets'`

Expected: 1 failure with one of the new substrings missing from `wizard_output`. (Minitest stops on the first failed `assert_includes`, so you may need to fix and re-run to see all three fail.)

- [ ] **Step 3: Add the three new explain methods to wizard.rb**

Open `lib/dev_boxer/wizard.rb`. Locate `def explain_base_domain` (currently the first `explain_*` method in the file). Immediately above it, insert these three new methods:

```ruby
    def explain_linux_username
      output.puts
      output.puts "Linux username:"
      output.puts "The Linux account you'll ssh into and do your work as."
      output.puts "`dev` is fine if you don't have a preference; just avoid `root` — Dev Boxer disables root login regardless."
      output.puts
    end

    def explain_ssh_public_key
      output.puts
      output.puts "SSH public key:"
      output.puts "Paste the public key you'll use to ssh into the box."
      output.puts "Dev Boxer adds it to authorized_keys for this account, and password login is disabled."
      output.puts "Generate one with `ssh-keygen -t ed25519` if you don't already have a key on your laptop."
      output.puts
    end

    def explain_ssh_port
      output.puts
      output.puts "SSH port:"
      output.puts "Dev Boxer puts ssh on a non-standard port to cut down on the noise from automated scanners hammering port 22."
      output.puts "2222 is the default; pick whatever you like between 1024 and 65535."
      output.puts
    end
```

- [ ] **Step 4: Wire the three new methods into `build_config`**

Still in `lib/dev_boxer/wizard.rb`, find this block at the top of `build_config`:

```ruby
      section_header("1. Server login")
      username = ask("Linux username", default: existing.dig("user", "name") || default_username)
      ssh_key = ask("SSH public key", default: existing.dig("user", "ssh_public_key") || default_ssh_public_key)
      ssh_port = ask_integer("SSH port", default: existing.dig("ssh", "port") || DEFAULT_SSH_PORT)
```

Replace it with:

```ruby
      section_header("1. Server login")
      explain_linux_username
      username = ask("Linux username", default: existing.dig("user", "name") || default_username)
      explain_ssh_public_key
      ssh_key = ask("SSH public key", default: existing.dig("user", "ssh_public_key") || default_ssh_public_key)
      explain_ssh_port
      ssh_port = ask_integer("SSH port", default: existing.dig("ssh", "port") || DEFAULT_SSH_PORT)
```

- [ ] **Step 5: Run the test and verify it passes**

Run: `cd ~/projects/dev-boxer && rake test TESTOPTS='--name=test_wizard_writes_config_and_secrets'`

Expected: 1 run, all assertions pass, 0 failures.

- [ ] **Step 6: Run the full suite to confirm no regressions**

Run: `cd ~/projects/dev-boxer && rake test`

Expected: all tests pass, 0 failures.

- [ ] **Step 7: Commit**

```bash
cd ~/projects/dev-boxer
git -c user.name="Dan Barker" -c user.email="you@example.com" add lib/dev_boxer/wizard.rb test/wizard_test.rb
git -c user.name="Dan Barker" -c user.email="you@example.com" commit -m "Preface server-login prompts with prose explanations

Linux username, SSH key, and SSH port now get a short prose paragraph
before the prompt — what's being asked, why, what to do — in the same
inline output.puts pattern as the existing explain_* methods."
```

---

## Task 2: Rewrite domain-and-DNS prefaces as prose

**Files:**
- Modify: `lib/dev_boxer/wizard.rb` (rewrite four existing `explain_*` methods)
- Modify: `test/wizard_test.rb` (update existing assertions to match new prose)

- [ ] **Step 1: Update wizard test assertions to match new prose**

Open `test/wizard_test.rb`. Find this block (currently lines ~74-80, but locate by the `"Tip:"` substring):

```ruby
      assert_includes wizard_output, "hello.<domain>"
      assert_includes wizard_output, "can create new subdomains for projects you make"
      assert_includes wizard_output, "Tip: We recommend giving the box its own domain."
      assert_includes wizard_output, "Cost: Low-cost domains such as .uk or .us often start around $5-6/year"
      assert_includes wizard_output, "Cloudflare zone DNS API token:"
      assert_includes wizard_output, "What: A zone-scoped Cloudflare API token for example.com."
      assert_includes wizard_output, "new subdomains for projects you make"
      assert_includes wizard_output, "How: Create a custom token at https://dash.cloudflare.com/profile/api-tokens"
      assert_includes wizard_output, "Scope: Limit the token to the example.com zone only. Do not grant access to all zones."
```

Replace it with:

```ruby
      assert_includes wizard_output, "Base domain:"
      assert_includes wizard_output, "Pick the Cloudflare-managed domain Dev Boxer should use"
      assert_includes wizard_output, "create dev, matrix, viewer, and hello subdomains"
      assert_includes wizard_output, "we recommend giving the box its own domain"
      assert_includes wizard_output, ".uk and .us names start around $5"
      assert_includes wizard_output, "Cloudflare zone DNS API token:"
      assert_includes wizard_output, "zone-scoped API token for example.com"
      assert_includes wizard_output, "any project subdomains you make later"
      assert_includes wizard_output, "Create one at https://dash.cloudflare.com/profile/api-tokens"
      assert_includes wizard_output, "scoped to this zone only"
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `cd ~/projects/dev-boxer && rake test TESTOPTS='--name=test_wizard_writes_config_and_secrets'`

Expected: 1 failure — the new substring (`"Pick the Cloudflare-managed domain Dev Boxer should use"` or one of the others) is not present because the wizard still emits the old labelled-bullet copy.

- [ ] **Step 3: Rewrite `explain_base_domain` to prose**

Open `lib/dev_boxer/wizard.rb`. Replace the existing `def explain_base_domain ... end` block with:

```ruby
    def explain_base_domain
      output.puts
      output.puts "Base domain:"
      output.puts "Pick the Cloudflare-managed domain Dev Boxer should use, e.g. example.com."
      output.puts "Dev Boxer will create dev, matrix, viewer, and hello subdomains under it, plus more for any projects you build later."
      output.puts "If you don't already have one, we recommend giving the box its own domain — .uk and .us names start around $5–6/year at https://www.cloudflare.com/products/registrar/."
      output.puts "An existing domain works too; just move it to Cloudflare DNS first."
      output.puts
    end
```

- [ ] **Step 4: Rewrite `explain_cloudflare_zone_token` to prose**

Replace the existing `def explain_cloudflare_zone_token(base_domain) ... end` block with:

```ruby
    def explain_cloudflare_zone_token(base_domain)
      output.puts
      output.puts "Cloudflare zone DNS API token:"
      output.puts "Dev Boxer needs a zone-scoped API token for #{base_domain} so it can create and update DNS records for dev, matrix, viewer, hello, and any project subdomains you make later."
      output.puts "Create one at https://dash.cloudflare.com/profile/api-tokens with Zone:Read and DNS:Edit, scoped to this zone only — never all zones."
      output.puts "Choose no below if you'd rather create each subdomain manually."
      output.puts
    end
```

- [ ] **Step 5: Rewrite `explain_manual_dns_setup` to prose**

Replace the existing `def explain_manual_dns_setup(base_domain) ... end` block with:

```ruby
    def explain_manual_dns_setup(base_domain)
      output.puts
      output.puts "Manual DNS selected:"
      output.puts "Dev Boxer won't store an API token."
      output.puts "Once the tunnel exists you'll need to create proxied CNAME records for dev.#{base_domain}, matrix.#{base_domain}, viewer.#{base_domain}, and hello.#{base_domain}, pointing at the tunnel target Dev Boxer prints (usually <TunnelID>.cfargotunnel.com)."
      output.puts "Any future project subdomains will also be your responsibility to create."
      output.puts
    end
```

- [ ] **Step 6: Rewrite `explain_manual_access_after_manual_dns` to prose**

Replace the existing `def explain_manual_access_after_manual_dns ... end` block with:

```ruby
    def explain_manual_access_after_manual_dns
      output.puts
      output.puts "Cloudflare Access will be manual too:"
      output.puts "Dev Boxer normally derives your Cloudflare account from the zone DNS token, and without that token it can't reach the Access API."
      output.puts "Create the Access app yourself later from the dashboard if you want browser SSO on dev, viewer, and hello — see docs/cloudflare-access.md."
      output.puts
    end
```

- [ ] **Step 7: Run the test and verify it passes**

Run: `cd ~/projects/dev-boxer && rake test TESTOPTS='--name=test_wizard_writes_config_and_secrets'`

Expected: 1 run, all assertions pass.

- [ ] **Step 8: Run the full suite to confirm no regressions**

Run: `cd ~/projects/dev-boxer && rake test`

Expected: all tests pass.

- [ ] **Step 9: Commit**

```bash
cd ~/projects/dev-boxer
git -c user.name="Dan Barker" -c user.email="you@example.com" add lib/dev_boxer/wizard.rb test/wizard_test.rb
git -c user.name="Dan Barker" -c user.email="you@example.com" commit -m "Rewrite domain-and-DNS wizard prefaces as prose

Convert the four labelled-bullet explain methods (base_domain,
cloudflare_zone_token, manual_dns_setup, manual_access_after_manual_dns)
to short prose paragraphs in the same style as the rest of the wizard.
Update the corresponding assertions in test/wizard_test.rb to match
the new copy."
```

---

## Task 3: Rewrite Cloudflare tunnel/Access prefaces as prose

**Files:**
- Modify: `lib/dev_boxer/wizard.rb` (rewrite three existing `explain_*` methods)
- Modify: `test/wizard_test.rb` (add assertions for new copy)

- [ ] **Step 1: Add assertions for the rewritten prose**

Open `test/wizard_test.rb`. Below the assertions for zone-token copy (which Task 2 left looking for `"scoped to this zone only"`), add these:

```ruby
      assert_includes wizard_output, "Cloudflare automation:"
      assert_includes wizard_output, "Dev Boxer can create the Cloudflare Tunnel"
      assert_includes wizard_output, "Matrix stays outside Access"
      assert_includes wizard_output, "One-time Cloudflare account setup token:"
      assert_includes wizard_output, "one-time account-level Cloudflare API token used only to create the tunnel"
      assert_includes wizard_output, "Cloudflare One Connector: cloudflared: Edit"
      assert_includes wizard_output, "wipes it from secrets.yml"
```

(The existing test path answers `yes` to "manage DNS" and `yes` to "let Dev Boxer create the tunnel", so `explain_cloudflare_automation` and `explain_cloudflare_setup_token` both fire. `explain_manual_cloudflare_setup`, `explain_manual_dns_setup`, and `explain_manual_access_after_manual_dns` only fire on manual-mode answers, which this test doesn't take; asserting on their copy is out of scope for this task. If those paths grow test coverage later they can pick up matching assertions then.)

- [ ] **Step 2: Run the test and verify it fails**

Run: `cd ~/projects/dev-boxer && rake test TESTOPTS='--name=test_wizard_writes_config_and_secrets'`

Expected: 1 failure on the first new assertion (the rewritten setup-token prose isn't in the output yet).

- [ ] **Step 3: Rewrite `explain_cloudflare_automation` to prose**

Open `lib/dev_boxer/wizard.rb`. Replace the existing `def explain_cloudflare_automation ... end` block with:

```ruby
    def explain_cloudflare_automation
      output.puts
      output.puts "Cloudflare automation:"
      output.puts "Dev Boxer can create the Cloudflare Tunnel (which exposes your hostnames without opening any inbound ports) and a Zero Trust Access app (browser SSO) in one go."
      output.puts "Matrix stays outside Access so Matrix clients keep working normally."
      output.puts "Say no if you'd rather run the cloudflared tunnel login and cloudflared tunnel create commands by hand — Dev Boxer will pause and tell you exactly what to run, then ask for the resulting TunnelID."
      output.puts
    end
```

- [ ] **Step 4: Rewrite `explain_manual_cloudflare_setup` to prose**

Replace the existing `def explain_manual_cloudflare_setup ... end` block with:

```ruby
    def explain_manual_cloudflare_setup
      output.puts
      output.puts "Manual Cloudflare setup selected:"
      output.puts "Dev Boxer will install cloudflared, print the exact `cloudflared tunnel login` and `cloudflared tunnel create` commands to run in another root shell, then ask you to paste the resulting TunnelID."
      output.puts "It won't create the Access app either — set that up later from the dashboard if you want SSO; see docs/cloudflare-access.md."
      output.puts
    end
```

- [ ] **Step 5: Rewrite `explain_cloudflare_setup_token` to prose**

Replace the existing `def explain_cloudflare_setup_token ... end` block with:

```ruby
    def explain_cloudflare_setup_token
      output.puts
      output.puts "One-time Cloudflare account setup token:"
      output.puts "A one-time account-level Cloudflare API token used only to create the tunnel and the Access app."
      output.puts "Create a custom token at https://dash.cloudflare.com/profile/api-tokens with these account permissions: Cloudflare One Connector: cloudflared: Edit, Access: Apps: Edit, and Access: Policies: Edit."
      output.puts "Dev Boxer wipes it from secrets.yml as soon as setup finishes."
      output.puts
    end
```

- [ ] **Step 6: Run the test and verify it passes**

Run: `cd ~/projects/dev-boxer && rake test TESTOPTS='--name=test_wizard_writes_config_and_secrets'`

Expected: 1 run, all assertions pass.

- [ ] **Step 7: Run the full suite to confirm no regressions**

Run: `cd ~/projects/dev-boxer && rake test`

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
cd ~/projects/dev-boxer
git -c user.name="Dan Barker" -c user.email="you@example.com" add lib/dev_boxer/wizard.rb test/wizard_test.rb
git -c user.name="Dan Barker" -c user.email="you@example.com" commit -m "Rewrite Cloudflare tunnel/Access wizard prefaces as prose

Convert cloudflare_automation, manual_cloudflare_setup, and
cloudflare_setup_token from labelled bullets to short prose paragraphs.
Add corresponding assertions to test/wizard_test.rb."
```

---

## Task 4: Add prefaces for Matrix prompts

**Files:**
- Modify: `lib/dev_boxer/wizard.rb` (add three new `explain_*` methods and three wiring lines)
- Modify: `test/wizard_test.rb` (add three `assert_includes` lines)

- [ ] **Step 1: Add the failing assertions to the wizard test**

Open `test/wizard_test.rb`. Find the `"== 4. Matrix =="` assertion. Add immediately after it:

```ruby
      assert_includes wizard_output, "== 4. Matrix =="
      assert_includes wizard_output, "Matrix homeserver location:"
      assert_includes wizard_output, "Choose `here` for the standard setup"
      assert_includes wizard_output, "Matrix username:"
      assert_includes wizard_output, "local part of your Matrix user"
```

(The add-bot blob preface fires on the `there` branch only; the existing test takes the `here` branch. We cover that preface separately in the `test_wizard_there_branch_decodes_blob_and_writes_creds_to_secrets` test in Step 4 below.)

- [ ] **Step 2: Run the test and verify it fails**

Run: `cd ~/projects/dev-boxer && rake test TESTOPTS='--name=test_wizard_writes_config_and_secrets'`

Expected: 1 failure on `"Matrix homeserver location:"` not being in the output.

- [ ] **Step 3: Add the three new Matrix explain methods**

Open `lib/dev_boxer/wizard.rb`. Locate `def ask_blob_until_valid` (the private helper). Immediately above it, insert these three methods:

```ruby
    def explain_matrix_location
      output.puts
      output.puts "Matrix homeserver location:"
      output.puts "Where should Matrix live?"
      output.puts "Choose `here` for the standard setup — Dev Boxer runs a fresh Matrix homeserver on this box and your Element account talks directly to it."
      output.puts "Choose `there` if you already have another Dev Boxer host running Matrix and want this box to join your existing Element session as a separate bot identity (you'll paste an add-bot blob from the other box on the next prompt)."
      output.puts
    end

    def explain_matrix_username
      output.puts
      output.puts "Matrix username:"
      output.puts "The local part of your Matrix user — the bit before the colon in @you:matrix.example.com."
      output.puts "Defaults to your Linux username, which is usually what you want."
      output.puts
    end

    def explain_add_bot_blob
      output.puts
      output.puts "Add-bot blob:"
      output.puts "Paste the blob from running `dev-boxer add-bot <name>` on your existing homeserver box."
      output.puts "It encodes the new bot's credentials and the bridge room id so this box can join your Element session as a separate identity — see docs/adding-bots.md."
      output.puts
    end
```

- [ ] **Step 4: Wire `explain_matrix_location` and `explain_matrix_username` into `build_config`**

Still in `lib/dev_boxer/wizard.rb`, find this block in `build_config`:

```ruby
      section_header("4. Matrix")
      matrix_choice = ask_choice(
        "Matrix homeserver location",
        choices: %w[here there],
        default: existing.dig("matrix", "mode") == "external" ? "there" : "here",
      )

      matrix_user, matrix_overrides, matrix_secret_fields =
        case matrix_choice
        when "here"
          name = ask("Matrix username", default: existing.dig("matrix", "user_username") || username)
```

Replace it with:

```ruby
      section_header("4. Matrix")
      explain_matrix_location
      matrix_choice = ask_choice(
        "Matrix homeserver location",
        choices: %w[here there],
        default: existing.dig("matrix", "mode") == "external" ? "there" : "here",
      )

      matrix_user, matrix_overrides, matrix_secret_fields =
        case matrix_choice
        when "here"
          explain_matrix_username
          name = ask("Matrix username", default: existing.dig("matrix", "user_username") || username)
```

- [ ] **Step 5: Wire `explain_add_bot_blob` into `ask_blob_until_valid`**

Still in `lib/dev_boxer/wizard.rb`, locate the existing `def ask_blob_until_valid` method:

```ruby
    def ask_blob_until_valid
      loop do
        raw = ask("Paste add-bot blob from your homeserver box", secret: true)
```

Replace it with:

```ruby
    def ask_blob_until_valid
      explain_add_bot_blob
      loop do
        raw = ask("Paste add-bot blob from your homeserver box", secret: true)
```

- [ ] **Step 6: Add assertion for the add-bot blob preface in the "there" test**

In `test/wizard_test.rb`, find `def test_wizard_there_branch_decodes_blob_and_writes_creds_to_secrets`. Inside that test, after `DevBoxer::Wizard.run(...)` returns, add this assertion (anywhere before the test's end):

```ruby
      assert_includes output.string, "Paste the blob from running `dev-boxer add-bot"
```

- [ ] **Step 7: Run the relevant tests and verify they pass**

Run: `cd ~/projects/dev-boxer && rake test TESTOPTS='--name=/wizard/'`

Expected: all wizard tests pass.

- [ ] **Step 8: Run the full suite to confirm no regressions**

Run: `cd ~/projects/dev-boxer && rake test`

Expected: all tests pass.

- [ ] **Step 9: Commit**

```bash
cd ~/projects/dev-boxer
git -c user.name="Dan Barker" -c user.email="you@example.com" add lib/dev_boxer/wizard.rb test/wizard_test.rb
git -c user.name="Dan Barker" -c user.email="you@example.com" commit -m "Preface Matrix prompts with prose explanations

The Matrix here/there choice, the matrix username prompt, and the
add-bot blob paste now each get a short prose paragraph in the same
style as the rest of the wizard."
```

---

## Task 5: Convert Claude-behavior inline summary to a proper explain method

**Files:**
- Modify: `lib/dev_boxer/wizard.rb` (remove inline puts in `build_claude_config`, add `explain_claude_experience_level`)
- Modify: `test/wizard_test.rb` (replace three existing claude-related assertions)

- [ ] **Step 1: Update wizard test assertions for Claude-behavior copy**

Open `test/wizard_test.rb`. Find this block (look for `"Beginner: explain more"`):

```ruby
      assert_includes wizard_output, "Claude behavior:"
      assert_includes wizard_output, "Beginner: explain more"
      assert_includes wizard_output, "Intermediate: concise explanations"
      assert_includes wizard_output, "Advanced: terse summaries"
```

Replace it with:

```ruby
      assert_includes wizard_output, "Claude experience level:"
      assert_includes wizard_output, "How should Claude collaborate with you on this box?"
      assert_includes wizard_output, "Beginner means more explanation"
      assert_includes wizard_output, "Intermediate (the default) is concise"
      assert_includes wizard_output, "Advanced is terse"
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `cd ~/projects/dev-boxer && rake test TESTOPTS='--name=test_wizard_writes_config_and_secrets'`

Expected: 1 failure — `"Claude experience level:"` is not in the output (current code emits `"Claude behavior:"`).

- [ ] **Step 3: Add `explain_claude_experience_level` to wizard.rb**

Open `lib/dev_boxer/wizard.rb`. Locate `def ask_experience_level` (the existing private method, currently right after `build_claude_config`). Immediately above `ask_experience_level`, insert:

```ruby
    def explain_claude_experience_level
      output.puts
      output.puts "Claude experience level:"
      output.puts "How should Claude collaborate with you on this box?"
      output.puts "Beginner means more explanation, and Claude asks before meaningful technical choices and summarises next steps."
      output.puts "Intermediate (the default) is concise — Claude proceeds on routine choices and asks on real tradeoffs."
      output.puts "Advanced is terse: Claude makes reasonable assumptions and focuses on diffs, tests, and blockers."
      output.puts
    end
```

- [ ] **Step 4: Replace the inline block in `build_claude_config` with a call to the new method**

Still in `lib/dev_boxer/wizard.rb`, find the existing `build_claude_config`:

```ruby
    def build_claude_config(existing)
      output.puts
      output.puts "Claude behavior:"
      output.puts "  Beginner: explain more, ask before meaningful technical choices, summarize next steps."
      output.puts "  Intermediate: concise explanations, proceed on routine choices, ask on tradeoffs."
      output.puts "  Advanced: terse summaries, proceed with reasonable assumptions, focus on diffs/tests/blockers."
      output.puts

      level = ask_experience_level(existing)
      config = { "experience_level" => level }
      plugins = existing.dig("claude", "plugins")
      config["plugins"] = plugins unless plugins.nil?
      config
    end
```

Replace it with:

```ruby
    def build_claude_config(existing)
      explain_claude_experience_level
      level = ask_experience_level(existing)
      config = { "experience_level" => level }
      plugins = existing.dig("claude", "plugins")
      config["plugins"] = plugins unless plugins.nil?
      config
    end
```

- [ ] **Step 5: Run the test and verify it passes**

Run: `cd ~/projects/dev-boxer && rake test TESTOPTS='--name=test_wizard_writes_config_and_secrets'`

Expected: 1 run, all assertions pass.

- [ ] **Step 6: Run the full suite to confirm no regressions**

Run: `cd ~/projects/dev-boxer && rake test`

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
cd ~/projects/dev-boxer
git -c user.name="Dan Barker" -c user.email="you@example.com" add lib/dev_boxer/wizard.rb test/wizard_test.rb
git -c user.name="Dan Barker" -c user.email="you@example.com" commit -m "Move Claude-behavior summary into explain_claude_experience_level

The inline labelled summary in build_claude_config becomes a proper
explain_* method written as prose, matching the rest of the wizard.
The prompt label changes from 'Claude behavior:' to 'Claude experience
level:' to match the section header more directly."
```

---

## Task 6: End-to-end manual sanity check

**Files:** none (manual verification)

- [ ] **Step 1: Render the wizard against the existing test fixtures and skim the output**

Run a one-off Ruby snippet that reproduces the test fixture's stdin and prints the wizard's full rendered output to your terminal so you can read it like a user would:

```bash
cd ~/projects/dev-boxer && ruby -e '
require_relative "lib/dev_boxer/wizard"
require_relative "lib/dev_boxer/config"
require_relative "lib/dev_boxer/credentials_blob"
require "tmpdir"
require "stringio"

Dir.mktmpdir do |dir|
  input = StringIO.new([
    "alice",
    "ssh-ed25519 AAAATEST alice@example.com",
    "2223",
    "example.com",
    "yes",
    "zone-token",
    "yes",
    "alice@example.com, example.com",
    "setup-token",
    "here",
    "alice-matrix",
    "intermediate",
  ].join("\n") + "\n")
  output = StringIO.new
  DevBoxer::Wizard.run(config_path: File.join(dir, "config.yml"), input: input, output: output)
  puts output.string
end
'
```

Read the rendered output top-to-bottom. Confirm: every prompt has a paragraph preface above it, the prose reads cleanly, no leftover `What:` / `Why:` / `How:` / `Tip:` / `Cost:` / `Link:` labels anywhere.

- [ ] **Step 2: Search the wizard source for any remaining labelled-bullet output**

Run: `cd ~/projects/dev-boxer && grep -nE "puts \"  (What|Why|How|Tip|Cost|Link|Scope|Alternative|Manual option|Login|Access|Tunnel|Cleanup): " lib/dev_boxer/wizard.rb`

Expected: no matches. (If anything matches, that's a labelled bullet I missed — rewrite it as prose in a follow-up commit before opening the PR.)

- [ ] **Step 3: Push the branch and open the PR**

Confirm with Dan that he's ready to push before running this.

```bash
cd ~/projects/dev-boxer
git push -u origin feat/wizard-prose-explanations
gh pr create --base main --head feat/wizard-prose-explanations \
  --title "Give every wizard prompt a short prose explanation" \
  --body "Closes the explanation gap in the first-run wizard: every prompt now gets a short prose paragraph above it explaining what's being asked, why, and what to do. The seven existing labelled-bullet blocks (What/Why/How/Tip/Cost/Link) are rewritten in the same prose style for consistency.

Spec: docs/superpowers/specs/2026-05-16-wizard-explanations-design.md
Plan: docs/superpowers/plans/2026-05-16-wizard-prose-explanations.md

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Out of scope (documented in the spec)

- Progress indicators ("step 2 of 5")
- Adaptive depth based on `claude.experience_level`
- Moving the prose to a separate copy file or YAML
- i18n / translation hooks
- Restructuring the wizard flow or changing prompt order
