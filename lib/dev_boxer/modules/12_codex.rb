require_relative "../components"
require "shellwords"

module DevBoxer
  module Modules
    # OpenAI's Codex CLI, alongside Claude Code, so a box arrives with both
    # coding agents available.
    #
    # Deliberately no credentials: each developer runs `codex login` once and
    # authenticates as themselves. The box does hold a shared OpenAI project
    # key (bridge.openai_api_key, used to title conversations), but pointing
    # Codex at it would bill every developer's usage to one key with no
    # attribution — a different purpose from the one it was issued for.
    class Codex < ModuleBase
      module_name  "codex"
      module_order 12

      PACKAGE = "@openai/codex".freeze

      def run
        section "Codex CLI"
        install_cli
        ok "Codex CLI ready — run `codex login` to sign in with your own account"
      end

      private

      # Installed globally as root, like the other npm-delivered tooling, so
      # every account on the box gets it rather than only the first user to
      # run setup. Node 22 arrives in 05_dev_tools, well before this module.
      def install_cli
        if config.setup&.profile == "starter"
          version = Components.tool_version("codex")
          return skip "Codex CLI #{version} already installed" if user_cli_version == version
          npm_root = shell.sh!("npm root -g").strip
          unless npm_root.start_with?("/") && npm_root.end_with?("/node_modules")
            raise SetupError, "Could not locate the global npm package directory."
          end
          # A root-only installation can report the right version to root.
          # Replace that package so its existing private modes cannot survive
          # npm's otherwise successful no-op. Do not touch account auth files.
          shell.sh!("npm uninstall -g #{PACKAGE}")
          scope = Shellwords.escape(File.join(npm_root, "@openai"))
          shell.sh!("umask 022 && install -d -m 0755 #{scope}")
          # Global packages must be executable by the account that runs the
          # agent, even when setup itself inherited a private umask.
          shell.sh!("umask 022 && npm install -g #{PACKAGE}@#{version}")
          unless user_cli_version == version
            raise SetupError, "Codex #{version} was installed, but #{config.user.name} cannot run that version. Check which codex comes first on that account's PATH."
          end
          return ok "Codex CLI #{version} installed"
        end
        if shell.command_exists?("codex")
          skip "Codex CLI already installed"
          return
        end
        info "Installing Codex CLI (#{PACKAGE})"
        shell.sh!("npm install -g #{PACKAGE}")
        ok "Codex CLI installed"
      end

      def user_cli_version
        shell.run_as_user(config.user.name, "codex --version").split.last
      rescue Shell::Error
        nil
      end
    end
  end
end
