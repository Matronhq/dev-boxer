require_relative "test_helper"
require "fileutils"
require "tmpdir"
require_relative "../lib/dev_boxer/modules/09_cloudflare"

class CloudflareModuleTest < Minitest::Test
  def test_persists_tunnel_id_to_active_config_path
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      secrets_path = File.join(dir, "secrets.yml")
      File.write(config_path, { "cloudflare" => { "enabled" => true } }.to_yaml)

      mod = build_cloudflare_module(config_path: config_path, secrets_path: secrets_path)
      mod.send(:persist_tunnel_id, "tunnel-123")

      assert_equal "tunnel-123", YAML.safe_load_file(config_path).dig("cloudflare", "tunnel", "id")
    end
  end

  def test_cleanup_setup_token_clears_config_and_secrets
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      secrets_path = File.join(dir, "secrets.yml")
      File.write(config_path, { "cloudflare" => { "api_token" => "from-config" } }.to_yaml)
      File.write(secrets_path, { "cloudflare" => { "api_token" => "from-secrets" } }.to_yaml)

      mod = build_cloudflare_module(config_path: config_path, secrets_path: secrets_path)
      mod.send(:cleanup_setup_token)

      assert_nil YAML.safe_load_file(config_path).dig("cloudflare", "api_token")
      assert_nil YAML.safe_load_file(secrets_path).dig("cloudflare", "api_token")
    end
  end

  def test_write_user_credentials_deploys_zone_token_without_zone_id
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      secrets_path = File.join(dir, "secrets.yml")
      home = File.join(dir, "home")
      FileUtils.mkdir_p(home)

      mod = DevBoxer::Modules::Cloudflare.new(
        config: DevBoxer::Config.from_hash(
          "user" => { "name" => "dev" },
          "cloudflare" => { "zone_api_token" => "zone-token" },
        ),
        log: DevBoxer::Log.new(io: StringIO.new, color: false),
        shell: DevBoxer::Shell.new(runner: ->(_cmd, _opts = {}) { [true, "", ""] }),
        templates_dir: File.expand_path("../templates", __dir__),
        config_path: config_path,
        secrets_path: secrets_path,
      )

      mod.stub(:home_dir, home) do
        mod.send(:write_user_credentials)
      end

      assert_equal "zone-token", File.read(File.join(home, ".cloudflare", "token"))
    end
  end

  def test_dns_routes_are_created_with_zone_token_for_all_tunnel_hostnames
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      secrets_path = File.join(dir, "secrets.yml")
      calls = []
      mod = build_cloudflare_module(
        config_path: config_path,
        secrets_path: secrets_path,
        config_hash: cloudflare_config(
          "zone_name" => "example.com",
          "zone_api_token" => "zone-token",
          "tunnel" => {
            "id" => "tunnel-123",
            "hostname" => "dev.example.com",
            "hostname_matrix" => "matrix.example.com",
            "hostname_viewer" => "viewer.example.com",
          },
        ),
      )

      api = lambda do |token:, method:, path:, query: {}, body: nil|
        calls << { token: token, method: method, path: path, query: query, body: body }
        return [{ "id" => "zone-123", "name" => "example.com" }] if path == "/zones"
        return [] if method == :get && path.end_with?("/dns_records")
        { "id" => "record-123" }
      end

      mod.stub(:cloudflare_api, api) do
        mod.send(:create_dns_routes)
      end

      created_names = calls
        .select { |call| call[:method] == :post && call[:path] == "/zones/zone-123/dns_records" }
        .map { |call| call[:body]["name"] }
      assert_equal ["dev.example.com", "matrix.example.com", "viewer.example.com"], created_names
      assert calls.all? { |call| call[:token] == "zone-token" }
    end
  end

  def test_manual_dns_prints_required_cname_records
    log_io = StringIO.new
    mod = DevBoxer::Modules::Cloudflare.new(
      config: DevBoxer::Config.from_hash(cloudflare_config(
        "zone_api_token" => nil,
        "dns" => { "create_manually" => true },
        "tunnel" => {
          "id" => "tunnel-123",
          "hostname" => "dev.example.com",
          "hostname_matrix" => "matrix.example.com",
          "hostname_viewer" => "viewer.example.com",
        },
      )),
      log: DevBoxer::Log.new(io: log_io, color: false),
      shell: DevBoxer::Shell.new(runner: ->(_cmd, _opts = {}) { [true, "", ""] }),
      templates_dir: File.expand_path("../templates", __dir__),
      config_path: "/tmp/config.yml",
      secrets_path: "/tmp/secrets.yml",
    )

    mod.send(:create_dns_routes)

    output = log_io.string
    assert_includes output, "Manual DNS setup required."
    assert_includes output, "Create proxied CNAME: dev.example.com -> tunnel-123.cfargotunnel.com"
    assert_includes output, "Create proxied CNAME: matrix.example.com -> tunnel-123.cfargotunnel.com"
    assert_includes output, "Create proxied CNAME: viewer.example.com -> tunnel-123.cfargotunnel.com"
  end

  def test_cloudflare_access_excludes_matrix_hostname
    mod = build_cloudflare_module(
      config_path: "/tmp/config.yml",
      secrets_path: "/tmp/secrets.yml",
      config_hash: cloudflare_config(
        "tunnel" => {
          "hostname" => "dev.example.com",
          "hostname_matrix" => "matrix.example.com",
          "hostname_viewer" => "viewer.example.com",
        },
      ),
    )

    assert_equal ["dev.example.com", "viewer.example.com"], mod.send(:access_hostnames)
  end

  def test_cloudflare_access_payload_allows_email_and_domain
    mod = build_cloudflare_module(
      config_path: "/tmp/config.yml",
      secrets_path: "/tmp/secrets.yml",
      config_hash: cloudflare_config(
        "access" => {
          "enabled" => true,
          "account_id" => "account-123",
          "allowed_emails" => ["alice@example.com"],
          "allowed_email_domains" => ["example.com"],
        },
      ),
    )

    payload = mod.send(:cloudflare_access_app_payload, ["dev.example.com", "viewer.example.com"])

    assert_equal "self_hosted", payload["type"]
    assert_equal ["dev.example.com", "viewer.example.com"], payload["destinations"].map { |dest| dest["uri"] }
    assert_equal [
      { "email" => { "email" => "alice@example.com" } },
      { "email_domain" => { "domain" => "example.com" } },
    ], payload.dig("policies", 0, "include")
  end

  def test_configure_access_uses_top_level_setup_token
    Dir.mktmpdir do |dir|
      config_path = File.join(dir, "config.yml")
      secrets_path = File.join(dir, "secrets.yml")
      File.write(config_path, { "cloudflare" => { "enabled" => true } }.to_yaml)
      calls = []
      mod = build_cloudflare_module(
        config_path: config_path,
        secrets_path: secrets_path,
        config_hash: cloudflare_config(
          "api_token" => "setup-token",
          "access" => {
            "enabled" => true,
            "allowed_email_domains" => ["example.com"],
          },
        ),
      )

      api = lambda do |token:, method:, path:, query: {}, body: nil|
        calls << { token: token, method: method, path: path, query: query, body: body }
        return [{ "id" => "zone-123", "name" => "example.com", "account" => { "id" => "account-123" } }] if path == "/zones"
        { "id" => "access-app-123" }
      end

      mod.stub(:cloudflare_api, api) do
        mod.send(:configure_cloudflare_access)
      end

      access_call = calls.find { |call| call[:path] == "/accounts/account-123/access/apps" }
      assert_equal "setup-token", access_call[:token]
      assert_equal "access-app-123", YAML.safe_load_file(config_path).dig("cloudflare", "access", "app_id")
    end
  end

  private

  def build_cloudflare_module(config_path:, secrets_path:, config_hash: { "cloudflare" => { "api_token" => "admin-token" } })
    DevBoxer::Modules::Cloudflare.new(
      config: DevBoxer::Config.from_hash(config_hash),
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
      shell: DevBoxer::Shell.new(runner: ->(_cmd, _opts = {}) { [true, "", ""] }),
      templates_dir: File.expand_path("../templates", __dir__),
      config_path: config_path,
      secrets_path: secrets_path,
    )
  end

  def cloudflare_config(overrides = {})
    DevBoxer::Config.deep_merge({
      "user" => { "name" => "dev" },
      "cloudflare" => {
        "zone_name" => "example.com",
        "zone_api_token" => "zone-token",
        "api_token" => "admin-token",
        "tunnel" => {
          "id" => "tunnel-123",
          "hostname" => "dev.example.com",
          "hostname_matrix" => "matrix.example.com",
          "hostname_viewer" => "viewer.example.com",
        },
      },
    }, { "cloudflare" => overrides })
  end
end
