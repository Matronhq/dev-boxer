require "securerandom"
require "shellwords"
require_relative "../journal_enrollment"

module DevBoxer
  module Modules
    # Matron chat stack: matron-journal (bundled mode only) + matron-bridge.
    #
    #   journal.mode: bundled  — install matron-journal on this box
    #     (loopback :9810), create the journal user, mint the agent token
    #     locally. Remote clients reach it through the Exposure layer.
    #   journal.mode: external — the bridge talks to a central journal over
    #     wss://; the agent token comes from a pre-provisioned file or
    #     app-approved pairing (JournalEnrollment).
    class Matron < ModuleBase
      module_name  "matron"
      module_order 8

      JOURNAL_REPO = "https://github.com/Matronhq/matron-journal.git".freeze
      BRIDGE_REPO  = "https://github.com/Matronhq/matron-bridge.git".freeze
      JOURNAL_DIR  = JournalEnrollment::JOURNAL_DIR
      JOURNAL_LOCAL_HTTP = "http://127.0.0.1:9810".freeze
      JOURNAL_LOCAL_WS   = "ws://127.0.0.1:9810/ws".freeze

      def run
        section "Matron chat stack"

        case journal_mode
        when "bundled"
          install_journal
          ensure_journal_user
        when "external"
          probe_external_journal!
        else
          raise "Unknown journal.mode: #{journal_mode.inspect} (expected bundled or external)"
        end

        token_file = enrollment.resolve!
        install_bridge
        write_bridge_env(token_file)
        write_mcp_config
        install_systemd_units
        ok "Matron chat stack ready"
      end

      private

      def journal_mode = config.journal&.mode || "bundled"
      def username = config.user.name
      def home_dir = "/home/#{username}"
      def bridge_dir = "#{home_dir}/matron-bridge"
      def journal_username = config.journal&.username || username
      def unit_dir = "/etc/systemd/system"

      def enrollment
        @enrollment ||= JournalEnrollment.new(
          config: config, shell: shell, log: log, interactive: interactive?,
        )
      end

      # ----- bundled journal -----

      def install_journal
        unless shell.user_exists?("matron")
          shell.sh!("useradd --system --home-dir #{JOURNAL_DIR} --shell /usr/sbin/nologin matron")
          ok "System user matron created"
        end

        if Dir.exist?(JOURNAL_DIR)
          skip "matron-journal already cloned"
          shell.sh!(as_matron("git -C #{JOURNAL_DIR} pull --ff-only"))
        else
          info "Cloning matron-journal"
          shell.sh!("git clone #{JOURNAL_REPO} #{JOURNAL_DIR}")
          shell.sh!("chown -R matron:matron #{JOURNAL_DIR}")
        end

        info "Installing matron-journal dependencies"
        shell.sh!(as_matron("cd #{JOURNAL_DIR} && npm ci --omit=dev"))
        shell.sh!(as_matron("mkdir -p #{JOURNAL_DIR}/data"))

        FileUtils.cp("#{JOURNAL_DIR}/deploy/matron-journal.service", "#{unit_dir}/matron-journal.service")
        shell.sh!("systemctl daemon-reload")
        shell.systemctl(:enable, "matron-journal")
        shell.systemctl(:restart, "matron-journal")

        # /metrics 401s without a token — any HTTP status means it's up.
        unless shell.wait_for_http("#{JOURNAL_LOCAL_HTTP}/metrics", timeout: 30)
          raise "matron-journal failed to start. Check: journalctl -u matron-journal"
        end
        ok "matron-journal running on loopback :9810"
      end

      # Run journal admin/file commands as the matron user — root would
      # leave root-owned SQLite WAL files / git objects behind and break
      # the service (git also refuses cross-owner repos).
      def as_matron(cmd)
        "runuser -u matron -- sh -c #{Shellwords.escape(cmd)}"
      end

      def matron_admin(args)
        JournalEnrollment.matron_admin_command(args)
      end

      def ensure_journal_user
        unless config.journal&.user_password.to_s.empty?
          skip "Journal user #{journal_username} already onboarded (password in secrets.yml)"
          return
        end

        password = SecureRandom.urlsafe_base64(18)
        if journal_user_exists?
          # Partial earlier run: user exists but the password was never
          # recorded. matron-admin user passwd converges us.
          info "Journal user #{journal_username} exists but secrets.yml has no password — resetting it"
          shell.sh!(matron_admin("user passwd #{Shellwords.escape(journal_username)} --password #{Shellwords.escape(password)}"))
        else
          info "Creating journal user #{journal_username}"
          shell.sh!(matron_admin("user add #{Shellwords.escape(journal_username)} --password #{Shellwords.escape(password)}"))
        end
        persist_journal_secrets(password)
        ok "Journal user #{journal_username} ready — the password in secrets.yml is your Matron app login"
      end

      def journal_user_exists?
        shell.sh(matron_admin("device list #{Shellwords.escape(journal_username)}") + " >/dev/null 2>&1")
      end

      def persist_journal_secrets(password)
        raise "secrets_path not provided to runner" unless secrets_path
        Config.merge_into_file(secrets_path, {
          "journal" => { "username" => journal_username, "user_password" => password },
        })
      end

      # ----- external journal -----

      def probe_external_journal!
        url = config.journal&.url
        raise "journal.url is required when journal.mode is external" if url.to_s.empty?
        base = JournalEnrollment.https_base(url)
        info "Probing external journal at #{base}"
        result = JournalEnrollment.probe(base, ca_file: config.journal&.ca_file)
        unless result == :ok
          raise "External journal unreachable at #{base}: #{result}\n" \
                "Refusing to install a bridge that would crash-loop — fix journal.url/journal.ca_file and re-run."
        end
        ok "External journal reachable"
      end

      # ----- bridge -----

      def install_bridge
        if Dir.exist?(bridge_dir)
          skip "matron-bridge already cloned"
          shell.sh("su - #{username} -c 'cd #{bridge_dir} && git pull --ff-only'")
        else
          ensure_dev_user_can_clone
          info "Cloning matron-bridge"
          shell.run_as_user(username, "git clone #{BRIDGE_REPO} #{bridge_dir}")
        end

        if Dir.exist?("#{bridge_dir}/node_modules")
          skip "npm dependencies already installed"
        else
          info "Installing npm dependencies"
          shell.run_as_user(username, "cd #{bridge_dir} && npm install")
        end
        ok "matron-bridge installed"
      end

      # matron-bridge is public, so this probe normally passes silently;
      # it still matters for private forks (BRIDGE_REPO overridden).
      def ensure_dev_user_can_clone
        probe = "GIT_TERMINAL_PROMPT=0 git ls-remote #{Shellwords.escape(BRIDGE_REPO)} HEAD >/dev/null 2>&1"
        if shell.sh("su - #{Shellwords.escape(username)} -c #{Shellwords.escape(probe)}")
          return
        end

        unless interactive?
          raise "#{username} cannot clone #{BRIDGE_REPO}; re-run interactively so we can run `gh auth login --web` as #{username}"
        end

        info "GitHub auth required for #{username} to clone the bridge repo"
        info "About to run: gh auth login --web --git-protocol https --hostname github.com (as #{username})"
        info "You'll see a one-time code and a URL — open the URL in any browser, paste the code, and authorize."
        shell.run_as_user_interactive(username, "gh auth login --web --git-protocol https --hostname github.com")
        shell.run_as_user_interactive(username, "gh auth setup-git")
        ok "GitHub CLI authenticated for #{username}"
      end

      def write_bridge_env(token_file)
        info "Generating bridge .env"
        render_template("matron-bridge.env", "#{bridge_dir}/.env", bridge_env_vars(token_file), mode: 0o600)
        shell.sh!("chown #{username}:#{username} #{bridge_dir}/.env")
        ok "Bridge .env generated"
      end

      # Memoised: rendered into .env + mcp config within one run, and
      # HMAC_SECRET must be identical across those renders. Persisted so
      # re-runs keep old viewer links valid.
      def bridge_env_vars(token_file = nil)
        @bridge_env_vars ||= {
          "JOURNAL_WS_URL" => journal_ws_url,
          "JOURNAL_TOKEN_FILE" => token_file,
          "USERNAME" => username,
          "HMAC_SECRET" => hmac_secret,
          "VIEWER_BASE_URL" => exposure.viewer_base_url,
          "NODE_EXTRA_CA_LINE" => node_extra_ca_line,
        }
      end

      def journal_ws_url
        journal_mode == "bundled" ? JOURNAL_LOCAL_WS : config.journal.url
      end

      def hmac_secret
        existing = config.bridge&.hmac_secret
        return existing unless existing.to_s.empty?
        generated = SecureRandom.hex(32)
        Config.merge_into_file(secrets_path, { "bridge" => { "hmac_secret" => generated } }) if secrets_path
        generated
      end

      def node_extra_ca_line
        ca = config.journal&.ca_file
        ca.to_s.empty? ? "" : "NODE_EXTRA_CA_CERTS=#{ca}"
      end

      def write_mcp_config
        info "Generating bridge MCP config"
        render_template("mcp-config.json", "#{bridge_dir}/mcp-config-generated.json", bridge_env_vars)
        shell.sh!("chown #{username}:#{username} #{bridge_dir}/mcp-config-generated.json")
        ok "Bridge MCP config generated"
      end

      def install_systemd_units
        info "Installing systemd services"
        render_template("matron-bridge.service", "#{unit_dir}/matron-bridge.service", bridge_env_vars)
        render_template("matron-viewer.service", "#{unit_dir}/matron-viewer.service", bridge_env_vars)
        shell.sh!("systemctl daemon-reload")
        shell.systemctl(:enable, "matron-bridge")
        shell.systemctl(:enable, "matron-viewer")
        shell.systemctl(:restart, "matron-bridge")
        shell.systemctl(:restart, "matron-viewer")
        ok "Bridge services installed and started"
      end
    end
  end
end
