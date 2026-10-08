module DevBoxer
  module Modules
    # Discover module classes under `dir`. Idempotent: subsequent calls
    # don't depend on `require` re-loading files (it doesn't), and instead
    # filter known subclasses by source location.
    def self.discover(dir)
      abs = File.expand_path(dir)
      Dir.glob(File.join(abs, "*.rb")).sort.each { |f| require f }
      collect_subclasses
        .select { |c| (loc = source_location_of(c)) && File.expand_path(loc).start_with?(abs + File::SEPARATOR) }
        .sort_by { |c| c.module_order || 0 }
    end

    def self.collect_subclasses
      ObjectSpace.each_object(Class).select { |c| c < DevBoxer::ModuleBase && !c.singleton_class? }
    end

    def self.source_location_of(klass)
      m = klass.instance_methods(false).first || klass.private_instance_methods(false).first
      return nil unless m
      klass.instance_method(m).source_location&.first
    end
  end
end
