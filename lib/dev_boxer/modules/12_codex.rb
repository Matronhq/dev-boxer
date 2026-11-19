require_relative "../components"

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
        shell.run_as_user(config.user.name, "codex --version") if config.setup&.profile == "starter"
        ok "Codex CLI ready — run `codex login` to sign in with your own account"
      end

      private

      # Installed globally as root, like the other npm-delivered tooling, so
      # every account on the box gets it rather than only the first user to
      # run setup. Node 22 arrives in 05_dev_tools, well before this module.
      def install_cli
        if config.setup&.profile == "starter"
          version = Components.tool_version("codex")
          return skip "Codex CLI #{version} already installed" if shell.command_exists?("codex") && shell.sh!("codex --version").split.last == version
          # Global packages must be executable by the account that runs the
          # agent, even when setup itself inherited a private umask.
          shell.sh!("umask 022 && npm install -g #{PACKAGE}@#{version}")
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
    end
  end
end
