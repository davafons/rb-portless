# frozen_string_literal: true

require "socket"
require "openssl"

module Portless
  # "Is *our* proxy on this port?" — every proxied response carries the
  # X-Portless-Rb header, so a HEAD probe distinguishes our proxy from any other
  # process holding 443/80/1355. The default proxy is HTTPS, so we try a TLS
  # handshake first (no noisy plaintext-to-TLS errors), then plain HTTP.
  # Mirrors portless's isProxyRunning + discoverState.
  module Health
    module_function

    REQUEST = "HEAD / HTTP/1.0\r\nHost: rb-portless.localhost\r\n\r\n"

    def proxy_running?(port, timeout: 1.0)
      probe_tls(port, timeout) || probe_plain(port, timeout)
    end

    def probe_tls(port, timeout)
      socket = Socket.tcp("127.0.0.1", port, connect_timeout: timeout)
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
      ssl = OpenSSL::SSL::SSLSocket.new(socket, ctx)
      ssl.sync_close = true
      ssl.connect
      ssl.write(REQUEST)
      marker?(ssl.read(4096))
    rescue StandardError
      false
    ensure
      ssl&.close
      socket&.close unless ssl
    end

    def probe_plain(port, timeout)
      Socket.tcp("127.0.0.1", port, connect_timeout: timeout) do |sock|
        sock.write(REQUEST)
        sock.close_write
        marker?(sock.read(4096))
      end
    rescue StandardError
      false
    end

    def marker?(response) = response.to_s.downcase.include?(Constants::HEALTH_HEADER)

    # The port our proxy is currently on, if any: an explicit marker file, else a
    # probe of the usual suspects.
    def discover_port
      from_file = read_port_file
      return from_file if from_file && proxy_running?(from_file)

      candidates = [ Integer(ENV["PORTLESS_PORT"], exception: false),
                     Constants::HTTPS_PORT, Constants::HTTP_PORT, Constants::FALLBACK_PROXY_PORT ].compact
      candidates.each { |port| return port if proxy_running?(port) }
      nil
    end

    def read_port_file
      Integer(File.read(State.proxy_port_file).strip, exception: false)
    rescue StandardError
      nil
    end
  end
end
