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

  def test_deep_merge_recurses_into_hashes
    a = { "a" => { "x" => 1, "y" => 2 } }
    b = { "a" => { "y" => 99, "z" => 3 } }
    assert_equal({ "a" => { "x" => 1, "y" => 99, "z" => 3 } }, DevBoxer::Config.deep_merge(a, b))
  end

  def test_merge_into_file_creates_file_when_missing
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      DevBoxer::Config.merge_into_file(path, { "matrix" => { "token" => "abc" } })
      assert File.exist?(path)
      reloaded = YAML.safe_load_file(path)
      assert_equal({ "matrix" => { "token" => "abc" } }, reloaded)
    end
  end

  def test_merge_into_file_preserves_other_top_level_sections
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, "user:\n  name: dan\nmatrix:\n  mode: bundled\n")
      DevBoxer::Config.merge_into_file(path, { "matrix" => { "token" => "abc" } })
      reloaded = YAML.safe_load_file(path)
      assert_equal "dan", reloaded.dig("user", "name")
      assert_equal "bundled", reloaded.dig("matrix", "mode")
      assert_equal "abc", reloaded.dig("matrix", "token")
    end
  end

  def test_merge_into_file_does_not_create_duplicate_top_level_key
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, "matrix:\n  mode: bundled\n")
      DevBoxer::Config.merge_into_file(path, { "matrix" => { "token" => "abc" } })
      raw = File.read(path)
      assert_equal 1, raw.scan(/^matrix:/m).length, "expected one matrix: key, found:\n#{raw}"
    end
  end
end
