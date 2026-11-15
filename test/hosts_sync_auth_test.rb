# frozen_string_literal: true

require "test_helper"

# Ported from hosts-sync-auth.test.ts.
class HostsSyncAuthTest < Minitest::Test
  A = Portless::HostsSyncAuth

  def setup
    @dir = Dir.mktmpdir
  end

  def teardown = FileUtils.rm_rf(@dir)

  def test_creates_private_state_and_rotates
    token = A.generate_token
    assert A.write_token(@dir, token)
    path = File.join(@dir, A::FILE)
    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_equal token, A.read_token(@dir)
    other = A.generate_token
    assert A.write_token(@dir, other)
    assert_equal other, A.read_token(@dir)
  end

  def test_rejects_malformed_tokens
    refute A.write_token(@dir, "nope")
    File.write(File.join(@dir, A::FILE), "zz")
    assert_nil A.read_token(@dir)
  end

  def test_fails_closed_when_it_cannot_publish
    refute A.write_token(File.join(@dir, "missing"), A.generate_token)
  end

  def test_proof_is_challenge_bound
    token = A.generate_token
    challenge = A.generate_challenge
    proof = A.create_proof(token, challenge)
    assert A.valid_token?(proof)
    refute_equal proof, A.create_proof(token, A.generate_challenge)
    assert_nil A.create_proof(token, "bad")
    assert_nil A.create_proof("bad", challenge)
  end

  def test_remove_token
    A.write_token(@dir, A.generate_token)
    A.remove_token(@dir)
    assert_nil A.read_token(@dir)
  end
end
