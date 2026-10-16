require "json"
require "net/http"
require "openssl"
require "uri"

module DevBoxer
  # Minimal Cloudflare v4 API client shared by the wizard's token checks and
  # the exposure module. Failures raise Error (Cloudflare answered with an
  # error) or Unreachable (no usable answer at all), so callers can turn them
  # into a clear message instead of a backtrace.
  module CloudflareAPI
    BASE = "https://api.cloudflare.com/client/v4".freeze

    # Error codes Cloudflare uses for a missing, malformed or under-privileged
    # token ("Authentication error", "Invalid API Token", "Unauthorized to
    # access requested resource", ...).
    AUTH_ERROR_CODES = [1000, 6003, 6111, 9106, 9109, 10000, 10001].freeze

    NETWORK_ERRORS = [
      SocketError, SystemCallError, IOError, Timeout::Error,
      Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError,
    ].freeze

    class Unreachable < StandardError; end

    class Error < StandardError
      attr_reader :http_method, :path, :status, :errors
      # Which credential made the call (:setup or :zone), when the caller knows.
      attr_accessor :token_kind

      def initialize(http_method:, path:, status:, errors:, body: nil)
        @http_method = http_method
        @path = path
        @status = status
        @errors = errors
        detail = errors.map { |err| err["message"].to_s }.reject(&:empty?).join("; ")
        detail = body.to_s.empty? ? "HTTP #{status}" : body.to_s if detail.empty?
        super("Cloudflare API #{http_method.to_s.upcase} #{path} failed: #{detail}")
      end

      def codes = errors.map { |err| err["code"] }.compact

      def auth_failure?
        [401, 403].include?(status) || codes.any? { |code| AUTH_ERROR_CODES.include?(code) }
      end
    end

    class Client
      REQUEST_CLASSES = {
        get: Net::HTTP::Get,
        post: Net::HTTP::Post,
        put: Net::HTTP::Put,
        patch: Net::HTTP::Patch,
        delete: Net::HTTP::Delete,
      }.freeze

      # transport: ->(http_method, uri, headers, body) { [status, response_body] }.
      # Tests inject one; the default talks to the real API.
      def initialize(transport: nil)
        @transport = transport || method(:net_http_transport)
      end

      def call(token:, method:, path:, query: {}, body: nil)
        uri = URI("#{BASE}#{path}")
        uri.query = URI.encode_www_form(query) unless query.empty?
        headers = { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
        status, response_body = @transport.call(method, uri, headers, body && JSON.generate(body))
        status = status.to_i

        # A server-side failure says nothing about the token; report it as an
        # outage so it is never shown as "token refused".
        raise Unreachable, "Cloudflare API #{method.to_s.upcase} #{path} returned HTTP #{status}" if status >= 500

        parsed = parse(response_body)
        if parsed.nil?
          raise Error.new(http_method: method, path: path, status: status, errors: [], body: response_body)
        end
        return parsed["result"] if status.between?(200, 299) && parsed["success"] != false

        raise Error.new(http_method: method, path: path, status: status,
                        errors: Array(parsed["errors"]).select { |err| err.is_a?(Hash) })
      end

      private

      def parse(body)
        parsed = JSON.parse(body.to_s)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end

      def net_http_transport(http_method, uri, headers, body)
        request = REQUEST_CLASSES.fetch(http_method).new(uri)
        headers.each { |name, value| request[name] = value }
        request.body = body if body
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) do |http|
          http.request(request)
        end
        [response.code.to_i, response.body]
      rescue *NETWORK_ERRORS => e
        raise Unreachable, "could not reach api.cloudflare.com (#{e.class}: #{e.message})"
      end
    end
  end
end
