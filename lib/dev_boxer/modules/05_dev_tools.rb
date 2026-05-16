require "shellwords"

module DevBoxer
  module Modules
    class DevTools < ModuleBase
      module_name  "dev-tools"
      module_order 5

      BASE_PACKAGES = %w[
        git build-essential make cmake htop jq unzip wget curl tree
      ].freeze

      def run
        section "Development tools"
        install_base_packages
        install_node
        install_python
        install_uv
        install_github_cli
        configure_github_auth_for_user
        ok "Development tools setup complete"
      end

      private

      def username = config.user.name

      def install_base_packages
        info "Installing base development packages"
        shell.apt_install(*BASE_PACKAGES)
        ok "Base packages installed"
      end

      def install_node
        if shell.command_exists?("node") && shell.sh!("node --version").include?("v22")
          skip "Node.js 22 already installed"
          return
        end
        info "Installing Node.js 22 LTS"
        shell.sh!("curl -fsSL https://deb.nodesource.com/setup_22.x | bash -")
        shell.apt_install("nodejs")
        ok "Node.js installed"
      end

      def install_python
        unless shell.command_exists?("python3")
          shell.apt_install("python3")
        end
        shell.apt_install("python3-pip", "python3-venv")
        ok "Python 3 + pip ready"
      end

      def install_uv
        if shell.sh("su - #{username} -c 'command -v uv'")
          skip "uv already installed"
          return
        end
        info "Installing uv"
        shell.run_as_user(username, "curl -LsSf https://astral.sh/uv/install.sh | sh")
        ok "uv installed"
      end

      def install_github_cli
        if shell.command_exists?("gh")
          skip "GitHub CLI already installed"
          return
        end
        info "Installing GitHub CLI"
        shell.sh!(
          "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg " \
          "| dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg"
        )
        shell.sh!("chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg")

        arch = shell.sh!("dpkg --print-architecture").strip
        repo = "deb [arch=#{arch} signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] " \
               "https://cli.github.com/packages stable main\n"
        shell.write_file("/etc/apt/sources.list.d/github-cli.list", repo)

        shell.apt_update
        shell.apt_install("gh")
        ok "GitHub CLI installed"
      end

      # Configure `gh` + git's credential helper for the dev user using the PAT
      # the operator pasted into the wizard. This avoids the mid-setup pause in
      # 08_matrix_bridge that would otherwise trigger an interactive
      # `gh auth login --web` because the dev user has no GitHub credentials
      # of its own. With this configured, all subsequent `git clone` calls as
      # the dev user against private repos in the PAT's scope just work.
      def configure_github_auth_for_user
        token = config.github&.token
        if token.to_s.empty?
          info "No github.token in secrets.yml; private clones as #{username} will prompt via `gh auth login --web` if needed"
          return
        end

        if shell.sh("su - #{Shellwords.escape(username)} -c 'gh auth status --hostname github.com >/dev/null 2>&1'")
          skip "GitHub CLI already authenticated for #{username}"
          return
        end

        info "Configuring GitHub CLI auth for #{username} from secrets.yml"
        # Pass the token via stdin so it never appears on the command line
        # (and so shell-special characters in tokens can't break the call).
        shell.sh!(
          "su - #{Shellwords.escape(username)} -c 'gh auth login --with-token --hostname github.com'",
          stdin: token,
        )
        shell.run_as_user(username, "gh auth setup-git --hostname github.com")
        ok "GitHub CLI authenticated for #{username}"
      end
    end
  end
end
