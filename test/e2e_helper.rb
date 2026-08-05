# frozen_string_literal: true

require_relative "test_helper"
require "net/http"
require "json"
require "socket"
require "digest/sha1"
require "base64"

# Shared harness for the end-to-end tests: boots the real proxy daemon (a child
# process running `exe/rb-portless proxy start --foreground` on a high port, so
# no sudo) against the isolated PORTLESS_STATE_DIR, plus a minimal HTTP/1.1 echo
# backend that reports what it received — the same shape as portless's
# tests/e2e harness. Booted lazily once per test run, torn down at_exit.
module E2E
  WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  module_function

  def proxy_port
    boot!
    @proxy_port
  end

  def backend_port
    boot!
    @backend_port
  end

  def boot!
    return if @proxy_port

    @backend_port = start_backend
    @proxy_port = start_proxy
    at_exit { teardown }
  end

  def teardown
    if @proxy_pid
      begin
        Process.kill("TERM", @proxy_pid)
        Process.wait(@proxy_pid)
      rescue StandardError
        nil
      end
    end
    @backend_server&.close
  rescue StandardError
    nil
  end

  def start_proxy
    port = free_port
    exe = File.expand_path("../exe/rb-portless", __dir__)
    lib = File.expand_path("../lib", __dir__)
    log = File.join(Portless::State.ensure_dir!, "e2e-proxy.log")
    @proxy_pid = Process.spawn(
      { "PORTLESS_STATE_DIR" => Portless::State.dir },
      RbConfig.ruby, "-I", lib, exe,
      "proxy", "start", "--foreground", "--port", port.to_s, "--tls",
      out: log, err: log
    )
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    until Portless::Health.proxy_running?(port, timeout: 0.5)
      raise "proxy did not boot; log:\n#{File.read(log)}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
    port
  end

  # A tiny HTTP/1.1 server: echoes the request (method/path/headers/body) as
  # JSON, or completes a WebSocket handshake and echoes frames back.
  def start_backend
    @backend_server = TCPServer.new("127.0.0.1", 0)
    port = @backend_server.addr[1]
    Thread.new do
      loop do
        client = @backend_server.accept
        Thread.new { handle_backend(client) }
      rescue IOError, Errno::EBADF
        break # server closed at teardown
      end
    end
    port
  end

  def handle_backend(client)
    request_line = client.gets or return client.close
    method, path, = request_line.split(" ")
    headers = {}
    while (line = client.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.strip.downcase] = value.to_s.strip
    end
    body = headers["content-length"] ? client.read(headers["content-length"].to_i) : nil

    if headers["upgrade"].to_s.downcase == "websocket"
      websocket_echo(client, headers)
    else
      payload = JSON.generate(method: method, path: path, headers: headers, body: body)
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
    end
    client.close
  rescue StandardError
    client.close rescue nil
  end

  # Complete the RFC 6455 handshake, then echo one text frame back.
  def websocket_echo(client, headers)
    accept = Base64.strict_encode64(Digest::SHA1.digest(headers["sec-websocket-key"] + WS_GUID))
    client.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
                 "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n")
    payload = read_ws_frame(client)
    client.write(ws_text_frame(payload)) if payload
  end

  # Read one (client→server, masked) text frame's payload.
  def read_ws_frame(io)
    b0 = io.read(1)&.unpack1("C") or return nil
    return nil unless (b0 & 0x0f) == 0x1 # text

    b1 = io.read(1).unpack1("C")
    len = b1 & 0x7f
    len = io.read(len == 126 ? 2 : 8).unpack1(len == 126 ? "n" : "Q>") if len >= 126
    mask = (b1 & 0x80).zero? ? nil : io.read(4).bytes
    data = io.read(len).bytes
    data = data.each_with_index.map { |byte, i| byte ^ mask[i % 4] } if mask
    data.pack("C*")
  end

  # Build an unmasked (server→client) text frame.
  def ws_text_frame(payload)
    header = [ 0x81 ].pack("C")
    header += if payload.bytesize < 126
      [ payload.bytesize ].pack("C")
    else
      [ 126, payload.bytesize ].pack("Cn")
    end
    header + payload
  end

  # Client-side helpers ------------------------------------------------------

  def register(hostname, port = backend_port, pid: Process.pid)
    Portless::RouteStore.new.add(hostname: hostname, port: port, pid: pid, force: true)
  end

  def deregister(hostname, pid: Process.pid)
    Portless::RouteStore.new.remove(hostname, owner_pid: pid)
  end

  # A real HTTPS GET through the proxy, with full peer + hostname verification
  # against the generated CA — exactly what a browser does after `trust`.
  def get(host, path = "/", verify: true)
    http = Net::HTTP.new(host, proxy_port)
    http.ipaddr = "127.0.0.1" # SNI/Host keep the hostname; skip OS DNS entirely
    http.use_ssl = true
    http.ca_file = Portless::State.ca_cert
    http.verify_mode = verify ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
    http.open_timeout = 5
    http.read_timeout = 5
    http.start { |conn| conn.get(path) }
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  # A raw TLS client socket to the proxy with SNI, verified against our CA.
  def tls_socket(sni_host)
    tcp = TCPSocket.new("127.0.0.1", proxy_port)
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
    store = OpenSSL::X509::Store.new
    store.add_file(Portless::State.ca_cert)
    ctx.cert_store = store
    yield ctx if block_given?
    ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
    ssl.hostname = sni_host
    ssl.sync_close = true
    ssl.connect
    ssl
  end
end
