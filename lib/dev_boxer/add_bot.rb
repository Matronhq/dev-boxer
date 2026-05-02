require "fileutils"
require "securerandom"
require "shellwords"
require "time"
require "yaml"
require_relative "credentials_blob"
require_relative "matrix_registration"
require_relative "config"
require_relative "shell"

module DevBoxer
  class AddBot
    UsageError    = Class.new(StandardError)
    AlreadyExists = Class.new(StandardError)

    BRIDGE_DIR_DEFAULT = ->(username) { "/home/#{username}/claude-matrix-bridge" }

    def initialize(name:, config:, log:, secrets_path:, registration: nil, run_mjs: nil, reprint: false, bridge_dir: nil)
      @name = name
      @config = config
      @log = log
      @secrets_path = secrets_path
      @reprint = reprint
      @registration = registration
      @run_mjs = run_mjs || method(:default_run_mjs)
      @bridge_dir = bridge_dir
    end

    def run
      raise UsageError, "--name is required (e.g. `dev-boxer add-bot box4`)" if @name.nil? || @name.to_s.empty?
      raise UsageError, "add-bot only runs on a homeserver host (matrix.mode must be 'bundled'); got #{matrix_mode.inspect}" unless matrix_mode == "bundled"

      existing = existing_bot_record
      if existing
        return reprint_blob(existing) if @reprint
        raise AlreadyExists, "Bot '#{@name}' already exists in #{@secrets_path}. Use --reprint to regenerate the blob."
      end

      # On a fresh run, mint a new password. On a re-run after a crashed
      # partial-persist, reuse the persisted password — the bot is already
      # registered on the homeserver with it, so a fresh password would
      # cause add-bot.mjs's login attempt to fail.
      partial = partial_bot_record
      bot_password = partial&.dig("bot_password") || SecureRandom.hex(16)
      persist_partial_bot_record(bot_password) unless partial

      reg_token = SecureRandom.hex(16)
      mjs_creds_path = "/dev/shm/dev-boxer-add-bot-#{SecureRandom.hex(8)}"

      begin
        registration.open(reg_token)
        registration.register_bot(username: @name, password: bot_password, reg_token: reg_token)
        @run_mjs.call(
          credentials_file: mjs_creds_path,
          bot_username: @name,
          bot_user_id: bot_user_id,
          bot_password: bot_password,
          user_id: user_id,
          reg_token: reg_token,
          homeserver_url: MatrixRegistration::HOMESERVER_LOCAL,
        )
        mjs_output = parse_mjs_output(mjs_creds_path)
        record = persist_full_bot_record(bot_password, mjs_output)
        encode_blob(record)
      ensure
        registration.close rescue nil
        File.delete(mjs_creds_path) if File.exist?(mjs_creds_path)
      end
    end

    private

    attr_reader :config, :log

    def matrix_mode
      config.matrix&.mode || "bundled"
    end

    def server_domain
      s = config.matrix&.server_domain
      raise UsageError, "matrix.server_domain is not set in config.yml" if s.nil? || s.to_s.empty?
      s
    end

    def user_username
      config.matrix&.user_username || config.user.name
    end

    def bot_user_id = "@#{@name}:#{server_domain}"
    def user_id     = "@#{user_username}:#{server_domain}"

    def registration
      @registration ||= MatrixRegistration.new(
        matrix_server_dir: "/home/#{config.user.name}/matrix-server",
        username: config.user.name,
        shell: Shell.new,
        log: log,
      )
    end

    def existing_bot_record
      record = partial_bot_record
      return nil unless record
      return nil if record["bot_recovery_key"].to_s.empty? || record["bridge_room_id"].to_s.empty?
      record
    end

    def partial_bot_record
      return nil unless File.exist?(@secrets_path)
      data = YAML.safe_load_file(@secrets_path) || {}
      record = data.dig("matrix", "bots", @name.to_s)
      record.is_a?(Hash) ? record : nil
    end

    def persist_partial_bot_record(bot_password)
      Config.merge_into_file(@secrets_path, {
        "matrix" => {
          "bots" => {
            @name.to_s => {
              "bot_user_id"  => bot_user_id,
              "bot_password" => bot_password,
              "created_at"   => Time.now.utc.iso8601,
            },
          },
        },
      })
    end

    def persist_full_bot_record(bot_password, mjs_output)
      existing = existing_bot_record || {}
      record = {
        "bot_user_id"      => bot_user_id,
        "bot_password"     => bot_password,
        "bot_recovery_key" => mjs_output.fetch("bot_recovery_key"),
        "bridge_room_id"   => mjs_output.fetch("bridge_room_id"),
        "created_at"       => existing["created_at"] || Time.now.utc.iso8601,
      }
      Config.merge_into_file(@secrets_path, {
        "matrix" => { "bots" => { @name.to_s => record } },
      })
      record
    end

    def parse_mjs_output(path)
      raise "add-bot.mjs did not write #{path}" unless File.exist?(path)
      contents = File.read(path)
      {
        "bot_recovery_key" => contents.match(/^bot_recovery_key=['"]?([^'"\n]+)['"]?$/)&.[](1),
        "bridge_room_id"   => contents.match(/^bridge_room_id=['"]?([^'"\n]+)['"]?$/)&.[](1),
      }.tap do |h|
        missing = h.select { |_, v| v.nil? || v.empty? }.keys
        raise "add-bot.mjs output missing keys: #{missing.join(', ')}" unless missing.empty?
      end
    end

    def reprint_blob(record)
      encode_blob(record)
    end

    def encode_blob(record)
      CredentialsBlob.encode(
        "homeserver_url"   => "https://#{server_domain}",
        "server_domain"    => server_domain,
        "bot_user_id"      => record["bot_user_id"],
        "bot_password"     => record["bot_password"],
        "bot_recovery_key" => record["bot_recovery_key"],
        "bridge_room_id"   => record["bridge_room_id"],
      )
    end

    def default_run_mjs(args)
      bridge_dir = @bridge_dir || BRIDGE_DIR_DEFAULT.call(config.user.name)
      env_prefix = [
        "MATRIX_HOMESERVER_URL=#{Shellwords.escape(args[:homeserver_url])}",
        "REG_TOKEN=#{Shellwords.escape(args[:reg_token])}",
      ].join(" ")
      cmd_parts = [
        "node",
        Shellwords.escape("#{bridge_dir}/add-bot.mjs"),
        Shellwords.escape(args[:bot_username]),
        "--password", Shellwords.escape(args[:bot_password]),
        "--user",     Shellwords.escape(args[:user_id]),
        "--credentials-file", Shellwords.escape(args[:credentials_file]),
      ]
      Shell.new.run_as_user(config.user.name, "#{env_prefix} #{cmd_parts.join(' ')}")
    end
  end
end
