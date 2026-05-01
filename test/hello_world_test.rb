require_relative "test_helper"
require "tmpdir"
require_relative "../lib/dev_boxer/modules/11_hello_world"

class HelloWorldTest < Minitest::Test
  def test_matrix_login_instructions_are_matron_focused_and_inline
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      home = File.join(dir, "home")
      FileUtils.mkdir_p(home)
      File.write(secrets_path, {
        "matrix" => {
          "user_password" => "matrix-pass",
        },
      }.to_yaml)
      File.write(File.join(home, "recovery-key.txt"), <<~KEY)
        # Copy this key

        recovery-key-value
      KEY
      output = StringIO.new
      mod = build_module(secrets_path: secrets_path, output: output)

      mod.stub(:home_dir, home) do
        mod.send(:print_matrix_login_instructions)
      end

      summary = output.string
      assert_includes summary, "Matrix bridge — Matron first login"
      assert_includes summary, "URL: https://matrix.example.com"
      assert_includes summary, "User ID: @dev:matrix.example.com"
      assert_includes summary, "Password: matrix-pass"
      assert_includes summary, "Secure Backup recovery key: recovery-key-value"
      refute_includes summary, "Open Element"
      refute_includes summary, "custom homeserver"
      refute_includes summary, "recovery-key.txt"
    end
  end

  def test_matrix_login_instructions_skip_disabled_matrix
    output = StringIO.new
    mod = build_module(
      output: output,
      config_hash: {
        "user" => { "name" => "dev" },
        "matrix" => { "mode" => "disabled" },
      },
    )

    mod.send(:print_matrix_login_instructions)

    assert_empty output.string
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
      "matrix" => {
        "mode" => "bundled",
        "server_domain" => "matrix.example.com",
        "user_username" => "dev",
      },
      "cloudflare" => {
        "tunnel" => {
          "hostname_matrix" => "matrix.example.com",
        },
      },
    }
  end
end
