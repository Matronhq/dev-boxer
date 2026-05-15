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
end
