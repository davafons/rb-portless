# frozen_string_literal: true

require_relative "test_helper"
require "socket"
require "protocol/http/request"
require "protocol/http/headers"

# The proxy app (Proxy#call) drives the routing + error + health-stamping logic
# synchronously, so we test it by invoking it directly with constructed requests
# — no async server to tear down (those hang in-process), no flakiness. The
# successful byte-forward + WebSocket relay need a live reactor and are verified
# end-to-end manually (HTTP/HTTPS/HTTP-2/wildcard/WS).
class ProxyTest < Minitest::Test
  def setup
    @store = Portless::RouteStore.new
    @proxy = Portless::Proxy.new(port: 8443, tls: true, route_store: @store)
  end

  def test_unknown_host_is_404_stamped_as_ours
    res = @proxy.call(request("nope.localhost"))
    assert_equal 404, res.status
    assert_equal Portless::VERSION, health(res)
  end

  def test_exact_and_wildcard_routing_via_route_for
    @store.add(hostname: "demo.localhost", port: 4321, pid: Process.pid)
    assert_equal 4321, @proxy.route_for("demo.localhost").port
    assert_equal 4321, @proxy.route_for("kobe.demo.localhost").port
    assert_nil @proxy.route_for("other.localhost")
  ensure
    @store.remove("demo.localhost", owner_pid: Process.pid)
  end

  # Tunnel-forwarded requests keep the public authority (upstream issue #297):
  # a route's tailscale/ngrok URL must resolve to its backend too.
  def test_share_hostnames_route_to_the_backend
    @store.add(hostname: "demo.localhost", port: 4321, pid: Process.pid,
               tailscale: "https://my-device.tail1234.ts.net:8443", ngrok: "https://abc.ngrok.app")
    assert_equal 4321, @proxy.route_for("my-device.tail1234.ts.net:8443").port
    assert_equal 4321, @proxy.route_for("my-device.tail1234.ts.net").port
    assert_equal 4321, @proxy.route_for("abc.ngrok.app").port
    assert_equal 4321, @proxy.route_for("abc.ngrok.app:443").port
    assert_nil @proxy.route_for("unrelated.ts.net")
  ensure
    @store.remove("demo.localhost", owner_pid: Process.pid)
  end

  def test_proxy_loop_is_rejected_with_508
    @store.add(hostname: "demo.localhost", port: 4321, pid: Process.pid)
    res = @proxy.call(request("demo.localhost", Portless::Proxy::HOP_HEADER => "5"))
    assert_equal 508, res.status
  ensure
    @store.remove("demo.localhost", owner_pid: Process.pid)
  end

  def test_dead_backend_is_502_stamped_as_ours
    @store.add(hostname: "demo.localhost", port: closed_port, pid: Process.pid)
    res = @proxy.call(request("demo.localhost"))
    assert_equal 502, res.status
    assert_equal Portless::VERSION, health(res)
  ensure
    @store.remove("demo.localhost", owner_pid: Process.pid)
  end

  # HTTP/2 clients may send one `cookie` field per cookie; forwarding them as
  # repeated HTTP/1.1 lines makes the backend join them with "," and corrupts
  # the values. build_forward must coalesce them into a single "; "-joined field.
  def test_split_http2_cookie_fields_are_coalesced
    list = Protocol::HTTP::Headers.new
    list.add("cookie", "_session=abc")
    list.add("cookie", "__profilin=p%3Dt")
    req = Protocol::HTTP::Request.new("http", "demo.localhost", "POST", "/", nil, list)

    fwd = @proxy.send(:build_forward, req, "demo.localhost", 0)
    cookie_fields = fwd.headers.to_a.select { |key, _| key.downcase == "cookie" }

    assert_equal 1, cookie_fields.size, "expected a single coalesced cookie field, not repeated lines"
    assert_equal "_session=abc; __profilin=p%3Dt", cookie_fields.first.last
  end

  # An h2 WebSocket opens as extended CONNECT (RFC 8441); the h1 backend needs
  # the classic GET + Upgrade instead — a raw CONNECT verb is a parse error.
  def test_h2_websocket_connect_is_forwarded_as_a_get_upgrade
    req = Protocol::HTTP::Request.new("https", "demo.localhost", "CONNECT", "/cable", "HTTP/2",
                                      Protocol::HTTP::Headers.new, nil, "websocket")
    fwd = @proxy.send(:build_forward, req, "demo.localhost", 0)
    assert_equal "GET", fwd.method
    assert_equal "websocket", fwd.protocol
    # Extended CONNECT carries no handshake nonce; the h1 backend requires one.
    refute_nil fwd.headers["sec-websocket-key"]
  end

  def test_a_true_connect_without_a_protocol_is_not_rewritten
    req = Protocol::HTTP::Request.new("https", "demo.localhost", "CONNECT", nil, "HTTP/2",
                                      Protocol::HTTP::Headers.new, nil, nil)
    assert_equal "CONNECT", @proxy.send(:build_forward, req, "demo.localhost", 0).method
  end

  # A crashing latecomer (EADDRINUSE) must never reap the live daemon's marker
  # files on its way out — that's what left root proxies unstoppable.
  def test_cleanup_leaves_markers_owned_by_another_process
    Portless::State.ensure_dir!
    File.write(Portless::State.proxy_pid_file, "999999")
    @proxy.send(:cleanup)
    assert File.exist?(Portless::State.proxy_pid_file)
  ensure
    File.delete(Portless::State.proxy_pid_file) if File.exist?(Portless::State.proxy_pid_file)
  end

  def test_cleanup_reaps_our_own_markers
    Portless::State.ensure_dir!
    File.write(Portless::State.proxy_pid_file, Process.pid.to_s)
    File.write(Portless::State.proxy_port_file, "8443")
    @proxy.send(:cleanup)
    refute File.exist?(Portless::State.proxy_pid_file)
    refute File.exist?(Portless::State.proxy_port_file)
  end

  private

  def request(host, headers = {})
    list = Protocol::HTTP::Headers.new
    headers.each { |key, value| list.add(key, value) }
    Protocol::HTTP::Request.new("http", host, "GET", "/", nil, list)
  end

  def health(response) = response.headers[Portless::Constants::HEALTH_HEADER].to_a.first

  def closed_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end
end
