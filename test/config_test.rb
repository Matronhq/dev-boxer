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

  def test_loads_sibling_secrets_yml_and_merges
    Dir.mktmpdir do |dir|
      File.write("#{dir}/config.yml",  "user:\n  name: dan\nmatrix:\n  mode: bundled\n")
      File.write("#{dir}/secrets.yml", "matrix:\n  bot_access_token: secret123\n")
      config = DevBoxer::Config.load("#{dir}/config.yml")
      assert_equal "dan",       config.user.name
      assert_equal "bundled",   config.matrix.mode
      assert_equal "secret123", config.matrix.bot_access_token
    end
  end

  def test_secrets_yml_overrides_config_yml_on_conflict
    Dir.mktmpdir do |dir|
      File.write("#{dir}/config.yml",  "matrix:\n  bot_access_token: from_config\n")
      File.write("#{dir}/secrets.yml", "matrix:\n  bot_access_token: from_secrets\n")
      config = DevBoxer::Config.load("#{dir}/config.yml")
      assert_equal "from_secrets", config.matrix.bot_access_token
    end
  end

  def test_missing_secrets_yml_is_fine
    Dir.mktmpdir do |dir|
      File.write("#{dir}/config.yml", "user:\n  name: dan\n")
      config = DevBoxer::Config.load("#{dir}/config.yml")
      assert_equal "dan", config.user.name
    end
  end

  def test_secrets_path_for_returns_sibling
    assert_equal "/foo/secrets.yml", DevBoxer::Config.secrets_path_for("/foo/config.yml")
    assert_equal "/foo/secrets.yml", DevBoxer::Config.secrets_path_for("/foo/anything.yml")
  end

  def test_does_not_claim_to_respond_to_coercion_methods
    config = DevBoxer::Config.from_hash("user" => { "name" => "dan" })
    refute config.respond_to?(:to_ary), "to_ary trips Array()/splat"
    refute config.respond_to?(:to_str), "to_str trips string concat"
    refute config.respond_to?(:to_hash), "to_hash trips ** splat"
    refute config.respond_to?(:to_int), "to_int trips Integer()"
    refute config.respond_to?(:to_proc), "to_proc trips & in method calls"
  end

  def test_array_wrap_does_not_raise
    config = DevBoxer::Config.from_hash({})
    assert_equal [config], Array(config)
  end

  def test_responds_to_actual_keys
    config = DevBoxer::Config.from_hash("matrix" => {})
    assert config.respond_to?(:matrix)
  end

  def test_coercion_method_with_matching_key_still_works
    config = DevBoxer::Config.from_hash("to_ary" => "weird-but-legal")
    assert_equal "weird-but-legal", config.to_ary
  end
end
