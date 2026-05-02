require_relative "test_helper"
require "tmpdir"
require_relative "../lib/dev_boxer/add_bot"

class AddBotTest < Minitest::Test
  def test_refuses_without_name
    err = assert_raises(DevBoxer::AddBot::UsageError) do
      DevBoxer::AddBot.new(name: nil, **build_deps).run
    end
    assert_match(/name/i, err.message)
  end

  def test_refuses_unless_mode_is_bundled
    deps = build_deps(matrix_mode: "external")
    err = assert_raises(DevBoxer::AddBot::UsageError) do
      DevBoxer::AddBot.new(name: "box4", **deps).run
    end
    assert_match(/bundled/i, err.message)
  end

  def test_refuses_to_overwrite_existing_bot_without_reprint
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      seed_existing_bot_in_secrets(secrets_path, "box4")
      deps = build_deps(secrets_path: secrets_path)
      err = assert_raises(DevBoxer::AddBot::AlreadyExists) do
        DevBoxer::AddBot.new(name: "box4", **deps).run
      end
      assert_match(/--reprint/, err.message)
    end
  end

  def test_reprint_returns_blob_without_touching_homeserver
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      seed_existing_bot_in_secrets(secrets_path, "box4")
      registration_calls = []
      registration = build_registration(calls: registration_calls)
      mjs_calls = []
      mjs = ->(*args) { mjs_calls << args; raise "should not run" }

      blob = DevBoxer::AddBot.new(
        name: "box4", reprint: true, **build_deps(secrets_path: secrets_path,
                                                   registration: registration,
                                                   run_mjs: mjs)
      ).run

      assert_match(/\Adb1:/, blob)
      assert_empty registration_calls
      assert_empty mjs_calls
    end
  end

  def test_happy_path_orchestrates_registration_then_mjs_then_close
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      events = []
      registration = Minitest::Mock.new
      registration.expect(:open, nil) { |_token| events << :open; true }
      registration.expect(:register_bot, true) { |username:, password:, reg_token:|
        events << [:register, username]
        true
      }
      registration.expect(:close, nil) { events << :close; true }

      run_mjs = lambda do |args|
        events << :mjs
        # add-bot.mjs's contract: write a creds-file at args[:credentials_file]
        File.write(args[:credentials_file], <<~OUT)
          bot_recovery_key='EsTm 4uK4'
          bridge_room_id='!abc:matrix.example.com'
        OUT
      end

      blob = DevBoxer::AddBot.new(
        name: "box4",
        **build_deps(secrets_path: secrets_path,
                     registration: registration,
                     run_mjs: run_mjs)
      ).run

      assert_equal [:open, [:register, "box4"], :mjs, :close], events
      decoded = DevBoxer::CredentialsBlob.decode(blob)
      assert_equal "@box4:matrix.example.com", decoded["bot_user_id"]
      assert_equal "EsTm 4uK4", decoded["bot_recovery_key"]
      assert_equal "!abc:matrix.example.com", decoded["bridge_room_id"]
      registration.verify
    end
  end

  def test_close_runs_even_if_mjs_raises
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      events = []
      registration = Minitest::Mock.new
      registration.expect(:open, nil) { |_token| events << :open; true }
      registration.expect(:register_bot, true) { |username:, password:, reg_token:|
        events << :register; true
      }
      registration.expect(:close, nil) { events << :close; true }

      run_mjs = ->(_args) { raise "kaboom" }

      assert_raises(RuntimeError) do
        DevBoxer::AddBot.new(
          name: "box4",
          **build_deps(secrets_path: secrets_path,
                       registration: registration,
                       run_mjs: run_mjs)
        ).run
      end

      assert_equal [:open, :register, :close], events
      registration.verify
    end
  end

  def test_persists_bot_password_before_opening_window
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      saw_password_in_secrets = nil
      registration = Minitest::Mock.new
      registration.expect(:open, nil) do |_token|
        secrets = YAML.safe_load_file(secrets_path)
        saw_password_in_secrets = secrets.dig("matrix", "bots", "box4", "bot_password")
        true
      end
      registration.expect(:register_bot, true) { |**_| true }
      registration.expect(:close, nil) { true }

      run_mjs = ->(args) { File.write(args[:credentials_file], "bot_recovery_key='r'\nbridge_room_id='!a:m'\n") }

      DevBoxer::AddBot.new(
        name: "box4",
        **build_deps(secrets_path: secrets_path,
                     registration: registration,
                     run_mjs: run_mjs)
      ).run

      refute_nil saw_password_in_secrets, "password should be persisted before open()"
      registration.verify
    end
  end

  def test_persist_full_record_preserves_created_at_from_partial_persist
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      captured_partial_created_at = nil
      registration = Minitest::Mock.new
      registration.expect(:open, nil) do |_token|
        secrets = YAML.safe_load_file(secrets_path)
        captured_partial_created_at = secrets.dig("matrix", "bots", "box4", "created_at")
        true
      end
      registration.expect(:register_bot, true) { |**_| true }
      registration.expect(:close, nil) { true }

      run_mjs = ->(args) { File.write(args[:credentials_file], "bot_recovery_key='r'\nbridge_room_id='!a:m'\n") }

      DevBoxer::AddBot.new(
        name: "box4",
        **build_deps(secrets_path: secrets_path,
                     registration: registration,
                     run_mjs: run_mjs)
      ).run

      final = YAML.safe_load_file(secrets_path)
      assert_equal captured_partial_created_at, final.dig("matrix", "bots", "box4", "created_at")
      registration.verify
    end
  end

  def test_partial_record_does_not_block_re_run
    Dir.mktmpdir do |dir|
      secrets_path = File.join(dir, "secrets.yml")
      # Simulate a partial-persist crash: bot_user_id + bot_password present,
      # bot_recovery_key + bridge_room_id absent.
      File.write(secrets_path, {
        "matrix" => {
          "bots" => {
            "box4" => {
              "bot_user_id"  => "@box4:matrix.example.com",
              "bot_password" => "old-pw",
              "created_at"   => "2026-05-02T12:34:56Z",
            },
          },
        },
      }.to_yaml)
      File.chmod(0o600, secrets_path)

      events = []
      registration = Minitest::Mock.new
      registration.expect(:open, nil) { |_token| events << :open; true }
      registration.expect(:register_bot, true) { |**_| events << :register; true }
      registration.expect(:close, nil) { events << :close; true }

      run_mjs = ->(args) { File.write(args[:credentials_file], "bot_recovery_key='r'\nbridge_room_id='!a:m'\n") }

      blob = DevBoxer::AddBot.new(
        name: "box4",
        **build_deps(secrets_path: secrets_path,
                     registration: registration,
                     run_mjs: run_mjs)
      ).run

      decoded = DevBoxer::CredentialsBlob.decode(blob)
      assert_equal "r", decoded["bot_recovery_key"]
      assert_equal "!a:m", decoded["bridge_room_id"]
      assert_equal [:open, :register, :close], events
      registration.verify
    end
  end

  private

  def build_deps(secrets_path: nil, matrix_mode: "bundled", registration: nil, run_mjs: nil)
    secrets_path ||= File.join(Dir.mktmpdir, "secrets.yml")
    {
      config: DevBoxer::Config.from_hash(
        "user" => { "name" => "dev" },
        "matrix" => {
          "mode" => matrix_mode,
          "server_domain" => "matrix.example.com",
          "user_username" => "dev",
        },
      ),
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
      secrets_path: secrets_path,
      registration: registration || build_registration,
      run_mjs: run_mjs || ->(args) { File.write(args[:credentials_file], "bot_recovery_key='r'\nbridge_room_id='!a:m'\n") },
    }
  end

  def build_registration(calls: [])
    fake = Object.new
    fake.define_singleton_method(:open)         { |token| calls << [:open, token] }
    fake.define_singleton_method(:register_bot) { |**args| calls << [:register, args]; true }
    fake.define_singleton_method(:close)        { calls << :close }
    fake
  end

  def seed_existing_bot_in_secrets(path, name)
    File.write(path, {
      "matrix" => {
        "bots" => {
          name => {
            "bot_user_id" => "@#{name}:matrix.example.com",
            "bot_password" => "old-pw",
            "bot_recovery_key" => "EsTm 4uK4",
            "bridge_room_id" => "!abc:matrix.example.com",
            "created_at" => "2026-05-02T12:34:56Z",
          },
        },
      },
    }.to_yaml)
    File.chmod(0o600, path)
  end
end
