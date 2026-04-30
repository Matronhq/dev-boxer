require "io/console"
require "fileutils"
require "securerandom"
require "yaml"

module DevBoxer
  class Wizard
    DEFAULT_USERNAME = "dev".freeze
    DEFAULT_SSH_PORT = 2222
    DEFAULT_HELLO_WORLD_PORT = 9810

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

      output.puts "Dev Boxer first-run setup"
      output.puts "Press Enter to accept the default shown in brackets."
      output.puts

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
      username = ask("Linux username", default: existing.dig("user", "name") || default_username)
      ssh_key = ask("SSH public key", default: existing.dig("user", "ssh_public_key") || default_ssh_public_key)
      ssh_port = ask_integer("SSH port", default: existing.dig("ssh", "port") || DEFAULT_SSH_PORT)
      base_domain = normalize_domain(ask("Base domain", default: default_base_domain(existing)))
      zone_token = ask(
        "Cloudflare zone DNS API token",
        default: existing.dig("cloudflare", "zone_api_token"),
        secret: true,
      )

      tunnel_id = existing.dig("cloudflare", "tunnel", "id")
      manual_tunnel = false
      if tunnel_id.to_s.empty?
        if confirm("Let Dev Boxer create the Cloudflare tunnel now?", default: true)
          manual_tunnel = false
        else
          manual_tunnel = true
          output.puts
          output.puts "Dev Boxer will pause during the Cloudflare module with manual tunnel instructions."
        end
      end
      access_config = build_access_config(existing)
      setup_token = nil
      if needs_setup_token?(tunnel_id: tunnel_id, manual_tunnel: manual_tunnel, access_config: access_config)
        explain_cloudflare_setup_token
        setup_token = ask(
          "One-time Cloudflare account setup token",
          default: existing.dig("cloudflare", "api_token"),
          secret: true,
        )
      end
      matrix_user = ask("Matrix username", default: existing.dig("matrix", "user_username") || username)
      rdp_password = existing.dig("user", "rdp_password") || SecureRandom.urlsafe_base64(18)

      config = {
        "user" => {
          "name" => username,
          "ssh_public_key" => ssh_key,
        },
        "ssh" => {
          "port" => ssh_port,
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
        "hello_world" => {
          "port" => DEFAULT_HELLO_WORLD_PORT,
        },
        "cloudflare" => {
          "enabled" => true,
          "zone_name" => base_domain,
          "tunnel" => {
            "id" => tunnel_id,
            "hostname" => "dev.#{base_domain}",
            "hostname_matrix" => "matrix.#{base_domain}",
            "hostname_viewer" => "viewer.#{base_domain}",
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

    def build_access_config(existing)
      output.puts
      output.puts "Cloudflare Access can protect dev/viewer hostnames while leaving matrix open for Matrix clients."
      enabled = confirm("Set up Cloudflare Zero Trust Access for dev/viewer now?", default: true)
      unless enabled
        return { "enabled" => false }
      end

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

    def explain_cloudflare_setup_token
      output.puts
      output.puts "Cloudflare setup:"
      output.puts "  - The zone DNS token is kept in secrets.yml for DNS records."
      output.puts "  - One temporary account token can create the tunnel and optional Access app."
      output.puts "  - It needs Account > Cloudflare Tunnel:Edit plus Access application/policy edit permissions."
      output.puts "  - Dev Boxer deletes this account token from secrets.yml after setup succeeds."
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
