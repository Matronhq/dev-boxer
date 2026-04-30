require_relative "test_helper"
require "tempfile"

class ConfigTest < Minitest::Test
  def write_config(yaml)
    f = Tempfile.new(["config", ".yml"])
    f.write(yaml)
    f.close
    f.path
  end

  def test_loads_top_level_keys
    path = write_config(<<~YAML)
      user:
        name: dan
      ssh:
        port: 2222
    YAML
    config = DevBoxer::Config.load(path)
    assert_equal "dan", config.user.name
    assert_equal 2222, config.ssh.port
  end

  def test_nested_access_returns_nil_for_missing_keys
    path = write_config("user:\n  name: dan\n")
    config = DevBoxer::Config.load(path)
    assert_nil config.user.email
  end

  def test_dig_for_deep_paths
    path = write_config(<<~YAML)
      cloudflare:
        tunnel:
          hostname: dev.example.com
    YAML
    config = DevBoxer::Config.load(path)
    assert_equal "dev.example.com", config.cloudflare.tunnel.hostname
  end

  def test_raises_when_file_missing
    assert_raises(DevBoxer::Config::NotFound) do
      DevBoxer::Config.load("/no/such/path.yml")
    end
  end

  def test_to_h_returns_hash
    path = write_config("user:\n  name: dan\n")
    config = DevBoxer::Config.load(path)
    assert_equal({ "user" => { "name" => "dan" } }, config.to_h)
  end
end
