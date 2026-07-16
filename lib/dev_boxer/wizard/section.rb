module DevBoxer
  class Wizard
    # One wizard topic. Sections declare the config keys they own
    # (owned_keys + validate), so Config.validation_errors derives from
    # the same declarations that drive the prompts — they cannot drift.
    class Section
      TITLE = nil

      def self.title = self::TITLE

      # Dotted config-path prefixes this section writes. The wizard test
      # asserts every written leaf falls under some section's prefixes.
      def self.owned_keys = []

      # Append validation errors for the keys this section owns.
      def self.validate(hash, errors); end

      def initialize(prompter:, existing:)
        @prompter = prompter
        @existing = existing
      end

      # Returns [config_fragment, secrets_fragment]. `so_far` is the config
      # accumulated from earlier sections, for cross-section defaults.
      def collect(so_far)
        raise NotImplementedError, "#{self.class} must implement #collect"
      end

      private

      attr_reader :prompter, :existing

      def ask(...) = prompter.ask(...)
      def ask_integer(...) = prompter.ask_integer(...)
      def ask_choice(...) = prompter.ask_choice(...)
      def confirm(...) = prompter.confirm(...)
      def say(...) = prompter.say(...)
    end
  end
end
