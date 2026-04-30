require_relative "test_helper"
require "tmpdir"

class ModulesRegistryTest < Minitest::Test
  def test_discover_returns_empty_array_when_directory_empty
    Dir.mktmpdir do |dir|
      assert_equal [], DevBoxer::Modules.discover(dir)
    end
  end

  def test_discover_returns_subclasses_from_files
    Dir.mktmpdir do |dir|
      File.write("#{dir}/01_alpha.rb", <<~RUBY)
        module DevBoxer
          module Modules
            class Alpha < ModuleBase
              module_name "alpha"
              module_order 1
              def run; end
            end
          end
        end
      RUBY
      File.write("#{dir}/02_beta.rb", <<~RUBY)
        module DevBoxer
          module Modules
            class Beta < ModuleBase
              module_name "beta"
              module_order 2
              def run; end
            end
          end
        end
      RUBY

      mods = DevBoxer::Modules.discover(dir)
      names = mods.map(&:module_name).sort
      assert_equal %w[alpha beta], names
    end
  end
end
