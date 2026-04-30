require "json"
require "net/http"
require "securerandom"
require "uri"

module DevBoxer
  module Modules
    class MatrixBridge < ModuleBase
      module_name  "matrix-bridge"
      module_order 8

      HOMESERVER_LOCAL = "http://localhost:6167".freeze

      def run
        section "Matrix bridge"

        case mode
        when "bundled" then setup_bundled_homeserver
        when "external" then info "Using external homeserver: #{config.matrix.homeserver_url}"
        when "disabled"
          skip "Matrix bridge disabled in config"
          return
        else
          raise "Unknown matrix.mode: #{mode.inspect} (expected bundled, external, or disabled)"
        end

        clone_bridge_repo
        npm_install
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

      def homeserver_url
        mode == "bundled" ? HOMESERVER_LOCAL : config.matrix.homeserver_url
      end

      # ----- bundled homeserver -----

      def setup_bundled_homeserver
        info "Setting up bundled Matron Server homeserver"
        FileUtils.mkdir_p(matrix_server_dir)
        render_template(
          "docker-compose.matron-server.yml",
          "#{matrix_server_dir}/docker-compose.yml",
          docker_compose_vars,
        )
        shell.sh!("chown -R #{username}:#{username} #{matrix_server_dir}")

        info "Starting Matron Server"
        shell.run_as_user(username, "cd #{matrix_server_dir} && docker compose up -d")

        unless shell.wait_for_url("#{HOMESERVER_LOCAL}/_matrix/client/versions", timeout: 30)
          raise "Matron Server failed to start. Check: docker logs matron-server"
        end
        ok "Matron Server is running"

        if config.matrix&.bot_access_token
          skip "Matrix accounts already registered (token in config)"
          return
        end
        register_accounts_and_create_room
      end

      def docker_compose_vars
        domain = config.matrix&.server_domain
        if domain.nil? || domain.to_s.empty?
          raise "matrix.mode is 'bundled' but matrix.server_domain is not set in config.yml — " \
                "set it to your matrix server name (e.g. matrix.example.com)"
        end
        { "MATRIX_SERVER_DOMAIN" => domain }
      end

      def register_accounts_and_create_room
        info "Registering Matrix accounts"
        reg_token    = SecureRandom.hex(16)
        bot_password = SecureRandom.hex(16)
        # config.example.yml documents user_password as "otherwise auto-generated";
        # honour that contract here (was being passed through as nil/empty,
        # which made registration fail with no clear error).
        user_password = config.matrix&.user_password
        user_password = SecureRandom.hex(16) if user_password.nil? || user_password.to_s.empty?
        @generated_user_password = user_password

        write_compose_override(reg_token)
        restart_compose
        unless shell.wait_for_url("#{HOMESERVER_LOCAL}/_matrix/client/versions", timeout: 30)
          File.delete("#{matrix_server_dir}/docker-compose.override.yml")
          raise "Matron Server failed to restart with registration enabled"
        end

        register_account(config.matrix.bot_username, bot_password, reg_token)
        ok "Bot account @#{config.matrix.bot_username}:#{config.matrix.server_domain} registered"

        register_account(config.matrix.user_username, user_password, reg_token)
        ok "User account @#{config.matrix.user_username}:#{config.matrix.server_domain} registered"

        File.delete("#{matrix_server_dir}/docker-compose.override.yml")
        restart_compose
        unless shell.wait_for_url("#{HOMESERVER_LOCAL}/_matrix/client/versions", timeout: 30)
          raise "Matron Server failed to restart after disabling registration"
        end

        @generated_bot_token = login_account(config.matrix.bot_username, bot_password)
        ok "Bot access token obtained"

        @generated_room_id = create_bridge_room(@generated_bot_token)
        if @generated_room_id
          ok "Bridge room created: #{@generated_room_id}"
        else
          warn "Failed to create bridge room — create it manually from your Matrix client"
        end

        persist_generated(bot_token: @generated_bot_token, room_id: @generated_room_id)
      end

      def write_compose_override(reg_token)
        override = <<~YML
          services:
            matron-server:
              environment:
                MATRON_SERVER_ALLOW_REGISTRATION: "true"
                MATRON_SERVER_REGISTRATION_TOKEN: "#{reg_token}"
        YML
        path = "#{matrix_server_dir}/docker-compose.override.yml"
        File.write(path, override)
        shell.sh!("chown #{username}:#{username} #{path}")
      end

      def restart_compose
        shell.run_as_user(username, "cd #{matrix_server_dir} && docker compose down && docker compose up -d")
      end

      def register_account(user, password, reg_token)
        body = {
          username: user, password: password,
          auth: { type: "m.login.registration_token", token: reg_token },
          inhibit_login: true,
        }
        resp = http_post("/_matrix/client/v3/register", body)
        return if resp["user_id"]

        # UIA fallback — repeat with session
        if (session = resp["session"])
          body[:auth][:session] = session
          resp = http_post("/_matrix/client/v3/register", body)
          return if resp["user_id"]
        end

        return if resp.dig("errcode") == "M_USER_IN_USE"
        raise "Registration failed for #{user}: #{resp.inspect}"
      end

      def login_account(user, password)
        body = {
          type: "m.login.password",
          identifier: { type: "m.id.user", user: user },
          password: password,
        }
        resp = http_post("/_matrix/client/v3/login", body)
        resp["access_token"] or raise "Login failed for #{user}: #{resp.inspect}"
      end

      def create_bridge_room(bot_token)
        body = {
          name: "Claude Code Bridge",
          topic: "Messages in this room are forwarded to Claude Code",
          visibility: "private",
          preset: "private_chat",
          invite: ["@#{config.matrix.user_username}:#{config.matrix.server_domain}"],
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

      # Use Config.merge_into_file rather than appending raw lines — appending
      # a duplicate top-level `matrix:` key would silently destroy the
      # existing matrix section on next YAML.safe_load_file.
      #
      # Persist the generated HMAC secret too: bridge_env_vars memoises it
      # for the current run, but without writing it back to disk every
      # subsequent run would mint a fresh one and invalidate any HMAC-signed
      # data the bridge stored from the previous run.
      def persist_generated(bot_token:, room_id:)
        path = File.expand_path("../../../config.yml", __dir__)
        return unless File.exist?(path)
        generated = { "bot_access_token" => bot_token, "hmac_secret" => bridge_env_vars["HMAC_SECRET"] }
        generated["bridge_room_id"] = room_id if room_id
        # Persist the auto-generated user password too so the operator can
        # recover it for first Element login. If the user supplied one
        # explicitly in config.matrix.user_password, that's preserved.
        generated["user_password"] = @generated_user_password if @generated_user_password
        Config.merge_into_file(path, { "matrix" => generated })
        ok "Wrote #{generated.keys.join(' + ')} back to config.yml"
      end

      # ----- bridge repo + env -----

      def clone_bridge_repo
        if Dir.exist?(bridge_dir)
          skip "Bridge repo already cloned"
          shell.sh("su - #{username} -c 'cd #{bridge_dir} && git pull --ff-only'")
        else
          info "Cloning claude-matrix-bridge"
          shell.run_as_user(username, "git clone https://github.com/matronhq/claude-matrix-bridge.git #{bridge_dir}")
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
        @bridge_env_vars ||= {
          "MATRIX_HOMESERVER_URL" => homeserver_url,
          "MATRIX_BOT_ACCESS_TOKEN_BUNDLED" => @generated_bot_token || config.matrix&.bot_access_token,
          "MATRIX_ALLOWED_USER_IDS" => "@#{config.matrix.user_username}:#{config.matrix.server_domain}",
          "USERNAME" => username,
          "HMAC_SECRET" => config.matrix&.hmac_secret || SecureRandom.hex(32),
          "CF_HOSTNAME_VIEWER" => config.cloudflare&.tunnel&.hostname_viewer || "localhost",
        }
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
