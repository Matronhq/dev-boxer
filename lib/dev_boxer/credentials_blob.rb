require "base64"
require "json"

module DevBoxer
  module CredentialsBlob
    Invalid = Class.new(StandardError)

    VERSION = "db1".freeze
    REQUIRED_KEYS = %w[
      homeserver_url
      server_domain
      bot_user_id
      bot_password
      bot_recovery_key
      bridge_room_id
    ].freeze

    USER_ID_RE = /\A@[^:]+:(?<domain>.+)\z/

    def self.encode(hash)
      missing = REQUIRED_KEYS - hash.keys
      raise Invalid, "missing required keys: #{missing.join(', ')}" unless missing.empty?

      payload = REQUIRED_KEYS.each_with_object({}) { |k, h| h[k] = hash.fetch(k) }
      "#{VERSION}:" + Base64.strict_encode64(JSON.dump(payload))
    end

    def self.decode(input)
      raise Invalid, "input must include version prefix '#{VERSION}:'" unless input.is_a?(String) && input.include?(":")

      version, body = input.split(":", 2)
      raise Invalid, "unknown blob version #{version.inspect} (expected #{VERSION})" unless version == VERSION

      decoded =
        begin
          Base64.strict_decode64(body)
        rescue ArgumentError
          raise Invalid, "blob body is not valid base64"
        end

      hash =
        begin
          JSON.parse(decoded)
        rescue JSON::ParserError => e
          raise Invalid, "blob body is not valid JSON: #{e.message}"
        end

      missing = REQUIRED_KEYS - hash.keys
      raise Invalid, "blob missing required keys: #{missing.join(', ')}" unless missing.empty?

      m = hash["bot_user_id"].match(USER_ID_RE)
      raise Invalid, "bot_user_id #{hash['bot_user_id'].inspect} is not a valid Matrix user ID" unless m
      raise Invalid, "bot_user_id domain #{m[:domain].inspect} does not match server_domain #{hash['server_domain'].inspect}" if m[:domain] != hash["server_domain"]

      hash
    end
  end
end
