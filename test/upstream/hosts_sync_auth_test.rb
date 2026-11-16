# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"

# Mirror of packages/portless/src/hosts-sync-auth.test.ts
describe "hosts-sync authorization state" do
  auth = Portless::HostsSyncAuth

  before { @dir = Dir.mktmpdir("portless-hosts-sync-auth-") }
  after { FileUtils.rm_rf(@dir) }

  it "creates private per-daemon authorization state" do
    token = auth.generate_token
    assert auth.write_token(@dir, token)
    token_path = File.join(@dir, auth::HOSTS_SYNC_AUTH_FILE)

    assert_match(/\A[a-f0-9]{64}\z/, token)
    assert_equal token, auth.read_token(@dir)
    assert_equal 0o600, File.stat(token_path).mode & 0o777
  end

  it "rotates authorization state" do
    first = "a" * 64
    second = "b" * 64
    auth.write_token(@dir, first)
    auth.write_token(@dir, second)

    refute_equal first, second
    assert_equal second, auth.read_token(@dir)
  end

  it "does not publish malformed authorization state" do
    refute auth.write_token(@dir, "not-a-token")
    assert_nil auth.read_token(@dir)
  end

  it "fails closed when authorization state cannot be published" do
    missing_dir = File.join(@dir, "missing", "state")
    refute auth.write_token(missing_dir, "a" * 64)
    assert_nil auth.read_token(missing_dir)
  end

  it "preserves the active authorization state when replacement fails" do
    active_token = "a" * 64
    replacement_token = "b" * 64
    assert auth.write_token(@dir, active_token)
    Dir.mkdir(File.join(@dir, "#{auth::HOSTS_SYNC_AUTH_FILE}.tmp"))

    refute auth.write_token(@dir, replacement_token)
    assert_equal active_token, auth.read_token(@dir)
  end

  it "creates a challenge-bound proof of authorization" do
    token = "a" * 64
    challenge = auth.generate_challenge

    assert_match(/\A[a-f0-9]{64}\z/, auth.create_proof(token, challenge))
    assert_nil auth.create_proof(token, "not-a-challenge")
  end

  it "rejects malformed authorization state %j" do
    [ "", "not-a-token", "a" * 63, "A" * 64 ].each do |value|
      File.write(File.join(@dir, auth::HOSTS_SYNC_AUTH_FILE), value)
      assert_nil auth.read_token(@dir), value.inspect
    end
  end

  it "removes authorization state" do
    auth.write_token(@dir, auth.generate_token)
    File.write(File.join(@dir, auth::HOSTS_SYNC_AUTH_TEMP_FILE), "stale")
    auth.remove_token(@dir)
    assert_nil auth.read_token(@dir)
    refute File.exist?(File.join(@dir, auth::HOSTS_SYNC_AUTH_TEMP_FILE))
  end
end
