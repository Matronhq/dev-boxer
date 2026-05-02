require_relative "test_helper"
require_relative "../lib/dev_boxer/credentials_blob"

class CredentialsBlobTest < Minitest::Test
  REQUIRED = {
    "homeserver_url"   => "https://matrix.example.com",
    "server_domain"    => "matrix.example.com",
    "bot_user_id"      => "@box4:matrix.example.com",
    "bot_password"     => "p4ssw0rd",
    "bot_recovery_key" => "EsTm 4uK4 abcd",
    "bridge_room_id"   => "!abc:matrix.example.com",
  }.freeze

  def test_round_trip
    encoded = DevBoxer::CredentialsBlob.encode(REQUIRED)
    assert_match(/\Adb1:/, encoded)

    decoded = DevBoxer::CredentialsBlob.decode(encoded)
    assert_equal REQUIRED, decoded
  end

  def test_decode_rejects_unknown_version_prefix
    encoded = DevBoxer::CredentialsBlob.encode(REQUIRED).sub(/\Adb1:/, "db2:")
    err = assert_raises(DevBoxer::CredentialsBlob::Invalid) { DevBoxer::CredentialsBlob.decode(encoded) }
    assert_match(/version/i, err.message)
  end

  def test_decode_rejects_missing_prefix
    body = DevBoxer::CredentialsBlob.encode(REQUIRED).split(":", 2)[1]
    err = assert_raises(DevBoxer::CredentialsBlob::Invalid) { DevBoxer::CredentialsBlob.decode(body) }
    assert_match(/prefix/i, err.message)
  end

  def test_decode_rejects_malformed_base64
    assert_raises(DevBoxer::CredentialsBlob::Invalid) { DevBoxer::CredentialsBlob.decode("db1:not-base64-!!") }
  end

  def test_decode_rejects_missing_required_key
    partial = REQUIRED.reject { |k, _| k == "bot_password" }
    encoded = "db1:" + Base64.strict_encode64(JSON.dump(partial))
    err = assert_raises(DevBoxer::CredentialsBlob::Invalid) { DevBoxer::CredentialsBlob.decode(encoded) }
    assert_match(/bot_password/, err.message)
  end

  def test_decode_rejects_bot_user_id_with_wrong_domain
    bad = REQUIRED.merge("bot_user_id" => "@box4:other.example.com")
    encoded = DevBoxer::CredentialsBlob.encode(bad)
    err = assert_raises(DevBoxer::CredentialsBlob::Invalid) { DevBoxer::CredentialsBlob.decode(encoded) }
    assert_match(/server_domain/, err.message)
  end
end
