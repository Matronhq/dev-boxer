require "json"

module DevBoxer
  module Modules
    class Claude < ModuleBase
      module_name  "claude"
      module_order 7

      DEFAULT_PLUGINS = %w[
        claude-code-setup
        claude-md-management
        code-review
        code-simplifier
        context7
        feature-dev
        figma
        frontend-design
        github
        greptile
        ralph-loop
        security-guidance
        serena
        superpowers
        typescript-lsp
      ].freeze

      MARKETPLACE = "anthropics/claude-plugins-official".freeze

      # PreToolUse hook that stops history-wide git searches (git log -S,
      # git blame, ...) in partial clones, where each one downloads every
      # old file version it touches and can fill the disk.
      GUARD_HOOK = "partial-clone-guard.py".freeze

      def run
        section "Claude Code"
        install_cli
        ensure_local_bin_on_path
        install_guard_hook
        write_settings
        register_marketplace
        install_plugins
        install_chrome_devtools_mcp
        ok "Claude Code setup complete"
      end

      private

      def username = config.user.name
      def home_dir = "/home/#{username}"

      def claude_installed?
        File.exist?("#{home_dir}/.local/bin/claude")
      end

      def install_cli
        if claude_installed?
          skip "Claude Code CLI already installed"
          return
        end
        info "Installing Claude Code CLI"
        shell.run_as_user(username, "curl -fsSL https://claude.ai/install.sh | bash")
        ok "Claude Code CLI installed"
      end

      # zsh's .zshrc isn't sourced for non-interactive `su - user -c '...'`
      # invocations, so .zshenv also needs the Claude binary on PATH.
      def ensure_local_bin_on_path
        line = 'export PATH="$HOME/.local/bin:$PATH"'
        %w[.bashrc .zshrc .zshenv].each do |rc|
          path = "#{home_dir}/#{rc}"
          existing = File.exist?(path) ? File.read(path) : ""
          next if existing.include?(".local/bin")
          File.open(path, "a") { |f| f.puts line }
          shell.sh!("chown #{username}:#{username} #{path}")
        end
        ok "~/.local/bin on PATH for bash + zsh (interactive + non-interactive)"
      end

      def guard_hook_path = "#{home_dir}/.claude/hooks/#{GUARD_HOOK}"

      # Copied on every run, so a changed hook reaches boxes set up earlier.
      def install_guard_hook
        FileUtils.mkdir_p(File.dirname(guard_hook_path))
        FileUtils.cp(template_path("claude-hooks/#{GUARD_HOOK}"), guard_hook_path)
        File.chmod(0o755, guard_hook_path)
        ok "Partial-clone guard hook installed"
      end

      def write_settings
        claude_dir = "#{home_dir}/.claude"
        FileUtils.mkdir_p(claude_dir)
        path = "#{claude_dir}/settings.json"

        existing = File.exist?(path) ? JSON.parse(File.read(path)) : {}
        changed = false
        unless existing["cleanupPeriodDays"] == 7
          existing["cleanupPeriodDays"] = 7
          changed = true
        end
        changed = true if add_guard_hook(existing)

        if changed
          File.write(path, JSON.pretty_generate(existing) + "\n")
          File.chmod(0o600, path)
          ok "Claude settings.json written (cleanupPeriodDays: 7, partial-clone guard)"
        else
          skip "Claude settings.json already configured"
        end
        shell.sh!("chown -R #{username}:#{username} #{claude_dir}")
      end

      # Adds the guard to settings' PreToolUse hooks unless an entry already
      # runs it. Leaves every other hook alone. Returns true if it changed.
      def add_guard_hook(settings)
        pre_tool_use = ((settings["hooks"] ||= {})["PreToolUse"] ||= [])
        present = pre_tool_use.any? do |entry|
          Array(entry["hooks"]).any? { |h| h["command"].to_s.include?(GUARD_HOOK) }
        end
        return false if present

        pre_tool_use << {
          "matcher" => "Bash",
          "hooks" => [{ "type" => "command", "command" => "python3 #{guard_hook_path}", "timeout" => 10 }],
        }
        true
      end

      # The marketplace must be registered before plugin install because the
      # CLI ships with none configured by default.
      def register_marketplace
        if shell.sh("su - #{username} -c 'claude plugin marketplace list 2>/dev/null' | grep -q claude-plugins-official")
          skip "Anthropic plugins marketplace already registered"
          return
        end
        info "Registering Anthropic plugins marketplace"
        shell.run_as_user(username, "claude plugin marketplace add #{MARKETPLACE}")
        ok "Marketplace #{MARKETPLACE} registered"
      end

      def install_plugins
        plugins = config.claude&.plugins || DEFAULT_PLUGINS
        info "Installing Claude plugins"
        # One subprocess instead of two — the previous implementation ran
        # `claude plugin list` once via shell.sh (boolean only) then again
        # via shell.sh! (capture). Use a single sh! and rescue if the CLI
        # fails (e.g. on first run when no plugins are installed).
        installed = begin
          shell.sh!("su - #{username} -c 'claude plugin list 2>/dev/null'")
        rescue Shell::Error
          ""
        end
        plugins.each do |p|
          if installed.include?("#{p}@claude-plugins-official")
            skip "Plugin #{p} already installed"
          else
            shell.run_as_user(username, "claude plugin install #{p}@claude-plugins-official")
            ok "Plugin #{p} installed"
          end
        end
      end

      def install_chrome_devtools_mcp
        install_chrome_devtools_npm_pkg
        register_chrome_devtools_mcp_server
      end

      def install_chrome_devtools_npm_pkg
        if shell.sh("npm ls -g chrome-devtools-mcp 2>/dev/null | grep -q chrome-devtools-mcp")
          skip "Chrome DevTools MCP npm package already installed"
          return
        end
        info "Installing Chrome DevTools MCP"
        shell.sh!("npm install -g chrome-devtools-mcp")
        ok "Chrome DevTools MCP installed"
      end

      # Independent of the npm install — the previous version returned early
      # if the package was already installed, leaving the MCP server unregistered
      # if a previous run was interrupted between the two steps.
      def register_chrome_devtools_mcp_server
        unless shell.command_exists?("google-chrome-stable")
          warn "Chrome not installed (no arm64 build); skipping chrome-devtools MCP registration"
          return
        end
        if shell.sh("su - #{username} -c 'claude mcp list 2>/dev/null' | grep -q chrome-devtools")
          skip "chrome-devtools MCP server already registered"
          return
        end
        shell.run_as_user(
          username,
          'claude mcp add chrome-devtools -- xvfb-run --auto-servernum ' \
          '--server-args="-screen 0 1920x1080x24" npx -y chrome-devtools-mcp ' \
          '--no-usage-statistics --acceptInsecureCerts ' \
          '--chromeArg=--no-sandbox --chromeArg=--disable-setuid-sandbox ' \
          '--viewport=1920x1080',
        )
        ok "chrome-devtools MCP server registered"
      end
    end
  end
end
