require "fileutils"
require "shellwords"

module DevBoxer
  module Exposure
    # IP mode: nginx terminates TLS on the server's IP with one long-lived
    # self-signed cert (SAN = the IP). No domain, no Cloudflare. Apps must
    # accept/pin the cert (SP5); the summary prints the fingerprint they
    # verify against.
    class SelfSigned < Base
      CERT_DAYS = 3650

      def setup!
        ensure_cert!
        install_nginx
        write_nginx_config
        shell.sh!("nginx -t")
        shell.systemctl(:enable, "nginx")
        shell.systemctl(:restart, "nginx")
        open_firewall
        ok "Self-signed exposure ready on #{ip_address}"
      end

      def journal_public_url
        return config.journal&.url unless journal_bundled?
        "wss://#{ip_address}:#{journal_port}/ws"
      end

      def viewer_base_url = "https://#{ip_address}:#{viewer_port}"
      def hello_url = "https://#{ip_address}:#{hello_port}"

      def summary_lines
        lines = []
        lines << "Journal (Matron apps): #{journal_public_url}" if journal_bundled?
        lines << "Viewer:  #{viewer_base_url}"
        lines << "Hello:   #{hello_url}"
        lines << "Certificate SHA-256 fingerprint: #{fingerprint}"
        lines << "This box uses a self-signed certificate — your Matron apps will warn on"
        lines << "first connection. Accept only if the fingerprint above matches."
        lines
      end

      # Public for tests; pure string build so it can be asserted without FS.
      def nginx_config
        blocks = []
        blocks << server_block(journal_port, 9810) if journal_bundled?
        blocks << server_block(viewer_port, 9803)
        blocks << server_block(hello_port, hello_world_port)
        "# Managed by Dev Boxer — do not edit (see lib/dev_boxer/exposure/self_signed.rb)\n" +
          blocks.join("\n")
      end

      def firewall_ports
        ports = []
        ports << journal_port if journal_bundled?
        ports << viewer_port << hello_port
      end

      private

      def ip_config = config.exposure&.ip

      def ip_address
        configured = ip_config&.address
        return configured unless configured.to_s.empty?
        detected_ip
      end

      def detected_ip
        @detected_ip ||= begin
          out = shell.sh!("hostname -I").strip rescue ""
          ip = out.split(/\s+/).reject(&:empty?).first
          raise "Could not auto-detect this server's IP (hostname -I returned nothing); set exposure.ip.address in config.yml" if ip.nil?
          ip
        end
      end

      def journal_port = ip_config&.journal_port || 8443
      def viewer_port  = ip_config&.viewer_port || 8444
      def hello_port   = ip_config&.hello_port || 8445

      def tls_dir = "/etc/matron/tls"
      def cert_path = "#{tls_dir}/cert.pem"
      def key_path = "#{tls_dir}/key.pem"
      def nginx_site_path = "/etc/nginx/sites-available/matron"
      def nginx_enabled_path = "/etc/nginx/sites-enabled/matron"

      def ensure_cert!
        FileUtils.mkdir_p(tls_dir)
        File.chmod(0o700, tls_dir)
        if File.exist?(cert_path)
          if san_matches?
            skip "TLS certificate already present for #{ip_address}"
            return
          end
          warn "TLS certificate SAN no longer matches #{ip_address} (IP changed?) — regenerating."
          warn "Matron apps that pinned the old certificate must re-accept the new one."
        end
        info "Generating self-signed certificate for #{ip_address} (#{CERT_DAYS} days)"
        shell.sh!(
          "openssl req -x509 -newkey rsa:2048 -sha256 -days #{CERT_DAYS} -nodes " \
          "-keyout #{key_path} -out #{cert_path} " \
          "-subj /CN=#{Shellwords.escape(ip_address)} " \
          "-addext subjectAltName=IP:#{Shellwords.escape(ip_address)}"
        )
        File.chmod(0o600, key_path) if File.exist?(key_path)
        ok "Certificate written to #{cert_path}"
      end

      def san_matches?
        out = shell.sh!("openssl x509 -in #{cert_path} -noout -ext subjectAltName") rescue ""
        out.include?("IP Address:#{ip_address}")
      end

      def fingerprint
        return "(certificate not generated yet)" unless File.exist?(cert_path)
        out = shell.sh!("openssl x509 -in #{cert_path} -noout -fingerprint -sha256").strip
        out.split("=", 2).last
      end

      def install_nginx
        if shell.command_exists?("nginx")
          skip "nginx already installed"
          return
        end
        info "Installing nginx"
        shell.apt_update
        shell.apt_install("nginx")
      end

      def write_nginx_config
        shell.write_file(nginx_site_path, nginx_config)
        shell.sh!("ln -sf #{nginx_site_path} #{nginx_enabled_path}") unless nginx_site_path == nginx_enabled_path
        ok "nginx TLS config deployed"
      end

      def server_block(listen_port, upstream_port)
        <<~NGINX
          server {
            listen #{listen_port} ssl;
            ssl_certificate #{cert_path};
            ssl_certificate_key #{key_path};
            location / {
              proxy_pass http://127.0.0.1:#{upstream_port};
              proxy_http_version 1.1;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "upgrade";
              proxy_set_header Host $host;
              proxy_set_header X-Forwarded-For $remote_addr;
              proxy_read_timeout 7d;
              proxy_send_timeout 7d;
            }
          }
        NGINX
      end

      def open_firewall
        firewall_ports.each { |port| shell.sh!("ufw allow #{port}/tcp") }
        ok "Firewall allows: #{firewall_ports.join(', ')}"
      end
    end
  end
end
