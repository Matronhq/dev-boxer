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
        create_tunnel
        create_dns_routes
        deploy_tunnel_config
        install_systemd_unit
        write_user_credentials
        cleanup_admin_token
        ok "Cloudflare Tunnel setup complete"
        print_hostnames
      end

      private

      def username = config.user.name
      def home_dir = "/home/#{username}"
      def admin_token = config.cloudflare&.api_token
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

        # `unless admin_token` is truthy for "" — guard against the empty
        # string explicitly so callers get the clear error rather than a
        # confusing cloudflared shell failure.
        if admin_token.nil? || admin_token.to_s.empty?
          raise "No cloudflare.tunnel.id and no cloudflare.api_token in config — cannot create tunnel"
        end

        info "Creating Cloudflare tunnel"
        tunnel_name = "dev-boxer-#{shell.sh!('hostname -s').strip}"
        # Set TUNNEL_API_TOKEN in the process env, not just inline on the
        # `tunnel create` line, so subsequent cloudflared subprocesses
        # (DNS route creation) inherit it.
        ENV["TUNNEL_API_TOKEN"] = admin_token
        shell.sh!(
          "cloudflared tunnel create #{tunnel_name} " \
          "--credentials-file /etc/cloudflared/credentials.json -o json",
        )

        unless File.exist?("/etc/cloudflared/credentials.json")
          raise "Tunnel creation reported success but credentials.json missing"
        end

        new_id = JSON.parse(File.read("/etc/cloudflared/credentials.json"))["TunnelID"]
        raise "Could not extract TunnelID from credentials.json" unless new_id

        ok "Tunnel created: #{tunnel_name} (id: #{new_id})"
        persist_tunnel_id(new_id)
      end

      # Use Config.merge_into_file rather than appending raw lines —
      # appending a duplicate top-level `cloudflare:` key would silently
      # destroy enabled / account_id / zone_id / tunnel.hostname etc. on
      # the next YAML.safe_load_file.
      def persist_tunnel_id(id)
        path = File.expand_path("../../../config.yml", __dir__)
        return unless File.exist?(path)
        Config.merge_into_file(path, { "cloudflare" => { "tunnel" => { "id" => id } } })
      end

      def create_dns_routes
        return unless current_tunnel_id
        info "Setting up DNS routes"
        configured_hostnames.each do |host|
          # Use sh! so a failed route creation actually raises — the previous
          # `sh` swallowed the failure and the `ok` log lied about success.
          shell.sh!("cloudflared tunnel route dns --overwrite-dns #{Shellwords.escape(current_tunnel_id)} #{Shellwords.escape(host)}")
          ok "DNS route: #{host} → tunnel"
        end
      end

      # Gather the hostnames actually configured by the operator. Excludes
      # nil and empty strings so the cloudflared-config.yml template doesn't
      # render ingress rules for hostnames that resolve nowhere.
      def configured_hostnames
        [tunnel_hostname, hostname_matrix, hostname_viewer].compact.reject(&:empty?)
      end

      def current_tunnel_id
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
        if present?(hostname_matrix)
          rules << "  - hostname: #{hostname_matrix}\n    service: http://localhost:6167"
        end
        if present?(hostname_viewer)
          rules << "  - hostname: #{hostname_viewer}\n    service: http://localhost:9801"
        end
        if present?(tunnel_hostname)
          rules << "  - hostname: #{tunnel_hostname}\n    service: https://localhost\n    originRequest:\n      noTLSVerify: true"
        end
        rules << "  - service: http_status:404"
        rules.join("\n")
      end

      def present?(s)
        s && !s.to_s.empty?
      end

      def install_systemd_unit
        FileUtils.cp(template_path("cloudflared-tunnel.service"), "/etc/systemd/system/cloudflared-tunnel.service")
        shell.sh!("systemctl daemon-reload")
        shell.systemctl(:enable, "cloudflared-tunnel")
        shell.systemctl(:restart, "cloudflared-tunnel")
        ok "cloudflared service installed and started"
      end

      # PR #222's cloudflare_credentials: deploy a per-user zone-scoped API
      # token + zone id under ~/.cloudflare/ so user-level tools (certbot DNS
      # challenge, custom scripts) have direct access without leaking the
      # admin tunnel-creation token.
      def write_user_credentials
        zone_token = config.cloudflare&.zone_api_token
        zone_id    = config.cloudflare&.zone_id
        # Empty strings are truthy in Ruby — explicitly reject them so we
        # don't deploy empty credential files when YAML has `zone_api_token: ""`.
        if zone_token.nil? || zone_token.to_s.empty? || zone_id.nil? || zone_id.to_s.empty?
          skip "Skipping ~/.cloudflare credentials (zone_api_token + zone_id not set)"
          return
        end

        dir = "#{home_dir}/.cloudflare"
        FileUtils.mkdir_p(dir)
        File.chmod(0o700, dir)

        write_user_file("#{dir}/token",   zone_token)
        write_user_file("#{dir}/zone_id", zone_id)
        shell.sh!("chown -R #{username}:#{username} #{dir}")
        ok "~/.cloudflare credentials deployed (zone-scoped)"
      end

      def write_user_file(path, content)
        File.write(path, content)
        File.chmod(0o600, path)
      end

      # The admin API token is needed once to create the tunnel; after that,
      # cloudflared authenticates with the tunnel-specific credentials.json.
      # Strip it from config.yml so a stolen config can't recreate tunnels.
      # Done as a structured YAML write (not regex over the raw text) so
      # we don't accidentally clobber an `api_token:` key in some other
      # section now or in the future.
      def cleanup_admin_token
        return unless admin_token
        # Wipe from process env first so subsequent modules' subprocesses
        # don't inherit the admin token. (We set ENV["TUNNEL_API_TOKEN"] in
        # create_tunnel so DNS-route subprocesses inherit auth; that's done
        # by the time cleanup_admin_token runs.)
        ENV.delete("TUNNEL_API_TOKEN")

        path = File.expand_path("../../../config.yml", __dir__)
        return unless File.exist?(path)
        cf = (YAML.safe_load_file(path) || {})["cloudflare"]
        return unless cf && cf["api_token"] && !cf["api_token"].to_s.empty?
        Config.merge_into_file(path, { "cloudflare" => { "api_token" => "" } })
        ok "Admin Cloudflare API token removed from config.yml + process env"
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
