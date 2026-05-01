require_relative "test_helper"
require_relative "../lib/dev_boxer/modules/02_users"

class UsersModuleTest < Minitest::Test
  def test_restarts_ubuntu_ssh_service
    recorded = []
    shell = DevBoxer::Shell.new(runner: ->(cmd, _opts = {}) {
      recorded << cmd
      [true, "", ""]
    })
    mod = DevBoxer::Modules::Users.new(
      config: DevBoxer::Config.from_hash("user" => { "name" => "dan" }),
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
      shell: shell,
    )

    mod.send(:restart_ssh_service)

    assert_includes recorded, "systemctl restart ssh"
    refute_includes recorded, "systemctl restart sshd"
  end
end
