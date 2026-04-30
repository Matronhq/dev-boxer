require_relative "test_helper"
require "tmpdir"

class ShellTest < Minitest::Test
  def setup
    @recorded = []
    @responses = {}
    runner = lambda do |cmd, opts = {}|
      @recorded << [cmd, opts]
      resp = @responses.fetch(cmd, [true, ""])
      resp
    end
    @sh = DevBoxer::Shell.new(runner: runner)
  end

  def respond(cmd, success:, output: "")
    @responses[cmd] = [success, output]
  end

  def test_sh_bang_runs_command
    @sh.sh!("ls /tmp")
    assert_equal [["ls /tmp", {}]], @recorded
  end

  def test_sh_bang_raises_on_failure
    respond("false", success: false, output: "")
    assert_raises(DevBoxer::Shell::Error) do
      @sh.sh!("false")
    end
  end

  def test_sh_returns_boolean
    respond("true", success: true)
    respond("false", success: false)
    assert @sh.sh("true")
    refute @sh.sh("false")
  end

  def test_command_exists_uses_command_v
    respond("command -v ufw >/dev/null 2>&1", success: true)
    assert @sh.command_exists?("ufw")
  end

  def test_apt_installed_checks_dpkg
    respond("dpkg -s ufw >/dev/null 2>&1", success: true)
    assert @sh.apt_installed?("ufw")
  end

  def test_service_active_uses_systemctl_is_active
    respond("systemctl is-active --quiet ufw", success: true)
    assert @sh.service_active?("ufw")
  end

  def test_apt_install_runs_apt_get_for_all_packages
    # apt is idempotent and handles version upgrades; pre-skipping based
    # on dpkg -s would prevent NodeSource repo-swap upgrades.
    @sh.apt_install("ufw", "curl")
    assert(@recorded.any? { |c, _|
      c.include?("apt-get install") && c.include?("ufw") && c.include?("curl")
    }, "expected one apt-get install with both packages; got:\n#{@recorded.map(&:first).join("\n")}")
  end

  def test_apt_install_with_no_packages_is_a_noop
    @sh.apt_install
    refute(@recorded.any? { |c, _| c.include?("apt-get install") })
  end

  def test_systemctl_runs_action
    @sh.systemctl(:enable, "fail2ban")
    @sh.systemctl(:restart, "fail2ban")
    assert_equal "systemctl enable fail2ban", @recorded[0][0]
    assert_equal "systemctl restart fail2ban", @recorded[1][0]
  end

  def test_run_as_user_wraps_in_su
    @sh.run_as_user("dan", "echo hi")
    assert_match(/su - dan -c/, @recorded[0][0])
  end

  def test_write_file_writes_content_and_chmods
    Dir.mktmpdir do |dir|
      path = "#{dir}/foo"
      @sh.write_file(path, "hello\n", mode: 0o600)
      assert_equal "hello\n", File.read(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_sh_passes_stdin_through_runner
    captured_opts = nil
    runner = lambda do |_cmd, opts = {}|
      captured_opts = opts
      [true, ""]
    end
    sh = DevBoxer::Shell.new(runner: runner)
    sh.sh!("chpasswd", stdin: "dan:p'a$$word\n")
    assert_equal "dan:p'a$$word\n", captured_opts[:stdin]
  end
end
