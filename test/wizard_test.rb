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

  def test_invalid_journal_mode_does_not_trigger_hostname_journal_error
    # Regression: when journal.mode is invalid ("banana"), we should get the
    # journal mode error, but NOT the hostname_journal error. The hostname_journal
    # requirement should only apply when journal.mode is exactly "bundled".
    hash = complete_config.dup
    hash["journal"]["mode"] = "banana"
    hash["exposure"]["cloudflare"]["tunnel"].delete("hostname_journal")

    errors = DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))

    assert_includes errors, "journal.mode must be bundled or external"
    refute_includes errors, "exposure.cloudflare.tunnel.hostname_journal is required when the journal is bundled"
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

  def complete_config
    {
      "user" => {
        "name" => "alice",
        "ssh_public_key" => "ssh-ed25519 AAAATEST alice@example.com",
        "rdp_password" => "rdp-secret",
      },
      "ssh" => { "port" => 2223 },
      "journal" => { "mode" => "bundled", "username" => "alice" },
      "exposure" => {
        "mode" => "cloudflare",
        "cloudflare" => {
          "zone_name" => "example.com",
          "api_token" => "setup-token",
          "zone_api_token" => "zone-token",
          "tunnel" => {
            "hostname" => "dev.example.com",
            "hostname_journal" => "chat.example.com",
            "hostname_viewer" => "viewer.example.com",
            "hostname_hello" => "hello.example.com",
            "create_manually" => false,
          },
          "dns" => { "create_manually" => false },
          "access" => {
            "enabled" => true,
            "app_name" => "Dev Boxer",
            "bypass_app_name" => "Dev Boxer Public",
            "session_duration" => "24h",
            "allowed_emails" => ["alice@example.com"],
          },
        },
      },
      "hello_world" => { "port" => 9820 },
      "claude" => { "experience_level" => "intermediate" },
    }
  end

  def leaf_paths(hash, prefix = [])
    hash.flat_map do |key, value|
      value.is_a?(Hash) ? leaf_paths(value, prefix + [key]) : [(prefix + [key]).join(".")]
    end
  end
end
