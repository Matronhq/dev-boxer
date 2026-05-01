require_relative "test_helper"
require "tmpdir"
require_relative "../lib/dev_boxer/modules/08_matrix_bridge"

class MatrixBridgeTest < Minitest::Test
  def test_patch_bridge_setup_user_uses_crypto_api_recovery_key_helper
    Dir.mktmpdir do |dir|
      bridge_dir = File.join(dir, "bridge")
      FileUtils.mkdir_p(bridge_dir)
      setup_path = File.join(bridge_dir, "setup-user.mjs")
      File.write(setup_path, "const keyInfo = await client.createRecoveryKeyFromPassphrase();\n")
      mod = build_module(secrets_path: File.join(dir, "secrets.yml"))

      mod.stub(:bridge_dir, bridge_dir) do
        mod.send(:patch_bridge_setup_user)
      end

      assert_includes File.read(setup_path), "cryptoApi.createRecoveryKeyFromPassphrase()"
      refute_includes File.read(setup_path), "client.createRecoveryKeyFromPassphrase()"
    end
  end

  def test_partial_onboarding_passwords_are_persisted
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      mod = build_module(secrets_path: secrets_path)

      mod.send(:persist_partial_onboarding_passwords, "bot-pass", "user-pass")

      secrets = YAML.safe_load_file(secrets_path)
      assert_equal "bot-pass", secrets.dig("matrix", "bot_password")
      assert_equal "user-pass", secrets.dig("matrix", "user_password")
      assert_equal "dev", secrets.dig("matrix", "user_username")
      assert_equal "matrix.example.com", secrets.dig("matrix", "server_domain")
    end
  end

  private

  def build_module(secrets_path:)
    DevBoxer::Modules::MatrixBridge.new(
      config: DevBoxer::Config.from_hash(
        "user" => { "name" => "dev" },
        "matrix" => {
          "mode" => "bundled",
          "server_domain" => "matrix.example.com",
          "user_username" => "dev",
        },
      ),
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
      shell: DevBoxer::Shell.new(runner: ->(_cmd, _opts = {}) { [true, "", ""] }),
      templates_dir: File.expand_path("../templates", __dir__),
      secrets_path: secrets_path,
    )
  end
end
