require "json"
require "net/http"
require "shellwords"
require "uri"
require "yaml"

module DevBoxer
  module Modules
    class Cloudflare < ModuleBase
      module_name  "cloudflare"
      module_order 9
      API_BASE = "https://api.cloudflare.com/client/v4".freeze
      CREDENTIALS_PATH = "/etc/cloudflared/credentials.json".freeze

      def run
        section "Cloudflare Tunnel"

        unless config.cloudflare&.enabled
          skip "Cloudflare disabled in config"
          return
        end

        install_cloudflared
        create_tunnel
        create_dns_routes
        configure_cloudflare_access
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
      def zone_name = config.cloudflare&.zone_name
      def dns_managed_manually? = config.cloudflare&.dns&.create_manually == true
      def tunnel_managed_manually? = config.cloudflare&.tunnel&.create_manually == true
      def tunnel_id = config.cloudflare&.tunnel&.id
      def tunnel_hostname = config.cloudflare&.tunnel&.hostname
      def hostname_matrix = config.cloudflare&.tunnel&.hostname_matrix
      def hostname_viewer = config.cloudflare&.tunnel&.hostname_viewer
      def hostname_hello = cloudflare_hello_hostname
      def config_managed_locally? = config.cloudflare&.tunnel&.config_managed_locally
      def access_config = config.cloudflare&.access
      def access_enabled? = access_config&.enabled == true
      def cloudflare_account_id = config.cloudflare&.account_id || access_config&.account_id || (zone_token.to_s.empty? ? nil : cloudflare_zone_account_id)
      def access_account_id = cloudflare_account_id
      def access_app_id = access_config&.app_id
      def access_app_name = access_config&.app_name || "Dev Boxer"
      def access_session_duration = access_config&.session_duration || "24h"
      def credentials_path = CREDENTIALS_PATH

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
        FileUtils.mkdir_p(File.dirname(credentials_path))

        if tunnel_id
          skip "Tunnel already exists (id: #{tunnel_id})"
          return
        end

        if tunnel_managed_manually?
          prompt_for_manual_tunnel_setup
          return
        end

        if setup_token.nil? || setup_token.to_s.empty?
          prompt_for_manual_tunnel_setup
          return
        end

        info "Creating Cloudflare tunnel"
        tunnel_name = "dev-boxer-#{shell.sh!('hostname -s').strip}"
        result = create_tunnel_via_api(tunnel_name)
        credentials = result["credentials_file"]
        raise "Cloudflare API did not return tunnel credentials" unless credentials.is_a?(Hash)

        write_tunnel_credentials(credentials)

        new_id = result["id"] || credentials["TunnelID"]
        raise "Could not extract TunnelID from #{credentials_path}" unless new_id

        ok "Tunnel created: #{tunnel_name} (id: #{new_id})"
        persist_tunnel_id(new_id)
        # NB: cleanup_setup_token is intentionally NOT called here. `run()`
        # removes it only after DNS and optional Access setup complete, so a
        # partial first run remains easy to retry.
      end

      def create_tunnel_via_api(tunnel_name)
        account_id = cloudflare_account_id
        raise "Cloudflare account ID could not be derived from zone #{zone_name.inspect}; set cloudflare.access.account_id" if account_id.to_s.empty?

        cloudflare_api(
          token: setup_token,
          method: :post,
          path: "/accounts/#{account_id}/cfd_tunnel",
          body: {
            "name" => tunnel_name,
            "config_src" => "local",
          },
        )
      end

      def write_tunnel_credentials(credentials)
        FileUtils.mkdir_p(File.dirname(credentials_path))
        old_umask = File.umask(0o077)
        begin
          File.write(credentials_path, JSON.pretty_generate(credentials) + "\n")
        ensure
          File.umask(old_umask)
        end
        File.chmod(0o600, credentials_path)
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

        if zone_token.nil? || zone_token.to_s.empty?
          print_manual_dns_instructions("#{current_tunnel_id}.cfargotunnel.com")
          return
        end

        info "Setting up DNS routes"
        zone_id = cloudflare_zone_id
        target = "#{current_tunnel_id}.cfargotunnel.com"
        configured_hostnames.each do |host|
          case upsert_tunnel_dns_record(zone_id, host, target)
          when :created
            ok "DNS route created: #{host} → tunnel"
          when :updated
            ok "DNS route updated: #{host} → tunnel"
          when :unchanged
            skip "DNS route already configured: #{host}"
          when :skipped
            warn "Skipped DNS route update for #{host}"
          end
        end
      end

      def print_manual_dns_instructions(target)
        if dns_managed_manually?
          info "Manual DNS setup required."
        else
          skip "Skipping DNS route creation (cloudflare.zone_api_token not set)"
        end
        configured_hostnames.each do |host|
          info "Create proxied CNAME: #{host} -> #{target}"
        end
      end

      # Hostnames the operator configured. Excludes nil and empty strings so
      # the cloudflared-config.yml template doesn't render `hostname: `
      # (literal empty value) — which is invalid YAML and breaks tunnel boot.
      def configured_hostnames
        [tunnel_hostname, hostname_matrix, hostname_viewer, hostname_hello].compact.reject { |h| h.to_s.empty? }
      end

      def cloudflare_zone_id
        cloudflare_zone["id"]
      end

      def cloudflare_zone_account_id
        account = cloudflare_zone["account"]
        account && account["id"]
      end

      def cloudflare_zone
        return @cloudflare_zone if @cloudflare_zone
        raise "cloudflare.zone_name is required to create DNS routes" if zone_name.to_s.empty?

        zones = cloudflare_api(
          token: zone_token,
          method: :get,
          path: "/zones",
          query: { "name" => zone_name, "status" => "active" },
        )
        zone = zones.find { |candidate| candidate["name"] == zone_name }
        raise "Cloudflare zone not found or token cannot read zone: #{zone_name}" unless zone

        @cloudflare_zone = zone
      end

      def upsert_tunnel_dns_record(zone_id, hostname, target)
        existing = cloudflare_api(
          token: zone_token,
          method: :get,
          path: "/zones/#{zone_id}/dns_records",
          query: { "type" => "CNAME", "name" => hostname },
        ).first

        body = {
          "type"    => "CNAME",
          "name"    => hostname,
          "content" => target,
          "ttl"     => 1,
          "proxied" => true,
          "comment" => "Managed by Dev Boxer",
        }

        if existing
          return :unchanged if dns_record_matches?(existing, target)
          return :skipped unless confirm_dns_record_update(hostname, existing, target)

          cloudflare_api(token: zone_token, method: :put, path: "/zones/#{zone_id}/dns_records/#{existing["id"]}", body: body)
          :updated
        else
          cloudflare_api(token: zone_token, method: :post, path: "/zones/#{zone_id}/dns_records", body: body)
          :created
        end
      end

      def dns_record_matches?(record, target)
        record["content"] == target && record["proxied"] == true
      end

      def confirm_dns_record_update(hostname, record, target)
        current = record["content"].to_s
        proxied = record.key?("proxied") ? record["proxied"] : "unknown"
        message = "Existing DNS record for #{hostname} points to #{current} (proxied: #{proxied}). Update it to #{target}?"

        unless $stdin.tty?
          raise "#{message} Re-run interactively to confirm, or choose manual DNS setup."
        end

        print "#{message} [y/N]: "
        answer = $stdin.gets.to_s.strip.downcase
        %w[y yes].include?(answer)
      end

      def configure_cloudflare_access
        return unless access_enabled?

        if access_app_id && setup_token.to_s.empty?
          skip "Cloudflare Access app already configured"
          return
        end

        protected = access_hostnames
        if protected.empty?
          skip "Skipping Cloudflare Access app (no non-Matrix hostnames configured)"
          return
        end

        raise "cloudflare.access.account_id is required when Access setup is enabled" if access_account_id.to_s.empty?
        raise "cloudflare.api_token is required until cloudflare.access.app_id exists" if setup_token.to_s.empty?

        info "Configuring Cloudflare Access for #{protected.join(", ")}"
        body = cloudflare_access_app_payload(protected)
        result =
          if access_app_id
            cloudflare_api(token: setup_token, method: :put, path: "/accounts/#{access_account_id}/access/apps/#{access_app_id}", body: body)
          else
            cloudflare_api(token: setup_token, method: :post, path: "/accounts/#{access_account_id}/access/apps", body: body)
          end

        persist_access_app_id(result["id"]) if result["id"]
        ok "Cloudflare Access protects #{protected.join(", ")}"
        info "Matrix hostname left outside Access: #{hostname_matrix}" if hostname_matrix
      end

      def access_hostnames
        [tunnel_hostname, hostname_viewer, hostname_hello]
          .compact
          .reject { |host| host.to_s.empty? || host == hostname_matrix }
          .uniq
      end

      def cloudflare_access_app_payload(hostnames)
        {
          "name"             => access_app_name,
          "type"             => "self_hosted",
          "domain"           => hostnames.first,
          "destinations"     => hostnames.map { |host| { "type" => "public", "uri" => host } },
          "session_duration" => access_session_duration,
          "policies"         => [
            {
              "name"     => "Allow configured users",
              "decision" => "allow",
              "include"  => access_policy_rules,
            },
          ],
        }
      end

      def access_policy_rules
        rules = []
        Array(access_config&.allowed_emails).each do |email|
          next if email.to_s.empty?
          rules << { "email" => { "email" => email } }
        end
        Array(access_config&.allowed_email_domains).each do |domain|
          next if domain.to_s.empty?
          rules << { "email_domain" => { "domain" => domain } }
        end
        raise "At least one cloudflare.access allowed email or email domain is required" if rules.empty?

        rules
      end

      def persist_access_app_id(id)
        return unless config_path && File.exist?(config_path)
        Config.merge_into_file(config_path, { "cloudflare" => { "access" => { "app_id" => id } } })
      end

      def prompt_for_manual_tunnel_setup
        unless $stdin.tty?
          if tunnel_managed_manually?
            raise "cloudflare.tunnel.create_manually is true; run interactively for manual tunnel setup or set cloudflare.tunnel.id"
          end
          raise "No cloudflare.tunnel.id and no one-time cloudflare.api_token; run interactively for manual tunnel setup"
        end

        tunnel_name = "dev-boxer-#{shell.sh!('hostname -s').strip}"
        info ""
        info "Manual Cloudflare tunnel setup required."
        info "Manual setup uses cloudflared login to create an origin certificate in this root shell."
        info ""
        info "In another root shell on this VPS, run:"
        info "  cloudflared tunnel login"
        info "  cloudflared tunnel create --credentials-file #{Shellwords.escape(credentials_path)} -o json #{Shellwords.escape(tunnel_name)}"
        info ""
        info "Then paste the TunnelID below. Dev Boxer will persist only the tunnel ID."

        manual_tunnel_id = nil
        loop do
          print "Cloudflare TunnelID: "
          manual_tunnel_id = $stdin.gets.to_s.strip
          break unless manual_tunnel_id.empty?
          info "TunnelID is required."
        end

        unless File.exist?(credentials_path)
          raise "Manual tunnel credentials not found at #{credentials_path}"
        end

        persist_tunnel_id(manual_tunnel_id)
        ok "Manual tunnel registered: #{manual_tunnel_id}"
      end

      def current_tunnel_id
        return @current_tunnel_id if @current_tunnel_id
        return tunnel_id if tunnel_id
        return nil unless File.exist?(credentials_path)
        JSON.parse(File.read(credentials_path))["TunnelID"]
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
        if !hostname_hello.to_s.empty?
          rules << "  - hostname: #{hostname_hello}\n    service: http://localhost:#{hello_world_port}"
        end
        if !tunnel_hostname.to_s.empty?
          rules << "  - hostname: #{tunnel_hostname}\n    service: https://localhost\n    originRequest:\n      noTLSVerify: true"
        end
        rules << "  - service: http_status:404"
        rules.join("\n")
      end

      def hello_world_port = config.hello_world&.port || 9810

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

      # The setup API token is needed once to create the tunnel and optional
      # Cloudflare Access app; after that, cloudflared authenticates with the
      # tunnel-specific credentials.json and Access is tracked by app_id.
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

      def cloudflare_api(token:, method:, path:, query: {}, body: nil)
        uri = URI("#{API_BASE}#{path}")
        uri.query = URI.encode_www_form(query) unless query.empty?
        request = cloudflare_request(method, uri)
        request["Authorization"] = "Bearer #{token}"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body) if body

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end
        parsed = JSON.parse(response.body)
        return parsed["result"] if response.is_a?(Net::HTTPSuccess) && parsed["success"] != false

        errors = Array(parsed["errors"]).map { |err| err["message"] }.reject(&:empty?).join("; ")
        errors = response.body if errors.empty?
        raise "Cloudflare API #{method.to_s.upcase} #{path} failed: #{errors}"
      rescue JSON::ParserError
        raise "Cloudflare API #{method.to_s.upcase} #{path} returned invalid JSON: #{response&.body}"
      end

      def cloudflare_request(method, uri)
        {
          get: Net::HTTP::Get,
          post: Net::HTTP::Post,
          put: Net::HTTP::Put,
          patch: Net::HTTP::Patch,
          delete: Net::HTTP::Delete,
        }.fetch(method).new(uri)
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
        info "Hello:   https://#{hostname_hello}"         if hostname_hello
        if access_enabled?
          info "Cloudflare Access: protects #{access_hostnames.join(", ")}; Matrix is excluded."
        else
          info "IMPORTANT: set up Cloudflare Access for zero-trust security. See docs/cloudflare-access.md."
        end
      end
    end
  end
end
