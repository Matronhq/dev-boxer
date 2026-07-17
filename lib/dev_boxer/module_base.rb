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

    attr_reader :config, :log, :shell, :templates_dir, :config_path, :secrets_path

    def initialize(config:, log:, shell: Shell.new, templates_dir: nil, config_path: nil, secrets_path: nil, interactive: true)
      @config = config
      @log = log
      @shell = shell
      @templates_dir = templates_dir
      @config_path = config_path
      @secrets_path = secrets_path
      @interactive = interactive
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

    private

    def interactive? = @interactive

    def exposure
      @exposure ||= DevBoxer::Exposure.for(
        config: config, shell: shell, log: log, templates_dir: templates_dir,
        config_path: config_path, secrets_path: secrets_path, interactive: interactive?,
      )
    end

    def template_path(name)
      raise "templates_dir not set" unless templates_dir
      File.join(templates_dir, name)
    end

    def render_template(template_name, output_path, vars, mode: nil)
      Template.render_to(template_path(template_name), output_path, vars, mode: mode)
    end

    def section(title) = log.section(title)
    def info(msg)      = log.info(msg)
    def ok(msg)        = log.ok(msg)
    def skip(msg)      = log.skip(msg)
    def warn(msg)      = log.warn(msg)
  end
end
