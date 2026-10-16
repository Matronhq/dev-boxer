require_relative "test_helper"

class CloudflareTokenCheckTest < Minitest::Test
  Transport = DevBoxer::Testing::FakeCloudflareTransport
  LEGACY = "a1B2-c3D4_e5F6g7H8i9J0k1L2m3N4o5P6q7R8s9".freeze
  ACCOUNT_TOKEN = "cfat_#{"x" * 40}ab12cd34".freeze
  INVALID = Transport.failure(400, 1000, "Invalid API Token")
  AUTH_ERROR = Transport.failure(403, 10000, "Authentication error")
  NOT_ENABLED = Transport.failure(403, 12006, "access.api.error.not_enabled: Access is not enabled.")
  ACTIVE = { "id" => "token-1", "status" => "active" }.freeze
  ZONE = { "id" => "zone-1", "name" => "example.com", "account" => { "id" => "acct-1" } }.freeze

  def shape(token) = DevBoxer::CloudflareTokenCheck.shape_problem(token)

  def test_shape_accepts_legacy_and_prefixed_tokens
    assert_equal 40, LEGACY.length
    assert_nil shape(LEGACY)
    assert_nil shape(ACCOUNT_TOKEN)
    assert_nil shape("cfut_#{"Y" * 40}zz99")
  end

  def test_shape_spots_a_doubled_paste
    assert_match(/pasted twice/, shape(LEGACY * 2))
    assert_match(/pasted twice/, shape("#{ACCOUNT_TOKEN} #{ACCOUNT_TOKEN}"))
  end

  def test_shape_refuses_global_api_keys
    assert_match(/Global API Key/, shape("cfk_#{"a" * 40}abcd1234"))
    assert_match(/Global API Key/, shape("0123456789abcdef0123456789abcdef01234"))
  end

  def test_shape_reports_length_and_whitespace
    assert_match(/is 10 characters long/, shape("short12345"))
    assert_match(/spaces or line breaks/, shape("#{LEGACY} extra"))
    assert_match(/nothing was entered/, shape(""))
  end

  def test_zone_token_passes_when_active_and_it_can_see_zone_and_dns
    transport = Transport.new(
      "GET /zones" => [ZONE],
      "GET /user/tokens/verify" => ACTIVE,
      "GET /zones/zone-1/dns_records" => [],
    )
    result = checker(transport).check_zone_token(LEGACY, zone_name: "example.com")

    assert result.ok?, result.problems.inspect
    assert_equal "acct-1", result.account_id
  end

  def test_unrecognised_token_is_refused_with_the_reason
    transport = Transport.new(
      "GET /zones" => AUTH_ERROR,
      "GET /user/tokens/verify" => INVALID,
      "GET /accounts" => AUTH_ERROR,
    )
    result = checker(transport).check_zone_token(LEGACY, zone_name: "example.com")

    refute result.ok?
    assert_match(/does not recognise it/, result.problems.join)
  end

  def test_zone_token_that_cannot_see_the_zone_names_the_permission
    transport = Transport.new(
      "GET /zones" => [],
      "GET /user/tokens/verify" => ACTIVE,
    )
    result = checker(transport).check_zone_token(LEGACY, zone_name: "example.com")

    assert_match(/cannot see the zone example.com.*Zone: Read/, result.problems.join)
  end

  def test_disabled_token_is_refused
    transport = Transport.new(
      "GET /zones" => [ZONE],
      "GET /user/tokens/verify" => { "status" => "disabled" },
    )
    result = checker(transport).check_zone_token(LEGACY, zone_name: "example.com")

    assert_match(/disabled, not active/, result.problems.join)
  end

  def test_account_owned_token_verifies_against_its_account
    transport = Transport.new(
      "GET /accounts/acct-1/tokens/verify" => ACTIVE,
      "GET /accounts/acct-1/cfd_tunnel" => [],
      "GET /accounts/acct-1/access/apps" => [],
    )
    result = checker(transport).check_setup_token(ACCOUNT_TOKEN, account_id: "acct-1", needs_access: true)

    assert result.ok?, result.problems.inspect
    assert_equal "acct-1", result.account_id
    refute_includes transport.calls.map(&:first), "GET /user/tokens/verify"
  end

  def test_setup_token_without_tunnel_permission_is_refused
    transport = Transport.new(
      "GET /user/tokens/verify" => ACTIVE,
      "GET /accounts/acct-1/cfd_tunnel" => AUTH_ERROR,
    )
    result = checker(transport).check_setup_token(LEGACY, account_id: "acct-1", needs_access: false)

    assert_match(/cannot manage Cloudflare Tunnels.*cloudflared: Edit/, result.problems.join)
  end

  def test_setup_token_without_access_permission_is_refused_only_when_access_is_needed
    routes = {
      "GET /user/tokens/verify" => ACTIVE,
      "GET /accounts/acct-1/cfd_tunnel" => [],
      "GET /accounts/acct-1/access/apps" => AUTH_ERROR,
    }
    with_access = checker(Transport.new(routes)).check_setup_token(LEGACY, account_id: "acct-1", needs_access: true)
    without_access = checker(Transport.new(routes)).check_setup_token(LEGACY, account_id: "acct-1", needs_access: false)

    assert_match(/Access: Apps: Edit/, with_access.problems.join)
    assert without_access.ok?
  end

  def test_access_not_switched_on_is_flagged_separately_from_token_problems
    transport = Transport.new(
      "GET /user/tokens/verify" => ACTIVE,
      "GET /accounts/acct-1/cfd_tunnel" => [],
      "GET /accounts/acct-1/access/apps" => NOT_ENABLED,
    )
    result = checker(transport).check_setup_token(LEGACY, account_id: "acct-1", needs_access: true)

    assert result.ok?, "the token itself is fine"
    assert result.access_not_enabled
  end

  def test_setup_token_finds_its_account_when_none_is_known
    transport = Transport.new(
      "GET /accounts" => [{ "id" => "acct-1" }, { "id" => "acct-2" }],
      "GET /user/tokens/verify" => ACTIVE,
      "GET /accounts/acct-1/cfd_tunnel" => AUTH_ERROR,
      "GET /accounts/acct-2/cfd_tunnel" => [],
    )
    result = checker(transport).check_setup_token(LEGACY, account_id: nil, needs_access: false)

    assert result.ok?, result.problems.inspect
    assert_equal "acct-2", result.account_id
  end

  def test_unreachable_api_is_reported_not_treated_as_a_refusal
    transport = ->(*) { raise DevBoxer::CloudflareAPI::Unreachable, "could not reach api.cloudflare.com" }
    client = DevBoxer::CloudflareAPI::Client.new(transport: transport)
    result = DevBoxer::CloudflareTokenCheck.new(client: client).check_zone_token(LEGACY, zone_name: "example.com")

    refute result.ok?
    assert_empty result.problems
    assert_match(/could not reach/, result.unreachable)
  end

  def test_cloudflare_server_errors_are_an_outage_not_a_bad_token
    transport = Transport.new(
      "GET /zones" => Transport.failure(503, 10001, "Service unavailable"),
      "GET /user/tokens/verify" => Transport.failure(503, 10001, "Service unavailable"),
    )
    result = checker(transport).check_zone_token(LEGACY, zone_name: "example.com")

    assert_empty result.problems
    assert_match(/HTTP 503/, result.unreachable)
  end

  def test_access_state_reports_an_outage_instead_of_raising
    transport = ->(*) { raise DevBoxer::CloudflareAPI::Unreachable, "timeout" }
    client = DevBoxer::CloudflareAPI::Client.new(transport: transport)

    assert_equal :unreachable, DevBoxer::CloudflareTokenCheck.new(client: client).access_state(LEGACY, "acct-1")
  end

  def test_access_outage_during_the_setup_token_check_is_not_a_pass
    transport = Transport.new(
      "GET /user/tokens/verify" => ACTIVE,
      "GET /accounts/acct-1/cfd_tunnel" => [],
      "GET /accounts/acct-1/access/apps" => Transport.failure(502, 10001, "Bad gateway"),
    )
    result = checker(transport).check_setup_token(LEGACY, account_id: "acct-1", needs_access: true)

    refute result.ok?
    assert_match(/check Access/, result.unreachable)
  end

  def test_api_error_knows_an_authentication_failure
    client = DevBoxer::CloudflareAPI::Client.new(transport: Transport.new("POST /accounts/acct-1/cfd_tunnel" => AUTH_ERROR))
    error = assert_raises(DevBoxer::CloudflareAPI::Error) do
      client.call(token: LEGACY, method: :post, path: "/accounts/acct-1/cfd_tunnel", body: {})
    end

    assert error.auth_failure?
    assert_equal "Cloudflare API POST /accounts/acct-1/cfd_tunnel failed: Authentication error", error.message
  end

  private

  def checker(transport)
    DevBoxer::CloudflareTokenCheck.new(client: DevBoxer::CloudflareAPI::Client.new(transport: transport))
  end
end
