require_relative "test_helper"
require "tmpdir"
require_relative "../lib/dev_boxer/matrix_registration"

class MatrixRegistrationTest < Minitest::Test
  def test_open_writes_override_with_token_and_restarts
    Dir.mktmpdir do |dir|
      cmds = []
      shell = DevBoxer::Shell.new(runner: ->(cmd, _opts = {}) { cmds << cmd; [true, "", ""] })
      reg = DevBoxer::MatrixRegistration.new(
        matrix_server_dir: dir, username: "dev", shell: shell,
        log: DevBoxer::Log.new(io: StringIO.new, color: false),
      )

      reg.stub(:wait_for_ready, true) do
        reg.open("token-123")
      end

      override = File.read(File.join(dir, "docker-compose.override.yml"))
      assert_includes override, 'TUWUNEL_REGISTRATION_TOKEN: "token-123"'
      assert_includes override, 'TUWUNEL_ALLOW_REGISTRATION: "true"'
      # Shell#run_as_user wraps via Shellwords.escape, so spaces become backslash-space
      assert(cmds.any? { |c| c.include?("compose") && c.include?("down") }, "compose down expected")
      assert(cmds.any? { |c| c.include?("compose") && c.include?("up") }, "compose up expected")
    end
  end

  def test_close_removes_override_and_restarts
    Dir.mktmpdir do |dir|
      override = File.join(dir, "docker-compose.override.yml")
      File.write(override, "stub")
      shell = DevBoxer::Shell.new(runner: ->(_cmd, _opts = {}) { [true, "", ""] })
      reg = DevBoxer::MatrixRegistration.new(
        matrix_server_dir: dir, username: "dev", shell: shell,
        log: DevBoxer::Log.new(io: StringIO.new, color: false),
      )

      reg.stub(:wait_for_ready, true) do
        reg.close
      end

      refute File.exist?(override), "override should be removed"
    end
  end

  def test_close_swallows_missing_override_quietly
    Dir.mktmpdir do |dir|
      shell = DevBoxer::Shell.new(runner: ->(_cmd, _opts = {}) { [true, "", ""] })
      reg = DevBoxer::MatrixRegistration.new(
        matrix_server_dir: dir, username: "dev", shell: shell,
        log: DevBoxer::Log.new(io: StringIO.new, color: false),
      )

      reg.stub(:wait_for_ready, true) do
        reg.close   # must not raise
      end
    end
  end

  def test_register_bot_returns_true_on_success_and_on_user_in_use
    posted = []
    http = ->(path, body, _bearer = nil) {
      posted << [path, body]
      body[:auth][:session] ? { "user_id" => "@box4:matrix.example.com" } : { "session" => "s" }
    }
    reg = DevBoxer::MatrixRegistration.new(
      matrix_server_dir: "/tmp", username: "dev", shell: nil, http: http,
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
    )

    assert reg.register_bot(username: "box4", password: "pw", reg_token: "tok")
    assert_equal 2, posted.length, "should POST twice (initial + with session)"

    in_use = ->(_path, _body, _bearer = nil) { { "errcode" => "M_USER_IN_USE" } }
    reg2 = DevBoxer::MatrixRegistration.new(
      matrix_server_dir: "/tmp", username: "dev", shell: nil, http: in_use,
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
    )
    assert reg2.register_bot(username: "box4", password: "pw", reg_token: "tok")
  end

  def test_register_bot_raises_on_unknown_failure
    http = ->(_path, _body, _bearer = nil) { { "errcode" => "M_FORBIDDEN" } }
    reg = DevBoxer::MatrixRegistration.new(
      matrix_server_dir: "/tmp", username: "dev", shell: nil, http: http,
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
    )
    assert_raises(DevBoxer::MatrixRegistration::Error) do
      reg.register_bot(username: "box4", password: "pw", reg_token: "tok")
    end
  end
end
