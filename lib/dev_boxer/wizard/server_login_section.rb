require "etc"
require "securerandom"
require_relative "section"

module DevBoxer
  class Wizard
    class ServerLoginSection < Section
      TITLE = "Server login".freeze
      DEFAULT_USERNAME = "dev".freeze
      DEFAULT_SSH_PORT = 2222

      def self.owned_keys = %w[user ssh]

      def self.validate(hash, errors)
        %w[user.name user.ssh_public_key user.rdp_password ssh.port].each do |path|
          errors << "#{path} is required" if Config.blank?(hash.dig(*path.split(".")))
        end
        Config.validate_port(errors, "ssh.port", hash.dig("ssh", "port"))
        Config.validate_username(errors, hash.dig("user", "name"))
      end

      def collect(_so_far)
        explain_linux_username
        username = ask_valid("Linux username", default: existing.dig("user", "name") || default_username) do |value|
          username_problem(value)
        end
        explain_ssh_public_key
        ssh_key = ask_valid("SSH public key", default: existing.dig("user", "ssh_public_key") || default_ssh_public_key) do |value|
          SshKeyCheck.problem(value)
        end
        explain_ssh_port
        ssh_port = loop do
          port = ask_integer("SSH port", default: existing.dig("ssh", "port") || DEFAULT_SSH_PORT)
          break port if port.between?(1, 65_535)
          say "The SSH port must be between 1 and 65535."
        end
        rdp_password = existing.dig("user", "rdp_password") || SecureRandom.urlsafe_base64(18)

        [
          { "user" => { "name" => username, "ssh_public_key" => ssh_key },
            "ssh" => { "port" => ssh_port } },
          { "user" => { "rdp_password" => rdp_password } },
        ]
      end

      private

      def explain_linux_username
        say
        say "Linux username:"
        say "The Linux account you'll ssh into and do your work as."
        say "`dev` is fine if you don't have a preference; just avoid `root` — Dev Boxer disables root login regardless."
        say
      end

      def explain_ssh_public_key
        say
        say "SSH public key:"
        say "Paste the public half of your SSH key — a single line starting with `ssh-ed25519`, `ssh-rsa`, or `sk-ssh-...`."
        say "Dev Boxer drops it into the new account's authorized_keys and disables password auth, so this key is your only way in."
        say "If you don't already have one, run `ssh-keygen -t ed25519` on your laptop and paste `~/.ssh/id_ed25519.pub` (on macOS, `pbcopy < ~/.ssh/id_ed25519.pub` puts it on your clipboard)."
        say
      end

      def explain_ssh_port
        say
        say "SSH port:"
        say "Dev Boxer puts ssh on a non-standard port to cut down on the noise from automated scanners hammering port 22."
        say "2222 is the default; pick whatever you like between 1024 and 65535."
        say
      end

      def username_problem(value)
        errors = []
        Config.validate_username(errors, value)
        return "use lowercase letters, digits, - and _, starting with a letter" unless errors.empty?
        return "root can't be used: Dev Boxer turns off root login" if value == "root"

        uid = Etc.getpwnam(value).uid
        "#{value} is a system account; pick a different name" if uid < 1000
      rescue ArgumentError
        nil # no such user yet: it will be created
      end

      def default_username
        user = ENV["SUDO_USER"]
        return user if user && user != "root"
        DEFAULT_USERNAME
      end

      def default_ssh_public_key
        path = "/root/.ssh/authorized_keys"
        return nil unless File.exist?(path)
        line = File.readlines(path).map(&:strip).find { |l| !l.empty? && !l.start_with?("#") }
        return nil unless line
        # Cloud images often prefix the key with options such as
        # command="echo 'Please login as ...'", which would stop the new user
        # getting a shell. Keep only "type key [comment]".
        types = SshKeyCheck::KEY_TYPES.map { |t| Regexp.escape(t) }.join("|")
        line[/(?:#{types})\s+AAAA\S*(?:\s.*)?\z/] || line
      end
    end
  end
end
