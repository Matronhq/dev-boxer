require_relative "test_helper"
require_relative "../lib/dev_boxer/modules/03_desktop"

class DesktopModuleTest < Minitest::Test
  def test_vscode_install_belongs_to_desktop_module
    recorded = []
    shell = Class.new do
      define_method(:command_exists?) do |name|
        recorded << "command_exists? #{name}"
        false
      end

      define_method(:sh!) do |cmd|
        recorded << cmd
        cmd == "dpkg --print-architecture" ? "amd64\n" : ""
      end

      define_method(:write_file) do |path, content|
        recorded << "write_file #{path} #{content}"
      end

      define_method(:apt_update) { recorded << "apt_update" }

      define_method(:apt_install) do |*packages|
        recorded << "apt_install #{packages.join(' ')}"
      end
    end.new
    mod = build_module(shell: shell)

    mod.send(:install_vscode)

    assert(recorded.any? { |cmd| cmd.include?("packages.microsoft.com/keys/microsoft.asc") })
    assert_includes recorded, "apt_install code"
  end

  def test_github_desktop_install_failure_is_non_fatal
    output = StringIO.new
    shell = DevBoxer::Shell.new(runner: ->(cmd, _opts = {}) {
      if cmd.include?("command -v github-desktop")
        [false, "", ""]
      elsif cmd.include?("apt.packages.shiftkey.dev/gpg.key")
        [false, "", "curl: (60) SSL certificate problem\n"]
      else
        [true, "", ""]
      end
    })
    mod = build_module(shell: shell, output: output)

    mod.send(:install_github_desktop)

    assert_includes output.string, "GitHub Desktop install skipped"
    assert_includes output.string, "curl: (60) SSL certificate problem"
    refute_includes output.string, "command failed:"
  end

  private

  def build_module(shell:, output: StringIO.new)
    DevBoxer::Modules::Desktop.new(
      config: DevBoxer::Config.from_hash(
        "user" => { "name" => "dev" },
        "ssh" => { "port" => 2222 },
      ),
      log: DevBoxer::Log.new(io: output, color: false),
      shell: shell,
      templates_dir: File.expand_path("../templates", __dir__),
    )
  end
end
