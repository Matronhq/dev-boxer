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
        "example.com",
        "yes",
        "zone-token",
        "yes",
        "alice@example.com, example.com",
        "setup-token",
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
      assert_includes wizard_output, "== 2. Domain and DNS =="
      assert_includes wizard_output, "== 3. Cloudflare tunnel and Access =="
      assert_includes wizard_output, "== 4. Matrix user =="
      assert_includes wizard_output, "== 5. Claude behavior =="
      assert_includes wizard_output, "Claude behavior:"
      assert_includes wizard_output, "Beginner: explain more"
      assert_includes wizard_output, "Intermediate: concise explanations"
      assert_includes wizard_output, "Advanced: terse summaries"
      assert_includes wizard_output, "hello.<domain>"
      assert_includes wizard_output, "can create new subdomains for projects you make"
      assert_includes wizard_output, "Tip: We recommend giving the box its own domain."
      assert_includes wizard_output, "Cost: Low-cost domains such as .uk or .us often start around $5-6/year"
      assert_includes wizard_output, "Cloudflare zone DNS API token:"
      assert_includes wizard_output, "What: A zone-scoped Cloudflare API token for example.com."
      assert_includes wizard_output, "new subdomains for projects you make"
      assert_includes wizard_output, "How: Create a custom token at https://dash.cloudflare.com/profile/api-tokens"
      assert_includes wizard_output, "Scope: Limit the token to the example.com zone only. Do not grant access to all zones."
      assert_includes wizard_output, "Alternative: Choose no below if you prefer to create each required subdomain manually."
      assert_includes wizard_output, "Let Dev Boxer manage DNS records for this domain?"
      assert_includes wizard_output, "Let Dev Boxer create the Cloudflare tunnel and Zero Trust Access app now?"
      assert_includes wizard_output, "Cloudflare One Connector: cloudflared: Edit"
      assert_includes wizard_output, "Access: Apps: Edit"
      assert_includes wizard_output, "Access: Policies: Edit"
      assert_includes wizard_output, "One-time Cloudflare account setup token:"
      assert_includes wizard_output, "Cleanup: Dev Boxer deletes this token from secrets.yml after setup succeeds."

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
        "example.com",
        "no",
        "no",
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
      assert_includes output.string, "Manual DNS selected."
      assert_includes output.string, "Dev Boxer will not store a DNS API token."
      assert_includes output.string, "hello.example.com"
      assert_includes output.string, "create any future project subdomains yourself"
      assert_includes output.string, "Cloudflare Access will be manual because DNS is manual."
      assert_includes output.string, "Let Dev Boxer create the Cloudflare tunnel now?"
      assert_includes output.string, "Manual Cloudflare setup selected."
      assert_includes output.string, "Dev Boxer will install cloudflared"
      assert_includes output.string, "Dev Boxer will not create a Zero Trust Access app."
      assert_empty DevBoxer::Config.validation_errors(DevBoxer::Config.load(config_path))
    end
  end

  private

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
