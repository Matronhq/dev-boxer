require_relative "test_helper"

class GithubTokenCheckTest < Minitest::Test
  CLASSIC = "ghp_#{"a1" * 18}".freeze
  FINE_GRAINED = "github_pat_#{"B2c" * 27}x".freeze
  NOW = Time.utc(2030, 1, 1)

  def shape(token) = DevBoxer::GithubTokenCheck.shape_problem(token)

  def check(token, status: 200, headers: {}, body: "{}")
    calls = []
    transport = lambda do |uri, request_headers|
      calls << [uri.to_s, request_headers]
      [status, headers, body]
    end
    result = DevBoxer::GithubTokenCheck.new(transport: transport, today: -> { NOW }).check(token)
    [result, calls]
  end

  def test_shape_accepts_classic_and_fine_grained_tokens
    assert_nil shape(CLASSIC)
    assert_nil shape(FINE_GRAINED)
  end

  def test_shape_refuses_doubled_paste_spaces_and_other_kinds
    assert_match(/pasted twice/, shape(CLASSIC * 2))
    assert_match(/spaces or line breaks/, shape("#{CLASSIC} #{FINE_GRAINED}"))
    assert_match(/GitHub App/, shape("ghs_#{"a" * 36}"))
    assert_match(/start with github_pat_ or ghp_/, shape("not-a-token"))
  end

  def test_a_bad_shape_is_refused_without_calling_github
    result, calls = check("short")
    refute result.ok?
    assert_empty calls
  end

  def test_an_accepted_fine_grained_token_passes
    result, calls = check(FINE_GRAINED)
    assert result.ok?, result.problems.inspect
    assert_equal "https://api.github.com/user", calls.first[0]
    assert_equal "Bearer #{FINE_GRAINED}", calls.first[1]["Authorization"]
  end

  def test_unrecognised_token_is_refused
    result, = check(CLASSIC, status: 401, body: '{"message":"Bad credentials"}')
    assert_match(/does not recognise it/, result.problems.join)
  end

  def test_classic_token_without_read_org_is_refused
    result, = check(CLASSIC, headers: { "X-OAuth-Scopes" => "repo, gist" })
    assert_match(/missing the read:org scope/, result.problems.join)
  end

  def test_classic_token_with_a_broader_org_scope_passes
    result, = check(CLASSIC, headers: { "X-OAuth-Scopes" => "repo, admin:org" })
    assert result.ok?, result.problems.inspect
  end

  def test_soon_expiring_token_passes_with_a_warning
    result, = check(FINE_GRAINED, headers: { "github-authentication-token-expiration" => "2030-01-04 00:00:00 UTC" })
    assert result.ok?
    assert_match(/expires in 3 days/, result.warnings.join)
  end

  def test_outage_and_rate_limit_are_not_a_refusal
    outage, = check(CLASSIC, status: 503)
    limited, = check(CLASSIC, status: 403, headers: { "X-RateLimit-Remaining" => "0" })
    [outage, limited].each do |result|
      refute result.ok?
      assert_empty result.problems
      assert result.unreachable
    end
  end

  def test_network_failure_is_reported_as_unreachable
    transport = ->(*) { raise DevBoxer::GithubTokenCheck::Unreachable, "could not reach api.github.com" }
    result = DevBoxer::GithubTokenCheck.new(transport: transport).check(CLASSIC)
    assert_empty result.problems
    assert_match(/could not reach/, result.unreachable)
  end
end
