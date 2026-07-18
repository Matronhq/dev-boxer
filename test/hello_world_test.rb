require_relative "test_helper"
require "tmpdir"
require "shellwords"
require_relative "../lib/dev_boxer/modules/11_hello_world"

class HelloWorldTest < Minitest::Test
  def test_matron_login_instructions_bundled_show_server_user_password
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      File.write(secrets_path, { "journal" => { "username" => "dan", "user_password" => "journal-pass" } }.to_yaml)
      output = StringIO.new
      mod = build_module(
        secrets_path: secrets_path,
        output: output,
        config_hash: {
          "user" => { "name" => "dev" },
          "journal" => { "mode" => "bundled" },
          "exposure" => { "mode" => "ip", "ip" => { "address" => "203.0.113.7" } },
        },
      )

      mod.send(:print_matron_login_instructions)

      summary = output.string
      assert_includes summary, "Matron — first login"
      assert_includes summary, "wss://203.0.113.7:8443/ws"
      assert_includes summary, "Username: dan"
      assert_includes summary, "Password: journal-pass"
      assert_includes summary, "bin/enroll"
      refute_match(/matrix/i, summary)
    end
  end

  def test_matron_login_instructions_external_point_at_existing_journal
    output = StringIO.new
    mod = build_module(
      output: output,
      config_hash: {
        "user" => { "name" => "dev" },
        "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" },
        "exposure" => { "mode" => "ip", "ip" => { "address" => "203.0.113.7" } },
      },
    )

    mod.send(:print_matron_login_instructions)

    summary = output.string
    assert_includes summary, "wss://chat.example.com/ws"
    assert_includes summary, "existing"
    refute_includes summary, "Password:"
  end

  def test_default_port_is_9820_to_avoid_journal_collision
    mod = build_module(output: StringIO.new)

    assert_equal 9820, mod.send(:hello_port)
  end

  def test_configured_port_overrides_default
    mod = build_module(output: StringIO.new, config_hash: {
      "user" => { "name" => "dev" },
      "hello_world" => { "port" => 12345 },
    })

    assert_equal 12345, mod.send(:hello_port)
  end

  def test_bundled_login_instructions_print_link_code_qr
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      File.write(secrets_path, { "journal" => { "username" => "dan", "user_password" => "journal-pass" } }.to_yaml)
      output = StringIO.new
      recorded = []
      runner = lambda do |cmd, _opts = {}|
        recorded << cmd
        if cmd.include?("link-code")
          [true, "|FAKE-ANSI-QR|\nServer: https://203.0.113.7:8443\nCode: ABCD-EFGH\n", ""]
        else
          [true, "", ""]
        end
      end
      mod = build_module(
        secrets_path: secrets_path,
        output: output,
        runner: runner,
        config_hash: {
          "user" => { "name" => "dev" },
          "journal" => { "mode" => "bundled" },
          "exposure" => { "mode" => "ip", "ip" => { "address" => "203.0.113.7" } },
        },
      )

      mod.send(:print_matron_login_instructions)

      link_cmd = recorded.find { |c| c.include?("link-code") }
      refute_nil link_cmd, "expected a matron-admin link-code invocation"
      assert_includes link_cmd, "runuser -u matron"
      # Inner command is Shellwords-escaped, so spaces appear as "\ ".
      # MATRON_DB is how the CLI locates the preapprove key — dropping it
      # would break authentication even with the runuser wrapper intact.
      assert_includes link_cmd, "MATRON_DB\\="
      assert_includes link_cmd, "link-code\\ dan\\ --server-url\\ https://203.0.113.7:8443"

      summary = output.string
      assert_includes summary, "|FAKE-ANSI-QR|"
      assert_includes summary, "Code: ABCD-EFGH"
      assert_includes summary, "scan this QR"
      assert_includes summary, "Password: journal-pass"
    end
  end

  def test_bundled_qr_uses_cloudflare_hostname_when_configured
    output = StringIO.new
    recorded = []
    runner = ->(cmd, _opts = {}) { recorded << cmd; [true, "qr\n", ""] }
    mod = build_module(
      output: output,
      runner: runner,
      config_hash: {
        "user" => { "name" => "dev" },
        "journal" => { "mode" => "bundled" },
        "exposure" => {
          "mode" => "cloudflare",
          "cloudflare" => { "tunnel" => { "hostname_journal" => "chat.example.com" } },
        },
      },
    )

    mod.send(:print_matron_login_instructions)

    link_cmd = recorded.find { |c| c.include?("link-code") }
    refute_nil link_cmd
    assert_includes link_cmd, "--server-url\\ https://chat.example.com"
  end

  def test_link_code_failure_warns_and_keeps_password_login
    output = StringIO.new
    runner = lambda do |cmd, _opts = {}|
      cmd.include?("link-code") ? [false, "", "unknown command: link-code"] : [true, "", ""]
    end
    mod = build_module(
      output: output,
      runner: runner,
      config_hash: {
        "user" => { "name" => "dev" },
        "journal" => { "mode" => "bundled" },
        "exposure" => { "mode" => "ip", "ip" => { "address" => "203.0.113.7" } },
      },
    )

    mod.send(:print_matron_login_instructions)

    summary = output.string
    assert_includes summary, "Couldn't mint a sign-in QR"
    assert_includes summary, "bin/enroll" # instructions continue past the failure
  end

  def test_external_mode_never_runs_link_code
    output = StringIO.new
    recorded = []
    runner = ->(cmd, _opts = {}) { recorded << cmd; [true, "", ""] }
    mod = build_module(
      output: output,
      runner: runner,
      config_hash: {
        "user" => { "name" => "dev" },
        "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" },
        "exposure" => { "mode" => "ip", "ip" => { "address" => "203.0.113.7" } },
      },
    )

    mod.send(:print_matron_login_instructions)

    assert_empty recorded.select { |c| c.include?("link-code") }
  end

  private

  def build_module(output:, secrets_path: nil, config_hash: default_config,
                   runner: ->(_cmd, _opts = {}) { [true, "", ""] })
    DevBoxer::Modules::HelloWorld.new(
      config: DevBoxer::Config.from_hash(config_hash),
      log: DevBoxer::Log.new(io: output, color: false),
      shell: DevBoxer::Shell.new(runner: runner),
      secrets_path: secrets_path,
    )
  end

  def default_config
    {
      "user" => { "name" => "dev" },
    }
  end
end
