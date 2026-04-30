require_relative "test_helper"

class ModuleBaseTest < Minitest::Test
  def setup
    @out = StringIO.new
    @log = DevBoxer::Log.new(io: @out, color: false)
    @config = DevBoxer::Config.from_hash("user" => { "name" => "dan" })
  end

  def test_subclass_declares_name_and_order
    klass = Class.new(DevBoxer::ModuleBase) do
      name "demo"
      order 5
    end
    assert_equal "demo", klass.module_name
    assert_equal 5, klass.module_order
  end

  def test_run_must_be_implemented
    klass = Class.new(DevBoxer::ModuleBase) do
      name "demo"
      order 1
    end
    assert_raises(NotImplementedError) do
      klass.new(config: @config, log: @log).run
    end
  end

  def test_subclass_exposes_log_and_config_to_run
    klass = Class.new(DevBoxer::ModuleBase) do
      name "demo"
      order 1
      def run
        log.info("user is #{config.user.name}")
      end
    end
    klass.new(config: @config, log: @log).run
    assert_match(/user is dan/, @out.string)
  end
end
