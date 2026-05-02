require "json"
require "net/http"
require "securerandom"
require "shellwords"
require "uri"
require "yaml"
require_relative "../matrix_registration"

module DevBoxer
  module Modules
    # Matrix bridge module — bundled, external, or disabled.
    #
    # In bundled mode, this performs full first-login onboarding:
    #   1. Run Matron Server locally
    #   2. Clone claude-matrix-bridge + npm install
    #   3. Open a registration window on the homeserver
    #   4. Register the bot (per-box, e.g. claude-bot-<host>)
    #   5. Run setup-user.mjs from the bridge repo, which:
    #      - Registers the human user
    #      - Bootstraps secret storage with a recovery key
    #      - Cross-signs the bot from the user side (Element shows verified)
    #   6. Login as bot, create encrypted bridge room, invite user
    #   7. Close registration window
    #   8. Persist all credentials (bot_access_token, recovery_key, etc.) to
    #      config.yml so re-runs are idempotent
    #
    # End result: the user opens Element, signs in with username + password +
    # recovery key, the bridge room is already there, the bot is already
    # verified, and !start works immediately.
    class MatrixBridge < ModuleBase
      module_name  "matrix-bridge"
      module_order 8

      HOMESERVER_LOCAL = "http://localhost:6167".freeze
      BRIDGE_REPO = "https://github.com/matronhq/claude-matrix-bridge.git".freeze

      def run
        section "Matrix bridge"

        case mode
        when "disabled"
          skip "Matrix bridge disabled in config"
          return
        when "bundled"
          start_matron_server
          clone_bridge_repo
          npm_install
          patch_bridge_setup_user
          onboard_users_if_needed
        when "external"
          info "Using external homeserver: #{config.matrix.homeserver_url}"
          clone_bridge_repo
          npm_install
          patch_bridge_setup_user
        else
          raise "Unknown matrix.mode: #{mode.inspect} (expected bundled, external, or disabled)"
        end

        write_bridge_env
        write_mcp_config
        install_systemd_units
        ok "Matrix bridge setup complete"
      end

      private

      def mode = config.matrix&.mode || "bundled"
      def username = config.user.name
      def home_dir = "/home/#{username}"
      def bridge_dir = "#{home_dir}/claude-matrix-bridge"
      def matrix_server_dir = "#{home_dir}/matrix-server"

      def server_domain
        s = config.matrix&.server_domain
        if s.nil? || s.to_s.empty?
          raise "matrix.server_domain is not set in config.yml — set it to your matrix server name " \
                "(e.g. matrix.example.com). It cannot be defaulted because user IDs and the matron " \
                "server identity are derived from it."
        end
        s
      end
      def user_username  = config.matrix&.user_username  || username
      def bot_username   = config.matrix&.bot_username   || default_bot_username
      def bot_user_id    = "@#{bot_username}:#{server_domain}"
      def user_id        = "@#{user_username}:#{server_domain}"
      def homeserver_url = mode == "bundled" ? HOMESERVER_LOCAL : config.matrix.homeserver_url

      def default_bot_username
        host = shell.sh!("hostname -s").strip rescue "host"
        "claude-bot-#{host}"
      end

      # ----- bundled homeserver -----

      def start_matron_server
        info "Setting up bundled Matron Server"
        FileUtils.mkdir_p(matrix_server_dir)
        render_template(
          "docker-compose.matron-server.yml",
          "#{matrix_server_dir}/docker-compose.yml",
          { "MATRIX_SERVER_DOMAIN" => server_domain },
        )
        shell.sh!("chown -R #{username}:#{username} #{matrix_server_dir}")

        info "Starting Matron Server"
        shell.run_as_user(username, "cd #{matrix_server_dir} && docker compose up -d")
        unless shell.wait_for_url("#{HOMESERVER_LOCAL}/_matrix/client/versions", timeout: 30)
          raise "Matron Server failed to start. Check: docker logs matron-server"
        end
        ok "Matron Server is running"
      end

      def onboard_users_if_needed
        token = config.matrix&.bot_access_token
        # Reject empty string explicitly: it's truthy in Ruby, so a config
        # with `bot_access_token: ""` (e.g. operator zero'd it manually) would
        # otherwise short-circuit and skip the onboarding flow.
        unless token.nil? || token.to_s.empty?
          skip "Matrix accounts already onboarded (bot_access_token in config)"
          return
        end
        onboard_users
      end

      # The full first-login flow: open registration, register bot, run
      # setup-user.mjs (registers + bootstraps + cross-signs), login bot,
      # create room, close registration.
      def onboard_users
        info "Onboarding Matrix bot + user (cross-signed first-login flow)"
        reg_token     = SecureRandom.hex(16)
        bot_password  = config.matrix&.bot_password || SecureRandom.hex(16)
        user_password = config.matrix&.user_password || SecureRandom.hex(16)
        persist_partial_onboarding_passwords(bot_password, user_password)

        # open_registration writes docker-compose.override.yml — if it (or
        # the post-restart wait_for_url) raises, close_registration must
        # still run to clean up the override and re-restart with
        # registration disabled. Wrap the whole window in begin/ensure.
        begin
          open_registration(reg_token)
          ok "Registration window open"

          register_bot_via_api(bot_password, reg_token)
          ok "Bot account #{bot_user_id} registered"

          recovery_key = run_setup_user_mjs(user_password, reg_token)
          ok "User #{user_id} registered, secret storage bootstrapped, bot cross-signed"

          bot_token = login_bot(bot_password)
          ok "Bot access token obtained"

          room_id = create_bridge_room(bot_token)
          ok room_id ? "Bridge room created: #{room_id}" : "Bridge room creation skipped (manual fallback)"

          @generated_credentials = {
            bot_username: bot_username,
            bot_access_token: bot_token,
            bot_password: bot_password,
            user_username: user_username,
            user_password: user_password,
            recovery_key: recovery_key,
            bridge_room_id: room_id,
            hmac_secret: SecureRandom.hex(32),
            server_domain: server_domain,
          }
          # Order matters: write the recovery-key file BEFORE persisting the
          # bot_access_token. If recovery-key write fails, the next run still
          # sees no bot_access_token in secrets.yml and re-runs onboarding
          # (which rotates bot creds anyway). Reverse order would leave the
          # operator with bot creds but no way to log into Element.
          write_recovery_key_file(recovery_key)
          persist_secrets
        ensure
          close_registration
          ok "Registration window closed"
        end
      end

      def open_registration(reg_token)
        matrix_registration.open(reg_token)
      end

      def close_registration
        matrix_registration.close
      end

      def register_bot_via_api(password, reg_token)
        matrix_registration.register_bot(username: bot_username, password: password, reg_token: reg_token)
      end

      def matrix_registration
        @matrix_registration ||= MatrixRegistration.new(
          matrix_server_dir: matrix_server_dir,
          username: username,
          shell: shell,
          log: log,
        )
      end

      # Use a tmpfs path so the recovery_key + password never hit a real disk.
      #
      # Shell-escape every interpolated value: `user_password` is auto-
      # generated entropy that may contain shell-significant characters
      # (rare but real with bytes-to-hex), and `user_username` /
      # `bot_user_id` come from config so they're operator-controlled but
      # we still want to fail the command rather than execute unintended
      # shell on bad input.
      def run_setup_user_mjs(user_password, reg_token)
        creds_path = "/dev/shm/dev-boxer-matrix-#{SecureRandom.hex(8)}"
        shell.run_as_user(username, "touch #{Shellwords.escape(creds_path)} && chmod 600 #{Shellwords.escape(creds_path)}")
        cmd = [
          "MATRIX_HOMESERVER_URL=#{Shellwords.escape(HOMESERVER_LOCAL)}",
          "REG_TOKEN=#{Shellwords.escape(reg_token)}",
          "node",
          Shellwords.escape("#{bridge_dir}/setup-user.mjs"),
          Shellwords.escape(user_username),
          "--password", Shellwords.escape(user_password),
          "--bot", Shellwords.escape(bot_user_id),
          "--credentials-file", Shellwords.escape(creds_path),
        ].join(" ")
        shell.run_as_user(username, cmd)

        contents = shell.sh!("cat #{creds_path}")
        # setup-user.mjs writes a shell-source-able file: key='value'
        recovery_key = contents.match(/^recovery_key=['"]?([^'"\n]+)['"]?$/)&.[](1)
        raise "setup-user.mjs did not write recovery_key to #{creds_path}" if recovery_key.nil? || recovery_key.empty?
        recovery_key
      ensure
        shell.run_as_user(username, "rm -f #{creds_path}") if creds_path
      end

      def persist_partial_onboarding_passwords(bot_password, user_password)
        raise "secrets_path not provided to runner" unless secrets_path

        existing = File.exist?(secrets_path) ? (YAML.safe_load_file(secrets_path) || {}) : {}
        merged = Config.deep_merge(existing, {
          "matrix" => {
            "bot_username" => bot_username,
            "bot_password" => bot_password,
            "user_username" => user_username,
            "user_password" => user_password,
            "server_domain" => server_domain,
          },
        })
        FileUtils.mkdir_p(File.dirname(secrets_path))
        body = header_for_secrets_file + merged.to_yaml.sub(/\A---\n/, "")
        write_secret_file(secrets_path, body, mode: 0o600)
        ok "Partial Matrix onboarding credentials persisted to #{secrets_path}"
      end

      def login_bot(password)
        body = {
          type: "m.login.password",
          identifier: { type: "m.id.user", user: bot_username },
          password: password,
        }
        resp = http_post("/_matrix/client/v3/login", body)
        resp["access_token"] or raise "Bot login failed: #{resp.inspect}"
      end

      def create_bridge_room(bot_token)
        body = {
          name: "Claude Code Bridge",
          topic: "Messages in this room are forwarded to Claude Code",
          visibility: "private",
          preset: "private_chat",
          invite: [user_id],
          initial_state: [{
            type: "m.room.encryption",
            state_key: "",
            content: { algorithm: "m.megolm.v1.aes-sha2" },
          }],
        }
        resp = http_post("/_matrix/client/v3/createRoom", body, bearer: bot_token)
        resp["room_id"]
      end

      def http_post(path, body, bearer: nil)
        uri = URI("#{HOMESERVER_LOCAL}#{path}")
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        req["Authorization"] = "Bearer #{bearer}" if bearer
        req.body = JSON.dump(body)
        res = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
        JSON.parse(res.body)
      rescue JSON::ParserError
        { "errcode" => "INVALID_RESPONSE", "raw" => res&.body }
      end

      # Persist non-recovery secrets to secrets.yml (gitignored, mode 0600).
      # Recovery key is intentionally NOT included here — it's written to
      # ~/recovery-key.txt with stricter permissions and a "delete me after
      # you've saved this" header (see #write_recovery_key_file).
      def persist_secrets
        raise "secrets_path not provided to runner" unless secrets_path
        c = @generated_credentials
        existing = File.exist?(secrets_path) ? (YAML.safe_load_file(secrets_path) || {}) : {}
        merged = Config.deep_merge(existing, {
          "matrix" => {
            "bot_access_token" => c[:bot_access_token],
            "bot_password"     => c[:bot_password],
            "user_password"    => c[:user_password],
            "bridge_room_id"   => c[:bridge_room_id],
            "hmac_secret"      => c[:hmac_secret],
          }.compact,
        })
        FileUtils.mkdir_p(File.dirname(secrets_path))
        body = header_for_secrets_file + merged.to_yaml.sub(/\A---\n/, "")
        write_secret_file(secrets_path, body, mode: 0o600)
        ok "Bridge secrets persisted to #{secrets_path} (mode 0600)"
      end

      def header_for_secrets_file
        <<~HEADER
          # secrets.yml — generated by dev-boxer; gitignored, mode 0600.
          # Loaded automatically alongside config.yml. Hand-edit at your own risk.
        HEADER
      end

      # Recovery key handling: print + write to ~/recovery-key.txt with mode
      # 0400, owner = dev user. Header tells the operator to copy it into a
      # password manager and then delete the file. The bridge service does
      # not need this key on disk — only the human's first Element login does.
      def write_recovery_key_file(recovery_key)
        path = "#{home_dir}/recovery-key.txt"
        body = <<~CONTENT
          # === Matrix recovery key for #{user_id} ===
          #
          # This key bootstraps end-to-end encryption when you first sign into
          # Element. Copy it into a password manager NOW, then delete this file.
          # You will not be able to retrieve it again.
          #
          # If you lose it: re-run `setup.rb --only matrix-bridge` after
          # deleting matrix.* from secrets.yml — that triggers a fresh
          # onboarding (also rotates bot credentials).

          #{recovery_key}
        CONTENT
        write_secret_file(path, body, mode: 0o400)
        shell.sh!("chown #{username}:#{username} #{path}")
        ok "Recovery key written to #{path} (mode 0400) — copy & delete"
      end

      # Write a file that contains a secret, ensuring it's never readable
      # by anyone except the owner. Tightening umask before File.write
      # avoids the brief 0o644 window that File.write + File.chmod would
      # otherwise create.
      def write_secret_file(path, content, mode:)
        old_umask = File.umask(0o077)
        begin
          File.write(path, content)
        ensure
          File.umask(old_umask)
        end
        File.chmod(mode, path)
      end

      # ----- bridge repo + env -----

      def clone_bridge_repo
        if Dir.exist?(bridge_dir)
          skip "Bridge repo already cloned"
          shell.sh("su - #{username} -c 'cd #{bridge_dir} && git pull --ff-only'")
        else
          info "Cloning claude-matrix-bridge"
          shell.run_as_user(username, "git clone #{BRIDGE_REPO} #{bridge_dir}")
          ok "Bridge repo cloned"
        end
      end

      def npm_install
        if Dir.exist?("#{bridge_dir}/node_modules")
          skip "npm dependencies already installed"
        else
          info "Installing npm dependencies"
          shell.run_as_user(username, "cd #{bridge_dir} && npm install")
          ok "npm dependencies installed"
        end
      end

      def patch_bridge_setup_user
        path = "#{bridge_dir}/setup-user.mjs"
        return unless File.exist?(path)

        source = File.read(path)
        patched = source.sub(
          "client.createRecoveryKeyFromPassphrase()",
          "cryptoApi.createRecoveryKeyFromPassphrase()",
        )

        if patched == source
          skip "Matrix user setup script already compatible"
          return
        end

        File.write(path, patched)
        shell.sh!("chown #{username}:#{username} #{path}")
        ok "Matrix user setup script patched for current matrix-js-sdk"
      end

      def write_bridge_env
        info "Generating bridge .env"
        render_template("matrix-bridge.env", "#{bridge_dir}/.env", bridge_env_vars, mode: 0o600)
        shell.sh!("chown #{username}:#{username} #{bridge_dir}/.env")
        ok "Bridge .env generated"
      end

      # Memoised: bridge_env_vars is invoked four times (.env + MCP config +
      # two systemd units), and HMAC_SECRET would otherwise be a fresh random
      # string each time, breaking the bridge's own HMAC verification.
      # Also reflects the just-generated bot_access_token, since on first
      # bundled run the in-memory `config` object pre-dates onboarding.
      def bridge_env_vars
        creds = @generated_credentials || {}
        @bridge_env_vars ||= begin
          base = {
            "MATRIX_HOMESERVER_URL" => homeserver_url,
            "MATRIX_BOT_ACCESS_TOKEN_BUNDLED" => creds[:bot_access_token] || config.matrix&.bot_access_token,
            "MATRIX_ALLOWED_USER_IDS" => user_id,
            "USERNAME" => username,
            "HMAC_SECRET" => creds[:hmac_secret] || config.matrix&.hmac_secret || SecureRandom.hex(32),
            "CF_HOSTNAME_VIEWER" => config.cloudflare&.tunnel&.hostname_viewer || "localhost",
          }

          if mode == "external"
            base["MATRIX_BOT_USER_ID"]      = config.matrix&.bot_user_id
            base["MATRIX_BOT_PASSWORD"]     = config.matrix&.bot_password
            base["MATRIX_BOT_RECOVERY_KEY"] = config.matrix&.bot_recovery_key
            base["MATRIX_BRIDGE_ROOM_ID"]   = config.matrix&.bridge_room_id
          end

          base
        end
      end

      def write_mcp_config
        info "Generating bridge MCP config"
        render_template("mcp-config.json", "#{bridge_dir}/mcp-config-generated.json", bridge_env_vars)
        shell.sh!("chown #{username}:#{username} #{bridge_dir}/mcp-config-generated.json")
        ok "Bridge MCP config generated"
      end

      def install_systemd_units
        info "Installing systemd services"
        render_template("claude-matrix-bridge.service", "/etc/systemd/system/claude-matrix-bridge.service", bridge_env_vars)
        render_template("claude-matrix-file-viewer.service", "/etc/systemd/system/claude-matrix-file-viewer.service", bridge_env_vars)
        shell.sh!("systemctl daemon-reload")
        shell.systemctl(:enable, "claude-matrix-bridge")
        shell.systemctl(:enable, "claude-matrix-file-viewer")
        shell.systemctl(:restart, "claude-matrix-bridge")
        shell.systemctl(:restart, "claude-matrix-file-viewer")
        ok "Bridge services installed and started"
      end

    end
  end
end
