# frozen_string_literal: true

require "net/http"
require "openssl"

module Portless
  # "Is *our* proxy on this port?" Every proxy response carries `X-Portless: 1`,
  # so a HEAD probe distinguishes a portless proxy from any other process
  # holding the port. Mirrors portless's isProxyRunning (cli-utils.ts).
  module Health
    module_function

    # TCP connect timeout when checking if something is listening (SOCKET_TIMEOUT_MS).
    SOCKET_TIMEOUT = 0.5

    # Plain HTTP also detects a TLS proxy (it byte-peeks plain requests);
    # `tls` probes over HTTPS without verification (the proxy uses the local CA).
    def proxy_running?(port, tls = false, timeout: SOCKET_TIMEOUT)
      http = Net::HTTP.new("127.0.0.1", port)
      http.open_timeout = timeout
      http.read_timeout = timeout
      if tls
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      http.start { |h| h.head("/") }[Constants::HEALTH_HEADER] == "1"
    rescue StandardError
      false
    end
  end
end
