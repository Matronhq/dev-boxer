require_relative "test_helper"
require "tmpdir"

class TemplateTest < Minitest::Test
  def test_render_substitutes_double_brace_placeholders
    Dir.mktmpdir do |dir|
      tpl = "#{dir}/in.txt"
      File.write(tpl, "Port {{SSH_PORT}}\nUser {{USERNAME}}\n")
      out = DevBoxer::Template.render(tpl, "SSH_PORT" => 2222, "USERNAME" => "dan")
      assert_equal "Port 2222\nUser dan\n", out
    end
  end

  def test_missing_variable_substitutes_empty_string
    Dir.mktmpdir do |dir|
      tpl = "#{dir}/in.txt"
      File.write(tpl, "X={{MISSING}}")
      out = DevBoxer::Template.render(tpl, {})
      assert_equal "X=", out
    end
  end

  def test_render_to_writes_file
    Dir.mktmpdir do |dir|
      tpl = "#{dir}/in.txt"
      File.write(tpl, "hi {{NAME}}")
      out = "#{dir}/out.txt"
      DevBoxer::Template.render_to(tpl, out, { "NAME" => "dan" })
      assert_equal "hi dan", File.read(out)
    end
  end

  def test_raises_when_template_missing
    assert_raises(DevBoxer::Template::NotFound) do
      DevBoxer::Template.render("/no/such/template", {})
    end
  end
end
