require_relative "test_helper"
require_relative "support/module_test_case"

class PortCheckTest < DevBoxer::Testing::ModuleTestCase
  def config(hash) = DevBoxer::Config.from_hash(hash)

  def ss(port) = "ss -ltnpH sport\\ \\=\\ :#{port}"

  def test_default_ports_do_not_clash
    assert_empty DevBoxer::PortCheck.clashes(config({}))
    assert_empty DevBoxer::PortCheck.clashes(config({ "exposure" => { "mode" => "ip" }, "desktop" => { "enabled" => true } }))
  end

  def test_a_configured_port_on_a_fixed_service_port_clashes
    clashes = DevBoxer::PortCheck.clashes(config({ "hello_world" => { "port" => 9803 } }))
    assert_equal ["the Matron file viewer (fixed) and the hello-world test page (hello_world.port) are both set to port 9803"], clashes
  end

  def test_two_configured_ports_clash
    clashes = DevBoxer::PortCheck.clashes(config({ "ssh" => { "port" => 8444 }, "exposure" => { "mode" => "ip" } }))
    assert_match(/SSH \(ssh.port\) and the file viewer over HTTPS \(exposure.ip.viewer_port\) are both set to port 8444/, clashes.join)
  end

  def test_a_port_held_by_another_program_is_busy
    respond(ss(2222), success: true, stdout: %(LISTEN 0 4096 0.0.0.0:2222 0.0.0.0:* users:(("docker-proxy",pid=10,fd=4))\n))
    busy = DevBoxer::PortCheck.busy(config({}), @shell, module_names: %w[security])
    assert_equal ["port 2222, wanted for SSH, is already in use by docker-proxy"], busy
  end

  def test_a_port_held_by_its_own_service_is_fine_on_a_re_run
    respond(ss(2222), success: true, stdout: %(LISTEN 0 4096 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=1,fd=3),("systemd",pid=1,fd=9))\n))
    respond(ss(9802), success: true, stdout: %(LISTEN 0 511 127.0.0.1:9802 0.0.0.0:* users:(("node",pid=7,fd=20))\n))
    assert_empty DevBoxer::PortCheck.busy(config({}), @shell, module_names: %w[users matron])
  end

  def test_only_ports_of_the_steps_about_to_run_are_checked
    respond_default(success: true, stdout: %(LISTEN 0 1 0.0.0.0:1 0.0.0.0:* users:(("other",pid=2,fd=3))\n))
    busy = DevBoxer::PortCheck.busy(config({}), @shell, module_names: %w[hello-world])
    assert_equal ["port 9820, wanted for the hello-world test page, is already in use by other"], busy
  end

  def test_a_free_port_or_an_unnamed_holder_is_not_reported
    respond_default(success: true, stdout: "")
    assert_empty DevBoxer::PortCheck.busy(config({}), @shell, module_names: %w[users matron])
    respond_default(success: true, stdout: "LISTEN 0 1 0.0.0.0:2222 0.0.0.0:*\n")
    assert_empty DevBoxer::PortCheck.busy(config({}), @shell, module_names: %w[users])
  end
end
