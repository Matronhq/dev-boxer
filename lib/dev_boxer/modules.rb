module DevBoxer
  module Modules
    def self.discover(dir)
      before = collect_subclasses
      Dir.glob(File.join(dir, "*.rb")).sort.each { |f| require f }
      after = collect_subclasses
      (after - before).sort_by { |k| k.module_order || 0 }
    end

    def self.collect_subclasses
      ObjectSpace.each_object(Class).select { |c| c < DevBoxer::ModuleBase }
    end
  end
end
