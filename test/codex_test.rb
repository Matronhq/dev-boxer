require_relative "test_helper"
require_relative "../lib/dev_boxer/modules/12_codex"

class CodexTest < Minitest::Test
  # Records every command; `codex_present` decides what `command -v codex` says.
  def build(codex_present:)
    recorded = []
    shell = DevBoxer::Shell.new(runner: ->(cmd, _opts = {}) {
      recorded << cmd
      [cmd.include?("command -v codex") ? codex_present : true, "", ""]
    })
    mod = DevBoxer::Modules::Codex.new(
      config: DevBoxer::Config.from_hash({}),
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
      shell: shell,
    )
    [mod, recorded]
  end

  def test_installs_the_cli_when_absent
    mod, recorded = build(codex_present: false)
    mod.run
    assert_includes recorded, "npm install -g @openai/codex"
  end

  # Re-running setup must not reinstall on every converge.
  def test_skips_when_already_installed
    mod, recorded = build(codex_present: true)
    mod.run
    refute(recorded.any? { |c| c.start_with?("npm install") }, "must not reinstall an existing CLI")
  end

  # Codex authenticates per developer via `codex login`; the module must never
  # plant a shared key or write credentials of any kind.
  def test_installs_no_credentials
    mod, recorded = build(codex_present: false)
    mod.run
    joined = recorded.join("\n")
    refute_match(/OPENAI_API_KEY|api[_-]?key|codex login/i, joined,
                 "the module must not configure credentials or attempt a login")
  end

  def test_tells_the_developer_how_to_authenticate
    io = StringIO.new
    shell = DevBoxer::Shell.new(runner: ->(_cmd, _opts = {}) { [true, "", ""] })
    DevBoxer::Modules::Codex.new(
      config: DevBoxer::Config.from_hash({}),
      log: DevBoxer::Log.new(io: io, color: false),
      shell: shell,
    ).run
    assert_match(/codex login/, io.string)
  end

  def test_module_identity
    assert_equal "codex", DevBoxer::Modules::Codex.module_name
    assert_equal 12, DevBoxer::Modules::Codex.module_order
  end

  def starter_with_unreadable_cli(repair_succeeds: true)
    calls = []
    usable = false
    version = DevBoxer::Components.tool_version("codex")
    io = StringIO.new
    shell = DevBoxer::Shell.new(runner: ->(cmd, _opts = {}) {
      calls << cmd
      if cmd.start_with?("su - alice ")
        [usable, usable ? "codex-cli #{version}\n" : "", usable ? "" : "permission denied"]
      elsif cmd == "npm root -g"
        [true, "/opt/fixture/lib/node_modules\n", ""]
      else
        usable = repair_succeeds if cmd.include?("npm install -g")
        [true, "", ""]
      end
    })
    config = DevBoxer::Config.from_hash({"setup" => {"profile" => "starter"}, "user" => {"name" => "alice"}})
    mod = DevBoxer::Modules::Codex.new(config: config, shell: shell, log: DevBoxer::Log.new(io: io))
    [mod, calls, io]
  end

  def test_starter_repairs_an_unreadable_install_and_then_skips_it
    mod, calls, io = starter_with_unreadable_cli
    mod.run
    assert_includes io.string, "Codex CLI ready"
    assert calls.any? { |cmd| cmd.include?("npm uninstall -g @openai/codex") }
    assert_equal 1, calls.count { |cmd| cmd.include?("npm install -g") }
    mod.run
    assert_equal 1, calls.count { |cmd| cmd.include?("npm install -g") }, "a usable CLI must not be reinstalled on resume"
  end

  def test_starter_does_not_claim_readiness_when_user_still_cannot_run_cli
    mod, _calls, io = starter_with_unreadable_cli(repair_succeeds: false)
    error = assert_raises(DevBoxer::SetupError) { mod.run }
    assert_match(/alice cannot run that version/, error.message)
    refute_includes io.string, "Codex CLI ready"
  end
end
