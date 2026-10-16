require_relative "test_helper"

class SshKeyCheckTest < Minitest::Test
  KEY = DevBoxer::Testing::SSH_KEY_ALICE

  def problem(value) = DevBoxer::SshKeyCheck.problem(value)

  def test_accepts_a_well_formed_key_with_or_without_a_comment
    assert_nil problem(KEY)
    assert_nil problem(KEY.split(" ")[0, 2].join(" "))
    assert_nil problem("#{KEY} my ssh-ed25519 laptop key")
  end

  def test_refuses_a_doubled_paste
    assert_match(/more than one key/, problem(KEY + KEY))
    assert_match(/more than one key/, problem("#{KEY} #{KEY}"))
  end

  def test_refuses_a_truncated_or_damaged_key
    assert_match(/damaged or cut short/, problem(KEY[0, 40]))
    assert_match(/damaged/, problem(KEY.sub("AAAA", "AA!A")))
  end

  def test_refuses_a_private_key_and_other_text
    assert_match(/private key/, problem("-----BEGIN OPENSSH PRIVATE KEY-----\nb3Blbn..."))
    assert_match(/should start with/, problem("AAAAC3NzaC1lZDI1NTE5"))
    assert_match(/nothing was entered/, problem("  "))
  end
end
