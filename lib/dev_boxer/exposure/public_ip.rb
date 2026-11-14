require "shellwords"

module DevBoxer
  module Exposure
    # A real ACME IP certificate, never a self-signed fallback. The journal
    # and viewer use different origins so a shared artifact cannot act as
    # the signed-in journal app.
    class PublicIp < Base
      CERTBOT = "/opt/matron-certbot/bin/certbot".freeze
      ACME_ROOT = "/var/lib/matron-acme".freeze
      CERT_DIR = "/etc/letsencrypt/live/matron-ip".freeze
      SITE = "/etc/nginx/sites-available/matron-starter".freeze
      LOCK = "/run/lock/matron-certificate.lock".freeze

      def address = config.exposure.ip.address
      def journal_public_url = journal_bundled? ? "wss://#{address}/ws" : config.journal.url
      def viewer_base_url = "https://#{address}:8444"
      def hello_url = "https://#{address}/app/"
      def summary_lines = ["Open Matron: #{JournalEnrollment.https_base(journal_public_url)}/app/", "Viewer: #{viewer_base_url}"]

      def setup!
        problem = StarterWizard.address_problem(address.to_s)
        raise SetupError, problem if problem
        raise SetupError, "Certificate terms must be accepted during setup." unless config.exposure.accept_terms == true
        shell.apt_install("nginx", "python3-venv")
        shell.sh!("python3 -m venv /opt/matron-certbot") unless shell.command_exists?(CERTBOT)
        shell.sh!("#{CERTBOT.sub(/certbot$/, 'pip')} install 'certbot==5.10.0'")
        shell.sh!("install -d -m 755 #{ACME_ROOT}")
        shell.write_file(SITE, nginx_config(tls: File.exist?("#{CERT_DIR}/fullchain.pem")))
        shell.sh!("ln -sfn #{SITE} /etc/nginx/sites-enabled/matron-starter")
        # This mode is for a fresh VPS. Existing sites are not removed.
        shell.sh!("nginx -t")
        shell.systemctl(:enable, "nginx")
        shell.systemctl(:restart, "nginx")
        [80, 443, 8444].each { |port| shell.sh!("ufw allow #{port}/tcp") }
        info "Obtaining the HTTPS certificate (waiting for any renewal already running)"
        shell.sh!("flock -w 600 #{LOCK} #{issue_command}")
        shell.write_file(SITE, nginx_config(tls: true))
        shell.sh!("nginx -t")
        shell.systemctl(:reload, "nginx")
        install_renewal
        ok "Trusted HTTPS ready; certificates renew automatically"
      end

      def issue_command
        "#{CERTBOT} certonly --non-interactive --agree-tos --register-unsafely-without-email " \
          "--preferred-profile shortlived --webroot --webroot-path #{ACME_ROOT} " \
          "--cert-name matron-ip --ip-address #{Shellwords.escape(address)} --keep-until-expiring"
      end

      def nginx_config(tls:)
        text = <<~NGINX
          # Managed by Matron setup.
          server {
            listen 80;
            server_name #{address};
            location /.well-known/acme-challenge/ { root #{ACME_ROOT}; }
            location / { return 404; }
          }
        NGINX
        return text unless tls
        text += server(443, 9810) if journal_bundled?
        text + server(8444, 9803)
      end

      private

      def server(port, upstream)
        <<~NGINX
          server {
            listen #{port} ssl;
            server_name #{address};
            ssl_certificate #{CERT_DIR}/fullchain.pem;
            ssl_certificate_key #{CERT_DIR}/privkey.pem;
            client_max_body_size 50m;
            location / {
              proxy_pass http://127.0.0.1:#{upstream};
              proxy_http_version 1.1;
              proxy_set_header Host $http_host;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "upgrade";
              proxy_set_header CF-Connecting-IP $remote_addr;
              proxy_set_header X-Forwarded-For $remote_addr;
              proxy_set_header X-Forwarded-Proto https;
              proxy_read_timeout 1d;
              proxy_buffering off;
            }
          }
        NGINX
      end

      def install_renewal
        shell.write_file("/etc/systemd/system/matron-certificate.service", <<~UNIT)
          [Unit]
          Description=Renew Matron HTTPS certificate
          After=network-online.target nginx.service
          [Service]
          Type=oneshot
          ExecStart=/usr/bin/flock -w 600 #{LOCK} #{CERTBOT} renew --cert-name matron-ip --quiet --no-random-sleep-on-renew --deploy-hook "nginx -t && systemctl reload nginx"
        UNIT
        shell.write_file("/etc/systemd/system/matron-certificate.timer", <<~UNIT)
          [Unit]
          Description=Check Matron certificate renewal twice daily
          [Timer]
          OnCalendar=*-*-* 00,12:00:00
          RandomizedDelaySec=1800
          Persistent=true
          [Install]
          WantedBy=timers.target
        UNIT
        shell.sh!("systemctl daemon-reload")
        shell.sh!("systemctl enable --now matron-certificate.timer")
      end
    end
  end
end
