require_relative "test_helper"

class LogTest < Minitest::Test
  def setup
    @out = StringIO.new
    @log = DevBoxer::Log.new(io: @out, color: false)
  end

  def test_section_writes_header_with_separator
    @log.section("Matrix bridge")
    assert_match(/Matrix bridge/, @out.string)
    assert_match(/={3,}/, @out.string)
  end

  def test_info_writes_plain_line
    @log.info("starting")
    assert_equal "starting\n", @out.string
  end

  def test_ok_prefixes_with_check
    @log.ok("done")
    assert_match(/✓.*done/, @out.string)
  end

  def test_skip_prefixes_with_dash
    @log.skip("already installed")
    assert_match(/-.*already installed/, @out.string)
  end

  def test_warn_prefixes_with_bang
    @log.warn("watch out")
    assert_match(/!.*watch out/, @out.string)
  end

  def test_error_prefixes_with_x
    @log.error("boom")
    assert_match(/✗.*boom/, @out.string)
  end
end
