module DevBoxer
  class ModuleBase
    # DSL: `module_name "security"` and `module_order 1`. We deliberately
    # avoid `name`/`order` as DSL identifiers because `Module#name` is a
    # core Ruby method (returns the class's qualified name) and overriding
    # it breaks introspection, error messages, and any tooling that expects
    # the standard behaviour.
    class << self
      def module_name(value = nil)
        return @module_name if value.nil?
        @module_name = value
      end

      def module_order(value = nil)
        return @module_order if value.nil?
        @module_order = value
      end
    end

    attr_reader :config, :log

    def initialize(config:, log:)
      @config = config
      @log = log
    end

    def module_name
      self.class.module_name
    end

    def module_order
      self.class.module_order
    end

    def run
      raise NotImplementedError, "#{self.class} must implement #run"
    end
  end
end
