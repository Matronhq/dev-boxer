require "json"

module DevBoxer
  module Modules
    class Claude < ModuleBase
      module_name  "claude"
      module_order 7

      # Mirrors yearbook-infra PR #222's plugin list (15 plugins).
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

      def run
        section "Claude Code"
        install_cli
        ensure_local_bin_on_path
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

      # PR #222 fix: zsh's .zshrc isn't sourced for non-interactive `su - user -c '...'`
      # invocations, so without .zshenv the `claude` binary in ~/.local/bin is not
      # on PATH for subsequent `run_as_user` commands (plugins, marketplace, etc.).
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

      def write_settings
        claude_dir = "#{home_dir}/.claude"
        FileUtils.mkdir_p(claude_dir)
        path = "#{claude_dir}/settings.json"

        existing = File.exist?(path) ? JSON.parse(File.read(path)) : {}
        if existing["cleanupPeriodDays"] == 7
          skip "Claude settings.json already configured"
        else
          existing["cleanupPeriodDays"] = 7
          File.write(path, JSON.pretty_generate(existing) + "\n")
          File.chmod(0o600, path)
          ok "Claude settings.json written (cleanupPeriodDays: 7)"
        end
        shell.sh!("chown -R #{username}:#{username} #{claude_dir}")
      end

      # PR #222 fix: marketplace MUST be registered before any plugin install
      # — the CLI ships with none configured by default.
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
