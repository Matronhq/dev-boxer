require_relative "test_helper"
require_relative "../lib/dev_boxer/modules/10_desktop_apps"

class DesktopAppsTest < Minitest::Test
  def test_claude_md_vars_include_zone_and_experience_guidance
    mod = build_module("advanced")

    vars = mod.send(:claude_md_vars)

    assert_equal "example.com", vars["CF_ZONE_NAME"]
    assert_equal "hello.example.com", vars["CF_HOSTNAME_HELLO"]
    assert_includes vars["USER_EXPERIENCE_GUIDANCE"], "advanced mode"
    assert_includes vars["USER_EXPERIENCE_GUIDANCE"], "diffs, tests, blockers"
  end

  def test_claude_md_vars_default_to_intermediate_guidance
    mod = build_module("unexpected")

    vars = mod.send(:claude_md_vars)

    assert_includes vars["USER_EXPERIENCE_GUIDANCE"], "intermediate mode"
  end

  def test_setup_desktop_script_runs_only_desktop_module
    mod = build_module("intermediate")

    script = mod.send(:setup_desktop_script)

    assert_includes script, "--only desktop"
    refute_includes script, "--only desktop-apps"
    assert_includes script, "Installing optional XFCE/XRDP desktop"
  end

  def test_final_setup_run_does_not_install_gui_apps
    recorded = []
    shell = DevBoxer::Shell.new(runner: ->(cmd, _opts = {}) {
      recorded << cmd
      if cmd.include?("command -v lazydocker")
        [false, "", ""]
      else
        [true, cmd == "dpkg --print-architecture" ? "amd64\n" : "", ""]
      end
    })
    mod = DevBoxer::Modules::DesktopApps.new(
      config: config("intermediate"),
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
      shell: shell,
      templates_dir: File.expand_path("../templates", __dir__),
    )

    mod.stub(:lazydocker_latest_version, "0.25.2") do
      mod.stub(:write_setup_scripts, nil) do
        mod.stub(:write_claude_md, nil) do
          mod.stub(:install_motd, nil) do
            mod.stub(:print_summary, nil) do
              mod.run
            end
          end
        end
      end
    end

    refute(recorded.any? { |cmd| cmd.include?("github-desktop") })
    refute(recorded.any? { |cmd| cmd.include?("code") })
  end

  def test_print_summary_uses_detected_ip_in_ssh_line
    log_io = StringIO.new
    shell = DevBoxer::Shell.new(runner: ->(cmd, _opts = {}) {
      cmd.include?("hostname -I") ? [true, "203.0.113.7 fe80::1\n", ""] : [true, "", ""]
    })
    mod = DevBoxer::Modules::DesktopApps.new(
      config: config("intermediate"),
      log: DevBoxer::Log.new(io: log_io, color: false),
      shell: shell,
      templates_dir: File.expand_path("../templates", __dir__),
    )

    mod.send(:print_summary)

    assert_includes log_io.string, "SSH:  ssh dev@203.0.113.7 -p 2222"
    refute_includes log_io.string, "<server-ip>"
  end

  def test_print_summary_falls_back_to_placeholder_when_ip_detection_fails
    log_io = StringIO.new
    shell = DevBoxer::Shell.new(runner: ->(cmd, _opts = {}) {
      cmd.include?("hostname -I") ? [false, "", "no such command"] : [true, "", ""]
    })
    mod = DevBoxer::Modules::DesktopApps.new(
      config: config("intermediate"),
      log: DevBoxer::Log.new(io: log_io, color: false),
      shell: shell,
      templates_dir: File.expand_path("../templates", __dir__),
    )

    mod.send(:print_summary)

    assert_includes log_io.string, "SSH:  ssh dev@<server-ip> -p 2222"
  end

  private

  def build_module(experience_level, log_io: StringIO.new)
    DevBoxer::Modules::DesktopApps.new(
      config: config(experience_level),
      log: DevBoxer::Log.new(io: log_io, color: false),
      shell: DevBoxer::Shell.new(runner: ->(_cmd, _opts = {}) { [true, "", ""] }),
      templates_dir: File.expand_path("../templates", __dir__),
    )
  end

  def config(experience_level)
    cloudflare = {
      "zone_name" => "example.com",
      "tunnel" => {
        "hostname" => "dev.example.com",
        "hostname_journal" => "chat.example.com",
        "hostname_viewer" => "viewer.example.com",
        "hostname_hello" => "hello.example.com",
      },
    }

    DevBoxer::Config.from_hash(
      "user" => { "name" => "dev" },
      "ssh" => { "port" => 2222 },
      "claude" => { "experience_level" => experience_level },
      "journal" => { "mode" => "bundled" },
      "exposure" => { "mode" => "cloudflare", "cloudflare" => cloudflare },
    )
  end
end
