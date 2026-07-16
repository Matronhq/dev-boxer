require "fileutils"
require "yaml"
require_relative "wizard/prompter"
require_relative "wizard/section"
require_relative "wizard/server_login_section"
require_relative "wizard/journal_section"
require_relative "wizard/exposure_section"
require_relative "wizard/claude_section"
require_relative "wizard/machine_defaults_section"

module DevBoxer
  class Wizard
    # Prompt order: journal before exposure, because the exposure section
    # provisions a journal hostname only when the journal is bundled.
    SECTIONS = [
      ServerLoginSection,
      JournalSection,
      ExposureSection,
      ClaudeSection,
      MachineDefaultsSection,
    ].freeze

    def self.run(config_path:, input: $stdin, output: $stdout, force: false)
      new(config_path: config_path, input: input, output: output).run(force: force)
    end

    def initialize(config_path:, input: $stdin, output: $stdout)
      @config_path = config_path
      @secrets_path = Config.secrets_path_for(config_path)
      @prompter = Prompter.new(input: input, output: output)
    end

    def run(force: false)
      existing_config = load_yaml(config_path)
      existing_secrets = load_yaml(secrets_path)
      existing = Config.deep_merge(existing_config, existing_secrets)

      if File.exist?(config_path) && !force && Config.validation_errors(Config.from_hash(existing)).empty?
        prompter.say "Existing config.yml looks complete."
        return :reused if prompter.confirm("Reuse existing config?", default: true)
      end

      print_welcome

      config, secrets = collect_all(existing)
      write_yaml(config_path, config, mode: 0o644)
      write_yaml(secrets_path, secrets, mode: 0o600)

      prompter.say
      prompter.say "Wrote #{config_path}"
      prompter.say "Wrote #{secrets_path} (mode 0600)"
      :created
    end

    private

    attr_reader :config_path, :secrets_path, :prompter

    def collect_all(existing)
      config = {}
      secrets = {}
      number = 0
      SECTIONS.each do |klass|
        if klass.title
          number += 1
          prompter.section_header("#{number}. #{klass.title}")
        end
        fragment, secret_fragment = klass.new(prompter: prompter, existing: existing).collect(config)
        config = Config.deep_merge(config, fragment || {})
        secrets = Config.deep_merge(secrets, secret_fragment || {})
      end
      [config, secrets]
    end

    def print_welcome
      prompter.say prompter.color("  +------------------------------------------------+", "36")
      prompter.say prompter.color("  |                   DEV BOXER                    |", "35")
      prompter.say prompter.color("  |        Remote Claude Code dev box setup        |", "36")
      prompter.say prompter.color("  +------------------------------------------------+", "36")
      prompter.say "Press Enter to accept the default shown in brackets."
      prompter.say
    end

    def load_yaml(path)
      File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
    end

    def write_yaml(path, hash, mode:)
      FileUtils.mkdir_p(File.dirname(path))
      old_umask = File.umask(mode == 0o600 ? 0o077 : 0o022)
      begin
        File.write(path, hash.to_yaml)
      ensure
        File.umask(old_umask)
      end
      File.chmod(mode, path)
    end
  end
end
