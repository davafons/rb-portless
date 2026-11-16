# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/proxy"

# Mirror of packages/portless/src/hosts-sync-client.test.ts
describe "hosts-sync internal client" do
  include ProxyTestSupport

  auth = Portless::HostsSyncAuth

  # beforeAll: one generated server cert shared by the HTTPS cases.
  def self.tls
    @tls ||= begin
      dir = Dir.mktmpdir("portless-hosts-sync-tls-")
      Minitest.after_run { FileUtils.rm_rf(dir) }
      certs = Portless::Certs.ensure_certs(dir)
      { cert: File.read(certs[:cert_path]), key: File.read(certs[:key_path]) }
    end
  end

  def create_dir = mktmpdir("portless-hosts-sync-client-")

  def start(state_dir, client_token: nil, daemon_token: "a" * 64, encrypted: false, result: :acted)
    Portless::HostsSyncAuth.write_token(state_dir, client_token) unless client_token.nil?
    calls = 0
    port = start_proxy(
      [], hosts_sync_token: daemon_token,
          on_hosts_sync_request: lambda {
            calls += 1
            result
          },
          **(encrypted ? { tls: self.class.tls } : {})
    )
    { port: port, calls: -> { calls } }
  end

  it "preserves the %s result" do
    [
      [ "acted over HTTP", false, :acted ],
      [ "acted over HTTPS", true, :acted ],
      [ "disabled", false, :disabled ]
    ].each do |name, encrypted, result|
      dir = create_dir
      token = "a" * 64
      running = start(dir, client_token: token, encrypted: encrypted, result: result)

      assert_equal result, Portless::Daemon.trigger_hosts_sync(running[:port], encrypted, dir), name
      assert_equal 1, running[:calls].call, name
    end
  end

  it "rejects %s" do
    [
      [ "stale authorization", "a" * 64, "b" * 64 ],
      [ "missing authorization", nil, "a" * 64 ]
    ].each do |name, client_token, daemon_token|
      dir = create_dir
      running = start(dir, client_token: client_token, daemon_token: daemon_token)

      assert_equal :mute, Portless::Daemon.trigger_hosts_sync(running[:port], false, dir), name
      assert_equal 0, running[:calls].call, name
    end
  end

  it "does not disclose authorization to an older or marker-copying service" do
    dir = create_dir
    auth.write_token(dir, "a" * 64)
    posts = 0
    server = listen_backend do |req|
      posts += 1 if req.method == "POST"
      [ req.method == "HEAD" ? 200 : 204, { "x-portless" => "1" }, [] ]
    end

    assert_equal :mute, Portless::Daemon.trigger_hosts_sync(server.port, false, dir)
    assert_equal 0, posts
  end

  it "does not disclose authorization when the proof header is duplicated" do
    dir = create_dir
    token = "a" * 64
    auth.write_token(dir, token)
    posts = 0
    server = listen_backend do |req|
      headers = [ [ "x-portless", "1" ] ]
      challenge = req.headers[auth::HOSTS_SYNC_AUTH_CHALLENGE_HEADER]&.to_s
      if req.method == "HEAD" && challenge.is_a?(String)
        proof = auth.create_proof(token, challenge)
        headers.push([ auth::HOSTS_SYNC_AUTH_PROOF_HEADER, proof ], [ auth::HOSTS_SYNC_AUTH_PROOF_HEADER, proof ])
      end
      posts += 1 if req.method == "POST"
      [ req.method == "HEAD" ? 200 : 204, Protocol::HTTP::Headers.new(headers), [] ]
    end

    assert_equal :mute, Portless::Daemon.trigger_hosts_sync(server.port, false, dir)
    assert_equal 0, posts
  end

  it "shares one 500 ms deadline across capability discovery and the privileged request" do
    dir = create_dir
    token = "a" * 64
    auth.write_token(dir, token)
    server = listen_backend do |req|
      headers = { "x-portless" => "1" }
      challenge = req.headers[auth::HOSTS_SYNC_AUTH_CHALLENGE_HEADER]&.to_s
      if req.method == "HEAD" && challenge.is_a?(String)
        headers[auth::HOSTS_SYNC_AUTH_PROOF_HEADER] = auth.create_proof(token, challenge)
      end
      sleep 0.3
      [ req.method == "POST" ? 204 : 200, headers, [] ]
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_equal :mute, Portless::Daemon.trigger_hosts_sync(server.port, false, dir)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :>=, 0.45
    assert_operator elapsed, :<, 0.8
  end

  it "uses the configured state directory by default" do
    dir = create_dir
    previous = ENV.fetch("PORTLESS_STATE_DIR", nil)
    ENV["PORTLESS_STATE_DIR"] = dir
    running = start(dir, client_token: "a" * 64)
    begin
      assert_equal :acted, Portless::Daemon.trigger_hosts_sync(running[:port])
    ensure
      ENV["PORTLESS_STATE_DIR"] = previous
    end
  end
end
