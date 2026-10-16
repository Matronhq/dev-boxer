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

      def ssh_port = config.ssh&.port || 2222

      # This restart turns on key-only login on the new port, so check first
      # that it cannot lock the operator out: a usable key is installed, the
      # config parses, and afterwards sshd really listens on the new port.
      def restart_ssh_service
        problem = SshKeyCheck.problem(config.user&.ssh_public_key)
        if problem
          raise SetupError, "Not restarting SSH: user.ssh_public_key in config.yml is not usable (#{problem}).\n" \
                            "Password login would be turned off, locking you out. Fix the key, then re-run: sudo ./setup.rb --from users"
        end
        unless shell.sh("sshd -t")
          raise SetupError, "Not restarting SSH: `sshd -t` rejects /etc/ssh/sshd_config.\n" \
                            "Run `sshd -t` to see why, fix it, then re-run: sudo ./setup.rb --from security"
        end

        info "Restarting SSH with hardened config"
        # Ubuntu 22.10+ starts sshd from ssh.socket, which keeps listening on
        # the old port until systemd regenerates it from sshd_config.
        if shell.sh("systemctl is-active --quiet ssh.socket")
          shell.sh!("systemctl daemon-reload")
          shell.systemctl(:restart, "ssh.socket")
        end
        shell.systemctl(:restart, "ssh")

        unless shell.sh("ss -ltnH 'sport = :#{Integer(ssh_port)}' | grep -q LISTEN")
          raise SetupError, "SSH is not listening on port #{ssh_port} after the restart. Keep this session open.\n" \
                            "Check `systemctl status ssh ssh.socket` and `ss -ltn`, fix it, then re-run: sudo ./setup.rb --from users"
        end
        ok "SSH restarted on port #{ssh_port} (key-only auth now active)"
      end
    end
  end
end
