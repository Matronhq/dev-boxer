require_relative "test_helper"
require "tmpdir"

class WizardTest < Minitest::Test
  def test_wizard_writes_config_and_secrets
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      secrets_path = DevBoxer::Config.secrets_path_for(config_path)
      input = StringIO.new([
        "alice",
        "ssh-ed25519 AAAATEST alice@example.com",
        "2223",
        "ghp_test_pat",
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
      result = DevBoxer::Wizard.run(config_path: config_path, input: input, output: output)

      assert_equal :created, result
      config = YAML.safe_load_file(config_path)
      secrets = YAML.safe_load_file(secrets_path)
      wizard_output = output.string

      assert_equal "alice", config.dig("user", "name")
      assert_equal "ssh-ed25519 AAAATEST alice@example.com", config.dig("user", "ssh_public_key")
      assert_equal 2223, config.dig("ssh", "port")
      assert_equal false, config.dig("desktop", "enabled")
      assert_equal "matrix.example.com", config.dig("matrix", "server_domain")
      assert_equal "alice-matrix", config.dig("matrix", "user_username")
      assert_equal "intermediate", config.dig("claude", "experience_level")
      assert_equal true, config.dig("cloudflare", "enabled")
      assert_equal "example.com", config.dig("cloudflare", "zone_name")
      assert_nil config.dig("cloudflare", "account_id")
      assert_nil config.dig("cloudflare", "zone_id")
      assert_equal "dev.example.com", config.dig("cloudflare", "tunnel", "hostname")
      assert_equal "matrix.example.com", config.dig("cloudflare", "tunnel", "hostname_matrix")
      assert_equal "viewer.example.com", config.dig("cloudflare", "tunnel", "hostname_viewer")
      assert_equal "hello.example.com", config.dig("cloudflare", "tunnel", "hostname_hello")
      assert_equal false, config.dig("cloudflare", "dns", "create_manually")
      assert_equal false, config.dig("cloudflare", "tunnel", "create_manually")
      assert_equal true, config.dig("cloudflare", "access", "enabled")
      assert_nil config.dig("cloudflare", "access", "account_id")
      assert_equal ["alice@example.com"], config.dig("cloudflare", "access", "allowed_emails")
      assert_equal ["example.com"], config.dig("cloudflare", "access", "allowed_email_domains")

      assert_nil config.dig("cloudflare", "api_token")
      assert_nil config.dig("cloudflare", "zone_api_token")
      assert_equal "setup-token", secrets.dig("cloudflare", "api_token")
      assert_equal "zone-token", secrets.dig("cloudflare", "zone_api_token")
      assert_nil secrets.dig("cloudflare", "access", "api_token")
      assert secrets.dig("user", "rdp_password")
      assert_equal 0o600, File.stat(secrets_path).mode & 0o777
      assert_includes wizard_output, "DEV BOXER"
      assert_includes wizard_output, "Remote Claude Code dev box setup"
      assert_includes wizard_output, "== 1. Server login =="
      assert_includes wizard_output, "Linux username:"
      assert_includes wizard_output, "The Linux account you'll ssh into"
      assert_includes wizard_output, "SSH public key:"
      assert_includes wizard_output, "Paste the public half of your SSH key"
      assert_includes wizard_output, "SSH port:"
      assert_includes wizard_output, "non-standard port to cut down on the noise"
      assert_includes wizard_output, "== 2. GitHub access =="
      assert_includes wizard_output, "GitHub personal access token (optional):"
      assert_includes wizard_output, "https://github.com/settings/personal-access-tokens/new"
      assert_equal "ghp_test_pat", secrets.dig("github", "token")
      assert_includes wizard_output, "== 3. Domain and DNS =="
      assert_includes wizard_output, "== 4. Cloudflare tunnel and Access =="
      assert_includes wizard_output, "== 5. Matrix =="
      assert_includes wizard_output, "Matrix homeserver location:"
      assert_includes wizard_output, "Choose `here` for the standard setup"
      assert_includes wizard_output, "Matrix username:"
      assert_includes wizard_output, "local part of your Matrix user"
      assert_includes wizard_output, "== 6. Claude behavior =="
      assert_includes wizard_output, "Claude experience level:"
      assert_includes wizard_output, "How should Claude collaborate with you on this box?"
      assert_includes wizard_output, "Beginner means more explanation"
      assert_includes wizard_output, "Intermediate (the default) is concise"
      assert_includes wizard_output, "Advanced is terse"
      assert_includes wizard_output, "Base domain:"
      assert_includes wizard_output, "Pick the Cloudflare-managed domain Dev Boxer should use"
      assert_includes wizard_output, "create dev, matrix, viewer, and hello subdomains"
      assert_includes wizard_output, "we recommend giving the box its own domain"
      assert_includes wizard_output, ".uk and .us names start around $5"
      assert_includes wizard_output, "zone-scoped API token for example.com"
      assert_includes wizard_output, "any project subdomains you make later"
      assert_includes wizard_output, "https://dash.cloudflare.com/?to=/:account/api-tokens"
      assert_includes wizard_output, "to this zone only — never all zones"
      assert_includes wizard_output, "Let Dev Boxer manage DNS records for this domain?"
      assert_includes wizard_output, "Let Dev Boxer create the Cloudflare tunnel and Zero Trust Access app now?"
      assert_includes wizard_output, "Cloudflare One Connector: cloudflared: Edit"
      assert_includes wizard_output, "Access: Apps: Edit"
      assert_includes wizard_output, "Access: Policies: Edit"
      assert_includes wizard_output, "One-time Cloudflare account setup token:"
      assert_includes wizard_output, "Cloudflare automation:"
      assert_includes wizard_output, "Dev Boxer can create the Cloudflare Tunnel"
      assert_includes wizard_output, "Matrix stays outside Access"
      assert_includes wizard_output, "one-time account-level Cloudflare API token used only to create the tunnel"
      assert_includes wizard_output, "wipes it from secrets.yml"

      assert_empty DevBoxer::Config.validation_errors(DevBoxer::Config.load(config_path))
    end
  end

  def test_wizard_reuses_complete_existing_config
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      secrets_path = DevBoxer::Config.secrets_path_for(config_path)
      File.write(config_path, complete_config("cloudflare" => { "tunnel" => { "id" => "abc" } }).to_yaml)
      File.write(secrets_path, {
        "user" => { "rdp_password" => "rdp-secret" },
        "cloudflare" => { "zone_api_token" => "zone-token" },
      }.to_yaml)

      result = DevBoxer::Wizard.run(
        config_path: config_path,
        input: StringIO.new("yes\n"),
        output: StringIO.new,
      )

      assert_equal :reused, result
    end
  end

  def test_wizard_can_choose_manual_tunnel_setup
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      secrets_path = DevBoxer::Config.secrets_path_for(config_path)
      input = StringIO.new([
        "alice",
        "ssh-ed25519 AAAATEST alice@example.com",
        "2223",
        "",                                         # GitHub PAT (optional, blank)
        "example.com",
        "no",
        "no",
        "here",
        "alice-matrix",
        "advanced",
      ].join("\n") + "\n")

      output = StringIO.new
      DevBoxer::Wizard.run(config_path: config_path, input: input, output: output)

      config = YAML.safe_load_file(config_path)
      secrets = YAML.safe_load_file(secrets_path)

      assert_equal true, config.dig("cloudflare", "tunnel", "create_manually")
      assert_equal true, config.dig("cloudflare", "dns", "create_manually")
      assert_equal false, config.dig("cloudflare", "access", "enabled")
      assert_equal false, config.dig("desktop", "enabled")
      assert_equal "advanced", config.dig("claude", "experience_level")
      assert_nil secrets.dig("cloudflare", "api_token")
      assert_nil secrets.dig("cloudflare", "zone_api_token")
      assert_includes output.string, "Manual DNS selected:"
      assert_includes output.string, "Dev Boxer won't store an API token."
      assert_includes output.string, "hello.example.com"
      assert_includes output.string, "Any future project subdomains will also be your responsibility to create."
      assert_includes output.string, "Cloudflare Access will be manual too:"
      assert_includes output.string, "Let Dev Boxer create the Cloudflare tunnel now?"
      assert_includes output.string, "Manual Cloudflare setup selected:"
      assert_includes output.string, "Dev Boxer will install cloudflared"
      assert_includes output.string, "It won't create the Access app either"
      assert_empty DevBoxer::Config.validation_errors(DevBoxer::Config.load(config_path))
    end
  end

  def test_wizard_there_branch_decodes_blob_and_writes_creds_to_secrets
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      secrets_path = DevBoxer::Config.secrets_path_for(config_path)

      blob_hash = {
        "homeserver_url"   => "https://matrix.example.com",
        "server_domain"    => "matrix.example.com",
        "bot_user_id"      => "@box4:matrix.example.com",
        "bot_password"     => "pw",
        "bot_recovery_key" => "EsTm 4uK4",
        "bridge_room_id"   => "!abc:matrix.example.com",
      }
      blob = DevBoxer::CredentialsBlob.encode(blob_hash)

      # Operator's Matrix username on the external homeserver is intentionally
      # different from their Linux username here ("juser" vs "alice"), to
      # cover the regression where the wizard silently used the Linux name
      # for ALLOWED_USER_IDS and the bridge dropped every message.
      input = StringIO.new(answers_for_there_branch(blob: blob, matrix_username: "juser"))
      output = StringIO.new
      DevBoxer::Wizard.run(config_path: config_path, input: input, output: output)

      config = YAML.safe_load_file(config_path)
      secrets = YAML.safe_load_file(secrets_path)

      assert_equal "external", config.dig("matrix", "mode")
      assert_equal "https://matrix.example.com", config.dig("matrix", "homeserver_url")
      assert_equal "matrix.example.com", config.dig("matrix", "server_domain")
      assert_equal "box4", config.dig("matrix", "bot_username")
      assert_equal "juser", config.dig("matrix", "user_username")
      assert_includes output.string, "Your Matrix username:"
      assert_includes output.string, "your MATRIX username, not your Linux username"

      assert_equal "@box4:matrix.example.com", secrets.dig("matrix", "bot_user_id")
      assert_equal "pw", secrets.dig("matrix", "bot_password")
      assert_equal "EsTm 4uK4", secrets.dig("matrix", "bot_recovery_key")
      assert_equal "!abc:matrix.example.com", secrets.dig("matrix", "bridge_room_id")
      assert_includes output.string, "Paste the blob from running `dev-boxer add-bot"
    end
  end

  def test_wizard_there_branch_re_prompts_on_malformed_blob
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
      input = StringIO.new(answers_for_there_branch(blob: "garbage", trailing_blob_retries: [valid_blob]))
      output = StringIO.new
      DevBoxer::Wizard.run(config_path: config_path, input: input, output: output)

      assert_match(/blob/i, output.string, "expected output to mention 'blob' in the re-prompt error")
      assert File.exist?(File.join(dir, "secrets.yml"))
    end
  end

  private

  # Answers feeding the wizard's STDIN for the "there" matrix branch.
  # Matches the prompt order in `lib/dev_boxer/wizard.rb#build_config`.
  # If a new prompt is added later, update this fixture too.
  def answers_for_there_branch(blob:, trailing_blob_retries: [], matrix_username: "alice")
    ([
      "alice",                                    # 1. Linux username
      "ssh-ed25519 AAAATEST alice@example.com",   # 2. SSH public key
      "2223",                                     # 3. SSH port
      "",                                         # 4. GitHub PAT (optional, blank)
      "example.com",                              # 5. Base domain
      "yes",                                      # 6. Let Dev Boxer manage DNS
      "zone-token",                               # 7. Zone DNS API token
      "yes",                                      # 8. Let Dev Boxer create tunnel + Access
      "alice@example.com, example.com",           # 9. Allowed emails for Access
      "setup-token",                              # 10. One-time CF setup token
      "there",                                    # 11. Matrix homeserver location
      blob,                                       # 12. Add-bot blob (first attempt)
    ] + trailing_blob_retries + [
      matrix_username,                            # 13. Your Matrix username on the external homeserver
      "intermediate",                             # 14. Claude experience level
    ]).join("\n") + "\n"
  end

  def complete_config(overrides = {})
    DevBoxer::Config.deep_merge({
      "user" => {
        "name" => "dev",
        "ssh_public_key" => "ssh-ed25519 AAAATEST dev@example.com",
      },
      "ssh" => { "port" => 2222 },
      "matrix" => {
        "mode" => "bundled",
        "server_domain" => "matrix.example.com",
        "user_username" => "dev",
      },
      "cloudflare" => {
        "enabled" => true,
        "zone_name" => "example.com",
        "tunnel" => {
          "hostname" => "dev.example.com",
          "hostname_matrix" => "matrix.example.com",
          "hostname_viewer" => "viewer.example.com",
          "hostname_hello" => "hello.example.com",
          "create_manually" => false,
        },
      },
      "hello_world" => { "port" => 9810 },
    }, overrides)
  end
end
