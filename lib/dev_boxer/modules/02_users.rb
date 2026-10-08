module DevBoxer
  module Modules
    class Users < ModuleBase
      module_name  "users"
      module_order 2

      def run
        section "User setup"
        create_user
        configure_zsh
        grant_sudo
        configure_passwordless_sudo
        install_ssh_key
        set_rdp_password if config.user&.rdp_password
        seed_known_hosts
        restart_ssh_service
        ok "User setup complete"
      end

      private

      def username = config.user.name
      def home_dir = "/home/#{username}"

      def create_user
        if shell.user_exists?(username)
          skip "User #{username} already exists"
        else
          shell.sh!("useradd -m -s /bin/bash #{username}")
          ok "User #{username} created"
        end
      end

      def configure_zsh
        info "Setting up zsh"
        shell.apt_install("zsh")
        zsh = shell.sh!("command -v zsh").strip
        shell.sh!("chsh -s #{zsh} #{username}") unless zsh.empty?
        ok "Shell set to zsh"
      end

      def grant_sudo
        if shell.sh("groups #{username} | grep -q sudo")
          skip "User #{username} already in sudo group"
        else
          shell.sh!("usermod -aG sudo #{username}")
          ok "User #{username} added to sudo group"
        end
      end

      def configure_passwordless_sudo
        path = "/etc/sudoers.d/#{username}"
        if File.exist?(path)
          skip "Sudoers file already exists"
        else
          shell.write_file(path, "#{username} ALL=(ALL) NOPASSWD:ALL\n", mode: 0o440)
          ok "Passwordless sudo configured"
        end
      end

      def install_ssh_key
        ssh_dir = "#{home_dir}/.ssh"
        FileUtils.mkdir_p(ssh_dir)
        authorized = "#{ssh_dir}/authorized_keys"
        key = config.user&.ssh_public_key

        if key && !key.empty?
          existing = File.exist?(authorized) ? File.read(authorized) : ""
          if existing.include?(key)
            skip "SSH key already in authorized_keys"
          else
            File.open(authorized, "a") { |f| f.puts key }
            ok "SSH public key added"
          end
        end

        File.chmod(0o700, ssh_dir)
        File.chmod(0o600, authorized) if File.exist?(authorized)
        shell.sh!("chown -R #{username}:#{username} #{ssh_dir}")
      end

      # Pipe the user:password pair via stdin instead of interpolating into
      # a shell string — passwords with single quotes (or any shell-meaningful
      # characters) would otherwise break out of quoting.
      def set_rdp_password
        password = config.user.rdp_password
        shell.sh!("chpasswd", stdin: "#{username}:#{password}\n")
        ok "RDP password set"
      end

      def seed_known_hosts
        ssh_dir = "#{home_dir}/.ssh"
        known = "#{ssh_dir}/known_hosts"
        if File.exist?(known) && File.read(known).include?("github.com")
          skip "github.com already in known_hosts"
        else
          shell.sh!("ssh-keyscan -t ed25519,rsa github.com >> #{known} 2>/dev/null")
          shell.sh!("chown #{username}:#{username} #{known}")
          ok "github.com added to known_hosts"
        end
      end

      def restart_ssh_service
        info "Restarting SSH with hardened config"
        shell.systemctl(:restart, "ssh")
        ok "SSH restarted (key-only auth now active)"
      end
    end
  end
end
