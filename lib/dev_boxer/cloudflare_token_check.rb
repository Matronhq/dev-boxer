require_relative "cloudflare_api"

module DevBoxer
  # Checks a Cloudflare API token the moment it is entered (and again before
  # the exposure module uses a saved one): its shape, that Cloudflare says it
  # is active, and that it can reach what setup needs later. Each check is a
  # cheap read, so a bad token is refused up front with the reason, instead
  # of failing half-way through setup.
  class CloudflareTokenCheck
    # The permissions each token needs, as the dashboard lists them. Shown
    # by the wizard, by refusals and by exposure errors, and in the README.
    ZONE_TOKEN_PERMISSIONS = [
      "Zone → Zone: Read",
      "Zone → DNS: Edit",
      "Zone Resources: Include → Specific zone → your domain",
    ].freeze

    SETUP_TOKEN_PERMISSIONS = [
      "Account → Cloudflare One Connector: cloudflared: Edit (called Cloudflare Tunnel: Edit on older dashboards)",
      "Account → Access: Apps: Edit and Access: Policies: Edit (only when Dev Boxer creates the Access apps)",
      "Account Resources: Include → the account that owns your domain",
    ].freeze

    # Zero Trust (which Access is part of) is switched on once per account
    # in the dashboard; the API cannot do it with a setup token.
    ZERO_TRUST_STEPS = [
      "Cloudflare Access is not switched on for this Cloudflare account yet. Turn it on once in the dashboard:",
      "  1. Open https://dash.cloudflare.com and pick the account that owns your domain.",
      "  2. Open Zero Trust in the left sidebar.",
      "  3. Pick a team name (any name; it becomes <team>.cloudflareaccess.com).",
      "  4. Choose the Free plan and finish the sign-up (it may ask for payment details; the Free plan costs nothing).",
      "  5. Wait until the Zero Trust overview page loads.",
    ].freeze

    # Legacy tokens: 40 URL-safe characters. Current tokens: cfut_ (user) or
    # cfat_ (account) followed by 40 characters and a short checksum.
    LEGACY_TOKEN = /\A[A-Za-z0-9_-]{40}\z/
    PREFIXED_TOKEN = /\Acf(?:ut|at)_[A-Za-z0-9_-]{40,60}\z/
    LEGACY_GLOBAL_KEY = /\A[0-9a-f]{37,45}\z/

    # access_not_enabled: the token is fine, but the account has not
    # switched Zero Trust on yet (see ZERO_TRUST_STEPS).
    Result = Struct.new(:problems, :account_id, :unreachable, :access_not_enabled, keyword_init: true) do
      def ok? = problems.empty? && unreachable.nil?
    end

    def self.token_shaped?(value)
      value.match?(LEGACY_TOKEN) || value.match?(PREFIXED_TOKEN)
    end

    # nil when the value looks like an API token, otherwise why not.
    def self.shape_problem(token)
      value = token.to_s
      return "nothing was entered" if value.empty?
      return "it looks like the same token pasted twice; paste it once" if doubled_paste?(value)
      return "it contains spaces or line breaks; paste the token once, on its own" if value.match?(/\s/)
      if value.start_with?("cfk_") || (value.match?(LEGACY_GLOBAL_KEY) && value.length != 40)
        return "it looks like a Global API Key; Dev Boxer needs an API token (My Profile or Manage Account → API Tokens → Create Token)"
      end
      return nil if token_shaped?(value)

      "it is #{value.length} characters long; a Cloudflare API token is 40 characters, or starts with cfat_ or cfut_"
    end

    def self.access_not_enabled_error?(error)
      error.codes.include?("access.api.error.not_enabled") ||
        error.errors.any? { |err| err["message"].to_s.match?(/not_enabled|Access is not enabled/i) }
    end

    def self.doubled_paste?(value)
      parts = value.split(/\s+/).reject(&:empty?)
      return true if parts.length > 1 && parts.uniq.length == 1 && token_shaped?(parts.first)

      half = value.length / 2
      value.length.even? && value[0, half] == value[half..] && token_shaped?(value[0, half])
    end

    def initialize(client: CloudflareAPI::Client.new)
      @client = client
    end

    # The zone token creates DNS records, so it must be active, see the
    # zone and read its DNS records. Returns the zone's account id, which
    # the setup token check and the exposure module need.
    def check_zone_token(token, zone_name:)
      shape = self.class.shape_problem(token)
      return Result.new(problems: [shape]) if shape

      reachable do
        zone = find_zone(token, zone_name)
        account_id = zone&.dig("account", "id")
        inactive = verify(token, account_ids: [account_id])
        next Result.new(problems: [inactive]) if inactive
        unless zone
          next Result.new(problems: ["it cannot see the zone #{zone_name}: give it Zone → Zone: Read on #{zone_name}"])
        end

        problems = []
        begin
          call(token, :get, "/zones/#{zone["id"]}/dns_records", "per_page" => 1)
        rescue CloudflareAPI::Error => e
          problems << "it cannot read DNS records for #{zone_name} (#{e.message}): give it Zone → DNS: Edit on #{zone_name}"
        end
        Result.new(problems: problems, account_id: account_id)
      end
    end

    # The one-time setup token creates the tunnel (and the Access apps when
    # asked to), so it must be active and able to read tunnels (and Access
    # apps) in the account that owns the zone.
    def check_setup_token(token, account_id:, needs_access:)
      shape = self.class.shape_problem(token)
      return Result.new(problems: [shape]) if shape

      reachable do
        candidates = account_id.to_s.empty? ? account_ids(token) : [account_id]
        inactive = verify(token, account_ids: candidates)
        next Result.new(problems: [inactive]) if inactive

        usable = candidates.select { |id| can_read?(token, "/accounts/#{id}/cfd_tunnel") }
        if usable.empty?
          where = account_id.to_s.empty? ? "any account it can see" : "the account that owns the zone"
          next Result.new(problems: ["it cannot manage Cloudflare Tunnels in #{where}: give it Account → Cloudflare One Connector: cloudflared: Edit for that account"])
        end
        if usable.length > 1
          next Result.new(problems: ["it can manage tunnels in #{usable.length} accounts; limit its Account Resources to the one account that owns your domain"])
        end

        chosen = usable.first
        problems = []
        not_enabled = false
        if needs_access
          case access_state(token, chosen)
          when :not_enabled then not_enabled = true
          when :unreachable
            next Result.new(problems: [], account_id: chosen, unreachable: "could not reach Cloudflare to check Access")
          when :denied
            problems << "it cannot manage Cloudflare Access apps: give it Account → Access: Apps: Edit and Access: Policies: Edit"
          end
        end
        Result.new(problems: problems, account_id: chosen, access_not_enabled: not_enabled)
      end
    end

    # :ok, :not_enabled (Zero Trust never switched on for the account),
    # :denied (the token lacks the Access permissions) or :unreachable.
    def access_state(token, account_id)
      call(token, :get, "/accounts/#{account_id}/access/apps", "per_page" => 1)
      :ok
    rescue CloudflareAPI::Error => e
      self.class.access_not_enabled_error?(e) ? :not_enabled : :denied
    rescue CloudflareAPI::Unreachable
      :unreachable
    end

    private

    attr_reader :client

    def call(token, method, path, query = {})
      client.call(token: token, method: method, path: path, query: query)
    end

    def reachable
      yield
    rescue CloudflareAPI::Unreachable => e
      Result.new(problems: [], unreachable: e.message)
    end

    # nil when Cloudflare reports the token active. User tokens verify at
    # /user/tokens/verify; account-owned tokens only at
    # /accounts/<id>/tokens/verify, so try each known account as well.
    def verify(token, account_ids:)
      paths = ["/user/tokens/verify"] + account_ids.compact.uniq.map { |id| "/accounts/#{id}/tokens/verify" }
      paths.reverse! if token.start_with?("cfat_")
      paths.each do |path|
        status = call(token, :get, path).to_h["status"]
        return nil if status == "active"
        return "Cloudflare says the token is #{status}, not active (it may be disabled or expired)" if status
      rescue CloudflareAPI::Error
        next
      end
      "Cloudflare does not recognise it: it is wrong or incomplete, or the token was deleted"
    end

    def find_zone(token, zone_name)
      zones = call(token, :get, "/zones", "name" => zone_name)
      Array(zones).find { |zone| zone["name"] == zone_name }
    rescue CloudflareAPI::Error
      nil
    end

    def account_ids(token)
      Array(call(token, :get, "/accounts", "per_page" => 50)).map { |account| account["id"] }.compact
    rescue CloudflareAPI::Error
      []
    end

    def can_read?(token, path)
      call(token, :get, path, "per_page" => 1)
      true
    rescue CloudflareAPI::Error
      false
    end
  end
end
