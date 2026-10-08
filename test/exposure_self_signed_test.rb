require_relative "test_helper"
require "tmpdir"
require_relative "support/module_test_case"

class ExposureSelfSignedTest < DevBoxer::Testing::ModuleTestCase
  def build_strategy(config_hash = {})
    base = {
      "user" => { "name" => "dev" },
      "journal" => { "mode" => "bundled" },
      "exposure" => { "mode" => "ip" },
      "hello_world" => { "port" => 9820 },
    }
    DevBoxer::Exposure::SelfSigned.new(
      config: DevBoxer::Config.from_hash(DevBoxer::Config.deep_merge(base, config_hash)),
      shell: @shell,
      log: @log,
    )
  end

  def test_urls_use_configured_address_and_default_ports
    strategy = build_strategy("exposure" => { "ip" => { "address" => "203.0.113.7" } })

    assert_equal "wss://203.0.113.7:8443/ws", strategy.journal_public_url
    assert_equal "https://203.0.113.7:8444", strategy.viewer_base_url
    assert_equal "https://203.0.113.7:8445", strategy.hello_url
  end

  def test_urls_respect_configured_ports
    strategy = build_strategy("exposure" => { "ip" => {
      "address" => "203.0.113.7", "journal_port" => 10443, "viewer_port" => 10444, "hello_port" => 10445,
    } })

    assert_equal "wss://203.0.113.7:10443/ws", strategy.journal_public_url
    assert_equal "https://203.0.113.7:10444", strategy.viewer_base_url
    assert_equal "https://203.0.113.7:10445", strategy.hello_url
  end

  def test_ip_detected_from_hostname_when_not_configured
    respond("hostname -I", success: true, stdout: "198.51.100.5 fe80::1\n")
    strategy = build_strategy

    assert_equal "https://198.51.100.5:8444", strategy.viewer_base_url
  end

  def test_ip_detection_failure_raises_with_remedy
    respond("hostname -I", success: false, stderr: "boom")
    strategy = build_strategy

    error = assert_raises(RuntimeError) { strategy.viewer_base_url }
    assert_match(/exposure\.ip\.address/, error.message)
  end

  def test_external_journal_passes_url_through_and_omits_journal_surface
    strategy = build_strategy(
      "journal" => { "mode" => "external", "url" => "wss://chat.example.com/ws" },
      "exposure" => { "ip" => { "address" => "203.0.113.7" } },
    )

    assert_equal "wss://chat.example.com/ws", strategy.journal_public_url
    refute_includes strategy.nginx_config, "listen 8443"
    refute_includes strategy.firewall_ports.map(&:to_s), "8443"
  end

  def test_nginx_config_has_three_tls_blocks_with_websocket_upgrade
    strategy = build_strategy("exposure" => { "ip" => { "address" => "203.0.113.7" } })
    conf = strategy.nginx_config

    assert_includes conf, "listen 8443 ssl;"
    assert_includes conf, "listen 8444 ssl;"
    assert_includes conf, "listen 8445 ssl;"
    assert_includes conf, "proxy_pass http://127.0.0.1:9810;"
    assert_includes conf, "proxy_pass http://127.0.0.1:9803;"
    assert_includes conf, "proxy_pass http://127.0.0.1:9820;"
    assert_includes conf, "proxy_set_header Upgrade $http_upgrade;"
    assert_includes conf, "ssl_certificate /etc/matron/tls/cert.pem;"
    assert_includes conf, "ssl_certificate_key /etc/matron/tls/key.pem;"
  end

  def test_setup_generates_cert_with_ip_san_when_missing
    Dir.mktmpdir do |dir|
      respond_default(success: true)
      strategy = build_strategy("exposure" => { "ip" => { "address" => "203.0.113.7" } })

      strategy.stub(:tls_dir, dir) do
        strategy.stub(:nginx_site_path, File.join(dir, "matron")) do
          strategy.setup!
        end
      end

      assert_recorded(/openssl req -x509 .*subjectAltName=IP:203\.0\.113\.7/)
      assert_recorded(/ufw allow 8443\/tcp/)
      assert_recorded(/ufw allow 8444\/tcp/)
      assert_recorded(/ufw allow 8445\/tcp/)
      assert_recorded(/nginx -t/)
    end
  end

  def test_setup_skips_cert_generation_when_san_matches
    Dir.mktmpdir do |dir|
      respond_default(success: true)
      FileUtils.touch(File.join(dir, "cert.pem"))
      FileUtils.touch(File.join(dir, "key.pem"))
      respond("openssl x509 -in #{File.join(dir, 'cert.pem')} -noout -ext subjectAltName",
        success: true, stdout: "X509v3 Subject Alternative Name:\n    IP Address:203.0.113.7\n")
      strategy = build_strategy("exposure" => { "ip" => { "address" => "203.0.113.7" } })

      strategy.stub(:tls_dir, dir) do
        strategy.stub(:nginx_site_path, File.join(dir, "matron")) do
          strategy.setup!
        end
      end

      refute_recorded(/openssl req -x509/)
    end
  end

  def test_summary_lines_include_fingerprint_and_self_signed_warning
    Dir.mktmpdir do |dir|
      FileUtils.touch(File.join(dir, "cert.pem"))
      respond("openssl x509 -in #{File.join(dir, 'cert.pem')} -noout -fingerprint -sha256",
        success: true, stdout: "sha256 Fingerprint=AA:BB:CC\n")
      strategy = build_strategy("exposure" => { "ip" => { "address" => "203.0.113.7" } })

      lines = strategy.stub(:tls_dir, dir) { strategy.summary_lines }

      assert(lines.any? { |l| l.include?("AA:BB:CC") })
      assert(lines.any? { |l| l.include?("wss://203.0.113.7:8443/ws") })
      assert(lines.any? { |l| l =~ /self-signed/i })
    end
  end
end
