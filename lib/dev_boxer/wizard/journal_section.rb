require_relative "section"

module DevBoxer
  class Wizard
    class JournalSection < Section
      TITLE = "Journal".freeze

      def self.owned_keys = %w[journal]

      def self.validate(hash, errors)
        mode = hash.dig("journal", "mode")
        if Config.blank?(mode)
          errors << "journal.mode is required"
        elsif !%w[bundled external].include?(mode)
          errors << "journal.mode must be bundled or external"
        end
        return unless mode == "external"

        url = hash.dig("journal", "url")
        if Config.blank?(url)
          errors << "journal.url is required when journal.mode is external"
        elsif !url.to_s.match?(%r{\Awss?://})
          errors << "journal.url must be a ws:// or wss:// URL"
        end
      end

      def collect(so_far)
        explain_journal_modes
        mode = ask_choice(
          "Journal location",
          choices: %w[bundled external],
          default: existing.dig("journal", "mode") || "bundled",
        )

        case mode
        when "bundled"
          explain_journal_username
          name = ask(
            "Journal username",
            default: existing.dig("journal", "username") || so_far.dig("user", "name"),
          )
          [{ "journal" => { "mode" => "bundled", "username" => name } }, {}]
        when "external"
          url = ask_journal_url
          token_file = ask(
            "Path to a pre-provisioned agent token file (Enter to skip and pair from the app)",
            default: existing.dig("journal", "token_file"),
            required: false,
          )
          # Carry forward keys the wizard doesn't prompt for but that config
          # supports (config.example.yml) and probe_external_journal! relies on
          # (module 08). Without this a reconfigure drops ca_file and the next
          # run's TLS probe fails. External branch only — switching to bundled
          # must not resurrect them.
          journal = {
            "mode" => "external",
            "url" => url,
            "token_file" => token_file,
            "ca_file" => existing.dig("journal", "ca_file"),
            "agent_name" => existing.dig("journal", "agent_name"),
          }.compact
          [{ "journal" => journal }, {}]
        end
      end

      private

      def ask_journal_url
        loop do
          url = ask("Journal WebSocket URL (e.g. wss://chat.example.com/ws)",
            default: existing.dig("journal", "url"))
          return url if url.to_s.match?(%r{\Awss?://})

          say "The journal URL must start with ws:// or wss:// — it is the apps' WebSocket endpoint."
        end
      end

      def explain_journal_modes
        say
        say "Journal location:"
        say "Matron needs a matron-journal server — the sync service your phone, desktop, and browser apps talk to."
        say "Choose `bundled` for a self-contained box: Dev Boxer installs matron-journal here and creates your account on it."
        say "Choose `external` to connect this box to a journal you already run elsewhere (e.g. a shared team server). You'll need its wss:// URL, plus either a pre-provisioned agent token file or a person with the Matron app to approve a pairing code during setup."
        say
      end

      def explain_journal_username
        say
        say "Journal username:"
        say "The account you'll sign into the Matron apps with. Defaults to your Linux username, which is usually what you want."
        say "Dev Boxer creates it with a generated password and prints both at the end of setup."
        say
      end
    end
  end
end
