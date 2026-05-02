require "io/console"
require "fileutils"
require "securerandom"
require "yaml"

module DevBoxer
  class Wizard
    DEFAULT_USERNAME = "dev".freeze
    DEFAULT_SSH_PORT = 2222
    DEFAULT_HELLO_WORLD_PORT = 9810
    DEFAULT_EXPERIENCE_LEVEL = "intermediate".freeze
    EXPERIENCE_LEVELS = %w[beginner intermediate advanced].freeze

    def self.run(config_path:, input: $stdin, output: $stdout, force: false)
      new(config_path: config_path, input: input, output: output).run(force: force)
    end

    def initialize(config_path:, input: $stdin, output: $stdout)
      @config_path = config_path
      @secrets_path = Config.secrets_path_for(config_path)
      @input = input
      @output = output
    end

    def run(force: false)
      existing_config = load_yaml(config_path)
      existing_secrets = load_yaml(secrets_path)
      existing = Config.deep_merge(existing_config, existing_secrets)

      if File.exist?(config_path) && !force && Config.validation_errors(Config.from_hash(existing)).empty?
        output.puts "Existing config.yml looks complete."
        return :reused if confirm("Reuse existing config?", default: true)
      end

      print_welcome

      config, secrets = build_config(existing)
      write_yaml(config_path, config, mode: 0o644)
      write_yaml(secrets_path, secrets, mode: 0o600)

      output.puts
      output.puts "Wrote #{config_path}"
      output.puts "Wrote #{secrets_path} (mode 0600)"
      :created
    end

    private

    attr_reader :config_path, :secrets_path, :input, :output

    def build_config(existing)
      section_header("1. Server login")
      username = ask("Linux username", default: existing.dig("user", "name") || default_username)
      ssh_key = ask("SSH public key", default: existing.dig("user", "ssh_public_key") || default_ssh_public_key)
      ssh_port = ask_integer("SSH port", default: existing.dig("ssh", "port") || DEFAULT_SSH_PORT)

      section_header("2. Domain and DNS")
      explain_base_domain
      base_domain = normalize_domain(ask("Base domain", default: default_base_domain(existing)))
      manual_dns, zone_token = choose_dns_setup(existing, base_domain)

      section_header("3. Cloudflare tunnel and Access")
      tunnel_id = existing.dig("cloudflare", "tunnel", "id")
      manual_tunnel, access_config = choose_cloudflare_setup(existing, tunnel_id, manual_dns: manual_dns)
      setup_token = nil
      if needs_setup_token?(tunnel_id: tunnel_id, manual_tunnel: manual_tunnel, access_config: access_config)
        explain_cloudflare_setup_token
        setup_token = ask(
          "One-time Cloudflare account setup token",
          default: existing.dig("cloudflare", "api_token"),
          secret: true,
        )
      end

      section_header("4. Matrix user")
      matrix_user = ask("Matrix username", default: existing.dig("matrix", "user_username") || username)
      section_header("5. Claude behavior")
      claude_config = build_claude_config(existing)
      rdp_password = existing.dig("user", "rdp_password") || SecureRandom.urlsafe_base64(18)

      config = {
        "user" => {
          "name" => username,
          "ssh_public_key" => ssh_key,
        },
        "ssh" => {
          "port" => ssh_port,
        },
        "desktop" => {
          "enabled" => false,
        },
        "docker" => {
          "data_root" => nil,
          "containerd_root" => nil,
          "prune" => {
            "interval" => "2h",
            "keep_until" => "4h",
          },
        },
        "matrix" => {
          "mode" => "bundled",
          "server_domain" => "matrix.#{base_domain}",
          "user_username" => matrix_user,
          "bot_username" => nil,
        },
        "claude" => claude_config,
        "hello_world" => {
          "port" => DEFAULT_HELLO_WORLD_PORT,
        },
        "cloudflare" => {
          "enabled" => true,
          "zone_name" => base_domain,
          "dns" => {
            "create_manually" => manual_dns,
          },
          "tunnel" => {
            "id" => tunnel_id,
            "hostname" => "dev.#{base_domain}",
            "hostname_matrix" => "matrix.#{base_domain}",
            "hostname_viewer" => "viewer.#{base_domain}",
            "hostname_hello" => "hello.#{base_domain}",
            "create_manually" => manual_tunnel,
            "config_managed_locally" => false,
          }.compact,
          "access" => access_config,
        }.compact,
      }

      secrets = {
        "user" => {
          "rdp_password" => rdp_password,
        },
        "cloudflare" => {
          "api_token" => setup_token,
          "zone_api_token" => zone_token,
        }.compact,
      }

      [config, secrets]
    end

    def build_claude_config(existing)
      output.puts
      output.puts "Claude behavior:"
      output.puts "  Beginner: explain more, ask before meaningful technical choices, summarize next steps."
      output.puts "  Intermediate: concise explanations, proceed on routine choices, ask on tradeoffs."
      output.puts "  Advanced: terse summaries, proceed with reasonable assumptions, focus on diffs/tests/blockers."
      output.puts

      level = ask_experience_level(existing)
      config = { "experience_level" => level }
      plugins = existing.dig("claude", "plugins")
      config["plugins"] = plugins unless plugins.nil?
      config
    end

    def ask_experience_level(existing)
      existing_level = existing.dig("claude", "experience_level").to_s.downcase
      default = EXPERIENCE_LEVELS.include?(existing_level) ? existing_level : DEFAULT_EXPERIENCE_LEVEL
      loop do
        level = ask("Claude user experience level", default: default).to_s.downcase
        return level if EXPERIENCE_LEVELS.include?(level)

        output.puts "Choose one of: #{EXPERIENCE_LEVELS.join(", ")}."
      end
    end

    def choose_dns_setup(existing, base_domain)
      explain_cloudflare_zone_token(base_domain)
      if confirm("Let Dev Boxer manage DNS records for this domain?", default: true)
        zone_token = ask(
          "Cloudflare zone DNS API token",
          default: existing.dig("cloudflare", "zone_api_token"),
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
        output.puts "Cloudflare tunnel already configured (id: #{tunnel_id})."
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
        "account_id" => existing.dig("cloudflare", "access", "account_id"),
        "app_id" => existing.dig("cloudflare", "access", "app_id"),
        "app_name" => existing.dig("cloudflare", "access", "app_name") || "Dev Boxer",
        "session_duration" => existing.dig("cloudflare", "access", "session_duration") || "24h",
        "allowed_emails" => allowed_emails,
        "allowed_email_domains" => allowed_domains,
      }.compact
    end

    def needs_setup_token?(tunnel_id:, manual_tunnel:, access_config:)
      tunnel_needs_token = tunnel_id.to_s.empty? && manual_tunnel != true
      access_needs_token = access_config["enabled"] == true && access_config["app_id"].to_s.empty?
      tunnel_needs_token || access_needs_token
    end

    def default_access_allowed(existing)
      [
        *Array(existing.dig("cloudflare", "access", "allowed_emails")),
        *Array(existing.dig("cloudflare", "access", "allowed_email_domains")),
      ].join(", ")
    end

    def parse_access_allowed(value)
      items = value.to_s.split(",").map { |item| item.strip.downcase }.reject(&:empty?).uniq
      raise "At least one email or email domain is required for Cloudflare Access" if items.empty?

      items.partition { |item| item.include?("@") }
    end

    def print_welcome
      output.puts color("  +------------------------------------------------+", "36")
      output.puts color("  |                   DEV BOXER                    |", "35")
      output.puts color("  |        Remote Claude Code dev box setup        |", "36")
      output.puts color("  +------------------------------------------------+", "36")
      output.puts "Press Enter to accept the default shown in brackets."
      output.puts
    end

    def section_header(title)
      output.puts
      output.puts color("== #{title} ==", "36")
      output.puts color("-" * (title.length + 6), "36")
    end

    def color(text, code)
      return text unless output.respond_to?(:tty?) && output.tty?
      "\e[#{code}m#{text}\e[0m"
    end

    def ask(label, default: nil, required: true, secret: false)
      loop do
        output.print(prompt_for(label, default, secret))
        value = read_value(secret)
        value = value.to_s.strip

        return value unless value.empty?
        return default unless default.to_s.empty?
        return nil unless required

        output.puts "#{label} is required."
      end
    end

    def ask_integer(label, default:)
      loop do
        value = ask(label, default: default)
        return Integer(value)
      rescue ArgumentError, TypeError
        output.puts "#{label} must be a number."
      end
    end

    def explain_base_domain
      output.puts
      output.puts "Base domain:"
      output.puts "  What: The Cloudflare-managed domain Dev Boxer will use, for example example.com."
      output.puts "  Why: Dev Boxer creates dev.<domain>, matrix.<domain>, viewer.<domain>, hello.<domain>, and can create new subdomains for projects you make."
      output.puts "  Tip: We recommend giving the box its own domain."
      output.puts "  Cost: Low-cost domains such as .uk or .us often start around $5-6/year, depending on current registrar pricing."
      output.puts "  How: Register or transfer a domain with Cloudflare Registrar, or add an existing domain to Cloudflare DNS first."
      output.puts "  Link: https://www.cloudflare.com/products/registrar/"
      output.puts
    end

    def explain_cloudflare_zone_token(base_domain)
      output.puts
      output.puts "Cloudflare zone DNS API token:"
      output.puts "  What: A zone-scoped Cloudflare API token for #{base_domain}."
      output.puts "  Why: Dev Boxer keeps this token in secrets.yml so it can create and update DNS records for dev, matrix, viewer, hello, and new subdomains for projects you make."
      output.puts "  How: Create a custom token at https://dash.cloudflare.com/profile/api-tokens with Zone:Read and DNS:Edit."
      output.puts "  Scope: Limit the token to the #{base_domain} zone only. Do not grant access to all zones."
      output.puts "  Alternative: Choose no below if you prefer to create each required subdomain manually."
      output.puts
    end

    def explain_manual_dns_setup(base_domain)
      output.puts
      output.puts "Manual DNS selected."
      output.puts "  Dev Boxer will not store a DNS API token."
      output.puts "  After the tunnel exists, create proxied CNAME records for:"
      output.puts "    - dev.#{base_domain}"
      output.puts "    - matrix.#{base_domain}"
      output.puts "    - viewer.#{base_domain}"
      output.puts "    - hello.#{base_domain}"
      output.puts "  Point each record at the tunnel target Dev Boxer prints, usually <TunnelID>.cfargotunnel.com."
      output.puts "  You will also need to create any future project subdomains yourself."
      output.puts
    end

    def explain_manual_access_after_manual_dns
      output.puts
      output.puts "Cloudflare Access will be manual because DNS is manual."
      output.puts "  Dev Boxer normally derives the Cloudflare account from the zone DNS token."
      output.puts "  Without that token, create the Access app manually later if you want browser SSO for dev/viewer/hello."
      output.puts
    end

    def explain_cloudflare_automation
      output.puts
      output.puts "Cloudflare automation:"
      output.puts "  What: Dev Boxer can create one Cloudflare Tunnel and one Zero Trust Access app."
      output.puts "  Why: The tunnel exposes dev.<domain>, matrix.<domain>, viewer.<domain>, and hello.<domain> without opening inbound ports."
      output.puts "       Access protects dev/viewer/hello in the browser, while matrix stays outside Access so Matrix clients work normally."
      output.puts "  Manual option: If you prefer, choose no. Dev Boxer will pause later with the exact cloudflared tunnel command, then ask for the TunnelID."
      output.puts "                 You can create the Access app manually after setup using docs/cloudflare-access.md."
      output.puts
    end

    def explain_manual_cloudflare_setup
      output.puts
      output.puts "Manual Cloudflare setup selected."
      output.puts "  Tunnel: Dev Boxer will install cloudflared, print a one-time tunnel creation command, and ask you to paste the resulting TunnelID."
      output.puts "  Login: The manual tunnel command starts with cloudflared tunnel login, which opens a Cloudflare authorization URL."
      output.puts "  Access: Dev Boxer will not create a Zero Trust Access app. Protect dev/viewer/hello manually later if you want browser SSO."
      output.puts
    end

    def explain_cloudflare_setup_token
      output.puts
      output.puts "One-time Cloudflare account setup token:"
      output.puts "  What: A temporary account-level Cloudflare API token."
      output.puts "  Why: Dev Boxer uses it once to create the Cloudflare Tunnel and optional Zero Trust Access app."
      output.puts "  How: Create a custom token at https://dash.cloudflare.com/profile/api-tokens with these account permissions:"
      output.puts "       - Cloudflare One Connector: cloudflared: Edit"
      output.puts "       - Access: Apps: Edit"
      output.puts "       - Access: Policies: Edit"
      output.puts "  Cleanup: Dev Boxer deletes this token from secrets.yml after setup succeeds."
      output.puts
    end

    def confirm(label, default:)
      suffix = default ? "Y/n" : "y/N"
      output.print "#{label} [#{suffix}]: "
      answer = input.gets.to_s.strip.downcase
      return default if answer.empty?
      %w[y yes].include?(answer)
    end

    def prompt_for(label, default, secret)
      if default.to_s.empty?
        "#{label}: "
      elsif secret
        "#{label} [press Enter to keep existing]: "
      else
        "#{label} [#{default}]: "
      end
    end

    def read_value(secret)
      if secret && input.respond_to?(:noecho)
        value = input.noecho(&:gets)
        output.puts
        value
      else
        input.gets
      end
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
      host = existing.dig("cloudflare", "tunnel", "hostname")
      host&.sub(/\Adev\./, "")
    end

    def default_username
      user = ENV["SUDO_USER"]
      return user if user && user != "root"
      DEFAULT_USERNAME
    end

    def default_ssh_public_key
      path = "/root/.ssh/authorized_keys"
      return nil unless File.exist?(path)
      File.readlines(path).map(&:strip).find { |line| !line.empty? && !line.start_with?("#") }
    end

    def load_yaml(path)
      File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
    end

    def write_yaml(path, hash, mode:)
      FileUtils.mkdir_p(File.dirname(path))
      old_umask = File.umask(mode == 0o600 ? 0o077 : 0o022)
      begin
        File.write(path, hash.to_yaml)
      ensure
        File.umask(old_umask)
      end
      File.chmod(mode, path)
    end
  end
end
