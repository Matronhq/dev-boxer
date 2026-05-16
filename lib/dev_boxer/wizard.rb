require "io/console"
require "fileutils"
require "securerandom"
require "yaml"
require "dev_boxer/credentials_blob"

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
      explain_linux_username
      username = ask("Linux username", default: existing.dig("user", "name") || default_username)
      explain_ssh_public_key
      ssh_key = ask("SSH public key", default: existing.dig("user", "ssh_public_key") || default_ssh_public_key)
      explain_ssh_port
      ssh_port = ask_integer("SSH port", default: existing.dig("ssh", "port") || DEFAULT_SSH_PORT)

      section_header("2. GitHub access")
      explain_github_token
      github_token = ask(
        "GitHub personal access token",
        default: existing.dig("github", "token"),
        required: false,
        secret: true,
      )

      section_header("3. Domain and DNS")
      explain_base_domain
      base_domain = normalize_domain(ask("Base domain", default: default_base_domain(existing)))
      manual_dns, zone_token = choose_dns_setup(existing, base_domain)

      section_header("4. Cloudflare tunnel and Access")
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

      section_header("5. Matrix")
      matrix_choice = ask_choice(
        "Matrix homeserver location",
        choices: %w[here there],
        default: existing.dig("matrix", "mode") == "external" ? "there" : "here",
      )

      matrix_user, matrix_overrides, matrix_secret_fields =
        case matrix_choice
        when "here"
          name = ask("Matrix username", default: existing.dig("matrix", "user_username") || username)
          [name, { "mode" => "bundled" }, {}]
        when "there"
          decoded = ask_blob_until_valid
          bot_localpart = decoded["bot_user_id"].split(":", 2).first.delete_prefix("@")
          # Ask explicitly: the Matrix localpart on the external homeserver is
          # often NOT the Linux username (e.g. juser on Matrix vs youruser
          # in Linux). Falling back silently produced the wrong ALLOWED_USER_IDS
          # in the bridge .env, which made box-2 silently drop every message.
          explain_external_matrix_username(decoded["server_domain"])
          name = ask(
            "Your Matrix username on #{decoded['server_domain']}",
            default: existing.dig("matrix", "user_username") || username,
          )
          overrides = {
            "mode"           => "external",
            "homeserver_url" => decoded["homeserver_url"],
            "server_domain"  => decoded["server_domain"],
            "bot_username"   => bot_localpart,
          }
          secrets_block = decoded.slice("bot_user_id", "bot_password", "bot_recovery_key", "bridge_room_id")
          [name, overrides, secrets_block]
        end

      section_header("6. Claude behavior")
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
        "matrix" => DevBoxer::Config.deep_merge({
          "mode" => "bundled",
          "server_domain" => "matrix.#{base_domain}",
          "user_username" => matrix_user,
          "bot_username" => nil,
        }, matrix_overrides),
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
      secrets["matrix"] = matrix_secret_fields unless matrix_secret_fields.empty?
      secrets["github"] = { "token" => github_token } unless github_token.to_s.empty?

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

    def ask_choice(prompt, choices:, default:)
      loop do
        raw = ask("#{prompt} (#{choices.join(' / ')})", default: default).to_s.downcase
        return raw if choices.include?(raw)

        output.puts "Choose one of: #{choices.join(', ')}."
      end
    end

    def ask_blob_until_valid
      loop do
        raw = ask("Paste add-bot blob from your homeserver box", secret: true)
        begin
          return DevBoxer::CredentialsBlob.decode(raw)
        rescue DevBoxer::CredentialsBlob::Invalid => e
          output.puts "  ✗ blob invalid: #{e.message}"
        end
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

    def explain_linux_username
      output.puts
      output.puts "Linux username:"
      output.puts "The Linux account you'll ssh into and do your work as."
      output.puts "`dev` is fine if you don't have a preference; just avoid `root` — Dev Boxer disables root login regardless."
      output.puts
    end

    def explain_ssh_public_key
      output.puts
      output.puts "SSH public key:"
      output.puts "Paste the public half of your SSH key — a single line starting with `ssh-ed25519`, `ssh-rsa`, or `sk-ssh-...`."
      output.puts "Dev Boxer drops it into the new account's authorized_keys and disables password auth, so this key is your only way in."
      output.puts "If you don't already have one, run `ssh-keygen -t ed25519` on your laptop and paste `~/.ssh/id_ed25519.pub` (on macOS, `pbcopy < ~/.ssh/id_ed25519.pub` puts it on your clipboard)."
      output.puts
    end

    def explain_ssh_port
      output.puts
      output.puts "SSH port:"
      output.puts "Dev Boxer puts ssh on a non-standard port to cut down on the noise from automated scanners hammering port 22."
      output.puts "2222 is the default; pick whatever you like between 1024 and 65535."
      output.puts
    end

    def explain_github_token
      output.puts
      output.puts "GitHub personal access token (optional):"
      output.puts "A fine-grained PAT for the private repos Dev Boxer needs to clone — today that's just claude-matrix-bridge, possibly more later."
      output.puts "Without it, setup pauses partway through and runs `gh auth login --web` as the new dev user; with it, the rest of setup runs unattended."
      output.puts "Create one at https://github.com/settings/personal-access-tokens/new — resource owner Matronhq, repository access \"Only select repositories\" → claude-matrix-bridge, Contents: Read-only, sensible expiration (e.g. 1 year)."
      output.puts "Saved to secrets.yml (mode 0600). Leave blank to fall back to the interactive web flow during the matrix-bridge module."
      output.puts
    end

    def explain_external_matrix_username(server_domain)
      output.puts
      output.puts "Your Matrix username:"
      output.puts "The local part of your existing Matrix account on #{server_domain} — the bit between `@` and `:`, e.g. `juser` in `@juser:#{server_domain}`."
      output.puts "This becomes ALLOWED_USER_IDS in the bridge .env. Anything else gets silently dropped, so getting this wrong leaves the bridge looking dead while it's actually receiving and decrypting your messages."
      output.puts "This is your MATRIX username, not your Linux username on this VPS — they're often different."
      output.puts
    end

    def explain_base_domain
      output.puts
      output.puts "Base domain:"
      output.puts "Pick the Cloudflare-managed domain Dev Boxer should use, e.g. example.com."
      output.puts "Dev Boxer will create dev, matrix, viewer, and hello subdomains under it, plus more for any projects you build later."
      output.puts "If you don't already have one, we recommend giving the box its own domain — .uk and .us names start around $5–6/year at https://www.cloudflare.com/products/registrar/."
      output.puts "An existing domain works too; just move it to Cloudflare DNS first."
      output.puts
    end

    def explain_cloudflare_zone_token(base_domain)
      output.puts
      output.puts "Cloudflare zone DNS API token:"
      output.puts "Dev Boxer needs a zone-scoped API token for #{base_domain} so it can create and update DNS records for dev, matrix, viewer, hello, and any project subdomains you make later."
      output.puts "Create one — pre-filled with Zone:Read + Zone:DNS:Edit and the name 'Dev Boxer DNS' — at:"
      output.puts "  https://dash.cloudflare.com/?to=/:account/api-tokens&permissionGroupKeys=%5B%7B%22key%22%3A%22zone%22%2C%22type%22%3A%22read%22%7D%2C%7B%22key%22%3A%22dns%22%2C%22type%22%3A%22edit%22%7D%5D&name=Dev+Boxer+DNS"
      output.puts "Set 'Zone Resources' to 'Include - Specific zone - #{base_domain}', then create the token. Scope it to this zone only — never all zones."
      output.puts "Choose no below if you'd rather create each subdomain manually."
      output.puts
    end

    def explain_manual_dns_setup(base_domain)
      output.puts
      output.puts "Manual DNS selected:"
      output.puts "Dev Boxer won't store an API token."
      output.puts "Once the tunnel exists you'll need to create proxied CNAME records for dev.#{base_domain}, matrix.#{base_domain}, viewer.#{base_domain}, and hello.#{base_domain}, pointing at the tunnel target Dev Boxer prints (usually <TunnelID>.cfargotunnel.com)."
      output.puts "Any future project subdomains will also be your responsibility to create."
      output.puts
    end

    def explain_manual_access_after_manual_dns
      output.puts
      output.puts "Cloudflare Access will be manual too:"
      output.puts "Dev Boxer normally derives your Cloudflare account from the zone DNS token, and without that token it can't reach the Access API."
      output.puts "Create the Access app yourself later from the dashboard if you want browser SSO on dev, viewer, and hello — see docs/cloudflare-access.md."
      output.puts
    end

    def explain_cloudflare_automation
      output.puts
      output.puts "Cloudflare automation:"
      output.puts "Dev Boxer can create the Cloudflare Tunnel (which exposes your hostnames without opening any inbound ports) and a Zero Trust Access app (browser SSO) in one go."
      output.puts "Matrix stays outside Access so Matrix clients keep working normally."
      output.puts "Say no if you'd rather run the cloudflared tunnel login and cloudflared tunnel create commands by hand — Dev Boxer will pause and tell you exactly what to run, then ask for the resulting TunnelID."
      output.puts
    end

    def explain_manual_cloudflare_setup
      output.puts
      output.puts "Manual Cloudflare setup selected:"
      output.puts "Dev Boxer will install cloudflared, print the exact `cloudflared tunnel login` and `cloudflared tunnel create` commands to run in another root shell, then ask you to paste the resulting TunnelID."
      output.puts "It won't create the Access app either — set that up later from the dashboard if you want SSO; see docs/cloudflare-access.md."
      output.puts
    end

    def explain_cloudflare_setup_token
      output.puts
      output.puts "One-time Cloudflare account setup token:"
      output.puts "A one-time account-level Cloudflare API token used only to create the tunnel and the Access app."
      output.puts "Create a custom token at https://dash.cloudflare.com/?to=/:account/api-tokens with these account permissions:"
      output.puts "  - Cloudflare One Connector: cloudflared: Edit"
      output.puts "  - Access: Apps: Edit"
      output.puts "  - Access: Policies: Edit"
      output.puts "Dev Boxer wipes it from secrets.yml as soon as setup finishes."
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
