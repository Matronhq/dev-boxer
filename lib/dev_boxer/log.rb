module DevBoxer
  class Log
    COLORS = {
      reset:  "\e[0m",
      bold:   "\e[1m",
      dim:    "\e[2m",
      red:    "\e[31m",
      green:  "\e[32m",
      yellow: "\e[33m",
      blue:   "\e[34m",
      cyan:   "\e[36m",
    }.freeze

    def initialize(io: $stdout, color: io.respond_to?(:tty?) && io.tty?)
      @io = io
      @color = color
    end

    def section(title)
      bar = "=" * [title.length + 4, 60].max
      write(:bold, bar)
      write(:bold, "  #{title}")
      write(:bold, bar)
    end

    def info(msg)
      @io.puts msg
    end

    def ok(msg)
      write(:green, "  ✓ #{msg}")
    end

    def skip(msg)
      write(:dim, "  - #{msg}")
    end

    def warn(msg)
      write(:yellow, "  ! #{msg}")
    end

    def error(msg)
      write(:red, "  ✗ #{msg}")
    end

    private

    def write(color, msg)
      if @color
        @io.puts "#{COLORS[color]}#{msg}#{COLORS[:reset]}"
      else
        @io.puts msg
      end
    end
  end
end
