require_relative "test_helper"

class PrompterTest < Minitest::Test
  Result = DevBoxer::CloudflareTokenCheck::Result

  # A keyboard: a TTY whose raw mode hands out one character at a time.
  class FakeTTY
    def initialize(keys) = (@keys = keys.chars)
    def tty? = true
    def raw = yield(self)
    def getc = @keys.shift
    def gets
      return nil if @keys.empty?
      line = +""
      line << @keys.shift until @keys.empty? || line.end_with?("\n")
      line
    end
  end

  def prompter(input)
    @output = StringIO.new
    DevBoxer::Wizard::Prompter.new(input: input, output: @output)
  end

  def test_secret_input_on_a_terminal_echoes_a_star_per_character
    value = prompter(FakeTTY.new("abc\r")).ask("Token", secret: true)

    assert_equal "abc", value
    assert_includes @output.string, "Token: ***"
    assert_includes @output.string, "Received 3 characters."
  end

  def test_backspace_and_escape_sequences_are_handled
    value = prompter(FakeTTY.new("ab\u007Fc\e[Ad\r")).ask("Token", secret: true)

    assert_equal "acd", value
    assert_includes @output.string, "\b \b"
  end

  def test_secret_is_trimmed_of_whitespace
    value = prompter(StringIO.new("  abc  \n")).ask("Token", secret: true)

    assert_equal "abc", value
  end

  def test_closed_input_stops_instead_of_looping
    assert_raises(DevBoxer::Wizard::Prompter::InputClosed) do
      prompter(StringIO.new("")).ask("Token", secret: true)
    end
  end

  def test_refused_secret_is_asked_again_and_the_saved_one_is_not_offered_again
    checked = []
    token, result = prompter(StringIO.new("\ngood\n")).ask_checked_secret(
      "Token", default: "saved-bad", needs: ["Zone → DNS: Edit"],
    ) do |value|
      checked << value
      Result.new(problems: value == "good" ? [] : ["it is wrong"])
    end

    assert_equal "good", token
    assert result.ok?
    assert_equal ["saved-bad", "good"], checked
    assert_includes @output.string, "That token was refused:\n  - it is wrong"
    assert_includes @output.string, "  - Zone → DNS: Edit"
    assert_equal 1, @output.string.scan("press Enter to keep existing").length
  end

  def test_unreachable_check_asks_before_using_the_token
    token, = prompter(StringIO.new("abc\ny\n")).ask_checked_secret("Token") do
      Result.new(problems: [], unreachable: "could not reach api.cloudflare.com")
    end

    assert_equal "abc", token
    assert_includes @output.string, "Could not check it: could not reach api.cloudflare.com"
  end

  def test_wait_until_done_rechecks_until_ready_or_skipped
    states = [false, true]
    assert prompter(StringIO.new("\n\n")).wait_until_done(["Do the thing."], done_label: "Done?") { states.shift }
    assert_includes @output.string, "Not yet."

    refute prompter(StringIO.new("skip\n")).wait_until_done(["Do the thing."], done_label: "Done?") { false }
  end
end
