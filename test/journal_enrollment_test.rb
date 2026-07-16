require_relative "test_helper"
require "tmpdir"
require_relative "support/module_test_case"

class JournalEnrollmentTest < DevBoxer::Testing::ModuleTestCase
  AGENT_ADD_OUTPUT = "agent dev-4 token: tok_abc123\n(store in the bridge credentials file; it is not shown again)\n".freeze

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
      enrollment = build_enrollment({ "journal" => { "mode" => "bundled", "username" => "dan", "agent_name" => "dev-4" } }, dir: dir)

      path = enrollment.resolve!

      assert_equal File.join(dir, "agent-token"), path
      assert_equal "tok_abc123\n", File.read(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
      # The inner command is Shellwords-escaped inside the runuser wrapper,
      # so spaces arrive as backslash-space in the recorded string.
      assert_recorded(/matron-admin\\ agent\\ add\\ dan\\ dev-4/)
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

  def test_https_base_conversion
    assert_equal "https://chat.example.com", DevBoxer::JournalEnrollment.https_base("wss://chat.example.com/ws")
    assert_equal "https://203.0.113.7:8443", DevBoxer::JournalEnrollment.https_base("wss://203.0.113.7:8443/ws")
    assert_equal "http://127.0.0.1:9810", DevBoxer::JournalEnrollment.https_base("ws://127.0.0.1:9810/ws")
  end
end
