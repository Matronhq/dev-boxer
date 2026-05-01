module DevBoxer
  module Modules
    class Security < ModuleBase
      module_name  "security"
      module_order 1

      def run
        section "Security hardening"
        configure_sshd
        configure_ufw
        configure_fail2ban
        configure_unattended_upgrades
        configure_email_relay if config.email&.resend_api_key
        configure_node_exporter if node_exporter_enabled?
        ok "Security hardening complete"
      end

      private

      def ssh_port = config.ssh&.port || 2222

      def configure_sshd
        info "Configuring SSH (sshd restart deferred until users have keys)"
        render_template("sshd_config", "/etc/ssh/sshd_config", { "SSH_PORT" => ssh_port })
        ok "SSH config deployed (port #{ssh_port}, key-only, no root login)"
      end

      def configure_ufw
        info "Configuring firewall"
        shell.apt_install("ufw") unless shell.command_exists?("ufw")

        unless shell.sh("ufw status | grep -q 'Status: active'")
          shell.sh!("ufw --force reset")
          shell.sh!("ufw default deny incoming")
          shell.sh!("ufw default allow outgoing")
        end

        shell.sh!("ufw allow #{ssh_port}/tcp comment SSH")

        if (rdp_ip = config.security&.rdp_allowed_ip)
          shell.sh!("ufw allow from #{rdp_ip} to any port 3389 proto tcp comment 'RDP from allowed IP'")
          ok "RDP allowed from #{rdp_ip}"
        end

        shell.sh!("ufw --force enable")
        ok "UFW enabled (deny incoming, allow SSH on #{ssh_port})"
      end

      def configure_fail2ban
        info "Configuring fail2ban"
        shell.apt_install("fail2ban")
        render_template("jail.local", "/etc/fail2ban/jail.local", { "SSH_PORT" => ssh_port })
        shell.systemctl(:enable, "fail2ban")
        shell.systemctl(:restart, "fail2ban")
        ok "fail2ban configured (SSH on #{ssh_port}, 6 retries, 5-min ban)"
      end

      def configure_unattended_upgrades
        info "Configuring automatic updates"
        shell.apt_install("unattended-upgrades", "apt-listchanges")

        FileUtils.cp(template_path("50unattended-upgrades"), "/etc/apt/apt.conf.d/50unattended-upgrades")
        FileUtils.cp(template_path("20auto-upgrades"),       "/etc/apt/apt.conf.d/20auto-upgrades")

        if config.email&.resend_api_key && config.email&.alert_email
          replacement = "Unattended-Upgrade::Mail \"#{config.email.alert_email}\";\\nUnattended-Upgrade::MailReport \"only-on-error\";"
          shell.sh!("sed -i 's|// MAIL_CONFIG_PLACEHOLDER|#{replacement}|' /etc/apt/apt.conf.d/50unattended-upgrades")
        end

        shell.systemctl(:enable, "unattended-upgrades")
        ok "Unattended-upgrades configured (security + regular, reboot at 03:00)"
      end

      def configure_email_relay
        info "Configuring email alerts via Resend"
        shell.apt_install("postfix", "libsasl2-modules")

        [
          "relayhost = [smtp.resend.com]:587",
          "smtp_sasl_auth_enable = yes",
          "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd",
          "smtp_sasl_security_options = noanonymous",
          "smtp_tls_security_level = encrypt",
          "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt",
          "inet_interfaces = loopback-only",
          "mydestination = ",
        ].each { |opt| shell.sh!("postconf -e '#{opt}'") }

        if (from = config.email&.from_address)
          shell.sh!("postconf -e 'myhostname = #{from.split('@', 2).last}'")
        end

        shell.write_file(
          "/etc/postfix/sasl_passwd",
          "[smtp.resend.com]:587 resend:#{config.email.resend_api_key}\n",
          mode: 0o600,
        )
        shell.sh!("postmap /etc/postfix/sasl_passwd")
        shell.systemctl(:enable, "postfix")
        shell.systemctl(:restart, "postfix")
        ok "Postfix configured as send-only relay via Resend"

        unless File.exist?("/etc/fail2ban/jail.local") && File.read("/etc/fail2ban/jail.local").include?("destemail")
          File.open("/etc/fail2ban/jail.local", "a") do |f|
            f.puts
            f.puts "[DEFAULT]"
            f.puts "destemail = #{config.email.alert_email}"
            f.puts "sender = #{config.email.from_address}"
            f.puts "mta = mail"
            f.puts "action = %(action_mwl)s"
          end
        end
        shell.systemctl(:restart, "fail2ban")
        ok "Fail2ban email alerts configured"
      end

      def node_exporter_enabled?
        config.monitoring&.node_exporter != false
      end

      def configure_node_exporter
        if shell.service_active?("prometheus-node-exporter")
          skip "Node exporter already running"
          return
        end
        info "Installing Prometheus node_exporter"
        shell.apt_install("prometheus-node-exporter")
        shell.write_file("/etc/default/prometheus-node-exporter", "ARGS=\"--web.listen-address=127.0.0.1:9100\"\n")
        shell.systemctl(:enable, "prometheus-node-exporter")
        shell.systemctl(:restart, "prometheus-node-exporter")
        ok "Node exporter installed (localhost:9100)"
      end
    end
  end
end
