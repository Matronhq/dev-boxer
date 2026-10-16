module DevBoxer
  module Testing
    # Made-up tokens with the shape of real ones.
    ZONE_TOKEN = "zone-token-".ljust(40, "0").freeze
    SETUP_TOKEN = "setup-token-".ljust(40, "0").freeze
    ROTATED_ZONE_TOKEN = "rotated-zone-token-".ljust(40, "0").freeze

    # Well-formed (but not real) ed25519 public keys.
    def self.ssh_key(comment, seed)
      blob = [11].pack("N") + "ssh-ed25519" + [32].pack("N") + (seed * 32)[0, 32]
      "ssh-ed25519 #{[blob].pack("m0")} #{comment}"
    end
    SSH_KEY_ALICE = ssh_key("alice@example.com", "a").freeze
    SSH_KEY_BOB = ssh_key("bob@example.com", "b").freeze

    # Stands in for CloudflareTokenCheck: approves every token, records the
    # checks, and can be told to refuse a token or report Access as off.
    class FakeTokenCheck
      attr_reader :checks
      attr_accessor :access_states

      def initialize(refuse: {}, access_not_enabled: false, account_id: "account-123")
        @refuse = refuse
        @access_not_enabled = access_not_enabled
        @account_id = account_id
        @checks = []
        @access_states = []
      end

      def check_zone_token(token, zone_name:)
        @checks << [:zone, token, zone_name]
        result_for(token)
      end

      def check_setup_token(token, account_id:, needs_access:)
        @checks << [:setup, token, account_id, needs_access]
        result_for(token, access_not_enabled: needs_access && @access_not_enabled)
      end

      def access_state(_token, _account_id)
        @access_states.shift || :ok
      end

      private

      def result_for(token, access_not_enabled: false)
        problems = @refuse.key?(token) ? [@refuse[token]] : []
        DevBoxer::CloudflareTokenCheck::Result.new(
          problems: problems, account_id: problems.empty? ? @account_id : nil,
          access_not_enabled: access_not_enabled,
        )
      end
    end

    # A transport for CloudflareAPI::Client: routes "GET /path" to a result
    # (wrapped in a success envelope), an [status, errors] failure, or a
    # callable. Unrouted calls fail the test.
    class FakeCloudflareTransport
      attr_reader :calls

      def initialize(routes)
        @routes = routes
        @calls = []
      end

      def call(http_method, uri, headers, _body)
        key = "#{http_method.to_s.upcase} #{uri.path.delete_prefix("/client/v4")}"
        @calls << [key, headers["Authorization"].delete_prefix("Bearer ")]
        route = @routes.fetch(key) { raise "unexpected Cloudflare call: #{key}" }
        route = route.call(headers["Authorization"].delete_prefix("Bearer ")) if route.respond_to?(:call)
        return route if route.is_a?(Array) && route.first.is_a?(Integer)

        [200, JSON.generate("success" => true, "errors" => [], "result" => route)]
      end

      def self.failure(status, code, message)
        [status, JSON.generate("success" => false, "errors" => [{ "code" => code, "message" => message }], "result" => nil)]
      end
    end
  end
end
