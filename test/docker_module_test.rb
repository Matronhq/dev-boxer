require_relative "test_helper"
require_relative "../lib/dev_boxer/modules/04_docker"

class DockerModuleTest < Minitest::Test
  def test_bare_numeric_prune_durations_default_to_hours
    mod = build_module(
      "docker" => {
        "prune" => {
          "interval" => 2,
          "keep_until" => 4,
        },
      },
    )

    assert_equal "2h", mod.send(:prune_interval)
    assert_equal "4h", mod.send(:prune_until)
  end

  def test_prune_duration_strings_are_preserved
    mod = build_module(
      "docker" => {
        "prune" => {
          "interval" => "6h",
          "keep_until" => "24h",
        },
      },
    )

    assert_equal "6h", mod.send(:prune_interval)
    assert_equal "24h", mod.send(:prune_until)
  end

  private

  def build_module(config_hash)
    DevBoxer::Modules::Docker.new(
      config: DevBoxer::Config.from_hash(config_hash),
      log: DevBoxer::Log.new(io: StringIO.new, color: false),
      shell: DevBoxer::Shell.new(runner: ->(_cmd, _opts = {}) { [true, "", ""] }),
    )
  end
end
