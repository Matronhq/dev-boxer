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
        shell: DevBoxer::Shell.new(runner: ->(_cmd, _opts = {}) { [true, ""] }),
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

  private

  def build_cloudflare_module(config_path:, secrets_path:)
    DevBoxer::Modules::Cloudflare.new(
      config: DevBoxer::Config.from_hash("cloudflare" => { "api_token" => "admin-token" }),
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
      shell: DevBoxer::Shell.new(runner: ->(_cmd, _opts = {}) { [true, ""] }),
      templates_dir: File.expand_path("../templates", __dir__),
      config_path: config_path,
      secrets_path: secrets_path,
    )
  end
end
