# frozen_string_literal: true

require "async"
require "async/http/server"
require "async/http/client"
require "async/http/endpoint"
require "async/http/protocol/http11"
require "async/http/protocol/https"
require "async/semaphore"
require "protocol/http/headers"
require "protocol/http/request"
require "protocol/http/response"
require "protocol/http/body/buffered"
require "protocol/http/body/completable"
require "openssl"
require "securerandom"
require "socket"
require "ipaddr"
require "json"
require "uri"
require "digest"
require_relative "pages"
require_relative "hosts_sync_auth"

module Portless
  # The reverse proxy (proxy.ts createProxyServer) on async-http: routes by Host
  # to a loopback backend from the route table, HTTP/1.1 + HTTP/2 over TLS with
  # per-host SNI certs, WebSockets (h1 Upgrade and h2 extended CONNECT), plain
  # HTTP on the TLS port answered with a 302 (WebSocket upgrades proxied),
  # styled/JSON error pages, loop detection, `upstream` (TLS / Host override)
  # backends, loopback-only peer gating and the daemon's hosts sync endpoint.
  class Proxy
    PORTLESS_HEADER = Constants::HEALTH_HEADER
    HOPS_HEADER = Constants::PORTLESS_HOPS_HEADER
    MAX_PROXY_HOPS = Constants::MAX_PROXY_HOPS
    HOSTS_SYNC_PATH = Constants::HOSTS_SYNC_PATH

    # RFC 6455: Sec-WebSocket-Accept = base64(sha1(key + GUID)).
    WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    # Hop-by-hop headers forbidden in HTTP/2 responses (proxy.ts HOP_BY_HOP_HEADERS),
    # stripped from responses to requests that arrived over TLS.
    HOP_BY_HOP_HEADERS = %w[connection keep-alive proxy-connection transfer-encoding upgrade].freeze
    # Client hop-by-hop headers dropped before forwarding a plain request. Node
    # keeps transfer-encoding to frame the streamed body; async-http frames the
    # body itself, so the header is dropped here too (it would double-chunk).
    REQUEST_HOP_BY_HOP_HEADERS = %w[connection keep-alive proxy-connection upgrade transfer-encoding].freeze

    # Only dials in progress are limited (per backend), so long-lived responses
    # such as SSE never starve other requests.
    MAX_PENDING_UPSTREAM_DIALS = 8
    UPSTREAM_CONNECT_TIMEOUT = 10
    REPLAYABLE_METHODS = %w[GET HEAD OPTIONS].freeze
    FORWARDED_HEADERS = %w[x-forwarded-for x-forwarded-proto x-forwarded-host x-forwarded-port].freeze
    # How a backend closing the socket before answering surfaces in async-http
    # (Node reports all of these as ECONNRESET "socket hang up").
    RESET_ERRORS = [ Errno::ECONNRESET, Errno::EPIPE, EOFError, ::Protocol::HTTP::RefusedError ].freeze

    # Raised from a request handler to drop the connection without a response
    # (Node's socket.destroy()); `serve` closes the socket.
    class DropConnection < StandardError; end

    # A pending upstream dial cancelled because the client went away or the
    # proxy is closing (Node's ABORT_ERR): answered 502, never logged.
    class AbortError < StandardError
      def initialize(message = "The operation was aborted") = super
    end

    # Node's AggregateError from createLoopbackConnection: `errors` are the
    # per-address failures (127.0.0.1 first), `details` their Node-style text.
    class AggregateError < StandardError
      attr_reader :errors, :details

      def initialize(message, errors, details)
        super(message)
        @errors = errors
        @details = details
      end
    end

    # Tags an error raised on a pooled connection that had already served a
    # response (Node's proxyReq.reusedSocket).
    module ReusedSocket; end

    # Async::HTTP::Client that records whether a failed request went out on a
    # reused connection. `retries: 1` disables async-http's own retries
    # (attempt 1 is the last); forward decides on the single replay.
    class UpstreamClient < Async::HTTP::Client
      # async-pool creates one connection at a time by default; upstream lets
      # up to MAX_PENDING_UPSTREAM_DIALS dials run at once (the endpoint's
      # semaphore enforces that limit).
      def initialize(endpoint, tracker = nil, **options)
        super(endpoint, retries: 1, concurrency: MAX_PENDING_UPSTREAM_DIALS, **options)
        @tracker = tracker
      end

      def make_response(request, connection, attempt)
        @tracker&.upstream_state!(:sent)
        reused = connection.count.positive?
        super
      rescue *RESET_ERRORS => e
        e.extend(ReusedSocket) if reused
        raise
      end
    end

    # Node's http server and client cap a header block at 16 KiB (maxHeaderSize);
    # protocol-http1 caps each line at 8 KiB by default, which dropped long
    # cookies and URLs that upstream accepts. Allow a single line up to Node's cap.
    MAX_HEADER_SIZE = 16 * 1024
    HTTP1_PROTOCOL = Async::HTTP::Protocol::HTTP11.new(maximum_line_length: MAX_HEADER_SIZE)

    TLS_502_DETAIL = "Could not connect to the target app over HTTPS. Check that it supports TLS on the configured port."

    # `port` is proxyPort (the port URLs and redirects name); `listen_port`
    # is the port actually bound once `run` has bound the primary listener.
    attr_reader :port, :listen_port

    # Mirrors ProxyServerOptions. `routes` is a callable returning the current
    # route table (getRoutes). `tls` is nil, `{ cert:, key:, ca:, state_dir: }`
    # (per-host certs minted under the TLDs) or `{ cert:, key:, custom: true }`
    # (one cert for every name). Listeners bind in the order
    # cli.ts starts its servers: the extra `bind_targets`, then (with
    # `redirect_http`) the :80 redirect on every target, then the primary.
    # `on_auxiliary_listen(kind, host, port, error)` reports each non-primary
    # bind (kind :proxy or :redirect, error nil on success); `on_listening`
    # fires once the primary is bound.
    def initialize(port:, routes:, bind_targets: Privilege.bind_targets(false), tld: Constants::DEFAULT_TLD, tlds: [ tld ],
                   strict: true, tls: nil, loopback_only: false, on_hosts_sync_request: nil, hosts_sync_token: nil,
                   on_error: ->(message) { warn(message) }, redirect_http: false, on_listening: nil,
                   on_auxiliary_listen: nil)
      @port = port
      @bind_targets = bind_targets
      @get_routes = routes
      @tld_suffixes = (tlds.empty? ? [ tld ] : tlds).uniq.map { |value| ".#{value}" }
      @primary_tld_suffix = @tld_suffixes.first || ".localhost"
      @strict = strict
      @tls = tls
      @loopback_only = loopback_only
      @on_hosts_sync_request = on_hosts_sync_request
      @hosts_sync_token = hosts_sync_token
      @on_error = on_error
      @redirect_http = redirect_http
      @on_listening = on_listening
      @on_auxiliary_listen = on_auxiliary_listen
      @clients = {}
      @dial_limits = {}
      @sockets = []
      # Requests between routing and the upstream response, by fiber:
      # :waiting (for a dial slot), :dialing, :sent (in flight).
      @upstream_waits = {}
      @upstream_limits = {}
      @closing = false
    end

    # ---------------------------------------------------------------------
    # Listening

    # Bind every listener, then serve until stopped (blocking). The primary
    # bind raises (EADDRINUSE / EACCES are the caller's to explain); other
    # binds are best-effort and reported through on_auxiliary_listen. Like
    # Node's server.listen(port), the listen port may differ from proxyPort
    # (0 picks a free one).
    def run(listen_port = @port, redirect_port: Constants::HTTP_PORT)
      listeners = bind_listeners(listen_port, redirect_port)
      @closing = false
      @stop_reader, @stop_writer = IO.pipe
      @on_listening&.call
      Sync do |task|
        listeners.each do |socket, kind|
          task.async { accept_loop(socket, kind) }
        end
        task.async do
          @stop_reader.wait_readable
          close_upstream
          # In-flight responses finish (async-http defers the stop until the
          # response is written); idle connections close now.
          task.stop
        end
      end
    ensure
      close
    end

    # Ask a running proxy to shut down. Safe from a signal trap or another
    # thread: it only writes to a self-pipe the reactor watches.
    def stop
      # Like server.close(): new upstream dials abort from now on, even from a
      # request already being routed; the reactor cancels the rest.
      @closing = true
      @stop_writer&.write_nonblock(".")
    rescue StandardError
      nil
    end

    def close
      @sockets.each { |socket| socket.close rescue nil }
      @sockets.clear
      [ @stop_reader, @stop_writer ].each { |io| io&.close rescue nil }
      @clients.each_value { |client| client.close rescue nil }
      @clients.clear
    end

    # ---------------------------------------------------------------------
    # Request handling (public so tests can drive it inside a reactor).

    # `peer` is the client address (String) and `encrypted` whether the
    # connection is TLS. Returns a Protocol::HTTP::Response.
    def call(request, peer: nil, encrypted: !!@tls, replay: false)
      return handle_extended_connect(request, peer) if request.method == "CONNECT"
      return handle_upgrade(request, peer, encrypted) if upgrade_request?(request)

      handle_request(request, peer, encrypted, replay)
    end

    # Node raises 'upgrade' only for `Connection: upgrade` plus an Upgrade
    # header; async-http extracts any Upgrade header into `protocol` (and
    # reads the body as a tunnel). Anything else is an ordinary request.
    def upgrade_request?(request)
      return false unless request.protocol
      return true unless request.version.to_s.start_with?("HTTP/1")

      connection = header_value(request, "connection").to_s.downcase.split(",").map(&:strip)
      return true if connection.include?("upgrade")

      request.protocol = nil
      framed = header_value(request, "content-length") || header_value(request, "transfer-encoding")
      request.body = nil unless framed
      false
    end

    # Exact hostname, tailscale authority, tailscale hostname, then (unless
    # strict) the longest registered parent (proxy.ts findRoute).
    def self.find_route(routes, host, strict = true)
      authority = normalize_authority(host)
      hostname = authority.split(":").first.to_s
      routes.find { |r| r.hostname.to_s.downcase == hostname } ||
        routes.find { |r| tailscale_authority(r) == authority } ||
        routes.find { |r| tailscale_authority(r)&.split(":")&.first == hostname } ||
        (strict ? nil : find_most_specific_parent(routes, hostname))
    end

    def self.find_most_specific_parent(routes, hostname)
      best = nil
      routes.each do |r|
        if hostname.end_with?(".#{r.hostname.to_s.downcase}") && (best.nil? || r.hostname.length > best.hostname.length)
          best = r
        end
      end
      best
    end

    # Lowercase and drop an explicit :443 (the default HTTPS port URL strips).
    def self.normalize_authority(host)
      lower = host.to_s.downcase
      lower.end_with?(":443") ? lower.delete_suffix(":443") : lower
    end

    def self.tailscale_authority(route)
      url = route.tailscale_url
      return nil if url.nil? || url.empty?

      uri = URI(url)
      return nil unless uri.host

      host = uri.host.downcase
      uri.port && uri.port != uri.default_port ? "#{host}:#{uri.port}" : host
    rescue URI::Error
      nil
    end

    def self.loopback_peer?(address)
      return false if address.nil? || address.empty?

      bare = address.start_with?("::ffff:") ? address.delete_prefix("::ffff:") : address
      bare == "::1" || bare.start_with?("127.")
    end

    def self.loopback_authority?(authority)
      return true if [ "127.0.0.1", "[::1]" ].include?(authority)
      return valid_port?(authority, "127.0.0.1") if authority.start_with?("127.0.0.1:")
      return valid_port?(authority, "[::1]") if authority.start_with?("[::1]:")

      false
    end

    # proxy.ts hasValidPort.
    def self.valid_port?(authority, hostname)
      authority == hostname || !Utils.parse_port(authority[(hostname.length + 1)..]).nil?
    end

    private

    # --- listeners -------------------------------------------------------

    def bind_listeners(listen_port, redirect_port)
      listeners = []
      primary, *rest = @bind_targets
      rest.each { |target| bind_auxiliary(listeners, target, listen_port, :proxy) }
      if @tls && @redirect_http
        @bind_targets.each { |target| bind_auxiliary(listeners, target, redirect_port, :redirect) }
      end
      socket = bind_socket(primary, listen_port)
      @listen_port = socket.local_address.ip_port
      listeners << [ socket, :proxy ]
      listeners
    rescue StandardError
      close
      raise
    end

    # Reports the bound port (the requested one, unless that was 0).
    def bind_auxiliary(listeners, target, port, kind)
      begin
        socket = bind_socket(target, port)
        listeners << [ socket, kind ]
        port = socket.local_address.ip_port
      rescue SystemCallError => e
        error = e
      end
      @on_auxiliary_listen&.call(kind, target[:host], port, error)
    end

    def bind_socket(target, port)
      socket = Privilege.listen_on_proxy_interface(port, target)
      @sockets << socket
      socket
    end

    def accept_loop(server, kind)
      loop do
        peer, addrinfo = server.accept
        Async { handle_connection(peer, addrinfo, kind) }
      end
    rescue IOError, Errno::EBADF
      nil # listener closed
    end

    def handle_connection(peer, addrinfo, kind)
      address = addrinfo&.ip_address
      # Unprivileged wildcard bind: close non-loopback peers before parsing a byte.
      return peer.close if refuses_peer?(address)

      if kind == :redirect
        serve(peer, address, HTTP1_PROTOCOL, "http") { |request| redirect_response(request, @port) }
      elsif @tls
        first = peek_byte(peer)
        return peer.close if first.nil?

        if first == 0x16
          ssl = tls_accept(peer) or return
          protocol = ssl.alpn_protocol == "h2" ? Async::HTTP::Protocol::HTTP2 : HTTP1_PROTOCOL
          serve(ssl, address, protocol, "https") { |request| call(request, peer: address, encrypted: true) }
        else
          serve(peer, address, HTTP1_PROTOCOL, "http") { |request| plain_on_tls_port(request, address) }
        end
      else
        Fiber[:portless_client_io] = peer
        serve(peer, address, HTTP1_PROTOCOL, "http") { |request| call(request, peer: address, encrypted: false) }
      end
    rescue StandardError
      peer.close rescue nil
    end

    # An HTTP/1.1 CONNECT is dropped on every listener: Node's servers have no
    # h1 'connect' handler (proxy.ts destroys the socket on the TLS port).
    def serve(io, address, protocol, scheme, &handler)
      app = lambda do |request|
        raise DropConnection if request.method == "CONNECT" && request.version != "HTTP/2"

        handler.call(request)
      end
      endpoint = Async::HTTP::Endpoint.parse("#{scheme}://localhost")
      Async::HTTP::Server.new(app, endpoint, protocol: protocol, scheme: scheme).accept(io, address)
    rescue StandardError
      nil # client went away / protocol error: just drop the connection
    ensure
      io.close rescue nil
    end

    def peek_byte(peer)
      peer.wait_readable
      data = peer.recv(1, Socket::MSG_PEEK)
      data.nil? || data.empty? ? nil : data.getbyte(0)
    rescue StandardError
      nil
    end

    def tls_accept(peer)
      ssl = OpenSSL::SSL::SSLSocket.new(peer, ssl_context)
      ssl.sync_close = true
      ssl.accept
      ssl
    rescue StandardError
      ssl ? (ssl.close rescue nil) : (peer.close rescue nil)
      nil
    end

    def ssl_context
      @ssl_context ||= begin
        # Generated certs: `state_dir:` builds the TLD-restricted SNI minting.
        # Custom certs (`custom: true`) serve the given cert for every name.
        if @tls[:state_dir] && !@tls[:custom]
          sni = Certs.create_sni_callback(@tls[:state_dir], @tls[:cert], @tls[:key],
                                          @tld_suffixes.map { |suffix| suffix[1..] }, @tls[:ca])
        end
        context = build_default_context
        if sni
          context.servername_cb = proc do |args|
            _socket, name = args
            sni.call(name)
          end
        end
        context
      end
    end

    # Like Node's `cert: tls.ca ? Buffer.concat([tls.cert, tls.ca]) : tls.cert`:
    # every PEM block is served, the first as the leaf and the rest as its chain.
    def build_default_context
      cert, *chain = to_certs(@tls[:cert]) + (@tls[:ca] ? to_certs(@tls[:ca]) : [])
      key = @tls[:key].is_a?(OpenSSL::PKey::PKey) ? @tls[:key] : OpenSSL::PKey.read(@tls[:key])
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.add_certificate(cert, key, chain)
      ctx.alpn_protocols = %w[h2 http/1.1]
      ctx.alpn_select_cb = ->(offered) { (%w[h2 http/1.1] & offered).first || "http/1.1" }
      ctx.session_id_context = "portless"
      ctx
    end

    def to_certs(value) = value.is_a?(OpenSSL::X509::Certificate) ? [ value ] : OpenSSL::X509::Certificate.load(value)

    def refuses_peer?(address) = @loopback_only && !self.class.loopback_peer?(address)

    # Plain HTTP on the TLS port: 302 to HTTPS on the same port, except
    # WebSocket upgrades (clients cannot follow a redirect), which are proxied.
    def plain_on_tls_port(request, address)
      return call(request, peer: address, encrypted: false) if request.protocol

      redirect_response(request, @port)
    end

    def redirect_response(request, https_port)
      host = request_host(request).split(":").first
      host = "localhost" if host.nil? || host.empty?
      location = "https://#{host}#{https_port == 443 ? '' : ":#{https_port}"}#{request.path || '/'}"
      ::Protocol::HTTP::Response[302, { "location" => location, PORTLESS_HEADER => "1" }, []]
    end

    # --- plain requests --------------------------------------------------

    def handle_request(request, peer, encrypted, replay)
      return text(403, "Forbidden", PORTLESS_HEADER => "1") if refuses_peer?(peer)

      raw_host = request_host(request)
      # Node's HTTP/1.1 parser rejects a request without Host before
      # portless's handler runs: a bare 400, no headers, no body.
      # An empty Host header is present, so it reaches the handler below.
      if request.authority.nil? && header_value(request, "host").nil? && request.version == "HTTP/1.1"
        return ::Protocol::HTTP::Response[400, {}, []]
      end

      extra = { PORTLESS_HEADER => "1" }
      add_hosts_sync_proof(request, peer, raw_host, extra)

      routes = @get_routes.call

      if request.method == "POST" && request.path == HOSTS_SYNC_PATH && self.class.loopback_authority?(raw_host.downcase)
        return with_headers(handle_hosts_sync_request(request, peer), extra)
      end

      host = raw_host.split(":").first.to_s
      return with_headers(text(400, "Missing Host header"), extra) if host.empty?

      hops = hops_of(request)
      return with_headers(loop_detected(request, host, hops, encrypted), extra) if hops >= MAX_PROXY_HOPS

      route = self.class.find_route(routes, raw_host, @strict)
      return with_headers(no_route(request, host, raw_host, routes, encrypted), extra) unless route

      response = forward(request, route, hops, peer, encrypted, replay)
      with_headers(response, extra)
    end

    def forward(request, route, hops, peer, encrypted, replay)
      raise DropConnection if @closing

      headers = build_upstream_headers(request, route, hops, peer, encrypted, strip_hop_by_hop: true)
      # Node's keep-alive agent announces the pooled connection.
      headers.add("connection", "keep-alive")
      upstream_request = ::Protocol::HTTP::Request.new(
        "http", headers.delete("host").to_s, request.method, request.path, nil, headers, replay ? nil : request.body
      )
      response = track_upstream(route) { client_for(route).call(upstream_request) }
      watch_response_disconnect(response)
      rewrite_upstream_location(response.headers, route, request, encrypted)
      HOP_BY_HOP_HEADERS.each { |key| response.headers.delete(key) } if encrypted
      response
    rescue *RESET_ERRORS => e
      # The backend closed a pooled socket as it was reused: replay once
      # instead of returning a 502. The first attempt consumed the body, so
      # only bodiless requests replay.
      if !replay && e.is_a?(ReusedSocket) && REPLAYABLE_METHODS.include?(request.method) && bodiless?(request)
        return forward(request, route, hops, peer, encrypted, true)
      end

      bad_gateway(request, e)
    rescue DropConnection
      raise
    rescue StandardError => e
      bad_gateway(request, e)
    end

    # --- upstream lifecycle (proxy.ts whenUpstreamReady / closeUpstream) ---

    public

    # Called from the requesting fiber as its upstream request progresses.
    def upstream_state!(state)
      fiber = Fiber.current
      @upstream_waits[fiber] = state if @upstream_waits.key?(fiber)
    end

    def closing? = @closing

    private

    def track_upstream(route)
      fiber = Fiber.current
      @upstream_waits[fiber] = :waiting
      @upstream_limits[fiber] = dial_limit(route)
      watcher = watch_client_disconnect(fiber)
      yield
    ensure
      @upstream_waits.delete(fiber)
      @upstream_limits.delete(fiber)
      watcher&.stop
    end

    # A request queued behind a full set of dials is dropped; a dial in
    # progress is aborted (502, not logged). A request that is merely on its
    # way to dialing aborts when it gets there; requests already sent are
    # left alone.
    def cancel_upstream(fiber)
      exception = case @upstream_waits[fiber]
      when :waiting then DropConnection if @upstream_limits[fiber]&.blocking?
      when :dialing then AbortError
      end
      return unless exception && fiber.alive?

      Fiber.scheduler.raise(fiber, exception)
    rescue FiberError
      nil
    end

    # Queued requests are dropped first, so a slot freed by an aborted dial
    # cannot start another one.
    def close_upstream
      @closing = true
      waiting, dialing = @upstream_waits.keys.partition { |fiber| @upstream_waits[fiber] == :waiting }
      (waiting + dialing).each { |fiber| cancel_upstream(fiber) }
    end

    # The client closing mid-response (a closed tab on an event stream) ends
    # the upstream response too, like Node's res 'close' -> proxyReq.destroy().
    def watch_response_disconnect(response)
      io = Fiber[:portless_client_io]
      body = response.body
      return unless io && body

      watcher = Async::Task.current.async(transient: true) do
        io.wait_readable
        peeked = io.recv_nonblock(1, Socket::MSG_PEEK, exception: false)
        body.close(EOFError.new("client disconnected")) if peeked.nil? || peeked == ""
      rescue StandardError
        body.close(EOFError.new("client disconnected"))
      end
      response.body = ::Protocol::HTTP::Body::Completable.new(body, ->(_error) { watcher.stop unless watcher.current? })
    end

    # Node aborts the upstream request when the client socket closes. A plain
    # HTTP/1.1 connection is idle while its request waits upstream, so EOF on
    # it means the client went away.
    def watch_client_disconnect(fiber)
      io = Fiber[:portless_client_io]
      return unless io

      Async::Task.current.async(transient: true) do
        io.wait_readable
        peeked = io.recv_nonblock(1, Socket::MSG_PEEK, exception: false)
        cancel_upstream(fiber) if peeked.nil? || peeked == ""
      rescue StandardError
        cancel_upstream(fiber)
      end
    end

    def bodiless?(request) = request.body.nil? || request.body.length&.zero?

    def bad_gateway(request, error)
      host = request_host(request)
      log_error("Proxy error for #{host}: #{format_proxy_error(error)}") unless error.is_a?(AbortError)
      detail = if tls_error?(error)
                 TLS_502_DETAIL
      elsif error_code(error) == Errno::ECONNREFUSED
                 "The target app is not responding. It may have crashed."
      else
                 "The target app may not be running."
      end
      send_proxy_error(request, 502, "bad_gateway", detail, host) do
        Pages.render_page(502, "Bad Gateway", %(<div class="content"><p class="desc">#{Pages.escape_html(detail)}</p></div>))
      end
    end

    def loop_detected(request, host, hops, encrypted)
      log_error("Loop detected for #{host}: request has passed through portless #{hops} times. " \
                "This usually means a backend is proxying back through portless without rewriting " \
                "the Host header. If you use Vite/webpack proxy, set changeOrigin: true.")
      scheme = encrypted ? "https" : "http"
      port_hint = encrypted ? "" : ":&lt;port&gt;"
      send_proxy_error(request, 508, "loop_detected", "Request passed through portless #{hops} times", host) do
        Pages.render_page(508, "Loop Detected", <<~HTML.chomp)
          <div class="content"><p class="desc">This request has passed through portless #{hops} times. This usually means a dev server (Vite, webpack, etc.) is proxying requests back through portless without rewriting the Host header.</p><div class="section"><p class="label">Fix: add changeOrigin to your proxy config</p><pre class="terminal">proxy: {
            "/api": {
              target: "#{scheme}://&lt;backend&gt;#{Pages.escape_html(@primary_tld_suffix)}#{port_hint}",
              changeOrigin: true,
            },
          }</pre></div></div>
        HTML
      end
    end

    def no_route(request, host, raw_host, routes, encrypted)
      lower = host.downcase
      name_host = lower.end_with?(".") ? lower.chomp(".") : lower
      portless_name = @tld_suffixes.any? { |suffix| name_host == suffix[1..] || name_host.end_with?(suffix) }
      ip_address = RouteStore.ipv4?(host) || raw_host.start_with?("[")
      unless portless_name || ip_address
        message = "DNS sent #{host} to this computer. This is not the real site."
        return send_proxy_error(request, 421, "misdirected_request", message, host) do
          Pages.render_page(421, "Misdirected Request",
                            %(<div class="content"><p class="desc">#{Pages.escape_html(message)}</p></div>))
        end
      end

      send_proxy_error(request, 404, "not_found", "No app registered for #{host}", host) do
        not_found_page(host, routes, encrypted)
      end
    end

    def not_found_page(host, routes, encrypted)
      safe_host = Pages.escape_html(host)
      matched = @tld_suffixes.select { |suffix| host.end_with?(suffix) }.max_by(&:length)
      stripped = matched && matched.length < host.length ? host[0...-matched.length] : host
      now = (Time.now.to_f * 1000).to_i
      filterable = routes.length > Pages::FILTER_THRESHOLD
      items = routes.map do |r|
        age = Pages.format_uptime(r.registered_at, now)
        label = r.pid.to_i.zero? && !r.pid.nil? ? "alias" : (age && "up #{age}")
        uptime = label ? %(<span class="uptime">#{label}</span>) : ""
        scheme = upstream_of(r)[:tls] ? "https" : "http"
        %(<li><a href="#{Pages.escape_html(Pages.format_url(r.hostname, @port, encrypted))}" class="card-link"><span class="name">#{Pages.escape_html(r.hostname)}</span><span class="meta">#{uptime}<code class="port">#{scheme}://127.0.0.1:#{Pages.escape_html(r.port.to_s)}</code><span class="arrow">#{Pages::ARROW_SVG}</span></span></a></li>)
      end.join
      routes_list = if routes.empty?
                      '<p class="empty">No apps running.</p>'
      else
                      %(<div class="section"><p class="label">Active apps</p>#{filterable ? Pages::FILTER_CONTROLS : ''}<ul class="card">#{items}</ul>#{filterable ? Pages::FILTER_NO_MATCH : ''}</div>#{filterable ? "<script>#{Pages::FILTER_SCRIPT}</script>" : ''})
      end
      Pages.render_page(404, "Not Found",
                        %(<div class="content"><p class="desc">No app registered for <strong>#{safe_host}</strong></p>#{routes_list}<div class="section"><div class="terminal"><span class="prompt">$ </span>rb-portless #{Pages.escape_html(stripped)} your-command</div></div></div>))
    end

    # HTML page for clients that accept text/html, else a small JSON body.
    def send_proxy_error(request, status, error, message, host)
      accept = header_value(request, "accept").to_s.downcase
      if accept.include?("text/html")
        body = yield
        return ::Protocol::HTTP::Response[status, { "vary" => "Accept", "content-type" => "text/html" }, [ body ]]
      end

      json = JSON.generate({ error: error, upstream: host, message: message })
      ::Protocol::HTTP::Response[status, { "vary" => "Accept", "content-type" => "application/json; charset=utf-8" }, [ json ]]
    end

    # --- hosts sync --------------------------------------------------------

    def add_hosts_sync_proof(request, peer, raw_host, extra)
      return unless @hosts_sync_token && HostsSyncAuth.valid_token?(@hosts_sync_token)
      return unless request.method == "HEAD" && request.path == "/" && self.class.loopback_peer?(peer) &&
                    self.class.loopback_authority?(raw_host.downcase) && no_browser_context?(request)

      challenge = single_raw_header(request, HostsSyncAuth::HOSTS_SYNC_AUTH_CHALLENGE_HEADER)
      proof = challenge && HostsSyncAuth.create_proof(@hosts_sync_token, challenge)
      return unless proof

      extra[HostsSyncAuth::HOSTS_SYNC_AUTH_PROOF_HEADER] = proof
      extra["cache-control"] = "no-store"
    end

    def handle_hosts_sync_request(request, peer)
      return text(403, "Forbidden") unless self.class.loopback_peer?(peer)

      supplied = single_raw_header(request, HostsSyncAuth::HOSTS_SYNC_AUTH_HEADER)
      authorized = no_browser_context?(request) && supplied && HostsSyncAuth.valid_token?(supplied) &&
                   @hosts_sync_token.is_a?(String) && HostsSyncAuth.valid_token?(@hosts_sync_token) &&
                   HostsSyncAuth.secure_compare(supplied, @hosts_sync_token)
      return text(401, "Unauthorized") unless authorized
      return text(404, "Not Found") unless @on_hosts_sync_request
      return text(409, "Hosts sync disabled") if @on_hosts_sync_request.call.to_s == "disabled"

      ::Protocol::HTTP::Response[204, {}, nil]
    end

    def no_browser_context?(request)
      header_value(request, "origin").nil? && header_value(request, "sec-fetch-site").nil?
    end

    # --- WebSockets --------------------------------------------------------

    # HTTP/1.1 Upgrade (on the TLS port, the plain HTTP listener, or a plain proxy).
    def handle_upgrade(request, peer, encrypted)
      raise DropConnection if refuses_peer?(peer)

      hops = hops_of(request)
      if hops >= MAX_PROXY_HOPS
        log_error("WebSocket loop detected for #{request_host(request).split(':').first}: request has passed " \
                  "through portless #{hops} times. Set changeOrigin: true in your proxy config.")
        return text(508, "Loop Detected: request has passed through portless too many times.\n" \
                         "Add changeOrigin: true to your dev server proxy config.\n")
      end

      route = self.class.find_route(@get_routes.call, request_host(request), @strict)
      raise DropConnection unless route

      proxy_upgrade(request, route, hops, peer, encrypted)
    end

    def proxy_upgrade(request, route, hops, peer, encrypted)
      headers = build_upstream_headers(request, route, hops, peer, encrypted, strip_hop_by_hop: false)
      %w[connection upgrade].each { |key| headers.delete(key) } # the protocol layer writes these
      upstream_request = ::Protocol::HTTP::Request.new(
        "http", headers.delete("host").to_s, request.method, request.path, nil, headers, request.body, request.protocol
      )
      response = track_upstream(route) { client_for(route, websocket: true).call(upstream_request) }
      if response.status == 101
        # The backend's 101 headers relay verbatim, except the two the
        # protocol layer writes itself when it switches protocols.
        %w[connection upgrade].each { |key| response.headers.delete(key) }
      else
        # A rejection relays the backend's raw headers, Location rewritten.
        # The connection closes after it either way (Node pipes then ends the
        # socket; async-http never reuses an upgrade connection and writes its
        # own `connection: close`), so the backend's copy would only repeat it.
        rewrite_upstream_location(response.headers, route, request, encrypted)
        response.headers.delete("connection")
        # No tunnel: stop reading the client side so the socket closes after
        # the relayed response, as Node ends it.
        request.body&.close rescue nil
      end
      response
    rescue DropConnection
      raise
    rescue StandardError => e
      log_error("WebSocket proxy error for #{request_host(request)}: #{format_proxy_error(e)}") unless e.is_a?(AbortError)
      # The tunnel never opened: stop reading the client side so the
      # connection closes after the 502 (Node's socket.end).
      request.body&.close rescue nil
      body = if tls_error?(e)
               "Bad Gateway: could not connect to the target app over HTTPS. Check that it supports TLS on the configured port.\n"
      else
               "Bad Gateway: the target app is not responding or sent an invalid response to the WebSocket handshake.\n"
      end
      text(502, body, "connection" => "close")
    end

    # RFC 8441 extended CONNECT (WebSocket over HTTP/2) bridged to an HTTP/1.1
    # Upgrade against the backend with a synthesized Sec-WebSocket-Key.
    def handle_extended_connect(request, peer)
      extra = { PORTLESS_HEADER => "1" }
      return with_headers(::Protocol::HTTP::Response[403, {}, nil], extra) if refuses_peer?(peer)
      unless request.protocol.to_s == "websocket"
        return with_headers(text(501, "CONNECT is only supported for WebSockets (RFC 8441)\n"), extra)
      end

      hops = hops_of(request)
      if hops >= MAX_PROXY_HOPS
        log_error("WebSocket loop detected for #{request_host(request).split(':').first}: request has passed " \
                  "through portless #{hops} times. Set changeOrigin: true in your proxy config.")
        return with_headers(text(508, "Loop Detected: request has passed through portless too many times.\n" \
                                      "Add changeOrigin: true to your dev server proxy config.\n"), extra)
      end

      route = self.class.find_route(@get_routes.call, request_host(request), @strict)
      return with_headers(text(404, "No app registered for #{request_host(request)}\n"), extra) unless route

      headers = build_upstream_headers(request, route, hops, peer, true, strip_hop_by_hop: false)
      %w[connection upgrade].each { |key| headers.delete(key) }
      ws_key = SecureRandom.base64(16)
      headers.set("sec-websocket-key", ws_key)
      headers.set("sec-websocket-version", "13") if headers["sec-websocket-version"].nil?
      upstream_request = ::Protocol::HTTP::Request.new(
        "http", headers.delete("host").to_s, "GET", request.path, nil, headers, request.body, "websocket"
      )
      response = track_upstream(route) { client_for(route, websocket: true).call(upstream_request) }

      if response.status == 101
        expected = [ Digest::SHA1.digest(ws_key + WS_GUID) ].pack("m0")
        if response.headers["sec-websocket-accept"].to_s != expected
          log_error("WebSocket proxy error for #{request_host(request)}: backend answered the handshake with an invalid Sec-WebSocket-Accept")
          response.close rescue nil
          return with_headers(text(502, "Bad Gateway: the target app sent an invalid response to the WebSocket handshake.\n"), extra)
        end
        HOP_BY_HOP_HEADERS.each { |key| response.headers.delete(key) }
        response.headers.delete("sec-websocket-accept")
        response.status = 200 # RFC 8441 signals success with :status 200, not 101
      else
        rewrite_upstream_location(response.headers, route, request, true)
        HOP_BY_HOP_HEADERS.each { |key| response.headers.delete(key) }
      end
      with_headers(response, extra)
    rescue DropConnection
      raise
    rescue StandardError => e
      log_error("WebSocket proxy error for #{request_host(request)}: #{format_proxy_error(e)}") unless e.is_a?(AbortError)
      body = tls_error?(e) ? "Bad Gateway: could not connect to the target app over HTTPS. Check that it supports TLS on the configured port.\n" : "Bad Gateway: the target app is not responding\n"
      with_headers(text(502, body), { PORTLESS_HEADER => "1" })
    end

    # --- upstream ----------------------------------------------------------

    # X-Forwarded-* pass through when the client already set them (a proxy in
    # front of us); otherwise they describe this hop.
    def build_upstream_headers(request, route, hops, peer, encrypted, strip_hop_by_hop:)
      headers = ::Protocol::HTTP::Headers.new
      cookies = []
      request.headers.each do |key, value|
        name = key.downcase
        next if name.start_with?(":") || name == HOPS_HEADER || FORWARDED_HEADERS.include?(name)
        next if strip_hop_by_hop && REQUEST_HOP_BY_HOP_HEADERS.include?(name)
        next if name == "host"

        # HTTP/2 clients may split cookies into one field each (RFC 9113
        # §8.2.3); join them with "; " for the HTTP/1.1 backend.
        name == "cookie" ? cookies << value : headers.add(name, value)
      end
      headers.add("cookie", cookies.join("; ")) unless cookies.empty?

      host_header = request_host(request)
      remote = peer || "127.0.0.1"
      xff = header_value(request, "x-forwarded-for")
      headers.set("x-forwarded-for", xff ? "#{xff}, #{remote}" : remote)
      headers.set("x-forwarded-proto", header_value(request, "x-forwarded-proto") || (encrypted ? "https" : "http"))
      headers.set("x-forwarded-host", header_value(request, "x-forwarded-host") || host_header)
      headers.set("x-forwarded-port", header_value(request, "x-forwarded-port") || host_header.split(":")[1] || (encrypted ? "443" : "80"))
      headers.set(HOPS_HEADER, (hops + 1).to_s)
      headers.set("host", upstream_of(route)[:host] || host_header)
      headers
    end

    # A backend reached through `upstream.host` may redirect to its own origin;
    # point such a Location back at the client-facing origin.
    def rewrite_upstream_location(headers, route, request, encrypted)
      upstream = upstream_of(route)
      location = headers["location"]&.to_s
      return if location.nil? || location.empty? || upstream[:host].nil?

      url = URI(location)
      return unless url.is_a?(URI::HTTP) && url.host

      origin = URI("#{upstream[:tls] ? 'https' : 'http'}://#{upstream[:host]}")
      return unless same_origin?(url, origin) && url.userinfo.nil?

      client = URI("#{encrypted ? 'https' : 'http'}://#{request_host(request)}")
      rewritten = URI::Generic.build(scheme: client.scheme, host: client.host, port: client.port,
                                     path: url.path, query: url.query, fragment: url.fragment)
      text = rewritten.to_s
      text = text.sub(":#{client.port}", "") if client.port == client.default_port
      text = "#{text}/" if url.path.empty? && !text.end_with?("/") && url.query.nil? && url.fragment.nil?
      headers.delete("location")
      headers.add("location", text)
    rescue URI::Error
      nil
    end

    def same_origin?(a, b)
      a.scheme.downcase == b.scheme.downcase && a.host.downcase == b.host.downcase && a.port == b.port
    end

    def upstream_of(route)
      value = route.upstream
      return {} unless value.is_a?(Hash)

      value.transform_keys(&:to_sym)
    end

    def upstream_key(route)
      upstream = upstream_of(route)
      [ route.port.to_i, !!upstream[:tls], upstream[:host].to_s ]
    end

    def dial_limit(route)
      @dial_limits[upstream_key(route)] ||= Async::Semaphore.new(MAX_PENDING_UPSTREAM_DIALS)
    end

    def client_for(route, websocket: false)
      upstream = upstream_of(route)
      key = upstream_key(route)
      endpoint = UpstreamEndpoint.new(route.port.to_i, upstream, dial_limit(route), self)
      # WebSocket connections are hijacked by the upgrade, so never pool them.
      return UpstreamClient.new(endpoint, limit: 1) if websocket

      @clients[key] ||= UpstreamClient.new(endpoint, self)
    end

    # The backend dial: race 127.0.0.1 and ::1 (so ::1-only backends work),
    # then TLS (SNI = upstream host, no verification) for `upstream.tls`
    # routes, all within one connect timeout, behind a per-backend
    # pending-dial limit (proxy.ts connectUpstream).
    class UpstreamEndpoint
      def initialize(port, upstream, limit, tracker)
        @port = port
        @upstream = upstream
        @limit = limit
        @tracker = tracker
      end

      def protocol = HTTP1_PROTOCOL
      def scheme = "http"
      def authority = "localhost:#{@port}"
      def secure? = false
      def to_s = "upstream:#{@port}"
      def inspect = "#<#{self.class} #{self}>"

      def connect
        raise AbortError if @tracker.closing?

        @limit.acquire do
          @tracker.upstream_state!(:dialing)
          Async::Task.current.with_timeout(UPSTREAM_CONNECT_TIMEOUT) { dial }
        rescue Async::TimeoutError
          raise Errno::ETIMEDOUT, "Upstream connection timed out"
        end
      end

      def dial
        socket = Proxy.create_loopback_connection(@port)
        return socket unless @upstream[:tls]

        connected = false
        begin
          ctx = OpenSSL::SSL::SSLContext.new
          ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
          ctx.alpn_protocols = [ "http/1.1" ]
          ssl = OpenSSL::SSL::SSLSocket.new(socket, ctx)
          ssl.sync_close = true
          servername = servername_for(@upstream[:host])
          ssl.hostname = servername if servername
          ssl.connect
          connected = true
          ssl
        ensure
          (ssl || socket).close rescue nil unless connected
        end
      end

      def servername_for(authority)
        return nil if authority.nil?

        host = authority.start_with?("[") ? authority[1...authority.index("]")] : authority.split(":").first
        IPAddr.new(host)
        nil # IP literals carry no SNI
      rescue IPAddr::Error
        host
      end
    end

    LOOPBACK_HOSTS = [ [ "127.0.0.1", Socket::AF_INET ], [ "::1", Socket::AF_INET6 ] ].freeze

    # Race both literal loopback addresses; return the first connected socket,
    # or raise an AggregateError once both failed (utils.ts createLoopbackConnection).
    # The caller bounds it with a timeout.
    def self.create_loopback_connection(port)
      task = Async::Task.current
      results = Thread::Queue.new
      attempts = LOOPBACK_HOSTS.each_with_index.map do |(host, family), index|
        task.async do
          socket = Socket.new(family, Socket::SOCK_STREAM, 0)
          handed_off = false
          begin
            socket.connect(Socket.pack_sockaddr_in(port, host))
            results << [ :ok, socket ]
            handed_off = true
          rescue StandardError => e
            results << [ :error, [ index, e ] ]
          ensure
            # The losing attempt is stopped mid-connect: destroy its socket.
            socket.close unless handed_off
          end
        end
      end
      errors = []
      winner = nil
      begin
        until winner || errors.compact.size == 2
          kind, value = results.pop
          kind == :ok ? winner = value : errors[value[0]] = value[1]
        end
      ensure
        attempts.each(&:stop)
        until results.empty?
          kind, value = results.pop
          value.close if kind == :ok && value != winner
        end
      end
      return winner if winner

      details = errors.each_with_index.map { |e, i| node_connect_error(e, LOOPBACK_HOSTS[i][0], port) }
      raise AggregateError.new("Both loopback connections failed", errors, details)
    end

    # String(err) of a Node connect error: "Error: connect ECONNREFUSED 127.0.0.1:4000".
    def self.node_connect_error(error, host, port)
      return "Error: #{error.message}" unless error.is_a?(SystemCallError)

      "Error: connect #{error.class.name.split('::').last} #{host}:#{port}"
    end

    # --- helpers -----------------------------------------------------------

    def request_host(request)
      (request.authority || header_value(request, "host")).to_s
    end

    def header_value(request, name)
      values = request.headers.to_a.select { |key, _| key.downcase == name }.map(&:last)
      values.empty? ? nil : values.join(", ")
    end

    def single_raw_header(request, name)
      values = request.headers.to_a.select { |key, _| key.downcase == name }
      values.size == 1 ? values.first.last.to_s : nil
    end

    def hops_of(request)
      header_value(request, HOPS_HEADER).to_s[/\A\s*[+-]?\d+/].to_i
    end

    def tls_error?(error) = error.is_a?(OpenSSL::SSL::SSLError)

    def format_proxy_error(error)
      error.is_a?(AggregateError) ? [ error.message, *error.details ].reject(&:empty?).join("; ") : error.message
    end

    # Node's err.code: an AggregateError carries its first error's code.
    def error_code(error) = error.is_a?(AggregateError) ? error.errors.first.class : error.class

    def text(status, body, extra = {})
      ::Protocol::HTTP::Response[status, { "content-type" => "text/plain" }.merge(extra), [ body ]]
    end

    def with_headers(response, extra)
      extra.each do |key, value|
        response.headers.delete(key)
        response.headers.add(key, value)
      end
      response
    end

    def log_error(message) = @on_error.call(message)
  end
end
