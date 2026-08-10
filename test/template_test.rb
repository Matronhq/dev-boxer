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

  # Asserting the final mode proves nothing — File.chmod reaches 0600 with or
  # without the umask guard. Stubbing chmod out leaves the umask as the only
  # thing that can have restricted the file, which is precisely the state a
  # crash between File.write and File.chmod would leave on disk.
  def test_render_to_never_creates_a_secret_bearing_file_world_readable
    Dir.mktmpdir do |dir|
      tpl = "#{dir}/in.env"
      File.write(tpl, "HMAC_SECRET={{SECRET}}\n")
      out = "#{dir}/out.env"

      previous = File.umask(0o000)
      begin
        File.stub(:chmod, nil) do
          DevBoxer::Template.render_to(tpl, out, { "SECRET" => "s3cret" }, mode: 0o600)
        end
      ensure
        File.umask(previous)
      end

      assert_equal 0o600, File.stat(out).mode & 0o777
    end
  end

  # Without the ensure, a template that fails to write would leave the process
  # umask at 0o077 for the rest of the run, silently tightening every file a
  # later module creates.
  def test_render_to_restores_the_process_umask_when_the_write_fails
    Dir.mktmpdir do |dir|
      tpl = "#{dir}/in.env"
      File.write(tpl, "X={{Y}}")

      previous = File.umask(0o022)
      begin
        assert_raises(Errno::EACCES, Errno::ENOENT) do
          DevBoxer::Template.render_to(tpl, "/proc/nope/out.env", { "Y" => "1" }, mode: 0o600)
        end
        assert_equal 0o022, File.umask
      ensure
        File.umask(previous)
      end
    end
  end

  def test_render_to_leaves_the_umask_alone_for_ordinary_files
    Dir.mktmpdir do |dir|
      tpl = "#{dir}/in.txt"
      File.write(tpl, "hi")
      previous = File.umask(0o022)
      begin
        File.stub(:chmod, nil) do
          DevBoxer::Template.render_to(tpl, "#{dir}/out.txt", {}, mode: 0o644)
        end
        assert_equal 0o644, File.stat("#{dir}/out.txt").mode & 0o777
      ensure
        File.umask(previous)
      end
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
      "CF_HOSTNAME_VIEWER" => "viewer.example.com",
      "CF_HOSTNAME_HELLO" => "hello.example.com",
      "CF_ZONE_NAME" => "example.com",
      "USER_EXPERIENCE_GUIDANCE" => "The user selected intermediate mode.",
    })

    assert_includes rendered, "Use this file as local context for coding sessions on this machine."
    assert_includes rendered, "Make new projects under `/home/dev/projects`"
    assert_includes rendered, "create a private GitHub repository with `gh` as early as practical"
    assert_includes rendered, "When the user asks for a new web-based project"
    assert_includes rendered, "Share the live URL with the user as soon as there is a minimal working page"
    assert_includes rendered, "When the user asks you to clone or work on an existing project"
    assert_includes rendered, "If it runs a local web server, start it on a stable local port"
    assert_includes rendered, "Commit changes on a branch, push that branch when useful, and open a pull request"
    assert_includes rendered, "For new GitHub projects, set up lightweight CI with GitHub Actions"
    assert_includes rendered, "Run the relevant test and lint commands before reporting work as complete"
    assert_includes rendered, "On the first prompt in a fresh session outside an existing project directory"
    assert_includes rendered, "create a new web project with a live private URL or work on an existing repository"
    assert_includes rendered, "If the session starts inside a project/repo, skip this opener"
    assert_includes rendered, "Hello-world smoke test hostname: `hello.example.com`"
    assert_includes rendered, "Cloudflare zone: `example.com`"
    assert_includes rendered, "create a proxied CNAME to the existing Cloudflare Tunnel target"
    assert_includes rendered, "Subdomain naming controls access"
    assert_includes rendered, "`public-<name>.example.com`"
    assert_includes rendered, "cloudflareaccess.com/cdn-cgi/access/login"
    assert_includes rendered, "confirmation from the user during a Matron bridge session"
    assert_includes rendered, "## Dev Boxer Services"
    assert_includes rendered, "dev-boxer-hello-world.service"
    assert_includes rendered, "Check service status:"
    assert_includes rendered, "Follow service logs:"
    refute_includes rendered, "Bridge Commands"
    refute_includes rendered, "`!start"
  end
end
