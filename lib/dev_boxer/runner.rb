module DevBoxer
  class Runner
    UnknownModule = Class.new(StandardError)

    def initialize(modules:, config:, log:, shell: Shell.new, templates_dir: nil, config_path: nil, secrets_path: nil, interactive: true)
      @modules = modules.sort_by { |m| m.module_order || 0 }
      @config = config
      @log = log
      @shell = shell
      @templates_dir = templates_dir
      @config_path = config_path
      @secrets_path = secrets_path
      @interactive = interactive
    end

    def run(only: nil, from: nil, skip: [], dry_run: false)
      validate_known!(only) if only
      validate_known!(from) if from
      skip.each { |n| validate_known!(n) }

      selected = @modules
      selected = selected.select { |m| m.module_name == only } if only
      selected = selected.drop_while { |m| m.module_name != from } if from
      selected = selected.reject { |m| skip.include?(m.module_name) }
      selected = selected.reject { |m| optional_module_disabled?(m) } unless only

      if dry_run
        @log.section("Plan")
        selected.each { |m| @log.info("#{m.module_order.to_s.rjust(2, '0')}  #{m.module_name}") }
        return
      end

      selected.each do |klass|
        klass.new(
          config: @config,
          log: @log,
          shell: @shell,
          templates_dir: @templates_dir,
          config_path: @config_path,
          secrets_path: @secrets_path,
          interactive: @interactive,
        ).run
      end
    end

    private

    def validate_known!(module_name)
      return if @modules.any? { |m| m.module_name == module_name }
      raise UnknownModule, "No such module: #{module_name}"
    end

    def optional_module_disabled?(mod)
      mod.module_name == "desktop" && @config.desktop&.enabled != true
    end
  end
end
