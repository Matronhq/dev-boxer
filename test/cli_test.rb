require_relative "test_helper"
require "tmpdir"
require "open3"

class CLITest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SETUP = File.join(ROOT, "setup.rb")

  def run_setup(*args, env: {})
    Open3.capture3(env, "ruby", SETUP, *args, chdir: ROOT)
  end

  def test_help_lists_options
    out, _err, status = run_setup("--help")
    assert status.success?, "expected --help to exit 0"
    assert_match(/--dry-run/, out)
    assert_match(/--only/,    out)
    assert_match(/--from/,    out)
    assert_match(/--skip/,    out)
    assert_match(/--config/,  out)
  end

  def test_dry_run_with_empty_modules_dir_prints_empty_plan
    Dir.mktmpdir do |dir|
      cfg = File.join(dir, "config.yml")
      File.write(cfg, "user:\n  name: test\n")
      mods_dir = File.join(dir, "modules")
      Dir.mkdir(mods_dir)

      out, err, status = run_setup(
        "--dry-run", "--config", cfg, "--modules-dir", mods_dir
      )
      assert status.success?, "expected --dry-run to exit 0\nstdout: #{out}\nstderr: #{err}"
      assert_match(/Plan/, out)
    end
  end

  def test_dry_run_lists_discovered_modules
    Dir.mktmpdir do |dir|
      cfg = File.join(dir, "config.yml")
      File.write(cfg, "user:\n  name: test\n")
      mods_dir = File.join(dir, "modules")
      Dir.mkdir(mods_dir)
      File.write("#{mods_dir}/01_demo.rb", <<~RUBY)
        module DevBoxer
          module Modules
            class Demo < ModuleBase
              module_name "demo"
              module_order 1
              def run; end
            end
          end
        end
      RUBY

      out, _err, status = run_setup(
        "--dry-run", "--config", cfg, "--modules-dir", mods_dir
      )
      assert status.success?
      assert_match(/demo/, out)
    end
  end

  def test_unknown_module_in_only_exits_nonzero
    Dir.mktmpdir do |dir|
      cfg = File.join(dir, "config.yml")
      File.write(cfg, "user:\n  name: test\n")
      mods_dir = File.join(dir, "modules")
      Dir.mkdir(mods_dir)

      _out, err, status = run_setup(
        "--dry-run", "--only", "nope",
        "--config", cfg, "--modules-dir", mods_dir
      )
      refute status.success?, "expected nonzero exit for unknown module"
      assert_match(/nope/, err)
    end
  end

  def test_explicitly_specified_missing_config_exits_nonzero
    Dir.mktmpdir do |dir|
      mods_dir = File.join(dir, "modules")
      Dir.mkdir(mods_dir)
      missing_path = File.join(dir, "no-such-config.yml")

      _out, err, status = run_setup(
        "--dry-run", "--config", missing_path, "--modules-dir", mods_dir
      )
      refute status.success?, "expected nonzero exit when --config points at a missing file"
      assert_match(/not found/i, err)
    end
  end
end
