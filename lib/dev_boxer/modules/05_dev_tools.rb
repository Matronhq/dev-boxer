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
    end
  end
end
