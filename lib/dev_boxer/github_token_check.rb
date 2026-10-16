require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

module DevBoxer
  # Checks the optional GitHub token in secrets.yml before setup uses it: its
  # shape, that GitHub accepts it, and (for classic tokens) the scopes
  # `gh auth login --with-token` insists on. One cheap read of /user, so a
  # bad token is refused at the start instead of half-way through the
  # dev-tools step.
  class GithubTokenCheck
    API = "https://api.github.com/user".freeze

    NEEDS = [
      "a fine-grained token (github_pat_...) with Contents: Read on the repositories the dev user clones, or",
      "a classic token (ghp_...) with the repo and read:org scopes (gh refuses one without read:org)",
    ].freeze

    # Classic tokens: gh's own minimum. A broader scope satisfies a narrower one.
    REQUIRED_SCOPES = {
      "repo" => %w[repo],
      "read:org" => %w[read:org write:org admin:org],
    }.freeze

    CLASSIC = /\A(?:ghp|gho|ghu)_[A-Za-z0-9]{36}\z/
    FINE_GRAINED = /\Agithub_pat_[A-Za-z0-9_]{70,100}\z/
    EXPIRY_WARNING_DAYS = 7

    NETWORK_ERRORS = [
      SocketError, SystemCallError, IOError, Timeout::Error,
      Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError,
    ].freeze

    class Unreachable < StandardError; end

    Result = Struct.new(:problems, :unreachable, :warnings, keyword_init: true) do
      def ok? = problems.empty? && unreachable.nil?
    end

    def self.token_shaped?(value) = value.match?(CLASSIC) || value.match?(FINE_GRAINED)

    # nil when the value looks like a GitHub token, otherwise why not.
    def self.shape_problem(token)
      value = token.to_s
      return "nothing was entered" if value.empty?
      half = value.length / 2
      if value.length.even? && value[0, half] == value[half..] && token_shaped?(value[0, half])
        return "it looks like the same token pasted twice; paste it once"
      end
      return "it contains spaces or line breaks; paste the token once, on its own" if value.match?(/\s/)
      return nil if token_shaped?(value)
      if value.start_with?("ghs_", "ghr_")
        return "it is a GitHub App or refresh token; use a personal access token (github_pat_ or ghp_)"
      end

      "it does not look like a GitHub personal access token (they start with github_pat_ or ghp_)"
    end

    # transport: ->(uri, headers) { [status, headers_hash, body] }. Tests
    # inject one; the default talks to the real API.
    def initialize(transport: nil, today: nil)
      @transport = transport || method(:net_http_transport)
      @today = today || -> { Time.now.utc }
    end

    def check(token)
      shape = self.class.shape_problem(token)
      return Result.new(problems: [shape], warnings: []) if shape

      status, headers, body = @transport.call(URI(API), {
        "Authorization" => "Bearer #{token}",
        "Accept" => "application/vnd.github+json",
        "User-Agent" => "dev-boxer",
      })
      headers = headers.transform_keys { |key| key.to_s.downcase }
      status = status.to_i

      if status >= 500 || rate_limited?(status, headers)
        return Result.new(problems: [], unreachable: "GitHub answered HTTP #{status}", warnings: [])
      end
      if status == 401
        return Result.new(problems: ["GitHub does not recognise it: it is wrong or incomplete, expired, or was revoked"], warnings: [])
      end
      unless status == 200
        message = (JSON.parse(body.to_s)["message"] rescue nil) || "HTTP #{status}"
        return Result.new(problems: ["GitHub refused it: #{message}"], warnings: [])
      end

      Result.new(problems: scope_problems(headers), warnings: expiry_warnings(headers))
    rescue Unreachable => e
      Result.new(problems: [], unreachable: e.message, warnings: [])
    end

    private

    def rate_limited?(status, headers)
      status == 403 && headers["x-ratelimit-remaining"].to_s == "0"
    end

    # Only classic tokens report scopes; fine-grained ones have no header.
    def scope_problems(headers)
      return [] unless headers.key?("x-oauth-scopes")
      granted = headers["x-oauth-scopes"].to_s.split(",").map(&:strip)
      missing = REQUIRED_SCOPES.reject { |_scope, satisfied_by| (granted & satisfied_by).any? }.keys
      return [] if missing.empty?

      ["it is missing the #{missing.join(" and ")} scope#{"s" if missing.length > 1}, which gh needs to log in with it"]
    end

    def expiry_warnings(headers)
      raw = headers["github-authentication-token-expiration"].to_s
      return [] if raw.empty?
      expires = Time.parse(raw) rescue (return [])
      days = ((expires - @today.call) / 86_400).floor
      return [] if days > EXPIRY_WARNING_DAYS

      ["The GitHub token expires in #{[days, 0].max} day#{"s" unless days == 1} (#{expires.strftime("%Y-%m-%d")}); " \
       "private clones will stop working then"]
    end

    def net_http_transport(uri, headers)
      request = Net::HTTP::Get.new(uri)
      headers.each { |name, value| request[name] = value }
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) do |http|
        http.request(request)
      end
      [response.code.to_i, response.each_header.to_h, response.body]
    rescue *NETWORK_ERRORS => e
      raise Unreachable, "could not reach api.github.com (#{e.class}: #{e.message})"
    end
  end
end
