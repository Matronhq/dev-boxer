require "json"
require "net/http"
require "uri"

module DevBoxer
  # Service object that owns the homeserver registration window plus
  # bot registration POSTs. Extracted from MatrixBridge so that AddBot
  # can drive the same flow without duplicating it.
  class MatrixRegistration
    Error = Class.new(StandardError)

    HOMESERVER_LOCAL = "http://localhost:6167".freeze

    def initialize(matrix_server_dir:, username:, shell:, log:, http: nil, homeserver_url: HOMESERVER_LOCAL)
      @matrix_server_dir = matrix_server_dir
      @username = username
      @shell = shell
      @log = log
      @homeserver_url = homeserver_url
      @http = http || method(:default_http_post)
    end

    def open(reg_token)
      File.write(override_path, <<~YML)
        services:
          matron-server:
            environment:
              TUWUNEL_ALLOW_REGISTRATION: "true"
              TUWUNEL_REGISTRATION_TOKEN: "#{reg_token}"
      YML
      shell.sh!("chown #{@username}:#{@username} #{override_path}")
      shell.run_as_user(@username, "cd #{@matrix_server_dir} && docker compose down && docker compose up -d")
      wait_for_ready or raise Error, "Matron Server failed to restart with registration enabled"
    end

    def close
      begin
        File.delete(override_path) if File.exist?(override_path)
      rescue Errno::ENOENT
        # already gone — fine
      rescue => e
        log.warn("Could not remove #{override_path}: #{e.class}: #{e.message}")
      end
      shell.run_as_user(@username, "cd #{@matrix_server_dir} && docker compose down && docker compose up -d") rescue nil
      wait_for_ready rescue nil
    end

    # Returns true if the bot account exists after this call (either
    # because we just created it or because it was already there).
    def register_bot(username:, password:, reg_token:)
      body = {
        username: username, password: password,
        auth: { type: "m.login.registration_token", token: reg_token },
        inhibit_login: true,
      }
      resp = @http.call("/_matrix/client/v3/register", body)
      return true if resp["user_id"]

      if (session = resp["session"])
        body[:auth][:session] = session
        resp = @http.call("/_matrix/client/v3/register", body)
        return true if resp["user_id"]
      end

      return true if resp["errcode"] == "M_USER_IN_USE"
      raise Error, "Bot registration failed: #{resp.inspect}"
    end

    private

    attr_reader :shell, :log

    def override_path
      File.join(@matrix_server_dir, "docker-compose.override.yml")
    end

    def wait_for_ready
      shell.wait_for_url("#{@homeserver_url}/_matrix/client/versions", timeout: 30)
    end

    def default_http_post(path, body, bearer = nil)
      uri = URI("#{@homeserver_url}#{path}")
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req["Authorization"] = "Bearer #{bearer}" if bearer
      req.body = JSON.dump(body)
      res = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
      JSON.parse(res.body)
    rescue JSON::ParserError
      { "errcode" => "INVALID_RESPONSE", "raw" => res&.body }
    end
  end
end
