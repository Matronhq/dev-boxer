require "shellwords"

module DevBoxer
  # Checks that run before the first step, for the steps about to run, so a
  # problem is reported while nothing has changed yet:
  #   - two services set to the same port, or a port another program holds;
  #   - the GitHub token in secrets.yml (shape, GitHub accepts it, scopes);
  #   - a pre-provisioned agent token file the dev user cannot read.
  # Raises SetupError with the next step; in a terminal, a refused GitHub
  # token can be replaced on the spot instead.
  class Preflight
    def initialize(config:, shell:, log:, interactive:, secrets_path: nil,
                   github_check: GithubTokenCheck.new, prompter: nil)
      @config = config
      @shell = shell
      @log = log
      @interactive = interactive
      @secrets_path = secrets_path
      @github_check = github_check
      @prompter = prompter
    end

    def run(module_names)
      check_ports(module_names)
      check_github_token if module_names.include?("dev-tools")
      check_agent_token_file if module_names.include?("matron")
    end

    private

    attr_reader :config, :shell, :log

    def check_ports(module_names)
      problems = PortCheck.clashes(config)
      next_step = "change one of them in config.yml"
      if problems.empty?
        problems = PortCheck.busy(config, shell, module_names: module_names)
        next_step = "stop that program, or change the port in config.yml"
      end
      return if problems.empty?

      raise SetupError, ["Some ports can't be used:", *problems.map { |problem| "  - #{problem}" },
                         "Next step: #{next_step}, then re-run setup. Nothing has been changed yet."].join("\n")
    end

    def check_github_token
      token = config.github&.token.to_s
      return if token.empty?
      if github_already_logged_in?
        log.skip "GitHub CLI already logged in for #{username}; github.token is not used"
        return
      end

      result = @github_check.check(token)
      if result.unreachable
        log.warn "Could not check github.token: #{result.unreachable}"
        return
      end
      result.warnings.each { |warning| log.warn warning }
      return log.ok("github.token accepted by GitHub") if result.ok?

      lines = ["The GitHub token in #{secrets_location} was refused:"]
      lines.concat(result.problems.map { |problem| "  - #{problem}" })
      unless @interactive
        lines << "It needs to be:"
        lines.concat(GithubTokenCheck::NEEDS.map { |need| "  - #{need}" })
        lines << "Next step: put a working token in #{secrets_location}, or remove github.token to log in " \
                 "with a browser instead, then re-run setup. Nothing has been changed yet."
        raise SetupError, lines.join("\n")
      end

      lines.each { |line| log.warn line }
      token, = prompter.ask_checked_secret(
        "GitHub token (Enter to continue without one)", required: false,
        needs: GithubTokenCheck::NEEDS, checking: "Checking it with GitHub..."
      ) { |value| @github_check.check(value) }
      save_github_token(token)
    end

    def check_agent_token_file
      path = config.journal&.token_file.to_s
      return if path.empty? || !File.exist?(path)

      JournalEnrollment.new(config: config, shell: shell, log: log).ensure_readable_by_user!(path)
    end

    def github_already_logged_in?
      return false unless shell.user_exists?(username)
      shell.sh("su - #{Shellwords.escape(username)} -c 'gh auth status --hostname github.com >/dev/null 2>&1'")
    end

    # nil drops the token, so the dev-tools step logs in with a browser
    # when a private clone needs it.
    def save_github_token(token)
      (config.to_h["github"] ||= {})["token"] = token
      if token.nil?
        log.warn "Continuing without a GitHub token; a private clone will ask you to log in with a browser."
      end
      return unless @secrets_path && File.exist?(@secrets_path)

      Config.merge_into_file(@secrets_path, { "github" => { "token" => token } })
      log.ok(token ? "Saved the new GitHub token to #{@secrets_path}" : "Removed the refused token from #{@secrets_path}")
    end

    def secrets_location = "#{@secrets_path || "secrets.yml"} (github.token)"
    def username = config.user&.name.to_s
    def prompter = (@prompter ||= Wizard::Prompter.new(input: $stdin, output: $stdout))
  end
end
