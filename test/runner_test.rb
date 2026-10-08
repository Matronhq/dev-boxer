require_relative "test_helper"

class RunnerTest < Minitest::Test
  def setup
    @out = StringIO.new
    @log = DevBoxer::Log.new(io: @out, color: false)
    @config = DevBoxer::Config.from_hash({})

    @ran = []
    ran = @ran

    @mod_a = Class.new(DevBoxer::ModuleBase) do
      module_name "alpha"
      module_order 2
      define_method(:run) { ran << "alpha" }
    end
    @mod_b = Class.new(DevBoxer::ModuleBase) do
      module_name "beta"
      module_order 1
      define_method(:run) { ran << "beta" }
    end
    @mod_c = Class.new(DevBoxer::ModuleBase) do
      module_name "gamma"
      module_order 3
      define_method(:run) { ran << "gamma" }
    end

    @runner = DevBoxer::Runner.new(
      modules: [@mod_a, @mod_b, @mod_c],
      config: @config,
      log: @log,
    )
  end

  def test_runs_modules_in_numeric_order
    @runner.run
    assert_equal %w[beta alpha gamma], @ran
  end

  def test_dry_run_lists_modules_without_executing
    @runner.run(dry_run: true)
    assert_empty @ran
    assert_match(/beta/, @out.string)
    assert_match(/alpha/, @out.string)
    assert_match(/gamma/, @out.string)
  end

  def test_only_runs_named_module
    @runner.run(only: "alpha")
    assert_equal %w[alpha], @ran
  end

  def test_from_runs_named_module_and_subsequent
    @runner.run(from: "alpha")
    assert_equal %w[alpha gamma], @ran
  end

  def test_skip_excludes_named_module
    @runner.run(skip: ["alpha"])
    assert_equal %w[beta gamma], @ran
  end

  def test_unknown_module_name_raises
    assert_raises(DevBoxer::Runner::UnknownModule) do
      @runner.run(only: "delta")
    end
  end

  def test_modules_with_nil_order_dont_crash_sort
    nil_order_module = Class.new(DevBoxer::ModuleBase) do
      module_name "delta"
      define_method(:run) { }
    end
    runner = DevBoxer::Runner.new(
      modules: [nil_order_module, @mod_b],
      config: @config,
      log: @log,
    )
    runner.run(dry_run: true)
    assert_match(/delta/, @out.string)
  end

  def test_desktop_module_is_skipped_by_default
    ran = @ran
    desktop = Class.new(DevBoxer::ModuleBase) do
      module_name "desktop"
      module_order 1
      define_method(:run) { ran << "desktop" }
    end
    beta = @mod_b
    runner = DevBoxer::Runner.new(
      modules: [desktop, beta],
      config: DevBoxer::Config.from_hash("desktop" => { "enabled" => false }),
      log: @log,
    )

    runner.run

    assert_equal %w[beta], @ran
  end

  def test_from_still_skips_disabled_desktop_module
    ran = @ran
    users = Class.new(DevBoxer::ModuleBase) do
      module_name "users"
      module_order 2
      define_method(:run) { ran << "users" }
    end
    desktop = Class.new(DevBoxer::ModuleBase) do
      module_name "desktop"
      module_order 3
      define_method(:run) { ran << "desktop" }
    end
    docker = Class.new(DevBoxer::ModuleBase) do
      module_name "docker"
      module_order 4
      define_method(:run) { ran << "docker" }
    end
    runner = DevBoxer::Runner.new(
      modules: [users, desktop, docker],
      config: DevBoxer::Config.from_hash("desktop" => { "enabled" => false }),
      log: @log,
    )

    runner.run(from: "users")

    assert_equal %w[users docker], @ran
  end

  def test_explicit_desktop_module_runs_even_when_disabled
    ran = @ran
    desktop = Class.new(DevBoxer::ModuleBase) do
      module_name "desktop"
      module_order 1
      define_method(:run) { ran << "desktop" }
    end
    runner = DevBoxer::Runner.new(
      modules: [desktop],
      config: DevBoxer::Config.from_hash("desktop" => { "enabled" => false }),
      log: @log,
    )

    runner.run(only: "desktop")

    assert_equal %w[desktop], @ran
  end
end
