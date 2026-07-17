require_relative "section"

module DevBoxer
  class Wizard
    class ClaudeSection < Section
      TITLE = "Claude behavior".freeze
      DEFAULT_EXPERIENCE_LEVEL = "intermediate".freeze
      EXPERIENCE_LEVELS = %w[beginner intermediate advanced].freeze

      def self.owned_keys = %w[claude]

      def collect(_so_far)
        explain_claude_experience_level
        config = { "experience_level" => ask_experience_level }
        plugins = existing.dig("claude", "plugins")
        config["plugins"] = plugins unless plugins.nil?
        [{ "claude" => config }, {}]
      end

      private

      def explain_claude_experience_level
        say
        say "Claude experience level:"
        say "How should Claude collaborate with you on this box?"
        say "Beginner means more explanation, and Claude asks before meaningful technical choices and summarises next steps."
        say "Intermediate (the default) is concise — Claude proceeds on routine choices and asks on real tradeoffs."
        say "Advanced is terse: Claude makes reasonable assumptions and focuses on diffs, tests, and blockers."
        say
      end

      def ask_experience_level
        existing_level = existing.dig("claude", "experience_level").to_s.downcase
        default = EXPERIENCE_LEVELS.include?(existing_level) ? existing_level : DEFAULT_EXPERIENCE_LEVEL
        loop do
          level = ask("Claude user experience level", default: default).to_s.downcase
          return level if EXPERIENCE_LEVELS.include?(level)

          say "Choose one of: #{EXPERIENCE_LEVELS.join(", ")}."
        end
      end
    end
  end
end
