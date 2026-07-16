require "uri"
require_relative "section"

module DevBoxer
  class Wizard
    class ExposureSection < Section
      TITLE = "Exposure".freeze

      def self.owned_keys = %w[exposure]

      def self.validate(hash, errors)
        mode = hash.dig("exposure", "mode")
        if Config.blank?(mode)
          errors << "exposure.mode is required"
        elsif !%w[cloudflare ip].include?(mode)
          errors << "exposure.mode must be cloudflare or ip"
        end
        validate_cloudflare(hash, errors) if mode == "cloudflare"
        validate_ip(hash, errors) if mode == "ip"
      end

      def self.validate_cloudflare(hash, errors)
        cf = hash.dig("exposure", "cloudflare") || {}

        errors << "exposure.cloudflare.zone_name is required" if Config.blank?(cf["zone_name"])
        errors << "exposure.cloudflare.tunnel.hostname is required" if Config.blank?(cf.dig("tunnel", "hostname"))
        errors << "exposure.cloudflare.tunnel.hostname_viewer is required" if Config.blank?(cf.dig("tunnel", "hostname_viewer"))

        if hash.dig("journal", "mode") != "external" && Config.blank?(cf.dig("tunnel", "hostname_journal"))
          errors << "exposure.cloudflare.tunnel.hostname_journal is required when the journal is bundled"
        end

        if Config.blank?(cf["zone_api_token"]) && cf.dig("dns", "create_manually") != true
          errors << "exposure.cloudflare.zone_api_token is required unless exposure.cloudflare.dns.create_manually is true"
        end

        if Config.blank?(cf.dig("tunnel", "id")) && Config.blank?(cf["api_token"]) &&
            cf.dig("tunnel", "create_manually") != true
          errors << "exposure.cloudflare.api_token is required until exposure.cloudflare.tunnel.id exists, unless exposure.cloudflare.tunnel.create_manually is true"
        end

        validate_access(cf, errors)
      end

      def self.validate_access(cf, errors)
        access = cf["access"] || {}
        return unless access["enabled"] == true

        if Config.blank?(access["app_id"]) && Config.blank?(cf["api_token"])
          errors << "exposure.cloudflare.api_token is required until exposure.cloudflare.access.app_id exists"
        end

        allowed_emails = Array(access["allowed_emails"]).reject { |value| Config.blank?(value) }
        allowed_domains = Array(access["allowed_email_domains"]).reject { |value| Config.blank?(value) }
        if allowed_emails.empty? && allowed_domains.empty?
          errors << "exposure.cloudflare.access needs at least one allowed email or email domain"
        end
      end

      def self.validate_ip(hash, errors)
        ip = hash.dig("exposure", "ip") || {}
        %w[journal_port viewer_port hello_port].each do |key|
          value = ip[key]
          Config.validate_port(errors, "exposure.ip.#{key}", value) unless value.nil?
        end
      end

      def collect(so_far)
        explain_exposure_modes
        mode = ask_choice(
          "Exposure mode",
          choices: %w[cloudflare ip],
          default: existing.dig("exposure", "mode") || "cloudflare",
        )
        mode == "ip" ? collect_ip : collect_cloudflare(so_far)
      end

      private

      def collect_ip
        explain_ip_mode
        address = ask(
          "Public IP address (Enter to auto-detect at setup time)",
          default: existing.dig("exposure", "ip", "address"),
          required: false,
        )
        ip = {
          "address" => address,
          "journal_port" => existing.dig("exposure", "ip", "journal_port") || 8443,
          "viewer_port" => existing.dig("exposure", "ip", "viewer_port") || 8444,
          "hello_port" => existing.dig("exposure", "ip", "hello_port") || 8445,
        }
        [{ "exposure" => { "mode" => "ip", "ip" => ip } }, {}]
      end

      def collect_cloudflare(so_far)
        journal_bundled = so_far.dig("journal", "mode") != "external"

        explain_base_domain
        base_domain = normalize_domain(ask("Base domain", default: default_base_domain(existing)))
        manual_dns, zone_token = choose_dns_setup(existing, base_domain)

        tunnel_id = existing.dig("exposure", "cloudflare", "tunnel", "id")
        manual_tunnel, access_config = choose_cloudflare_setup(existing, tunnel_id, manual_dns: manual_dns)

        setup_token = nil
        if needs_setup_token?(tunnel_id: tunnel_id, manual_tunnel: manual_tunnel,
                              access_config: access_config, base_domain: base_domain,
                              journal_bundled: journal_bundled)
          explain_cloudflare_setup_token
          setup_token = ask(
            "One-time Cloudflare account setup token",
            default: existing.dig("exposure", "cloudflare", "api_token"),
            secret: true,
          )
        end

        config = { "exposure" => { "mode" => "cloudflare", "cloudflare" => {
          "zone_name" => base_domain,
          "dns" => { "create_manually" => manual_dns },
          "tunnel" => {
            "id" => tunnel_id,
            "hostname" => "dev.#{base_domain}",
            "hostname_journal" => (journal_bundled ? "chat.#{base_domain}" : nil),
            "hostname_viewer" => "viewer.#{base_domain}",
            "hostname_hello" => "hello.#{base_domain}",
            "create_manually" => manual_tunnel,
            "config_managed_locally" => false,
          }.compact,
          "access" => access_config,
        }.compact } }

        secret_fields = { "api_token" => setup_token, "zone_api_token" => zone_token }.compact
        secrets = secret_fields.empty? ? {} : { "exposure" => { "cloudflare" => secret_fields } }
        [config, secrets]
      end

      def explain_exposure_modes
        say
        say "Exposure mode:"
        say "How should this box be reachable from your phone/laptop?"
        say "`cloudflare` — your own domain behind a Cloudflare Tunnel: real trusted certificate, no open inbound ports, the box can mint project subdomains, optional SSO. Needs a Cloudflare-managed domain (a .uk/.us name is ~$5-6/year)."
        say "`ip` — quick and cheap: no domain needed, the box serves wss/https directly on its IP with a self-signed certificate. Your Matron apps must accept (pin) that certificate the first time, and there's no SSO in front."
        say
      end

      def explain_ip_mode
        say
        say "IP mode:"
        say "Dev Boxer generates a 10-year self-signed certificate for the server IP, terminates TLS with nginx, and opens only the ports it uses in the firewall."
        say "Setup prints the certificate's SHA-256 fingerprint — verify it against the warning your app shows on first connection."
        say
      end

      def choose_dns_setup(existing, base_domain)
        explain_cloudflare_zone_token(base_domain)
        if confirm("Let Dev Boxer manage DNS records for this domain?", default: true)
          zone_token = ask(
            "Cloudflare zone DNS API token",
            default: existing.dig("exposure", "cloudflare", "zone_api_token"),
            secret: true,
          )
          [false, zone_token]
        else
          explain_manual_dns_setup(base_domain)
          [true, nil]
        end
      end

      def choose_cloudflare_setup(existing, tunnel_id, manual_dns:)
        if !tunnel_id.to_s.empty?
          say "Cloudflare tunnel already configured (id: #{tunnel_id})."
          if manual_dns
            explain_manual_access_after_manual_dns
            return [false, { "enabled" => false }]
          end
          return [false, build_access_config(existing, enabled: true)]
        end

        if manual_dns
          explain_manual_access_after_manual_dns
          if confirm("Let Dev Boxer create the Cloudflare tunnel now?", default: true)
            return [false, { "enabled" => false }]
          end

          explain_manual_cloudflare_setup
          return [true, { "enabled" => false }]
        end

        explain_cloudflare_automation
        if confirm("Let Dev Boxer create the Cloudflare tunnel and Zero Trust Access app now?", default: true)
          [false, build_access_config(existing, enabled: true)]
        else
          explain_manual_cloudflare_setup
          [true, { "enabled" => false }]
        end
      end

      def build_access_config(existing, enabled:)
        return { "enabled" => false } unless enabled

        allowed = ask(
          "Allowed emails or email domains (comma-separated)",
          default: default_access_allowed(existing),
        )
        allowed_emails, allowed_domains = parse_access_allowed(allowed)

        {
          "enabled" => true,
          "account_id" => existing.dig("exposure", "cloudflare", "access", "account_id"),
          "app_id" => existing.dig("exposure", "cloudflare", "access", "app_id"),
          "app_name" => existing.dig("exposure", "cloudflare", "access", "app_name") || "Dev Boxer",
          "bypass_app_id" => existing.dig("exposure", "cloudflare", "access", "bypass_app_id"),
          "bypass_app_name" => existing.dig("exposure", "cloudflare", "access", "bypass_app_name") || "Dev Boxer Public",
          "bypass_hostnames" => existing.dig("exposure", "cloudflare", "access", "bypass_hostnames"),
          "session_duration" => existing.dig("exposure", "cloudflare", "access", "session_duration") || "24h",
          "allowed_emails" => allowed_emails,
          "allowed_email_domains" => allowed_domains,
        }.compact
      end

      def needs_setup_token?(tunnel_id:, manual_tunnel:, access_config:, base_domain:, journal_bundled:)
        tunnel_needs_token = tunnel_id.to_s.empty? && manual_tunnel != true
        return tunnel_needs_token unless access_config["enabled"] == true

        # Protected app: always needed when Access is enabled.
        return true if access_config["app_id"].to_s.empty?

        # Bypass app: only needed when there will actually be bypass
        # destinations. Without this check the wizard demands a token any time
        # bypass_app_id is missing, even for installs that explicitly turned
        # bypass off — the module would correctly skip creation in that case
        # and the prompted token goes unused. Mirrors needs_bypass in
        # Modules::Cloudflare#configure_cloudflare_access.
        if access_config["bypass_app_id"].to_s.empty? &&
           !would_be_bypass_destinations(access_config, base_domain, journal_bundled: journal_bundled).empty?
          return true
        end

        tunnel_needs_token
      end

      # Mirrors Modules::Cloudflare#access_bypass_destinations using the data
      # the wizard has at hand (base_domain becomes hostname_journal when the
      # wizard later writes exposure.cloudflare.tunnel.hostname_journal).
      def would_be_bypass_destinations(access_config, base_domain, journal_bundled:)
        configured =
          if access_config.key?("bypass_hostnames")
            Array(access_config["bypass_hostnames"]).reject { |h| h.to_s.empty? }
          elsif !base_domain.to_s.empty?
            ["public-*.#{base_domain}"]
          else
            []
          end
        journal = (journal_bundled && !base_domain.to_s.empty?) ? "chat.#{base_domain}" : nil
        [journal, *configured].compact.reject { |h| h.to_s.empty? }.uniq
      end

      def default_access_allowed(existing)
        [
          *Array(existing.dig("exposure", "cloudflare", "access", "allowed_emails")),
          *Array(existing.dig("exposure", "cloudflare", "access", "allowed_email_domains")),
        ].join(", ")
      end

      def parse_access_allowed(value)
        items = value.to_s.split(",").map { |item| item.strip.downcase }.reject(&:empty?).uniq
        raise "At least one email or email domain is required for Cloudflare Access" if items.empty?

        items.partition { |item| item.include?("@") }
      end

      def explain_base_domain
        say
        say "Base domain:"
        say "Pick the Cloudflare-managed domain Dev Boxer should use, e.g. example.com."
        say "Dev Boxer will create dev, chat, viewer, and hello subdomains under it, plus more for any projects you build later."
        say "If you don't already have one, we recommend giving the box its own domain — .uk and .us names start around $5–6/year at https://www.cloudflare.com/products/registrar/."
        say "An existing domain works too; just move it to Cloudflare DNS first."
        say
      end

      def explain_cloudflare_zone_token(base_domain)
        token_name = "Dev Boxer DNS (#{base_domain})"
        encoded_name = URI.encode_www_form_component(token_name)
        say
        say "Cloudflare zone DNS API token:"
        say "Dev Boxer needs a zone-scoped API token for #{base_domain} so it can create and update DNS records for dev, chat, viewer, hello, and any project subdomains you make later."
        say "Open this prefill link — it sets Zone:Read + Zone:DNS:Edit and the name '#{token_name}':"
        say "  https://dash.cloudflare.com/?to=/:account/api-tokens&permissionGroupKeys=%5B%7B%22key%22%3A%22zone%22%2C%22type%22%3A%22read%22%7D%2C%7B%22key%22%3A%22dns%22%2C%22type%22%3A%22edit%22%7D%5D&name=#{encoded_name}"
        say
        say "!! IMPORTANT — Cloudflare does NOT let us pre-fill the zone scope, so the page will default to 'All zones'. You MUST change it before creating the token:"
        say "  1. Scroll to 'Zone Resources'."
        say "  2. Change 'Include' from 'All zones from an account' to 'Specific zone'."
        say "  3. In the zone dropdown, pick #{base_domain}."
        say "  4. Continue to the summary and create the token."
        say
        say "Scope it to this zone only — never all zones. A token granting access to every zone in your Cloudflare account is far more powerful than Dev Boxer needs and is a much bigger blast radius if it ever leaks."
        say "Choose no below if you'd rather create each subdomain manually."
        say
      end

      def explain_manual_dns_setup(base_domain)
        say
        say "Manual DNS selected:"
        say "Dev Boxer won't store an API token."
        say "Once the tunnel exists you'll need to create proxied CNAME records for dev.#{base_domain}, chat.#{base_domain}, viewer.#{base_domain}, and hello.#{base_domain}, pointing at the tunnel target Dev Boxer prints (usually <TunnelID>.cfargotunnel.com)."
        say "Any future project subdomains will also be your responsibility to create."
        say
      end

      def explain_manual_access_after_manual_dns
        say
        say "Cloudflare Access will be manual too:"
        say "Dev Boxer normally derives your Cloudflare account from the zone DNS token, and without that token it can't reach the Access API."
        say "Create the two Access apps yourself later from the dashboard — a protected app for `*.<your zone>` and a bypass app for the journal and `public-*` (so the Matron apps and any public subdomains skip the login wall). See docs/cloudflare-access.md."
        say
      end

      def explain_cloudflare_automation
        say
        say "Cloudflare automation:"
        say "Dev Boxer can create the Cloudflare Tunnel (which exposes your hostnames without opening any inbound ports) and the two Zero Trust Access apps in one go: a protected app that puts `*.<your zone>` behind browser SSO, and a bypass app that lets the journal and any `public-`-prefixed subdomain through without a login."
        say "Say no if you'd rather run the cloudflared tunnel login and cloudflared tunnel create commands by hand — Dev Boxer will pause and tell you exactly what to run, then ask for the resulting TunnelID."
        say
      end

      def explain_manual_cloudflare_setup
        say
        say "Manual Cloudflare setup selected:"
        say "Dev Boxer will install cloudflared, print the exact `cloudflared tunnel login` and `cloudflared tunnel create` commands to run in another root shell, then ask you to paste the resulting TunnelID."
        say "It won't create the Access apps either — set up both (a protected app for `*.<your zone>` and a bypass app for the journal and `public-*`) later from the dashboard if you want SSO; see docs/cloudflare-access.md."
        say
      end

      def explain_cloudflare_setup_token
        say
        say "One-time Cloudflare account setup token:"
        say "A one-time account-level Cloudflare API token used only to create the tunnel and the Access app."
        say "Create a custom token at https://dash.cloudflare.com/?to=/:account/api-tokens with these account permissions:"
        say "  - Cloudflare One Connector: cloudflared: Edit"
        say "  - Access: Apps: Edit"
        say "  - Access: Policies: Edit"
        say "Dev Boxer wipes it from secrets.yml as soon as setup finishes."
        say
      end

      def normalize_domain(domain)
        normalized = domain.to_s
          .strip
          .sub(%r{\Ahttps?://}i, "")
          .split("/", 2)
          .first
          .sub(/\A\*\./, "")
          .sub(/\.\z/, "")
          .downcase
        raise "Base domain is required" if normalized.empty?
        normalized
      end

      def default_base_domain(existing)
        host = existing.dig("exposure", "cloudflare", "tunnel", "hostname")
        host&.sub(/\Adev\./, "")
      end
    end
  end
end
