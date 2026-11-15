# frozen_string_literal: true

require "socket"
require "openssl"
require "timeout"

module Portless
  # "Is *our* proxy on this port?" Every proxy response carries `X-Portless: 1`,
  # so a HEAD probe distinguishes a portless proxy from any other process
  # holding the port. Mirrors portless's isProxyRunning (cli-utils.ts).
  module Health
    module_function

    # TCP connect timeout when checking if something is listening (SOCKET_TIMEOUT_MS).
    SOCKET_TIMEOUT = 0.5

    # `tls: true` probes over HTTPS (verification off — the proxy uses the local
    # CA), `false` over plain HTTP. `nil` tries TLS first, then plain HTTP.
    def proxy_running?(port, tls: nil, timeout: SOCKET_TIMEOUT)
      responses = case tls
                  when true then [ probe_tls(port, timeout) ]
                  when false then [ probe_plain(port, timeout) ]
                  else [ probe_tls(port, timeout) || probe_plain(port, timeout) ]
                  end
      responses.any? { |response| marker?(response) }
    end

    # The X-Portless header value on the port, or nil when no proxy answers.
    def proxy_version(port, timeout: SOCKET_TIMEOUT)
      response = probe_tls(port, timeout) || probe_plain(port, timeout)
      header_value(response)
    end

    def request(port) = "HEAD / HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nConnection: close\r\n\r\n"

    def probe_tls(port, timeout)
      socket = TCPSocket.new("127.0.0.1", port, connect_timeout: timeout)
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
      ssl = OpenSSL::SSL::SSLSocket.new(socket, ctx)
      ssl.sync_close = true
      Timeout.timeout(timeout) { ssl.connect }
      ssl.write(request(port))
      Timeout.timeout(timeout) { read_head(ssl) }
    rescue StandardError
      nil
    ensure
      ssl&.close rescue nil
      socket&.close unless ssl
    end

    def probe_plain(port, timeout)
      # TCPSocket, not Socket.tcp: on Ruby 4.0 Socket.tcp with connect_timeout
      # returns a socket even when the connection was refused.
      sock = TCPSocket.new("127.0.0.1", port, connect_timeout: timeout)
      sock.write(request(port))
      Timeout.timeout(timeout) { read_head(sock) }
    rescue StandardError
      nil
    ensure
      sock&.close
    end

    # Whether anything accepts TCP on 127.0.0.1 or ::1 (isPortListening).
    def port_listening?(port, timeout: SOCKET_TIMEOUT)
      %w[127.0.0.1 ::1].any? do |host|
        TCPSocket.new(host, port, connect_timeout: timeout).close
        true
      rescue StandardError
        false
      end
    end

    def read_head(io)
      buffer = +""
      buffer << io.readpartial(4096) until buffer.include?("\r\n\r\n") || buffer.bytesize > 16_384
      buffer
    rescue EOFError
      buffer
    end

    def header_value(response)
      response.to_s[/^#{Regexp.escape(Constants::HEALTH_HEADER)}:[ \t]*([^\r\n]*)/i, 1]&.strip
    end

    def marker?(response) = header_value(response) == "1"

    # The port our proxy is currently on, if any: the marker file, else a probe
    # of the usual suspects.
    def discover_port
      from_file = read_port_file
      return from_file if from_file && proxy_running?(from_file)

      candidates = [ Integer(ENV["PORTLESS_PORT"].to_s, exception: false),
                     Constants::HTTPS_PORT, Constants::HTTP_PORT, Constants::FALLBACK_PROXY_PORT ].compact
      candidates.uniq.each { |port| return port if proxy_running?(port) }
      nil
    end

    def read_port_file
      Integer(File.read(State.proxy_port_file).strip, exception: false)
    rescue StandardError
      nil
    end
  end
end
