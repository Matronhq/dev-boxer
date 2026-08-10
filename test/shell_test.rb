require_relative "test_helper"
require "tmpdir"

class ShellTest < Minitest::Test
  def setup
    @recorded = []
    @responses = {}
    runner = lambda do |cmd, opts = {}|
      @recorded << [cmd, opts]
      @responses.fetch(cmd, [true, "", ""])
    end
    @sh = DevBoxer::Shell.new(runner: runner)
  end

  def respond(cmd, success:, stdout: "", stderr: "")
    @responses[cmd] = [success, stdout, stderr]
  end

  def test_sh_bang_runs_command
    @sh.sh!("ls /tmp")
    assert_equal [["ls /tmp", {}]], @recorded
  end

  def test_sh_bang_raises_on_failure
    respond("false", success: false)
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

  # /etc/postfix/sasl_passwd goes through here carrying the Resend API key.
  # See the matching template_test case for why chmod is stubbed out.
  def test_write_file_never_creates_a_secret_bearing_file_world_readable
    Dir.mktmpdir do |dir|
      path = "#{dir}/sasl_passwd"

      previous = File.umask(0o000)
      begin
        File.stub(:chmod, nil) do
          @sh.write_file(path, "[smtp.resend.com]:587 resend:re_key\n", mode: 0o600)
        end
      ensure
        File.umask(previous)
      end

      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_sh_passes_stdin_through_runner
    captured_opts = nil
    runner = lambda do |_cmd, opts = {}|
      captured_opts = opts
      [true, "", ""]
    end
    sh = DevBoxer::Shell.new(runner: runner)
    sh.sh!("chpasswd", stdin: "dan:p'a$$word\n")
    assert_equal "dan:p'a$$word\n", captured_opts[:stdin]
  end

  def test_default_runner_executes_shell_builtins
    sh = DevBoxer::Shell.new
    assert_includes sh.sh!("command -v sh"), "sh"
  end

  def test_wait_for_http_accepts_any_http_status
    recorded = []
    shell = DevBoxer::Shell.new(runner: lambda { |cmd, _opts = {}|
      recorded << cmd
      [true, "", ""]  # curl exit 0 == got an HTTP response (even 401)
    })

    assert shell.wait_for_http("http://127.0.0.1:9810/metrics", timeout: 1)
    assert_match(/curl -s -o \/dev\/null/, recorded.first)
    refute_match(/curl -sf/, recorded.first)
  end
end
