# frozen_string_literal: true

require_relative "e2e_helper"

# True end-to-end coverage of the proxy: a real daemon process on a high port,
# a real backend, real TLS handshakes — the paths proxy_test.rb can only unit
# test. Mirrors the upstream portless tests/e2e suite.
class E2EProxyTest < Minitest::Test
  HOST = "e2e-demo.localhost"

  def setup
    E2E.register(HOST)
  end

  def teardown
    E2E.deregister(HOST)
  end

  def test_https_request_is_forwarded_with_x_forwarded_headers
    res = E2E.get(HOST, "/hello?x=1")

    assert_equal "200", res.code
    assert_equal Portless::VERSION, res[Portless::Constants::HEALTH_HEADER]

    echo = JSON.parse(res.body)
    assert_equal "GET", echo["method"]
    assert_equal "/hello?x=1", echo["path"]
    assert_equal "#{HOST}:#{E2E.proxy_port}", echo["headers"]["x-forwarded-host"]
    assert_equal "https", echo["headers"]["x-forwarded-proto"]
    assert_equal E2E.proxy_port.to_s, echo["headers"]["x-forwarded-port"]
    assert_includes [ "127.0.0.1", "::1" ], echo["headers"]["x-forwarded-for"]
    # The backend must still see the public Host, not 127.0.0.1:<port> —
    # that's what Rails host authorization / request.host are built from.
    assert_equal HOST, echo["headers"]["host"].split(":").first
  end

  def test_tls_leaf_verifies_against_the_ca_for_the_exact_host
    ssl = E2E.tls_socket(HOST)
    cert = ssl.peer_cert
    assert OpenSSL::SSL.verify_certificate_identity(cert, HOST),
           "leaf cert #{cert.subject} does not cover #{HOST}"
  ensure
    ssl&.close
  end

  def test_wildcard_subdomain_routes_to_the_same_app_with_a_valid_cert
    res = E2E.get("kobe.#{HOST}", "/tenant")

    assert_equal "200", res.code # VERIFY_PEER: fails unless the SNI leaf covers the subdomain
    echo = JSON.parse(res.body)
    assert_equal "kobe.#{HOST}:#{E2E.proxy_port}", echo["headers"]["x-forwarded-host"]
  end

  def test_unknown_host_gets_a_404_listing_the_active_apps
    res = E2E.get("nobody-home.localhost", "/")
    assert_equal "404", res.code
    assert_equal Portless::VERSION, res[Portless::Constants::HEALTH_HEADER]
    assert_includes res.body, HOST # the running app is listed
    assert_includes res.body, "rb-portless nobody-home" # the command that would fix it
  end

  def test_request_body_is_forwarded
    http = Net::HTTP.new(HOST, E2E.proxy_port)
    http.use_ssl = true
    http.ca_file = Portless::State.ca_cert
    res = http.start { |conn| conn.post("/submit", "payload=42", "content-type" => "application/x-www-form-urlencoded") }

    echo = JSON.parse(res.body)
    assert_equal "POST", echo["method"]
    assert_equal "payload=42", echo["body"]
  end

  def test_dead_backend_is_a_502_not_a_hang
    E2E.register("e2e-dead.localhost", E2E.free_port)
    res = E2E.get("e2e-dead.localhost", "/")
    assert_equal "502", res.code
  ensure
    E2E.deregister("e2e-dead.localhost")
  end

  def test_route_changes_are_picked_up_without_a_proxy_restart
    late = "e2e-late.localhost"
    assert_equal "404", E2E.get(late, "/").code

    E2E.register(late)
    assert_equal "200", E2E.get(late, "/").code
  ensure
    E2E.deregister(late)
  end

  def test_http2_is_negotiated_and_served
    ssl = E2E.tls_socket(HOST) { |ctx| ctx.alpn_protocols = [ "h2" ] }
    assert_equal "h2", ssl.alpn_protocol
  ensure
    ssl&.close
  end

  # Security: without --lan the proxy must NOT be reachable from the network —
  # on 0.0.0.0 every registered dev app is exposed to the whole LAN/VPN.
  def test_proxy_is_not_reachable_on_the_lan_interface_by_default
    ip = Portless::LanIp.detect(nil)
    skip "no LAN IPv4 on this machine" unless ip

    assert_raises(Errno::ECONNREFUSED, Errno::ETIMEDOUT) do
      Socket.tcp(ip, E2E.proxy_port, connect_timeout: 2).close
    end
    refute File.exist?(Portless::State.proxy_lan_file), "no LAN marker without --lan"
  end

  def test_proxy_is_reachable_on_the_ipv6_loopback
    tcp = TCPSocket.new("::1", E2E.proxy_port)
    tcp.close
  end

  def test_http2_request_round_trips_through_the_h1_backend
    require "async"
    require "async/http/client"
    require "async/http/endpoint"

    store = OpenSSL::X509::Store.new
    store.add_file(Portless::State.ca_cert)
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.cert_store = store
    ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
    ctx.alpn_protocols = [ "h2" ]

    body = nil
    version = nil
    health = nil
    Sync do
      # Connect to the loopback explicitly (SNI + :authority still carry the
      # hostname) so the test never depends on OS *.localhost resolution.
      endpoint = Async::HTTP::Endpoint.parse("https://#{HOST}:#{E2E.proxy_port}",
                                             ssl_context: ctx, hostname: "127.0.0.1")
      client = Async::HTTP::Client.new(endpoint)
      response = client.get("/over-h2")
      version = response.version
      health = response.headers[Portless::Constants::HEALTH_HEADER].to_a.first
      body = response.read
      client.close
    end

    assert_equal "HTTP/2", version
    # Regression: a backend `Connection: close` relayed into the h2 stream used
    # to abort the header block — bare 200, no headers, no body.
    assert_equal Portless::VERSION, health
    echo = JSON.parse(body)
    assert_equal "/over-h2", echo["path"]
    assert_equal "https", echo["headers"]["x-forwarded-proto"]
  end

  # The full WebSocket relay: TLS client → proxy → h1 backend, 101 handshake
  # (with the backend's Sec-WebSocket-Accept relayed back) then echo frames
  # flowing both ways over the upgraded tunnel.
  def test_websocket_upgrade_and_frames_relay_end_to_end
    key = Base64.strict_encode64(Random.bytes(16))
    ssl = E2E.tls_socket(HOST)
    ssl.write("GET /cable HTTP/1.1\r\nHost: #{HOST}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
              "Sec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n")

    status_line = ssl.gets
    headers = {}
    while (line = ssl.gets) && line != "\r\n"
      k, v = line.split(":", 2)
      headers[k.strip.downcase] = v.to_s.strip
    end

    assert_match(/101/, status_line.to_s, "expected 101 Switching Protocols, got #{status_line.inspect}")
    expected_accept = Base64.strict_encode64(Digest::SHA1.digest(key + E2E::WS_GUID))
    assert_equal expected_accept, headers["sec-websocket-accept"]

    # One masked text frame in, the echo back out through the tunnel.
    payload = "ping-through-portless"
    mask = Random.bytes(4).bytes
    masked = payload.bytes.each_with_index.map { |b, i| b ^ mask[i % 4] }
    ssl.write(([ 0x81, 0x80 | payload.bytesize ] + mask + masked).pack("C*"))

    echoed = Timeout.timeout(5) { E2E.read_ws_frame(ssl) }
    assert_equal payload, echoed
  ensure
    ssl&.close
  end
end
