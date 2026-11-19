require "ipaddr"
require "uri"
require "securerandom"

module DevBoxer
  # The first-run path. Existing installations keep the advanced wizard and
  # their settings; this profile is only chosen for a new installation.
  class StarterWizard
    def self.run(config_path:, input: $stdin, output: $stdout, **)
      new(config_path, Wizard::Prompter.new(input: input, output: output)).run
    end

    def initialize(config_path, prompter)
      @path, @p = config_path, prompter
    end

    def run
      @p.say "Set up Matron"
      @p.say "1 — Set up my first Matron"
      @p.say "2 — Add a box to my Matron"
      @p.say "3 — Advanced developer setup"
      choice = @p.ask_choice("Choose", choices: %w[1 2 3], default: "1")
      return Wizard.run(config_path: @path, input: @p.input, output: @p.output) if choice == "3"

      name = ask_valid("Your sign-in name", default: "alice") do |s|
        s.match?(/\A[a-z][a-z0-9_-]{0,30}\z/) && s != "root" ? nil : "Use a short name: lowercase letters, digits, - or _."
      end
      agent = @p.ask_choice("Which AI account will you sign into?", choices: %w[claude codex], default: "claude")
      @p.say "Use the stable public IPv4 address shown in your VPS dashboard."
      address = ask_valid("This VPS's public IPv4 address") { |s| self.class.address_problem(s) }
      @p.say "Allow inbound TCP ports 22, 80, 443 and 8444 in your provider's firewall."
      @p.say "HTTPS certificates renew automatically. Port 80 must stay reachable for renewal."
      @p.say "Certificate issuance uses Let's Encrypt: https://letsencrypt.org/repository/"
      raise SetupError, "Setup cancelled before making changes." unless @p.confirm("Accept the certificate authority's terms and continue?", default: false)

      @p.say "Paste your SSH PUBLIC key (the .pub file). Keep the private key on your computer."
      key = ask_valid("SSH public key", default: existing_public_key) { |s| SshKeyCheck.problem(s) }
      journal = { "mode" => choice == "1" ? "bundled" : "external", "username" => name }
      if choice == "2"
        origin = ask_valid("Your existing Matron HTTPS address") { |s| self.class.origin_problem(s) }
        journal["url"] = origin.sub(/\/$/, "").sub(/\Ahttps:/, "wss:") + "/ws"
      end
      data = {
        "setup" => { "profile" => "starter" },
        "user" => { "name" => "dev", "ssh_public_key" => key },
        "ssh" => { "port" => 22 },
        "journal" => journal,
        "exposure" => { "mode" => "public-ip", "ip" => { "address" => address }, "accept_terms" => true },
        "agent" => { "provider" => agent },
        "bridge" => { "voice_notes" => { "enabled" => false } },
        "claude" => { "experience_level" => "beginner", "plugins" => [] },
        "desktop" => { "enabled" => false },
        "monitoring" => { "node_exporter" => false },
        "hello_world" => { "port" => 9820 },
      }
      Config.merge_into_file(@path, data)
      Config.merge_into_file(Config.secrets_path_for(@path), { "user" => { "rdp_password" => SecureRandom.urlsafe_base64(24) } })
      @p.say "Settings saved. Setup can be safely resumed with the same command."
      :created
    end

    def self.address_problem(value)
      return "Enter a public IPv4 address, without a port or network range." if value.include?("/")
      ip = IPAddr.new(value)
      return "Enter the public IPv4 address from your VPS dashboard." unless ip.ipv4? && !ip.private? && !ip.loopback? && !ip.link_local?
      return "Enter a unicast public IPv4 address." if IPAddr.new("0.0.0.0/8").include?(ip) || IPAddr.new("224.0.0.0/3").include?(ip) || IPAddr.new("100.64.0.0/10").include?(ip)
      nil
    rescue IPAddr::InvalidAddressError
      "Enter an IPv4 address, for example 203.0.113.7."
    end

    def self.origin_problem(value)
      u = URI(value)
      return nil if u.scheme == "https" && u.host && !u.userinfo && !u.query && !u.fragment && ["", "/"].include?(u.path)
      "Use just the HTTPS address, without /app, /ws, a password or a query."
    rescue URI::InvalidURIError
      "Enter a valid HTTPS address."
    end

    private

    def ask_valid(label, **opts)
      loop do
        answer = @p.ask(label, **opts)
        problem = yield(answer)
        return answer unless problem
        @p.say problem
        opts.delete(:default)
      end
    end

    def existing_public_key
      return unless File.file?("/root/.ssh/authorized_keys")
      File.readlines("/root/.ssh/authorized_keys").filter_map do |line|
        key = line.strip[/((?:ssh-ed25519|ssh-rsa|ecdsa-sha2-\S+) AAAA\S*(?: .*)?)/, 1]
        key if key && !SshKeyCheck.problem(key)
      end.first
    end
  end
end
