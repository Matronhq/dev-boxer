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

  def test_claude_md_template_is_agent_facing
    template = File.expand_path("../templates/CLAUDE.md.template", __dir__)
    rendered = DevBoxer::Template.render(template, {
      "USERNAME" => "dev",
      "SSH_PORT" => 2222,
      "CF_HOSTNAME_MAIN" => "dev.example.com",
      "CF_HOSTNAME_MATRIX" => "matrix.example.com",
      "CF_HOSTNAME_VIEWER" => "viewer.example.com",
      "CF_ZONE_NAME" => "example.com",
      "USER_EXPERIENCE_GUIDANCE" => "The user selected intermediate mode.",
    })

    assert_includes rendered, "This file is for Claude Code, not a human connection guide."
    assert_includes rendered, "Make new projects under `/home/dev/projects`"
    assert_includes rendered, "Cloudflare zone: `example.com`"
    refute_includes rendered, "Bridge Commands"
    refute_includes rendered, "`!start"
  end
end
