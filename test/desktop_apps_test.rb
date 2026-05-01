require_relative "test_helper"
require_relative "../lib/dev_boxer/modules/10_desktop_apps"

class DesktopAppsTest < Minitest::Test
  def test_claude_md_vars_include_zone_and_experience_guidance
    mod = build_module("advanced")

    vars = mod.send(:claude_md_vars)

    assert_equal "example.com", vars["CF_ZONE_NAME"]
    assert_includes vars["USER_EXPERIENCE_GUIDANCE"], "advanced mode"
    assert_includes vars["USER_EXPERIENCE_GUIDANCE"], "diffs, tests, blockers"
  end

  def test_claude_md_vars_default_to_intermediate_guidance
    mod = build_module("unexpected")

    vars = mod.send(:claude_md_vars)

    assert_includes vars["USER_EXPERIENCE_GUIDANCE"], "intermediate mode"
  end

  def test_setup_desktop_script_runs_desktop_then_desktop_apps
    mod = build_module("intermediate")

    script = mod.send(:setup_desktop_script)

    assert_includes script, "--only desktop"
    assert_includes script, "--only desktop-apps"
    assert_includes script, "Installing optional XFCE/XRDP desktop"
  end

  def test_desktop_apps_are_skipped_without_desktop_environment
    recorded = []
    shell = DevBoxer::Shell.new(runner: ->(cmd, _opts = {}) {
      recorded << cmd
      [false, "", ""]
    })
    mod = DevBoxer::Modules::DesktopApps.new(
      config: config("intermediate"),
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
      shell: shell,
      templates_dir: File.expand_path("../templates", __dir__),
    )

    mod.send(:install_desktop_apps_if_available)

    refute(recorded.any? { |cmd| cmd.include?("github-desktop") })
    refute(recorded.any? { |cmd| cmd.include?("code") })
  end

  private

  def build_module(experience_level)
    DevBoxer::Modules::DesktopApps.new(
      config: config(experience_level),
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
      shell: DevBoxer::Shell.new(runner: ->(_cmd, _opts = {}) { [true, "", ""] }),
      templates_dir: File.expand_path("../templates", __dir__),
    )
  end

  def config(experience_level)
    DevBoxer::Config.from_hash(
      "user" => { "name" => "dev" },
      "ssh" => { "port" => 2222 },
      "claude" => { "experience_level" => experience_level },
      "cloudflare" => {
        "zone_name" => "example.com",
        "tunnel" => {
          "hostname" => "dev.example.com",
          "hostname_matrix" => "matrix.example.com",
          "hostname_viewer" => "viewer.example.com",
        },
      },
    )
  end
end
