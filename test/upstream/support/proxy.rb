# frozen_string_literal: true

require "socket"
require "net/http"
require "openssl"
require "json"
require "fileutils"
require "async"
require "async/http/server"
require "async/http/client"
require "async/http/endpoint"
require "async/http/protocol/http11"
require "async/http/protocol/http2"
require "protocol/http/body/writable"

# vi.spyOn(net.Socket.prototype, "connect"): while a hook is set, every
# Socket#connect to an IP address goes through hook.call(socket, host, port)
# { the real connect }.
module ConnectHook
  class << self
    attr_accessor :hook
  end

  def connect(addr, *rest)
    hook = ConnectHook.hook
    if hook
      port, host = begin
        Socket.unpack_sockaddr_in(addr)
      rescue ArgumentError, TypeError
        nil
      end
      return hook.call(self, host, port) { super } if port
    end
    super
  end
end
Socket.prepend(ConnectHook)

# Shared harness for the proxy-area mirrors (proxy, proxy-upstream,
# hosts-sync-client). Upstream builds Node servers in-process and listens on
# port 0; here a Portless::Proxy runs in a thread on a free port, backends are
# small Async::HTTP servers (or raw TCP servers) in threads, and clients are
# Net::HTTP, Async::HTTP (h2) or raw sockets.
module ProxyTestSupport
  TEST_PROXY_PORT = 1355

  Response = Struct.new(:status, :headers, :body) do
    def [](name) = headers[name.downcase]
  end

  # A Node-style backend: the handler gets the Protocol::HTTP::Request and
  # returns a Protocol::HTTP::Response (or [status, headers, body]).
  class Backend
    attr_reader :port, :host, :connections, :requests, :secure_connections

    # `tls` (raw backends): { cert:, key: } PEM strings, like https.createServer.
    # `ipv6_only` binds ::1 with IPV6_V6ONLY.
    def initialize(host = "127.0.0.1", raw: nil, tls: nil, ipv6_only: false, port: 0, &handler)
      @host = host
      @server = ipv6_only ? ipv6_only_server(host) : TCPServer.new(host, port)
      @port = @server.local_address.ip_port
      @connections = 0
      @secure_connections = 0
      @requests = 0
      @clients = []
      @lock = Mutex.new
      @tls = tls && tls_context(tls)
      @thread = raw ? raw_loop(raw) : http_loop(handler)
    end

    def url_host = host.include?(":") ? "[#{host}]" : host

    def close
      @server.close rescue nil
      @lock.synchronize { @clients.each { |c| c.close rescue nil } }
      @thread.kill
      @thread.join(2)
    end

    private

    def ipv6_only_server(host)
      socket = Socket.new(Socket::AF_INET6, Socket::SOCK_STREAM, 0)
      socket.setsockopt(Socket::IPPROTO_IPV6, Socket::IPV6_V6ONLY, true)
      socket.bind(Addrinfo.tcp(host, 0))
      socket.listen(128)
      socket
    end

    def tls_context(tls)
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.cert = OpenSSL::X509::Certificate.new(tls[:cert])
      ctx.key = OpenSSL::PKey.read(tls[:key])
      ctx.alpn_protocols = [ "http/1.1" ]
      ctx.alpn_select_cb = ->(_offered) { "http/1.1" }
      ctx.servername_cb = lambda do |(socket, name)|
        socket.instance_variable_set(:@servername, name)
        nil
      end
      ctx
    end

    def track(client)
      @lock.synchronize do
        @connections += 1
        @clients << client
      end
    end

    def http_loop(handler)
      app = lambda do |request|
        @lock.synchronize { @requests += 1 }
        result = handler ? handler.call(request) : ::Protocol::HTTP::Response[200, {}, [ "ok" ]]
        result.is_a?(Array) ? ::Protocol::HTTP::Response[*result] : result
      end
      Thread.new do
        Sync do |task|
          endpoint = Async::HTTP::Endpoint.parse("http://localhost")
          server = Async::HTTP::Server.new(app, endpoint, protocol: Async::HTTP::Protocol::HTTP11)
          loop do
            client, addr = @server.accept
            track(client)
            task.async do
              server.accept(client, addr)
            rescue StandardError
              nil
            ensure
              client.close rescue nil
            end
          end
        rescue IOError, Errno::EBADF
          nil
        end
      end
    end

    # `raw` gets each accepted socket in its own thread.
    def raw_loop(raw)
      Thread.new do
        loop do
          client, = @server.accept
          track(client)
          Thread.new(client) do |c|
            if @tls
              ssl = OpenSSL::SSL::SSLSocket.new(c, @tls)
              ssl.sync_close = true
              ssl.accept
              @lock.synchronize { @secure_connections += 1 }
              c = ssl
            end
            raw.call(c)
          rescue StandardError
            c.close rescue nil
          end
        end
      rescue IOError, Errno::EBADF
        nil
      end
    end
  end

  # A raw HTTP/1.1 request as a Node backend sees it: lowercase header names,
  # duplicate values joined with ", " (set-cookie aside), body fully read.
  IncomingRequest = Struct.new(:method, :url, :headers, :raw_headers, :body, :socket, :count) do
    def [](name) = headers[name.downcase]

    # (req.socket as TLSSocket).servername: the SNI the client sent, or nil.
    def servername = socket.instance_variable_get(:@servername)
  end

  # A Node http.createServer stand-in on raw sockets, so tests see exactly
  # what the proxy sent. The handler gets an IncomingRequest and returns
  # [status, headers, body] (written with content-length, kept alive), or
  # :handled after writing to req.socket itself (the connection then closes
  # unless it returns :keep).
  class NodeBackend < Backend
    def initialize(host = "127.0.0.1", tls: nil, ipv6_only: false, port: 0, &handler)
      super(host, raw: ->(socket) { serve(socket, handler) }, tls: tls, ipv6_only: ipv6_only, port: port)
    end

    def self.read_request(socket)
      head = +""
      until head.end_with?("\r\n\r\n")
        byte = socket.read(1)
        return nil if byte.nil?

        head << byte
        # Like Node's parser: not an HTTP request line (a TLS ClientHello, a
        # bare string) gets a 400 and the socket ends.
        if head.length == 1 && byte !~ /[A-Za-z]/
          socket.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
          return nil
        end
      end
      lines = head.split("\r\n")
      method, url, = lines.shift.split(" ", 3)
      raw = lines.map { |line| line.split(":", 2).then { |k, v| [ k, v.to_s.strip ] } }
      headers = {}
      raw.each do |key, value|
        name = key.downcase
        headers[name] = headers.key?(name) ? "#{headers[name]}, #{value}" : value
      end
      body = +""
      if headers["transfer-encoding"]&.include?("chunked")
        loop do
          size = socket.gets("\r\n").to_s.strip.split(";").first.to_i(16)
          if size.zero?
            socket.gets("\r\n")
            break
          end
          body << socket.read(size)
          socket.read(2)
        end
      elsif (length = headers["content-length"].to_i).positive?
        body << socket.read(length)
      end
      IncomingRequest.new(method, url, headers, raw, body, socket)
    end

    def self.write_response(socket, status, headers = {}, body = "")
      body = body.to_s
      lines = [ "HTTP/1.1 #{status} #{STATUS_TEXT.fetch(status, 'Status')}" ]
      names = headers.keys.map { |k| k.to_s.downcase }
      headers.each { |k, v| Array(v).each { |item| lines << "#{k}: #{item}" } }
      lines << "content-length: #{body.bytesize}" unless names.include?("content-length") ||
                                                          names.include?("transfer-encoding")
      lines << "connection: keep-alive" unless names.include?("connection")
      socket.write("#{lines.join("\r\n")}\r\n\r\n#{body}")
    end

    STATUS_TEXT = { 200 => "OK", 201 => "Created", 204 => "No Content", 301 => "Moved Permanently",
                    302 => "Found", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden",
                    404 => "Not Found", 426 => "Upgrade Required", 500 => "Internal Server Error",
                    502 => "Bad Gateway", 503 => "Service Unavailable" }.freeze

    private

    def serve(socket, handler)
      count = 0
      while (req = self.class.read_request(socket))
        count += 1
        req.count = count
        result = handler ? handler.call(req) : [ 200, {}, "ok" ]
        next if result == :keep
        break if result == :handled

        status, headers, body = result
        self.class.write_response(socket, status, headers || {}, body)
        break if req["connection"]&.downcase == "close"
      end
    ensure
      socket.close rescue nil
    end
  end

  # A running Portless::Proxy (createProxyServer + listen(0)).
  class RunningProxy
    attr_reader :proxy, :errors

    def initialize(routes: nil, get_routes: nil, port: TEST_PROXY_PORT, listen_port: 0, errors: nil, **options)
      @errors = errors || []
      get_routes ||= -> { routes }
      ready = Thread::Queue.new
      @proxy = Portless::Proxy.new(
        port: port, routes: get_routes, bind_targets: options.delete(:bind_targets) || [ { host: "127.0.0.1" } ],
        on_error: ->(message) { @errors << message }, on_listening: -> { ready << :ok }, **options
      )
      @thread = Thread.new do
        @proxy.run(listen_port, redirect_port: options[:redirect_http] ? 0 : Portless::Constants::HTTP_PORT)
      rescue Exception => e # rubocop:disable Lint/RescueException
        ready << e
      end
      result = ready.pop(timeout: 10)
      raise result if result.is_a?(Exception)
      raise "proxy did not start" unless result == :ok
    end

    def listen_port = @proxy.listen_port

    # The proxy thread is still serving (no uncaught exception took it down).
    def alive? = @thread.alive?

    def close
      @proxy.stop
      @thread.join(5) or @thread.kill
    end
  end

  def setup
    super
    @closers = []
    @dirs = []
  end

  def teardown
    @closers.reverse_each { |c| c.call rescue nil }
    @dirs.each { |d| FileUtils.rm_rf(d) }
    super
  end

  def on_cleanup(&block) = @closers << block

  def mktmpdir(prefix = "portless-proxy-test-")
    dir = Dir.mktmpdir(prefix)
    @dirs << dir
    dir
  end

  def route(hostname, port, **extra)
    Portless::RouteStore::Route.new(hostname: hostname, port: port, pid: extra.delete(:pid), extra: {}, **extra)
  end

  def make_routes(count)
    Array.new(count) { |i| route("app#{i}.localhost", 4000 + i) }
  end

  # createProxyServer(...) + listen(0). Returns the listen port.
  def start_proxy(routes = [], **options)
    running = RunningProxy.new(routes: routes, **options)
    on_cleanup { running.close }
    @running = running
    running.listen_port
  end

  def proxy_errors = @running.errors

  def listen_backend(host = "127.0.0.1", raw: nil, tls: nil, port: 0, &handler)
    backend = Backend.new(host, raw: raw, tls: tls, port: port, &handler)
    on_cleanup { backend.close }
    backend
  end

  # http.createServer(handler) + listen(0, host), handler as in NodeBackend.
  def listen_http(host = "127.0.0.1", tls: nil, ipv6_only: false, port: 0, &handler)
    backend = NodeBackend.new(host, tls: tls, ipv6_only: ipv6_only, port: port, &handler)
    on_cleanup { backend.close }
    backend
  end

  # A backend that answers every request with `body` (text/plain, 200).
  def text_backend(body, host = "127.0.0.1")
    listen_http(host) { [ 200, { "Content-Type" => "text/plain" }, body ] }
  end

  def tls_options(dir = mktmpdir("portless-proxy-tls-"))
    certs = Portless::Certs.ensure_certs(dir)
    { cert: File.read(certs[:cert_path]), key: File.read(certs[:key_path]), ca: File.read(certs[:ca_path]),
      state_dir: dir }
  end

  # The upstream test's request(): Accept defaults to text/html, nil omits it.
  def request(port, host: "", path: "/", method: "GET", headers: {}, accept: "text/html", body: nil, tls: false,
              hostname: "127.0.0.1", read_timeout: 5)
    conn = Net::HTTP.new(hostname, port)
    if tls
      conn.use_ssl = true
      conn.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end
    conn.open_timeout = 5
    conn.read_timeout = read_timeout
    req = Net::HTTPGenericRequest.new(method, !body.nil?, method != "HEAD", path)
    req.delete("accept")
    req.delete("accept-encoding")
    req.delete("user-agent")
    req["host"] = host
    req["accept"] = accept unless accept.nil?
    headers.each do |k, v|
      req.delete(k.to_s)
      Array(v).each { |item| req.add_field(k.to_s, item) }
    end
    req.body = body if body
    res = conn.start { |c| c.request(req) }
    Response.new(res.code.to_i, res.to_hash.transform_values { |v| v.length == 1 ? v.first : v }, res.body.to_s)
  end

  # Raw HTTP/1.1 exchange: writes `data`, reads until the peer closes.
  def raw_request(port, data, read_timeout: 5)
    socket = TCPSocket.new("127.0.0.1", port)
    socket.write(data)
    read_all(socket, read_timeout)
  ensure
    socket&.close
  end

  def read_all(socket, timeout = 5)
    out = +""
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if remaining <= 0 || !socket.wait_readable(remaining)

      chunk = socket.read_nonblock(65_536, exception: false)
      break if chunk.nil?
      next if chunk == :wait_readable

      out << chunk
    end
    out
  rescue Errno::ECONNRESET
    out
  end

  # Reads one HTTP/1.1 response head (up to the blank line) from a socket.
  def read_head(socket, timeout = 5)
    if socket.is_a?(OpenSSL::SSL::SSLSocket)
      head = +""
      head << socket.readpartial(1) until head.end_with?("\r\n\r\n")
      return head
    end
    out = +""
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until out.include?("\r\n\r\n")
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if remaining <= 0 || !socket.wait_readable(remaining)

      chunk = socket.read_nonblock(1, exception: false)
      break if chunk.nil?
      next if chunk == :wait_readable

      out << chunk
    end
    out
  end

  # Parses a raw HTTP/1.x response head into [status, headers].
  def parse_head(text)
    lines = text.split("\r\n\r\n", 2).first.to_s.split("\r\n")
    status = lines.shift.to_s[/\AHTTP\/\d\.\d (\d+)/, 1].to_i
    headers = Hash.new { |h, k| h[k] = nil }
    lines.each do |line|
      key, value = line.split(":", 2)
      key = key.downcase
      headers[key] = headers[key] ? [ *headers[key], value.strip ] : value.strip
    end
    [ status, headers ]
  end

  # One request over HTTP/2 (TLS, ALPN h2), like http2.connect + client.request.
  # The body goes out as DATA frames with no content-length (Node streams it
  # the same way) unless the headers give one.
  def h2_request(port, headers, body: nil, servername: nil)
    Sync do
      client = h2_client(port, servername: servername)
      out = h2_call(client, headers, body: body)
      client.close
      out
    end
  end

  # client.request(headers) on an open session; body nil sends END_STREAM
  # with the headers.
  def h2_call(client, headers, body: nil)
    req = h2_build(headers, body)
    res = client.call(req)
    Response.new(res.status, res.headers.to_h.transform_keys(&:downcase), res.read.to_s)
  end

  # Like Node's http2 client, a `host` header becomes :authority.
  def h2_build(headers, body)
    headers = headers.dup
    headers[":authority"] ||= headers.delete("host")
    request_headers = headers.reject { |k, _| k.start_with?(":") }
    writable = nil
    unless body.nil?
      writable = ::Protocol::HTTP::Body::Writable.new
      writable.write(body) unless body.empty?
      writable.close_write
    end
    path = headers.key?(":path") ? headers[":path"] : "/"
    ::Protocol::HTTP::Request.new("https", headers[":authority"], headers[":method"] || "GET", path,
                                  nil, ::Protocol::HTTP::Headers[request_headers], writable, headers[":protocol"])
  end

  # The server's SETTINGS as the client saw them (Protocol::HTTP2::Settings).
  def h2_remote_settings(client)
    pool = client.instance_variable_get(:@pool)
    pool.acquire { |connection| connection.remote_settings }
  end

  def h2_client(port, servername: nil)
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
    ctx.alpn_protocols = [ "h2" ]
    endpoint = Async::HTTP::Endpoint.parse("https://127.0.0.1:#{port}", ssl_context: ctx,
                                                                        protocol: Async::HTTP::Protocol::HTTP2)
    endpoint = endpoint.with(hostname: servername) if servername
    Async::HTTP::Client.new(endpoint, protocol: Async::HTTP::Protocol::HTTP2)
  end

  def with_connect_hook(hook)
    ConnectHook.hook = hook
    yield
  ensure
    ConnectHook.hook = nil
  end

  # Reads a chunked body from a socket until the terminating chunk.
  def read_chunked(socket)
    body = +""
    loop do
      size = socket.gets("\r\n").to_s.strip.to_i(16)
      break socket.gets("\r\n") if size.zero?

      body << socket.read(size)
      socket.read(2)
    end
    body
  end

  # A non-internal IPv4 address of this machine; connecting to it makes the
  # peer non-loopback.
  def lan_ip
    Socket.ip_address_list.find { |a| a.ipv4? && !a.ipv4_loopback? && !a.ipv4_multicast? && !a.ip_address.start_with?("169.254.") }
          &.ip_address
  end

  def now_ms = (Time.now.to_f * 1000).to_i

  # socket.resetAndDestroy(): close with an RST instead of a FIN.
  def reset_and_destroy(socket)
    socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [ 1, 0 ].pack("ii"))
    socket.close
  rescue IOError, SystemCallError
    nil
  end

  def wait_until(timeout = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
    true
  end
end
