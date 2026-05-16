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

  def test_matrix_registration_helper_returns_memoised_service_with_module_dependencies
    Dir.mktmpdir do |dir|
      mod = build_module(secrets_path: File.join(dir, "secrets.yml"))

      reg = mod.send(:matrix_registration)
      assert_kind_of DevBoxer::MatrixRegistration, reg
      assert_same reg, mod.send(:matrix_registration), "matrix_registration should be memoised"
    end
  end

  def test_bridge_env_vars_in_external_mode_include_imported_creds
    Dir.mktmpdir do |dir|
      config = DevBoxer::Config.from_hash(
        "user" => { "name" => "dev" },
        "matrix" => {
          "mode" => "external",
          "homeserver_url" => "https://matrix.example.com",
          "server_domain" => "matrix.example.com",
          "user_username" => "dev",
          "bot_username" => "box4",
          "bot_user_id" => "@box4:matrix.example.com",
          "bot_password" => "pw",
          "bot_recovery_key" => "EsTm 4uK4",
          "bridge_room_id" => "!abc:matrix.example.com",
        },
      )
      mod = DevBoxer::Modules::MatrixBridge.new(
        config: config,
        log: DevBoxer::Log.new(io: StringIO.new, color: false),
        shell: DevBoxer::Shell.new(runner: ->(_cmd, _opts = {}) { [true, "", ""] }),
        templates_dir: File.expand_path("../templates", __dir__),
        secrets_path: File.join(dir, "secrets.yml"),
      )

      vars = mod.send(:bridge_env_vars)

      assert_equal "@box4:matrix.example.com", vars["MATRIX_BOT_USER_ID"]
      assert_equal "pw", vars["MATRIX_BOT_PASSWORD"]
      assert_equal "EsTm 4uK4", vars["MATRIX_BOT_RECOVERY_KEY"]
      assert_equal "!abc:matrix.example.com", vars["MATRIX_BRIDGE_ROOM_ID"]
    end
  end

  def test_bridge_env_vars_in_bundled_mode_does_not_include_password_or_recovery
    Dir.mktmpdir do |dir|
      mod = build_module(secrets_path: File.join(dir, "secrets.yml"))
      vars = mod.send(:bridge_env_vars)
      assert_nil vars["MATRIX_BOT_PASSWORD"]
      assert_nil vars["MATRIX_BOT_RECOVERY_KEY"]
    end
  end

  def test_matrix_credentials_path_uses_available_temp_location
    Dir.mktmpdir do |dir|
      mod = build_module(secrets_path: File.join(dir, "secrets.yml"))
      path = mod.send(:matrix_credentials_path)

      assert_match(/dev-boxer-matrix-/, File.basename(path))
      assert_equal Dir.exist?("/dev/shm") ? "/dev/shm" : Dir.tmpdir, File.dirname(path)
    end
  end

  def test_bridge_room_name_uses_bot_specific_label
    Dir.mktmpdir do |dir|
      mod = build_module(
        secrets_path: File.join(dir, "secrets.yml"),
        matrix: { "bot_username" => "claude-bot-dev-4" },
      )

      assert_equal "dev-4: Claude Code Bridge", mod.send(:bridge_room_name)
    end
  end

  def test_bootstrap_external_crosssigning_restarts_bridge_even_when_node_step_fails
    Dir.mktmpdir do |dir|
      mod = build_module(
        secrets_path: File.join(dir, "secrets.yml"),
        matrix: { "bot_password" => "pw", "bot_recovery_key" => "EsTm 4uK4" },
      )
      systemctl_calls = []
      mod.shell.define_singleton_method(:systemctl) do |action, name|
        systemctl_calls << [action, name]
        true
      end
      mod.shell.define_singleton_method(:sh) { |_cmd| false }
      mod.shell.define_singleton_method(:run_as_user) do |_user, cmd|
        raise "node bootstrap-crosssigning failed" if cmd.include?("bootstrap-crosssigning.mjs")
        true
      end

      assert_raises(RuntimeError) do
        mod.stub(:sleep, nil) do
          mod.send(:bootstrap_external_crosssigning)
        end
      end

      assert_includes systemctl_calls, [:stop, "claude-matrix-bridge"]
      assert_includes systemctl_calls, [:restart, "claude-matrix-bridge"],
                      "bridge must be restarted even if cross-signing bootstrap fails"
    end
  end

  private

  def build_module(secrets_path:, matrix: {})
    DevBoxer::Modules::MatrixBridge.new(
      config: DevBoxer::Config.from_hash(
        "user" => { "name" => "dev" },
        "matrix" => {
          "mode" => "bundled",
          "server_domain" => "matrix.example.com",
          "user_username" => "dev",
        }.merge(matrix),
      ),
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
      shell: DevBoxer::Shell.new(runner: ->(_cmd, _opts = {}) { [true, "", ""] }),
      templates_dir: File.expand_path("../templates", __dir__),
      secrets_path: secrets_path,
    )
  end
end
