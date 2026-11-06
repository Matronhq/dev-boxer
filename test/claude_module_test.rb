require_relative "test_helper"
require_relative "support/module_test_case"
require "json"
require "open3"
require "tmpdir"
require_relative "../lib/dev_boxer/modules/07_claude"

class ClaudeModuleTest < DevBoxer::Testing::ModuleTestCase
  HOOK = File.join(TEMPLATES_DIR, "claude-hooks", "partial-clone-guard.py")

  def test_settings_gain_the_guard_hook_once_and_keep_everything_else
    Dir.mktmpdir do |home|
      FileUtils.mkdir_p("#{home}/.claude")
      File.write("#{home}/.claude/settings.json", JSON.generate(
        "cleanupPeriodDays" => 7,
        "model" => "opus",
        "hooks" => { "PreToolUse" => [{ "matcher" => ".*", "hooks" => [{ "type" => "command", "command" => "other-hook" }] }] },
      ))
      mod = build_module(DevBoxer::Modules::Claude, { "user" => { "name" => "alice" } })

      mod.stub(:home_dir, home) do
        mod.send(:install_guard_hook)
        mod.send(:write_settings)
        mod.send(:write_settings)
      end

      settings = JSON.parse(File.read("#{home}/.claude/settings.json"))
      assert_equal "opus", settings["model"]
      commands = settings["hooks"]["PreToolUse"].flat_map { |e| e["hooks"].map { |h| h["command"] } }
      assert_equal ["other-hook", "python3 #{home}/.claude/hooks/partial-clone-guard.py"], commands
      assert File.executable?("#{home}/.claude/hooks/partial-clone-guard.py")
      assert_includes @log_io.string, "already configured"
    end
  end

  def test_guard_denies_history_searches_in_a_partial_clone
    skip "python3 or git missing" unless system("command -v python3 git >/dev/null 2>&1")
    Dir.mktmpdir do |dir|
      partial = git_repo(dir, "partial", partial: true)
      full = git_repo(dir, "full", partial: false)

      assert_equal "deny", decision("git log -S needle -- src", partial)
      assert_equal "deny", decision("cd #{partial} && git log --oneline -G needle", dir)
      assert_equal "deny", decision("git -C #{partial} blame README.md", dir)
      assert_equal "deny", decision("git status && git log --stat origin/master | head", partial)
      assert_includes reason("git log -S needle", partial), "git grep"

      assert_nil decision("git log -p -3", partial)
      assert_nil decision("git log -n 20 --stat", partial)
      assert_nil decision("git log --oneline -50", partial)
      assert_nil decision("git grep -n needle origin/master", partial)
      assert_nil decision("echo 'git log -S needle'", partial)
      assert_nil decision("git log -S needle -- src", full)
    end
  end

  private

  def git_repo(dir, name, partial:)
    path = File.join(dir, name)
    system("git", "init", "-q", path, exception: true)
    if partial
      system("git", "-C", path, "config", "remote.origin.promisor", "true", exception: true)
      system("git", "-C", path, "config", "remote.origin.partialclonefilter", "blob:none", exception: true)
    end
    path
  end

  def run_hook(command, cwd)
    input = JSON.generate("tool_name" => "Bash", "cwd" => cwd, "tool_input" => { "command" => command })
    out, status = Open3.capture2("python3", HOOK, stdin_data: input)
    assert status.success?
    out.strip.empty? ? nil : JSON.parse(out)["hookSpecificOutput"]
  end

  def decision(command, cwd) = run_hook(command, cwd)&.fetch("permissionDecision")
  def reason(command, cwd) = run_hook(command, cwd).fetch("permissionDecisionReason")
end
