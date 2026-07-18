require "yaml"
require "shellwords"

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

        port = hello_port
        deploy_doc_root
        deploy_unit(port)
        shell.sh!("systemctl daemon-reload")
        shell.systemctl(:enable, "dev-boxer-hello-world")
        shell.systemctl(:restart, "dev-boxer-hello-world")
        ok "Hello-world service running on http://localhost:#{port}"
        print_matron_login_instructions
      end

      private

      def username = config.user.name
      def hello_port = config.hello_world&.port || 9820

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

      def print_matron_login_instructions
        info ""
        info "=========================================="
        info "  Matron — first login"
        info "=========================================="
        if config.journal&.mode == "external"
          info "This box's bridge is connected to your existing journal:"
          info "  Server: #{config.journal&.url}"
          info "Open the Matron app with your existing account — this box appears"
          info "under Settings -> Devices once the bridge connects."
        else
          secrets = merged_config_hash
          journal_user = secrets.dig("journal", "username") || username
          info "Open the Matron app (iOS / desktop / web) and add this server:"
          info "  Server:   #{exposure.journal_public_url}"
          info "  Username: #{journal_user}"
          info "  Password: #{secrets.dig('journal', 'user_password') || '(missing from secrets.yml)'}"
          print_first_phone_qr(journal_user)
        end
        # Single end-of-run connection summary (modules 09/10 no longer repeat
        # it). The journal URL was just printed above as "Server:", so skip
        # summary_lines' duplicate "Journal (Matron apps):" entry.
        exposure.summary_lines.each do |line|
          next if line.start_with?("Journal (Matron apps):")
          info line
        end
        info ""
        info "If the agent token is ever revoked, re-enroll with: sudo bin/enroll"
      end

      # Prints matron-admin link-code's ANSI QR: scanning it signs the first
      # phone straight into the journal account (pre-approved link code, no
      # approve tap). Best-effort — on any failure the username/password
      # printed above still work.
      def print_first_phone_qr(journal_user)
        server = JournalEnrollment.https_base(exposure.journal_public_url)
        out = shell.sh!(JournalEnrollment.matron_admin_command(
          "link-code #{Shellwords.escape(journal_user)} --server-url #{Shellwords.escape(server)}"
        ))
        info ""
        info "Or scan this QR with the Matron app to sign the first phone in (valid ~10 minutes):"
        out.each_line { |line| info line.chomp }
      rescue Shell::Error => e
        warn "Couldn't mint a sign-in QR (#{e.message.lines.first&.strip}) — sign in with the username/password above."
      end

      def merged_config_hash
        base = config.respond_to?(:to_h) ? config.to_h : {}
        return base unless secrets_path && File.exist?(secrets_path)
        Config.deep_merge(base, YAML.safe_load_file(secrets_path) || {})
      end
    end
  end
end
