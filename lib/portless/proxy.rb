# frozen_string_literal: true

require "async"
require "async/http/server"
require "async/http/client"
require "async/http/endpoint"
require "protocol/http/headers"
require "protocol/http/body/buffered"
require "securerandom"

module Portless
  # The reverse proxy daemon (async-http: HTTP/1.1 + TLS + WebSockets; HTTP/2 in
  # phase 2). Routes by Host to a backend 127.0.0.1:<port> from the route store —
  # exact match, then wildcard *.name — adds X-Forwarded-*, stamps the
  # X-Portless-Rb health header, guards against proxy loops, and re-reads
  # routes.json per request so new apps appear without a restart. A sibling :80
  # listener 302-redirects to HTTPS. Mirrors portless's proxy.ts.
  class Proxy
    HOP_HEADER = "x-rb-portless-hops"
    HOP_BY_HOP = %w[connection keep-alive proxy-authenticate proxy-authorization
                    te trailers transfer-encoding upgrade host].freeze

    def initialize(port:, tls: true, lan: false, route_store: RouteStore.new, certs: Certs.new)
      @port = port
      @tls = tls
      @lan = lan
      @route_store = route_store
      @certs = certs
      @clients = {}
      @host_contexts = {}
    end

    def run
      State.ensure_dir!
      # A second daemon on the same port would overwrite the live one's marker
      # files, then wipe them on its own EADDRINUSE crash — leaving the survivor
      # unstoppable by `proxy stop`. Refuse before touching any state.
      raise Error, "a proxy is already running on :#{@port}" if Health.proxy_running?(@port)

      @certs.ensure_ca! if @tls
      write_markers
      install_signal_handlers

      Async do
        listen_hosts.each { |host| make_server(endpoint_for(host)).run }
        start_redirect_listener if @tls && @port != Constants::HTTP_PORT
      end
    ensure
      cleanup
    end

    # Loopback-only unless LAN mode was asked for: on 0.0.0.0 every registered
    # dev app is reachable from the LAN/VPN by default (upstream shipped the
    # same change as a security fix). `*.localhost` resolves to ::1 too, so an
    # IPv6-loopback sibling always listens (best-effort — its bind failure
    # surfaces as a logged task error, never fatal).
    def listen_hosts
      (@lan ? [ "0.0.0.0" ] : [ "127.0.0.1" ]) + [ "[::1]" ]
    end

    # Exact host match, then a route's public share hostname (tailscale/ngrok —
    # requests forwarded by the tunnel keep the *.ts.net authority, upstream
    # issue #297), then wildcard fallback so *.name.localhost all reach the
    # single app registered as name.localhost.
    #
    # `lan_client:` restricts the search to routes that opted into LAN serving
    # (`run --lan`). LAN mode opens one socket for the whole daemon, so without
    # this every app you happen to be running would answer the whole Wi-Fi.
    def route_for(host, lan_client: false)
      authority = host.to_s.downcase.delete_suffix(":443")
      host = authority.split(":").first.to_s
      routes = @route_store.routes
      routes = routes.select(&:lan?) if lan_client
      routes.find { |r| r.hostname == host } ||
        routes.find { |r| share_match?(r, authority, host) } ||
        routes.find { |r| host.end_with?(".#{r.hostname}") }
    end

    # The reverse-proxy app: resolve the request's host to a backend, forward it,
    # stamp the health header. Public so it can be mounted in a test reactor
    # (Async::HTTP::Server.for(endpoint, &proxy.method(:call))).
    def call(request)
      host = request_host(request)
      # Only consulted in LAN mode: with a loopback-only bind there is no
      # off-machine client, and a stricter default there could 404 local dev if
      # the peer address were ever unreadable.
      lan_client = @lan && !loopback_client?(request)
      route = route_for(host, lan_client: lan_client)
      return not_found(host, lan_client: lan_client) unless route

      hops = request.headers[HOP_HEADER].to_a.first.to_i
      return error(508, "Proxy loop detected for #{host}.") if hops >= Constants::MAX_PROXY_HOPS

      response = with_backend_timeout do
        client_for(route.port).call(build_forward(request, host, hops))
      end
      if response.status == 101 && request.version == "HTTP/2"
        # The h1 backend accepts a WebSocket with 101 Switching Protocols, but
        # HTTP/2 forbids 1xx finals — an extended-CONNECT success is a plain 2xx,
        # and the h1 handshake headers are meaningless (and illegal) on h2.
        response.status = 200
        strip_hop_headers(response)
        response.headers.delete("sec-websocket-accept")
      elsif response.status != 101
        # Hop-by-hop headers are single-hop by definition; relayed into an h2
        # stream a backend's `Connection: close` aborts the whole header block,
        # so the client sees a bare 200 with no headers and no body.
        strip_hop_headers(response)
      end
      response.headers.add(Constants::HEALTH_HEADER, VERSION)
      response
    rescue Async::TimeoutError
      error(504, "Backend for #{host} accepted the connection but never answered.")
    rescue StandardError => e
      error(502, "Backend for #{host} is not responding (#{e.class}).")
    end

    private

    # Does the request authority match this route's public tunnel URL
    # (https://<device>.ts.net[:port] / https://xxxx.ngrok.app)?
    def share_match?(route, authority, host)
      [ route.tailscale, route.ngrok ].compact.any? do |url|
        uri = begin
          URI(url)
        rescue StandardError
          nil
        end
        next false unless uri&.host

        share = uri.port && uri.port != 443 ? "#{uri.host}:#{uri.port}" : uri.host
        authority == share.downcase || host == uri.host.downcase
      end
    end

    # Bound the wait for the backend's response *headers* (body streaming is
    # unaffected) — a backend that accepts and then hangs must not hold client
    # connections forever. No-op outside a reactor (unit tests drive #call
    # directly).
    BACKEND_HEADER_TIMEOUT = 30

    def with_backend_timeout(&block)
      task = Async::Task.current?
      task ? task.with_timeout(BACKEND_HEADER_TIMEOUT, &block) : yield
    end

    def make_server(endpoint)
      Async::HTTP::Server.for(endpoint) { |request| call(request) }
    end

    def build_forward(request, host, hops)
      headers = Protocol::HTTP::Headers.new
      cookies = []
      request.headers.each do |key, value|
        next if HOP_BY_HOP.include?(key.downcase)

        # HTTP/2 clients may split the cookie header into one field per cookie
        # (RFC 9113 §8.2.3); an intermediary translating to HTTP/1.1 MUST
        # concatenate them with "; " — otherwise the backend joins the repeated
        # lines with "," and cookie parsing (split on ";") corrupts the values.
        key.downcase == "cookie" ? cookies << value : headers.add(key, value)
      end
      headers.add("cookie", cookies.join("; ")) unless cookies.empty?
      # Keep the full authority (host:port): Rails rebuilds request.url from
      # X-Forwarded-Host, so stripping the port breaks generated URLs whenever
      # the proxy serves on a non-default port (e.g. the :1355 fallback).
      headers.set("x-forwarded-host", host)
      headers.set("x-forwarded-proto", @tls ? "https" : "http")
      headers.set("x-forwarded-port", @port.to_s)
      # Append (repeated XFF fields join as a comma list) so Rails' remote_ip
      # sees the real client — 127.0.0.1 locally, the device IP in LAN mode.
      headers.add("x-forwarded-for", client_address(request))
      headers.add(HOP_HEADER, (hops + 1).to_s)

      # HTTP/2 WebSockets arrive as extended CONNECT (RFC 8441, :protocol on the
      # request); the HTTP/1.1 equivalent is GET + Upgrade, which the client
      # layer emits from request.protocol. Forwarded raw, the CONNECT verb makes
      # the backend's parser reject the stream. Extended CONNECT also drops
      # Sec-WebSocket-Key (h2 needs no handshake nonce), but an h1 backend
      # refuses an upgrade without one — synthesize it.
      method = request.method
      if method == "CONNECT" && request.protocol
        method = "GET"
        headers.set("sec-websocket-key", SecureRandom.base64(16)) if headers["sec-websocket-key"].nil?
      end

      Protocol::HTTP::Request.new(
        "http", host, method, request.path, request.version,
        headers, request.body, request.protocol
      )
    end

    def client_address(request)
      request.remote_address&.ip_address || "127.0.0.1"
    rescue StandardError
      "127.0.0.1"
    end

    # Is the peer on this machine? Positive identification only — an unreadable
    # address counts as remote, so LAN gating fails closed.
    def loopback_client?(request)
      address = begin
        request.remote_address&.ip_address
      rescue StandardError
        nil
      end
      return false unless address

      address = address.to_s.downcase.delete_prefix("::ffff:")
      address == "::1" || address.start_with?("127.")
    end

    def strip_hop_headers(response)
      HOP_BY_HOP.each { |key| response.headers.delete(key) }
    end

    def client_for(port)
      # "localhost", not 127.0.0.1: the endpoint tries each resolved address in
      # sequence, so an IPv6-only backend (a Node server bound to ::1) still
      # connects — portless happy-eyeballs both loopbacks the same way.
      @clients[port] ||= Async::HTTP::Client.new(Async::HTTP::Endpoint.parse("http://localhost:#{port}"))
    end

    def endpoint_for(host)
      scheme = @tls ? "https" : "http"
      options = @tls ? { ssl_context: ssl_context } : {}
      Async::HTTP::Endpoint.parse("#{scheme}://#{host}:#{@port}", **options)
    end

    # Base TLS context with an SNI callback that swaps in a per-host leaf cert.
    def ssl_context
      context = host_context("localhost")
      context.servername_cb = proc { |_socket, name| host_context(name) }
      context
    end

    def host_context(hostname)
      @host_contexts[hostname] ||= begin
        cert, key = @certs.leaf_for(hostname)
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.add_certificate(cert, key, [ @certs.ca_certificate ])
        # Offer HTTP/2 with HTTP/1.1 fallback. Servers negotiate via the *select*
        # callback (alpn_protocols is the client-side list); async-http then
        # dispatches to its HTTP/2 or HTTP/1.1 server based on the result.
        ctx.alpn_protocols = [ "h2", "http/1.1" ]
        ctx.alpn_select_cb = ->(offered) { ([ "h2", "http/1.1" ] & offered).first || "http/1.1" }
        ctx.session_id_context = "rb-portless"
        ctx
      end
    end

    # A best-effort :80 listener that bounces plain HTTP to HTTPS. Same bind
    # scope as the main listeners (loopback unless LAN).
    def start_redirect_listener
      listen_hosts.each do |host|
        endpoint = Async::HTTP::Endpoint.parse("http://#{host}:#{Constants::HTTP_PORT}")
        Async::HTTP::Server.for(endpoint) do |request|
          request_host = request_host(request).split(":").first
          Protocol::HTTP::Response[302, { "location" => "https://#{request_host}#{request.path}", Constants::HEALTH_HEADER => VERSION }, []]
        end.run
      end
    rescue StandardError
      nil # port 80 taken / unavailable — non-fatal.
    end

    def request_host(request)
      (request.authority || request.headers["host"].to_a.first).to_s
    end

    # The 404 lists what IS running (clickable) plus the command that would
    # register the missing name — upstream portless's most-loved error page.
    # Never to a LAN client though: that would hand anyone on the Wi-Fi the
    # name of every project you have running.
    def not_found(host, lan_client: false)
      return error(404, "No app is registered for <strong>#{escape(host)}</strong>.") if lan_client

      safe_host = escape(host)
      routes = @route_store.routes
      suffix = @port == (@tls ? Constants::HTTPS_PORT : Constants::HTTP_PORT) ? "" : ":#{@port}"
      scheme = @tls ? "https" : "http"
      apps = if routes.empty?
        "<p style='color:#888'>No apps are running.</p>"
      else
        items = routes.map do |r|
          url = "#{scheme}://#{escape(r.hostname)}#{suffix}"
          "<li><a href='#{url}'>#{escape(r.hostname)}</a> <span style='color:#888'>→ :#{r.port.to_i}</span></li>"
        end
        "<p>Active apps:</p><ul>#{items.join}</ul>"
      end
      name = host.to_s.split(":").first.to_s.split(".").first
      name = "myapp" if name.empty?
      hint = "<pre style='background:rgba(128,128,128,.15);padding:.75rem;border-radius:6px'>" \
             "rb-portless #{escape(name)} bin/dev</pre>"
      error(404, "No app is registered for <strong>#{safe_host}</strong>.", extra: "#{apps}#{hint}")
    end

    def error(status, message, extra: "")
      body = Protocol::HTTP::Body::Buffered.wrap("<!doctype html><meta charset=utf-8><title>rb-portless</title>" \
        "<meta name=color-scheme content='light dark'>" \
        "<body style='font:16px system-ui;padding:3rem;max-width:40rem;margin:auto'>" \
        "<h1>#{status}</h1><p>#{message}</p>#{extra}" \
        "<p style='color:#888;margin-top:2rem'>rb-portless</p></body>")
      Protocol::HTTP::Response[status, { "content-type" => "text/html; charset=utf-8", Constants::HEALTH_HEADER => VERSION }, body]
    end

    def escape(value)
      value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;").gsub("'", "&#39;")
    end

    def write_markers
      File.write(State.proxy_pid_file, Process.pid.to_s)
      File.write(State.proxy_port_file, @port.to_s)
      # Record how this daemon was started so restarts (and `run`'s
      # mode-mismatch detection) can preserve/compare it.
      File.write(State.proxy_tls_file, @tls ? "1" : "0")
      if @lan
        File.write(State.proxy_lan_file, "1")
      elsif File.exist?(State.proxy_lan_file)
        File.delete(State.proxy_lan_file)
      end
      State.fix_ownership
    end

    def install_signal_handlers
      %w[INT TERM].each { |sig| trap(sig) { cleanup; exit(0) } }
    end

    # Only reap markers we own — a crashing latecomer must never delete the
    # live daemon's pid/port files.
    def cleanup
      return unless marker_pid == Process.pid

      [ State.proxy_pid_file, State.proxy_port_file,
        State.proxy_lan_file, State.proxy_tls_file ].each do |f|
        File.delete(f) if File.exist?(f)
      end
    rescue StandardError
      nil
    end

    def marker_pid
      Integer(File.read(State.proxy_pid_file).strip, exception: false) if File.exist?(State.proxy_pid_file)
    end
  end
end
