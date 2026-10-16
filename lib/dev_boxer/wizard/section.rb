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

      def initialize(prompter:, existing:, token_check: nil)
        @prompter = prompter
        @existing = existing
        @token_check = token_check
      end

      # Returns [config_fragment, secrets_fragment]. `so_far` is the config
      # accumulated from earlier sections, for cross-section defaults.
      def collect(so_far)
        raise NotImplementedError, "#{self.class} must implement #collect"
      end

      private

      attr_reader :prompter, :existing

      def token_check = (@token_check ||= CloudflareTokenCheck.new)

      def ask(...) = prompter.ask(...)
      def ask_integer(...) = prompter.ask_integer(...)
      def ask_choice(...) = prompter.ask_choice(...)
      def confirm(...) = prompter.confirm(...)
      def say(...) = prompter.say(...)

      # Ask until the block (value -> problem or nil) accepts the answer, so
      # a bad value is refused at entry rather than failing later in setup.
      def ask_valid(label, **options)
        loop do
          value = ask(label, **options)
          problem = yield(value)
          return value if problem.nil?

          say "That #{label.downcase} was refused: #{problem}."
          options = options.merge(default: nil) if value == options[:default]
        end
      end
    end
  end
end
