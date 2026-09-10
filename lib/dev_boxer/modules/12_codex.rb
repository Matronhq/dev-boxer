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
