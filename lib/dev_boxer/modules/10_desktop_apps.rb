require "json"
require "net/http"
require "uri"

module DevBoxer
  module Modules
    class DesktopApps < ModuleBase
      module_name  "desktop-apps"
      module_order 10

      LAZYDOCKER_ARCH = {
        "amd64" => "x86_64",
        "arm64" => "arm64",
        "armhf" => "armv6",
      }.freeze

      SHORTCUTS = [
        ["VS Code",  "code",                  "visual-studio-code"],
        ["Firefox",  "firefox",               "firefox"],
        ["Chrome",   "google-chrome-stable",  "google-chrome"],
        ["Terminal", "xfce4-terminal",        "utilities-terminal"],
      ].freeze

      MOTD_PATH = "/etc/update-motd.d/60-dev-boxer".freeze

      def run
        section "Desktop apps & final setup"
        install_vscode
        install_github_desktop
        install_lazydocker
        write_desktop_shortcuts
        write_claude_md
        install_motd
        ok "Setup complete!"
        print_summary
      end

      private

      def username = config.user.name
      def home_dir = "/home/#{username}"
      def ssh_port = config.ssh&.port || 2222

      def install_vscode
        if shell.command_exists?("code")
          skip "VS Code already installed"
          return
        end
        info "Installing VS Code"
        shell.sh!(
          "curl -fsSL https://packages.microsoft.com/keys/microsoft.asc " \
          "| gpg --dearmor --yes -o /usr/share/keyrings/microsoft.gpg"
        )
        arch = shell.sh!("dpkg --print-architecture").strip
        repo = "deb [arch=#{arch} signed-by=/usr/share/keyrings/microsoft.gpg] " \
               "https://packages.microsoft.com/repos/code stable main\n"
        shell.write_file("/etc/apt/sources.list.d/vscode.list", repo)
        shell.apt_update
        shell.apt_install("code")
        ok "VS Code installed"
      end

      def install_github_desktop
        if shell.command_exists?("github-desktop")
          skip "GitHub Desktop already installed"
          return
        end
        info "Installing GitHub Desktop"
        shell.sh!(
          "curl -fsSL https://apt.packages.shiftkey.dev/gpg.key " \
          "| gpg --dearmor --yes -o /usr/share/keyrings/shiftkey-packages.gpg"
        )
        arch = shell.sh!("dpkg --print-architecture").strip
        repo = "deb [arch=#{arch} signed-by=/usr/share/keyrings/shiftkey-packages.gpg] " \
               "https://apt.packages.shiftkey.dev/ubuntu/ any main\n"
        shell.write_file("/etc/apt/sources.list.d/shiftkey-packages.list", repo)
        shell.apt_update
        shell.apt_install("github-desktop")
        ok "GitHub Desktop installed"
      end

      def install_lazydocker
        if shell.command_exists?("lazydocker")
          skip "lazydocker already installed"
          return
        end
        info "Installing lazydocker"
        # Detect arch the same way install_vscode and install_github_desktop
        # do, then map dpkg's arch names to lazydocker's release-tag names.
        # Hardcoding x86_64 broke ARM-based VPSes (e.g. Hetzner ARM, AWS Graviton).
        dpkg_arch = shell.sh!("dpkg --print-architecture").strip
        ld_arch = LAZYDOCKER_ARCH[dpkg_arch] ||
          raise("lazydocker has no known release for dpkg arch #{dpkg_arch.inspect}; install manually or skip via --skip desktop-apps")
        version = lazydocker_latest_version
        url = "https://github.com/jesseduffield/lazydocker/releases/download/" \
              "v#{version}/lazydocker_#{version}_Linux_#{ld_arch}.tar.gz"
        shell.sh!("curl -fsSL #{url} | tar xz -C /usr/local/bin lazydocker")
        ok "lazydocker installed (v#{version}, #{ld_arch})"
      end

      def lazydocker_latest_version
        uri = URI("https://api.github.com/repos/jesseduffield/lazydocker/releases/latest")
        resp = Net::HTTP.get(uri)
        JSON.parse(resp).fetch("tag_name").sub(/\Av/, "")
      end

      def write_desktop_shortcuts
        desktop_dir = "#{home_dir}/Desktop"
        FileUtils.mkdir_p(desktop_dir)
        SHORTCUTS.each do |name, exec, icon|
          path = "#{desktop_dir}/#{name}.desktop"
          File.write(path, <<~ENTRY)
            [Desktop Entry]
            Type=Application
            Name=#{name}
            Exec=#{exec}
            Icon=#{icon}
            Terminal=false
          ENTRY
          File.chmod(0o755, path)
        end
        shell.sh!("chown -R #{username}:#{username} #{desktop_dir}")
        ok "Desktop shortcuts created"
      end

      def write_claude_md
        info "Generating CLAUDE.md"
        claude_dir = "#{home_dir}/.claude"
        FileUtils.mkdir_p(claude_dir)
        render_template("CLAUDE.md.template", "#{claude_dir}/CLAUDE.md", claude_md_vars)
        shell.sh!("chown -R #{username}:#{username} #{claude_dir}")
        ok "CLAUDE.md generated"
      end

      def claude_md_vars
        {
          "USERNAME"          => username,
          "SSH_PORT"          => ssh_port,
          "CF_HOSTNAME_MAIN"  => config.cloudflare&.tunnel&.hostname,
          "CF_HOSTNAME_MATRIX"=> config.cloudflare&.tunnel&.hostname_matrix,
          "CF_HOSTNAME_VIEWER"=> config.cloudflare&.tunnel&.hostname_viewer,
        }
      end

      # Drop a small MOTD telling new SSH/RDP arrivals what's running and where
      # to look.
      def install_motd
        body = <<~MOTD
          #!/bin/bash
          cat <<'EOF'

          ┌──────────────────────────────────────────────────────────────┐
          │  Dev Boxer — remote Claude Code dev environment              │
          ├──────────────────────────────────────────────────────────────┤
          │  Logs:      journalctl -u claude-matrix-bridge -f            │
          │  Restart:   sudo systemctl restart claude-matrix-bridge      │
          │  Bridge:    cd ~/claude-matrix-bridge                        │
          │  Setup log: /var/log/dev-boxer-setup.log                     │
          └──────────────────────────────────────────────────────────────┘

          EOF
        MOTD
        shell.write_file(MOTD_PATH, body, mode: 0o755)
        ok "MOTD installed (#{MOTD_PATH})"
      end

      def print_summary
        info ""
        info "=== Connection details ==="
        info "SSH:  ssh #{username}@<server-ip> -p #{ssh_port}"
        info "RDP:  ssh -L 3389:localhost:3389 #{username}@<server-ip> -p #{ssh_port}"
        info ""
        if config.cloudflare&.tunnel&.hostname
          info "Tunnel URLs:"
          info "  Main:    https://#{config.cloudflare.tunnel.hostname}"
          info "  Matrix:  https://#{config.cloudflare.tunnel.hostname_matrix}" if config.cloudflare.tunnel.hostname_matrix
          info "  Viewer:  https://#{config.cloudflare.tunnel.hostname_viewer}" if config.cloudflare.tunnel.hostname_viewer
          info ""
        end
        info "Matrix bridge:"
        info "  1. Open Element/Matron, set homeserver to https://#{config.cloudflare&.tunnel&.hostname_matrix || 'your-matrix-hostname'}"
        info "  2. Log in as @#{config.matrix&.user_username || 'your-username'}:#{config.matrix&.server_domain || 'your-domain'}"
        info "  3. Open the 'Claude Code Bridge' room and send !start"
        info ""
        info "IMPORTANT: set up Cloudflare Access for zero-trust security. See docs/cloudflare-access.md."
      end
    end
  end
end
