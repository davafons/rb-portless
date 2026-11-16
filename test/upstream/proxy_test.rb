# frozen_string_literal: true

require_relative "../test_helper"
require_relative "support/proxy"
require "digest"

# Mirror of packages/portless/src/proxy.test.ts
#
# `server = start_proxy(routes, **options)` is createProxyServer(...) +
# listen(0, "127.0.0.1"): it returns the listen port, and `request(server, ...)`
# is the upstream request() helper (Accept: text/html unless given).
describe "createProxyServer" do
  include ProxyTestSupport

  describe "request routing" do
    it "returns 404 when Host header has no matching route" do
      routes = []
      server = start_proxy(routes)

      res = request(server, host: "nonexistent.localhost")
      assert_equal 404, res.status
      assert_includes res.body, "Not Found"
    end

    it "returns a 421 HTML page with a DNS note for a public host that has no route" do
      routes = make_routes(1)
      server = start_proxy(routes)

      res = request(server, host: "<script>alert(1)</script>.com")
      assert_equal 421, res.status
      assert_equal "text/html", res["content-type"]
      assert_equal "Accept", res["vary"]
      assert_includes res.body, "Misdirected Request"
      assert_includes res.body, "DNS sent &lt;script&gt;alert(1)&lt;/script&gt;.com to this computer"
      refute_includes res.body, "<script>alert(1)</script>"
      refute_includes res.body, "app0.localhost"
      refute_includes res.body, "Active apps"
    end

    it "returns a 421 JSON error for a public host that has no route" do
      server = start_proxy([])

      res = request(server, host: "example.com", accept: "application/json")
      assert_equal 421, res.status
      assert_equal "application/json; charset=utf-8", res["content-type"]
      assert_equal({ "error" => "misdirected_request", "upstream" => "example.com",
                     "message" => "DNS sent example.com to this computer. This is not the real site." },
                   JSON.parse(res.body))
    end

    it "keeps the 404 page for unknown names inside every configured TLD and for IP hosts" do
      server = start_proxy([], tld: "test", tlds: %w[test localhost])

      [ "unknown.localhost", "unknown.localhost.", "unknown.test", "localhost", "MyApp.Localhost",
        "127.0.0.1:1355" ].each do |host|
        res = request(server, host: host)
        assert_equal 404, res.status, host
      end
    end

    it "returns 404 with HTML page for unknown host" do
      routes = []
      server = start_proxy(routes)

      res = request(server, host: "unknown.localhost")
      assert_equal 404, res.status
      assert_equal "text/html", res["content-type"]
      assert_includes res.body, "Not Found"
      assert_includes res.body, "unknown.localhost"
      assert_includes res.body, "No apps running."
    end

    it "shows active routes in 404 page when routes exist" do
      routes = [ route("myapp.localhost", 4001), route("api.localhost", 4002) ]
      server = start_proxy(routes)

      res = request(server, host: "other.localhost")
      assert_equal 404, res.status
      assert_includes res.body, "Active apps"
      assert_includes res.body, "myapp.localhost"
      assert_includes res.body, "api.localhost"
    end

    it "shows uptime for a route registered 2 hours ago in the 404 page" do
      routes = [ route("api.localhost", 4001, registered_at: now_ms - (2 * 3600 * 1000)) ]
      server = start_proxy(routes)

      res = request(server, host: "other.localhost")
      assert_equal 404, res.status
      assert_includes res.body, "up 2h"
    end

    it "shows an alias label instead of uptime for pid 0 routes in the 404 page" do
      routes = [ route("db.localhost", 4001, pid: 0, registered_at: now_ms - (2 * 3600 * 1000)) ]
      server = start_proxy(routes)

      res = request(server, host: "other.localhost")
      assert_includes res.body, 'class="uptime">alias<'
      refute_includes res.body, "up 2h"
    end

    it "renders routes without a valid registeredAt with no uptime in the 404 page" do
      routes = [ route("old.localhost", 4001), route("bad.localhost", 4002, registered_at: "yesterday") ]
      server = start_proxy(routes)

      res = request(server, host: "other.localhost")
      assert_equal 404, res.status
      assert_includes res.body, "old.localhost"
      assert_includes res.body, "bad.localhost"
      assert_includes res.body, "127.0.0.1:4001"
      assert_includes res.body, "127.0.0.1:4002"
      refute_includes res.body, 'class="uptime"'
    end

    it "includes correct port in 404 page links" do
      routes = [ route("myapp.localhost", 4001) ]
      server = start_proxy(routes, port: 8080)

      res = request(server, host: "other.localhost")
      assert_equal 404, res.status
      assert_includes res.body, 'href="http://myapp.localhost:8080"'
    end

    it "omits port 80 in 404 page links" do
      routes = [ route("myapp.localhost", 4001) ]
      server = start_proxy(routes, port: 80)

      res = request(server, host: "other.localhost")
      assert_equal 404, res.status
      assert_includes res.body, 'href="http://myapp.localhost"'
      refute_includes res.body, ":80"
    end

    it "renders the filter controls and script only above 5 routes" do
      five = start_proxy(make_routes(5))
      five_res = request(five, host: "other.localhost")
      refute_includes five_res.body, 'type="search"'
      refute_includes five_res.body, "<script>"

      six = start_proxy(make_routes(6))
      six_res = request(six, host: "other.localhost")
      assert_includes six_res.body, 'type="search"'
      assert_includes six_res.body, "<script>"
    end

    it "renders the filter controls and no-match message hidden for a long list" do
      server = start_proxy(make_routes(20))

      res = request(server, host: "other.localhost")
      assert_match(/<div class="filter" hidden>/, res.body)
      assert_match(/<p class="empty" role="status" hidden>/, res.body)
      input = res.body[/<input[^>]*>/]
      assert_includes input, 'type="search"'
      assert_includes input, 'autocomplete="off"'
      assert_includes input, "aria-label="
      refute_includes res.body, "<form"
    end

    it "renders a newest-first toggle in the hidden controls row, rows in registration order" do
      server = start_proxy(make_routes(20))

      res = request(server, host: "other.localhost")
      controls = res.body[%r{<div class="filter" hidden>.*?</div>}]
      assert_includes controls, '<button type="button" aria-pressed="false">Newest first</button>'
      names = res.body.scan(%r{app(\d+)\.localhost</span>}).map { |m| m[0].to_i }
      assert_equal (0...20).to_a, names
    end

    it "proxies request to matching route" do
      backend = text_backend("hello from backend")

      routes = [ route("myapp.localhost", backend.port) ]
      server = start_proxy(routes)

      res = request(server, host: "myapp.localhost")
      assert_equal 200, res.status
      assert_equal "hello from backend", res.body
    end

    it "proxies to a backend listening on IPv6 loopback only (issue #320)" do
      begin
        backend = text_backend("hello from ipv6 backend", "::1")
      rescue SystemCallError
        skip "no IPv6 loopback"
      end

      routes = [ route("myapp.localhost", backend.port) ]
      server = start_proxy(routes)

      res = request(server, host: "myapp.localhost")
      assert_equal 200, res.status
      assert_equal "hello from ipv6 backend", res.body
    end

    it "routes a wildcard subdomain to the most specific parent in any order (issue #380)" do
      backends = %w[parent child].map { |name| listen_http { [ 200, {}, name ] }.port }
      parent = route("acme.localhost", backends[0])
      child = route("api.acme.localhost", backends[1])

      [ [ parent, child ], [ child, parent ] ].each do |routes|
        server = start_proxy(routes, strict: false)
        assert_equal "child", request(server, host: "admin.api.acme.localhost").body
        assert_equal "parent", request(server, host: "tenant.acme.localhost").body
        assert_equal "child", request(server, host: "api.acme.localhost").body
      end
    end

    it "does not forward client hop-by-hop headers to the backend (issue #434)" do
      received = {}
      backend = listen_http do |req|
        received = req.headers
        [ 200, {}, "ok" ]
      end

      routes = [ route("myapp.localhost", backend.port) ]
      server = start_proxy(routes)

      res = request(server, host: "myapp.localhost",
                            headers: { "connection" => "close", "keep-alive" => "timeout=5",
                                       "proxy-connection" => "keep-alive", "upgrade" => "h2c" })
      assert_equal 200, res.status
      # the pooled upstream agent sets its own keep-alive, a forwarded client
      # value would show up as close
      assert_equal "keep-alive", received["connection"]
      assert_nil received["keep-alive"]
      assert_nil received["proxy-connection"]
      assert_nil received["upgrade"]
    end

    it "survives a backend resetting a kept-alive connection (issue #434)" do
      sockets = []
      backend = listen_http do |req|
        sockets << req.socket
        [ 200, {}, "ok" ]
      end

      routes = [ route("myapp.localhost", backend.port) ]
      server = start_proxy(routes)

      first = request(server, host: "myapp.localhost", headers: { "connection" => "keep-alive" })
      assert_equal 200, first.status
      sockets.each { |socket| reset_and_destroy(socket) }
      sleep 0.1

      second = request(server, host: "myapp.localhost")
      assert_equal 200, second.status
      assert @running.alive?
    end

    it "forwards a chunked DELETE body intact" do
      body = +""
      backend = listen_http do |req|
        body << req.body
        [ 200, {}, "ok" ]
      end

      routes = [ route("myapp.localhost", backend.port) ]
      server = start_proxy(routes)

      socket = TCPSocket.new("127.0.0.1", server)
      socket.write("DELETE / HTTP/1.1\r\nhost: myapp.localhost\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n")
      socket.write("9\r\npart-one,\r\n")
      socket.write("8\r\npart-two\r\n0\r\n\r\n")
      status, = parse_head(read_all(socket))
      socket.close
      assert_equal 200, status
      assert_equal "part-one,part-two", body
    end

    it "routes wildcard subdomain to matching parent route when strict is false" do
      backend = text_backend("wildcard hit")

      routes = [ route("myapp.localhost", backend.port) ]
      server = start_proxy(routes, strict: false)

      res = request(server, host: "tenant.myapp.localhost")
      assert_equal 200, res.status
      assert_equal "wildcard hit", res.body
    end

    it "prefers exact match over wildcard subdomain match" do
      exact_backend = text_backend("exact")
      wildcard_backend = text_backend("wildcard")

      routes = [ route("tenant.myapp.localhost", exact_backend.port), route("myapp.localhost", wildcard_backend.port) ]
      server = start_proxy(routes, strict: false)

      res = request(server, host: "tenant.myapp.localhost")
      assert_equal 200, res.status
      assert_equal "exact", res.body
    end

    it "returns 404 when subdomain does not match any route" do
      routes = [ route("myapp.localhost", 4001) ]
      server = start_proxy(routes)

      res = request(server, host: "other.localhost")
      assert_equal 404, res.status
    end

    it "strips port from Host header for matching" do
      backend = text_backend("matched")

      routes = [ route("myapp.localhost", backend.port) ]
      server = start_proxy(routes)

      res = request(server, host: "myapp.localhost:80")
      assert_equal 200, res.status
      assert_equal "matched", res.body
    end

    it "routes requests addressed to a route's tailscale hostname (issue #297)" do
      backend = text_backend("funnel hit")

      routes = [ route("myapp.localhost", backend.port, tailscale_url: "https://my-device.tail1234.ts.net") ]
      server = start_proxy(routes)

      res = request(server, host: "my-device.tail1234.ts.net")
      assert_equal 200, res.status
      assert_equal "funnel hit", res.body
    end

    it "routes tailscale hostname even when the local hostname is worktree-prefixed (issue #343)" do
      backend = text_backend("worktree funnel hit")

      routes = [ route("myfeature.myapp.localhost", backend.port, tailscale_url: "https://my-device.tail1234.ts.net") ]
      server = start_proxy(routes, strict: true)

      res = request(server, host: "my-device.tail1234.ts.net")
      assert_equal 200, res.status
      assert_equal "worktree funnel hit", res.body
    end

    it "does not match tailscale hostname against unrelated hosts" do
      routes = [ route("myapp.localhost", 4001, tailscale_url: "https://my-device.tail1234.ts.net") ]
      server = start_proxy(routes)

      res = request(server, host: "other-device.tail1234.ts.net")
      assert_equal 421, res.status
      refute_includes res.body, "my-device"
    end

    it "matches the tailscale route registered for the request port" do
      backend_a = text_backend("app on :443")
      backend_b = text_backend("app on :8443")

      routes = [
        route("app-a.localhost", backend_a.port, tailscale_url: "https://my-device.tail1234.ts.net"),
        route("app-b.localhost", backend_b.port, tailscale_url: "https://my-device.tail1234.ts.net:8443")
      ]
      server = start_proxy(routes)

      res_b = request(server, host: "my-device.tail1234.ts.net:8443")
      assert_equal 200, res_b.status
      assert_equal "app on :8443", res_b.body

      res_a = request(server, host: "my-device.tail1234.ts.net")
      assert_equal 200, res_a.status
      assert_equal "app on :443", res_a.body
    end

    it "matches a tailscale route by hostname when the request port differs" do
      backend = text_backend("only app")

      routes = [ route("myapp.localhost", backend.port, tailscale_url: "https://my-device.tail1234.ts.net:8443") ]
      server = start_proxy(routes)

      res = request(server, host: "my-device.tail1234.ts.net")
      assert_equal 200, res.status
      assert_equal "only app", res.body
    end

    it "routes an explicit :443 tailscale Host to the default-port app when another route shares the hostname (review: ctate)" do
      backend_default = text_backend("app on :443")
      backend_alt = text_backend("app on :8443")

      # The alternate-port route is listed first so a port-insensitive fallback
      # would resolve the explicit :443 request to the wrong app.
      routes = [
        route("app-b.localhost", backend_alt.port, tailscale_url: "https://my-device.tail1234.ts.net:8443"),
        route("app-a.localhost", backend_default.port, tailscale_url: "https://my-device.tail1234.ts.net")
      ]
      server = start_proxy(routes)

      res = request(server, host: "my-device.tail1234.ts.net:443")
      assert_equal 200, res.status
      assert_equal "app on :443", res.body
    end

    it "matches a tailscale hostname case-insensitively (review: ctate)" do
      backend = text_backend("mixed case funnel hit")

      routes = [ route("myapp.localhost", backend.port, tailscale_url: "https://my-device.tail1234.ts.net") ]
      server = start_proxy(routes)

      res = request(server, host: "My-Device.Tail1234.TS.net")
      assert_equal 200, res.status
      assert_equal "mixed case funnel hit", res.body
    end

    it "returns 404 for unregistered subdomain prefix by default" do
      backend = text_backend("should not reach")

      routes = [ route("myapp.localhost", backend.port) ]
      server = start_proxy(routes)

      res = request(server, host: "unknown.myapp.localhost")
      assert_equal 404, res.status
      assert_includes res.body, "Not Found"
    end

    it "still routes exact matches by default" do
      backend = text_backend("exact match")

      routes = [ route("myapp.localhost", backend.port) ]
      server = start_proxy(routes)

      res = request(server, host: "myapp.localhost")
      assert_equal 200, res.status
      assert_equal "exact match", res.body
    end

    it "routes registered subdomain prefix but not unregistered ones" do
      parent_backend = text_backend("parent")
      child_backend = text_backend("child")

      routes = [ route("myapp.localhost", parent_backend.port), route("feat.myapp.localhost", child_backend.port) ]
      server = start_proxy(routes)

      # Registered prefix routes to its own backend
      child_res = request(server, host: "feat.myapp.localhost")
      assert_equal 200, child_res.status
      assert_equal "child", child_res.body

      # Unregistered prefix returns 404
      unknown_res = request(server, host: "other.myapp.localhost")
      assert_equal 404, unknown_res.status

      # Parent still works
      parent_res = request(server, host: "myapp.localhost")
      assert_equal 200, parent_res.status
      assert_equal "parent", parent_res.body
    end
  end

  describe "missing Host header" do
    it "returns 400 when Host header is missing" do
      routes = []
      server = start_proxy(routes)

      # Use raw TCP to send HTTP request without a Host header
      response = raw_request(server, "GET / HTTP/1.0\r\n\r\n")

      assert_includes response, "400"
      assert_includes response, "Missing Host header"
    end
  end

  describe "error handling" do
    it "returns 502 when backend is not running" do
      routes = [ route("dead.localhost", 59_999) ]
      server = start_proxy(routes)
      errors = proxy_errors

      res = request(server, host: "dead.localhost")
      assert_equal 502, res.status
      assert_includes res.body, "Bad Gateway"
      assert_operator errors.length, :>, 0
      assert_includes errors[0], "dead.localhost"
      assert_includes errors[0], "ECONNREFUSED"
      assert_includes errors[0], "127.0.0.1:59999"
      assert_includes errors[0], "::1:59999"
    end

    error_scenarios = [
      { name: "404", status: 404, error: "not_found", host: "missing.localhost", routes: [], headers: {},
        message: "No app registered for missing.localhost" },
      { name: "502", status: 502, error: "bad_gateway", host: "dead.localhost", routes: [ [ "dead.localhost", 59_999 ] ],
        headers: {}, message: "The target app is not responding. It may have crashed." },
      { name: "508", status: 508, error: "loop_detected", host: "app.localhost", routes: [ [ "app.localhost", 59_999 ] ],
        headers: { "x-portless-hops" => "5" }, message: "Request passed through portless 5 times" }
    ]

    it "returns a compact JSON $name error to JSON clients" do
      error_scenarios.each do |s|
        server = start_proxy(s[:routes].map { |hostname, port| route(hostname, port) })

        res = request(server, host: s[:host], accept: "application/json", headers: s[:headers])
        assert_equal s[:status], res.status, s[:name]
        assert_equal "application/json; charset=utf-8", res["content-type"], s[:name]
        assert_equal "Accept", res["vary"], s[:name]
        assert_equal({ "error" => s[:error], "upstream" => s[:host], "message" => s[:message] }, JSON.parse(res.body))
      end
    end

    it "returns JSON when Accept is %s" do
      [ "*/*", nil ].each do |accept|
        server = start_proxy([])

        res = request(server, host: "missing.localhost", accept: accept)
        assert_equal 404, res.status
        assert_equal "application/json; charset=utf-8", res["content-type"], accept.inspect
      end
    end

    it "returns the HTML page to browsers" do
      server = start_proxy([])

      res = request(server, host: "missing.localhost", accept: "text/html,application/xhtml+xml,*/*;q=0.8")
      assert_equal 404, res.status
      assert_equal "text/html", res["content-type"]
      assert_equal "Accept", res["vary"]
      assert_includes res.body, "Not Found"
    end

    it "passes an upstream 5xx JSON response through unchanged for JSON clients" do
      upstream_body = '{"error":"database unavailable","retry":true}'
      backend = listen_http { [ 503, { "Content-Type" => "application/json", "X-Backend" => "yes" }, upstream_body ] }

      routes = [ route("api.localhost", backend.port) ]
      server = start_proxy(routes)

      res = request(server, host: "api.localhost", accept: "application/json")
      assert_equal 503, res.status
      assert_equal "application/json", res["content-type"]
      assert_equal "yes", res["x-backend"]
      assert_nil res["vary"]
      assert_equal upstream_body, res.body
    end

    it "keeps reading the request body after a 502 so the connection can be reused" do
      routes = [ route("dead.localhost", 59_999) ]
      server = start_proxy(routes)

      body_size = 1024 * 1024
      client = TCPSocket.new("127.0.0.1", server)
      data = +""
      reader = Thread.new do
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        while data.scan("HTTP/1.1 502").size < 2
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0 || !client.wait_readable(remaining)

          chunk = client.read_nonblock(65_536, exception: false)
          break if chunk.nil?

          data << chunk unless chunk == :wait_readable
        end
      rescue IOError, SystemCallError
        nil
      end
      begin
        client.write("POST / HTTP/1.1\r\nHost: dead.localhost\r\nContent-Length: #{body_size}\r\n\r\n")
        client.write("\0" * body_size)
        client.write("GET / HTTP/1.1\r\nHost: dead.localhost\r\n\r\n")
      rescue SystemCallError
        nil
      end
      reader.join
      client.close
      assert_equal 2, data.scan("HTTP/1.1 502").size
    end
  end

  describe "upstream connections" do
    it "serves an IPv6 backend while the IPv4 connection stays pending" do
      begin
        backend = listen_http("::1") { [ 200, {}, "ipv6" ] }
      rescue SystemCallError
        skip "no IPv6 loopback"
      end
      backend_port = backend.port
      server = start_proxy([ route("myapp.localhost", backend_port) ])
      pending = []
      hook = lambda do |socket, host, port, &connect|
        if port == backend_port && host == "127.0.0.1"
          pending << socket
          sleep # stays connecting until the proxy gives up on it
        end
        connect.call
      end
      with_connect_hook(hook) do
        res = Timeout.timeout(1, RuntimeError, "IPv4 blocked the IPv6 backend") do
          request(server, host: "myapp.localhost")
        end
        assert_equal 200, res.status
        assert_equal "ipv6", res.body
        assert wait_until(1) { pending.length == 1 && pending[0].closed? }
        assert_equal 1, pending.length
        assert pending[0].closed?
      ensure
        pending.each { |socket| socket.close rescue nil }
      end
    end

    it "streams a POST after IPv6 refuses while IPv4 is still pending" do
      # req.on("data", chunk => res.write(chunk)); req.on("end", () => res.end())
      backend = listen_backend(raw: lambda do |socket|
        head = +""
        head << socket.read(1) until head.end_with?("\r\n\r\n")
        socket.write("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n")
        loop do
          size = socket.gets("\r\n").to_s.strip.to_i(16)
          break if size.zero?

          chunk = socket.read(size)
          socket.read(2)
          socket.write("#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n")
        end
        socket.write("0\r\n\r\n")
        socket.close
      end)
      server = start_proxy([ route("myapp.localhost", backend.port) ])
      ipv4_pending = false
      release_ipv4 = Thread::Queue.new
      refused_while_pending = false
      hook = lambda do |_socket, host, port, &connect|
        if port == backend.port
          if host == "127.0.0.1"
            ipv4_pending = true
            release_ipv4.pop
            ipv4_pending = false
          elsif host == "::1"
            begin
              return connect.call
            rescue SystemCallError
              refused_while_pending = ipv4_pending
              release_ipv4 << true
              raise
            end
          end
        end
        connect.call
      end
      with_connect_hook(hook) do
        client = TCPSocket.new("127.0.0.1", server)
        client.write("POST / HTTP/1.1\r\nhost: myapp.localhost\r\ntransfer-encoding: chunked\r\n\r\n5\r\nfirst\r\n")
        status, headers = parse_head(read_head(client))
        assert_equal "chunked", headers["transfer-encoding"]
        size = client.gets("\r\n").to_s.strip.to_i(16)
        body = client.read(size)
        client.read(2)
        client.write("5\r\n-last\r\n0\r\n\r\n")
        body << read_chunked(client)
        client.close
        assert refused_while_pending
        assert_equal({ status: 200, body: "first-last" }, { status: status, body: body })
      end
    end

    it "reuses one upstream connection across requests (issue #370)" do
      backend = listen_http { [ 200, {}, "ok" ] }

      routes = [ route("myapp.localhost", backend.port) ]
      server = start_proxy(routes)

      5.times { assert_equal 200, request(server, host: "myapp.localhost").status }
      assert_equal 1, backend.connections
    end

    it "finishes an in-flight response when the proxy closes" do
      finish = Thread::Queue.new
      backend = listen_backend(raw: lambda do |socket|
        ProxyTestSupport::NodeBackend.read_request(socket)
        socket.write("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nfirst\r\n")
        finish.pop
        socket.write("4\r\nlast\r\n0\r\n\r\n")
      end)

      running = ProxyTestSupport::RunningProxy.new(routes: [ route("myapp.localhost", backend.port) ])
      on_cleanup { running.close }
      closer = nil
      client = TCPSocket.new("127.0.0.1", running.listen_port)
      begin
        client.write("GET / HTTP/1.1\r\nhost: myapp.localhost\r\n\r\n")
        _status, headers = parse_head(read_head(client))
        assert_equal "chunked", headers["transfer-encoding"]
        size = client.gets("\r\n").to_s.strip.to_i(16)
        body = client.read(size)
        client.read(2)
        closer = Thread.new { running.close }
        finish << true
        body << read_chunked(client)

        assert_equal "firstlast", body
        assert closer.join(5)
      ensure
        finish << true
        client.close
        closer&.join(5)
      end
    end

    it "keeps serving requests while many long-lived responses are open" do
      # SSE and streaming responses hold their upstream socket for good, so a
      # cap on open sockets would leave every later request waiting forever
      backend = listen_http do |req|
        if req.url == "/stream"
          req.socket.write("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n" \
                           "a\r\ndata: hi\n\n\r\n")
          next :keep
        end
        [ 200, {}, "ok" ]
      end
      routes = [ route("myapp.localhost", backend.port) ]
      server = start_proxy(routes)

      streams = Array.new(80) do
        Thread.new do
          socket = TCPSocket.new("127.0.0.1", server)
          socket.write("GET /stream HTTP/1.1\r\nhost: myapp.localhost\r\nconnection: close\r\n\r\n")
          read_head(socket, 10)
          socket.gets("\r\n")
          socket
        end
      end.map(&:value)

      res = request(server, host: "myapp.localhost")
      assert_equal 200, res.status
      assert_equal "ok", res.body
      streams.each(&:close)
    end

    it "replays a request when the backend resets a pooled connection" do
      # answer the first request on a connection then reset the next one, which
      # is what an idle close looks like when it crosses our write
      resets = 0
      backend = listen_http do |req|
        next [ 200, {}, "ok" ] if req.count == 1

        resets += 1
        reset_and_destroy(req.socket)
        :handled
      end

      routes = [ route("myapp.localhost", backend.port) ]
      server = start_proxy(routes)
      errors = proxy_errors

      4.times do
        res = request(server, host: "myapp.localhost")
        assert_equal 200, res.status
        assert_equal "ok", res.body
      end
      assert_operator resets, :>, 0
      assert_equal [], errors
    end
  end

  describe "X-Portless header" do
    it "includes X-Portless header on 404 responses" do
      routes = []
      server = start_proxy(routes)

      res = request(server, host: "unknown.localhost")
      assert_equal "1", res[Portless::Proxy::PORTLESS_HEADER.downcase]
    end

    it "includes X-Portless header on 400 responses" do
      routes = []
      server = start_proxy(routes)

      res = request(server, host: "")
      assert_equal "1", res[Portless::Proxy::PORTLESS_HEADER.downcase]
    end
  end

  describe "proxy loop detection" do
    it "returns 508 when X-Portless-Hops reaches the threshold" do
      backend = listen_http { [ 200, {}, "should not reach here" ] }

      routes = [ route("app.localhost", backend.port) ]
      server = start_proxy(routes)
      errors = proxy_errors

      res = request(server, host: "app.localhost", accept: "text/html", headers: { "x-portless-hops" => "5" })

      assert_equal 508, res.status
      assert_includes res.body, "Loop Detected"
      assert_includes res.body, "changeOrigin"
      assert_operator errors.length, :>, 0
      assert_includes errors[0], "Loop detected"
    end

    it "allows requests with hops below the threshold" do
      backend = text_backend("ok")

      routes = [ route("app.localhost", backend.port) ]
      server = start_proxy(routes)

      res = request(server, host: "app.localhost", accept: nil, headers: { "x-portless-hops" => "2" })

      assert_equal 200, res.status
      assert_equal "ok", res.body
    end

    it "increments X-Portless-Hops when forwarding to backend" do
      received_hops = ""
      backend = listen_http do |req|
        received_hops = req["x-portless-hops"]
        [ 200, {}, "ok" ]
      end

      routes = [ route("myapp.localhost", backend.port) ]
      server = start_proxy(routes)

      # Request with no existing hops header; should be set to 1
      request(server, host: "myapp.localhost")
      assert_equal "1", received_hops

      # Request with existing hops; should be incremented
      request(server, host: "myapp.localhost", accept: nil, headers: { "x-portless-hops" => "3" })
      assert_equal "4", received_hops
    end

    it "closes socket on WebSocket upgrade when hops exceed threshold" do
      backend = listen_http do |req|
        req.socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        :handled
      end

      routes = [ route("ws.localhost", backend.port) ]
      server = start_proxy(routes)
      errors = proxy_errors

      response = raw_request(server, "GET / HTTP/1.1\r\nhost: ws.localhost\r\nconnection: Upgrade\r\n" \
                                     "upgrade: websocket\r\nx-portless-hops: 5\r\n\r\n")
      destroyed = !response.start_with?("HTTP/1.1 101")

      assert destroyed
      assert_operator errors.length, :>, 0
      assert_includes errors[0], "WebSocket loop detected"
    end

    it "detects loop with real proxy loop scenario" do
      routes = []
      proxy_server = start_proxy(routes)

      # Backend that proxies /api requests back through portless with the
      # same Host header (simulates Vite without changeOrigin: true)
      looping_backend = listen_http do |req|
        if req.url.start_with?("/api")
          begin
            sock = TCPSocket.new("127.0.0.1", proxy_server)
            headers = req.raw_headers.reject { |k, _| k.casecmp?("connection") || k.casecmp?("content-length") }
            sock.write("#{req.method} #{req.url} HTTP/1.1\r\n#{headers.map { |k, v| "#{k}: #{v}\r\n" }.join}" \
                       "connection: close\r\n\r\n")
            status, proxied_headers = parse_head(raw = read_all(sock, 5))
            sock.close
            body = raw.split("\r\n\r\n", 2)[1].to_s
            body = body.sub(/\A\h+\r\n/, "").sub(/\r\n0\r\n\r\n\z/, "") if proxied_headers["transfer-encoding"]
            [ status, { "content-type" => proxied_headers["content-type"] }.compact, body ]
          rescue SystemCallError
            [ 502, {}, "proxy error" ]
          end
        else
          [ 200, {}, "frontend page" ]
        end
      end

      routes.push(route("frontend.localhost", looping_backend.port))

      res = request(proxy_server, host: "frontend.localhost", path: "/api/tasks", accept: "text/html")

      assert_equal 508, res.status
      assert_includes res.body, "Loop Detected"
    end
  end

  describe "custom TLD" do
    it "uses custom TLD in 404 page suggested command" do
      routes = []
      server = start_proxy(routes, tld: "test")

      res = request(server, host: "unknown.test")
      assert_equal 404, res.status
      assert_includes res.body, "unknown.test"
      assert_includes res.body, "rb-portless unknown your-command"
    end

    it "uses custom TLD in 508 loop detection page" do
      backend = listen_http { [ 200, {}, "ok" ] }

      routes = [ route("app.test", backend.port) ]
      server = start_proxy(routes, tld: "test")

      res = request(server, host: "app.test", accept: "text/html", headers: { "x-portless-hops" => "5" })

      assert_equal 508, res.status
      assert_includes res.body, ".test"
    end

    it "routes requests with custom TLD hostnames" do
      backend = text_backend("custom tld hit")

      routes = [ route("myapp.test", backend.port) ]
      server = start_proxy(routes, tld: "test")

      res = request(server, host: "myapp.test")
      assert_equal 200, res.status
      assert_equal "custom tld hit", res.body
    end

    it "routes requests with multi-segment custom TLD hostnames (issue #260)" do
      backend = text_backend("multi-segment tld hit")

      routes = [ route("myapp.dev.example.com", backend.port) ]
      server = start_proxy(routes, tlds: [ "dev.example.com" ])

      res = request(server, host: "myapp.dev.example.com")
      assert_equal 200, res.status
      assert_equal "multi-segment tld hit", res.body
    end

    it "suggests the longest matching overlapping TLD in 404 page (issue #260)" do
      routes = []
      server = start_proxy(routes, tlds: [ "example.com", "dev.example.com" ])

      res = request(server, host: "missing.dev.example.com")
      assert_equal 404, res.status
      assert_includes res.body, "rb-portless missing your-command"
    end
  end

  describe "XSS safety" do
    it "escapes hostname in 404 page" do
      routes = []
      server = start_proxy(routes)

      # The proxy extracts hostname from the Host header before the colon
      res = request(server, host: "<script>alert(1)</script>.localhost")
      assert_equal 404, res.status
      refute_includes res.body, "<script>alert(1)</script>"
      assert_includes res.body, "&lt;script&gt;"
    end

    it "keeps a hostile requested host out of the filter script" do
      server = start_proxy(make_routes(6))

      res = request(server, host: '"</script><script>.localhost')
      assert_equal 404, res.status
      assert_includes res.body, "&lt;/script&gt;&lt;script&gt;"
      assert_equal 1, res.body.scan("<script>").length
      assert_equal 1, res.body.scan("</script>").length
    end

    it "escapes route hostnames in active apps list" do
      # Route hostnames come from the route store, but defense-in-depth matters
      routes = [ route('<img src=x onerror="alert(1)">', 4001) ]
      server = start_proxy(routes)

      res = request(server, host: "other.localhost")
      assert_equal 404, res.status
      refute_includes res.body, "<img src=x"
      assert_includes res.body, "&lt;img"
    end
  end
  describe "WebSocket upgrade" do
    # A backend's 'upgrade' handler: gets the raw request, writes to its socket.
    def upgrade_backend(&on_upgrade)
      listen_http do |req|
        on_upgrade.call(req, req.socket)
        :handled
      end
    end

    def upgrade_request(port, host, path: "/", headers: {})
      lines = [ "GET #{path} HTTP/1.1", "host: #{host}", "connection: Upgrade", "upgrade: websocket" ]
      headers.each { |k, v| lines << "#{k}: #{v}" }
      "#{lines.join("\r\n")}\r\n\r\n".then { |data| raw_request(port, data, read_timeout: 2) }
    end

    it "proxies WebSocket upgrade to matching route" do
      # Create a backend that accepts WebSocket upgrades
      backend = upgrade_backend do |_req, socket|
        socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        socket.close
      end

      routes = [ route("ws.localhost", backend.port) ]
      server = start_proxy(routes)

      response = upgrade_request(server, "ws.localhost")
      upgraded = parse_head(response)[0] == 101

      assert upgraded
    end

    it "responds 502 when the backend answers the handshake with a non-HTTP response" do
      backend = upgrade_backend do |_req, socket|
        # Next.js dev rejects a WebSocket whose Origin is not in
        # allowedDevOrigins by writing a bare string with no status line.
        socket.write("Unauthorized")
        socket.close
      end

      routes = [ route("ws.localhost", backend.port) ]
      server = start_proxy(routes)

      response = upgrade_request(server, "ws.localhost", path: "/_next/webpack-hmr",
                                                         headers: { "sec-websocket-version" => "13",
                                                                    "sec-websocket-key" => "dGhlIHNhbXBsZSBub25jZQ==" })
      status, = parse_head(response)
      result = { status: status, failed: status.zero? || status == 101 }

      # The client gets a diagnosable 502 instead of an abrupt connection close.
      refute result[:failed]
      assert_equal 502, result[:status]
    end

    it "does not report an error when shutdown aborts a pending WebSocket upgrade" do
      backend_port = ProxyTestSupport::TEST_PROXY_PORT + 1
      pending = []
      pending_started = Thread::Queue.new
      hook = lambda do |socket, _host, port, &connect|
        if port == backend_port
          pending << socket
          pending_started << true if pending.length == 2
          sleep # stays connecting until the proxy gives up on it
        end
        connect.call
      end
      with_connect_hook(hook) do
        running = ProxyTestSupport::RunningProxy.new(routes: [ route("ws.localhost", backend_port) ])
        on_cleanup { running.close }
        errors = running.errors
        result = Thread.new do
          response = raw_request(running.listen_port, "GET / HTTP/1.1\r\nhost: ws.localhost\r\n" \
                                                      "connection: Upgrade\r\nupgrade: websocket\r\n\r\n")
          { status: parse_head(response)[0], closed: true }
        end

        pending_started.pop(timeout: 5)
        assert(pending.none?(&:closed?))
        running.close
        assert_equal({ status: 502, closed: true }, result.value)
        assert(pending.all?(&:closed?))
        assert_empty errors
      ensure
        pending.each { |socket| socket.close rescue nil }
      end
    end

    it "forwards backend Sec-WebSocket-Accept and custom headers" do
      test_accept_value = "dGhlIHNhbXBsZSBub25jZQ=="
      test_protocol = "graphql-ws"

      backend = upgrade_backend do |_req, socket|
        socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                     "Sec-WebSocket-Accept: #{test_accept_value}\r\nSec-WebSocket-Protocol: #{test_protocol}\r\n\r\n")
        socket.close
      end

      routes = [ route("ws.localhost", backend.port) ]
      server = start_proxy(routes)

      status, headers = parse_head(upgrade_request(server, "ws.localhost"))
      result = { upgraded: status == 101, accept: headers["sec-websocket-accept"],
                 protocol: headers["sec-websocket-protocol"] }

      assert result[:upgraded]
      assert_equal test_accept_value, result[:accept]
      assert_equal test_protocol, result[:protocol]
    end

    it "destroys socket for unknown host on upgrade" do
      routes = []
      server = start_proxy(routes)

      # Attempt a WebSocket upgrade to an unknown host
      response = upgrade_request(server, "unknown.localhost")
      destroyed = response.empty?

      assert destroyed
    end
  end
end

describe "createProxyServer with TLS (HTTP/2)" do
  include ProxyTestSupport

  # beforeAll: one generated cert for the proxy and the TLS backends.
  def self.certs
    @certs ||= begin
      dir = Dir.mktmpdir("portless-proxy-test-")
      Minitest.after_run { FileUtils.rm_rf(dir) }
      paths = Portless::Certs.ensure_certs(dir)
      { cert: File.read(paths[:cert_path]), key: File.read(paths[:key_path]) }
    end
  end

  def tls_cert = self.class.certs[:cert]
  def tls_key = self.class.certs[:key]
  def tls = { cert: tls_cert, key: tls_key }

  def https_request(server, host: "", path: "/", method: "GET", accept: "text/html")
    request(server, host: host, path: path, method: method, accept: accept, tls: true)
  end

  it "forwards HTTP/1 and HTTP/2 POST bodies to a TLS upstream using its authority" do
    received = []
    backend = listen_http(tls: tls) do |req|
      received << { host: req["host"], forwarded_host: req["x-forwarded-host"], sni: req.servername, body: req.body }
      [ 200, {}, "received" ]
    end
    routes = [ route("api.localhost", backend.port, upstream: { tls: true, host: "api.internal:8443" }) ]
    plain = start_proxy(routes)
    secure = start_proxy(routes, tls: tls)

    http1_body = request(plain, host: "api.localhost:1444", method: "POST", accept: nil, body: "http1 body").body
    assert_equal "received", http1_body

    http2_body = h2_request(secure, { ":method" => "POST", ":path" => "/", ":authority" => "api.localhost:1444" },
                            body: "http2 body").body
    assert_equal "received", http2_body
    assert_equal [
      { host: "api.internal:8443", forwarded_host: "api.localhost:1444", sni: "api.internal", body: "http1 body" },
      { host: "api.internal:8443", forwarded_host: "api.localhost:1444", sni: "api.internal", body: "http2 body" }
    ], received
  end

  it "rewrites only redirects to the configured upstream origin" do
    backend = listen_http(tls: tls) do |req|
      locations = {
        "/matching" => "https://api.internal:8443/login?next=1#section",
        "/other" => "https://elsewhere.internal/login",
        "/relative" => "/login"
      }
      [ 302, { "location" => locations[req.url] }, "" ]
    end
    routes = [ route("api.localhost", backend.port, upstream: { tls: true, host: "api.internal:8443" }) ]
    plain = start_proxy(routes)
    secure = start_proxy(routes, tls: tls)

    [
      [ plain, false, "api.localhost", "http://api.localhost/login?next=1#section" ],
      [ plain, false, "api.localhost:80", "http://api.localhost/login?next=1#section" ],
      [ plain, false, "api.localhost:1444", "http://api.localhost:1444/login?next=1#section" ],
      [ secure, true, "api.localhost", "https://api.localhost/login?next=1#section" ],
      [ secure, true, "api.localhost:443", "https://api.localhost/login?next=1#section" ],
      [ secure, true, "api.localhost:1444", "https://api.localhost:1444/login?next=1#section" ]
    ].each do |proxy, encrypted, host, location|
      response = encrypted ? https_request(proxy, host: host, path: "/matching") : request(proxy, host: host, path: "/matching")
      assert_equal 302, response.status
      assert_equal location, response["location"]
    end

    [ [ "/other", "https://elsewhere.internal/login" ], [ "/relative", "/login" ] ].each do |path, location|
      response = request(plain, host: "api.localhost:1444", path: path)
      assert_equal 302, response.status
      assert_equal location, response["location"]
    end
  end

  it "reuses TLS sockets only for the same upstream authority and protocol" do
    backend = listen_http(tls: tls) do |req|
      [ 200, {}, JSON.generate({ sni: req.servername, host: req["host"] }) ]
    end
    route = route("api.localhost", backend.port, upstream: { tls: true, host: "a.internal" })
    server = start_proxy(get_routes: -> { [ route ] })
    get = -> { request(server, host: "api.localhost") }
    assert_equal({ "sni" => "a.internal", "host" => "a.internal" }, JSON.parse(get.call.body))
    assert_equal({ "sni" => "a.internal", "host" => "a.internal" }, JSON.parse(get.call.body))
    assert_equal 1, backend.secure_connections
    route.upstream = { tls: true, host: "b.internal" }
    assert_equal({ "sni" => "b.internal", "host" => "b.internal" }, JSON.parse(get.call.body))
    assert_equal 2, backend.secure_connections
    route.upstream = { tls: false, host: "a.internal" }
    assert_equal 502, get.call.status
    route.upstream = { tls: true, host: "a.internal" }
    assert_equal({ "sni" => "a.internal", "host" => "a.internal" }, JSON.parse(get.call.body))
    assert_equal 2, backend.secure_connections
  end

  it "reports a TLS mismatch against a plaintext backend and recovers" do
    backend = listen_http { [ 200, {}, "ok" ] }
    route = route("api.localhost", backend.port, upstream: { tls: true })
    server = start_proxy(get_routes: -> { [ route ] })
    assert_equal 502, request(server, host: "api.localhost").status
    route.upstream = { tls: false }
    assert_equal "ok", request(server, host: "api.localhost").body
  end

  it "reaches an IPv6-only TLS backend" do
    begin
      backend = listen_http("::1", tls: tls, ipv6_only: true) { [ 200, {}, "ipv6" ] }
    rescue Errno::EAFNOSUPPORT, Errno::EADDRNOTAVAIL
      skip "no IPv6 loopback"
    end
    routes = [ route("api.localhost", backend.port, upstream: { tls: true, host: "api.internal" }) ]
    server = start_proxy(routes)
    assert_equal "ipv6", request(server, host: "api.localhost").body
  end

  it "times out, cancels and shuts down stalled TLS handshakes without losing dial slots" do
    backend = listen_http(tls: tls) { [ 200, {}, "ok" ] }
    sockets = []
    incoming_sockets = []
    lock = Mutex.new
    accepted = 0
    forward = false
    tunnel = listen_backend(raw: lambda do |socket|
      lock.synchronize do
        accepted += 1
        sockets << socket
        incoming_sockets << socket
      end
      begin
        if forward
          target = TCPSocket.new("127.0.0.1", backend.port)
          lock.synchronize { sockets << target }
          pipe = Thread.new { IO.copy_stream(target, socket) rescue nil }
          IO.copy_stream(socket, target) rescue nil
          pipe.join
          target.close
        else
          IO.copy_stream(socket, IO::NULL) rescue nil # socket.resume()
        end
      ensure
        socket.close rescue nil
        lock.synchronize do
          sockets.delete(socket)
          sockets.delete(target)
          incoming_sockets.delete(socket)
        end
      end
    end)
    route = route("api.localhost", tunnel.port, upstream: { tls: true, host: "timeout.internal" })
    port = start_proxy(get_routes: -> { [ route ] })
    clients = []
    open = lambda do
      client = TCPSocket.new("127.0.0.1", port)
      client.write("GET / HTTP/1.1\r\nhost: api.localhost\r\nconnection: close\r\n\r\n")
      clients << client
      client
    end
    begin
      timeout = request(port, host: "api.localhost", accept: "application/json", read_timeout: 15)
      assert_equal 502, timeout.status
      assert_equal "The target app may not be running.", JSON.parse(timeout.body)["message"]
      assert wait_until { lock.synchronize { sockets.empty? } }
      route.upstream = { tls: true, host: "cancel.internal" }
      initial = accepted
      stalled = Array.new(8) { open.call }
      assert wait_until { accepted - initial == 8 }
      queued = Thread.new { request(port, host: "api.localhost") }
      sleep 0.1
      assert_equal 8, accepted - initial
      forward = true
      stalled.each(&:close)
      assert_equal "ok", queued.value.body
      assert wait_until { accepted - initial == 9 }
      forward = false
      route.upstream = { tls: true, host: "shutdown.internal" }
      before_shutdown = accepted
      Array.new(9) { open.call }
      assert wait_until { accepted - before_shutdown == 8 }
      sleep 0.1
      assert_equal 8, accepted - before_shutdown
      @running.close
      assert wait_until { lock.synchronize { incoming_sockets.empty? } }
    ensure
      clients.each { |client| client.close rescue nil }
      lock.synchronize { sockets.dup }.each { |socket| socket.close rescue nil }
    end
  end

  it "streams TLS upstream events without blocking another request" do
    stream = Thread::Queue.new
    backend = listen_http(tls: tls) do |req|
      next [ 200, {}, "ok" ] unless req.url == "/events"

      req.socket.write("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n" \
                       "d\r\ndata: first\n\n\r\n")
      stream.pop
      :handled
    end
    routes = [ route("api.localhost", backend.port, upstream: { tls: true }) ]
    server = start_proxy(routes)
    req = TCPSocket.new("127.0.0.1", server)
    begin
      req.write("GET /events HTTP/1.1\r\nhost: api.localhost\r\n\r\n")
      read_head(req)
      size = req.gets("\r\n").to_s.strip.to_i(16)
      chunk = req.read(size)
      assert_equal "data: first\n\n", chunk
      assert_equal "ok", request(server, host: "api.localhost").body
    ensure
      req.close
      stream << true
    end
  end

  it "creates an HTTPS server that responds to requests" do
    routes = []
    server = start_proxy(routes, tls: tls)

    res = https_request(server, host: "unknown.localhost")
    assert_equal 404, res.status
    assert_includes res.body, "Not Found"
  end

  it "includes X-Portless header on TLS responses" do
    routes = []
    server = start_proxy(routes, tls: tls)

    res = https_request(server, host: "unknown.localhost")
    assert_equal "1", res[Portless::Proxy::PORTLESS_HEADER.downcase]
  end

  it "proxies HTTPS request to matching route" do
    backend = text_backend("hello from backend via h2")

    routes = [ route("myapp.localhost", backend.port) ]
    server = start_proxy(routes, tls: tls)

    res = https_request(server, host: "myapp.localhost")
    assert_equal 200, res.status
    assert_equal "hello from backend via h2", res.body
  end

  it "supports HTTP/2 connections" do
    routes = []
    server = start_proxy(routes, tls: tls)

    res = h2_request(server, { ":method" => "GET", ":path" => "/", "host" => "test.localhost" })
    result = { status: res.status, protocol: "h2" }

    assert_equal 404, result[:status]
    assert_equal "h2", result[:protocol]
  end

  it "frames h2 request bodies sent without content-length (issue #414)" do
    received = []
    backend = listen_http do |req|
      received << { method: req.method, te: req["transfer-encoding"], body: req.body }
      [ 200, {}, "ok" ]
    end

    routes = [ route("myapp.localhost", backend.port) ]
    server = start_proxy(routes, tls: tls)

    Sync do
      client = h2_client(server)
      send = lambda do |method, body = nil, headers = {}|
        h2_call(client, { ":method" => method, ":path" => "/", ":authority" => "myapp.localhost" }.merge(headers),
                body: body).status
      end
      begin
        assert_equal 200, send.call("DELETE", '{"id":1}')
        assert_equal 200, send.call("GET", "x")
        assert_equal 200, send.call("GET")
        assert_equal 200, send.call("DELETE", "{}", { "content-length" => "2" })
      ensure
        client.close
      end
    end

    assert_equal [
      { method: "DELETE", te: "chunked", body: '{"id":1}' },
      { method: "GET", te: "chunked", body: "x" },
      { method: "GET", te: nil, body: "" },
      { method: "DELETE", te: nil, body: "{}" }
    ], received
  end

  it "keeps an unframed h2 body from reaching another client's pooled request" do
    received = []
    backend = listen_http do |req|
      received << { url: req.url, auth: req["authorization"] }
      [ 200, {}, "ok" ]
    end

    server = start_proxy([ route("myapp.localhost", backend.port) ], tls: tls)

    send = lambda do |path, headers, body = nil|
      h2_request(server, { ":method" => "GET", ":path" => path, ":authority" => "myapp.localhost" }.merge(headers),
                 body: body).status
    end

    # An incomplete request in a GET body must not prefix the next request
    # that reuses the same upstream socket.
    assert_equal 200, send.call("/", {}, "GET /admin HTTP/1.1\r\nX-Ignore: ")
    assert_equal 200, send.call("/profile", { "authorization" => "Bearer victim" })

    refute(received.any? { |r| r[:url] == "/admin" })
    assert_includes received, { url: "/profile", auth: "Bearer victim" }
  end

  it "returns compact JSON errors over TLS to JSON clients" do
    server = start_proxy([], tls: tls)

    res = https_request(server, host: "missing.localhost", accept: "application/json")
    assert_equal 404, res.status
    assert_equal "application/json; charset=utf-8", res["content-type"]
    assert_equal "not_found", JSON.parse(res.body)["error"]
  end

  it "forwards the :authority hostname as Host to the backend (h2 -> HTTP/1.1)" do
    received_host = ""
    backend = listen_http do |req|
      received_host = req["host"] || ""
      [ 200, { "Content-Type" => "text/plain" }, "ok" ]
    end

    routes = [ route("myapp.localhost", backend.port) ]
    server = start_proxy(routes, tls: tls)

    # Real h2 clients (browsers, curl) send only :authority — no Host header.
    status = h2_request(server, { ":method" => "GET", ":path" => "/", ":authority" => "myapp.localhost" }).status

    assert_equal 200, status
    assert_equal "myapp.localhost", received_host
  end

  it "still accepts HTTP/1.1 connections over TLS (allowHTTP1)" do
    routes = []
    server = start_proxy(routes, tls: tls)

    res = https_request(server, host: "fallback.localhost")
    assert_equal 404, res.status
    assert_includes res.body, "Not Found"
  end

  it "generates https:// URLs in 404 page" do
    routes = [ route("myapp.localhost", 4001) ]
    server = start_proxy(routes, tls: tls)

    res = https_request(server, host: "other.localhost")
    assert_equal 404, res.status
    assert_includes res.body, "https://myapp.localhost:1355"
  end

  it "sets x-forwarded-proto to http for plain HTTP requests on non-TLS proxy" do
    received_proto = ""
    backend = listen_http do |req|
      received_proto = req["x-forwarded-proto"]
      [ 200, {}, "ok" ]
    end

    routes = [ route("myapp.localhost", backend.port) ]
    server = start_proxy(routes, port: 80)

    request(server, host: "myapp.localhost")
    assert_equal "http", received_proto
  end

  it "sets x-forwarded-proto to https when proxying" do
    received_proto = ""
    backend = listen_http do |req|
      received_proto = req["x-forwarded-proto"]
      [ 200, {}, "ok" ]
    end

    routes = [ route("myapp.localhost", backend.port) ]
    server = start_proxy(routes, tls: tls)

    https_request(server, host: "myapp.localhost")
    assert_equal "https", received_proto
  end

  # A TLS client socket to the proxy (https.request with rejectUnauthorized: false).
  def tls_socket(port, alpn: "http/1.1")
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
    ctx.alpn_protocols = [ alpn ]
    ssl = OpenSSL::SSL::SSLSocket.new(TCPSocket.new("127.0.0.1", port), ctx)
    ssl.sync_close = true
    ssl.connect
    ssl
  end

  def read_all_ssl(ssl, timeout = 2)
    out = +""
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      chunk = ssl.read_nonblock(65_536, exception: false)
      case chunk
      when nil then break
      when :wait_readable
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remaining <= 0 || !ssl.to_io.wait_readable(remaining)
      else out << chunk
      end
    end
    out
  rescue OpenSSL::SSL::SSLError, SystemCallError, IOError
    out
  end

  it "proxies WebSocket upgrade over TLS" do
    backend = listen_http do |req|
      req.socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
      :handled
    end

    routes = [ route("ws.localhost", backend.port) ]
    server = start_proxy(routes, tls: tls)

    ssl = tls_socket(server)
    ssl.write("GET / HTTP/1.1\r\nhost: ws.localhost\r\nconnection: Upgrade\r\nupgrade: websocket\r\n\r\n")
    upgraded = parse_head(read_all_ssl(ssl))[0] == 101
    ssl.close

    assert upgraded
  end

  # Open an HTTP/2 client session to the proxy (h2Session); the block gets
  # the client and the server's SETTINGS.
  def h2_session(server)
    Sync do
      client = h2_client(server)
      begin
        yield client, -> { h2_remote_settings(client) }
      ensure
        client.close
      end
    end
  end

  def h2_websocket(client, path: "/", authority: "ws.localhost")
    req = h2_build({ ":method" => "CONNECT", ":protocol" => "websocket", ":path" => path, ":authority" => authority,
                     "sec-websocket-version" => "13" }, "")
    res = client.call(req)
    { status: res.status, body: res.read.to_s }
  end

  it "distinguishes unavailable TLS upstreams from TLS protocol errors for HTTP and WebSockets" do
    reset = false
    port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }

    server = start_proxy([ route("ws.localhost", port, upstream: { tls: true, host: "ws.internal" }) ], tls: tls)
    errors = proxy_errors
    ws_headers = { "connection" => "Upgrade", "upgrade" => "websocket", "sec-websocket-version" => "13",
                   "sec-websocket-key" => "dGhlIHNhbXBsZSBub25jZQ==" }

    h2_session(server) do |client|
      json = https_request(server, host: "ws.localhost", accept: "application/json")
      html = https_request(server, host: "ws.localhost")
      ws = request(server, host: "ws.localhost", headers: ws_headers)
      h2ws = h2_websocket(client)
      unavailable = "The target app is not responding. It may have crashed."
      assert_equal 502, json.status
      assert_equal unavailable, JSON.parse(json.body)["message"]
      assert_equal 502, html.status
      assert html.body.include?(unavailable)
      [ ws, h2ws ].each do |response|
        response = response.to_h if response.is_a?(Struct)
        assert_equal 502, response[:status]
        assert_includes response[:body], "target app is not responding"
        refute_includes response[:body], "supports TLS"
      end

      # A plain HTTP server on the port: answers the ClientHello with a 400
      # (Node's clientError), or destroys the socket once `reset` is set.
      plain = listen_backend(port: port, raw: lambda do |socket|
        socket.readpartial(16_384) # the whole ClientHello, so close() sends FIN, not RST
        socket.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n") unless reset
        reset ? reset_and_destroy(socket) : socket.close
      end)
      mismatch_http = https_request(server, host: "ws.localhost", accept: "application/json")
      mismatch_ws = request(server, host: "ws.localhost", headers: ws_headers)
      mismatch_h2ws = h2_websocket(client)
      [ mismatch_http.to_h, mismatch_ws.to_h, mismatch_h2ws ].each do |response|
        assert_equal 502, response[:status]
        assert_includes response[:body], "supports TLS on the configured port"
      end
      # The text is the system OpenSSL's (Node bundles its own): 3.5.5 reports a
      # plaintext reply as "record layer failure", 3.5.7 as "wrong version number".
      assert(errors.any? { |error| error =~ /wrong version number|record layer failure/i }, errors.inspect)
      reset = true
      reset_response = https_request(server, host: "ws.localhost", accept: "application/json")
      assert_equal 502, reset_response.status
      assert_equal "The target app may not be running.", JSON.parse(reset_response.body)["message"]

      plain.close
      listen_http(port: port, tls: tls) { [ 200, {}, "recovered" ] }
      response = https_request(server, host: "ws.localhost")
      assert_equal 200, response.status
      assert_equal "recovered", response.body
    end
  end

  it "reports a malformed WebSocket response after a successful upstream TLS handshake" do
    backend = listen_http(tls: tls) do |req|
      req.socket.write("Unauthorized")
      :handled
    end
    routes = [ route("ws.localhost", backend.port, upstream: { tls: true, host: "ws.internal" }) ]
    server = start_proxy(routes)
    response = request(server, host: "ws.localhost",
                               headers: { "connection" => "Upgrade", "upgrade" => "websocket",
                                          "sec-websocket-version" => "13",
                                          "sec-websocket-key" => "dGhlIHNhbXBsZSBub25jZQ==" })
    assert_equal 1, backend.secure_connections
    assert_equal 502, response.status
    assert_includes response.body, "invalid response to the WebSocket handshake"
    refute_includes response.body, "supports TLS"
  end

  # The backend's 'upgrade' handler for an echoing WebSocket: answers the
  # handshake with the right Sec-WebSocket-Accept, then echoes every chunk.
  def echo_upgrade(req)
    accept = [ Digest::SHA1.digest("#{req['sec-websocket-key']}258EAFA5-E914-47DA-95CA-C5AB0DC85B11") ].pack("m0")
    req.socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                     "Sec-WebSocket-Accept: #{accept}\r\n\r\n")
    while (data = req.socket.readpartial(4096))
      req.socket.write("echo:#{data}")
    end
  rescue EOFError, IOError, SystemCallError
    nil
  end

  it "forwards HTTP/1 and RFC 8441 WebSockets through TLS with upstream headers" do
    received = []
    backend = listen_http(tls: tls) do |req|
      received << { host: req["host"], forwarded: req["x-forwarded-host"], sni: req.servername }
      echo_upgrade(req)
      :handled
    end
    routes = [ route("ws.localhost", backend.port, upstream: { tls: true, host: "ws.internal:8443" }) ]
    server = start_proxy(routes, tls: tls)

    ssl = tls_socket(server)
    ssl.write("GET / HTTP/1.1\r\nhost: ws.localhost:1444\r\nconnection: Upgrade\r\nupgrade: websocket\r\n" \
              "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\nsec-websocket-version: 13\r\n\r\n")
    head = +""
    head << ssl.readpartial(1) until head.end_with?("\r\n\r\n")
    status, = parse_head(head)
    flunk "unexpected HTTP #{status}" unless status == 101
    ssl.write("ping")
    http1 = ssl.readpartial(4096)
    ssl.close
    assert_equal "echo:ping", http1

    h2_session(server) do |client|
      body = ::Protocol::HTTP::Body::Writable.new
      req = ::Protocol::HTTP::Request.new("https", "ws.localhost:1444", "CONNECT", "/ws", nil,
                                          ::Protocol::HTTP::Headers[{ "sec-websocket-version" => "13" }], body, "websocket")
      response = client.call(req)
      body.write("ping")
      result = { status: response.status, data: response.body.read.to_s }
      body.close_write
      response.close
      assert_equal({ status: 200, data: "echo:ping" }, result)
    end
    assert_equal Array.new(2, { host: "ws.internal:8443", forwarded: "ws.localhost:1444", sni: "ws.internal" }), received
  end

  it "proxies WebSocket over HTTP/2 extended CONNECT (RFC 8441)" do
    received = {}
    backend = listen_http do |req|
      received.merge!(req.headers)
      echo_upgrade(req)
      :handled
    end

    routes = [ route("ws.localhost", backend.port) ]
    server = start_proxy(routes, tls: tls)

    h2_session(server) do |client, settings|
      body = ::Protocol::HTTP::Body::Writable.new
      req = ::Protocol::HTTP::Request.new("https", "ws.localhost", "CONNECT", "/_next/webpack-hmr", nil,
                                          ::Protocol::HTTP::Headers[{ "sec-websocket-version" => "13" }], body, "websocket")
      response = client.call(req)
      assert_equal 1, settings.call.enable_connect_protocol
      body.write("ping")
      result = { status: response.status, accept: response.headers["sec-websocket-accept"],
                 echoed: response.body.read.to_s }
      body.close_write
      response.close

      # RFC 8441 handshake succeeds with :status 200 and no Accept header.
      assert_equal 200, result[:status]
      assert_nil result[:accept]
      assert_equal "echo:ping", result[:echoed]
      # The backend saw a synthesized HTTP/1.1 handshake.
      assert_equal "websocket", received["upgrade"]
      assert_equal "13", received["sec-websocket-version"]
      assert_equal 16, received["sec-websocket-key"].unpack1("m").bytesize
      assert_equal "ws.localhost", received["host"]
      assert_equal "1", received["x-portless-hops"]
      assert_equal "https", received["x-forwarded-proto"]
      if received["connection"] == "upgrade"
        skip "async-http writes the upgrade request's Connection header itself, lowercase (\"upgrade\")"
      end
      assert_equal "Upgrade", received["connection"]
    end
  end

  it "opens no upstream sockets when shutdown starts during extended CONNECT routing" do
    connects = []
    running = nil
    running = ProxyTestSupport::RunningProxy.new(
      get_routes: lambda {
        running.proxy.stop
        [ route("ws.localhost", 12_345) ]
      },
      tls: tls
    )
    on_cleanup { running.close }
    Sync do
      client = h2_client(running.listen_port)
      h2_remote_settings(client)
      hook = lambda do |_socket, host, port, &connect|
        connects << [ host, port ]
        connect.call
      end
      begin
        status = with_connect_hook(hook) do
          h2_call(client, { ":method" => "CONNECT", ":protocol" => "websocket", ":path" => "/ws",
                            ":authority" => "ws.localhost" }, body: "").status
        end
        assert_equal 502, status
        assert_empty connects
      ensure
        client.close rescue nil
      end
    end
    running.close
  end

  it "proxies WS-over-H2 extended CONNECT with a multi-segment custom TLD (issue #260)" do
    backend = listen_http do |req|
      echo_upgrade(req)
      :handled
    end

    routes = [ route("myapp.dev.example.com", backend.port) ]
    server = start_proxy(routes, tlds: [ "dev.example.com" ], tls: tls)

    h2_session(server) do |client|
      body = ::Protocol::HTTP::Body::Writable.new
      req = ::Protocol::HTTP::Request.new("https", "myapp.dev.example.com", "CONNECT", "/ws", nil,
                                          ::Protocol::HTTP::Headers[{ "sec-websocket-version" => "13" }], body, "websocket")
      response = client.call(req)
      body.write("ping")
      result = { status: response.status, echoed: response.body.read.to_s }
      body.close_write
      response.close

      assert_equal 200, result[:status]
      assert_equal "echo:ping", result[:echoed]
    end
  end

  it "answers 502 when the backend's Sec-WebSocket-Accept does not match" do
    backend = listen_http do |req|
      req.socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                       "Sec-WebSocket-Accept: not-the-right-hash\r\n\r\n")
      while (data = req.socket.readpartial(4096))
        req.socket.write("leak:#{data}")
      end
    rescue EOFError, IOError, SystemCallError
      :handled
    end

    routes = [ route("ws.localhost", backend.port) ]
    server = start_proxy(routes, tls: tls)

    h2_session(server) do |client|
      result = h2_websocket(client, path: "/_next/webpack-hmr")

      # The tunnel must not open: no payload from the backend leaks through.
      assert_equal 502, result[:status]
      assert_includes result[:body], "invalid response to the WebSocket handshake"
      refute_includes result[:body], "leak:"
    end
  end

  it "forwards backend rejection of an extended CONNECT as an HTTP response" do
    backend = listen_http do |req|
      req.socket.write("HTTP/1.1 307 Temporary Redirect\r\nLocation: /login\r\nContent-Length: 0\r\n\r\n")
      :handled
    end

    routes = [ route("ws.localhost", backend.port) ]
    server = start_proxy(routes, tls: tls)

    h2_session(server) do |client|
      res = h2_call(client, { ":method" => "CONNECT", ":protocol" => "websocket", ":path" => "/_next/webpack-hmr",
                              ":authority" => "ws.localhost" }, body: "")
      result = { status: res.status, location: res["location"] }

      assert_equal 307, result[:status]
      assert_equal "/login", result[:location]
    end
  end

  it "returns 404 for extended CONNECT to an unknown host" do
    server = start_proxy([], tls: tls)

    h2_session(server) do |client|
      status = h2_call(client, { ":method" => "CONNECT", ":protocol" => "websocket", ":path" => "/",
                                 ":authority" => "unknown.localhost" }, body: "").status
      assert_equal 404, status
    end
  end

  it "returns 501 for a classic CONNECT without :protocol" do
    server = start_proxy([], tls: tls)

    h2_session(server) do |client|
      status = h2_call(client, { ":method" => "CONNECT", ":authority" => "example.com:443", ":path" => nil }).status
      assert_equal 501, status
    end
  end

  it "proxies plain-HTTP WebSocket upgrades on the TLS port instead of dropping them" do
    backend = listen_http do |req|
      req.socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
      :handled
    end

    routes = [ route("ws.localhost", backend.port) ]
    server = start_proxy(routes, tls: tls)

    response = raw_request(server, "GET / HTTP/1.1\r\nhost: ws.localhost\r\nconnection: Upgrade\r\nupgrade: websocket\r\n\r\n",
                           read_timeout: 2)
    upgraded = parse_head(response)[0] == 101

    assert upgraded
  end

  it "redirects plain HTTP to HTTPS on the TLS-enabled port" do
    routes = []
    server = start_proxy(routes, port: 443, tls: tls)

    res = request(server, host: "myapp.localhost", path: "/dashboard")
    assert_equal 302, res.status
    assert_equal "https://myapp.localhost/dashboard", res["location"]
  end

  it "includes port in redirect Location when proxy is not on 443" do
    routes = []
    server = start_proxy(routes, tls: tls)

    res = request(server, host: "myapp.localhost")
    assert_equal 302, res.status
    assert_equal "https://myapp.localhost:#{ProxyTestSupport::TEST_PROXY_PORT}/", res["location"]
  end

  it "includes X-Portless header in HTTP-to-HTTPS redirect" do
    server = start_proxy([], port: 443, tls: tls)

    res = request(server, host: "myapp.localhost")
    assert_equal 302, res.status
    assert_equal "1", res["x-portless"]
  end

  it "strips hop-by-hop headers from proxied TLS responses (HTTP/2 client)" do
    backend = listen_http do
      # Backend sends hop-by-hop headers that are invalid in HTTP/2
      [ 200, { "Content-Type" => "text/plain", "Connection" => "keep-alive", "Keep-Alive" => "timeout=5",
               "X-Custom" => "preserved" }, "ok" ]
    end

    routes = [ route("hop.localhost", backend.port) ]
    server = start_proxy(routes, tls: tls)

    # Use HTTP/2 client; hop-by-hop headers must be stripped for HTTP/2
    res = h2_request(server, { ":method" => "GET", ":path" => "/", "host" => "hop.localhost" })
    result = { status: res.status, headers: res.headers, body: res.body }

    assert_equal 200, result[:status]
    assert_nil result[:headers]["connection"]
    assert_nil result[:headers]["keep-alive"]
    assert_equal "preserved", Array(result[:headers]["x-custom"]).join
    assert_equal "ok", result[:body]
  end

  it "session survives sustained stream cancellation (issues #217, #221)" do
    backend = text_backend("ok")

    routes = [ route("h2burst.localhost", backend.port) ]
    server = start_proxy(routes, tls: tls)

    # Simulate Vite/Nuxt HMR: sustained bursts of stream cancellations.
    # Without tuning, an HTTP/2 server sends GOAWAY after ~1000 cumulative
    # resets, killing the session (ERR_HTTP2_PROTOCOL_ERROR in Chrome).
    Sync do
      client = h2_client(server)
      h2_remote_settings(client)
      pool = client.instance_variable_get(:@pool)
      connection = pool.acquire { |conn| conn }
      total = 1500
      batch = 100
      sent = 0
      got_goaway = -> { !connection.instance_variable_get(:@goaway_stream_id).nil? }
      until got_goaway.call || sent >= total
        batch.times do
          break if sent >= total

          stream = connection.create_stream
          stream.send_headers([ [ ":method", "GET" ], [ ":path", "/#{sent}" ], [ ":scheme", "https" ],
                                [ ":authority", "h2burst.localhost" ] ], Protocol::HTTP2::END_STREAM)
          stream.send_reset_stream(Protocol::HTTP2::Error::CANCEL)
          sent += 1
        end
        sleep 0.01
      end

      # Verify the session is still alive with a real request
      final_status = 0
      unless got_goaway.call || connection.closed?
        final_status = h2_call(client, { ":method" => "GET", ":path" => "/final", "host" => "h2burst.localhost" }).status
      end

      client.close
      refute got_goaway.call
      assert_equal 200, final_status
    end
  end
end

describe "internal hosts-sync route" do
  include ProxyTestSupport

  token = "a" * 64
  hosts_sync_path = Portless::Proxy::HOSTS_SYNC_PATH
  auth_header = Portless::HostsSyncAuth::HOSTS_SYNC_AUTH_HEADER

  define_method(:start) do |on_hosts_sync_request = nil, routes = []|
    start_proxy(routes, on_hosts_sync_request: on_hosts_sync_request, hosts_sync_token: token)
  end

  it "accepts canonical loopback authorities with optional ports" do
    calls = 0
    server = start(lambda {
      calls += 1
      :acted
    })
    [ "127.0.0.1", "127.0.0.1:1355", "[::1]", "[::1]:1355" ].each do |host|
      res = request(server, host: host, path: hosts_sync_path, method: "POST", headers: { auth_header => token })
      assert_equal 204, res.status, host
    end
    assert_equal 4, calls
  end

  it "accepts an IPv6 loopback peer with canonical authority" do
    calls = 0
    begin
      server = start_proxy([], bind_targets: [ { host: "::1" } ], hosts_sync_token: token,
                               on_hosts_sync_request: lambda {
                                 calls += 1
                                 :acted
                               })
    rescue Errno::EAFNOSUPPORT, Errno::EADDRNOTAVAIL
      skip "no IPv6 loopback"
    end
    res = request(server, hostname: "::1", host: "[::1]", path: hosts_sync_path, method: "POST",
                          headers: { auth_header => token })

    assert_equal 204, res.status
    assert_equal 1, calls
  end

  it "proxies a registered hostname beginning with 127" do
    upstream = listen_http { [ 200, {}, "app response" ] }

    server = start(-> { :acted }, [ route("127.evil.test", upstream.port) ])
    res = request(server, host: "127.evil.test", path: hosts_sync_path, method: "POST")
    assert_equal 200, res.status
    assert_equal "app response", res.body
    assert_nil res[Portless::HostsSyncAuth::HOSTS_SYNC_AUTH_PROOF_HEADER]
  end

  it "refuses a canonical loopback authority from a non-loopback peer" do
    lan = lan_ip
    skip "no LAN address" unless lan

    server = start_proxy([], bind_targets: [ { host: "0.0.0.0" } ], on_hosts_sync_request: -> { :acted },
                             hosts_sync_token: token)

    status = request(server, hostname: lan, host: "127.0.0.1", path: hosts_sync_path, method: "POST", accept: nil,
                             headers: { auth_header => token }).status
    assert_equal 403, status
  end

  it "answers 404 when the daemon has no hosts-sync producer" do
    server = start
    res = request(server, host: "127.0.0.1", path: hosts_sync_path, method: "POST", headers: { auth_header => token })
    assert_equal 404, res.status
  end

  it "does not acknowledge when hosts sync is disabled" do
    server = start(-> { :disabled })
    res = request(server, host: "127.0.0.1", path: hosts_sync_path, method: "POST", headers: { auth_header => token })
    assert_equal 409, res.status
  end

  rejected_requests = [
    [ "missing authorization", {} ],
    [ "malformed authorization", { auth_header => "not-a-token" } ],
    [ "incorrect authorization", { auth_header => "b" * 64 } ],
    [ "duplicated authorization", { auth_header => [ token, token ] } ],
    [ "browser origin", { auth_header => token, "origin" => "https://attacker.example" } ],
    *%w[cross-site same-site same-origin none].map do |site|
      [ "browser fetch metadata #{site}", { auth_header => token, "sec-fetch-site" => site } ]
    end
  ]

  it "rejects %s before the callback" do
    rejected_requests.each do |name, headers|
      calls = 0
      server = start(lambda {
        calls += 1
        :acted
      })
      res = request(server, host: "127.0.0.1", path: hosts_sync_path, method: "POST", headers: headers)
      assert_equal 401, res.status, name
      assert_equal 0, calls, name
    end
  end

  it "does not dispatch a browser preflight" do
    calls = 0
    server = start(lambda {
      calls += 1
      :acted
    })
    res = request(server, host: "127.0.0.1", path: hosts_sync_path, method: "OPTIONS",
                          headers: { "origin" => "https://attacker.example", "access-control-request-method" => "POST",
                                     "access-control-request-headers" => auth_header })
    refute_equal 204, res.status
    assert_nil res["access-control-allow-origin"]
    assert_equal 0, calls
  end

  it "does not accept alternate authority %s" do
    [ "127.1", "2130706433", "127.0.0.1@evil.test" ].each do |host|
      server = start(-> { :acted })
      res = request(server, host: host, path: hosts_sync_path, method: "POST", headers: { auth_header => token })
      refute_equal 204, res.status, host
    end
  end
end

describe "loopbackOnly" do
  include ProxyTestSupport

  def self.certs
    @certs ||= begin
      dir = Dir.mktmpdir("portless-loopback-only-")
      Minitest.after_run { FileUtils.rm_rf(dir) }
      paths = Portless::Certs.ensure_certs(dir)
      { cert: File.read(paths[:cert_path]), key: File.read(paths[:key_path]) }
    end
  end

  # listen(0, "0.0.0.0")
  def listen_all(routes, **options)
    start_proxy(routes, bind_targets: [ { host: "0.0.0.0" } ], **options)
  end

  def backend
    hits = 0
    server = listen_http do
      hits += 1
      [ 200, {}, "app" ]
    end
    { port: server.port, hits: -> { hits } }
  end

  # Plain request from `hostname` to the same host: the status, or the socket error.
  def plain_request(hostname, port, headers = {})
    { status: request(port, hostname: hostname, host: "myapp.localhost", accept: nil, headers: headers).status }
  rescue StandardError => e
    { error: e.class.name }
  end

  def tls_request(hostname, port)
    { status: request(port, hostname: hostname, host: "myapp.localhost", accept: nil, tls: true).status }
  rescue StandardError => e
    { error: e.class.name }
  end

  it "still serves loopback peers through the wildcard-bound plain server" do
    app = backend
    port = listen_all([ route("myapp.localhost", app[:port]) ], loopback_only: true)
    assert_equal({ status: 200 }, plain_request("127.0.0.1", port))
    assert_equal 1, app[:hits].call
  end

  it "closes a non-loopback peer before the plain request reaches a backend" do
    skip "no LAN address" unless lan_ip
    app = backend
    port = listen_all([ route("myapp.localhost", app[:port]) ], loopback_only: true)
    result = plain_request(lan_ip, port)
    assert_nil result[:status]
    refute_nil result[:error]
    assert_equal 0, app[:hits].call
  end

  it "accepts the same non-loopback peer when loopbackOnly is off" do
    skip "no LAN address" unless lan_ip
    app = backend
    port = listen_all([ route("myapp.localhost", app[:port]) ])
    assert_equal({ status: 200 }, plain_request(lan_ip, port))
    assert_equal 1, app[:hits].call
  end

  it "closes a non-loopback peer before the TLS handshake" do
    skip "no LAN address" unless lan_ip
    app = backend
    port = listen_all([ route("myapp.localhost", app[:port]) ], loopback_only: true, tls: self.class.certs)
    assert_nil tls_request(lan_ip, port)[:status]
    assert_equal({ status: 200 }, tls_request("127.0.0.1", port))
    assert_equal 1, app[:hits].call
  end

  it "guards the HTTP-to-HTTPS redirect listener the same way" do
    skip "no LAN address" unless lan_ip
    # createHttpRedirectServer(443, true): the proxy's redirect listener.
    redirect_port = nil
    listen_all([], port: 443, loopback_only: true, tls: self.class.certs, redirect_http: true,
                   on_auxiliary_listen: ->(kind, _host, bound, _error) { redirect_port = bound if kind == :redirect })
    port = redirect_port
    assert_nil plain_request(lan_ip, port)[:status]
    assert_equal({ status: 302 }, plain_request("127.0.0.1", port))
  end
end
