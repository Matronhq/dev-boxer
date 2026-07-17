require_relative "test_helper"
require "fileutils"
require "tmpdir"

class ConfigTest < Minitest::Test
  # Use an isolated tmpdir per call so Config.load's sibling-secrets.yml
  # lookup never picks up a stray /tmp/secrets.yml from another test or
  # the host environment.
  def write_config(yaml)
    @scratch_dirs ||= []
    dir = Dir.mktmpdir
    @scratch_dirs << dir
    path = File.join(dir, "config.yml")
    File.write(path, yaml)
    path
  end

  def teardown
    @scratch_dirs&.each { |d| FileUtils.rm_rf(d) }
  end

  def test_loads_top_level_keys
    path = write_config(<<~YAML)
      user:
        name: dan
      ssh:
        port: 2222
    YAML
    config = DevBoxer::Config.load(path)
    assert_equal "dan", config.user.name
    assert_equal 2222, config.ssh.port
  end

  def test_nested_access_returns_nil_for_missing_keys
    path = write_config("user:\n  name: dan\n")
    config = DevBoxer::Config.load(path)
    assert_nil config.user.email
  end

  def test_dig_for_deep_paths
    path = write_config(<<~YAML)
      cloudflare:
        tunnel:
          hostname: dev.example.com
    YAML
    config = DevBoxer::Config.load(path)
    assert_equal "dev.example.com", config.cloudflare.tunnel.hostname
  end

  def test_raises_when_file_missing
    assert_raises(DevBoxer::Config::NotFound) do
      DevBoxer::Config.load("/no/such/path.yml")
    end
  end

  def test_to_h_returns_hash
    path = write_config("user:\n  name: dan\n")
    config = DevBoxer::Config.load(path)
    assert_equal({ "user" => { "name" => "dan" } }, config.to_h)
  end

  def test_deep_merge_recurses_into_hashes
    a = { "a" => { "x" => 1, "y" => 2 } }
    b = { "a" => { "y" => 99, "z" => 3 } }
    assert_equal({ "a" => { "x" => 1, "y" => 99, "z" => 3 } }, DevBoxer::Config.deep_merge(a, b))
  end

  def test_merge_into_file_creates_file_when_missing
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      DevBoxer::Config.merge_into_file(path, { "matrix" => { "token" => "abc" } })
      assert File.exist?(path)
      reloaded = YAML.safe_load_file(path)
      assert_equal({ "matrix" => { "token" => "abc" } }, reloaded)
    end
  end

  def test_merge_into_file_preserves_other_top_level_sections
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, "user:\n  name: dan\nmatrix:\n  mode: bundled\n")
      DevBoxer::Config.merge_into_file(path, { "matrix" => { "token" => "abc" } })
      reloaded = YAML.safe_load_file(path)
      assert_equal "dan", reloaded.dig("user", "name")
      assert_equal "bundled", reloaded.dig("matrix", "mode")
      assert_equal "abc", reloaded.dig("matrix", "token")
    end
  end

  def test_merge_into_file_does_not_create_duplicate_top_level_key
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, "matrix:\n  mode: bundled\n")
      DevBoxer::Config.merge_into_file(path, { "matrix" => { "token" => "abc" } })
      raw = File.read(path)
      assert_equal 1, raw.scan(/^matrix:/m).length, "expected one matrix: key, found:\n#{raw}"
    end
  end

  def test_loads_sibling_secrets_yml_and_merges
    Dir.mktmpdir do |dir|
      File.write("#{dir}/config.yml",  "user:\n  name: dan\nmatrix:\n  mode: bundled\n")
      File.write("#{dir}/secrets.yml", "matrix:\n  bot_access_token: secret123\n")
      config = DevBoxer::Config.load("#{dir}/config.yml")
      assert_equal "dan",       config.user.name
      assert_equal "bundled",   config.matrix.mode
      assert_equal "secret123", config.matrix.bot_access_token
    end
  end

  def test_secrets_yml_overrides_config_yml_on_conflict
    Dir.mktmpdir do |dir|
      File.write("#{dir}/config.yml",  "matrix:\n  bot_access_token: from_config\n")
      File.write("#{dir}/secrets.yml", "matrix:\n  bot_access_token: from_secrets\n")
      config = DevBoxer::Config.load("#{dir}/config.yml")
      assert_equal "from_secrets", config.matrix.bot_access_token
    end
  end

  def test_missing_secrets_yml_is_fine
    Dir.mktmpdir do |dir|
      File.write("#{dir}/config.yml", "user:\n  name: dan\n")
      config = DevBoxer::Config.load("#{dir}/config.yml")
      assert_equal "dan", config.user.name
    end
  end

  def test_secrets_path_for_returns_sibling
    assert_equal "/foo/secrets.yml", DevBoxer::Config.secrets_path_for("/foo/config.yml")
    assert_equal "/foo/secrets.yml", DevBoxer::Config.secrets_path_for("/foo/anything.yml")
  end

  def test_does_not_claim_to_respond_to_coercion_methods
    config = DevBoxer::Config.from_hash("user" => { "name" => "dan" })
    refute config.respond_to?(:to_ary), "to_ary trips Array()/splat"
    refute config.respond_to?(:to_str), "to_str trips string concat"
    refute config.respond_to?(:to_hash), "to_hash trips ** splat"
    refute config.respond_to?(:to_int), "to_int trips Integer()"
    refute config.respond_to?(:to_proc), "to_proc trips & in method calls"
  end

  def test_array_wrap_does_not_raise
    config = DevBoxer::Config.from_hash({})
    assert_equal [config], Array(config)
  end

  def test_responds_to_actual_keys
    config = DevBoxer::Config.from_hash("matrix" => {})
    assert config.respond_to?(:matrix)
  end

  def test_coercion_method_with_matching_key_still_works
    config = DevBoxer::Config.from_hash("to_ary" => "weird-but-legal")
    assert_equal "weird-but-legal", config.to_ary
  end

  def test_validation_accepts_tunnel_id_without_setup_token
    config = DevBoxer::Config.from_hash(valid_public_config("exposure" => {
      "cloudflare" => {
        "api_token" => nil,
        "tunnel" => { "id" => "existing-tunnel-id" },
      },
    }))

    assert_empty DevBoxer::Config.validation_errors(config)
  end

  def test_validation_requires_setup_token_until_tunnel_exists_unless_manual
    hash = valid_public_config
    hash["exposure"]["cloudflare"].delete("api_token")
    hash["exposure"]["cloudflare"]["tunnel"].delete("id")

    errors = DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))

    assert_includes errors, "exposure.cloudflare.api_token is required until exposure.cloudflare.tunnel.id exists, unless exposure.cloudflare.tunnel.create_manually is true"
  end

  def test_validation_allows_manual_tunnel_setup_without_setup_token
    hash = valid_public_config
    hash["exposure"]["cloudflare"].delete("api_token")
    hash["exposure"]["cloudflare"]["tunnel"].delete("id")
    hash["exposure"]["cloudflare"]["tunnel"]["create_manually"] = true

    assert_empty DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))
  end

  def test_validation_rejects_unsafe_linux_username
    hash = valid_public_config
    hash["user"]["name"] = "dev;reboot"

    errors = DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))

    assert_includes errors, "user.name must be a shell-safe Linux username"
  end

  def test_validation_requires_zone_name_for_dns_setup
    hash = valid_public_config
    hash["exposure"]["cloudflare"].delete("zone_name")

    errors = DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))

    assert_includes errors, "exposure.cloudflare.zone_name is required"
  end

  def test_validation_requires_zone_token_unless_dns_is_manual
    hash = valid_public_config
    hash["exposure"]["cloudflare"].delete("zone_api_token")

    errors = DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))

    assert_includes errors, "exposure.cloudflare.zone_api_token is required unless exposure.cloudflare.dns.create_manually is true"
  end

  def test_validation_requires_access_setup_token_until_app_exists
    hash = valid_public_config("exposure" => {
      "cloudflare" => {
        "access" => {
          "enabled" => true,
          "allowed_email_domains" => ["example.com"],
        },
      },
    })
    hash["exposure"]["cloudflare"].delete("api_token")

    errors = DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))

    assert_includes errors, "exposure.cloudflare.api_token is required until exposure.cloudflare.access.app_id exists"
  end

  def test_validation_allows_access_app_without_token_after_setup
    hash = valid_public_config("exposure" => {
      "cloudflare" => {
        "access" => {
          "enabled" => true,
          "app_id" => "app-123",
          "allowed_email_domains" => ["example.com"],
        },
      },
    })

    assert_empty DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))
  end

  def test_validation_allows_manual_dns_without_zone_token
    hash = valid_public_config("exposure" => {
      "cloudflare" => {
        "zone_api_token" => nil,
        "dns" => { "create_manually" => true },
      },
    })

    assert_empty DevBoxer::Config.validation_errors(DevBoxer::Config.from_hash(hash))
  end

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

  private

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
end
