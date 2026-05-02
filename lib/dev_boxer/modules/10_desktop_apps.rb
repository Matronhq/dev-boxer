require "json"
require "net/http"
require "shellwords"
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

      MOTD_PATH = "/etc/update-motd.d/60-dev-boxer".freeze

      def run
        section "Final setup"
        install_lazydocker
        write_setup_scripts
        write_claude_md
        install_motd
        ok "Setup complete!"
        print_summary
      end

      private

      def username = config.user.name
      def home_dir = "/home/#{username}"
      def ssh_port = config.ssh&.port || 2222
      def setup_path = File.expand_path("../../../setup.rb", __dir__)
      def hostname_hello = config.cloudflare&.tunnel&.hostname_hello || fallback_hello_hostname
      def access_enabled? = config.cloudflare&.access&.enabled == true
      def fallback_hello_hostname
        zone_name = config.cloudflare&.zone_name
        zone_name.to_s.empty? ? nil : "hello.#{zone_name}"
      end

      def install_lazydocker
        if shell.command_exists?("lazydocker")
          skip "lazydocker already installed"
          return
        end
        info "Installing lazydocker"
        # Map dpkg's arch names to lazydocker's release-tag names.
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

      def desktop_environment_installed?
        shell.command_exists?("xfce4-terminal")
      end

      def write_setup_scripts
        script_path = "#{home_dir}/setup-desktop"
        shell.write_file(script_path, setup_desktop_script, mode: 0o755, owner: "#{username}:#{username}")
        ok "Optional setup scripts installed in #{home_dir}"
      end

      def setup_desktop_script
        <<~SH
          #!/bin/sh
          set -eu

          SETUP=#{Shellwords.escape(setup_path)}

          echo "Installing optional XFCE/XRDP desktop..."
          sudo "$SETUP" --only desktop

          echo "Desktop setup complete."
        SH
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
          "USERNAME"                => username,
          "SSH_PORT"                => ssh_port,
          "CF_HOSTNAME_MAIN"        => config.cloudflare&.tunnel&.hostname,
          "CF_HOSTNAME_MATRIX"      => config.cloudflare&.tunnel&.hostname_matrix,
          "CF_HOSTNAME_VIEWER"      => config.cloudflare&.tunnel&.hostname_viewer,
          "CF_HOSTNAME_HELLO"       => hostname_hello,
          "CF_ZONE_NAME"            => config.cloudflare&.zone_name,
          "USER_EXPERIENCE_GUIDANCE" => user_experience_guidance,
        }
      end

      def user_experience_guidance
        case claude_experience_level
        when "beginner"
          <<~TEXT.strip
            The user selected beginner mode.

            - Explain your plan in plain language before substantial changes.
            - Briefly explain commands before running them when the purpose may not be obvious.
            - Ask before choosing between meaningful technical options.
            - Summarize what changed, how it was verified, and what the user can try next.
          TEXT
        when "advanced"
          <<~TEXT.strip
            The user selected advanced mode.

            - Be concise and focus on diffs, tests, blockers, and tradeoffs.
            - Make reasonable implementation decisions from the surrounding code.
            - Ask only when a choice changes product behavior, cost, data, security, or deployment risk.
          TEXT
        else
          <<~TEXT.strip
            The user selected intermediate mode.

            - Keep explanations concise, but include enough context for non-obvious changes.
            - Proceed on routine implementation choices that match the existing project.
            - Ask when requirements are ambiguous or when there are meaningful tradeoffs.
            - Include verification steps and any remaining risks in the final summary.
          TEXT
        end
      end

      def claude_experience_level
        level = config.claude&.experience_level.to_s
        %w[beginner intermediate advanced].include?(level) ? level : "intermediate"
      end

      # Drop a small MOTD telling new SSH arrivals what's running and where
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
          │  Desktop:   ~/setup-desktop                                  │
          │  Setup log: /var/log/dev-boxer-setup.log                     │
          └──────────────────────────────────────────────────────────────┘

          EOF
        MOTD
        shell.write_file(MOTD_PATH, body, mode: 0o755)
        ok "MOTD installed (#{MOTD_PATH})"
      end

      def print_summary
        ip = server_ip
        info ""
        info "=== Connection details ==="
        info "SSH:  ssh #{username}@#{ip} -p #{ssh_port}"
        if desktop_environment_installed?
          info "RDP:  ssh -L 3389:localhost:3389 #{username}@#{ip} -p #{ssh_port}"
        else
          info "Desktop: optional; run ~/setup-desktop after SSH login"
        end
        info ""
        if config.cloudflare&.tunnel&.hostname
          info "Tunnel URLs:"
          info "  Main:    https://#{config.cloudflare.tunnel.hostname}"
          info "  Matrix:  https://#{config.cloudflare.tunnel.hostname_matrix}" if config.cloudflare.tunnel.hostname_matrix
          info "  Viewer:  https://#{config.cloudflare.tunnel.hostname_viewer}" if config.cloudflare.tunnel.hostname_viewer
          info "  Hello:   https://#{hostname_hello}" if hostname_hello
          info ""
        end
        if access_enabled?
          info "Cloudflare Access: configured for browser tunnel URLs; Matrix is excluded."
        else
          info "IMPORTANT: set up Cloudflare Access for zero-trust security. See docs/cloudflare-access.md."
        end
      end

      # Best-effort: take the first non-loopback IPv4/v6 from `hostname -I`.
      # Falls back to the placeholder `<server-ip>` if detection fails (e.g.
      # the binary is missing or returns no addresses) — better an obvious
      # placeholder than misleading output.
      def server_ip
        out = shell.sh!("hostname -I").strip rescue ""
        out.split(/\s+/).reject(&:empty?).first || "<server-ip>"
      end
    end
  end
end
