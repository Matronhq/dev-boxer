require "json"
require "shellwords"
require "yaml"

module DevBoxer
  module Modules
    class Cloudflare < ModuleBase
      module_name  "cloudflare"
      module_order 9

      def run
        section "Cloudflare Tunnel"

        unless config.cloudflare&.enabled
          skip "Cloudflare disabled in config"
          return
        end

        install_cloudflared
        begin
          create_tunnel
          create_dns_routes
        ensure
          ENV.delete("TUNNEL_API_TOKEN")
        end
        deploy_tunnel_config
        install_systemd_unit
        write_user_credentials
        cleanup_setup_token
        ok "Cloudflare Tunnel setup complete"
        print_hostnames
      end

      private

      def username = config.user.name
      def home_dir = "/home/#{username}"
      def setup_token = config.cloudflare&.api_token
      def zone_token = config.cloudflare&.zone_api_token
      def tunnel_id = config.cloudflare&.tunnel&.id
      def tunnel_hostname = config.cloudflare&.tunnel&.hostname
      def hostname_matrix = config.cloudflare&.tunnel&.hostname_matrix
      def hostname_viewer = config.cloudflare&.tunnel&.hostname_viewer
      def config_managed_locally? = config.cloudflare&.tunnel&.config_managed_locally

      def install_cloudflared
        if shell.command_exists?("cloudflared")
          skip "cloudflared already installed"
          return
        end
        info "Installing cloudflared"
        shell.sh!(
          "curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg " \
          "| gpg --dearmor --yes -o /usr/share/keyrings/cloudflare-main.gpg"
        )
        codename = shell.sh!(". /etc/os-release && echo $VERSION_CODENAME").strip
        repo = "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] " \
               "https://pkg.cloudflare.com/cloudflared #{codename} main\n"
        shell.write_file("/etc/apt/sources.list.d/cloudflared.list", repo)
        shell.apt_update
        shell.apt_install("cloudflared")
        ok "cloudflared installed"
      end

      def create_tunnel
        FileUtils.mkdir_p("/etc/cloudflared")

        if tunnel_id
          skip "Tunnel already exists (id: #{tunnel_id})"
          return
        end

        if setup_token.nil? || setup_token.to_s.empty?
          prompt_for_manual_tunnel_setup
          return
        end

        info "Creating Cloudflare tunnel"
        tunnel_name = "dev-boxer-#{shell.sh!('hostname -s').strip}"
        # cloudflared reads TUNNEL_API_TOKEN from the process environment for
        # tunnel creation; the value is cleared before later modules run.
        ENV["TUNNEL_API_TOKEN"] = setup_token
        shell.sh!(
          "cloudflared tunnel create #{Shellwords.escape(tunnel_name)} " \
          "--credentials-file /etc/cloudflared/credentials.json -o json",
        )

        unless File.exist?("/etc/cloudflared/credentials.json")
          raise "Tunnel creation reported success but credentials.json missing"
        end

        new_id = JSON.parse(File.read("/etc/cloudflared/credentials.json"))["TunnelID"]
        raise "Could not extract TunnelID from credentials.json" unless new_id

        ok "Tunnel created: #{tunnel_name} (id: #{new_id})"
        persist_tunnel_id(new_id)
        # NB: cleanup_setup_token is intentionally NOT called here. The
        # token must remain in config until create_dns_routes succeeds —
        # otherwise a network failure between tunnel creation and DNS
        # route creation would leave DNS setup permanently un-retryable
        # (the `setup_token` accessor reads from disk, and the file no
        # longer has it). `run()` calls cleanup_setup_token only after
        # both create_tunnel AND create_dns_routes complete successfully.
      end

      # Use Config.merge_into_file rather than appending raw lines —
      # appending a duplicate top-level `cloudflare:` key would silently
      # destroy enabled / tunnel.hostname etc. on
      # the next YAML.safe_load_file.
      def persist_tunnel_id(id)
        @current_tunnel_id = id
        return unless config_path && File.exist?(config_path)
        Config.merge_into_file(config_path, { "cloudflare" => { "tunnel" => { "id" => id } } })
      end

      def create_dns_routes
        return unless current_tunnel_id
        # `cloudflared tunnel route dns` requires Account-level Cloudflare
        # Tunnel:Edit permission — the same token that created the tunnel
        # (setup_token), NOT the zone-scoped DNS token. Using zone_token
        # here was failing silently because the token lacks the required
        # account-level permission.
        if setup_token.nil? || setup_token.to_s.empty?
          skip "Skipping DNS route creation (no setup token; routes should already exist from a prior run)"
          return
        end
        ENV["TUNNEL_API_TOKEN"] = setup_token
        info "Setting up DNS routes"
        configured_hostnames.each do |host|
          # Use sh! so a failed route creation actually raises, surfacing
          # cloudflared's error rather than silently logging "ok".
          shell.sh!(
            "cloudflared tunnel route dns --overwrite-dns " \
            "#{Shellwords.escape(current_tunnel_id)} #{Shellwords.escape(host)}"
          )
          ok "DNS route: #{host} → tunnel"
        end
      end

      # Hostnames the operator configured. Excludes nil and empty strings so
      # the cloudflared-config.yml template doesn't render `hostname: `
      # (literal empty value) — which is invalid YAML and breaks tunnel boot.
      def configured_hostnames
        [tunnel_hostname, hostname_matrix, hostname_viewer].compact.reject { |h| h.to_s.empty? }
      end

      def prompt_for_manual_tunnel_setup
        unless $stdin.tty?
          raise "No cloudflare.tunnel.id and no one-time cloudflare.api_token; run interactively for manual tunnel setup"
        end

        tunnel_name = "dev-boxer-#{shell.sh!('hostname -s').strip}"
        info ""
        info "Manual Cloudflare tunnel setup required."
        info "Create a temporary Cloudflare API token with Account > Cloudflare Tunnel:Edit."
        info "Do not save that token in config.yml or secrets.yml."
        info ""
        info "In another root shell on this VPS, run:"
        info "  export TUNNEL_API_TOKEN=<temporary-token>"
        info "  cloudflared tunnel create #{Shellwords.escape(tunnel_name)} --credentials-file /etc/cloudflared/credentials.json -o json"
        info "  unset TUNNEL_API_TOKEN"
        info ""
        info "Then paste the TunnelID below. Dev Boxer will persist only the tunnel ID."

        manual_tunnel_id = nil
        loop do
          print "Cloudflare TunnelID: "
          manual_tunnel_id = $stdin.gets.to_s.strip
          break unless manual_tunnel_id.empty?
          info "TunnelID is required."
        end

        unless File.exist?("/etc/cloudflared/credentials.json")
          raise "Manual tunnel credentials not found at /etc/cloudflared/credentials.json"
        end

        persist_tunnel_id(manual_tunnel_id)
        ok "Manual tunnel registered: #{manual_tunnel_id}"
      end

      def current_tunnel_id
        return @current_tunnel_id if @current_tunnel_id
        return tunnel_id if tunnel_id
        return nil unless File.exist?("/etc/cloudflared/credentials.json")
        JSON.parse(File.read("/etc/cloudflared/credentials.json"))["TunnelID"]
      rescue StandardError
        nil
      end

      def deploy_tunnel_config
        path = "/etc/cloudflared/config.yml"
        if config_managed_locally? && File.exist?(path)
          skip "Tunnel config managed locally, leaving #{path} untouched"
          return
        end
        info "Deploying tunnel config"
        render_template("cloudflared-config.yml", path, tunnel_template_vars)
        ok "Tunnel config deployed"
      end

      def tunnel_template_vars
        {
          "CLOUDFLARE_TUNNEL_ID" => current_tunnel_id,
          "INGRESS"              => render_ingress,
        }
      end

      # Build the cloudflared ingress list from whichever hostnames the
      # operator configured. Skipping unset hostnames prevents rendering
      # `hostname: ` (literal empty value) which is invalid YAML and
      # would break the tunnel on startup.
      def render_ingress
        rules = []
        if !hostname_matrix.to_s.empty?
          rules << "  - hostname: #{hostname_matrix}\n    service: http://localhost:6167"
        end
        if !hostname_viewer.to_s.empty?
          rules << "  - hostname: #{hostname_viewer}\n    service: http://localhost:9801"
        end
        if !tunnel_hostname.to_s.empty?
          rules << "  - hostname: #{tunnel_hostname}\n    service: https://localhost\n    originRequest:\n      noTLSVerify: true"
        end
        rules << "  - service: http_status:404"
        rules.join("\n")
      end

      def install_systemd_unit
        FileUtils.cp(template_path("cloudflared-tunnel.service"), "/etc/systemd/system/cloudflared-tunnel.service")
        shell.sh!("systemctl daemon-reload")
        shell.systemctl(:enable, "cloudflared-tunnel")
        shell.systemctl(:restart, "cloudflared-tunnel")
        ok "cloudflared service installed and started"
      end

      # Deploy a per-user zone-scoped API token under ~/.cloudflare/ so
      # user-level tools (certbot DNS challenge, custom scripts) have access
      # without leaking the setup tunnel-creation token.
      def write_user_credentials
        if zone_token.nil? || zone_token.to_s.empty?
          skip "Skipping ~/.cloudflare credentials (zone_api_token not set)"
          return
        end

        dir = "#{home_dir}/.cloudflare"
        FileUtils.mkdir_p(dir)
        File.chmod(0o700, dir)

        write_user_file("#{dir}/token", zone_token)
        shell.sh!("chown -R #{username}:#{username} #{dir}")
        ok "~/.cloudflare token deployed (zone-scoped)"
      end

      # Tighten umask before File.write so the zone API token is never
      # briefly world-readable between create-time (default umask, 0o644)
      # and File.chmod. Mirrors MatrixBridge#write_secret_file.
      def write_user_file(path, content)
        old_umask = File.umask(0o077)
        begin
          File.write(path, content)
        ensure
          File.umask(old_umask)
        end
        File.chmod(0o600, path)
      end

      # The setup API token is needed once to create the tunnel; after that,
      # cloudflared authenticates with the tunnel-specific credentials.json.
      # Strip it from config.yml so a stolen config can't recreate tunnels.
      # Done as a structured YAML write (not regex over the raw text) so
      # we don't accidentally clobber an `api_token:` key in some other
      # section now or in the future.
      def cleanup_setup_token
        return unless setup_token
        removed = [config_path, secrets_path].compact.uniq.map do |path|
          clear_setup_token(path)
        end.any?
        ok "Cloudflare setup API token removed from config" if removed
      end

      def clear_setup_token(path)
        return false unless File.exist?(path)
        data = YAML.safe_load_file(path) || {}
        cf = data["cloudflare"]
        return false unless cf && cf["api_token"] && !cf["api_token"].to_s.empty?
        cf.delete("api_token")
        write_yaml_preserving_mode(path, data)
        true
      end

      def write_yaml_preserving_mode(path, data)
        mode = File.stat(path).mode & 0o777
        old_umask = mode == 0o600 ? File.umask(0o077) : nil
        begin
          File.write(path, data.to_yaml)
        ensure
          File.umask(old_umask) if old_umask
        end
        File.chmod(mode, path)
      end

      def print_hostnames
        info "Main:    https://#{tunnel_hostname}"        if tunnel_hostname
        info "Matrix:  https://#{hostname_matrix}"        if hostname_matrix
        info "Viewer:  https://#{hostname_viewer}"        if hostname_viewer
        info "IMPORTANT: set up Cloudflare Access for zero-trust security. See docs/cloudflare-access.md."
      end
    end
  end
end
