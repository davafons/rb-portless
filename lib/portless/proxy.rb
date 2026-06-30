# frozen_string_literal: true

require "async"
require "async/http/server"
require "async/http/client"
require "async/http/endpoint"
require "protocol/http/headers"
require "protocol/http/body/buffered"

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

    def initialize(port:, tls: true, route_store: RouteStore.new, certs: Certs.new)
      @port = port
      @tls = tls
      @route_store = route_store
      @certs = certs
      @clients = {}
      @host_contexts = {}
    end

    def run
      State.ensure_dir!
      @certs.ensure_ca! if @tls
      write_markers
      install_signal_handlers

      Async do
        make_server(listen_endpoint).run
        start_redirect_listener if @tls && @port != Constants::HTTP_PORT
      end
    ensure
      cleanup
    end

    # Exact host match, then wildcard fallback so *.name.localhost all reach the
    # single app registered as name.localhost.
    def route_for(host)
      host = host.to_s.split(":").first.to_s.downcase
      routes = @route_store.routes
      routes.find { |r| r.hostname == host } ||
        routes.find { |r| host.end_with?(".#{r.hostname}") }
    end

    private

    def make_server(endpoint)
      Async::HTTP::Server.for(endpoint) { |request| handle(request) }
    end

    def handle(request)
      host = request_host(request)
      route = route_for(host)
      return error(404, "No app is registered for #{host}.") unless route

      hops = request.headers[HOP_HEADER].to_a.first.to_i
      return error(508, "Proxy loop detected for #{host}.") if hops >= Constants::MAX_PROXY_HOPS

      response = client_for(route.port).call(build_forward(request, host, hops))
      response.headers.add(Constants::HEALTH_HEADER, "1")
      response
    rescue StandardError => e
      error(502, "Backend for #{host} is not responding (#{e.class}).")
    end

    def build_forward(request, host, hops)
      headers = Protocol::HTTP::Headers.new
      request.headers.each do |key, value|
        headers.add(key, value) unless HOP_BY_HOP.include?(key.downcase)
      end
      headers.set("x-forwarded-host", host.split(":").first)
      headers.set("x-forwarded-proto", @tls ? "https" : "http")
      headers.set("x-forwarded-port", @port.to_s)
      headers.add(HOP_HEADER, (hops + 1).to_s)

      Protocol::HTTP::Request.new(
        "http", host, request.method, request.path, request.version,
        headers, request.body, request.protocol
      )
    end

    def client_for(port)
      @clients[port] ||= Async::HTTP::Client.new(Async::HTTP::Endpoint.parse("http://127.0.0.1:#{port}"))
    end

    def listen_endpoint
      scheme = @tls ? "https" : "http"
      options = @tls ? { ssl_context: ssl_context } : {}
      Async::HTTP::Endpoint.parse("#{scheme}://0.0.0.0:#{@port}", **options)
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

    # A best-effort :80 listener that bounces plain HTTP to HTTPS.
    def start_redirect_listener
      endpoint = Async::HTTP::Endpoint.parse("http://0.0.0.0:#{Constants::HTTP_PORT}")
      Async::HTTP::Server.for(endpoint) do |request|
        host = request_host(request).split(":").first
        Protocol::HTTP::Response[302, { "location" => "https://#{host}#{request.path}", Constants::HEALTH_HEADER => "1" }, []]
      end.run
    rescue StandardError
      nil # port 80 taken / unavailable — non-fatal.
    end

    def request_host(request)
      (request.authority || request.headers["host"].to_a.first).to_s
    end

    def error(status, message)
      body = Protocol::HTTP::Body::Buffered.wrap("<!doctype html><meta charset=utf-8><title>rb-portless</title>" \
        "<body style='font:16px system-ui;padding:3rem;max-width:40rem;margin:auto'>" \
        "<h1>#{status}</h1><p>#{message}</p></body>")
      Protocol::HTTP::Response[status, { "content-type" => "text/html; charset=utf-8", Constants::HEALTH_HEADER => "1" }, body]
    end

    def write_markers
      File.write(State.proxy_pid_file, Process.pid.to_s)
      File.write(State.proxy_port_file, @port.to_s)
      State.fix_ownership
    end

    def install_signal_handlers
      %w[INT TERM].each { |sig| trap(sig) { cleanup; exit(0) } }
    end

    def cleanup
      [ State.proxy_pid_file, State.proxy_port_file ].each { |f| File.delete(f) if File.exist?(f) }
    rescue StandardError
      nil
    end
  end
end
