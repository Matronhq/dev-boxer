module DevBoxer
  # How the box is reached from the internet. Strategies share one
  # interface; modules 08/10/11 consume it and MUST NOT branch on the
  # exposure mode themselves.
  module Exposure
    def self.for(config:, shell:, log:, templates_dir: nil, config_path: nil, secrets_path: nil, interactive: true)
      klass =
        case config.exposure&.mode
        when "ip" then SelfSigned
        when "cloudflare", nil then Cloudflare
        else raise "Unknown exposure.mode: #{config.exposure.mode.inspect} (expected cloudflare or ip)"
        end
      klass.new(config: config, shell: shell, log: log, templates_dir: templates_dir,
                config_path: config_path, secrets_path: secrets_path, interactive: interactive)
    end

    class Base
      attr_reader :config, :shell, :log, :templates_dir, :config_path, :secrets_path

      def initialize(config:, shell:, log:, templates_dir: nil, config_path: nil, secrets_path: nil, interactive: true)
        @config = config
        @shell = shell
        @log = log
        @templates_dir = templates_dir
        @config_path = config_path
        @secrets_path = secrets_path
        @interactive = interactive
      end

      def setup! = raise(NotImplementedError)
      def journal_public_url = raise(NotImplementedError)
      def viewer_base_url = raise(NotImplementedError)
      def hello_url = raise(NotImplementedError)
      def summary_lines = raise(NotImplementedError)

      private

      def interactive? = @interactive
      def journal_bundled? = (config.journal&.mode || "bundled") != "external"
      def hello_world_port = config.hello_world&.port || 9820

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
end

require_relative "exposure/cloudflare"
require_relative "exposure/self_signed"
