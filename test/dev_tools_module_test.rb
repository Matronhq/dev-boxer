require_relative "test_helper"
require_relative "../lib/dev_boxer/modules/05_dev_tools"

class DevToolsModuleTest < Minitest::Test
  def test_skips_github_auth_when_no_token_in_secrets
    recorded = []
    shell = DevBoxer::Shell.new(runner: ->(cmd, _opts = {}) {
      recorded << cmd
      [true, "", ""]
    })
    output = StringIO.new
    mod = DevBoxer::Modules::DevTools.new(
      config: DevBoxer::Config.from_hash("user" => { "name" => "dev" }),
      log: DevBoxer::Log.new(io: output, color: false),
      shell: shell,
    )

    mod.send(:configure_github_auth_for_user)

    refute(recorded.any? { |c| c.include?("gh auth login") },
           "should not call gh auth login when no token configured")
    assert_includes output.string, "No github.token in secrets.yml"
  end

  def test_uses_pat_to_configure_gh_for_dev_user
    recorded = []
    shell = DevBoxer::Shell.new(runner: ->(cmd, opts = {}) {
      recorded << [cmd, opts]
      success = !cmd.include?("gh auth status")
      [success, "", ""]
    })
    mod = DevBoxer::Modules::DevTools.new(
      config: DevBoxer::Config.from_hash(
        "user"   => { "name" => "dev" },
        "github" => { "token" => "ghp_secret123" },
      ),
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
      shell: shell,
    )

    mod.send(:configure_github_auth_for_user)

    # Shellwords.escape backslash-escapes spaces in the inner command, so the
    # recorded outer cmd looks like `su - dev -c gh\ auth\ login\ --with-token...`.
    # Match on substrings that don't contain spaces.
    login_call = recorded.find { |(cmd, _)| cmd.include?("--with-token") }
    refute_nil login_call, "should call gh auth login --with-token"
    cmd, opts = login_call
    assert_match(/su - dev -c/, cmd)
    assert_equal "ghp_secret123", opts[:stdin], "token must be piped via stdin, not on the command line"
    refute_includes cmd, "ghp_secret123", "token must never appear on the command line"

    setup_call = recorded.find { |(cmd, _)| cmd.include?("setup-git") }
    refute_nil setup_call, "should call gh auth setup-git after login"
    assert_match(/su - dev -c/, setup_call.first)
  end

  def test_skips_login_when_dev_user_already_authenticated
    recorded = []
    shell = DevBoxer::Shell.new(runner: ->(cmd, _opts = {}) {
      recorded << cmd
      [true, "", ""] # gh auth status returns success → already auth'd
    })
    output = StringIO.new
    mod = DevBoxer::Modules::DevTools.new(
      config: DevBoxer::Config.from_hash(
        "user"   => { "name" => "dev" },
        "github" => { "token" => "ghp_secret123" },
      ),
      log: DevBoxer::Log.new(io: output, color: false),
      shell: shell,
    )

    mod.send(:configure_github_auth_for_user)

    refute(recorded.any? { |c| c.include?("gh auth login") },
           "should not re-login when gh auth status already succeeds")
    assert_includes output.string, "GitHub CLI already authenticated"
  end

  def gh_install_run(version_output:, gh_present: true)
    recorded = []
    shell = DevBoxer::Shell.new(runner: ->(cmd, _opts = {}) {
      recorded << cmd
      next [gh_present, "", ""] if cmd.start_with?("command -v gh")
      next [true, version_output, ""] if cmd == "gh --version"
      next [true, "amd64\n", ""] if cmd.include?("dpkg --print-architecture")
      [true, "", ""]
    })
    shell.define_singleton_method(:write_file) { |path, _content, **| recorded << "write_file #{path}" }
    output = StringIO.new
    mod = DevBoxer::Modules::DevTools.new(
      config: DevBoxer::Config.from_hash("user" => { "name" => "dev" }),
      log: DevBoxer::Log.new(io: output, color: false),
      shell: shell,
    )
    mod.send(:install_github_cli)
    [recorded, output.string]
  end

  def test_skips_gh_install_when_version_supports_attach
    recorded, output = gh_install_run(version_output: "gh version 2.99.0 (2026-09-01)\n")

    refute(recorded.any? { |c| c.include?("apt-get install") }, "should not reinstall a current gh")
    assert_includes output, "GitHub CLI 2.99.0 already installed"
  end

  def test_upgrades_gh_older_than_attach_support
    recorded, output = gh_install_run(version_output: "gh version 2.97.0 (2026-07-31)\n")

    assert(recorded.any? { |c| c.include?("apt-get update") }, "should refresh apt before upgrading")
    assert(recorded.any? { |c| c.include?("apt-get install") && c.include?("gh") }, "should upgrade gh")
    assert_includes output, "Upgrading GitHub CLI 2.97.0"
  end

  def test_installs_gh_when_absent
    recorded, output = gh_install_run(version_output: "", gh_present: false)

    refute_includes recorded, "gh --version"
    assert(recorded.any? { |c| c.include?("apt-get install") && c.include?("gh") }, "should install gh")
    assert_includes output, "Installing GitHub CLI"
  end
end
