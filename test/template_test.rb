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

  # Asserting the final mode proves nothing — File.chmod reaches 0600 whether
  # or not the file was created that way. Stubbing chmod out leaves creation
  # as the only thing that can have restricted the file, which is precisely
  # the state a crash mid-write would leave on disk.
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

  # The case a umask guard cannot reach: an interrupted earlier run leaves the
  # target at 0644, and File.write over an existing file keeps that mode. Every
  # run after the first would rewrite the secret into a world-readable file.
  def test_render_to_replaces_an_existing_world_readable_target
    Dir.mktmpdir do |dir|
      tpl = "#{dir}/in.env"
      File.write(tpl, "HMAC_SECRET={{SECRET}}\n")
      out = "#{dir}/out.env"
      File.write(out, "HMAC_SECRET=stale\n")
      File.chmod(0o644, out)

      File.stub(:chmod, nil) do
        DevBoxer::Template.render_to(tpl, out, { "SECRET" => "s3cret" }, mode: 0o600)
      end

      assert_equal 0o600, File.stat(out).mode & 0o777
      assert_equal "HMAC_SECRET=s3cret\n", File.read(out)
    end
  end

  # rename(2) is atomic, so a failure must leave the previous secret in place
  # rather than a truncated file — and must not strand the temporary copy,
  # which holds the same secret.
  def test_render_to_leaves_the_target_intact_when_the_write_fails
    Dir.mktmpdir do |dir|
      tpl = "#{dir}/in.env"
      File.write(tpl, "HMAC_SECRET={{SECRET}}\n")
      out = "#{dir}/out.env"
      File.write(out, "HMAC_SECRET=previous\n")

      File.stub(:rename, ->(*) { raise Errno::EIO }) do
        assert_raises(Errno::EIO) do
          DevBoxer::Template.render_to(tpl, out, { "SECRET" => "s3cret" }, mode: 0o600)
        end
      end

      assert_equal "HMAC_SECRET=previous\n", File.read(out)
      assert_empty Dir.glob("#{dir}/.*.tmp"), "temporary copy of the secret left behind"
    end
  end

  def test_render_to_leaves_unmoded_renders_on_the_plain_write_path
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
