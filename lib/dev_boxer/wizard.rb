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
      setup_token = nil
      if tunnel_id.to_s.empty?
        explain_tunnel_setup_token
        if confirm("Let Dev Boxer create the Cloudflare tunnel now?", default: true)
          setup_token = ask(
            "One-time Cloudflare Tunnel setup token",
            default: existing.dig("cloudflare", "api_token"),
            secret: true,
          )
        else
          manual_tunnel = true
          output.puts
          output.puts "Dev Boxer will pause during the Cloudflare module with manual tunnel instructions."
        end
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
          "tunnel" => {
            "id" => tunnel_id,
            "hostname" => "dev.#{base_domain}",
            "hostname_matrix" => "matrix.#{base_domain}",
            "hostname_viewer" => "viewer.#{base_domain}",
            "create_manually" => manual_tunnel,
            "config_managed_locally" => false,
          }.compact,
        },
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

    def explain_tunnel_setup_token
      output.puts
      output.puts "Cloudflare tunnel setup:"
      output.puts "  - The zone DNS token is kept in secrets.yml for DNS route creation."
      output.puts "  - Automatic tunnel creation needs a separate one-time token with Account > Cloudflare Tunnel:Edit."
      output.puts "  - If you provide it, Dev Boxer deletes it from secrets.yml after the tunnel is created."
      output.puts "  - You can skip it and create the tunnel manually when prompted later."
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
