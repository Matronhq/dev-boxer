require "io/console"

module DevBoxer
  class Wizard
    # All terminal I/O for the wizard. Sections share one instance.
    class Prompter
      # stdin closed mid-question; re-asking would loop forever.
      InputClosed = Class.new(StandardError)

      attr_reader :input, :output

      def initialize(input: $stdin, output: $stdout)
        @input = input
        @output = output
      end

      def say(text = "")
        output.puts(text)
      end

      def ask(label, default: nil, required: true, secret: false)
        loop do
          output.print(prompt_for(label, default, secret))
          value = read_value(secret)
          raise InputClosed, "Input ended while asking for: #{label}" if value.nil?
          value = value.to_s.strip

          unless value.empty?
            output.puts "Received #{value.length} characters." if secret
            return value
          end
          return default unless default.to_s.empty?
          return nil unless required

          output.puts "#{label} is required."
        end
      end

      # Ask for a secret, check it, and ask again until the check passes.
      # The block gets the value and returns a CloudflareTokenCheck::Result
      # (or anything with ok?, problems and unreachable). A refused saved
      # value is not offered again. Returns [value, result], or nil when the
      # user enters nothing and required is false.
      def ask_checked_secret(label, default: nil, required: true, needs: [])
        loop do
          value = ask(label, default: default, required: required, secret: true)
          return nil if value.nil?

          say "Checking it with Cloudflare..."
          result = yield value
          return [value, result] if result.ok?

          if result.unreachable
            say color("Could not check it: #{result.unreachable}", "33")
            return [value, result] if confirm("Use it without checking?", default: false)
            next
          end

          say color("That token was refused:", "31")
          result.problems.each { |problem| say "  - #{problem}" }
          unless needs.empty?
            say "The token needs:"
            needs.each { |need| say "  - #{need}" }
          end
          say "Paste a corrected token, or create a new one."
          default = nil if value == default
        end
      end

      # Show steps the user must do elsewhere (e.g. in a dashboard), then
      # re-check on Enter until the block returns true. Typing "skip"
      # returns false.
      def wait_until_done(lines, done_label:)
        lines.each { |line| say line }
        loop do
          output.print "#{done_label} [Enter to check again, or type skip]: "
          answer = input.gets
          raise InputClosed, "Input ended while waiting for: #{done_label}" if answer.nil?
          return false if answer.strip.downcase == "skip"
          return true if yield
          say color("Not yet.", "33")
        end
      end

      def ask_integer(label, default:)
        loop do
          value = ask(label, default: default)
          return Integer(value)
        rescue ArgumentError, TypeError
          output.puts "#{label} must be a number."
        end
      end

      def ask_choice(prompt, choices:, default:)
        loop do
          raw = ask("#{prompt} (#{choices.join(' / ')})", default: default).to_s.downcase
          return raw if choices.include?(raw)

          output.puts "Choose one of: #{choices.join(', ')}."
        end
      end

      def confirm(label, default:)
        suffix = default ? "Y/n" : "y/N"
        output.print "#{label} [#{suffix}]: "
        answer = input.gets.to_s.strip.downcase
        return default if answer.empty?
        %w[y yes].include?(answer)
      end

      def section_header(title)
        output.puts
        output.puts color("== #{title} ==", "36")
        output.puts color("-" * (title.length + 6), "36")
      end

      def color(text, code)
        return text unless output.respond_to?(:tty?) && output.tty?
        "\e[#{code}m#{text}\e[0m"
      end

      private

      def prompt_for(label, default, secret)
        if default.to_s.empty?
          "#{label}: "
        elsif secret
          "#{label} [press Enter to keep existing]: "
        else
          "#{label} [#{default}]: "
        end
      end

      def read_value(secret)
        return input.gets unless secret

        if input.respond_to?(:tty?) && input.tty? && input.respond_to?(:raw)
          read_masked
        elsif input.respond_to?(:noecho)
          value = input.noecho(&:gets)
          output.puts
          value
        else
          input.gets
        end
      end

      # Read a line in raw mode, echoing one * per character so a paste is
      # visibly received (and a second paste visibly doubles the stars).
      # Supports Backspace and Ctrl-U; Ctrl-C aborts as usual.
      def read_masked
        value = +""
        input.raw do |io|
          loop do
            char = io.getc
            case char
            when nil
              return nil if value.empty?
              break
            when "\r", "\n"
              break
            when "\u0003"
              raise Interrupt
            when "\u0004"
              break if value.empty?
            when "\u007F", "\b"
              next if value.empty?
              value.chop!
              output.print "\b \b"
            when "\u0015"
              output.print("\b \b" * value.length)
              value.clear
            when "\e"
              skip_escape_sequence(io)
            else
              next if char.ord < 32
              value << char
              output.print "*"
            end
            output.flush if output.respond_to?(:flush)
          end
        end
        output.puts
        value
      end

      # Arrow keys and bracketed-paste markers arrive as ESC [ ... final-byte.
      def skip_escape_sequence(io)
        return unless io.getc == "["
        loop do
          char = io.getc
          break if char.nil? || char.match?(/[A-Za-z~]/)
        end
      end
    end
  end
end
