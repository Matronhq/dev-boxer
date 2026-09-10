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
end
