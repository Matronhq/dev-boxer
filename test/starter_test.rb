require_relative "test_helper"
require "tmpdir"
require_relative "../lib/dev_boxer/modules/08_matron"

class StarterTest < Minitest::Test
  def test_first_run_and_add_box_produce_valid_profiles
    public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGP4T5GJsgHLV5B6gGfmWsWxm1uKZ2bJH9UKZcf3T3fP fixture"
    ["1", "2"].each do |choice|
      Dir.mktmpdir do |dir|
        input = StringIO.new([choice, "alice", "codex", "203.0.113.7", "y", public_key, "https://chat.example.com"].join("\n") + "\n")
        path = File.join(dir, "config.yml")
        DevBoxer::StarterWizard.run(config_path: path, input: input, output: StringIO.new)
        config = DevBoxer::Config.load(path)
        assert_empty DevBoxer::Config.validation_errors(config)
        assert_equal 22, config.ssh.port
        assert_equal "starter", config.setup.profile
        assert_equal "codex", config.agent.provider
        assert_equal 0o600, File.stat(File.join(dir, "secrets.yml")).mode & 0o777
        if choice == "2"
          assert_equal "wss://chat.example.com/ws", config.journal.url
        else
          assert_equal "bundled", config.journal.mode
        end
      end
    end
  end

  def test_declining_terms_does_not_write_configuration
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      assert_raises(DevBoxer::SetupError) do
        DevBoxer::StarterWizard.run(config_path: path, input: StringIO.new("1\nalice\nclaude\n203.0.113.7\nn\n"), output: StringIO.new)
      end
      refute File.exist?(path)
    end
  end

  def test_bad_addresses_and_urls_cannot_enter_proxy_configuration
    %w[127.0.0.1 10.0.0.1 0.0.0.0 224.0.0.1 100.64.0.1 192.168.1.1 ::1 example.com 203.0.113.7/24].each do |address|
      assert DevBoxer::StarterWizard.address_problem(address), address
    end
    assert DevBoxer::StarterWizard.address_problem("203.0.113.7;id")
    %w[http://example.com https://example.com/app https://alice:password@example.com https://example.com/?token=x].each do |origin|
      assert DevBoxer::StarterWizard.origin_problem(origin), origin
    end
    assert_nil DevBoxer::StarterWizard.origin_problem("https://chat.example.com:8443/")
  end

  def test_starter_only_installs_selected_provider_and_essential_modules
    modules = DevBoxer::Modules.discover(File.expand_path("../lib/dev_boxer/modules", __dir__))
    %w[claude codex].each do |provider|
      io = StringIO.new
      config = DevBoxer::Config.from_hash({"setup" => {"profile" => "starter"}, "agent" => {"provider" => provider}})
      DevBoxer::Runner.new(modules: modules, config: config, log: DevBoxer::Log.new(io: io)).run(dry_run: true)
      assert_includes io.string, provider
      assert_includes io.string, "onboarding"
      refute_match(/docker|browsers|desktop|hello-world/, io.string)
      refute_includes io.string, provider == "codex" ? "claude" : "codex"
    end
  end

  def test_password_provisioning_uses_stdin_and_never_logs_it
    Dir.mktmpdir do |dir|
      calls = []
      io = StringIO.new
      shell = DevBoxer::Shell.new(runner: ->(cmd, opts) { calls << [cmd, opts]; [true, "", ""] })
      mod = DevBoxer::Modules::Matron.new(config: DevBoxer::Config.from_hash({"user" => {"name" => "alice"}}),
        shell: shell, log: DevBoxer::Log.new(io: io), secrets_path: File.join(dir, "secrets.yml"))
      mod.stub(:journal_user_exists?, false) { mod.send(:ensure_journal_user) }
      password = YAML.safe_load_file(File.join(dir, "secrets.yml")).dig("journal", "user_password")
      assert_equal password, calls.first.last[:stdin]
      assert_includes calls.first.first, "--password-stdin"
      refute_includes calls.first.first, password
      refute_includes io.string, password
    end
  end

  def test_public_https_does_not_trust_client_supplied_forwarding_headers
    config = DevBoxer::Config.from_hash({"journal" => {"mode" => "bundled"}, "exposure" => {"mode" => "public-ip", "ip" => {"address" => "203.0.113.7"}}})
    ex = DevBoxer::Exposure.for(config: config, shell: DevBoxer::Shell.new, log: DevBoxer::Log.new(io: StringIO.new))
    proxy = ex.nginx_config(tls: true)
    assert_includes proxy, "proxy_set_header CF-Connecting-IP $remote_addr;"
    assert_includes proxy, "proxy_set_header X-Forwarded-For $remote_addr;"
    refute_includes proxy, "$proxy_add_x_forwarded_for"
    assert_includes proxy, "listen 443 ssl;"
    assert_includes proxy, "listen 8444 ssl;"
    refute_includes ex.nginx_config(tls: false), "ssl_certificate"
    assert_includes ex.issue_command, "--preferred-profile shortlived"
    refute_match(/--staging|--manual|--standalone/, ex.issue_command)
  end
end
