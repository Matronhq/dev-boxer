require_relative "test_helper"
require "tmpdir"
require_relative "support/module_test_case"
require_relative "../lib/dev_boxer/modules/08_matron"

class MatronModuleTest < DevBoxer::Testing::ModuleTestCase
  def base_config(overrides = {})
    DevBoxer::Config.deep_merge({
      "user" => { "name" => "dev" },
      "journal" => { "mode" => "bundled", "username" => "dev" },
      "exposure" => { "mode" => "ip", "ip" => { "address" => "203.0.113.7" } },
      "hello_world" => { "port" => 9820 },
    }, overrides)
  end

  def build_matron(config_hash = {}, secrets_path: nil)
    DevBoxer::Modules::Matron.new(
      config: DevBoxer::Config.from_hash(base_config(config_hash)),
      log: @log,
      shell: @shell,
      templates_dir: TEMPLATES_DIR,
      secrets_path: secrets_path,
    )
  end

  def test_bridge_env_vars_bundled_uses_loopback_ws_and_viewer_from_exposure
    Dir.mktmpdir do |dir|
      mod = build_matron({}, secrets_path: File.join(dir, "secrets.yml"))

      vars = mod.send(:bridge_env_vars, "/etc/matron/agent-token")

      assert_equal "ws://127.0.0.1:9810/ws", vars["JOURNAL_WS_URL"]
      assert_equal "/etc/matron/agent-token", vars["JOURNAL_TOKEN_FILE"]
      assert_equal "https://203.0.113.7:8444", vars["VIEWER_BASE_URL"]
      assert_equal "", vars["NODE_EXTRA_CA_LINE"]
      assert vars["HMAC_SECRET"]
      refute(vars.keys.any? { |k| k.start_with?("MATRIX_") })
    end
  end

  # Without ALLOWED_USER_IDS the bridge has no sender identity and answers
  # every !start/!resume with "Cannot determine sender."
  def test_bridge_env_vars_sets_allowed_user_ids_from_user_and_agent_name
    Dir.mktmpdir do |dir|
      mod = build_matron(
        { "journal" => { "agent_name" => "dev-z" } },
        secrets_path: File.join(dir, "secrets.yml"),
      )

      assert_equal "@dev:dev-z", mod.send(:bridge_env_vars, "/t")["ALLOWED_USER_IDS"]
    end
  end

  def test_allowed_user_ids_agent_name_falls_back_to_hostname
    Dir.mktmpdir do |dir|
      respond("hostname -s", success: true, stdout: "dev-6\n")
      mod = build_matron({}, secrets_path: File.join(dir, "secrets.yml"))

      assert_equal "@dev:dev-6", mod.send(:bridge_env_vars, "/t")["ALLOWED_USER_IDS"]
    end
  end

  def test_bridge_env_template_renders_allowed_user_ids
    template = File.read(File.join(TEMPLATES_DIR, "matron-bridge.env"))
    assert_includes template, "ALLOWED_USER_IDS={{ALLOWED_USER_IDS}}"
  end

  # /sleep stops the whole box, and whether that is reversible depends on the
  # deployment (here: the host's vm-wake starts a stopped guest again). Only a
  # deployer knows, so dev-boxer ships the key empty and never guesses.
  def test_bridge_env_vars_sleep_command_is_empty_by_default
    Dir.mktmpdir do |dir|
      mod = build_matron({}, secrets_path: File.join(dir, "secrets.yml"))

      vars = mod.send(:bridge_env_vars, "/t")

      assert_equal "", vars["MATRON_SLEEP_COMMAND"]
      assert_equal "", vars["MATRON_SLEEP_WAKE_HINT"]
    end
  end

  def test_bridge_env_vars_sleep_command_from_config
    Dir.mktmpdir do |dir|
      mod = build_matron(
        { "bridge" => { "sleep_command" => "sudo systemctl poweroff",
                        "sleep_wake_hint" => "you message this chat" } },
        secrets_path: File.join(dir, "secrets.yml"),
      )

      vars = mod.send(:bridge_env_vars, "/t")

      assert_equal "sudo systemctl poweroff", vars["MATRON_SLEEP_COMMAND"]
      assert_equal "you message this chat", vars["MATRON_SLEEP_WAKE_HINT"]
    end
  end

  def test_bridge_env_template_renders_sleep_keys
    template = File.read(File.join(TEMPLATES_DIR, "matron-bridge.env"))
    assert_includes template, "MATRON_SLEEP_COMMAND={{MATRON_SLEEP_COMMAND}}"
    assert_includes template, "MATRON_SLEEP_WAKE_HINT={{MATRON_SLEEP_WAKE_HINT}}"
  end

  def test_bridge_env_vars_external_uses_journal_url_and_ca_line
    Dir.mktmpdir do |dir|
      mod = build_matron(
        { "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws", "ca_file" => "/etc/matron/chat-ca.pem" } },
        secrets_path: File.join(dir, "secrets.yml"),
      )

      vars = mod.send(:bridge_env_vars, "/etc/matron/agent-token")

      assert_equal "wss://chat.example.com/ws", vars["JOURNAL_WS_URL"]
      assert_equal "NODE_EXTRA_CA_CERTS=/etc/matron/chat-ca.pem", vars["NODE_EXTRA_CA_LINE"]
    end
  end

  def test_hmac_secret_is_memoised_and_persisted
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      mod = build_matron({}, secrets_path: secrets_path)

      first = mod.send(:bridge_env_vars, "/t")["HMAC_SECRET"]
      second = mod.send(:bridge_env_vars, "/t")["HMAC_SECRET"]

      assert_equal first, second
      assert_equal first, YAML.safe_load_file(secrets_path).dig("bridge", "hmac_secret")
    end
  end

  def test_hmac_secret_reused_from_config
    mod = DevBoxer::Modules::Matron.new(
      config: DevBoxer::Config.from_hash(base_config("bridge" => { "hmac_secret" => "keepme" })),
      log: @log, shell: @shell, templates_dir: TEMPLATES_DIR,
    )

    assert_equal "keepme", mod.send(:bridge_env_vars, "/t")["HMAC_SECRET"]
  end

  def test_ensure_journal_user_skips_when_password_recorded
    Dir.mktmpdir do |dir|
      mod = build_matron({ "journal" => { "user_password" => "already" } }, secrets_path: File.join(dir, "secrets.yml"))

      mod.send(:ensure_journal_user)

      refute_recorded(/matron-admin/)
    end
  end

  def test_ensure_journal_user_adds_user_and_persists_password
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      respond_default(success: true)
      mod = build_matron({}, secrets_path: secrets_path)
      mod.stub(:journal_user_exists?, false) do
        mod.send(:ensure_journal_user)
      end

      # Inner command is Shellwords-escaped inside the runuser wrapper, so
      # spaces arrive as backslash-space in the recorded string.
      assert_recorded(/matron-admin\\ user\\ add\\ dev\\ --password/)
      secrets = YAML.safe_load_file(secrets_path)
      assert_equal "dev", secrets.dig("journal", "username")
      assert secrets.dig("journal", "user_password")
    end
  end

  def test_ensure_journal_user_resets_password_when_user_exists_but_unrecorded
    Dir.mktmpdir do |dir|
      respond_default(success: true)
      mod = build_matron({}, secrets_path: File.join(dir, "secrets.yml"))
      mod.stub(:journal_user_exists?, true) do
        mod.send(:ensure_journal_user)
      end

      assert_recorded(/matron-admin\\ user\\ passwd\\ dev\\ --password/)
      refute_recorded(/matron-admin\\ user\\ add/)
    end
  end

  def test_probe_failure_raises_before_bridge_install
    mod = build_matron({ "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" } })

    DevBoxer::JournalEnrollment.stub(:probe, "Errno::ECONNREFUSED: nope") do
      error = assert_raises(RuntimeError) { mod.send(:probe_external_journal!) }
      assert_match(/chat\.example\.com/, error.message)
      assert_match(/ECONNREFUSED/, error.message)
    end
  end

  def test_systemd_units_are_matron_named
    Dir.mktmpdir do |dir|
      respond_default(success: true)
      mod = build_matron({}, secrets_path: File.join(dir, "secrets.yml"))
      mod.stub(:bridge_dir, dir) do
        mod.stub(:unit_dir, dir) do
          mod.send(:install_systemd_units)
        end
      end

      assert File.exist?(File.join(dir, "matron-bridge.service"))
      assert File.exist?(File.join(dir, "matron-viewer.service"))
      assert_includes File.read(File.join(dir, "matron-bridge.service")), "/home/dev/matron-bridge/index.js"
      assert_includes File.read(File.join(dir, "matron-viewer.service")), "viewer/start.js"
      assert_recorded(/systemctl restart matron-bridge/)
      assert_recorded(/systemctl restart matron-viewer/)
    end
  end
end
