require_relative "test_helper"
require_relative "support/module_test_case"
require "tmpdir"
require "yaml"

class PreflightTest < DevBoxer::Testing::ModuleTestCase
  GOOD = "github_pat_#{"B2c" * 27}x".freeze
  BAD = "ghp_#{"a1" * 18}".freeze
  GH_STATUS = "su - dev -c 'gh auth status --hostname github.com >/dev/null 2>&1'".freeze

  # Accepts GOOD, refuses everything else.
  class FakeGithubCheck
    attr_reader :checked

    def initialize = @checked = []

    def check(token)
      @checked << token
      problems = token == GOOD ? [] : ["GitHub does not recognise it"]
      DevBoxer::GithubTokenCheck::Result.new(problems: problems, warnings: [])
    end
  end

  def setup
    super
    respond_default(success: true, stdout: "")
    respond(GH_STATUS, success: false)
    @github = FakeGithubCheck.new
    @output = StringIO.new
  end

  def preflight(hash, interactive: false, input: "", secrets_path: nil)
    @config = DevBoxer::Config.from_hash({ "user" => { "name" => "dev" } }.merge(hash))
    DevBoxer::Preflight.new(
      config: @config, shell: @shell, log: @log, interactive: interactive, secrets_path: secrets_path,
      github_check: @github,
      prompter: DevBoxer::Wizard::Prompter.new(input: StringIO.new(input), output: @output),
    )
  end

  def test_a_port_clash_stops_before_any_step
    error = assert_raises(DevBoxer::SetupError) do
      preflight({ "ssh" => { "port" => 9802 } }).run(%w[security])
    end
    assert_match(/SSH \(ssh.port\) and the Matron bridge API \(fixed\) are both set to port 9802/, error.message)
    assert_match(/Nothing has been changed yet/, error.message)
  end

  def test_a_good_github_token_passes
    preflight({ "github" => { "token" => GOOD } }).run(%w[dev-tools])
    assert_equal [GOOD], @github.checked
    assert_match(/github.token accepted/, @log_io.string)
  end

  def test_github_token_is_only_checked_when_dev_tools_runs
    preflight({ "github" => { "token" => BAD } }).run(%w[exposure])
    assert_empty @github.checked
  end

  def test_github_token_is_not_checked_once_gh_is_logged_in
    respond(GH_STATUS, success: true)
    preflight({ "github" => { "token" => BAD } }).run(%w[dev-tools])
    assert_empty @github.checked
  end

  def test_a_refused_github_token_stops_a_non_interactive_run_with_the_next_step
    error = assert_raises(DevBoxer::SetupError) do
      preflight({ "github" => { "token" => BAD } }, secrets_path: "/etc/dev-boxer/secrets.yml").run(%w[dev-tools])
    end
    assert_match(%r{The GitHub token in /etc/dev-boxer/secrets.yml \(github.token\) was refused}, error.message)
    assert_match(/read:org/, error.message)
    assert_match(/Nothing has been changed yet/, error.message)
  end

  def test_a_refused_github_token_is_replaced_in_a_terminal_and_saved
    Dir.mktmpdir do |dir|
      secrets = File.join(dir, "secrets.yml")
      File.write(secrets, { "github" => { "token" => BAD } }.to_yaml)
      preflight({ "github" => { "token" => BAD } }, interactive: true, input: "#{GOOD}\n", secrets_path: secrets).run(%w[dev-tools])

      assert_equal GOOD, @config.github.token
      assert_equal GOOD, YAML.safe_load_file(secrets).dig("github", "token")
      assert_match(/Checking it with GitHub/, @output.string)
    end
  end

  def test_entering_nothing_drops_the_refused_github_token
    Dir.mktmpdir do |dir|
      secrets = File.join(dir, "secrets.yml")
      File.write(secrets, { "github" => { "token" => BAD } }.to_yaml)
      preflight({ "github" => { "token" => BAD } }, interactive: true, input: "\n", secrets_path: secrets).run(%w[dev-tools])

      assert_nil @config.github.token
      assert_nil YAML.safe_load_file(secrets).dig("github", "token")
      assert_match(/log in with a browser/, @log_io.string)
    end
  end

  def test_an_unreadable_agent_token_file_is_handed_to_the_dev_user
    Dir.mktmpdir do |dir|
      token = File.join(dir, "agent-token")
      File.write(token, "tok\n")
      readable = "runuser -u dev -- test -r #{token}"
      checks = [[false, "", ""], [true, "", ""]]
      # Unreadable at first, readable after the chown.
      responses = @responses
      responses.define_singleton_method(:fetch) { |cmd, default| cmd == readable ? checks.shift : default }

      preflight({ "journal" => { "token_file" => token } }).run(%w[matron])

      assert_recorded("chown dev:dev #{token}")
      assert_recorded("chmod 0600 #{token}")
    end
  end
end

class PreflightFirstRunTokenTest < DevBoxer::Testing::ModuleTestCase
  def preflight(token)
    config = DevBoxer::Config.from_hash({ "user" => { "name" => "dev" }, "journal" => { "token_file" => token } })
    DevBoxer::Preflight.new(config: config, shell: @shell, log: @log, interactive: false)
  end

  def setup
    super
    respond("id -u dev >/dev/null 2>&1", success: false)
  end

  def test_a_token_under_a_closed_directory_stops_a_first_run
    Dir.mktmpdir do |dir|
      closed = File.join(dir, "closed")
      Dir.mkdir(closed, 0o700)
      token = File.join(closed, "agent-token")
      File.write(token, "tok\n")

      error = assert_raises(DevBoxer::SetupError) { preflight(token).run(%w[matron]) }
      assert_match(/is under #{Regexp.escape(closed)}, which only its owner and group can open/, error.message)
      refute_recorded(/chown|runuser/)
    end
  end

  def test_a_token_under_open_directories_waits_for_the_matron_step
    Dir.mktmpdir do |dir|
      File.chmod(0o755, dir)
      token = File.join(dir, "agent-token")
      File.write(token, "tok\n")
      File.chmod(0o600, token)

      preflight(token).run(%w[matron])
      refute_recorded(/chown|runuser/)
    end
  end
end

class PreflightAgentTokenTest < DevBoxer::Testing::ModuleTestCase
  def test_a_token_still_unreadable_after_the_chown_stops_with_the_next_step
    Dir.mktmpdir do |dir|
      token = File.join(dir, "agent-token")
      File.write(token, "tok\n")
      respond("runuser -u dev -- test -r #{token}", success: false)
      config = DevBoxer::Config.from_hash({ "user" => { "name" => "dev" }, "journal" => { "token_file" => token } })
      enrollment = DevBoxer::JournalEnrollment.new(config: config, shell: @shell, log: @log)

      error = assert_raises(DevBoxer::SetupError) { enrollment.ensure_readable_by_user!(token) }
      assert_match(/a directory above it is closed to dev/, error.message)
      assert_match(%r{re-run: sudo ./setup.rb --from matron}, error.message)
    end
  end

  def test_nothing_is_changed_when_the_dev_user_can_already_read_it
    config = DevBoxer::Config.from_hash({ "user" => { "name" => "dev" } })
    DevBoxer::JournalEnrollment.new(config: config, shell: @shell, log: @log).ensure_readable_by_user!("/etc/matron/agent-token")
    refute_recorded(/chown|chmod/)
  end
end
