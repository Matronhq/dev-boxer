require "yaml"

module DevBoxer
  module Modules
    # Deploys a tiny local HTTP server used to verify that a Cloudflare
    # Tunnel hostname actually reaches this machine, independent of the
    # rest of the stack.
    class HelloWorld < ModuleBase
      module_name  "hello-world"
      module_order 11

      DOC_ROOT      = "/opt/dev-boxer-hello-world".freeze
      SERVICE_PATH  = "/etc/systemd/system/dev-boxer-hello-world.service".freeze

      def run
        section "Hello world smoke-test service"

        port = config.hello_world&.port || 9810
        deploy_doc_root
        deploy_unit(port)
        shell.sh!("systemctl daemon-reload")
        shell.systemctl(:enable, "dev-boxer-hello-world")
        shell.systemctl(:restart, "dev-boxer-hello-world")
        ok "Hello-world service running on http://localhost:#{port}"
        print_matrix_login_instructions
      end

      private

      def username = config.user.name
      def home_dir = "/home/#{username}"

      def deploy_doc_root
        FileUtils.mkdir_p(DOC_ROOT)
        File.chmod(0o755, DOC_ROOT)
        File.write("#{DOC_ROOT}/index.html", "Hello world\n")
      end

      def deploy_unit(port)
        File.write(SERVICE_PATH, <<~UNIT)
          [Unit]
          Description=Dev Boxer hello-world tunnel smoke test
          After=network.target

          [Service]
          Type=simple
          WorkingDirectory=#{DOC_ROOT}
          ExecStart=/usr/bin/python3 -m http.server #{port} --bind 127.0.0.1
          Restart=on-failure
          User=nobody
          Group=nogroup

          [Install]
          WantedBy=multi-user.target
        UNIT
      end

      def print_matrix_login_instructions
        details = matrix_login_details
        return unless details

        info ""
        info "=========================================="
        info "  Matrix bridge — first login"
        info "=========================================="
        if details[:mode] == "external"
          info "Open Element (web/desktop) and sign in to your existing account:"
          info "  Homeserver URL: #{details[:homeserver_url]}"
          info "  User ID: #{details[:user_id]}"
          info "  Password: (use your existing #{details[:server_domain]} account password)"
          info "  Secure Backup recovery key: (use your existing recovery key)"
        else
          info "Open Matron:"
          info "  URL: #{details[:homeserver_url]}"
          info "  User ID: #{details[:user_id]}"
          info "  Password: #{details[:password] || '(missing from secrets.yml)'}"
          info "  Secure Backup recovery key: #{details[:recovery_key] || '(not found; check ~/recovery-key.txt if still present)'}"
        end
        info ""
        info "After login, open the 'Claude Code Bridge' room and send !start."
      end

      def matrix_login_details
        hash = merged_config_hash
        matrix = hash["matrix"] || {}
        return nil if matrix["mode"] == "disabled"

        mode = matrix["mode"] || "bundled"
        server_domain = matrix["server_domain"] || "your-domain"
        user_username = matrix["user_username"] || username

        homeserver_url =
          if mode == "external"
            # In external mode the homeserver lives elsewhere; matrix.homeserver_url
            # is the only correct URL. cloudflare.tunnel.hostname_matrix points at
            # a local Matron container that doesn't exist in this mode.
            matrix["homeserver_url"] || "https://#{server_domain}"
          else
            matrix_hostname = hash.dig("cloudflare", "tunnel", "hostname_matrix") || server_domain
            public_url(matrix_hostname)
          end

        {
          mode: mode,
          server_domain: server_domain,
          homeserver_url: homeserver_url,
          user_id: "@#{user_username}:#{server_domain}",
          password: matrix["user_password"],
          recovery_key: matrix_recovery_key,
        }
      end

      def merged_config_hash
        base = config.respond_to?(:to_h) ? config.to_h : {}
        return base unless secrets_path && File.exist?(secrets_path)

        Config.deep_merge(base, YAML.safe_load_file(secrets_path) || {})
      end

      def public_url(hostname)
        value = hostname.to_s
        value.start_with?("http://", "https://") ? value : "https://#{value}"
      end

      def matrix_recovery_key
        path = "#{home_dir}/recovery-key.txt"
        return nil unless File.exist?(path)

        File.readlines(path)
          .map(&:strip)
          .reject { |line| line.empty? || line.start_with?("#") }
          .last
      end
    end
  end
end
