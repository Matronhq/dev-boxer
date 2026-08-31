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

  # Voice notes were the bug this covers: the bridge shells out to ffmpeg and
  # whisper-cli, dev-boxer installed neither, and the failure surfaced only as
  # "Could not transcribe that voice note" the first time someone sent one.
  def test_install_voice_notes_runs_the_bridge_installer_when_absent
    respond("test -f /home/dev/.local/share/whisper-cpp/build/bin/whisper-cli", success: false)
    mod = build_matron

    mod.send(:install_voice_notes)

    # Shellwords-escaped inside the `su - dev -c` wrapper, so `=` and spaces
    # arrive backslashed.
    assert_recorded(%r{WHISPER_MODEL\\=small.*setup/install-whisper\.sh})
  end

  def test_install_voice_notes_passes_the_configured_model
    respond("test -f /home/dev/.local/share/whisper-cpp/build/bin/whisper-cli", success: false)
    mod = build_matron({ "bridge" => { "voice_notes" => { "model" => "medium" } } })

    mod.send(:install_voice_notes)

    assert_recorded(/WHISPER_MODEL\\=medium/)
  end

  # Idempotent re-runs must not rebuild whisper.cpp or re-download the model.
  def test_install_voice_notes_skips_when_binary_and_model_present
    respond_default(success: true)
    mod = build_matron

    mod.send(:install_voice_notes)

    refute_recorded(/install-whisper\.sh/)
  end

  # A binary from an earlier run plus a missing model (interrupted download)
  # must still converge, not report "already installed".
  def test_install_voice_notes_reinstalls_when_model_missing
    respond("test -f /home/dev/.local/share/whisper-cpp/models/ggml-small.bin", success: false)
    mod = build_matron

    mod.send(:install_voice_notes)

    assert_recorded(/install-whisper\.sh/)
  end

  def test_install_voice_notes_can_be_disabled
    respond_default(success: false)
    mod = build_matron({ "bridge" => { "voice_notes" => { "enabled" => false } } })

    mod.send(:install_voice_notes)

    refute_recorded(/install-whisper\.sh/)
  end

  # Opting out must not leave `WHISPER_MODEL_PATH=` (empty) in .env pointing
  # the bridge at a model nothing installed.
  def test_bridge_env_vars_omits_whisper_line_when_voice_notes_disabled
    Dir.mktmpdir do |dir|
      mod = build_matron({ "bridge" => { "voice_notes" => { "enabled" => false } } },
                         secrets_path: File.join(dir, "secrets.yml"))

      assert_equal "", mod.send(:bridge_env_vars, "/t")["WHISPER_MODEL_LINE"]
    end
  end

  # Voice notes are a nice-to-have; a whisper build that OOMs or times out on
  # a small box must not take the whole chat stack down with it.
  def test_install_voice_notes_failure_warns_instead_of_aborting_setup
    respond_default(success: false)
    mod = build_matron

    mod.send(:install_voice_notes)

    assert_match(/Whisper install failed/, @log_io.string)
    assert_match(%r{setup/install-whisper\.sh}, @log_io.string)
  end

  def test_bridge_env_vars_points_the_bridge_at_the_installed_model
    Dir.mktmpdir do |dir|
      mod = build_matron({ "bridge" => { "voice_notes" => { "model" => "medium" } } },
                         secrets_path: File.join(dir, "secrets.yml"))

      assert_equal "WHISPER_MODEL_PATH=/home/dev/.local/share/whisper-cpp/models/ggml-medium.bin",
                   mod.send(:bridge_env_vars, "/t")["WHISPER_MODEL_LINE"]
    end
  end

  def test_bridge_env_template_renders_whisper_model_line
    template = File.read(File.join(TEMPLATES_DIR, "matron-bridge.env"))
    assert_includes template, "{{WHISPER_MODEL_LINE}}"
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
