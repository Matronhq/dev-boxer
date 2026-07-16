require_relative "test_helper"
require "tmpdir"
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

  private

  def build_module(output:, secrets_path: nil, config_hash: default_config)
    DevBoxer::Modules::HelloWorld.new(
      config: DevBoxer::Config.from_hash(config_hash),
      log: DevBoxer::Log.new(io: output, color: false),
      shell: DevBoxer::Shell.new(runner: ->(_cmd, _opts = {}) { [true, "", ""] }),
      secrets_path: secrets_path,
    )
  end

  def default_config
    {
      "user" => { "name" => "dev" },
    }
  end
end
