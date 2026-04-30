module DevBoxer
  class ModuleBase
    class << self
      def name(value = nil)
        return @module_name if value.nil?
        @module_name = value
      end

      def order(value = nil)
        return @module_order if value.nil?
        @module_order = value
      end

      def module_name
        @module_name
      end

      def module_order
        @module_order
      end
    end

    attr_reader :config, :log

    def initialize(config:, log:)
      @config = config
      @log = log
    end

    def name
      self.class.module_name
    end

    def order
      self.class.module_order
    end

    def run
      raise NotImplementedError, "#{self.class} must implement #run"
    end
  end
end
