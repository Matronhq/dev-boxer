require_relative "test_helper"

class ModulesShapeTest < Minitest::Test
  MODULES_DIR = File.expand_path("../lib/dev_boxer/modules", __dir__)

  def setup
    @modules = DevBoxer::Modules.discover(MODULES_DIR)
  end

  def test_all_modules_subclass_module_base
    assert(@modules.all? { |m| m < DevBoxer::ModuleBase })
  end

  def test_all_modules_have_a_name
    @modules.each do |m|
      assert_kind_of String, m.module_name, "#{m} missing name"
      refute_empty m.module_name
    end
  end

  def test_all_modules_have_an_order
    @modules.each do |m|
      assert_kind_of Integer, m.module_order, "#{m} missing order"
    end
  end

  def test_module_names_are_unique
    names = @modules.map(&:module_name)
    assert_equal names.uniq.sort, names.sort
  end

  def test_module_orders_are_unique
    orders = @modules.map(&:module_order)
    assert_equal orders.uniq.sort, orders.sort
  end

  def test_filename_prefix_matches_order
    @modules.each do |m|
      file = m.instance_method(:run).source_location[0]
      prefix = File.basename(file).match(/\A(\d+)_/)[1].to_i
      assert_equal prefix, m.module_order,
        "#{File.basename(file)} prefix should match declared order #{m.module_order}"
    end
  end

  def test_modules_implement_run
    log = DevBoxer::Log.new(io: StringIO.new, color: false)
    config = DevBoxer::Config.from_hash({})
    @modules.each do |m|
      instance = m.new(config: config, log: log)
      assert_respond_to instance, :run
    end
  end

  def test_six_modules_present_for_pr_2
    names = @modules.map(&:module_name).sort
    assert_equal %w[browsers desktop dev-tools docker security users], names
  end
end
