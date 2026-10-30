require_relative "test_helper"
require "tmpdir"
require_relative "support/module_test_case"

class JournalEnrollmentTest < DevBoxer::Testing::ModuleTestCase
  AGENT_ADD_OUTPUT = "agent box-4 token: tok_abc123\n(store in the bridge credentials file; it is not shown again)\n".freeze

  def build_enrollment(config_hash, dir:, interactive: false, http_post: nil, input: StringIO.new)
    DevBoxer::JournalEnrollment.new(
      config: DevBoxer::Config.from_hash({ "user" => { "name" => "dev" } }.merge(config_hash)),
      shell: @shell,
      log: @log,
      interactive: interactive,
      input: input,
      token_path: File.join(dir, "agent-token"),
      http_post: http_post,
      sleeper: ->(_seconds) {},
    )
  end

  def test_configured_token_file_wins
    Dir.mktmpdir do |dir|
      provided = File.join(dir, "provided-token")
      File.write(provided, "tok\n")
      enrollment = build_enrollment({ "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws", "token_file" => provided } }, dir: dir)

      assert_equal provided, enrollment.resolve!
    end
  end

  def test_configured_token_file_must_exist
    Dir.mktmpdir do |dir|
      enrollment = build_enrollment({ "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws", "token_file" => "/nope" } }, dir: dir)

      error = assert_raises(DevBoxer::JournalEnrollment::NotEnrolled) { enrollment.resolve! }
      assert_match(/does not exist/, error.message)
    end
  end

  def test_existing_token_at_default_path_is_reused
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "agent-token"), "tok\n")
      enrollment = build_enrollment({ "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" } }, dir: dir)

      assert_equal File.join(dir, "agent-token"), enrollment.resolve!
    end
  end

  def test_bundled_mode_mints_locally_and_writes_token
    Dir.mktmpdir do |dir|
      respond_default(success: true, stdout: AGENT_ADD_OUTPUT)
      enrollment = build_enrollment({ "journal" => { "mode" => "bundled", "username" => "alice", "agent_name" => "box-4" } }, dir: dir)

      path = enrollment.resolve!

      assert_equal File.join(dir, "agent-token"), path
      assert_equal "tok_abc123\n", File.read(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
      # The inner command is Shellwords-escaped inside the runuser wrapper,
      # so spaces arrive as backslash-space in the recorded string.
      assert_recorded(/matron-admin\\ agent\\ add\\ alice\\ box-4/)
      assert_recorded(/runuser -u matron/)
    end
  end

  def test_non_interactive_external_without_token_raises_with_remedy
    Dir.mktmpdir do |dir|
      enrollment = build_enrollment({ "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" } }, dir: dir)

      error = assert_raises(DevBoxer::JournalEnrollment::NotEnrolled) { enrollment.resolve! }
      assert_match(/journal\.token_file/, error.message)
      assert_match(/bin\/enroll/, error.message)
    end
  end

  def test_interactive_pairing_start_poll_claim_writes_token
    Dir.mktmpdir do |dir|
      responses = [
        [200, { "pair_code" => "ABCD-EFGH", "poll_token" => "poll1", "expires_in" => 600 }],
        [200, { "status" => "pending" }],
        [200, { "status" => "approved", "token" => "tok_paired", "device_id" => 7 }],
      ]
      calls = []
      http_post = lambda { |url, body| calls << [url, body]; responses.shift }
      enrollment = build_enrollment(
        { "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" } },
        dir: dir, interactive: true, http_post: http_post,
      )

      path = enrollment.resolve!

      assert_equal "tok_paired\n", File.read(path)
      assert_equal "https://chat.example.com/pair/start", calls[0][0]
      assert_equal "https://chat.example.com/pair/claim", calls[1][0]
      assert_equal({ "poll_token" => "poll1" }, calls[1][1])
      assert_includes @log_io.string, "ABCD-EFGH"
      assert_includes @log_io.string, "Settings"
    end
  end

  def test_expired_code_offers_fresh_one
    Dir.mktmpdir do |dir|
      responses = [
        [200, { "pair_code" => "AAAA-AAAA", "poll_token" => "p1", "expires_in" => 600 }],
        [404, { "error" => "not_found" }],
        [200, { "pair_code" => "BBBB-BBBB", "poll_token" => "p2", "expires_in" => 600 }],
        [200, { "status" => "approved", "token" => "tok2", "device_id" => 8 }],
      ]
      http_post = lambda { |_url, _body| responses.shift }
      enrollment = build_enrollment(
        { "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" } },
        dir: dir, interactive: true, http_post: http_post, input: StringIO.new("y\n"),
      )

      assert_equal "tok2\n", File.read(enrollment.resolve!)
    end
  end

  def test_force_skips_existing_token_and_re_enrolls
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "agent-token"), "stale\n")
      respond_default(success: true, stdout: AGENT_ADD_OUTPUT)
      enrollment = build_enrollment({ "journal" => { "mode" => "bundled" } }, dir: dir)

      enrollment.resolve!(force: true)

      assert_equal "tok_abc123\n", File.read(File.join(dir, "agent-token"))
    end
  end

  # Finding A: a force re-enroll must write the fresh token to the configured
  # journal.token_file (the path module 08 pointed the bridge .env at), not the
  # default /etc/matron/agent-token. Otherwise the bridge keeps reading the old
  # revoked token.
  def test_force_re_enroll_bundled_writes_to_configured_token_file
    Dir.mktmpdir do |dir|
      configured = File.join(dir, "provided-token")
      File.write(configured, "stale\n")
      respond_default(success: true, stdout: AGENT_ADD_OUTPUT)
      enrollment = build_enrollment(
        { "journal" => { "mode" => "bundled", "username" => "alice", "agent_name" => "box-4", "token_file" => configured } },
        dir: dir,
      )

      path = enrollment.resolve!(force: true)

      assert_equal configured, path
      assert_equal "tok_abc123\n", File.read(configured)
      refute File.exist?(File.join(dir, "agent-token")),
        "force mint must not write to the default token_path when journal.token_file is set"
    end
  end

  def test_force_re_enroll_external_pairing_writes_to_configured_token_file
    Dir.mktmpdir do |dir|
      configured = File.join(dir, "provided-token")
      File.write(configured, "stale\n")
      responses = [
        [200, { "pair_code" => "ABCD-EFGH", "poll_token" => "poll1", "expires_in" => 600 }],
        [200, { "status" => "approved", "token" => "tok_paired", "device_id" => 7 }],
      ]
      http_post = lambda { |_url, _body| responses.shift }
      enrollment = build_enrollment(
        { "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws", "token_file" => configured } },
        dir: dir, interactive: true, http_post: http_post,
      )

      path = enrollment.resolve!(force: true)

      assert_equal configured, path
      assert_equal "tok_paired\n", File.read(configured)
      refute File.exist?(File.join(dir, "agent-token")),
        "force pairing must not write to the default token_path when journal.token_file is set"
    end
  end

  def test_force_without_token_file_writes_to_default_path
    Dir.mktmpdir do |dir|
      respond_default(success: true, stdout: AGENT_ADD_OUTPUT)
      enrollment = build_enrollment({ "journal" => { "mode" => "bundled" } }, dir: dir)

      path = enrollment.resolve!(force: true)

      assert_equal File.join(dir, "agent-token"), path
      assert_equal "tok_abc123\n", File.read(File.join(dir, "agent-token"))
    end
  end

  # Finding C: pairing without journal.url must raise an actionable NotEnrolled
  # error, not an opaque URI error from https_base.
  def test_interactive_pairing_without_journal_url_raises_actionable_error
    Dir.mktmpdir do |dir|
      enrollment = build_enrollment({ "journal" => { "mode" => "external" } }, dir: dir, interactive: true)

      error = assert_raises(DevBoxer::JournalEnrollment::NotEnrolled) { enrollment.resolve! }
      assert_match(/journal\.url/, error.message)
      assert_match(/config\.yml/, error.message)
    end
  end

  def test_expired_code_with_closed_input_stops_instead_of_retrying_forever
    Dir.mktmpdir do |dir|
      responses = [
        [200, { "pair_code" => "AAAA-AAAA", "poll_token" => "p1", "expires_in" => 600 }],
        [404, { "error" => "not_found" }],
      ]
      enrollment = build_enrollment(
        { "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" } },
        dir: dir, interactive: true, http_post: ->(_url, _body) { responses.shift }, input: StringIO.new(""),
      )

      error = assert_raises(DevBoxer::JournalEnrollment::NotEnrolled) { enrollment.resolve! }
      assert_match(/Pairing abandoned/, error.message)
    end
  end

  def test_https_base_conversion
    assert_equal "https://chat.example.com", DevBoxer::JournalEnrollment.https_base("wss://chat.example.com/ws")
    assert_equal "https://203.0.113.7:8443", DevBoxer::JournalEnrollment.https_base("wss://203.0.113.7:8443/ws")
    assert_equal "http://127.0.0.1:9810", DevBoxer::JournalEnrollment.https_base("ws://127.0.0.1:9810/ws")
  end

  def test_matron_admin_command_wraps_runuser_matron_with_db_env
    cmd = DevBoxer::JournalEnrollment.matron_admin_command("user add alice")
    inner = "cd /opt/matron-journal && MATRON_DB=/opt/matron-journal/data/matron.db npx matron-admin user add alice"
    assert_equal "runuser -u matron -- sh -c #{Shellwords.escape(inner)}", cmd
  end

  def test_pair_uri_matches_the_bridge_format_with_server_url_encoded
    assert_equal "matron://pair?v=1&server=https%3A%2F%2Fjournal.example.com%3A8443&code=BCDF-GHJK",
      DevBoxer::JournalEnrollment.pair_uri("https://journal.example.com:8443", "BCDF-GHJK")
    assert_equal "matron://pair?v=1&server=https%3A%2F%2Fjournal.example.com&code=BCDF-GHJK",
      DevBoxer::JournalEnrollment.pair_uri(DevBoxer::JournalEnrollment.https_base("wss://journal.example.com/ws"), "BCDF-GHJK")
  end

  def test_encode_component_follows_encode_uri_component
    assert_equal "a%20b%2F%3F%26%3D%2B!~*'()-_.", DevBoxer::JournalEnrollment.encode_component("a b/?&=+!~*'()-_.")
    assert_equal "%C3%A9", DevBoxer::JournalEnrollment.encode_component("\u00e9")
  end

  def pairing_enrollment(dir)
    responses = [
      [200, { "pair_code" => "ABCD-EFGH", "poll_token" => "poll1", "expires_in" => 600 }],
      [200, { "status" => "approved", "token" => "tok_paired", "device_id" => 7 }],
    ]
    build_enrollment(
      { "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" } },
      dir: dir, interactive: true, http_post: ->(_url, _body) { responses.shift },
    )
  end

  QR_COMMAND = "qrencode -t ANSIUTF8 -m 2 " \
    "#{Shellwords.escape('matron://pair?v=1&server=https%3A%2F%2Fchat.example.com&code=ABCD-EFGH')}".freeze

  def test_pairing_prints_qr_code_of_pair_uri_when_qrencode_is_present
    Dir.mktmpdir do |dir|
      respond("command -v qrencode >/dev/null 2>&1", success: true)
      respond(QR_COMMAND, success: true, stdout: "[QR BLOCKS]\n")

      pairing_enrollment(dir).resolve!

      assert_recorded(QR_COMMAND)
      assert_includes @log_io.string, "[QR BLOCKS]"
      assert_includes @log_io.string, "Pairing code: ABCD-EFGH"
      assert_operator @log_io.string.index("[QR BLOCKS]"), :<, @log_io.string.index("Pairing code: ABCD-EFGH")
    end
  end

  def test_pairing_falls_back_to_text_code_without_qrencode
    Dir.mktmpdir do |dir|
      respond("command -v qrencode >/dev/null 2>&1", success: false)

      pairing_enrollment(dir).resolve!

      refute_recorded(/\Aqrencode /)
      assert_includes @log_io.string, "Pairing code: ABCD-EFGH"
      refute_includes @log_io.string, "scan the QR code"
    end
  end

  def test_pairing_falls_back_to_text_code_when_qrencode_fails
    Dir.mktmpdir do |dir|
      respond("command -v qrencode >/dev/null 2>&1", success: true)
      respond(QR_COMMAND, success: false, stderr: "qrencode: boom")

      pairing_enrollment(dir).resolve!

      assert_includes @log_io.string, "Pairing code: ABCD-EFGH"
      refute_includes @log_io.string, "Scan this"
    end
  end
end
