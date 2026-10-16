require_relative "test_helper"
require_relative "../lib/dev_boxer/modules/02_users"

class UsersModuleTest < Minitest::Test
  def build(key: DevBoxer::Testing::SSH_KEY_ALICE, failing: [])
    @recorded = []
    shell = DevBoxer::Shell.new(runner: ->(cmd, _opts = {}) {
      @recorded << cmd
      [failing.none? { |pattern| pattern === cmd }, "", ""]
    })
    DevBoxer::Modules::Users.new(
      config: DevBoxer::Config.from_hash("user" => { "name" => "alice", "ssh_public_key" => key }, "ssh" => { "port" => 2223 }),
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
      shell: shell,
    )
  end

  def test_restarts_ubuntu_ssh_service
    build.send(:restart_ssh_service)

    assert_includes @recorded, "systemctl restart ssh"
    refute_includes @recorded, "systemctl restart sshd"
  end

  def test_socket_activated_ssh_is_regenerated_so_the_new_port_takes_effect
    build.send(:restart_ssh_service)

    reload = @recorded.index("systemctl daemon-reload")
    socket = @recorded.index("systemctl restart ssh.socket")
    assert reload && socket && reload < socket, @recorded.inspect
    assert_includes @recorded, "ss -ltnH 'sport = :2223' | grep -q LISTEN"
  end

  def test_without_ssh_socket_only_the_service_restarts
    build(failing: ["systemctl is-active --quiet ssh.socket"]).send(:restart_ssh_service)

    refute_includes @recorded, "systemctl restart ssh.socket"
    assert_includes @recorded, "systemctl restart ssh"
  end

  def test_refuses_to_turn_on_key_only_login_with_an_unusable_key
    mod = build(key: "ssh-ed25519 AAAATEST alice@example.com")
    error = assert_raises(DevBoxer::SetupError) { mod.send(:restart_ssh_service) }

    assert_match(/Not restarting SSH: user.ssh_public_key/, error.message)
    refute_includes @recorded, "systemctl restart ssh"
  end

  def test_refuses_to_restart_when_sshd_config_is_invalid
    mod = build(failing: ["sshd -t"])
    error = assert_raises(DevBoxer::SetupError) { mod.send(:restart_ssh_service) }

    assert_match(/sshd -t/, error.message)
    refute_includes @recorded, "systemctl restart ssh"
  end

  def test_reports_when_ssh_is_not_listening_on_the_new_port
    mod = build(failing: [/\Ass -ltnH/])
    error = assert_raises(DevBoxer::SetupError) { mod.send(:restart_ssh_service) }

    assert_match(/not listening on port 2223.*Keep this session open/m, error.message)
  end
end
