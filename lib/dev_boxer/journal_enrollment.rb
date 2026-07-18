require "fileutils"
require "json"
require "net/http"
require "shellwords"
require "uri"

module DevBoxer
  # Resolves the matron-journal agent token this box's bridge authenticates
  # with. Resolution order (SP4 spec §Enrollment):
  #   1. journal.token_file configured        -> use it (must exist)
  #   2. /etc/matron/agent-token present      -> reuse (idempotent re-runs)
  #   3. bundled journal                      -> mint via matron-admin agent add
  #   4. interactive                          -> app-approved pairing
  #   5. otherwise                            -> NotEnrolled
  # bin/enroll re-runs this with force: true (skips 1-2) after a token is
  # revoked or the journal moves.
  class JournalEnrollment
    NotEnrolled = Class.new(StandardError)

    TOKEN_PATH = "/etc/matron/agent-token".freeze
    JOURNAL_DIR = "/opt/matron-journal".freeze
    POLL_INTERVAL = 3
    RATE_LIMIT_BACKOFF = 30

    def self.https_base(ws_url)
      uri = URI(ws_url.to_s)
      scheme = uri.scheme == "ws" ? "http" : "https"
      default_port = scheme == "http" ? 80 : 443
      base = "#{scheme}://#{uri.host}"
      base += ":#{uri.port}" if uri.port && uri.port != default_port
      base
    end

    # Full root-shell command for one matron-admin invocation: cd into the
    # checkout, point at the live DB, run as the matron user (root would
    # leave root-owned SQLite WAL files behind and break the service).
    def self.matron_admin_command(args)
      cmd = "cd #{JOURNAL_DIR} && MATRON_DB=#{JOURNAL_DIR}/data/matron.db npx matron-admin #{args}"
      "runuser -u matron -- sh -c #{Shellwords.escape(cmd)}"
    end

    # Any HTTP response (including 401 from /metrics) means the journal is
    # reachable; only transport/TLS failures return an error string.
    def self.probe(https_base, ca_file: nil)
      uri = URI("#{https_base}/metrics")
      http = Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.ca_file = ca_file unless ca_file.to_s.empty?
      http.open_timeout = 5
      http.read_timeout = 5
      http.request(Net::HTTP::Get.new(uri))
      :ok
    rescue OpenSSL::SSL::SSLError => e
      "TLS verification failed (#{e.message}). If this journal uses a self-signed certificate, set journal.ca_file to its certificate."
    rescue StandardError => e
      "#{e.class}: #{e.message}"
    end

    def initialize(config:, shell:, log:, interactive: false, input: $stdin,
                   token_path: TOKEN_PATH, http_post: nil, sleeper: nil)
      @config = config
      @shell = shell
      @log = log
      @interactive = interactive
      @input = input
      @token_path = token_path
      @http_post = http_post || method(:default_http_post)
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
    end

    def resolve!(force: false)
      unless force
        configured = config.journal&.token_file
        unless configured.to_s.empty?
          unless File.exist?(configured)
            raise NotEnrolled, "journal.token_file is set to #{configured} but that file does not exist"
          end
          log.skip "Using pre-provisioned agent token: #{configured}"
          return configured
        end
        if File.exist?(token_path)
          log.skip "Reusing existing agent token: #{token_path}"
          return token_path
        end
      end

      return mint_local_token if bundled?
      return pair! if interactive

      raise NotEnrolled, <<~MSG
        No agent token found and this run is non-interactive, so the pairing
        flow can't run. Either set journal.token_file to a pre-provisioned
        token (on the journal host: matron-admin agent add <user> <agent-name>),
        or run bin/enroll interactively on this box.
      MSG
    end

    def agent_name
      configured = config.journal&.agent_name
      return configured unless configured.to_s.empty?
      shell.sh!("hostname -s").strip
    end

    private

    attr_reader :config, :shell, :log, :interactive, :input

    # The path the resolved token actually lives at. A configured
    # journal.token_file wins over the injected/default token_path so a force
    # re-enroll writes the fresh token to the exact path module 08 pointed the
    # bridge .env (JOURNAL_TOKEN_FILE) at. Preserves the invariant:
    # the path resolve! returns == where the token lives == what .env reads.
    def token_path
      configured = config.journal&.token_file
      configured.to_s.empty? ? @token_path : configured
    end

    def bundled? = (config.journal&.mode || "bundled") == "bundled"

    def mint_local_token
      user = config.journal&.username || config.user.name
      out = shell.sh!(self.class.matron_admin_command(
        "agent add #{Shellwords.escape(user)} #{Shellwords.escape(agent_name)}"
      ))
      token = out[/token: (\S+)/, 1]
      raise NotEnrolled, "matron-admin agent add did not print a token:\n#{out}" if token.to_s.empty?
      write_token(token)
      log.ok "Agent #{agent_name} minted for journal user #{user}"
      token_path
    end

    def pair!
      url = config.journal&.url
      if url.to_s.empty?
        raise NotEnrolled, "journal.url is not set, so the app pairing flow can't reach the " \
          "journal. Set journal.url in config.yml (or re-run setup.rb) and try again."
      end
      base = self.class.https_base(url)
      loop do
        code, body = @http_post.call("#{base}/pair/start", {})
        if code == 429
          log.warn "Pairing rate-limited by the journal — waiting #{RATE_LIMIT_BACKOFF}s"
          @sleeper.call(RATE_LIMIT_BACKOFF)
          next
        end
        raise NotEnrolled, "pair/start failed with HTTP #{code}: #{body.inspect}" unless code == 200

        display_code(body)
        return token_path if poll_for_claim(base, body)

        # nil -> the code expired before approval
        unless confirm_retry?
          raise NotEnrolled, "Pairing abandoned — run bin/enroll when you're ready to try again"
        end
      end
    end

    def display_code(pair)
      minutes = ((pair["expires_in"] || 600) / 60.0).round
      log.info ""
      log.info "Pairing code: #{pair['pair_code']}"
      log.info "In the Matron app: Settings -> Devices -> Add Agent, enter the code,"
      log.info "and name the agent (suggested name: #{agent_name})."
      log.info "The code expires in ~#{minutes} minutes. Waiting for approval (Ctrl-C to abort)..."
    end

    def poll_for_claim(base, pair)
      loop do
        @sleeper.call(POLL_INTERVAL)
        code, body = @http_post.call("#{base}/pair/claim", { "poll_token" => pair["poll_token"] })
        case
        when code == 200 && body["status"] == "approved"
          write_token(body["token"])
          log.ok "Pairing approved — agent token stored at #{token_path}"
          return true
        when code == 200
          next # pending
        when code == 404
          log.warn "The pairing code expired before it was approved."
          return nil
        when code == 429
          log.warn "Rate-limited while polling — backing off #{RATE_LIMIT_BACKOFF}s"
          @sleeper.call(RATE_LIMIT_BACKOFF)
        else
          raise NotEnrolled, "pair/claim failed with HTTP #{code}: #{body.inspect}"
        end
      end
    end

    def confirm_retry?
      log.info "Request a fresh pairing code? [Y/n]:"
      answer = input.gets.to_s.strip.downcase
      answer.empty? || %w[y yes].include?(answer)
    end

    def write_token(token)
      FileUtils.mkdir_p(File.dirname(token_path))
      old_umask = File.umask(0o077)
      begin
        File.write(token_path, "#{token}\n")
      ensure
        File.umask(old_umask)
      end
      File.chmod(0o600, token_path)
      owner = config.user&.name
      shell.sh!("chown #{Shellwords.escape(owner)}:#{Shellwords.escape(owner)} #{Shellwords.escape(token_path)}") if owner
    end

    def default_http_post(url, body)
      uri = URI(url)
      http = Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl = uri.scheme == "https"
      ca = config.journal&.ca_file
      http.ca_file = ca unless ca.to_s.empty?
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.dump(body)
      response = http.request(request)
      parsed = begin
        JSON.parse(response.body)
      rescue JSON::ParserError
        {}
      end
      [response.code.to_i, parsed]
    end
  end
end
