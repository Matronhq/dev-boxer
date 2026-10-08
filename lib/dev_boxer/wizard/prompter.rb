require "io/console"

module DevBoxer
  class Wizard
    # All terminal I/O for the wizard. Sections share one instance.
    class Prompter
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
          value = value.to_s.strip

          return value unless value.empty?
          return default unless default.to_s.empty?
          return nil unless required

          output.puts "#{label} is required."
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
        if secret && input.respond_to?(:noecho)
          value = input.noecho(&:gets)
          output.puts
          value
        else
          input.gets
        end
      end
    end
  end
end
