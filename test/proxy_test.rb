# frozen_string_literal: true

require_relative "test_helper"
require "socket"
require "net/http"
require "openssl"
require "json"

# Ported from upstream proxy.test.ts / proxy-upstream.test.ts. Each test boots
# a real Proxy in a forked child on a free high port (no sudo) and talks to it
# over sockets; backends are tiny in-process TCP servers.
class ProxyTest < Minitest::Test
  Route = Portless::RouteStore::Route

  def setup
    @children = []
    @servers = []
    @dir = Dir.mktmpdir("portless-proxy-test-")
  end

  def teardown
    @children.each do |pid|
      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue StandardError
      nil
    end
    @servers.each { |s| s.close rescue nil }
    FileUtils.rm_rf(@dir)
  end

  # --- harness -------------------------------------------------------------

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def route(hostname, port, pid: Process.pid, **extra)
    Route.new(hostname: hostname, port: port, pid: pid, extra: {}, **extra)
  end

  def tls_options(tlds = [ "localhost" ])
    certs = Portless::Certs.ensure_certs(@dir)
    cert = File.read(certs[:cert_path])
    key = File.read(certs[:key_path])
    ca = File.read(certs[:ca_path])
    { cert: cert, key: key, ca: ca, sni_callback: Portless::Certs.create_sni_callback(@dir, cert, key, tlds, ca) }
  end

  def start_proxy(routes, tls: nil, **options)
    port = free_port
    tls = tls_options(options.fetch(:tlds, [ "localhost" ])) if tls == true
    reader, writer = IO.pipe
    errors_r, errors_w = IO.pipe
    pid = fork do
      reader.close
      errors_r.close
      proxy = Portless::Proxy.new(port: port, routes: -> { routes }, tls: tls, redirect_http: false,
                                  on_error: ->(m) { errors_w.puts(m) },
                                  on_listening: ->(_) { writer.write("."); writer.close }, **options)
      proxy.run
    rescue StandardError => e
      warn e.full_message
      exit!(1)
    end
    writer.close
    errors_w.close
    @children << pid
    reader.read(1) or flunk("proxy did not start")
    @errors = errors_r
    port
  end

  # A backend that answers every request with the raw request it received.
  def echo_backend(host = "127.0.0.1", &responder)
    server = TCPServer.new(host, 0)
    @servers << server
    Thread.new do
      loop do
        client = server.accept
        Thread.new(client) do |c|
          head = +""
          head << c.readpartial(4096) until head.include?("\r\n\r\n")
          if (length = head[/^content-length:\s*(\d+)/i, 1]&.to_i) && length.positive?
            head << c.read(length - head.split("\r\n\r\n", 2)[1].to_s.bytesize)
          end
          if responder
            responder.call(c, head)
          else
            c.write("HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: #{head.bytesize}\r\n\r\n#{head}")
          end
          c.close
        rescue StandardError
          c.close rescue nil
        end
      end
    rescue IOError
      nil
    end
    server.addr[1]
  end

  def http(port, host, path = "/", headers: {}, method: "GET", tls: false, body: nil)
    conn = Net::HTTP.new(host.split(":").first, port)
    conn.ipaddr = "127.0.0.1"
    if tls
      conn.use_ssl = true
      conn.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end
    conn.open_timeout = conn.read_timeout = 5
    request = Net::HTTPGenericRequest.new(method, !body.nil?, method != "HEAD", path)
    request["host"] = host
    headers.each { |k, v| request[k] = v }
    request.body = body if body
    conn.start { |c| c.request(request) }
  end

  def raw(port, data)
    s = TCPSocket.new("127.0.0.1", port, connect_timeout: 2)
    s.write(data)
    s.close_write
    s.read
  ensure
    s&.close
  end

  # --- findRoute (pure) -----------------------------------------------------

  def test_find_route_prefers_exact_then_tailscale_then_longest_parent
    routes = [ route("app.localhost", 1), route("nested.app.localhost", 2),
               route("ts.localhost", 3, tailscale_url: "https://dev.tail.ts.net"),
               route("ts2.localhost", 4, tailscale_url: "https://dev.tail.ts.net:8443") ]
    find = Portless::Proxy.method(:find_route)
    assert_equal 1, find.call(routes, "APP.localhost:1355").port
    assert_nil find.call(routes, "x.nested.app.localhost")
    assert_equal 2, find.call(routes, "x.nested.app.localhost", false).port
    assert_equal 2, find.call(routes.reverse, "x.nested.app.localhost", false).port
    assert_equal 3, find.call(routes, "DEV.tail.ts.net:443").port
    assert_equal 4, find.call(routes, "dev.tail.ts.net:8443").port
    assert_equal 3, find.call(routes, "dev.tail.ts.net:9999").port
    assert_nil find.call(routes, "unrelated.ts.net")
  end

  def test_loopback_helpers
    assert Portless::Proxy.loopback_peer?("::ffff:127.0.0.1")
    assert Portless::Proxy.loopback_peer?("::1")
    refute Portless::Proxy.loopback_peer?("192.168.1.2")
    refute Portless::Proxy.loopback_peer?(nil)
    assert Portless::Proxy.loopback_authority?("127.0.0.1:1355")
    assert Portless::Proxy.loopback_authority?("[::1]")
    refute Portless::Proxy.loopback_authority?("127.0.0.1:0")
    refute Portless::Proxy.loopback_authority?("127.0.0.1.nip.io")
  end

  # --- routing ----------------------------------------------------------------

  def test_proxies_to_the_matching_route_with_forwarded_headers
    backend = echo_backend
    port = start_proxy([ route("app.localhost", backend) ])
    res = http(port, "app.localhost:#{port}", "/hello?x=1", headers: { "connection" => "keep-alive", "x-forwarded-prefix" => "/p" })
    assert_equal "200", res.code
    assert_equal "1", res["x-portless"]
    body = res.body.downcase
    assert_includes body, "get /hello?x=1 http/1.1"
    assert_includes body, "host: app.localhost:#{port}"
    assert_includes body, "x-forwarded-for: 127.0.0.1"
    assert_includes body, "x-forwarded-proto: http"
    assert_includes body, "x-forwarded-host: app.localhost:#{port}"
    assert_includes body, "x-forwarded-port: #{port}"
    assert_includes body, "x-forwarded-prefix: /p"
    assert_includes body, "x-portless-hops: 1"
    refute_match(/^connection: keep-alive/, body)
  end

  def test_incoming_forwarded_headers_pass_through
    backend = echo_backend
    port = start_proxy([ route("app.localhost", backend) ])
    body = http(port, "app.localhost", headers: { "x-forwarded-for" => "10.0.0.1", "x-forwarded-proto" => "https",
                                                  "x-forwarded-host" => "public.example", "x-forwarded-port" => "8443" }).body
    assert_includes body, "x-forwarded-for: 10.0.0.1, 127.0.0.1"
    assert_includes body, "x-forwarded-proto: https"
    assert_includes body, "x-forwarded-host: public.example"
    assert_includes body, "x-forwarded-port: 8443"
  end

  def test_proxies_to_an_ipv6_only_backend
    backend = echo_backend("::1")
    port = start_proxy([ route("app.localhost", backend) ])
    assert_equal "200", http(port, "app.localhost").code
  rescue Errno::EADDRNOTAVAIL
    skip "no IPv6 loopback"
  end

  def test_strict_by_default_and_wildcard_picks_the_most_specific_parent
    a = echo_backend { |c, _| c.write("HTTP/1.1 200 OK\r\ncontent-length: 1\r\n\r\na") }
    b = echo_backend { |c, _| c.write("HTTP/1.1 200 OK\r\ncontent-length: 1\r\n\r\nb") }
    routes = [ route("app.localhost", a), route("nested.app.localhost", b) ]
    strict = start_proxy(routes)
    assert_equal "404", http(strict, "x.app.localhost").code
    wild = start_proxy(routes, strict: false)
    assert_equal "a", http(wild, "x.app.localhost").body
    assert_equal "b", http(wild, "x.nested.app.localhost").body
    assert_equal "a", http(wild, "app.localhost").body
  end

  def test_unknown_name_is_404_json_or_html_with_vary
    port = start_proxy([ route("app.localhost", 4321, registered_at: (Time.now.to_f * 1000).to_i - 7_200_000),
                         route("alias.localhost", 4322, pid: 0) ])
    res = http(port, "nope.localhost")
    assert_equal "404", res.code
    assert_equal "Accept", res["vary"]
    assert_equal "1", res["x-portless"]
    assert_equal({ "error" => "not_found", "upstream" => "nope.localhost", "message" => "No app registered for nope.localhost" },
                 JSON.parse(res.body))

    html = http(port, "nope.localhost:#{port}", headers: { "accept" => "text/html" })
    assert_equal "text/html", html["content-type"]
    assert_includes html.body, "<title>404 - Not Found</title>"
    assert_includes html.body, %(href="http://app.localhost:#{port}")
    assert_includes html.body, %(<span class="uptime">up 2h</span>)
    assert_includes html.body, %(<span class="uptime">alias</span>)
    assert_includes html.body, "rb-portless nope your-command"
    refute_includes html.body, "Filter apps"
  end

  def test_filter_controls_appear_above_five_routes
    port = start_proxy(6.times.map { |i| route("app#{i}.localhost", 4000 + i) })
    body = http(port, "nope.localhost", headers: { "accept" => "text/html" }).body
    assert_includes body, Portless::Pages::FILTER_CONTROLS
    assert_includes body, Portless::Pages::FILTER_NO_MATCH
  end

  def test_public_host_without_route_is_421_and_ip_hosts_stay_404
    port = start_proxy([], tlds: [ "localhost", "test" ])
    res = http(port, "evil.com")
    assert_equal "421", res.code
    assert_equal "misdirected_request", JSON.parse(res.body)["error"]
    html = http(port, "evil.com", headers: { "accept" => "text/html" })
    assert_includes html.body, "DNS sent evil.com to this computer. This is not the real site."
    assert_equal "404", http(port, "x.test").code
    assert_equal "404", http(port, "localhost").code
    assert_equal "404", http(port, "127.0.0.1:#{port}").code
  end

  def test_longest_overlapping_tld_in_suggestion_and_escaping
    port = start_proxy([ route("<b>x</b>.localhost", 1) ], tlds: [ "test", "dev.test" ])
    body = http(port, "api.dev.test", headers: { "accept" => "text/html" }).body
    assert_includes body, "rb-portless api your-command"
    assert_includes body, "&lt;b&gt;x&lt;/b&gt;.localhost"
    refute_includes body, "<b>x</b>"
  end

  def test_missing_host_is_400
    port = start_proxy([])
    response = raw(port, "GET / HTTP/1.0\r\n\r\n")
    assert_match(/\AHTTP\/1\.[01] 400/, response)
    assert_includes response, "Missing Host header"
  end

  def test_http11_without_host_is_a_bare_400_like_node
    port = start_proxy([])
    response = raw(port, "GET / HTTP/1.1\r\nConnection: close\r\n\r\n")
    assert_match(/\AHTTP\/1\.1 400/, response)
    refute_includes response.downcase, "x-portless"
    refute_includes response, "Missing Host header"
  end

  def test_loop_detection_returns_508
    port = start_proxy([ route("app.localhost", 1) ])
    res = http(port, "app.localhost", headers: { "x-portless-hops" => "5" })
    assert_equal "508", res.code
    assert_equal "loop_detected", JSON.parse(res.body)["error"]
    html = http(port, "app.localhost", headers: { "x-portless-hops" => "7", "accept" => "text/html" }).body
    assert_includes html, "changeOrigin: true"
    assert_includes html, "&lt;backend&gt;.localhost:&lt;port&gt;"
    assert_match(/Loop detected for app\.localhost/, @errors.gets)
  end

  def test_dead_backend_is_502_with_a_reason
    port = start_proxy([ route("app.localhost", free_port) ])
    res = http(port, "app.localhost")
    assert_equal "502", res.code
    assert_equal "1", res["x-portless"]
    assert_equal({ "error" => "bad_gateway", "upstream" => "app.localhost",
                   "message" => "The target app is not responding. It may have crashed." }, JSON.parse(res.body))
  end

  def test_upstream_json_errors_pass_through_unchanged
    backend = echo_backend { |c, _| c.write(%(HTTP/1.1 503 Service Unavailable\r\ncontent-type: application/json\r\ncontent-length: 11\r\n\r\n{"down":1}\n)) }
    port = start_proxy([ route("app.localhost", backend) ])
    res = http(port, "app.localhost")
    assert_equal "503", res.code
    assert_equal %({"down":1}\n), res.body
  end

  def test_post_body_is_forwarded
    backend = echo_backend
    port = start_proxy([ route("app.localhost", backend) ])
    body = http(port, "app.localhost", "/u", method: "POST", body: "hello=world").body
    assert_includes body, "hello=world"
  end

  def test_upstream_host_override_and_location_rewrite
    backend = echo_backend do |c, head|
      if head.start_with?("GET /redirect")
        c.write("HTTP/1.1 302 Found\r\nlocation: http://api.internal:9999/next?x=1\r\ncontent-length: 0\r\n\r\n")
      elsif head.start_with?("GET /foreign")
        c.write("HTTP/1.1 302 Found\r\nlocation: http://other.example/next\r\ncontent-length: 0\r\n\r\n")
      else
        c.write("HTTP/1.1 200 OK\r\ncontent-length: #{head.bytesize}\r\n\r\n#{head}")
      end
    end
    port = start_proxy([ route("up.localhost", backend, pid: 0, upstream: { host: "api.internal:9999" }) ])
    assert_includes http(port, "up.localhost:#{port}").body, "host: api.internal:9999"
    assert_equal "http://up.localhost:#{port}/next?x=1", http(port, "up.localhost:#{port}", "/redirect")["location"]
    assert_equal "http://other.example/next", http(port, "up.localhost:#{port}", "/foreign")["location"]
  end

  def test_upstream_tls_backend
    certs = Portless::Certs.ensure_certs(@dir)
    server = TCPServer.new("127.0.0.1", 0)
    @servers << server
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.cert = OpenSSL::X509::Certificate.new(File.read(certs[:cert_path]))
    ctx.key = OpenSSL::PKey.read(File.read(certs[:key_path]))
    ssl_server = OpenSSL::SSL::SSLServer.new(server, ctx)
    sni = nil
    ctx.servername_cb = proc { |(_, name)| sni = name; nil }
    Thread.new do
      c = ssl_server.accept
      head = +""
      head << c.readpartial(4096) until head.include?("\r\n\r\n")
      c.write("HTTP/1.1 200 OK\r\ncontent-length: 6\r\n\r\nsecure")
      c.close
    rescue StandardError
      nil
    end
    port = start_proxy([ route("tls.localhost", server.addr[1], pid: 0, upstream: { tls: true, host: "api.internal" }) ])
    assert_equal "secure", http(port, "tls.localhost").body
    assert_equal "api.internal", sni
  end

  def test_backend_answering_plain_http_to_a_tls_upstream_is_a_tls_502
    server = TCPServer.new("127.0.0.1", 0)
    @servers << server
    Thread.new do
      loop do
        c = server.accept
        c.readpartial(4096)
        c.write("HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\n\r\n")
        c.close
      end
    rescue IOError
      nil
    end
    backend = server.addr[1]
    port = start_proxy([ route("tls.localhost", backend, pid: 0, upstream: { tls: true }) ])
    res = http(port, "tls.localhost")
    assert_equal "502", res.code
    assert_equal Portless::Proxy::TLS_502_DETAIL, JSON.parse(res.body)["message"]
  end

  # --- TLS ------------------------------------------------------------------------

  def test_tls_serves_h1_and_plain_http_on_the_tls_port_redirects
    backend = echo_backend
    port = start_proxy([ route("app.localhost", backend) ], tls: true)
    res = http(port, "app.localhost:#{port}", tls: true)
    assert_equal "200", res.code
    assert_includes res.body, "x-forwarded-proto: https"

    plain = http(port, "app.localhost:#{port}", "/a?b=1")
    assert_equal "302", plain.code
    assert_equal "https://app.localhost:#{port}/a?b=1", plain["location"]
    assert_equal "1", plain["x-portless"]
  end

  def test_tls_negotiates_h2
    port = start_proxy([], tls: true)
    socket = Socket.tcp("127.0.0.1", port)
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
    ctx.alpn_protocols = %w[h2 http/1.1]
    ssl = OpenSSL::SSL::SSLSocket.new(socket, ctx)
    ssl.hostname = "app.localhost"
    ssl.connect
    assert_equal "h2", ssl.alpn_protocol
    leaf = ssl.peer_cert
    assert_includes leaf.extensions.find { |e| e.oid == "subjectAltName" }.value, "DNS:app.localhost"
  ensure
    ssl&.close
  end

  def test_tls_refuses_sni_outside_the_tlds
    port = start_proxy([], tls: true)
    assert_raises(OpenSSL::SSL::SSLError, Errno::ECONNRESET, EOFError) { http(port, "evil.com", tls: true) }
    refute File.exist?(File.join(@dir, "host-certs", "evil_com.pem"))
  end

  # --- WebSocket ----------------------------------------------------------------

  def test_websocket_upgrade_is_relayed
    backend = echo_backend do |c, head|
      key = head[/^sec-websocket-key:\s*(\S+)/i, 1]
      accept = [ Digest::SHA1.digest(key + Portless::Proxy::WS_GUID) ].pack("m0")
      c.write("HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: #{accept}\r\n\r\n")
      c.write(c.readpartial(1024)) # echo one chunk
    end
    port = start_proxy([ route("app.localhost", backend) ])
    Socket.tcp("127.0.0.1", port) do |s|
      s.write("GET /cable HTTP/1.1\r\nHost: app.localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
              "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
      head = +""
      head << s.readpartial(1024) until head.include?("\r\n\r\n")
      assert_match(/\AHTTP\/1\.1 101/, head)
      assert_includes head.downcase, "sec-websocket-accept: s3pplmbitxaq9kygzzhzrbk+xoo="
      assert_equal 1, head.downcase.scan("connection:").size
      s.write("ping")
      assert_equal "ping", s.readpartial(1024)
    end
  end

  def ws_backend
    echo_backend do |c, head|
      key = head[/^sec-websocket-key:\s*(\S+)/i, 1]
      accept = [ Digest::SHA1.digest(key + Portless::Proxy::WS_GUID) ].pack("m0")
      c.write("HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: #{accept}\r\n\r\n")
      c.write(c.readpartial(1024))
    end
  end

  # RFC 8441: an h2 extended CONNECT is bridged to an h1 Upgrade; success is :status 200.
  def test_h2_extended_connect_is_bridged
    require "async/http/client"
    port = start_proxy([ route("app.localhost", ws_backend) ], tls: true)
    Sync do
      endpoint = Async::HTTP::Endpoint.parse("https://app.localhost:#{port}",
                                             ssl_context: OpenSSL::SSL::SSLContext.new.tap { |c| c.verify_mode = OpenSSL::SSL::VERIFY_NONE; c.alpn_protocols = %w[h2] },
                                             protocol: Async::HTTP::Protocol::HTTP2)
      endpoint = endpoint.with(address: Addrinfo.tcp("127.0.0.1", port)) if endpoint.respond_to?(:with)
      client = Async::HTTP::Client.new(endpoint)
      body = Protocol::HTTP::Body::Writable.new
      request = Protocol::HTTP::Request.new("https", "app.localhost:#{port}", "CONNECT", "/cable", nil,
                                            Protocol::HTTP::Headers.new, body, "websocket")
      response = client.call(request)
      assert_equal 200, response.status
      assert_equal "1", response.headers["x-portless"].to_s
      assert_nil response.headers["sec-websocket-accept"]
      body.write("ping")
      assert_equal "ping", response.body.read
      body.close_write
      response.close
      client.close
    end
  end

  def test_websocket_to_a_dead_backend_is_a_502
    port = start_proxy([ route("app.localhost", free_port) ])
    response = raw(port, "GET / HTTP/1.1\r\nHost: app.localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                         "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n")
    assert_match(/\AHTTP\/1\.1 502/, response)
    assert_includes response, "Bad Gateway: the target app is not responding"
  end

  # --- hosts sync -----------------------------------------------------------------

  TOKEN = "a" * 64

  def test_hosts_sync_endpoint_requires_the_token_and_a_loopback_authority
    calls = IO.pipe
    port = start_proxy([], hosts_sync_token: TOKEN, on_hosts_sync_request: -> { calls[1].write("."); "acted" })
    path = Portless::Proxy::HOSTS_SYNC_PATH
    header = Portless::HostsSyncAuth::HOSTS_SYNC_AUTH_HEADER
    assert_equal "401", http(port, "127.0.0.1:#{port}", path, method: "POST").code
    assert_equal "401", http(port, "127.0.0.1:#{port}", path, method: "POST", headers: { header => "b" * 64 }).code
    assert_equal "401", http(port, "127.0.0.1:#{port}", path, method: "POST",
                                                            headers: { header => TOKEN, "origin" => "http://evil" }).code
    assert_equal "204", http(port, "127.0.0.1:#{port}", path, method: "POST", headers: { header => TOKEN }).code
    assert_equal ".", calls[0].read_nonblock(1)
    # A named host is a normal route lookup, never the sync endpoint.
    assert_equal "404", http(port, "app.localhost", path, method: "POST", headers: { header => TOKEN }).code
  end

  def test_hosts_sync_disabled_and_absent_producer
    disabled = start_proxy([], hosts_sync_token: TOKEN, on_hosts_sync_request: -> { "disabled" })
    header = { Portless::HostsSyncAuth::HOSTS_SYNC_AUTH_HEADER => TOKEN }
    assert_equal "409", http(disabled, "127.0.0.1", Portless::Proxy::HOSTS_SYNC_PATH, method: "POST", headers: header).code
    absent = start_proxy([], hosts_sync_token: TOKEN)
    assert_equal "404", http(absent, "[::1]", Portless::Proxy::HOSTS_SYNC_PATH, method: "POST", headers: header).code
  end

  def test_head_challenge_gets_a_proof
    port = start_proxy([], hosts_sync_token: TOKEN)
    challenge = "c" * 64
    res = http(port, "127.0.0.1:#{port}", method: "HEAD",
                                          headers: { Portless::HostsSyncAuth::HOSTS_SYNC_AUTH_CHALLENGE_HEADER => challenge })
    assert_equal Portless::HostsSyncAuth.create_proof(TOKEN, challenge), res[Portless::HostsSyncAuth::HOSTS_SYNC_AUTH_PROOF_HEADER]
    assert_equal "no-store", res["cache-control"]
    named = http(port, "app.localhost", method: "HEAD",
                                        headers: { Portless::HostsSyncAuth::HOSTS_SYNC_AUTH_CHALLENGE_HEADER => challenge })
    assert_nil named[Portless::HostsSyncAuth::HOSTS_SYNC_AUTH_PROOF_HEADER]
  end

  # --- listening ------------------------------------------------------------------

  def test_binds_loopback_by_default_and_wildcard_for_lan
    proxy = Portless::Proxy.new(port: 1, routes: -> { [] })
    assert_equal %w[127.0.0.1 ::1], proxy.bind_targets.map { |t| t[:host] }
    lan = Portless::Proxy.new(port: 1, routes: -> { [] }, lan_bind: true)
    assert_equal %w[0.0.0.0 ::], lan.bind_targets.map { |t| t[:host] }
    assert lan.bind_targets.last[:ipv6_only]
  end

  def test_primary_bind_failure_raises_without_noise
    blocker = TCPServer.new("127.0.0.1", 0)
    @servers << blocker
    proxy = Portless::Proxy.new(port: blocker.addr[1], routes: -> { [] })
    assert_raises(Errno::EADDRINUSE) { proxy.run }
  end

  def test_loopback_only_serves_loopback_and_closes_other_peers
    backend = echo_backend
    port = start_proxy([ route("app.localhost", backend) ], lan_bind: true, loopback_only: true)
    assert_equal "200", http(port, "app.localhost").code
    lan_ip = Socket.ip_address_list.find { |a| a.ipv4? && !a.ipv4_loopback? && !a.ipv4_multicast? }&.ip_address
    skip "no non-loopback IPv4 address" unless lan_ip
    response = begin
      s = TCPSocket.new(lan_ip, port, connect_timeout: 2)
      s.write("GET / HTTP/1.1\r\nHost: app.localhost\r\n\r\n")
      s.read
    rescue Errno::ECONNRESET, Errno::EPIPE
      ""
    ensure
      s&.close
    end
    assert_equal "", response.to_s
  end

  def test_state_dir_tls_option_mints_sni_certs_and_stop_is_trap_safe
    certs = Portless::Certs.ensure_certs(@dir)
    tls = { cert: File.read(certs[:cert_path]), key: File.read(certs[:key_path]), ca: File.read(certs[:ca_path]), state_dir: @dir }
    backend = echo_backend
    port = start_proxy([ route("app.localhost", backend) ], tls: tls)
    assert_equal "200", http(port, "app.localhost", tls: true).code
    assert File.exist?(File.join(@dir, "host-certs", "app_localhost.pem"))

    proxy = Portless::Proxy.new(port: free_port, routes: -> { [] }, on_listening: -> { Process.kill("USR2", Process.pid) })
    previous = trap("USR2") { proxy.stop }
    Timeout.timeout(5) { proxy.run }
  ensure
    trap("USR2", previous || "DEFAULT")
  end

  # --- RouteCache -----------------------------------------------------------------

  def test_route_cache_drops_dead_owners_and_keeps_the_last_good_table
    store = Portless::RouteStore.new(@dir)
    child = spawn("sleep 30")
    store.add_route(hostname: "a.localhost", port: 1, pid: child)
    store.add_route(hostname: "b.localhost", port: 2, pid: 0)
    warnings = []
    cache = Portless::Proxy::RouteCache.new(store, on_warning: ->(m) { warnings << m })
    assert_equal %w[a.localhost b.localhost], cache.call.map(&:hostname)
    Process.kill("KILL", child)
    Process.wait(child)
    assert_equal %w[b.localhost], cache.call.map(&:hostname)

    File.write(store.routes_path, "corrupt!")
    assert_equal %w[b.localhost], cache.call.map(&:hostname)
    assert_equal 1, warnings.size
    cache.call
    assert_equal 1, warnings.size
  end
end
