require "yaml"
require "fileutils"

module DevBoxer
  class Config
    NotFound = Class.new(StandardError)
    Invalid = Class.new(StandardError)

    def self.load(path)
      raise NotFound, "Config not found: #{path}" unless File.exist?(path)
      base = YAML.safe_load_file(path) || {}
      secrets_path = secrets_path_for(path)
      if File.exist?(secrets_path)
        secrets = YAML.safe_load_file(secrets_path) || {}
        base = deep_merge(base, secrets)
      end
      from_hash(base)
    end

    def self.from_hash(hash)
      new(hash)
    end

    def self.secrets_path_for(config_path)
      File.join(File.dirname(config_path), "secrets.yml")
    end

    def self.deep_merge(a, b)
      a.merge(b) do |_, av, bv|
        av.is_a?(Hash) && bv.is_a?(Hash) ? deep_merge(av, bv) : bv
      end
    end

    # Read existing YAML, deep-merge `hash` in, write back as proper YAML.
    # Use this for module-level persistence — appending duplicate top-level
    # keys silently destroys the previous section on next parse.
    def self.merge_into_file(path, hash)
      existing = File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
      mode = File.exist?(path) ? (File.stat(path).mode & 0o777) : default_mode_for(path)
      merged = deep_merge(existing, hash)
      FileUtils.mkdir_p(File.dirname(path))
      old_umask = mode == 0o600 ? File.umask(0o077) : nil
      begin
        File.write(path, merged.to_yaml)
      ensure
        File.umask(old_umask) if old_umask
      end
      File.chmod(mode, path) if mode
      merged
    end

    MATRIX_RETIRED =
      "config contains a retired `matrix:` section — Matrix support was removed in the " \
      "journal-only migration (config schema v2). Replace it with `journal:` and `exposure:` " \
      "sections; see README \"Upgrading from a Matrix-era install\" and " \
      "docs/superpowers/specs/2026-07-16-sp4-dev-boxer-journal-only-design.md".freeze

    def self.validation_errors(config)
      hash = config.respond_to?(:to_h) ? config.to_h : config
      errors = []

      errors << MATRIX_RETIRED if hash.key?("matrix")

      %w[
        user.name
        user.ssh_public_key
        user.rdp_password
        ssh.port
        hello_world.port
      ].each do |path|
        value = hash.dig(*path.split("."))
        errors << "#{path} is required" if blank?(value)
      end

      validate_journal_block(errors, hash)
      validate_exposure_block(errors, hash)

      validate_port(errors, "ssh.port", hash.dig("ssh", "port"))
      validate_port(errors, "hello_world.port", hash.dig("hello_world", "port"))
      validate_username(errors, hash.dig("user", "name"))

      errors
    end

    # NOTE: validate_journal_block / validate_exposure_block move into the
    # wizard sections (JournalSection.validate / ExposureSection.validate)
    # when the wizard restructure lands — see the SP4 plan, Task 3.
    def self.validate_journal_block(errors, hash)
      mode = hash.dig("journal", "mode")
      if blank?(mode)
        errors << "journal.mode is required"
      elsif !%w[bundled external].include?(mode)
        errors << "journal.mode must be bundled or external"
      end
      return unless mode == "external"

      url = hash.dig("journal", "url")
      if blank?(url)
        errors << "journal.url is required when journal.mode is external"
      elsif !url.to_s.match?(%r{\Awss?://})
        errors << "journal.url must be a ws:// or wss:// URL"
      end
    end

    def self.validate_exposure_block(errors, hash)
      mode = hash.dig("exposure", "mode")
      if blank?(mode)
        errors << "exposure.mode is required"
      elsif !%w[cloudflare ip].include?(mode)
        errors << "exposure.mode must be cloudflare or ip"
      end
      validate_exposure_cloudflare(errors, hash) if mode == "cloudflare"
      validate_exposure_ip(errors, hash) if mode == "ip"
    end

    def self.validate_exposure_cloudflare(errors, hash)
      cf = hash.dig("exposure", "cloudflare") || {}

      errors << "exposure.cloudflare.zone_name is required" if blank?(cf["zone_name"])
      errors << "exposure.cloudflare.tunnel.hostname is required" if blank?(cf.dig("tunnel", "hostname"))
      errors << "exposure.cloudflare.tunnel.hostname_viewer is required" if blank?(cf.dig("tunnel", "hostname_viewer"))

      if hash.dig("journal", "mode") != "external" && blank?(cf.dig("tunnel", "hostname_journal"))
        errors << "exposure.cloudflare.tunnel.hostname_journal is required when the journal is bundled"
      end

      if blank?(cf["zone_api_token"]) && cf.dig("dns", "create_manually") != true
        errors << "exposure.cloudflare.zone_api_token is required unless exposure.cloudflare.dns.create_manually is true"
      end

      if blank?(cf.dig("tunnel", "id")) && blank?(cf["api_token"]) &&
          cf.dig("tunnel", "create_manually") != true
        errors << "exposure.cloudflare.api_token is required until exposure.cloudflare.tunnel.id exists, unless exposure.cloudflare.tunnel.create_manually is true"
      end

      validate_exposure_access(errors, cf)
    end

    def self.validate_exposure_access(errors, cf)
      access = cf["access"] || {}
      return unless access["enabled"] == true

      if blank?(access["app_id"]) && blank?(cf["api_token"])
        errors << "exposure.cloudflare.api_token is required until exposure.cloudflare.access.app_id exists"
      end

      allowed_emails = Array(access["allowed_emails"]).reject { |value| blank?(value) }
      allowed_domains = Array(access["allowed_email_domains"]).reject { |value| blank?(value) }
      if allowed_emails.empty? && allowed_domains.empty?
        errors << "exposure.cloudflare.access needs at least one allowed email or email domain"
      end
    end

    def self.validate_exposure_ip(errors, hash)
      ip = hash.dig("exposure", "ip") || {}
      %w[journal_port viewer_port hello_port].each do |key|
        value = ip[key]
        validate_port(errors, "exposure.ip.#{key}", value) unless value.nil?
      end
    end

    def self.validate!(config)
      errors = validation_errors(config)
      return true if errors.empty?
      raise Invalid, "Config is incomplete:\n- #{errors.join("\n- ")}"
    end

    def initialize(hash)
      @hash = hash || {}
    end

    def to_h
      @hash
    end

    def [](key)
      wrap(@hash[key.to_s])
    end

    # Methods Ruby invokes during implicit type coercion. Claiming to
    # respond to them (or letting method_missing return nil for them)
    # makes splat / Array() / string concat / etc. raise a confusing
    # TypeError instead of giving the caller's own NoMethodError.
    COERCION_METHODS = %i[
      to_ary to_a to_str to_hash to_int to_proc to_io to_path
    ].freeze

    def respond_to_missing?(name, _include_private = false)
      return false if COERCION_METHODS.include?(name) && !@hash.key?(name.to_s)
      true
    end

    def method_missing(name, *args, &block)
      return super if COERCION_METHODS.include?(name) && !@hash.key?(name.to_s)
      return super unless args.empty? && !block
      wrap(@hash[name.to_s])
    end

    private

    def self.blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end

    def self.validate_port(errors, path, value)
      port = Integer(value)
      errors << "#{path} must be between 1 and 65535" unless port.between?(1, 65_535)
    rescue ArgumentError, TypeError
      errors << "#{path} must be a number"
    end

    def self.validate_username(errors, value)
      return if blank?(value)
      return if value.match?(/\A[a-z_][a-z0-9_-]*\z/)
      errors << "user.name must be a shell-safe Linux username"
    end

    def self.default_mode_for(path)
      File.basename(path) == "secrets.yml" ? 0o600 : nil
    end

    def wrap(value)
      case value
      when Hash then Config.new(value)
      else value
      end
    end
  end
end
