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
    assert_equal "1", health(res)
  end

  def test_exact_and_wildcard_routing_via_route_for
    @store.add(hostname: "demo.localhost", port: 4321, pid: Process.pid)
    assert_equal 4321, @proxy.route_for("demo.localhost").port
    assert_equal 4321, @proxy.route_for("kobe.demo.localhost").port
    assert_nil @proxy.route_for("other.localhost")
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
    assert_equal "1", health(res)
  ensure
    @store.remove("demo.localhost", owner_pid: Process.pid)
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
